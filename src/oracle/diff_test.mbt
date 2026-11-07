// Differential tests: the pipeline against the reference slicer.
//
// Four shapes the pipeline claims to handle exactly (straight line, branch,
// loop, call) must agree on every criterion and in both directions. The
// remaining tests record the two places where the syntax-directed control
// dependence deliberately over-approximates, with the exact edges it adds, so a
// future change to `cdg` fails here with the reason attached.

///|
fn d_straight() -> String {
  "fn f(a : Int, b : Int) -> Int {\n  let mut x = a + b\n  let y = x * 2\n  y\n}\n"
}

///|
fn d_branch() -> String {
  "fn f(a : Int, b : Int) -> Int {\n  let mut x = a\n  if a < b {\n    x = b\n  } else {\n    x = a + 1\n  }\n  let y = x\n  y\n}\n"
}

///|
fn d_loop() -> String {
  "fn f(a : Int, b : Int) -> Int {\n  let mut x = a\n  while x < b {\n    x = x + 1\n    a = a + x\n  }\n  let y = x\n  y\n}\n"
}

///|
fn d_call() -> String {
  "fn helper(x : Int) -> Int {\n  x + 1\n}\n\nfn f(a : Int) -> Int {\n  let x = helper(a)\n  let y = helper(x)\n  y\n}\n"
}

///|
test "differential check agrees on a straight line" {
  let result = @oracle.differential_check(d_straight())
  assert_true(!result.truncated)
  assert_true(result.agree)
  assert_eq(result.missing.length(), 0)
  assert_eq(result.extra.length(), 0)
  assert_eq(result.reference_size, result.actual_size)
}

///|
test "differential check agrees on a branch" {
  let result = @oracle.differential_check(d_branch())
  assert_true(result.agree)
  assert_true(!result.forward)
  assert_true(result.reference_size > 0)
}

///|
test "differential check agrees on a loop" {
  let result = @oracle.differential_check(d_loop())
  assert_true(result.agree)
  assert_eq(result.missing.length(), 0)
  assert_eq(result.extra.length(), 0)
}

///|
test "differential check agrees on a call" {
  let result = @oracle.differential_check(d_call())
  assert_true(result.agree)
  let program = @oracle.parse(d_call())
  assert_eq(program.functions.length(), 2)
}

///|
test "differential relations match pair for pair on flat control flow" {
  let sources : Array[String] = [d_straight(), d_branch(), d_loop(), d_call()]
  for source in sources {
    let rel = @oracle.differential_relations(source)
    assert_eq(rel.data_missing.length(), 0)
    assert_eq(rel.data_extra.length(), 0)
    assert_eq(rel.control_missing.length(), 0)
    assert_eq(rel.control_extra.length(), 0)
  }
}

///|
test "differential check covers every criterion in both directions" {
  let results = @oracle.differential_check_all(d_branch())
  let program = @oracle.parse(d_branch())
  assert_eq(results.length(), program.nodes.length() * 2)
  let mut agreeing = 0
  for result in results {
    if result.agree {
      agreeing = agreeing + 1
    }
  }
  assert_eq(agreeing, results.length())
}

///|
test "differential check at one criterion and direction agrees" {
  let backward = @oracle.differential_check_at(d_loop(), 5, false)
  let forward = @oracle.differential_check_at(d_loop(), 1, true)
  assert_true(backward.agree)
  assert_true(forward.agree)
  assert_true(forward.forward)
  assert_eq(forward.criterion, 1)
}

///|
test "the default criterion is the function result, never the exit node" {
  let program = @oracle.parse(d_straight())
  let criterion = @oracle.default_criterion(program)
  let exits : Array[Int32] = []
  for function in program.functions {
    exits.push(function.exit)
  }
  let mut found = false
  for id in exits {
    if id == criterion {
      found = true
    }
  }
  assert_true(!found)
  // The result expression is the last node before the exit.
  let mut last = -1
  for node in program.nodes {
    if node.id != exits[0] && node.id > last {
      last = node.id
    }
  }
  assert_eq(criterion, last)
}

///|
test "an unparseable source is reported as undecided, not as agreement" {
  let result = @oracle.differential_check("fn f( {\n")
  assert_true(result.truncated)
  assert_true(!result.agree)
  assert_eq(result.reference_size, 0)
  assert_eq(result.actual_size, 0)
}

///|
test "every generated program agrees on every slice" {
  let seeds : Array[Int32] = []
  let mut seed = 1
  while seed <= 40 {
    seeds.push(seed)
    seed = seed + 1
  }
  for seed in seeds {
    let source = @oracle.generate(seed)
    let results = @oracle.differential_check_all(source)
    let mut idx = 0
    while idx < results.length() {
      assert_true(results[idx].agree)
      idx = idx + 1
    }
  }
}

