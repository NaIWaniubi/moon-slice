// JSON / DOT / SVG / HTML rendering for slices.

///|
fn join_ints(xs : Array[Int32]) -> String {
  let out = StringBuilder()
  let mut first = true
  for x in xs {
    if !first {
      out.write_char(',')
    }
    out.write_string(x.to_string())
    first = false
  }
  out.to_string()
}

///|
pub fn json_string(s : String) -> String {
  let out = StringBuilder()
  for ch in s.iter() {
    match ch {
      '\\' => out.write_string("\\\\")
      '"' => out.write_string("\\\"")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      '\b' => out.write_string("\\b")
      '\f' => out.write_string("\\f")
      // `<` and `>` are escaped as `\u003c` / `\u003e` even though JSON allows
      // them literally: the same string is embedded in an HTML `<script>` block
      // (see to_result_json), where a literal `</script>` would end the block
      // early and turn analyser output into markup. JSON parsers decode the
      // escapes back, so the wire format is unchanged for consumers.
      '<' => out.write_string("\\u003c")
      '>' => out.write_string("\\u003e")
      _ => {
        let code = ch.to_int()
        if code < 0x20 {
          let hex = code.to_string(radix=16)
          out.write_string("\\u00")
          if hex.length() == 1 {
            out.write_char('0')
          }
          out.write_string(hex)
        } else {
          out.write_char(ch)
        }
      }
    }
  }
  "\"" + out.to_string() + "\""
}

///|
/// A stable machine-readable error object, for `--json` failure paths.
pub fn to_error_json(code : String, message : String) -> String {
  "{\"error\":{\"code\":" + json_string(code) + ",\"message\":" + json_string(message) + "}}"
}

///|
/// The machine-readable result embedded in the HTML report:
/// `{"target":{"line":..,"node":..},"nodes":[..],"lines":[..],"errors":[..]}`.
///
/// Nothing here is copied from the source, so a `</script>` in the analysed
/// file cannot break out of the block.
pub fn to_result_json(
  program : @core.Program,
  result : @core.SliceResult,
  target_line : Int32,
  target_node : Int32,
) -> String {
  let errors = StringBuilder()
  let mut first = true
  for e in program.errors {
    if !first {
      errors.write_char(',')
    }
    errors.write_string(json_string(e))
    first = false
  }
  "{\"target\":{\"line\":" +
  target_line.to_string() +
  ",\"node\":" +
  target_node.to_string() +
  "},\"nodes\":[" +
  join_ints(result.nodes) +
  "],\"lines\":[" +
  join_ints(result.lines) +
  "],\"errors\":[" +
  errors.to_string() +
  "]}"
}

///|
/// Node/edge listing for `graph --format json`.
///
/// Nodes are emitted in id order and edges in `(from, to, kind)` order, both
/// taken from the PDG, so equal inputs give byte-identical output. Synthetic
/// entry/exit nodes are included because a consumer may want the full graph;
/// `synthetic` says which they are.
pub fn to_graph_json(
  program : @core.Program,
  pdg : @core.Pdg,
) -> String {
  let nodes = StringBuilder()
  let mut first = true
  for node in program.nodes {
    if !first {
      nodes.write_char(',')
    }
    nodes.write_string("{\"id\":")
    nodes.write_string(node.id.to_string())
    nodes.write_string(",\"kind\":")
    nodes.write_string(json_string(edge_label_of_kind(node.kind)))
    nodes.write_string(",\"line\":")
    nodes.write_string(node.loc.start_line.to_string())
    nodes.write_string(",\"synthetic\":")
    nodes.write_string(if is_synth(program, node.id) { "true" } else { "false" })
    nodes.write_char('}')
    first = false
  }
  let edges = StringBuilder()
  first = true
  for edge in pdg.edges {
    if !first {
      edges.write_char(',')
    }
    edges.write_string("{\"from\":")
    edges.write_string(edge.from.to_string())
    edges.write_string(",\"to\":")
    edges.write_string(edge.to.to_string())
    edges.write_string(",\"kind\":")
    edges.write_string(json_string(edge_label(edge.kind)))
    edges.write_char('}')
    first = false
  }
  "{\"nodes\":[" + nodes.to_string() + "],\"edges\":[" + edges.to_string() + "]}"
}

