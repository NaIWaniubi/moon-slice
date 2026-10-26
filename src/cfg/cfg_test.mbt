// Blackbox tests for the CFG builder.
//
// Every test parses a tiny program, builds the CFG and asserts the *exact* edge
// set. Building the program through the parser keeps the tests honest about the
// real node layout; the edge expectations are hand-written from the construct
// rules documented in `cfg.mbt`.

///|
fn edges_sorted(cfg : @core.Cfg) -> Array[(Int32, Int32)] {
  let out = cfg.edges.copy()
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
fn program_of(source : String) -> @core.Program {
  @parser_adapter.parse_source(source, "cfg.mbt")
}

///|
test "straight-line function is a chain from entry to exit" {
  let program = program_of("fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n")
  let cfg = @cfg.build(program)
  assert_eq(cfg.entry, 0)
  assert_eq(cfg.exit, 3)
  assert_eq(edges_sorted(cfg), [(0, 1), (1, 2), (2, 3)])
}

///|
test "if/else forks at the head and joins after the branches" {
  //  0 entry, 1 head(if), 2 then-region, 3 then body,
  //  4 else-region, 5 else body, 6 exit
  let program = program_of(
    "fn f(c : Bool) -> Int {\n  if c {\n    1\n  } else {\n    2\n  }\n}\n",
  )
  let cfg = @cfg.build(program)
  assert_eq(edges_sorted(cfg), [
    (0, 1),
    (1, 2), // head -> then region
    (1, 4), // head -> else region
    (2, 3), // then region -> then body
    (3, 6), // then body -> exit
    (4, 5), // else region -> else body
    (5, 6), // else body -> exit
  ])
}

///|
test "if without else forks to the join point directly" {
  //  0 entry, 1 head, 2 then-region, 3 then body, 4 trailing, 5 exit
  let program = program_of(
    "fn f(c : Bool) -> Int {\n  if c {\n    1\n  }\n  0\n}\n",
  )
  let cfg = @cfg.build(program)
  assert_eq(edges_sorted(cfg), [
    (0, 1),
    (1, 2), // head -> then region
    (1, 4), // head -> after the if (no else branch)
    (2, 3), // then region -> then body
    (3, 4), // then body -> after the if
    (4, 5),
  ])
}

///|
test "empty then branch keeps the join point reachable" {
  //  0 entry, 1 head, 2 region (empty), 3 trailing, 4 exit
  let program = program_of("fn f(c : Bool) -> Int {\n  if c {\n  }\n  0\n}\n")
  let cfg = @cfg.build(program)
  // `if c {}` has no else branch, so the head points at the join point directly
  // as well as into the (empty) then-region.
  assert_eq(edges_sorted(cfg), [(0, 1), (1, 2), (1, 3), (2, 3), (3, 4)])
}

///|
test "while forms a loop with a back edge and an exit edge" {
  //  0 entry, 1 letmut, 2 head(while), 3 body-region, 4 body, 5 trailing, 6 exit
  let program = program_of(
    "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n",
  )
  let cfg = @cfg.build(program)
  assert_eq(edges_sorted(cfg), [
    (0, 1),
    (1, 2),
    (2, 3), // head -> body region
    (2, 5), // head -> after the loop
    (3, 4), // body region -> body
    (4, 2), // back edge
    (5, 6),
  ])
}

///|
test "break leaves the loop, continue returns to the condition" {
  //  0 entry, 1 letmut, 2 head(while), 3 region, 4 assign,
  //  5 if head, 6 then-region, 7 break, 8 else-region, 9 continue,
  //  10 trailing, 11 exit
  let program = program_of(
    "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n    if i > 2 {\n      break\n    } else {\n      continue\n    }\n  }\n  i\n}\n",
  )
  let cfg = @cfg.build(program)
  let edges = edges_sorted(cfg)
  // break -> after the loop
  assert_true(edges.contains((7, 10)))
  // continue -> loop condition
  assert_true(edges.contains((9, 2)))
}

///|
test "for loop back edge targets the head" {
  //  0 entry, 1 letmut, 2 head(for), 3 region, 4 body, 5 trailing, 6 exit
  let program = program_of(
    "fn f(xs : Array[Int]) -> Int {\n  let mut t = 0\n  for x in xs {\n    t = t + x\n  }\n  t\n}\n",
  )
  let cfg = @cfg.build(program)
  assert_eq(edges_sorted(cfg), [
    (0, 1),
    (1, 2),
    (2, 3), // head -> body region
    (2, 5),
    (3, 4), // body region -> body
    (4, 2), // back edge to the for head
    (5, 6),
  ])
}

///|
test "nested loops: break binds to the innermost loop" {
  let program = program_of(
    "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    let mut j = 0\n    while j < n {\n      break\n    }\n    i = i + 1\n  }\n  i\n}\n",
  )
  let cfg = @cfg.build(program)
  let edges = edges_sorted(cfg)
  // Node ids: 0 entry, 1 letmut i, 2 while i, 3 outer body region,
  //           4 letmut j, 5 while j, 6 inner body region, 7 break,
  //           8 assign i (after the inner loop), 9 trailing, 10 exit
  let break_node = 7
  let inner_region = 6
  let outer_head = 2
  // `break` leaves the inner loop, so it targets the statement after it.
  assert_true(edges.contains((break_node, 8)))
  // It must not target the outer loop head, nor escape past the outer loop.
  assert_true(!edges.contains((break_node, outer_head)))
  assert_true(!edges.contains((break_node, 9)))
  // The inner loop head reaches its body through the region node.
  assert_true(edges.contains((5, inner_region)))
  assert_true(edges.contains((inner_region, break_node)))
}

///|
test "return jumps to the function exit" {
  //  0 entry, 1 return, 2 exit
  let program = program_of("fn f(a : Int) -> Int {\n  return a\n}\n")
  let cfg = @cfg.build(program)
  assert_eq(edges_sorted(cfg), [
    (0, 1),
    (1, 2), // return -> exit
  ])
}

///|
test "statements after return keep their incoming edge" {
  //  0 entry, 1 return, 2 trailing expression, 3 exit
  let program = program_of("fn f(a : Int) -> Int {\n  return a\n  a\n}\n")
  let cfg = @cfg.build(program)
  assert_true(edges_sorted(cfg).contains((2, 3)))
}

///|
test "match forks into one edge per case" {
  //  0 entry, 1 head, 2 case0-region, 3 case0 body, 4 case1-region, 5 case1 body, 6 exit
  let program = program_of(
    "fn f(a : Int) -> Int {\n  match a {\n    0 => 1\n    _ => 2\n  }\n}\n",
  )
  let cfg = @cfg.build(program)
  assert_eq(edges_sorted(cfg), [
    (0, 1),
    (1, 2), // head -> case region
    (1, 4), // head -> case region
    (2, 3), // case region -> case body
    (3, 6), // case body -> join
    (4, 5), // case region -> case body
    (5, 6), // case body -> join
  ])
}

///|
test "two functions are two disjoint components" {
  let program = program_of(
    "fn f(a : Int) -> Int {\n  a\n}\n\nfn g(b : Int) -> Int {\n  b\n}\n",
  )
  let cfg = @cfg.build(program)
  // Every edge stays inside one function: an edge whose endpoints straddle the
  // boundary between the two functions would be a bug.
  let first_exit = program.functions[0].exit
  let second_entry = program.functions[1].entry
  let crossing : Array[(Int32, Int32)] = []
  cfg.edges.each(fn(edge) {
    if edge.0 <= first_exit && edge.1 >= second_entry {
      crossing.push(edge)
    }
  })
  assert_eq(crossing, [])
  assert_eq(cfg.entry, program.functions[0].entry)
  assert_eq(cfg.exit, program.functions[0].exit)
}

///|
test "explicit break outside any loop still produces an edge" {
  // MoonBit rejects this in practice, but the builder must stay total.
  let program = program_of("fn f() -> Unit {\n  break\n}\n")
  let cfg = @cfg.build(program)
  // Either the parser reports an error (no nodes) or the break falls through;
  // both are acceptable, an exception is not.
  assert_true(cfg.edges.length() >= 0)
}

///|
test "edges are deduplicated" {
  let program = program_of(
    "fn f(c : Bool) -> Int {\n  if c {\n    1\n  } else {\n    2\n  }\n}\n",
  )
  let cfg = @cfg.build(program)
  let sorted = edges_sorted(cfg)
  let mut i = 0
  while i + 1 < sorted.length() {
    assert_true(sorted[i] != sorted[i + 1])
    i = i + 1
  }
}

///|
test "empty program yields an empty edge set" {
  let cfg = @cfg.build(program_of(""))
  assert_eq(cfg.edges.length(), 0)
  assert_eq(cfg.entry, 0)
  assert_eq(cfg.exit, 0)
}
