// Blackbox tests for the parser adapter.
//
// Every test builds a tiny program, parses it and asserts an exact node/line
// shape. Expected node ids are hand-computed from the documented emission order
// (depth-first, statements of a block as siblings, head before its region
// nodes, synthetic entry node first and synthetic exit node last per function).

///|
let add_source : String = "fn add(a : Int, b : Int) -> Int {\n  let s = a + b\n  s\n}\n"

///|
fn loc(line : Int32) -> @core.Loc {
  { start_line: line, start_col: 0, end_line: line, end_col: 0 }
}

///|
/// Node ids whose `start_line` equals `line`, ascending.
fn ids_on_line(program : @core.Program, line : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  program.nodes.each(fn(node) {
    if node.loc.start_line == line {
      out.push(node.id)
    }
  })
  out
}

///|
/// `(name, scope)` pairs, for readable assertions on VarId sets.
fn var_names(vars : Array[@core.VarId]) -> Array[(String, Int32)] {
  let out : Array[(String, Int32)] = []
  vars.each(fn(v) { out.push((v.name, v.scope)) })
  out
}

///|
test "empty source yields no functions and no nodes" {
  let program = @parser_adapter.parse_source("", "empty.mbt")
  assert_eq(program.nodes.length(), 0)
  assert_eq(program.functions.length(), 0)
  assert_eq(program.errors.length(), 0)
}

///|
test "parse error is reported, not raised" {
  let program = @parser_adapter.parse_source("fn broken( {\n", "bad.mbt")
  assert_true(program.errors.length() > 0)
  let first = program.errors[0]
  assert_true(first.contains("bad.mbt:"))
}

///|
test "single function yields entry, statements, exit" {
  let program = @parser_adapter.parse_source(add_source, "add.mbt")
  assert_eq(program.errors.length(), 0)
  assert_eq(program.functions.length(), 1)
  let function = program.functions[0]
  assert_eq(function.name, "add")
  // entry node, `let`, the trailing identifier expression, exit node
  assert_eq(program.nodes.length(), 4)
  assert_eq(function.entry, 0)
  assert_eq(function.exit, 3)
}

///|
test "node kinds follow source order" {
  let program = @parser_adapter.parse_source(add_source, "add.mbt")
  assert_eq(program.nodes[0].kind, @core.SNodeKind::Expr) // synthetic entry
  assert_eq(program.nodes[1].kind, @core.SNodeKind::Let)
  assert_eq(program.nodes[2].kind, @core.SNodeKind::Expr)
  assert_eq(program.nodes[3].kind, @core.SNodeKind::Expr) // synthetic exit
}

///|
test "let statement location covers exactly its own line" {
  let program = @parser_adapter.parse_source(add_source, "add.mbt")
  let let_node = program.nodes[1]
  assert_eq(let_node.loc.start_line, 2)
  assert_eq(let_node.loc.end_line, 2)
  assert_eq(let_node.loc.start_col, 3)
  assert_eq(let_node.loc.end_col, 16)
}

///|
test "parameters are defined by the entry node" {
  let program = @parser_adapter.parse_source(add_source, "add.mbt")
  let entry = program.nodes[0]
  assert_eq(entry.defs.length(), 2)
  assert_eq(entry.defs[0].name, "a")
  assert_eq(entry.defs[1].name, "b")
  // Parameters are entered before the body, so they take the first scopes.
  assert_eq(entry.defs[0].scope, 1)
  assert_eq(entry.defs[1].scope, 2)
}

///|
test "let defines its binder and uses the parameters" {
  let program = @parser_adapter.parse_source(add_source, "add.mbt")
  let let_node = program.nodes[1]
  assert_eq(var_names(let_node.defs), [("s", 3)])
  assert_eq(var_names(let_node.uses), [("a", 1), ("b", 2)])
}

///|
test "trailing expression uses the let binder" {
  let program = @parser_adapter.parse_source(add_source, "add.mbt")
  let expr_node = program.nodes[2]
  assert_eq(expr_node.kind, @core.SNodeKind::Expr)
  assert_eq(expr_node.defs.length(), 0)
  assert_eq(var_names(expr_node.uses), [("s", 3)])
  assert_eq(expr_node.loc.start_line, 3)
}

