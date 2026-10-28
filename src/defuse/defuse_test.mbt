// Blackbox tests for reaching definitions.
//
// Each test parses a small program, builds the CFG, runs the analysis and
// asserts the exact `(definition node, use node)` set. Node ids are documented
// inline so the expectations can be checked against `cfg_test.mbt` by hand.

///|
fn reaching(source : String) -> (Array[(Int32, Int32)], @core.Program) {
  let program = @parser_adapter.parse_source(source, "du.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  (defuse.reaching, program)
}

///|
fn edges_of(source : String) -> Array[(Int32, Int32)] {
  let (pairs, _) = reaching(source)
  pairs
}

///|
fn has(pairs : Array[(Int32, Int32)], from : Int32, to : Int32) -> Bool {
  let mut i = 0
  let mut found = false
  while i < pairs.length() {
    if pairs[i].0 == from && pairs[i].1 == to {
      found = true
    }
    i = i + 1
  }
  found
}

///|
test "single definition reaches the following use" {
  //  0 entry(a), 1 let s, 2 use s, 3 exit
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n"
  let pairs = edges_of(source)
  assert_eq(pairs, [(0, 1), (1, 2)])
}

///|
test "parameter definition reaches every use of the parameter" {
  let source = "fn f(a : Int) -> Int {\n  a + a\n}\n"
  let pairs = edges_of(source)
  assert_eq(pairs, [(0, 1)])
}

///|
test "redefinition kills the earlier definition on the straight-line path" {
  //  0 entry(a), 1 letmut x, 2 assign x = a, 3 use x, 4 exit
  let source = "fn f(a : Int) -> Int {\n  let mut x = 0\n  x = a\n  x\n}\n"
  let pairs = edges_of(source)
  // The use of `x` on line 4 is reached only by the assignment on line 3.
  assert_eq(pairs, [(0, 2), (2, 3)])
  assert_true(!has(pairs, 1, 3))
}

///|
test "a definition reaches a use inside a branch" {
  //  0 entry(c), 1 letmut x, 2 if head, 3 then-region, 4 assign x, 5 exit
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  }\n  x\n}\n"
  let pairs = edges_of(source)
  // entry reaches the condition; the `let mut` reaches the branch store's own
  // read (none here) and the closing read.
  assert_true(has(pairs, 0, 2))
  // The closing read of `x` is reached by both the pre-branch definition and
  // the in-branch assignment.
  assert_true(has(pairs, 1, 5))
  assert_true(has(pairs, 4, 5))
}

///|
test "both arms of if/else reach the join point" {
  //  0 entry(c), 1 letmut x, 2 head, 3 then-region, 4 then store,
  //  5 else-region, 6 else store, 7 use x, 8 exit
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let pairs = edges_of(source)
  assert_true(has(pairs, 4, 7))
  assert_true(has(pairs, 6, 7))
  // The initial definition is killed on both paths.
  assert_true(!has(pairs, 1, 7))
}

///|
test "a definition does not reach a use it dominates the other way" {
  //  0 entry(a), 1 let s = a, 2 use s, 3 exit
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n"
  let pairs = edges_of(source)
  assert_true(!has(pairs, 2, 1))
  assert_true(!has(pairs, 1, 1))
}

///|
test "loop body definition reaches the loop header use" {
  //  0 entry(n), 1 letmut i, 2 while head, 3 region, 4 assign i, 5 use i, 6 exit
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n"
  let pairs = edges_of(source)
  // Header reads `i` from the pre-loop definition and from the back edge.
  assert_true(has(pairs, 1, 2))
  assert_true(has(pairs, 4, 2))
  // The header read of `n` comes from the parameter.
  assert_true(has(pairs, 0, 2))
  // The trailing read sees the back-edge definition too.
  assert_true(has(pairs, 4, 5))
}

