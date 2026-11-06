// A minimal Language Server for MoonBit: dead stores and unreachable code as
// diagnostics, pushed on every open/change.
//
// The transport is LSP over stdio: `Content-Length` header lines, then a JSON
// body. `@stdio.stdin.read_until("\r\n")` gives one header line at a time and
// `read_exactly` gives the body, so the framing is handled by the async runtime
// rather than by a hand-rolled buffer.

///|
/// One document the editor has open, keyed by URI.
let documents : Map[String, String] = Map([])

///|
fn hex_char(value : Int) -> Char {
  if value < 10 {
    ('0'.to_int() + value).unsafe_to_char()
  } else {
    ('a'.to_int() + value - 10).unsafe_to_char()
  }
}

///|
fn json_escape(text : String) -> String {
  let out = StringBuilder()
  for ch in text.iter() {
    match ch {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      _ => {
        let code = ch.to_int()
        if code < 32 {
          out.write_string("\\u00")
          out.write_char(hex_char((code / 16) % 16))
          out.write_char(hex_char(code % 16))
        } else {
          out.write_char(ch)
        }
      }
    }
  }
  out.to_string()
}

///|
fn json_string(text : String) -> String {
  "\"" + json_escape(text) + "\""
}

///|
async fn send(payload : String) -> Unit {
  let bytes = @utf8.encode(payload)
  @stdio.stdout.write("Content-Length: " + bytes.length().to_string() + "\r\n\r\n")
  @stdio.stdout.write(bytes)
}

///|
async fn send_response(id : String, result : String) -> Unit {
  send(
    "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":" + result + "}",
  )
}

///|
fn parse_content_length(line : String) -> Int {
  let mut value = 0
  let mut seen = false
  for ch in line.iter() {
    let code = ch.to_int()
    if code >= '0'.to_int() && code <= '9'.to_int() {
      value = value * 10 + (code - '0'.to_int())
      seen = true
    }
  }
  if seen { value } else { -1 }
}

///|
/// Read one framed message, or `None` when the editor closed the stream.
async fn read_message() -> String? {
  let mut length = -1
  while true {
    let line = match @stdio.stdin.read_until("\r\n") {
      None => return None
      Some(line) => line
    }
    if line == "" {
      break
    }
    if line.has_prefix("Content-Length:") {
      length = parse_content_length(line)
    }
  }
  if length < 0 {
    return None
  }
  let body = @stdio.stdin.read_exactly(length)
  Some(@utf8.decode_lossy(body))
}

///|
/// One finding at a line, ready to be turned into a diagnostic.
struct Finding {
  line : Int32
  start_col : Int32
  end_col : Int32
  rule : String
  message : String
}

