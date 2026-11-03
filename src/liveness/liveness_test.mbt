// Tests for the package-level liveness pass. Each case is a whole package: the
// point of the pass is that a private function's callers may live in another
// file, so a test that only looks at one file would not prove anything.

///|
fn facts(files : Array[(String, String)]) -> Array[@liveness.FileFacts] {
  files.map(fn(pair) { @liveness.collect(pair.0, pair.1) })
}

///|
fn names(found : Array[@liveness.UnusedFn]) -> Array[String] {
  found.map(fn(item) { item.name })
}

///|
test "a private function nobody calls is reported" {
  let pkg = facts([
    ("a.mbt", "fn helper() -> Int {\n  1\n}\n\nfn caller() -> Int {\n  helper()\n}\n\nfn orphan() -> Int {\n  0\n}\n\nfn main {\n  println(caller())\n}\n"),
  ])
  let found = @liveness.unused_functions(pkg)
  assert_eq(names(found), ["orphan"])
  assert_eq(found[0].path, "a.mbt")
  assert_eq(found[0].line, 9)
}

///|
test "a chain that ends at an entry point is alive" {
  let pkg = facts([
    ("a.mbt", "fn leaf() -> Int {\n  1\n}\n\nfn middle() -> Int {\n  leaf()\n}\n\nfn main {\n  println(middle())\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a public function is API and is never reported" {
  let pkg = facts([
    ("a.mbt", "pub fn exported() -> Int {\n  1\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a caller in a sibling file keeps the function alive" {
  let pkg = facts([
    ("a.mbt", "fn shared() -> Int {\n  1\n}\n"),
    ("b.mbt", "fn use_it() -> Int {\n  shared()\n}\n\nfn main {\n  println(use_it())\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a helper called from a live sibling is alive, its caller is not" {
  let pkg = facts([
    ("a.mbt", "fn shared() -> Int {\n  1\n}\n"),
    ("b.mbt", "fn use_it() -> Int {\n  shared()\n}\n"),
  ])
  assert_eq(names(@liveness.unused_functions(pkg)), ["use_it"])
}

///|
test "a caller in a test block keeps the function alive" {
  let pkg = facts([
    ("a.mbt", "fn helper() -> Int {\n  1\n}\n"),
    ("a_wbtest.mbt", "test \"helper works\" {\n  assert_eq(helper(), 1)\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a name mentioned in a comment is treated as a reference" {
  let pkg = facts([
    ("a.mbt", "// helper is kept for the migration guide\nfn helper() -> Int {\n  1\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "main is an entry point even when nothing calls it" {
  let pkg = facts([
    ("a.mbt", "fn main {\n  println(1)\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a recursive function counts its own reference" {
  // Self-recursion is a reference, so this pass stays silent. That is the
  // conservative direction: a function that only calls itself is dead, but
  // proving it needs a stronger argument than a name scan.
  let pkg = facts([
    ("a.mbt", "fn rec(n : Int) -> Int {\n  if n <= 0 { 0 } else { rec(n - 1) }\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "an unparsable file suppresses the whole package" {
  let pkg = facts([
    ("a.mbt", "fn orphan() -> Int {\n  0\n}\n"),
    ("broken.mbt", "fn broken( {\n  let x =\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a declaration without a body is not a candidate" {
  let pkg = facts([
    ("a.mbt", "fn declared() -> Int\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "an inherent impl method nobody references is reported" {
  // `impl T with fn m` cannot be reached by trait dispatch, so an unmentioned
  // one is as dead as an unused free function.
  let pkg = facts([
    ("a.mbt", "struct T {\n  v : Int\n}\n\nimpl T with bump(self : T) -> Int {\n  self.v + 1\n}\n"),
  ])
  assert_eq(names(@liveness.unused_functions(pkg)), ["bump"])
}

///|
test "a trait impl method is never reported" {
  // `impl Show for T` is reached through the trait, where the call site names
  // the trait, not the method.
  let pkg = facts([
    ("a.mbt", "struct T {\n  v : Int\n}\n\nimpl Show for T with show(self : T) -> String {\n  \"t\"\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a method called through a receiver keeps its declaration alive" {
  let pkg = facts([
    ("a.mbt", "struct T {\n  v : Int\n}\n\nimpl T with bump(self : T) -> Int {\n  self.v + 1\n}\n"),
    ("b.mbt", "fn use(t : T) -> Int {\n  t.bump()\n}\n"),
  ])
  // `use` itself is unreferenced; `bump` is the one that must stay alive.
  assert_false(names(@liveness.unused_functions(pkg)).contains("bump"))
}

///|
test "a method called as T::m keeps its declaration alive" {
  let pkg = facts([
    ("a.mbt", "struct T {\n  v : Int\n}\n\nimpl T with bump(self : T) -> Int {\n  self.v + 1\n}\n"),
    ("b.mbt", "fn use(t : T) -> Int {\n  T::bump(t)\n}\n"),
  ])
  assert_false(names(@liveness.unused_functions(pkg)).contains("bump"))
}

///|
test "findings come back in file and line order" {
  let pkg = facts([
    ("b.mbt", "fn second() -> Int {\n  2\n}\n"),
    ("a.mbt", "fn first() -> Int {\n  1\n}\n"),
  ])
  assert_eq(names(@liveness.unused_functions(pkg)), ["first", "second"])
}

///|
test "a method declared as Type::name is reported when nothing references it" {
  let pkg = facts([
    ("a.mbt", "enum D {\n  End\n}\n\nfn D::describe(self : D) -> Int {\n  1\n}\n"),
  ])
  assert_eq(names(@liveness.unused_functions(pkg)), ["describe"])
}

///|
test "init is an entry point even when nothing calls it" {
  let pkg = facts([
    ("setup_test.mbt", "fn init {\n  println(1)\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a name used only inside an interpolation is a reference" {
  let pkg = facts([
    ("a.mbt", "fn helper() -> Int {\n  1\n}\n\nfn show() -> String {\n  \"v=\\{helper()}\"\n}\n"),
  ])
  // `show` has no caller; `helper` is read by the interpolation.
  assert_eq(names(@liveness.unused_functions(pkg)), ["show"])
}

///|
test "a priv function is still a candidate" {
  let pkg = facts([
    ("a.mbt", "priv fn hidden() -> Int {\n  1\n}\n"),
  ])
  assert_eq(names(@liveness.unused_functions(pkg)), ["hidden"])
}

///|
test "a top-level let that calls a function keeps it alive" {
  let pkg = facts([
    ("a.mbt", "fn helper() -> Int {\n  1\n}\n\nlet seed = helper()\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a call from an impl body keeps a free function alive" {
  let pkg = facts([
    ("a.mbt", "fn helper() -> Int {\n  1\n}\n\nstruct T {\n  v : Int\n}\n\nimpl T with bump(self : T) -> Int {\n  helper()\n}\n"),
  ])
  // `bump` itself is unreferenced and now a candidate; the point here is that
  // `helper`, called from its body, is not.
  assert_false(names(@liveness.unused_functions(pkg)).contains("helper"))
}

///|
test "an explicit unused_value opt-out is honoured" {
  let pkg = facts([
    ("a.mbt", "#warnings(\"-unused_value\")\nfn keep_import_alive() -> Unit {\n  ignore(1)\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}

///|
test "a leading underscore marks a binding the author keeps on purpose" {
  let pkg = facts([
    ("a.mbt", "fn _keep_alive() -> Int {\n  1\n}\n\nfn orphan() -> Int {\n  2\n}\n"),
  ])
  assert_eq(names(@liveness.unused_functions(pkg)), ["orphan"])
}

///|
test "an underscore-prefixed method is not reported either" {
  let pkg = facts([
    ("a.mbt", "enum D {\n  End\n}\n\nfn D::_use_debug(self : D) -> Int {\n  1\n}\n"),
  ])
  assert_eq(@liveness.unused_functions(pkg).length(), 0)
}
