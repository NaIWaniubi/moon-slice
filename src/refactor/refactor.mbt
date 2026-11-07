// Dead-code removal planning: from findings to edits, with a proof.
//
// The analysis packages answer "what is dead"; this one answers "what may be
// deleted, and why is that safe". It is deliberately the most conservative
// package in the tree, because an edit here changes the user's source:
//
//   * a statement is removed only when it is a `let` binding whose variables
//     are never read and never redefined, and whose initializer is pure;
//   * a function is removed only when `src/roots` proves it unreachable from
//     every package root *and* `src/sidefx` proves its body effect-free. The
//     package must also have no unresolved call boundary at all: a call the
//     graph could not attribute could reach any private function, so with one
//     present no function is removed (bindings can still go);
//   * a `// moon-slice: ignore` directive always wins;
//   * a public declaration is never removed;
//   * after the edits are computed they are applied in memory and both the
//     statement analysis and the package reachability run again; a single new
//     finding undoes the whole plan for that file.
//
// Removal ranges are statement-precise. A `let` or a `fn` span comes from the
// AST (line and byte column), so when two statements share a line only the
// target text is deleted. A range whose boundaries already sit on the line's
// first and last code character is widened to the whole line, which is what
// makes the common case a clean line deletion including its newline.
//
// Purity is checked twice on purpose. `src/sidefx` summarises the expression or
// body (IO names, field writes, receiver mutation, raise, recursion). On top of
// that every call must resolve to a single pure declaration of the package:
//
//   * a free call (`f(x)`) must name one pure free function;
//   * `T::m(x)` must name one pure method of `T`;
//   * a dot call (`x.m()`) is resolved through `@parser_adapter.call_facts`,
//     which types the receiver from what the source writes down. A method name
//     on its own is never enough: `x.m()` where `x`'s type is unknown is a call
//     whose effects cannot be ruled out.
//
// The result is a `RemovalPlan`: line/column edits plus the human-readable
// proof trail that explains every accepted and every rejected candidate.
// Rendering that plan as a unified diff is also here, so the CLI only wires
// flags to it.

///|
/// One source file of a package, as the planner sees it.
pub(all) struct SourceFile {
  path : String
  source : String
}

///|
/// One source range to delete. Lines are 1-based; columns are 1-based byte
/// offsets into the line and the end is exclusive, the same convention the
/// parser's `Loc` uses.
///
/// `end_col == 0` marks a whole-line edit: the lines `start_line..end_line`
/// are removed together with their newlines. `start_col` is then 1.
pub(all) struct Edit {
  file : String
  start_line : Int32
  start_col : Int32
  end_line : Int32
  end_col : Int32
  /// Why the removal is safe, in one sentence.
  reason : String
}

///|
/// A whole-line edit, the common case. Kept as a constructor so callers and
/// tests do not repeat the column convention.
pub fn Edit::lines(
  file : String,
  start_line : Int32,
  end_line : Int32,
  reason : String,
) -> Edit {
  Edit::{
    file,
    start_line,
    start_col: 1,
    end_line,
    end_col: 0,
    reason,
  }
}

