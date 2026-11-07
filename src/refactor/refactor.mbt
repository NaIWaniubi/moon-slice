// Dead-code removal planning: from findings to edits, with a proof.
//
// The analysis packages answer "what is dead"; this one answers "what may be
// deleted, and why is that safe". It is deliberately the most conservative
// package in the tree, because an edit here changes the user's source:
//
//   * a statement is removed only when it is a `let` binding whose variables
//     are never read and never redefined, and whose initializer is pure;
//   * a function is removed only when `src/roots` proves it unreachable from
//     every package root *and* `src/sidefx` proves its body effect-free;
//   * a `// moon-slice: ignore` directive always wins;
//   * a public declaration is never removed;
//   * after the edits are computed they are applied in memory and the analysis
//     runs again; a single new finding undoes the whole plan for that file.
//
// Purity is checked twice on purpose. `src/sidefx` summarises the expression or
// body (IO names, field writes, receiver mutation, raise, recursion). On top of
// that, every call has to resolve to a single declaration of the package whose
// own summary is pure: a call the analysis cannot place is a call whose effects
// it cannot rule out, and the safe reading of "unknown" is "not pure".
//
// The result is a `RemovalPlan`: line edits plus the human-readable proof trail
// that explains every accepted and every rejected candidate. Rendering that
// plan as a unified diff is also here, so the CLI only wires flags to it.

///|
/// One source file of a package, as the planner sees it.
pub(all) struct SourceFile {
  path : String
  source : String
}

///|
/// One line range to delete. Lines are 1-based and inclusive; `end_line` is the
/// last line of the removed statement or declaration.
pub(all) struct Edit {
  file : String
  start_line : Int32
  end_line : Int32
  /// Why the removal is safe, in one sentence. It names the finding and the
  /// evidence (never read, pure initializer, unreachable from any root, ...).
  reason : String
}

///|
/// What `fix` would do, plus the reasoning behind it.
pub(all) struct RemovalPlan {
  /// Non-overlapping, sorted by file and line.
  edits : Array[Edit]
  /// One line per decision: accepted edits, rejected candidates with the
  /// reason, and the outcome of the re-analysis check.
  proof : Array[String]
}

///|
/// The plan with no edits. Useful as a neutral element when merging.
pub fn empty_plan() -> RemovalPlan {
  RemovalPlan::{ edits: [], proof: [] }
}

///|
/// The name of the synthetic function used to summarise a binding's
/// initializer. Unlikely enough that a package cannot clash with it.
const PROBE_NAME : String = "__moon_slice_refactor_probe__"

///|
fn site(path : String, line : Int32) -> String {
  path + ":" + line.to_string()
}

///|
/// Split a source into lines, without the empty element a trailing newline
/// produces. A trailing `\r` (CRLF input) is dropped so line-oriented output is
/// stable across checkouts.
fn source_lines(source : String) -> Array[String] {
  let parts : Array[String] = []
  for raw in source.split("\n") {
    let line = raw.to_owned()
    let stripped = if line.has_suffix("\r") {
      line[:line.length() - 1].to_owned()
    } else {
      line
    }
    parts.push(stripped)
  }
  if parts.length() > 0 && parts[parts.length() - 1] == "" {
    let out : Array[String] = []
    let mut i = 0
    while i < parts.length() - 1 {
      out.push(parts[i])
      i = i + 1
    }
    out
  } else {
    parts
  }
}

///|
/// Every line number covered by `edits`, as a set.
fn deleted_lines(edits : Array[Edit]) -> Set[Int] {
  let out : Set[Int] = Set([])
  for edit in edits {
    let mut line = if edit.start_line < 1 { 1 } else { edit.start_line }
    while line <= edit.end_line {
      out.add(line)
      line = line + 1
    }
  }
  out
}

