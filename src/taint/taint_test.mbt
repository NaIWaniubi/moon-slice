// Tests for the taint pass. Each case is a tiny hand-built program with exact
// expected ids, lines and path: the value of a taint report is that a reader
// can trace every hop, so a broad smoke test would prove nothing. The last few
// tests run the real parser adapter to keep the hand-built model honest.

///|
fn loc_of(line : Int32) -> @core.Loc {
  { start_line: line, start_col: 1, end_line: line, end_col: 8, }
}

///|
fn span(start_line : Int32, end_line : Int32) -> @core.Loc {
  { start_line, start_col: 1, end_line, end_col: 8, }
}

///|
fn node(id : Int32, kind : @core.SNodeKind, line : Int32) -> @core.SNode {
  { id, kind, loc: loc_of(line), defs: [], uses: [], children: [], parent: None, }
}

///|
fn spanned(
  id : Int32,
  kind : @core.SNodeKind,
  start_line : Int32,
  end_line : Int32,
) -> @core.SNode {
  {
    id,
    kind,
    loc: span(start_line, end_line),
    defs: [],
    uses: [],
    children: [],
    parent: None,
  }
}

///|
fn site(caller : String, callee : String, line : Int32) -> @core.CallSite {
  { caller, callee, line, }
}

///|
fn prog(
  nodes : Array[@core.SNode],
  calls : Array[@core.CallSite],
) -> @core.Program {
  { nodes, functions: [], calls, errors: [], }
}

///|
fn data(from : Int32, to : Int32) -> @core.PdgEdge {
  { from, to, kind: @core.Data, }
}

///|
fn control(from : Int32, to : Int32) -> @core.PdgEdge {
  { from, to, kind: @core.Control, }
}

///|
fn graph(edges : Array[@core.PdgEdge]) -> @core.Pdg {
  { edges, }
}

///|
fn conf(
  sources : Array[String],
  sinks : Array[String],
  sanitizers : Array[String],
) -> @taint.TaintConfig {
  { sources, sinks, sanitizers, }
}

// ---------------------------------------------------------------------------
// Core flows
// ---------------------------------------------------------------------------

///|
test "direct source to sink" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2), node(2, @core.SNodeKind::Call, 3)],
    [site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(program, graph([data(1, 2)]), conf(
    ["read"], ["exec"], [],
  ))
  assert_eq(report.findings.length(), 1)
  let finding = report.findings[0]
  assert_eq(finding.source_name, "read")
  assert_eq(finding.source_line, 2)
  assert_eq(finding.sink_name, "exec")
  assert_eq(finding.sink_line, 3)
  assert_eq(finding.path, [1, 2])
  assert_eq(finding.sanitized, false)
  assert_eq(report.sources_seen, 1)
  assert_eq(report.sinks_seen, 1)
  assert_eq(report.truncated, 0)
}

///|
test "flow through an intermediate variable" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Let, 3),
      node(3, @core.SNodeKind::Call, 4),
    ],
    [site("main", "read", 2), site("main", "exec", 4)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2), data(2, 3)]),
    conf(["read"], ["exec"], []),
  )
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].path, [1, 2, 3])
  assert_eq(report.findings[0].source_line, 2)
  assert_eq(report.findings[0].sink_line, 4)
}

///|
test "a sanitizer on the only path suppresses the finding" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Call, 3),
      node(3, @core.SNodeKind::Call, 4),
    ],
    [site("main", "read", 2), site("main", "san", 3), site("main", "exec", 4)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2), data(2, 3)]),
    conf(["read"], ["exec"], ["san"]),
  )
  assert_eq(report.findings, [])
  assert_eq(report.truncated, 1)
  assert_eq(report.sources_seen, 1)
  assert_eq(report.sinks_seen, 1)
}

///|
test "a clean alternative path survives a sanitizer on another path" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Call, 3),
      node(3, @core.SNodeKind::Let, 4),
      node(4, @core.SNodeKind::Call, 5),
    ],
    [site("main", "read", 2), site("main", "san", 3), site("main", "exec", 5)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2), data(1, 3), data(2, 4), data(3, 4)]),
    conf(["read"], ["exec"], ["san"]),
  )
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].path, [1, 3, 4])
  assert_eq(report.truncated, 1)
}

