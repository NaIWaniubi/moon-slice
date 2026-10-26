///|
fn loc(line : Int32) -> @core.Loc {
  { start_line: line, start_col: 1, end_line: line, end_col: 8, }
}

///|
fn node(id : Int32, kind : @core.SNodeKind, line : Int32) -> @core.SNode {
  { id, kind, loc: loc(line), defs: [], uses: [], children: [], parent: None, }
}

///|
fn program(nodes : Array[@core.SNode]) -> @core.Program {
  { nodes, functions: [], errors: [], }
}

///|
fn data(from : Int32, to : Int32) -> @core.PdgEdge {
  { from, to, kind: @core.Data, }
}

///|
fn control(from : Int32, to : Int32) -> @core.PdgEdge {
  { from, to, kind: @core.Control, }
}

///|
fn dag() -> @core.Pdg {
  // 1 -> 2 -> 3 chain, plus 4 -> 3 and 2 -> 5 branch.
  //   1
  //   v
  //   2 --> 5
  //   v
  //   3
  //   ^
  //   4
  { edges: [data(1, 2), data(2, 3), data(4, 3), data(2, 5)], }
}

///|
test "backward slice follows incoming edges transitively" {
  let result = @slice.backward(dag(), 3)
  // 3 is reached by 2 and 4; 2 is reached by 1; 4 has no predecessor.
  assert_eq(result.nodes, [1, 2, 3, 4])
}

///|
test "forward slice follows outgoing edges transitively" {
  let result = @slice.forward(dag(), 2)
  // 2 reaches 3 and 5; 3 is reachable from 2 directly.
  assert_eq(result.nodes, [2, 3, 5])
}

///|
test "the criterion is always part of its own slice" {
  let pdg : @core.Pdg = { edges: [], }
  assert_eq(@slice.backward(pdg, 7).nodes, [7])
  assert_eq(@slice.forward(pdg, 7).nodes, [7])
}

///|
test "a node with no incoming edge slices to itself" {
  let result = @slice.backward(dag(), 1)
  assert_eq(result.nodes, [1])
}

///|
test "a node with no outgoing edge slices to itself" {
  let result = @slice.forward(dag(), 5)
  assert_eq(result.nodes, [5])
}

///|
test "cycle terminates and includes every member" {
  // 1 -> 2 -> 3 -> 1
  let pdg : @core.Pdg = { edges: [data(1, 2), data(2, 3), control(3, 1)], }
  assert_eq(@slice.backward(pdg, 2).nodes, [1, 2, 3])
  assert_eq(@slice.forward(pdg, 2).nodes, [1, 2, 3])
}

///|
test "self edges do not change the result" {
  let pdg : @core.Pdg = { edges: [data(1, 1), data(1, 2)], }
  assert_eq(@slice.backward(pdg, 2).nodes, [1, 2])
  assert_eq(@slice.forward(pdg, 1).nodes, [1, 2])
}

///|
test "control and data edges are both followed" {
  // 1 --data--> 2 --control--> 3
  let pdg : @core.Pdg = { edges: [data(1, 2), control(2, 3)], }
  assert_eq(@slice.backward(pdg, 3).nodes, [1, 2, 3])
  assert_eq(@slice.forward(pdg, 1).nodes, [1, 2, 3])
}

///|
test "backward and forward disagree on a diamond" {
  //   1
  //  / \
  // 2   3
  //  \ /
  //   4
  let pdg : @core.Pdg = {
    edges: [data(1, 2), data(1, 3), data(2, 4), data(3, 4)],
  }
  assert_eq(@slice.backward(pdg, 4).nodes, [1, 2, 3, 4])
  assert_eq(@slice.forward(pdg, 1).nodes, [1, 2, 3, 4])
  // From a middle node the two directions are strictly different.
  assert_eq(@slice.backward(pdg, 2).nodes, [1, 2])
  assert_eq(@slice.forward(pdg, 2).nodes, [2, 4])
}

///|
test "lines are unique, sorted, and drawn from the reached nodes only" {
  let prog = program([
    node(1, @core.Let, 10),
    node(2, @core.Assign, 20),
    node(3, @core.Assign, 20), // shares a line with 2
    node(4, @core.Assign, 5),
  ])
  let pdg : @core.Pdg = { edges: [data(1, 2), data(2, 3), data(3, 4)], }
  let result = @slice.backward(pdg, 4, program=prog)
  assert_eq(result.nodes, [1, 2, 3, 4])
  assert_eq(result.lines, [5, 10, 20])
}

///|
test "without a program the lines array is empty" {
  let result = @slice.backward(dag(), 3)
  assert_eq(result.nodes, [1, 2, 3, 4])
  assert_eq(result.lines, [])
}

///|
test "ids missing from the program contribute no line" {
  let prog = program([node(1, @core.Let, 10)])
  let pdg : @core.Pdg = { edges: [data(1, 2)], }
  let result = @slice.backward(pdg, 2, program=prog)
  assert_eq(result.nodes, [1, 2])
  assert_eq(result.lines, [10])
}

///|
test "repeated ids in the program use the first occurrence" {
  let prog = program([node(1, @core.Let, 10), node(1, @core.Assign, 99)])
  let pdg : @core.Pdg = { edges: [], }
  assert_eq(@slice.backward(pdg, 1, program=prog).lines, [10])
}

///|
test "lines_of ignores duplicates in the node list" {
  let prog = program([node(1, @core.Let, 10), node(2, @core.Let, 20)])
  assert_eq(@slice.lines_of(prog, [2, 1, 2, 1]), [10, 20])
  assert_eq(@slice.lines_of(prog, []), [])
}