///|
/// Sort edits by file and position, then drop any edit that is contained in an
/// earlier one. Containment is real: a dead binding inside an unreachable
/// function would otherwise be deleted twice.
fn normalize_edits(edits : Array[Edit]) -> Array[Edit] {
  let sorted = edits.copy()
  sorted.sort_by(fn(a, b) {
    let by_file = a.file.lexical_compare(b.file)
    if by_file != 0 {
      by_file
    } else if a.start_line < b.start_line {
      -1
    } else if a.start_line > b.start_line {
      1
    } else if a.end_line < b.end_line {
      -1
    } else if a.end_line > b.end_line {
      1
    } else {
      0
    }
  })
  let out : Array[Edit] = []
  for edit in sorted {
    let mut keep = true
    for existing in out {
      if existing.file == edit.file &&
        existing.start_line <= edit.start_line &&
        existing.end_line >= edit.end_line {
        keep = false
      }
    }
    if keep {
      out.push(edit)
    }
  }
  out
}

///|
/// Merge several plans into one. Proof lines are kept in order; edits are
/// normalised together so a later range can suppress an earlier nested one.
pub fn merge_plans(plans : Array[RemovalPlan]) -> RemovalPlan {
  let edits : Array[Edit] = []
  let proof : Array[String] = []
  for plan in plans {
    for edit in plan.edits {
      edits.push(edit)
    }
    for line in plan.proof {
      proof.push(line)
    }
  }
  RemovalPlan::{ edits: normalize_edits(edits), proof }
}

///|
/// The source with every edited line range removed. Line endings are
/// normalised to LF and the result always ends with a newline; the CLI writes
/// exactly this text under `--write`.
pub fn apply_edits(source : String, edits : Array[Edit]) -> String {
  let lines = source_lines(source)
  let deleted = deleted_lines(edits)
  let out = StringBuilder()
  let mut i = 0
  while i < lines.length() {
    if !deleted.contains(i + 1) {
      out.write_string(lines[i])
      out.write_char('\n')
    }
    i = i + 1
  }
  out.to_string()
}

///|
/// Render the plan as a unified diff against `source`, three lines of context.
/// An empty string means there is nothing to change.
pub fn to_unified_diff(file : String, source : String, edits : Array[Edit]) -> String {
  let lines = source_lines(source)
  let count = lines.length()
  let deleted = deleted_lines(edits)
  if count == 0 || deleted.length() == 0 {
    return ""
  }
  // Contiguous runs of deleted lines, then merge runs that are close enough
  // that their context windows would touch.
  let groups : Array[(Int, Int)] = []
  let mut i = 1
  while i <= count {
    if deleted.contains(i) {
      let start = i
      let mut end = i
      while end + 1 <= count && deleted.contains(end + 1) {
        end = end + 1
      }
      if groups.length() > 0 {
        let previous = groups[groups.length() - 1]
        if start - previous.1 - 1 <= 6 {
          groups[groups.length() - 1] = (previous.0, end)
        } else {
          groups.push((start, end))
        }
      } else {
        groups.push((start, end))
      }
      i = end + 1
    } else {
      i = i + 1
    }
  }
  let out = StringBuilder()
  out.write_string("--- a/" + file + "\n")
  out.write_string("+++ b/" + file + "\n")
  for group in groups {
    let old_start = if group.0 - 3 < 1 { 1 } else { group.0 - 3 }
    let old_end = if group.1 + 3 > count { count } else { group.1 + 3 }
    let old_count = old_end - old_start + 1
    let mut kept_before = 0
    let mut line = 1
    while line < old_start {
      if !deleted.contains(line) {
        kept_before = kept_before + 1
      }
      line = line + 1
    }
    let mut new_count = 0
    line = old_start
    while line <= old_end {
      if !deleted.contains(line) {
        new_count = new_count + 1
      }
      line = line + 1
    }
    let new_start = if new_count == 0 { kept_before } else { kept_before + 1 }
    out.write_string(
      "@@ -" +
      old_start.to_string() +
      "," +
      old_count.to_string() +
      " +" +
      new_start.to_string() +
      "," +
      new_count.to_string() +
      " @@\n",
    )
    line = old_start
    while line <= old_end {
      if deleted.contains(line) {
        out.write_char('-')
      } else {
        out.write_char(' ')
      }
      out.write_string(lines[line - 1])
      out.write_char('\n')
      line = line + 1
    }
  }
  out.to_string()
}

