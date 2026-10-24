///|
test "parser dependency smoke" {
  let source = "fn add(a : Int, b : Int) -> Int { a + b }"
  let (impls, reports) = @parser.parse_string(source, name="smoke.mbt")
  assert_eq(impls.length(), 1)
  assert_eq(reports.length(), 0)
}