///|
test "let mut is distinguished from let" {
  let source = "fn f(a : Int) -> Int {\n  let mut x = a\n  x\n}\n"
  let program = @parser_adapter.parse_source(source, "m.mbt")
  assert_eq(program.nodes[1].kind, @core.SNodeKind::LetMut)
  assert_eq(var_names(program.nodes[1].defs), [("x", 2)])
  assert_eq(var_names(program.nodes[1].uses), [("a", 1)])
}

///|
test "assignment defines and uses the same variable" {
  let source = "fn f(a : Int) -> Int {\n  let mut x = 0\n  x = a\n  x\n}\n"
  let program = @parser_adapter.parse_source(source, "a.mbt")
  let store = program.nodes[2]
  assert_eq(store.kind, @core.SNodeKind::Assign)
  assert_eq(var_names(store.defs), [("x", 2)])
  assert_eq(var_names(store.uses), [("a", 1)])
  assert_eq(store.loc.start_line, 3)
}

///|
test "augmented assignment also reads its target" {
  let source = "fn f() -> Int {\n  let mut x = 1\n  x = x + 1\n  x\n}\n"
  let program = @parser_adapter.parse_source(source, "aug.mbt")
  let store = program.nodes[2]
  assert_eq(store.kind, @core.SNodeKind::Assign)
  assert_eq(var_names(store.defs), [("x", 1)])
  assert_eq(var_names(store.uses), [("x", 1)])
}

///|
test "if head carries the condition and owns one region per branch" {
  let source = "fn f(c : Bool) -> Int {\n  if c {\n    1\n  } else {\n    2\n  }\n}\n"
  let program = @parser_adapter.parse_source(source, "if.mbt")
  let head = program.nodes[1]
  assert_eq(head.kind, @core.SNodeKind::If)
  assert_eq(var_names(head.uses), [("c", 1)])
  assert_eq(head.children.length(), 2)
  let then_region = program.nodes[head.children[0]]
  let else_region = program.nodes[head.children[1]]
  assert_eq(then_region.parent, Some(head.id))
  assert_eq(else_region.parent, Some(head.id))
  assert_eq(then_region.children.length(), 1)
  assert_eq(else_region.children.length(), 1)
  // Regions stay on the construct's own line, so they add no source line.
  assert_eq(then_region.loc.start_line, 2)
  assert_eq(else_region.loc.start_line, 2)
}

///|
test "if without else has a single region" {
  let source = "fn f(c : Bool) -> Int {\n  if c {\n    1\n  }\n  0\n}\n"
  let program = @parser_adapter.parse_source(source, "if1.mbt")
  let head = program.nodes[1]
  assert_eq(head.kind, @core.SNodeKind::If)
  assert_eq(head.children.length(), 1)
}

///|
test "while head collects the condition and the body region" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n"
  let program = @parser_adapter.parse_source(source, "w.mbt")
  let head = program.nodes[2]
  assert_eq(head.kind, @core.SNodeKind::While)
  assert_eq(var_names(head.uses), [("i", 2), ("n", 1)])
  assert_eq(head.children.length(), 1)
  let body = program.nodes[head.children[0]]
  assert_eq(body.children.length(), 1)
  assert_eq(program.nodes[body.children[0]].kind, @core.SNodeKind::Assign)
}

///|
test "for each defines the pattern binder" {
  let source = "fn f(xs : Array[Int]) -> Int {\n  for x in xs {\n    x\n  }\n  0\n}\n"
  let program = @parser_adapter.parse_source(source, "fe.mbt")
  let head = program.nodes[1]
  assert_eq(head.kind, @core.SNodeKind::For)
  assert_eq(var_names(head.uses), [("xs", 1)])
  assert_eq(var_names(head.defs), [("x", 2)])
  assert_eq(head.children.length(), 1)
}

///|
test "match head owns one region per case and regions define pattern binders" {
  let source = "fn f(a : Int) -> Int {\n  match a {\n    0 => 1\n    _ => 2\n  }\n}\n"
  let program = @parser_adapter.parse_source(source, "mt.mbt")
  let head = program.nodes[1]
  assert_eq(head.kind, @core.SNodeKind::Match)
  assert_eq(var_names(head.uses), [("a", 1)])
  assert_eq(head.children.length(), 2)
  // A wildcard case binds nothing.
  program.nodes[head.children[0]].children.each(fn(id) { ignore(id) })
  let case0 = program.nodes[head.children[0]]
  let case1 = program.nodes[head.children[1]]
  assert_eq(case0.defs.length(), 0)
  assert_eq(case1.defs.length(), 0)
}