///|
test "batch of 100 seeds agrees on every decided slice" {
  let seeds : Array[Int32] = []
  let mut seed = 1
  while seed <= 100 {
    seeds.push(seed)
    seed = seed + 1
  }
  let batch = @oracle.batch_check(seeds)
  assert_eq(batch.programs, 100)
  assert_true(batch.comparisons > 1000)
  assert_eq(batch.skipped, 0)
  assert_eq(batch.failures.length(), 0)
  assert_eq(batch.agreeing, batch.comparisons)
  assert_eq(@oracle.agreement_rate(batch), 1.0)
}

///|
test "agreement rate of an empty batch is zero, not one" {
  let batch = @oracle.batch_check([])
  assert_eq(batch.comparisons, 0)
  assert_eq(@oracle.agreement_rate(batch), 0.0)
}

// ---------------------------------------------------------------------------
// Known divergences: the syntax-directed control dependence over-approximates.
//
// These are not wrong answers: CONTRACT.md requires the analysis to include a
// statement that might not matter and never to drop one that does. Each test
// pins down the exact extra edges, so a change in that behaviour is visible.
// ---------------------------------------------------------------------------

///|
fn d_nested_if() -> String {
  "fn f(a : Int, b : Int) -> Int {\n  let mut x = a\n  if a < b {\n    if a < 1 {\n      x = 2\n    }\n  }\n  x\n}\n"
}

///|
fn d_return_in_if() -> String {
  "fn f(a : Int) -> Int {\n  let mut x = a\n  if a < 1 {\n    return 2\n  }\n  x = 3\n  x\n}\n"
}

///|
fn d_nested_while() -> String {
  "fn f(a : Int, b : Int) -> Int {\n  let mut x = a\n  while b < 3 {\n    while x < 4 {\n      x = x + 1\n    }\n    b = b + 1\n  }\n  x\n}\n"
}

///|
fn d_if_in_while() -> String {
  "fn f(a : Int, b : Int) -> Int {\n  let mut x = a\n  while b < 3 {\n    if x < 2 {\n      x = x + 1\n    }\n    b = b + 1\n  }\n  x\n}\n"
}

///|
test "known divergence: a nested control node is attributed to its outer head" {
  let rel = @oracle.differential_relations(d_nested_if())
  // No data-flow difference at all; only the nesting rule of `cdg.build`, which
  // attributes the inner region and its statement to the outer `if` as well.
  assert_eq(rel.data_extra.length(), 0)
  assert_eq(rel.data_missing.length(), 0)
  assert_eq(t_pairs(rel.control_missing), "[]")
  assert_eq(t_pairs(rel.control_extra), "[(2, 5), (2, 6)]")
}

///|
test "known divergence: nested control edges change no slice" {
  // The extra control edges are reachability-redundant: the outer head already
  // reaches every descendant through the inner head and its region.
  let results = @oracle.differential_check_all(d_nested_if())
  for result in results {
    assert_true(result.agree)
  }
}

///|
test "known divergence: nested while is attributed to the outer loop" {
  let rel = @oracle.differential_relations(d_nested_while())
  assert_eq(rel.data_extra.length(), 0)
  assert_eq(rel.data_missing.length(), 0)
  assert_eq(t_pairs(rel.control_extra), "[(2, 5), (2, 6)]")
  let results = @oracle.differential_check_all(d_nested_while())
  for result in results {
    assert_true(result.agree)
  }
}

///|
test "known divergence: an if inside a loop is attributed to the loop" {
  let rel = @oracle.differential_relations(d_if_in_while())
  assert_eq(t_pairs(rel.control_extra), "[(2, 5), (2, 6)]")
  let results = @oracle.differential_check_all(d_if_in_while())
  for result in results {
    assert_true(result.agree)
  }
}

///|
test "known divergence: the escape rule marks the exit as controlled" {
  let rel = @oracle.differential_relations(d_return_in_if())
  // A `return` inside the `if` makes `cdg.build` mark the code an abrupt exit
  // could skip. The exit node is included; the reference never marks it,
  // because every path ends there.
  assert_eq(rel.data_extra.length(), 0)
  assert_eq(rel.data_missing.length(), 0)
  assert_eq(t_pairs(rel.control_extra), "[(2, 7), (3, 7)]")
  // A forward slice from the entry therefore picks up the exit node.
  let forward = @oracle.differential_check_at(d_return_in_if(), 0, true)
  assert_true(!forward.agree)
  assert_eq(t_ints(forward.extra), "[7]")
  assert_eq(t_ints(forward.missing), "[]")
  // Every backward slice still agrees: the exit node has no outgoing edge.
  let backward = @oracle.differential_check_at(d_return_in_if(), 6, false)
  assert_true(backward.agree)
}