///|
/// The machine-readable plan: `{"edits":[...],"proof":[...]}`. Field names are
/// part of the CLI contract, so they do not change when the internals do.
pub fn to_json(plan : RemovalPlan) -> String {
  let out = StringBuilder()
  out.write_string("{\"edits\":[")
  let mut first = true
  for edit in plan.edits {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"file\":")
    out.write_string(@report.json_string(edit.file))
    out.write_string(",\"start_line\":")
    out.write_string(edit.start_line.to_string())
    out.write_string(",\"end_line\":")
    out.write_string(edit.end_line.to_string())
    out.write_string(",\"reason\":")
    out.write_string(@report.json_string(edit.reason))
    out.write_string("}")
  }
  out.write_string("],\"proof\":[")
  first = true
  for line in plan.proof {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string(@report.json_string(line))
  }
  out.write_string("]}")
  out.to_string()
}

///|
/// What one function declaration contributes to a removal decision.
priv struct DeclSite {
  name : String
  line : Int32
  end_line : Int32
  exported : Bool
  body : @syntax.Expr?
}

///|
fn is_exported(vis : @syntax.Visibility) -> Bool {
  match vis {
    @syntax.Visibility::Default => false
    @syntax.Visibility::Pub(..) => true
    @syntax.Visibility::Priv(..) => false
  }
}

///|
fn body_of(decl_body : @syntax.DeclBody) -> @syntax.Expr? {
  match decl_body {
    @syntax.DeclBody::DeclBody(expr~) => Some(expr)
    _ => None
  }
}

///|
/// Every free function and inherent/trait method with a body, with the line
/// range the whole declaration occupies. The range is what an edit removes.
fn decl_sites(source : String, path : String) -> Array[DeclSite] {
  let (items, _reports) = @parser.parse_string(source, name=path)
  let out : Array[DeclSite] = []
  items.each(fn(item) {
    match item {
      @syntax.Impl::TopFuncDef(fun_decl=decl, decl_body=decl_body, loc~, ..) => {
        let body = body_of(decl_body)
        let start = decl.name.loc.start.lnum
        let mut end = loc.end.lnum
        match body {
          Some(expr) =>
            match expr {
              @syntax.Expr::StaticAssert(..) => ()
              _ => {
                let body_end = (expr : @syntax.Expr).loc().end.lnum
                if body_end > end {
                  end = body_end
                }
              }
            }
          None => ()
        }
        out.push(DeclSite::{
          name: decl.name.name,
          line: start,
          end_line: end,
          exported: is_exported(decl.vis),
          body,
        })
      }
      @syntax.Impl::TopImpl(method_name~, vis~, body~, loc~, ..) => {
        let body_expr = body_of(body)
        let start = method_name.loc.start.lnum
        let mut end = loc.end.lnum
        match body_expr {
          Some(expr) => {
            let body_end = expr.loc().end.lnum
            if body_end > end {
              end = body_end
            }
          }
          None => ()
        }
        out.push(DeclSite::{
          name: method_name.name,
          line: start,
          end_line: end,
          exported: is_exported(vis),
          body: body_expr,
        })
      }
      _ => ()
    }
  })
  out
}

///|
fn find_decl(sites : Array[DeclSite], name : String, line : Int32) -> DeclSite? {
  for entry in sites {
    if entry.name == name && entry.line == line {
      return Some(entry)
    }
  }
  None
}

///|
/// Which package functions are "known pure". A name declared more than once is
/// never trusted: the summary cannot say which declaration a call means.
priv struct PurityIndex {
  counts : Map[String, Int]
  pure : Map[String, Bool]
}

