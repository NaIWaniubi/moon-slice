///|
fn loc(line : Int32) -> @core.Loc {
  { start_line: line, start_col: 1, end_line: line, end_col: 8 }
}

///|
fn node(
  id : Int32,
  kind : @core.SNodeKind,
  line : Int32,
  children~ : Array[Int32] = [],
  parent~ : Int32? = None,
) -> @core.SNode {
  { id, kind, loc: loc(line), defs: [], uses: [], children, parent }
}

///|
fn program(nodes : Array[@core.SNode]) -> @core.Program {
  { nodes, functions: [], errors: [] }
}

///|
fn cfg(edges : Array[(Int32, Int32)], entry : Int32, exit : Int32) -> @core.Cfg {
  { edges, entry, exit }
}

///|
test "leaf statements have no dependences" {
  let prog = program([
    node(0, @core.Let, 1),
    node(1, @core.Assign, 2),
    node(2, @core.Call, 3),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (1, 2)], 0, 2))
  assert_eq(result.edges, [])
}

///|
test "if controls both branches and nested statements" {
  // 0: if cond
  // 1: then-stmt      2: nested if
  // 3: nested-then    4: else-stmt
  // 5: continuation
  let prog = program([
    node(0, @core.If, 1, children=[1, 2, 4], parent=None),
    node(1, @core.Assign, 2, parent=Some(0)),
    node(2, @core.If, 3, children=[3], parent=Some(0)),
    node(3, @core.Assign, 4, parent=Some(2)),
    node(4, @core.Assign, 5, parent=Some(0)),
    node(5, @core.Assign, 6),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (0, 4), (1, 2), (2, 3), (2, 5)], 0, 5))
  assert_eq(result.edges, [(0, 1), (0, 2), (0, 3), (0, 4), (2, 3)])
}

///|
test "while controls its body but not the following statement" {
  // 0: while    1: body stmt   2: after loop
  let prog = program([
    node(0, @core.While, 1, children=[1], parent=None),
    node(1, @core.Assign, 2, parent=Some(0)),
    node(2, @core.Assign, 3),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (1, 0), (0, 2)], 0, 2))
  assert_eq(result.edges, [(0, 1)])
}

///|
test "for controls its body and nested if" {
  // 0: for   1: body   2: nested if   3: nested body
  let prog = program([
    node(0, @core.For, 1, children=[1, 2], parent=None),
    node(1, @core.Assign, 2, parent=Some(0)),
    node(2, @core.If, 3, children=[3], parent=Some(0)),
    node(3, @core.Assign, 4, parent=Some(2)),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (1, 2), (2, 3), (3, 0)], 0, 2))
  assert_eq(result.edges, [(0, 1), (0, 2), (0, 3), (2, 3)])
}

///|
test "match controls every arm" {
  // 0: match   1: arm a   2: arm b   3: continuation
  let prog = program([
    node(0, @core.Match, 1, children=[1, 2], parent=None),
    node(1, @core.Assign, 2, parent=Some(0)),
    node(2, @core.Assign, 3, parent=Some(0)),
    node(3, @core.Assign, 4),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (0, 2), (1, 3), (2, 3)], 0, 3))
  assert_eq(result.edges, [(0, 1), (0, 2)])
}

///|
test "return inside if controls the skipped continuation" {
  // 0: if      1: return     2: after the if
  let prog = program([
    node(0, @core.If, 1, children=[1], parent=None),
    node(1, @core.Return, 2, parent=Some(0)),
    node(2, @core.Assign, 3),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (0, 2), (1, 2)], 0, 2))
  // 2 runs only when the return branch was not taken.
  assert_eq(result.edges, [(0, 1), (0, 2)])
}

///|
test "break inside if is bounded by the enclosing loop" {
  // 0: while
  // 1: if        2: break
  // 3: skipped body statement
  // 4: after the loop (not controllable by the if: break stays in the loop)
  let prog = program([
    node(0, @core.While, 1, children=[1, 3], parent=None),
    node(1, @core.If, 2, children=[2], parent=Some(0)),
    node(2, @core.Break, 3, parent=Some(1)),
    node(3, @core.Assign, 4, parent=Some(0)),
    node(4, @core.Assign, 5),
  ])
  let result = @cdg.build(
    prog,
    cfg([(0, 1), (1, 2), (1, 3), (2, 4), (3, 0), (0, 4)], 0, 4),
  )
  // The while controls its whole body, including the break. The if additionally
  // controls the body statement it skips. Code after the loop is NOT included:
  // break stays inside the loop.
  assert_eq(result.edges, [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3)])
}

///|
test "continue inside if is bounded by the enclosing loop" {
  // 0: while   1: if   2: continue   3: skipped
  let prog = program([
    node(0, @core.While, 1, children=[1, 3], parent=None),
    node(1, @core.If, 2, children=[2], parent=Some(0)),
    node(2, @core.Continue, 3, parent=Some(1)),
    node(3, @core.Assign, 4, parent=Some(0)),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (1, 2), (1, 3), (2, 0), (3, 0)], 0, 0))
  assert_eq(result.edges, [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3)])
}

