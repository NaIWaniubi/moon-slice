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


// ---------------------------------------------------------------------------
// Impact certificates attached to review results
// ---------------------------------------------------------------------------

///|
fn write_review_probe(path : String, source : String) -> Unit {
  @fs.write_string_to_file(path, source) catch {
    @fs.IOError(msg) => abort("write failed: " + msg)
  }
}

///|
fn remove_review_probe(path : String) -> Unit {
  @fs.remove_file(path) catch {
    @fs.IOError(_) => ()
  }
}

///|
fn remove_review_package(dir : String, files : Array[String]) -> Unit {
  for file in files {
    remove_review_probe(dir + "/" + file)
  }
  @fs.remove_dir(dir) catch {
    @fs.IOError(_) => ()
  }
}

///|
fn probe_source() -> String {
  "fn probe(x : Int) -> Int {\n" +
  "  let a = x + 1\n" +
  "  let b = a + 1\n" +
  "  return b\n" +
  "}\n"
}

///|
test "review impact certificate proves the changed line" {
  let path = "review_wbtest_impact_probe.mbt"
  write_review_probe(path, probe_source())
  let certificate = review_impact(path, [3], None)
  remove_review_probe(path)
  assert_eq(certificate.changed_lines, [3])
  assert_eq(certificate.affected_functions, ["probe"])
  assert_true(certificate.affected_statements.length() > 0)
  assert_true(certificate.evidence.length() > 0)
}

///|
test "review impact ignores a line with no statement" {
  let path = "review_wbtest_impact_blank.mbt"
  write_review_probe(path, probe_source())
  let certificate = review_impact(path, [999], None)
  remove_review_probe(path)
  assert_eq(certificate.changed_lines, [999])
  assert_eq(certificate.affected_statements, [])
  assert_eq(certificate.affected_functions, [])
  assert_eq(certificate.evidence, [])
}

///|
test "review impact with no changed lines is empty" {
  let path = "review_wbtest_impact_empty.mbt"
  write_review_probe(path, probe_source())
  let certificate = review_impact(path, [], None)
  remove_review_probe(path)
  assert_eq(certificate.changed_lines, [])
  assert_eq(certificate.affected_statements, [])
  assert_eq(certificate.reachable_entries, [])
  assert_eq(certificate.evidence, [])
}

///|
test "review impact keeps the shape for an unreadable file" {
  let certificate = review_impact("review_wbtest_missing.mbt", [4, 2], None)
  assert_eq(certificate.changed_lines, [2, 4])
  assert_eq(certificate.affected_statements, [])
  assert_eq(certificate.unresolved_boundaries, [])
}

///|
test "review impact is empty for an unparsable file" {
  let path = "review_wbtest_impact_broken.mbt"
  write_review_probe(path, "fn broken( {\n  let x =\n}\n")
  let certificate = review_impact(path, [1, 2], None)
  remove_review_probe(path)
  assert_eq(certificate.changed_lines, [1, 2])
  assert_eq(certificate.affected_statements, [])
  assert_eq(certificate.evidence, [])
}

///|
test "review impact without a package has no entries or tests" {
  let path = "review_wbtest_impact_single.mbt"
  write_review_probe(path, "pub fn api() -> Int {\n  helper()\n}\nfn helper() -> Int {\n  1\n}\n")
  let certificate = review_impact(path, [5], None)
  remove_review_probe(path)
  assert_eq(certificate.affected_functions, ["helper"])
  assert_eq(certificate.reachable_entries, [])
  assert_eq(certificate.related_tests, [])
  assert_eq(certificate.cross_package_files, [])
}

///|
test "impact json carries every contract field" {
  let path = "review_wbtest_impact_json.mbt"
  write_review_probe(path, probe_source())
  let certificate = review_impact(path, [3], None)
  remove_review_probe(path)
  let json = impact_json(certificate)
  assert_true(json.has_prefix("{\"changed_lines\":[3],\"affected_statements\":"))
  assert_true(json.contains("\"affected_functions\":[\"probe\"]"))
  assert_true(json.contains("\"reachable_entries\":"))
  assert_true(json.contains("\"cross_package_files\":"))
  assert_true(json.contains("\"related_tests\":"))
  assert_true(json.contains("\"unresolved_boundaries\":"))
  assert_true(json.contains("\"evidence_paths\":"))
  assert_true(json.has_suffix("}"))
}

