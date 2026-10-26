// End-to-end corpus tests: parse each example, run the full pipeline, and
// compare the visible slice lines with the expected sets in
// testdata/expected.json. Keeping these in MoonBit means `moon test` alone is
// enough to catch a regression in any layer.

///|
fn slice_lines(file : String, target : Int32, forward : Bool) -> Array[Int32] {
  let source = @fs.read_file_to_string(file) catch { _ => panic() }
  let program = @parser_adapter.parse_source(source, file)
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let node = match @query.target_node(program, target) {
    Some(id) => id
    None => panic()
  }
  let result = if forward {
    @slice.forward(pdg, node, program~)
  } else {
    @slice.backward(pdg, node, program~)
  }
  @query.visible_lines(program, result.nodes)
}

///|
fn check(
  file : String,
  target : Int32,
  backward : Array[Int32],
  forward : Array[Int32],
) -> Unit raise {
  assert_eq(slice_lines(file, target, false), backward)
  assert_eq(slice_lines(file, target, true), forward)
}

///|
test "01 let" {
  check("examples/01_let.mbt", 5, [4, 5], [5, 6, 8])
}

///|
test "02 mut" {
  check("examples/02_mut.mbt", 6, [5, 6], [6, 7, 8])
}

///|
test "03 if/else" {
  check("examples/03_if_else.mbt", 6, [5, 6], [6, 10])
}

///|
test "04 while" {
  check("examples/04_while.mbt", 7, [4, 5, 6, 7, 8], [7, 10])
}

///|
test "05 for" {
  check("examples/05_for.mbt", 7, [4, 5, 6, 7], [7, 9])
}

///|
test "06 match" {
  check("examples/06_match.mbt", 7, [5, 7], [7, 10])
}

///|
test "07 return" {
  check("examples/07_return.mbt", 6, [4, 5, 6], [6, 7, 8, 10])
}

///|
test "08 dead assignment" {
  check("examples/08_dead_assignment.mbt", 7, [6, 7], [7, 8, 9])
}

///|
test "09 shadowing" {
  check("examples/09_shadowing.mbt", 6, [5, 6], [6, 7])
}

///|
test "10 field write" {
  check("examples/10_field_write.mbt", 11, [9, 10, 11], [11, 12])
}

///|
test "data-flow path from a definition to a use" {
  let source = @fs.read_file_to_string("examples/01_let.mbt") catch {
    _ => panic()
  }
  let program = @parser_adapter.parse_source(source, "examples/01_let.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let starts = @query.nodes_defining_name(program, "a")
  let goals = @query.nodes_using_name(program, "b")
  match @query.path_between(pdg, starts, goals) {
    Some(path) => assert_eq(path, [1, 2, 3])
    None => fail("expected a path from a to b")
  }
}

///|
test "no path in the reverse direction" {
  let source = @fs.read_file_to_string("examples/01_let.mbt") catch {
    _ => panic()
  }
  let program = @parser_adapter.parse_source(source, "examples/01_let.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let starts = @query.nodes_defining_name(program, "c")
  let goals = @query.nodes_using_name(program, "a")
  assert_eq(@query.path_between(pdg, starts, goals), None)
}

///|
test "unreachable code is flagged" {
  let source = "fn f() -> Int {\n  return 1\n  let x = 2\n  x\n}\n"
  let program = @parser_adapter.parse_source(source, "unreachable.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let dead = @query.dead_nodes(program, defuse)
  let unreach = @query.unreachable_nodes(program, cfg)
  let all = @query.union_sorted(dead, unreach)
  assert_eq(@query.visible_lines(program, all), [3, 4])
}

///|
test "call graph finds free-function calls" {
  let source = @fs.read_file_to_string("bench/callgraph.mbt") catch {
    _ => panic()
  }
  let program = @parser_adapter.parse_source(source, "bench/callgraph.mbt")
  assert_eq(@query.call_edges(program), [("twice", "inc"), ("main_fn", "twice")])
}

///|
test "conservative interprocedural expansion includes callee bodies" {
  let source = @fs.read_file_to_string("bench/callgraph.mbt") catch {
    _ => panic()
  }
  let program = @parser_adapter.parse_source(source, "bench/callgraph.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let node = match @query.target_node(program, 12) {
    Some(id) => id
    None => panic()
  }
  let base = @slice.backward(pdg, node, program~)
  let expanded = @query.expand_calls(program, base)
  assert_true(expanded.lines.contains(2))
  assert_true(expanded.lines.contains(6))
  assert_true(expanded.lines.contains(7))
  assert_true(expanded.lines.contains(8))
  assert_true(expanded.lines.contains(12))
}
