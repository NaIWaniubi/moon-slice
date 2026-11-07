// Tests for package graph construction.
//
// Each case is a small workspace: a handful of paths and the manifests that
// connect them. The graph is the only thing a build tool sees, so the assertions
// are on the exact file lists, dependency edges and names it produces.

///|
fn graph_file(path : String, content : String) -> @workspace.WorkspaceFile {
  @workspace.WorkspaceFile::{ path, content }
}

///|
fn graph_files(graph : @workspace.PackageGraph, dir : String) -> Array[String] {
  match @workspace.find_package(graph, dir) {
    Some(node) => node.files
    None => ["!missing " + dir]
  }
}

///|
fn graph_tests(graph : @workspace.PackageGraph, dir : String) -> Array[String] {
  match @workspace.find_package(graph, dir) {
    Some(node) => node.test_files
    None => ["!missing " + dir]
  }
}

///|
fn graph_deps(graph : @workspace.PackageGraph, dir : String) -> Array[String] {
  match @workspace.find_package(graph, dir) {
    Some(node) => node.deps
    None => ["!missing " + dir]
  }
}

///|
fn graph_imports(graph : @workspace.PackageGraph, dir : String) -> Array[String] {
  match @workspace.find_package(graph, dir) {
    Some(node) => node.imports
    None => ["!missing " + dir]
  }
}

///|
fn graph_name(graph : @workspace.PackageGraph, dir : String) -> String {
  match @workspace.find_package(graph, dir) {
    Some(node) => node.name
    None => "!missing " + dir
  }
}

///|
fn graph_has_manifest(graph : @workspace.PackageGraph, dir : String) -> Bool {
  match @workspace.find_package(graph, dir) {
    Some(node) => node.has_manifest
    None => false
  }
}

///|
fn graph_found(graph : @workspace.PackageGraph, dir : String) -> Bool {
  match @workspace.find_package(graph, dir) {
    Some(_) => true
    None => false
  }
}

///|
test "files are grouped by package directory" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/a/a.mbt", "pub fn a() -> Int {\n  1\n}\n"),
    graph_file("src/a/b.mbt", "pub fn b() -> Int {\n  2\n}\n"),
    graph_file("src/b/c.mbt", "pub fn c() -> Int {\n  3\n}\n"),
  ])
  assert_eq(@workspace.package_dirs(graph), ["src/a", "src/b"])
  assert_eq(graph_files(graph, "src/a"), ["src/a/a.mbt", "src/a/b.mbt"])
  assert_eq(graph_files(graph, "src/b"), ["src/b/c.mbt"])
}

///|
test "packages are ordered by directory" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/z/z.mbt", "\n"),
    graph_file("src/m/m.mbt", "\n"),
    graph_file("src/a/a.mbt", "\n"),
  ])
  assert_eq(@workspace.package_dirs(graph), ["src/a", "src/m", "src/z"])
}

///|
test "test files belong to the package but are not its sources" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/a/a.mbt", "\n"),
    graph_file("src/a/a_test.mbt", "\n"),
    graph_file("src/a/a_wbtest.mbt", "\n"),
    graph_file("src/a/README.md", "not moonbit\n"),
  ])
  assert_eq(graph_files(graph, "src/a"), ["src/a/a.mbt"])
  assert_eq(graph_tests(graph, "src/a"), ["src/a/a_test.mbt", "src/a/a_wbtest.mbt"])
}

///|
test "a package name is the module name plus its directory" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/a/a.mbt", "\n"),
    graph_file("src/a/moon.pkg", ""),
  ])
  assert_eq(graph_name(graph, "src/a"), "example/ws/src/a")
}

///|
test "root-level files form the module package" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("a.mbt", "\n"),
    graph_file("moon.pkg", ""),
  ])
  assert_eq(@workspace.package_dirs(graph), [""])
  assert_eq(graph_name(graph, ""), "example/ws")
  assert_eq(graph_files(graph, ""), ["a.mbt"])
}

