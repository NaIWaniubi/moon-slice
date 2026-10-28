// Control-flow graph over the frozen @core IR.
//
// Node set: every `SNode` produced by the parser adapter, including the
// synthetic per-function entry (parameter definitions) and exit nodes.
//
// Region nodes are CFG nodes of their own, because they are the definition sites
// of a `match` case's pattern binders. Control flows *through* a region:
//
//     head -> region -> first statement of the body
//     last statement of the body -> join point (or the loop head, for a loop)
//
// Edge set, by construct:
//
//   sequence     stmt -> next stmt; last stmt -> function exit
//   if           head -> then-region -> first statement (same for else);
//                head -> next when a branch is absent
//                branch bodies fall through to `next`
//   while / for  head -> body-region -> first statement;
//                last body statement -> head (back edge); head -> next
//   break        -> the statement after the innermost enclosing loop
//   continue     -> the innermost enclosing loop head
//   return       -> the function exit node
//   match        head -> one region per case; case bodies fall through
//
// Deliberate limitations, all of which only ever *add* edges (never remove one
// that a real execution could take):
//
//   * No reachability pruning. A statement textually after `return`/`break`/
//     `continue` keeps its incoming edge, so it stays in the graph.
//   * `while`/`for` with an `else` block model the else block as the normal
//     termination path; the head does not also get a direct edge to `next`.
//   * A `break`/`continue` with no enclosing loop falls through to `next`
//     instead of being dropped, keeping the graph well formed.
//   * A `for` continue target is the loop head; the increment expressions are
//     evaluated there rather than at a separate node.
//   * An empty branch region gets a region -> next edge so the join point stays
//     reachable.

///|
/// Innermost enclosing loop, used to resolve `break` / `continue`.
priv struct LoopCtx {
  continue_to : Int32
  break_to : Int32
}

///|
priv struct Builder {
  nodes : Array[@core.SNode]
  edges : Array[(Int32, Int32)]
  seen : Set[(Int32, Int32)]
  exit_slot : Array[Int32]
}

///|
/// Build the CFG for every function in `program`.
///
/// `Cfg.entry` / `Cfg.exit` name the boundary nodes of the *first* function, so
/// that a single-function file needs no extra lookup. Multi-function programs
/// yield one connected component per function; use `Program.functions` for the
/// per-function boundaries.
pub fn build(program : @core.Program) -> @core.Cfg {
  let builder : Builder = {
    nodes: program.nodes,
    edges: [],
    seen: Set([]),
    exit_slot: [0],
  }
  program.functions.each(fn(function) {
    builder.exit_slot[0] = function.exit
    let top : Array[Int32] = []
    program.nodes.each(fn(node) {
      let in_function = node.id > function.entry && node.id < function.exit
      match node.parent {
        None => if in_function { top.push(node.id) }
        Some(_) => ()
      }
    })
    if top.length() == 0 {
      add_edge(builder, function.entry, function.exit)
    } else {
      add_edge(builder, function.entry, top[0])
      walk_list(builder, top, function.exit, [])
    }
  })
  let entry = if program.functions.length() > 0 {
    program.functions[0].entry
  } else {
    0
  }
  let exit = if program.functions.length() > 0 {
    program.functions[0].exit
  } else {
    0
  }
  @core.Cfg::{ edges: builder.edges, entry, exit, }
}

///|
fn walk_list(
  builder : Builder,
  statements : Array[Int32],
  after : Int32,
  loops : Array[LoopCtx],
) -> Unit {
  let mut i = 0
  while i < statements.length() {
    let node = builder.nodes[statements[i]]
    let next = if i + 1 < statements.length() {
      statements[i + 1]
    } else {
      after
    }
    dispatch(builder, node, next, loops)
    i = i + 1
  }
}

