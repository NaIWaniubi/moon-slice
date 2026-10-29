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
