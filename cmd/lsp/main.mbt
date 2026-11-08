// A minimal Language Server for MoonBit: dead stores and unreachable code as
// diagnostics, pushed on every open/change.
//
// The transport is LSP over stdio: `Content-Length` header lines, then a JSON
// body. `@stdio.stdin.read_until("\r\n")` gives one header line at a time and
// `read_exactly` gives the body, so the framing is handled by the async runtime
// rather than by a hand-rolled buffer.

///|
/// One document the editor has open, keyed by URI.
let documents : Map[String, String] = Map([])

///|
/// The facts from each directory's last package scan, so saving a file only
/// re-reads what changed.
let scan_cache : @scan.Cache = @scan.Cache::new()

///|
/// Reported in `serverInfo`. Kept in step with `moon.mod` by the release
/// checklist; the client test fails when the two disagree.
let lsp_version : String = "0.11.0"

///|
fn hex_char(value : Int) -> Char {
  if value < 10 {
    ('0'.to_int() + value).unsafe_to_char()
  } else {
    ('a'.to_int() + value - 10).unsafe_to_char()
  }
}

///|
fn json_escape(text : String) -> String {
  let out = StringBuilder()
  for ch in text.iter() {
    match ch {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      _ => {
        let code = ch.to_int()
        if code < 32 {
          out.write_string("\\u00")
          out.write_char(hex_char((code / 16) % 16))
          out.write_char(hex_char(code % 16))
        } else {
          out.write_char(ch)
        }
      }
    }
  }
  out.to_string()
}

///|
fn json_string(text : String) -> String {
  "\"" + json_escape(text) + "\""
}

///|
async fn send(payload : String) -> Unit {
  let bytes = @utf8.encode(payload)
  @stdio.stdout.write("Content-Length: " + bytes.length().to_string() + "\r\n\r\n")
  @stdio.stdout.write(bytes)
}

///|
async fn send_response(id : String, result : String) -> Unit {
  send(
    "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":" + result + "}",
  )
}

///|
fn parse_content_length(line : String) -> Int {
  let mut value = 0
  let mut seen = false
  for ch in line.iter() {
    let code = ch.to_int()
    if code >= '0'.to_int() && code <= '9'.to_int() {
      value = value * 10 + (code - '0'.to_int())
      seen = true
    }
  }
  if seen { value } else { -1 }
}

///|
/// Read one framed message, or `None` when the editor closed the stream.
async fn read_message() -> String? {
  let mut length = -1
  while true {
    let line = match @stdio.stdin.read_until("\r\n") {
      None => return None
      Some(line) => line
    }
    if line == "" {
      break
    }
    if line.has_prefix("Content-Length:") {
      length = parse_content_length(line)
    }
  }
  if length < 0 {
    return None
  }
  let body = @stdio.stdin.read_exactly(length)
  Some(@utf8.decode_lossy(body))
}

///|
/// One finding at a line, ready to be turned into a diagnostic.
struct Finding {
  line : Int32
  start_col : Int32
  end_col : Int32
  rule : String
  message : String
}

///|
fn findings_for(source : String, uri : String) -> Array[Finding] {
  let out : Array[Finding] = []
  let program = @parser_adapter.parse_source(source, uri)
  if program.errors.length() > 0 {
    // A file that does not parse gets one diagnostic per parser report; the
    // report text already carries the line, so it is shown as the message.
    for error in program.errors {
      out.push(Finding::{
        line: 1,
        start_col: 0,
        end_col: 0,
        rule: "parse-error",
        message: error,
      })
    }
    return out
  }
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let dead = @query.dead_nodes(program, defuse)
  let unreached = @query.unreachable_nodes(program, cfg)
  let ids = @query.union_sorted(dead, unreached)
  for id in ids {
    match @query.node_by_id(program, id) {
      None => ()
      Some(node) => {
        let is_dead = dead.contains(id)
        out.push(Finding::{
          line: node.loc.start_line,
          start_col: node.loc.start_col,
          end_col: node.loc.end_col,
          rule: if is_dead { "dead-store" } else { "unreachable-code" },
          message: if is_dead {
            @report.sarif_dead_message(node)
          } else {
            "unreachable code: no execution path reaches this statement"
          },
        })
      }
    }
  }
  out
}

///|
fn finding_entry(finding : Finding) -> String {
  let line = if finding.line > 0 { finding.line - 1 } else { 0 }
  "{\"range\":{\"start\":{\"line\":" +
  line.to_string() +
  ",\"character\":" +
  finding.start_col.to_string() +
  "},\"end\":{\"line\":" +
  line.to_string() +
  ",\"character\":" +
  finding.end_col.to_string() +
  "}},\"severity\":" +
  (if finding.rule == "parse-error" { "1" } else { "2" }) +
  ",\"source\":\"moon-slice\",\"code\":" +
  json_string(finding.rule) +
  ",\"message\":" +
  json_string(finding.message) +
  "}"
}

///|
fn diagnostics_json(source : String, uri : String) -> String {
  let entries : Array[String] = []
  for finding in findings_for(source, uri) {
    entries.push(finding_entry(finding))
  }
  entries_json(entries)
}

///|
async fn publish(uri : String) -> Unit {
  let source = match documents.get(uri) {
    Some(text) => text
    None => ""
  }
  send(
    "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":" +
    json_string(uri) +
    ",\"diagnostics\":" +
    diagnostics_json(source, uri) +
    "}}",
  )
}

