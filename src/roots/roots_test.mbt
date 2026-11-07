// Tests for reachability roots and the explanations. Every case is a whole
// package: roots are a package-level question, and the point of the pass is
// that a caller may live in a sibling file.
//
// The consistency tests at the end compare the roots answer with
// `src/liveness.unused_functions` on the same input. The last case is the one
// place they deliberately differ: reachability is transitive, a lexical
// mention scan is not.

///|
fn facts(files : Array[(String, String)]) -> Array[@liveness.FileFacts] {
  files.map(fn(pair) { @liveness.collect(pair.0, pair.1) })
}

///|
fn analyze(
  files : Array[(String, String)],
  entries? : Array[String] = [],
) -> @roots.Reachability {
  @roots.analyze(facts(files), entries~)
}

///|
fn unreachable_names(result : @roots.Reachability) -> Array[String] {
  result.unreachable_fns.map(fn(item) { item.name })
}

///|
fn unused_names(files : Array[(String, String)]) -> Array[String] {
  @liveness.unused_functions(facts(files)).map(fn(item) { item.name })
}

///|
fn root_named(result : @roots.Reachability, name : String) -> @roots.Root? {
  let mut found : @roots.Root? = None
  for root in result.roots {
    if root.name == name {
      found = Some(root)
    }
  }
  found
}

///|
fn expect_root(
  result : @roots.Reachability,
  name : String,
) -> @roots.Root {
  match root_named(result, name) {
    Some(root) => root
    None => abort("expected a root named `" + name + "`")
  }
}

///|
fn path_names(path : @roots.LivePath) -> Array[String] {
  path.steps.map(fn(step) { step.function_name })
}

///|
fn expect_path(
  files : Array[(String, String)],
  name : String,
) -> @roots.LivePath {
  match @roots.explain_live(facts(files), name) {
    Some(path) => path
    None => abort("expected `" + name + "` to be live")
  }
}

///|
fn expect_dead(
  files : Array[(String, String)],
  name : String,
) -> @roots.DeadExplanation {
  match @roots.explain_dead(facts(files), name) {
    Some(explanation) => explanation
    None => abort("expected `" + name + "` to be dead")
  }
}

///|
fn any_contains(lines : Array[String], needle : String) -> Bool {
  let mut found = false
  for line in lines {
    if line.contains(needle) {
      found = true
    }
  }
  found
}

// ---------------------------------------------------------------------------
// Root classification
// ---------------------------------------------------------------------------

///|
test "a public function is a public-api root" {
  let result = analyze([("a.mbt", "pub fn api() -> Int {\n  1\n}\n")])
  let root = expect_root(result, "api")
  assert_eq(root.kind, @roots.RootKind::PublicApi)
  assert_eq(root.path, "a.mbt")
  assert_eq(root.line, 1)
  assert_eq(root.site, "a.mbt:1")
  assert_true(result.is_reachable("api"))
}

///|
test "main is an entry-point root" {
  let result = analyze([("a.mbt", "fn main {\n  println(1)\n}\n")])
  let root = expect_root(result, "main")
  assert_eq(root.kind, @roots.RootKind::EntryPoint)
  assert_eq(root.line, 1)
  assert_true(result.is_reachable("main"))
}

///|
test "init is an entry-point root" {
  let result = analyze([("setup_test.mbt", "fn init {\n  println(1)\n}\n")])
  let root = expect_root(result, "init")
  assert_eq(root.kind, @roots.RootKind::EntryPoint)
  assert_true(result.is_reachable("init"))
}

///|
test "a function called from a test block is a test-call root" {
  let result = analyze([
    ("a.mbt", "fn helper() -> Int {\n  1\n}\n"),
    ("a_test.mbt", "test \"t\" {\n  assert_eq(helper(), 1)\n}\n"),
  ])
  let root = expect_root(result, "helper")
  assert_eq(root.kind, @roots.RootKind::TestCall)
  // The root is discovered at the test call site, not at the declaration.
  assert_eq(root.path, "a_test.mbt")
  assert_eq(root.line, 2)
  assert_eq(root.site, "a_test.mbt:2")
  assert_true(result.is_reachable("helper"))
}

