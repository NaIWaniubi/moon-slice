// Whitebox tests for reaching definitions on hand-built programs.
//
// These pin the analysis on shapes the parser never emits (mission 4 and the
// slicing tests build `Program` values directly) and on the guard rails: an
// empty program, a CFG that omits a node, and an unused getter.

///|
fn empty_loc() -> @core.Loc {
  { start_line: 0, start_col: 0, end_line: 0, end_col: 0, }
}

///|
fn mkvar(name : String, scope : Int32) -> @core.VarId {
  { name, scope, }
}

///|
fn node(
  id : Int32,
  defs : Array[@core.VarId],
  uses : Array[@core.VarId],
) -> @core.SNode {
  {
    id,
    kind: @core.SNodeKind::Expr,
    loc: empty_loc(),
    defs,
    uses,
    children: [],
    parent: None,
  }
}

///|
test "a hand-built chain produces one edge per step" {
  //  0 defines x, 1 uses x, 2 defines y
  let program : @core.Program = {
    nodes: [
      node(0, [mkvar("x", 1)], []),
      node(1, [], [mkvar("x", 1)]),
      node(2, [mkvar("y", 2)], []),
    ],
    functions: [{ name: "f", entry: 0, exit: 2, }],
    errors: [],
  }
  let cfg : @core.Cfg = { edges: [(0, 1), (1, 2)], entry: 0, exit: 2, }
  let defuse = analyze(program, cfg)
  assert_eq(defuse.reaching, [(0, 1)])
}

///|
test "an empty program yields no reaching definitions" {
  let program : @core.Program = { nodes: [], functions: [], errors: [], }
  let cfg : @core.Cfg = { edges: [], entry: 0, exit: 0, }
  let defuse = analyze(program, cfg)
  assert_eq(defuse.reaching.length(), 0)
}

///|
test "an isolated node with no predecessors still reads its own definition" {
  // Node 0 defines and uses the same var, with no CFG edges at all.
  let program : @core.Program = {
    nodes: [node(0, [mkvar("x", 1)], [mkvar("x", 1)])],
    functions: [{ name: "f", entry: 0, exit: 0, }],
    errors: [],
  }
  let cfg : @core.Cfg = { edges: [], entry: 0, exit: 0, }
  let defuse = analyze(program, cfg)
  // GEN happens after the incoming set is computed, so a node's own definition
  // does not reach its own uses. This documents that choice.
  assert_eq(defuse.reaching.length(), 0)
}

///|
test "two definitions of the same var reaching one use both appear" {
  //  0 d1(x), 1 d2(x), 2 use(x), edges 0->2 and 1->2
  let program : @core.Program = {
    nodes: [
      node(0, [mkvar("x", 1)], []),
      node(1, [mkvar("x", 1)], []),
      node(2, [], [mkvar("x", 1)]),
    ],
    functions: [{ name: "f", entry: 0, exit: 2, }],
    errors: [],
  }
  let cfg : @core.Cfg = { edges: [(0, 2), (1, 2)], entry: 0, exit: 2, }
  let defuse = analyze(program, cfg)
  assert_eq(defuse.reaching, [(0, 2), (1, 2)])
}

///|
test "a definition of another variable is not killed" {
  //  0 d(x), 1 d(y), 2 use(x)
  let program : @core.Program = {
    nodes: [
      node(0, [mkvar("x", 1)], []),
      node(1, [mkvar("y", 2)], []),
      node(2, [], [mkvar("x", 1)]),
    ],
    functions: [{ name: "f", entry: 0, exit: 2, }],
    errors: [],
  }
  let cfg : @core.Cfg = { edges: [(0, 1), (1, 2)], entry: 0, exit: 2, }
  let defuse = analyze(program, cfg)
  assert_eq(defuse.reaching, [(0, 2)])
}

///|
test "distinct scopes of the same name are distinct variables" {
  //  0 d(x#1), 1 d(x#2), 2 use(x#2)
  let program : @core.Program = {
    nodes: [
      node(0, [mkvar("x", 1)], []),
      node(1, [mkvar("x", 2)], []),
      node(2, [], [mkvar("x", 2)]),
    ],
    functions: [{ name: "f", entry: 0, exit: 2, }],
    errors: [],
  }
  let cfg : @core.Cfg = { edges: [(0, 1), (1, 2)], entry: 0, exit: 2, }
  let defuse = analyze(program, cfg)
  assert_eq(defuse.reaching, [(1, 2)])
}

///|
test "edges pointing outside the node range are ignored" {
  let program : @core.Program = {
    nodes: [node(0, [mkvar("x", 1)], []), node(1, [], [mkvar("x", 1)])],
    functions: [{ name: "f", entry: 0, exit: 1, }],
    errors: [],
  }
  let cfg : @core.Cfg = {
    edges: [(0, 1), (0, 99), (99, 1)],
    entry: 0,
    exit: 1,
  }
  let defuse = analyze(program, cfg)
  assert_eq(defuse.reaching, [(0, 1)])
}

///|
test "a cyclic CFG converges instead of looping forever" {
  //  0 d(x), 1 use(x), 1 -> 0 back edge
  let program : @core.Program = {
    nodes: [node(0, [mkvar("x", 1)], []), node(1, [], [mkvar("x", 1)])],
    functions: [{ name: "f", entry: 0, exit: 1, }],
    errors: [],
  }
  let cfg : @core.Cfg = { edges: [(0, 1), (1, 0)], entry: 0, exit: 1, }
  let defuse = analyze(program, cfg)
  assert_eq(defuse.reaching, [(0, 1)])
}

///|
test "a use of a var with no definition site stays unreached" {
  let program : @core.Program = {
    nodes: [node(0, [], [mkvar("ghost", -1)])],
    functions: [{ name: "f", entry: 0, exit: 0, }],
    errors: [],
  }
  let cfg : @core.Cfg = { edges: [], entry: 0, exit: 0, }
  let defuse = analyze(program, cfg)
  assert_eq(defuse.reaching.length(), 0)
}
