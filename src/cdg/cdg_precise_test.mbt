// Tests for the post-dominator based control-dependence builder.
//
// `build_precise` derives control dependence from the CFG alone, so these tests
// hand-build CFGs where the answer follows from the textbook definition:
// Y is control dependent on X when one successor of X post-dominates Y and
// another does not.

///|
fn pnode(
  id : Int32,
  kind : @core.SNodeKind,
  line : Int32,
) -> @core.SNode {
  {
    id,
    kind,
    loc: { start_line: line, start_col: 1, end_line: line, end_col: 8 },
    defs: [],
    uses: [],
    children: [],
    parent: None,
  }
}

///|
fn pprog(
  nodes : Array[@core.SNode],
  entry : Int32,
  exit : Int32,
) -> @core.Program {
  {
    nodes,
    functions: [{ name: "f", entry, exit }],
    calls: [],
    errors: [],
  }
}

///|
fn pcfg(
  edges : Array[(Int32, Int32)],
  entry : Int32,
  exit : Int32,
) -> @core.Cfg {
  { edges, entry, exit, }
}

///|
test "precise: straight line has no control dependence" {
  // 0 entry -> 1 -> 2 -> 3 exit
  let prog = pprog(
    [
      pnode(0, @core.Expr, 1),
      pnode(1, @core.Let, 2),
      pnode(2, @core.Return, 3),
      pnode(3, @core.Expr, 4),
    ],
    0,
    3,
  )
  let result = @cdg.build_precise(prog, pcfg([(0, 1), (1, 2), (2, 3)], 0, 3))
  assert_eq(result.edges, [])
}

///|
test "precise: if/else arms depend on the branch, the join does not" {
  // 0 entry, 1 head, 2 then, 3 else, 4 join, 5 exit
  let prog = pprog(
    [
      pnode(0, @core.Expr, 1),
      pnode(1, @core.If, 2),
      pnode(2, @core.Assign, 3),
      pnode(3, @core.Assign, 4),
      pnode(4, @core.Return, 5),
      pnode(5, @core.Expr, 6),
    ],
    0,
    5,
  )
  let result = @cdg.build_precise(
    prog,
    pcfg([(0, 1), (1, 2), (1, 3), (2, 4), (3, 4), (4, 5)], 0, 5),
  )
  assert_eq(result.edges, [(1, 2), (1, 3)])
}

///|
test "precise: if without else makes the join depend on the branch" {
  // 0 entry, 1 head, 2 then, 3 join, 4 exit
  let prog = pprog(
    [
      pnode(0, @core.Expr, 1),
      pnode(1, @core.If, 2),
      pnode(2, @core.Assign, 3),
      pnode(3, @core.Return, 4),
      pnode(4, @core.Expr, 5),
    ],
    0,
    4,
  )
  let result = @cdg.build_precise(
    prog,
    pcfg([(0, 1), (1, 2), (1, 3), (2, 3), (3, 4)], 0, 4),
  )
  // The join post-dominates both successors of the head (straight to it, or
  // through the branch), so by definition it is NOT control dependent on the
  // head. Only the then-body is.
  assert_eq(result.edges, [(1, 2)])
}

///|
test "precise: loop body depends on the head, the exit does not" {
  // 0 entry, 1 head, 2 body, 3 after loop, 4 exit
  let prog = pprog(
    [
      pnode(0, @core.Expr, 1),
      pnode(1, @core.While, 2),
      pnode(2, @core.Assign, 3),
      pnode(3, @core.Return, 4),
      pnode(4, @core.Expr, 5),
    ],
    0,
    4,
  )
  let result = @cdg.build_precise(
    prog,
    pcfg([(0, 1), (1, 2), (1, 3), (2, 1), (3, 4)], 0, 4),
  )
  assert_eq(result.edges, [(1, 2)])
}

///|
test "precise: a return inside a branch makes the join depend on it" {
  // 0 entry, 1 head, 2 then-return, 3 else-body, 4 join, 5 exit
  let prog = pprog(
    [
      pnode(0, @core.Expr, 1),
      pnode(1, @core.If, 2),
      pnode(2, @core.Return, 3),
      pnode(3, @core.Assign, 4),
      pnode(4, @core.Return, 5),
      pnode(5, @core.Expr, 6),
    ],
    0,
    5,
  )
  let result = @cdg.build_precise(
    prog,
    pcfg([(0, 1), (1, 2), (1, 3), (2, 5), (3, 4), (4, 5)], 0, 5),
  )
  assert_eq(result.edges, [(1, 2), (1, 3), (1, 4)])
}

