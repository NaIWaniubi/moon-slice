// Reference-slicer tests: hand-built IR trees whose expected dependence sets
// are written out by hand, so a wrong answer cannot hide behind the pipeline.
//
// The trees mirror exactly what the adapter emits (entry/exit boundary nodes,
// one region node per branch or loop body, `children` positional), so these
// tests exercise the reference on the shapes it meets in production.

///|
fn t_loc(line : Int32) -> @core.Loc {
  { start_line: line, start_col: 1, end_line: line, end_col: 2, }
}

///|
fn t_var(name : String) -> @core.VarId {
  { name, scope: 0, }
}

///|
fn t_var2(name : String, scope : Int32) -> @core.VarId {
  { name, scope, }
}

///|
fn t_node(
  id : Int32,
  kind : @core.SNodeKind,
  line : Int32,
  defs : Array[@core.VarId],
  uses : Array[@core.VarId],
  children : Array[Int32],
  parent : Int32?,
) -> @core.SNode {
  { id, kind, loc: t_loc(line), defs, uses, children, parent }
}

///|
/// One function `f` from `entry` to `exit`.
fn t_program(nodes : Array[@core.SNode], entry : Int32, exit : Int32) -> @core.Program {
  {
    nodes,
    functions: [{ name: "f", entry, exit }],
    calls: [],
    errors: [],
  }
}

///|
fn t_ints(values : Array[Int32]) -> String {
  let out = StringBuilder()
  out.write_string("[")
  let mut i = 0
  while i < values.length() {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string(values[i].to_string())
    i = i + 1
  }
  out.write_string("]")
  out.to_string()
}

///|
fn t_pairs(values : Array[(Int32, Int32)]) -> String {
  let out = StringBuilder()
  out.write_string("[")
  let mut i = 0
  while i < values.length() {
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string("(")
    out.write_string(values[i].0.to_string())
    out.write_string(", ")
    out.write_string(values[i].1.to_string())
    out.write_string(")")
    i = i + 1
  }
  out.write_string("]")
  out.to_string()
}

///|
/// A straight line: `let mut x = a` then `let y = x`.
///
///   0 entry (defines a)
///   1 LetMut x   (uses a, defines x)
///   2 Let    y   (uses x, defines y)
///   3 exit
fn t_line() -> @core.Program {
  let a = t_var("a")
  let x = t_var2("x", 1)
  let y = t_var2("y", 2)
  t_program(
    [
      t_node(0, @core.Expr, 1, [a], [], [], None),
      t_node(1, @core.LetMut, 2, [x], [a], [], None),
      t_node(2, @core.Let, 3, [y], [x], [], None),
      t_node(3, @core.Expr, 1, [], [], [], None),
    ],
    0,
    3,
  )
}

///|
test "reference backward walks a straight line to the parameter" {
  let sliced = @oracle.reference_backward(t_line(), 2)
  assert_eq(t_ints(sliced), "[0, 1, 2]")
}

///|
test "reference forward walks a straight line to its reader" {
  let sliced = @oracle.reference_forward(t_line(), 1)
  assert_eq(t_ints(sliced), "[1, 2]")
}

///|
test "reference backward of a node with no incoming edge is itself" {
  let sliced = @oracle.reference_backward(t_line(), 0)
  assert_eq(t_ints(sliced), "[0]")
}

///|
test "reference dependences of a straight line are the chained definitions" {
  let deps = @oracle.reference_dependences(t_line())
  assert_eq(t_pairs(deps.data), "[(0, 1), (1, 2)]")
  assert_eq(t_pairs(deps.control), "[]")
  assert_true(!deps.truncated)
  assert_eq(deps.paths, 1)
}

///|
/// `if a < b { x = a } else { x = b }` then `let y = x`.
///
///   0 entry            (defines a, b)
///   1 LetMut x = a     (uses a)
///   2 If  a < b        (uses a, b)
///   3 If region        (then)
///   4 Assign x = a
///   5 If region        (else)
///   6 Assign x = b
///   7 Let y = x        (uses x)
///   8 exit
fn t_branch() -> @core.Program {
  let a = t_var("a")
  let b = t_var("b")
  let x = t_var2("x", 1)
  let y = t_var2("y", 2)
  t_program(
    [
      t_node(0, @core.Expr, 1, [a, b], [], [], None),
      t_node(1, @core.LetMut, 2, [x], [a], [], None),
      t_node(2, @core.If, 3, [], [a, b], [3, 5], None),
      t_node(3, @core.If, 3, [], [], [4], Some(2)),
      t_node(4, @core.Assign, 4, [x], [a], [], Some(3)),
      t_node(5, @core.If, 5, [], [], [6], Some(2)),
      t_node(6, @core.Assign, 6, [x], [b], [], Some(5)),
      t_node(7, @core.Let, 7, [y], [x], [], None),
      t_node(8, @core.Expr, 1, [], [], [], None),
    ],
    0,
    8,
  )
}

