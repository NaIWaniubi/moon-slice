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
test "a bare call to a pure function contributes only the value it returns" {
  let a = "fn main_fn(x : Int) -> Int {\n  twice(x)\n}\n"
  let b = "fn inc(x : Int) -> Int {\n  x + 1\n}\n\nfn twice(x : Int) -> Int {\n  let a = inc(x)\n  let b = inc(a)\n  b\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let file_a = index.files[0]
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(file_a, 2))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2])
  // `twice` is pure, so the call contributes the value it hands back (8) and
  // none of the statements that only build it (6, 7).
  assert_eq(lines_of(result, "pkg/b.mbt"), [8])
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

///|
test "a receiver call is listed when the package declares the method" {
  let a = "fn caller(p : Point) -> Int {\n  p.norm()\n}\n"
  let b = "impl Point with fn norm(self) -> Int {\n  1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let sites = @interproc.callers(index, "norm")
  assert_eq(sites.length(), 1)
  assert_eq(sites[0].path, "pkg/a.mbt")
  assert_eq(sites[0].line, 2)
  assert_eq(sites[0].caller, "caller")
}

///|
test "a receiver call to a method the package never declares is not listed" {
  // `Point::norm` is declared nowhere in this package, so `p.norm()` may be a
  // method from a dependency. Counting it would invent the edge.
  let a = "fn caller(p : Point) -> Int {\n  p.norm()\n}\n"
  let b = "impl Other with fn norm(self) -> Int {\n  1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  assert_eq(@interproc.callers(index, "norm").length(), 0)
}

///|
test "self.helper() inside an impl is listed with the method as its caller" {
  let a =
    "impl Point with fn norm(self) -> Int {\n  self.helper()\n}\nfn Point::helper(self) -> Int {\n  1\n}\n"
  let index = index_of([("pkg/a.mbt", a)])
  let sites = @interproc.callers(index, "helper")
  assert_eq(sites.length(), 1)
  assert_eq(sites[0].line, 2)
  assert_eq(sites[0].caller, "norm")
}

///|
test "an unannotated receiver is not listed even when the method exists" {
  let a = "fn caller() -> Int {\n  let p = make()\n  p.norm()\n}\n"
  let b = "impl Point with fn norm(self) -> Int {\n  1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  assert_eq(@interproc.callers(index, "norm").length(), 0)
}

///|
test "qualified and receiver calls to the same name are listed together" {
  let a =
    "fn by_type() -> Int {\n  Point::norm()\n}\nfn by_receiver(p : Point) -> Int {\n  p.norm()\n}\n"
  let b = "impl Point with fn norm(self) -> Int {\n  1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let sites = @interproc.callers(index, "norm")
  assert_eq(sites.length(), 2)
  assert_eq(sites[0].line, 2)
  assert_eq(sites[1].line, 5)
}

///|
test "a receiver call expands into the method body across files" {
  let a = "fn use(p : Point) -> Int {\n  p.norm()\n}\n"
  let b = "impl Point with fn norm(self) -> Int {\n  let v = 42\n  v\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [2, 3])
}

///|
test "a receiver call to an undeclared method expands nothing" {
  let a = "fn use(p : Point) -> Int {\n  p.norm()\n}\n"
  let b = "fn norm() -> Int {\n  1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [])
}

///|
test "self.helper() inside an impl expands within the same file" {
  let a =
    "impl Point with fn norm(self) -> Int {\n  self.helper()\n}\nfn Point::helper(self) -> Int {\n  7\n}\n"
  let index = index_of([("pkg/a.mbt", a)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2, 5])
}

///|
test "an unannotated receiver expands nothing even when the method exists" {
  let a = "fn use() -> Int {\n  let p = make()\n  p.norm()\n}\n"
  let b = "impl Point with fn norm(self) -> Int {\n  1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", slice_of(index.files[0], 3))
  assert_eq(lines_of(result, "pkg/b.mbt"), [])
}

