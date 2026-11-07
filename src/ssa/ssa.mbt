// Static single assignment form over the frozen `@core` IR.
//
// The pass consumes a `@core.Program` plus its `@core.Cfg` and produces a
// `SsaProgram`: the CFG partitioned into basic blocks, the dominance tree, the
// dominance frontiers, the phi nodes a minimal SSA construction needs, and the
// rewritten (versioned) def/use sets of every statement.
//
// Layout of the construction, in order:
//
//   1. basic blocks      leaders are the function entries, the targets of any
//                        node with more than one successor, and any node with
//                        more than one predecessor (a join point);
//   2. dominators        Cooper–Harvey–Kennedy over reverse postorder, which
//                        never needs the full dominance sets;
//   3. frontiers         the standard `DF(x) = { y : x dominates a predecessor
//                        of y but does not strictly dominate y }`;
//   4. phi insertion     iterated dominance frontiers over the blocks that
//                        define each variable;
//   5. renaming          a dominator-tree walk with one version stack per
//                        `@core.VarId`, so a use sees exactly the values that
//                        can reach it and every join receives one phi operand
//                        per predecessor block.
//
// Value model: a `SsaValue` pairs the frozen `@core.VarId` (name + scope, so
// shadowing stays structural) with a version. Version `0` means "no definition
// on any path that reaches here" — a free name, a module-level value, or code
// the CFG could not connect to the function entry. An undefined value is a
// value, not an error: the analysis stays total, as the contract requires.
//
// Query surface:
//
//   `def_of(var, block)`         the value a variable resolves to on block entry;
//   `phi_sources(var, block)`    the phi's (predecessor block, value) operands;
//   `def_use()` / `ssa_def_use()` the SSA edges, in the pair form `@core.DefUse`
//                                already uses, with phi operands expanded back to
//                                the statement definitions that reach the use.
//
// `verify` re-checks the invariants the construction is supposed to establish:
// every use is dominated by exactly one definition (or receives it through a
// phi), every phi has one operand per predecessor, and every block's immediate
// dominator really dominates it. Tests assert it returns an empty array.

///|
/// One SSA value: a variable plus the definition version it names.
///
/// `version == 0` is the undefined value. Versions are allocated in dominator
/// tree order, so a larger version is a later definition, but only the identity
/// of the version is meaningful — never arithmetic on it.
pub(all) struct SsaValue {
  base : @core.VarId
  version : Int32
} derive(Debug, Eq, Hash)

///|
/// Where a value was defined: by a statement node or by a phi node.
pub(all) enum SsaDefSite {
  DefStmt(Int32)
  DefPhi(Int32)
} derive(Debug, Eq, Hash)

///|
/// A basic block: a maximal straight-line run of CFG nodes with one entry.
pub(all) struct SsaBlock {
  /// Block index; `blocks[id].id == id`.
  id : Int32
  /// CFG nodes in execution order.
  nodes : Array[Int32]
  /// Predecessor block ids, ascending.
  preds : Array[Int32]
  /// Successor block ids, ascending.
  succs : Array[Int32]
  /// Immediate dominator block id; a root dominates itself. `-1` only for a
  /// block the CFG never connected to any root.
  idom : Int32
  /// Dominance frontier block ids, ascending.
  frontier : Array[Int32]
} derive(Debug)

///|
/// A phi node: `base[version] = phi(sources)` at the entry of `block`.
///
/// `sources` holds one `(predecessor block, incoming value)` pair per
/// predecessor block, sorted by predecessor id. An incoming undefined value is
/// recorded with `version == 0`, which is what makes the join over a branch that
/// does not define the variable honest.
pub(all) struct SsaPhi {
  /// Phi index; `phis[id].id == id`.
  id : Int32
  base : @core.VarId
  value : SsaValue
  block : Int32
  sources : Array[(Int32, SsaValue)]
} derive(Debug)

///|
/// A statement with its variables rewritten to SSA values, in source order of
/// the statement's own `uses` / `defs` arrays. A use is resolved before this
/// node's own definitions are applied, so `x = x + 1` reads the old version.
pub(all) struct SsaStmt {
  node : Int32
  block : Int32
  defs : Array[SsaValue]
  uses : Array[SsaValue]
} derive(Debug)

