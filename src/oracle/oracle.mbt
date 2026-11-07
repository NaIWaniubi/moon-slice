// Reference slicer: an independent, brute-force oracle for the analysis
// pipeline.
//
// This package deliberately shares no code with `src/cfg`, `src/defuse`,
// `src/cdg`, `src/pdg` or `src/slice`. Everything below is rebuilt from
// `@core.Program` alone: the control-flow relation, the data-flow facts and the
// control-dependence facts are all derived by *enumerating executions* and
// simulating each one. That is exponential, and that is the point — it makes a
// second, structurally different implementation available so the real pipeline
// can be differential-tested against it.
//
// The method, in three steps:
//
//   1. `ref_cfg` rebuilds a control-flow relation from the statement tree. It
//      follows the same IR conventions the adapter documents (a control node
//      owns one region node per body; a region's children are its statements;
//      `for` update blocks are trailing `Expr` children of the body region) but
//      nothing of the existing pass's code.
//   2. `ref_enumerate` walks every execution from the function entry to its exit,
//      unrolling loops a bounded number of times. Each walk is a concrete path,
//      so data flow on it can be simulated directly instead of solved as a fixed
//      point.
//   3. The paths are folded into two relations:
//        data    `(def, use)`  — a definition is the most recent write of a
//                                variable read by `use` on some path;
//        control `(head, y)`   — `y` is executed on every path that leaves some
//                                successor of `head`, but not on every path that
//                                leaves another successor. (That is the exact
//                                "postdominates one successor but not all"
//                                criterion, evaluated over the enumerated
//                                paths.)
//
// A slice is then plain reachability in that relation: backward follows edges
// in reverse, forward follows them forward, and the criterion node is always
// part of its own slice.
//
// Limits, all reported through `RefDependences.truncated`:
//
//   * a node may be visited at most `MAX_VISITS` times per path (loop unroll),
//   * a path may not exceed `max_steps`,
//   * at most `MAX_PATHS` complete paths are kept.
//
// Exhausting a loop bound is *not* truncation: it simply stops that walk. A run
// is truncated only when the path table or the step budget runs out, because
// only then can a dependence be missing.

///|
/// How many times one node may appear on a single enumerated path. Four is
/// enough for every dependence a straight-line loop body can express: a write in
/// iteration *i* reaching a read in iteration *i+1*, *i+2* or *i+3*.
let max_visits : Int = 4

///|
/// Upper bound on the number of complete paths kept per function.
let max_paths : Int = 20000

///|
/// Innermost enclosing loop, used to resolve `break` / `continue` in the
/// reference control-flow relation.
priv struct RefLoop {
  continue_to : Int32
  break_to : Int32
}

///|
/// Mutable build state. `edges` and the maps are reference values, so pushing
/// through a copy of this struct is visible to the caller.
priv struct RefBuild {
  by_id : Map[Int32, @core.SNode]
  edges : Array[(Int32, Int32)]
  exit_id : Int32
}

///|
/// One function's boundary in `@core.Program`.
priv struct RefRegion {
  entry : Int32
  exit : Int32
}

///|
/// One continuation recorded during path enumeration: the branch node, the
/// successor the path took, and the rest of the execution from that successor.
priv struct RefCont {
  branch : Int32
  first : Int32
  cont : Array[Int32]
}

///|
/// Enumeration state: the paths found so far, the visit counters and the
/// resource flags.
priv struct RefWalk {
  succ : Map[Int32, Array[Int32]]
  exit : Int32
  paths : Array[Array[Int32]]
  counts : Array[Int32]
  step_limit : Int
  truncated : Array[Bool]
}

///|
/// The reference dependence relation for one program.
pub(all) struct RefDependences {
  /// `(definition node, use node)` pairs.
  data : Array[(Int32, Int32)]
  /// `(control node, controlled node)` pairs.
  control : Array[(Int32, Int32)]
  /// True when a resource bound stopped the enumeration, so the relation may be
  /// missing edges rather than holding all of them.
  truncated : Bool
  /// Number of complete execution paths the relation was computed from.
  paths : Int32
}

