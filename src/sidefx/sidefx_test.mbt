// Tests for the side-effect summary pass. Each case is a tiny source fragment
// plus the exact effects it must report: field labels, calls, and the derived
// purity verdict. The call-graph cases use a package batch, which is where the
// closure and the recursion rule live.

///|
fn fx(source : String, name : String) -> @sidefx.SideEffects {
  @sidefx.summarize_source(source, name).unwrap()
}

///|
fn pkg(entries : Array[(String, String)]) -> Array[@sidefx.FnSummary] {
  let sources : Array[@sidefx.FnSource] = []
  entries.each(fn(entry) {
    sources.push(@sidefx.FnSource::{ name: entry.0, source: entry.1 })
  })
  @sidefx.summarize_package(sources)
}

///|
fn by_name(
  summaries : Array[@sidefx.FnSummary],
  name : String,
) -> @sidefx.SideEffects {
  let mut found : @sidefx.SideEffects? = None
  for summary in summaries {
    if summary.name == name {
      found = Some(summary.effects)
    }
  }
  found.unwrap()
}

// ---------------------------------------------------------------------------
// Pure bodies
// ---------------------------------------------------------------------------

///|
test "an empty body is pure and does nothing" {
  let effects = fx("fn empty() -> Unit { () }", "empty")
  assert_eq(effects.reads_fields, [])
  assert_eq(effects.writes_fields, [])
  assert_true(!effects.mutates_receiver)
  assert_eq(effects.calls, [])
  assert_true(!effects.may_raise)
  assert_true(!effects.may_io)
  assert_true(effects.pure)
}

///|
test "constant arithmetic is pure" {
  let effects = fx("fn two() -> Int { 1 + 2 }", "two")
  assert_eq(effects.calls, [])
  assert_true(effects.pure)
}

///|
test "a field read does not break purity" {
  let effects = fx("fn read_x(p : Point) -> Int { p.x }", "read_x")
  assert_eq(effects.reads_fields, ["x"])
  assert_eq(effects.writes_fields, [])
  assert_true(effects.pure)
}

///|
test "every read field is reported, sorted" {
  let effects = fx("fn total(p : Point) -> Int { p.b + p.a }", "total")
  assert_eq(effects.reads_fields, ["a", "b"])
}

///|
test "a nested field path reports every label on the way" {
  let effects = fx("fn deep(p : Point) -> Int { p.a.b }", "deep")
  assert_eq(effects.reads_fields, ["a", "b"])
}

///|
test "a tuple index is not a field read" {
  let effects = fx("fn first(pair : (Int, Int)) -> Int { pair.0 }", "first")
  assert_eq(effects.reads_fields, [])
  assert_true(effects.pure)
}

