// End-to-end test: a small MoonBit program written by hand as a `Program`
// tree, carried through cdg -> pdg -> slice. The source it models is in
// fixtures/sum_first.mbt.txt and the numbers here are cross-checked against it.

///|
fn e2e_loc(start_line : Int32, start_col : Int32) -> @core.Loc {
  { start_line, start_col, end_line: start_line, end_col: start_col + 1, }
}

///|
fn e2e_var(name : String) -> @core.VarId {
  { name, scope: 0, }
}

///|
fn e2e_node(
  id : Int32,
  kind : @core.SNodeKind,
  start_line : Int32,
  start_col : Int32,
  defs : Array[@core.VarId],
  uses : Array[@core.VarId],
  children : Array[Int32],
  parent : Int32?,
) -> @core.SNode {
  {
    id,
    kind,
    loc: e2e_loc(start_line, start_col),
    defs,
    uses,
    children,
    parent,
  }
}

///|
test "end to end: cdg -> pdg -> backward and forward slices" {
  // Source (fixtures/sum_first.mbt.txt):
  //
  // line 1: fn sum_first(n : Int) -> Int {
  // line 2:   let total = 0
  // line 3:   let mut i = 0
  // line 4:   while i < n {
  // line 5:     if i % 2 == 0 {
  // line 6:       total = total + i
  // line 7:     } else {
  // line 8:       i = i + 1
  // line 9:     }
  // line 10:   }
  // line 11:   return total
  // line 12: }
  //
  // Node map:
  //   0  line 2   Let     total              (defines total)
  //   1  line 3   LetMut  i                  (defines i)
  //   2  line 4   While   i, n               child of none
  //   3  line 5   If      i                  child of 2
  //   4  line 6   Assign  total (uses total, i)   child of 3
  //   5  line 8   Assign  i (uses i)              child of 3
  //   6  line 11  Return  total
  let total = e2e_var("total")
  let i_var = e2e_var("i")
  let n_var = e2e_var("n")
  let prog : @core.Program = {
    nodes: [
      e2e_node(0, @core.Let, 2, 3, [total], [], [], None),
      e2e_node(1, @core.LetMut, 3, 3, [i_var], [], [], None),
      e2e_node(2, @core.While, 4, 3, [], [i_var, n_var], [3], None),
      e2e_node(3, @core.If, 5, 5, [], [i_var], [4, 5], Some(2)),
      e2e_node(4, @core.Assign, 6, 7, [total], [total, i_var], [], Some(3)),
      e2e_node(5, @core.Assign, 8, 7, [i_var], [i_var], [], Some(3)),
      e2e_node(6, @core.Return, 11, 3, [], [total], [], None),
    ],
    functions: [{ name: "sum_first", entry: 0, exit: 6, }],
    errors: [],
  }
  // CFG: straight line, loop back edge, if branches rejoin at the while header.
  let cfg : @core.Cfg = {
    edges: [(0, 1), (1, 2), (2, 3), (3, 4), (3, 5), (4, 2), (5, 2), (2, 6)],
    entry: 0,
    exit: 6,
  }
  // Def-use: total is defined at 0 and redefined at 4; i at 1, 5.
  let defuse : @core.DefUse = {
    reaching: [
      (0, 4), // total defined at 0 reaches its own increment at 4
      (0, 6), // total defined at 0 reaches the return
      (1, 2), // i defined at 1 reaches the loop condition
      (1, 3), // i reaches the if condition
      (1, 4), // i reaches the increment of total
      (1, 5), // i reaches its own increment
      (4, 6), // total redefined at 4 reaches the return
      (5, 2), // i redefined at 5 reaches the loop condition
      (5, 3), // i redefined at 5 reaches the if condition
    ],
  }
  let cdg = @cdg.build(prog, cfg)
  // The while controls its body (3, 4, 5); the if controls its two branches.
  // No escape rule fires: no return or break sits inside a non-loop controller.
  assert_eq(cdg.edges, [(2, 3), (2, 4), (2, 5), (3, 4), (3, 5)])
  let pdg = @pdg.build(defuse, cdg)
  let edge_count = pdg.edges.length()
  assert_eq(edge_count, 5 + 9)
  // Backward from the return on line 11: the return depends on total at 0 and 4,
  // on the controller if at 3 and while at 2, and on the definitions they carry.
  let backward = @slice.backward(pdg, 6, program=prog)
  assert_eq(backward.nodes, [0, 1, 2, 3, 4, 5, 6])
  assert_eq(backward.lines, [2, 3, 4, 5, 6, 8, 11])
  // Forward from the definition on line 2: the only outgoing dependency is the
  // increment on line 6 (data) and the return on line 11 (data). Control edges
  // point from controller to body, so 0 cannot reach the controllers.
  let forward = @slice.forward(pdg, 0, program=prog)
  assert_eq(forward.nodes, [0, 4, 6])
  assert_eq(forward.lines, [2, 6, 11])
}