///|
/// The SSA form of one program.
pub(all) struct SsaProgram {
  blocks : Array[SsaBlock]
  phis : Array[SsaPhi]
  /// Statements ordered by node id.
  stmts : Array[SsaStmt]
  /// `(block, variable, value)` triples: the value that enters the block, after
  /// its phi nodes have been applied. Function parameters are additionally
  /// reported by `def_of` for the entry block (see its documentation).
  entries : Array[(Int32, @core.VarId, SsaValue)]
  /// The unique site that defines each value (version > 0).
  sites : Map[SsaValue, SsaDefSite]
  /// CFG node id -> block id, for every node the CFG covers.
  node_block : Map[Int32, Int32]
  /// Synthetic entry node ids, one per function.
  function_entries : Array[Int32]
}

///|
/// Builder state. All the collections are arrays or maps, so the struct itself
/// can be passed by value and every mutation is still visible to the caller.
/// The only scalar state is data that is never mutated after the phase that
/// fills it (`nblocks` is derived from `block_nodes`).
priv struct Ctx {
  by_id : Map[Int32, @core.SNode]
  block_nodes : Array[Array[Int32]]
  block_succs : Array[Array[Int32]]
  phis : Array[SsaPhi]
  phis_by_block : Map[Int32, Array[Int32]]
  stacks : Map[@core.VarId, Array[SsaValue]]
  counters : Map[@core.VarId, Int32]
  sites : Map[SsaValue, SsaDefSite]
  entries : Array[(Int32, @core.VarId, SsaValue)]
  stmts : Array[SsaStmt]
  base_vars : Array[@core.VarId]
}