///|
fn PurityIndex::is_pure(self : PurityIndex, name : String) -> Bool {
  let unique = match self.counts.get(name) {
    Some(count) => count == 1
    None => false
  }
  if !unique {
    return false
  }
  match self.pure.get(name) {
    Some(true) => true
    _ => false
  }
}

///|
fn purity_index(facts : Array[@liveness.FileFacts]) -> PurityIndex {
  let counts : Map[String, Int] = Map([])
  let batch : Array[@sidefx.FnSource] = []
  for file in facts {
    for decl in file.decls {
      if decl.has_body {
        let next = match counts.get(decl.name) {
          Some(count) => count + 1
          None => 1
        }
        counts.set(decl.name, next)
        batch.push(@sidefx.FnSource::{ name: decl.name, source: file.source })
      }
    }
  }
  let pure : Map[String, Bool] = Map([])
  for summary in @sidefx.summarize_package(batch) {
    let so_far = match pure.get(summary.name) {
      Some(value) => value
      None => true
    }
    pure.set(summary.name, so_far && summary.effects.pure)
  }
  PurityIndex::{ counts, pure }
}

///|
/// Collects calls the planner cannot prove harmless: a package-qualified call
/// (`@pkg.f`), a call through an expression, and any call whose name is not a
/// single pure declaration of the package.
priv struct CallAudit {
  purity : PurityIndex
  problems : Array[String]
}

///|
extend CallAudit with @syntax.IterVisitor::{ base }

///|
fn CallAudit::note(self : CallAudit, name : String) -> Unit {
  if !self.problems.contains(name) && !self.purity.is_pure(name) {
    self.problems.push(name)
  }
}

///|
impl @syntax.IterVisitor for CallAudit with fn visit_Expr_Apply(
  env,
  func~,
  args~,
  loc~,
) {
  match func {
    @syntax.Expr::Ident(id~, ..) =>
      match id.name {
        @syntax.LongIdent::Ident(name~) => env.note(name)
        @syntax.LongIdent::Dot(pkg~, id~) =>
          env.note("@" + pkg + "." + id)
      }
    @syntax.Expr::Method(method_name~, ..) => env.note(method_name.name)
    @syntax.Expr::Group(expr~, ..) =>
      match expr {
        @syntax.Expr::Ident(id~, ..) =>
          match id.name {
            @syntax.LongIdent::Ident(name~) => env.note(name)
            @syntax.LongIdent::Dot(pkg~, id~) =>
              env.note("@" + pkg + "." + id)
          }
        _ => env.note("call through an expression")
      }
    _ => env.note("call through an expression")
  }
  @syntax.IterVisitor::visit_Expr_Apply(env.base(), func~, args~, loc~)
}

///|
impl @syntax.IterVisitor for CallAudit with fn visit_Expr_DotApply(
  env,
  self~,
  method_name~,
  args~,
  return_self~,
  loc~,
) {
  env.note(method_name.name)
  @syntax.IterVisitor::visit_Expr_DotApply(
    env.base(), self~, method_name~, args~, return_self~, loc~,
  )
}

///|
fn audit_calls(expr : @syntax.Expr, purity : PurityIndex) -> Array[String] {
  let audit : CallAudit = { purity, problems: [] }
  @syntax.IterVisitor::visit_Expr(audit, expr)
  audit.problems
}

///|
fn audit_source(source : String, purity : PurityIndex) -> Array[String] {
  let sites = decl_sites(source, "<probe>")
  if sites.length() != 1 {
    return ["<unparsed initializer>"]
  }
  match sites[0].body {
    None => ["<unparsed initializer>"]
    Some(body) => audit_calls(body, purity)
  }
}