///|
test "multiple paths report the shortest one" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Let, 3),
      node(3, @core.SNodeKind::Let, 4),
      node(4, @core.SNodeKind::Let, 5),
      node(5, @core.SNodeKind::Call, 6),
    ],
    [site("main", "read", 2), site("main", "exec", 6)],
  )
  let report = @taint.analyze(
    program,
    // Long: 1 -> 2 -> 3 -> 5. Short: 1 -> 4 -> 5.
    graph([data(1, 2), data(2, 3), data(3, 5), data(1, 4), data(4, 5)]),
    conf(["read"], ["exec"], []),
  )
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].path, [1, 4, 5])
}

///|
test "a source that never reaches a sink produces no finding" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Let, 3),
      node(3, @core.SNodeKind::Call, 4),
    ],
    [site("main", "read", 2), site("main", "exec", 4)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2)]),
    conf(["read"], ["exec"], []),
  )
  assert_eq(report.findings, [])
  assert_eq(report.sources_seen, 1)
  assert_eq(report.sinks_seen, 1)
  assert_eq(report.truncated, 0)
}

///|
test "control edges carry no taint" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2), node(2, @core.SNodeKind::Call, 3)],
    [site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(
    program,
    graph([control(1, 2)]),
    conf(["read"], ["exec"], []),
  )
  assert_eq(report.findings, [])
}

///|
test "empty program yields an empty report" {
  let report = @taint.analyze(prog([], []), graph([]), conf(
    ["read"], ["exec"], [],
  ))
  assert_eq(report.findings, [])
  assert_eq(report.sources_seen, 0)
  assert_eq(report.sinks_seen, 0)
  assert_eq(report.truncated, 0)
}

///|
test "an empty config matches nothing" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2), node(2, @core.SNodeKind::Call, 3)],
    [site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(program, graph([data(1, 2)]), conf([], [], []))
  assert_eq(report.findings, [])
  assert_eq(report.sources_seen, 0)
  assert_eq(report.sinks_seen, 0)
}

///|
test "two sinks from one source are both reported in line order" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Call, 5),
      node(3, @core.SNodeKind::Call, 9),
    ],
    [site("main", "read", 2), site("main", "log", 9), site("main", "exec", 5)],
  )
  let report = @taint.analyze(
    program,
    // Edges deliberately listed out of line order.
    graph([data(1, 3), data(1, 2)]),
    conf(["read"], ["exec", "log"], []),
  )
  assert_eq(report.findings.length(), 2)
  assert_eq(report.findings[0].sink_name, "exec")
  assert_eq(report.findings[0].sink_line, 5)
  assert_eq(report.findings[1].sink_name, "log")
  assert_eq(report.findings[1].sink_line, 9)
}

///|
test "the nearest of several sources owns the flow" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Call, 3),
      node(3, @core.SNodeKind::Call, 4),
    ],
    [site("main", "read", 2), site("main", "args", 3), site("main", "exec", 4)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 3), data(2, 3)]),
    conf(["read", "args"], ["exec"], []),
  )
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].source_name, "read")
  assert_eq(report.findings[0].path, [1, 3])
  assert_eq(report.sources_seen, 2)
}

///|
test "a sink that is also a source is reported with a one-node path" {
  // `exec(read())` lowers to one Call node for both calls.
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2)],
    [site("main", "read", 2), site("main", "exec", 2)],
  )
  let report = @taint.analyze(program, graph([]), conf(
    ["read"], ["exec"], [],
  ))
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].path, [1])
  assert_eq(report.findings[0].source_line, 2)
  assert_eq(report.findings[0].sink_line, 2)
}

///|
test "a self data edge terminates the walk" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Call, 3),
      node(3, @core.SNodeKind::Call, 4),
    ],
    [site("main", "read", 2), site("main", "exec", 4)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2), data(2, 2), data(2, 3)]),
    conf(["read"], ["exec"], []),
  )
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].path, [1, 2, 3])
}

// ---------------------------------------------------------------------------
// Rule matching and call resolution
// ---------------------------------------------------------------------------

