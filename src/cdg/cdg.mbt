// Structured control dependence for the moon-slice MVP.
//
// The algorithm is syntax-directed: it reads the `parent` / `children` tree of
// `@core.Program` and never computes post-dominators. See LIMITATIONS.md in
// this directory for what that buys and what it costs.

///|
/// Read-only index over a `@core.Program` tree.
///
/// `children` is the union of the explicit `SNode.children` links and the
/// inverse of `SNode.parent`, deduplicated, so a front end that fills in only
/// one side of the tree still yields a usable structure. `all` holds every node
/// id in the program and is used as the unbounded escape region.
priv struct Index {
  by_id : Map[Int32, @core.SNode]
  ids : Array[Int32]
  children : Map[Int32, Array[Int32]]
  parent : Map[Int32, Int32]
  all : Set[Int32]
}

///|
fn index_program(program : @core.Program) -> Index {
  let by_id : Map[Int32, @core.SNode] = Map([])
  let ids : Array[Int32] = []
  for node in program.nodes {
    by_id.set(node.id, node)
    ids.push(node.id)
  }
  let all : Set[Int32] = Set([])
  for id in ids {
    all.add(id)
  }
  let parent : Map[Int32, Int32] = Map([])
  for node in program.nodes {
    match node.parent {
      Some(p) =>
        if p != node.id && by_id.contains(p) && !parent.contains(node.id) {
          parent.set(node.id, p)
        }
      None => ()
    }
  }
  let children : Map[Int32, Array[Int32]] = Map([])
  for node in program.nodes {
    let kids : Array[Int32] = []
    let seen : Set[Int32] = Set([])
    for kid in node.children {
      if kid != node.id && by_id.contains(kid) && !seen.contains(kid) {
        seen.add(kid)
        kids.push(kid)
        if !parent.contains(kid) {
          parent.set(kid, node.id)
        }
      }
    }
    if !kids.is_empty() {
      children.set(node.id, kids)
    }
  }
  // Second pass: a node that only declared a parent still has to appear in
  // that parent's child list, otherwise subtree walks would miss it.
  for node in program.nodes {
    match parent.get(node.id) {
      None => ()
      Some(p) =>
        match children.get(p) {
          None => children.set(p, [node.id])
          Some(kids) => if !kids.contains(node.id) { kids.push(node.id) }
        }
    }
  }
  { by_id, ids, children, parent, all, }
}

///|
fn is_control_kind(kind : @core.SNodeKind) -> Bool {
  match kind {
    @core.If | @core.While | @core.For | @core.Match => true
    _ => false
  }
}

///|
fn is_loop_kind(kind : @core.SNodeKind) -> Bool {
  match kind {
    @core.While | @core.For => true
    _ => false
  }
}

///|
/// The node itself plus every transitive child, following the `children` map.
fn subtree(index : Index, id : Int32) -> Set[Int32] {
  let out : Set[Int32] = Set([])
  out.add(id)
  let stack : Array[Int32] = [id]
  while !stack.is_empty() {
    let current = stack.pop().unwrap()
    match index.children.get(current) {
      None => ()
      Some(kids) =>
        for kid in kids {
          if !out.contains(kid) {
            out.add(kid)
            stack.push(kid)
          }
        }
    }
  }
  out
}

///|
/// Walks ancestors of `id` looking for the nearest `while`/`for`. `fuel` bounds
/// the walk, which keeps cycles in a malformed `parent` map from hanging the
/// analysis.
fn enclosing_loop_from(index : Index, id : Int32, fuel : Int32) -> Int32? {
  if fuel <= 0 {
    return None
  }
  match index.parent.get(id) {
    None => None
    Some(p) =>
      match index.by_id.get(p) {
        None => None
        Some(node) =>
          if is_loop_kind(node.kind) {
            Some(p)
          } else {
            enclosing_loop_from(index, p, fuel - 1)
          }
      }
  }
}

///|
fn enclosing_loop(index : Index, id : Int32) -> Int32? {
  enclosing_loop_from(index, id, index.ids.length() + 1)
}

///|
/// Reports which kinds of abrupt exit occur inside a subtree:
/// `(has return, has break or continue)`.
fn subtree_escapes(index : Index, inner : Set[Int32]) -> (Bool, Bool) {
  let mut has_return = false
  let mut has_jump = false
  for id in inner.to_array() {
    match index.by_id.get(id) {
      None => ()
      Some(node) =>
        match node.kind {
          @core.Return => has_return = true
          @core.Break | @core.Continue => has_jump = true
          _ => ()
        }
    }
  }
  (has_return, has_jump)
}

///|
/// Walks ancestors of `id` collecting them. `fuel` bounds the walk, which keeps
/// cycles in a malformed `parent` map from hanging the analysis.
fn collect_ancestors(
  index : Index,
  id : Int32,
  fuel : Int32,
  out : Set[Int32],
) -> Unit {
  if fuel <= 0 {
    return
  }
  match index.parent.get(id) {
    None => ()
    Some(p) =>
      if !out.contains(p) {
        out.add(p)
        collect_ancestors(index, p, fuel - 1, out)
      }
  }
}

///|
/// Every ancestor of `id`. Those nodes execute before `id`, so an abrupt exit
/// from `id` can never skip them.
fn ancestors(index : Index, id : Int32) -> Set[Int32] {
  let out : Set[Int32] = Set([])
  collect_ancestors(index, id, index.ids.length() + 1, out)
  out
}