///|
/// True when `items` contains `needle`.
fn ref_member(items : Array[Int32], needle : Int32) -> Bool {
  let mut i = 0
  let mut found = false
  while i < items.length() {
    if items[i] == needle {
      found = true
    }
    i = i + 1
  }
  found
}

///|
/// Append `value` unless it is already present.
fn ref_push_unique(items : Array[Int32], value : Int32) -> Unit {
  if !ref_member(items, value) {
    items.push(value)
  }
}

///|
/// Append a pair unless it is already present.
fn ref_push_pair(items : Array[(Int32, Int32)], pair : (Int32, Int32)) -> Unit {
  let mut i = 0
  let mut found = false
  while i < items.length() {
    if items[i].0 == pair.0 && items[i].1 == pair.1 {
      found = true
    }
    i = i + 1
  }
  if !found {
    items.push(pair)
  }
}

///|
/// Copy an array of node ids.
fn ref_copy_nodes(items : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = []
  for item in items {
    out.push(item)
  }
  out
}

///|
/// Copy the loop stack so an inner walk cannot mutate its caller's view.
fn ref_copy_loops(loops : Array[RefLoop]) -> Array[RefLoop] {
  let out : Array[RefLoop] = []
  for item in loops {
    out.push(item)
  }
  out
}

///|
/// The function regions of `program`, in order.
///
/// A program without `functions` entries (a hand-built tree in a test) is taken
/// as one region spanning every node id from the smallest to the largest.
fn ref_regions(program : @core.Program) -> Array[RefRegion] {
  let out : Array[RefRegion] = []
  if program.functions.length() > 0 {
    for function in program.functions {
      out.push({ entry: function.entry, exit: function.exit })
    }
  } else if program.nodes.length() > 0 {
    let mut low = program.nodes[0].id
    let mut high = program.nodes[0].id
    for node in program.nodes {
      if node.id < low {
        low = node.id
      }
      if node.id > high {
        high = node.id
      }
    }
    out.push({ entry: low, exit: high })
  }
  out
}

///|
/// Record an edge unless it is a self edge or an endpoint outside the program.
fn ref_add(builder : RefBuild, from : Int32, to : Int32) -> Unit {
  if from < 0 || to < 0 || from == to {
    return
  }
  builder.edges.push((from, to))
}

///|
/// Rebuild the control-flow relation of `program` from its statement tree.
///
/// The relation is returned as a successor map with duplicate edges collapsed
/// and self edges removed. Nodes only appear as successors when they are
/// reachable, so a dead statement simply has no successor entry of its own —
/// which is exactly what path enumeration needs.
fn ref_cfg(program : @core.Program) -> Map[Int32, Array[Int32]] {
  let by_id : Map[Int32, @core.SNode] = Map([])
  for node in program.nodes {
    if !by_id.contains(node.id) {
      by_id.set(node.id, node)
    }
  }
  let edges : Array[(Int32, Int32)] = []
  for region in ref_regions(program) {
    let builder : RefBuild = { by_id, edges, exit_id: region.exit, }
    let top : Array[Int32] = []
    for node in program.nodes {
      if node.id > region.entry && node.id < region.exit {
        match node.parent {
          None => top.push(node.id)
          Some(_) => ()
        }
      }
    }
    top.sort()
    if top.length() == 0 {
      ref_add(builder, region.entry, region.exit)
    } else {
      ref_add(builder, region.entry, top[0])
      ref_walk(builder, top, region.exit, [])
    }
  }
  let succ : Map[Int32, Array[Int32]] = Map([])
  for (from, to) in edges {
    match succ.get(from) {
      None => succ.set(from, [to])
      Some(existing) => ref_push_unique(existing, to)
    }
  }
  succ
}

///|
/// Walk a statement list, threading the fall-through edge from the last
/// statement to `after`.
fn ref_walk(
  builder : RefBuild,
  statements : Array[Int32],
  after : Int32,
  loops : Array[RefLoop],
) -> Unit {
  let mut i = 0
  while i < statements.length() {
    let node = match builder.by_id.get(statements[i]) {
      Some(node) => node
      None => {
        i = i + 1
        continue
      }
    }
    let next = if i + 1 < statements.length() {
      statements[i + 1]
    } else {
      after
    }
    ref_dispatch(builder, node, next, loops)
    i = i + 1
  }
}

