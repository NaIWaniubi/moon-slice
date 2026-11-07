// Regression tests for the third review round: free-call shadowing and exact
// byte preservation in `apply_edits`.
//
// A free call whose name is bound in the enclosing function (a parameter, a
// local `let`, a closure parameter, ...) runs that value, not the package
// function of the same name. Treating it as the pure package function would
// delete a call that may invoke an impure closure.

///|
fn plan_one_source(source : String) -> @refactor.RemovalPlan {
  @refactor.plan_package([
    @refactor.SourceFile::{ path: "p.mbt", source },
  ])
}

///|
fn proof_contains(plan : @refactor.RemovalPlan, needle : String) -> Bool {
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
fn edit_ranges(plan : @refactor.RemovalPlan) -> String {
  let parts : Array[String] = []
  for edit in plan.edits {
    parts.push(edit.start_line.to_string() + "-" + edit.end_line.to_string())
  }
  parts.join(",")
}

///|
test "a parameter shadowing a pure function makes the initializer impure" {
  // Without the shadow check, `compute(1)` would be matched to the package's
  // pure free function `compute` and deleted; the parameter may hold any
  // closure, including an impure one.
  let plan = plan_one_source(
    "fn compute(x : Int) -> Int {\n  x + 1\n}\n\nfn keep(compute : (Int) -> Int) -> Int {\n  let spare = compute(1)\n  7\n}\n\nfn main {\n  keep(compute)\n}\n",
  )
  assert_eq(edit_ranges(plan), "")
  assert_true(proof_contains(plan, "`spare`"))
  assert_true(proof_contains(plan, "does not prove pure"))
}

///|
test "a local let shadowing a pure function makes the initializer impure" {
  let plan = plan_one_source(
    "fn helper() -> Int {\n  1\n}\n\nfn keep() -> Int {\n  let helper = fn() { 2 }\n  let spare = helper()\n  7\n}\n\nfn main {\n  helper()\n  keep()\n}\n",
  )
  assert_eq(edit_ranges(plan), "")
  assert_true(proof_contains(plan, "`spare`"))
}

///|
test "an unshadowed pure free call is still removable" {
  let plan = plan_one_source(
    "fn helper() -> Int {\n  1\n}\n\nfn keep() -> Int {\n  let spare = helper()\n  7\n}\n\nfn main {\n  helper()\n  keep()\n}\n",
  )
  assert_eq(edit_ranges(plan), "6-6")
}

///|
test "apply_edits preserves CRLF line endings" {
  let source = "fn f() -> Int {\r\n  let a = 1\r\n  let b = 2\r\n  a\r\n}\r\n"
  let edits = [@refactor.Edit::lines("p.mbt", 3, 3, "r")]
  assert_eq(
    @refactor.apply_edits(source, edits),
    "fn f() -> Int {\r\n  let a = 1\r\n  a\r\n}\r\n",
  )
}

///|
test "apply_edits preserves a missing trailing newline" {
  let source = "fn f() -> Int {\n  let a = 1\n  let b = 2\n  a\n}"
  let edits = [@refactor.Edit::lines("p.mbt", 3, 3, "r")]
  assert_eq(
    @refactor.apply_edits(source, edits),
    "fn f() -> Int {\n  let a = 1\n  a\n}",
  )
}

///|
test "a precise edit keeps CRLF and only rewrites the target bytes" {
  let source = "fn f() -> Int {\r\n  let a = 1; let b = 2\r\n  b\r\n}\r\n"
  let edits = [
    @refactor.Edit::{
      file: "p.mbt",
      start_line: 2,
      start_col: 3,
      end_line: 2,
      end_col: 14,
      reason: "r",
    },
  ]
  assert_eq(
    @refactor.apply_edits(source, edits),
    "fn f() -> Int {\r\n  let b = 2\r\n  b\r\n}\r\n",
  )
}

///|
test "apply_edits leaves a file untouched when there are no edits" {
  let source = "fn f() -> Int {\r\n  1\r\n}"
  assert_eq(@refactor.apply_edits(source, []), source)
}
