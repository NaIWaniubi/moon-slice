// Whitebox tests for the remaining adapter arms.

///|
test "discarded positional parameter binds nothing" {
  let source = "fn f(_ : Int, b : Int) -> Int {\n  b\n}\n"
  let program = parse_source(source, "disc.mbt")
  assert_eq(program.errors.length(), 0)
  let entry = program.nodes[0]
  let names : Array[String] = []
  entry.defs.each(fn(d) { names.push(d.name) })
  assert_eq(names, ["b"])
}

///|
test "let-bound lambda binds its name as a Let" {
  let source = "fn f(a : Int) -> Int {\n  let g = fn(y : Int) { y + a }\n  g\n}\n"
  let program = parse_source(source, "lfn.mbt")
  assert_eq(program.errors.length(), 0)
  let bind = program.nodes[1]
  let kind = match bind.kind {
    Let => "Let"
    _ => "other"
  }
  assert_eq(kind, "Let")
  let names : Array[String] = []
  bind.defs.each(fn(d) { names.push(d.name) })
  assert_eq(names, ["g"])
  // The lambda body mentions `a`, which is conservatively recorded as a use of
  // the binding statement.
  assert_true(bind.uses.length() >= 1)
}

///|
test "a statement list keeps declaration order" {
  let source = "fn f(a : Int) -> Int {\n  let x = a\n  let y = x\n  let z = y\n  z\n}\n"
  let program = parse_source(source, "order.mbt")
  assert_eq(program.errors.length(), 0)
  // Scopes increase monotonically in source order.
  let scopes : Array[Int32] = []
  program.nodes.each(fn(node) { node.defs.each(fn(d) { scopes.push(d.scope) }) })
  let mut i = 0
  while i + 1 < scopes.length() {
    assert_true(scopes[i] < scopes[i + 1])
    i = i + 1
  }
}

///|
test "the exit node comes after every body node" {
  let source = "fn f(a : Int) -> Int {\n  a\n}\n"
  let program = parse_source(source, "exit.mbt")
  let function = program.functions[0]
  assert_eq(function.exit, program.nodes.length() - 1)
  assert_eq(function.entry, 0)
}
