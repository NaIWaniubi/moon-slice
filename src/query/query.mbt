// Query helpers over a lowered `@core.Program`.

///|
/// Resolve a node id without assuming ids are array indexes. The adapter emits
/// dense ids, but a hand-built `Program` need not, and indexing by id would then
/// read the wrong node or run off the end.
fn node_by_id(program : @core.Program, id : Int32) -> @core.SNode? {
  for node in program.nodes {
    if node.id == id {
      return Some(node)
    }
  }
  None
}

///|
/// `id -> node` table. Used by the helpers that are called once per slice node,
/// where a linear scan per lookup would make a large result quadratic.
fn node_table(program : @core.Program) -> Map[Int32, @core.SNode] {
  let table : Map[Int32, @core.SNode] = Map([])
  for node in program.nodes {
    if !table.contains(node.id) {
      table.set(node.id, node)
    }
  }
  table
}

///|
fn is_synthetic(program : @core.Program, node : @core.SNode) -> Bool {
  for f in program.functions {
    if node.id == f.entry || node.id == f.exit {
      return true
    }
  }
  false
}

///|
fn is_region(program : @core.Program, node : @core.SNode) -> Bool {
  let control = node.kind == @core.SNodeKind::If ||
    node.kind == @core.SNodeKind::While ||
    node.kind == @core.SNodeKind::For ||
    node.kind == @core.SNodeKind::Match
  if !control || node.uses.length() != 0 || node.children.length() == 0 {
    return false
  }
  match node.parent {
    None => false
    Some(pid) =>
      match node_by_id(program, pid) {
        None => false
        Some(parent) => parent.kind == node.kind && parent.loc == node.loc
      }
  }
}

///|
fn is_statement_kind(kind : @core.SNodeKind) -> Bool {
  match kind {
    @core.SNodeKind::Let => true
    @core.SNodeKind::LetMut => true
    @core.SNodeKind::Assign => true
    @core.SNodeKind::Return => true
    @core.SNodeKind::Break => true
    @core.SNodeKind::Continue => true
    @core.SNodeKind::Call => true
    _ => false
  }
}

///|
/// Whether a node with this id exists in `program`.
pub fn node_exists(program : @core.Program, id : Int32) -> Bool {
  match node_by_id(program, id) {
    Some(_) => true
    None => false
  }
}

///|
/// All node ids whose `loc.start_line` equals `line`, ascending.
pub fn nodes_at_line(program : @core.Program, line : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  for node in program.nodes {
    if node.loc.start_line == line {
      out.push(node.id)
    }
  }
  out.sort()
  out
}

///|
/// All statement-level candidates on `line`, ascending: real statements first,
/// then control heads, then other non-region nodes. Regions and synthetic
/// entry/exit nodes are excluded.
///
/// The CLI uses this to report ambiguity when several statements share a line
/// (`let a = h(x); let b = k(x)`), instead of silently picking the first one.
pub fn statement_candidates(
  program : @core.Program,
  line : Int32,
) -> Array[Int32] {
  let statement : Array[Int32] = []
  let control : Array[Int32] = []
  let other : Array[Int32] = []
  for node in program.nodes {
    if node.loc.start_line != line || is_synthetic(program, node) || is_region(program, node) {
      continue
    }
    if is_statement_kind(node.kind) {
      statement.push(node.id)
    } else if node.kind == @core.SNodeKind::If ||
      node.kind == @core.SNodeKind::While ||
      node.kind == @core.SNodeKind::For ||
      node.kind == @core.SNodeKind::Match {
      control.push(node.id)
    } else {
      other.push(node.id)
    }
  }
  statement.sort()
  control.sort()
  other.sort()
  let out : Array[Int32] = []
  for id in statement {
    out.push(id)
  }
  for id in control {
    out.push(id)
  }
  for id in other {
    out.push(id)
  }
  out
}

///|
/// Pick the best node for a source line.
///
/// Preference: a real statement node, then a control head, then any non-region
/// node, then anything at all (synthetic entry for a function header). Regions
/// and synthetic entry/exit nodes are excluded unless nothing else matches.
pub fn target_node(program : @core.Program, line : Int32) -> Int32? {
  let candidates = statement_candidates(program, line)
  if candidates.length() > 0 {
    return Some(candidates[0])
  }
  let fallback : Array[Int32] = []
  for node in program.nodes {
    if node.loc.start_line != line {
      continue
    }
    if is_synthetic(program, node) || is_region(program, node) {
      fallback.push(node.id)
    }
  }
  if fallback.length() > 0 {
    Some(fallback[0])
  } else {
    None
  }
}

///|
/// Definition nodes whose definitions never reach a use.
pub fn dead_nodes(
  program : @core.Program,
  defuse : @core.DefUse,
) -> Array[Int32] {
  let used : Set[Int32] = Set([])
  for pair in defuse.reaching {
    used.add(pair.0)
  }
  let out : Array[Int32] = []
  for node in program.nodes {
    if node.defs.length() > 0 &&
      !is_synthetic(program, node) &&
      !used.contains(node.id) {
      out.push(node.id)
    }
  }
  out.sort()
  out
}