///|
fn describe_impurity(effects : @sidefx.SideEffects) -> String {
  if effects.may_io {
    "the initializer would perform I/O"
  } else if effects.may_raise {
    "the initializer could raise"
  } else if effects.mutates_receiver {
    "the initializer would mutate its receiver"
  } else if effects.writes_fields.length() > 0 {
    "the initializer would write a field"
  } else if effects.calls.length() > 0 {
    "the initializer calls " + effects.calls.join(", ")
  } else {
    "the initializer is not a pure expression"
  }
}

///|
/// `None` when the initializer is provably effect-free, otherwise the reason
/// the planner refuses to delete the binding.
fn rhs_purity(rhs : String, purity : PurityIndex) -> String? {
  let probe = "fn " + PROBE_NAME + "() -> Unit {\n" + rhs + "\n}\n"
  match @sidefx.summarize_source(probe, PROBE_NAME) {
    None => Some("the initializer does not parse as an expression")
    Some(effects) =>
      if !effects.pure {
        Some(describe_impurity(effects))
      } else {
        let unresolved = audit_source(probe, purity)
        if unresolved.length() > 0 {
          Some(
            "the initializer calls " +
            unresolved.join(", ") +
            ", which this package does not prove pure",
          )
        } else {
          None
        }
      }
  }
}

///|
/// The initializer text of a `let`/`let mut` statement, taken from the source
/// lines the node covers. Everything up to the first `=` on the first line is
/// the binder; a multi-line initializer keeps the rest of its lines.
///
/// Taking the whole rest of the line is deliberate: if several statements share
/// a line the probe sees more code than the initializer, which can only add an
/// effect and make the planner refuse. The error is in the safe direction.
fn binding_rhs(source : String, node : @core.SNode) -> String? {
  let lines = source_lines(source)
  let start = node.loc.start_line
  let end = node.loc.end_line
  if start < 1 || start > lines.length() {
    return None
  }
  let last = if end < start {
    start
  } else if end > lines.length() {
    lines.length()
  } else {
    end
  }
  let first_line = lines[start - 1]
  let equals = match first_line.find("=") {
    Some(index) => index
    None => return None
  }
  let out = StringBuilder()
  out.write_string(first_line[equals + 1:].to_owned())
  let mut line = start
  while line < last {
    out.write_char('\n')
    out.write_string(lines[line])
    line = line + 1
  }
  Some(out.to_string())
}

///|
/// True when no statement in the program reads or redefines the variables this
/// binding introduces. `src/query.dead_nodes` already proves the definition
/// itself reaches no use; this is the stronger property an edit needs, because
/// removing a declaration that a later assignment writes would leave that
/// assignment without a binding.
fn unused_binding(program : @core.Program, node : @core.SNode) -> Bool {
  if node.defs.length() == 0 {
    return false
  }
  for variable in node.defs {
    for read in node.uses {
      if read == variable {
        return false
      }
    }
    for other in program.nodes {
      if other.id != node.id {
        for defined in other.defs {
          if defined == variable {
            return false
          }
        }
        for used in other.uses {
          if used == variable {
            return false
          }
        }
      }
    }
  }
  true
}

///|
fn binding_label(node : @core.SNode) -> String {
  let names : Array[String] = []
  for variable in node.defs {
    names.push(variable.name)
  }
  names.join(", ")
}

///|
fn kind_label(kind : @core.SNodeKind) -> String {
  match kind {
    @core.SNodeKind::Let => "let"
    @core.SNodeKind::LetMut => "let mut"
    @core.SNodeKind::Assign => "assignment"
    @core.SNodeKind::If => "if"
    @core.SNodeKind::While => "while"
    @core.SNodeKind::For => "for"
    @core.SNodeKind::Match => "match"
    @core.SNodeKind::Return => "return"
    @core.SNodeKind::Break => "break"
    @core.SNodeKind::Continue => "continue"
    @core.SNodeKind::Call => "call"
    @core.SNodeKind::Expr => "expression"
  }
}

