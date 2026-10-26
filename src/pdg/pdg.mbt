// Program dependence graph: data edges from reaching definitions, control
// edges from the structured CDG.

///|
fn kind_rank(kind : @core.EdgeKind) -> Int32 {
  match kind {
    @core.Data => 0
    @core.Control => 1
  }
}

///|
fn cmp_edge(a : @core.PdgEdge, b : @core.PdgEdge) -> Int32 {
  if a.from != b.from {
    return if a.from < b.from { -1 } else { 1 }
  }
  if a.to != b.to {
    return if a.to < b.to { -1 } else { 1 }
  }
  let ra = kind_rank(a.kind)
  let rb = kind_rank(b.kind)
  if ra != rb {
    return if ra < rb { -1 } else { 1 }
  }
  0
}

///|
fn edge_key(edge : @core.PdgEdge) -> (Int32, Int32, Int32) {
  (edge.from, edge.to, kind_rank(edge.kind))
}

///|
/// Builds the program dependence graph.
///
/// Every pair `(def, use)` in `defuse.reaching` becomes a `Data` edge from the
/// defining statement to the using statement. Every pair `(controller,
/// controlled)` in `cdg.edges` becomes a `Control` edge. Self-edges are dropped:
/// a statement that reaches itself adds no information to a slice and would only
/// complicate traversal. Duplicates are removed and the edge list is sorted by
/// `(from, to, kind)` with `Data` before `Control` at equal endpoints, so the
/// same inputs always produce byte-identical output.
///
/// Both inputs are treated as authoritative but not as validated: ids are
/// copied through unchanged. `DefUse` and `Cdg` are expected to come from the
/// same `Program`, and callers that mix programs get a graph over the union of
/// the ids they passed in.
pub fn build(defuse : @core.DefUse, cdg : @core.Cdg) -> @core.Pdg {
  let collected : Array[@core.PdgEdge] = []
  for (def_id, use_id) in defuse.reaching {
    if def_id != use_id {
      collected.push({ from: def_id, to: use_id, kind: @core.Data })
    }
  }
  for (controller, controlled) in cdg.edges {
    if controller != controlled {
      collected.push({ from: controller, to: controlled, kind: @core.Control })
    }
  }
  let seen : Set[(Int32, Int32, Int32)] = Set([])
  let edges : Array[@core.PdgEdge] = []
  for edge in collected {
    let key = edge_key(edge)
    if !seen.contains(key) {
      seen.add(key)
      edges.push(edge)
    }
  }
  edges.sort_by(cmp_edge)
  { edges, }
}