///|
test "reference data flow joins both branches at the use after the if" {
  let deps = @oracle.reference_dependences(t_branch())
  // (0, 2) is the `if` reading a and b; (4, 7) and (6, 7) are the two writes
  // that can reach the join point. (1, 7) is absent: `x = a` is overwritten on
  // both arms before the read, so it never reaches it.
  assert_eq(
    t_pairs(deps.data),
    "[(0, 1), (0, 2), (0, 4), (0, 6), (4, 7), (6, 7)]",
  )
}

///|
test "reference control flow names the head, both regions and both bodies" {
  let deps = @oracle.reference_dependences(t_branch())
  // The if governs its regions (3, 5) and the statements inside them (4, 6);
  // each region governs its own body. The statement after the if (7) is reached
  // through every successor, so it is not controlled by the if.
  assert_eq(t_pairs(deps.control), "[(2, 3), (2, 4), (2, 5), (2, 6), (3, 4), (5, 6)]")
}

///|
test "reference backward slice of the join point reaches both writes" {
  let sliced = @oracle.reference_backward(t_branch(), 7)
  // Node 1 (`x = a`) is genuinely absent: both arms redefine x, so no path
  // carries that write into the read at 7.
  assert_eq(t_ints(sliced), "[0, 2, 3, 4, 5, 6, 7]")
}

///|
test "reference forward slice of a branch head covers both arms" {
  let sliced = @oracle.reference_forward(t_branch(), 2)
  assert_eq(t_ints(sliced), "[2, 3, 4, 5, 6, 7]")
}

///|
test "reference forward slice of one arm skips the other arm" {
  // From the then-branch write: it reaches the read after the if, and nothing in
  // the else arm.
  let sliced = @oracle.reference_forward(t_branch(), 4)
  assert_eq(t_ints(sliced), "[4, 7]")
}

///|
/// `while x < n { y = x; x = 1 }`.
///
///   0 entry          (defines n)
///   1 LetMut x = 0   (defines x)
///   2 While  x < n   (uses x, n)
///   3 While region
///   4 Assign y = x   (uses x)
///   5 Assign x = 1   (defines x)
///   6 exit
fn t_loop() -> @core.Program {
  let n = t_var("n")
  let x = t_var2("x", 1)
  let y = t_var2("y", 2)
  t_program(
    [
      t_node(0, @core.Expr, 1, [n], [], [], None),
      t_node(1, @core.LetMut, 2, [x], [], [], None),
      t_node(2, @core.While, 3, [], [x, n], [3], None),
      t_node(3, @core.While, 3, [], [], [4, 5], Some(2)),
      t_node(4, @core.Assign, 4, [y], [x], [], Some(3)),
      t_node(5, @core.Assign, 5, [x], [], [], Some(3)),
      t_node(6, @core.Expr, 1, [], [], [], None),
    ],
    0,
    6,
  )
}

///|
test "reference finds the definition that reaches a read across iterations" {
  let deps = @oracle.reference_dependences(t_loop())
  // (5, 4) only exists on the second iteration: `x = 1` in one pass reaches
  // `y = x` in the next. A single unrolled pass would miss it.
  assert_eq(t_pairs(deps.data), "[(0, 2), (1, 2), (1, 4), (5, 2), (5, 4)]")
}

///|
test "reference control flow marks the loop body and its pieces" {
  let deps = @oracle.reference_dependences(t_loop())
  assert_eq(t_pairs(deps.control), "[(2, 3), (2, 4), (2, 5), (3, 4), (3, 5)]")
}

///|
test "reference backward slice of a loop body includes the back edge" {
  let sliced = @oracle.reference_backward(t_loop(), 4)
  // y = x is fed by the initial x and by the in-loop x = 1; the loop condition
  // needs n, which comes from the entry node.
  assert_eq(t_ints(sliced), "[0, 1, 2, 3, 4, 5]")
}

