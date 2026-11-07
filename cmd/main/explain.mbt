// Package-level explanations and receiver-call coverage.
//
// Three commands share one file because they share one input: every `.mbt`
// file under `--dir D`, normalized the same way the rest of the CLI does and
// handed to the package that owns the question.
//
//   explain-live --dir D --name F   the shortest chain that reaches F
//   explain-dead --dir D --name F   the proof that nothing reaches F
//   coverage     --dir D            how many receiver calls got an owner
//
// None of the analysis is here: `src/liveness` reads the files, `src/roots`
// builds the reachability graph, `src/resolve` classifies the calls. This file
// collects, renders, and turns "no answer" into exit 2 with a reason.

///|
/// The files of one package, sorted. `--dir D` names a package in every command
/// that uses this helper, so a path that is not a directory is a usage error,
/// not an empty result.
fn package_file_paths(dir : String) -> Array[String] {
  let is_directory = @fs.is_dir(dir) catch {
    @fs.IOError(_) => false
  }
  if !is_directory {
    fail_code("read_failed", "not a directory: \{dir}")
  }
  let paths : Array[String] = []
  collect_mbt_files(dir, paths)
  paths.sort_by(fn(a, b) { a.lexical_compare(b) })
  paths
}

///|
/// Read every `.mbt` file under `dir` as `(normalized path, source)`. A file
/// that cannot be read is collected in `errors` and left out, exactly like the
/// other directory scans.
fn read_package_sources(
  dir : String,
  errors : Array[String],
) -> Array[(String, String)] {
  let sources : Array[(String, String)] = []
  for path in package_file_paths(dir) {
    match read_scan_file(path, errors) {
      None => ()
      Some(source) => sources.push((normalize_path(path), source))
    }
  }
  sources
}

///|
/// The `FileFacts` input `src/roots` and `src/liveness` agree on: one entry per
/// readable file, keyed by the normalized path so sites are comparable.
fn read_package_facts(
  dir : String,
  errors : Array[String],
) -> Array[@liveness.FileFacts] {
  let facts : Array[@liveness.FileFacts] = []
  for (path, source) in read_package_sources(dir, errors) {
    facts.push(@liveness.collect(path, source))
  }
  facts
}

///|
/// Reachability is a claim about a whole package, so one unparsable file makes
/// the claim unsound. `src/roots` reports that as a skipped package; refusing
/// up front names the problem instead of returning "no function found".
fn require_parsable(dir : String, facts : Array[@liveness.FileFacts]) -> Unit {
  let mut bad = 0
  for fact in facts {
    if fact.parse_errors > 0 {
      bad = bad + 1
    }
  }
  if bad > 0 {
    fail_code(
      "parse_error",
      "\{bad} file(s) under \{dir} have parser diagnostics; reachability needs a package that parses",
    )
  }
}

///|
fn emit_report(rendered : String, out_path : String) -> Unit {
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
fn strings_json(items : Array[String]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  let mut first = true
  for item in items {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string(@report.json_string(item))
  }
  out.write_char(']')
  out.to_string()
}

///|
fn steps_json(steps : Array[@roots.PathStep]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  let mut first = true
  for step in steps {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"function\":")
    out.write_string(@report.json_string(step.function_name))
    out.write_string(",\"file\":")
    out.write_string(@report.json_string(step.path))
    out.write_string(",\"line\":")
    out.write_string(step.line.to_string())
    out.write_string("}")
  }
  out.write_char(']')
  out.to_string()
}

///|
/// One line per step: `file:line: caller -> callee`. The first step is the
/// root's declaration, so it has no caller; every later step's site is where
/// the previous function mentions the one it names.
fn render_live_path(path : @roots.LivePath) -> String {
  let out = StringBuilder()
  let mut i = 0
  while i < path.steps.length() {
    let step = path.steps[i]
    if i > 0 {
      out.write_char('\n')
    }
    out.write_string(step.path)
    out.write_char(':')
    out.write_string(step.line.to_string())
    out.write_string(": ")
    if i == 0 {
      out.write_string(step.function_name)
      out.write_string(" (root)")
    } else {
      out.write_string(path.steps[i - 1].function_name)
      out.write_string(" -> ")
      out.write_string(step.function_name)
    }
    i = i + 1
  }
  out.to_string()
}

