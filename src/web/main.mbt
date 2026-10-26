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
fn error_html(message : String) -> String {
  "<!doctype html><html><body style=\"margin:0;padding:2rem;background:#0f1115;color:#ffb4a2;font-family:ui-monospace,monospace\"><h2>moon-slice</h2><p>" +
  message +
  "</p></body></html>"
}

///|
fn main {
  let input = read_input()
  let parts = input.split("@@MOONSLICE@@").map(p => p.to_owned()).to_array()
  if parts.length() < 3 {
    write_output(error_html("bad input"))
    return
  }
  let direction = parts[0]
  let line = @string.parse_int(parts[1]) catch { _ => 0 }
  let source = parts[2]
  let program = @parser_adapter.parse_source(source, "playground.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let line32 : Int32 = line.to_int64().to_int()
  match @query.target_node(program, line32) {
    None => write_output(error_html("no statement starts at line \{line}"))
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
        @query.expand_calls(program, result)
      } else {
        result
      }
      let html = @report.to_html(source, program, pdg, result, line32, node)
      write_output(html)
    }
  }
}