///|
/// Length of one 0-based line, without its line terminator.
fn line_length(source : String, line0 : Int) -> Int {
  let lines = source.split("\n").to_array()
  if line0 < 0 || line0 >= lines.length() {
    return 0
  }
  let mut text = lines[line0].to_owned()
  if text.has_suffix("\r") {
    text = text[: text.length() - 1].to_owned()
  }
  text.length()
}

///|
/// One comma-separated line list, used by both slice paragraphs.
fn append_lines(text : StringBuilder, lines : Array[Int32]) -> Unit {
  let mut first = true
  for line in lines {
    if !first {
      text.write_string(", ")
    }
    first = false
    text.write_string(line.to_string())
  }
}

///|
/// The name of the private function declared on `line1` (1-based), if the line
/// is a declaration. The file-local facts are enough for that question; the
/// package graph is only consulted once a name is in hand.
///
/// Methods are included: `src/roots` models inherent methods and trait impls
/// too, so the reachability claim it makes holds for them as well.
fn private_decl_at(source : String, path : String, line1 : Int) -> String? {
  let facts = @liveness.collect(path, source)
  for decl in facts.decls {
    if decl.line == line1 && !decl.exported && decl.has_body {
      return Some(decl.name)
    }
  }
  None
}

///|
/// `reachable; shortest chain: \`main\` (a.mbt:5) → \`helper\` (a.mbt:6)`.
fn live_chain_text(path : @roots.LivePath) -> String {
  let text = StringBuilder()
  let mut first = true
  for step in path.steps {
    if !first {
      text.write_string(" → ")
    }
    first = false
    text.write_string("`" + step.function_name + "`")
    if step.path != "" {
      text.write_string(" (" + step.path + ":" + step.line.to_string() + ")")
    }
  }
  text.to_string()
}

///|
/// The `explain_dead` evidence, rendered for a hover: the incoming-edge
/// evidence first (why nothing reaches it), then the scope the search covered,
/// so a reader can tell a real dead function from a hole in the analysis.
fn dead_evidence_text(dead : @roots.DeadExplanation) -> String {
  let text = StringBuilder()
  text.write_string("**liveness** — unreachable: `")
  text.write_string(dead.function_name)
  text.write_string("` is not reached from any root\n\n")
  for evidence in dead.evidence {
    text.write_string("- ")
    text.write_string(evidence)
    text.write_string("\n")
  }
  text.write_string("\nsearched ")
  text.write_string(dead.searched_files.to_string())
  text.write_string(" file(s), ")
  text.write_string(dead.searched_functions.to_string())
  text.write_string(" declaration(s); ")
  text.write_string(dead.root_summary.length().to_string())
  text.write_string(" root(s)")
  if dead.boundaries.length() > 0 {
    text.write_string(", ")
    text.write_string(dead.boundaries.length().to_string())
    text.write_string(" unresolved call site(s)")
  }
  text.to_string()
}

///|
/// The liveness paragraph for a declaration line, or `None` when the name is
/// not part of the package graph (a virtual buffer, a file outside the
/// directory). A claim is never invented for a name the graph did not see.
fn liveness_section(reach : @roots.Reachability, name : String) -> String? {
  match reach.dead_reason(name) {
    Some(dead) => Some(dead_evidence_text(dead))
    None =>
      match reach.live_path(name) {
        Some(live) =>
          Some(
            "**liveness** — reachable; shortest chain: " + live_chain_text(live),
          )
        None => None
      }
  }
}

///|
fn package_contains_facts_path(pkg : PackageFacts, path : String) -> Bool {
  pkg.paths.contains(path) || pkg.paths.contains("./" + path)
}

///|
/// Hover: the backward and forward slices for the line under the cursor, plus a
/// `liveness` paragraph when the line declares a private function. The
/// paragraphs about slices are unchanged; the liveness one is added after them
/// so an existing reader sees the same first lines.
async fn hover_result(uri : String, line0 : Int) -> String {
  // An editor normally opens the document before hovering, but a file only
  // present on disk (a sibling in the package) still gets an answer.
  let source = match documents.get(uri) {
    Some(text) => text
    None =>
      match uri_to_path(uri) {
        Some(path) =>
          match read_text(path) {
            Some(text) => text
            None => ""
          }
        None => ""
      }
  }
  let program = @parser_adapter.parse_source(source, uri)
  if program.errors.length() > 0 {
    return "null"
  }
  match @query.target_node(program, line0 + 1) {
    None => "null"
    Some(node) => {
      let cfg = @cfg.build(program)
      let defuse = @defuse.analyze(program, cfg)
      let cdg = @cdg.build(program, cfg)
      let pdg = @pdg.build(defuse, cdg)
      let backward = @slice.backward(pdg, node, program=program)
      let forward = @slice.forward(pdg, node, program=program)
      let text = StringBuilder()
      text.write_string("**backward slice** — ")
      text.write_string(backward.nodes.length().to_string())
      text.write_string(" statement(s) reach this line\n\nlines: ")
      append_lines(text, @query.visible_lines(program, backward.nodes))
      text.write_string("\n\n**forward slice** — ")
      text.write_string(forward.nodes.length().to_string())
      text.write_string(" statement(s) this line affects\n\nlines: ")
      append_lines(text, @query.visible_lines(program, forward.nodes))
      let path = match uri_to_path(uri) {
        Some(path) => path
        None => uri
      }
      match private_decl_at(source, path, line0 + 1) {
        Some(name) =>
          match collect_package(uri) {
            Some(pkg) =>
              // The graph only speaks for the files it read; a virtual buffer
              // is not part of the package and gets no liveness claim.
              if package_contains_facts_path(pkg, path) {
                match liveness_section(@roots.analyze(pkg.facts), name) {
                  Some(section) => {
                    text.write_string("\n\n")
                    text.write_string(section)
                  }
                  None => ()
                }
              }
            None => ()
          }
        None => ()
      }
      "{\"contents\":{\"kind\":\"markdown\",\"value\":" +
      json_string(text.to_string()) +
      "},\"range\":{\"start\":{\"line\":" +
      line0.to_string() +
      ",\"character\":0},\"end\":{\"line\":" +
      line0.to_string() +
      ",\"character\":0}}}"
    }
  }
}