///|
/// Emit the edges of one statement.
fn ref_dispatch(
  builder : RefBuild,
  node : @core.SNode,
  next : Int32,
  loops : Array[RefLoop],
) -> Unit {
  match node.kind {
    Return => ref_add(builder, node.id, builder.exit_id)
    Break =>
      match loops.last() {
        Some(loop_) => ref_add(builder, node.id, loop_.break_to)
        None => ref_add(builder, node.id, next)
      }
    Continue =>
      match loops.last() {
        Some(loop_) => ref_add(builder, node.id, loop_.continue_to)
        None => ref_add(builder, node.id, next)
      }
    If => {
      let regions = node.children
      if regions.length() == 0 {
        ref_add(builder, node.id, next)
      } else {
        ref_branch(builder, node.id, regions[0], next, loops)
        if regions.length() > 1 {
          ref_branch(builder, node.id, regions[1], next, loops)
        } else {
          ref_add(builder, node.id, next)
        }
      }
    }
    While | For => {
      let regions = node.children
      if regions.length() == 0 {
        ref_add(builder, node.id, next)
      } else {
        ref_loop_body(builder, node, regions[0], next, loops)
        if regions.length() > 1 {
          ref_branch(builder, node.id, regions[1], next, loops)
        } else {
          ref_add(builder, node.id, next)
        }
      }
    }
    Match => {
      let regions = node.children
      if regions.length() == 0 {
        ref_add(builder, node.id, next)
      } else {
        for region in regions {
          ref_branch(builder, node.id, region, next, loops)
        }
      }
    }
    // A `for` update block: control reaches the first update, then the rest of
    // the block in order, then `next`.
    Expr => {
      if node.children.length() == 0 {
        ref_add(builder, node.id, next)
      } else {
        ref_add(builder, node.id, node.children[0])
        ref_walk(builder, node.children, next, loops)
      }
    }
    _ => ref_add(builder, node.id, next)
  }
}

///|
/// Enter one branch region: `head -> region -> first statement`, and the
/// region's statements fall through to `next`.
fn ref_branch(
  builder : RefBuild,
  head : Int32,
  region : Int32,
  next : Int32,
  loops : Array[RefLoop],
) -> Unit {
  ref_add(builder, head, region)
  let statements = match builder.by_id.get(region) {
    Some(node) => node.children
    None => []
  }
  if statements.length() == 0 {
    ref_add(builder, region, next)
  } else {
    ref_add(builder, region, statements[0])
    ref_walk(builder, statements, next, loops)
  }
}

///|
/// Enter a loop body: same as `ref_branch`, but the body falls back to the loop
/// head, which is the back edge.
fn ref_loop_body(
  builder : RefBuild,
  head : @core.SNode,
  region : Int32,
  next : Int32,
  loops : Array[RefLoop],
) -> Unit {
  ref_add(builder, head.id, region)
  let statements = match builder.by_id.get(region) {
    Some(node) => node.children
    None => []
  }
  if statements.length() == 0 {
    ref_add(builder, region, head.id)
    return
  }
  ref_add(builder, region, statements[0])
  let inner = ref_copy_loops(loops)
  inner.push({ continue_to: ref_continue_target(builder, head, statements), break_to: next, })
  ref_walk(builder, statements, head.id, inner)
}

///|
/// Where a `continue` in `head`'s body resumes. A C-style `for` carries its
/// update block as a trailing `Expr` child of the body region; everything else
/// resumes at the loop head.
fn ref_continue_target(
  builder : RefBuild,
  head : @core.SNode,
  statements : Array[Int32],
) -> Int32 {
  if head.kind != @core.SNodeKind::For || statements.length() == 0 {
    return head.id
  }
  let last = match builder.by_id.get(statements[statements.length() - 1]) {
    Some(node) => node
    None => return head.id
  }
  if last.kind == @core.SNodeKind::Expr &&
    last.loc == head.loc &&
    last.children.length() > 0 {
    last.children[0]
  } else {
    head.id
  }
}