///|
test "an enum declared in a sibling file types a match arm" {
  let a = "fn use(m : MaybeP) -> Int {\n  match m {\n    Just(p) => p.norm()\n  }\n}\n"
  let b = "struct Point {\n  x : Int\n}\n\nenum MaybeP {\n  Just(Point)\n}\n\nimpl Point with fn norm(self) -> Int {\n  1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let sites = @interproc.callers(index, "norm")
  assert_eq(sites.length(), 1)
  assert_eq(sites[0].path, "pkg/a.mbt")
  assert_eq(sites[0].line, 3)
}

///|
test "a struct field declared in a sibling file types a receiver chain" {
  let a = "fn use(h : Holder) -> Int {\n  h.p.norm()\n}\n"
  let b = "struct Point {\n  x : Int\n}\n\nstruct Holder {\n  p : Point\n}\n\nimpl Point with fn norm(self) -> Int {\n  1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let sites = @interproc.callers(index, "norm")
  assert_eq(sites.length(), 1)
  assert_eq(sites[0].line, 2)
}

// ---------------------------------------------------------------------------
// Bare calls: side-effect precision
// ---------------------------------------------------------------------------

///|
/// A slice holding just the statement on `line`. These cases are about what the
/// expansion adds, so the intraprocedural pass is left out.
fn bare_slice(file : @interproc.PackageFile, line : Int32) -> @core.SliceResult {
  let id = match @query.target_node(file.program, line) {
    Some(found) => found
    None => abort("no node on line")
  }
  @core.SliceResult::{ nodes: [id], lines: @query.visible_lines(file.program, [id]) }
}

///|
test "a bare call to a pure function skips its unrelated statements" {
  let a = "fn use_it() -> Int {\n  pure_helper(7)\n}\n"
  let b = "fn pure_helper(n : Int) -> Int {\n  let unused = n * 2\n  return n\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2])
  // Only the value the call hands back; the local computation stays out.
  assert_eq(lines_of(result, "pkg/b.mbt"), [3])
}

///|
test "a pure callee without an explicit return contributes its trailing expression" {
  let a = "fn use_it() -> Int {\n  helper(1)\n}\n"
  let b = "fn helper(n : Int) -> Int {\n  let dead = n\n  n + 1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [3])
}

///|
test "a bare call pulls in the field write of its callee" {
  let a = "fn use_it(p : Point) -> Unit {\n  set_field(p)\n}\n"
  let b = "fn set_field(p : Point) -> Int {\n  let decoy = 99\n  p.x = 1\n  decoy\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  // The write (3) and the returned value (4); the unrelated `decoy` (2) stays out.
  assert_eq(lines_of(result, "pkg/b.mbt"), [3, 4])
}

///|
test "a bare call pulls in an element write of its callee" {
  let a = "fn use_it(items : Array[Int]) -> Unit {\n  poke(items)\n}\n"
  let b = "fn poke(items : Array[Int]) -> Unit {\n  items[0] = 1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [2])
}

///|
test "a bare call pulls in a receiver mutation of its callee" {
  let a = "fn use_it(c : Counter) -> Unit {\n  Counter::bump(c)\n}\n"
  let b = "impl Counter with fn bump(self : Counter) -> Unit {\n  self.n = self.n + 1\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [2])
}

///|
test "a bare call pulls in the raise of its callee" {
  let a = "fn use_it() -> Unit {\n  bad()\n}\n"
  let b = "fn bad() -> Unit {\n  let decoy = 1\n  raise Failure(\"boom\")\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [3])
}

///|
test "a bare call pulls in a panic statement of its callee" {
  let a = "fn use_it() -> Unit {\n  explode()\n}\n"
  let b = "fn explode() -> Unit {\n  let decoy = 1\n  panic()\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [3])
}