///|
test "an internal import becomes a dependency edge" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/a/moon.pkg", "import {\n  \"example/ws/src/b\",\n}\n"),
    graph_file("src/a/a.mbt", "\n"),
    graph_file("src/b/moon.pkg", ""),
    graph_file("src/b/b.mbt", "\n"),
  ])
  assert_eq(graph_imports(graph, "src/a"), ["example/ws/src/b"])
  assert_eq(graph_deps(graph, "src/a"), ["src/b"])
  assert_eq(graph_deps(graph, "src/b"), [])
}

///|
test "an external import is not an edge" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/a/moon.pkg", "import {\n  \"moonbitlang/parser\",\n}\n"),
    graph_file("src/a/a.mbt", "\n"),
  ])
  assert_eq(graph_imports(graph, "src/a"), ["moonbitlang/parser"])
  assert_eq(graph_deps(graph, "src/a"), [])
}

///|
test "an import of another module is not an edge" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/a/moon.pkg", "import {\n  \"other/module/src/b\",\n}\n"),
    graph_file("src/a/a.mbt", "\n"),
    graph_file("src/b/b.mbt", "\n"),
  ])
  assert_eq(graph_deps(graph, "src/a"), [])
}

///|
test "a test-only import is a dependency of the package too" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file(
      "src/a/moon.pkg",
      "import {\n  \"example/ws/src/b\",\n} for \"test\"\n",
    ),
    graph_file("src/a/a.mbt", "\n"),
    graph_file("src/b/b.mbt", "\n"),
  ])
  assert_eq(graph_imports(graph, "src/a"), [])
  assert_eq(graph_deps(graph, "src/a"), ["src/b"])
}

///|
test "a dependency is recorded once even when declared twice" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file(
      "src/a/moon.pkg",
      "import {\n  \"example/ws/src/b\",\n}\n\nimport {\n  \"example/ws/src/b\",\n} for \"test\"\n",
    ),
    graph_file("src/a/a.mbt", "\n"),
    graph_file("src/b/b.mbt", "\n"),
  ])
  assert_eq(graph_deps(graph, "src/a"), ["src/b"])
}

///|
test "a package whose manifest does not parse keeps its files" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/a/moon.pkg", "pkgtype = 1\n"),
    graph_file("src/a/a.mbt", "\n"),
  ])
  assert_eq(graph_files(graph, "src/a"), ["src/a/a.mbt"])
  assert_false(graph_has_manifest(graph, "src/a"))
  assert_eq(graph_deps(graph, "src/a"), [])
}

///|
test "a directory holding only a manifest is still a package" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/a/moon.pkg", ""),
  ])
  assert_eq(@workspace.package_dirs(graph), ["src/a"])
  assert_true(graph_has_manifest(graph, "src/a"))
  assert_eq(graph_files(graph, "src/a"), [])
}

///|
test "backslash and dot prefixes name the same file" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src\\a\\a.mbt", "\n"),
    graph_file("./src/a/a.mbt", "\n"),
  ])
  assert_eq(@workspace.package_dirs(graph), ["src/a"])
  assert_eq(graph_files(graph, "src/a"), ["src/a/a.mbt"])
}

///|
test "find_package reports a directory that is not there" {
  let graph = @workspace.build_graph("example/ws", [graph_file("src/a/a.mbt", "\n")])
  assert_true(graph_found(graph, "src/a"))
  assert_false(graph_found(graph, "src/nope"))
}

///|
test "dependents are the packages that import a directory" {
  let graph = @workspace.build_graph("example/ws", [
    graph_file("src/a/moon.pkg", "import {\n  \"example/ws/src/b\",\n}\n"),
    graph_file("src/a/a.mbt", "\n"),
    graph_file("src/c/moon.pkg", "import {\n  \"example/ws/src/b\",\n}\n"),
    graph_file("src/c/c.mbt", "\n"),
    graph_file("src/b/b.mbt", "\n"),
    graph_file("src/d/d.mbt", "\n"),
  ])
  assert_eq(@workspace.dependents(graph, "src/b"), ["src/a", "src/c"])
  assert_eq(@workspace.dependents(graph, "src/d"), [])
}

///|
test "a directory with no files is not a package" {
  let graph = @workspace.build_graph("example/ws", [graph_file("README.md", "hi\n")])
  assert_eq(@workspace.package_dirs(graph), [])
}
