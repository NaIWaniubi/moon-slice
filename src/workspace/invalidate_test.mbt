// Tests for incremental invalidation.
//
// The chain used throughout is
//
//   src/a -> src/b -> src/c        (src/a depends on src/b depends on src/c)
//   src/d                          (depends on nothing)
//
// so a change to `src/c` must reach `src/b` and `src/a` and must not reach
// `src/d`.

///|
fn inv_file(path : String, content : String) -> @workspace.WorkspaceFile {
  @workspace.WorkspaceFile::{ path, content }
}

///|
fn inv_fps(pairs : Array[(String, String)]) -> Array[@workspace.FileFingerprint] {
  pairs.map(fn(pair) { @workspace.fingerprint(pair.0, pair.1) })
}

///|
fn inv_chain() -> @workspace.PackageGraph {
  let files : Array[@workspace.WorkspaceFile] = [
    inv_file("moon.mod", "name = \"example/ws\"\nversion = \"1.0.0\"\n"),
    inv_file("src/a/moon.pkg", "import {\n  \"example/ws/src/b\",\n}\n"),
    inv_file("src/a/a.mbt", "pub fn a() -> Int {\n  1\n}\n"),
    inv_file("src/b/moon.pkg", "import {\n  \"example/ws/src/c\",\n}\n"),
    inv_file("src/b/b.mbt", "pub fn b() -> Int {\n  1\n}\n"),
    inv_file("src/c/moon.pkg", ""),
    inv_file("src/c/c.mbt", "pub fn c() -> Int {\n  1\n}\n"),
    inv_file("src/d/moon.pkg", ""),
    inv_file("src/d/d.mbt", "pub fn d() -> Int {\n  1\n}\n"),
  ]
  @workspace.build_graph("example/ws", files)
}

///|
test "an unchanged workspace invalidates nothing" {
  let graph = inv_chain()
  let old = inv_fps([("src/c/c.mbt", "same"), ("src/d/d.mbt", "same")])
  let new = inv_fps([("src/c/c.mbt", "same"), ("src/d/d.mbt", "same")])
  let result = @workspace.invalidate(old, new, graph)
  assert_eq(result.changed, [])
  assert_eq(result.added, [])
  assert_eq(result.removed, [])
  assert_eq(result.packages, [])
}

///|
test "changing a leaf file invalidates the leaf and its importers" {
  let graph = inv_chain()
  let old = inv_fps([("src/c/c.mbt", "old")])
  let new = inv_fps([("src/c/c.mbt", "new")])
  let result = @workspace.invalidate(old, new, graph)
  assert_eq(result.changed, ["src/c/c.mbt"])
  assert_eq(result.added, [])
  assert_eq(result.removed, [])
  assert_eq(result.packages, ["src/a", "src/b", "src/c"])
}

///|
test "the closure crosses more than one edge" {
  let graph = inv_chain()
  let result = @workspace.invalidate(
    inv_fps([("src/c/c.mbt", "old")]),
    inv_fps([("src/c/c.mbt", "new")]),
    graph,
  )
  assert_true(result.packages.contains("src/b"))
  assert_true(result.packages.contains("src/a"))
}

///|
test "a change in a package nothing imports stays local" {
  let graph = inv_chain()
  let result = @workspace.invalidate(
    inv_fps([("src/d/d.mbt", "old")]),
    inv_fps([("src/d/d.mbt", "new")]),
    graph,
  )
  assert_eq(result.changed, ["src/d/d.mbt"])
  assert_eq(result.packages, ["src/d"])
}

///|
test "adding a file invalidates its package and its importers" {
  let graph = inv_chain()
  let old = inv_fps([("src/a/a.mbt", "same")])
  let new = inv_fps([("src/a/a.mbt", "same"), ("src/c/extra.mbt", "pub fn x() -> Int {\n  0\n}\n")])
  let result = @workspace.invalidate(old, new, graph)
  assert_eq(result.added, ["src/c/extra.mbt"])
  assert_eq(result.changed, [])
  assert_eq(result.packages, ["src/a", "src/b", "src/c"])
}

///|
test "removing a file invalidates its package" {
  let graph = inv_chain()
  let old = inv_fps([("src/a/a.mbt", "same"), ("src/d/gone.mbt", "x")])
  let new = inv_fps([("src/a/a.mbt", "same")])
  let result = @workspace.invalidate(old, new, graph)
  assert_eq(result.removed, ["src/d/gone.mbt"])
  assert_eq(result.packages, ["src/d"])
}

///|
test "a test file of a package invalidates that package" {
  let graph = inv_chain()
  let result = @workspace.invalidate(
    inv_fps([("src/a/a_test.mbt", "old")]),
    inv_fps([("src/a/a_test.mbt", "new")]),
    graph,
  )
  assert_eq(result.changed, ["src/a/a_test.mbt"])
  assert_eq(result.packages, ["src/a"])
}

///|
test "a change to moon.mod invalidates every package" {
  let graph = inv_chain()
  let result = @workspace.invalidate(
    inv_fps([("moon.mod", "name = \"example/ws\"\nversion = \"1.0.0\"\n")]),
    inv_fps([("moon.mod", "name = \"example/ws\"\nversion = \"1.0.1\"\n")]),
    graph,
  )
  assert_eq(result.changed, ["moon.mod"])
  assert_eq(result.packages, ["src/a", "src/b", "src/c", "src/d"])
}

///|
test "a file outside every package invalidates no package" {
  let graph = inv_chain()
  let result = @workspace.invalidate(
    inv_fps([("README.md", "old")]),
    inv_fps([("README.md", "new")]),
    graph,
  )
  assert_eq(result.changed, ["README.md"])
  assert_eq(result.packages, [])
}

///|
test "several changed files are reported sorted and merged" {
  let graph = inv_chain()
  let old = inv_fps([("src/d/d.mbt", "old"), ("src/c/c.mbt", "old")])
  let new = inv_fps([("src/d/d.mbt", "new"), ("src/c/c.mbt", "new")])
  let result = @workspace.invalidate(old, new, graph)
  assert_eq(result.changed, ["src/c/c.mbt", "src/d/d.mbt"])
  assert_eq(result.packages, ["src/a", "src/b", "src/c", "src/d"])
}

///|
test "backslash paths are compared as the same file" {
  let graph = inv_chain()
  let old = inv_fps([("src/c/c.mbt", "same")])
  let new = inv_fps([("src\\c\\c.mbt", "same")])
  let result = @workspace.invalidate(old, new, graph)
  assert_eq(result.changed, [])
  assert_eq(result.added, [])
  assert_eq(result.removed, [])
}
