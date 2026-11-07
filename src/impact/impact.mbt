// Impact proof: what a set of changed lines can affect.
//
// `slice` answers "which statements does this one change reach"; this package
// turns that answer into a certificate a reviewer can attach to a change:
//
//   * `changed_lines`          — the input, normalised;
//   * `affected_statements`    — the union of the forward slices of every
//                                changed line that resolves to a statement;
//   * `affected_functions`     — the functions those statements belong to;
//   * `reachable_entries`      — which public / `main` / test entry can reach
//                                those functions (through `@roots`);
//   * `cross_package_files`    — sibling files pulled in by `@interproc`
//                                expansion, i.e. impact that leaves the file;
//   * `related_tests`          — test call sites that call an affected
//                                function;
//   * `unresolved_boundaries`  — calls the analysis could not attribute, so a
//                                reader can see where the proof stops;
//   * `evidence`               — a shortest PDG path from a changed statement
//                                to every affected statement.
//
// The evidence is the difference between "these lines moved" and "this line
// moved *because* of that one". Paths follow control edges as well as data
// edges, because the forward slice does too: a changed `if` condition affects
// the body it guards through control dependence, and a data-only path would
// have no evidence for a real impact.

///|
/// One affected statement together with the shortest dependency path that
/// reaches it from a changed statement.
///
/// `path` always starts at a changed statement and ends at `node`, so the first
/// element names the cause and the last one the effect. Every node id belongs
/// to the program the certificate was computed on.
pub(all) struct ImpactEvidence {
  node : Int32
  line : Int32
  path : Array[Int32]
} derive(Debug, Eq)

///|
/// The impact of a set of changed lines: the proof, not just the line list.
pub(all) struct ImpactCertificate {
  changed_lines : Array[Int32]
  affected_statements : Array[Int32]
  affected_functions : Array[String]
  reachable_entries : Array[String]
  cross_package_files : Array[String]
  related_tests : Array[String]
  unresolved_boundaries : Array[String]
  evidence : Array[ImpactEvidence]
} derive(Debug)

///|
/// Sorted unique copy of the input lines. The certificate is a set-valued
/// answer, so `--lines 7,7,3` and `--lines 3,7` must produce the same proof.
fn sorted_unique_numbers(values : Array[Int32]) -> Array[Int32] {
  let seen : Set[Int32] = Set([])
  let out : Array[Int32] = []
  for value in values {
    if !seen.contains(value) {
      seen.add(value)
      out.push(value)
    }
  }
  out.sort()
  out
}

///|
fn push_unique(out : Array[String], value : String) -> Unit {
  if !out.contains(value) {
    out.push(value)
  }
}

///|
fn sort_strings(values : Array[String]) -> Unit {
  values.sort_by(fn(a, b) { a.lexical_compare(b) })
}

///|
/// Functions whose node span contains at least one of `nodes`.
///
/// A function owns `[entry, exit]` inclusively in the lowered IR, which is the
/// same range convention `@query` and `@interproc` use.
pub fn functions_of(program : @core.Program, nodes : Array[Int32]) -> Array[String] {
  let out : Array[String] = []
  for function in program.functions {
    let mut hit = false
    for id in nodes {
      if id >= function.entry && id <= function.exit {
        hit = true
      }
    }
    if hit {
      push_unique(out, function.name)
    }
  }
  sort_strings(out)
  out
}

///|
fn root_kind_label(kind : @roots.RootKind) -> String {
  match kind {
    @roots.RootKind::PublicApi => "public api"
    @roots.RootKind::EntryPoint => "entry point"
    @roots.RootKind::TestCall => "test call"
    @roots.RootKind::TraitImpl => "trait impl"
    @roots.RootKind::Explicit => "explicit entry"
    @roots.RootKind::TopLevel => "top-level"
  }
}

///|
/// The package call graph as `caller -> [callee]`, built once per certificate.
/// Both the entry proof and the test proof walk it.
fn call_adjacency(reachability : @roots.Reachability) -> Map[String, Array[String]] {
  let adjacency : Map[String, Array[String]] = Map([])
  for edge in reachability.edges {
    match adjacency.get(edge.caller) {
      None => adjacency.set(edge.caller, [edge.callee])
      Some(next) => next.push(edge.callee)
    }
  }
  adjacency
}