///|
test "shadowed binding is a separate definition site" {
  //  0 entry(x), 1 let y = x, 2 let x = y, 3 use x, 4 exit
  let source = "fn f(x : Int) -> Int {\n  let y = x\n  let x = y\n  x\n}\n"
  let pairs = edges_of(source)
  // The parameter `x` (node 0) does not reach the final use: the inner `let x`
  // on line 3 does.
  assert_true(has(pairs, 2, 3))
  assert_true(!has(pairs, 0, 3))
  // The parameter still reaches the first `let`.
  assert_true(has(pairs, 0, 1))
}

///|
test "shadowing in a branch does not affect the outer binding afterwards" {
  let source = "fn f(c : Bool) -> Int {\n  let x = 1\n  if c {\n    let x = 2\n    x\n  }\n  x\n}\n"
  let (pairs, program) = reaching(source)
  // 0 entry, 1 let x, 2 head, 3 region, 4 let x (inner), 5 use inner x, 6 use outer x
  assert_true(has(pairs, 4, 5)) // inner def -> inner use
  assert_true(has(pairs, 1, 6)) // outer def -> outer use
  assert_true(!has(pairs, 1, 5)) // outer def does not reach the inner use
  assert_true(!has(pairs, 4, 6)) // inner def does not escape the branch
  // Guard against a silently shifted layout.
  assert_eq(program.nodes[4].loc.start_line, 4)
  assert_eq(program.nodes[6].loc.start_line, 7)
}

///|
test "use of an unbound name produces no edge" {
  let source = "fn f() -> Int {\n  g\n}\n"
  let pairs = edges_of(source)
  assert_eq(pairs, [])
}

///|
test "field write defines its base, so later reads reach it" {
  //  0 entry(r), 1 store r.x, 2 read r, 3 exit
  let source = "fn f(r : R) -> Int {\n  r.x = 1\n  r.x\n}\n"
  let pairs = edges_of(source)
  // Node 1 both reads and writes `r`; the later read reaches node 1, not the
  // parameter.
  assert_true(has(pairs, 1, 2))
  assert_true(!has(pairs, 0, 2))
}

///|
test "array write defines its base, so later reads reach it" {
  let source = "fn f(a : Array[Int]) -> Int {\n  a[0] = 1\n  a[0]\n}\n"
  let pairs = edges_of(source)
  assert_true(has(pairs, 1, 2))
  assert_true(!has(pairs, 0, 2))
}

///|
test "a kill only affects the killed variable" {  //  0 entry(a, b), 1 letmut x, 2 assign x, 3 let y, 4 use x and y, 5 exit
  let source = "fn f(a : Int, b : Int) -> Int {\n  let mut x = 0\n  x = a\n  let y = b\n  x + y\n}\n"
  let pairs = edges_of(source)
  // The store to `x` kills the previous `x` but must not kill `b`.
  assert_true(has(pairs, 0, 2)) // a -> store
  assert_true(has(pairs, 0, 3)) // b -> let y
  assert_true(has(pairs, 2, 4)) // store -> final read of x
  assert_true(has(pairs, 3, 4)) // let y -> final read of y
  assert_true(!has(pairs, 1, 4))
}

///|
test "for each binder is defined by the loop head" {
  //  0 entry(xs), 1 letmut t, 2 for head, 3 region, 4 assign t, 5 use t, 6 exit
  let source = "fn f(xs : Array[Int]) -> Int {\n  let mut t = 0\n  for x in xs {\n    t = t + x\n  }\n  t\n}\n"
  let pairs = edges_of(source)
  // `x` is defined at the head (node 2) and used in the body.
  assert_true(has(pairs, 2, 4))
  // `xs` comes from the parameter into the head.
  assert_true(has(pairs, 0, 2))
}

///|
test "match pattern binder is defined by its case region" {
  //  0 entry(a), 1 head, 2 case0-region, 3 body uses n, 4 case1-region, 5 body, 6 exit
  let source = "fn f(a : Int) -> Int {\n  match a {\n    n => n + 1\n    _ => 2\n  }\n}\n"
  let pairs = edges_of(source)
  assert_true(has(pairs, 2, 3))
}

