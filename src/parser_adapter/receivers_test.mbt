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
test "a type inferred from a constructor is not resolved" {
  // Tempting and unsound to guess: `make()` could return a trait object.
  assert_eq(calls_of("fn f() {\n  let p = Point::{ x: 1 }\n  p.norm()\n}\n"), [])
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
