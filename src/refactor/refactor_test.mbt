// Blackbox tests for the removal planner.
//
// Every case is a small MoonBit source and the assertion is on the exact line
// range that would be deleted (or its absence) plus the proof line that records
// the decision. Hand-built inputs keep the expectations readable: an edit that
// appears or disappears for the wrong reason fails here, not in a smoke test.
//
// Function-removal fixtures deliberately avoid calls the package graph cannot
// attribute (a `println`, a call through an expression, a `@pkg` call): one
// unresolved boundary disables function removal for the whole package, which
// has its own regression test.

///|
fn plan_of(source : String) -> @refactor.RemovalPlan {
  @refactor.plan_package([
    @refactor.SourceFile::{ path: "p.mbt", source },
  ])
}

///|
fn plan_files(files : Array[@refactor.SourceFile]) -> @refactor.RemovalPlan {
  @refactor.plan_package(files)
}

///|
fn edits_text(plan : @refactor.RemovalPlan) -> String {
  let parts : Array[String] = []
  for edit in plan.edits {
    parts.push(edit.start_line.to_string() + "-" + edit.end_line.to_string())
  }
  parts.join(",")
}

///|
fn proof_has(plan : @refactor.RemovalPlan, needle : String) -> Bool {
  let mut found = false
  for line in plan.proof {
    match line.find(needle) {
      Some(_) => found = true
      None => ()
    }
  }
  found
}

///|
fn only_edit(plan : @refactor.RemovalPlan) -> @refactor.Edit {
  if plan.edits.length() != 1 {
    abort("expected exactly one edit, got " + plan.edits.length().to_string())
  }
  plan.edits[0]
}

///|
test "a pure unused let binding is removed" {
  let plan = plan_of(
    "fn keep(x : Int) -> Int {\n  let unused = 1\n  x\n}\n\nfn main {\n  keep(1)\n}\n",
  )
  assert_eq(edits_text(plan), "2-2")
  let edit = only_edit(plan)
  assert_eq(edit.file, "p.mbt")
  assert_eq(edit.start_col, 1)
  assert_eq(edit.end_col, 0)
  assert_true(edit.reason.contains("unused binding `unused`"))
  assert_true(proof_has(plan, "remove dead binding `unused`: pure initializer"))
}

///|
test "an unused let mut binding with a pure initializer is removed" {
  let plan = plan_of(
    "fn keep() -> Int {\n  let mut spare = 2 + 3\n  7\n}\n\nfn main {\n  keep()\n}\n",
  )
  assert_eq(edits_text(plan), "2-2")
}

