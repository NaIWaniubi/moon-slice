// Argument mapping and effect-line extraction, checked against hand-written
// sources where the expected parameter binding is unambiguous.

///|
fn args_of(source : String, caller : String, line : Int32) -> Array[@parser_adapter.CallArgument] {
  @parser_adapter.call_arguments(source, caller, line)
}

///|
fn texts(args : Array[@parser_adapter.CallArgument]) -> Array[String] {
  args.map(fn(arg) { arg.expr_text })
}

///|
fn names(args : Array[@parser_adapter.CallArgument]) -> Array[String] {
  args.map(fn(arg) { arg.param_name })
}

// ---------------------------------------------------------------------------
// Positional, named and default arguments
// ---------------------------------------------------------------------------

///|
test "positional arguments bind in declaration order" {
  let source = "fn add(a : Int, b : Int) -> Int {\n  a + b\n}\n\nfn main_fn() -> Int {\n  add(1, 2)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(names(args), ["a", "b"])
  assert_eq(texts(args), ["1", "2"])
  assert_eq(args[0].index, 0)
  assert_eq(args[1].index, 1)
  assert_eq(args[0].expr_line, 6)
  assert_eq(args[1].expr_line, 6)
}

///|
test "a named argument binds by parameter name, not by position" {
  let source = "fn pair(a : Int, b : Int) -> Int {\n  a - b\n}\n\nfn main_fn() -> Int {\n  pair(b=2, a=1)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(names(args), ["a", "b"])
  assert_eq(texts(args), ["1", "2"])
}

///|
test "a pun argument carries the name as its text" {
  let source = "fn pair(a : Int, b : Int) -> Int {\n  a - b\n}\n\nfn main_fn(b : Int) -> Int {\n  pair(a=1, b~)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(names(args), ["a", "b"])
  assert_eq(texts(args), ["1", "b"])
}

///|
test "an omitted parameter keeps an empty text" {
  let source = "fn scaled(x : Int, k? : Int = 2) -> Int {\n  x * k\n}\n\nfn main_fn() -> Int {\n  scaled(5)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(names(args), ["x", "k"])
  assert_eq(texts(args), ["5", ""])
  assert_eq(args[1].expr_line, 0)
}

///|
test "a supplied optional parameter is reported with its text" {
  let source = "fn scaled(x : Int, k? : Int = 2) -> Int {\n  x * k\n}\n\nfn main_fn() -> Int {\n  scaled(5, k=3)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(texts(args), ["5", "3"])
}

///|
test "a complex argument keeps its exact source text" {
  let source = "fn f(a : Int) -> Int {\n  a\n}\n\nfn main_fn(x : Int) -> Int {\n  f(x * 2 + 1)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(texts(args), ["x * 2 + 1"])
}

///|
test "a nested call argument keeps the inner call as text" {
  let source = "fn g(x : Int) -> Int {\n  x\n}\n\nfn f(a : Int) -> Int {\n  a\n}\n\nfn main_fn() -> Int {\n  f(g(1))\n}\n"
  let args = args_of(source, "main_fn", 10)
  assert_eq(texts(args), ["g(1)"])
}

///|
test "text extraction is unaffected by a non-ASCII comment above the call" {
  let source = "fn f(a : Int) -> Int {\n  a\n}\n\nfn main_fn(x : Int) -> Int {\n  // 中文注释不应该移动列号\n  f(x)\n}\n"
  let args = args_of(source, "main_fn", 7)
  assert_eq(texts(args), ["x"])
}

///|
test "a multi-line argument is reported across its lines" {
  let source = "fn f(a : Int) -> Int {\n  a\n}\n\nfn main_fn(x : Int) -> Int {\n  f(x +\n    1)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(texts(args), ["x +\n    1"])
  assert_eq(args[0].expr_line, 6)
}

///|
test "a qualified method call binds against its declared parameters" {
  let source = "fn T::make(a : Int, b : Int) -> Int {\n  a + b\n}\n\nfn main_fn() -> Int {\n  T::make(1, 2)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(names(args), ["a", "b"])
  assert_eq(texts(args), ["1", "2"])
}

///|
test "a receiver call binds against a declared method" {
  let source = "impl Point with fn shift(self, dx : Int) -> Unit {\n  ignore(dx)\n}\n\nfn main_fn(p : Point) -> Unit {\n  p.shift(3)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(names(args), ["self", "dx"])
  assert_eq(texts(args), ["", "3"])
}

///|
test "an unknown callee reports supplied arguments without parameter names" {
  let source = "fn main_fn(x : Int) -> Int {\n  elsewhere(x, 2)\n}\n"
  let args = args_of(source, "main_fn", 2)
  assert_eq(texts(args), ["x", "2"])
  assert_eq(names(args), ["", ""])
}