///|
fn edge_label_of_kind(kind : @core.SNodeKind) -> String {
  match kind {
    @core.SNodeKind::Let => "let"
    @core.SNodeKind::LetMut => "let_mut"
    @core.SNodeKind::Assign => "assign"
    @core.SNodeKind::If => "if"
    @core.SNodeKind::While => "while"
    @core.SNodeKind::For => "for"
    @core.SNodeKind::Match => "match"
    @core.SNodeKind::Return => "return"
    @core.SNodeKind::Break => "break"
    @core.SNodeKind::Continue => "continue"
    @core.SNodeKind::Call => "call"
    @core.SNodeKind::Expr => "expr"
  }
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
  let out = StringBuilder()
  out.write_string("digraph pdg {\n  rankdir=LR;\n")
  for edge in pdg.edges {
    out.write_string("  n")
    out.write_string(edge.from.to_string())
    out.write_string(" -> n")
    out.write_string(edge.to.to_string())
    out.write_string(" [label=\"")
    out.write_string(edge_label(edge.kind))
    out.write_string("\"];\n")
  }
  out.write_string("}\n")
  out.to_string()
}

///|
fn escape_html(s : String) -> String {
  let out = StringBuilder()
  for ch in s.iter() {
    match ch {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&#39;")
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
fn svg_kind_name(kind : @core.SNodeKind) -> String {
  match kind {
    @core.SNodeKind::Let => "let"
    @core.SNodeKind::LetMut => "let mut"
    @core.SNodeKind::Assign => "assign"
    @core.SNodeKind::If => "if"
    @core.SNodeKind::While => "while"
    @core.SNodeKind::For => "for"
    @core.SNodeKind::Match => "match"
    @core.SNodeKind::Return => "return"
    @core.SNodeKind::Break => "break"
    @core.SNodeKind::Continue => "continue"
    @core.SNodeKind::Call => "call"
    @core.SNodeKind::Expr => "expr"
  }
}

///|
/// Self-contained SVG dependency graph. Nodes are laid out in BFS layers from
/// the PDG roots; cycles are capped, and the graph is truncated at 200 nodes so
/// a huge input cannot produce a multi-megabyte HTML file.
pub fn to_svg(
  program : @core.Program,
  pdg : @core.Pdg,
  result : @core.SliceResult,
  target_node : Int32,
) -> String {
  let n = program.nodes.length()
  if n == 0 {
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"360\" height=\"80\"><rect width=\"100%\" height=\"100%\" fill=\"#0f1115\"/><text x=\"16\" y=\"42\" fill=\"#d7dae0\" font-family=\"monospace\">empty program</text></svg>"
  }
  // The layout arrays below are indexed by node id. That is only valid when ids
  // are dense and equal to their position, which the adapter guarantees. A
  // hand-built Program with gaps would silently draw the wrong node, so refuse
  // instead of lying.
  let mut dense = true
  let mut probe = 0
  while probe < n {
    if program.nodes[probe].id != probe {
      dense = false
    }
    probe = probe + 1
  }
  if !dense {
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"420\" height=\"80\"><rect width=\"100%\" height=\"100%\" fill=\"#0f1115\"/><text x=\"16\" y=\"42\" fill=\"#ffb4a2\" font-family=\"monospace\">graph omitted: node ids are not dense</text></svg>"
  }
  let max_nodes_int = if n > 200 { 200 } else { n }
  let max_nodes : Int32 = max_nodes_int.to_int64().to_int()
  let truncated = n > 200
  let skip : Array[Bool] = []
  let mut i : Int32 = 0
  while i < max_nodes {
    let node = program.nodes[i]
    let mut synthetic = false
    for f in program.functions {
      if node.id == f.entry || node.id == f.exit {
        synthetic = true
      }
    }
    skip.push(synthetic)
    i = i + 1
  }
  // Source-order layout: unique non-synthetic start lines become layers. This
  // is deterministic and puts the graph in the same order a reader sees the
  // file, which is much easier to follow than a PDG BFS around loops.
  let lines : Array[Int32] = []
  i = 0
  while i < max_nodes {
    if !skip[i] {
      let line = program.nodes[i].loc.start_line
      if !lines.contains(line) {
        lines.push(line)
      }
    }
    i = i + 1
  }
  lines.sort()
  let max_layer : Int32 = if lines.length() == 0 {
    0
  } else {
    (lines.length() - 1).to_int64().to_int()
  }
  let layer : Array[Int32] = []
  i = 0
  while i < max_nodes {
    if skip[i] {
      layer.push(-1)
    } else {
      let line = program.nodes[i].loc.start_line
      let mut rank : Int32 = 0
      let mut j = 0
      while j < lines.length() {
        if lines[j] == line {
          rank = j.to_int64().to_int()
          j = lines.length()
        } else {
          j = j + 1
        }
      }
      layer.push(rank)
    }
    i = i + 1
  }
  let per_layer : Array[Int32] = []
  let mut l : Int32 = 0
  while l <= max_layer {
    per_layer.push(0)
    l = l + 1
  }
  i = 0
  while i < max_nodes {
    if !skip[i] {
      per_layer[layer[i]] = per_layer[layer[i]] + 1
    }
    i = i + 1
  }
  let cursor : Array[Int32] = []
  l = 0
  while l <= max_layer {
    cursor.push(0)
    l = l + 1
  }
  let xs : Array[Int32] = []
  let ys : Array[Int32] = []
  i = 0
  while i < max_nodes {
    if skip[i] {
      xs.push(0)
      ys.push(0)
    } else {
      let ly = layer[i]
      xs.push(40 + cursor[ly] * 180)
      ys.push(40 + ly * 90)
      cursor[ly] = cursor[ly] + 1
    }
    i = i + 1
  }
  let mut max_count : Int32 = 0
  l = 0
  while l < per_layer.length() {
    if per_layer[l] > max_count {
      max_count = per_layer[l]
    }
    l = l + 1
  }
  let width = 80 + max_count * 180
  let height = 90 + (max_layer + 1) * 90
  let mut svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-labelledby=\"graph-title graph-desc\" width=\"" +
    width.to_string() +
    "\" height=\"" +
    height.to_string() +
    "\" viewBox=\"0 0 " +
    width.to_string() +
    " " +
    height.to_string() +
    "\"><title id=\"graph-title\">Program dependence graph</title><desc id=\"graph-desc\">Solid edges are data dependencies; dashed edges are control dependencies. Orange is the target and green nodes are in the slice.</desc>"
  svg = svg +
    "<defs><marker id=\"arrow\" markerWidth=\"8\" markerHeight=\"8\" refX=\"7\" refY=\"3\" orient=\"auto\"><path d=\"M0,0 L0,6 L8,3 z\" fill=\"#9aa0a6\"/></marker></defs>"
  svg = svg + "<rect width=\"100%\" height=\"100%\" fill=\"#0f1115\"/>"
  for e in pdg.edges {
    if e.from >= 0 &&
      e.from < max_nodes &&
      e.to >= 0 &&
      e.to < max_nodes &&
      !skip[e.from] &&
      !skip[e.to] {
      let x1 = xs[e.from] + 45
      let y1 = ys[e.from] + 36
      let x2 = xs[e.to] + 45
      let y2 = ys[e.to]
      let color = match e.kind {
        @core.EdgeKind::Data => "#8ab4f8"
        @core.EdgeKind::Control => "#f6bd60"
      }
      let dash = match e.kind {
        @core.EdgeKind::Data => ""
        @core.EdgeKind::Control => " stroke-dasharray=\"5,4\""
      }
      svg = svg +
        "<line x1=\"" +
        x1.to_string() +
        "\" y1=\"" +
        y1.to_string() +
        "\" x2=\"" +
        x2.to_string() +
        "\" y2=\"" +
        y2.to_string() +
        "\" stroke=\"" +
        color +
        "\" stroke-width=\"1.5\"" +
        dash +
        " marker-end=\"url(#arrow)\"/>"
    }
  }
  i = 0
  while i < max_nodes {
    if skip[i] {
      i = i + 1
      continue
    }
    let node = program.nodes[i]
    let hit = result.nodes.contains(node.id)
    let fill = if node.id == target_node {
      "#ff9800"
    } else if hit {
      "#2e7d32"
    } else {
      "#2b2f3a"
    }
    let stroke = if node.id == target_node {
      "#ffb74d"
    } else if hit {
      "#81c784"
    } else {
      "#4b5563"
    }
    let label = "n" +
      node.id.to_string() +
      " L" +
      node.loc.start_line.to_string()
    svg = svg +
      "<g><rect x=\"" +
      xs[i].to_string() +
      "\" y=\"" +
      ys[i].to_string() +
      "\" width=\"90\" height=\"36\" rx=\"6\" fill=\"" +
      fill +
      "\" stroke=\"" +
      stroke +
      "\"/><text x=\"" +
      (xs[i] + 45).to_string() +
      "\" y=\"" +
      (ys[i] + 23).to_string() +
      "\" text-anchor=\"middle\" fill=\"#eef2f7\" font-size=\"12\" font-family=\"monospace\">" +
      label +
      "</text><title>" +
      escape_html(svg_kind_name(node.kind)) +
      " · line " +
      node.loc.start_line.to_string() +
      " · defs " +
      node.defs.length().to_string() +
      " · uses " +
      node.uses.length().to_string() +
      "</title></g>"
    i = i + 1
  }
  svg = svg +
    "<text x=\"16\" y=\"" +
    (height - 12).to_string() +
    "\" fill=\"#9aa0a6\" font-size=\"11\" font-family=\"monospace\">solid = data · dashed = control · orange = target · green = slice" +
    (if truncated {
      " · showing first 200 nodes; table and metrics contain the full result"
    } else {
      ""
    }) +
    "</text>"
  svg = svg + "</svg>"
  svg
}

///|
fn is_synth(program : @core.Program, id : Int32) -> Bool {
  for f in program.functions {
    if id == f.entry || id == f.exit {
      return true
    }
  }
  false
}

///|
fn vars_text(vars : Array[@core.VarId]) -> String {
  let mut out = ""
  let mut first = true
  for v in vars {
    if !first {
      out = out + ", "
    }
    out = out + escape_html(v.name) + "#" + v.scope.to_string()
    first = false
  }
  out
}

///|
pub fn to_html(
  source : String,
  program : @core.Program,
  pdg : @core.Pdg,
  result : @core.SliceResult,
  target_line : Int32,
  target_node : Int32,
) -> String {
  let lines = source.split("\n").map(line => line.to_owned()).to_array()
  // A set, not a linear scan per source line: the report may cover tens of
  // thousands of lines, and `has_line` per line would make it quadratic.
  let hit_lines : Set[Int32] = Set([])
  for line in result.lines {
    hit_lines.add(line)
  }
  let body = StringBuilder()
  let mut n : Int32 = 1
  for line in lines {
    let hit = hit_lines.contains(n)
    body.write_string("<span")
    if hit {
      body.write_string(" class=\"hit\"")
    }
    body.write_char('>')
    body.write_string(if hit { "•" } else { " " })
    body.write_char(' ')
    body.write_string(n.to_string())
    body.write_string("  ")
    body.write_string(escape_html(line))
    body.write_string("</span>\n")
    n = n + 1
  }
  let errs = StringBuilder()
  for e in program.errors {
    errs.write_string("<li>")
    errs.write_string(escape_html(e))
    errs.write_string("</li>")
  }
  if errs.is_empty() {
    errs.write_string("<li>none</li>")
  }
  let svg = to_svg(program, pdg, result, target_node)
  let rows = StringBuilder()
  // Index by declared id: a hand-built Program may have gaps, and `nodes[id]`
  // would then render the wrong statement.
  let text_by_id : Map[Int32, String] = Map([])
  for node in program.nodes {
    text_by_id.set(node.id, svg_kind_name(node.kind))
  }
  let line_by_id : Map[Int32, Int32] = Map([])
  for node in program.nodes {
    line_by_id.set(node.id, node.loc.start_line)
  }
  let defs_by_id : Map[Int32, String] = Map([])
  let uses_by_id : Map[Int32, String] = Map([])
  for node in program.nodes {
    defs_by_id.set(node.id, vars_text(node.defs))
    uses_by_id.set(node.id, vars_text(node.uses))
  }
  for id in result.nodes {
    match text_by_id.get(id) {
      None => ()
      Some(kind_text) =>
        if !is_synth(program, id) {
          let target = if id == target_node { " class=\"target\"" } else { "" }
          rows.write_string("<tr")
          rows.write_string(target)
          rows.write_string("><td>n")
          rows.write_string(id.to_string())
          rows.write_string("</td><td>")
          rows.write_string(kind_text)
          rows.write_string("</td><td>")
          let line_text = match line_by_id.get(id) {
            None => "?"
            Some(line) => line.to_string()
          }
          rows.write_string(line_text)
          rows.write_string("</td><td>")
          let defs_text = match defs_by_id.get(id) {
            None => ""
            Some(text) => text
          }
          rows.write_string(defs_text)
          rows.write_string("</td><td>")
          let uses_text = match uses_by_id.get(id) {
            None => ""
            Some(text) => text
          }
          rows.write_string(uses_text)
          rows.write_string("</td></tr>")
        }
    }
  }
  let metrics = "nodes " +
    program.nodes.length().to_string() +
    " · edges " +
    pdg.edges.length().to_string() +
    " · slice nodes " +
    result.nodes.length().to_string() +
    " · slice lines " +
    result.lines.length().to_string() +
    " · target n" +
    target_node.to_string() +
    " on line " +
    target_line.to_string()
  "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"generator\" content=\"moon-slice 0.5.0\">\n<title>moon-slice report</title>\n<style>\nbody{font-family:ui-monospace,Menlo,Consolas,monospace;margin:2rem;background:#0f1115;color:#d7dae0}\nh1{margin:0 0 .25rem}h1 span{color:#ffb74d}\n.muted{color:#9aa0a6}\n.hit{background:#1f3b2a;color:#b7f7c1}\npre{white-space:pre-wrap;line-height:1.45}\n.graph{margin:1rem 0;padding:1rem;background:#151922;border:1px solid #2b2f3a;border-radius:10px;overflow:auto}\n.graph svg{display:block;max-width:100%;height:auto;margin:0 auto}\n.metrics{color:#9aa0a6;font-size:13px}\ndetails{margin:.5rem 0}\nsummary{cursor:pointer;color:#8ab4f8}\ntable{border-collapse:collapse;width:100%;font-size:13px}\nth,td{border:1px solid #2b2f3a;padding:.3rem .55rem;text-align:left}\nth{background:#151922;color:#9aa0a6}\n</style>\n</head>\n<body>\n<h1>moon-slice <span>·</span> line " +
  target_line.to_string() +
  "</h1>\n<p class=\"metrics\">" +
  metrics +
  "</p>\n<div class=\"graph\">" +
  svg +
  "</div>\n<h2>Source</h2>\n<pre>" +
  body.to_string() +
  "</pre>\n<h2>Slice nodes</h2>\n<table><thead><tr><th scope=\"col\">node</th><th scope=\"col\">kind</th><th scope=\"col\">line</th><th scope=\"col\">defs</th><th scope=\"col\">uses</th></tr></thead><tbody>" +
  rows.to_string() +
  "</tbody></table>\n<h2>Errors</h2>\n<ul>" +
  errs.to_string() +
  "</ul>\n<details><summary>PDG (DOT)</summary>\n<pre>" +
  escape_html(to_dot(pdg)) +
  "</pre>\n</details>\n<script type=\"application/json\" id=\"moon-slice-result\">" +
  to_result_json(program, result, target_line, target_node) +
  "</script>\n</body>\n</html>\n"
}

///|
/// DOT for a function-level call graph.
pub fn to_call_dot(edges : Array[(String, String)]) -> String {
  let out = StringBuilder()
  out.write_string("digraph callgraph {\n  rankdir=LR;\n")
  for e in edges {
    out.write_string("  ")
    out.write_string(json_string(e.0))
    out.write_string(" -> ")
    out.write_string(json_string(e.1))
    out.write_string(";\n")
  }
  out.write_string("}\n")
  out.to_string()
}

///|
/// JSON array of `[caller, callee]` pairs, for tooling.
pub fn to_call_json(edges : Array[(String, String)]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  let mut first = true
  for e in edges {
    if !first {
      out.write_char(',')
    }
    out.write_char('[')
    out.write_string(json_string(e.0))
    out.write_char(',')
    out.write_string(json_string(e.1))
    out.write_char(']')
    first = false
  }
  out.write_char(']')
  out.to_string()
}

///|
/// `dead`'s JSON form. `suppressed` is the number of findings hidden by a
/// baseline; consumers that key on `nodes` keep working unchanged.
pub fn to_dead_json(
  program : @core.Program,
  result : @core.SliceResult,
  suppressed : Int,
) -> String {
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
  "],\"suppressed\":" +
  suppressed.to_string() +
  "}"
}

///|
/// Normalise a filesystem path into the forward-slash form SARIF expects.
/// Windows accepts both separators, but consumers compare URIs textually.
fn sarif_uri(path : String) -> String {
  let out = StringBuilder()
  for ch in path.iter() {
    match ch {
      '\\' => out.write_char('/')
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
fn sarif_node(program : @core.Program, id : Int32) -> @core.SNode? {
  for node in program.nodes {
    if node.id == id {
      return Some(node)
    }
  }
  None
}

///|
pub fn sarif_dead_message(node : @core.SNode) -> String {
  let names = StringBuilder()
  let mut first = true
  for variable in node.defs {
    if !first {
      names.write_string(", ")
    }
    names.write_string("`" + variable.name + "`")
    first = false
  }
  let target = names.to_string()
  if target == "" {
    "dead store: the assigned value is never read"
  } else {
    "dead store: the value assigned to " + target + " is never read"
  }
}

///|
pub fn to_sarif(
  file : String,
  program : @core.Program,
  ids : Array[Int32],
  dead : Array[Int32],
  suppressed : Int,
  version : String,
) -> String {
  let findings : Array[SarifFinding] = []
  for id in ids {
    match sarif_node(program, id) {
      None => ()
      Some(node) => {
        let is_dead = dead.contains(id)
        findings.push(SarifFinding::{
          file: sarif_uri(file),
          line: node.loc.start_line,
          rule: if is_dead { "dead-store" } else { "unreachable-code" },
          message: if is_dead {
            sarif_dead_message(node)
          } else {
            "unreachable code: no execution path reaches this statement"
          },
        })
      }
    }
  }
  to_sarif_findings(findings, suppressed, version, 1, 0)
}

///|
/// A finding already reduced to the fields SARIF needs. `file` is a URI path
/// (forward slashes); `rule` is `dead-store` or `unreachable-code`.
pub(all) struct SarifFinding {
  file : String
  line : Int32
  rule : String
  message : String
}

///|
/// Merge any number of files into one SARIF run. `files` is how many files were
/// analysed and `parse_failures` how many could not be parsed; both are exposed
/// as run properties so a CI job can tell "clean" from "did not look".
pub fn to_sarif_findings(
  findings : Array[SarifFinding],
  suppressed : Int,
  version : String,
  files : Int,
  parse_failures : Int,
) -> String {
  let out = StringBuilder()
  out.write_string(
    "{\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{\"name\":\"moon-slice\",\"informationUri\":\"https://github.com/cs6210501-lab/moon-slice\",\"version\":",
  )
  out.write_string(json_string(version))
  out.write_string(
    ",\"rules\":[{\"id\":\"dead-store\",\"name\":\"DeadStore\",\"shortDescription\":{\"text\":\"A value is assigned but never read\"},\"helpUri\":\"https://github.com/cs6210501-lab/moon-slice#dead-code\"},{\"id\":\"unreachable-code\",\"name\":\"UnreachableCode\",\"shortDescription\":{\"text\":\"A statement no execution path can reach\"},\"helpUri\":\"https://github.com/cs6210501-lab/moon-slice#dead-code\"}]}},",
  )
  out.write_string("\"invocations\":[{\"executionSuccessful\":")
  out.write_string(if parse_failures == 0 { "true" } else { "false" })
  out.write_string("}],\"results\":[")
  let mut first = true
  for finding in findings {
    let is_dead = finding.rule == "dead-store"
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"ruleId\":")
    out.write_string(json_string(finding.rule))
    out.write_string(",\"ruleIndex\":")
    out.write_string(if is_dead { "0" } else { "1" })
    out.write_string(",\"level\":\"warning\",\"message\":{\"text\":")
    out.write_string(json_string(finding.message))
    out.write_string("},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":")
    out.write_string(json_string(finding.file))
    out.write_string("},\"region\":{\"startLine\":")
    out.write_string(finding.line.to_string())
    out.write_string("}}}],\"partialFingerprints\":{\"moonSlice/v1\":")
    out.write_string(
      json_string(finding.file + ":" + finding.line.to_string() + ":" + finding.rule),
    )
    out.write_string("}}")
  }
  out.write_string("],\"properties\":{\"suppressed\":")
  out.write_string(suppressed.to_string())
  out.write_string(",\"files\":")
  out.write_string(files.to_string())
  out.write_string(",\"parseFailures\":")
  out.write_string(parse_failures.to_string())
  out.write_string("}}]}")
  out.to_string()
}

///|
/// JSON for a directory scan. Unlike `to_dead_json` this is keyed by file, so a
/// consumer does not have to assume node ids are meaningful across files.
pub fn to_scan_json(
  findings : Array[SarifFinding],
  files : Int,
  suppressed : Int,
  errors : Array[String],
) -> String {
  let out = StringBuilder()
  out.write_string("{\"findings\":[")
  let mut first = true
  for finding in findings {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"file\":")
    out.write_string(json_string(finding.file))
    out.write_string(",\"line\":")
    out.write_string(finding.line.to_string())
    out.write_string(",\"kind\":")
    out.write_string(json_string(finding.rule))
    out.write_string("}")
  }
  out.write_string("],\"files\":")
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
    out.write_string(json_string(message))
  }
  out.write_string("]}")
  out.to_string()
}
