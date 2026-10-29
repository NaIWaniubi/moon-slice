// Inter-procedural argument mapping.
//
// `expand_calls` pairs a call site's arguments with the callee's parameters in
// declaration order and drops callee statements whose only parameter
// dependencies are parameters the caller did not supply. These tests pin that
// behaviour down with hand-written programs.

///|
fn pipeline(source : String) -> (@core.Program, @core.Pdg) {
  let program = @parser_adapter.parse_source(source, "interproc.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  (program, pdg)
}

///|
fn slice_at(
  program : @core.Program,
  pdg : @core.Pdg,
  line : Int32,
  interprocedural : Bool,
) -> Array[Int32] {
  let node = match @query.target_node(program, line) {
    Some(id) => id
    None => panic()
  }
  let base = @slice.backward(pdg, node, program~)
  let base = @core.SliceResult::{
    nodes: base.nodes,
    lines: @query.visible_lines(program, base.nodes),
  }
  let result = if interprocedural {
    @query.expand_calls(program, pdg, base)
  } else {
    base
  }
  result.lines
}

///|
test "interproc: literal arguments never drop the callee" {
  // `add(1, 2)` has no identifier uses, so a mapping based on variable uses
  // would conclude that zero parameters were supplied and drop the whole
  // callee. That is an under-approximation; the call must keep the return cone.
  let source = "fn add(a : Int, b : Int) -> Int {\n  let s = a + b\n  return s\n}\nfn main_fn() -> Int {\n  let r = add(1, 2)\n  r\n}\n"
  let (program, pdg) = pipeline(source)
  let lines = slice_at(program, pdg, 7, true)
  assert_true(lines.contains(2))
  assert_true(lines.contains(3))
  assert_true(lines.contains(7))
}

///|
test "interproc: a partial call keeps the whole return cone" {
  // `two(a, b)` called as `two(x)` is not valid MoonBit, and more importantly
  // an omitted parameter may carry a default that still affects the return.
  // The whole cone is the sound answer.
  let source = "fn two(a : Int, b : Int) -> Int {\n  let fromA = a * 2\n  let fromB = b * 3\n  return fromA + fromB\n}\nfn caller(x : Int) -> Int {\n  let y = two(x)\n  return y\n}\n"
  let (program, pdg) = pipeline(source)
  let lines = slice_at(program, pdg, 7, true)
  assert_true(lines.contains(2))
  assert_true(lines.contains(3))
  assert_true(lines.contains(4))
}

///|
test "interproc: a fully supplied call keeps both parameter branches" {
  let source = "fn two(a : Int, b : Int) -> Int {\n  let fromA = a * 2\n  let fromB = b * 3\n  return fromA + fromB\n}\nfn caller(x : Int, z : Int) -> Int {\n  let y = two(x, z)\n  return y\n}\n"
  let (program, pdg) = pipeline(source)
  let lines = slice_at(program, pdg, 7, true)
  assert_true(lines.contains(2))
  assert_true(lines.contains(3))
  assert_true(lines.contains(4))
}

///|
test "interproc: a parameter-independent callee statement stays" {
  // `base` depends on no parameter, so it contributes to the return value and
  // must survive even though only one argument is supplied.
  let source = "fn mixed(a : Int, b : Int) -> Int {\n  let base = 10\n  let fromB = b + base\n  return a + fromB\n}\nfn caller(x : Int) -> Int {\n  let y = mixed(x)\n  return y\n}\n"
  let (program, pdg) = pipeline(source)
  let lines = slice_at(program, pdg, 7, true)
  assert_true(lines.contains(2))
  assert_true(lines.contains(4))
}

///|
test "interproc: expansion is a superset of the intraprocedural slice" {
  let source = "fn inc(x : Int) -> Int {\n  let dead = 99\n  return x + 1\n}\nfn main_fn(x : Int) -> Int {\n  let y = inc(x)\n  y\n}\n"
  let (program, pdg) = pipeline(source)
  let plain = slice_at(program, pdg, 7, false)
  let expanded = slice_at(program, pdg, 7, true)
  for line in plain {
    assert_true(expanded.contains(line))
  }
  // The callee's dead store still stays out.
  assert_true(!expanded.contains(2))
}

///|
test "interproc: a chain of calls expands transitively" {
  let source = "fn inc(x : Int) -> Int {\n  return x + 1\n}\nfn twice(x : Int) -> Int {\n  let a = inc(x)\n  return inc(a)\n}\nfn top(x : Int) -> Int {\n  let y = twice(x)\n  return y\n}\n"
  let (program, pdg) = pipeline(source)
  let lines = slice_at(program, pdg, 10, true)
  assert_true(lines.contains(2))
  assert_true(lines.contains(5))
  assert_true(lines.contains(6))
}

///|
test "interproc: recursion terminates" {
  let source = "fn rec(n : Int) -> Int {\n  if n <= 0 {\n    return 0\n  }\n  return rec(n - 1)\n}\nfn top(n : Int) -> Int {\n  return rec(n)\n}\n"
  let (program, pdg) = pipeline(source)
  let lines = slice_at(program, pdg, 8, true)
  assert_true(lines.length() > 0)
  assert_true(lines.contains(8))
}

///|
test "interproc: a bare call statement still adds the whole body" {
  // Side effects are not summarized, so a bare call keeps every callee line.
  let source = "fn work(a : Int, b : Int) -> Unit {\n  let x = a + 1\n  let y = b + 1\n}\nfn caller(a : Int, b : Int) -> Unit {\n  work(a, b)\n}\n"
  let (program, pdg) = pipeline(source)
  let lines = slice_at(program, pdg, 6, true)
  assert_true(lines.contains(2))
  assert_true(lines.contains(3))
}

///|
test "interproc: more arguments than parameters is harmless" {
  let source = "fn one(a : Int) -> Int {\n  return a + 1\n}\nfn caller(x : Int, z : Int) -> Int {\n  let y = one(x, z)\n  return y\n}\n"
  let (program, pdg) = pipeline(source)
  let lines = slice_at(program, pdg, 5, true)
  assert_true(lines.contains(2))
}
