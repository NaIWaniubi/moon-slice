// Cross-file expansion tests. Each case is a package of two or more files: the
// point of this module is that the callee is not in the file being sliced.

///|
fn index_of(files : Array[(String, String)]) -> @interproc.PackageIndex {
  let built : Array[@interproc.PackageFile] = []
  for pair in files {
    match @interproc.build_file(pair.0, pair.1) {
      Some(file) => built.push(file)
      None => abort("did not parse")
    }
  }
  @interproc.index(built)
}

///|
fn lines_of(result : Array[@interproc.FileSlice], path : String) -> Array[Int32] {
  for file in result {
    if file.path == path {
      return file.lines
    }
  }
  []
}

///|
fn slice_of(file : @interproc.PackageFile, line : Int32) -> @core.SliceResult {
  let node = match @query.target_node(file.program, line) {
    Some(id) => id
    None => abort("no node on line")
  }
  @slice.backward(file.pdg, node, program=file.program)
}

///|
test "a bare call expands into the callee's body in a sibling file" {
  let a = "fn main_fn(x : Int) -> Int {\n  twice(x)\n}\n"
  let b = "fn inc(x : Int) -> Int {\n  x + 1\n}\n\nfn twice(x : Int) -> Int {\n  let a = inc(x)\n  let b = inc(a)\n  b\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let file_a = index.files[0]
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(file_a, 2))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2])
  // `twice`'s body (6,7,8) and the `inc` it calls (2).
  assert_eq(lines_of(result, "pkg/b.mbt"), [2, 6, 7, 8])
}

///|
test "a value-returning call expands to the return cone, not the whole body" {
  let a = "fn caller() -> Int {\n  let v = helper()\n  v\n}\n"
  let b = "fn helper() -> Int {\n  let dead = 1\n  let live = 2\n  return live\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 2))
  // `dead = 1` does not reach the return, so it stays out.
  assert_eq(lines_of(result, "pkg/b.mbt"), [3, 4])
}

///|
test "expansion is transitive across three files" {
  let a = "fn top() -> Int {\n  middle()\n}\n"
  let b = "fn middle() -> Int {\n  leaf()\n}\n"
  let c = "fn leaf() -> Int {\n  42\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b), ("pkg/c.mbt", c)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [2])
  assert_eq(lines_of(result, "pkg/c.mbt"), [2])
}

///|
test "a local definition wins over a same-named function elsewhere" {
  let a = "fn local() -> Int {\n  1\n}\n\nfn top() -> Int {\n  local()\n}\n"
  let b = "fn local() -> Int {\n  999\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 6))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2, 6])
  // The unrelated b.mbt definition is never pulled in.
  assert_eq(lines_of(result, "pkg/b.mbt"), [])
}

///|
test "a callee nobody defines adds nothing" {
  let a = "fn top() -> Int {\n  external_thing()\n}\n"
  let index = index_of([("pkg/a.mbt", a)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2])
  assert_eq(result.length(), 1)
}

///|
test "an unparsable file is left out of the index" {
  assert_true(@interproc.build_file("bad.mbt", "fn broken( {\n") is None)
  assert_true(@interproc.build_file("good.mbt", "fn ok() -> Int {\n  1\n}\n") is Some(_))
}

///|
test "files in one directory share a package" {
  let index = index_of([
    ("pkg/a.mbt", "fn a() -> Int {\n  1\n}\n"),
    ("pkg/b.mbt", "fn b() -> Int {\n  2\n}\n"),
    ("other/c.mbt", "fn c() -> Int {\n  3\n}\n"),
  ])
  assert_eq(@interproc.files_in_package(index, "pkg"), ["pkg/a.mbt", "pkg/b.mbt"])
  assert_eq(@interproc.package_dir("a/b/c.mbt"), "a/b")
  assert_eq(@interproc.package_dir("c.mbt"), ".")
}

///|
test "a qualified call expands across files and is listed as a caller" {
  let a = "fn caller() -> Int {\n  T::helper(1)\n}\n"
  let b = "fn T::helper(x : Int) -> Int {\n  x + 1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [2])
  let sites = @interproc.callers(index, "helper")
  assert_eq(sites.length(), 1)
  assert_eq(sites[0].path, "pkg/a.mbt")
  assert_eq(sites[0].line, 2)
  assert_eq(sites[0].caller, "caller")
}

///|
test "a receiver call is not attributed to a same-named free function" {
  // `s.m()` needs type resolution to know which `m` it runs; attributing it to
  // the free function `m` would invent a call, so nothing is expanded and
  // nothing is listed.
  let a = "struct S {\n  v : Int\n}\n\nfn caller(s : S) -> Int {\n  s.m()\n}\n"
  let b = "fn m() -> Int {\n  999\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 6))
  assert_eq(lines_of(result, "pkg/b.mbt"), [])
  assert_eq(@interproc.callers(index, "m").length(), 0)
}