///|
test "a trait impl method is a trait-impl root" {
  let result = analyze([
    (
      "a.mbt",
      "struct T {\n  v : Int\n}\n\nimpl Show for T with show(self : T) -> String {\n  \"t\"\n}\n",
    ),
  ])
  let root = expect_root(result, "show")
  assert_eq(root.kind, @roots.RootKind::TraitImpl)
  assert_eq(root.line, 5)
  assert_true(result.is_reachable("show"))
}

///|
test "an explicit entry keeps a private function alive" {
  let files : Array[(String, String)] = [
    ("a.mbt", "fn callback() -> Int {\n  1\n}\n"),
  ]
  let without = analyze(files)
  assert_eq(unreachable_names(without), ["callback"])
  let with_entry = analyze(files, entries=["callback"])
  let root = expect_root(with_entry, "callback")
  assert_eq(root.kind, @roots.RootKind::Explicit)
  assert_eq(root.path, "a.mbt")
  assert_eq(root.site, "configuration")
  assert_eq(unreachable_names(with_entry), [])
}

///|
test "a call from a top-level let is a top-level root" {
  let result = analyze([
    ("a.mbt", "fn seed() -> Int {\n  1\n}\n\nlet value = seed()\n"),
  ])
  let root = expect_root(result, "seed")
  assert_eq(root.kind, @roots.RootKind::TopLevel)
  assert_eq(root.site, "a.mbt:5")
  assert_true(result.is_reachable("seed"))
}

///|
test "a function can be a root for more than one reason" {
  let result = analyze([
    ("a.mbt", "pub fn api() -> Int {\n  1\n}\n"),
    ("a_test.mbt", "test \"t\" {\n  assert_eq(api(), 1)\n}\n"),
  ])
  assert_eq(result.roots.length(), 2)
  let mut saw_public = false
  let mut saw_test = false
  for root in result.roots {
    if root.kind == @roots.RootKind::PublicApi {
      saw_public = true
    }
    if root.kind == @roots.RootKind::TestCall {
      saw_test = true
    }
  }
  assert_true(saw_public)
  assert_true(saw_test)
}

///|
test "a package with no roots reports every private candidate" {
  let result = analyze([
    ("a.mbt", "fn alpha() -> Int {\n  1\n}\n\nfn beta() -> Int {\n  2\n}\n"),
  ])
  assert_eq(result.roots.length(), 0)
  assert_eq(unreachable_names(result), ["alpha", "beta"])
}

// ---------------------------------------------------------------------------
// Transitive reachability
// ---------------------------------------------------------------------------

///|
test "a chain from main is reachable through the middle function" {
  let result = analyze([
    (
      "a.mbt",
      "fn leaf() -> Int {\n  1\n}\n\nfn middle() -> Int {\n  leaf()\n}\n\nfn main {\n  println(middle())\n}\n",
    ),
  ])
  assert_true(result.is_reachable("main"))
  assert_true(result.is_reachable("middle"))
  assert_true(result.is_reachable("leaf"))
  assert_eq(unreachable_names(result), [])
}

///|
test "reachability crosses file boundaries" {
  let result = analyze([
    ("a.mbt", "fn shared() -> Int {\n  1\n}\n"),
    ("b.mbt", "fn use_it() -> Int {\n  shared()\n}\n\nfn main {\n  println(use_it())\n}\n"),
  ])
  assert_true(result.is_reachable("shared"))
  assert_true(result.is_reachable("use_it"))
  assert_eq(unreachable_names(result), [])
}

///|
test "a public root expands to its private callees" {
  let result = analyze([
    ("a.mbt", "pub fn api() -> Int {\n  helper()\n}\n\nfn helper() -> Int {\n  2\n}\n"),
  ])
  assert_true(result.is_reachable("helper"))
  assert_eq(unreachable_names(result), [])
}