///|
test "a binding whose initializer performs IO is kept" {
  let plan = plan_of(
    "fn keep() -> Int {\n  let ghost = println(\"side\")\n  7\n}\n\nfn main {\n  keep()\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "would perform I/O"))
}

///|
test "a binding calling an impure package function is kept" {
  let plan = plan_of(
    "fn noisy() -> Int {\n  raise Failure\n}\n\nfn keep() -> Int {\n  let ghost = noisy()\n  7\n}\n\nfn main {\n  keep()\n  noisy()\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "does not prove pure"))
  assert_true(proof_has(plan, "`ghost`"))
}

///|
test "a binding calling a pure package function is removed" {
  let plan = plan_of(
    "fn helper() -> Int {\n  41 + 1\n}\n\nfn keep() -> Int {\n  let spare = helper()\n  7\n}\n\nfn main {\n  helper()\n  keep()\n}\n",
  )
  assert_eq(edits_text(plan), "6-6")
}

///|
test "an unreachable pure private function is removed with its whole range" {
  let plan = plan_of(
    "fn orphan() -> Int {\n  7\n}\n\nfn main {\n  1\n}\n",
  )
  assert_eq(edits_text(plan), "1-3")
  let edit = only_edit(plan)
  assert_eq(edit.start_col, 1)
  assert_eq(edit.end_col, 0)
  assert_true(edit.reason.contains("unreachable private function `orphan`"))
  assert_true(proof_has(plan, "no root reaches it"))
}

///|
test "an unreachable function that prints is kept" {
  let plan = plan_of(
    "fn noisy() -> Int {\n  raise Failure\n}\n\nfn main {\n  1\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "`noisy`: it may have side effects"))
}

///|
test "an unreachable function that writes a field is kept" {
  let plan = plan_of(
    "struct Box {\n  mut v : Int\n}\n\nfn bump(b : Box) -> Unit {\n  b.v = 1\n}\n\nfn main {\n  1\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "`bump`: it may have side effects"))
}

///|
test "an unreachable wrapper around an impure function is kept" {
  let plan = plan_of(
    "fn noisy() -> Int {\n  raise Failure\n}\n\nfn wrapper() -> Int {\n  noisy()\n}\n\nfn main {\n  1\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "`wrapper`: it may have side effects"))
}

///|
test "an unresolved call boundary disables function removal" {
  // `println` has no declaration in the package, so `src/roots` records a
  // boundary. The private function looks unreachable and pure, but a call the
  // graph cannot attribute could reach it, so nothing may be removed.
  let plan = plan_of(
    "fn orphan() -> Int {\n  7\n}\n\nfn main {\n  println(1)\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "function removal disabled"))
  assert_true(proof_has(plan, "boundary:"))
}

///|
test "a trailing directive suppresses a dead binding" {
  let plan = plan_of(
    "fn keep() -> Int {\n  let unused = 1 // moon-slice: ignore dead-store\n  7\n}\n\nfn main {\n  keep()\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "suppressed by a directive"))
}

///|
test "a standalone directive covers the next code line" {
  let plan = plan_of(
    "fn keep() -> Int {\n  // moon-slice: ignore\n  let unused = 1\n  7\n}\n\nfn main {\n  keep()\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "suppressed by a directive"))
}

///|
test "a directive naming another rule does not suppress the binding" {
  let plan = plan_of(
    "fn keep() -> Int {\n  let unused = 1 // moon-slice: ignore unreachable-code\n  7\n}\n\nfn main {\n  keep()\n}\n",
  )
  assert_eq(edits_text(plan), "2-2")
}

///|
test "a directive suppresses an unreachable function" {
  let plan = plan_of(
    "// moon-slice: ignore[unused-function]\nfn orphan() -> Int {\n  7\n}\n\nfn main {\n  1\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "`orphan`: suppressed by a directive"))
}

///|
test "a public function is never removed" {
  let plan = plan_of(
    "pub fn api() -> Int {\n  7\n}\n\nfn main {\n  1\n}\n",
  )
  assert_eq(edits_text(plan), "")
}

///|
test "a used binding is not reported in the first place" {
  let plan = plan_of(
    "fn keep() -> Int {\n  let used = 1\n  used\n}\n\nfn main {\n  keep()\n}\n",
  )
  assert_eq(edits_text(plan), "")
}

///|
test "a reassigned binding is kept even when its first write is dead" {
  let plan = plan_of(
    "fn keep() -> Int {\n  let mut cache = 1\n  cache = 2\n  cache\n}\n\nfn main {\n  keep()\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "read or redefined elsewhere"))
}

///|
test "a dead binding inside an unreachable function collapses into one edit" {
  let plan = plan_of(
    "fn orphan() -> Int {\n  let spare = 1\n  7\n}\n\nfn main {\n  1\n}\n",
  )
  assert_eq(edits_text(plan), "1-4")
}

///|
test "a dead assignment is reported but not removed" {
  let plan = plan_of(
    "fn f() -> Int {\n  let mut cache = 1\n  cache = 2\n  cache = 3\n  cache = cache + 4\n  let result = cache * 2\n  return result\n}\n\nfn main {\n  f()\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "only unused `let` bindings are removed"))
}

///|
test "two statements on one line: only the dead one is removed" {
  // `a` is dead and `b` is used. The edit must be a column span, not the whole
  // line, or deleting `let a` would take `let b` with it.
  let source = "fn keep() -> Int {\n  let a = 1; let b = 2\n  b\n}\n\nfn main {\n  keep()\n}\n"
  let plan = plan_of(source)
  assert_eq(edits_text(plan), "2-2")
  let edit = only_edit(plan)
  assert_eq(edit.start_line, 2)
  assert_eq(edit.end_line, 2)
  assert_eq(edit.start_col, 3)
  assert_eq(edit.end_col, 14)
  assert_eq(
    @refactor.apply_edits(source, plan.edits),
    "fn keep() -> Int {\n  let b = 2\n  b\n}\n\nfn main {\n  keep()\n}\n",
  )
  let diff = @refactor.to_unified_diff("p.mbt", source, plan.edits)
  assert_true(diff.contains("-  let a = 1; let b = 2\n"))
  assert_true(diff.contains("+  let b = 2\n"))
}

///|
test "the unified diff has the standard header, hunk and deletion line" {
  let source = "fn f() -> Int {\n  let a = 1\n  let b = 2\n  a\n}\n"
  let edits = [@refactor.Edit::lines("p.mbt", 3, 3, "r")]
  let diff = @refactor.to_unified_diff("p.mbt", source, edits)
  let expected = "--- a/p.mbt\n" +
    "+++ b/p.mbt\n" +
    "@@ -1,5 +1,4 @@\n" +
    " fn f() -> Int {\n" +
    "   let a = 1\n" +
    "-  let b = 2\n" +
    "   a\n" +
    " }\n"
  assert_eq(diff, expected)
}

///|
test "distant deletions become separate hunks" {
  let source = "fn f() -> Int {\n  let line1 = 1\n  let line2 = 2\n  let line3 = 3\n  let line4 = 4\n  let line5 = 5\n  let line6 = 6\n  let line7 = 7\n  let line8 = 8\n  let line9 = 9\n  0\n}\n"
  let edits = [
    @refactor.Edit::lines("p.mbt", 2, 2, "r"),
    @refactor.Edit::lines("p.mbt", 11, 11, "r"),
  ]
  let diff = @refactor.to_unified_diff("p.mbt", source, edits)
  let mut hunks = 0
  for line in diff.split("\n") {
    if line.has_prefix("@@ ") {
      hunks = hunks + 1
    }
  }
  assert_eq(hunks, 2)
  assert_true(diff.contains("-  let line1 = 1\n"))
  assert_true(diff.contains("-  0\n"))
}

///|
test "a plan with no edits has an empty diff" {
  let source = "fn f() -> Int {\n  1\n}\n"
  assert_eq(@refactor.to_unified_diff("p.mbt", source, []), "")
}

///|
test "apply_edits removes exactly the edited range" {
  let source = "fn f() -> Int {\n  let a = 1\n  let b = 2\n  a\n}\n"
  let edits = [@refactor.Edit::lines("p.mbt", 3, 3, "r")]
  assert_eq(
    @refactor.apply_edits(source, edits),
    "fn f() -> Int {\n  let a = 1\n  a\n}\n",
  )
}

///|
test "verify accepts a removal that exposes no new finding" {
  let source = "fn f() -> Int {\n  let a = 1\n  let b = 2\n  a\n}\n"
  let edits = [@refactor.Edit::lines("p.mbt", 3, 3, "r")]
  let files = [@refactor.SourceFile::{ path: "p.mbt", source }]
  assert_eq(@refactor.verify("p.mbt", source, edits, files), [])
}

///|
test "verify rejects a removal that makes another binding dead" {
  let source = "fn f() -> Int {\n  let a = 1\n  let b = a + 1\n  b\n}\n"
  let edits = [@refactor.Edit::lines("p.mbt", 3, 3, "r")]
  let files = [@refactor.SourceFile::{ path: "p.mbt", source }]
  let problems = @refactor.verify("p.mbt", source, edits, files)
  assert_eq(problems.length(), 1)
  assert_true(problems[0].contains("new dead-store finding"))
}

///|
test "verify re-runs reachability and rejects an edit that orphans a function" {
  // `helper` is reachable only through the dead binding's initializer. Removing
  // the binding would leave it unreachable, so the statement-level check alone
  // would (wrongly) accept the plan; the roots check must refuse it.
  let source = "fn helper() -> Int {\n  1\n}\n\nfn keep() -> Int {\n  let spare = helper()\n  7\n}\n\nfn main {\n  keep()\n}\n"
  let plan = plan_of(source)
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "would become unreachable from every root"))
  assert_true(proof_has(plan, "dropped all"))
}

///|
test "writing a plan and planning again yields no further edits" {
  let source = "fn keep(x : Int) -> Int {\n  let unused = 1\n  x\n}\n\nfn main {\n  keep(1)\n}\n"
  let first = plan_of(source)
  assert_eq(edits_text(first), "2-2")
  let after = @refactor.apply_edits(source, first.edits)
  let second = @refactor.plan_package([
    @refactor.SourceFile::{ path: "p.mbt", source: after },
  ])
  assert_eq(edits_text(second), "")
}

///|
test "the JSON plan keeps the wire field names and escapes text" {
  let plan = @refactor.RemovalPlan::{
    edits: [
      @refactor.Edit::{
        file: "a.mbt",
        start_line: 2,
        start_col: 3,
        end_line: 3,
        end_col: 4,
        reason: "quote \" and backslash \\",
      },
    ],
    proof: ["kept"],
  }
  assert_eq(
    @refactor.to_json(plan),
    "{\"edits\":[{\"file\":\"a.mbt\",\"start_line\":2,\"start_col\":3,\"end_line\":3,\"end_col\":4,\"reason\":\"quote \\\" and backslash \\\\\"}],\"proof\":[\"kept\"]}",
  )
}

///|
test "plan_file restricts edits to the requested file" {
  let a = "fn keep_a() -> Int {\n  let x = 1\n  7\n}\n\nfn main {\n  keep_a()\n  keep_b()\n}\n"
  let b = "fn keep_b() -> Int {\n  let y = 2\n  8\n}\n"
  let package_files = [
    @refactor.SourceFile::{ path: "a.mbt", source: a },
    @refactor.SourceFile::{ path: "b.mbt", source: b },
  ]
  let plan = @refactor.plan_file(
    @refactor.SourceFile::{ path: "b.mbt", source: b },
    package_files,
  )
  assert_eq(plan.edits.length(), 1)
  assert_eq(plan.edits[0].file, "b.mbt")
  assert_eq(plan.edits[0].start_line, 2)
}

///|
test "the same package analysed as a whole plans both files" {
  let a = "fn keep_a() -> Int {\n  let x = 1\n  7\n}\n\nfn main {\n  keep_a()\n  keep_b()\n}\n"
  let b = "fn keep_b() -> Int {\n  let y = 2\n  8\n}\n"
  let plan = plan_files([
    @refactor.SourceFile::{ path: "a.mbt", source: a },
    @refactor.SourceFile::{ path: "b.mbt", source: b },
  ])
  assert_eq(plan.edits.length(), 2)
  assert_eq(plan.edits[0].file, "a.mbt")
  assert_eq(plan.edits[1].file, "b.mbt")
}

///|
test "merge_plans concatenates proof and normalises nested edits" {
  let outer = @refactor.RemovalPlan::{
    edits: [@refactor.Edit::lines("a.mbt", 1, 5, "fn")],
    proof: ["outer"],
  }
  let inner = @refactor.RemovalPlan::{
    edits: [@refactor.Edit::lines("a.mbt", 2, 3, "let")],
    proof: ["inner"],
  }
  let merged = @refactor.merge_plans([outer, inner])
  assert_eq(merged.edits.length(), 1)
  assert_eq(merged.edits[0].reason, "fn")
  assert_eq(merged.proof, ["outer", "inner"])
}

///|
test "a file with parser diagnostics yields no edits" {
  let plan = plan_of("fn broken( {\n  let x =\n}\n")
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "parser diagnostic"))
}

///|
test "a let binding hidden in a multi-line initializer is read correctly" {
  let plan = plan_of(
    "fn keep() -> Int {\n  let spare = add(\n    1,\n    2,\n  )\n  7\n}\n\nfn add(a : Int, b : Int) -> Int {\n  a + b\n}\n\nfn main {\n  add(1, 2)\n  keep()\n}\n",
  )
  assert_eq(edits_text(plan), "2-5")
  assert_true(proof_has(plan, "remove dead binding `spare`"))
}

///|
test "a dot call on an unknown receiver type is not treated as pure" {
  // `norm` is a pure method of `Point`, but here it is called on an `Int`.
  // Matching the bare method name would call the initializer pure and delete a
  // call the analysis cannot type; receiver resolution must keep it.
  let plan = plan_of(
    "struct Point {\n  v : Int\n}\n\nimpl Point with norm(self : Point) -> Int {\n  self.v\n}\n\nfn keep(x : Int) -> Int {\n  let spare = x.norm()\n  7\n}\n\nfn main {\n  keep(1)\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "`spare`"))
  assert_true(proof_has(plan, "does not prove pure"))
}

///|
test "a dot call on a resolved receiver type is proved pure and removed" {
  let plan = plan_of(
    "struct Point {\n  v : Int\n}\n\nimpl Point with norm(self : Point) -> Int {\n  self.v\n}\n\nfn keep(point : Point) -> Int {\n  let spare = point.norm()\n  7\n}\n\nfn use_norm(p : Point) -> Int {\n  p.norm()\n}\n\nfn main {\n  keep(Point::{ v: 1 })\n  use_norm(Point::{ v: 2 })\n}\n",
  )
  assert_eq(edits_text(plan), "10-10")
}

///|
test "a dot call on a resolved receiver with an impure method is kept" {
  let plan = plan_of(
    "struct Point {\n  mut v : Int\n}\n\nimpl Point with bump(self : Point) -> Int {\n  self.v = self.v + 1\n  self.v\n}\n\nfn keep(point : Point) -> Int {\n  let spare = point.bump()\n  7\n}\n\nfn main {\n  keep(Point::{ v: 1 })\n}\n",
  )
  assert_eq(edits_text(plan), "")
  assert_true(proof_has(plan, "`spare`"))
}

///|
test "plan_dead_bindings accepts a caller-computed Program and dead set" {
  let source = "fn keep(x : Int) -> Int {\n  let unused = 1\n  x\n}\n\nfn main {\n  keep(1)\n}\n"
  let program = @parser_adapter.parse_source(source, "p.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let dead = @query.dead_nodes(program, defuse)
  assert_eq(dead.length(), 1)
  let plan = @refactor.plan_dead_bindings(
    program,
    dead,
    @refactor.SourceFile::{ path: "p.mbt", source },
    @suppress.parse(source),
    [@refactor.SourceFile::{ path: "p.mbt", source }],
  )
  assert_eq(edits_text(plan), "2-2")
}
