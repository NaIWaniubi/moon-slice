// Resolution tests. Each case feeds a small source and pins one verdict: a
// resolved call names its owner, an ambiguous one lists exactly the candidates,
// an unresolved one carries the reason category. The sources state their types
// the way an author would, so the cases double as documentation of what the
// pass can see.

///|
fn one(source : String) -> @resolve.ResolvedCall {
  let result = @resolve.resolve_source(source, "probe.mbt")
  if result.calls.length() != 1 {
    abort("expected exactly one dot call")
  }
  result.calls[0]
}

///|
fn describe(call : @resolve.ResolvedCall) -> String {
  call.receiver_expr +
  ":" +
  call.method_name +
  ":" +
  @resolve.status_name(call.status) +
  ":" +
  call.owner +
  ":" +
  @resolve.reason_name(call.reason)
}

///|
fn described(source : String) -> Array[String] {
  @resolve.resolve_source(source, "probe.mbt").calls.map(fn(call) {
    describe(call)
  })
}

///|
test "an annotated parameter resolves its receiver" {
  let call = one(
    "struct Point { x : Int }\nimpl Point with fn norm(self) -> Int { 1 }\nfn g(p : Point) {\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
  assert_eq(call.receiver_type, "Point")
  assert_eq(call.receiver_expr, "p")
  assert_eq(call.method_name, "norm")
  assert_eq(call.line, 4)
}

///|
test "an annotated let resolves its receiver" {
  let call = one(
    "impl Point with fn norm(self) -> Int { 1 }\nfn f() {\n  let p : Point = make()\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
  assert_eq(call.receiver_expr, "p")
}

///|
test "an annotated let mut resolves its receiver" {
  let call = one(
    "impl Point with fn norm(self) -> Int { 1 }\nfn f() {\n  let mut p : Point = make()\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
}

///|
test "a binding typed by a declared return type resolves" {
  let call = one(
    "struct Point { x : Int }\nfn make_point() -> Point { Point::{ x: 1 } }\nimpl Point with fn norm(self) -> Int { 1 }\nfn use() {\n  let p = make_point()\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
}

///|
test "a qualified constructor types the binding it creates" {
  let call = one(
    "struct Point { x : Int }\nfn Point::new() -> Point { Point::{ x: 1 } }\nimpl Point with fn norm(self) -> Int { 1 }\nfn use() {\n  let p = Point::new()\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
}

///|
test "a record literal that names its type resolves" {
  let call = one(
    "struct Point { x : Int }\nimpl Point with fn norm(self) -> Int { 1 }\nfn use() {\n  let p = Point::{ x: 1 }\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
}

///|
test "a declared field type resolves a one-link chain" {
  let call = one(
    "struct P { inner : Q }\nstruct Q { w : Int }\nimpl Q with fn norm(self) -> Int { 1 }\nfn use(p : P) {\n  p.inner.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Q")
  assert_eq(call.receiver_expr, "p.inner")
}

///|
test "a declared field type resolves a two-link chain" {
  let call = one(
    "struct R { v : Int }\nstruct Q { r : R }\nstruct P { q : Q }\nimpl R with fn norm(self) -> Int { 1 }\nfn use(p : P) {\n  p.q.r.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "R")
  assert_eq(call.receiver_expr, "p.q.r")
}

///|
test "a match payload carries the variant's type" {
  let call = one(
    "struct Point { x : Int }\nenum E {\n  Ok(Point)\n  Err(Int)\n}\nimpl Point with fn norm(self) -> Int { 1 }\nfn use(e : E) {\n  match e {\n    Ok(p) => p.norm()\n  }\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
  assert_eq(call.receiver_expr, "p")
}

///|
test "self inside an impl resolves to the implemented type" {
  let call = one(
    "impl Point with fn norm(self) -> Int {\n  self.helper()\n}\nfn Point::helper(self) -> Int { 1 }\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
  assert_eq(call.receiver_expr, "self")
  assert_eq(call.method_name, "helper")
}

///|
test "self inside a qualified method resolves to its type" {
  let call = one(
    "fn Point::norm(self) -> Int {\n  self.helper()\n}\nfn Point::helper(self) -> Int { 1 }\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
  assert_eq(call.receiver_expr, "self")
}

///|
test "a generic enum substitutes its payload before resolving" {
  let call = one(
    "enum Box[T] {\n  Wrap(T)\n}\nstruct Point { x : Int }\nimpl Point with fn norm(self) -> Int { 1 }\nfn use(b : Box[Point]) {\n  let Wrap(p) = b\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
}

///|
test "an Option payload resolves through the prelude enum" {
  let call = one(
    "struct Point { x : Int }\nimpl Point with fn norm(self) -> Int { 1 }\nfn use(o : Option[Point]) {\n  let Some(p) = o\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
}

///|
test "a Result Ok payload resolves through the prelude enum" {
  let call = one(
    "struct Point { x : Int }\nimpl Point with fn norm(self) -> Int { 1 }\nfn use(r : Result[Point, Int]) {\n  let Ok(p) = r\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
}

///|
test "the same method name on two types resolves per receiver" {
  let result = @resolve.resolve_source(
    "struct A { v : Int }\nstruct B { w : Int }\nimpl A with fn norm(self) -> Int { 1 }\nimpl B with fn norm(self) -> Int { 1 }\nfn use(a : A, b : B) {\n  a.norm()\n  b.norm()\n}\n",
    "probe.mbt",
  )
  assert_eq(result.calls.length(), 2)
  assert_eq(result.calls[0].owner, "A")
  assert_eq(result.calls[1].owner, "B")
  assert_eq(@resolve.status_name(result.calls[0].status), "resolved")
  assert_eq(@resolve.status_name(result.calls[1].status), "resolved")
}

///|
test "a missing method on a local type is method_not_declared" {
  let call = one(
    "struct P { x : Int }\nimpl P with fn other(self) -> Int { 1 }\nfn use(p : P) {\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "unresolved")
  assert_eq(@resolve.reason_name(call.reason), "method_not_declared")
  assert_eq(call.receiver_type, "P")
  assert_eq(call.owner, "")
}

///|
test "a method on a type this package does not declare is external_package" {
  let call = one("fn use(p : @geo.Point) {\n  p.norm()\n}\n")
  assert_eq(@resolve.status_name(call.status), "unresolved")
  assert_eq(@resolve.reason_name(call.reason), "external_package")
  assert_eq(call.receiver_type, "Point")
}

///|
test "a call result is a dynamic receiver" {
  let call = one(
    "struct A { v : Int }\nimpl A with fn norm(self) -> Int { 1 }\nfn use() {\n  make().norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "unresolved")
  assert_eq(@resolve.reason_name(call.reason), "dynamic_value")
  assert_eq(call.receiver_type, "")
  assert_eq(call.receiver_expr, "make(...)")
}

///|
test "an untyped binding with one owner is unknown_receiver_type" {
  let call = one(
    "struct A { v : Int }\nimpl A with fn norm(self) -> Int { 1 }\nfn use() {\n  let p = make()\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "unresolved")
  assert_eq(@resolve.reason_name(call.reason), "unknown_receiver_type")
  assert_eq(call.receiver_type, "")
  assert_eq(call.receiver_expr, "p")
}

///|
test "an untyped binding with two owners is ambiguous" {
  let call = one(
    "struct A { v : Int }\nstruct B { w : Int }\nimpl A with fn norm(self) -> Int { 1 }\nimpl B with fn norm(self) -> Int { 1 }\nfn use() {\n  let p = make()\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "ambiguous")
  assert_eq(call.candidates.length(), 2)
  assert_eq(@resolve.candidate_text(call.candidates[0]), "A::norm@3")
  assert_eq(@resolve.candidate_text(call.candidates[1]), "B::norm@4")
  assert_eq(call.owner, "")
}

///|
test "one owner declaring a method twice is ambiguous" {
  let call = one(
    "struct P { v : Int }\nfn P::norm(self) -> Int { 1 }\nfn P::norm(self) -> Int { 2 }\nfn use(p : P) {\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "ambiguous")
  assert_eq(call.receiver_type, "P")
  assert_eq(call.candidates.length(), 2)
  assert_eq(@resolve.candidate_text(call.candidates[0]), "P::norm@2")
  assert_eq(@resolve.candidate_text(call.candidates[1]), "P::norm@3")
}

///|
test "coverage splits the three outcomes and keeps the total" {
  let result = @resolve.resolve_source(
    "struct A { v : Int }\nstruct B { w : Int }\nimpl A with fn norm(self) -> Int { 1 }\nimpl B with fn norm(self) -> Int { 1 }\nfn use(a : A) {\n  a.norm()\n  let p = make()\n  p.norm()\n  make().other()\n}\n",
    "probe.mbt",
  )
  let report = result.coverage
  assert_eq(report.total, 3)
  assert_eq(report.resolved, 1)
  assert_eq(report.ambiguous, 1)
  assert_eq(report.unresolved, 1)
  assert_eq(report.resolved + report.ambiguous + report.unresolved, report.total)
}

///|
test "coverage counts each reason category" {
  let report = @resolve.resolve_source(
    "struct A { v : Int }\nimpl A with fn norm(self) -> Int { 1 }\nfn use(p : @geo.Point) {\n  p.norm()\n  make().norm()\n  other().norm()\n  let q = unknown()\n  q.norm()\n}\n",
    "probe.mbt",
  ).coverage
  assert_eq(report.total, 4)
  assert_eq(report.unresolved, 4)
  assert_eq(@resolve.reason_count(report, @resolve.ExternalPackage), 1)
  assert_eq(@resolve.reason_count(report, @resolve.DynamicValue), 2)
  assert_eq(@resolve.reason_count(report, @resolve.UnknownReceiverType), 1)
  assert_eq(@resolve.reason_count(report, @resolve.MethodNotDeclared), 0)
}

///|
test "a file without dot calls reports zero coverage" {
  let result = @resolve.resolve_source("fn nothing() {\n  1\n}\n", "probe.mbt")
  assert_eq(result.calls.length(), 0)
  assert_eq(result.coverage.total, 0)
  assert_eq(result.coverage.resolved, 0)
  assert_eq(result.coverage.ambiguous, 0)
  assert_eq(result.coverage.unresolved, 0)
  assert_eq(@resolve.reason_count(result.coverage, @resolve.DynamicValue), 0)
}

///|
test "every call keeps its own line" {
  let result = @resolve.resolve_source(
    "impl Point with fn one(self) -> Int { 1 }\nimpl Point with fn two(self) -> Int { 1 }\nfn use(p : Point) {\n\n  p.one()\n  p.two()\n}\n",
    "probe.mbt",
  )
  assert_eq(result.calls.length(), 2)
  assert_eq(result.calls[0].line, 5)
  assert_eq(result.calls[1].line, 6)
  assert_eq(result.calls[0].method_name, "one")
  assert_eq(result.calls[1].method_name, "two")
}

///|
test "a resolved call has no reason and no candidates" {
  let call = one(
    "impl Point with fn norm(self) -> Int { 1 }\nfn use(p : Point) {\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.reason_name(call.reason), "")
  assert_eq(call.candidates.length(), 0)
  assert_eq(call.receiver_type, call.owner)
}

///|
test "an ambiguous call carries no failure reason" {
  let call = one(
    "struct A { v : Int }\nstruct B { w : Int }\nimpl A with fn norm(self) -> Int { 1 }\nimpl B with fn norm(self) -> Int { 1 }\nfn use() {\n  let p = make()\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "ambiguous")
  assert_eq(@resolve.reason_name(call.reason), "")
}

///|
test "an unresolved call lists no candidates" {
  let call = one(
    "struct P { x : Int }\nimpl P with fn other(self) -> Int { 1 }\nfn use(p : P) {\n  p.norm()\n}\n",
  )
  assert_eq(call.candidates.length(), 0)
}

///|
test "a method declared in another file resolves the call" {
  let first = @resolve.source_file(
    "point.mbt",
    "struct Point { x : Int }\nimpl Point with fn norm(self) -> Int { 1 }\n",
  )
  let second = @resolve.source_file(
    "use.mbt",
    "fn use(p : Point) {\n  p.norm()\n}\n",
  )
  let results = @resolve.resolve_package([first, second])
  assert_eq(results.length(), 2)
  assert_eq(results[0].calls.length(), 0)
  assert_eq(results[1].calls.length(), 1)
  assert_eq(results[1].calls[0].owner, "Point")
  assert_eq(@resolve.status_name(results[1].calls[0].status), "resolved")
}

///|
test "a field type declared in another file resolves a chain" {
  let first = @resolve.source_file(
    "types.mbt",
    "struct Q { w : Int }\nstruct P { inner : Q }\nimpl Q with fn norm(self) -> Int { 1 }\n",
  )
  let second = @resolve.source_file("use.mbt", "fn use(p : P) {\n  p.inner.norm()\n}\n")
  let results = @resolve.resolve_package([first, second])
  let call = results[1].calls[0]
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Q")
  assert_eq(call.receiver_expr, "p.inner")
}

///|
test "a package reports per-file coverage" {
  let first = @resolve.source_file(
    "point.mbt",
    "struct Point { x : Int }\nimpl Point with fn norm(self) -> Int { 1 }\n",
  )
  let second = @resolve.source_file(
    "use.mbt",
    "fn use(p : Point) {\n  p.norm()\n}\n",
  )
  let results = @resolve.resolve_package([first, second])
  assert_eq(results[0].file, "point.mbt")
  assert_eq(results[1].file, "use.mbt")
  assert_eq(results[0].coverage.total, 0)
  assert_eq(results[1].coverage.total, 1)
  assert_eq(results[1].coverage.resolved, 1)
}

///|
test "merged coverage sums the per-file reports" {
  let first = @resolve.source_file(
    "point.mbt",
    "struct Point { x : Int }\nimpl Point with fn norm(self) -> Int { 1 }\n",
  )
  let second = @resolve.source_file(
    "use.mbt",
    "fn use(p : Point) {\n  p.norm()\n}\n",
  )
  let results = @resolve.resolve_package([first, second])
  let merged = @resolve.merged_coverage(results)
  assert_eq(merged.total, 1)
  assert_eq(merged.resolved, 1)
  assert_eq(merged.resolved + merged.ambiguous + merged.unresolved, merged.total)
}

///|
test "an extra table resolves a method the file does not declare" {
  let extra = @resolve.declarations(
    "impl Point with fn norm(self) -> Int { 1 }\n",
    "helper.mbt",
  )
  let result = @resolve.resolve_source(
    "fn use(p : Point) {\n  p.norm()\n}\n",
    "main.mbt",
    extra=extra,
  )
  assert_eq(result.calls[0].owner, "Point")
  assert_eq(@resolve.status_name(result.calls[0].status), "resolved")
}

///|
test "merge_tables combines two files' declarations" {
  let table = @resolve.empty_table()
  @resolve.merge_tables(
    table,
    @resolve.declarations("impl A with fn norm(self) -> Int { 1 }\n", "a.mbt"),
  )
  @resolve.merge_tables(
    table,
    @resolve.declarations("impl B with fn other(self) -> Int { 1 }\n", "b.mbt"),
  )
  let result = @resolve.resolve_source(
    "fn use(p : A, q : B) {\n  p.norm()\n  q.other()\n}\n",
    "main.mbt",
    extra=table,
  )
  assert_eq(result.calls.map(describe), [
    "p:norm:resolved:A:",
    "q:other:resolved:B:",
  ])
}

///|
test "a dynamic receiver with two declared owners is ambiguous" {
  let call = one(
    "struct A { v : Int }\nstruct B { w : Int }\nimpl A with fn norm(self) -> Int { 1 }\nimpl B with fn norm(self) -> Int { 1 }\nfn use() {\n  make().norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "ambiguous")
  assert_eq(@resolve.reason_name(call.reason), "")
  assert_eq(call.receiver_expr, "make(...)")
  assert_eq(call.candidates.length(), 2)
}

///|
test "candidate_text names owner, method and line" {
  let call = one(
    "struct A { v : Int }\nstruct B { w : Int }\nimpl A with fn norm(self) -> Int { 1 }\nimpl B with fn norm(self) -> Int { 1 }\nfn use() {\n  let p = make()\n  p.norm()\n}\n",
  )
  assert_eq(@resolve.candidate_text(call.candidates[1]), "B::norm@4")
}

///|
test "source_file keeps its name and source" {
  let file = @resolve.source_file("a.mbt", "fn f() {\n  1\n}\n")
  assert_eq(file.name, "a.mbt")
  assert_eq(file.source, "fn f() {\n  1\n}\n")
}

///|
test "several calls in one body each get a verdict" {
  assert_eq(
    described(
      "struct A { v : Int }\nstruct B { w : Int }\nimpl A with fn norm(self) -> Int { 1 }\nimpl B with fn norm(self) -> Int { 1 }\nfn use(a : A) {\n  a.norm()\n  let p = make()\n  p.norm()\n  make().other()\n}\n",
    ),
    [
      "a:norm:resolved:A:",
      "p:norm:ambiguous::",
      "make(...):other:unresolved::dynamic_value",
    ],
  )
}

///|
test "coverage_of recomputes the report from the calls" {
  let result = @resolve.resolve_source(
    "struct A { v : Int }\nimpl A with fn norm(self) -> Int { 1 }\nfn use(p : @geo.Point) {\n  p.norm()\n  make().norm()\n}\n",
    "probe.mbt",
  )
  let recomputed = @resolve.coverage_of(result.calls)
  assert_eq(recomputed.total, result.coverage.total)
  assert_eq(recomputed.resolved, result.coverage.resolved)
  assert_eq(recomputed.ambiguous, result.coverage.ambiguous)
  assert_eq(recomputed.unresolved, result.coverage.unresolved)
  assert_eq(@resolve.reason_count(recomputed, @resolve.ExternalPackage), 1)
}

///|
test "an empty package merges to zero coverage" {
  let results = @resolve.resolve_package([])
  assert_eq(results.length(), 0)
  let merged = @resolve.merged_coverage(results)
  assert_eq(merged.total, 0)
  assert_eq(@resolve.reason_count(merged, @resolve.MethodNotDeclared), 0)
}

///|
test "a chain whose first link is unknown is unresolved, not invented" {
  let call = one(
    "struct P { inner : Q }\nstruct Q { w : Int }\nimpl Q with fn norm(self) -> Int { 1 }\nfn use(p : Unknown) {\n  p.inner.norm()\n}\n",
  )
  assert_eq(@resolve.status_name(call.status), "unresolved")
  assert_eq(@resolve.reason_name(call.reason), "unknown_receiver_type")
  assert_eq(call.receiver_expr, "p.inner")
}

///|
test "a nested call inside a receiver leaves the outer call dynamic" {
  assert_eq(
    described(
      "struct A { v : Int }\nstruct B { w : Int }\nimpl A with fn to_b(self) -> B { B::{ w: 1 } }\nimpl B with fn norm(self) -> Int { 1 }\nfn use(a : A) {\n  a.to_b().norm()\n}\n",
    ),
    [
      "a.to_b(...):norm:unresolved::dynamic_value",
      "a:to_b:resolved:A:",
    ],
  )
}

///|
test "a package resolves a call typed by a cross-file return type" {
  let first = @resolve.source_file(
    "point.mbt",
    "struct Point { x : Int }\nfn make_point() -> Point { Point::{ x: 1 } }\nimpl Point with fn norm(self) -> Int { 1 }\n",
  )
  let second = @resolve.source_file(
    "use.mbt",
    "fn use() {\n  let p = make_point()\n  p.norm()\n}\n",
  )
  let results = @resolve.resolve_package([first, second])
  let call = results[1].calls[0]
  assert_eq(@resolve.status_name(call.status), "resolved")
  assert_eq(call.owner, "Point")
}

///|
test "status and reason names cover every variant" {
  assert_eq(@resolve.status_name(@resolve.Resolved), "resolved")
  assert_eq(@resolve.status_name(@resolve.Ambiguous), "ambiguous")
  assert_eq(@resolve.status_name(@resolve.Unresolved), "unresolved")
  assert_eq(@resolve.reason_name(@resolve.NoReason), "")
  assert_eq(@resolve.reason_name(@resolve.UnknownReceiverType), "unknown_receiver_type")
  assert_eq(@resolve.reason_name(@resolve.MethodNotDeclared), "method_not_declared")
  assert_eq(@resolve.reason_name(@resolve.ExternalPackage), "external_package")
  assert_eq(@resolve.reason_name(@resolve.DynamicValue), "dynamic_value")
}

///|
test "an empty report has all counter categories at zero" {
  let report = @resolve.empty_report()
  assert_eq(report.total, 0)
  assert_eq(report.resolved, 0)
  assert_eq(report.ambiguous, 0)
  assert_eq(report.unresolved, 0)
  assert_eq(@resolve.reason_count(report, @resolve.UnknownReceiverType), 0)
  assert_eq(@resolve.reason_count(report, @resolve.DynamicValue), 0)
}
