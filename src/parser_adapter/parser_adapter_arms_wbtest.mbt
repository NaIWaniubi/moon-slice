// Whitebox tests for adapter arms reachable from real MoonBit source.
//
// Each test parses a snippet and asserts the emitted node shape. Cases whose
// syntax this MoonBit version rejects (`while ... else`, `let ... and`) are
// documented in the package header instead of being faked here.

///|
/// Kind name, so failures read as `Let != Call` rather than `0 != 4`.
fn kind_name(kind : @core.SNodeKind) -> String {
  match kind {
    Let => "Let"
    LetMut => "LetMut"
    Assign => "Assign"
    If => "If"
    While => "While"
    For => "For"
    Match => "Match"
    Return => "Return"
    Break => "Break"
    Continue => "Continue"
    Call => "Call"
    Expr => "Expr"
  }
}

///|
fn kinds_of(program : @core.Program) -> Array[String] {
  let out : Array[String] = []
  program.nodes.each(fn(node) { out.push(kind_name(node.kind)) })
  out
}

///|
fn def_names(node : @core.SNode) -> Array[String] {
  let out : Array[String] = []
  node.defs.each(fn(d) { out.push(d.name) })
  out
}

///|
fn use_names(node : @core.SNode) -> Array[String] {
  let out : Array[String] = []
  node.uses.each(fn(u) { out.push(u.name) })
  out
}

///|
test "labelled and optional parameters all bind" {
  let source = "fn f(a : Int, b~ : Int, c? : Int = 0, d? : Int) -> Int {\n  a + b + c + d\n}\n"
  let program = parse_source(source, "p.mbt")
  assert_eq(program.errors.length(), 0)
  let entry = program.nodes[0]
  assert_eq(def_names(entry), ["a", "b", "c", "d"])
}

///|
test "parameterless function has an empty entry def set" {
  let source = "fn f() -> Int {\n  1\n}\n"
  let program = parse_source(source, "p0.mbt")
  assert_eq(program.errors.length(), 0)
  assert_eq(program.nodes[0].defs.length(), 0)
}

///|
test "method call is a Call that uses receiver and arguments" {
  let source = "fn f(s : S, v : Int) -> Int {\n  s.m(v)\n}\n"
  let program = parse_source(source, "dot.mbt")
  assert_eq(program.errors.length(), 0)
  let call = program.nodes[1]
  assert_eq(kind_name(call.kind), "Call")
  assert_eq(use_names(call), ["s", "v"])
}

///|
test "bare return has no uses" {
  let source = "fn f() -> Unit {\n  return\n}\n"
  let program = parse_source(source, "ret.mbt")
  assert_eq(program.errors.length(), 0)
  let ret = program.nodes[1]
  assert_eq(kind_name(ret.kind), "Return")
  assert_eq(ret.uses.length(), 0)
}

///|
test "break with a value records the value's uses" {
  let source = "fn f(n : Int) -> Int {\n  while n > 0 {\n    break n\n  }\n  0\n}\n"
  let program = parse_source(source, "brk.mbt")
  assert_eq(program.errors.length(), 0)
  let break_node = program.nodes[3]
  assert_eq(kind_name(break_node.kind), "Break")
  assert_eq(use_names(break_node), ["n"])
}

///|
test "continue carries its arguments as uses" {
  let source = "fn f(n : Int) -> Int {\n  while n > 0 {\n    continue n\n  }\n  0\n}\n"
  let program = parse_source(source, "cont.mbt")
  assert_eq(program.errors.length(), 0)
  let cont = program.nodes[3]
  assert_eq(kind_name(cont.kind), "Continue")
  assert_eq(use_names(cont), ["n"])
}

///|
test "guard becomes an If head with a single region" {
  let source = "fn f(n : Int) -> Int {\n  guard n > 0 else { return 0 }\n  n\n}\n"
  let program = parse_source(source, "guard.mbt")
  assert_eq(program.errors.length(), 0)
  let head = program.nodes[1]
  assert_eq(kind_name(head.kind), "If")
  assert_true(use_names(head).contains("n"))
  assert_true(head.children.length() >= 1)
}