///|
test "an array element read is not a field read" {
  let effects = fx("fn head(xs : Array[Int]) -> Int { xs[0] }", "head")
  assert_eq(effects.reads_fields, [])
  assert_true(effects.pure)
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

///|
test "a field write makes the function impure" {
  let effects = fx("fn set_x(p : Point) -> Unit { p.x = 1 }", "set_x")
  assert_eq(effects.writes_fields, ["x"])
  assert_eq(effects.reads_fields, [])
  assert_true(!effects.mutates_receiver)
  assert_true(!effects.pure)
}

///|
test "a compound field assignment reads and writes the field" {
  let effects = fx("fn bump_x(p : Point) -> Unit { p.x += 1 }", "bump_x")
  assert_eq(effects.writes_fields, ["x"])
  assert_eq(effects.reads_fields, ["x"])
  assert_true(!effects.pure)
}

///|
test "a record literal is not a field write" {
  let effects = fx("fn make() -> Point { Point::{ x: 1 } }", "make")
  assert_eq(effects.writes_fields, [])
  assert_eq(effects.reads_fields, [])
  assert_true(effects.pure)
}

///|
test "a receiver field write mutates the receiver" {
  let effects = fx("fn T::bump(self : T) -> Unit { self.x = 1 }", "bump")
  assert_eq(effects.writes_fields, ["x"])
  assert_eq(effects.reads_fields, [])
  assert_true(effects.mutates_receiver)
  assert_true(!effects.pure)
}

///|
test "reading a receiver field does not mutate it" {
  let effects = fx("fn T::get(self : T) -> Int { self.x }", "get")
  assert_eq(effects.reads_fields, ["x"])
  assert_true(!effects.mutates_receiver)
  assert_true(effects.pure)
}

///|
test "a nested receiver write still mutates the receiver" {
  let effects = fx("fn T::arm(self : T) -> Unit { self.inner.flag = 1 }", "arm")
  assert_eq(effects.writes_fields, ["flag"])
  assert_eq(effects.reads_fields, ["inner"])
  assert_true(effects.mutates_receiver)
}

///|
test "writing an element through a receiver field mutates the receiver" {
  let effects = fx("fn T::poke(self : T) -> Unit { self.items[0] = 1 }", "poke")
  assert_eq(effects.writes_fields, [])
  assert_eq(effects.reads_fields, ["items"])
  assert_true(effects.mutates_receiver)
  assert_true(!effects.pure)
}

///|
test "assigning self wholesale mutates the receiver" {
  let effects = fx("fn T::reset(self : T) -> Unit { self = self }", "reset")
  assert_true(effects.mutates_receiver)
  assert_true(!effects.pure)
}

///|
test "a free function writing a parameter field does not touch a receiver" {
  let effects = fx("fn store(p : Point) -> Unit { p.x = 1 }", "store")
  assert_eq(effects.writes_fields, ["x"])
  assert_true(!effects.mutates_receiver)
}

// ---------------------------------------------------------------------------
// Calls and the package closure
// ---------------------------------------------------------------------------

///|
test "calling a pure function stays pure" {
  let summaries = pkg([
    ("double", "fn double(n : Int) -> Int { n + n }"),
    ("use_it", "fn use_it(n : Int) -> Int { double(n) }"),
  ])
  assert_true(by_name(summaries, "double").pure)
  let caller = by_name(summaries, "use_it")
  assert_eq(caller.calls, ["double"])
  assert_true(caller.pure)
}

///|
test "calling an impure function is impure" {
  let summaries = pkg([
    ("set_x", "fn set_x(p : Point) -> Unit { p.x = 1 }"),
    ("caller", "fn caller(p : Point) -> Unit { set_x(p) }"),
  ])
  assert_true(!by_name(summaries, "set_x").pure)
  let caller = by_name(summaries, "caller")
  assert_eq(caller.writes_fields, [])
  assert_true(!caller.pure)
}

///|
test "impurity propagates through a chain of calls" {
  let summaries = pkg([
    ("writes", "fn writes(p : Point) -> Unit { p.x = 1 }"),
    ("middle", "fn middle(p : Point) -> Unit { writes(p) }"),
    ("top", "fn top(p : Point) -> Unit { middle(p) }"),
  ])
  assert_true(!by_name(summaries, "writes").pure)
  assert_true(!by_name(summaries, "middle").pure)
  assert_true(!by_name(summaries, "top").pure)
}

///|
test "a directly recursive function is conservatively impure" {
  let effects = fx("fn spin(n : Int) -> Unit { spin(n) }", "spin")
  assert_eq(effects.calls, ["spin"])
  assert_true(!effects.pure)
}

///|
test "mutually recursive functions are impure" {
  let summaries = pkg([
    ("f", "fn f(n : Int) -> Unit { g(n) }"),
    ("g", "fn g(n : Int) -> Unit { f(n) }"),
  ])
  assert_true(!by_name(summaries, "f").pure)
  assert_true(!by_name(summaries, "g").pure)
}

///|
test "a caller of a recursive function is impure, an unrelated one is not" {
  let summaries = pkg([
    ("spin", "fn spin(n : Int) -> Unit { spin(n) }"),
    ("wrap", "fn wrap(n : Int) -> Unit { spin(n) }"),
    ("idle", "fn idle() -> Int { 1 }"),
  ])
  assert_true(!by_name(summaries, "spin").pure)
  assert_true(!by_name(summaries, "wrap").pure)
  assert_true(by_name(summaries, "idle").pure)
}

///|
test "an unknown callee does not break purity" {
  let effects = fx("fn use_unknown() -> Unit { mystery() }", "use_unknown")
  assert_eq(effects.calls, ["mystery"])
  assert_true(effects.pure)
}

///|
test "call names are deduplicated and sorted" {
  let effects = fx("fn many() -> Unit { h(); g(); h() }", "many")
  assert_eq(effects.calls, ["g", "h"])
}

///|
test "a dot call records the method name" {
  let effects = fx("fn T::run(self : T) -> Int { self.norm() }", "run")
  assert_eq(effects.calls, ["norm"])
}

///|
test "a method call to an impure method of the package is impure" {
  let summaries = pkg([
    ("norm", "fn T::norm(self : T) -> Unit { self.x = 1 }"),
    ("run", "fn T::run(self : T) -> Int { self.norm() }"),
  ])
  assert_true(!by_name(summaries, "norm").pure)
  assert_true(!by_name(summaries, "run").pure)
}

// ---------------------------------------------------------------------------
// Raising and panicking
// ---------------------------------------------------------------------------

///|
test "raise makes a function may-raise and impure" {
  let effects = fx("fn bad() -> Int { raise Failure(\"boom\") }", "bad")
  assert_true(effects.may_raise)
  assert_true(!effects.pure)
}

///|
test "try! makes a function may-raise" {
  let effects = fx("fn risky() -> Int { try! boom() }", "risky")
  assert_true(effects.may_raise)
  assert_true(!effects.pure)
  assert_eq(effects.calls, ["boom"])
}

///|
test "a panic helper makes a function may-raise" {
  let effects = fx("fn explode() -> Unit { panic() }", "explode")
  assert_eq(effects.calls, ["panic"])
  assert_true(effects.may_raise)
  assert_true(!effects.pure)
}

///|
test "may-raise propagates to callers" {
  let summaries = pkg([
    ("bad", "fn bad() -> Int { raise Failure(\"boom\") }"),
    ("wrap", "fn wrap() -> Int { bad() }"),
  ])
  assert_true(by_name(summaries, "wrap").may_raise)
  assert_true(!by_name(summaries, "wrap").pure)
}

// ---------------------------------------------------------------------------
// IO heuristics
// ---------------------------------------------------------------------------

///|
test "println makes a function may-IO and impure" {
  let effects = fx("fn log_it() -> Unit { println(\"hi\") }", "log_it")
  assert_eq(effects.calls, ["println"])
  assert_true(effects.may_io)
  assert_true(!effects.pure)
}

///|
test "the IO name list is configurable" {
  let effects = @sidefx.summarize_source(
    "fn shout() -> Unit { log_it(1) }",
    "shout",
    io_names=["log_it"],
  ).unwrap()
  assert_true(effects.may_io)
  assert_true(!effects.pure)
}

///|
test "a name outside the default IO list is not IO" {
  let effects = fx("fn shout() -> Unit { log_it(1) }", "shout")
  assert_eq(effects.calls, ["log_it"])
  assert_true(!effects.may_io)
  assert_true(effects.pure)
}

///|
test "may-IO propagates to callers" {
  let summaries = pkg([
    ("writer", "fn writer() -> Unit { println(1) }"),
    ("caller", "fn caller() -> Unit { writer() }"),
  ])
  assert_true(by_name(summaries, "writer").may_io)
  assert_true(by_name(summaries, "caller").may_io)
  assert_true(!by_name(summaries, "caller").pure)
}

// ---------------------------------------------------------------------------
// Batch shape and lookup
// ---------------------------------------------------------------------------

///|
test "summaries keep the input order" {
  let summaries = pkg([
    ("zeta", "fn zeta() -> Unit { () }"),
    ("alpha", "fn alpha(p : Point) -> Unit { p.x = 1 }"),
  ])
  assert_eq(summaries.length(), 2)
  assert_eq(summaries[0].name, "zeta")
  assert_eq(summaries[1].name, "alpha")
}

///|
test "a missing function has no summary" {
  match @sidefx.summarize_source("fn a() -> Unit { () }", "b") {
    None => ()
    Some(_) => assert_true(false)
  }
}

///|
test "an empty name selects the only function of a snippet" {
  let effects = @sidefx.summarize_source(
    "fn lonely(p : Point) -> Unit { p.x = 1 }",
    "",
  ).unwrap()
  assert_eq(effects.writes_fields, ["x"])
}

///|
test "an empty batch summarises to nothing" {
  let sources : Array[@sidefx.FnSource] = []
  assert_eq(@sidefx.summarize_package(sources).length(), 0)
}

///|
test "a method declared with impl is seen as a method" {
  let effects = fx(
    "impl Point with fn norm(self : Point) -> Int { self.x }",
    "norm",
  )
  assert_eq(effects.reads_fields, ["x"])
  assert_true(!effects.mutates_receiver)
  assert_true(effects.pure)
}
