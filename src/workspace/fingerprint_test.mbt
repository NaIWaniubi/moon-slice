// Tests for content fingerprints.

///|
fn fp_file(path : String, content : String) -> @workspace.WorkspaceFile {
  @workspace.WorkspaceFile::{ path, content }
}

///|
test "the same content fingerprints the same" {
  let a = @workspace.fingerprint("a.mbt", "pub fn f() -> Int {\n  1\n}\n")
  let b = @workspace.fingerprint("a.mbt", "pub fn f() -> Int {\n  1\n}\n")
  assert_eq(a.hash, b.hash)
  assert_eq(a.size, b.size)
}

///|
test "different content fingerprints differently" {
  let a = @workspace.fingerprint("a.mbt", "pub fn f() -> Int {\n  1\n}\n")
  let b = @workspace.fingerprint("a.mbt", "pub fn f() -> Int {\n  2\n}\n")
  assert_true(a.hash != b.hash)
}

///|
test "a one-character change moves the hash" {
  assert_true(@workspace.hash_text("abc") != @workspace.hash_text("abd"))
  assert_true(@workspace.hash_text("abc") != @workspace.hash_text("ab"))
}

///|
test "the size counts characters" {
  assert_eq(@workspace.fingerprint("a.mbt", "").size, 0)
  assert_eq(@workspace.fingerprint("a.mbt", "abc").size, 3)
  assert_eq(@workspace.fingerprint("a.mbt", "a\nb\n").size, 4)
  assert_eq(@workspace.fingerprint("a.mbt", "ab\ncd").size, 5)
}

///|
test "the hash ignores the path" {
  let a = @workspace.fingerprint("src/a/a.mbt", "same text")
  let b = @workspace.fingerprint("src/b/b.mbt", "same text")
  assert_eq(a.hash, b.hash)
  assert_true(a.path != b.path)
}

///|
test "an empty file has a stable fingerprint" {
  let empty = @workspace.fingerprint("a.mbt", "")
  assert_eq(empty.hash, "000000-000000")
  assert_eq(@workspace.hash_text(""), "000000-000000")
}

///|
test "the fingerprint is two fixed-width lanes" {
  let hash = @workspace.hash_text("pub fn f() -> Int {\n  1\n}\n")
  assert_eq(hash.length(), 13)
  assert_true(hash.contains("-"))
}

///|
test "fingerprints preserves the given order and normalises paths" {
  let list = @workspace.fingerprints([
    fp_file("src\\b\\b.mbt", "b"),
    fp_file("./src/a/a.mbt", "a"),
  ])
  assert_eq(list.length(), 2)
  assert_eq(list[0].path, "src/b/b.mbt")
  assert_eq(list[1].path, "src/a/a.mbt")
  assert_eq(list[0].size, 1)
}

///|
test "a long body still hashes within the lanes" {
  let line = "pub fn f() -> Int {\n  1\n}\n"
  let mut text = ""
  let mut i = 0
  while i < 200 {
    text = text + line
    i = i + 1
  }
  let hash = @workspace.hash_text(text)
  assert_eq(hash.length(), 13)
  assert_eq(@workspace.fingerprint("a.mbt", text).size, 200 * line.length())
  assert_true(hash != @workspace.hash_text(line))
}