///|
test "reaching is sorted and deduplicated" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s + s\n}\n"
  let (pairs, _) = reaching(source)
  let mut i = 0
  while i + 1 < pairs.length() {
    let current = pairs[i]
    let next = pairs[i + 1]
    let ordered = current.0 < next.0 ||
      (current.0 == next.0 && current.1 < next.1)
    assert_true(ordered)
    i = i + 1
  }
}

///|
test "empty program has no reaching definitions" {
  let program = @parser_adapter.parse_source("", "e.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  assert_eq(defuse.reaching.length(), 0)
}

///|
test "a use with two reaching definitions yields two pairs" {
  //  0 entry(c), 1 letmut x, 2 head, 3 then-region, 4 then store,
  //  5 else-region, 6 else store, 7 use x, 8 exit
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let pairs = edges_of(source)
  let mut count = 0
  pairs.each(fn(pair) { if pair.1 == 7 { count = count + 1 } })
  assert_eq(count, 2)
}

///|
test "parameterless straight-line chain propagates definitions" {
  // 0 entry, 1 letmut x, 2 assign, 3 assign, 4 use x, 5 exit
  let source = "fn f() -> Int {\n  let mut x = 1\n  x = 2\n  x = 3\n  x\n}\n"
  let pairs = edges_of(source)
  assert_true(has(pairs, 3, 4))
  assert_true(!has(pairs, 1, 4))
  assert_true(!has(pairs, 2, 4))
}

///|
test "deep nested loops reach a fixed point" {
  // 30 nested loops produce enough back edges and merges that a round-capped
  // worklist stops before convergence; the analysis must terminate on its own.
  let mut body = ""
  let mut depth = 0
  while depth < 30 {
    body = body + "while c" + depth.to_string() + " {\n"
    body = body + "x = x + " + depth.to_string() + "\n"
    depth = depth + 1
  }
  let mut closing = 0
  while closing < 30 {
    body = body + "}\n"
    closing = closing + 1
  }
  let source = "fn f(x : Int, c0 : Bool) -> Int {\n  let mut y = x\n" + body + "y\n}\n"
  let (pairs, program) = reaching(source)
  // Every `x = x + k` assignment has a use, so the chain of reaching pairs must
  // be non-empty all the way to the deepest level (not a truncated prefix).
  let assignments : Array[Int32] = []
  program.nodes.each(fn(node) {
    if node.kind == @core.SNodeKind::Assign {
      assignments.push(node.id)
    }
  })
  assert_eq(assignments.length(), 30)
  let mut reached = 0
  for id in assignments {
    let mut hit = false
    for pair in pairs {
      if pair.0 == id || pair.1 == id {
        hit = true
      }
    }
    if hit {
      reached = reached + 1
    }
  }
  assert_eq(reached, 30)
}

///|
test "a 2000-statement chain yields exactly the expected reaching pairs" {
  // A straight-line chain `x = x + 1` repeated n times. Each assignment reads
  // the previous one, so the reaching set is exactly one pair per statement
  // after the first: (node k, node k+1). The closed form is checked exactly, so
  // a future optimisation that silently drops edges cannot pass.
  let n = 2000
  let mut body = ""
  let mut i = 0
  while i < n {
    body = body + "x = x + 1\n"
    i = i + 1
  }
  let source = "fn chain() -> Int {\n  let mut x = 0\n" + body + "x\n}\n"
  let (pairs, program) = reaching(source)
  // Nodes: 0 entry, 1 let mut, then n assigns, then the trailing use, then exit.
  assert_eq(program.nodes.length(), n + 4)
  // The function has no parameters, so the synthetic entry defines nothing and
  // contributes no pair. `let mut x = 0` has a constant RHS, so it uses nothing
  // either. The pairs are therefore exactly the n links of the assignment chain
  // plus the final link into the trailing use: n + 1 pairs, asserted exactly so
  // a future optimisation cannot drop edges silently.
  assert_eq(pairs.length(), n + 1)
  assert_true(has(pairs, 1, 2))
  let last_assign = (n + 1).to_int64().to_int()
  let trailing_use = (n + 2).to_int64().to_int()
  assert_true(has(pairs, last_assign, trailing_use))
}