///|
fn dispatch(
  builder : Builder,
  node : @core.SNode,
  next : Int32,
  loops : Array[LoopCtx],
) -> Unit {
  match node.kind {
    Return => add_edge(builder, node.id, builder.exit_slot[0])
    Break =>
      match loops.last() {
        Some(loop_) => add_edge(builder, node.id, loop_.break_to)
        None => add_edge(builder, node.id, next)
      }
    Continue =>
      match loops.last() {
        Some(loop_) => add_edge(builder, node.id, loop_.continue_to)
        None => add_edge(builder, node.id, next)
      }
    If => {
      let regions = node.children
      if regions.length() == 0 {
        add_edge(builder, node.id, next)
      } else {
        walk_branch(builder, node.id, regions[0], next, loops)
        if regions.length() > 1 {
          walk_branch(builder, node.id, regions[1], next, loops)
        } else {
          add_edge(builder, node.id, next)
        }
      }
    }
    While | For => {
      let regions = node.children
      if regions.length() == 0 {
        add_edge(builder, node.id, next)
      } else {
        walk_loop_body(builder, node, regions[0], next, loops)
        if regions.length() > 1 {
          walk_branch(builder, node.id, regions[1], next, loops)
        } else {
          add_edge(builder, node.id, next)
        }
      }
    }
    Match => {
      let regions = node.children
      if regions.length() == 0 {
        add_edge(builder, node.id, next)
      } else {
        regions.each(fn(region) {
          walk_branch(builder, node.id, region, next, loops)
        })
      }
    }
    _ => add_edge(builder, node.id, next)
  }
}

///|
/// Enter one branch region. The region is itself a CFG node because it is the
/// definition site of that body's pattern binders (`match` cases), so control
/// passes through it rather than skipping it:
///
///     head -> region -> first statement
///
/// The region's statements fall through to `next`, and an empty region keeps the
/// edge so control still reaches the join point.
fn walk_branch(
  builder : Builder,
  head : Int32,
  region : Int32,
  next : Int32,
  loops : Array[LoopCtx],
) -> Unit {
  add_edge(builder, head, region)
  let statements = builder.nodes[region].children
  if statements.length() == 0 {
    add_edge(builder, region, next)
  } else {
    add_edge(builder, region, statements[0])
    walk_list(builder, statements, next, loops)
  }
}

///|
/// Enter a loop body region. Same shape as `walk_branch`, but the body falls
/// back to the loop head instead of forward to the join point, which is the
/// back edge.
///
/// A C-style `for` carries its update expressions in a trailing step block (an
/// `Expr` child of the body region emitted by the adapter). `continue` must
/// resume at that block, not at the head, or the increment would be skipped.
fn walk_loop_body(
  builder : Builder,
  head : @core.SNode,
  region : Int32,
  next : Int32,
  loops : Array[LoopCtx],
) -> Unit {
  add_edge(builder, head.id, region)
  let statements = builder.nodes[region].children
  if statements.length() == 0 {
    add_edge(builder, region, head.id)
    return
  }
  add_edge(builder, region, statements[0])
  let inner = copy_loops(loops)
  inner.push({ continue_to: loop_continue_target(builder, head, statements), break_to: next, })
  walk_list(builder, statements, head.id, inner)
}

///|
/// Where a `continue` inside `head` resumes. The adapter appends the C-style
/// `for` update block as the last child of the body region; its first statement
/// is the resume point. Everything else resumes at the loop head.
fn loop_continue_target(
  builder : Builder,
  head : @core.SNode,
  statements : Array[Int32],
) -> Int32 {
  match head.kind {
    @core.SNodeKind::For =>
      match step_block(builder, head, statements) {
        Some(step) => step
        None => head.id
      }
    _ => head.id
  }
}

///|
/// The adapter's update block: a trailing `Expr` region on the loop's own line
/// whose children are the update assignments. The adapter never emits a bare
/// `Expr` statement block with children for anything else inside a loop body,
/// so this is unambiguous.
fn step_block(
  builder : Builder,
  head : @core.SNode,
  statements : Array[Int32],
) -> Int32? {
  if statements.length() == 0 {
    return None
  }
  let last = builder.nodes[statements[statements.length() - 1]]
  if last.kind == @core.SNodeKind::Expr &&
    last.loc == head.loc &&
    last.children.length() > 0 {
    Some(last.children[0])
  } else {
    None
  }
}

///|
fn copy_loops(loops : Array[LoopCtx]) -> Array[LoopCtx] {
  let out : Array[LoopCtx] = []
  loops.each(fn(item) { out.push(item) })
  out
}

///|
fn add_edge(builder : Builder, from : Int32, to : Int32) -> Unit {
  if from < 0 || to < 0 {
    return
  }
  let key = (from, to)
  if !builder.seen.contains(key) {
    builder.seen.add(key)
    builder.edges.push(key)
  }
}