///|
test "a bare call pulls in the IO statement of its callee" {
  let a = "fn use_it() -> Unit {\n  shout()\n}\n"
  let b = "fn shout() -> Unit {\n  println(\"hi\")\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [2])
}

///|
test "a callee calling an unresolved function falls back to its whole body" {
  let a = "fn use_it() -> Int {\n  wrapper()\n}\n"
  let b = "fn wrapper() -> Int {\n  let decoy = 1\n  mystery()\n  decoy\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  // Nothing is known about `mystery`, so the summary cannot justify dropping a
  // statement: the whole body is the safe answer.
  assert_eq(lines_of(result, "pkg/b.mbt"), [2, 3, 4])
}

///|
test "a callee calling another package falls back to its whole body" {
  let a = "fn use_it() -> Int {\n  wrapper()\n}\n"
  let b = "fn wrapper() -> Int {\n  let decoy = 1\n  @other.f()\n  decoy\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [2, 3, 4])
}

///|
test "a bare call to a wrapper of an impure function follows the call" {
  let a = "fn use_it() -> Unit {\n  log_it()\n}\n"
  let b = "fn log_it() -> Unit {\n  inner()\n}\n"
  let c = "fn inner() -> Unit {\n  println(\"x\")\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b), ("pkg/c.mbt", c)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  // The wrapper has no effect line of its own; the call to the impure callee is
  // what carries the impurity, and it is then expanded in turn.
  assert_eq(lines_of(result, "pkg/b.mbt"), [2])
  assert_eq(lines_of(result, "pkg/c.mbt"), [2])
}

///|
test "a bare call to a pure wrapper of a pure function adds only its value" {
  let a = "fn use_it() -> Int {\n  outer()\n}\n"
  let b = "fn outer() -> Int {\n  let v = inner(1)\n  v\n}\n"
  let c = "fn inner(n : Int) -> Int {\n  n\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b), ("pkg/c.mbt", c)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [3])
  assert_eq(lines_of(result, "pkg/c.mbt"), [])
}

///|
test "a recursive callee terminates and keeps its raise and its call" {
  let a = "fn use_it() -> Unit {\n  spin(3)\n}\n"
  let b = "fn spin(n : Int) -> Unit {\n  if n > 0 {\n    spin(n - 1)\n  }\n  raise Failure(\"done\")\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [3, 5])
}

// ---------------------------------------------------------------------------
// Value-returning calls: cone plus side effects
// ---------------------------------------------------------------------------

///|
test "a value-returning call keeps its cone and adds the callee's write" {
  let a = "fn caller(p : Point) -> Int {\n  let v = helper(p)\n  v\n}\n"
  let b = "fn helper(p : Point) -> Int {\n  p.x = 1\n  return 7\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  // The cone of `return 7` is the return itself (3); the write (2) does not feed
  // the value but the call performs it, so it is added on top.
  assert_eq(lines_of(result, "pkg/b.mbt"), [2, 3])
}

///|
test "a value-returning call to a pure function adds no side-effect line" {
  let a = "fn caller() -> Int {\n  let v = helper()\n  v\n}\n"
  let b = "fn helper() -> Int {\n  let dead = 1\n  let live = 2\n  return live\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [3, 4])
}

///|
test "a value-returning call adds an IO statement the return does not depend on" {
  let a = "fn caller() -> Int {\n  let v = noisy()\n  v\n}\n"
  let b = "fn noisy() -> Int {\n  println(\"hi\")\n  return 5\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  assert_eq(lines_of(result, "pkg/b.mbt"), [2, 3])
}

///|
test "a value-returning call does not fall back to the whole body" {
  let a = "fn caller() -> Int {\n  let v = wrapper()\n  v\n}\n"
  let b = "fn wrapper() -> Int {\n  let decoy = 1\n  mystery()\n  return 2\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 2))
  // The cone (4) is preserved; the unresolved call adds nothing and the whole
  // body (2) is not pulled in either.
  assert_eq(lines_of(result, "pkg/b.mbt"), [4])
}

