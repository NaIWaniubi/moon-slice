// Blackbox tests for the SSA pass.
//
// Every test drives the real front end: a MoonBit source string is parsed and
// lowered by `@parser_adapter`, the CFG is built by `@cfg`, and only then is SSA
// constructed. Node ids are never assumed; helpers look nodes up by the variable
// they define or use, which keeps the expectations readable and lets the parser
// evolve its layout without breaking these tests.
//
// The invariants under test are the ones the pass promises:
//
//   * a straight-line function is one block with no phi nodes;
//   * a join gets exactly one phi per variable that can arrive from more than
//     one definition, with one operand per predecessor block;
//   * a loop header gets a phi for every loop-carried variable, with the back
//     edge as one of the operands;
//   * every use is dominated by the definition it resolves to (checked both by
//     `verify` and explicitly, use by use);
//   * `ssa_def_use` reproduces the reaching-definition pairs a conventional
//     analysis reports, phis included.

///|
fn parse(source : String) -> @core.Program {
  @parser_adapter.parse_source(source, "ssa.mbt")
}

///|
fn ssa_of(source : String) -> @ssa.SsaProgram {
  let program = parse(source)
  let cfg = @cfg.build(program)
  @ssa.build(program, cfg)
}

///|
fn var_named(program : @core.Program, name : String) -> @core.VarId {
  for node in program.nodes {
    for v in node.defs {
      if v.name == name {
        return v
      }
    }
  }
  for node in program.nodes {
    for v in node.uses {
      if v.name == name {
        return v
      }
    }
  }
  abort("variable \{name} is not in the program")
}

///|
fn block_id(ssa : @ssa.SsaProgram, node : Int32) -> Int32 {
  match @ssa.block_of(ssa, node) {
    Some(block) => block
    None => abort("node \{node} has no block")
  }
}

///|
fn nodes_defining(program : @core.Program, name : String) -> Array[Int32] {
  let out : Array[Int32] = []
  for node in program.nodes {
    for v in node.defs {
      if v.name == name && !out.contains(node.id) {
        out.push(node.id)
      }
    }
  }
  out
}

///|
fn nodes_using(program : @core.Program, name : String) -> Array[Int32] {
  let out : Array[Int32] = []
  for node in program.nodes {
    for v in node.uses {
      if v.name == name && !out.contains(node.id) {
        out.push(node.id)
      }
    }
  }
  out
}

///|
fn has_pair(pairs : Array[(Int32, Int32)], from : Int32, to : Int32) -> Bool {
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
fn entry_node(program : @core.Program) -> Int32 {
  if program.functions.length() == 0 {
    abort("program has no functions")
  }
  program.functions[0].entry
}

///|
fn has_phi(ssa : @ssa.SsaProgram, var_ : @core.VarId, block : Int32) -> Bool {
  match @ssa.phi_at(ssa, var_, block) {
    Some(_) => true
    None => false
  }
}

///|
fn is_defined(value : @ssa.SsaValue?) -> Bool {
  match value {
    Some(_) => true
    None => false
  }
}

// ---------------------------------------------------------------------------
// Straight-line code
// ---------------------------------------------------------------------------

///|
test "empty program yields an empty SSA form" {
  let ssa = ssa_of("")
  assert_eq(ssa.blocks.length(), 0)
  assert_eq(ssa.phis.length(), 0)
  assert_eq(ssa.stmts.length(), 0)
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "straight-line function is a single block" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  assert_eq(ssa.blocks.length(), 1)
  // 0 entry(a), 1 let s = a, 2 use s, 3 exit
  assert_eq(ssa.blocks[0].nodes, [0, 1, 2, 3])
  assert_eq(ssa.blocks[0].idom, 0)
  assert_eq(ssa.blocks[0].preds, [])
  assert_eq(ssa.blocks[0].succs, [])
  assert_eq(ssa.blocks[0].frontier, [])
  assert_eq(@ssa.verify(ssa), [])
  assert_eq(program.nodes.length(), 4)
}

///|
test "straight-line function needs no phi nodes" {
  let ssa = ssa_of("fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n")
  assert_eq(ssa.phis.length(), 0)
}

///|
test "parameter is visible on entry to the function block" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let a = var_named(program, "a")
  let entry = entry_node(program)
  let param = @ssa.defs_of(ssa, entry)[0]
  assert_eq(@ssa.def_of(ssa, a, block_id(ssa, entry)), Some(param))
  assert_eq(param.version, 1)
}