///|
fn binding_edit(
  program : @core.Program,
  node : @core.SNode,
  file : SourceFile,
  directives : @suppress.Directives,
  purity : PurityIndex,
  proof : Array[String],
) -> Edit? {
  let location = site(file.path, node.loc.start_line)
  let label = binding_label(node)
  if @suppress.suppresses(directives, node.loc.start_line, "dead-store") {
    proof.push(
      location + ": kept dead binding `" + label + "`: suppressed by a directive",
    )
    return None
  }
  if !unused_binding(program, node) {
    proof.push(
      location +
      ": kept dead binding `" +
      label +
      "`: the variable is read or redefined elsewhere",
    )
    return None
  }
  let rhs = match binding_rhs(file.source, node) {
    None => {
      proof.push(
        location + ": kept dead binding `" + label + "`: the initializer could not be read",
      )
      return None
    }
    Some(rhs) => rhs
  }
  match rhs_purity(rhs, purity) {
    Some(reason) => {
      proof.push(location + ": kept dead binding `" + label + "`: " + reason)
      None
    }
    None => {
      proof.push(
        location +
        ": remove dead binding `" +
        label +
        "`: pure initializer and no use",
      )
      Some(Edit::{
        file: file.path,
        start_line: node.loc.start_line,
        end_line: node.loc.end_line,
        reason: "unused binding `" +
          label +
          "`: the initializer is pure and nothing reads the variable",
      })
    }
  }
}

///|
fn function_edit(
  item : @roots.UnreachableFn,
  sites : Array[DeclSite],
  directives : @suppress.Directives,
  purity : PurityIndex,
  proof : Array[String],
) -> Edit? {
  let location = site(item.path, item.line)
  let declared = match find_decl(sites, item.name, item.line) {
    None => {
      proof.push(
        location +
        ": kept unreachable function `" +
        item.name +
        "`: its declaration range could not be read",
      )
      return None
    }
    Some(declared) => declared
  }
  if declared.exported {
    proof.push(
      location + ": kept function `" + item.name + "`: public declarations are never removed",
    )
    return None
  }
  if @suppress.suppresses(directives, item.line, "unused-function") ||
    @suppress.suppresses(directives, item.line, "unreachable-code") {
    proof.push(
      location +
      ": kept unreachable function `" +
      item.name +
      "`: suppressed by a directive",
    )
    return None
  }
  if !purity.is_pure(item.name) {
    proof.push(
      location +
      ": kept unreachable function `" +
      item.name +
      "`: it may have side effects or its name is declared more than once",
    )
    return None
  }
  match declared.body {
    None => {
      proof.push(
        location +
        ": kept unreachable function `" +
        item.name +
        "`: no body to audit",
      )
      None
    }
    Some(body) => {
      let unresolved = audit_calls(body, purity)
      if unresolved.length() > 0 {
        proof.push(
          location +
          ": kept unreachable function `" +
          item.name +
          "`: its body calls " +
          unresolved.join(", ") +
          ", which this package does not prove pure",
        )
        None
      } else {
        proof.push(
          location +
          ": remove unreachable function `" +
          item.name +
          "`: no root reaches it and its body is pure",
        )
        Some(Edit::{
          file: item.path,
          start_line: item.line,
          end_line: declared.end_line,
          reason: "unreachable private function `" +
            item.name +
            "`: no path from any package root and no side effects",
        })
      }
    }
  }
}

///|
/// Statement-level findings of one file, after in-source suppression:
/// `(line, rule)` pairs. This is the same rule the `dead` command reports.
fn findings(source : String, path : String) -> Array[(Int32, String)] {
  let program = @parser_adapter.parse_source(source, path)
  if program.errors.length() > 0 {
    return []
  }
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let dead = @query.dead_nodes(program, defuse)
  let unreachable_ids = @query.unreachable_nodes(program, cfg)
  let directives = @suppress.parse(source)
  let out : Array[(Int32, String)] = []
  for id in dead {
    match @query.node_by_id(program, id) {
      None => ()
      Some(node) =>
        if !@suppress.suppresses(directives, node.loc.start_line, "dead-store") {
          out.push((node.loc.start_line, "dead-store"))
        }
    }
  }
  for id in unreachable_ids {
    if !dead.contains(id) {
      match @query.node_by_id(program, id) {
        None => ()
        Some(node) =>
          if !@suppress.suppresses(
            directives,
            node.loc.start_line,
            "unreachable-code",
          ) {
            out.push((node.loc.start_line, "unreachable-code"))
          }
      }
    }
  }
  out
}

