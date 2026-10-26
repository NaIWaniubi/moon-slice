///|
fn loc(line : Int32) -> @core.Loc {
  { start_line: line, start_col: 1, end_line: line, end_col: 8, }
}

///|
fn program(nodes : Array[@core.SNode]) -> @core.Program {
  { nodes, functions: [], errors: [], }
}

///|
fn node(id : Int32, kind : @core.SNodeKind, line : Int32) -> @core.SNode {
  { id, kind, loc: loc(line), defs: [], uses: [], children: [], parent: None, }
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
/// `PdgEdge` has no `Eq` in the frozen core, so tests compare the observable
/// key `(from, to, kind)` instead.
fn key(edge : @core.PdgEdge) -> (Int32, Int32, @core.EdgeKind) {
  (edge.from, edge.to, edge.kind)
}

///|
fn keys(edges : Array[@core.PdgEdge]) -> Array[(Int32, Int32, @core.EdgeKind)] {
  let out : Array[(Int32, Int32, @core.EdgeKind)] = []
  for edge in edges {
    out.push(key(edge))
  }
  out
}

///|
test "empty inputs yield an empty graph" {
  let pdg = @pdg.build({ reaching: [], }, { edges: [], })
  assert_eq(keys(pdg.edges), [])
}

///|
test "reaching definitions become data edges" {
  // 0 defines x, 1 uses x, 2 uses x
  let pdg = @pdg.build({ reaching: [(0, 1), (0, 2)], }, { edges: [], })
  assert_eq(keys(pdg.edges), [key(data(0, 1)), key(data(0, 2))])
}

///|
test "cdg pairs become control edges" {
  let pdg = @pdg.build({ reaching: [], }, { edges: [(3, 4), (3, 5)], })
  assert_eq(keys(pdg.edges), [key(control(3, 4)), key(control(3, 5))])
}

///|
test "data and control edges coexist and sort with data first" {
  // Same endpoints from both sources stay distinct edges.
  let pdg = @pdg.build({ reaching: [(1, 2)], }, { edges: [(1, 2)], })
  assert_eq(keys(pdg.edges), [key(data(1, 2)), key(control(1, 2))])
}

///|
test "edges are sorted by from then to then kind" {
  let pdg = @pdg.build({ reaching: [(5, 6), (1, 9)], }, {
    edges: [(1, 2), (5, 7)],
  })
  assert_eq(keys(pdg.edges), [
    key(control(1, 2)),
    key(data(1, 9)),
    key(data(5, 6)),
    key(control(5, 7)),
  ])
}

///|
test "self edges are dropped from both sources" {
  let pdg = @pdg.build({ reaching: [(2, 2), (2, 3)], }, { edges: [(4, 4)], })
  assert_eq(keys(pdg.edges), [key(data(2, 3))])
}

///|
test "duplicate pairs collapse to one edge" {
  let pdg = @pdg.build({ reaching: [(0, 1), (0, 1)], }, {
    edges: [(0, 1), (0, 1)],
  })
  assert_eq(keys(pdg.edges), [key(data(0, 1)), key(control(0, 1))])
}

///|
test "ids pass through unchanged even when unknown to any program" {
  // `build` only has DefUse and Cdg, so it cannot validate ids; this documents
  // the pass-through contract.
  let pdg = @pdg.build({ reaching: [(100, 200)], }, { edges: [(300, 400)], })
  assert_eq(keys(pdg.edges), [key(data(100, 200)), key(control(300, 400))])
}

///|
test "negative and zero ids are preserved" {
  let pdg = @pdg.build({ reaching: [(-1, 0)], }, { edges: [(0, -1)], })
  assert_eq(keys(pdg.edges), [key(data(-1, 0)), key(control(0, -1))])
}

///|
test "a structured program keeps its control edges intact" {
  let prog = program([
    node(0, @core.If, 1),
    node(1, @core.Assign, 2),
    node(2, @core.Assign, 3),
  ])
  // Hand-built: an `if` at 0 controlling the statements at 1 and 2.
  let cdg : @core.Cdg = { edges: [(0, 1), (0, 2)], }
  let pdg = @pdg.build({ reaching: [(1, 2)], }, cdg)
  assert_eq(keys(pdg.edges), [
    key(control(0, 1)),
    key(control(0, 2)),
    key(data(1, 2)),
  ])
  assert_eq(prog.nodes.length(), 3)
}