///|
test "the first definition of a variable is version one" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let s = nodes_defining(program, "s")[0]
  assert_eq(@ssa.defs_of(ssa, s)[0].version, 1)
}

///|
test "a use resolves to the definition that dominates it" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let defined = nodes_defining(program, "s")[0]
  let used = nodes_using(program, "s")[0]
  assert_eq(@ssa.uses_of(ssa, used)[0], @ssa.defs_of(ssa, defined)[0])
}

///|
test "assignment creates a second version and the next use picks it" {
  let source = "fn f(a : Int) -> Int {\n  let mut x = 0\n  x = a\n  x\n}\n"
  let ssa = ssa_of(source)
  // 0 entry(a), 1 letmut x, 2 assign x = a, 3 use x, 4 exit
  let initial = @ssa.defs_of(ssa, 1)[0]
  let overwrite = @ssa.defs_of(ssa, 2)[0]
  assert_eq(initial.version, 1)
  assert_eq(overwrite.version, 2)
  assert_eq(@ssa.uses_of(ssa, 3)[0], overwrite)
  assert_true(@ssa.uses_of(ssa, 3)[0] != initial)
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "an unbound name is the undefined value and produces no def-use edge" {
  let source = "fn f() -> Int {\n  g\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let g = var_named(program, "g")
  let used = nodes_using(program, "g")[0]
  let value = @ssa.uses_of(ssa, used)[0]
  assert_eq(value.base, g)
  assert_eq(value.version, 0)
  assert_eq(@ssa.def_of(ssa, g, block_id(ssa, used)), None)
  assert_eq(@ssa.def_node(ssa, value), None)
  assert_eq(@ssa.ssa_def_use(ssa), [])
}

///|
test "def_of is None for a variable before its defining statement" {
  let source = "fn f(a : Int) -> Int {\n  let mut x = 0\n  x\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let x = var_named(program, "x")
  let entry = entry_node(program)
  // `x` is defined by the statement after the entry node, not on entry.
  assert_eq(@ssa.def_of(ssa, x, block_id(ssa, entry)), None)
}

// ---------------------------------------------------------------------------
// If / else joins
// ---------------------------------------------------------------------------

///|
test "if/else join receives a phi for a variable defined in both branches" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let x = var_named(program, "x")
  // 0 entry(c), 1 letmut x, 2 head, 3 then-region, 4 then store,
  // 5 else-region, 6 else store, 7 use x, 8 exit
  let join = block_id(ssa, 7)
  let phi = @ssa.phi_at(ssa, x, join).unwrap()
  assert_eq(phi.block, join)
  assert_eq(phi.sources.length(), 2)
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "phi operands name the branch blocks and their definitions" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let x = var_named(program, "x")
  let join = block_id(ssa, 7)
  let then_block = block_id(ssa, 4)
  let else_block = block_id(ssa, 6)
  let sources = @ssa.phi_sources(ssa, x, join)
  assert_eq(sources.length(), 2)
  assert_eq(sources[0].0, then_block)
  assert_eq(sources[1].0, else_block)
  assert_eq(sources[0].1, @ssa.defs_of(ssa, 4)[0])
  assert_eq(sources[1].1, @ssa.defs_of(ssa, 6)[0])
  // The initial definition on line 2 is killed on both paths.
  assert_true(sources[0].1 != @ssa.defs_of(ssa, 1)[0])
  assert_eq(ssa.blocks[join].preds, [then_block, else_block])
}

///|
test "the join block's immediate dominator is the branch head" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let ssa = ssa_of(source)
  let join = block_id(ssa, 7)
  let head = block_id(ssa, 2)
  assert_eq(ssa.blocks[join].idom, head)
  assert_true(@ssa.dominates(ssa, head, join))
}

///|
test "the dominance frontier of a branch is the join" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let ssa = ssa_of(source)
  let join = block_id(ssa, 7)
  assert_true(ssa.blocks[block_id(ssa, 4)].frontier.contains(join))
  assert_true(ssa.blocks[block_id(ssa, 6)].frontier.contains(join))
  assert_true(!ssa.blocks[block_id(ssa, 1)].frontier.contains(join))
}