///|
test "return in a loop controls code after the loop" {
  // 0: while   1: return   2: after the loop
  let prog = program([
    node(0, @core.While, 1, children=[1], parent=None),
    node(1, @core.Return, 2, parent=Some(0)),
    node(2, @core.Assign, 3),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (1, 2), (0, 2)], 0, 2))
  assert_eq(result.edges, [(0, 1), (0, 2)])
}

///|
test "a return nested in a loop reaches past the loop via the return edge" {
  // 0: while
  //   1: if        2: return
  //   3: after the loop
  //
  // 3 runs only when the body never returned, so it is control dependent on the
  // if at 1 and on the loop condition at 0. The escape walk finds it from the
  // CFG edge `return -> after`, and the ancestor filter keeps node 0 from being
  // marked dependent on its own descendant 1.
  let prog = program([
    node(0, @core.While, 1, children=[1], parent=None),
    node(1, @core.If, 2, children=[2], parent=Some(0)),
    node(2, @core.Return, 3, parent=Some(1)),
    node(3, @core.Assign, 4),
  ])
  let result = @cdg.build(
    prog,
    cfg([(0, 1), (1, 2), (1, 0), (2, 3), (0, 3)], 0, 3),
  )
  assert_eq(result.edges, [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3)])
}

///|
test "break alone in a loop does not create an escape edge" {  // A loop naturally ends, so the statement after it is not control dependent
  // on the loop condition.
  let prog = program([
    node(0, @core.While, 1, children=[1], parent=None),
    node(1, @core.Break, 2, parent=Some(0)),
    node(2, @core.Assign, 3),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (1, 2), (0, 2)], 0, 2))
  assert_eq(result.edges, [(0, 1)])
}

///|
test "children and parent links are reconciled" {
  // Only the parent side is declared; the walk must still nest 2 inside 0.
  let prog = program([
    node(0, @core.If, 1),
    node(1, @core.Assign, 2, parent=Some(0)),
    node(2, @core.If, 3, parent=Some(0)),
    node(3, @core.Assign, 4, parent=Some(2)),
  ])
  let result = @cdg.build(prog, cfg([(0, 1), (0, 2), (2, 3)], 0, 3))
  assert_eq(result.edges, [(0, 1), (0, 2), (0, 3), (2, 3)])
}

///|
test "unknown child ids and self links are ignored" {
  let prog = program([
    node(0, @core.If, 1, children=[0, 99, 1]),
    node(1, @core.Assign, 2, parent=Some(0)),
  ])
  let result = @cdg.build(prog, cfg([(0, 1)], 0, 1))
  assert_eq(result.edges, [(0, 1)])
}

///|
test "duplicate declarations collapse to one edge" {
  // Both the child list and the parent field declare the same nesting, and 0
  // is listed twice.
  let prog = program([
    node(0, @core.If, 1, children=[1, 1]),
    node(1, @core.Assign, 2, parent=Some(0)),
  ])
  let result = @cdg.build(prog, cfg([(0, 1)], 0, 1))
  assert_eq(result.edges, [(0, 1)])
}

///|
test "edges are sorted by controller then controlled" {
  let prog = program([
    node(5, @core.Assign, 6),
    node(3, @core.If, 4, children=[5]),
    node(1, @core.Assign, 2),
    node(4, @core.If, 5, children=[1]),
  ])
  let result = @cdg.build(prog, cfg([], 0, 5))
  assert_eq(result.edges, [(3, 5), (4, 1)])
}

///|
test "a loop containing an if with a return controls code after the loop" {
  // 0: while
  //   1: if        2: return
  //   3: body continuation
  // 4: after the loop
  let prog = program([
    node(0, @core.While, 1, children=[1, 3], parent=None),
    node(1, @core.If, 2, children=[2], parent=Some(0)),
    node(2, @core.Return, 3, parent=Some(1)),
    node(3, @core.Assign, 4, parent=Some(0)),
    node(4, @core.Assign, 5),
  ])
  let result = @cdg.build(
    prog,
    cfg([(0, 1), (1, 2), (1, 3), (2, 4), (3, 0), (0, 4)], 0, 4),
  )
  // The while controls its whole body, and also node 4 after it, because a body
  // iteration can return and skip the exit. The if controls its return, the
  // body statement it skips, and node 4. Node 0 is an ancestor of the if, so it
  // is never marked controlled by it.
  assert_eq(
    result.edges,
    [(0, 1), (0, 2), (0, 3), (0, 4), (1, 2), (1, 3), (1, 4)],
  )
}

///|
test "empty program yields an empty cdg" {
  let prog : @core.Program = { nodes: [], functions: [], errors: [] }
  let result = @cdg.build(prog, cfg([], 0, 0))
  assert_eq(result.edges, [])
}