///|
test "a test-call root expands transitively" {
  let result = analyze([
    ("a.mbt", "fn leaf() -> Int {\n  1\n}\n\nfn helper() -> Int {\n  leaf()\n}\n"),
    ("a_test.mbt", "test \"t\" {\n  assert_eq(helper(), 1)\n}\n"),
  ])
  assert_true(result.is_reachable("helper"))
  assert_true(result.is_reachable("leaf"))
  assert_eq(unreachable_names(result), [])
}

///|
test "a receiver call is an edge to the declared method" {
  let result = analyze([
    (
      "a.mbt",
      "struct Point {\n  v : Int\n}\n\nimpl Point with norm(self : Point) -> Int {\n  self.v\n}\n\nfn main {\n  let p : Point = { v: 1 }\n  println(p.norm())\n}\n",
    ),
  ])
  assert_true(result.is_reachable("norm"))
  assert_eq(unreachable_names(result), [])
}

///|
test "a T::m call is an edge to the declared method" {
  let result = analyze([
    (
      "a.mbt",
      "struct Box {\n  v : Int\n}\n\nimpl Box with get(self : Box) -> Int {\n  self.v\n}\n\nfn main {\n  let b : Box = { v: 1 }\n  println(Box::get(b))\n}\n",
    ),
  ])
  assert_true(result.is_reachable("get"))
  assert_eq(unreachable_names(result), [])
}

///|
test "a receiver call in a test block keeps the method alive" {
  let result = analyze([
    (
      "a.mbt",
      "struct Point {\n  v : Int\n}\n\nimpl Point with norm(self : Point) -> Int {\n  self.v\n}\n",
    ),
    (
      "a_test.mbt",
      "test \"m\" {\n  let p : Point = { v: 1 }\n  assert_eq(p.norm(), 1)\n}\n",
    ),
  ])
  assert_true(result.is_reachable("norm"))
}

///|
test "a cycle reachable from main keeps every participant alive" {
  let result = analyze([
    (
      "a.mbt",
      "fn ping(n : Int) -> Int {\n  pong(n)\n}\n\nfn pong(n : Int) -> Int {\n  ping(n)\n}\n\nfn main {\n  println(ping(1))\n}\n",
    ),
  ])
  assert_true(result.is_reachable("ping"))
  assert_true(result.is_reachable("pong"))
  assert_eq(unreachable_names(result), [])
}

///|
test "a cycle with no root is unreachable even though each half references the other" {
  let result = analyze([
    (
      "a.mbt",
      "fn alpha() -> Int {\n  beta()\n}\n\nfn beta() -> Int {\n  alpha()\n}\n",
    ),
  ])
  assert_eq(result.roots.length(), 0)
  assert_eq(unreachable_names(result), ["alpha", "beta"])
}

///|
test "unreachable functions carry their declaration site and are sorted" {
  let result = analyze([
    ("b.mbt", "fn second() -> Int {\n  2\n}\n"),
    ("a.mbt", "fn first() -> Int {\n  1\n}\n"),
  ])
  assert_eq(result.unreachable_fns.length(), 2)
  assert_eq(result.unreachable_fns[0].path, "a.mbt")
  assert_eq(result.unreachable_fns[0].name, "first")
  assert_eq(result.unreachable_fns[0].line, 1)
  assert_eq(result.unreachable_fns[1].path, "b.mbt")
  assert_eq(result.unreachable_fns[1].line, 1)
}

///|
test "public, entry, trait and underscore declarations are not candidates" {
  let result = analyze([
    (
      "a.mbt",
      "struct T {\n  v : Int\n}\n\npub fn api() -> Int {\n  1\n}\n\nfn main {\n  println(api())\n}\n\nimpl Show for T with show(self : T) -> String {\n  \"t\"\n}\n\nfn _kept() -> Int {\n  2\n}\n\nfn orphan() -> Int {\n  3\n}\n",
    ),
  ])
  assert_eq(unreachable_names(result), ["orphan"])
}

///|
test "an unparsable file skips the whole package" {
  let result = analyze([
    ("a.mbt", "fn orphan() -> Int {\n  0\n}\n"),
    ("broken.mbt", "fn broken( {\n  let x =\n}\n"),
  ])
  assert_eq(result.unreachable_fns.length(), 0)
  assert_eq(result.functions, 0)
  assert_true(any_contains(result.boundaries, "package skipped"))
}