///|
test "reference forward slice of a loop write reaches the next read" {
  let sliced = @oracle.reference_forward(t_loop(), 5)
  // x = 1 feeds the loop condition (which in turn decides the body) and the next
  // iteration's y = x.
  assert_eq(t_ints(sliced), "[2, 3, 4, 5]")
}

///|
/// `let x = a` then a call `f(x)`: a call node reads its arguments.
///
///   0 entry        (defines a)
///   1 Let x = a
///   2 Call f(x)
///   3 exit
fn t_call() -> @core.Program {
  let a = t_var("a")
  let x = t_var2("x", 1)
  t_program(
    [
      t_node(0, @core.Expr, 1, [a], [], [], None),
      t_node(1, @core.Let, 2, [x], [a], [], None),
      t_node(2, @core.Call, 3, [], [x], [], None),
      t_node(3, @core.Expr, 1, [], [], [], None),
    ],
    0,
    3,
  )
}

///|
test "reference treats a call argument as a use of its definition" {
  let deps = @oracle.reference_dependences(t_call())
  assert_eq(t_pairs(deps.data), "[(0, 1), (1, 2)]")
  assert_eq(t_ints(@oracle.reference_backward(t_call(), 2)), "[0, 1, 2]")
}

///|
test "reference reports one path for straight-line code" {
  let deps = @oracle.reference_dependences(t_call())
  assert_eq(deps.paths, 1)
  assert_true(!deps.truncated)
}

///|
test "reference slice of an absent criterion is just that id" {
  let sliced = @oracle.reference_backward(t_line(), 99)
  assert_eq(t_ints(sliced), "[99]")
}

///|
test "reference handles a program whose functions list is empty" {
  // A hand-built tree with no `functions` entry is treated as one region from
  // the smallest id to the largest.
  let a = t_var("a")
  let x = t_var2("x", 1)
  let program : @core.Program = {
    nodes: [
      t_node(0, @core.Expr, 1, [a], [], [], None),
      t_node(1, @core.LetMut, 2, [x], [a], [], None),
      t_node(2, @core.Expr, 3, [], [x], [], None),
    ],
    functions: [],
    calls: [],
    errors: [],
  }
  assert_eq(t_ints(@oracle.reference_backward(program, 2)), "[0, 1, 2]")
}

///|
test "reference keeps shadowed names apart" {
  // `let a = p` and an inner `let a = q` are different variables: the second
  // definition must not reach a read of the first.
  let p = t_var("p")
  let q = t_var("q")
  let outer = t_var2("a", 10)
  let inner = t_var2("a", 11)
  let program = t_program(
    [
      t_node(0, @core.Expr, 1, [p, q], [], [], None),
      t_node(1, @core.Let, 2, [outer], [p], [], None),
      t_node(2, @core.Let, 3, [inner], [q], [], None),
      t_node(3, @core.Expr, 4, [], [outer], [], None),
      t_node(4, @core.Expr, 1, [], [], [], None),
    ],
    0,
    4,
  )
  let deps = @oracle.reference_dependences(program)
  assert_eq(t_pairs(deps.data), "[(0, 1), (0, 2), (1, 3)]")
}

///|
test "reference drops branches that cannot reach the exit" {
  // The if has two arms but only the first contains a statement; the empty arm
  // still contributes a region node and a control edge, and still reaches the
  // join point.
  let a = t_var("a")
  let x = t_var2("x", 1)
  let program = t_program(
    [
      t_node(0, @core.Expr, 1, [a], [], [], None),
      t_node(1, @core.If, 2, [], [a], [2, 3], None),
      t_node(2, @core.If, 2, [], [], [4], Some(1)),
      t_node(3, @core.If, 2, [], [], [], Some(1)),
      t_node(4, @core.Assign, 3, [x], [a], [], Some(2)),
      t_node(5, @core.Expr, 4, [], [x], [], None),
      t_node(6, @core.Expr, 1, [], [], [], None),
    ],
    0,
    6,
  )
  let deps = @oracle.reference_dependences(program)
  assert_eq(t_pairs(deps.control), "[(1, 2), (1, 3), (1, 4), (2, 4)]")
  // The write in the then-branch (4) reaches the read at 5.
  assert_eq(t_ints(@oracle.reference_forward(program, 1)), "[1, 2, 3, 4, 5]")
}
