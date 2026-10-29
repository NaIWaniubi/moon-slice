// Whitebox tests for the diff parser and the file-level review helper. The CLI
// smoke test covers the printed format; these cover the edge cases the format
// depends on.

///|
test "diff parser collects added lines in new-file coordinates" {
  let diff = "--- a/src/a.mbt\n" +
    "+++ b/src/a.mbt\n" +
    "@@ -1,0 +3,2 @@\n" +
    "+  let b = a + 1\n" +
    "+  let c = b + 1\n"
  let hunks = parse_diff(diff)
  assert_eq(hunks.length(), 1)
  assert_eq(hunks[0].path, "src/a.mbt")
  assert_eq(hunks[0].lines, [3, 4])
}

///|
test "diff parser ignores deleted lines and deleted files" {
  let diff = "--- a/src/a.mbt\n" +
    "+++ b/src/a.mbt\n" +
    "@@ -3,2 +3,1 @@\n" +
    "-  let old = 1\n" +
    "+  let new = 1\n" +
    "--- a/src/gone.mbt\n" +
    "+++ /dev/null\n" +
    "@@ -1,1 +0,0 @@\n" +
    "-fn gone() -> Unit { () }\n"
  let hunks = parse_diff(diff)
  assert_eq(hunks.length(), 1)
  assert_eq(hunks[0].lines, [3])
}

///|
test "diff parser advances over context lines" {
  let diff = "+++ b/src/a.mbt\n" +
    "@@ -1,2 +1,2 @@\n" +
    " fn keep() -> Unit { () }\n" +
    "+fn added() -> Unit { () }\n"
  let hunks = parse_diff(diff)
  assert_eq(hunks[0].lines, [2])
}

///|
test "diff parser merges hunks of one file" {
  let diff = "+++ b/src/a.mbt\n" +
    "@@ -1,0 +2,1 @@\n" +
    "+let a = 1\n" +
    "@@ -10,0 +12,1 @@\n" +
    "+let b = 2\n"
  let hunks = parse_diff(diff)
  assert_eq(hunks.length(), 1)
  assert_eq(hunks[0].lines, [2, 12])
}

///|
test "review file forward-slices the changed statement" {
  let path = "review_wbtest_probe.mbt"
  let source = "fn probe(x : Int) -> Int {\n" +
    "  let a = x + 1\n" +
    "  let b = a + 1\n" +
    "  return b\n" +
    "}\n"
  @fs.write_string_to_file(path, source) catch {
    @fs.IOError(msg) => fail("write failed: \{msg}")
  }
  let affected = review_file(path, [3])
  @fs.remove_file(path) catch {
    @fs.IOError(_) => ()
  }
  // Line 3 defines `b`; line 4 reads it. Line 1 is the function header, which
  // the slice does not mark, and neither does it include unrelated lines.
  assert_eq(affected, [3, 4])
}

///|
test "review file returns nothing for an unparsable file" {
  let path = "review_wbtest_broken.mbt"
  @fs.write_string_to_file(path, "fn broken( {\n  let x =\n}\n") catch {
    @fs.IOError(msg) => fail("write failed: \{msg}")
  }
  let affected = review_file(path, [1, 2])
  @fs.remove_file(path) catch {
    @fs.IOError(_) => ()
  }
  assert_eq(affected, [])
}

///|
test "functions touching a line are reported by name" {
  let source = "fn probe(x : Int) -> Int {\n" +
    "  let a = x + 1\n" +
    "  let b = a + 1\n" +
    "  return b\n" +
    "}\n"
  let program = @parser_adapter.parse_source(source, "probe.mbt")
  let names = functions_touching(program, [3, 4])
  assert_eq(names, ["probe"])
  let none = functions_touching(program, [])
  assert_eq(none.length(), 0)
}
