// Independent precision oracle.
//
// The optimised analysis solves reaching definitions with a work-list over
// per-node state. This file checks it against a different formulation of the
// same textbook definition: *enumerate walks* from each function entry and, for
// each use, record which definition was the most recent one for that variable.
// Nothing here shares code or data structures with `src/defuse`.
//
// Walks may revisit a node, because loop-carried definitions require it: the
// assignment `i = i + 1` defines and uses `i`, and its own definition reaches
// its own use on the next iteration. Each node is allowed at most two visits,
// which is what a single loop-carried dependence needs; cycles that would need
// more are equivalent to a repeated cycle that cannot change the last-seen
// definition any further.

///|
/// Score for "how many times each node appears in this walk", so the walk
/// enumeration can stop before a legal but useless repetition.
fn walk_visits(path : Array[Int32], id : Int32) -> Int {
  let mut n = 0
  for item in path {
    if item == id {
      n = n + 1
    }
  }
  n
}

///|
/// Every walk from `start` in which no node appears more than twice, capped at
/// `2 * node_count` steps. Exponential by nature, which is why the oracle only
/// runs on the small programs in the corpus.
fn all_walks(
  cfg : @core.Cfg,
  start : Int32,
  node_count : Int32,
) -> Array[Array[Int32]] {
  let out : Array[Array[Int32]] = []
  let succ : Map[Int32, Array[Int32]] = Map([])
  for edge in cfg.edges {
    match succ.get(edge.0) {
      None => succ.set(edge.0, [edge.1])
      Some(next) => next.push(edge.1)
    }
  }
  let max_steps = node_count * 2
  fn walk(path : Array[Int32]) -> Unit {
    out.push(path.copy())
    if path.length() >= max_steps {
      return
    }
    let last = path[path.length() - 1]
    match succ.get(last) {
      None => ()
      Some(next) =>
        for candidate in next {
          if walk_visits(path, candidate) < 2 {
            path.push(candidate)
            walk(path)
            ignore(path.pop())
          }
        }
    }
  }
  walk([start])
  out
}

///|
/// Reference reaching definitions: for every use, the set of definitions that
/// can be the most recent definition of that variable on some walk from a
/// function entry.
///
/// Uses are processed before definitions on the same node, so a plain
/// `x = x + 1` is reached by the *previous* iteration's definition, not by
/// itself; the self pair appears only when a walk actually returns to the node.
fn oracle_reaching(program : @core.Program, cfg : @core.Cfg) -> Array[(Int32, Int32)] {
  let pairs : Set[(Int32, Int32)] = Set([])
  let node_count = program.nodes.length()
  for f in program.functions {
    for path in all_walks(cfg, f.entry, node_count) {
      let reaching : Map[@core.VarId, Int32] = Map([])
      for id in path {
        match lookup(program, id) {
          None => ()
          Some(node) => {
            for variable in node.uses {
              match reaching.get(variable) {
                None => ()
                Some(def_id) => pairs.add((def_id, id))
              }
            }
            for variable in node.defs {
              reaching.set(variable, id)
            }
          }
        }
      }
    }
  }
  let out = pairs.to_array()
  out.sort_by(fn(a, b) {
    if a.0 != b.0 {
      a.0.compare(b.0)
    } else {
      a.1.compare(b.1)
    }
  })
  out
}

///|
fn lookup(program : @core.Program, id : Int32) -> @core.SNode? {
  for node in program.nodes {
    if node.id == id {
      return Some(node)
    }
  }
  None
}

///|
fn analyse(source : String) -> (@core.Program, @core.Cfg, @core.DefUse) {
  let program = @parser_adapter.parse_source(source, "oracle.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  (program, cfg, defuse)
}

///|
fn assert_matches_oracle(source : String) -> Unit raise {
  let (program, cfg, defuse) = analyse(source)
  let expected = oracle_reaching(program, cfg)
  let actual = defuse.reaching.copy()
  if actual != expected {
    println("oracle mismatch for source:\n\{source}")
    for pair in expected {
      println("expected " + pair.0.to_string() + " -> " + pair.1.to_string())
    }
    for pair in actual {
      println("actual   " + pair.0.to_string() + " -> " + pair.1.to_string())
    }
    fail("reaching definitions disagree with the walk oracle")
  }
}

///|
test "reaching definitions match the walk oracle on straight-line code" {
  assert_matches_oracle(
    "fn f(a : Int, b : Int) -> Int {\n  let x = a\n  let y = x\n  x + y + b\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on if/else" {
  assert_matches_oracle(
    "fn f(c : Bool, a : Int) -> Int {\n  let mut x = a\n  if c {\n    x = x + 1\n  } else {\n    x = 0\n  }\n  x\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on a while loop" {
  assert_matches_oracle(
    "fn f(n : Int) -> Int {\n  let mut i = 0\n  let mut total = 0\n  while i < n {\n    total = total + i\n    i = i + 1\n  }\n  total\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on nested branches" {
  assert_matches_oracle(
    "fn f(c : Bool, d : Bool, a : Int) -> Int {\n  let mut x = a\n  if c {\n    if d {\n      x = 1\n    } else {\n      x = 2\n    }\n  }\n  x\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on a C-style for" {
  assert_matches_oracle(
    "fn f(n : Int) -> Int {\n  let mut k = 0\n  for i = 0; i < n; i = i + 1 {\n    k = k + i\n    if i == 2 {\n      continue\n    }\n    k = k + 1\n  }\n  k\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on match arms" {
  assert_matches_oracle(
    "fn f(a : Int) -> Int {\n  let mut x = 0\n  match a {\n    0 => x = 1\n    _ => x = 2\n  }\n  x\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on shadowing" {
  assert_matches_oracle(
    "fn f(x : Int, c : Bool) -> Int {\n  let y = x\n  if c {\n    let x = y + 1\n    x\n  } else {\n    x\n  }\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on a guard" {
  assert_matches_oracle(
    "fn f(n : Int, fallback : Int) -> Int {\n  guard n > 0 else { return fallback }\n  return n\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on recursion" {
  assert_matches_oracle(
    "fn rec(n : Int, acc : Int) -> Int {\n  if n <= 0 {\n    return acc\n  }\n  return rec(n - 1, acc + n)\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on field and array writes" {
  assert_matches_oracle(
    "fn f(r : R, a : Array[Int], i : Int) -> Int {\n  r.x = 1\n  a[i] = r.x\n  a[i] + r.x\n}\n",
  )
}

///|
test "reaching definitions match the walk oracle on a nested loop" {
  assert_matches_oracle(
    "fn f(n : Int) -> Int {\n  let mut s = 0\n  let mut i = 0\n  while i < n {\n    let mut j = 0\n    while j < n {\n      s = s + i * j\n      j = j + 1\n    }\n    i = i + 1\n  }\n  s\n}\n",
  )
}

///|
/// Corpus-wide agreement: every example in the shipped corpus is checked against
/// the oracle, so an example whose recorded expectation was produced by the
/// analysis under test cannot hide a systematic error.
test "reaching definitions match the walk oracle on the example corpus" {
  let files : Array[String] = [
    "examples/01_let.mbt", "examples/02_mut.mbt", "examples/03_if_else.mbt",
    "examples/04_while.mbt", "examples/05_for.mbt", "examples/06_match.mbt",
    "examples/07_return.mbt", "examples/08_dead_assignment.mbt",
    "examples/09_shadowing.mbt", "examples/10_field_write.mbt",
  ]
  for file in files {
    let source = @fs.read_file_to_string(file) catch { _ => panic() }
    assert_matches_oracle(source)
  }
}
