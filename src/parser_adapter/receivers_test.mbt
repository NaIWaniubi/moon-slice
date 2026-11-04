// Receiver-call resolution. Every case pins the same promise the docs make:
// a `x.f()` edge exists only when the type of `x` is written in the source, and
// only when the package actually declares `T::f`.

///|
fn facts(source : String) -> @parser_adapter.CallFacts {
  @parser_adapter.call_facts(source, "probe.mbt")
}

///|
fn calls_of(source : String) -> Array[String] {
  facts(source).receivers.map(fn(call) {
    call.receiver_type + "::" + call.method_name
  })
}

///|
test "an annotated parameter resolves a receiver call" {
  let source = "struct Point { x : Int }\nfn g(p : Point) {\n  p.norm()\n}\n"
  let facts = facts(source)
  assert_eq(facts.receivers.length(), 1)
  let call = facts.receivers[0]
  assert_eq(call.receiver_type, "Point")
  assert_eq(call.method_name, "norm")
  assert_eq(call.caller, "g")
  assert_eq(call.line, 3)
}

///|
test "an annotated let resolves a receiver call" {
  assert_eq(calls_of("fn f() {\n  let p : Point = make()\n  p.norm()\n}\n"), ["Point::norm"])
}

///|
test "an annotated let mut resolves a receiver call" {
  assert_eq(calls_of("fn f() {\n  let mut p : Point = make()\n  p.norm()\n}\n"), ["Point::norm"])
}

///|
test "a binding without an annotation is not resolved" {
  assert_eq(calls_of("fn f() {\n  let p = make()\n  p.norm()\n}\n"), [])
}

///|
test "a record literal without a type name stays unresolved" {
  // `{ x: 1 }` can be any type with that field; only `Point::{ x: 1 }` names one.
  assert_eq(calls_of("fn f() {\n  let p = { x : 1 }\n  p.norm()\n}\n"), [])
}

///|
test "the same name annotated twice with one type still resolves" {
  assert_eq(
    calls_of("fn f(c : Bool) {\n  let p : Point = a()\n  p.norm()\n  let p : Point = b()\n  p.norm()\n}\n"),
    ["Point::norm", "Point::norm"],
  )
}

///|
test "the same name annotated with two types is dropped" {
  // Either edge would be a guess; one of the two calls is not on a Point.
  assert_eq(
    calls_of("fn f(c : Bool) {\n  let p : Point = a()\n  p.norm()\n  let p : Other = b()\n  p.norm()\n}\n"),
    [],
  )
}

///|
test "self inside an impl resolves to the implemented type" {
  let source = "impl Point with fn norm(self) -> Int {\n  self.x_field()\n}\n"
  let facts = facts(source)
  assert_eq(facts.receivers.length(), 1)
  assert_eq(facts.receivers[0].receiver_type, "Point")
  assert_eq(facts.receivers[0].caller, "norm")
}

///|
test "self inside fn T::m(self) resolves to T" {
  assert_eq(calls_of("fn Point::norm(self) -> Int {\n  self.helper()\n}\n"), ["Point::helper"])
}

///|
test "a chained receiver is left unresolved" {
  assert_eq(calls_of("fn f(p : Point) {\n  p.inner.norm()\n}\n"), [])
}

///|
test "a call on a call result is left unresolved" {
  assert_eq(calls_of("fn f() {\n  make().norm()\n}\n"), [])
}

///|
test "a labelled parameter carries its type" {
  assert_eq(calls_of("fn f(~p : Point) {\n  p.norm()\n}\n"), ["Point::norm"])
}

///|
test "an optional parameter carries its type" {
  assert_eq(calls_of("fn f(p? : Point) {\n  p.norm()\n}\n"), ["Point::norm"])
}

///|
test "a package-qualified type annotation keeps the short name" {
  assert_eq(calls_of("fn f(p : @geo.Point) {\n  p.norm()\n}\n"), ["Point::norm"])
}

///|
test "a parameterised type resolves on its base name" {
  assert_eq(calls_of("fn f(xs : Array[Int]) {\n  xs.push(1)\n}\n"), ["Array::push"])
}

///|
test "declared methods are reported with their owner" {
  let facts = facts(
    "impl Point with fn norm(self) -> Int { 1 }\nfn Point::other(self) -> Int { 2 }\nfn free() -> Int { 3 }\n",
  )
  let declared = facts.methods.map(fn(item) { item.owner + "::" + item.name })
  assert_eq(declared, ["Point::norm", "Point::other"])
}

///|
test "a free function is not a method declaration" {
  let facts = facts("fn free() -> Int { 1 }\n")
  assert_eq(facts.methods.length(), 0)
}