///|
/// What `fix` would do, plus the reasoning behind it.
pub(all) struct RemovalPlan {
  /// Non-overlapping, sorted by file and position.
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
fn clamp(value : Int32, low : Int32, high : Int32) -> Int32 {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
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
fn joined_text(lines : Array[String]) -> String {
  if lines.length() == 0 {
    return ""
  }
  let out = StringBuilder()
  for line in lines {
    out.write_string(line)
    out.write_char('\n')
  }
  out.to_string()
}

///|
/// The 1-based byte column as a 0-based string offset, clamped to the text.
fn col_offset(text : String, column : Int32) -> Int {
  let offset = if column < 1 { 0 } else { column - 1 }
  if offset > text.length() {
    text.length()
  } else {
    offset
  }
}

///|
fn line_prefix(text : String, column : Int32) -> String {
  text[:col_offset(text, column)].to_owned()
}

///|
fn line_suffix(text : String, column : Int32) -> String {
  text[col_offset(text, column):].to_owned()
}

///|
/// Absolute byte offset of a (line, column) position in the canonical text
/// (`lines.join("\n") + "\n"`).
fn absolute_offset(
  lines : Array[String],
  line : Int32,
  column : Int32,
) -> Int {
  let target = clamp(line, 1, lines.length() + 1)
  let mut offset = 0
  let mut i = 0
  while i < target - 1 && i < lines.length() {
    offset = offset + lines[i].length() + 1
    i = i + 1
  }
  if target > lines.length() {
    offset
  } else {
    offset + col_offset(lines[target - 1], column)
  }
}

///|
/// The absolute `[start, end)` byte range an edit removes.
fn edit_range(lines : Array[String], edit : Edit) -> (Int, Int) {
  let count = lines.length()
  let start_line = clamp(edit.start_line, 1, count)
  let start = absolute_offset(lines, start_line, edit.start_col)
  if edit.end_col == 0 {
    let end_line = clamp(edit.end_line, start_line, count)
    let end = if end_line >= count {
      joined_text(lines).length()
    } else {
      absolute_offset(lines, end_line + 1, 1)
    }
    (start, end)
  } else {
    let end_line = clamp(edit.end_line, start_line, count)
    (start, absolute_offset(lines, end_line, edit.end_col))
  }
}

///|
/// The source with every edited range removed. For a precise edit the
/// surrounding text of the line is kept, so two statements on one line do not
/// take each other out. Line endings normalise to LF and the result ends with a
/// newline; the CLI writes exactly this text under `--write`.
pub fn apply_edits(source : String, edits : Array[Edit]) -> String {
  let lines = source_lines(source)
  let mut text = joined_text(lines)
  // Right to left so earlier offsets stay valid.
  let ranges : Array[(Int, Int)] = []
  for edit in edits {
    let (start, end) = edit_range(lines, edit)
    ranges.push((start, end))
  }
  ranges.sort_by(fn(a, b) {
    if a.0 > b.0 {
      -1
    } else if a.0 < b.0 {
      1
    } else if a.1 > b.1 {
      -1
    } else if a.1 < b.1 {
      1
    } else {
      0
    }
  })
  let mut ceiling = text.length()
  for range in ranges {
    let start = range.0
    let end = if range.1 > ceiling { ceiling } else { range.1 }
    if start < end && end <= ceiling {
      text = text[:start].to_owned() + text[end:].to_owned()
      ceiling = start
    }
  }
  text
}

///|
/// The lines an edit removes entirely and the lines it rewrites in place.
priv struct LineOps {
  removed : Set[Int]
  replaced : Map[Int, String]
}

///|
fn line_ops(source : String, edits : Array[Edit]) -> LineOps {
  let lines = source_lines(source)
  let removed : Set[Int] = Set([])
  let replaced : Map[Int, String] = Map([])
  let spans : Map[Int, Array[(Int32, Int32)]] = Map([])
  let count = lines.length()
  if count == 0 {
    return LineOps::{ removed, replaced }
  }
  for edit in edits {
    let start = clamp(edit.start_line, 1, count)
    let end = clamp(edit.end_line, start, count)
    if edit.end_col == 0 {
      let mut line = start
      while line <= end {
        removed.add(line)
        line = line + 1
      }
    } else if start == end {
      let list = match spans.get(start) {
        Some(found) => found
        None => {
          let fresh : Array[(Int32, Int32)] = []
          spans.set(start, fresh)
          fresh
        }
      }
      list.push((edit.start_col, edit.end_col))
    } else {
      // A multi-line statement: the first and last line survive around it.
      replaced.set(
        start,
        line_prefix(lines[start - 1], edit.start_col) +
        line_suffix(lines[end - 1], edit.end_col),
      )
      let mut line = start + 1
      while line <= end {
        removed.add(line)
        line = line + 1
      }
    }
  }
  for pair in spans.to_array() {
    let line = pair.0
    let list = pair.1
    let sorted = list.copy()
    sorted.sort_by(fn(a, b) {
      if a.0 > b.0 {
        -1
      } else if a.0 < b.0 {
        1
      } else {
        0
      }
    })
    let mut text = lines[line - 1]
    for span in sorted {
      text = line_prefix(text, span.0) + line_suffix(text, span.1)
    }
    replaced.set(line, text)
  }
  LineOps::{ removed, replaced }
}

///|
/// Every line number an edit removes entirely (not the lines it rewrites).
fn removed_lines(edits : Array[Edit]) -> Set[Int] {
  let out : Set[Int] = Set([])
  for edit in edits {
    if edit.end_col == 0 {
      let mut line = if edit.start_line < 1 { 1 } else { edit.start_line }
      while line <= edit.end_line {
        out.add(line)
        line = line + 1
      }
    }
  }
  out
}

///|
fn starts_before(a : Edit, b : Edit) -> Bool {
  a.start_line < b.start_line ||
  (a.start_line == b.start_line && a.start_col <= b.start_col)
}

///|
fn ends_after(a : Edit, b : Edit) -> Bool {
  if a.end_col == 0 {
    b.end_line <= a.end_line
  } else if b.end_col == 0 {
    false
  } else {
    b.end_line < a.end_line ||
    (b.end_line == a.end_line && b.end_col <= a.end_col)
  }
}

///|
/// Sort edits by file and position, then drop any edit contained in an earlier
/// one. Containment is real: a dead binding inside an unreachable function
/// would otherwise be deleted twice.
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
    } else if a.start_col < b.start_col {
      -1
    } else if a.start_col > b.start_col {
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
        starts_before(existing, edit) &&
        ends_after(existing, edit) {
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
/// Render the plan as a unified diff against `source`, three lines of context.
/// Whole-line edits appear as deletions; precise edits appear as a rewritten
/// line (`-old` / `+new`). An empty string means there is nothing to change.
pub fn to_unified_diff(file : String, source : String, edits : Array[Edit]) -> String {
  let lines = source_lines(source)
  let count = lines.length()
  let ops = line_ops(source, edits)
  let changed : Set[Int] = Set([])
  for line in ops.removed.to_array() {
    changed.add(line)
  }
  for pair in ops.replaced.to_array() {
    changed.add(pair.0)
  }
  if count == 0 || changed.length() == 0 {
    return ""
  }
  let groups : Array[(Int, Int)] = []
  let mut i = 1
  while i <= count {
    if changed.contains(i) {
      let start = i
      let mut end = i
      while end + 1 <= count && changed.contains(end + 1) {
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
      if !ops.removed.contains(line) {
        kept_before = kept_before + 1
      }
      line = line + 1
    }
    let mut removed_count = 0
    line = old_start
    while line <= old_end {
      if ops.removed.contains(line) {
        removed_count = removed_count + 1
      }
      line = line + 1
    }
    let new_count = old_count - removed_count
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
      if changed.contains(line) {
        let block_start = line
        let mut block_end = line
        while block_end + 1 <= old_end && changed.contains(block_end + 1) {
          block_end = block_end + 1
        }
        let mut cursor = block_start
        while cursor <= block_end {
          out.write_char('-')
          out.write_string(lines[cursor - 1])
          out.write_char('\n')
          cursor = cursor + 1
        }
        cursor = block_start
        while cursor <= block_end {
          match ops.replaced.get(cursor) {
            Some(text) => {
              out.write_char('+')
              out.write_string(text)
              out.write_char('\n')
            }
            None => ()
          }
          cursor = cursor + 1
        }
        line = block_end + 1
      } else {
        out.write_char(' ')
        out.write_string(lines[line - 1])
        out.write_char('\n')
        line = line + 1
      }
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
    out.write_string(",\"start_col\":")
    out.write_string(edit.start_col.to_string())
    out.write_string(",\"end_line\":")
    out.write_string(edit.end_line.to_string())
    out.write_string(",\"end_col\":")
    out.write_string(edit.end_col.to_string())
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
  start_col : Int32
  end_line : Int32
  end_col : Int32
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
fn end_position(
  loc_line : Int32,
  loc_col : Int32,
  body : @syntax.Expr?,
) -> (Int32, Int32) {
  let mut line = loc_line
  let mut col = loc_col
  match body {
    Some(expr) =>
      match expr {
        @syntax.Expr::StaticAssert(..) => ()
        _ => {
          let body_loc = (expr : @syntax.Expr).loc()
          if body_loc.end.lnum > line {
            line = body_loc.end.lnum
            col = body_loc.end.column()
          } else if body_loc.end.lnum == line && body_loc.end.column() > col {
            col = body_loc.end.column()
          }
        }
      }
    None => ()
  }
  (line, col)
}

///|
/// Every free function and inherent/trait method with a body, with the exact
/// source span the declaration occupies. The span is what an edit removes.
fn decl_sites(source : String, path : String) -> Array[DeclSite] {
  let (items, _reports) = @parser.parse_string(source, name=path)
  let out : Array[DeclSite] = []
  items.each(fn(item) {
    match item {
      @syntax.Impl::TopFuncDef(fun_decl=decl, decl_body=decl_body, loc~, ..) => {
        let body = body_of(decl_body)
        let (end_line, end_col) = end_position(loc.end.lnum, loc.end.column(), body)
        out.push(DeclSite::{
          name: decl.name.name,
          line: decl.name.loc.start.lnum,
          start_col: loc.start.column(),
          end_line,
          end_col,
          exported: is_exported(decl.vis),
          body,
        })
      }
      @syntax.Impl::TopImpl(method_name~, vis~, body~, loc~, ..) => {
        let body_expr = body_of(body)
        let (end_line, end_col) = end_position(loc.end.lnum, loc.end.column(), body_expr)
        out.push(DeclSite::{
          name: method_name.name,
          line: method_name.loc.start.lnum,
          start_col: loc.start.column(),
          end_line,
          end_col,
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
/// Build an edit for a span, widening it to whole lines when the span already
/// covers the code on its boundary lines. That keeps the common case a clean
/// line deletion and still removes only the target when other code shares a
/// line.
fn make_span(
  file : String,
  source : String,
  start_line : Int32,
  start_col : Int32,
  end_line : Int32,
  end_col : Int32,
  reason : String,
) -> Edit {
  let lines = source_lines(source)
  let valid = start_line >= 1 &&
    start_line <= lines.length() &&
    end_line >= start_line &&
    end_line <= lines.length()
  if !valid || start_col < 1 || end_col < 1 {
    return Edit::lines(file, start_line, end_line, reason)
  }
  // A statement can share its line with others separated by `;`. The AST span
  // stops at the statement, so an adjacent separator would be left dangling
  // (`  ; let b = 2`) and the edited file would not parse. Pull the span over
  // the separator on either side when one is present.
  let start_text = lines[start_line - 1]
  let end_text = lines[end_line - 1]
  let mut start = start_col
  let mut end = end_col
  let before = line_prefix(start_text, start)
  let before_trimmed = before.trim_end()
  if before_trimmed.has_suffix(";") {
    start = before_trimmed.length().to_int64().to_int()
  }
  let after = line_suffix(end_text, end)
  let after_trimmed = after.trim_start()
  if after_trimmed.has_prefix(";") {
    let spaces_before = after.length() - after_trimmed.length()
    let tail = after_trimmed[1:].to_owned()
    let spaces_after = tail.length() - tail.trim_start().length()
    end = end + (spaces_before + 1 + spaces_after)
  }
  let prefix = line_prefix(start_text, start)
  let suffix = line_suffix(end_text, end)
  if prefix.trim().is_empty() && suffix.trim().is_empty() {
    Edit::lines(file, start_line, end_line, reason)
  } else {
    Edit::{
      file,
      start_line,
      start_col: start,
      end_line,
      end_col: end,
      reason,
    }
  }
}

///|
/// Which package functions are "known pure". A name declared more than once is
/// never trusted: the summary cannot say which declaration a call means.
priv struct PurityIndex {
  counts : Map[String, Int]
  free_counts : Map[String, Int]
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
/// A free call may only target a free function, not a method.
fn PurityIndex::is_pure_free(self : PurityIndex, name : String) -> Bool {
  if !self.is_pure(name) {
    return false
  }
  match self.free_counts.get(name) {
    Some(count) => count == 1
    None => false
  }
}

///|
/// Resolved receiver calls and method declarations of the package. `receivers`
/// answers "what type was written for this dot call", which is what makes a
/// method call checkable instead of a name guess.
priv struct CallContext {
  /// caller function name -> resolved receiver calls in that body.
  receivers : Map[String, Array[@parser_adapter.ReceiverCall]]
  /// method name -> every declaration of that name, with its owner.
  methods : Map[String, Array[(String, Int32)]]
}

///|
fn CallContext::method_owner(self : CallContext, name : String) -> String? {
  match self.methods.get(name) {
    None => None
    Some(decls) =>
      if decls.length() == 1 {
        Some(decls[0].0)
      } else {
        None
      }
  }
}

///|
/// `T::m(...)`: the owner is written, the method must be the single pure
/// declaration of that name and belong to `owner`.
fn CallContext::is_pure_method(
  self : CallContext,
  purity : PurityIndex,
  owner : String,
  name : String,
) -> Bool {
  if !purity.is_pure(name) {
    return false
  }
  match self.method_owner(name) {
    Some(declared) => declared == owner
    None => false
  }
}

///|
fn purity_index(facts : Array[@liveness.FileFacts]) -> PurityIndex {
  let counts : Map[String, Int] = Map([])
  let free_counts : Map[String, Int] = Map([])
  let batch : Array[@sidefx.FnSource] = []
  for file in facts {
    for decl in file.decls {
      if decl.has_body {
        let next = match counts.get(decl.name) {
          Some(count) => count + 1
          None => 1
        }
        counts.set(decl.name, next)
        if !decl.is_method {
          let free_next = match free_counts.get(decl.name) {
            Some(count) => count + 1
            None => 1
          }
          free_counts.set(decl.name, free_next)
        }
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
  PurityIndex::{ counts, free_counts, pure }
}

///|
fn call_context(facts : Array[@liveness.FileFacts]) -> CallContext {
  let receivers : Map[String, Array[@parser_adapter.ReceiverCall]] = Map([])
  let methods : Map[String, Array[(String, Int32)]] = Map([])
  for file in facts {
    let found = @parser_adapter.call_facts(file.source, file.path)
    for call in found.receivers {
      let list = match receivers.get(call.caller) {
        Some(list) => list
        None => {
          let fresh : Array[@parser_adapter.ReceiverCall] = []
          receivers.set(call.caller, fresh)
          fresh
        }
      }
      list.push(call)
    }
    for declared in found.methods {
      let list = match methods.get(declared.name) {
        Some(list) => list
        None => {
          let fresh : Array[(String, Int32)] = []
          methods.set(declared.name, fresh)
          fresh
        }
      }
      list.push((declared.owner, declared.line))
    }
  }
  CallContext::{ receivers, methods }
}

///|
/// Collects calls the planner cannot prove harmless: a package-qualified call
/// (`@pkg.f`), a call through an expression, a free call that is not a single
/// pure free function, an explicit method call whose owner does not declare
/// it, and a dot call whose receiver type the source does not state.
priv struct CallAudit {
  purity : PurityIndex
  context : CallContext
  /// Function whose body is being audited; matches `ReceiverCall.caller`.
  caller : String
  /// Line range of the audited text in the original file, for receiver lookup.
  start_line : Int32
  end_line : Int32
  problems : Array[String]
  /// Dot calls seen, by method name. Resolution happens after the walk.
  dots : Map[String, Int]
}

///|
extend CallAudit with @syntax.IterVisitor::{ base }

///|
fn CallAudit::note(self : CallAudit, name : String) -> Unit {
  if !self.problems.contains(name) {
    self.problems.push(name)
  }
}

///|
fn CallAudit::finish(self : CallAudit) -> Unit {
  for pair in self.dots.to_array() {
    let name = pair.0
    let seen = pair.1
    let mut resolved = 0
    match self.context.receivers.get(self.caller) {
      Some(calls) =>
        for call in calls {
          if call.method_name == name &&
            call.line >= self.start_line &&
            call.line <= self.end_line {
            resolved = resolved + 1
            if !self.context.is_pure_method(self.purity, call.receiver_type, name) {
              self.note(name)
            }
          }
        }
      None => ()
    }
    if resolved < seen {
      // A dot call exists that no receiver type resolved (or it is on a
      // receiver whose type the source never writes down).
      self.note(name)
    }
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
        @syntax.LongIdent::Ident(name~) =>
          if !env.purity.is_pure_free(name) {
            env.note(name)
          }
        @syntax.LongIdent::Dot(pkg~, id~) =>
          env.note("@" + pkg + "." + id)
      }
    @syntax.Expr::Method(type_name~, method_name~, ..) => {
      let owner = short_type_name(type_name.name)
      if !env.context.is_pure_method(env.purity, owner, method_name.name) {
        env.note(method_name.name)
      }
    }
    @syntax.Expr::Group(expr~, ..) =>
      match expr {
        @syntax.Expr::Ident(id~, ..) =>
          match id.name {
            @syntax.LongIdent::Ident(name~) =>
              if !env.purity.is_pure_free(name) {
                env.note(name)
              }
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
/// A dot call records its name; `finish` resolves it through the package's
/// receiver table, so a bare method-name match never decides purity.
impl @syntax.IterVisitor for CallAudit with fn visit_Expr_DotApply(
  env,
  self~,
  method_name~,
  args~,
  return_self~,
  loc~,
) {
  let seen = match env.dots.get(method_name.name) {
    Some(count) => count + 1
    None => 1
  }
  env.dots.set(method_name.name, seen)
  @syntax.IterVisitor::visit_Expr_DotApply(
    env.base(), self~, method_name~, args~, return_self~, loc~,
  )
}

///|
/// `T::m(...)` is an explicit method reference.
impl @syntax.IterVisitor for CallAudit with fn visit_Expr_Method(
  env,
  type_name~,
  method_name~,
  loc~,
) {
  let owner = short_type_name(type_name.name)
  if !env.context.is_pure_method(env.purity, owner, method_name.name) {
    env.note(method_name.name)
  }
  @syntax.IterVisitor::visit_Expr_Method(env.base(), type_name~, method_name~, loc~)
}

///|
fn short_type_name(name : @syntax.LongIdent) -> String {
  match name {
    @syntax.LongIdent::Ident(name~) => name
    @syntax.LongIdent::Dot(id~, ..) => id
  }
}

///|
fn audit_calls(
  expr : @syntax.Expr,
  purity : PurityIndex,
  context : CallContext,
  caller : String,
  start_line : Int32,
  end_line : Int32,
) -> Array[String] {
  let audit : CallAudit = {
    purity,
    context,
    caller,
    start_line,
    end_line,
    problems: [],
    dots: Map([]),
  }
  @syntax.IterVisitor::visit_Expr(audit, expr)
  audit.finish()
  audit.problems
}

///|
fn audit_source(
  source : String,
  purity : PurityIndex,
  context : CallContext,
  caller : String,
  start_line : Int32,
  end_line : Int32,
) -> Array[String] {
  let sites = decl_sites(source, "<probe>")
  if sites.length() != 1 {
    return ["<unparsed initializer>"]
  }
  match sites[0].body {
    None => ["<unparsed initializer>"]
    Some(body) => audit_calls(body, purity, context, caller, start_line, end_line)
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
/// the planner refuses to delete the binding. `caller` and the line span come
/// from the original file: the synthetic probe cannot type a receiver, so the
/// receiver table of the enclosing function is what resolves a dot call.
fn rhs_purity(
  rhs : String,
  purity : PurityIndex,
  context : CallContext,
  caller : String,
  start_line : Int32,
  end_line : Int32,
) -> String? {
  let probe = "fn " + PROBE_NAME + "() -> Unit {\n" + rhs + "\n}\n"
  match @sidefx.summarize_source(probe, PROBE_NAME) {
    None => Some("the initializer does not parse as an expression")
    Some(effects) =>
      if !effects.pure {
        Some(describe_impurity(effects))
      } else {
        let unresolved = audit_source(
          probe, purity, context, caller, start_line, end_line,
        )
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
/// Exact source text of a span (line/column, end exclusive).
fn span_text(
  source : String,
  start_line : Int32,
  start_col : Int32,
  end_line : Int32,
  end_col : Int32,
) -> String {
  let lines = source_lines(source)
  if start_line < 1 || start_line > lines.length() || end_line < start_line {
    return ""
  }
  let last = if end_line > lines.length() { lines.length() } else { end_line }
  if start_line == last {
    return line_prefix(
      line_suffix(lines[start_line - 1], start_col),
      if end_col < start_col {
        start_col
      } else {
        end_col - start_col + 1
      },
    )
  }
  let out = StringBuilder()
  out.write_string(line_suffix(lines[start_line - 1], start_col))
  let mut line = start_line + 1
  while line < last {
    out.write_char('\n')
    out.write_string(lines[line - 1])
    line = line + 1
  }
  out.write_char('\n')
  out.write_string(line_prefix(lines[last - 1], end_col))
  out.to_string()
}

///|
/// Finds the initializer expression of the `let`/`let mut` whose statement
/// starts at the given position.
priv struct LetInitFinder {
  line : Int32
  col : Int32
  found : Array[@syntax.Expr]
}

///|
extend LetInitFinder with @syntax.IterVisitor::{ base }

///|
fn LetInitFinder::record(
  self : LetInitFinder,
  expr : @syntax.Expr,
  line : Int32,
  col : Int32,
) -> Unit {
  if self.found.length() == 0 && line == self.line && col == self.col {
    self.found.push(expr)
  }
}

///|
impl @syntax.IterVisitor for LetInitFinder with fn visit_Expr_Let(
  self,
  pattern~,
  expr~,
  body~,
  loc~,
) {
  self.record(expr, loc.start.lnum, loc.start.column())
  @syntax.IterVisitor::visit_Expr_Let(self.base(), pattern~, expr~, body~, loc~)
}

///|
impl @syntax.IterVisitor for LetInitFinder with fn visit_Expr_LetMut(
  self,
  binder~,
  ty~,
  expr~,
  body~,
  loc~,
) {
  self.record(expr, loc.start.lnum, loc.start.column())
  @syntax.IterVisitor::visit_Expr_LetMut(
    self.base(), binder~, ty~, expr~, body~, loc~,
  )
}

///|
fn find_let_init(
  source : String,
  path : String,
  line : Int32,
  col : Int32,
) -> @syntax.Expr? {
  let (items, _reports) = @parser.parse_string(source, name=path)
  let finder : LetInitFinder = { line, col, found: [] }
  items.each(fn(item) {
    match item {
      @syntax.Impl::TopFuncDef(decl_body=body, ..) =>
        match body {
          @syntax.DeclBody::DeclBody(expr~) =>
            @syntax.IterVisitor::visit_Expr(finder, expr)
          _ => ()
        }
      @syntax.Impl::TopImpl(body~, ..) =>
        match body {
          @syntax.DeclBody::DeclBody(expr~) =>
            @syntax.IterVisitor::visit_Expr(finder, expr)
          _ => ()
        }
      @syntax.Impl::TopExpr(expr~, ..) =>
        @syntax.IterVisitor::visit_Expr(finder, expr)
      @syntax.Impl::TopTest(expr~, ..) =>
        @syntax.IterVisitor::visit_Expr(finder, expr)
      @syntax.Impl::TopView(body~, ..) =>
        @syntax.IterVisitor::visit_Expr(finder, body)
      @syntax.Impl::TopLetDef(expr~, ..) =>
        @syntax.IterVisitor::visit_Expr(finder, expr)
      _ => ()
    }
  })
  if finder.found.length() > 0 {
    Some(finder.found[0])
  } else {
    None
  }
}

///|
/// The initializer text of a `let`/`let mut` statement, taken from the AST span
/// of the initializer expression. Using the AST (not the rest of the line)
/// keeps a second statement on the same line out of the probe.
fn binding_rhs(
  source : String,
  path : String,
  node : @core.SNode,
) -> String? {
  match find_let_init(source, path, node.loc.start_line, node.loc.start_col) {
    None => None
    Some(expr) => {
      let loc = (expr : @syntax.Expr).loc()
      Some(
        span_text(
          source,
          loc.start.lnum,
          loc.start.column(),
          loc.end.lnum,
          loc.end.column(),
        ),
      )
    }
  }
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
/// The function a node belongs to, by node-id range.
fn enclosing_function(program : @core.Program, node : @core.SNode) -> String {
  for function in program.functions {
    if node.id > function.entry && node.id < function.exit {
      return function.name
    }
  }
  ""
}

///|
fn binding_edit(
  program : @core.Program,
  node : @core.SNode,
  file : SourceFile,
  directives : @suppress.Directives,
  purity : PurityIndex,
  context : CallContext,
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
  let rhs = match binding_rhs(file.source, file.path, node) {
    None => {
      proof.push(
        location + ": kept dead binding `" + label + "`: the initializer could not be read",
      )
      return None
    }
    Some(rhs) => rhs
  }
  let caller = enclosing_function(program, node)
  match rhs_purity(
    rhs,
    purity,
    context,
    caller,
    node.loc.start_line,
    node.loc.end_line,
  ) {
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
      Some(
        make_span(
          file.path,
          file.source,
          node.loc.start_line,
          node.loc.start_col,
          node.loc.end_line,
          node.loc.end_col,
          "unused binding `" +
          label +
          "`: the initializer is pure and nothing reads the variable",
        ),
      )
    }
  }
}

///|
fn function_edit(
  item : @roots.UnreachableFn,
  sites : Array[DeclSite],
  file : SourceFile,
  directives : @suppress.Directives,
  purity : PurityIndex,
  context : CallContext,
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
      let unresolved = audit_calls(
        body,
        purity,
        context,
        item.name,
        declared.line,
        declared.end_line,
      )
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
        Some(
          make_span(
            item.path,
            file.source,
            declared.line,
            declared.start_col,
            declared.end_line,
            declared.end_col,
            "unreachable private function `" +
            item.name +
            "`: no path from any package root and no side effects",
          ),
        )
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
  let unreachable_findings = @query.unreachable_nodes(program, cfg)
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
  for id in unreachable_findings {
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
/// The line an old line maps to once the edited lines are removed, or -1 when
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
fn package_reachability(files : Array[SourceFile]) -> @roots.Reachability {
  let facts : Array[@liveness.FileFacts] = []
  for file in files {
    facts.push(@liveness.collect(file.path, file.source))
  }
  @roots.analyze(facts)
}

///|
fn with_source(
  files : Array[SourceFile],
  path : String,
  source : String,
) -> Array[SourceFile] {
  let out : Array[SourceFile] = []
  let mut found = false
  for file in files {
    if file.path == path {
      out.push(SourceFile::{ path, source })
      found = true
    } else {
      out.push(file)
    }
  }
  if !found {
    out.push(SourceFile::{ path, source })
  }
  out
}

///|
/// Re-analyse the edited source and the edited package and report anything the
/// removal made worse. Empty means the plan is safe to show or to write.
///
/// Two checks:
///   * statement findings (dead stores, unreachable statements) after the edit
///     must be exactly the old ones at their shifted lines;
///   * package reachability must not lose entries: a function that no root
///     reaches only because the edit removed its last mention is a new problem.
///
/// `reach_before` is the reachability of `package_files` before the edit, which
/// callers already computed.
fn verify_inner(
  file : String,
  original : String,
  edits : Array[Edit],
  reach_before : @roots.Reachability,
  package_files : Array[SourceFile],
) -> Array[String] {
  let problems : Array[String] = []
  if edits.length() == 0 {
    return problems
  }
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
  // Reachability: no function may become unreachable because of the edit.
  let before_names : Set[String] = Set([])
  for item in reach_before.unreachable_fns {
    before_names.add(item.name)
  }
  let after_reach = package_reachability(with_source(package_files, file, after))
  for item in after_reach.unreachable_fns {
    if !before_names.contains(item.name) {
      problems.push(
        "`" +
        item.name +
        "` at " +
        site(item.path, item.line) +
        " would become unreachable from every root",
      )
    }
  }
  // Statement findings: every finding still present must have been there
  // before, at the shifted line.
  let deleted = removed_lines(edits)
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
/// Re-analyse one file and its package after applying `edits`. This is the
/// public safety gate: it re-runs `src/roots` (not only the statement
/// analysis), so an edit that would orphan another function is rejected.
pub fn verify(
  file : String,
  original : String,
  edits : Array[Edit],
  package_files : Array[SourceFile],
) -> Array[String] {
  let before = package_reachability(with_source(package_files, file, original))
  verify_inner(file, original, edits, before, package_files)
}

///|
/// Turn a caller-computed dead-node set into binding edits. This is the
/// `Program` + node-ids entry point the pipeline uses internally and the one a
/// caller with its own analysis can drive directly.
fn add_binding_edits(
  program : @core.Program,
  dead : Array[Int32],
  file : SourceFile,
  directives : @suppress.Directives,
  purity : PurityIndex,
  context : CallContext,
  proof : Array[String],
  edits : Array[Edit],
) -> Unit {
  for id in dead {
    match @query.node_by_id(program, id) {
      None => ()
      Some(node) =>
        if node.kind == @core.SNodeKind::Let ||
          node.kind == @core.SNodeKind::LetMut {
          match binding_edit(
            program, node, file, directives, purity, context, proof,
          ) {
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
/// bindings of `file`. `package_files` supplies the purity closure and the
/// receiver types, so a call in an initializer is judged by the declaration it
/// actually reaches.
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
  let context = call_context(facts)
  let proof : Array[String] = []
  let edits : Array[Edit] = []
  add_binding_edits(program, dead, file, directives, purity, context, proof, edits)
  RemovalPlan::{ edits: normalize_edits(edits), proof }
}

///|
fn plan_one(
  file : SourceFile,
  package_files : Array[SourceFile],
  reach : @roots.Reachability,
  purity : PurityIndex,
  context : CallContext,
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
  add_binding_edits(
    program, dead, file, directives, purity, context, proof, edits,
  )
  // A boundary is a call the package graph could not attribute: a receiver
  // whose type is unknown, a call into another package, a call through an
  // expression. Any private function might be its target, so with one present
  // no function is removed at all.
  let boundaries = reach.boundaries
  if boundaries.length() > 0 {
    proof.push(
      file.path +
      ": function removal disabled: the package has " +
      boundaries.length().to_string() +
      " unresolved call site(s) that could reach a private function",
    )
    let mut shown = 0
    for boundary in boundaries {
      if shown < 10 {
        proof.push("  boundary: " + boundary)
        shown = shown + 1
      }
    }
    if boundaries.length() > shown {
      proof.push(
        "  ... and " +
        (boundaries.length() - shown).to_string() +
        " more boundary site(s)",
      )
    }
  } else {
    for item in reach.unreachable_fns {
      if item.path == file.path {
        match function_edit(
          item, sites, file, directives, purity, context, proof,
        ) {
          Some(edit) => edits.push(edit)
          None => ()
        }
      }
    }
  }
  let normalized = normalize_edits(edits)
  let problems = verify_inner(
    file.path, file.source, normalized, reach, package_files,
  )
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
  let context = call_context(facts)
  proof.push(
    "analysed " +
    ordered.length().to_string() +
    " file(s), " +
    reach.functions.to_string() +
    " declaration(s), " +
    reach.roots.length().to_string() +
    " root(s), " +
    reach.boundaries.length().to_string() +
    " unresolved call site(s)",
  )
  for file in ordered {
    let wanted = match only {
      None => true
      Some(path) => path == file.path
    }
    if wanted {
      let one = plan_one(file, ordered, reach, purity, context)
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