///|
/// Every complete execution path of one function region, bounded by
/// `walk.step_limit`, `max_visits` per node and `max_paths` paths.
fn ref_enumerate(
  succ : Map[Int32, Array[Int32]],
  entry : Int32,
  exit : Int32,
  step_limit : Int,
  size : Int,
) -> RefWalk {
  // Visit counters are indexed by node id. Ids from the adapter are dense; a
  // hand-built program with gaps just gets a larger table. `size` is
  // `max(id) + 1` over the whole program, computed by the caller.
  let counts : Array[Int32] = []
  let mut i = 0
  while i < size {
    counts.push(0)
    i = i + 1
  }
  let walk : RefWalk = {
    succ,
    exit,
    paths: [],
    counts,
    step_limit,
    truncated: [false],
  }
  let path : Array[Int32] = []
  ref_dfs(walk, entry, path)
  walk
}

///|
/// Depth-first enumeration. `path` is the current execution prefix; the visit
/// counter guards against unbounded unrolling, and both are undone on return so
/// sibling branches start from the same state.
fn ref_dfs(walk : RefWalk, node : Int32, path : Array[Int32]) -> Unit {
  if walk.truncated[0] {
    return
  }
  if path.length() >= walk.step_limit || walk.paths.length() >= max_paths {
    walk.truncated[0] = true
    return
  }
  if node < 0 || node >= walk.counts.length() {
    return
  }
  if walk.counts[node] >= max_visits {
    // Reached the unroll bound: stop this walk, but that is not a resource
    // failure of the whole enumeration.
    return
  }
  path.push(node)
  walk.counts[node] = walk.counts[node] + 1
  if node == walk.exit {
    let snapshot = ref_copy_nodes(path)
    walk.paths.push(snapshot)
  } else {
    match walk.succ.get(node) {
      None => ()
      Some(next) =>
        for candidate in next {
          ref_dfs(walk, candidate, path)
        }
    }
  }
  walk.counts[node] = walk.counts[node] - 1
  ignore(path.pop())
}

///|
/// Run the reference analysis on `program`.
pub fn reference_dependences(program : @core.Program) -> RefDependences {
  let by_id : Map[Int32, @core.SNode] = Map([])
  for node in program.nodes {
    if !by_id.contains(node.id) {
      by_id.set(node.id, node)
    }
  }
  let succ = ref_cfg(program)
  let step_limit = program.nodes.length() * 12 + 32
  let mut size = 1
  for node in program.nodes {
    if node.id + 1 > size {
      size = node.id + 1
    }
  }
  for function in program.functions {
    if function.entry + 1 > size {
      size = function.entry + 1
    }
    if function.exit + 1 > size {
      size = function.exit + 1
    }
  }
  let data : Array[(Int32, Int32)] = []
  let control : Array[(Int32, Int32)] = []
  let mut truncated = false
  let mut path_count = 0
  for region in ref_regions(program) {
    let walk = ref_enumerate(succ, region.entry, region.exit, step_limit, size)
    if walk.truncated[0] {
      truncated = true
    }
    path_count = path_count + walk.paths.length()
    ref_collect_data(walk.paths, by_id, data)
    ref_collect_control(walk.paths, succ, control)
  }
  ref_collect_region_control(program, control)
  data.sort_by(ref_cmp_pair)
  control.sort_by(ref_cmp_pair)
  { data, control, truncated, paths: path_count, }
}

///|
/// Total order on node-id pairs, so the relation is deterministic.
fn ref_cmp_pair(a : (Int32, Int32), b : (Int32, Int32)) -> Int32 {
  if a.0 != b.0 {
    return if a.0 < b.0 { -1 } else { 1 }
  }
  if a.1 != b.1 {
    return if a.1 < b.1 { -1 } else { 1 }
  }
  0
}

///|
/// Look up a variable's current definition in a path-local association list.
fn ref_state_get(state : Array[(@core.VarId, Int32)], needle : @core.VarId) -> Int32? {
  let mut i = state.length() - 1
  while i >= 0 {
    if state[i].0 == needle {
      return Some(state[i].1)
    }
    i = i - 1
  }
  None
}