///|
test "reachable_names is sorted and complete" {
  let result = analyze([
    (
      "a.mbt",
      "fn leaf() -> Int {\n  1\n}\n\nfn main {\n  println(leaf())\n}\n",
    ),
  ])
  assert_eq(result.reachable_names(), ["leaf", "main"])
}

// ---------------------------------------------------------------------------
// explain_live
// ---------------------------------------------------------------------------

///|
test "explain_live returns the chain with a site for every step" {
  let path = expect_path([
    (
      "a.mbt",
      "fn leaf() -> Int {\n  1\n}\n\nfn middle() -> Int {\n  leaf()\n}\n\nfn main {\n  println(middle())\n}\n",
    ),
  ], "leaf")
  assert_eq(path.steps, [
    @roots.PathStep::{ function_name: "main", path: "a.mbt", line: 9 },
    @roots.PathStep::{ function_name: "middle", path: "a.mbt", line: 10 },
    @roots.PathStep::{ function_name: "leaf", path: "a.mbt", line: 6 },
  ])
}

///|
test "explain_live picks the shortest chain when two exist" {
  let path = expect_path([
    (
      "a.mbt",
      "fn main {\n  println(fast())\n  println(slow2())\n}\n\nfn fast() -> Int {\n  leaf()\n}\n\nfn slow1() -> Int {\n  leaf()\n}\n\nfn slow2() -> Int {\n  slow1()\n}\n\nfn leaf() -> Int {\n  7\n}\n",
    ),
  ], "leaf")
  assert_eq(path_names(path), ["main", "fast", "leaf"])
}

///|
test "explain_live steps carry the file of each call site" {
  let path = expect_path([
    ("a.mbt", "fn shared() -> Int {\n  1\n}\n"),
    ("b.mbt", "fn use_it() -> Int {\n  shared()\n}\n\nfn main {\n  println(use_it())\n}\n"),
  ], "shared")
  assert_eq(path.steps, [
    @roots.PathStep::{ function_name: "main", path: "b.mbt", line: 5 },
    @roots.PathStep::{ function_name: "use_it", path: "b.mbt", line: 6 },
    @roots.PathStep::{ function_name: "shared", path: "b.mbt", line: 2 },
  ])
}

///|
test "a root explains itself in one step" {
  let path = expect_path([
    ("a.mbt", "pub fn api() -> Int {\n  1\n}\n"),
  ], "api")
  assert_eq(path.steps, [
    @roots.PathStep::{ function_name: "api", path: "a.mbt", line: 1 },
  ])
}

///|
test "explain_live follows a receiver edge" {
  let files : Array[(String, String)] = [
    (
      "a.mbt",
      "struct Point {\n  v : Int\n}\n\nimpl Point with norm(self : Point) -> Int {\n  self.v\n}\n\nfn main {\n  let p : Point = { v: 1 }\n  println(p.norm())\n}\n",
    ),
  ]
  let path = expect_path(files, "norm")
  assert_eq(path.steps, [
    @roots.PathStep::{ function_name: "main", path: "a.mbt", line: 9 },
    @roots.PathStep::{ function_name: "norm", path: "a.mbt", line: 11 },
  ])
}

///|
test "explain_live returns none for a dead function" {
  let files : Array[(String, String)] = [
    ("a.mbt", "fn orphan() -> Int {\n  1\n}\n"),
  ]
  assert_eq(@roots.explain_live(facts(files), "orphan"), None)
}

///|
test "explain_live returns none for a name the package does not declare" {
  let files : Array[(String, String)] = [
    ("a.mbt", "fn main {\n  println(1)\n}\n"),
  ]
  assert_eq(@roots.explain_live(facts(files), "missing"), None)
}

// ---------------------------------------------------------------------------
// explain_dead
// ---------------------------------------------------------------------------

