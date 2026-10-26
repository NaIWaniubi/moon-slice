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
    ],
    functions: [{ name: "f", entry: 0, exit: 3, }],
    calls: [],
    errors: ["bad <input>"],
  }
}

///|
fn sample_pdg() -> @core.Pdg {
  @core.Pdg::{
    edges: [
      @core.PdgEdge::{ from: 1, to: 2, kind: @core.EdgeKind::Data, },
      @core.PdgEdge::{ from: 1, to: 2, kind: @core.EdgeKind::Control, },
    ],
  }
}

///|
fn sample_result() -> @core.SliceResult {
  @core.SliceResult::{ nodes: [1, 2], lines: [2, 3], }
}

///|
test "json renders nodes, lines and errors" {
  let json = @report.to_json(sample_program(), sample_result())
  assert_true(json.contains("\"nodes\":[1,2]"))
  assert_true(json.contains("\"lines\":[2,3]"))
  assert_true(json.contains("bad <input>"))
}

///|
test "dot renders both edge kinds" {
  let dot = @report.to_dot(sample_pdg())
  assert_true(dot.contains("n1 -> n2"))
  assert_true(dot.contains("data"))
  assert_true(dot.contains("control"))
}

///|
test "call dot renders function edges" {
  let dot = @report.to_call_dot([("f", "g"), ("g", "h")])
  assert_true(dot.contains("\"f\" -> \"g\""))
  assert_true(dot.contains("\"g\" -> \"h\""))
}

///|
test "svg skips synthetic entry/exit and draws slice nodes" {
  let svg = @report.to_svg(sample_program(), sample_pdg(), sample_result(), 1)
  assert_true(svg.contains("<svg"))
  assert_true(svg.contains("n1"))
  assert_true(svg.contains("n2"))
  assert_true(svg.contains("L2"))
  assert_true(svg.contains("solid = data"))
}

///|
test "svg handles an empty program" {
  let program : @core.Program = {
    nodes: [],
    functions: [],
    calls: [],
    errors: [],
  }
  let pdg : @core.Pdg = { edges: [], }
  let result : @core.SliceResult = { nodes: [], lines: [], }
  let svg = @report.to_svg(program, pdg, result, 0)
  assert_true(svg.contains("empty program"))
}

///|
test "html includes graph, source highlighting and table" {
  let source = "line one\nline two\nline three\n"
  let html = @report.to_html(
    source,
    sample_program(),
    sample_pdg(),
    sample_result(),
    2,
    1,
  )
  assert_true(html.contains("<!doctype html>"))
  assert_true(html.contains("<svg"))
  assert_true(html.contains("class=\"hit\""))
  assert_true(html.contains("Slice nodes"))
  assert_true(html.contains("PDG (DOT)"))
}
