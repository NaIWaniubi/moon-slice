// `review`: diff-aware slicing.
//
// Given a unified diff, find the `.mbt` lines it adds, forward-slice each of
// them, and report the lines and functions those changes can affect. This is the
// question a reviewer actually asks before merging: "what does this diff touch
// beyond what it appears to touch?"
//
// The diff is read from a file rather than obtained by running git here, so the
// command stays testable and has no process dependency; `tools/review.sh`
// produces the diff with git.

///|
priv struct DiffHunk {
  path : String
  lines : Array[Int32]
}

///|
/// Parse a unified diff into `path -> added/modified new-file line numbers`.
///
/// Only added lines are collected: a deleted line has no new-file position to
/// slice, and a context line is unchanged behaviour. Callers are expected to
/// produce the diff with `-U0`, which keeps this simple and deterministic.
fn parse_diff(diff : String) -> Array[DiffHunk] {
  let hunks : Array[DiffHunk] = []
  let mut current : DiffHunk? = None
  let mut new_line : Int32 = 0
  for raw in diff.split("\n") {
    let line = raw.to_owned()
    if line.has_prefix("+++ ") {
      let path = line[4:].to_owned()
      let path = if path.has_prefix("b/") { path[2:].to_owned() } else { path }
      if path == "/dev/null" {
        current = None
      } else {
        let hunk : DiffHunk = { path, lines: [], }
        hunks.push(hunk)
        current = Some(hunk)
      }
    } else if line.has_prefix("@@ ") {
      // `@@ -a,b +c,d @@` — only the new-file start matters.
      let plus = line.find(" +")
      match plus {
        None => ()
        Some(index) => {
          let rest = line[index + 2:].to_owned()
          let comma = rest.find(",")
          let space = rest.find(" ")
          let stop = match (comma, space) {
            (Some(c), Some(s)) => if c < s { c } else { s }
            (Some(c), None) => c
            (None, Some(s)) => s
            (None, None) => rest.length()
          }
          let digits = rest[:stop].to_owned()
          new_line = @string.parse_int(digits) catch { _ => 0 }
        }
      }
    } else if line.has_prefix("+") && !line.has_prefix("+++") {
      match current {
        None => ()
        Some(hunk) =>
          if new_line > 0 {
            if !hunk.lines.contains(new_line) {
              hunk.lines.push(new_line)
            }
            new_line = new_line + 1
          }
      }
    } else if line.has_prefix(" ") {
      // Context line (only with -U>0): it exists in the new file too.
      if new_line > 0 {
        new_line = new_line + 1
      }
    }
  }
  hunks
}

///|
/// Read a file, or `None` when it cannot be read. `review` skips unreadable
/// files (a diff may reference a deleted path) instead of failing the run.
fn read_optional(path : String) -> String? {
  let ok = [true]
  let text = @fs.read_file_to_string(path) catch {
    @fs.IOError(_) => {
      ok[0] = false
      ""
    }
  }
  if ok[0] {
    Some(text)
  } else {
    None
  }
}

///|
/// Lines affected by a diff, per file, computed by forward-slicing every
/// changed line that resolves to a statement.
fn review_file(
  path : String,
  changed : Array[Int32],
) -> Array[Int32] {
  let source = match read_optional(path) {
    None => return []
    Some(text) => text
  }
  let program = @parser_adapter.parse_source(source, path)
  if program.errors.length() > 0 {
    return []
  }
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let affected : Array[Int32] = []
  for line in changed {
    let node = match @query.target_node(program, line) {
      Some(id) => id
      None => continue
    }
    let slice = @slice.forward(pdg, node, program~)
    for id in slice.nodes {
      let node = program.nodes[id]
      let line = node.loc.start_line
      if line > 0 && !affected.contains(line) {
        affected.push(line)
      }
    }
  }
  affected.sort()
  affected
}

///|
/// Function names that contain at least one of `lines`.
fn functions_touching(
  program : @core.Program,
  lines : Array[Int32],
) -> Array[String] {
  let out : Array[String] = []
  for function in program.functions {
    let mut hit = false
    for id in lines {
      if id >= function.entry && id <= function.exit {
        hit = true
      }
    }
    if hit && !out.contains(function.name) {
      out.push(function.name)
    }
  }
  out
}

///|
fn lines_csv(lines : Array[Int32]) -> String {
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
fn names_json(names : Array[String]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  let mut first = true
  for name in names {
    if !first {
      out.write_char(',')
    }
    out.write_string(@report.json_string(name))
    first = false
  }
  out.write_char(']')
  out.to_string()
}

///|
/// Entry point for `review --diff FILE [--json]`.
fn run_review(diff_path : String, json : Bool) -> Unit {
  let diff = match read_optional(diff_path) {
    Some(text) => text
    None => {
      fail_code("read_failed", "failed to read \{diff_path}")
      ""
    }
  }
  let hunks = parse_diff(diff)
  let records = StringBuilder()
  let mut first = true
  let mut total_changed = 0
  let mut total_affected = 0
  for hunk in hunks {
    if hunk.lines.length() == 0 {
      continue
    }
    let affected = review_file(hunk.path, hunk.lines)
    let source = match read_optional(hunk.path) {
      None => ""
      Some(text) => text
    }
    let program = @parser_adapter.parse_source(source, hunk.path)
    let functions = functions_touching(program, affected)
    total_changed = total_changed + hunk.lines.length()
    total_affected = total_affected + affected.length()
    if json {
      if !first {
        records.write_char(',')
      }
      records.write_string("{\"file\":")
      records.write_string(@report.json_string(hunk.path))
      records.write_string(",\"changed\":[")
      records.write_string(lines_csv(hunk.lines))
      records.write_string("],\"affected\":[")
      records.write_string(lines_csv(affected))
      records.write_string("],\"functions\":")
      records.write_string(names_json(functions))
      records.write_char('}')
      first = false
    } else {
      println(
        hunk.path +
        ": changed " +
        hunk.lines.length().to_string() +
        " line(s) -> affected " +
        affected.length().to_string() +
        " line(s)" +
        (if functions.length() > 0 {
          " in " + functions.join(", ")
        } else {
          ""
        }),
      )
      if affected.length() > 0 {
        println("  affected lines: " + lines_csv(affected))
      }
    }
  }
  if json {
    println(
      "{\"files\":" +
      hunks.length().to_string() +
      ",\"changed\":" +
      total_changed.to_string() +
      ",\"affected\":" +
      total_affected.to_string() +
      ",\"records\":[" +
      records.to_string() +
      "]}",
    )
  } else {
    println(
      "review: " +
      hunks.length().to_string() +
      " file(s), " +
      total_changed.to_string() +
      " changed line(s), " +
      total_affected.to_string() +
      " affected line(s)",
    )
  }
}