///|
/// Unique sorted start lines for the given node ids.
pub fn lines_of(program : @core.Program, nodes : Array[Int32]) -> Array[Int32] {
  let table = node_table(program)
  let out : Array[Int32] = []
  for id in nodes {
    match table.get(id) {
      None => ()
      Some(node) => {
        let line = node.loc.start_line
        if !out.contains(line) {
          out.push(line)
        }
      }
    }
  }
  out.sort()
  out
}

///|
/// Like `lines_of`, but drops synthetic entry/exit nodes. Those nodes carry the
/// function signature's line, which is not a statement a user asked to slice.
pub fn visible_lines(
  program : @core.Program,
  nodes : Array[Int32],
) -> Array[Int32] {
  let table = node_table(program)
  let out : Array[Int32] = []
  for id in nodes {
    match table.get(id) {
      None => ()
      Some(node) =>
        if !is_synthetic(program, node) {
          let line = node.loc.start_line
          if !out.contains(line) {
            out.push(line)
          }
        }
    }
  }
  out.sort()
  out
}

///|
/// Nodes not reachable from any function entry in `cfg`. Synthetic entry/exit
/// nodes are excluded from the result.
pub fn unreachable_nodes(
  program : @core.Program,
  cfg : @core.Cfg,
) -> Array[Int32] {
  let n = program.nodes.length()
  let seen : Set[Int32] = Set([])
  let queue : Array[Int32] = []
  for f in program.functions {
    if f.entry >= 0 && f.entry < n && !seen.contains(f.entry) {
      seen.add(f.entry)
      queue.push(f.entry)
    }
  }
  // One adjacency pass instead of scanning every edge per dequeued node.
  let succ : Map[Int32, Array[Int32]] = Map([])
  for edge in cfg.edges {
    if edge.0 >= 0 && edge.0 < n && edge.1 >= 0 && edge.1 < n {
      match succ.get(edge.0) {
        None => succ.set(edge.0, [edge.1])
        Some(next) => next.push(edge.1)
      }
    }
  }
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    match succ.get(current) {
      None => ()
      Some(next) =>
        for candidate in next {
          if !seen.contains(candidate) {
            seen.add(candidate)
            queue.push(candidate)
          }
        }
    }
  }
  let out : Array[Int32] = []
  for node in program.nodes {
    if !seen.contains(node.id) && !is_synthetic(program, node) {
      out.push(node.id)
    }
  }
  out.sort()
  out
}

///|
/// Sorted union of two node-id arrays.
pub fn union_sorted(a : Array[Int32], b : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = []
  for x in a {
    if !out.contains(x) {
      out.push(x)
    }
  }
  for x in b {
    if !out.contains(x) {
      out.push(x)
    }
  }
  out.sort()
  out
}

///|
/// Nodes that define or use a variable with the given source name.
pub fn nodes_with_name(program : @core.Program, name : String) -> Array[Int32] {
  let out : Array[Int32] = []
  for node in program.nodes {
    let mut hit = false
    for v in node.defs {
      if v.name == name {
        hit = true
      }
    }
    for v in node.uses {
      if v.name == name {
        hit = true
      }
    }
    if hit {
      out.push(node.id)
    }
  }
  out.sort()
  out
}

///|
/// Shortest directed PDG path from any start node to any goal node.
/// Returns the nodes in flow order, or `None` when no path exists.
pub fn path_between(
  pdg : @core.Pdg,
  starts : Array[Int32],
  goals : Array[Int32],
) -> Array[Int32]? {
  let goal_set : Set[Int32] = Set([])
  for g in goals {
    goal_set.add(g)
  }
  // Build the forward adjacency once. Scanning `pdg.edges` per dequeued node
  // makes the search O(V*E); this makes it O(V+E).
  let succ : Map[Int32, Array[Int32]] = Map([])
  for e in pdg.edges {
    match succ.get(e.from) {
      None => succ.set(e.from, [e.to])
      Some(next) => next.push(e.to)
    }
  }
  let visited : Set[Int32] = Set([])
  let parent : Map[Int32, Int32] = Map([])
  let queue : Array[Int32] = []
  for s in starts {
    if !visited.contains(s) {
      visited.add(s)
      queue.push(s)
    }
  }
  let mut head = 0
  let mut found : Int32? = None
  while head < queue.length() && found == None {
    let current = queue[head]
    head = head + 1
    if goal_set.contains(current) {
      found = Some(current)
    } else {
      match succ.get(current) {
        None => ()
        Some(next) =>
          for candidate in next {
            if !visited.contains(candidate) {
              visited.add(candidate)
              parent.set(candidate, current)
              queue.push(candidate)
            }
          }
      }
    }
  }
  match found {
    None => None
    Some(goal) => {
      let reversed : Array[Int32] = [goal]
      let mut current = goal
      while parent.contains(current) {
        current = parent.get(current).unwrap()
        reversed.push(current)
      }
      let path : Array[Int32] = []
      let mut i = reversed.length() - 1
      while i >= 0 {
        path.push(reversed[i])
        i = i - 1
      }
      Some(path)
    }
  }
}

