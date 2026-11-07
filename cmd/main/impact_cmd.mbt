// `impact`: the diff-aware impact certificate.
//
// This file holds no analysis. It parses `--lines` / `--diff`, loads the
// package (programs, PDGs, `FileFacts`), calls `@impact.impact`, and renders
// the certificate as text or JSON. `review` answers "which lines moved";
// `impact` answers "why, and what can see it": the forward-slice union, the
// reachable entries, the sibling files `@interproc` pulls in, the tests that
// call into the change, the calls the proof could not follow, and one shortest
// dependency path per affected statement.

///|
priv struct ImpactRequest {
  path : String
  lines : Array[Int32]
}

///|
/// Parse `--lines 1,2,3`. Blank pieces are ignored, so a trailing comma is
/// harmless; anything non-numeric or non-positive is a usage error.
fn parse_lines_flag(value : String) -> Array[Int32] {
  let out : Array[Int32] = []
  for piece in value.split(",") {
    let text = piece.trim().to_owned()
    if text == "" {
      continue
    }
    let parsed = @string.parse_int(text) catch {
      _ => {
        fail_code("bad_integer", "invalid integer for --lines: " + text)
        0
      }
    }
    if parsed <= 0 {
      fail_code("bad_integer", "--lines values must be positive: " + text)
    }
    out.push(parsed.to_int64().to_int())
  }
  out
}

///|
fn impact_file_at(
  index : @interproc.PackageIndex,
  path : String,
) -> @interproc.PackageFile? {
  for file in index.files {
    if file.path == path {
      return Some(file)
    }
  }
  None
}

///|
/// Read every `.mbt` file the impact run needs and build the package index and
/// the liveness facts. With `--dir`, the whole tree is loaded so calls into
/// sibling files and the reachability graph see the real package; without it,
/// only the files named by the request are loaded.
fn load_impact_package(
  requests : Array[ImpactRequest],
  dir : String,
  errors : Array[String],
) -> (@interproc.PackageIndex, Array[@liveness.FileFacts]) {
  let files : Array[@interproc.PackageFile] = []
  let facts : Array[@liveness.FileFacts] = []
  if dir != "" {
    let is_directory = @fs.is_dir(dir) catch {
      @fs.IOError(_) => false
    }
    if !is_directory {
      fail_code("read_failed", "not a directory: " + dir)
    }
    let paths : Array[String] = []
    collect_mbt_files(dir, paths)
    paths.sort_by(fn(a, b) { a.lexical_compare(b) })
    for path in paths {
      match read_scan_file(path, errors) {
        None => ()
        Some(source) => {
          let normalized = normalize_path(path)
          facts.push(@liveness.collect(normalized, source))
          match @interproc.build_file(normalized, source) {
            None => errors.push(normalized + ": parser diagnostic(s)")
            Some(built) => files.push(built)
          }
        }
      }
    }
  } else {
    let seen : Set[String] = Set([])
    for request in requests {
      let normalized = normalize_path(request.path)
      if seen.contains(normalized) {
        continue
      }
      seen.add(normalized)
      match read_scan_file(normalized, errors) {
        None => ()
        Some(source) => {
          facts.push(@liveness.collect(normalized, source))
          match @interproc.build_file(normalized, source) {
            None => errors.push(normalized + ": parser diagnostic(s)")
            Some(built) => files.push(built)
          }
        }
      }
    }
  }
  (@interproc.index(files), facts)
}

///|
fn impact_many_json(
  certificates : Array[(String, @impact.ImpactCertificate)],
) -> String {
  let out = StringBuilder()
  out.write_string("{\"files\":")
  out.write_string(certificates.length().to_string())
  out.write_string(",\"certificates\":[")
  let mut first = true
  for item in certificates {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"file\":")
    out.write_string(@report.json_string(item.0))
    out.write_string(",\"certificate\":")
    out.write_string(@impact.certificate_json(item.1))
    out.write_char('}')
  }
  out.write_string("]}")
  out.to_string()
}

///|
fn impact_many_text(
  certificates : Array[(String, @impact.ImpactCertificate)],
) -> String {
  let out = StringBuilder()
  let mut first = true
  for item in certificates {
    if !first {
      out.write_char('\n')
    }
    first = false
    out.write_string("== ")
    out.write_string(item.0)
    out.write_string(" ==\n")
    out.write_string(@impact.certificate_text(item.1))
  }
  out.to_string()
}

///|
/// `impact --file F --lines ...` or `impact --diff PATCH [--json] [--dir D]`.
fn run_impact(
  file : String,
  diff_path : String,
  lines_arg : String,
  dir : String,
  json : Bool,
  out_path : String,
) -> Unit {
  if file == "" && diff_path == "" {
    fail_code(
      "missing_file",
      "impact needs --file F --lines L1,L2 or --diff PATCH",
    )
  }
  if file != "" && diff_path != "" {
    fail_code("bad_flag", "use either --file or --diff, not both")
  }
  let requests : Array[ImpactRequest] = []
  let explicit_file = file != ""
  if explicit_file {
    if lines_arg == "" {
      fail_code("missing_lines", "--lines is required for impact --file")
    }
    let lines = parse_lines_flag(lines_arg)
    if lines.length() == 0 {
      fail_code("missing_lines", "--lines needs at least one line number")
    }
    requests.push(ImpactRequest::{ path: normalize_path(file), lines })
  } else {
    if lines_arg != "" {
      fail_code("bad_flag", "--lines and --diff are alternatives, not additions")
    }
    let diff = match read_optional(diff_path) {
      Some(text) => text
      None => {
        fail_code("read_failed", "failed to read " + diff_path)
        ""
      }
    }
    for hunk in parse_diff(diff) {
      if hunk.lines.length() > 0 && is_mbt_file(hunk.path) {
        requests.push(ImpactRequest::{ path: normalize_path(hunk.path), lines: hunk.lines })
      }
    }
    if requests.length() == 0 {
      fail_code("empty_diff", "the diff adds no .mbt line")
    }
  }
  let errors : Array[String] = []
  let (index, facts) = load_impact_package(requests, dir, errors)
  if errors.length() > 0 {
    // A certificate that skips an unreadable file is not a proof; the caller
    // can fix the input and run again.
    fail_code("read_failed", errors[0])
  }
  let reachability = @roots.analyze(facts)
  let certificates : Array[(String, @impact.ImpactCertificate)] = []
  for request in requests {
    match impact_file_at(index, request.path) {
      None =>
        if explicit_file {
          fail_code(
            "missing_file",
            request.path + " is not a readable .mbt file" +
            (if dir == "" { "" } else { " under " + dir }),
          )
        }
      Some(built) =>
        certificates.push((
          request.path,
          @impact.impact(
            built.program,
            built.pdg,
            request.lines,
            path=request.path,
            index=index,
            reachability=reachability,
          ),
        ))
    }
  }
  if certificates.length() == 0 {
    fail_code("missing_file", "no readable .mbt file to analyse")
  }
  let single = certificates.length() == 1 && explicit_file
  let rendered = if json {
    if single {
      @impact.certificate_json(certificates[0].1)
    } else {
      impact_many_json(certificates)
    }
  } else if single {
    @impact.certificate_text(certificates[0].1)
  } else {
    impact_many_text(certificates)
  }
  if out_path == "" {
    println(rendered)
  } else {
    @fs.write_string_to_file(out_path, rendered) catch {
      @fs.IOError(msg) => fail_code("write_failed", "failed to write " + out_path + ": " + msg)
    }
    println("wrote " + out_path)
  }
}