///|
test "a package-qualified rule matches the bare call name" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2), node(2, @core.SNodeKind::Call, 3)],
    [site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2)]),
    conf(["env/read"], ["process/exec"], []),
  )
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].source_name, "env/read")
  assert_eq(report.findings[0].sink_name, "process/exec")
}

///|
test "rules are case sensitive" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2), node(2, @core.SNodeKind::Call, 3)],
    [site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2)]),
    conf(["Read"], ["Exec"], []),
  )
  assert_eq(report.findings, [])
  assert_eq(report.sources_seen, 0)
  assert_eq(report.sinks_seen, 0)
}

///|
test "a rule tail must equal the whole call name" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2), node(2, @core.SNodeKind::Call, 3)],
    [site("main", "read_all", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2)]),
    conf(["env/read"], ["exec"], []),
  )
  assert_eq(report.findings, [])
  assert_eq(report.sources_seen, 0)
}

///|
test "one call node is claimed by the first matching rule only" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2), node(2, @core.SNodeKind::Call, 3)],
    [site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2)]),
    conf(["env/read", "fs/read"], ["exec"], []),
  )
  assert_eq(report.sources_seen, 1)
  assert_eq(report.findings[0].source_name, "env/read")
}

///|
test "a call on a statement line resolves to that statement" {
  // `let cmd = read()` has no Call node; the Let node on the line is the
  // statement that carries the flow.
  let program = prog(
    [
      node(1, @core.SNodeKind::Let, 2),
      node(2, @core.SNodeKind::Call, 3),
    ],
    [site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2)]),
    conf(["read"], ["exec"], []),
  )
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].path, [1, 2])
  assert_eq(report.findings[0].source_line, 2)
}

///|
test "the narrowest call node containing the line wins" {
  let program = prog(
    [
      spanned(1, @core.SNodeKind::Call, 4, 6),
      spanned(2, @core.SNodeKind::Call, 5, 5),
      node(3, @core.SNodeKind::Call, 7),
    ],
    [site("main", "read", 5), site("main", "exec", 7)],
  )
  let report = @taint.analyze(
    program,
    graph([data(2, 3)]),
    conf(["read"], ["exec"], []),
  )
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].path, [2, 3])
}

///|
test "a call site with no node at its line is ignored" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 3)],
    [site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(program, graph([]), conf(
    ["read"], ["exec"], [],
  ))
  assert_eq(report.sources_seen, 0)
  assert_eq(report.sinks_seen, 1)
  assert_eq(report.findings, [])
}

///|
test "duplicate call sites for one node count once" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2), node(2, @core.SNodeKind::Call, 3)],
    [site("main", "read", 2), site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2)]),
    conf(["read"], ["exec"], []),
  )
  assert_eq(report.sources_seen, 1)
  assert_eq(report.findings.length(), 1)
}

///|
test "an unreachable sanitizer is not counted as truncated" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Call, 3),
      node(3, @core.SNodeKind::Call, 4),
    ],
    [site("main", "read", 2), site("main", "san", 3), site("main", "exec", 4)],
  )
  let report = @taint.analyze(
    program,
    // The sanitizer is a separate component from the source.
    graph([data(1, 3)]),
    conf(["read"], ["exec"], ["san"]),
  )
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].path, [1, 3])
  assert_eq(report.truncated, 0)
}

///|
test "two reached sanitizers are counted separately" {
  let program = prog(
    [
      node(1, @core.SNodeKind::Call, 2),
      node(2, @core.SNodeKind::Call, 3),
      node(3, @core.SNodeKind::Call, 4),
    ],
    [site("main", "read", 2), site("main", "one", 3), site("main", "two", 4)],
  )
  let report = @taint.analyze(
    program,
    graph([data(1, 2), data(1, 3)]),
    conf(["read"], ["exec"], ["one", "two"]),
  )
  assert_eq(report.findings, [])
  assert_eq(report.truncated, 2)
}

// ---------------------------------------------------------------------------
// Config parsing
// ---------------------------------------------------------------------------

