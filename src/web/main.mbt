// Browser entry point. The JS host defines two globals:
//   moonSliceReadInput() -> "direction@@MOONSLICE@@line@@MOONSLICE@@source"
//   moonSliceWriteOutput(html) -> unit
// The MoonBit side runs the full analysis pipeline and returns a self-contained
// HTML report, which the host renders in an iframe.

///|
extern "js" fn read_input() -> String = "moonSliceReadInput"

///|
extern "js" fn write_output(s : String) -> Unit = "moonSliceWriteOutput"

///|
fn escape_error_text(s : String) -> String {
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
fn error_html(message : String) -> String {
  "<!doctype html><html><body style=\"margin:0;padding:2rem;background:#0f1115;color:#ffb4a2;font-family:ui-monospace,monospace\"><h2>moon-slice</h2><p>" +
  escape_error_text(message) +
  "</p></body></html>"
}

///|
fn join_source(parts : Array[String]) -> String {
  let mut source = ""
  let mut i = 3
  while i < parts.length() {
    if i > 3 {
      source = source + "\n"
    }
    source = source + parts[i]
    i = i + 1
  }
  source
}

///|
fn main {
  let input = read_input()
  // The first three newline-delimited fields are controlled by the host
  // (direction, line, optional node id); everything after them is source text
  // and is joined without interpretation.
  let parts = input.split("\n").map(p => p.to_owned()).to_array()
  if parts.length() < 4 {
    write_output(error_html("bad input"))
    return
  }
  let direction = parts[0]
  let line = @string.parse_int(parts[1]) catch { _ => 0 }
  let node_field = parts[2]
  let source = join_source(parts)
  let program = @parser_adapter.parse_source(source, "playground.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let line32 : Int32 = line.to_int64().to_int()
  let requested : Int32? = if node_field == "" {
    None
  } else {
    let parsed = @string.parse_int(node_field) catch { _ => -1 }
    Some(parsed.to_int64().to_int())
  }
  let target = match requested {
    Some(id) =>
      match @query.node_exists(program, id) {
        true => Some(id)
        false => None
      }
    None => @query.target_node(program, line32)
  }
  match target {
    None =>
      match requested {
        Some(id) => write_output(error_html("no node with id \{id}"))
        None => write_output(error_html("no statement starts at line \{line}"))
      }
    Some(node) => {
      let result = if direction == "forward" {
        @slice.forward(pdg, node, program~)
      } else {
        @slice.backward(pdg, node, program~)
      }
      let result = @core.SliceResult::{
        nodes: result.nodes,
        lines: @query.visible_lines(program, result.nodes),
      }
      let result = if direction == "interprocedural" {
        @query.expand_calls(program, pdg, result)
      } else {
        result
      }
      let html = @report.to_html(source, program, pdg, result, line32, node)
      write_output(html)
    }
  }
}
