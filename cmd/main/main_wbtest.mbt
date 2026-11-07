// Whitebox tests for the scan helpers: path normalisation decides whether a
// baseline entry matches, and the directory filter decides what is scanned.

///|
test "only .mbt files are scanned" {
  assert_true(is_mbt_file("a.mbt"))
  assert_true(is_mbt_file("src/parser_adapter.mbt"))
  assert_true(!is_mbt_file("a.mbt.bak"))
  assert_true(!is_mbt_file("notes.md"))
}

///|
test "baseline keys normalise separators and a leading ./" {
  assert_eq(baseline_key(".\\src\\a.mbt", 3), "src/a.mbt:3")
  assert_eq(baseline_key("./src/a.mbt", 12), "src/a.mbt:12")
  assert_eq(baseline_key("src/a.mbt", 1), "src/a.mbt:1")
}

///|
test "build and vcs directories are skipped" {
  assert_true(skip_scan_dir(".git"))
  assert_true(skip_scan_dir("_build"))
  assert_true(skip_scan_dir(".mooncakes"))
  assert_true(skip_scan_dir("node_modules"))
  assert_true(!skip_scan_dir("src"))
}

// ---------------------------------------------------------------------------
// Rendering of the package commands
// ---------------------------------------------------------------------------

///|
test "a live path prints one line per frame, the first one as the root" {
  let path : @roots.LivePath = {
    steps: [
      @roots.PathStep::{ function_name: "main", path: "a.mbt", line: 9 },
      @roots.PathStep::{ function_name: "middle", path: "a.mbt", line: 10 },
      @roots.PathStep::{ function_name: "leaf", path: "a.mbt", line: 6 },
    ],
  }
  assert_eq(
    render_live_path(path),
    "a.mbt:9: main (root)\na.mbt:10: main -> middle\na.mbt:6: middle -> leaf",
  )
}

///|
test "a one-step live path is a root explaining itself" {
  let path : @roots.LivePath = {
    steps: [@roots.PathStep::{ function_name: "api", path: "b.mbt", line: 1 }],
  }
  assert_eq(render_live_path(path), "b.mbt:1: api (root)")
}

///|
test "the dead explanation prints roots, evidence and boundaries in order" {
  let explanation : @roots.DeadExplanation = {
    function_name: "orphan",
    path: "a.mbt",
    line: 13,
    root_summary: ["entry point: main at a.mbt:9"],
    searched_files: 1,
    searched_functions: 2,
    evidence: ["no function in the package calls or mentions `orphan`"],
    boundaries: ["a.mbt:10: call to `println` leaves the package"],
  }
  assert_eq(
    render_dead(explanation),
    "function: orphan\n" +
    "declared: a.mbt:13\n" +
    "searched: 1 file(s), 2 function(s)\n" +
    "roots (1):\n" +
    "  entry point: main at a.mbt:9\n" +
    "evidence:\n" +
    "  - no function in the package calls or mentions `orphan`\n" +
    "boundaries (1):\n" +
    "  - a.mbt:10: call to `println` leaves the package\n",
  )
}

///|
test "coverage reason order is fixed and complete" {
  assert_eq(coverage_reasons().map(@resolve.reason_name), [
    "unknown_receiver_type",
    "method_not_declared",
    "external_package",
    "dynamic_value",
  ])
}

///|
test "coverage json keeps the invariant and every reason key" {
  let rendered = coverage_json(3, @resolve.empty_report(), [])
  assert_eq(
    rendered,
    "{\"files\":3,\"total\":0,\"resolved\":0,\"ambiguous\":0,\"unresolved\":0," +
    "\"by_reason\":{\"unknown_receiver_type\":0,\"method_not_declared\":0," +
    "\"external_package\":0,\"dynamic_value\":0},\"errors\":[]}",
  )
}

///|
test "steps json escapes names and keeps the file:line site" {
  let steps : Array[@roots.PathStep] = [
    @roots.PathStep::{ function_name: "a\"b", path: "x/y.mbt", line: 7 },
  ]
  assert_eq(
    steps_json(steps),
    "[{\"function\":\"a\\\"b\",\"file\":\"x/y.mbt\",\"line\":7}]",
  )
}
