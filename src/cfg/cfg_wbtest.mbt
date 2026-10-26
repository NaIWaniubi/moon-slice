// Whitebox tests for CFG paths that the parser cannot produce.
//
// The builder must stay total: a hand-built `Program` (which mission 4 and the
// slicing tests will use) may omit regions, have an empty function body, or hold
// a stray `break`. These tests build `@core.Program` values directly so those
// defensive branches are exercised and pinned.

///|
fn empty_loc() -> @core.Loc {
  { start_line: 0, start_col: 0, end_line: 0, end_col: 0, }
}

///|
fn node(
  id : Int32,
  kind : @core.SNodeKind,
  parent : Int32?,
  children : Array[Int32],
) -> @core.SNode {
  { id, kind, loc: empty_loc(), defs: [], uses: [], children, parent, }
}

///|
fn program_of_nodes(
  nodes : Array[@core.SNode],
  functions : Array[@core.FunctionInfo],
) -> @core.Program {
  { nodes, functions, errors: [], }
}

///|
test "a function with an empty body still connects entry to exit" {
  let nodes : Array[@core.SNode] = [
    node(0, @core.SNodeKind::Expr, None, []),
    node(1, @core.SNodeKind::Expr, None, []),
  ]
  let functions : Array[@core.FunctionInfo] = [
    { name: "f", entry: 0, exit: 1, },
  ]
  let cfg = build(program_of_nodes(nodes, functions))
  assert_eq(cfg.edges, [(0, 1)])
}

///|
test "a stray continue outside a loop falls through" {
  let nodes : Array[@core.SNode] = [
    node(0, @core.SNodeKind::Expr, None, []),
    node(1, @core.SNodeKind::Continue, None, []),
    node(2, @core.SNodeKind::Expr, None, []),
  ]
  let functions : Array[@core.FunctionInfo] = [
    { name: "f", entry: 0, exit: 2, },
  ]
  let cfg = build(program_of_nodes(nodes, functions))
  assert_eq(cfg.edges, [(0, 1), (1, 2)])
}

///|
test "an if head with no regions falls through" {
  let nodes : Array[@core.SNode] = [
    node(0, @core.SNodeKind::Expr, None, []),
    node(1, @core.SNodeKind::If, None, []),
    node(2, @core.SNodeKind::Expr, None, []),
  ]
  let functions : Array[@core.FunctionInfo] = [
    { name: "f", entry: 0, exit: 2, },
  ]
  let cfg = build(program_of_nodes(nodes, functions))
  assert_eq(cfg.edges, [(0, 1), (1, 2)])
}

///|
test "a while head with no regions falls through" {
  let nodes : Array[@core.SNode] = [
    node(0, @core.SNodeKind::Expr, None, []),
    node(1, @core.SNodeKind::While, None, []),
    node(2, @core.SNodeKind::Expr, None, []),
  ]
  let functions : Array[@core.FunctionInfo] = [
    { name: "f", entry: 0, exit: 2, },
  ]
  let cfg = build(program_of_nodes(nodes, functions))
  assert_eq(cfg.edges, [(0, 1), (1, 2)])
}

///|
test "a match head with no regions falls through" {
  let nodes : Array[@core.SNode] = [
    node(0, @core.SNodeKind::Expr, None, []),
    node(1, @core.SNodeKind::Match, None, []),
    node(2, @core.SNodeKind::Expr, None, []),
  ]
  let functions : Array[@core.FunctionInfo] = [
    { name: "f", entry: 0, exit: 2, },
  ]
  let cfg = build(program_of_nodes(nodes, functions))
  assert_eq(cfg.edges, [(0, 1), (1, 2)])
}

///|
test "a loop with an empty body region still has a back edge" {
  //  while head -> empty body region -> head
  let nodes : Array[@core.SNode] = [
    node(0, @core.SNodeKind::Expr, None, []),
    node(1, @core.SNodeKind::While, None, [2]),
    node(2, @core.SNodeKind::While, Some(1), []),
    node(3, @core.SNodeKind::Expr, None, []),
  ]
  let functions : Array[@core.FunctionInfo] = [
    { name: "f", entry: 0, exit: 3, },
  ]
  let cfg = build(program_of_nodes(nodes, functions))
  assert_true(cfg.edges.contains((1, 2)))
  assert_true(cfg.edges.contains((2, 1)))
  assert_true(cfg.edges.contains((1, 3)))
}

///|
test "a loop with only an else region models it as the exiting path" {
  //  while head -> body region(with one stmt) and an else region
  let nodes : Array[@core.SNode] = [
    node(0, @core.SNodeKind::Expr, None, []),
    node(1, @core.SNodeKind::While, None, [2, 4]),
    node(2, @core.SNodeKind::While, Some(1), [3]),
    node(3, @core.SNodeKind::Expr, Some(2), []),
    node(4, @core.SNodeKind::While, Some(1), []),
    node(5, @core.SNodeKind::Expr, None, []),
  ]
  let functions : Array[@core.FunctionInfo] = [
    { name: "f", entry: 0, exit: 5, },
  ]
  let cfg = build(program_of_nodes(nodes, functions))
  // The else region is entered from the head and exits forward.
  assert_true(cfg.edges.contains((1, 4)))
  assert_true(cfg.edges.contains((4, 5)))
}

///|
test "a node id outside the function is not treated as a top-level statement" {
  // Entry 1, exit 3: node 0 belongs to nothing and must be ignored.
  let nodes : Array[@core.SNode] = [
    node(0, @core.SNodeKind::Expr, None, []),
    node(1, @core.SNodeKind::Expr, None, []),
    node(2, @core.SNodeKind::Expr, None, []),
    node(3, @core.SNodeKind::Expr, None, []),
  ]
  let functions : Array[@core.FunctionInfo] = [
    { name: "f", entry: 1, exit: 3, },
  ]
  let cfg = build(program_of_nodes(nodes, functions))
  assert_eq(cfg.edges, [(1, 2), (2, 3)])
}

///|
test "duplicate edges are collapsed" {
  let nodes : Array[@core.SNode] = [
    node(0, @core.SNodeKind::Expr, None, []),
    node(1, @core.SNodeKind::Break, None, []),
    node(2, @core.SNodeKind::Expr, None, []),
  ]
  let functions : Array[@core.FunctionInfo] = [
    { name: "f", entry: 0, exit: 2, },
  ]
  let cfg = build(program_of_nodes(nodes, functions))
  // Only the fall-through edge exists, once.
  assert_eq(cfg.edges, [(0, 1), (1, 2)])
}
