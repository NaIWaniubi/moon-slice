// moon-slice command line interface.
//
// Commands:
//   slice --file F --line N --direction backward|forward [--json]
//   graph --file F [--format dot]
//   dead  --file F
//   html  --file F --line N [--out report.html]
//   dump  --file F --line N
//
// The analysis pipeline is intentionally thin here: every decision lives in
// the library packages, and this file only parses flags and renders output.

///|
fn usage() -> Unit {
  println(
    "moon-slice — program slicing for MoonBit\n" +
    "\n" +
    "Commands:\n" +
    "  slice --file F --line N --direction backward|forward [--json] [--interprocedural]\n" +
    "        [--node ID]   disambiguate several statements on the same line\n" +
    "  graph --file F [--format dot|json]\n" +
    "  callgraph --file F [--json]\n" +
    "  dead  --file F [--json] [--format sarif] [--out FILE]\n" +
    "        [--baseline FILE | --write-baseline FILE] [--fail-on-findings]\n" +
    "  dead  --dir D [--json] [--format sarif] [--out FILE]  scan a tree\n" +
    "        [--baseline FILE | --write-baseline FILE] [--fail-on-findings]\n" +
    "  unused --dir D [--json] [--format sarif] [--out FILE]  private functions\n" +
    "        [--fail-on-findings]                     nothing calls anymore\n" +
    "  path  --file F --from VAR --to VAR [--json]\n" +
    "  html  --file F --line N [--out report.html] [--interprocedural] [--node ID]\n" +
    "  dump  --file F --line N\n" +
    "  dump-errors / dump-cfg / dump-defuse / dump-pdg --file F\n" +
    "  version | help\n" +
    "\n" +
    "Options:\n" +
    "  --precise   derive control dependence from post-dominators instead of the\n" +
    "              syntax tree. Exact for the CFG; drops the structural rule's\n" +
    "              over-approximations. Works with slice/graph/dead/html.\n" +
    "  --json      machine-readable output; failures become\n" +
    "              {\"error\":{\"code\":..,\"message\":..}} and still exit 2.\n" +
    "  --format sarif   (dead, unused) SARIF 2.1.0 for code-scanning uploads.\n" +
    "  --baseline FILE  (dead only) hide findings listed in FILE. The file is\n" +
    "              the output of a previous --write-baseline run.\n" +
    "  --write-baseline FILE  record the current findings and exit.\n" +
    "  --fail-on-findings     (dead, unused) exit 1 when a finding remains after\n" +
    "              baseline filtering; output is written first.\n" +
    "  --dir D     (dead, unused) scan every .mbt file under D. Mutually\n" +
    "              exclusive with --file; parse failures are reported, not fatal.\n" +
    "\n" +
    "Exit codes: 0 success, 1 findings with --fail-on-findings, 2 usage error,\n" +
    "unreadable input, parse error or write failure. When a line holds several\n" +
    "statements, `dump --line N` lists\n" +
    "their node ids; pass the wanted one with `--node ID`.\n",
  )
}

///|
/// Pre-scan argv for `--json` so a failure during argument parsing still knows
/// whether the caller wants a machine-readable error.
fn prescan_json(argv : Array[String]) -> Bool {
  let mut found = false
  for arg in argv {
    if arg == "--json" {
      found = true
    }
  }
  found
}

///|
/// Whether the invocation asked for `--json`. Failures consult this so a
/// machine consumer always gets an error object instead of prose. It is a cell
/// because the flag is parsed before the command runs, and the failure helpers
/// are shared by every command.
let json_mode : Array[Bool] = [false]

///|
let tool_version : String = "0.7.1"

///|
/// Emit a machine-readable error object when `--json` was requested, otherwise
/// the human line, then exit 2.
fn fail_code(code : String, message : String) -> Unit {
  if json_mode[0] {
    println(@report.to_error_json(code, message))
  } else {
    println("error: " + message)
  }
  @sys.exit(2)
}

///|
fn read_source(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => {
      fail_code("read_failed", "failed to read \{path}: \{msg}")
      ""
    }
  }
}

///|
fn known_command(command : String) -> Bool {
  command == "slice" ||
  command == "graph" ||
  command == "compare" ||
  command == "review" ||
  command == "unused" ||
  command == "callers" ||
  command == "callgraph" ||
  command == "dead" ||
  command == "path" ||
  command == "html" ||
  command == "dump" ||
  command == "dump-errors" ||
  command == "dump-cfg" ||
  command == "dump-defuse" ||
  command == "dump-pdg"
}

///|
fn require_value(argv : Array[String], i : Int, _flag : String) -> String {
  if i + 1 >= argv.length() {
    fail_code("missing_value", "\{_flag} requires a value")
    ""
  } else {
    argv[i + 1]
  }
}

///|
fn parse_line(value : String) -> Int {
  @string.parse_int(value) catch {
    _ => {
      fail_code("bad_integer", "invalid integer for --line: \{value}")
      0
    }
  }
}

///|
fn require_line(command : String, line : Int) -> Unit {
  if (command == "slice" || command == "html" || command == "dump") && line <= 0 {
    fail_code("missing_line", "--line is required for \{command}")
  }
}