///|
/// Build SSA form for `program` over `cfg`.
///
/// `cfg` is used as given: only its edges are read, so a CFG built from a
/// different program yields whatever that graph says rather than panicking.
/// Edges whose endpoints are not nodes of `program` are ignored, which keeps a
/// hand-built `@core.Cfg` from indexing outside the node tables.
pub fn build(program : @core.Program, cfg : @core.Cfg) -> SsaProgram {
  let by_id : Map[Int32, @core.SNode] = Map([])
  for node in program.nodes {
    if !by_id.contains(node.id) {
      by_id.set(node.id, node)
    }
  }
  let ids = sorted_unique_int(collect_ids(program))
  let slot_count = max_slot(program)
  let succ = empty_arrays(slot_count)
  let pred = empty_arrays(slot_count)
  for edge in cfg.edges {
    let from = edge.0
    let to = edge.1
    if from >= 0 &&
      to >= 0 &&
      from < slot_count &&
      to < slot_count &&
      by_id.contains(from) &&
      by_id.contains(to) {
      if !succ[from].contains(to) {
        succ[from].push(to)
      }
      if !pred[to].contains(from) {
        pred[to].push(from)
      }
    }
  }
  let mut i = 0
  while i < ids.length() {
    succ[ids[i]].sort_by(fn(a, b) { a.compare(b) })
    pred[ids[i]].sort_by(fn(a, b) { a.compare(b) })
    i = i + 1
  }
  let (block_nodes, node_block) = build_blocks(ids, succ, pred)
  let nblocks = block_nodes.length()
  let block_succs = empty_arrays(nblocks)
  let block_preds = empty_arrays(nblocks)
  for edge in cfg.edges {
    match (node_block.get(edge.0), node_block.get(edge.1)) {
      (Some(from), Some(to)) =>
        if from != to {
          if !block_succs[from].contains(to) {
            block_succs[from].push(to)
          }
          if !block_preds[to].contains(from) {
            block_preds[to].push(from)
          }
        }
      _ => ()
    }
  }
  let mut b = 0
  while b < nblocks {
    block_succs[b].sort_by(fn(x, y) { x.compare(y) })
    block_preds[b].sort_by(fn(x, y) { x.compare(y) })
    b = b + 1
  }
  let idom = compute_idom(nblocks, block_succs, block_preds)
  let frontier = compute_frontiers(nblocks, block_preds, idom)
  let base_vars : Array[@core.VarId] = []
  let def_blocks : Array[Array[Int32]] = []
  for id in ids {
    let node = match by_id.get(id) {
      Some(node) => node
      None => continue
    }
    let block = match node_block.get(id) {
      Some(block) => block
      None => continue
    }
    for d in node.defs {
      let pos = index_of_var(base_vars, d)
      if pos == -1 {
        base_vars.push(d)
        def_blocks.push([block])
      } else if !def_blocks[pos].contains(block) {
        def_blocks[pos].push(block)
      }
    }
  }
  let phis : Array[SsaPhi] = []
  let phis_by_block : Map[Int32, Array[Int32]] = Map([])
  insert_phis(base_vars, def_blocks, frontier, phis, phis_by_block)
  let dom_children : Map[Int32, Array[Int32]] = Map([])
  b = 0
  while b < nblocks {
    let parent = idom[b]
    if parent != -1 && parent != b {
      match dom_children.get(parent) {
        Some(list) => list.push(b)
        None => dom_children.set(parent, [b])
      }
    }
    b = b + 1
  }
  let function_entries : Array[Int32] = []
  for f in program.functions {
    if by_id.contains(f.entry) && !function_entries.contains(f.entry) {
      function_entries.push(f.entry)
    }
  }
  let ctx : Ctx = {
    by_id,
    block_nodes,
    block_succs,
    phis,
    phis_by_block,
    stacks: Map([]),
    counters: Map([]),
    sites: Map([]),
    entries: [],
    stmts: [],
    base_vars,
  }
  // Roots first, then any block the dominator computation never reached (only
  // possible for a graph with a cycle and no entry). Both loops are needed so
  // renaming stays total on a malformed CFG.
  b = 0
  while b < nblocks {
    if idom[b] == b {
      rename(ctx, b, dom_children)
    }
    b = b + 1
  }
  b = 0
  while b < nblocks {
    if idom[b] == -1 {
      rename(ctx, b, dom_children)
    }
    b = b + 1
  }
  // Phi operands are appended while the predecessor block is finished, which is
  // not predecessor order, so sort them here. Same for the statement list: the
  // dominator walk visits blocks, not nodes.
  let mut p = 0
  while p < ctx.phis.length() {
    ctx.phis[p].sources.sort_by(fn(x, y) { x.0.compare(y.0) })
    p = p + 1
  }
  let stmts = ctx.stmts.copy()
  stmts.sort_by(fn(x, y) { x.node.compare(y.node) })
  let blocks : Array[SsaBlock] = []
  b = 0
  while b < nblocks {
    blocks.push(SsaBlock::{
      id: b,
      nodes: block_nodes[b],
      preds: block_preds[b],
      succs: block_succs[b],
      idom: idom[b],
      frontier: frontier[b],
    })
    b = b + 1
  }
  SsaProgram::{
    blocks,
    phis: ctx.phis,
    stmts,
    entries: ctx.entries,
    sites: ctx.sites,
    node_block,
    function_entries,
  }
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

///|
/// The CFG node -> block lookup for one node.
pub fn block_of(ssa : SsaProgram, node : Int32) -> Int32? {
  ssa.node_block.get(node)
}

///|
/// The rewritten def/use sets of one statement node.
pub fn stmt_of(ssa : SsaProgram, node : Int32) -> SsaStmt? {
  let mut i = 0
  while i < ssa.stmts.length() {
    if ssa.stmts[i].node == node {
      return Some(ssa.stmts[i])
    }
    i = i + 1
  }
  None
}

///|
/// The SSA values a statement defines, in the node's own `defs` order.
pub fn defs_of(ssa : SsaProgram, node : Int32) -> Array[SsaValue] {
  match stmt_of(ssa, node) {
    Some(stmt) => stmt.defs
    None => []
  }
}

///|
/// The SSA values a statement uses, in the node's own `uses` order.
pub fn uses_of(ssa : SsaProgram, node : Int32) -> Array[SsaValue] {
  match stmt_of(ssa, node) {
    Some(stmt) => stmt.uses
    None => []
  }
}

///|
/// The value `var` resolves to when entering `block` (after that block's phi
/// nodes have been applied).
///
/// Function parameters are bound on entry, so for the block that starts a
/// function the parameter definitions of the synthetic entry node are reported
/// here as well; every other definition becomes visible only after the
/// statement that performs it.
pub fn def_of(ssa : SsaProgram, var_id : @core.VarId, block : Int32) -> SsaValue? {
  let mut i = 0
  while i < ssa.entries.length() {
    let entry = ssa.entries[i]
    if entry.0 == block && entry.1 == var_id {
      return Some(entry.2)
    }
    i = i + 1
  }
  if block >= 0 && block < ssa.blocks.length() {
    let members = ssa.blocks[block].nodes
    if members.length() > 0 && ssa.function_entries.contains(members[0]) {
      match stmt_of(ssa, members[0]) {
        Some(stmt) =>
          for d in stmt.defs {
            if d.base == var_id {
              return Some(d)
            }
          }
        None => ()
      }
    }
  }
  None
}

///|
/// The phi node for `var` at `block`, if one was placed.
pub fn phi_at(ssa : SsaProgram, var_id : @core.VarId, block : Int32) -> SsaPhi? {
  let mut i = 0
  while i < ssa.phis.length() {
    let phi = ssa.phis[i]
    if phi.block == block && phi.base == var_id {
      return Some(phi)
    }
    i = i + 1
  }
  None
}

///|
/// The `(predecessor block, incoming value)` operands of the phi for `var` at
/// `block`, ascending by predecessor block. Empty when no phi was placed.
pub fn phi_sources(
  ssa : SsaProgram,
  var_id : @core.VarId,
  block : Int32,
) -> Array[(Int32, SsaValue)] {
  let out : Array[(Int32, SsaValue)] = []
  let mut i = 0
  while i < ssa.phis.length() {
    let phi = ssa.phis[i]
    if phi.block == block && phi.base == var_id {
      for source in phi.sources {
        out.push(source)
      }
    }
    i = i + 1
  }
  out
}

///|
/// The definition site of a value. `None` for the undefined value (version 0)
/// and for values that did not originate in this program.
pub fn def_site(ssa : SsaProgram, value : SsaValue) -> SsaDefSite? {
  ssa.sites.get(value)
}

///|
/// The statement node that defines `value`, if it is defined by a statement.
pub fn def_node(ssa : SsaProgram, value : SsaValue) -> Int32? {
  match ssa.sites.get(value) {
    Some(DefStmt(node)) => Some(node)
    _ => None
  }
}

///|
/// The block in which `value` is defined — the statement's block or the phi's
/// block.
pub fn def_block(ssa : SsaProgram, value : SsaValue) -> Int32? {
  match ssa.sites.get(value) {
    Some(DefStmt(node)) => ssa.node_block.get(node)
    Some(DefPhi(id)) =>
      if id >= 0 && id < ssa.phis.length() {
        Some(ssa.phis[id].block)
      } else {
        None
      }
    None => None
  }
}

///|
/// Whether block `a` dominates block `b` in the dominance tree.
pub fn dominates(ssa : SsaProgram, a : Int32, b : Int32) -> Bool {
  if a == b {
    return true
  }
  if a < 0 || b < 0 || a >= ssa.blocks.length() || b >= ssa.blocks.length() {
    return false
  }
  let mut cur = b
  let mut steps = 0
  while steps <= ssa.blocks.length() {
    let parent = ssa.blocks[cur].idom
    if parent == -1 || parent == cur {
      return false
    }
    cur = parent
    if cur == a {
      return true
    }
    steps = steps + 1
  }
  false
}

///|
/// The SSA def-use edges as `(defining statement, using statement)` pairs,
/// sorted by definition then use and deduplicated.
///
/// A use fed by a phi is expanded to the statement definitions that reach it
/// through the phi's operands, recursively, so the result is the same
/// "definition reaches use" relation `@core.DefUse` records — not a set of
/// edges through synthetic nodes.
pub fn ssa_def_use(ssa : SsaProgram) -> Array[(Int32, Int32)] {
  let pairs : Array[(Int32, Int32)] = []
  let mut i = 0
  while i < ssa.stmts.length() {
    let stmt = ssa.stmts[i]
    for use_var in stmt.uses {
      let defs : Array[Int32] = []
      collect_def_nodes(ssa, use_var, defs, Set([]))
      for d in defs {
        let pair = (d, stmt.node)
        if !pairs.contains(pair) {
          pairs.push(pair)
        }
      }
    }
    i = i + 1
  }
  pairs.sort_by(fn(a, b) {
    if a.0 != b.0 {
      a.0.compare(b.0)
    } else {
      a.1.compare(b.1)
    }
  })
  pairs
}

///|
/// The same relation as `ssa_def_use`, in the frozen `@core.DefUse` shape so a
/// downstream pass that already consumes reaching definitions can be fed SSA
/// edges without an adapter.
pub fn def_use(ssa : SsaProgram) -> @core.DefUse {
  @core.DefUse::{ reaching: ssa_def_use(ssa), }
}

///|
/// Re-check the SSA invariants and return a description of every violation
/// found. An empty array means the construction is sound for this program:
///
///   * every block except a root has an immediate dominator that dominates it;
///   * every phi has exactly one operand per predecessor block, and each
///     operand is defined in a block that dominates that predecessor;
///   * every versioned use resolves to exactly one definition site, in a block
///     that dominates the use (earlier in the same block when the definition is
///     a statement, which is the local form of the same property).
pub fn verify(ssa : SsaProgram) -> Array[String] {
  let errors : Array[String] = []
  let mut b = 0
  while b < ssa.blocks.length() {
    let block = ssa.blocks[b]
    if block.idom == -1 {
      errors.push("block \{block.id}: no immediate dominator")
    } else if block.idom != block.id && !dominates(ssa, block.idom, block.id) {
      errors.push("block \{block.id}: idom \{block.idom} does not dominate it")
    }
    b = b + 1
  }
  let mut p = 0
  while p < ssa.phis.length() {
    let phi = ssa.phis[p]
    let preds = ssa.blocks[phi.block].preds
    if phi.sources.length() != preds.length() {
      errors.push(
        "phi \{phi.id} (\{phi.base.name}#\{phi.value.version}): \{phi.sources.length()} operands for \{preds.length()} predecessors",
      )
    }
    for source in phi.sources {
      if !preds.contains(source.0) {
        errors.push(
          "phi \{phi.id} (\{phi.base.name}): operand from block \{source.0}, which is not a predecessor",
        )
      }
      if source.1.version > 0 {
        match def_block(ssa, source.1) {
          Some(def_block) =>
            if !dominates(ssa, def_block, source.0) {
              errors.push(
                "phi \{phi.id} (\{phi.base.name}): operand \{source.1.version} defined in block \{def_block} does not dominate predecessor \{source.0}",
              )
            }
          None =>
            errors.push(
              "phi \{phi.id} (\{phi.base.name}): operand value has no definition site",
            )
        }
      }
    }
    p = p + 1
  }
  let mut s = 0
  while s < ssa.stmts.length() {
    let stmt = ssa.stmts[s]
    for use_var in stmt.uses {
      if use_var.version == 0 {
        continue
      }
      match ssa.sites.get(use_var) {
        None =>
          errors.push(
            "use of \{use_var.base.name}#\{use_var.version} at node \{stmt.node} has no definition site",
          )
        Some(site) => {
          match def_block(ssa, use_var) {
            Some(def_block) =>
              if !dominates(ssa, def_block, stmt.block) {
                errors.push(
                  "use of \{use_var.base.name}#\{use_var.version} at node \{stmt.node}: def block \{def_block} does not dominate use block \{stmt.block}",
                )
              }
            None =>
              errors.push(
                "use of \{use_var.base.name}#\{use_var.version} at node \{stmt.node}: unknown def block",
              )
          }
          match site {
            DefStmt(def_node) =>
              if def_block(ssa, use_var) == Some(stmt.block) &&
                !node_before(ssa, stmt.block, def_node, stmt.node) {
                errors.push(
                  "use of \{use_var.base.name}#\{use_var.version} at node \{stmt.node}: defining statement \{def_node} does not precede it in block \{stmt.block}",
                )
              }
            DefPhi(_) => ()
          }
        }
      }
    }
    s = s + 1
  }
  errors
}

// ---------------------------------------------------------------------------
// Basic blocks
// ---------------------------------------------------------------------------

///|
fn collect_ids(program : @core.Program) -> Array[Int32] {
  let ids : Array[Int32] = []
  for node in program.nodes {
    ids.push(node.id)
  }
  ids
}

///|
fn max_slot(program : @core.Program) -> Int32 {
  let mut slot = 1
  for node in program.nodes {
    if node.id + 1 > slot {
      slot = node.id + 1
    }
  }
  slot
}

///|
fn empty_arrays(n : Int32) -> Array[Array[Int32]] {
  let out : Array[Array[Int32]] = []
  let mut i = 0
  while i < n {
    out.push([])
    i = i + 1
  }
  out
}

///|
fn sorted_unique_int(items : Array[Int32]) -> Array[Int32] {
  let copy = items.copy()
  copy.sort_by(fn(a, b) { a.compare(b) })
  let out : Array[Int32] = []
  let mut i = 0
  while i < copy.length() {
    if out.length() == 0 || out[out.length() - 1] != copy[i] {
      out.push(copy[i])
    }
    i = i + 1
  }
  out
}

///|
fn index_of_var(items : Array[@core.VarId], needle : @core.VarId) -> Int32 {
  let mut i = 0
  while i < items.length() {
    if items[i] == needle {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// Partition the CFG nodes into basic blocks.
///
/// Leaders are the function entries and any node that is the target of a node
/// with more than one successor, plus every node with more than one predecessor
/// (a join). A block then extends along the unique successor while that
/// successor is not itself a leader. Splitting at joins as well as at branch
/// targets is what makes every block single-entry, which the phi placement
/// relies on.
fn build_blocks(
  ids : Array[Int32],
  succ : Array[Array[Int32]],
  pred : Array[Array[Int32]],
) -> (Array[Array[Int32]], Map[Int32, Int32]) {
  let leader : Set[Int32] = Set([])
  let mut i = 0
  while i < ids.length() {
    if pred[ids[i]].length() != 1 {
      leader.add(ids[i])
    }
    i = i + 1
  }
  i = 0
  while i < ids.length() {
    if succ[ids[i]].length() != 1 {
      for next in succ[ids[i]] {
        leader.add(next)
      }
    }
    i = i + 1
  }
  let block_nodes : Array[Array[Int32]] = []
  let node_block : Map[Int32, Int32] = Map([])
  i = 0
  while i < ids.length() {
    let id = ids[i]
    if leader.contains(id) && !node_block.contains(id) {
      let members : Array[Int32] = []
      let block_id = block_nodes.length()
      let mut cur = id
      while true {
        members.push(cur)
        node_block.set(cur, block_id)
        if succ[cur].length() != 1 {
          break
        }
        let next = succ[cur][0]
        if leader.contains(next) || node_block.contains(next) {
          break
        }
        cur = next
      }
      block_nodes.push(members)
    }
    i = i + 1
  }
  (block_nodes, node_block)
}

// ---------------------------------------------------------------------------
// Dominators
// ---------------------------------------------------------------------------

///|
/// Immediate dominators by Cooper–Harvey–Kennedy: iterate `intersect` over the
/// processed predecessors in reverse postorder until nothing changes. A root
/// (no predecessors) is its own immediate dominator; `-1` means "not yet known",
/// which the fixed point resolves for every block the roots can reach.
fn compute_idom(
  nblocks : Int32,
  succs : Array[Array[Int32]],
  preds : Array[Array[Int32]],
) -> Array[Int32] {
  let visited : Array[Bool] = []
  let mut i = 0
  while i < nblocks {
    visited.push(false)
    i = i + 1
  }
  let post : Array[Int32] = []
  i = 0
  while i < nblocks {
    if preds[i].length() == 0 && !visited[i] {
      dfs_post(i, succs, visited, post)
    }
    i = i + 1
  }
  i = 0
  while i < nblocks {
    if !visited[i] {
      dfs_post(i, succs, visited, post)
    }
    i = i + 1
  }
  let rpo : Array[Int32] = []
  let mut k = post.length() - 1
  while k >= 0 {
    rpo.push(post[k])
    k = k - 1
  }
  let rpo_index : Array[Int32] = []
  i = 0
  while i < nblocks {
    rpo_index.push(-1)
    i = i + 1
  }
  i = 0
  while i < rpo.length() {
    rpo_index[rpo[i]] = i
    i = i + 1
  }
  let idom : Array[Int32] = []
  i = 0
  while i < nblocks {
    idom.push(-1)
    i = i + 1
  }
  i = 0
  while i < nblocks {
    if preds[i].length() == 0 {
      idom[i] = i
    }
    i = i + 1
  }
  let mut changed = true
  let mut rounds = 0
  let limit = nblocks * 4 + 8
  while changed && rounds <= limit {
    changed = false
    let mut pos = 0
    while pos < rpo.length() {
      let block = rpo[pos]
      if idom[block] != block {
        let mut new_idom = -1
        for pred in preds[block] {
          // A self-loop predecessor never dominates the block, and it is not a
          // usable starting point for `intersect` either.
          if pred != block && idom[pred] != -1 {
            if new_idom == -1 {
              new_idom = pred
            } else {
              new_idom = intersect_dom(pred, new_idom, idom, rpo_index)
            }
          }
        }
        if new_idom != -1 && idom[block] != new_idom {
          idom[block] = new_idom
          changed = true
        }
      }
      pos = pos + 1
    }
    rounds = rounds + 1
  }
  idom
}

///|
/// Postorder DFS with an explicit stack: the recursion depth of a deep CFG
/// would otherwise be unbounded, and a stack is also where the visited flag
/// belongs on a graph with back edges.
fn dfs_post(
  start : Int32,
  succs : Array[Array[Int32]],
  visited : Array[Bool],
  post : Array[Int32],
) -> Unit {
  let stack : Array[Int32] = [start]
  let cursor : Array[Int32] = [0]
  visited[start] = true
  while stack.length() > 0 {
    let top = stack[stack.length() - 1]
    let at = cursor[cursor.length() - 1]
    if at < succs[top].length() {
      cursor[cursor.length() - 1] = at + 1
      let next = succs[top][at]
      if !visited[next] {
        visited[next] = true
        stack.push(next)
        cursor.push(0)
      }
    } else {
      post.push(top)
      let _ = stack.pop()
      let _ = cursor.pop()
    }
  }
}

///|
/// Walk two dominator chains up to their common ancestor, using reverse
/// postorder numbers as the height metric.
fn intersect_dom(
  a0 : Int32,
  b0 : Int32,
  idom : Array[Int32],
  rpo_index : Array[Int32],
) -> Int32 {
  let mut a = a0
  let mut b = b0
  let mut steps = 0
  while a != b && steps < 4096 {
    while rpo_index[a] > rpo_index[b] {
      let next = idom[a]
      if next == a || next == -1 {
        return a
      }
      a = next
    }
    while rpo_index[b] > rpo_index[a] {
      let next = idom[b]
      if next == b || next == -1 {
        return b
      }
      b = next
    }
    steps = steps + 1
  }
  a
}

///|
/// `DF(x)`: the join points `y` such that `x` dominates a predecessor of `y`
/// but not `y` itself. For a block with two or more predecessors, walking each
/// predecessor's dominator chain up to `idom(y)` visits exactly those `x`.
fn compute_frontiers(
  nblocks : Int32,
  preds : Array[Array[Int32]],
  idom : Array[Int32],
) -> Array[Array[Int32]] {
  let frontier = empty_arrays(nblocks)
  let mut b = 0
  while b < nblocks {
    if preds[b].length() > 1 {
      let stop = idom[b]
      for pred in preds[b] {
        let mut runner = pred
        let mut steps = 0
        while runner != -1 && runner != stop && steps <= nblocks {
          if !frontier[runner].contains(b) {
            frontier[runner].push(b)
          }
          runner = idom[runner]
          steps = steps + 1
        }
      }
    }
    b = b + 1
  }
  b = 0
  while b < nblocks {
    frontier[b].sort_by(fn(x, y) { x.compare(y) })
    b = b + 1
  }
  frontier
}

// ---------------------------------------------------------------------------
// Phi insertion
// ---------------------------------------------------------------------------

///|
/// Minimal SSA phi placement: for every variable, walk the iterated dominance
/// frontier of its definition blocks. A phi is placed the first time a frontier
/// block is reached; the block is then itself treated as a definition site so
/// the iteration continues, which is what plants a phi on the loop header of a
/// loop-carried variable.
fn insert_phis(
  base_vars : Array[@core.VarId],
  def_blocks : Array[Array[Int32]],
  frontier : Array[Array[Int32]],
  phis : Array[SsaPhi],
  phis_by_block : Map[Int32, Array[Int32]],
) -> Unit {
  let mut v = 0
  while v < base_vars.length() {
    let var_ = base_vars[v]
    let work : Array[Int32] = def_blocks[v].copy()
    let placed : Array[Int32] = []
    let mut w = 0
    while w < work.length() {
      let block = work[w]
      w = w + 1
      for target in frontier[block] {
        if !placed.contains(target) {
          placed.push(target)
          let id = phis.length()
          phis.push(SsaPhi::{
            id,
            base: var_,
            value: SsaValue::{ base: var_, version: 0 },
            block: target,
            sources: [],
          })
          match phis_by_block.get(target) {
            Some(list) => list.push(id)
            None => phis_by_block.set(target, [id])
          }
          if !def_blocks[v].contains(target) && !work.contains(target) {
            work.push(target)
          }
        }
      }
    }
    v = v + 1
  }
}

// ---------------------------------------------------------------------------
// Renaming
// ---------------------------------------------------------------------------

///|
/// Rename every definition and use in the dominator subtree rooted at `block`.
///
/// The version stacks encode the dominance relation: a block sees exactly the
/// values its dominators pushed. Phi nodes are renamed before the block's
/// statements (they sit on the block boundary), and each successor's phi
/// operands are filled once this block is finished, when the end-of-block value
/// is known — that is also what makes a back edge carry the new version into the
/// loop header's phi.
fn rename(ctx : Ctx, block : Int32, dom_children : Map[Int32, Array[Int32]]) -> Unit {
  let pushed : Array[@core.VarId] = []
  match ctx.phis_by_block.get(block) {
    Some(indices) =>
      for index in indices {
        let phi = ctx.phis[index]
        let version = next_version(ctx, phi.base)
        let value = SsaValue::{ base: phi.base, version }
        ctx.phis[index] = SsaPhi::{
          id: phi.id,
          base: phi.base,
          value,
          block: phi.block,
          // Keep the operand array: successors append to this same array later.
          sources: phi.sources,
        }
        ctx.sites.set(value, DefPhi(phi.id))
        push_value(ctx, phi.base, value)
        ctx.entries.push((block, phi.base, value))
        pushed.push(phi.base)
      }
    None => ()
  }
  // Record the values that reach the block entry for variables the block does
  // not itself phi. This is what `def_of` answers with.
  for var_ in ctx.base_vars {
    if !contains_var(pushed, var_) {
      match top_value(ctx, var_) {
        Some(value) => ctx.entries.push((block, var_, value))
        None => ()
      }
    }
  }
  let members = ctx.block_nodes[block]
  for node_id in members {
    let node = match ctx.by_id.get(node_id) {
      Some(node) => node
      None => continue
    }
    // Uses are resolved before this statement's own definitions, so an
    // assignment reads the previous version of the variable it overwrites.
    let uses : Array[SsaValue] = []
    for use_var in node.uses {
      match top_value(ctx, use_var) {
        Some(value) => uses.push(value)
        None => uses.push(SsaValue::{ base: use_var, version: 0 })
      }
    }
    let defs : Array[SsaValue] = []
    for def in node.defs {
      let version = next_version(ctx, def)
      let value = SsaValue::{ base: def, version }
      ctx.sites.set(value, DefStmt(node_id))
      push_value(ctx, def, value)
      defs.push(value)
      pushed.push(def)
    }
    ctx.stmts.push(SsaStmt::{ node: node_id, block, defs, uses })
  }
  for successor in ctx.block_succs[block] {
    match ctx.phis_by_block.get(successor) {
      Some(indices) =>
        for index in indices {
          let phi = ctx.phis[index]
          let value = match top_value(ctx, phi.base) {
            Some(value) => value
            None => SsaValue::{ base: phi.base, version: 0 }
          }
          // One operand per predecessor *block*. The block is always a
          // predecessor of `successor`, so no membership test is needed.
          phi.sources.push((block, value))
        }
      None => ()
    }
  }
  match dom_children.get(block) {
    Some(children) =>
      for child in children {
        rename(ctx, child, dom_children)
      }
    None => ()
  }
  // Pop in reverse push order: a variable defined twice in the block stacked
  // two versions, and both have to disappear on the way out.
  let mut i = pushed.length() - 1
  while i >= 0 {
    match ctx.stacks.get(pushed[i]) {
      Some(stack) =>
        if stack.length() > 0 {
          let _ = stack.pop()
        }
      None => ()
    }
    i = i - 1
  }
}

///|
fn next_version(ctx : Ctx, var_ : @core.VarId) -> Int32 {
  let current = match ctx.counters.get(var_) {
    Some(value) => value
    None => 0
  }
  let next = current + 1
  ctx.counters.set(var_, next)
  next
}

///|
fn push_value(ctx : Ctx, var_ : @core.VarId, value : SsaValue) -> Unit {
  match ctx.stacks.get(var_) {
    Some(stack) => stack.push(value)
    None => ctx.stacks.set(var_, [value])
  }
}

///|
fn top_value(ctx : Ctx, var_ : @core.VarId) -> SsaValue? {
  match ctx.stacks.get(var_) {
    Some(stack) =>
      if stack.length() > 0 {
        Some(stack[stack.length() - 1])
      } else {
        None
      }
    None => None
  }
}

///|
fn contains_var(items : Array[@core.VarId], needle : @core.VarId) -> Bool {
  let mut i = 0
  while i < items.length() {
    if items[i] == needle {
      return true
    }
    i = i + 1
  }
  false
}

// ---------------------------------------------------------------------------
// Def-use expansion
// ---------------------------------------------------------------------------

///|
/// Resolve `value` to the statement nodes that actually define it. A statement
/// definition terminates the walk; a phi is followed through its operands, with
/// a visited set so a loop-carried phi cannot cycle. The undefined value
/// contributes nothing.
fn collect_def_nodes(
  ssa : SsaProgram,
  value : SsaValue,
  out : Array[Int32],
  visited : Set[Int32],
) -> Unit {
  if value.version == 0 {
    return
  }
  match ssa.sites.get(value) {
    Some(DefStmt(node)) =>
      if !out.contains(node) {
        out.push(node)
      }
    Some(DefPhi(id)) =>
      if !visited.contains(id) {
        visited.add(id)
        if id >= 0 && id < ssa.phis.length() {
          for source in ssa.phis[id].sources {
            collect_def_nodes(ssa, source.1, out, visited)
          }
        }
      }
    None => ()
  }
}

///|
fn node_before(ssa : SsaProgram, block : Int32, first : Int32, second : Int32) -> Bool {
  let members = ssa.blocks[block].nodes
  let mut pos_first = -1
  let mut pos_second = -1
  let mut i = 0
  while i < members.length() {
    if members[i] == first {
      pos_first = i
    }
    if members[i] == second {
      pos_second = i
    }
    i = i + 1
  }
  pos_first >= 0 && pos_second >= 0 && pos_first < pos_second
}
