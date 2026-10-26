// JSON / DOT / HTML rendering for slices.

///|
fn join_ints(xs : Array[Int32]) -> String {
  let mut out = ""
  let mut first = true
  for x in xs {
    if !first {
      out = out + ","
    }
    out = out + x.to_string()
    first = false
  }
  out
}

///|
fn json_string(s : String) -> String {
  let escaped = s
    .replace(old="\\", new="\\\\")
    .replace(old="\"", new="\\\"")
    .replace(old="\n", new="\n")
    .replace(old="\r", new="\r")
    .replace(old="\t", new="\t")
  "\"" + escaped + "\""
}

///|
pub fn to_json(program : @core.Program, result : @core.SliceResult) -> String {
  let mut errors = ""
  let mut first = true
  for e in program.errors {
    if !first {
      errors = errors + ","
    }
    errors = errors + json_string(e)
    first = false
  }
  "{\"nodes\":[" +
  join_ints(result.nodes) +
  "],\"lines\":[" +
  join_ints(result.lines) +
  "],\"errors\":[" +
  errors +
  "]}"
}

///|
fn edge_label(kind : @core.EdgeKind) -> String {
  match kind {
    @core.EdgeKind::Data => "data"
    @core.EdgeKind::Control => "control"
  }
}

///|
pub fn to_dot(pdg : @core.Pdg) -> String {
  let mut out = "digraph pdg {\n  rankdir=LR;\n"
  for edge in pdg.edges {
    out = out +
      "  n" +
      edge.from.to_string() +
      " -> n" +
      edge.to.to_string() +
      " [label=\"" +
      edge_label(edge.kind) +
      "\"];\n"
  }
  out = out + "}\n"
  out
}

///|
fn escape_html(s : String) -> String {
  s
  .replace(old="&", new="&amp;")
  .replace(old="<", new="&lt;")
  .replace(old=">", new="&gt;")
}

///|
fn has_line(lines : Array[Int32], line : Int32) -> Bool {
  for l in lines {
    if l == line {
      return true
    }
  }
  false
}

///|
pub fn to_html(
  source : String,
  program : @core.Program,
  result : @core.SliceResult,
  target_line : Int32,
  dot : String,
) -> String {
  let lines = source.split("\n").map(line => line.to_owned()).to_array()
  let mut body = ""
  let mut n : Int32 = 1
  for line in lines {
    let hit = has_line(result.lines, n)
    let cls = if hit { " class=\"hit\"" } else { "" }
    let marker = if hit { "•" } else { " " }
    body = body +
      "<span" +
      cls +
      ">" +
      marker +
      " " +
      n.to_string() +
      "  " +
      escape_html(line) +
      "</span>\n"
    n = n + 1
  }
  let mut errs = ""
  for e in program.errors {
    errs = errs + "<li>" + escape_html(e) + "</li>"
  }
  "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>moon-slice report</title>\n<style>\nbody{font-family:ui-monospace,Menlo,Consolas,monospace;margin:2rem;background:#0f1115;color:#d7dae0}\n.hit{background:#1f3b2a;color:#b7f7c1}\npre{white-space:pre-wrap}\n</style>\n</head>\n<body>\n<h1>moon-slice</h1>\n<p>Target line: " +
  target_line.to_string() +
  " · slice lines: " +
  join_ints(result.lines) +
  "</p>\n<pre>" +
  body +
  "</pre>\n<h2>Errors</h2>\n<ul>" +
  errs +
  "</ul>\n<h2>PDG (DOT)</h2>\n<pre>" +
  escape_html(dot) +
  "</pre>\n</body>\n</html>\n"
}