///|
fn select_target(
  program : @core.Program,
  line : Int32,
  override_node : Int32?,
) -> Int32 {
  match override_node {
    Some(id) => {
      match @query.node_exists(program, id) {
        true => id
        false => {
          fail_code("unknown_node", "no node with id \{id}")
          0
        }
      }
    }
    None => {
      let candidates = @query.statement_candidates(program, line)
      if candidates.length() == 0 {
        fail_code("no_node_at_line", "no node starts at line \{line}")
      }
      if candidates.length() > 1 {
        let ids = StringBuilder()
        let mut first = true
        for id in candidates {
          if !first {
            ids.write_char(',')
          }
          ids.write_string(id.to_string())
          first = false
        }
        println(
          "note: line \{line} has \{candidates.length()} statements; using node \{candidates[0]}. Pass --node ID to choose another (candidates: \{ids.to_string()})",
        )
      }
      candidates[0]
    }
  }
}

///|
/// Control edges of a PDG as a set, for the `compare` command.
fn control_edge_set(pdg : @core.Pdg) -> Set[(Int32, Int32)] {
  let out : Set[(Int32, Int32)] = Set([])
  for edge in pdg.edges {
    if edge.kind == @core.EdgeKind::Control {
      out.add((edge.from, edge.to))
    }
  }
  out
}

///|
fn pair_array_json(pairs : Array[(Int32, Int32)]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  let mut first = true
  for (from, to) in pairs {
    if !first {
      out.write_char(',')
    }
    out.write_string("[")
    out.write_string(from.to_string())
    out.write_char(',')
    out.write_string(to.to_string())
    out.write_char(']')
    first = false
  }
  out.write_char(']')
  out.to_string()
}

///|
fn lines_text(lines : Array[Int32]) -> String {
  let out = StringBuilder()
  let mut first = true
  for line in lines {
    if !first {
      out.write_char(',')
    }
    out.write_string(line.to_string())
    first = false
  }
  out.to_string()
}

///|
fn analyze(
  source : String,
  name : String,
  precise : Bool,
) -> (@core.Program, @core.Cfg, @core.DefUse, @core.Pdg) {
  let program = @parser_adapter.parse_source(source, name)
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = if precise {
    @cdg.build_precise(program, cfg)
  } else {
    @cdg.build(program, cfg)
  }
  let pdg = @pdg.build(defuse, cdg)
  (program, cfg, defuse, pdg)
}

///|
fn print_lines(result : @core.SliceResult) -> Unit {
  let mut out = ""
  let mut first = true
  for line in result.lines {
    if !first {
      out = out + ","
    }
    out = out + line.to_string()
    first = false
  }
  println(out)
}

///|
fn vars_str(vars : Array[@core.VarId]) -> String {
  let mut out = ""
  let mut first = true
  for v in vars {
    if !first {
      out = out + ","
    }
    out = out + v.name + "#" + v.scope.to_string()
    first = false
  }
  out
}

///|
fn edge_kind_name(kind : @core.EdgeKind) -> String {
  match kind {
    @core.EdgeKind::Data => "data"
    @core.EdgeKind::Control => "control"
  }
}

///|
fn kind_name(kind : @core.SNodeKind) -> String {
  match kind {
    @core.SNodeKind::Let => "Let"
    @core.SNodeKind::LetMut => "LetMut"
    @core.SNodeKind::Assign => "Assign"
    @core.SNodeKind::If => "If"
    @core.SNodeKind::While => "While"
    @core.SNodeKind::For => "For"
    @core.SNodeKind::Match => "Match"
    @core.SNodeKind::Return => "Return"
    @core.SNodeKind::Break => "Break"
    @core.SNodeKind::Continue => "Continue"
    @core.SNodeKind::Call => "Call"
    @core.SNodeKind::Expr => "Expr"
  }
}

///|
/// Baseline entries are `path:line`, so a path must compare equal regardless of
/// the separator the caller used.
fn normalize_path(path : String) -> String {
  let out = StringBuilder()
  for ch in path.iter() {
    match ch {
      '\\' => out.write_char('/')
      _ => out.write_char(ch)
    }
  }
  let joined = out.to_string()
  if joined.has_prefix("./") { joined[2:].to_owned() } else { joined }
}

///|
fn baseline_key(file : String, line : Int32) -> String {
  normalize_path(file) + ":" + line.to_string()
}

///|
/// Read a baseline written by `--write-baseline`. Blank lines and `#` comments
/// are ignored, so the file can carry a short header.
fn parse_baseline(text : String) -> Set[String] {
  let keys : Set[String] = Set([])
  for raw in text.split("\n") {
    let line = raw.replace(old="\r", new="").to_owned()
    if line != "" && !line.has_prefix("#") {
      keys.add(normalize_path(line))
    }
  }
  keys
}

///|
fn filter_baseline(
  program : @core.Program,
  ids : Array[Int32],
  file : String,
  baseline : Set[String],
) -> Array[Int32] {
  let out : Array[Int32] = []
  for id in ids {
    match @query.node_by_id(program, id) {
      None => out.push(id)
      Some(node) =>
        if !baseline.contains(baseline_key(file, node.loc.start_line)) {
          out.push(id)
        }
    }
  }
  out
}