///|
/// Nodes that define a variable with the given name.
pub fn nodes_defining_name(
  program : @core.Program,
  name : String,
) -> Array[Int32] {
  let out : Array[Int32] = []
  for node in program.nodes {
    for v in node.defs {
      if v.name == name {
        out.push(node.id)
      }
    }
  }
  out.sort()
  out
}

///|
/// Nodes that use a variable with the given name.
pub fn nodes_using_name(program : @core.Program, name : String) -> Array[Int32] {
  let out : Array[Int32] = []
  for node in program.nodes {
    for v in node.uses {
      if v.name == name {
        out.push(node.id)
      }
    }
  }
  out.sort()
  out
}

///|
/// Heuristic call graph: for each function, a `Call` node's first use is the
/// callee name when the callee is a free function. Only edges to functions
/// defined in the same program are emitted; method calls and function values
/// are intentionally omitted. The result is deduplicated and in function order.
pub fn call_edges(program : @core.Program) -> Array[(String, String)] {
  let names : Set[String] = Set([])
  for f in program.functions {
    names.add(f.name)
  }
  let out : Array[(String, String)] = []
  for call in program.calls {
    if call.caller != "" && names.contains(call.callee) {
      let edge = (call.caller, call.callee)
      if !out.contains(edge) {
        out.push(edge)
      }
    }
  }
  out
}

///|
fn function_named(
  program : @core.Program,
  name : String,
) -> @core.FunctionInfo? {
  for f in program.functions {
    if f.name == name {
      return Some(f)
    }
  }
  None
}

///|
fn call_site_node(
  program : @core.Program,
  caller : @core.FunctionInfo,
  callee_name : String,
  line : Int32,
  nodes : Array[Int32],
) -> @core.SNode? {
  let table = node_table(program)
  for id in nodes {
    match table.get(id) {
      None => ()
      Some(node) =>
        if id > caller.entry && id < caller.exit && node.loc.start_line == line {
          for variable in node.uses {
            if variable.name == callee_name {
              return Some(node)
            }
          }
        }
    }
  }
  // Keep a line-based fallback for unsupported/qualified expressions whose
  // callee name is not preserved in the node uses.
  for id in nodes {
    match table.get(id) {
      None => ()
      Some(node) =>
        if id > caller.entry && id < caller.exit && node.loc.start_line == line {
          return Some(node)
        }
    }
  }
  None
}

///|
/// Nodes that can reach any return of `callee`. This is the callee's
/// return-value cone: dead stores and branches that do not affect the return
/// are excluded.
fn return_cone(
  program : @core.Program,
  pdg : @core.Pdg,
  callee : @core.FunctionInfo,
) -> Array[Int32] {
  let out : Array[Int32] = []
  for node in program.nodes {
    if node.id > callee.entry &&
      node.id < callee.exit &&
      node.kind == @core.SNodeKind::Return {
      let slice = @slice.backward(pdg, node.id, program~)
      for id in slice.nodes {
        if !out.contains(id) {
          out.push(id)
        }
      }
    }
  }
  out
}

///|
/// Inter-procedural expansion. A value-returning call (`let`/assignment/return
/// position) adds only the callee's return-value cone, so dead stores in the
/// callee are excluded. A bare call statement adds the whole callee body,
/// because its side effects cannot be summarized yet. Repeats to a fixed point
/// so chains expand transitively. Side effects of value-returning calls are not
/// modeled; this is the documented conservative boundary.
pub fn expand_calls(
  program : @core.Program,
  pdg : @core.Pdg,
  result : @core.SliceResult,
) -> @core.SliceResult {
  let nodes : Array[Int32] = []
  for id in result.nodes {
    if !nodes.contains(id) {
      nodes.push(id)
    }
  }
  let mut changed = true
  let mut rounds = 0
  let max_rounds = program.functions.length() + 2
  while changed && rounds < max_rounds {
    changed = false
    rounds = rounds + 1
    for call in program.calls {
      let caller = function_named(program, call.caller)
      let callee = function_named(program, call.callee)
      match (caller, callee) {
        (Some(cf), Some(ef)) =>
          match call_site_node(program, cf, call.callee, call.line, nodes) {
            Some(node) =>
              if node.kind == @core.SNodeKind::Call {
                let mut i = ef.entry + 1
                while i < ef.exit {
                  if !nodes.contains(i) {
                    nodes.push(i)
                    changed = true
                  }
                  i = i + 1
                }
              } else {
                let cone = return_cone(program, pdg, ef)
                if cone.length() == 0 {
                  let mut i = ef.entry + 1
                  while i < ef.exit {
                    if !nodes.contains(i) {
                      nodes.push(i)
                      changed = true
                    }
                    i = i + 1
                  }
                } else {
                  for id in cone {
                    if !nodes.contains(id) {
                      nodes.push(id)
                      changed = true
                    }
                  }
                }
              }
            None => ()
          }
        _ => ()
      }
    }
  }
  nodes.sort()
  @core.SliceResult::{ nodes, lines: visible_lines(program, nodes), }
}