///|
/// The line an old line maps to once the edited ranges are removed, or -1 when
/// the line itself is deleted.
fn shifted_line(line : Int32, deleted : Set[Int]) -> Int32 {
  if deleted.contains(line) {
    return -1
  }
  let mut removed = 0
  let mut current = 1
  while current < line {
    if deleted.contains(current) {
      removed = removed + 1
    }
    current = current + 1
  }
  line - removed
}

///|
/// Re-analyse the edited source and report anything the removal made worse.
/// An empty array means the plan is safe to show or to write.
///
/// The check is a set comparison: every finding still present after the edit
/// must have been present before, at the corresponding shifted line. A new
/// finding means deleting X made Y dead, and the caller must not proceed.
pub fn verify(file : String, original : String, edits : Array[Edit]) -> Array[String] {
  let problems : Array[String] = []
  if edits.length() == 0 {
    return problems
  }
  let deleted = deleted_lines(edits)
  let after = apply_edits(original, edits)
  let reparsed = @parser_adapter.parse_source(after, file)
  if reparsed.errors.length() > 0 {
    problems.push(
      "the edited file would not parse (" +
      reparsed.errors.length().to_string() +
      " parser diagnostic(s))",
    )
    return problems
  }
  let expected : Set[String] = Set([])
  for pair in findings(original, file) {
    let moved = shifted_line(pair.0, deleted)
    if moved >= 0 {
      expected.add(moved.to_string() + "|" + pair.1)
    }
  }
  for pair in findings(after, file) {
    let key = pair.0.to_string() + "|" + pair.1
    if !expected.contains(key) {
      problems.push(
        "line " +
        pair.0.to_string() +
        ": a new " +
        pair.1 +
        " finding appears after the removal",
      )
    }
  }
  problems
}

///|
/// Turn a caller-computed dead-node set into binding edits. This is the
/// `Program` + node-ids entry point the pipeline uses internally and the one a
/// caller with its own analysis can drive directly; `plan_package` adds the
/// function-level and re-analysis checks around it.
fn add_binding_edits(
  program : @core.Program,
  dead : Array[Int32],
  file : SourceFile,
  directives : @suppress.Directives,
  purity : PurityIndex,
  proof : Array[String],
  edits : Array[Edit],
) -> Unit {
  for id in dead {
    match @query.node_by_id(program, id) {
      None => ()
      Some(node) =>
        if node.kind == @core.SNodeKind::Let ||
          node.kind == @core.SNodeKind::LetMut {
          match binding_edit(program, node, file, directives, purity, proof) {
            Some(edit) => edits.push(edit)
            None => ()
          }
        } else {
          proof.push(
            site(file.path, node.loc.start_line) +
            ": kept dead " +
            kind_label(node.kind) +
            " (only unused `let` bindings are removed)",
          )
        }
    }
  }
}

///|
/// The `Program` + dead-node-set entry point: plan the removable `let`
/// bindings of `file`. `package_files` supplies the purity closure, so a call
/// in an initializer to another declaration of the package is judged by that
/// declaration's summary.
pub fn plan_dead_bindings(
  program : @core.Program,
  dead : Array[Int32],
  file : SourceFile,
  directives : @suppress.Directives,
  package_files : Array[SourceFile],
) -> RemovalPlan {
  let facts : Array[@liveness.FileFacts] = []
  for entry in package_files {
    facts.push(@liveness.collect(entry.path, entry.source))
  }
  let purity = purity_index(facts)
  let proof : Array[String] = []
  let edits : Array[Edit] = []
  add_binding_edits(program, dead, file, directives, purity, proof, edits)
  RemovalPlan::{ edits: normalize_edits(edits), proof }
}