///|
/// Every entry that can reach `name`, as `"<name> (<kind>)"`.
///
/// All roots are tested, not just the one the BFS parent chain ends at: a
/// function can be both public API and called by a test, and a reviewer needs
/// both facts. A root that does not reach the function contributes nothing, so
/// an unreachable function returns an empty array rather than a guess.
fn entry_labels(
  adjacency : Map[String, Array[String]],
  reachability : @roots.Reachability,
  name : String,
) -> Array[String] {
  let out : Array[String] = []
  for root in reachability.roots {
    if reaches(adjacency, root.name, name) {
      push_unique(out, root.name + " (" + root_kind_label(root.kind) + ")")
    }
  }
  sort_strings(out)
  out
}

///|
fn defined_in_index(index : @interproc.PackageIndex, name : String) -> Bool {
  for file in index.files {
    match @query.function_named(file.program, name) {
      Some(_) => return true
      None => ()
    }
  }
  false
}

///|
/// Whether `goal` is reachable from `start` over the package call graph.
///
/// `@liveness` / `@parser_adapter` lower functions, not `test` blocks, so a
/// test's call sites never appear in any `Program`. Reachability sees them
/// because it walks the AST, and its `edges` are the package-wide graph; this
/// BFS is how an indirect test (`test -> mid -> changed`) is attributed.
fn reaches(adjacency : Map[String, Array[String]], start : String, goal : String) -> Bool {
  let seen : Set[String] = Set([])
  let queue : Array[String] = [start]
  seen.add(start)
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    if current == goal {
      return true
    }
    match adjacency.get(current) {
      None => ()
      Some(next) =>
        for candidate in next {
          if !seen.contains(candidate) {
            seen.add(candidate)
            queue.push(candidate)
          }
        }
    }
  }
  false
}

///|
/// The test entries that can reach `name`, rendered as `"<site>: <root>"`.
///
/// A root of kind `TestCall` is the place a `test` block mentions a function.
/// Reporting the site rather than the declaration is the useful direction for a
/// reviewer: it names the test they have to run.
fn test_entries(
  adjacency : Map[String, Array[String]],
  reachability : @roots.Reachability,
  name : String,
) -> Array[String] {
  let out : Array[String] = []
  for root in reachability.roots {
    if root.kind == @roots.RootKind::TestCall &&
      reaches(adjacency, root.name, name) {
      push_unique(out, root.site + ": " + root.name)
    }
  }
  sort_strings(out)
  out
}

///|
/// Whether a path is test code. Test files are the only place a "related test"
/// can live in MoonBit: `_test.mbt` for blackbox tests, `_wbtest.mbt` for
/// whitebox ones, and anything under a `test/` directory for suite drivers.
fn is_test_path(path : String) -> Bool {
  path.contains("_test.mbt") ||
  path.contains("_wbtest.mbt") ||
  path.contains("/test/") ||
  path.contains("\\test\\") ||
  path.has_prefix("test/")
}

