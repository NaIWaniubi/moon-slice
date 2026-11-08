// Renderers for `TaintReport`. Pure string building, no IO.

///|
/// JSON string literal for `s`. Control characters are escaped so a finding
/// built from hostile source text cannot break the document, and `<` / `>` are
/// escaped so the same text can be embedded in an HTML `<script>` block.
fn json_escape(s : String) -> String {
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
/// `path` as a comma-separated list, for the text renderer.
fn path_text(path : Array[Int32]) -> String {
  let out = StringBuilder()
  let mut first = true
  for id in path {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string(id.to_string())
  }
  out.to_string()
}

///|
/// The report as one JSON object:
///
/// ```json
/// {"findings":[{"source_name":"env/read","source_line":2,
///               "sink_name":"process/exec","sink_line":6,
///               "path":[1,2,6],"sanitized":false}],
///  "sources_seen":1,"sinks_seen":1,"truncated":0}
/// ```
///
/// Findings keep the order `analyze` produced. No line breaks are emitted, so
/// the output is one line a shell pipeline can consume.
pub fn report_json(report : TaintReport) -> String {
  let out = StringBuilder()
  out.write_string("{\"findings\":[")
  let mut first = true
  for finding in report.findings {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_string("{\"source_name\":")
    out.write_string(json_escape(finding.source_name))
    out.write_string(",\"source_line\":")
    out.write_string(finding.source_line.to_string())
    out.write_string(",\"sink_name\":")
    out.write_string(json_escape(finding.sink_name))
    out.write_string(",\"sink_line\":")
    out.write_string(finding.sink_line.to_string())
    out.write_string(",\"path\":[")
    let mut first_id = true
    for id in finding.path {
      if !first_id {
        out.write_char(',')
      }
      first_id = false
      out.write_string(id.to_string())
    }
    out.write_string("],\"sanitized\":")
    out.write_string(if finding.sanitized { "true" } else { "false" })
    out.write_char('}')
  }
  out.write_string("],\"sources_seen\":")
  out.write_string(report.sources_seen.to_string())
  out.write_string(",\"sinks_seen\":")
  out.write_string(report.sinks_seen.to_string())
  out.write_string(",\"truncated\":")
  out.write_string(report.truncated.to_string())
  out.write_char('}')
  out.to_string()
}

///|
/// The report as text, one finding per line:
///
/// ```text
/// taint: findings=1 sources=1 sinks=1 truncated=0
///   env/read:2 -> process/exec:6 path=1,2,6
/// ```
///
/// A finding marked sanitized carries a trailing ` sanitized`. An empty report
/// prints the header only, so a caller always gets the counters.
pub fn report_text(report : TaintReport) -> String {
  let out = StringBuilder()
  out.write_string("taint: findings=")
  out.write_string(report.findings.length().to_string())
  out.write_string(" sources=")
  out.write_string(report.sources_seen.to_string())
  out.write_string(" sinks=")
  out.write_string(report.sinks_seen.to_string())
  out.write_string(" truncated=")
  out.write_string(report.truncated.to_string())
  for finding in report.findings {
    out.write_string("\n  ")
    out.write_string(finding.source_name)
    out.write_char(':')
    out.write_string(finding.source_line.to_string())
    out.write_string(" -> ")
    out.write_string(finding.sink_name)
    out.write_char(':')
    out.write_string(finding.sink_line.to_string())
    out.write_string(" path=")
    out.write_string(path_text(finding.path))
    if finding.sanitized {
      out.write_string(" sanitized")
    }
  }
  out.to_string()
}
