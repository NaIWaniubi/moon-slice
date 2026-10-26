// JSON / DOT / SVG / HTML rendering for slices.

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
    .replace(old="\n", new="\\n")
    .replace(old="\r", new="\\r")
    .replace(old="\t", new="\\t")
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
  let max_nodes_int = if n > 200 { 200 } else { n }
  let max_nodes : Int32 = max_nodes_int.to_int64().to_int()
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
  let mut svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" +
    width.to_string() +
    "\" height=\"" +
    height.to_string() +
    "\" viewBox=\"0 0 " +
    width.to_string() +
    " " +
    height.to_string() +
    "\">"
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
    "\" fill=\"#9aa0a6\" font-size=\"11\" font-family=\"monospace\">solid = data · dashed = control · orange = target · green = slice</text>"
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
    out = out + v.name + "#" + v.scope.to_string()
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
  if errs == "" {
    errs = "<li>none</li>"
  }
  let svg = to_svg(program, pdg, result, target_node)
  let mut rows = ""
  for id in result.nodes {
    if !is_synth(program, id) {
      let node = program.nodes[id]
      rows = rows +
        "<tr><td>n" +
        id.to_string() +
        "</td><td>" +
        svg_kind_name(node.kind) +
        "</td><td>" +
        node.loc.start_line.to_string() +
        "</td><td>" +
        vars_text(node.defs) +
        "</td><td>" +
        vars_text(node.uses) +
        "</td></tr>"
    }
  }
  let metrics = "nodes " +
    program.nodes.length().to_string() +
    " · edges " +
    pdg.edges.length().to_string() +
    " · slice nodes " +
    result.nodes.length().to_string() +
    " · slice lines " +
    result.lines.length().to_string()
  "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>moon-slice report</title>\n<style>\nbody{font-family:ui-monospace,Menlo,Consolas,monospace;margin:2rem;background:#0f1115;color:#d7dae0}\nh1{margin:0 0 .25rem}h1 span{color:#ffb74d}\n.muted{color:#9aa0a6}\n.hit{background:#1f3b2a;color:#b7f7c1}\npre{white-space:pre-wrap;line-height:1.45}\n.graph{margin:1rem 0;padding:1rem;background:#151922;border:1px solid #2b2f3a;border-radius:10px;overflow:auto}\n.graph svg{display:block;max-width:100%;height:auto;margin:0 auto}\n.metrics{color:#9aa0a6;font-size:13px}\ndetails{margin:.5rem 0}\nsummary{cursor:pointer;color:#8ab4f8}\ntable{border-collapse:collapse;width:100%;font-size:13px}\nth,td{border:1px solid #2b2f3a;padding:.3rem .55rem;text-align:left}\nth{background:#151922;color:#9aa0a6}\n</style>\n</head>\n<body>\n<h1>moon-slice <span>·</span> line " +
  target_line.to_string() +
  "</h1>\n<p class=\"metrics\">" +
  metrics +
  "</p>\n<div class=\"graph\">" +
  svg +
  "</div>\n<h2>Source</h2>\n<pre>" +
  body +
  "</pre>\n<h2>Slice nodes</h2>\n<table><thead><tr><th>node</th><th>kind</th><th>line</th><th>defs</th><th>uses</th></tr></thead><tbody>" +
  rows +
  "</tbody></table>\n<h2>Errors</h2>\n<ul>" +
  errs +
  "</ul>\n<details><summary>PDG (DOT)</summary>\n<pre>" +
  escape_html(to_dot(pdg)) +
  "</pre>\n</details>\n</body>\n</html>\n"
}
