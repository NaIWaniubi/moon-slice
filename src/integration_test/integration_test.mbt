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
  let expanded = @query.expand_calls(program, pdg, base)
  assert_true(expanded.lines.contains(2))
  assert_true(expanded.lines.contains(6))
  assert_true(expanded.lines.contains(7))
  assert_true(expanded.lines.contains(8))
  assert_true(expanded.lines.contains(12))
}

///|
test "call graph includes nested and recursive calls" {
  let source = "fn h(x : Int) -> Int { x }\nfn g(x : Int) -> Int { x }\nfn f(x : Int) -> Int {\n  let y = g(h(x))\n  y\n}\nfn rec(n : Int) -> Int {\n  if n <= 0 { return 0 }\n  return rec(n - 1)\n}\n"
  let program = @parser_adapter.parse_source(source, "calls.mbt")
  let edges = @query.call_edges(program)
  assert_true(edges.contains(("f", "g")))
  assert_true(edges.contains(("f", "h")))
  assert_true(edges.contains(("rec", "rec")))
}

///|
test "method names are not mistaken for free functions" {
  let source = "fn m(x : Int) -> Int { x }\nfn f(s : S) -> Unit {\n  s.m()\n}\n"
  let program = @parser_adapter.parse_source(source, "method.mbt")
  assert_eq(@query.call_edges(program), [])
}

///|
test "two calls on one line expand only the matching callee" {
  let source = "fn h(x : Int) -> Int {\n  return x\n}\nfn k(x : Int) -> Int {\n  let dead = 7\n  return x + 1\n}\nfn f(x : Int) -> Int {\n  let a = h(x); let b = k(x); a\n}\n"
  let program = @parser_adapter.parse_source(source, "sameline.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let node = match @query.target_node(program, 9) {
    Some(id) => id
    None => panic()
  }
  let base = @slice.backward(pdg, node, program~)
  let base = @core.SliceResult::{
    nodes: base.nodes,
    lines: @query.visible_lines(program, base.nodes),
  }
  let expanded = @query.expand_calls(program, pdg, base)
  assert_true(expanded.lines.contains(2))
  // `k` is called on the same line, but its dead store is not in `h`'s cone.
  assert_true(!expanded.lines.contains(5))
}

///|
test "calls in conditions and loop bounds are recorded" {
  let source = "fn h(x : Int) -> Bool { x > 0 }\nfn w(x : Int) -> Bool { x > 0 }\nfn f(x : Int) -> Int {\n  if h(x) {\n    1\n  }\n  while w(x) {\n    return 2\n  }\n  0\n}\n"
  let program = @parser_adapter.parse_source(source, "condcalls.mbt")
  let edges = @query.call_edges(program)
  assert_true(edges.contains(("f", "h")))
  assert_true(edges.contains(("f", "w")))
}

///|
test "interprocedural return cone excludes dead callee stores" {
  let source = "fn inc(x : Int) -> Int {\n  let dead = 99\n  return x + 1\n}\n\nfn main_fn(x : Int) -> Int {\n  let y = inc(x)\n  y\n}\n"
  let program = @parser_adapter.parse_source(source, "cone.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let node = match @query.target_node(program, 7) {
    Some(id) => id
    None => panic()
  }
  let base = @slice.backward(pdg, node, program~)
  let base = @core.SliceResult::{
    nodes: base.nodes,
    lines: @query.visible_lines(program, base.nodes),
  }
  let expanded = @query.expand_calls(program, pdg, base)
  assert_true(expanded.lines.contains(3))
  assert_true(!expanded.lines.contains(2))
}

///|
test "precise control dependence drops region-to-region pseudo edges" {
  // `if c { x = 1 } else { x = 2 }` produces a structural CDG that marks each
  // branch region as controlling the other one, which no execution can do: a
  // region has a single successor. The post-dominator builder must not.
  let source = "fn f(c : Bool, n : Int) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  let y = x + n\n  return y\n}\n"
  let program = @parser_adapter.parse_source(source, "precise.mbt")
  let cfg = @cfg.build(program)
  let structural = @cdg.build(program, cfg)
  let precise = @cdg.build_precise(program, cfg)
  assert_true(structural.edges.length() > precise.edges.length())
  // No edge may START at a region node. A region is the control kind with no
  // uses of its own, nested under a control node that shares its location; a
  // region has exactly one CFG successor, so nothing can be control dependent
  // on it. (The head shares kind and loc with its regions, so comparing those
  // alone would misclassify the legitimate head -> region edges.)
  for pair in precise.edges {
    let from = program.nodes[pair.0]
    let control_kind = from.kind == @core.SNodeKind::If ||
      from.kind == @core.SNodeKind::While ||
      from.kind == @core.SNodeKind::For ||
      from.kind == @core.SNodeKind::Match
    let mut is_region = false
    if control_kind && from.uses.length() == 0 {
      match from.parent {
        Some(owner) =>
          if program.nodes[owner].kind == from.kind &&
            program.nodes[owner].loc == from.loc {
            is_region = true
          }
        None => ()
      }
    }
    assert_true(!is_region)
  }
  // The branch head still controls both arms.
  let head = match @query.target_node(program, 3) {
    Some(id) => id
    None => panic()
  }
  let mut controls_both = true
  let arms : Array[Int32] = []
  for child in program.nodes[head].children {
    arms.push(child)
  }
  for arm in arms {
    let mut found = false
    for pair in precise.edges {
      if pair.0 == head && pair.1 == arm {
        found = true
      }
    }
    if !found {
      controls_both = false
    }
  }
  assert_true(controls_both)
}

///|
test "precise control dependence keeps a return's escape edge" {
  // A return inside a branch makes the join depend on that branch in both
  // builders; precise mode must not lose it.
  let source = "fn f(c : Bool) -> Int {\n  if c {\n    return 1\n  }\n  let x = 2\n  return x\n}\n"
  let program = @parser_adapter.parse_source(source, "escape.mbt")
  let cfg = @cfg.build(program)
  let precise = @cdg.build_precise(program, cfg)
  let head = match @query.target_node(program, 2) {
    Some(id) => id
    None => panic()
  }
  // Some node on line 5 or 6 (the code skipped by the return) must be
  // controlled by the head.
  let mut found = false
  for pair in precise.edges {
    if pair.0 == head {
      let line = program.nodes[pair.1].loc.start_line
      if line >= 5 {
        found = true
      }
    }
  }
  assert_true(found)
}