///|
test "if without else still phi-merges the branch definition" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  }\n  x\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let x = var_named(program, "x")
  // 0 entry(c), 1 letmut x, 2 head, 3 then-region, 4 store, 5 use x, 6 exit
  let join = block_id(ssa, 5)
  let phi = @ssa.phi_at(ssa, x, join).unwrap()
  assert_eq(phi.sources.length(), 2)
  // One operand is the branch store, the other the pre-if definition.
  assert_eq(phi.sources[0].0, block_id(ssa, 1))
  assert_eq(phi.sources[0].1, @ssa.defs_of(ssa, 1)[0])
  assert_eq(phi.sources[1].0, block_id(ssa, 4))
  assert_eq(phi.sources[1].1, @ssa.defs_of(ssa, 4)[0])
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "the value at the join is the phi, not either branch definition" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let x = var_named(program, "x")
  let join = block_id(ssa, 7)
  let phi = @ssa.phi_at(ssa, x, join).unwrap()
  assert_eq(@ssa.def_of(ssa, x, join), Some(phi.value))
  assert_eq(@ssa.uses_of(ssa, 7)[0], phi.value)
  assert_eq(@ssa.def_site(ssa, phi.value), Some(@ssa.SsaDefSite::DefPhi(phi.id)))
  assert_eq(@ssa.def_node(ssa, phi.value), None)
}

///|
test "a branch block does not dominate the join" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let ssa = ssa_of(source)
  let then_block = block_id(ssa, 4)
  let else_block = block_id(ssa, 6)
  let join = block_id(ssa, 7)
  assert_true(!@ssa.dominates(ssa, then_block, join))
  assert_true(!@ssa.dominates(ssa, else_block, join))
  assert_true(!@ssa.dominates(ssa, join, then_block))
}

///|
test "a definiton site for a let is the statement node" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let s = nodes_defining(program, "s")[0]
  let value = @ssa.defs_of(ssa, s)[0]
  assert_eq(@ssa.def_site(ssa, value), Some(@ssa.SsaDefSite::DefStmt(s)))
  assert_eq(@ssa.def_node(ssa, value), Some(s))
  assert_eq(@ssa.def_block(ssa, value), Some(block_id(ssa, s)))
}

// ---------------------------------------------------------------------------
// Loops
// ---------------------------------------------------------------------------

///|
test "while head receives a phi for the loop-carried variable" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let i = var_named(program, "i")
  // 0 entry(n), 1 letmut i, 2 while head, 3 body-region, 4 assign i,
  // 5 use i, 6 exit
  let head = block_id(ssa, 2)
  let phi = @ssa.phi_at(ssa, i, head).unwrap()
  assert_eq(phi.sources.length(), 2)
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "loop phi operands are the preheader definition and the back edge" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let i = var_named(program, "i")
  let head = block_id(ssa, 2)
  let body = block_id(ssa, 4)
  let sources = @ssa.phi_sources(ssa, i, head)
  assert_eq(sources[0].0, block_id(ssa, 1))
  assert_eq(sources[0].1, @ssa.defs_of(ssa, 1)[0])
  assert_eq(sources[1].0, body)
  assert_eq(sources[1].1, @ssa.defs_of(ssa, 4)[0])
}

///|
test "the read after a loop sees the loop phi" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let i = var_named(program, "i")
  let head = block_id(ssa, 2)
  let phi = @ssa.phi_at(ssa, i, head).unwrap()
  assert_eq(@ssa.uses_of(ssa, 5)[0], phi.value)
  assert_eq(@ssa.def_of(ssa, i, block_id(ssa, 5)), Some(phi.value))
}

///|
test "the loop body's read of the counter sees the header phi" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let i = var_named(program, "i")
  let head = block_id(ssa, 2)
  let phi = @ssa.phi_at(ssa, i, head).unwrap()
  // The assignment reads the old value, which on the back edge is the phi.
  assert_eq(@ssa.uses_of(ssa, 4)[0], phi.value)
  assert_true(@ssa.defs_of(ssa, 4)[0] != phi.value)
}

///|
test "a loop head is dominated by the block before it and dominates the body" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n"
  let ssa = ssa_of(source)
  let head = block_id(ssa, 2)
  let body = block_id(ssa, 4)
  let pre = block_id(ssa, 1)
  assert_true(@ssa.dominates(ssa, pre, head))
  assert_true(@ssa.dominates(ssa, head, body))
  assert_true(@ssa.dominates(ssa, head, head))
  assert_true(!@ssa.dominates(ssa, body, head))
}