///|
fn live_path_json(
  name : String,
  path : @roots.LivePath,
  files : Int,
  functions : Int,
  errors : Array[String],
) -> String {
  let out = StringBuilder()
  out.write_string("{\"name\":")
  out.write_string(@report.json_string(name))
  out.write_string(",\"reachable\":true,\"files\":")
  out.write_string(files.to_string())
  out.write_string(",\"functions\":")
  out.write_string(functions.to_string())
  out.write_string(",\"steps\":")
  out.write_string(steps_json(path.steps))
  out.write_string(",\"errors\":")
  out.write_string(strings_json(errors))
  out.write_char('}')
  out.to_string()
}

///|
/// The evidence, flattened into one sentence for a failure message. The
/// structured list is what `explain-dead --json` prints.
fn dead_reason_text(explanation : @roots.DeadExplanation) -> String {
  let mut text = ""
  for line in explanation.evidence {
    if text != "" {
      text = text + "; "
    }
    text = text + line
  }
  text
}

///|
fn render_dead(explanation : @roots.DeadExplanation) -> String {
  let out = StringBuilder()
  out.write_string("function: ")
  out.write_string(explanation.function_name)
  out.write_char('\n')
  out.write_string("declared: ")
  out.write_string(explanation.path)
  out.write_char(':')
  out.write_string(explanation.line.to_string())
  out.write_char('\n')
  out.write_string("searched: ")
  out.write_string(explanation.searched_files.to_string())
  out.write_string(" file(s), ")
  out.write_string(explanation.searched_functions.to_string())
  out.write_string(" function(s)\n")
  out.write_string("roots (")
  out.write_string(explanation.root_summary.length().to_string())
  out.write_string("):\n")
  for root in explanation.root_summary {
    out.write_string("  ")
    out.write_string(root)
    out.write_char('\n')
  }
  out.write_string("evidence:\n")
  for line in explanation.evidence {
    out.write_string("  - ")
    out.write_string(line)
    out.write_char('\n')
  }
  out.write_string("boundaries (")
  out.write_string(explanation.boundaries.length().to_string())
  out.write_string("):\n")
  for line in explanation.boundaries {
    out.write_string("  - ")
    out.write_string(line)
    out.write_char('\n')
  }
  out.to_string()
}

///|
fn dead_json(
  explanation : @roots.DeadExplanation,
  errors : Array[String],
) -> String {
  let out = StringBuilder()
  out.write_string("{\"function\":")
  out.write_string(@report.json_string(explanation.function_name))
  out.write_string(",\"file\":")
  out.write_string(@report.json_string(explanation.path))
  out.write_string(",\"line\":")
  out.write_string(explanation.line.to_string())
  out.write_string(",\"searched_files\":")
  out.write_string(explanation.searched_files.to_string())
  out.write_string(",\"searched_functions\":")
  out.write_string(explanation.searched_functions.to_string())
  out.write_string(",\"roots\":")
  out.write_string(strings_json(explanation.root_summary))
  out.write_string(",\"evidence\":")
  out.write_string(strings_json(explanation.evidence))
  out.write_string(",\"boundaries\":")
  out.write_string(strings_json(explanation.boundaries))
  out.write_string(",\"errors\":")
  out.write_string(strings_json(errors))
  out.write_char('}')
  out.to_string()
}

///|
/// The fixed report order of the reason categories. `by_reason` always carries
/// all four, so a renderer fixes the order instead of sorting map keys.
fn coverage_reasons() -> Array[@resolve.ResolveReason] {
  [
    @resolve.ResolveReason::UnknownReceiverType,
    @resolve.ResolveReason::MethodNotDeclared,
    @resolve.ResolveReason::ExternalPackage,
    @resolve.ResolveReason::DynamicValue,
  ]
}

