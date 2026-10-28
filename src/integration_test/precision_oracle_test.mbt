// Independent precision oracle.
//
// The optimised analysis solves reaching definitions with a work-list over
// per-node state. This file checks it against a different formulation of the
// same definition: a definition reaches a use when some CFG path runs from the
// definition to the use with no intervening redefinition of that variable.
// That is a reachability question, answered by BFS, so it needs no iteration
// bound and stays correct on nested loops. Nothing here shares code or data
// structures with `src/defuse`.

///|
/// Definitions of each variable, in id order.
fn definitions_by_variable(program : @core.Program) -> Map[@core.VarId, Array[Int32]] {
  let table : Map[@core.VarId, Array[Int32]] = Map([])
  for node in program.nodes {
    for variable in node.defs {
      match table.get(variable) {
        None => table.set(variable, [node.id])
        Some(ids) => if !ids.contains(node.id) { ids.push(node.id) }
      }
    }
  }
  table
}

///|
/// Whether the definition at `def_id` can reach the use at `use_id` without an
/// intervening redefinition of the same variable.
///
/// This is the path formulation of "reaching": a definition reaches a use when
/// some path runs from the definition to the use and no node strictly inside
/// that path defines the variable again. A node that both defines and uses the
/// variable (an augmented assignment) can only be reached by its own definition
/// when the CFG contains a cycle back to it, which the search finds because the
/// target is checked before the "defines" filter.
fn definition_reaches(
  succ : Map[Int32, Array[Int32]],
  defs : Array[Int32],
  target : Int32,
  def_id : Int32,
) -> Bool {
  let defines_here : Set[Int32] = Set([])
  for id in defs {
    defines_here.add(id)
  }
  let visited : Set[Int32] = Set([])
  let queue : Array[Int32] = []
  match succ.get(def_id) {
    None => ()
    Some(next) =>
      for candidate in next {
        if !visited.contains(candidate) {
          visited.add(candidate)
          queue.push(candidate)
        }
      }
  }
  let mut head = 0
  let mut found = false
  while head < queue.length() && !found {
    let current = queue[head]
    head = head + 1
    if current == target {
      found = true
    } else if defines_here.contains(current) {
      // The definition is killed here, so it cannot flow past this node.
      continue
    } else {
      match succ.get(current) {
        None => ()
        Some(next) =>
          for candidate in next {
            if !visited.contains(candidate) {
              visited.add(candidate)
              queue.push(candidate)
            }
          }
      }
    }
  }
  found
}

///|
/// Reference reaching definitions, derived from the path formulation rather
/// than from a dataflow fixpoint: for every use, every definition of that
/// variable that can reach it along a path with no intervening redefinition.
///
/// This shares no code with `src/defuse` and needs no iteration bound, so it
/// stays correct on nested loops where a bounded walk enumeration would stop
/// too early.
fn oracle_reaching(program : @core.Program, cfg : @core.Cfg) -> Array[(Int32, Int32)] {
  let pairs : Set[(Int32, Int32)] = Set([])
  let succ : Map[Int32, Array[Int32]] = Map([])
  for edge in cfg.edges {
    match succ.get(edge.0) {
      None => succ.set(edge.0, [edge.1])
      Some(next) => next.push(edge.1)
    }
  }
  let defs_of = definitions_by_variable(program)
  for node in program.nodes {
    for variable in node.uses {
      match defs_of.get(variable) {
        None => ()
        Some(defs) =>
          for def_id in defs {
            if definition_reaches(succ, defs, node.id, def_id) {
              pairs.add((def_id, node.id))
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