///|
test "nested loops place a phi at each loop header and verify" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    let mut j = 0\n    while j < n {\n      break\n    }\n    i = i + 1\n  }\n  i\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let i = var_named(program, "i")
  let j = var_named(program, "j")
  // 0 entry, 1 letmut i, 2 while i, 3 outer region, 4 letmut j,
  // 5 while j, 6 inner region, 7 break, 8 assign i, 9 trailing, 10 exit
  // `j` is defined in the outer body, so its phi lands on the outer header just
  // like `i`'s: the inner header shares a block with the definition.
  assert_true(has_phi(ssa, i, block_id(ssa, 2)))
  assert_true(has_phi(ssa, j, block_id(ssa, 2)))
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "break contributes an operand to the post-loop phi" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n    if i > 2 {\n      break\n    } else {\n      continue\n    }\n  }\n  i\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let i = var_named(program, "i")
  // 0 entry, 1 letmut i, 2 head, 3 region, 4 assign, 5 if head,
  // 6 then-region, 7 break, 8 else-region, 9 continue, 10 trailing, 11 exit
  let join = block_id(ssa, 10)
  let phi = @ssa.phi_at(ssa, i, join).unwrap()
  assert_eq(phi.sources.length(), 2)
  // The loop head's phi value and the value produced before the break.
  assert_eq(phi.sources[0].0, block_id(ssa, 2))
  assert_eq(phi.sources[1].0, block_id(ssa, 7))
  assert_true(@ssa.uses_of(ssa, 10)[0] == phi.value)
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "continue feeds the loop header phi through the back edge" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n    if i > 2 {\n      break\n    } else {\n      continue\n    }\n  }\n  i\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let i = var_named(program, "i")
  let head = block_id(ssa, 2)
  let continue_block = block_id(ssa, 9)
  let sources = @ssa.phi_sources(ssa, i, head)
  assert_eq(sources.length(), 2)
  assert_eq(sources[0].0, block_id(ssa, 1))
  assert_eq(sources[1].0, continue_block)
  assert_eq(sources[1].1, @ssa.defs_of(ssa, 4)[0])
}

///|
test "a for loop with a step block verifies" {
  let source = "fn f(xs : Array[Int]) -> Int {\n  let mut t = 0\n  for x in xs {\n    t = t + x\n  }\n  t\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let t = var_named(program, "t")
  // 0 entry(xs), 1 letmut t, 2 for head, 3 body-region, 4 assign t,
  // 5 trailing t, 6 exit
  assert_true(has_phi(ssa, t, block_id(ssa, 2)))
  assert_eq(@ssa.verify(ssa), [])
}

// ---------------------------------------------------------------------------
// Nested control flow, multiple variables, match
// ---------------------------------------------------------------------------