///|
test "a line without a call inside the caller has no arguments" {
  let source = "fn main_fn(x : Int) -> Int {\n  x\n}\n"
  assert_eq(args_of(source, "main_fn", 2).length(), 0)
}

///|
test "an unknown caller has no arguments" {
  let source = "fn main_fn(x : Int) -> Int {\n  f(x)\n}\n"
  assert_eq(args_of(source, "nobody", 2).length(), 0)
}

///|
test "a discard parameter consumes its position but produces no entry" {
  let source = "fn f(_ : Int, b : Int) -> Int {\n  b\n}\n\nfn main_fn() -> Int {\n  f(1, 2)\n}\n"
  let args = args_of(source, "main_fn", 6)
  assert_eq(names(args), ["b"])
  assert_eq(args[0].index, 1)
  assert_eq(texts(args), ["2"])
}

// ---------------------------------------------------------------------------
// Effect lines
// ---------------------------------------------------------------------------

///|
fn effects_of(source : String, name : String) -> @parser_adapter.EffectLines {
  @parser_adapter.effect_lines(source, name)
}

///|
fn call_names(fx : @parser_adapter.EffectLines) -> Array[String] {
  fx.calls.map(fn(call) { call.name })
}

///|
test "a field write is reported on its line" {
  let fx = effects_of("fn set_x(p : Point) -> Unit {\n  p.x = 1\n}\n", "set_x")
  assert_eq(fx.writes, [2])
  assert_eq(fx.raises, [])
  assert_eq(fx.io, [])
}

///|
test "an element write is reported on its line" {
  let fx = effects_of("fn poke(self : T) -> Unit {\n  self.items[0] = 1\n}\n", "poke")
  assert_eq(fx.writes, [2])
}

///|
test "assigning self is a receiver mutation" {
  let fx = effects_of("fn reset(self : T) -> Unit {\n  self = self\n}\n", "reset")
  assert_eq(fx.writes, [2])
}

///|
test "a plain local assignment is not a write the caller sees" {
  let fx = effects_of("fn local() -> Int {\n  let mut n = 1\n  n = 2\n  n\n}\n", "local")
  assert_eq(fx.writes, [])
}

///|
test "a raise is reported on its line" {
  let fx = effects_of("fn bad() -> Int {\n  raise Failure(\"boom\")\n}\n", "bad")
  assert_eq(fx.raises, [2])
}

///|
test "a try operator is reported as a raise" {
  let fx = effects_of("fn risky() -> Int {\n  try! boom()\n}\n", "risky")
  assert_eq(fx.raises, [2])
  assert_eq(call_names(fx), ["boom"])
}

///|
test "a panic helper is both a call and a raise" {
  let fx = effects_of("fn explode() -> Unit {\n  panic()\n}\n", "explode")
  assert_eq(fx.raises, [2])
  assert_eq(fx.io, [])
  assert_eq(call_names(fx), ["panic"])
}

///|
test "an IO call is reported on its line" {
  let fx = effects_of("fn log_it() -> Unit {\n  println(\"hi\")\n}\n", "log_it")
  assert_eq(fx.io, [2])
  assert_eq(call_names(fx), ["println"])
}

///|
test "a dot call records the method name" {
  let fx = effects_of("fn T::run(self : T) -> Int {\n  self.norm()\n}\n", "run")
  assert_eq(call_names(fx), ["norm"])
  assert_eq(fx.io, [])
}

///|
test "every call site of a body is reported in source order" {
  let fx = effects_of("fn many() -> Unit {\n  h()\n  g()\n  h()\n}\n", "many")
  assert_eq(call_names(fx), ["h", "g", "h"])
  assert_eq(fx.calls.map(fn(call) { call.line }), [2, 3, 4])
}

///|
test "a package-qualified call is a boundary marker" {
  let fx = effects_of("fn use_pkg() -> Unit {\n  @other.f()\n}\n", "use_pkg")
  assert_eq(call_names(fx), ["@"])
}

///|
test "a pure body has no effect lines" {
  let fx = effects_of("fn two() -> Int {\n  let a = 1\n  a + 1\n}\n", "two")
  assert_eq(fx.writes, [])
  assert_eq(fx.raises, [])
  assert_eq(fx.io, [])
  assert_eq(fx.calls.length(), 0)
}

///|
test "an unknown function has no effect lines" {
  let fx = effects_of("fn two() -> Int {\n  2\n}\n", "three")
  assert_eq(fx.calls.length(), 0)
}