///|
fn render_coverage(files : Int, report : @resolve.CoverageReport) -> String {
  let out = StringBuilder()
  out.write_string("files: ")
  out.write_string(files.to_string())
  out.write_char('\n')
  out.write_string("total: ")
  out.write_string(report.total.to_string())
  out.write_char('\n')
  out.write_string("resolved: ")
  out.write_string(report.resolved.to_string())
  out.write_char('\n')
  out.write_string("ambiguous: ")
  out.write_string(report.ambiguous.to_string())
  out.write_char('\n')
  out.write_string("unresolved: ")
  out.write_string(report.unresolved.to_string())
  out.write_char('\n')
  out.write_string("by_reason:\n")
  for reason in coverage_reasons() {
    out.write_string("  ")
    out.write_string(@resolve.reason_name(reason))
    out.write_string(": ")
    out.write_string(@resolve.reason_count(report, reason).to_string())
    out.write_char('\n')
  }
  out.to_string()
}

///|
fn coverage_json(
  files : Int,
  report : @resolve.CoverageReport,
  errors : Array[String],
) -> String {
  let out = StringBuilder()
  out.write_string("{\"files\":")
  out.write_string(files.to_string())
  out.write_string(",\"total\":")
  out.write_string(report.total.to_string())
  out.write_string(",\"resolved\":")
  out.write_string(report.resolved.to_string())
  out.write_string(",\"ambiguous\":")
  out.write_string(report.ambiguous.to_string())
  out.write_string(",\"unresolved\":")
  out.write_string(report.unresolved.to_string())
  out.write_string(",\"by_reason\":{")
  let mut first = true
  for reason in coverage_reasons() {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string(@report.json_string(@resolve.reason_name(reason)))
    out.write_char(':')
    out.write_string(@resolve.reason_count(report, reason).to_string())
  }
  out.write_string("},\"errors\":")
  out.write_string(strings_json(errors))
  out.write_char('}')
  out.to_string()
}

///|
fn run_explain_live(
  dir : String,
  name : String,
  json : Bool,
  out_path : String,
) -> Unit {
  let errors : Array[String] = []
  let facts = read_package_facts(dir, errors)
  if errors.length() > 0 {
    fail_code("read_failed", errors[0])
  }
  require_parsable(dir, facts)
  let reachability = @roots.analyze(facts)
  match reachability.sites.get(name) {
    None => fail_code("unknown_name", "\{name} is not declared in \{dir}")
    Some(_) => ()
  }
  match reachability.live_path(name) {
    Some(path) => {
      let rendered = if json {
        live_path_json(name, path, reachability.files, reachability.functions, errors)
      } else {
        render_live_path(path)
      }
      emit_report(rendered, out_path)
    }
    None => {
      let reason = match reachability.dead_reason(name) {
        Some(explanation) => dead_reason_text(explanation)
        None => "no root reaches it"
      }
      fail_code("unreachable", "\{name} is not reachable from any root: " + reason)
    }
  }
}

///|
fn run_explain_dead(
  dir : String,
  name : String,
  json : Bool,
  out_path : String,
) -> Unit {
  let errors : Array[String] = []
  let facts = read_package_facts(dir, errors)
  if errors.length() > 0 {
    fail_code("read_failed", errors[0])
  }
  require_parsable(dir, facts)
  let reachability = @roots.analyze(facts)
  match reachability.sites.get(name) {
    None => fail_code("unknown_name", "\{name} is not declared in \{dir}")
    Some(_) => ()
  }
  match reachability.dead_reason(name) {
    Some(explanation) => {
      let rendered = if json {
        dead_json(explanation, errors)
      } else {
        render_dead(explanation)
      }
      emit_report(rendered, out_path)
    }
    None => {
      // The question was "why is this dead?" and the answer is "it is not".
      // Name the chain so the caller can check the analysis agrees with them.
      let chain = match reachability.live_path(name) {
        Some(path) => path.steps.map(fn(step) { step.function_name }).join(" -> ")
        None => name
      }
      fail_code("reachable", "\{name} is reachable: " + chain)
    }
  }
}

///|
fn run_coverage(dir : String, json : Bool, out_path : String) -> Unit {
  let errors : Array[String] = []
  let sources : Array[@resolve.SourceFile] = []
  for (path, source) in read_package_sources(dir, errors) {
    sources.push(@resolve.source_file(path, source))
  }
  let resolutions = @resolve.resolve_package(sources)
  let report = @resolve.merged_coverage(resolutions)
  let rendered = if json {
    coverage_json(sources.length(), report, errors)
  } else {
    render_coverage(sources.length(), report)
  }
  emit_report(rendered, out_path)
}
