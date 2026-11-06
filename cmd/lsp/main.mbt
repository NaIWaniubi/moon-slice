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
fn field(json : @builtin.Json, name : String) -> @builtin.Json? {
  match json {
    Object(map) => map.get(name)
    _ => None
  }
}

///|
fn string_field(json : @builtin.Json, name : String) -> String? {
  match field(json, name) {
    None => None
    Some(value) =>
      match value {
        String(text) => Some(text)
        _ => None
      }
  }
}

///|
/// Returns `false` when the editor asked the server to exit.
async fn handle_message(text : String) -> Bool {
  let json = @json.parse(text) catch {
    _ => return true
  }
  let method_name = match string_field(json, "method") {
    Some(name) => name
    None => return true
  }
  // A request carries an id; a notification does not and gets no response.
  let id = match field(json, "id") {
    None => ""
    Some(value) => value.stringify()
  }
  match method_name {
    "initialize" =>
      send_response(
        id,
        "{\"capabilities\":{\"textDocumentSync\":1,\"diagnosticProvider\":{\"interFileDependencies\":false,\"workspaceDiagnostics\":false}},\"serverInfo\":{\"name\":\"moon-slice\",\"version\":0}}",
      )
    "initialized" => ()
    "shutdown" => send_response(id, "null")
    "exit" => return false
    "textDocument/didOpen" => {
      match field(json, "params") {
        None => ()
        Some(params) =>
          match field(params, "textDocument") {
            None => ()
            Some(document) =>
              match (string_field(document, "uri"), string_field(document, "text")) {
                (Some(uri), Some(source)) => {
                  documents.set(uri, source)
                  publish(uri)
                }
                _ => ()
              }
          }
      }
    }
    "textDocument/didChange" => {
      match field(json, "params") {
        None => ()
        Some(params) =>
          match field(params, "textDocument") {
            None => ()
            Some(document) =>
              match string_field(document, "uri") {
                None => ()
                Some(uri) =>
                  match field(params, "contentChanges") {
                    None => ()
                    Some(changes) =>
                      match changes {
                        Array(items) =>
                          match items.get(0) {
                            None => ()
                            Some(change) =>
                              match string_field(change, "text") {
                                None => ()
                                Some(source) => {
                                  documents.set(uri, source)
                                  publish(uri)
                                }
                              }
                          }
                        _ => ()
                      }
                  }
              }
          }
      }
    }
    "textDocument/didClose" => {
      match field(json, "params") {
        None => ()
        Some(params) =>
          match field(params, "textDocument") {
            None => ()
            Some(document) =>
              match string_field(document, "uri") {
                None => ()
                Some(uri) => {
                  documents.remove(uri)
                  publish(uri)
                }
              }
          }
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