// ---------------------------------------------------------------------------
// Argument mapping: the caller side of the edge
// ---------------------------------------------------------------------------

///|
test "an identifier argument brings its definition into the slice" {
  let a = "fn main_fn(x : Int) -> Unit {\n  let arg = x + 1\n  consume(arg)\n}\n"
  let b = "fn consume(v : Int) -> Unit {\n  ()\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 3))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2, 3])
}

///|
test "a compound expression argument brings every definition it reads" {
  let a = "fn main_fn(x : Int, y : Int) -> Unit {\n  let first = x + 1\n  let second = y * 2\n  consume(first + second)\n}\n"
  let b = "fn consume(v : Int) -> Unit {\n  ()\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 4))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2, 3, 4])
}

///|
test "a field-access argument brings the base definition" {
  let a = "fn main_fn(p : Point) -> Unit {\n  let q = p\n  consume(q.x)\n}\n"
  let b = "fn consume(v : Int) -> Unit {\n  ()\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 3))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2, 3])
}

///|
test "a literal argument brings nothing" {
  let a = "fn main_fn(x : Int) -> Unit {\n  let unused = x\n  consume(5)\n}\n"
  let b = "fn consume(v : Int) -> Unit {\n  ()\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 3))
  assert_eq(lines_of(result, "pkg/a.mbt"), [3])
}

///|
test "an omitted default parameter brings nothing even when the name is in scope" {
  let a = "fn consume(v : Int, k? : Int = 2) -> Unit {\n  ()\n}\n\nfn main_fn(x : Int) -> Unit {\n  let k = 99\n  let arg = x\n  consume(arg)\n}\n"
  let index = index_of([("pkg/a.mbt", a)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 8))
  // `k` is a default the call does not supply, so the unrelated local named `k`
  // is not the argument.
  assert_eq(lines_of(result, "pkg/a.mbt"), [7, 8])
}

///|
test "a named argument is mapped by parameter name" {
  let a = "fn consume(a? : Int = 0, b? : Int = 0) -> Unit {\n  ()\n}\n\nfn main_fn(x : Int, y : Int) -> Unit {\n  let first = x\n  let second = y\n  consume(b?=second)\n}\n"
  let index = index_of([("pkg/a.mbt", a)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 8))
  assert_eq(lines_of(result, "pkg/a.mbt"), [7, 8])
}

///|
test "the reaching definition is the one before the call" {
  let a = "fn consume(v : Int) -> Unit {\n  ()\n}\n\nfn main_fn(x : Int) -> Unit {\n  let arg = x\n  let other = 1\n  let arg = 2\n  consume(arg)\n}\n"
  let index = index_of([("pkg/a.mbt", a)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 9))
  // The redefinition on 8 wins; the earlier one on 6 is shadowed.
  assert_eq(lines_of(result, "pkg/a.mbt"), [8, 9])
}

///|
test "a same-named definition in another function is not pulled in" {
  let a = "fn other_fn() -> Int {\n  let arg = 1\n  arg\n}\n\nfn main_fn(x : Int) -> Unit {\n  consume(arg)\n}\n"
  let b = "fn consume(v : Int) -> Unit {\n  ()\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 7))
  assert_eq(lines_of(result, "pkg/a.mbt"), [7])
}

///|
test "a value-returning call maps its argument as well" {
  let a = "fn main_fn(x : Int) -> Int {\n  let arg = x\n  let v = take(arg)\n  v\n}\n"
  let b = "fn take(v : Int) -> Int {\n  return v\n}\n"
  let index = index_of([("pkg/a.mbt", a), ("pkg/b.mbt", b)])
  let result = @interproc.expand(index, "pkg/a.mbt", bare_slice(index.files[0], 3))
  assert_eq(lines_of(result, "pkg/a.mbt"), [2, 3])
  assert_eq(lines_of(result, "pkg/b.mbt"), [2])
}