///|
test "impact json evidence_paths is the evidence count" {
  let path = "review_wbtest_impact_count.mbt"
  write_review_probe(path, probe_source())
  let certificate = review_impact(path, [3], None)
  remove_review_probe(path)
  let json = impact_json(certificate)
  let want = "\"evidence_paths\":" + certificate.evidence.length().to_string() + "}"
  assert_true(json.has_suffix(want))
}

///|
test "impact text prints the five summary lines" {
  let path = "review_wbtest_impact_text.mbt"
  write_review_probe(path, probe_source())
  let certificate = review_impact(path, [3], None)
  remove_review_probe(path)
  let text = impact_text(certificate)
  assert_true(text.contains("impact functions: probe"))
  assert_true(text.contains("reachable entries: (none)"))
  assert_true(text.contains("related tests: (none)"))
  assert_true(text.contains("evidence paths: "))
  assert_true(text.contains("unresolved boundaries: 0"))
}

///|
test "impact text counts unresolved boundaries" {
  let path = "review_wbtest_impact_boundary.mbt"
  write_review_probe(path, "fn f(x : Int) -> Unit {\n  println(x)\n}\n")
  let certificate = review_impact(path, [2], None)
  remove_review_probe(path)
  assert_true(certificate.unresolved_boundaries.length() > 0)
  assert_true(
    impact_text(certificate).contains(
      "unresolved boundaries: " +
      certificate.unresolved_boundaries.length().to_string(),
    ),
  )
}

///|
test "review impact with a package finds the public entry" {
  let dir = "review_wbtest_pkg_entries"
  @fs.create_dir(dir) catch {
    @fs.IOError(msg) => fail("create_dir failed: \{msg}")
  }
  let source = "pub fn api() -> Int {\n  helper()\n}\nfn helper() -> Int {\n  1\n}\n"
  write_review_probe(dir + "/a.mbt", source)
  let loaded = load_review_package(dir)
  let certificate = match loaded {
    None => {
      remove_review_package(dir, ["a.mbt"])
      fail("expected a package index for " + dir)
    }
    Some(context) => review_impact(dir + "/a.mbt", [5], Some(context))
  }
  remove_review_package(dir, ["a.mbt"])
  assert_eq(certificate.affected_functions, ["helper"])
  assert_eq(certificate.reachable_entries, ["api (public api)"])
}

///|
test "review impact with a package finds the sibling file" {
  let dir = "review_wbtest_pkg_cross"
  @fs.create_dir(dir) catch {
    @fs.IOError(msg) => fail("create_dir failed: \{msg}")
  }
  write_review_probe(dir + "/a.mbt", "fn use() -> Int {\n  gate(1)\n}\n")
  write_review_probe(dir + "/b.mbt", "fn gate(v : Int) -> Int {\n  v + 1\n}\n")
  let loaded = load_review_package(dir)
  let certificate = match loaded {
    None => {
      remove_review_package(dir, ["a.mbt", "b.mbt"])
      fail("expected a package index for " + dir)
    }
    Some(context) => review_impact(dir + "/a.mbt", [2], Some(context))
  }
  remove_review_package(dir, ["a.mbt", "b.mbt"])
  assert_eq(certificate.cross_package_files, [dir + "/b.mbt"])
  assert_eq(certificate.unresolved_boundaries, [])
}

///|
test "review impact with a package finds related tests" {
  let dir = "review_wbtest_pkg_tests"
  @fs.create_dir(dir) catch {
    @fs.IOError(msg) => fail("create_dir failed: \{msg}")
  }
  write_review_probe(dir + "/a.mbt", "fn checked() -> Int {\n  1\n}\n")
  write_review_probe(
    dir + "/a_test.mbt",
    "test \"checked\" {\n  assert_eq(checked(), 1)\n}\n",
  )
  let loaded = load_review_package(dir)
  let certificate = match loaded {
    None => {
      remove_review_package(dir, ["a.mbt", "a_test.mbt"])
      fail("expected a package index for " + dir)
    }
    Some(context) => review_impact(dir + "/a.mbt", [2], Some(context))
  }
  remove_review_package(dir, ["a.mbt", "a_test.mbt"])
  assert_true(certificate.related_tests.length() > 0)
  assert_true(certificate.related_tests[0].has_prefix(dir + "/a_test.mbt:"))
  assert_true(certificate.related_tests[0].contains("checked"))
  assert_true(
    impact_text(certificate).contains("related tests: " + dir + "/a_test.mbt:"),
  )
}

///|
test "load review package returns none for an unusable directory" {
  match load_review_package("review_wbtest_no_such_dir") {
    None => ()
    Some(_) => fail("expected no package for a missing directory")
  }
}