///|
/// Build the impact certificate.
///
/// `program` and `pdg` are the analysed file. `changed_lines` are 1-based source
/// lines; a line with no node is ignored (it may be a comment or a blank line,
/// which a diff reports but nothing can slice).
///
/// `path` names the file inside `index`; with both supplied, `@interproc.expand`
/// follows calls into sibling files and `@interproc.callers` finds test callers.
/// `reachability` comes from `@roots.analyze` over the package's `FileFacts` and
/// turns affected function names into the entries that can reach them.
///
/// Everything is deterministic: sets are sorted, and evidence is emitted in
/// ascending statement order.
pub fn impact(
  program : @core.Program,
  pdg : @core.Pdg,
  changed_lines : Array[Int32],
  path? : String,
  index? : @interproc.PackageIndex,
  reachability? : @roots.Reachability,
) -> ImpactCertificate {
  let changed = sorted_unique_numbers(changed_lines)
  let target_path = match path {
    None => ""
    Some(value) => value
  }
  // A changed line can hold several statements; `target_node` picks the
  // statement a user means, exactly as `slice --line` does.
  let targets : Array[Int32] = []
  for line in changed {
    match @query.target_node(program, line) {
      Some(id) => targets.push(id)
      None => ()
    }
  }
  let seen : Set[Int32] = Set([])
  let statements : Array[Int32] = []
  for target in targets {
    for id in @slice.forward(pdg, target).nodes {
      if !seen.contains(id) {
        seen.add(id)
        statements.push(id)
      }
    }
  }
  statements.sort()
  let functions = functions_of(program, statements)
  // One shortest path per affected statement. Control edges are followed so a
  // statement guarded by a changed condition still has a witness.
  let evidence : Array[ImpactEvidence] = []
  for id in statements {
    let line = match @query.node_by_id(program, id) {
      Some(node) => node.loc.start_line
      None => 0
    }
    let steps = match @query.path_between(pdg, targets, [id], with_control=true) {
      Some(found) => found
      None => [id]
    }
    evidence.push(ImpactEvidence::{ node: id, line, path: steps })
  }
  // Cross-file impact, only when the caller supplied the package index and the
  // path that names this program inside it.
  let cross : Array[String] = []
  match index {
    None => ()
    Some(package_index) =>
      if target_path != "" && statements.length() > 0 {
        let base = @core.SliceResult::{ nodes: statements.copy(), lines: [] }
        for slice in @interproc.expand(package_index, target_path, base) {
          if slice.path != target_path {
            push_unique(cross, slice.path)
          }
        }
      }
  }
  sort_strings(cross)
  // Which entries reach the affected functions, and which tests can reach them.
  // Reachability sees `test` blocks (the lowerer does not), so it is the primary
  // source for `related_tests`; the call-site scan below still catches an
  // ordinary function declared in a test file.
  let entries : Array[String] = []
  let tests : Array[String] = []
  match reachability {
    None => ()
    Some(reach) => {
      let adjacency = call_adjacency(reach)
      for name in functions {
        for label in entry_labels(adjacency, reach, name) {
          push_unique(entries, label)
        }
        for entry in test_entries(adjacency, reach, name) {
          push_unique(tests, entry)
        }
      }
    }
  }
  sort_strings(entries)
  sort_strings(tests)
  match index {
    None => ()
    Some(package_index) =>
      for name in functions {
        for site in @interproc.callers(package_index, name) {
          if is_test_path(site.path) {
            push_unique(
              tests,
              site.path + ":" + site.line.to_string() + ": " + site.caller,
            )
          }
        }
      }
  }
  sort_strings(tests)
  // Where the proof stops. A direct call to a name this package does not
  // declare may go anywhere, so it is recorded instead of dropped.
  let boundaries : Array[String] = []
  for call in program.calls {
    if call.callee == "" {
      continue
    }
    let declared_here = match @query.function_named(program, call.callee) {
      Some(_) => true
      None => false
    }
    let elsewhere = match index {
      None => false
      Some(package_index) => defined_in_index(package_index, call.callee)
    }
    if !declared_here && !elsewhere {
      let site = if target_path == "" {
        "line " + call.line.to_string()
      } else {
        target_path + ":" + call.line.to_string()
      }
      push_unique(boundaries, call.caller + " -> " + call.callee + " at " + site)
    }
  }
  match reachability {
    None => ()
    Some(reach) =>
      for boundary in reach.boundaries {
        push_unique(boundaries, boundary)
      }
  }
  sort_strings(boundaries)
  ImpactCertificate::{
    changed_lines: changed,
    affected_statements: statements,
    affected_functions: functions,
    reachable_entries: entries,
    cross_package_files: cross,
    related_tests: tests,
    unresolved_boundaries: boundaries,
    evidence,
  }
}

///|
fn numbers_json(values : Array[Int32]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  let mut first = true
  for value in values {
    if !first {
      out.write_char(',')
    }
    out.write_string(value.to_string())
    first = false
  }
  out.write_char(']')
  out.to_string()
}