///|
fn findings_for(source : String, uri : String) -> Array[Finding] {
  let out : Array[Finding] = []
  let program = @parser_adapter.parse_source(source, uri)
  if program.errors.length() > 0 {
    // A file that does not parse gets one diagnostic per parser report; the
    // report text already carries the line, so it is shown as the message.
    for error in program.errors {
      out.push(Finding::{
        line: 1,
        start_col: 0,
        end_col: 0,
        rule: "parse-error",
        message: error,
      })
    }
    return out
  }
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let dead = @query.dead_nodes(program, defuse)
  let unreached = @query.unreachable_nodes(program, cfg)
  let ids = @query.union_sorted(dead, unreached)
  for id in ids {
    match @query.node_by_id(program, id) {
      None => ()
      Some(node) => {
        let is_dead = dead.contains(id)
        out.push(Finding::{
          line: node.loc.start_line,
          start_col: node.loc.start_col,
          end_col: node.loc.end_col,
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
  out
}

///|
fn diagnostics_json(source : String, uri : String) -> String {
  let out = StringBuilder()
  let findings = findings_for(source, uri)
  out.write_string("[")
  let mut first = true
  for finding in findings {
    if !first {
      out.write_char(',')
    }
    first = false
    let line = if finding.line > 0 { finding.line - 1 } else { 0 }
    out.write_string("{\"range\":{\"start\":{\"line\":")
    out.write_string(line.to_string())
    out.write_string(",\"character\":")
    out.write_string(finding.start_col.to_string())
    out.write_string("},\"end\":{\"line\":")
    out.write_string(line.to_string())
    out.write_string(",\"character\":")
    out.write_string(finding.end_col.to_string())
    out.write_string("}},\"severity\":")
    // A parser failure is an error; a dead store is a warning.
    out.write_string(if finding.rule == "parse-error" { "1" } else { "2" })
    out.write_string(",\"source\":\"moon-slice\",\"code\":")
    out.write_string(json_string(finding.rule))
    out.write_string(",\"message\":")
    out.write_string(json_string(finding.message))
    out.write_string("}")
  }
  out.write_string("]")
  out.to_string()
}

///|
async fn publish(uri : String) -> Unit {
  let source = match documents.get(uri) {
    Some(text) => text
    None => ""
  }
  send(
    "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":" +
    json_string(uri) +
    ",\"diagnostics\":" +
    diagnostics_json(source, uri) +
    "}}",
  )
}

///|
/// Length of one 0-based line, without its line terminator.
fn line_length(source : String, line0 : Int) -> Int {
  let lines = source.split("\n").to_array()
  if line0 < 0 || line0 >= lines.length() {
    return 0
  }
  let mut text = lines[line0].to_owned()
  if text.has_suffix("\r") {
    text = text[: text.length() - 1].to_owned()
  }
  text.length()
}

///|
/// Hover: the backward slice for the line under the cursor, as Markdown.
fn hover_result(uri : String, line0 : Int) -> String {
  let source = match documents.get(uri) {
    Some(text) => text
    None => ""
  }
  let program = @parser_adapter.parse_source(source, uri)
  if program.errors.length() > 0 {
    return "null"
  }
  match @query.target_node(program, line0 + 1) {
    None => "null"
    Some(node) => {
      let cfg = @cfg.build(program)
      let defuse = @defuse.analyze(program, cfg)
      let cdg = @cdg.build(program, cfg)
      let pdg = @pdg.build(defuse, cdg)
      let result = @slice.backward(pdg, node, program=program)
      let lines = @query.visible_lines(program, result.nodes)
      let text = StringBuilder()
      text.write_string("**backward slice** — ")
      text.write_string(result.nodes.length().to_string())
      text.write_string(" statement(s) reach this line\n\nlines: ")
      let mut first = true
      for line in lines {
        if !first {
          text.write_string(", ")
        }
        first = false
        text.write_string(line.to_string())
      }
      "{\"contents\":{\"kind\":\"markdown\",\"value\":" +
      json_string(text.to_string()) +
      "},\"range\":{\"start\":{\"line\":" +
      line0.to_string() +
      ",\"character\":0},\"end\":{\"line\":" +
      line0.to_string() +
      ",\"character\":0}}}"
    }
  }
}

///|
/// A quick fix that appends `// moon-slice: ignore[rule]` to the line, which is
/// the same directive the CLI honours.
fn code_actions_result(uri : String, line0 : Int, rule : String) -> String {
  let source = match documents.get(uri) {
    Some(text) => text
    None => ""
  }
  let column = line_length(source, line0)
  let insert = " // moon-slice: ignore[" + rule + "]"
  let title = "Suppress with // moon-slice: ignore[" + rule + "]"
  "[{\"title\":" +
  json_string(title) +
  ",\"kind\":\"quickfix\",\"edit\":{\"changes\":{" +
  json_string(uri) +
  ":[{\"range\":{\"start\":{\"line\":" +
  line0.to_string() +
  ",\"character\":" +
  column.to_string() +
  "},\"end\":{\"line\":" +
  line0.to_string() +
  ",\"character\":" +
  column.to_string() +
  "}},\"newText\":" +
  json_string(insert) +
  "}]}}}]"
}

///|
/// Returns `false` when the editor asked the server to exit.
///
/// The Json type is never named here: it is reached through pattern matching on
/// the value `@json.parse` returns, which keeps the file compiling across core
/// versions that disagree about where the type is declared.
async fn handle_message(text : String) -> Bool {
  let parsed = @json.parse(text) catch {
    _ => return true
  }
  let object = match parsed {
    Object(map) => map
    _ => return true
  }
  let method_name = match object.get("method") {
    Some(String(name)) => name
    _ => return true
  }
  // A request carries an id; a notification does not and gets no response.
  let id = match object.get("id") {
    Some(value) => value.stringify()
    None => ""
  }
  match method_name {
    "initialize" =>
      send_response(
        id,
        "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"codeActionProvider\":true,\"diagnosticProvider\":{\"interFileDependencies\":false,\"workspaceDiagnostics\":false}},\"serverInfo\":{\"name\":\"moon-slice\",\"version\":0}}",
      )
    "initialized" => ()
    "shutdown" => send_response(id, "null")
    "textDocument/hover" => {
      match object.get("params") {
        Some(Object(params)) =>
          match (params.get("textDocument"), params.get("position")) {
            (Some(Object(document)), Some(Object(position))) =>
              match (document.get("uri"), position.get("line")) {
                (Some(String(uri)), Some(Number(value, ..))) =>
                  send_response(id, hover_result(uri, value.to_int()))
                _ => send_response(id, "null")
              }
            _ => send_response(id, "null")
          }
        _ => send_response(id, "null")
      }
    }
    "textDocument/codeAction" => {
      match object.get("params") {
        Some(Object(params)) =>
          match (params.get("textDocument"), params.get("context")) {
            (Some(Object(document)), Some(Object(context))) =>
              match (document.get("uri"), context.get("diagnostics")) {
                (Some(String(uri)), Some(Array(items))) => {
                  let mut rule = ""
                  let mut line0 = 0
                  for item in items {
                    match item {
                      Object(diagnostic) =>
                        if rule == "" {
                          match diagnostic.get("code") {
                            Some(String(code)) =>
                              if code == "dead-store" || code == "unreachable-code" {
                                rule = code
                                match diagnostic.get("range") {
                                  Some(Object(range)) =>
                                    match range.get("start") {
                                      Some(Object(start)) =>
                                        match start.get("line") {
                                          Some(Number(value, ..)) =>
                                            line0 = value.to_int()
                                          _ => ()
                                        }
                                      _ => ()
                                    }
                                  _ => ()
                                }
                              }
                            _ => ()
                          }
                        }
                      _ => ()
                    }
                  }
                  if rule == "" {
                    send_response(id, "[]")
                  } else {
                    send_response(id, code_actions_result(uri, line0, rule))
                  }
                }
                _ => send_response(id, "[]")
              }
            _ => send_response(id, "[]")
          }
        _ => send_response(id, "[]")
      }
    }
    "exit" => return false
    "textDocument/didOpen" => {
      match object.get("params") {
        Some(Object(params)) =>
          match params.get("textDocument") {
            Some(Object(document)) =>
              match (document.get("uri"), document.get("text")) {
                (Some(String(uri)), Some(String(source))) => {
                  documents.set(uri, source)
                  publish(uri)
                }
                _ => ()
              }
            _ => ()
          }
        _ => ()
      }
    }
    "textDocument/didChange" => {
      match object.get("params") {
        Some(Object(params)) =>
          match params.get("textDocument") {
            Some(Object(document)) =>
              match document.get("uri") {
                Some(String(uri)) =>
                  match params.get("contentChanges") {
                    Some(Array(items)) =>
                      match items.get(0) {
                        Some(Object(change)) =>
                          match change.get("text") {
                            Some(String(source)) => {
                              documents.set(uri, source)
                              publish(uri)
                            }
                            _ => ()
                          }
                        _ => ()
                      }
                    _ => ()
                  }
                _ => ()
              }
            _ => ()
          }
        _ => ()
      }
    }
    "textDocument/didClose" => {
      match object.get("params") {
        Some(Object(params)) =>
          match params.get("textDocument") {
            Some(Object(document)) =>
              match document.get("uri") {
                Some(String(uri)) => {
                  documents.remove(uri)
                  publish(uri)
                }
                _ => ()
              }
            _ => ()
          }
        _ => ()
      }
    }
    _ => {
      // Unknown request: answer with MethodNotFound so a client never hangs.
      if id != "" {
        send(
          "{\"jsonrpc\":\"2.0\",\"id\":" +
          id +
          ",\"error\":{\"code\":-32601,\"message\":\"unsupported method\"}}",
        )
      }
    }
  }
  true
}

///|
async fn main {
  let mut running = true
  while running {
    let message = read_message()
    match message {
      None => running = false
      Some(text) => running = handle_message(text)
    }
  }
}
