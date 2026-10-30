// The browser engine runs the same pipeline as the CLI, but on the JavaScript
// backend. This test pins the engine's exact flow so a backend-specific
// difference in the analysis shows up here instead of in the playground.

///|
fn engine_flow(source : String, line : Int32, direction : String) -> @core.SliceResult {
  let program = @parser_adapter.parse_source(source, "playground.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let node = match @query.target_node(program, line) {
    Some(id) => id
    None => abort("no node on line")
  }
  let sliced = if direction == "forward" {
    @slice.forward(pdg, node, program~)
  } else {
    @slice.backward(pdg, node, program~)
  }
  let result = @core.SliceResult::{
    nodes: sliced.nodes,
    lines: @query.visible_lines(program, sliced.nodes),
  }
  if direction == "interprocedural" {
    @query.expand_calls(program, pdg, result)
  } else {
    result
  }
}

///|
test "the engine expands an interprocedural slice" {
  let source = "fn inc(x : Int) -> Int {\n  x + 1\n}\n\nfn twice(x : Int) -> Int {\n  let a = inc(x)\n  let b = inc(a)\n  b\n}\n\nfn main_fn(x : Int) -> Int {\n  twice(x)\n}\n"
  assert_eq(engine_flow(source, 12, "backward").lines, [12])
  assert_eq(engine_flow(source, 12, "interprocedural").lines, [2, 6, 7, 8, 12])
  assert_eq(engine_flow(source, 12, "forward").lines, [12])
}