///|
/// A quick fix that appends `// moon-slice: ignore[rule]` to the line, which is
/// the same directive the CLI honours.
fn code_actions_result(uri : String, line0 : Int, rule : String) -> String {
  let source = match documents.get(uri) {
    Some(text) => text
    None => ""
  }
  let column = line_length(source, line0)
  let insert = " // moon-slice: ignore[" + rule + "]"
  let title = "Suppress with // moon-slice: ignore[" + rule + "]"
  "[{\"title\":" +
  json_string(title) +
  ",\"kind\":\"quickfix\",\"edit\":{\"changes\":{" +
  json_string(uri) +
  ":[{\"range\":{\"start\":{\"line\":" +
  line0.to_string() +
  ",\"character\":" +
  column.to_string() +
  "},\"end\":{\"line\":" +
  line0.to_string() +
  ",\"character\":" +
  column.to_string() +
  "}},\"newText\":" +
  json_string(insert) +
  "}]}}}]"
}

///|
/// One `.mbt` file of the package, with the text to scan. An open editor buffer
/// wins over the copy on disk, so a definition of a not-yet-saved name is still
/// found.
struct SourceFile {
  uri : String
  path : String
  text : String
}

///|
/// A declaration the word scan recognised: a free function, a method, a `let`
/// binding, a struct/enum member, or a type. Columns are 0-based.
struct Declaration {
  name : String
  line : Int
  start_col : Int
  end_col : Int
}

///|
/// One open `{ ... }` block being scanned, so field lines remember whether they
/// sit in a `struct` or an `enum`.
struct BlockFrame {
  kind : String
  depth : Int
}

///|
fn ident_char(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
  (code >= '0'.to_int() && code <= '9'.to_int()) || ch == '_'
}

///|
fn ident_start_char(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= 'A'.to_int() && code <= 'Z'.to_int()) || ch == '_'
}

///|
fn string_chars(text : String) -> Array[Char] {
  let chars : Array[Char] = []
  for ch in text.iter() {
    chars.push(ch)
  }
  chars
}

///|
fn chars_range(chars : Array[Char], start : Int, end : Int) -> String {
  let out = StringBuilder()
  let mut i = start
  while i < end {
    out.write_char(chars[i])
    i = i + 1
  }
  out.to_string()
}

///|
/// `word` occurs at `start` as a whole word: the character after it is not part
/// of an identifier, so `fn` does not match `fnord`.
fn word_at_index(chars : Array[Char], start : Int, word : String) -> Bool {
  let length = word.length()
  if start < 0 || start + length > chars.length() {
    return false
  }
  let mut i = 0
  for ch in word.iter() {
    if chars[start + i] != ch {
      return false
    }
    i = i + 1
  }
  start + length >= chars.length() || !ident_char(chars[start + length])
}

///|
fn skip_spaces(chars : Array[Char], start : Int) -> Int {
  let mut i = start
  while i < chars.length() && (chars[i] == ' ' || chars[i] == '\t') {
    i = i + 1
  }
  i
}

///|
fn ident_end(chars : Array[Char], start : Int) -> Int {
  let mut i = start
  while i < chars.length() && ident_char(chars[i]) {
    i = i + 1
  }
  i
}

///|
fn push_declaration(
  out : Array[Declaration],
  chars : Array[Char],
  start : Int,
  end : Int,
  line0 : Int,
) -> Unit {
  if end <= start || !ident_start_char(chars[start]) {
    return
  }
  out.push(
    Declaration::{
      name: chars_range(chars, start, end),
      line: line0,
      start_col: start,
      end_col: end,
    },
  )
}

///|
fn line_text_at(source : String, line0 : Int) -> String {
  if line0 < 0 {
    return ""
  }
  let lines = source.split("\n").to_array()
  if line0 >= lines.length() {
    return ""
  }
  let mut text = lines[line0].to_owned()
  if text.has_suffix("\r") {
    text = text[: text.length() - 1].to_owned()
  }
  text
}

