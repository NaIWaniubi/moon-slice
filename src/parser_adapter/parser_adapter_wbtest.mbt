// Whitebox tests covering adapter paths that are easier to reach directly than
// through the blackbox API: the C-style `for`, nested regions, `let fn`, and the
// loc helpers.

///|
test "C-style for defines its binder and reads the bound" {
  let source = "fn f() -> Int {\n  let mut t = 0\n  for i = 0; i < 3; i = i + 1 {\n    t = t + i\n  }\n  t\n}\n"
  let program = parse_source(source, "for.mbt")
  assert_eq(program.errors.length(), 0)
  let head = program.nodes[2]
  assert_eq(head.kind, @core.SNodeKind::For)
  assert_eq(head.loc.start_line, 3)
  // The loop variable is defined by the head itself.
  let defs : Array[String] = []
  head.defs.each(fn(d) { defs.push(d.name) })
  assert_eq(defs, ["i"])
  assert_eq(head.children.length(), 1)
  let body = program.nodes[head.children[0]]
  // The body is followed by a real update node before the back edge.
  assert_eq(body.children.length(), 2)
  assert_eq(program.nodes[body.children[1]].kind, @core.SNodeKind::Assign)
}

///|
test "nested if inside a loop body keeps both region chains" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    if i > 2 {\n      i = 0\n    }\n    i = i + 1\n  }\n  i\n}\n"
  let program = parse_source(source, "nest.mbt")
  assert_eq(program.errors.length(), 0)
  let while_head = program.nodes[2]
  assert_eq(while_head.kind, @core.SNodeKind::While)
  let while_region = program.nodes[while_head.children[0]]
  // The body holds the inner if head and the increment store.
  assert_eq(while_region.children.length(), 2)
  let inner_if = program.nodes[while_region.children[0]]
  assert_eq(inner_if.kind, @core.SNodeKind::If)
  assert_eq(inner_if.parent, Some(while_region.id))
  let inner_region = program.nodes[inner_if.children[0]]
  assert_eq(inner_region.children.length(), 1)
}

///|
test "local fn is a Let that binds the name" {
  let source = "fn f(a : Int) -> Int {\n  let g = fn(y : Int) { y + a }\n  g(a)\n}\n"
  let program = parse_source(source, "letfn.mbt")
  assert_eq(program.errors.length(), 0)
  let bind = program.nodes[1]
  assert_eq(bind.kind, @core.SNodeKind::Let)
  let names : Array[String] = []
  bind.defs.each(fn(d) { names.push(d.name) })
  assert_eq(names, ["g"])
}

///|
test "loc_whole keeps the parser's full span" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n"
  let program = parse_source(source, "l.mbt")
  let let_node = program.nodes[1]
  // The synthetic entry/exit nodes span `fn` through the closing brace, so every
  // statement's Loc sits inside that span.
  let entry_loc = program.nodes[0].loc
  assert_eq(entry_loc.start_line, 1)
  assert_true(let_node.loc.start_line >= entry_loc.start_line)
  assert_true(let_node.loc.end_line <= entry_loc.end_line)
  // `let s = a` occupies one line, so start and end lines agree.
  assert_eq(let_node.loc.start_line, let_node.loc.end_line)
  assert_true(let_node.loc.end_col > let_node.loc.start_col)
}

///|
test "a let whose RHS is a brace block is a single node on its own line" {
  let source = "fn f(a : Int) -> Int {\n  let x = {\n    let y = a\n    y\n  }\n  x\n}\n"
  let program = parse_source(source, "blk.mbt")
  assert_eq(program.errors.length(), 0)
  let let_node = program.nodes[1]
  assert_eq(let_node.kind, @core.SNodeKind::Let)
  assert_eq(let_node.loc.start_line, 2)
  // The brace block is outside the modeled subset, so its identifiers are
  // swept into the enclosing statement's uses instead of getting their own nodes.
  assert_true(let_node.uses.length() > 0)
}

///|
test "pattern tuple binding defines every component" {
  let source = "fn f(p : (Int, Int)) -> Int {\n  let (a, b) = p\n  a + b\n}\n"
  let program = parse_source(source, "tup.mbt")
  assert_eq(program.errors.length(), 0)
  let bind = program.nodes[1]
  let names : Array[String] = []
  bind.defs.each(fn(d) { names.push(d.name) })
  assert_eq(names, ["a", "b"])
}