///|
/// Region the escape rule is allowed to mark as controlled by a control node.
///
/// The base region is every node in the program for a `return`, and the
/// enclosing loop's subtree for a `break`/`continue` (a jump only skips the rest
/// of its loop). Ancestors of the control node are then removed: they execute
/// before it, so no exit from it can skip them. Removing ancestors also keeps
/// the CFG walk from following a back edge into the loop header, which would
/// otherwise make the loop condition look control dependent on its own body.
fn escape_region(index : Index, id : Int32, has_return : Bool) -> Set[Int32] {
  let base = if has_return {
    index.all
  } else {
    match enclosing_loop(index, id) {
      Some(loop_id) => subtree(index, loop_id)
      None => index.all
    }
  }
  let blocked = ancestors(index, id)
  let region : Set[Int32] = Set([])
  for candidate in base.to_array() {
    if !blocked.contains(candidate) {
      region.add(candidate)
    }
  }
  region
}

///|
/// Nodes outside `inner` that a control node governs through an abrupt exit:
/// breadth-first walk over the CFG, seeded with the successors of every node in
/// `inner` (including the control node itself, so an `if` without an `else`
/// still reaches its continuation), bounded by `region`.
fn escape_targets(
  succ : Map[Int32, Array[Int32]],
  inner : Set[Int32],
  region : Set[Int32],
) -> Array[Int32] {
  let targets : Array[Int32] = []
  let visited : Set[Int32] = Set([])
  let queue : Array[Int32] = []
  for node_id in inner.to_array() {
    match succ.get(node_id) {
      None => ()
      Some(next) =>
        for n in next {
          if !inner.contains(n) && !visited.contains(n) && region.contains(n) {
            visited.add(n)
            queue.push(n)
            targets.push(n)
          }
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
        for n in next {
          if !inner.contains(n) && !visited.contains(n) && region.contains(n) {
            visited.add(n)
            queue.push(n)
            targets.push(n)
          }
        }
    }
  }
  targets
}

///|
fn cfg_successors(cfg : @core.Cfg) -> Map[Int32, Array[Int32]] {
  let succ : Map[Int32, Array[Int32]] = Map([])
  for (from, to) in cfg.edges {
    match succ.get(from) {
      None => succ.set(from, [to])
      Some(next) => next.push(to)
    }
  }
  succ
}

///|
fn cmp_pair(a : (Int32, Int32), b : (Int32, Int32)) -> Int32 {
  if a.0 != b.0 {
    return if a.0 < b.0 { -1 } else { 1 }
  }
  if a.1 != b.1 {
    return if a.1 < b.1 { -1 } else { 1 }
  }
  0
}

///|
/// Builds the structured control-dependence graph of `program`.
///
/// The controller of a branch is the control node itself (`If`, `While`, `For`,
/// `Match`), whose `uses` are expected to carry the condition's variables. Two
/// rules apply:
///
/// 1. **Nesting rule.** A control node controls every node nested in its
///    branches or body at any depth. A nested control node is therefore both
///    controlled by its parent and a controller of its own body.
/// 2. **Escape rule (conservative).** When a control node has a descendant of
///    kind `Return`, or of kind `Break`/`Continue` and is not itself a loop, the
///    code an abrupt exit may skip is also marked control dependent on it. The
///    skipped set is found by walking `cfg` from the frontier of the node's
///    subtree: unbounded for `Return`, bounded by the enclosing loop for
///    `Break`/`Continue`. A loop only triggers this rule for `Return`, because
///    leaving a loop through `break` is its normal exit.
///
/// Self-edges are dropped, duplicates removed, and the result sorted by
/// `(controller, controlled)` so equal inputs always produce equal output. Only
/// ids present in `program` can appear in an edge, even when `cfg` mentions
/// unknown ids.
///
/// # Limitations
///
/// See `LIMITATIONS.md`: no post-dominator computation, so loop-carried control
/// dependences and non-structured control flow are not modelled, and the escape
/// rule deliberately over-approximates.
pub fn build(program : @core.Program, cfg : @core.Cfg) -> @core.Cdg {
  let index = index_program(program)
  let succ = cfg_successors(cfg)
  let collected : Array[(Int32, Int32)] = []
  for id in index.ids {
    match index.by_id.get(id) {
      Some(node) =>
        if is_control_kind(node.kind) {
          let inner = subtree(index, id)
          for node_id in inner.to_array() {
            if node_id != id {
              collected.push((id, node_id))
            }
          }
          let (has_return, has_jump) = subtree_escapes(index, inner)
          let escape_matters = has_return ||
            (has_jump && !is_loop_kind(node.kind))
          if escape_matters {
            let region = escape_region(index, id, has_return)
            for target in escape_targets(succ, inner, region) {
              collected.push((id, target))
            }
          }
        }
      None => ()
    }
  }
  let seen : Set[(Int32, Int32)] = Set([])
  let edges : Array[(Int32, Int32)] = []
  for pair in collected {
    if pair.0 != pair.1 && !seen.contains(pair) {
      seen.add(pair)
      edges.push(pair)
    }
  }
  edges.sort_by(cmp_pair)
  { edges, }
}
