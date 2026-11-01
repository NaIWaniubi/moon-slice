// Directives are parsed from source text, so every case here is a small file
// and the assertion is on the resolved line number plus the rule it silences.

///|
fn only(source : String) -> @suppress.Directive {
  let directives = @suppress.parse(source)
  let n = directives.items.length()
  if n != 1 {
    abort("expected exactly one directive, got " + n.to_string())
  }
  directives.items[0]
}

///|
test "a trailing directive applies to its own line" {
  let directive = only("fn f() {\n  let a = 1 // moon-slice: ignore dead-store\n}\n")
  assert_eq(directive.line, 2)
  assert_eq(directive.rules, ["dead-store"])
}

///|
test "a bare ignore silences every rule" {
  let directives = @suppress.parse("let a = 1 // moon-slice: ignore\n")
  assert_true(@suppress.suppresses(directives, 1, "dead-store"))
  assert_true(@suppress.suppresses(directives, 1, "unreachable-code"))
  assert_true(@suppress.suppresses(directives, 1, "unused-function"))
  // "every rule" is literal: a rule added later is covered without editing the
  // directive, which is why the bare form is worth having.
  assert_true(@suppress.suppresses(directives, 1, "a-rule-added-later"))
  assert_false(@suppress.suppresses(directives, 2, "dead-store"))
}

///|
test "a named rule does not silence its neighbours" {
  let directives = @suppress.parse("let a = 1 // moon-slice: ignore dead-store\n")
  assert_true(@suppress.suppresses(directives, 1, "dead-store"))
  assert_false(@suppress.suppresses(directives, 1, "unreachable-code"))
  assert_false(@suppress.suppresses(directives, 2, "dead-store"))
}

///|
test "a standalone directive applies to the next line of code" {
  let directive = only("// moon-slice: ignore unused-function\nfn helper() -> Unit {}\n")
  assert_eq(directive.line, 2)
  assert_eq(directive.rules, ["unused-function"])
}

///|
test "a standalone directive skips blanks and comments" {
  let directive = only(
    "// moon-slice: ignore\n\n// a note about the function below\nfn helper() -> Unit {}\n" +
    "fn other() -> Unit {}\n",
  )
  assert_eq(directive.line, 4)
}

///|
test "the bracket form carries several rules" {
  let directive = only("let a = 1 // moon-slice: ignore[dead-store, unreachable-code]\n")
  assert_eq(directive.rules, ["dead-store", "unreachable-code"])
}

///|
test "rules can be separated by spaces instead of commas" {
  let directive = only("let a = 1 // moon-slice: ignore dead-store unreachable-code\n")
  assert_eq(directive.rules, ["dead-store", "unreachable-code"])
}

///|
test "a repeated rule is recorded once" {
  let directive = only("let a = 1 // moon-slice: ignore[dead-store, dead-store]\n")
  assert_eq(directive.rules.length(), 1)
}

///|
test "an unknown rule name leaves the directive inert" {
  let directives = @suppress.parse("let a = 1 // moon-slice: ignore dead_stores\n")
  assert_eq(@suppress.count(directives), 0)
  assert_false(@suppress.suppresses(directives, 1, "dead-store"))
}

///|
test "an unknown name next to a known one rejects the whole directive" {
  let directives = @suppress.parse(
    "let a = 1 // moon-slice: ignore[dead-store, dead-stores]\n",
  )
  assert_eq(@suppress.count(directives), 0)
  assert_false(@suppress.suppresses(directives, 1, "dead-store"))
}

///|
test "the marker must sit inside a comment" {
  let directives = @suppress.parse("let note = 1 moon-slice: ignore\n")
  assert_eq(@suppress.count(directives), 0)
}

///|
test "an unterminated bracket is not a directive" {
  let directives = @suppress.parse("let a = 1 // moon-slice: ignore[dead-store\n")
  assert_eq(@suppress.count(directives), 0)
}

///|
test "an empty bracket list is not a directive" {
  let directives = @suppress.parse("let a = 1 // moon-slice: ignore[]\n")
  assert_eq(@suppress.count(directives), 0)
}

///|
test "a marker inside a string literal does not silence the line" {
  let directives = @suppress.parse("let s = \"// moon-slice: ignore\"\n")
  assert_eq(@suppress.count(directives), 0)
  assert_false(@suppress.suppresses(directives, 1, "dead-store"))
}

///|
test "a bare word that is not ignore is not a directive" {
  let directives = @suppress.parse("let a = 1 // moon-slice: silence dead-store\n")
  assert_eq(@suppress.count(directives), 0)
}

///|
test "CRLF files resolve the same lines as LF files" {
  let directive = only("// moon-slice: ignore\r\nfn helper() -> Unit {}\r\n")
  assert_eq(directive.line, 2)
  assert_true(@suppress.suppresses(@suppress.parse("let a = 1 // moon-slice: ignore\r\n"), 1, "dead-store"))
}

///|
test "a trailing directive at end of file has no line to cover" {
  let directives = @suppress.parse("fn f() {\n}\n// moon-slice: ignore\n")
  assert_eq(@suppress.count(directives), 0)
}

///|
test "a file without directives has none" {
  let directives = @suppress.parse("fn f() {\n  let a = 1\n}\n")
  assert_eq(@suppress.count(directives), 0)
  assert_false(@suppress.suppresses(directives, 2, "dead-store"))
}

///|
test "empty() behaves like a file without directives" {
  let directives = @suppress.empty()
  assert_eq(@suppress.count(directives), 0)
  assert_false(@suppress.suppresses(directives, 1, "dead-store"))
}

///|
test "several directives in one file are all recorded" {
  let directives = @suppress.parse(
    "let a = 1 // moon-slice: ignore dead-store\n" +
    "let b = 2 // moon-slice: ignore\n" +
    "fn f() {}\n",
  )
  assert_eq(@suppress.count(directives), 2)
  assert_true(@suppress.suppresses(directives, 1, "dead-store"))
  assert_false(@suppress.suppresses(directives, 1, "unreachable-code"))
  assert_true(@suppress.suppresses(directives, 2, "unreachable-code"))
}

///|
test "indentation before a standalone directive is still standalone" {
  let directive = only("    // moon-slice: ignore\n    let a = 1\n")
  assert_eq(directive.line, 2)
}