///|
test "every receiver call keeps its line and caller" {
  let facts = facts(
    "fn a(p : Point) {\n  p.one()\n}\n\nfn b(p : Point) {\n\n  p.two()\n}\n",
  )
  let described = facts.receivers.map(fn(call) {
    call.caller + "@" + call.line.to_string() + ":" + call.method_name
  })
  assert_eq(described, ["a@2:one", "b@7:two"])
}

///|
test "a binding typed by a declared return type resolves its receiver" {
  let source =
    "struct Point {\n  x : Int\n}\n\nfn make_point() -> Point {\n  Point::{ x: 1 }\n}\n\nfn use() {\n  let p = make_point()\n  p.norm()\n}\n"
  assert_true(calls_of(source).contains("Point::norm"))
}

///|
test "a qualified constructor resolves through its declared return type" {
  let source =
    "struct Point {\n  x : Int\n}\n\nfn Point::new() -> Point {\n  Point::{ x: 1 }\n}\n\nfn use() {\n  let p = Point::new()\n  p.norm()\n}\n"
  assert_true(calls_of(source).contains("Point::norm"))
}

///|
test "a record literal that names its type resolves" {
  let source =
    "struct Point {\n  x : Int\n}\n\nfn use() {\n  let p = Point::{ x: 1 }\n  p.norm()\n}\n"
  assert_true(calls_of(source).contains("Point::norm"))
}

///|
test "an alias of a known binding keeps the type" {
  let source =
    "struct Point {\n  x : Int\n}\n\nfn use(q : Point) {\n  let p = q\n  p.norm()\n}\n"
  assert_true(calls_of(source).contains("Point::norm"))
}

///|
test "a local shadowing a declared function blocks the inference" {
  // `make_point` here is a value, not the function above; typing its result
  // from the function signature would invent an edge.
  let source =
    "struct Point {\n  x : Int\n}\n\nfn make_point() -> Point {\n  Point::{ x: 1 }\n}\n\nfn use(make_point : Unit -> Unit) {\n  let p = make_point()\n  p.norm()\n}\n"
  assert_eq(calls_of(source), [])
}

///|
test "a call to a function this file does not declare stays unresolved" {
  let source = "fn use() {\n  let p = unknown_maker()\n  p.norm()\n}\n"
  assert_eq(calls_of(source), [])
}

///|
test "a method's declared return type resolves the next receiver" {
  let source =
    "struct A {\n  v : Int\n}\n\nstruct B {\n  w : Int\n}\n\nfn A::to_b(self : A) -> B {\n  B::{ w: self.v }\n}\n\nfn use(a : A) {\n  let b = a.to_b()\n  b.other()\n}\n"
  assert_true(calls_of(source).contains("B::other"))
}

///|
test "an unknown return type keeps the binding unresolved" {
  let source =
    "fn use() {\n  let x = make()\n  x.norm()\n}\n\nfn make() -> Unknown {\n  1\n}\n"
  // `Unknown` is stated, so the type is known even though nothing declares it;
  // interproc's owner check is what stops the edge, not this pass.
  assert_eq(calls_of(source), ["Unknown::norm"])
}

///|
test "a field access carries the declared field type" {
  let source =
    "struct Q {\n  w : Int\n}\n\nstruct P {\n  inner : Q\n}\n\nfn use(p : P) {\n  p.inner.norm()\n}\n"
  assert_eq(calls_of(source), ["Q::norm"])
}

///|
test "a binding from a field access is typed" {
  let source =
    "struct Q {\n  w : Int\n}\n\nstruct P {\n  inner : Q\n}\n\nfn use(p : P) {\n  let q = p.inner\n  q.norm()\n}\n"
  assert_eq(calls_of(source), ["Q::norm"])
}

///|
test "a chain of fields resolves when every link is declared" {
  let source =
    "struct R {\n  v : Int\n}\n\nstruct Q {\n  r : R\n}\n\nstruct P {\n  q : Q\n}\n\nfn use(p : P) {\n  p.q.r.norm()\n}\n"
  assert_eq(calls_of(source), ["R::norm"])
}

///|
test "an undeclared field stops the chain" {
  let source =
    "struct P {\n  inner : Q\n}\n\nfn use(p : P) {\n  p.missing.norm()\n}\n"
  assert_eq(calls_of(source), [])
}

///|
test "a field typed by a type parameter resolves to nothing" {
  // `struct Box[T] { v : T }` says nothing about what `b.v` is.
  let source =
    "struct Box[T] {\n  v : T\n}\n\nfn use(b : Box[Int]) {\n  b.v.norm()\n}\n"
  assert_eq(calls_of(source), [])
}

///|
test "a tuple index access is left unresolved" {
  let source =
    "fn use(p : (Q, Q)) {\n  p.0.norm()\n}\n"
  assert_eq(calls_of(source), [])
}