///|
fn write_baseline_file(
  path : String,
  file : String,
  ids : Array[Int32],
  program : @core.Program,
) -> Unit {
  let out = StringBuilder()
  out.write_string("# moon-slice baseline v1\n")
  out.write_string("# path:line, one finding per line\n")
  for id in ids {
    match @query.node_by_id(program, id) {
      None => ()
      Some(node) => {
        out.write_string(baseline_key(file, node.loc.start_line))
        out.write_char('\n')
      }
    }
  }
  @fs.write_string_to_file(path, out.to_string()) catch {
    @fs.IOError(msg) => fail_code("write_failed", "failed to write \{path}: \{msg}")
  }
  println("wrote \{path} (\{ids.length()} finding(s))")
}

///|
fn is_mbt_file(name : String) -> Bool {
  match name.find(".mbt") {
    Some(index) => index == name.length() - 4
    None => false
  }
}

///|
fn skip_scan_dir(name : String) -> Bool {
  name == ".git" ||
  name == "_build" ||
  name == "target" ||
  name == "node_modules" ||
  name == ".mooncakes"
}

///|
fn collect_mbt_files(dir : String, out : Array[String]) -> Unit {
  let entries : Array[String] = @fs.read_dir(dir) catch {
    @fs.IOError(_) => []
  }
  entries.sort_by(fn(a, b) { a.lexical_compare(b) })
  for name in entries {
    let path = if dir == "." { name } else { dir + "/" + name }
    let directory = @fs.is_dir(path) catch {
      @fs.IOError(_) => false
    }
    if directory {
      if !skip_scan_dir(name) {
        collect_mbt_files(path, out)
      }
    } else if is_mbt_file(name) {
      out.push(path)
    }
  }
}

///|
fn render_findings_text(findings : Array[@report.SarifFinding]) -> String {
  let out = StringBuilder()
  let mut first = true
  let mut previous = ""
  for finding in findings {
    let key = finding.file + ":" + finding.line.to_string()
    if key != previous {
      if !first {
        out.write_char('\n')
      }
      out.write_string(key)
      previous = key
      first = false
    }
  }
  out.to_string()
}

///|
fn write_scan_baseline(path : String, findings : Array[@report.SarifFinding]) -> Unit {
  let out = StringBuilder()
  out.write_string("# moon-slice baseline v1\n")
  out.write_string("# path:line, one finding per line\n")
  let mut previous = ""
  for finding in findings {
    let key = baseline_key(finding.file, finding.line)
    if key != previous {
      out.write_string(key)
      out.write_char('\n')
      previous = key
    }
  }
  @fs.write_string_to_file(path, out.to_string()) catch {
    @fs.IOError(msg) => fail_code("write_failed", "failed to write \{path}: \{msg}")
  }
  println("wrote \{path} (\{findings.length()} finding(s))")
}

///|
fn read_scan_file(path : String, errors : Array[String]) -> String? {
  let ok = [true]
  let text = @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => {
      ok[0] = false
      errors.push(path + ": " + msg)
      ""
    }
  }
  if ok[0] { Some(text) } else { None }
}

