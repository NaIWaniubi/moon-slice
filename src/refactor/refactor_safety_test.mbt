// Regression tests for the second review round: transitive purity, package-wide
// plan verification, and the restored CLI assertion set (see cli_smoke.sh).
//
// Each test is a small package; the assertion is on the plan's edits and on the
// proof line that records why a candidate was refused.

///|
fn plan_one_file(source : String) -> @refactor.RemovalPlan {
  @refactor.plan_package([
    @refactor.SourceFile::{ path: "p.mbt", source },
  ])
}

///|
fn plan_package_files(files : Array[@refactor.SourceFile]) -> @refactor.RemovalPlan {
  @refactor.plan_package(files)
}

///|
fn contains_line(plan : @refactor.RemovalPlan, needle : String) -> Bool {
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
fn edit_summary(plan : @refactor.RemovalPlan) -> String {
  let parts : Array[String] = []
  for edit in plan.edits {
    parts.push(
      edit.file +
      ":" +
      edit.start_line.to_string() +
      "-" +
      edit.end_line.to_string(),
    )
  }
  parts.join(",")
}

///|
test "a callee with an external call is not trusted as pure" {
  // `leaf` calls a name the package does not declare. `@sidefx` calls that
  // harmless because it cannot see behind it, but the summary's `calls` list
  // still names it; purity must walk that list and reject the chain.
  let plan = plan_one_file(
    "fn leaf() -> Int {\n  external_thing()\n}\n\nfn mid() -> Int {\n  leaf()\n}\n\nfn keep() -> Int {\n  let spare = mid()\n  7\n}\n\nfn main {\n  mid()\n  keep()\n}\n",
  )
  assert_eq(edit_summary(plan), "")
  assert_true(contains_line(plan, "`spare`"))
  assert_true(contains_line(plan, "does not prove pure"))
  assert_true(contains_line(plan, "mid"))
}

///|
test "a callee with an external call at depth two is rejected transitively" {
  let plan = plan_one_file(
    "fn leaf() -> Int {\n  @other.compute()\n}\n\nfn mid() -> Int {\n  leaf()\n}\n\nfn keep() -> Int {\n  let spare = mid()\n  7\n}\n\nfn main {\n  mid()\n  keep()\n}\n",
  )
  assert_eq(edit_summary(plan), "")
  assert_true(contains_line(plan, "`spare`"))
}

///|
test "a callee whose own body is clean stays removable" {
  let plan = plan_one_file(
    "fn leaf() -> Int {\n  41 + 1\n}\n\nfn mid() -> Int {\n  leaf()\n}\n\nfn keep() -> Int {\n  let spare = mid()\n  7\n}\n\nfn main {\n  mid()\n  keep()\n}\n",
  )
  assert_eq(edit_summary(plan), "p.mbt:10-10")
}

///|
test "two files dropping their last mention of one function reject the package plan" {
  // `helper` is reachable only through the two dead bindings. Each file's edit
  // is safe alone (the other mention keeps the function alive); together they
  // orphan it, so the package-wide re-analysis must reject both.
  let a = "fn keep_a() -> Int {\n  let spare_a = helper()\n  1\n}\n"
  let b = "fn keep_b() -> Int {\n  let spare_b = helper()\n  2\n}\n\nfn helper() -> Int {\n  3\n}\n\nfn main {\n  keep_a()\n  keep_b()\n}\n"
  let plan = plan_package_files([
    @refactor.SourceFile::{ path: "a.mbt", source: a },
    @refactor.SourceFile::{ path: "b.mbt", source: b },
  ])
  assert_eq(edit_summary(plan), "")
  assert_true(contains_line(plan, "would become unreachable from every root"))
  assert_true(contains_line(plan, "dropped all"))
}

///|
test "the same two file edits are accepted when a third mention keeps the function alive" {
  let a = "fn keep_a() -> Int {\n  let spare_a = helper()\n  1\n}\n"
  let b = "fn keep_b() -> Int {\n  let spare_b = helper()\n  2\n}\n\nfn helper() -> Int {\n  3\n}\n\nfn main {\n  keep_a()\n  keep_b()\n  helper()\n}\n"
  let plan = plan_package_files([
    @refactor.SourceFile::{ path: "a.mbt", source: a },
    @refactor.SourceFile::{ path: "b.mbt", source: b },
  ])
  assert_eq(edit_summary(plan), "a.mbt:2-2,b.mbt:2-2")
}