///|
test "match case patterns bind and their bodies use the binding" {
  let source = "fn f(a : Int) -> Int {\n  match a {\n    n => n + 1\n  }\n}\n"
  let program = @parser_adapter.parse_source(source, "mtb.mbt")
  let head = program.nodes[1]
  let region = program.nodes[head.children[0]]
  assert_eq(var_names(region.defs), [("n", 2)])
  let body = program.nodes[region.children[0]]
  assert_eq(var_names(body.uses), [("n", 2)])
}

///|
test "return is modeled as a Return node" {
  let source = "fn f(a : Int) -> Int {\n  return a\n}\n"
  let program = @parser_adapter.parse_source(source, "r.mbt")
  let ret = program.nodes[1]
  assert_eq(ret.kind, @core.SNodeKind::Return)
  assert_eq(var_names(ret.uses), [("a", 1)])
}

///|
test "break and continue are modeled" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n    if i > 2 {\n      break\n    } else {\n      continue\n    }\n  }\n  i\n}\n"
  let program = @parser_adapter.parse_source(source, "bc.mbt")
  let kinds : Array[@core.SNodeKind] = []
  program.nodes.each(fn(node) { kinds.push(node.kind) })
  assert_true(kinds.contains(@core.SNodeKind::Break))
  assert_true(kinds.contains(@core.SNodeKind::Continue))
}

///|
test "call node uses the callee and every argument" {
  let source = "fn f(a : Int) -> Int {\n  g(a, 1)\n}\n"
  let program = @parser_adapter.parse_source(source, "c.mbt")
  let call = program.nodes[1]
  assert_eq(call.kind, @core.SNodeKind::Call)
  assert_eq(var_names(call.uses), [("g", -1), ("a", 1)])
}

///|
test "field read uses the base variable" {
  let source = "fn f(r : R) -> Int {\n  r.x\n}\n"
  let program = @parser_adapter.parse_source(source, "fr.mbt")
  let read = program.nodes[1]
  assert_eq(read.kind, @core.SNodeKind::Expr)
  assert_eq(var_names(read.uses), [("r", 1)])
}

///|
test "array read uses the array and the index" {
  let source = "fn f(a : Array[Int], i : Int) -> Int {\n  a[i]\n}\n"
  let program = @parser_adapter.parse_source(source, "ar.mbt")
  let read = program.nodes[1]
  assert_eq(read.kind, @core.SNodeKind::Expr)
  assert_eq(var_names(read.uses), [("a", 1), ("i", 2)])
}

///|
test "field write is an Assign that defines its base" {
  let source = "fn f(r : R, v : Int) -> Unit {\n  r.x = v\n}\n"
  let program = @parser_adapter.parse_source(source, "fw.mbt")
  let store = program.nodes[1]
  assert_eq(store.kind, @core.SNodeKind::Assign)
  // Conservative: the base is both read and (may-)defined.
  assert_eq(var_names(store.defs), [("r", 1)])
  assert_eq(var_names(store.uses), [("r", 1), ("v", 2)])
}

///|
test "array write is an Assign that defines its base" {
  let source = "fn f(a : Array[Int], i : Int, v : Int) -> Unit {\n  a[i] = v\n}\n"
  let program = @parser_adapter.parse_source(source, "aw.mbt")
  let store = program.nodes[1]
  assert_eq(store.kind, @core.SNodeKind::Assign)
  assert_eq(var_names(store.defs), [("a", 1)])
  assert_eq(var_names(store.uses), [("a", 1), ("i", 2), ("v", 3)])
}

///|
test "unsupported construct becomes one Expr node with all identifiers as uses" {
  // `try` is outside the modeled subset.
  let source = "fn f(a : Int) -> Int {\n  try { a } catch {\n    _ => 0\n  }\n}\n"
  let program = @parser_adapter.parse_source(source, "u.mbt")
  let node = program.nodes[1]
  assert_eq(node.kind, @core.SNodeKind::Expr)
  let names = var_names(node.uses)
  assert_true(names.contains(("a", 1)))
}