///|
fn plan_one(
  file : SourceFile,
  reach : @roots.Reachability,
  purity : PurityIndex,
) -> RemovalPlan {
  let proof : Array[String] = []
  let program = @parser_adapter.parse_source(file.source, file.path)
  if program.errors.length() > 0 {
    proof.push(
      file.path +
      ": skipped (" +
      program.errors.length().to_string() +
      " parser diagnostic(s))",
    )
    return RemovalPlan::{ edits: [], proof }
  }
  let directives = @suppress.parse(file.source)
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let dead = @query.dead_nodes(program, defuse)
  let sites = decl_sites(file.source, file.path)
  let edits : Array[Edit] = []
  add_binding_edits(program, dead, file, directives, purity, proof, edits)
  for item in reach.unreachable_fns {
    if item.path == file.path {
      match function_edit(item, sites, directives, purity, proof) {
        Some(edit) => edits.push(edit)
        None => ()
      }
    }
  }
  let normalized = normalize_edits(edits)
  let problems = verify(file.path, file.source, normalized)
  if problems.length() > 0 {
    for problem in problems {
      proof.push(file.path + ": verification: " + problem)
    }
    proof.push(
      file.path +
      ": dropped all " +
      normalized.length().to_string() +
      " edit(s): the removal would leave new findings",
    )
    return RemovalPlan::{ edits: [], proof }
  }
  if normalized.length() > 0 {
    proof.push(
      file.path +
      ": " +
      normalized.length().to_string() +
      " edit(s) accepted after re-analysis",
    )
  }
  RemovalPlan::{ edits: normalized, proof }
}

///|
fn plan_package_inner(
  files : Array[SourceFile],
  entries : Array[String],
  only : String?,
) -> RemovalPlan {
  let ordered : Array[SourceFile] = []
  for file in files {
    ordered.push(file)
  }
  ordered.sort_by(fn(a, b) { a.path.lexical_compare(b.path) })
  let proof : Array[String] = []
  let edits : Array[Edit] = []
  if ordered.length() == 0 {
    proof.push("no files to analyse")
    return RemovalPlan::{ edits, proof }
  }
  let facts : Array[@liveness.FileFacts] = []
  for file in ordered {
    facts.push(@liveness.collect(file.path, file.source))
  }
  let reach = @roots.analyze(facts, entries~)
  let purity = purity_index(facts)
  proof.push(
    "analysed " +
    ordered.length().to_string() +
    " file(s), " +
    reach.functions.to_string() +
    " declaration(s), " +
    reach.roots.length().to_string() +
    " root(s)",
  )
  for file in ordered {
    let wanted = match only {
      None => true
      Some(path) => path == file.path
    }
    if wanted {
      let one = plan_one(file, reach, purity)
      for edit in one.edits {
        edits.push(edit)
      }
      for line in one.proof {
        proof.push(line)
      }
    }
  }
  RemovalPlan::{ edits: normalize_edits(edits), proof }
}

///|
/// Plan removals for one package. `files` must be every `.mbt` file of the
/// package — tests included — because reachability is a package question.
pub fn plan_package(
  files : Array[SourceFile],
  entries? : Array[String] = [],
) -> RemovalPlan {
  plan_package_inner(files, entries, None)
}

///|
/// Plan removals for one file, using the rest of its package only as context.
/// Edits are restricted to `target`; the reachability and purity answers still
/// come from the whole package, which is the scope a private function lives in.
pub fn plan_file(
  target : SourceFile,
  package_files : Array[SourceFile],
  entries? : Array[String] = [],
) -> RemovalPlan {
  let files : Array[SourceFile] = []
  for file in package_files {
    if file.path != target.path {
      files.push(file)
    }
  }
  files.push(target)
  plan_package_inner(files, entries, Some(target.path))
}