///|
test "explain_dead reports no incoming edge" {
  let explanation = expect_dead([
    ("a.mbt", "fn orphan() -> Int {\n  1\n}\n"),
  ], "orphan")
  assert_eq(explanation.function_name, "orphan")
  assert_eq(explanation.path, "a.mbt")
  assert_eq(explanation.line, 1)
  assert_eq(explanation.root_summary.length(), 0)
  assert_true(any_contains(explanation.evidence, "no roots"))
  assert_true(any_contains(explanation.evidence, "no function in the package calls"))
}

///|
test "explain_dead reports incoming edges that all start at unreachable functions" {
  let explanation = expect_dead([
    (
      "a.mbt",
      "fn wrapper() -> Int {\n  orphan()\n}\n\nfn orphan() -> Int {\n  1\n}\n",
    ),
  ], "orphan")
  assert_true(any_contains(explanation.evidence, "incoming edge"))
  assert_true(any_contains(explanation.evidence, "themselves unreachable"))
  assert_true(any_contains(explanation.evidence, "`wrapper`"))
  assert_true(any_contains(explanation.evidence, "a.mbt:2"))
}

///|
test "explain_dead summarizes the root set" {
  let explanation = expect_dead([
    (
      "a.mbt",
      "pub fn api() -> Int {\n  1\n}\n\nfn main {\n  println(api())\n}\n\nfn orphan() -> Int {\n  0\n}\n",
    ),
  ], "orphan")
  assert_eq(explanation.root_summary.length(), 2)
  assert_true(any_contains(explanation.root_summary, "public api: api at a.mbt:1"))
  assert_true(any_contains(explanation.root_summary, "entry point: main at a.mbt:5"))
}

///|
test "explain_dead records the search scope" {
  let explanation = expect_dead([
    (
      "a.mbt",
      "pub fn api() -> Int {\n  1\n}\n\nfn main {\n  println(api())\n}\n\nfn orphan() -> Int {\n  0\n}\n",
    ),
  ], "orphan")
  assert_eq(explanation.searched_files, 1)
  assert_eq(explanation.searched_functions, 3)
}

///|
test "explain_dead lists the unresolved call boundaries" {
  let explanation = expect_dead([
    (
      "a.mbt",
      "fn probe(p : Point) -> Int {\n  println(1)\n  p.missing()\n}\n",
    ),
  ], "probe")
  assert_true(any_contains(explanation.boundaries, "call to `println`"))
  assert_true(any_contains(explanation.boundaries, "unresolved method call `missing()`"))
  assert_true(any_contains(explanation.boundaries, "a.mbt:3"))
}

///|
test "explain_dead returns none for a reachable function" {
  let files : Array[(String, String)] = [
    ("a.mbt", "fn main {\n  println(1)\n}\n"),
  ]
  assert_eq(@roots.explain_dead(facts(files), "main"), None)
}

///|
test "explain_dead returns none for an unknown name" {
  let files : Array[(String, String)] = [
    ("a.mbt", "fn main {\n  println(1)\n}\n"),
  ]
  assert_eq(@roots.explain_dead(facts(files), "ghost"), None)
}

// ---------------------------------------------------------------------------
// Consistency with src/liveness
// ---------------------------------------------------------------------------

///|
test "consistency: a chain plus an orphan" {
  let files : Array[(String, String)] = [
    (
      "a.mbt",
      "fn helper() -> Int {\n  1\n}\n\nfn orphan() -> Int {\n  2\n}\n\nfn main {\n  println(helper())\n}\n",
    ),
  ]
  let unused = unused_names(files)
  let dead = unreachable_names(analyze(files))
  assert_eq(unused, ["orphan"])
  assert_eq(dead, unused)
}

///|
test "consistency: callers split across sibling files" {
  let files : Array[(String, String)] = [
    ("a.mbt", "fn shared() -> Int {\n  1\n}\n\nfn orphan() -> Int {\n  2\n}\n"),
    ("b.mbt", "fn use_it() -> Int {\n  shared()\n}\n\nfn main {\n  println(use_it())\n}\n"),
  ]
  let unused = unused_names(files)
  let dead = unreachable_names(analyze(files))
  assert_eq(unused, ["orphan"])
  assert_eq(dead, unused)
}

