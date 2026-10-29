// Data-flow analysis: which definition nodes reach which use nodes.
//
// The analysis is a classic forward "reaching definitions" pass over the CFG,
// restricted to the modeled subset and solved with a work-list to a fixed point.
//
// Facts are per `VarId` (name + scope), so shadowing is structural: an inner
// `let x` has a distinct `VarId` from an outer `x`, and definitions of one never
// reach uses of the other.
//
// Universe of definitions: a node is a definition site for var `v` iff `v` occurs
// in `node.defs`. The synthetic function-entry node carries parameter bindings,
// so parameters have a definition site and uses inside the body resolve to it.
//
// Conservative choices:
//
//   * A field or element write (`r.f = e`, `a[i] = e`) *defines* its base
//     variable, because the write changes state reachable through that name.
//     This inflates `defs` but cannot hide a real dependence.
//   * A use that resolves to no definition site (free name, module-level value)
//     produces no edge. Reaching-definition sets are still tracked for it, so no
//     spurious edge appears elsewhere.
//   * `Reaching` is emitted as (definition node, use node) pairs sorted by
//     definition node then use node, deduplicated. It is a set of pairs, not a
//     path enumeration.

///|
/// Per-node transfer facts.
priv struct Facts {
  /// Definition sites keyed by variable.
  defs : Array[(Int32, @core.VarId)]
  /// Uses with their variable.
  uses : Array[(Int32, @core.VarId)]
}

///|
/// Compute reaching definitions for `program` over `cfg`.
///
/// `cfg` is used as given; callers that pass a CFG built from a different
/// program get whatever that CFG says, so this function only reads `cfg.edges`.
pub fn analyze(program : @core.Program, cfg : @core.Cfg) -> @core.DefUse {
  let facts = collect_facts(program)
  let node_count = program.nodes.length()
  if node_count == 0 {
    let none : Array[(Int32, Int32)] = []
    return @core.DefUse::{ reaching: none, }
  }
  // Per-node GEN/USE indexes keep the fixed point local: a transfer step only
  // touches the definitions of the node it visits, not every definition in the
  // program.
  // Slot arrays are indexed by node id. A hand-built Program may use sparse
  // ids, so the table is sized by the largest id rather than by node count;
  // `node_count` would silently mis-index (`nodes[id]` out of range) the first
  // time an id gap appears.
  let mut slot_count = node_count
  for node in program.nodes {
    if node.id + 1 > slot_count {
      slot_count = node.id + 1
    }
  }
  let defs_at : Array[Array[@core.VarId]] = []
  let uses_at : Array[Array[@core.VarId]] = []
  let mut i = 0
  while i < slot_count {
    defs_at.push([])
    uses_at.push([])
    i = i + 1
  }
  facts.defs.each(fn(pair) { defs_at[pair.0].push(pair.1) })
  facts.uses.each(fn(pair) { uses_at[pair.0].push(pair.1) })
  let in_state : Array[Array[(Int32, @core.VarId)]] = []
  let out_state : Array[Array[(Int32, @core.VarId)]] = []
  i = 0
  while i < slot_count {
    in_state.push([])
    out_state.push([])
    i = i + 1
  }
  let preds = predecessors(cfg, slot_count)
  let succs = successors(cfg, slot_count)
  let work : Array[Int32] = []
  let queued : Set[Int32] = Set([])
  // Seed every node, not only the roots. A root with an empty out-state (for
  // example a parameterless entry) never changes, so a work-list that only
  // enqueues successors on change would never visit the rest of a straight-line
  // CFG. Processing every node once is cheap and makes convergence independent
  // of which node happens to carry the first definition.
  for node in program.nodes {
    if !queued.contains(node.id) {
      queued.add(node.id)
      work.push(node.id)
    }
  }
  // The lattice is finite (each definition/use pair is either present or not)
  // and transfer is monotone, so the loop terminates on its own. No round cap.
  //
  // Allocation note: `join_predecessor_out` and `transfer` each build one fresh
  // array per visit, and an unchanged visit throws its result away. The
  // comparison is therefore done before the array is retained: a visit that
  // changes nothing only pays for building the candidate, not for keeping it.
  // Sharing the arrays between nodes is deliberately not attempted, because the
  // state is mutated in place by `transfer` and a shared buffer would let one
  // node's definition leak into another's set.
  while work.length() > 0 {
    let current = work.pop().unwrap()
    queued.remove(current)
    let joined = join_predecessor_out(preds[current], out_state)
    if !same_set(in_state[current], joined) {
      in_state[current] = joined
    }
    let next_out = transfer(current, defs_at[current], in_state[current])
    if !same_set(out_state[current], next_out) {
      out_state[current] = next_out
      for succ in succs[current] {
        if !queued.contains(succ) {
          queued.add(succ)
          work.push(succ)
        }
      }
    }
  }
  // A use is reached by every definition in its in-state for the same variable.
  let pairs : Set[(Int32, Int32)] = Set([])
  for node in program.nodes {
    let state = in_state[node.id]
    uses_at[node.id].each(fn(use_var) {
      state.each(fn(def_pair) {
        if def_pair.1 == use_var {
          pairs.add((def_pair.0, node.id))
        }
      })
    })
  }
  let reaching = pairs.to_array()
  reaching.sort_by(fn(a, b) {
    if a.0 != b.0 {
      a.0.compare(b.0)
    } else {
      a.1.compare(b.1)
    }
  })
  @core.DefUse::{ reaching, }
}