///|
test "end to end: a dead assignment stays out of the backward slice" {
  // line 1: fn f(n : Int) -> Int {
  // line 2:   let dead = 41
  // line 3:   let live = n + 1
  // line 4:   live
  // line 5: }
  let dead = e2e_var("dead")
  let live = e2e_var("live")
  let n_var = e2e_var("n")
  let prog : @core.Program = {
    nodes: [
      e2e_node(0, @core.Let, 2, 3, [dead], [], [], None),
      e2e_node(1, @core.Let, 3, 3, [live], [n_var], [], None),
      e2e_node(2, @core.Expr, 4, 3, [], [live], [], None),
    ],
    functions: [{ name: "f", entry: 0, exit: 2, }],
    errors: [],
  }
  let cfg : @core.Cfg = { edges: [(0, 1), (1, 2)], entry: 0, exit: 2, }
  let defuse : @core.DefUse = { reaching: [(1, 2)], }
  let cdg = @cdg.build(prog, cfg)
  assert_eq(cdg.edges, [])
  let pdg = @pdg.build(defuse, cdg)
  let backward = @slice.backward(pdg, 2, program=prog)
  // The dead definition at line 2 never reaches the use, so it is absent.
  assert_eq(backward.nodes, [1, 2])
  assert_eq(backward.lines, [3, 4])
}

///|
test "end to end: return inside a branch widens the control slice" {
  // line 1: fn g(x : Int) -> Int {
  // line 2:   if x < 0 {
  // line 3:     return 0
  // line 4:   }
  // line 5:   let y = x + 1
  // line 6:   y
  // line 7: }
  let x_var = e2e_var("x")
  let y_var = e2e_var("y")
  let prog : @core.Program = {
    nodes: [
      e2e_node(0, @core.If, 2, 3, [], [x_var], [1], None),
      e2e_node(1, @core.Return, 3, 5, [], [], [], Some(0)),
      e2e_node(2, @core.Let, 5, 3, [y_var], [x_var], [], None),
      e2e_node(3, @core.Expr, 6, 3, [], [y_var], [], None),
    ],
    functions: [{ name: "g", entry: 0, exit: 3, }],
    errors: [],
  }
  let cfg : @core.Cfg = {
    edges: [(0, 1), (0, 2), (1, 3), (2, 3)],
    entry: 0,
    exit: 3,
  }
  let defuse : @core.DefUse = { reaching: [(2, 3)], }
  let cdg = @cdg.build(prog, cfg)
  // The if controls its return; the escape rule also marks lines 5 and 6,
  // because reaching them means the branch did not return.
  assert_eq(cdg.edges, [(0, 1), (0, 2), (0, 3)])
  let pdg = @pdg.build(defuse, cdg)
  // Backward from line 6: the definition of y at line 5 and the guarding if at
  // line 2. The return at line 3 cannot produce y, so it stays out.
  let backward = @slice.backward(pdg, 3, program=prog)
  assert_eq(backward.nodes, [0, 2, 3])
  assert_eq(backward.lines, [2, 5, 6])
  // The forward slice from the branch condition controls both branches and
  // therefore reaches them, but the return has no outgoing edge to line 5/6.
  let forward = @slice.forward(pdg, 0, program=prog)
  assert_eq(forward.nodes, [0, 1, 2, 3])
  assert_eq(forward.lines, [2, 3, 5, 6])
}
