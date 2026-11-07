// Tests for `moon.mod` parsing.
//
// The helpers return the value a caller would read, or the error reason prefixed
// with `!`, so a failing assertion shows why the parse failed instead of only
// that it did.

///|
fn mod_name_of(source : String) -> String {
  match @workspace.parse_mod(source) {
    Ok(manifest) => manifest.name
    Err(error) => "!" + error.reason
  }
}

///|
fn mod_version_of(source : String) -> String {
  match @workspace.parse_mod(source) {
    Ok(manifest) => manifest.version
    Err(error) => "!" + error.reason
  }
}

///|
fn mod_imports_of(source : String) -> Array[String] {
  match @workspace.parse_mod(source) {
    Ok(manifest) => manifest.imports
    Err(error) => ["!" + error.reason]
  }
}

///|
fn mod_error_of(source : String) -> String {
  match @workspace.parse_mod(source) {
    Ok(_) => ""
    Err(error) => error.reason
  }
}

///|
test "a real module manifest parses its name, version and imports" {
  let source = "// Learn more about moon.mod configuration:\n" +
    "// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html\n" +
    "\n" +
    "name = \"NaIWaniubi/moon-slice\"\n" +
    "\n" +
    "version = \"0.10.2\"\n" +
    "\n" +
    "readme = \"README.mbt.md\"\n" +
    "\n" +
    "repository = \"https://github.com/NaIWaniubi/moon-slice\"\n" +
    "\n" +
    "license = \"Apache-2.0\"\n" +
    "\n" +
    "keywords = [ \"slicing\", \"static-analysis\", \"developer-tools\", \"pdg\" ]\n" +
    "\n" +
    "preferred_target = \"wasm\"\n" +
    "\n" +
    "description = \"Program slicing, dependency graphs, and data-flow paths for MoonBit\"\n" +
    "\n" +
    "import {\n" +
    "  \"moonbitlang/async@0.22.4\",\n" +
    "  \"moonbitlang/parser@0.4.6\",\n" +
    "  \"moonbitlang/x@0.5.1\",\n" +
    "}\n"
  assert_eq(mod_name_of(source), "NaIWaniubi/moon-slice")
  assert_eq(mod_version_of(source), "0.10.2")
  assert_eq(mod_imports_of(source), [
    "moonbitlang/async@0.22.4",
    "moonbitlang/parser@0.4.6",
    "moonbitlang/x@0.5.1",
  ])
  assert_eq(mod_error_of(source), "")
}

///|
test "a commented-out import is not a dependency" {
  let source = "name = \"a/b\"\n" +
    "// import {\n" +
    "//   \"moonbitlang/x\",\n" +
    "// }\n" +
    "import {\n" +
    "  \"moonbitlang/parser\",\n" +
    "}\n"
  assert_eq(mod_imports_of(source), ["moonbitlang/parser"])
}

///|
test "a block comment between entries is ignored" {
  let source = "/* generated, do not edit */ name = \"a/b\"\n" +
    "version = \"1.2.3\" /* trailing */\n"
  assert_eq(mod_name_of(source), "a/b")
  assert_eq(mod_version_of(source), "1.2.3")
  assert_eq(mod_error_of(source), "")
}

///|
test "a trailing comma after the last import is accepted" {
  let source = "name = \"a/b\"\nimport {\n  \"x/y\",\n  \"y/z\",\n}\n"
  assert_eq(mod_imports_of(source), ["x/y", "y/z"])
}

///|
test "duplicate imports collapse to one entry" {
  let source = "name = \"a/b\"\nimport {\n  \"x/y\",\n  \"x/y\",\n}\n"
  assert_eq(mod_imports_of(source), ["x/y"])
}

///|
test "an absent version falls back to 0.0.0" {
  assert_eq(mod_version_of("name = \"a/b\"\n"), "0.0.0")
}

///|
test "unknown keys and array values are stepped over" {
  let source = "keywords = [ \"slicing\", \"pdg\" ]\n" +
    "preferred_target = \"wasm\"\n" +
    "name = \"a/b\"\n" +
    "targets = [ \"wasm\", \"js\" ]\n" +
    "version = \"2.0.0\"\n"
  assert_eq(mod_name_of(source), "a/b")
  assert_eq(mod_version_of(source), "2.0.0")
}

///|
test "a missing name is an error with a reason" {
  let reason = mod_error_of("version = \"1.0.0\"\n")
  assert_true(reason.contains("name"))
  assert_eq(mod_name_of("version = \"1.0.0\"\n"), "!missing `name` field")
}

///|
test "a name that is not a quoted string is an error" {
  let reason = mod_error_of("name = 42\n")
  assert_true(reason.contains("name"))
  assert_true(reason.contains("line 1"))
}

///|
test "an unterminated string is an error, not a panic" {
  let reason = mod_error_of("name = \"a/b\n")
  assert_true(reason.contains("unterminated string"))
  assert_true(reason.contains("line 1"))
}

///|
test "an unterminated block comment is an error" {
  let reason = mod_error_of("/* name = \"a/b\"\n")
  assert_true(reason.contains("unterminated block comment"))
}

///|
test "a stray closing brace is an error" {
  let reason = mod_error_of("name = \"a/b\"\n}\n")
  assert_true(reason.contains("unmatched"))
}

///|
test "an empty manifest is an error rather than an empty module" {
  let reason = mod_error_of("")
  assert_eq(reason, "missing `name` field")
}

///|
test "an unclosed import block is an error" {
  let reason = mod_error_of("name = \"a/b\"\nimport {\n  \"x/y\",\n")
  assert_true(reason.contains("unterminated import block"))
}