///|
/// The identifier under a 0-based `(line, character)`. An editor often puts the
/// cursor just past a word, so a non-word character looks one to the left
/// before giving up.
fn word_at(source : String, line0 : Int, character : Int) -> String? {
  let chars = string_chars(line_text_at(source, line0))
  if chars.length() == 0 {
    return None
  }
  let mut pos = character
  if pos < 0 {
    pos = 0
  }
  if pos >= chars.length() {
    pos = chars.length() - 1
  }
  if !ident_char(chars[pos]) {
    if pos > 0 && ident_char(chars[pos - 1]) {
      pos = pos - 1
    } else {
      return None
    }
  }
  let mut start = pos
  while start > 0 && ident_char(chars[start - 1]) {
    start = start - 1
  }
  let mut end = pos + 1
  while end < chars.length() && ident_char(chars[end]) {
    end = end + 1
  }
  if !ident_start_char(chars[start]) {
    return None
  }
  Some(chars_range(chars, start, end))
}

///|
/// Declarations on one line. Returns the block kind the line opens (`struct` or
/// `enum`) so the caller can track field context.
fn scan_declarations(
  line : String,
  line0 : Int,
  in_struct : Bool,
  in_enum : Bool,
  out : Array[Declaration],
) -> String? {
  let chars = string_chars(line)
  let mut i = skip_spaces(chars, 0)
  if i >= chars.length() || chars[i] == '/' {
    return None
  }
  // Strip the visibility prefix; `pub(all)` and `priv` change nothing about
  // where the declared name starts.
  if word_at_index(chars, i, "pub") {
    i = skip_spaces(chars, i + 3)
    if i < chars.length() && chars[i] == '(' {
      while i < chars.length() && chars[i] != ')' {
        i = i + 1
      }
      i = skip_spaces(chars, i + 1)
    }
  } else if word_at_index(chars, i, "priv") {
    i = skip_spaces(chars, i + 4)
  }
  if i >= chars.length() {
    return None
  }
  if word_at_index(chars, i, "fn") {
    let mut j = skip_spaces(chars, i + 2)
    let start = j
    let end = ident_end(chars, j)
    if end > start {
      if end + 1 < chars.length() && chars[end] == ':' && chars[end + 1] == ':' {
        // `fn Type::name(self)` declares a method; the useful target is the
        // method name, not the type.
        j = skip_spaces(chars, end + 2)
        let second_end = ident_end(chars, j)
        push_declaration(out, chars, j, second_end, line0)
      } else {
        push_declaration(out, chars, start, end, line0)
      }
    }
    return None
  }
  if word_at_index(chars, i, "let") {
    let mut j = skip_spaces(chars, i + 3)
    if word_at_index(chars, j, "mut") {
      j = skip_spaces(chars, j + 3)
    }
    let end = ident_end(chars, j)
    push_declaration(out, chars, j, end, line0)
    return None
  }
  let is_enum = word_at_index(chars, i, "enum")
  if is_enum || word_at_index(chars, i, "struct") {
    let keyword_length = if is_enum { 4 } else { 6 }
    let j = skip_spaces(chars, i + keyword_length)
    let end = ident_end(chars, j)
    if end > j {
      push_declaration(out, chars, j, end, line0)
      return Some(if is_enum { "enum" } else { "struct" })
    }
    return None
  }
  if word_at_index(chars, i, "type") {
    let j = skip_spaces(chars, i + 4)
    let end = ident_end(chars, j)
    push_declaration(out, chars, j, end, line0)
    return None
  }
  if word_at_index(chars, i, "impl") {
    // `impl T with fn m(...)` declares a method after the first `fn` keyword.
    let mut k = i + 4
    while k < chars.length() {
      if word_at_index(chars, k, "fn") {
        let j = skip_spaces(chars, k + 2)
        let end = ident_end(chars, j)
        push_declaration(out, chars, j, end, line0)
        break
      }
      k = k + 1
    }
    return None
  }
  if in_struct {
    // `x : Int`, `pub y : String`, and mutable fields `z : Int`.
    let end = ident_end(chars, i)
    if end > i {
      let mut k = end
      if k < chars.length() && chars[k] == '?' {
        k = k + 1
      }
      k = skip_spaces(chars, k)
      if k < chars.length() && chars[k] == ':' {
        push_declaration(out, chars, i, end, line0)
      }
    }
    return None
  }
  if in_enum {
    // A bare variant (`None`) or one with payload (`Some(Int)`).
    let end = ident_end(chars, i)
    if end > i {
      let k = skip_spaces(chars, end)
      if k >= chars.length() ||
        chars[k] == '(' || chars[k] == '{' || chars[k] == '=' || chars[k] == ',' {
        push_declaration(out, chars, i, end, line0)
      }
    }
    return None
  }
  None
}

///|
/// Every declaration a file's text spells out, in source order. The scan is
/// line-based on purpose: it must also see virtual buffers that the parser
/// cannot resolve, and a declaration is a lexical shape.
fn file_declarations(source : String) -> Array[Declaration] {
  let out : Array[Declaration] = []
  let lines = source.split("\n").to_array()
  let stack : Array[BlockFrame] = []
  let mut depth = 0
  for line_index in 0..<lines.length() {
    let mut line = lines[line_index].to_owned()
    if line.has_suffix("\r") {
      line = line[: line.length() - 1].to_owned()
    }
    let kind = match stack.last() {
      Some(frame) => frame.kind
      None => ""
    }
    let opened = scan_declarations(line, line_index, kind == "struct", kind == "enum", out)
    let mut opens = 0
    let mut closes = 0
    for ch in line.iter() {
      if ch == '{' {
        opens = opens + 1
      } else if ch == '}' {
        closes = closes + 1
      }
    }
    depth = depth + opens - closes
    match opened {
      Some(kind) =>
        // A one-line `struct Foo { x : Int }` has no following field lines.
        if opens > closes {
          stack.push(BlockFrame::{ kind, depth })
        }
      None => ()
    }
    let mut trimming = true
    while trimming && stack.length() > 0 {
      match stack.last() {
        Some(frame) =>
          if frame.depth > depth {
            ignore(stack.pop())
          } else {
            trimming = false
          }
        None => trimming = false
      }
    }
  }
  out
}