///|
fn collect_facts(program : @core.Program) -> Facts {
  let defs : Array[(Int32, @core.VarId)] = []
  let uses : Array[(Int32, @core.VarId)] = []
  program.nodes.each(fn(node) {
    node.defs.each(fn(var_) { defs.push((node.id, var_)) })
    node.uses.each(fn(var_) { uses.push((node.id, var_)) })
  })
  { defs, uses, }
}

///|
/// GEN/KILL as a set operation: drop pairs whose var is redefined by `node`,
/// then add this node's own definitions.
fn transfer(
  node : Int32,
  defined : Array[@core.VarId],
  incoming : Array[(Int32, @core.VarId)],
) -> Array[(Int32, @core.VarId)] {
  let out : Array[(Int32, @core.VarId)] = []
  incoming.each(fn(pair) {
    if !array_has_var(defined, pair.1) {
      push_unique_pair(out, pair)
    }
  })
  defined.each(fn(var_) { push_unique_pair(out, (node, var_)) })
  out
}

///|
fn join_predecessor_out(
  preds : Array[Int32],
  out_state : Array[Array[(Int32, @core.VarId)]],
) -> Array[(Int32, @core.VarId)] {
  let joined : Array[(Int32, @core.VarId)] = []
  preds.each(fn(pred) {
    out_state[pred].each(fn(pair) { push_unique_pair(joined, pair) })
  })
  joined
}

///|
fn predecessors(cfg : @core.Cfg, node_count : Int32) -> Array[Array[Int32]] {
  let preds : Array[Array[Int32]] = []
  let mut i = 0
  while i < node_count {
    preds.push([])
    i = i + 1
  }
  cfg.edges.each(fn(edge) {
    if edge.0 >= 0 && edge.0 < node_count && edge.1 >= 0 && edge.1 < node_count {
      if !contains_int(preds[edge.1], edge.0) {
        preds[edge.1].push(edge.0)
      }
    }
  })
  preds
}

///|
/// Successors of every node, restricted to ids that exist in the program. A CFG
/// carrying an endpoint outside `0 ..< node_count` is ignored rather than
/// allowed to index out of bounds later.
fn successors(
  cfg : @core.Cfg,
  node_count : Int32,
) -> Array[Array[Int32]] {
  let out : Array[Array[Int32]] = []
  let mut i = 0
  while i < node_count {
    out.push([])
    i = i + 1
  }
  let seen : Set[(Int32, Int32)] = Set([])
  cfg.edges.each(fn(edge) {
    if edge.0 >= 0 &&
      edge.0 < node_count &&
      edge.1 >= 0 &&
      edge.1 < node_count &&
      !seen.contains(edge) {
      seen.add(edge)
      out[edge.0].push(edge.1)
    }
  })
  out
}

///|
fn contains_int(items : Array[Int32], needle : Int32) -> Bool {
  let mut i = 0
  let mut found = false
  while i < items.length() {
    if items[i] == needle {
      found = true
    }
    i = i + 1
  }
  found
}

///|
fn array_has_var(items : Array[@core.VarId], needle : @core.VarId) -> Bool {
  let mut i = 0
  let mut found = false
  while i < items.length() {
    if items[i] == needle {
      found = true
    }
    i = i + 1
  }
  found
}

///|
fn push_unique_pair(
  items : Array[(Int32, @core.VarId)],
  pair : (Int32, @core.VarId),
) -> Unit {
  let mut i = 0
  let mut found = false
  while i < items.length() {
    let existing = items[i]
    if existing.0 == pair.0 && existing.1 == pair.1 {
      found = true
    }
    i = i + 1
  }
  if !found {
    items.push(pair)
  }
}

///|
fn same_set(
  a : Array[(Int32, @core.VarId)],
  b : Array[(Int32, @core.VarId)],
) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  let mut same = true
  while i < a.length() {
    if !contains_pair(b, a[i]) {
      same = false
    }
    i = i + 1
  }
  same
}

///|
fn contains_pair(
  items : Array[(Int32, @core.VarId)],
  needle : (Int32, @core.VarId),
) -> Bool {
  let mut i = 0
  let mut found = false
  while i < items.length() {
    let existing = items[i]
    if existing.0 == needle.0 && existing.1 == needle.1 {
      found = true
    }
    i = i + 1
  }
  found
}