///|
/// Overwrite the path-local definition of `needle`.
fn ref_state_set(
  state : Array[(@core.VarId, Int32)],
  needle : @core.VarId,
  value : Int32,
) -> Unit {
  let mut i = state.length() - 1
  while i >= 0 {
    if state[i].0 == needle {
      state[i] = (needle, value)
      return
    }
    i = i - 1
  }
  state.push((needle, value))
}

///|
/// Simulate each path and record `(definition, use)` pairs.
///
/// Every path is one concrete execution, so the definition that reaches a use is
/// simply the most recent write of that variable on the path. Unioning over all
/// paths is exactly "may reach".
fn ref_collect_data(
  paths : Array[Array[Int32]],
  by_id : Map[Int32, @core.SNode],
  out : Array[(Int32, Int32)],
) -> Unit {
  for path in paths {
    let state : Array[(@core.VarId, Int32)] = []
    for id in path {
      match by_id.get(id) {
        None => ()
        Some(node) => {
          for used in node.uses {
            match ref_state_get(state, used) {
              // The pair may name the same node twice: in a loop, the write in
              // one iteration reaches the same statement's read in the next.
              // A self pair adds nothing to a slice, but it is a real fact and
              // the pipeline reports it too.
              Some(def_id) => ref_push_pair(out, (def_id, id))
              None => ()
            }
          }
          for defined in node.defs {
            ref_state_set(state, defined, id)
          }
        }
      }
    }
  }
}

///|
/// Record `(controller, controlled)` pairs from the enumerated continuations.
///
/// For a branch node `head` with successors `s1 … sk`, `y` is control dependent
/// on `head` when `y` lies on every continuation that leaves one successor but
/// not on every continuation that leaves another. That is the exact
/// post-dominator criterion, evaluated over the enumerated executions; a join
/// point that all successors reach fails the second half and is correctly
/// excluded.
fn ref_collect_control(
  paths : Array[Array[Int32]],
  succ : Map[Int32, Array[Int32]],
  out : Array[(Int32, Int32)],
) -> Unit {
  let records : Array[RefCont] = []
  for path in paths {
    let mut i = 0
    while i + 1 < path.length() {
      let branch = path[i]
      let out_degree = match succ.get(branch) {
        None => 0
        Some(next) => next.length()
      }
      if out_degree >= 2 {
        let cont : Array[Int32] = []
        let mut j = i + 1
        while j < path.length() {
          cont.push(path[j])
          j = j + 1
        }
        records.push({ branch, first: path[i + 1], cont })
      }
      i = i + 1
    }
  }
  let branches : Array[Int32] = []
  for record in records {
    ref_push_unique(branches, record.branch)
  }
  branches.sort()
  for branch in branches {
    let successors : Array[Int32] = []
    for record in records {
      if record.branch == branch {
        ref_push_unique(successors, record.first)
      }
    }
    if successors.length() < 2 {
      continue
    }
    let musts : Array[Array[Int32]] = []
    for successor in successors {
      let mut must : Array[Int32] = []
      let mut first_seen = true
      for record in records {
        if record.branch == branch && record.first == successor {
          if first_seen {
            must = ref_copy_nodes(record.cont)
            first_seen = false
          } else {
            must = ref_intersect(must, record.cont)
          }
        }
      }
      musts.push(must)
    }
    let executed : Array[Int32] = []
    for record in records {
      if record.branch == branch {
        for id in record.cont {
          ref_push_unique(executed, id)
        }
      }
    }
    for y in executed {
      if y == branch {
        continue
      }
      let mut witness = -1
      let mut k = 0
      while k < musts.length() {
        if witness < 0 && ref_member(musts[k], y) {
          witness = k
        }
        k = k + 1
      }
      if witness < 0 {
        continue
      }
      let mut escaped = false
      k = 0
      while k < musts.length() {
        if k != witness && !ref_member(musts[k], y) {
          escaped = true
        }
        k = k + 1
      }
      if escaped {
        ref_push_pair(out, (branch, y))
      }
    }
  }
}

///|
/// Set intersection, preserving the left operand's order.
fn ref_intersect(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = []
  for item in left {
    if ref_member(right, item) {
      out.push(item)
    }
  }
  out
}

///|
/// True for the kinds the IR uses for both a control head and its region.
fn ref_is_control_kind(kind : @core.SNodeKind) -> Bool {
  match kind {
    @core.If | @core.While | @core.For | @core.Match => true
    _ => false
  }
}

