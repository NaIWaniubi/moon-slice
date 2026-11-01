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
  // `<` and `>` are escaped so the same string can be embedded in HTML safely.
  assert_true(json.contains("bad \\u003cinput\\u003e"))
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

///|
test "call json renders pairs" {
  let json = @report.to_call_json([("f", "g"), ("g", "h")])
  assert_eq(json, "[[\"f\",\"g\"],[\"g\",\"h\"]]")
}

///|
test "json escapes every control character" {
  let program = sample_program()
  let program = @core.Program::{
    nodes: program.nodes,
    functions: program.functions,
    calls: program.calls,
    errors: ["bad\u{1}\u{8}\u{c}\u{1f}"],
  }
  let json = @report.to_json(program, sample_result())
  assert_true(json.contains("bad\\u0001\\b\\f\\u001f"))
}

///|
test "html escapes repeated source delimiters and quotes" {
  let html = @report.to_html(
    "<one> <two> & <script>probe()</script> 'quote' \"double\"",
    sample_program(),
    sample_pdg(),
    sample_result(),
    2,
    1,
  )
  assert_true(html.contains("&lt;one&gt; &lt;two&gt; &amp; &lt;script&gt;probe()&lt;/script&gt;"))
  assert_true(html.contains("&#39;quote&#39; &quot;double&quot;"))
  assert_true(!html.contains("<script>probe()</script>"))
}

///|
test "html marks the selected target node" {
  let source = "line one\nline two\n"
  let html = @report.to_html(
    source,
    sample_program(),
    sample_pdg(),
    sample_result(),
    2,
    1,
  )
  assert_true(html.contains("class=\"target\""))
  assert_true(html.contains("target n1 on line 2"))
}

///|
test "error json carries a stable code and message" {
  let json = @report.to_error_json("read_failed", "no such file")
  assert_eq(json, "{\"error\":{\"code\":\"read_failed\",\"message\":\"no such file\"}}")
}

///|
test "error json escapes quotes and control characters" {
  let json = @report.to_error_json("bad\"code", "line\u{1}\"quoted\"")
  assert_true(json.contains("bad\\\"code"))
  assert_true(json.contains("\\u0001"))
  assert_true(!json.contains("\u{1}"))
}

///|
test "graph json lists nodes and edges deterministically" {
  let program = sample_program()
  let pdg = sample_pdg()
  let first = @report.to_graph_json(program, pdg)
  let second = @report.to_graph_json(program, pdg)
  assert_eq(first, second)
  assert_true(first.contains("\"nodes\":["))
  assert_true(first.contains("\"edges\":["))
  assert_true(first.contains("\"id\":1"))
  assert_true(first.contains("\"kind\":\"let\""))
  assert_true(first.contains("\"synthetic\":true"))
  assert_true(first.contains("\"from\":1,\"to\":2,\"kind\":\"data\""))
  assert_true(first.contains("\"kind\":\"control\""))
}

///|
test "result json carries the target, nodes, lines and errors" {
  let json = @report.to_result_json(sample_program(), sample_result(), 2, 1)
  assert_eq(
    json,
    "{\"target\":{\"line\":2,\"node\":1},\"nodes\":[1,2],\"lines\":[2,3],\"errors\":[\"bad \\u003cinput\\u003e\"]}",
  )
}

///|
test "result json cannot be broken out of by source text" {
  // Errors come from the parser and may contain anything; the block must not
  // contain a literal closing tag.
  let program = sample_program()
  let program = @core.Program::{
    nodes: program.nodes,
    functions: program.functions,
    calls: program.calls,
    errors: ["</script><script>probe()</script>"],
  }
  let json = @report.to_result_json(program, sample_result(), 2, 1)
  assert_true(!json.contains("</script>"))
  assert_true(json.contains("\u003c") || json.contains("<\/script>") || !json.contains("<"))
}

///|
test "dead json carries the suppressed count" {
  let json = @report.to_dead_json(sample_program(), sample_result(), 3)
  assert_true(json.contains("\"nodes\":[1,2]"))
  assert_true(json.contains("\"suppressed\":3"))
}

///|
test "sarif classifies dead stores and unreachable code" {
  let sarif = @report.to_sarif(
    "src\\sample.mbt",
    sample_program(),
    [1, 2],
    [1],
    1,
    "0.7.1",
  )
  assert_true(sarif.contains("\"version\":\"2.1.0\""))
  assert_true(sarif.contains("\"version\":\"0.7.1\""))
  // Windows separators become URI separators.
  assert_true(sarif.contains("\"uri\":\"src/sample.mbt\""))
  assert_true(sarif.contains("\"ruleId\":\"dead-store\""))
  assert_true(sarif.contains("\"ruleId\":\"unreachable-code\""))
  assert_true(sarif.contains("\"startLine\":2"))
  assert_true(sarif.contains("\"startLine\":3"))
  assert_true(sarif.contains("`x`"))
  assert_true(sarif.contains("\"suppressed\":1"))
  assert_true(sarif.contains("\"partialFingerprints\""))
}

///|
test "sarif is valid with no findings" {
  let sarif = @report.to_sarif("a.mbt", sample_program(), [], [], 0, "0.6.0")
  assert_true(sarif.contains("\"results\":[]"))
  assert_true(sarif.contains("\"suppressed\":0"))
}

///|
test "scan json lists findings by file with scan counts" {
  let findings : Array[@report.SarifFinding] = [
    @report.SarifFinding::{ file: "src/a.mbt", line: 3, rule: "dead-store", message: "m" },
    @report.SarifFinding::{ file: "src/b.mbt", line: 9, rule: "unreachable-code", message: "m" },
  ]
  let json = @report.to_scan_json(findings, 12, 4, ["src/c.mbt: 2 parser diagnostic(s)"])
  assert_true(json.contains("\"findings\":[{\"file\":\"src/a.mbt\",\"line\":3,\"kind\":\"dead-store\"}"))
  assert_true(json.contains("\"file\":\"src/b.mbt\",\"line\":9"))
  assert_true(json.contains("\"files\":12"))
  assert_true(json.contains("\"suppressed\":4"))
  assert_true(json.contains("src/c.mbt: 2 parser diagnostic(s)"))
}

///|
test "sarif findings merge files and expose scan counts" {
  let findings : Array[@report.SarifFinding] = [
    @report.SarifFinding::{ file: "a.mbt", line: 3, rule: "dead-store", message: "m1" },
    @report.SarifFinding::{ file: "b.mbt", line: 9, rule: "unreachable-code", message: "m2" },
  ]
  let sarif = @report.to_sarif_findings(findings, 2, "0.6.0", 7, 1)
  assert_true(sarif.contains("\"uri\":\"a.mbt\""))
  assert_true(sarif.contains("\"uri\":\"b.mbt\""))
  assert_true(sarif.contains("\"ruleId\":\"dead-store\""))
  assert_true(sarif.contains("\"ruleId\":\"unreachable-code\""))
  assert_true(sarif.contains("\"files\":7"))
  assert_true(sarif.contains("\"parseFailures\":1"))
  assert_true(sarif.contains("\"executionSuccessful\":false"))
}