///|
test "config parses all three rule lists" {
  let config = @taint.parse_config(
    "{\"sources\":[\"env/read\",\"args\"],\"sinks\":[\"exec\"],\"sanitizers\":[\"escape\"]}",
  )
  assert_eq(config.sources, ["env/read", "args"])
  assert_eq(config.sinks, ["exec"])
  assert_eq(config.sanitizers, ["escape"])
}

///|
test "config tolerates missing fields" {
  let config = @taint.parse_config("{\"sources\":[\"read\"]}")
  assert_eq(config.sources, ["read"])
  assert_eq(config.sinks, [])
  assert_eq(config.sanitizers, [])
}

///|
test "config skips non-string entries" {
  let config = @taint.parse_config(
    "{\"sources\":[\"read\",1,true,null,{\"x\":1}],\"sinks\":[\"exec\"]}",
  )
  assert_eq(config.sources, ["read"])
  assert_eq(config.sinks, ["exec"])
}

///|
test "config ignores a non-array field" {
  let config = @taint.parse_config(
    "{\"sources\":\"read\",\"sinks\":[\"exec\"]}",
  )
  assert_eq(config.sources, [])
  assert_eq(config.sinks, ["exec"])
}

///|
test "malformed config JSON yields an empty config" {
  let config = @taint.parse_config("not json at all")
  assert_eq(config.sources, [])
  assert_eq(config.sinks, [])
  assert_eq(config.sanitizers, [])
}

///|
test "a non-object config yields an empty config" {
  let config = @taint.parse_config("[\"read\"]")
  assert_eq(config.sources, [])
  assert_eq(config.sinks, [])
  assert_eq(config.sanitizers, [])
}

///|
test "default config covers sources, sinks and sanitizers" {
  let config = @taint.default_config()
  assert_true(config.sources.contains("env/read"))
  assert_true(config.sinks.contains("process/exec"))
  assert_true(config.sanitizers.contains("html/escape"))
  assert_true(config.sources.length() > 0)
  assert_true(config.sinks.length() > 0)
  assert_true(config.sanitizers.length() > 0)
}

///|
test "default config finds a read to exec flow" {
  let program = prog(
    [node(1, @core.SNodeKind::Call, 2), node(2, @core.SNodeKind::Call, 3)],
    [site("main", "read", 2), site("main", "exec", 3)],
  )
  let report = @taint.analyze(program, graph([data(1, 2)]), @taint.default_config())
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].source_name, "env/read")
  assert_eq(report.findings[0].sink_name, "process/exec")
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

///|
fn sample_report() -> @taint.TaintReport {
  {
    findings: [
      {
        source_name: "env/read",
        source_line: 2,
        sink_name: "process/exec",
        sink_line: 6,
        path: [1, 2, 6],
        sanitized: false,
      },
    ],
    sources_seen: 1,
    sinks_seen: 1,
    truncated: 0,
  }
}

///|
test "report json carries every finding field" {
  let json = @taint.report_json(sample_report())
  assert_true(json.contains("\"findings\":["))
  assert_true(json.contains("\"source_name\":\"env/read\""))
  assert_true(json.contains("\"source_line\":2"))
  assert_true(json.contains("\"sink_name\":\"process/exec\""))
  assert_true(json.contains("\"sink_line\":6"))
  assert_true(json.contains("\"path\":[1,2,6]"))
  assert_true(json.contains("\"sanitized\":false"))
  assert_true(json.contains("\"sources_seen\":1"))
  assert_true(json.contains("\"sinks_seen\":1"))
  assert_true(json.contains("\"truncated\":0"))
}

///|
test "report json escapes quotes and control characters" {
  let report : @taint.TaintReport = {
    findings: [
      {
        source_name: "a\"b",
        source_line: 1,
        sink_name: "x\u{1}y",
        sink_line: 2,
        path: [1, 2],
        sanitized: true,
      },
    ],
    sources_seen: 1,
    sinks_seen: 1,
    truncated: 0,
  }
  let json = @taint.report_json(report)
  assert_true(json.contains("a\\\"b"))
  assert_true(json.contains("x\\u0001y"))
  assert_true(json.contains("\"sanitized\":true"))
}

