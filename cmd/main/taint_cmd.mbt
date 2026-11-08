// `taint`: source-to-sink reachability over the PDG.
//
// This file holds no analysis. It loads the package, runs `@taint.analyze` per
// file, and renders the findings as text or JSON. The propagation rules and
// the sanitizer cut-off live in `src/taint`; the CLI only decides what to read
// and how to print it.

///|
/// Read every `.mbt` file under `dir`, build a program and PDG for each, and
/// run the taint analysis. Parse failures are collected, not fatal: a report
/// that silently skipped a file would not be a proof.
fn run_taint(
  dir : String,
  config_path : String,
  json : Bool,
  out_path : String,
  fail_on_findings : Bool,
) -> Unit {
  if dir == "" {
    fail_code("missing_dir", "taint scans a package: --dir D is required")
  }
  let is_directory = @fs.is_dir(dir) catch {
    @fs.IOError(_) => false
  }
  if !is_directory {
    fail_code("read_failed", "not a directory: " + dir)
  }
  let config = if config_path == "" {
    @taint.default_config()
  } else {
    match read_optional(config_path) {
      Some(text) => @taint.parse_config(text)
      None => {
        fail_code("read_failed", "failed to read " + config_path)
        @taint.default_config()
      }
    }
  }
  let paths : Array[String] = []
  collect_mbt_files(dir, paths)
  paths.sort_by(fn(a, b) { a.lexical_compare(b) })
  let errors : Array[String] = []
  let results : Array[(String, @taint.TaintReport)] = []
  for path in paths {
    match read_scan_file(path, errors) {
      None => ()
      Some(source) => {
        let normalized = normalize_path(path)
        match @interproc.build_file(normalized, source) {
          None => errors.push(normalized + ": parser diagnostic(s)")
          Some(built) =>
            results.push((
              normalized,
              @taint.analyze(built.program, built.pdg, config),
            ))
        }
      }
    }
  }
  let mut total = 0
  for result in results {
    total = total + result.1.findings.length()
  }
  let rendered = if json {
    let out = StringBuilder()
    out.write_string("{\"files\":[")
    let mut first = true
    for result in results {
      if !first {
        out.write_char(',')
      }
      first = false
      out.write_string("{\"path\":")
      out.write_string(@report.json_string(result.0))
      out.write_string(",\"report\":")
      out.write_string(@taint.report_json(result.1))
      out.write_char('}')
    }
    out.write_string("],\"findings\":")
    out.write_string(total.to_string())
    out.write_string(",\"errors\":[")
    let mut first_error = true
    for message in errors {
      if !first_error {
        out.write_char(',')
      }
      first_error = false
      out.write_string(@report.json_string(message))
    }
    out.write_string("]}")
    out.to_string()
  } else {
    let out = StringBuilder()
    for result in results {
      out.write_string("== ")
      out.write_string(result.0)
      out.write_string(" ==\n")
      out.write_string(@taint.report_text(result.1))
      out.write_char('\n')
    }
    for message in errors {
      out.write_string("# error: ")
      out.write_string(message)
      out.write_char('\n')
    }
    out.to_string()
  }
  if out_path == "" {
    println(rendered)
  } else {
    @fs.write_string_to_file(out_path, rendered) catch {
      @fs.IOError(msg) => fail_code(
        "write_failed",
        "failed to write \{out_path}: \{msg}",
      )
    }
    println("wrote \{out_path}")
  }
  if fail_on_findings && total > 0 {
    @sys.exit(1)
  }
}