///|
fn declaration_named(decls : Array[Declaration], name : String) -> Declaration? {
  for decl in decls {
    if decl.name == name {
      return Some(decl)
    }
  }
  None
}

///|
fn range_json(uri : String, line0 : Int, start : Int, end : Int) -> String {
  "{\"uri\":" +
  json_string(uri) +
  ",\"range\":{\"start\":{\"line\":" +
  line0.to_string() +
  ",\"character\":" +
  start.to_string() +
  "},\"end\":{\"line\":" +
  line0.to_string() +
  ",\"character\":" +
  end.to_string() +
  "}}}"
}

///|
fn location_json(uri : String, decl : Declaration) -> String {
  range_json(uri, decl.line, decl.start_col, decl.end_col)
}

///|
/// The text of the file under the cursor: its open buffer, or the copy on disk.
async fn anchor_source(uri : String) -> String {
  match documents.get(uri) {
    Some(text) => text
    None =>
      match uri_to_path(uri) {
        Some(path) =>
          match read_text(path) {
            Some(text) => text
            None => ""
          }
        None => ""
      }
  }
}

///|
/// Every `.mbt` file of the cursor's package, plus the cursor's own buffer when
/// it is not on disk yet. `collect_package` supplies both halves: it already
/// prefers an open buffer over the file on disk and reuses the scan cache.
async fn package_sources(anchor_uri : String) -> Array[SourceFile] {
  let out : Array[SourceFile] = []
  let anchor_path = match uri_to_path(anchor_uri) {
    Some(path) => path
    None => anchor_uri
  }
  let directory = parent_dir(anchor_path)
  // A buffer with no directory on disk (`file:///probe.mbt`) has no package to
  // list; answering from its own text is the only truthful answer.
  if directory != "" && directory != "." {
    match collect_package(anchor_uri) {
      Some(pkg) => {
        let mut index = 0
        while index < pkg.paths.length() {
          out.push(
            SourceFile::{
              uri: path_to_uri(pkg.paths[index]),
              path: pkg.paths[index],
              text: pkg.facts[index].source,
            },
          )
          index = index + 1
        }
      }
      None => ()
    }
  }
  let mut found = false
  for file in out {
    if file.uri == anchor_uri || file.path == anchor_path {
      found = true
    }
  }
  if !found {
    out.push(
      SourceFile::{ uri: anchor_uri, path: anchor_path, text: anchor_source(anchor_uri) },
    )
  }
  out
}

///|
/// `textDocument/definition`: the first declaration of the word under the
/// cursor in the package. The cursor's own file is searched first, so a local
/// binding wins over a sibling file's function of the same name.
async fn definition_result(uri : String, line0 : Int, character : Int) -> String {
  let source = anchor_source(uri)
  let name = match word_at(source, line0, character) {
    Some(name) => name
    None => return "null"
  }
  let files = package_sources(uri)
  for pass in 0..<2 {
    for file in files {
      let is_anchor = file.uri == uri
      let wanted = if pass == 0 { is_anchor } else { !is_anchor }
      if wanted {
        match declaration_named(file_declarations(file.text), name) {
          Some(decl) => return location_json(file.uri, decl)
          None => ()
        }
      }
    }
  }
  "null"
}

///|
/// `textDocument/references`: every whole-word occurrence of the cursor's word
/// in the package. The declaration's own occurrence is omitted unless the
/// client asked for it.
async fn references_result(
  uri : String,
  line0 : Int,
  character : Int,
  include_declaration : Bool,
) -> String {
  let source = anchor_source(uri)
  let name = match word_at(source, line0, character) {
    Some(name) => name
    None => return "[]"
  }
  let files = package_sources(uri)
  let entries : Array[String] = []
  for file in files {
    let decls = file_declarations(file.text)
    let lines = file.text.split("\n").to_array()
    for line_index in 0..<lines.length() {
      let mut line = lines[line_index].to_owned()
      if line.has_suffix("\r") {
        line = line[: line.length() - 1].to_owned()
      }
      let chars = string_chars(line)
      let mut i = 0
      while i < chars.length() {
        if ident_start_char(chars[i]) {
          let start = i
          let end = ident_end(chars, start)
          if chars_range(chars, start, end) == name {
            let mut is_declaration = false
            for decl in decls {
              if decl.line == line_index &&
                decl.start_col == start &&
                decl.end_col == end {
                is_declaration = true
              }
            }
            if include_declaration || !is_declaration {
              entries.push(range_json(file.uri, line_index, start, end))
            }
          }
          i = end
        } else {
          i = i + 1
        }
      }
    }
  }
  entries_json(entries)
}

