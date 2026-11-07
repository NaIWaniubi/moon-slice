// Generator tests: the programs a seed produces must be something the front end
// accepts and the passes can consume, otherwise a batch failure would be blamed
// on the wrong component.

///|
fn g_seeds(count : Int32) -> Array[Int32] {
  let seeds : Array[Int32] = []
  let mut seed = 1
  while seed <= count {
    seeds.push(seed)
    seed = seed + 1
  }
  seeds
}

///|
test "every generated program parses without errors" {
  let mut parsed = 0
  for seed in g_seeds(40) {
    let program = @oracle.parse(@oracle.generate(seed))
    assert_eq(program.errors.length(), 0)
    // One helper function and one generated function.
    assert_eq(program.functions.length(), 2)
    parsed = parsed + 1
  }
  assert_eq(parsed, 40)
}

///|
test "generation is deterministic" {
  let mut seed = 1
  while seed <= 20 {
    assert_eq(@oracle.generate(seed), @oracle.generate(seed))
    seed = seed + 1
  }
  assert_true(@oracle.generate(1) != @oracle.generate(2))
}

///|
test "generated programs stay within the statement budget" {
  for seed in g_seeds(60) {
    let generated = @oracle.generate_with_stats(seed)
    assert_true(generated.statements >= 6)
    assert_true(generated.statements <= 30)
  }
}

///|
test "generated programs satisfy the IR invariants the passes rely on" {
  for seed in g_seeds(40) {
    let program = @oracle.parse(@oracle.generate(seed))
    let count = program.nodes.length()
    let mut idx = 0
    while idx < count {
      assert_eq(program.nodes[idx].id, idx)
      for child in program.nodes[idx].children {
        assert_true(child >= 0 && child < count)
      }
      match program.nodes[idx].parent {
        Some(owner) => assert_true(owner >= 0 && owner < count)
        None => ()
      }
      idx = idx + 1
    }
    for function in program.functions {
      assert_true(function.entry >= 0)
      assert_true(function.entry < function.exit)
      assert_true(function.exit < count)
    }
  }
}

///|
test "the generator reaches every construct it claims to emit" {
  let mut with_if = 0
  let mut with_while = 0
  let mut with_call = 0
  let mut with_else = 0
  for seed in g_seeds(60) {
    let source = @oracle.generate(seed)
    if source.contains("if ") {
      with_if = with_if + 1
    }
    if source.contains("} else {") {
      with_else = with_else + 1
    }
    if source.contains("while ") {
      with_while = with_while + 1
    }
    if source.contains("helper(") {
      with_call = with_call + 1
    }
  }
  assert_true(with_if >= 10)
  assert_true(with_while >= 10)
  assert_true(with_else >= 10)
  assert_true(with_call >= 50)
}

///|
test "generated programs differ across seeds" {
  // A generator that ignored its seed would make the batch meaningless.
  let mut distinct = 0
  let sources : Array[String] = []
  for seed in g_seeds(10) {
    let source = @oracle.generate(seed)
    let mut seen = false
    for existing in sources {
      if existing == source {
        seen = true
      }
    }
    if !seen {
      sources.push(source)
      distinct = distinct + 1
    }
  }
  assert_eq(distinct, 10)
}
