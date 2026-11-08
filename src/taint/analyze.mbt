// The taint walk: resolve config rules to nodes, then run one multi-source BFS
// over the PDG's data edges.

///|
/// A config rule resolved to the call node it names, together with the rule
/// that matched so a finding can name the rule rather than the bare callee.
priv struct CallPoint {
  node : Int32
  name : String
}

///|
/// Whether a rule names a call. Case-sensitive. A rule containing `/`
/// (`env/read`) names the call after its last slash; a bare rule (`read`)
/// must equal the call exactly.
fn name_matches(rule : String, callee : String) -> Bool {
  if rule == callee {
    return true
  }
  match rule.rev_after("/") {
    None => false
    Some(tail) => tail.equal_to_string(callee)
  }
}

///|
/// The node a call site refers to.
///
/// The adapter makes the outer `Apply` a `Call` node spanning the whole
/// expression, so a call name recorded inside it (`f(g(x))` records both `f`
/// and `g`) may sit at a line covered by a wider node. Preference order is:
///
///   1. the narrowest `Call` node whose line span contains the call's line —
///      narrower means closer to the call, and the id breaks ties;
///   2. otherwise the lowest-id non-synthetic node starting on that line (a
///      `Let`, `Return`, `Assign`, or `Expr` that wraps the call);
///   3. otherwise the lowest-id node starting on that line, synthetic included.
///
/// A call site with no node at all resolves to `None` and is ignored.
fn resolve_call_node(program : @core.Program, call : @core.CallSite) -> Int32? {
  let mut best_id = -1
  let mut best_width = -1
  for node in program.nodes {
    if node.kind == @core.SNodeKind::Call &&
      node.loc.start_line <= call.line &&
      call.line <= node.loc.end_line {
      let width = node.loc.end_line - node.loc.start_line
      if best_id < 0 ||
        width < best_width ||
        (width == best_width && node.id < best_id) {
        best_id = node.id
        best_width = width
      }
    }
  }
  if best_id >= 0 {
    return Some(best_id)
  }
  let mut fallback_id = -1
  let mut synthetic_id = -1
  for node in program.nodes {
    if node.loc.start_line != call.line {
      continue
    }
    if is_synthetic(program, node) {
      if synthetic_id < 0 || node.id < synthetic_id {
        synthetic_id = node.id
      }
    } else if fallback_id < 0 || node.id < fallback_id {
      fallback_id = node.id
    }
  }
  if fallback_id >= 0 {
    return Some(fallback_id)
  }
  if synthetic_id >= 0 {
    return Some(synthetic_id)
  }
  None
}

///|
/// Whether the node is a function's synthetic entry or exit. Those carry the
/// signature's line and are not statements a call can be attributed to.
fn is_synthetic(program : @core.Program, node : @core.SNode) -> Bool {
  for f in program.functions {
    if node.id == f.entry || node.id == f.exit {
      return true
    }
  }
  false
}

///|
/// Resolves every rule in `rules` against the program's recorded call sites.
///
/// A node is claimed at most once, by the first rule (in rule order) that names
/// one of its call sites, so `["env/read", "fs/read"]` on one `read(...)` call
/// yields a single source labelled `env/read`.
fn resolve_calls(
  program : @core.Program,
  rules : Array[String],
) -> Array[CallPoint] {
  let out : Array[CallPoint] = []
  let claimed : Set[Int32] = Set([])
  for call in program.calls {
    match resolve_call_node(program, call) {
      None => ()
      Some(node_id) =>
        if !claimed.contains(node_id) {
          let mut matched = ""
          for rule in rules {
            if name_matches(rule, call.callee) {
              matched = rule
              break
            }
          }
          if matched != "" {
            claimed.add(node_id)
            out.push({ node: node_id, name: matched, })
          }
        }
    }
  }
  out
}

///|
/// The set of node ids in a resolved rule list.
fn node_set(points : Array[CallPoint]) -> Set[Int32] {
  let out : Set[Int32] = Set([])
  for point in points {
    out.add(point.node)
  }
  out
}

///|
/// `node id -> rule name`, for naming findings.
fn name_table(points : Array[CallPoint]) -> Map[Int32, String] {
  let out : Map[Int32, String] = Map([])
  for point in points {
    if !out.contains(point.node) {
      out.set(point.node, point.name)
    }
  }
  out
}

///|
/// `node id -> start line`.
fn line_table(program : @core.Program) -> Map[Int32, Int32] {
  let table : Map[Int32, Int32] = Map([])
  for node in program.nodes {
    if !table.contains(node.id) {
      table.set(node.id, node.loc.start_line)
    }
  }
  table
}

///|
/// Data-edge adjacency, successors sorted ascending. Sorting is what makes the
/// chosen shortest path deterministic: two equal-length paths are broken by the
/// node ids on the way, never by `Pdg.edges` order.
fn data_successors(pdg : @core.Pdg) -> Map[Int32, Array[Int32]] {
  let adj : Map[Int32, Array[Int32]] = Map([])
  for edge in pdg.edges {
    if edge.kind != @core.Data {
      continue
    }
    match adj.get(edge.from) {
      None => adj.set(edge.from, [edge.to])
      Some(next) =>
        if !next.contains(edge.to) {
          next.push(edge.to)
        }
    }
  }
  adj.each(fn(_from, next) { next.sort() })
  adj
}

