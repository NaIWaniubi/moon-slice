///|
fn sample_program() -> @core.Program {
  @core.Program::{
    nodes: [
      @core.SNode::{
        id: 0,
        kind: @core.SNodeKind::Expr,
        loc: { start_line: 1, start_col: 0, end_line: 1, end_col: 0, },
        defs: [],
        uses: [],
        children: [],
        parent: None,
      },
      @core.SNode::{
        id: 1,
        kind: @core.SNodeKind::Let,
        loc: { start_line: 2, start_col: 0, end_line: 2, end_col: 5, },
        defs: [{ name: "x", scope: 1, }],
        uses: [],
        children: [],
        parent: None,
      },
      @core.SNode::{
        id: 2,
        kind: @core.SNodeKind::Expr,
        loc: { start_line: 3, start_col: 0, end_line: 3, end_col: 5, },
        defs: [],
        uses: [{ name: "x", scope: 1, }],
        children: [],
        parent: None,
      },
      @core.SNode::{
        id: 3,
        kind: @core.SNodeKind::Expr,
        loc: { start_line: 1, start_col: 0, end_line: 1, end_col: 0, },
        defs: [],
        uses: [],
        children: [],
        parent: None,
      },
      @core.SNode::{
        id: 4,
        kind: @core.SNodeKind::Expr,
        loc: { start_line: 5, start_col: 0, end_line: 5, end_col: 0, },
        defs: [],
        uses: [],
        children: [],
        parent: None,
      },
    ],
    functions: [{ name: "f", entry: 0, exit: 3, }],
    calls: [],
    errors: [],
  }
}

///|
test "name queries separate definitions, uses and both" {
  let program = sample_program()
  assert_eq(@query.nodes_with_name(program, "x"), [1, 2])
  assert_eq(@query.nodes_defining_name(program, "x"), [1])
  assert_eq(@query.nodes_using_name(program, "x"), [2])
  assert_eq(@query.nodes_defining_name(program, "missing"), [])
}

///|
test "shortest path and reverse direction" {
  let pdg : @core.Pdg = {
    edges: [@core.PdgEdge::{ from: 1, to: 2, kind: @core.Data, }],
  }
  match @query.path_between(pdg, [1], [2]) {
    Some(path) => assert_eq(path, [1, 2])
    None => fail("expected a path")
  }
  assert_eq(@query.path_between(pdg, [2], [1]), None)
}

///|
test "unreachable nodes are those outside the CFG walk" {
  let program = sample_program()
  let cfg : @core.Cfg = { edges: [(0, 1), (1, 2), (2, 3)], entry: 0, exit: 3, }
  assert_eq(@query.unreachable_nodes(program, cfg), [4])
}

///|
test "visible lines drop synthetic entry/exit" {
  let program = sample_program()
  assert_eq(@query.visible_lines(program, [0, 1, 2, 3]), [2, 3])
  assert_eq(@query.lines_of(program, [0, 1, 2, 3]), [1, 2, 3])
}

///|
test "union is sorted and deduplicated" {
  assert_eq(@query.union_sorted([1, 3], [2, 3]), [1, 2, 3])
  assert_eq(@query.union_sorted([], []), [])
}

///|
test "queries resolve node ids when they are not array indexes" {
  let node : (@core.SNodeKind, Int32) -> @core.SNode = fn(kind, id) {
    @core.SNode::{
      id,
      kind,
      loc: { start_line: id, start_col: 0, end_line: id, end_col: 1, },
      defs: [],
      uses: [],
      children: [],
      parent: None,
    }
  }
  let program : @core.Program = {
    nodes: [node(@core.SNodeKind::Let, 10), node(@core.SNodeKind::Expr, 20)],
    functions: [],
    calls: [],
    errors: [],
  }
  // Sparse ids: id 20 sits at array index 1, not index 20.
  assert_eq(@query.lines_of(program, [10, 20]), [10, 20])
  assert_eq(@query.visible_lines(program, [20]), [20])
  assert_eq(@query.nodes_at_line(program, 20), [20])
  assert_eq(@query.target_node(program, 20), Some(20))
}
