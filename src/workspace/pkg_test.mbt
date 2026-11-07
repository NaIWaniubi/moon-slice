// Tests for `moon.pkg` parsing.

///|
fn pkg_imports_of(source : String) -> Array[String] {
  match @workspace.parse_pkg(source) {
    Ok(manifest) => manifest.imports
    Err(error) => ["!" + error.reason]
  }
}

///|
fn pkg_test_imports_of(source : String) -> Array[String] {
  match @workspace.parse_pkg(source) {
    Ok(manifest) => manifest.test_imports
    Err(error) => ["!" + error.reason]
  }
}

///|
fn pkg_kind_of(source : String) -> String {
  match @workspace.parse_pkg(source) {
    Ok(manifest) => @workspace.pkgtype_text(manifest.pkgtype)
    Err(error) => "!" + error.reason
  }
}

///|
fn pkg_is_main_of(source : String) -> Bool {
  match @workspace.parse_pkg(source) {
    Ok(manifest) => manifest.is_main
    Err(_) => false
  }
}

///|
fn pkg_error_of(source : String) -> String {
  match @workspace.parse_pkg(source) {
    Ok(_) => ""
    Err(error) => error.reason
  }
}

///|
test "an empty package manifest is a library with no dependencies" {
  assert_eq(pkg_imports_of(""), [])
  assert_eq(pkg_kind_of(""), "library")
  assert_false(pkg_is_main_of(""))
  assert_eq(pkg_error_of(""), "")
}

///|
test "the import block is read in declaration order" {
  let source = "import {\n  \"moonbitlang/parser\",\n  \"moonbitlang/x\",\n}\n"
  assert_eq(pkg_imports_of(source), ["moonbitlang/parser", "moonbitlang/x"])
}

///|
test "pkgtype names the package kind" {
  assert_eq(pkg_kind_of("pkgtype = \"executable\"\n"), "executable")
  assert_eq(pkg_kind_of("pkgtype = \"test\"\n"), "test")
  assert_eq(pkg_kind_of("pkgtype = \"wbtest\"\n"), "wbtest")
  assert_eq(pkg_kind_of("pkgtype = \"library\"\n"), "library")
}

///|
test "an unknown pkgtype is preserved instead of rejected" {
  assert_eq(pkg_kind_of("pkgtype = \"weird-kind\"\n"), "weird-kind")
  assert_eq(pkg_error_of("pkgtype = \"weird-kind\"\n"), "")
}

///|
test "is-main marks an executable" {
  assert_true(pkg_is_main_of("is-main = true\n"))
  assert_false(pkg_is_main_of("is-main = false\n"))
}

///|
test "a scoped import is a test-only dependency" {
  let source = "import {\n  \"NaIWaniubi/moon-slice/src/core\",\n}\n" +
    "\n" +
    "import {\n  \"NaIWaniubi/moon-slice/src/core\",\n} for \"test\"\n"
  assert_eq(pkg_imports_of(source), ["NaIWaniubi/moon-slice/src/core"])
  assert_eq(pkg_test_imports_of(source), ["NaIWaniubi/moon-slice/src/core"])
}

///|
test "test-import is a test-only dependency" {
  let source = "import {\n  \"a/b\",\n}\n\ntest-import {\n  \"c/d\",\n}\n"
  assert_eq(pkg_imports_of(source), ["a/b"])
  assert_eq(pkg_test_imports_of(source), ["c/d"])
}

///|
test "wbtest-import is a test-only dependency" {
  let source = "wbtest-import {\n  \"c/d\",\n}\n"
  assert_eq(pkg_imports_of(source), [])
  assert_eq(pkg_test_imports_of(source), ["c/d"])
}

///|
test "other keys such as warnings are stepped over" {
  let source = "warnings = \"-79\"\n\nimport {\n  \"a/b\",\n}\n"
  assert_eq(pkg_imports_of(source), ["a/b"])
  assert_eq(pkg_error_of(source), "")
}

///|
test "comments are allowed in a package manifest" {
  let source = "// the analysis pass depends on nothing\n" +
    "import {\n  // shared model\n  \"NaIWaniubi/moon-slice/src/core\",\n}\n"
  assert_eq(pkg_imports_of(source), ["NaIWaniubi/moon-slice/src/core"])
}

///|
test "an unterminated import block is an error" {
  let reason = pkg_error_of("import {\n  \"a/b\",\n")
  assert_true(reason.contains("unterminated"))
  assert_true(reason.contains("import"))
}

///|
test "a pkgtype that is not a quoted string is an error" {
  let reason = pkg_error_of("pkgtype = 1\n")
  assert_true(reason.contains("pkgtype"))
  assert_true(reason.contains("line 1"))
}

///|
test "a stray closing brace is an error" {
  let reason = pkg_error_of("}\n")
  assert_true(reason.contains("unmatched"))
}

///|
test "duplicate imports collapse to one entry" {
  let source = "import {\n  \"a/b\",\n  \"a/b\",\n}\n"
  assert_eq(pkg_imports_of(source), ["a/b"])
}
