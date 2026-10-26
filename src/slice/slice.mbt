// Program slicing over a `@core.Pdg`.
//
// `backward` walks incoming edges (what may have produced this value),
// `forward` walks outgoing edges (what may this value affect). Both return the
// criterion node plus every node reachable from it, sorted ascending, with the
// unique sorted start lines of those nodes when a `Program` is supplied.

///|
/// Builds the adjacency map used by the graph walk.
///
/// With `forward = true` the map is `from -> [to]`; otherwise it is inverted to
/// `to -> [from]`. Duplicate edges collapse naturally because the walk keeps a
/// visited set.
fn adjacency(pdg : @core.Pdg, forward : Bool) -> Map[Int32, Array[Int32]] {
  let adj : Map[Int32, Array[Int32]] = Map([])
  for edge in pdg.edges {
    let source = if forward { edge.from } else { edge.to }
    let target = if forward { edge.to } else { edge.from }
    match adj.get(source) {
      None => adj.set(source, [target])
      Some(next) => next.push(target)
    }
  }
  adj
}

///|
/// Breadth-first reachability from `target`. The criterion is always part of
/// its own slice, so it is seeded into the result even when it has no edge.
fn reachable(adj : Map[Int32, Array[Int32]], target : Int32) -> Array[Int32] {
  let seen : Set[Int32] = Set([])
  seen.add(target)
  let nodes : Array[Int32] = [target]
  let queue : Array[Int32] = [target]
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    match adj.get(current) {
      None => ()
      Some(next) =>
        for candidate in next {
          if !seen.contains(candidate) {
            seen.add(candidate)
            nodes.push(candidate)
            queue.push(candidate)
          }
        }
    }
  }
  nodes.sort()
  nodes
}

///|
/// Maps node ids to their unique sorted `loc.start_line`.
///
/// Ids absent from `program` contribute no line, so a slice over a graph built
/// from another program still returns the lines of the nodes that do exist. When
/// two nodes share a line, that line appears once. `program` is expected to hold
/// at most one node per id; if it repeats an id the first occurrence wins.
pub fn lines_of(program : @core.Program, nodes : Array[Int32]) -> Array[Int32] {
  let line_of : Map[Int32, Int32] = Map([])
  for node in program.nodes {
    if !line_of.contains(node.id) {
      line_of.set(node.id, node.loc.start_line)
    }
  }
  let seen : Set[Int32] = Set([])
  let lines : Array[Int32] = []
  for id in nodes {
    match line_of.get(id) {
      None => ()
      Some(line) =>
        if !seen.contains(line) {
          seen.add(line)
          lines.push(line)
        }
    }
  }
  lines.sort()
  lines
}

///|
/// Backward slice: the criterion plus every node that can reach it through an
/// incoming edge, transitively.
///
/// `program` is optional because `@core.Pdg` carries no locations. Pass it to
/// populate `lines`; without it `lines` is empty and only `nodes` is filled.
/// The two-argument form `backward(pdg, target)` is the frozen contract
/// signature and stays valid.
///
/// The walk is a breadth-first search over inverted PDG edges with a visited
/// set, so cycles terminate and every node is emitted once. `nodes` is sorted
/// ascending, making the result independent of edge order.
pub fn backward(
  pdg : @core.Pdg,
  target : Int32,
  program? : @core.Program,
) -> @core.SliceResult {
  let nodes = reachable(adjacency(pdg, false), target)
  let lines = match program {
    None => []
    Some(prog) => lines_of(prog, nodes)
  }
  { nodes, lines, }
}

///|
/// Forward slice: the criterion plus every node reachable from it through an
/// outgoing edge, transitively.
///
/// `program` is optional for the same reason as in `backward`; pass it to fill
/// `lines`. Cycles terminate, `nodes` is sorted ascending, and `lines` is the
/// unique sorted set of `loc.start_line` values.
pub fn forward(
  pdg : @core.Pdg,
  target : Int32,
  program? : @core.Program,
) -> @core.SliceResult {
  let nodes = reachable(adjacency(pdg, true), target)
  let lines = match program {
    None => []
    Some(prog) => lines_of(prog, nodes)
  }
  { nodes, lines, }
}