///|
fn strings_json(values : Array[String]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  let mut first = true
  for value in values {
    if !first {
      out.write_char(',')
    }
    out.write_string(@report.json_string(value))
    first = false
  }
  out.write_char(']')
  out.to_string()
}

///|
/// The certificate as one JSON object. Field order is fixed, so the output is
/// stable across runs and can be diffed in CI.
pub fn certificate_json(certificate : ImpactCertificate) -> String {
  let out = StringBuilder()
  out.write_string("{\"changed_lines\":")
  out.write_string(numbers_json(certificate.changed_lines))
  out.write_string(",\"affected_statements\":")
  out.write_string(numbers_json(certificate.affected_statements))
  out.write_string(",\"affected_functions\":")
  out.write_string(strings_json(certificate.affected_functions))
  out.write_string(",\"reachable_entries\":")
  out.write_string(strings_json(certificate.reachable_entries))
  out.write_string(",\"cross_package_files\":")
  out.write_string(strings_json(certificate.cross_package_files))
  out.write_string(",\"related_tests\":")
  out.write_string(strings_json(certificate.related_tests))
  out.write_string(",\"unresolved_boundaries\":")
  out.write_string(strings_json(certificate.unresolved_boundaries))
  out.write_string(",\"evidence\":[")
  let mut first = true
  for item in certificate.evidence {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"node\":")
    out.write_string(item.node.to_string())
    out.write_string(",\"line\":")
    out.write_string(item.line.to_string())
    out.write_string(",\"path\":")
    out.write_string(numbers_json(item.path))
    out.write_char('}')
  }
  out.write_string("]}")
  out.to_string()
}

///|
fn path_text(path : Array[Int32]) -> String {
  let out = StringBuilder()
  let mut first = true
  for id in path {
    if !first {
      out.write_string(" -> ")
    }
    out.write_string(id.to_string())
    first = false
  }
  out.to_string()
}

///|
fn join_lines(values : Array[Int32]) -> String {
  let out = StringBuilder()
  let mut first = true
  for value in values {
    if !first {
      out.write_char(',')
    }
    out.write_string(value.to_string())
    first = false
  }
  out.to_string()
}

///|
fn indented_list(out : StringBuilder, values : Array[String], empty : String) -> Unit {
  if values.length() == 0 {
    out.write_string(" (")
    out.write_string(empty)
    out.write_string(")\n")
  } else {
    out.write_char('\n')
    for value in values {
      out.write_string("  ")
      out.write_string(value)
      out.write_char('\n')
    }
  }
}

///|
/// The certificate as text. Every field of the JSON form appears here, so the
/// two renderings cannot drift apart.
pub fn certificate_text(certificate : ImpactCertificate) -> String {
  let out = StringBuilder()
  out.write_string(
    "impact: " +
    certificate.changed_lines.length().to_string() +
    " changed line(s), " +
    certificate.affected_statements.length().to_string() +
    " affected statement(s) in " +
    certificate.affected_functions.length().to_string() +
    " function(s)\n",
  )
  out.write_string("changed lines: ")
  out.write_string(join_lines(certificate.changed_lines))
  out.write_char('\n')
  out.write_string("affected statements: ")
  out.write_string(join_lines(certificate.affected_statements))
  out.write_char('\n')
  out.write_string("affected functions:")
  indented_list(out, certificate.affected_functions, "none")
  out.write_string("reachable entries:")
  indented_list(out, certificate.reachable_entries, "none")
  out.write_string("cross-package files:")
  indented_list(out, certificate.cross_package_files, "none")
  out.write_string("related tests:")
  indented_list(out, certificate.related_tests, "none")
  out.write_string("unresolved boundaries:")
  indented_list(out, certificate.unresolved_boundaries, "none")
  out.write_string("evidence:")
  if certificate.evidence.length() == 0 {
    out.write_string(" (none)\n")
  } else {
    out.write_char('\n')
    for item in certificate.evidence {
      out.write_string("  ")
      out.write_string(item.node.to_string())
      out.write_string(" (line ")
      out.write_string(item.line.to_string())
      out.write_string("): ")
      out.write_string(path_text(item.path))
      out.write_char('\n')
    }
  }
  out.to_string()
}