///|
/// Collect every descendant of `id` through the child relation, excluding `id`.
fn ref_collect_descendants(
  id : Int32,
  children : Map[Int32, Array[Int32]],
  out : Array[Int32],
) -> Unit {
  let stack : Array[Int32] = [id]
  let mut head = 0
  while head < stack.length() {
    let current = stack[head]
    head = head + 1
    match children.get(current) {
      None => ()
      Some(kids) =>
        for kid in kids {
          if kid != id && !ref_member(out, kid) {
            out.push(kid)
            stack.push(kid)
          }
        }
    }
  }
}

///|
/// The region rule: a region node carries its construct's kind and owns one
/// body, so it also governs the statements of that body.
///
/// This is an IR convention, not an analysis choice. The adapter gives every
/// branch and loop body its own region node with the construct's kind, so a
/// region is a real node in every slice that touches its construct; the
/// pipeline's syntax-directed control dependence therefore reports
/// `(region, statement)` edges. The reference derives the same relation straight
/// from the tree — a region governs exactly its descendants — so a slice
/// comparison is about analysis, not about which nodes happen to exist.
fn ref_collect_region_control(
  program : @core.Program,
  out : Array[(Int32, Int32)],
) -> Unit {
  let by_id : Map[Int32, @core.SNode] = Map([])
  for node in program.nodes {
    if !by_id.contains(node.id) {
      by_id.set(node.id, node)
    }
  }
  let children : Map[Int32, Array[Int32]] = Map([])
  for node in program.nodes {
    for kid in node.children {
      match children.get(node.id) {
        None => children.set(node.id, [kid])
        Some(existing) => ref_push_unique(existing, kid)
      }
    }
    match node.parent {
      None => ()
      Some(owner) =>
        match children.get(owner) {
          None => children.set(owner, [node.id])
          Some(existing) => ref_push_unique(existing, node.id)
        }
    }
  }
  for node in program.nodes {
    if !ref_is_control_kind(node.kind) {
      continue
    }
    let owned = match node.parent {
      None => false
      Some(owner) =>
        match by_id.get(owner) {
          None => false
          Some(parent) => ref_is_control_kind(parent.kind)
        }
    }
    if owned {
      let descendants : Array[Int32] = []
      ref_collect_descendants(node.id, children, descendants)
      for y in descendants {
        ref_push_pair(out, (node.id, y))
      }
    }
  }
}

///|
/// Slice over the reference relation: the criterion plus every node that
/// reaches it (`forward = false`) or is reached from it (`forward = true`).
fn ref_slice(
  deps : RefDependences,
  target : Int32,
  forward : Bool,
) -> Array[Int32] {
  let adjacency : Map[Int32, Array[Int32]] = Map([])
  let pairs : Array[(Int32, Int32)] = []
  for pair in deps.data {
    pairs.push(pair)
  }
  for pair in deps.control {
    pairs.push(pair)
  }
  for (from, to) in pairs {
    let source = if forward { from } else { to }
    let destination = if forward { to } else { from }
    match adjacency.get(source) {
      None => adjacency.set(source, [destination])
      Some(existing) => ref_push_unique(existing, destination)
    }
  }
  let seen : Array[Int32] = [target]
  let queue : Array[Int32] = [target]
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    match adjacency.get(current) {
      None => ()
      Some(next) =>
        for candidate in next {
          if !ref_member(seen, candidate) {
            seen.push(candidate)
            queue.push(candidate)
          }
        }
    }
  }
  seen.sort()
  seen
}

///|
/// Reference backward slice: every node that may have produced the value used at
/// `target`, plus whatever produced *those* values, transitively.
///
/// `target` is always included, even when it has no incoming dependence.
pub fn reference_backward(program : @core.Program, target : Int32) -> Array[Int32] {
  ref_slice(reference_dependences(program), target, false)
}

///|
/// Reference forward slice: every node the value defined at `target` may affect,
/// transitively.
pub fn reference_forward(program : @core.Program, target : Int32) -> Array[Int32] {
  ref_slice(reference_dependences(program), target, true)
}