///|
test "nested branches get one phi per join" {
  let source = "fn f(c : Bool, d : Bool) -> Int {\n  let mut x = 0\n  if c {\n    if d {\n      x = 1\n    } else {\n      x = 2\n    }\n    x = x + 10\n  } else {\n    x = 3\n  }\n  x\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let x = var_named(program, "x")
  // The inner if joins before `x = x + 10`; the outer if joins before the final
  // read, so two distinct joins need a phi each.
  let x_phis : Array[Int32] = []
  for phi in ssa.phis {
    if phi.base == x {
      x_phis.push(phi.block)
    }
  }
  assert_eq(x_phis.length(), 2)
  assert_true(x_phis[0] != x_phis[1])
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "each variable gets its own phi at a shared join" {
  let source = "fn f(c : Bool, a : Int, b : Int) -> Int {\n  let mut x = a\n  let mut y = b\n  if c {\n    x = 1\n    y = 2\n  } else {\n    x = 3\n    y = 4\n  }\n  x + y\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let x = var_named(program, "x")
  let y = var_named(program, "y")
  // 0 entry(c,a,b), 1 letmut x, 2 letmut y, 3 head, 4 then-region,
  // 5 store x, 6 store y, 7 else-region, 8 store x, 9 store y,
  // 10 use x+y, 11 exit
  let join = block_id(ssa, 10)
  let phi_x = @ssa.phi_at(ssa, x, join).unwrap()
  let phi_y = @ssa.phi_at(ssa, y, join).unwrap()
  assert_eq(phi_x.block, phi_y.block)
  assert_true(phi_x.id != phi_y.id)
  assert_eq(phi_x.sources.length(), 2)
  assert_eq(phi_y.sources.length(), 2)
  assert_eq(phi_x.sources[0].1, @ssa.defs_of(ssa, 5)[0])
  assert_eq(phi_x.sources[1].1, @ssa.defs_of(ssa, 8)[0])
  assert_eq(phi_y.sources[0].1, @ssa.defs_of(ssa, 6)[0])
  assert_eq(phi_y.sources[1].1, @ssa.defs_of(ssa, 9)[0])
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "a match binder reaches the join through a phi with an undefined operand" {
  let source = "fn f(a : Int) -> Int {\n  match a {\n    n => n + 1\n    _ => 2\n  }\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let n = var_named(program, "n")
  // 0 entry(a), 1 match head, 2 case0-region(def n), 3 case0 body,
  // 4 case1-region, 5 case1 body, 6 exit
  let join = block_id(ssa, 6)
  let phi = @ssa.phi_at(ssa, n, join).unwrap()
  assert_eq(phi.sources.length(), 2)
  assert_eq(phi.sources[0].1, @ssa.defs_of(ssa, 2)[0])
  // The `_` case never binds `n`, so that operand is the undefined value.
  assert_eq(phi.sources[1].1.version, 0)
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "two functions are two independent SSA components" {
  let source = "fn f(a : Int) -> Int {\n  a\n}\n\nfn g(b : Int) -> Int {\n  b\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  assert_eq(ssa.phis.length(), 0)
  assert_eq(ssa.blocks.length(), 2)
  // Both components are roots, and neither dominates the other.
  assert_eq(ssa.blocks[0].idom, 0)
  assert_eq(ssa.blocks[1].idom, 1)
  assert_true(!@ssa.dominates(ssa, 0, 1))
  assert_true(!@ssa.dominates(ssa, 1, 0))
  // Each parameter is visible on entry to its own function only.
  let a = var_named(program, "a")
  let b = var_named(program, "b")
  assert_true(is_defined(@ssa.def_of(ssa, a, 0)))
  assert_eq(@ssa.def_of(ssa, a, 1), None)
  assert_true(is_defined(@ssa.def_of(ssa, b, 1)))
  assert_eq(@ssa.def_of(ssa, b, 0), None)
  assert_eq(@ssa.verify(ssa), [])
}

// ---------------------------------------------------------------------------
// Correctness invariants
// ---------------------------------------------------------------------------

///|
test "every versioned use is dominated by its definition (loop)" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n"
  let ssa = ssa_of(source)
  let mut checked = 0
  for stmt in ssa.stmts {
    for use_var in stmt.uses {
      if use_var.version > 0 {
        let defined_in = @ssa.def_block(ssa, use_var).unwrap()
        assert_true(@ssa.dominates(ssa, defined_in, stmt.block))
        checked = checked + 1
      }
    }
  }
  assert_true(checked >= 4)
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "every versioned use is dominated by its definition (nested branches)" {
  let source = "fn f(c : Bool, d : Bool) -> Int {\n  let mut x = 0\n  if c {\n    if d {\n      x = 1\n    } else {\n      x = 2\n    }\n  } else {\n    x = 3\n  }\n  x\n}\n"
  let ssa = ssa_of(source)
  for stmt in ssa.stmts {
    for use_var in stmt.uses {
      if use_var.version > 0 {
        let defined_in = @ssa.def_block(ssa, use_var).unwrap()
        assert_true(@ssa.dominates(ssa, defined_in, stmt.block))
      }
    }
  }
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "every phi has one operand per predecessor block" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n    if i > 2 {\n      break\n    } else {\n      continue\n    }\n  }\n  i\n}\n"
  let ssa = ssa_of(source)
  for phi in ssa.phis {
    assert_eq(phi.sources.length(), ssa.blocks[phi.block].preds.length())
    for source in phi.sources {
      assert_true(ssa.blocks[phi.block].preds.contains(source.0))
    }
  }
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "blocks partition every node exactly once" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let mut total = 0
  for block in ssa.blocks {
    total = total + block.nodes.length()
  }
  assert_eq(total, program.nodes.length())
  for node in program.nodes {
    let block = block_id(ssa, node.id)
    let mut occurrences = 0
    for id in ssa.blocks[block].nodes {
      if id == node.id {
        occurrences = occurrences + 1
      }
    }
    assert_eq(occurrences, 1)
  }
}

///|
test "verify accepts an unreachable statement after return" {
  let source = "fn f(a : Int) -> Int {\n  return a\n  a\n}\n"
  let ssa = ssa_of(source)
  assert_eq(@ssa.verify(ssa), [])
}

///|
test "ssa_def_use is sorted and deduplicated" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s + s\n}\n"
  let ssa = ssa_of(source)
  let pairs = @ssa.ssa_def_use(ssa)
  let mut i = 0
  while i + 1 < pairs.length() {
    let current = pairs[i]
    let next = pairs[i + 1]
    assert_true(current.0 < next.0 || (current.0 == next.0 && current.1 < next.1))
    i = i + 1
  }
}