///|
test "shadowing gives the inner binding a distinct VarId" {
  let source = "fn f(x : Int) -> Int {\n  let y = x\n  let x = y\n  x\n}\n"
  let program = @parser_adapter.parse_source(source, "sh.mbt")
  let outer_use = program.nodes[1]
  let inner_let = program.nodes[2]
  let inner_use = program.nodes[3]
  // The first `let y = x` reads the parameter.
  assert_eq(var_names(outer_use.uses), [("x", 1)])
  // The inner `let x` reads `y`, and binds a *different* `x`.
  assert_eq(var_names(inner_let.uses), [("y", 2)])
  let bound = var_names(inner_let.defs)
  assert_eq(bound.length(), 1)
  assert_eq(bound[0].0, "x")
  assert_true(bound[0].1 != 1)
  // The trailing `x` resolves to the inner binding, not the parameter.
  assert_eq(var_names(inner_use.uses), bound)
}

///|
test "shadowing inside a branch does not leak out" {
  let source = "fn f(c : Bool) -> Int {\n  let x = 1\n  if c {\n    let x = 2\n    x\n  }\n  x\n}\n"
  let program = @parser_adapter.parse_source(source, "shb.mbt")
  let outer = program.nodes[1]
  let head = program.nodes[2]
  let region = program.nodes[head.children[0]]
  let inner_let = program.nodes[region.children[0]]
  let inner_use = program.nodes[region.children[1]]
  let outer_use = program.nodes[6]
  assert_eq(var_names(outer.defs), [("x", 2)])
  assert_eq(var_names(inner_let.defs), [("x", 3)])
  assert_eq(var_names(inner_use.uses), [("x", 3)])
  // After the branch the outer binding is visible again.
  assert_eq(var_names(outer_use.uses), [("x", 2)])
}

///|
test "two functions get separate entry/exit pairs and separate scopes" {
  let source = "fn f(a : Int) -> Int {\n  a\n}\n\nfn g(b : Int) -> Int {\n  let c = b\n  c\n}\n"
  let program = @parser_adapter.parse_source(source, "two.mbt")
  assert_eq(program.functions.length(), 2)
  assert_eq(program.errors.length(), 0)
  let first = program.functions[0]
  let second = program.functions[1]
  assert_eq(first.name, "f")
  assert_eq(second.name, "g")
  assert_eq(program.nodes[first.entry].defs.length(), 1)
  assert_eq(program.nodes[second.entry].defs.length(), 1)
  assert_eq(program.nodes[first.exit].kind, @core.SNodeKind::Expr)
  assert_eq(program.nodes[second.exit].kind, @core.SNodeKind::Expr)
  assert_true(first.exit < second.entry)
  // Scopes are process-wide unique, so variable identity never collides
  // across functions.
  let f_param = program.nodes[first.entry].defs[0]
  let g_param = program.nodes[second.entry].defs[0]
  assert_true(f_param.scope != g_param.scope)
}

///|
test "sequence emits one node per statement on its own line" {
  let source = "fn f() -> Int {\n  let a = 1\n  let b = 2\n  a\n}\n"
  let program = @parser_adapter.parse_source(source, "seq.mbt")
  assert_eq(program.nodes.length(), 5)
  assert_eq(ids_on_line(program, 2), [1])
  assert_eq(ids_on_line(program, 3), [2])
  assert_eq(ids_on_line(program, 4), [3])
}

///|
test "a let spanning several lines reports only its first line" {
  let source = "fn f(a : Int) -> Int {\n  let x = {\n    let y = a\n    y\n  }\n  x\n}\n"
  let program = @parser_adapter.parse_source(source, "brace.mbt")
  let let_node = program.nodes[1]
  assert_eq(let_node.loc.start_line, 2)
  // The brace-block RHS is a single unsupported construct, so its identifiers
  // are conservatively collected as uses of the `let`.
  let names = var_names(let_node.uses)
  assert_true(names.length() > 0)
}

///|
test "loc conversion carries columns through unchanged" {
  let program = @parser_adapter.parse_source(add_source, "add.mbt")
  let let_node = program.nodes[1]
  // `let s = a + b` starts at column 3 (1-based) on line 2.
  assert_eq(let_node.loc.start_line, 2)
  assert_eq(let_node.loc.start_col, 3)
  assert_true(let_node.loc.end_col > let_node.loc.start_col)
}

///|
test "loc helper is stable for equal lines" {
  assert_eq(loc(4), loc(4))
  assert_true(loc(4) != loc(5))
}