///|
/// Scan every `.mbt` file under `dir`. Unlike the single-file path, a parse
/// failure in one file must not hide the others: failures are collected and
/// reported, and only successfully parsed files count towards `files`.
fn run_dead_dir(
  dir : String,
  format : String,
  json : Bool,
  out_path : String,
  baseline_path : String,
  write_baseline : String,
  fail_on_findings : Bool,
) -> Unit {
  let paths : Array[String] = []
  let is_directory = @fs.is_dir(dir) catch {
    @fs.IOError(_) => false
  }
  if !is_directory {
    fail_code("read_failed", "not a directory: \{dir}")
  }
  collect_mbt_files(dir, paths)
  paths.sort_by(fn(a, b) { a.lexical_compare(b) })
  let baseline = if baseline_path == "" {
    Set([])
  } else {
    parse_baseline(read_source(baseline_path))
  }
  let all : Array[@report.SarifFinding] = []
  let errors : Array[String] = []
  let mut scanned = 0
  for path in paths {
    let maybe_source = read_scan_file(path, errors)
    match maybe_source {
      None => ()
      Some(source) => {
        let (program, cfg, defuse, _) = analyze(source, path, false)
        if program.errors.length() > 0 {
          errors.push(
            path +
            ": " +
            program.errors.length().to_string() +
            " parser diagnostic(s)",
          )
        } else {
          scanned = scanned + 1
          let dead = @query.dead_nodes(program, defuse)
          let unreach = @query.unreachable_nodes(program, cfg)
          let ids = @query.union_sorted(dead, unreach)
          for id in ids {
            match @query.node_by_id(program, id) {
              None => ()
              Some(node) => {
                let is_dead = dead.contains(id)
                all.push(@report.SarifFinding::{
                  file: normalize_path(path),
                  line: node.loc.start_line,
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
        }
      }
    }
  }
  all.sort_by(fn(a, b) {
    let by_file = a.file.lexical_compare(b.file)
    if by_file < 0 {
      -1
    } else if by_file > 0 {
      1
    } else if a.line < b.line {
      -1
    } else if a.line > b.line {
      1
    } else {
      let by_rule = a.rule.lexical_compare(b.rule)
      if by_rule < 0 {
        -1
      } else if by_rule > 0 {
        1
      } else {
        0
      }
    }
  })
  if write_baseline != "" {
    write_scan_baseline(write_baseline, all)
    return
  }
  let kept : Array[@report.SarifFinding] = []
  let mut suppressed = 0
  for finding in all {
    if baseline.contains(baseline_key(finding.file, finding.line)) {
      suppressed = suppressed + 1
    } else {
      kept.push(finding)
    }
  }
  let rendered = if format == "sarif" {
    @report.to_sarif_findings(kept, suppressed, tool_version, scanned, errors.length())
  } else if json {
    @report.to_scan_json(kept, scanned, suppressed, errors)
  } else {
    let mut text = render_findings_text(kept)
    for message in errors {
      if text != "" {
        text = text + "\n"
      }
      text = text + "# error: " + message
    }
    text
  }
  if out_path == "" {
    println(rendered)
  } else {
    @fs.write_string_to_file(out_path, rendered) catch {
      @fs.IOError(msg) => fail_code("write_failed", "failed to write \{out_path}: \{msg}")
    }
    println("wrote \{out_path}")
  }
  if fail_on_findings && kept.length() > 0 {
    @sys.exit(1)
  }
}

///|
fn write_unused_baseline(path : String, unused : Array[@liveness.UnusedFn]) -> Unit {
  let out = StringBuilder()
  out.write_string("# moon-slice baseline v1\n")
  out.write_string("# path:line, one finding per line\n")
  let mut previous = ""
  for item in unused {
    let key = baseline_key(item.path, item.line)
    if key != previous {
      out.write_string(key)
      out.write_char('\n')
      previous = key
    }
  }
  @fs.write_string_to_file(path, out.to_string()) catch {
    @fs.IOError(msg) => fail_code("write_failed", "failed to write \{path}: \{msg}")
  }
  println("wrote \{path} (\{unused.length()} finding(s))")
}

///|
/// The directory a file belongs to. In MoonBit a package is one directory, so
/// this is the unit the liveness question is asked about.
fn package_key(path : String) -> String {
  let normalized = normalize_path(path)
  let mut last_separator = -1
  let mut index = 0
  for ch in normalized.iter() {
    if ch == '/' {
      last_separator = index
    }
    index = index + 1
  }
  if last_separator < 0 {
    "."
  } else {
    normalized[:last_separator].to_owned()
  }
}

///|
fn add_facts(
  groups : Array[(String, Array[@liveness.FileFacts])],
  facts : @liveness.FileFacts,
) -> Unit {
  let key = package_key(facts.path)
  let mut index = -1
  let mut i = 0
  while i < groups.length() {
    if groups[i].0 == key {
      index = i
    }
    i = i + 1
  }
  if index >= 0 {
    groups[index].1.push(facts)
  } else {
    groups.push((key, [facts]))
  }
}

///|
fn unused_json(
  unused : Array[@liveness.UnusedFn],
  packages : Int,
  files : Int,
  suppressed : Int,
  errors : Array[String],
) -> String {
  let out = StringBuilder()
  out.write_string("{\"findings\":[")
  let mut first = true
  for item in unused {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"file\":")
    out.write_string(@report.json_string(item.path))
    out.write_string(",\"line\":")
    out.write_string(item.line.to_string())
    out.write_string(",\"name\":")
    out.write_string(@report.json_string(item.name))
    out.write_string("}")
  }
  out.write_string("],\"packages\":")
  out.write_string(packages.to_string())
  out.write_string(",\"files\":")
  out.write_string(files.to_string())
  out.write_string(",\"suppressed\":")
  out.write_string(suppressed.to_string())
  out.write_string(",\"errors\":[")
  first = true
  for message in errors {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string(@report.json_string(message))
  }
  out.write_string("]}")
  out.to_string()
}

///|
/// Report private free functions that nothing in their package references.
///
/// The unit of analysis is the package (one directory), because that is the
/// scope a private function is visible in; a file-local answer would be wrong
/// for callers in sibling files.
fn run_unused_dir(
  dir : String,
  format : String,
  json : Bool,
  out_path : String,
  baseline_path : String,
  write_baseline : String,
  fail_on_findings : Bool,
) -> Unit {
  let paths : Array[String] = []
  let is_directory = @fs.is_dir(dir) catch {
    @fs.IOError(_) => false
  }
  if !is_directory {
    fail_code("read_failed", "not a directory: \{dir}")
  }
  collect_mbt_files(dir, paths)
  paths.sort_by(fn(a, b) { a.lexical_compare(b) })
  let errors : Array[String] = []
  let groups : Array[(String, Array[@liveness.FileFacts])] = []
  let mut scanned = 0
  for path in paths {
    match read_scan_file(path, errors) {
      None => ()
      Some(source) => {
        scanned = scanned + 1
        add_facts(groups, @liveness.collect(normalize_path(path), source))
      }
    }
  }
  groups.sort_by(fn(a, b) { a.0.lexical_compare(b.0) })
  let all : Array[@liveness.UnusedFn] = []
  for group in groups {
    for item in @liveness.unused_functions(group.1) {
      all.push(item)
    }
  }
  if write_baseline != "" {
    write_unused_baseline(write_baseline, all)
    return
  }
  let baseline = if baseline_path == "" {
    Set([])
  } else {
    parse_baseline(read_source(baseline_path))
  }
  let unused : Array[@liveness.UnusedFn] = []
  let mut suppressed = 0
  for item in all {
    if baseline.contains(baseline_key(item.path, item.line)) {
      suppressed = suppressed + 1
    } else {
      unused.push(item)
    }
  }
  let findings : Array[@report.SarifFinding] = []
  for item in unused {
    findings.push(@report.SarifFinding::{
      file: item.path,
      line: item.line,
      rule: "unused-function",
      message: "private function `" +
        item.name +
        "` is never referenced in its package",
    })
  }
  let rendered = if format == "sarif" {
    @report.to_sarif_findings(
      findings,
      suppressed,
      tool_version,
      scanned,
      errors.length(),
    )
  } else if json {
    unused_json(unused, groups.length(), scanned, suppressed, errors)
  } else {
    let text = StringBuilder()
    let mut first = true
    for item in unused {
      if !first {
        text.write_char('\n')
      }
      first = false
      text.write_string(item.path)
      text.write_char(':')
      text.write_string(item.line.to_string())
      text.write_string(": ")
      text.write_string(item.name)
    }
    let mut rendered = text.to_string()
    for message in errors {
      if rendered != "" {
        rendered = rendered + "\n"
      }
      rendered = rendered + "# error: " + message
    }
    rendered
  }
  if out_path == "" {
    println(rendered)
  } else {
    @fs.write_string_to_file(out_path, rendered) catch {
      @fs.IOError(msg) => fail_code("write_failed", "failed to write \{out_path}: \{msg}")
    }
    println("wrote \{out_path}")
  }
  if fail_on_findings && unused.length() > 0 {
    @sys.exit(1)
  }
}

///|
fn slice_files_json(
  slices : Array[@interproc.FileSlice],
  errors : Array[String],
) -> String {
  let out = StringBuilder()
  out.write_string("{\"files\":[")
  let mut first = true
  for file in slices {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"file\":")
    out.write_string(@report.json_string(file.path))
    out.write_string(",\"nodes\":[")
    out.write_string(lines_text(file.nodes))
    out.write_string("],\"lines\":[")
    out.write_string(lines_text(file.lines))
    out.write_string("]}")
  }
  out.write_string("],\"errors\":[")
  first = true
  for message in errors {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string(@report.json_string(message))
  }
  out.write_string("]}")
  out.to_string()
}

///|
/// Slice one file, with callees resolved across the whole `dir` tree.
///
/// `--interprocedural` decides whether callee bodies are pulled in; without it
/// this is the same slice as `slice --file`, only reported per file so the
/// caller never has to guess which file a line number belongs to.
fn run_slice_package(
  dir : String,
  file : String,
  line : Int32,
  override_node : Int32?,
  direction : String,
  interproc : Bool,
  precise : Bool,
  json : Bool,
  out_path : String,
) -> Unit {
  let is_directory = @fs.is_dir(dir) catch {
    @fs.IOError(_) => false
  }
  if !is_directory {
    fail_code("read_failed", "not a directory: \{dir}")
  }
  let target = normalize_path(file)
  let paths : Array[String] = []
  collect_mbt_files(dir, paths)
  paths.sort_by(fn(a, b) { a.lexical_compare(b) })
  let errors : Array[String] = []
  let files : Array[@interproc.PackageFile] = []
  let mut found_target = false
  for path in paths {
    let normalized = normalize_path(path)
    match read_scan_file(path, errors) {
      None => ()
      Some(source) =>
        match @interproc.build_file(normalized, source, precise~) {
          None => errors.push(normalized + ": parser diagnostic(s)")
          Some(built) => {
            if normalized == target {
              found_target = true
            }
            files.push(built)
          }
        }
    }
  }
  if !found_target {
    fail_code("missing_file", "\{file} is not a readable .mbt file under \{dir}")
  }
  let index = @interproc.index(files)
  let mut target_file : @interproc.PackageFile? = None
  for candidate in files {
    if candidate.path == target {
      target_file = Some(candidate)
    }
  }
  let program = match target_file {
    Some(built) => built.program
    None => {
      fail_code("missing_file", "\{file} is not a readable .mbt file under \{dir}")
      return
    }
  }
  let built = match target_file {
    Some(value) => value
    None => return
  }
  let node = select_target(program, line, override_node)
  let sliced = if direction == "forward" {
    @slice.forward(built.pdg, node, program=program)
  } else {
    @slice.backward(built.pdg, node, program=program)
  }
  let slices = if interproc {
    @interproc.expand(index, target, sliced)
  } else {
    [
      @interproc.FileSlice::{
        path: target,
        nodes: sliced.nodes,
        lines: @query.visible_lines(program, sliced.nodes),
      },
    ]
  }
  let rendered = if json {
    slice_files_json(slices, errors)
  } else {
    let text = StringBuilder()
    let mut first = true
    for slice in slices {
      if !first {
        text.write_char('\n')
      }
      first = false
      text.write_string(slice.path)
      text.write_string(": ")
      text.write_string(lines_text(slice.lines))
    }
    let mut rendered = text.to_string()
    for message in errors {
      if rendered != "" {
        rendered = rendered + "\n"
      }
      rendered = rendered + "# error: " + message
    }
    rendered
  }
  if out_path == "" {
    println(rendered)
  } else {
    @fs.write_string_to_file(out_path, rendered) catch {
      @fs.IOError(msg) => fail_code("write_failed", "failed to write \{out_path}: \{msg}")
    }
    println("wrote \{out_path}")
  }
}

///|
fn run_callers(
  dir : String,
  name : String,
  json : Bool,
  out_path : String,
) -> Unit {
  let is_directory = @fs.is_dir(dir) catch {
    @fs.IOError(_) => false
  }
  if !is_directory {
    fail_code("read_failed", "not a directory: \{dir}")
  }
  let paths : Array[String] = []
  collect_mbt_files(dir, paths)
  paths.sort_by(fn(a, b) { a.lexical_compare(b) })
  let errors : Array[String] = []
  let files : Array[@interproc.PackageFile] = []
  for path in paths {
    match read_scan_file(path, errors) {
      None => ()
      Some(source) =>
        match @interproc.build_file(normalize_path(path), source) {
          None => errors.push(normalize_path(path) + ": parser diagnostic(s)")
          Some(built) => files.push(built)
        }
    }
  }
  let found = @interproc.callers(@interproc.index(files), name)
  let rendered = if json {
    let out = StringBuilder()
    out.write_string("{\"name\":")
    out.write_string(@report.json_string(name))
    out.write_string(",\"files\":")
    out.write_string(files.length().to_string())
    out.write_string(",\"callers\":[")
    let mut first = true
    for site in found {
      if !first {
        out.write_char(',')
      }
      first = false
      out.write_string("{\"file\":")
      out.write_string(@report.json_string(site.path))
      out.write_string(",\"line\":")
      out.write_string(site.line.to_string())
      out.write_string(",\"caller\":")
      out.write_string(@report.json_string(site.caller))
      out.write_string("}")
    }
    out.write_string("],\"errors\":[")
    first = true
    for message in errors {
      if !first {
        out.write_char(',')
      }
      first = false
      out.write_string(@report.json_string(message))
    }
    out.write_string("]}")
    out.to_string()
  } else {
    let text = StringBuilder()
    let mut first = true
    for site in found {
      if !first {
        text.write_char('\n')
      }
      first = false
      text.write_string(site.path)
      text.write_char(':')
      text.write_string(site.line.to_string())
      text.write_string(": ")
      text.write_string(site.caller)
    }
    text.to_string()
  }
  if out_path == "" {
    println(rendered)
  } else {
    @fs.write_string_to_file(out_path, rendered) catch {
      @fs.IOError(msg) => fail_code("write_failed", "failed to write \{out_path}: \{msg}")
    }
    println("wrote \{out_path}")
  }
}

///|
fn main {
  let argv = @env.args()
  json_mode[0] = prescan_json(argv)
  if argv.length() < 2 {
    usage()
    return
  }
  let command = argv[1]
  if command == "version" || command == "--version" {
    println("moon-slice " + tool_version)
    return
  }
  if command == "help" || command == "--help" {
    usage()
    return
  }
  if !known_command(command) {
    fail_code("unknown_command", "unknown command \{command}")
  }
  let mut file = ""
  let mut line = 0
  let mut direction = "backward"
  let mut format = "dot"
  let mut out = ""
  let mut json = false
  let mut interproc = false
  let mut from_var = ""
  let mut to_var = ""
  let mut node_override : Int32? = None
  let mut precise_cdg = false
  let mut diff_path = ""
  let mut with_control = false
  let mut baseline_path = ""
  let mut write_baseline = ""
  let mut fail_on_findings = false
  let mut dir_path = ""
  let mut name_var = ""
  let mut i = 2
  while i < argv.length() {
    let arg = argv[i]
    if arg == "--file" {
      file = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--line" {
      line = parse_line(require_value(argv, i, arg))
      i = i + 2
    } else if arg == "--direction" {
      direction = require_value(argv, i, arg)
      if direction != "backward" && direction != "forward" {
        fail_code("bad_direction", "unsupported --direction \{direction} (use backward or forward)")
      }
      i = i + 2
    } else if arg == "--format" {
      format = require_value(argv, i, arg)
      if format != "dot" && format != "json" && format != "sarif" {
        fail_code("bad_format", "unsupported --format \{format} (use dot, json, or sarif)")
      }
      if format == "sarif" && command != "dead" && command != "unused" {
        fail_code("bad_format", "--format sarif is only supported by dead and unused")
      }
      i = i + 2
    } else if arg == "--baseline" {
      baseline_path = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--write-baseline" {
      write_baseline = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--fail-on-findings" {
      fail_on_findings = true
      i = i + 1
    } else if arg == "--dir" {
      dir_path = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--name" {
      name_var = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--out" {
      out = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--from" {
      from_var = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--to" {
      to_var = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--node" {
      node_override = Some(parse_line(require_value(argv, i, arg)).to_int64().to_int())
      i = i + 2
    } else if arg == "--json" {
      json = true
      i = i + 1
    } else if arg == "--interprocedural" {
      interproc = true
      i = i + 1
    } else if arg == "--precise" {
      precise_cdg = true
      i = i + 1
    } else if arg == "--with-control" {
      with_control = true
      i = i + 1
    } else if arg == "--diff" {
      diff_path = require_value(argv, i, arg)
      i = i + 2
    } else {
      fail_code("unknown_argument", "unknown argument \{arg}")
    }
  }
  if command == "review" {
    if diff_path == "" {
      fail_code("missing_diff", "--diff is required for review")
    }
    run_review(diff_path, json)
    return
  }
  if command == "unused" {
    if dir_path == "" {
      fail_code("missing_dir", "unused scans a package: --dir D is required")
    }
    if file != "" {
      fail_code("bad_flag", "unused works on a package directory, not a single file")
    }
    run_unused_dir(
      dir_path,
      format,
      json,
      out,
      baseline_path,
      write_baseline,
      fail_on_findings,
    )
    return
  }
  // Package-scope slicing: --dir D names the package root, --file F the file to
  // slice inside it. Callees are then looked up across every file under D.
  if command == "callers" {
    if dir_path == "" {
      fail_code("missing_dir", "callers scans a package: --dir D is required")
    }
    if name_var == "" {
      fail_code("missing_name", "callers needs --name F: the function to look for")
    }
    if file != "" {
      fail_code("bad_flag", "callers works on a package directory, not a single file")
    }
    run_callers(dir_path, name_var, json, out)
    return
  }
  if dir_path != "" && command == "slice" {
    if file == "" {
      fail_code(
        "missing_file",
        "slice --dir D needs --file F: the file to slice inside D",
      )
    }
    require_line(command, line)
    run_slice_package(
      dir_path,
      file,
      line.to_int64().to_int(),
      node_override,
      direction,
      interproc,
      precise_cdg,
      json,
      out,
    )
    return
  }
  if dir_path != "" {
    if command != "dead" {
      fail_code("bad_flag", "--dir is only supported by dead, unused and slice")
    }
    if file != "" {
      fail_code("bad_flag", "use either --file or --dir, not both")
    }
    run_dead_dir(
      dir_path,
      format,
      json,
      out,
      baseline_path,
      write_baseline,
      fail_on_findings,
    )
    return
  }
  if file == "" {
    fail_code("missing_file", "--file is required")
  }
  require_line(command, line)
  if command == "path" && (from_var == "" || to_var == "") {
    fail_code("missing_path_args", "--from and --to are required")
  }
  if (baseline_path != "" || write_baseline != "") && command != "dead" {
    fail_code("bad_flag", "--baseline and --write-baseline are only supported by dead")
  }
  if baseline_path != "" && write_baseline != "" {
    fail_code("bad_flag", "use either --baseline or --write-baseline, not both")
  }
  if fail_on_findings && command != "dead" && command != "unused" {
    fail_code(
      "bad_flag",
      "--fail-on-findings is only supported by dead and unused",
    )
  }
  let source = read_source(file)
  let (program, cfg, defuse, pdg) = analyze(source, file, precise_cdg)
  if command != "dump-errors" && program.errors.length() > 0 {
    fail_code("parse_error", "source contains \{program.errors.length()} parser diagnostic(s); use dump-errors to inspect them")
  }
  match command {
    "slice" => {
      let target = select_target(program, line.to_int64().to_int(), node_override)
      let result = if direction == "forward" {
        @slice.forward(pdg, target, program~)
      } else {
        @slice.backward(pdg, target, program~)
      }
      let result = @core.SliceResult::{
        nodes: result.nodes,
        lines: @query.visible_lines(program, result.nodes),
      }
      let result = if interproc {
        @query.expand_calls(program, pdg, result)
      } else {
        result
      }
      if json {
        println(@report.to_json(program, result))
      } else {
        print_lines(result)
      }
    }
    "graph" =>
      if format == "json" {
        println(@report.to_graph_json(program, pdg))
      } else {
        println(@report.to_dot(pdg))
      }
    "compare" => {
      // Show what the post-dominator builder buys: the control edges the
      // structural rule invents, and (with --line) how the slice changes.
      let precise_cdg = @cdg.build_precise(program, cfg)
      let precise_pdg = @pdg.build(defuse, precise_cdg)
      let structural = control_edge_set(pdg)
      let precise = control_edge_set(precise_pdg)
      let removed : Array[(Int32, Int32)] = []
      for edge in structural {
        if !precise.contains(edge) {
          removed.push(edge)
        }
      }
      let added : Array[(Int32, Int32)] = []
      for edge in precise {
        if !structural.contains(edge) {
          added.push(edge)
        }
      }
      if json {
        println(
          "{\"structural_control_edges\":" +
          structural.length().to_string() +
          ",\"precise_control_edges\":" +
          precise.length().to_string() +
          ",\"removed\":" +
          pair_array_json(removed) +
          ",\"added\":" +
          pair_array_json(added) +
          "}",
        )
      } else {
        println("structural control edges: " + structural.length().to_string())
        println("precise control edges:    " + precise.length().to_string())
        println("removed by precise:       " + removed.length().to_string())
        for (from, to) in removed {
          println(
            "  n" +
            from.to_string() +
            " -> n" +
            to.to_string() +
            "  (lines " +
            program.nodes[from].loc.start_line.to_string() +
            " -> " +
            program.nodes[to].loc.start_line.to_string() +
            ")",
          )
        }
        println("added by precise:         " + added.length().to_string())
        for (from, to) in added {
          println(
            "  n" +
            from.to_string() +
            " -> n" +
            to.to_string() +
            "  (lines " +
            program.nodes[from].loc.start_line.to_string() +
            " -> " +
            program.nodes[to].loc.start_line.to_string() +
            ")",
          )
        }
        if line > 0 {
          let target = select_target(program, line.to_int64().to_int(), node_override)
          let before = @slice.backward(pdg, target, program~)
          let after = @slice.backward(precise_pdg, target, program~)
          let before_lines = @query.visible_lines(program, before.nodes)
          let after_lines = @query.visible_lines(program, after.nodes)
          println("slice line " + line.to_string() + " (structural): " + lines_text(before_lines))
          println("slice line " + line.to_string() + " (precise):    " + lines_text(after_lines))
        }
      }
    }
    "callgraph" => {
      let edges = @query.call_edges(program)
      if json {
        println(@report.to_call_json(edges))
      } else if edges.length() == 0 {
        println("no internal calls")
      } else {
        println(@report.to_call_dot(edges))
      }
    }
    "dead" => {
      let dead = @query.dead_nodes(program, defuse)
      let unreach = @query.unreachable_nodes(program, cfg)
      let all = @query.union_sorted(dead, unreach)
      if write_baseline != "" {
        write_baseline_file(write_baseline, file, all, program)
        return
      }
      let baseline = if baseline_path == "" {
        Set([])
      } else {
        parse_baseline(read_source(baseline_path))
      }
      let kept = filter_baseline(program, all, file, baseline)
      let suppressed = all.length() - kept.length()
      let result = @core.SliceResult::{
        nodes: kept,
        lines: @query.visible_lines(program, kept),
      }
      let rendered = if format == "sarif" {
        @report.to_sarif(file, program, kept, dead, suppressed, tool_version)
      } else if json {
        @report.to_dead_json(program, result, suppressed)
      } else {
        lines_text(result.lines)
      }
      if out == "" {
        println(rendered)
      } else {
        @fs.write_string_to_file(out, rendered) catch {
          @fs.IOError(msg) => fail_code("write_failed", "failed to write \{out}: \{msg}")
        }
        println("wrote \{out}")
      }
      if fail_on_findings && kept.length() > 0 {
        @sys.exit(1)
      }
    }
    "html" => {
      let target = select_target(program, line.to_int64().to_int(), node_override)
      let result = @slice.backward(pdg, target, program~)
      let result = @core.SliceResult::{
        nodes: result.nodes,
        lines: @query.visible_lines(program, result.nodes),
      }
      let result = if interproc {
        @query.expand_calls(program, pdg, result)
      } else {
        result
      }
      let html = @report.to_html(
        source,
        program,
        pdg,
        result,
        line.to_int64().to_int(),
        target,
      )
      if out == "" {
        println(html)
      } else {
        @fs.write_string_to_file(out, html) catch {
          @fs.IOError(msg) => fail_code("write_failed", "failed to write \{out}: \{msg}")
        }
        println("wrote \{out}")
      }
    }
    "path" => {
      if from_var == "" || to_var == "" {
        println("error: --from and --to are required")
        return
      }
      let mut starts = @query.nodes_defining_name(program, from_var)
      if starts.length() == 0 {
        starts = @query.nodes_with_name(program, from_var)
      }
      let mut goals = @query.nodes_using_name(program, to_var)
      if goals.length() == 0 {
        goals = @query.nodes_with_name(program, to_var)
      }
      match @query.path_between(pdg, starts, goals, with_control=with_control) {
        Some(path) => {
          let result = @core.SliceResult::{
            nodes: path,
            lines: @query.lines_of(program, path),
          }
          if json {
            println(@report.to_json(program, result))
          } else {
            let mut line_out = ""
            let mut first = true
            for id in path {
              if !first {
                line_out = line_out + " -> "
              }
              line_out = line_out +
                "n" +
                id.to_string() +
                " L" +
                program.nodes[id].loc.start_line.to_string()
              first = false
            }
            println(line_out)
          }
        }
        None =>
          if json {
            println("{\"found\":false}")
          } else {
            println("no path from \{from_var} to \{to_var}")
          }
      }
    }
    "dump-errors" => {
      println("errors \{program.errors.length()}")
      for e in program.errors {
        println(e)
      }
    }
    "dump-cfg" => {
      let cfg = @cfg.build(program)
      println("entry \{cfg.entry} exit \{cfg.exit}")
      for edge in cfg.edges {
        println("cfg \{edge.0} -> \{edge.1}")
      }
    }
    "dump-defuse" =>
      for pair in defuse.reaching {
        println("du \{pair.0} -> \{pair.1}")
      }
    "dump-pdg" =>
      for edge in pdg.edges {
        println("pdg \{edge.from} -> \{edge.to} \{edge_kind_name(edge.kind)}")
      }
    "dump" => {
      let ids = @query.nodes_at_line(program, line.to_int64().to_int())
      if ids.length() == 0 {
        println("no nodes at line \{line}")
      }
      for id in ids {
        let node = program.nodes[id]
        println(
          "node \{node.id} kind \{kind_name(node.kind)} line \{node.loc.start_line} defs [\{vars_str(node.defs)}] uses [\{vars_str(node.uses)}] children \{node.children.length()}",
        )
      }
    }
    _ => usage()
  }
}