///|
test "precise: nested branches keep both controllers" {
  // 0 entry, 1 outer, 2 inner, 3 inner-then, 4 outer-join, 5 after, 6 exit
  let prog = pprog(
    [
      pnode(0, @core.Expr, 1),
      pnode(1, @core.If, 2),
      pnode(2, @core.If, 3),
      pnode(3, @core.Assign, 4),
      pnode(4, @core.Assign, 5),
      pnode(5, @core.Return, 6),
      pnode(6, @core.Expr, 7),
    ],
    0,
    6,
  )
  let result = @cdg.build_precise(
    prog,
    pcfg(
      [(0, 1), (1, 2), (1, 4), (2, 3), (2, 4), (3, 4), (4, 5), (5, 6)],
      0,
      6,
    ),
  )
  // Node 4 (the outer join) post-dominates both successors of the outer head,
  // so it is not dependent on it. The inner head is dependent on the outer one
  // because the `1 -> 4` path skips it, and the inner then-body is dependent on
  // the inner head.
  assert_eq(result.edges, [(1, 2), (2, 3)])
}

///|
test "precise: break inside a loop controls what it skips" {
  // 0 entry, 1 head, 2 if, 3 break, 4 skipped body, 5 after loop, 6 exit
  let prog = pprog(
    [
      pnode(0, @core.Expr, 1),
      pnode(1, @core.While, 2),
      pnode(2, @core.If, 3),
      pnode(3, @core.Break, 4),
      pnode(4, @core.Assign, 5),
      pnode(5, @core.Return, 6),
      pnode(6, @core.Expr, 7),
    ],
    0,
    6,
  )
  let result = @cdg.build_precise(
    prog,
    pcfg(
      [(0, 1), (1, 2), (2, 3), (2, 4), (3, 5), (4, 1), (1, 5), (5, 6)],
      0,
      6,
    ),
  )
  // The break is controlled by the if, and the skipped body statement too.
  // Node 1 (the loop head) is control dependent on the if: the head is reached
  // by the `4 -> 1` continue path but not by the `3 -> 5` break path, which is
  // the loop-carried edge a syntax-only CDG cannot express. The statement after
  // the loop is not included, because the loop also exits normally via `1 -> 5`.
  assert_eq(result.edges, [(1, 2), (2, 1), (2, 3), (2, 4)])
}

///|
test "precise: irreducible flow terminates and is deterministic" {
  // A two-entry cycle: 1 -> 2 -> 3 -> 2 and 1 -> 3.
  let edges : Array[(Int32, Int32)] = [
    (0, 1),
    (1, 2),
    (1, 3),
    (2, 3),
    (3, 2),
    (3, 4),
    (4, 5),
  ]
  let nodes : Array[@core.SNode] = [
    pnode(0, @core.Expr, 1),
    pnode(1, @core.If, 2),
    pnode(2, @core.Assign, 3),
    pnode(3, @core.Assign, 4),
    pnode(4, @core.Return, 5),
    pnode(5, @core.Expr, 6),
  ]
  let first = @cdg.build_precise(pprog(nodes, 0, 5), pcfg(edges, 0, 5))
  let second = @cdg.build_precise(pprog(nodes, 0, 5), pcfg(edges, 0, 5))
  assert_eq(second.edges, first.edges)
  for pair in first.edges {
    assert_true(pair.0 != pair.1)
  }
}

///|
test "precise: unknown cfg ids are ignored" {
  let prog = pprog(
    [
      pnode(0, @core.Expr, 1),
      pnode(1, @core.If, 2),
      pnode(2, @core.Return, 3),
      pnode(3, @core.Expr, 4),
    ],
    0,
    3,
  )
  let result = @cdg.build_precise(
    prog,
    pcfg([(0, 1), (1, 2), (1, 99), (2, 3), (99, 3)], 0, 3),
  )
  for pair in result.edges {
    assert_true(pair.0 >= 0 && pair.0 < 4)
    assert_true(pair.1 >= 0 && pair.1 < 4)
  }
}

///|
test "precise: empty program yields an empty graph" {
  let prog : @core.Program = {
    nodes: [],
    functions: [],
    calls: [],
    errors: [],
  }
  let result = @cdg.build_precise(prog, pcfg([], 0, 0))
  assert_eq(result.edges, [])
}
