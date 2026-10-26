// Robustness tests: the whole pipeline must never crash on input it does not model.
//
// The adapter's contract for anything outside the modeled subset is: emit one
// `Expr` node whose uses are the identifiers in that subtree. These tests push
// every awkward construct this compiler accepts through parse -> CFG -> def-use
// and assert the run completes with well-formed output. They do not assert a
// particular node shape for the unsupported forms, only that nothing panics and
// that the invariants the downstream passes rely on still hold.
//
// This suite lives in `defuse` because that package is the only one that already
// depends on both the adapter and the CFG; putting it in `parser_adapter` would
// require a cycle back to `defuse`.

///|
/// Run the whole pipeline and return the three artifacts, so a crash surfaces
/// here rather than in a consumer.
fn run_pipeline(source : String) -> (@core.Program, @core.Cfg, @core.DefUse) {
  let program = @parser_adapter.parse_source(source, "robust.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  (program, cfg, defuse)
}

///|
/// Structural invariants every emitted program must satisfy. Violating any of
/// these would break the CFG or the data-flow pass, so they are checked for
/// every input rather than for a hand-picked one.
fn check_invariants(
  program : @core.Program,
  cfg : @core.Cfg,
  defuse : @core.DefUse,
) -> Unit raise {
  let count = program.nodes.length()
  // Node ids are dense and equal to their index, which the CFG indexes by.
  let mut i = 0
  while i < count {
    assert_eq(program.nodes[i].id, i)
    // A child id always names a node that exists.
    program.nodes[i].children.each(child => {
      assert_true(child >= 0 && child < count)
    })
    // A parent id, when present, names a node that exists.
    match program.nodes[i].parent {
      Some(owner) => assert_true(owner >= 0 && owner < count)
      None => ()
    }
    i = i + 1
  }
  // Every CFG endpoint names a node that exists.
  cfg.edges.each(edge => {
    assert_true(edge.0 >= 0 && edge.0 < count)
    assert_true(edge.1 >= 0 && edge.1 < count)
  })
  // Every reaching pair names a node that exists.
  defuse.reaching.each(pair => {
    assert_true(pair.0 >= 0 && pair.0 < count)
    assert_true(pair.1 >= 0 && pair.1 < count)
  })
  // A function's entry and exit are real nodes, with entry first.
  program.functions.each(function => {
    assert_true(function.entry >= 0 && function.entry < count)
    assert_true(function.exit >= 0 && function.exit < count)
    assert_true(function.entry < function.exit)
  })
}

///|
test "unsupported expression forms do not crash the pipeline" {
  let sources : Array[String] = [
    // try / catch
    "fn f(a : Int) -> Int {\n  try { a } catch {\n    _ => 0\n  }\n}\n",
    // labelled block
     "fn f(a : Int) -> Int {\n  lbl~: { a }\n}\n",
    // record construction and update
     "fn f(a : Int) -> R {\n  { x: a, y: 1 }\n}\n", "fn f(r : R, a : Int) -> R {\n  { ..r, x: a }\n}\n",
    // pipe and reverse pipe
     "fn f(a : Int) -> Int {\n  a |> g\n}\n",
    // tuple
     "fn f(a : Int, b : Int) -> (Int, Int) {\n  (a, b)\n}\n",
    // array literal and spread
     "fn f(a : Int) -> Array[Int] {\n  [a, 1, 2]\n}\n",
    // list comprehension
     "fn f(xs : Array[Int]) -> Array[Int] {\n  [for x in xs => x]\n}\n",
    // interpolated string
     "fn f(a : Int) -> String {\n  \"v=\\{a}\"\n}\n",
    // lambda in expression position
     "fn f(a : Int) -> (Int) -> Int {\n  fn(y) { y + a }\n}\n",
    // as-cast and constraint
     "fn f(a : Int) -> Int {\n  (a : Int)\n}\n",
    // defer
     "fn f(a : Int) -> Int {\n  defer { g(a) }\n  a\n}\n",
    // raise
     "fn f(a : Int) -> Int raise {\n  if a > 0 { raise E }\n  a\n}\n",
  ]
  sources.each(source => {
    let (program, cfg, defuse) = run_pipeline(source)
    check_invariants(program, cfg, defuse)
  })
}

///|
test "malformed source reports errors without crashing" {
  let sources : Array[String] = [
    "fn f( {\n", "fn f() -> { }\n", "let = 1\n", "fn f() { if }\n", "fn\n", "@#$%^&\n",
    "fn f() -> Int { 1 } extra_tokens_here\n",
  ]
  sources.each(source => {
    let program = @parser_adapter.parse_source(source, "bad.mbt")
    let cfg = @cfg.build(program)
    let defuse = @defuse.analyze(program, cfg)
    // Either the source parsed (and the invariants hold) or it reported errors.
    // Both outcomes are acceptable; a panic is not.
    if program.errors.length() == 0 {
      check_invariants(program, cfg, defuse)
    } else {
      assert_true(program.errors[0].contains("bad.mbt:"))
    }
  })
}

///|
test "deeply nested blocks stay linear and terminate" {
  // 40 nested ifs: enough to catch a quadratic blowup or a recursion issue,
  // small enough to keep the test fast.
  let mut source = ""
  let mut depth = 0
  while depth < 40 {
    source = source + "if c {\n"
    depth = depth + 1
  }
  source = source + "1\n"
  let mut closing = 0
  while closing < 40 {
    source = source + "}\n"
    closing = closing + 1
  }
  let full = "fn f(c : Bool) -> Int {\n" + source + "}\n"
  let (program, cfg, defuse) = run_pipeline(full)
  check_invariants(program, cfg, defuse)
  assert_eq(program.functions.length(), 1)
  let mut ifs = 0
  program.nodes.each(fn(node) {
    if node.kind == @core.SNodeKind::If {
      ifs = ifs + 1
    }
  })
  assert_true(ifs >= 40)
}

///|
test "a long statement chain stays linear" {
  let mut body = ""
  let mut n = 0
  while n < 200 {
    body = body + "let x" + n.to_string() + " = " + n.to_string() + "\n"
    n = n + 1
  }
  let source = "fn f() -> Int {\n" + body + "0\n}\n"
  let (program, cfg, defuse) = run_pipeline(source)
  check_invariants(program, cfg, defuse)
  // 200 lets + the trailing expression + entry + exit.
  assert_eq(program.nodes.length(), 203)
  assert_eq(program.functions.length(), 1)
}

///|
test "unicode identifiers survive lowering" {
  let source = "fn f(变量 : Int) -> Int {\n  let 结果 = 变量 + 1\n  结果\n}\n"
  let program = @parser_adapter.parse_source(source, "unicode.mbt")
  assert_eq(program.errors.length(), 0)
  assert_eq(program.functions.length(), 1)
  assert_eq(program.nodes[0].defs[0].name, "变量")
  let bind = program.nodes[1]
  assert_eq(bind.defs[0].name, "结果")
  assert_eq(bind.uses[0].name, "变量")
}

///|
test "empty and whitespace-only sources yield an empty program" {
  let sources : Array[String] = [
    "", "   \n\t\n  ", "\n\n\n", "// just a comment\n",
  ]
  sources.each(source => {
    let program = @parser_adapter.parse_source(source, "blank.mbt")
    assert_eq(program.nodes.length(), 0)
    assert_eq(program.functions.length(), 0)
    let cfg = @cfg.build(program)
    assert_eq(cfg.edges.length(), 0)
    let defuse = @defuse.analyze(program, cfg)
    assert_eq(defuse.reaching.length(), 0)
  })
}