///|
test "consistency: a test block is an entry point" {
  let files : Array[(String, String)] = [
    ("a.mbt", "fn helper() -> Int {\n  1\n}\n\nfn orphan() -> Int {\n  2\n}\n"),
    ("a_test.mbt", "test \"t\" {\n  assert_eq(helper(), 1)\n}\n"),
  ]
  let unused = unused_names(files)
  let dead = unreachable_names(analyze(files))
  assert_eq(unused, ["orphan"])
  assert_eq(dead, unused)
}

///|
test "consistency: an unreferenced inherent method" {
  let files : Array[(String, String)] = [
    (
      "a.mbt",
      "struct T {\n  v : Int\n}\n\npub fn api() -> Int {\n  1\n}\n\nimpl T with bump(self : T) -> Int {\n  self.v + 1\n}\n\nfn main {\n  println(api())\n}\n",
    ),
  ]
  let unused = unused_names(files)
  let dead = unreachable_names(analyze(files))
  assert_eq(unused, ["bump"])
  assert_eq(dead, unused)
}

///|
test "consistency: a cycle reached from main" {
  let files : Array[(String, String)] = [
    (
      "a.mbt",
      "fn alpha(n : Int) -> Int {\n  if n <= 0 { 0 } else { beta(n - 1) }\n}\n\nfn beta(n : Int) -> Int {\n  alpha(n)\n}\n\nfn main {\n  println(alpha(3))\n}\n",
    ),
  ]
  let unused = unused_names(files)
  let dead = unreachable_names(analyze(files))
  assert_eq(unused, [])
  assert_eq(dead, unused)
}

///|
test "consistency: a method reached through a receiver" {
  let files : Array[(String, String)] = [
    (
      "a.mbt",
      "struct Point {\n  v : Int\n}\n\nimpl Point with norm(self : Point) -> Int {\n  self.v\n}\n\nfn main {\n  let p : Point = { v: 1 }\n  println(p.norm())\n}\n\nfn orphan() -> Int {\n  0\n}\n",
    ),
  ]
  let unused = unused_names(files)
  let dead = unreachable_names(analyze(files))
  assert_eq(unused, ["orphan"])
  assert_eq(dead, unused)
}

///|
test "consistency: a method reached through T::m" {
  let files : Array[(String, String)] = [
    (
      "a.mbt",
      "struct Box {\n  v : Int\n}\n\nimpl Box with get(self : Box) -> Int {\n  self.v\n}\n\nfn main {\n  let b : Box = { v: 1 }\n  println(Box::get(b))\n}\n\nfn orphan() -> Int {\n  0\n}\n",
    ),
  ]
  let unused = unused_names(files)
  let dead = unreachable_names(analyze(files))
  assert_eq(unused, ["orphan"])
  assert_eq(dead, unused)
}

///|
test "consistency: a package with nothing to report" {
  let files : Array[(String, String)] = [
    ("a.mbt", "pub fn api() -> Int {\n  1\n}\n\nfn main {\n  println(api())\n}\n"),
  ]
  let unused = unused_names(files)
  let dead = unreachable_names(analyze(files))
  assert_eq(unused, [])
  assert_eq(dead, unused)
}

///|
test "transitive reachability is stricter than a lexical mention scan" {
  // `helper` is mentioned, so the lexical pass keeps it alive even though the
  // only mention sits in a function no root reaches. Reachability follows the
  // edge and finds both dead; `explain_dead` names `wrapper` as the failing
  // caller. This is the case the graph exists for.
  let files : Array[(String, String)] = [
    (
      "a.mbt",
      "fn wrapper() -> Int {\n  helper()\n}\n\nfn helper() -> Int {\n  1\n}\n",
    ),
  ]
  assert_eq(unused_names(files), ["wrapper"])
  assert_eq(unreachable_names(analyze(files)), ["wrapper", "helper"])
  let explanation = expect_dead(files, "helper")
  assert_true(any_contains(explanation.evidence, "`wrapper`"))
}