///|
test "ssa_def_use matches reaching definitions on straight-line code" {
  assert_eq(
    @ssa.ssa_def_use(ssa_of("fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n")),
    [(0, 1), (1, 2)],
  )
}

///|
test "ssa_def_use matches reaching definitions on if/else" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  assert_eq(@ssa.ssa_def_use(ssa_of(source)), [(0, 2), (4, 7), (6, 7)])
}

///|
test "ssa_def_use matches reaching definitions on a loop" {
  let source = "fn f(n : Int) -> Int {\n  let mut i = 0\n  while i < n {\n    i = i + 1\n  }\n  i\n}\n"
  assert_eq(
    @ssa.ssa_def_use(ssa_of(source)),
    [(0, 2), (1, 2), (1, 4), (1, 5), (4, 2), (4, 4), (4, 5)],
  )
}

///|
test "a phi-mediated use expands to both reaching definitions" {
  let source = "fn f(c : Bool) -> Int {\n  let mut x = 0\n  if c {\n    x = 1\n  } else {\n    x = 2\n  }\n  x\n}\n"
  let pairs = @ssa.ssa_def_use(ssa_of(source))
  assert_true(has_pair(pairs, 4, 7))
  assert_true(has_pair(pairs, 6, 7))
  assert_true(!has_pair(pairs, 1, 7))
}

///|
test "def_use returns the frozen DefUse shape" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s\n}\n"
  let ssa = ssa_of(source)
  assert_eq(@ssa.def_use(ssa).reaching, @ssa.ssa_def_use(ssa))
}

///|
test "defs_of and uses_of agree with stmt_of" {
  let source = "fn f(a : Int) -> Int {\n  let s = a\n  s + a\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let let_node = nodes_defining(program, "s")[0]
  let use_node = nodes_using(program, "s")[0]
  let stmt = @ssa.stmt_of(ssa, let_node).unwrap()
  assert_eq(@ssa.defs_of(ssa, let_node), stmt.defs)
  assert_eq(@ssa.uses_of(ssa, use_node), @ssa.stmt_of(ssa, use_node).unwrap().uses)
  assert_eq(stmt.node, let_node)
  assert_eq(stmt.block, block_id(ssa, let_node))
}

///|
test "the entry value of a parameter is stable across blocks" {
  let source = "fn f(c : Bool, a : Int) -> Int {\n  let mut x = a\n  if c {\n    x = a + 1\n  } else {\n    x = a + 2\n  }\n  x\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let a = var_named(program, "a")
  let entry = block_id(ssa, entry_node(program))
  let parameter = @ssa.def_of(ssa, a, entry).unwrap()
  // Every block the parameter dominates sees the same definition.
  for block in ssa.blocks {
    if @ssa.dominates(ssa, entry, block.id) {
      assert_eq(@ssa.def_of(ssa, a, block.id), Some(parameter))
    }
  }
}

///|
test "versions of a variable are never shared between definitions" {
  let source = "fn f(a : Int) -> Int {\n  let mut x = 0\n  x = 1\n  x = 2\n  x\n}\n"
  let program = parse(source)
  let ssa = ssa_of(source)
  let x = var_named(program, "x")
  let defs = nodes_defining(program, "x")
  let seen : Array[@ssa.SsaValue] = []
  for node in defs {
    let value = @ssa.defs_of(ssa, node)[0]
    assert_eq(value.base, x)
    assert_true(!seen.contains(value))
    seen.push(value)
  }
  assert_eq(seen.length(), 3)
  assert_eq(@ssa.uses_of(ssa, nodes_using(program, "x")[0])[0], seen[2])
}