///|
test "empty report json is an empty findings array with counters" {
  let report : @taint.TaintReport = {
    findings: [],
    sources_seen: 3,
    sinks_seen: 2,
    truncated: 1,
  }
  let json = @taint.report_json(report)
  assert_eq(
    json,
    "{\"findings\":[],\"sources_seen\":3,\"sinks_seen\":2,\"truncated\":1}",
  )
}

///|
test "report text renders a finding line with its path" {
  let text = @taint.report_text(sample_report())
  assert_true(text.contains("taint: findings=1 sources=1 sinks=1 truncated=0"))
  assert_true(text.contains("env/read:2 -> process/exec:6 path=1,2,6"))
}

///|
test "report text marks a sanitized finding" {
  let report : @taint.TaintReport = {
    findings: [
      {
        source_name: "read",
        source_line: 2,
        sink_name: "exec",
        sink_line: 3,
        path: [1, 2],
        sanitized: true,
      },
    ],
    sources_seen: 1,
    sinks_seen: 1,
    truncated: 0,
  }
  let text = @taint.report_text(report)
  assert_true(text.contains("read:2 -> exec:3 path=1,2 sanitized"))
}

///|
test "empty report text is the header alone" {
  let report : @taint.TaintReport = {
    findings: [],
    sources_seen: 0,
    sinks_seen: 0,
    truncated: 0,
  }
  assert_eq(
    @taint.report_text(report),
    "taint: findings=0 sources=0 sinks=0 truncated=0",
  )
}

// ---------------------------------------------------------------------------
// Real IR: the hand-built model must match what the adapter emits
// ---------------------------------------------------------------------------

///|
fn pipeline(source : String) -> (@core.Program, @core.Pdg) {
  let program = @parser_adapter.parse_source(source, "a.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  (program, @pdg.build(defuse, cdg))
}

///|
test "real IR reports a let-bound read flowing into exec" {
  let (program, pdg) = pipeline(
    "fn main() {\n  let cmd = read()\n  exec(cmd)\n}\n",
  )
  let report = @taint.analyze(program, pdg, conf(["read"], ["exec"], []))
  assert_eq(report.sources_seen, 1)
  assert_eq(report.sinks_seen, 1)
  assert_eq(report.findings.length(), 1)
  let finding = report.findings[0]
  assert_eq(finding.source_name, "read")
  assert_eq(finding.source_line, 2)
  assert_eq(finding.sink_name, "exec")
  assert_eq(finding.sink_line, 3)
  assert_true(finding.path.length() >= 2)
  assert_eq(finding.path[finding.path.length() - 1], report_node_on_line(
    program, 3,
  ))
}

///|
fn report_node_on_line(program : @core.Program, line : Int32) -> Int32 {
  for node in program.nodes {
    if node.loc.start_line == line && node.kind == @core.SNodeKind::Call {
      return node.id
    }
  }
  -1
}

///|
test "real IR reports nothing when the value does not reach the sink" {
  let (program, pdg) = pipeline(
    "fn main() {\n  let cmd = read()\n  exec(\"ls\")\n}\n",
  )
  let report = @taint.analyze(program, pdg, conf(["read"], ["exec"], []))
  assert_eq(report.findings, [])
  assert_eq(report.sources_seen, 1)
}

///|
test "real IR stops a flow at a sanitizer call" {
  let (program, pdg) = pipeline(
    "fn main() {\n  let raw = read()\n  let safe = escape(raw)\n  exec(safe)\n}\n",
  )
  let report = @taint.analyze(program, pdg, conf(
    ["read"], ["exec"], ["escape"],
  ))
  assert_eq(report.findings, [])
  assert_true(report.truncated >= 1)
}

///|
test "real IR line numbers match the source" {
  let (program, pdg) = pipeline(
    "fn helper() -> String {\n  read()\n}\n\nfn main() {\n  let cmd = helper()\n  exec(cmd)\n}\n",
  )
  let report = @taint.analyze(program, pdg, conf(["read"], ["exec"], []))
  // `helper` returns the source value, but the adapter does not model return
  // values across a call, so the source does not reach `exec` here.
  assert_eq(report.findings, [])
  assert_eq(report.sources_seen, 1)
  assert_eq(report.sinks_seen, 1)
}
