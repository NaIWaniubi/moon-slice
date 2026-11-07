// Tests for the impact certificate. Every case is a small, hand-built input
// with exact expected line sets: the certificate's whole value is that a
// reviewer can trust the proof, so a broad smoke test would prove nothing.

///|
fn pipeline(source : String) -> (@core.Program, @core.Pdg) {
  let program = @parser_adapter.parse_source(source, "a.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  (program, @pdg.build(defuse, cdg))
}

///|
fn certificate(source : String, lines : Array[Int32]) -> @impact.ImpactCertificate {
  let (program, pdg) = pipeline(source)
  @impact.impact(program, pdg, lines)
}

///|
fn affected_lines(certificate : @impact.ImpactCertificate) -> Array[Int32] {
  let out : Array[Int32] = []
  for item in certificate.evidence {
    if !out.contains(item.line) {
      out.push(item.line)
    }
  }
  out.sort()
  out
}

///|
fn package_files(
  sources : Array[(String, String)],
) -> Array[@interproc.PackageFile] {
  let out : Array[@interproc.PackageFile] = []
  for pair in sources {
    match @interproc.build_file(pair.0, pair.1) {
      Some(file) => out.push(file)
      None => ()
    }
  }
  out
}

///|
fn package_reachability(
  sources : Array[(String, String)],
) -> @roots.Reachability {
  @roots.analyze(sources.map(fn(pair) {
    @liveness.collect(pair.0, pair.1)
  }))
}

///|
fn find_file(
  files : Array[@interproc.PackageFile],
  path : String,
) -> @interproc.PackageFile {
  for file in files {
    if file.path == path {
      return file
    }
  }
  abort("missing package file " + path)
}

///|
fn package_certificate(
  sources : Array[(String, String)],
  target : String,
  lines : Array[Int32],
  with_reachability : Bool,
) -> @impact.ImpactCertificate {
  let files = package_files(sources)
  let file = find_file(files, target)
  let index = @interproc.index(files)
  if with_reachability {
    @impact.impact(
      file.program,
      file.pdg,
      lines,
      path=target,
      index=index,
      reachability=package_reachability(sources),
    )
  } else {
    @impact.impact(file.program, file.pdg, lines, path=target, index=index)
  }
}

///|
fn chain_source() -> String {
  "fn chain() -> Int {\n" +
  "  let a = 1\n" +
  "  let b = a + 2\n" +
  "  let c = b * 3\n" +
  "  let unused = 99\n" +
  "  return c\n" +
  "}\n"
}

// ---------------------------------------------------------------------------
// Finding the affected statements
// ---------------------------------------------------------------------------

///|
test "a single changed line reaches its readers" {
  let result = certificate(chain_source(), [2])
  assert_eq(affected_lines(result), [2, 3, 4, 6])
  assert_eq(result.changed_lines, [2])
}

///|
test "a write nothing reads affects only itself" {
  let result = certificate(chain_source(), [5])
  assert_eq(affected_lines(result), [5])
}

///|
test "a line with no node contributes nothing" {
  let result = certificate(chain_source(), [999])
  assert_eq(result.changed_lines, [999])
  assert_eq(result.affected_statements, [])
  assert_eq(result.evidence, [])
}

///|
test "several changed lines union their forward slices" {
  let result = certificate(chain_source(), [2, 5])
  assert_eq(affected_lines(result), [2, 3, 4, 5, 6])
}

///|
test "changed lines are sorted and deduplicated" {
  let result = certificate(chain_source(), [5, 2, 5])
  assert_eq(result.changed_lines, [2, 5])
}

///|
test "an empty change set proves no impact" {
  let result = certificate(chain_source(), [])
  assert_eq(result.changed_lines, [])
  assert_eq(result.affected_statements, [])
  assert_eq(result.affected_functions, [])
  assert_eq(result.evidence, [])
}

///|
test "affected functions are the owners of the affected statements" {
  let source = "fn f() -> Int {\n" +
    "  let x = 1\n" +
    "  x + 1\n" +
    "}\n" +
    "fn g() -> Int {\n" +
    "  let y = 2\n" +
    "  y + 2\n" +
    "}\n"
  let result = certificate(source, [2, 6])
  assert_eq(result.affected_functions, ["f", "g"])
}

///|
test "a change stays inside its own function without expansion" {
  let source = "fn f() -> Int {\n" +
    "  let x = 1\n" +
    "  x + 1\n" +
    "}\n" +
    "fn g() -> Int {\n" +
    "  let y = 2\n" +
    "  y + 2\n" +
    "}\n"
  let result = certificate(source, [2])
  assert_eq(result.affected_functions, ["f"])
}

///|
test "functions_of is sorted and unique" {
  let (program, _) = pipeline(chain_source())
  let names = @impact.functions_of(program, [1, 2, 3, 4, 5, 6])
  assert_eq(names, ["chain"])
}

// ---------------------------------------------------------------------------
// Evidence paths
// ---------------------------------------------------------------------------

///|
test "every affected statement has evidence" {
  let result = certificate(chain_source(), [2])
  assert_eq(result.evidence.length(), result.affected_statements.length())
}

///|
test "evidence begins at a changed statement" {
  let (program, pdg) = pipeline(chain_source())
  let target = match @query.target_node(program, 2) {
    Some(id) => id
    None => abort("no node at line 2")
  }
  let result = @impact.impact(program, pdg, [2])
  for item in result.evidence {
    assert_eq(item.path[0], target)
  }
}

///|
test "evidence follows the dependency chain" {
  let (program, pdg) = pipeline(chain_source())
  let a = match @query.target_node(program, 2) {
    Some(id) => id
    None => abort("no node at line 2")
  }
  let b = match @query.target_node(program, 3) {
    Some(id) => id
    None => abort("no node at line 3")
  }
  let c = match @query.target_node(program, 4) {
    Some(id) => id
    None => abort("no node at line 4")
  }
  let result = @impact.impact(program, pdg, [2])
  let mut found : Array[Int32]? = None
  for item in result.evidence {
    if item.line == 4 {
      found = Some(item.path)
    }
  }
  assert_eq(found, Some([a, b, c]))
}

///|
test "evidence picks the shortest path" {
  let source = "fn f() -> Int {\n" +
    "  let a = 1\n" +
    "  let b = a + 1\n" +
    "  let c = a + b\n" +
    "  c\n" +
    "}\n"
  let (program, pdg) = pipeline(source)
  let a = match @query.target_node(program, 2) {
    Some(id) => id
    None => abort("no node at line 2")
  }
  let c = match @query.target_node(program, 4) {
    Some(id) => id
    None => abort("no node at line 4")
  }
  let result = @impact.impact(program, pdg, [2])
  let mut found : Array[Int32]? = None
  for item in result.evidence {
    if item.line == 4 {
      found = Some(item.path)
    }
  }
  // `a` feeds `c` directly, so the direct edge wins over `a -> b -> c`.
  assert_eq(found, Some([a, c]))
}

///|
test "evidence crosses a control dependency" {
  let source = "fn f(n : Int) -> Int {\n" +
    "  let mut x = 0\n" +
    "  if n > 0 {\n" +
    "    x = 1\n" +
    "  }\n" +
    "  return x\n" +
    "}\n"
  let (program, pdg) = pipeline(source)
  let head = match @query.target_node(program, 3) {
    Some(id) => id
    None => abort("no node at line 3")
  }
  let body = match @query.target_node(program, 4) {
    Some(id) => id
    None => abort("no node at line 4")
  }
  let result = @impact.impact(program, pdg, [3])
  let mut found : Array[Int32]? = None
  for item in result.evidence {
    if item.line == 4 {
      found = Some(item.path)
    }
  }
  assert_eq(found, Some([head, body]))
}

// ---------------------------------------------------------------------------
// Cross-file impact
// ---------------------------------------------------------------------------

///|
test "cross-file impact is empty without a package index" {
  let (program, pdg) = pipeline(chain_source())
  let result = @impact.impact(program, pdg, [2], path="a.mbt")
  assert_eq(result.cross_package_files, [])
}

///|
test "interprocedural expansion lists the sibling file" {
  let sources = [
    ("pkg/a.mbt", "fn use() -> Int {\n  gate(1)\n}\n"),
    ("pkg/b.mbt", "fn gate(v : Int) -> Int {\n  v + 1\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [2], false)
  assert_eq(result.cross_package_files, ["pkg/b.mbt"])
}

///|
test "a same-file callee is not a cross-file impact" {
  let sources = [
    ("pkg/a.mbt", "fn gate(v : Int) -> Int {\n  v + 1\n}\nfn use() -> Int {\n  gate(1)\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [4], false)
  assert_eq(result.cross_package_files, [])
}

///|
test "no cross-file impact when the changed line affects nothing" {
  let sources = [
    ("pkg/a.mbt", "fn use() -> Int {\n  gate(1)\n}\n"),
    ("pkg/b.mbt", "fn gate(v : Int) -> Int {\n  v + 1\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [999], false)
  assert_eq(result.cross_package_files, [])
}

// ---------------------------------------------------------------------------
// Related tests
// ---------------------------------------------------------------------------

///|
test "related tests find the test caller" {
  let sources = [
    ("pkg/a.mbt", "fn checked() -> Int {\n  1\n}\n"),
    ("pkg/a_test.mbt", "test \"checked\" {\n  assert_eq(checked(), 1)\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [2], true)
  assert_true(result.related_tests.length() > 0)
  assert_true(result.related_tests[0].has_prefix("pkg/a_test.mbt:"))
  assert_true(result.related_tests[0].contains("checked"))
}

///|
test "an indirect test caller reaches the affected function" {
  let sources = [
    ("pkg/a.mbt", "fn mid() -> Int {\n  helper()\n}\nfn helper() -> Int {\n  1\n}\n"),
    ("pkg/a_test.mbt", "test \"mid\" {\n  assert_eq(mid(), 1)\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [5], true)
  assert_eq(result.affected_functions, ["helper"])
  assert_true(result.related_tests.length() > 0)
  assert_true(result.related_tests[0].contains("mid"))
}

///|
test "non-test callers are not related tests" {
  let sources = [
    ("pkg/a.mbt", "fn checked() -> Int {\n  1\n}\nfn use() -> Int {\n  checked()\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [2], true)
  assert_eq(result.related_tests, [])
}

///|
test "related tests need the package facts" {
  let (program, pdg) = pipeline("fn checked() -> Int {\n  1\n}\n")
  let result = @impact.impact(program, pdg, [2])
  assert_eq(result.related_tests, [])
}

// ---------------------------------------------------------------------------
// Reachable entries
// ---------------------------------------------------------------------------

///|
test "reachable entries name the public api" {
  let sources = [
    ("pkg/a.mbt", "pub fn api() -> Int {\n  helper()\n}\nfn helper() -> Int {\n  1\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [5], true)
  assert_eq(result.affected_functions, ["helper"])
  assert_eq(result.reachable_entries, ["api (public api)"])
}

///|
test "reachable entries name main" {
  let sources = [
    ("pkg/a.mbt", "fn main {\n  println(helper())\n}\nfn helper() -> Int {\n  1\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [5], true)
  assert_eq(result.reachable_entries, ["main (entry point)"])
}

///|
test "reachable entries cross files through the call graph" {
  let sources = [
    ("pkg/a.mbt", "pub fn api() -> Int {\n  helper()\n}\n"),
    ("pkg/b.mbt", "fn helper() -> Int {\n  1\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/b.mbt", [2], true)
  assert_eq(result.affected_functions, ["helper"])
  assert_eq(result.reachable_entries, ["api (public api)"])
}

///|
test "an unreachable function has no entry" {
  let sources = [
    ("pkg/a.mbt", "fn orphan() -> Int {\n  1\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [2], true)
  assert_eq(result.affected_functions, ["orphan"])
  assert_eq(result.reachable_entries, [])
}

///|
test "reachable entries need the package facts" {
  let (program, pdg) = pipeline("pub fn api() -> Int {\n  helper()\n}\nfn helper() -> Int {\n  1\n}\n")
  let result = @impact.impact(program, pdg, [4])
  assert_eq(result.affected_functions, ["helper"])
  assert_eq(result.reachable_entries, [])
}

// ---------------------------------------------------------------------------
// Unresolved boundaries
// ---------------------------------------------------------------------------

///|
test "a call outside the package is an unresolved boundary" {
  let source = "fn f(x : Int) -> Unit {\n  println(x)\n}\n"
  let (program, pdg) = pipeline(source)
  let result = @impact.impact(program, pdg, [2], path="a.mbt")
  let mut saw = false
  for boundary in result.unresolved_boundaries {
    if boundary.contains("println") {
      saw = true
    }
  }
  assert_true(saw)
  assert_true(result.unresolved_boundaries[0].contains("a.mbt:2"))
}

///|
test "a call inside the program is not a boundary" {
  let source = "fn helper() -> Int {\n  1\n}\nfn f() -> Int {\n  helper()\n}\n"
  let (program, pdg) = pipeline(source)
  let result = @impact.impact(program, pdg, [2])
  assert_eq(result.unresolved_boundaries, [])
}

///|
test "the package index resolves sibling calls" {
  let sources = [
    ("pkg/a.mbt", "fn use() -> Int {\n  gate(1)\n}\n"),
    ("pkg/b.mbt", "fn gate(v : Int) -> Int {\n  v + 1\n}\n"),
  ]
  let result = package_certificate(sources, "pkg/a.mbt", [2], false)
  assert_eq(result.unresolved_boundaries, [])
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

///|
test "json has every certificate field" {
  let result = certificate(chain_source(), [2])
  let json = @impact.certificate_json(result)
  for key in [
      "\"changed_lines\":[2]",
      "\"affected_statements\":",
      "\"affected_functions\":[\"chain\"]",
      "\"reachable_entries\":",
      "\"cross_package_files\":",
      "\"related_tests\":",
      "\"unresolved_boundaries\":",
      "\"evidence\":[",
    ] {
    assert_true(json.contains(key))
  }
}

///|
test "json evidence carries node, line and path" {
  let result = certificate(chain_source(), [2])
  let json = @impact.certificate_json(result)
  assert_true(json.contains("\"node\":"))
  assert_true(json.contains("\"line\":"))
  assert_true(json.contains("\"path\":["))
}

///|
test "text lists functions and the evidence chain" {
  let result = certificate(chain_source(), [2])
  let text = @impact.certificate_text(result)
  assert_true(text.contains("affected functions:"))
  assert_true(text.contains("chain"))
  assert_true(text.contains("evidence:"))
  assert_true(text.contains("->"))
}

///|
test "text says none when nothing is affected" {
  let result = certificate(chain_source(), [999])
  let text = @impact.certificate_text(result)
  assert_true(text.contains("affected functions: (none)"))
  assert_true(text.contains("evidence: (none)"))
}