///|
/// Returns `false` when the editor asked the server to exit.
///
/// The Json type is never named here: it is reached through pattern matching on
/// the value `@json.parse` returns, which keeps the file compiling across core
/// versions that disagree about where the type is declared.
async fn handle_message(text : String) -> Bool {
  let parsed = @json.parse(text) catch {
    _ => return true
  }
  let object = match parsed {
    Object(map) => map
    _ => return true
  }
  let method_name = match object.get("method") {
    Some(String(name)) => name
    _ => return true
  }
  // A request carries an id; a notification does not and gets no response.
  let id = match object.get("id") {
    Some(value) => value.stringify()
    None => ""
  }
  match method_name {
    "initialize" =>
      send_response(
        id,
        "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"codeActionProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true,\"diagnosticProvider\":{\"interFileDependencies\":false,\"workspaceDiagnostics\":false}},\"serverInfo\":{\"name\":\"moon-slice\",\"version\":" +
        json_string(lsp_version) +
        "}}",
      )
    "initialized" => ()
    "shutdown" => send_response(id, "null")
    "textDocument/hover" => {
      match object.get("params") {
        Some(Object(params)) =>
          match (params.get("textDocument"), params.get("position")) {
            (Some(Object(document)), Some(Object(position))) =>
              match (document.get("uri"), position.get("line")) {
                (Some(String(uri)), Some(Number(value, ..))) => {
                  let result = hover_result(uri, value.to_int())
                  send_response(id, result)
                }
                _ => send_response(id, "null")
              }
            _ => send_response(id, "null")
          }
        _ => send_response(id, "null")
      }
    }
    "textDocument/codeAction" => {
      match object.get("params") {
        Some(Object(params)) =>
          match (params.get("textDocument"), params.get("context")) {
            (Some(Object(document)), Some(Object(context))) =>
              match (document.get("uri"), context.get("diagnostics")) {
                (Some(String(uri)), Some(Array(items))) => {
                  let mut rule = ""
                  let mut line0 = 0
                  for item in items {
                    match item {
                      Object(diagnostic) =>
                        if rule == "" {
                          match diagnostic.get("code") {
                            Some(String(code)) =>
                              if code == "dead-store" || code == "unreachable-code" {
                                rule = code
                                match diagnostic.get("range") {
                                  Some(Object(range)) =>
                                    match range.get("start") {
                                      Some(Object(start)) =>
                                        match start.get("line") {
                                          Some(Number(value, ..)) =>
                                            line0 = value.to_int()
                                          _ => ()
                                        }
                                      _ => ()
                                    }
                                  _ => ()
                                }
                              }
                            _ => ()
                          }
                        }
                      _ => ()
                    }
                  }
                  if rule == "" {
                    send_response(id, "[]")
                  } else {
                    send_response(id, code_actions_result(uri, line0, rule))
                  }
                }
                _ => send_response(id, "[]")
              }
            _ => send_response(id, "[]")
          }
        _ => send_response(id, "[]")
      }
    }
    "textDocument/definition" => {
      match object.get("params") {
        Some(Object(params)) =>
          match (params.get("textDocument"), params.get("position")) {
            (Some(Object(document)), Some(Object(position))) =>
              match (document.get("uri"), position.get("line"), position.get("character")) {
                (Some(String(uri)), Some(Number(line, ..)), Some(Number(character, ..))) => {
                  let result = definition_result(
                    uri,
                    line.to_int(),
                    character.to_int(),
                  )
                  send_response(id, result)
                }
                _ => send_response(id, "null")
              }
            _ => send_response(id, "null")
          }
        _ => send_response(id, "null")
      }
    }
    "textDocument/references" => {
      match object.get("params") {
        Some(Object(params)) =>
          match (params.get("textDocument"), params.get("position")) {
            (Some(Object(document)), Some(Object(position))) =>
              match (document.get("uri"), position.get("line"), position.get("character")) {
                (Some(String(uri)), Some(Number(line, ..)), Some(Number(character, ..))) => {
                  let include_declaration = match params.get("context") {
                    Some(Object(context)) =>
                      match context.get("includeDeclaration") {
                        Some(True) => true
                        _ => false
                      }
                    _ => false
                  }
                  let result = references_result(
                    uri,
                    line.to_int(),
                    character.to_int(),
                    include_declaration,
                  )
                  send_response(id, result)
                }
                _ => send_response(id, "[]")
              }
            _ => send_response(id, "[]")
          }
        _ => send_response(id, "[]")
      }
    }
    "exit" => return false
    "textDocument/didOpen" => {
      match object.get("params") {
        Some(Object(params)) =>
          match params.get("textDocument") {
            Some(Object(document)) =>
              match (document.get("uri"), document.get("text")) {
                (Some(String(uri)), Some(String(source))) => {
                  documents.set(uri, source)
                  // The package pass publishes the open file too; the
                  // file-local pass only covers a directory it cannot list.
                  if !publish_package(uri) {
                    publish(uri)
                  }
                }
                _ => ()
              }
            _ => ()
          }
        _ => ()
      }
    }
    "textDocument/didChange" => {
      match object.get("params") {
        Some(Object(params)) =>
          match params.get("textDocument") {
            Some(Object(document)) =>
              match document.get("uri") {
                Some(String(uri)) =>
                  match params.get("contentChanges") {
                    Some(Array(items)) =>
                      match items.get(0) {
                        Some(Object(change)) =>
                          match change.get("text") {
                            Some(String(source)) => {
                              documents.set(uri, source)
                              publish(uri)
                            }
                            _ => ()
                          }
                        _ => ()
                      }
                    _ => ()
                  }
                _ => ()
              }
            _ => ()
          }
        _ => ()
      }
    }
    "textDocument/didSave" => {
      match object.get("params") {
        Some(Object(params)) =>
          match params.get("textDocument") {
            Some(Object(document)) =>
              match document.get("uri") {
                Some(String(uri)) =>
                  if !publish_package(uri) {
                    publish(uri)
                  }
                _ => ()
              }
            _ => ()
          }
        _ => ()
      }
    }
    "textDocument/didClose" => {
      match object.get("params") {
        Some(Object(params)) =>
          match params.get("textDocument") {
            Some(Object(document)) =>
              match document.get("uri") {
                Some(String(uri)) => {
                  documents.remove(uri)
                  publish(uri)
                }
                _ => ()
              }
            _ => ()
          }
        _ => ()
      }
    }
    _ => {
      // Unknown request: answer with MethodNotFound so a client never hangs.
      if id != "" {
        send(
          "{\"jsonrpc\":\"2.0\",\"id\":" +
          id +
          ",\"error\":{\"code\":-32601,\"message\":\"unsupported method\"}}",
        )
      }
    }
  }
  true
}