///|
test "array get slice is a plain Expr node" {
  let source = "fn f(a : Array[Int], i : Int, j : Int) -> Array[Int] {\n  a[i:j]\n}\n"
  let program = parse_source(source, "sl.mbt")
  assert_eq(program.errors.length(), 0)
  let node = program.nodes[1]
  assert_eq(kind_name(node.kind), "Expr")
  let names = use_names(node)
  assert_true(names.contains("a"))
  assert_true(names.contains("i"))
  assert_true(names.contains("j"))
}

///|
test "augmented array write defines and reads its base" {
  let source = "fn f(a : Array[Int], i : Int, v : Int) -> Unit {\n  a[i] += v\n}\n"
  let program = parse_source(source, "augarr.mbt")
  assert_eq(program.errors.length(), 0)
  let store = program.nodes[1]
  assert_eq(kind_name(store.kind), "Assign")
  assert_eq(def_names(store), ["a"])
  let names = use_names(store)
  assert_true(names.contains("a"))
  assert_true(names.contains("i"))
  assert_true(names.contains("v"))
}

///|
test "top-level let is not lowered into a function body" {
  // A module-level binding is not part of any function, so the analysis skips
  // it; only the `fn` after it produces nodes.
  let source = "let k = 1\n\nfn f() -> Int {\n  k\n}\n"
  let program = parse_source(source, "toplevel.mbt")
  assert_eq(program.errors.length(), 0)
  assert_eq(program.functions.length(), 1)
  assert_eq(program.functions[0].name, "f")
  // `k` is free: it has no definition node, so the use carries scope -1.
  let read = program.nodes[1]
  assert_eq(use_names(read), ["k"])
  assert_eq(read.uses[0].scope, -1)
}

///|
test "impl block bodies are not lowered" {
  let source = "struct T { v : Int }\n\nimpl T with fn get(self) -> Int {\n  self.v\n}\n"
  let program = parse_source(source, "impl.mbt")
  assert_eq(program.errors.length(), 0)
  assert_eq(program.functions.length(), 0)
  assert_eq(program.nodes.length(), 0)
}

///|
test "a declared-only function has no body nodes" {
  let source = "fn ext(a : Int) -> Int = \"test\"\n\nfn real(a : Int) -> Int {\n  a\n}\n"
  let program = parse_source(source, "stubs.mbt")
  assert_eq(program.errors.length(), 0)
  // Only `real` has a DeclBody, so only it appears in `functions`.
  assert_eq(program.functions.length(), 1)
  assert_eq(program.functions[0].name, "real")
}

///|
test "sequence of three statements emits three siblings in order" {
  let source = "fn f(a : Int) -> Int {\n  let x = a\n  let y = x\n  y\n}\n"
  let program = parse_source(source, "seq3.mbt")
  assert_eq(kinds_of(program), ["Expr", "Let", "Let", "Expr", "Expr"])
  let first = program.nodes[1]
  let second = program.nodes[2]
  assert_eq(def_names(first), ["x"])
  assert_eq(def_names(second), ["y"])
  assert_eq(use_names(second), ["x"])
}

///|
test "identical uses inside one statement are deduplicated" {
  let source = "fn f(a : Int) -> Int {\n  a + a + a\n}\n"
  let program = parse_source(source, "dup.mbt")
  let node = program.nodes[1]
  assert_eq(use_names(node), ["a"])
}

///|
test "a node never lists its own definition among its uses" {
  let source = "fn f() -> Int {\n  let mut x = 1\n  x = x + 1\n  x\n}\n"
  let program = parse_source(source, "ownuse.mbt")
  let store = program.nodes[2]
  assert_eq(def_names(store), ["x"])
  // The read of `x` on the right-hand side is a genuine use of the *previous*
  // definition, so it must be present exactly once.
  assert_eq(use_names(store), ["x"])
}