///|
/// Rebuilds the BFS path from `source` to `sink` out of the parent links.
/// Endpoints included; `source` first, `sink` last.
fn build_path(
  parent : Map[Int32, Int32],
  source : Int32,
  sink : Int32,
) -> Array[Int32] {
  let reversed : Array[Int32] = [sink]
  let mut current = sink
  while current != source {
    match parent.get(current) {
      None => break
      Some(previous) => {
        current = previous
        reversed.push(current)
      }
    }
  }
  let path : Array[Int32] = []
  let mut index = reversed.length() - 1
  while index >= 0 {
    path.push(reversed[index])
    index = index - 1
  }
  path
}

///|
/// Report order: source line, sink line, rule names, then path. A stable order
/// keeps `report_json` diffable across runs.
fn cmp_findings(a : TaintFinding, b : TaintFinding) -> Int32 {
  if a.source_line != b.source_line {
    return if a.source_line < b.source_line { -1 } else { 1 }
  }
  if a.sink_line != b.sink_line {
    return if a.sink_line < b.sink_line { -1 } else { 1 }
  }
  let by_source = a.source_name.lexical_compare(b.source_name)
  if by_source != 0 {
    return by_source
  }
  let by_sink = a.sink_name.lexical_compare(b.sink_name)
  if by_sink != 0 {
    return by_sink
  }
  if a.path.length() != b.path.length() {
    return if a.path.length() < b.path.length() { -1 } else { 1 }
  }
  if a.path.length() > 0 && b.path.length() > 0 && a.path[0] != b.path[0] {
    return if a.path[0] < b.path[0] { -1 } else { 1 }
  }
  0
}

///|
/// Finds source-to-sink flows through the PDG's data edges.
///
/// One breadth-first walk seeded with every source call gives each node its
/// shortest tainted path, so a sink is reported once, through its nearest
/// source. A sanitizer stops the walk at itself: its successors are never
/// enqueued, so flows through it do not exist as far as the report is
/// concerned, while an alternative clean route (if any) is still found.
///
/// A sink that resolves to the same node as a source is reported with a
/// one-node path. That is the nested-call case: `exec(read())` lowers to a
/// single `Call` node, and the statement itself is the whole flow. `control`
/// edges are ignored entirely.
///
/// `truncated` counts sanitizer calls the walk actually reached; a sanitizer no
/// source can reach is not counted.
pub fn analyze(
  program : @core.Program,
  pdg : @core.Pdg,
  config : TaintConfig,
) -> TaintReport {
  let sources = resolve_calls(program, config.sources)
  let sinks = resolve_calls(program, config.sinks)
  let sanitizers = resolve_calls(program, config.sanitizers)
  let source_count = sources.length()
  let sink_count = sinks.length()
  let sink_set = node_set(sinks)
  let sanitizer_set = node_set(sanitizers)
  if source_count == 0 {
    // Nothing is tainted, so there is no walk to run and nothing to truncate.
    return { findings: [], sources_seen: 0, sinks_seen: sink_count, truncated: 0, }
  }
  let lines = line_table(program)
  let source_names = name_table(sources)
  let sink_names = name_table(sinks)
  let successors = data_successors(pdg)
  let visited : Set[Int32] = Set([])
  let parent : Map[Int32, Int32] = Map([])
  // Which source node the taint at a node came from, so a finding can name it
  // without walking the parent chain backwards for every sink.
  let root : Map[Int32, Int32] = Map([])
  let queue : Array[Int32] = []
  for point in sources {
    if !visited.contains(point.node) {
      visited.add(point.node)
      root.set(point.node, point.node)
      queue.push(point.node)
    }
  }
  let flows : Array[(Int32, Int32)] = []
  let mut truncated = 0
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    if sanitizer_set.contains(current) {
      truncated = truncated + 1
      continue
    }
    let from_source = root.get(current).unwrap_or(current)
    if sink_set.contains(current) {
      flows.push((current, from_source))
    }
    match successors.get(current) {
      None => ()
      Some(next) =>
        for candidate in next {
          if !visited.contains(candidate) {
            visited.add(candidate)
            parent.set(candidate, current)
            root.set(candidate, from_source)
            queue.push(candidate)
          }
        }
    }
  }
  let findings : Array[TaintFinding] = []
  for flow in flows {
    let sink_node = flow.0
    let source_node = flow.1
    findings.push({
      source_name: source_names.get_or_default(source_node, ""),
      source_line: lines.get_or_default(source_node, 0),
      sink_name: sink_names.get_or_default(sink_node, ""),
      sink_line: lines.get_or_default(sink_node, 0),
      path: build_path(parent, source_node, sink_node),
      sanitized: false,
    })
  }
  findings.sort_by(cmp_findings)
  {
    findings,
    sources_seen: source_count,
    sinks_seen: sink_count,
    truncated,
  }
}