///|
/// `file:///c:/dir/a.mbt` -> `c:/dir/a.mbt`; `%20` becomes a space. Only the
/// forms editors actually send are handled; anything else returns `None`.
fn uri_to_path(uri : String) -> String? {
  if !uri.has_prefix("file://") {
    return None
  }
  let mut path = uri[7:].to_owned()
  match path.get_char(2) {
    Some(':') => path = path[1:].to_owned()
    _ => ()
  }
  Some(path.replace_all(old="%20", new=" "))
}

///|
fn path_to_uri(path : String) -> String {
  let out = StringBuilder()
  for ch in path.iter() {
    if ch == '\\' {
      out.write_char('/')
    } else {
      out.write_char(ch)
    }
  }
  let normalized = out.to_string()
  if normalized.has_prefix("/") {
    "file://" + normalized
  } else {
    "file:///" + normalized
  }
}

///|
fn parent_dir(path : String) -> String {
  let mut last = -1
  let mut i = 0
  for ch in path.iter() {
    if ch == '/' || ch == '\\' {
      last = i
    }
    i = i + 1
  }
  if last <= 0 {
    "."
  } else {
    path[:last].to_owned()
  }
}

///|
async fn read_text(path : String) -> String? {
  let data = @fs.read_file(path) catch {
    _ => return None
  }
  Some(@utf8.decode_lossy(data.binary()))
}

///|
/// The file's identity on disk: modification time and size. `None` when the
/// file cannot be stat'ed — it may have been removed between the directory
/// listing and now, in which case there is nothing to cache anyway.
async fn file_stamp(path : String) -> @scan.Stamp? {
  let mtime = @fs.mtime(path) catch {
    _ => return None
  }
  let size = @fs.file_size(path) catch {
    _ => return None
  }
  Some(@scan.Stamp::new(mtime.0, mtime.1, size))
}

///|
/// Diagnostics travel to the editor over stdout, so the scan's own account of
/// itself goes to stderr, where it cannot corrupt the protocol stream.
async fn log_line(text : String) -> Unit {
  @stdio.stderr.write("moon-slice: " + text + "\n")
}

///|
/// Why `src/roots` agrees (or does not) that the name is dead, as one sentence
/// appended to the lexical finding. The lexical pass says "the name occurs
/// once"; the graph says why: no incoming edge at all, or incoming edges whose
/// sources are themselves unreachable.
fn unused_evidence(reach : @roots.Reachability?, name : String) -> String {
  match reach {
    Some(reach) =>
      match reach.dead_reason(name) {
        Some(dead) =>
          if dead.evidence.length() == 0 {
            ""
          } else {
            "; reachability: " + dead.evidence.join("; ")
          }
        None => ""
      }
    None => ""
  }
}

///|
fn unused_entry(item : @liveness.UnusedFn, reach : @roots.Reachability?) -> String {
  let line = if item.line > 0 { item.line - 1 } else { 0 }
  "{\"range\":{\"start\":{\"line\":" +
  line.to_string() +
  ",\"character\":0},\"end\":{\"line\":" +
  line.to_string() +
  ",\"character\":0}},\"severity\":2,\"source\":\"moon-slice\",\"code\":\"unused-function\",\"message\":" +
  json_string(
    "private function `" +
    item.name +
    "` is never referenced in its package" +
    unused_evidence(reach, item.name),
  ) +
  "}"
}

///|
fn entries_json(entries : Array[String]) -> String {
  let out = StringBuilder()
  out.write_string("[")
  let mut first = true
  for entry in entries {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string(entry)
  }
  out.write_string("]")
  out.to_string()
}

///|
/// Everything one package scan produced: the facts `src/liveness` and
/// `src/roots` take, the files they came from, and the read/cache split the
/// stderr line reports.
struct PackageFacts {
  directory : String
  facts : Array[@liveness.FileFacts]
  paths : Array[String]
  re_read : Int
  reused : Int
}

///|
/// Every `.mbt` file of the anchor's directory. The editor's buffer is used for
/// any file it has open; everything else is read from disk.
///
/// A file whose stamp did not change since the last scan is neither read nor
/// parsed again: `@scan` hands its facts back.
///
/// Returns `None` when the directory cannot be listed (a virtual URI, a
/// directory the server cannot read).
async fn collect_package(anchor_uri : String) -> PackageFacts? {
  let anchor = match uri_to_path(anchor_uri) {
    Some(path) => path
    None => return None
  }
  let directory = parent_dir(anchor)
  let names = @fs.readdir(directory) catch {
    _ => return None
  }
  let scan = scan_cache.begin(directory)
  let facts : Array[@liveness.FileFacts] = []
  let paths : Array[String] = []
  let mut re_read = 0
  let mut reused = 0
  // Stamps are independent of each other, and one round trip each is what the
  // per-file cost was made of on a large package, so they are fetched a few at
  // a time rather than one after another.
  let mbt_names = names.filter(fn(name) { name.has_suffix(".mbt") })
  let stamps : Array[@scan.Stamp?] = @async.all(
    mbt_names.map(fn(name) { () => file_stamp(directory + "/" + name) }),
    max_concurrent=32,
  )
  for index in 0..<mbt_names.length() {
    let name = mbt_names[index]
    let full = directory + "/" + name
    let uri = path_to_uri(full)
    // Any open buffer is the authoritative text, not only the anchor's: a
    // hover can collect the package from a sibling, and re-reading a modified
    // buffer from disk would both be wrong and evict its cache entry.
    let buffer = documents.get(uri)
    let stamp = stamps[index]
    let cached = match stamp {
      Some(stamp) => scan.reuse(full, stamp, buffer)
      None => None
    }
    match cached {
      Some(file_facts) => {
        facts.push(file_facts)
        paths.push(full)
        reused = reused + 1
      }
      None => {
        let text = match buffer {
          Some(text) => Some(text)
          None => read_text(full)
        }
        match text {
          None => ()
          Some(text) => {
            let file_facts = @liveness.collect(full, text)
            match stamp {
              Some(stamp) => scan.record(full, stamp, buffer, file_facts)
              None => ()
            }
            facts.push(file_facts)
            paths.push(full)
            re_read = re_read + 1
          }
        }
      }
    }
  }
  scan_cache.commit(scan)
  Some(PackageFacts::{ directory, facts, paths, re_read, reused })
}

///|
/// Package-wide pass: every `.mbt` file next to the edited one is analysed as
/// one package, so `unused-function` works across files. `collect_package`
/// does the reading, and the stderr line below is what the client test asserts
/// against.
///
/// Returns `false` when the pass could not run, so the caller can fall back to
/// the file-local diagnostics.
async fn publish_package(anchor_uri : String) -> Bool {
  let pkg = match collect_package(anchor_uri) {
    Some(pkg) => pkg
    None => return false
  }
  let facts = pkg.facts
  let paths = pkg.paths
  let findings = @liveness.unused_functions(facts)
  // Reachability only explains a finding. A clean save does not pay for the
  // second parse of the package.
  let reach = if findings.length() > 0 {
    Some(@roots.analyze(facts))
  } else {
    None
  }
  let by_file : Map[String, Array[@liveness.UnusedFn]] = Map([])
  for item in findings {
    let list = match by_file.get(item.path) {
      Some(list) => list
      None => {
        let fresh : Array[@liveness.UnusedFn] = []
        by_file.set(item.path, fresh)
        fresh
      }
    }
    list.push(item)
  }
  let mut anchor_published = false
  for full in paths {
    let uri = path_to_uri(full)
    let entries : Array[String] = []
    if uri == anchor_uri {
      anchor_published = true
      let source = match documents.get(uri) {
        Some(text) => text
        None => ""
      }
      for finding in findings_for(source, uri) {
        entries.push(
          finding_entry(finding),
        )
      }
    }
    match by_file.get(full) {
      Some(items) =>
        for item in items {
          entries.push(unused_entry(item, reach))
        }
      None => ()
    }
    send(
      "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":" +
      json_string(uri) +
      ",\"diagnostics\":" +
      entries_json(entries) +
      "}}",
    )
  }
  if !anchor_published {
    // The open file is not among the listed files: a new unsaved buffer, or a
    // URI that spells the path differently. It still gets its own diagnostics;
    // leaving the previous ones in place would be worse.
    let entries : Array[String] = []
    let source = match documents.get(anchor_uri) {
      Some(text) => text
      None => ""
    }
    for finding in findings_for(source, anchor_uri) {
      entries.push(finding_entry(finding))
    }
    send(
      "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":" +
      json_string(anchor_uri) +
      ",\"diagnostics\":" +
      entries_json(entries) +
      "}}",
    )
  }
  // Reported last, so the line means "the whole pass finished", which is what
  // `bench/scan.mjs` measures.
  log_line(
    "package " +
    pkg.directory +
    ": " +
    paths.length().to_string() +
    " files, " +
    pkg.re_read.to_string() +
    " re-read, " +
    pkg.reused.to_string() +
    " cached",
  )
  true
}

///|
async fn main {
  let mut running = true
  while running {
    let message = read_message()
    match message {
      None => running = false
      Some(text) => running = handle_message(text)
    }
  }
}
