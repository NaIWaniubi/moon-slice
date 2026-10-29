// moon-slice command line interface.
//
// Commands:
//   slice --file F --line N --direction backward|forward [--json]
//   graph --file F [--format dot]
//   dead  --file F
//   html  --file F --line N [--out report.html]
//   dump  --file F --line N
//
// The analysis pipeline is intentionally thin here: every decision lives in
// the library packages, and this file only parses flags and renders output.

///|
fn usage() -> Unit {
  println(
    "moon-slice — program slicing for MoonBit\n" +
    "\n" +
    "Commands:\n" +
    "  slice --file F --line N --direction backward|forward [--json] [--interprocedural]\n" +
    "        [--node ID]   disambiguate several statements on the same line\n" +
    "  graph --file F [--format dot|json]\n" +
    "  callgraph --file F [--json]\n" +
    "  dead  --file F [--json]\n" +
    "  path  --file F --from VAR --to VAR [--json]\n" +
    "  html  --file F --line N [--out report.html] [--interprocedural] [--node ID]\n" +
    "  dump  --file F --line N\n" +
    "  dump-errors / dump-cfg / dump-defuse / dump-pdg --file F\n" +
    "  version | help\n" +
    "\n" +
    "Options:\n" +
    "  --precise   derive control dependence from post-dominators instead of the\n" +
    "              syntax tree. Exact for the CFG; drops the structural rule's\n" +
    "              over-approximations. Works with slice/graph/dead/html.\n" +
    "  --json      machine-readable output; failures become\n" +
    "              {\"error\":{\"code\":..,\"message\":..}} and still exit 2.\n" +
    "\n" +
    "Exit codes: 0 success, 2 usage error, unreadable input, parse error or\n" +
    "write failure. When a line holds several statements, `dump --line N` lists\n" +
    "their node ids; pass the wanted one with `--node ID`.\n",
  )
}

///|
/// Pre-scan argv for `--json` so a failure during argument parsing still knows
/// whether the caller wants a machine-readable error.
fn prescan_json(argv : Array[String]) -> Bool {
  let mut found = false
  for arg in argv {
    if arg == "--json" {
      found = true
    }
  }
  found
}

///|
/// Whether the invocation asked for `--json`. Failures consult this so a
/// machine consumer always gets an error object instead of prose. It is a cell
/// because the flag is parsed before the command runs, and the failure helpers
/// are shared by every command.
let json_mode : Array[Bool] = [false]

///|
/// Emit a machine-readable error object when `--json` was requested, otherwise
/// the human line, then exit 2.
fn fail_code(code : String, message : String) -> Unit {
  if json_mode[0] {
    println(@report.to_error_json(code, message))
  } else {
    println("error: " + message)
  }
  @sys.exit(2)
}

///|
fn read_source(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => {
      fail_code("read_failed", "failed to read \{path}: \{msg}")
      ""
    }
  }
}

///|
fn known_command(command : String) -> Bool {
  command == "slice" ||
  command == "graph" ||
  command == "compare" ||
  command == "review" ||
  command == "callgraph" ||
  command == "dead" ||
  command == "path" ||
  command == "html" ||
  command == "dump" ||
  command == "dump-errors" ||
  command == "dump-cfg" ||
  command == "dump-defuse" ||
  command == "dump-pdg"
}

///|
fn require_value(argv : Array[String], i : Int, _flag : String) -> String {
  if i + 1 >= argv.length() {
    fail_code("missing_value", "\{_flag} requires a value")
    ""
  } else {
    argv[i + 1]
  }
}

///|
fn parse_line(value : String) -> Int {
  @string.parse_int(value) catch {
    _ => {
      fail_code("bad_integer", "invalid integer for --line: \{value}")
      0
    }
  }
}

///|
fn require_line(command : String, line : Int) -> Unit {
  if (command == "slice" || command == "html" || command == "dump") && line <= 0 {
    fail_code("missing_line", "--line is required for \{command}")
  }
}

///|
fn select_target(
  program : @core.Program,
  line : Int32,
  override_node : Int32?,
) -> Int32 {
  match override_node {
    Some(id) => {
      match @query.node_exists(program, id) {
        true => id
        false => {
          fail_code("unknown_node", "no node with id \{id}")
          0
        }
      }
    }
    None => {
      let candidates = @query.statement_candidates(program, line)
      if candidates.length() == 0 {
        fail_code("no_node_at_line", "no node starts at line \{line}")
      }
      if candidates.length() > 1 {
        let ids = StringBuilder()
        let mut first = true
        for id in candidates {
          if !first {
            ids.write_char(',')
          }
          ids.write_string(id.to_string())
          first = false
        }
        println(
          "note: line \{line} has \{candidates.length()} statements; using node \{candidates[0]}. Pass --node ID to choose another (candidates: \{ids.to_string()})",
        )
      }
      candidates[0]
    }
  }
}

///|
/// Control edges of a PDG as a set, for the `compare` command.
fn control_edge_set(pdg : @core.Pdg) -> Set[(Int32, Int32)] {
  let out : Set[(Int32, Int32)] = Set([])
  for edge in pdg.edges {
    if edge.kind == @core.EdgeKind::Control {
      out.add((edge.from, edge.to))
    }
  }
  out
}

///|
fn pair_array_json(pairs : Array[(Int32, Int32)]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  let mut first = true
  for (from, to) in pairs {
    if !first {
      out.write_char(',')
    }
    out.write_string("[")
    out.write_string(from.to_string())
    out.write_char(',')
    out.write_string(to.to_string())
    out.write_char(']')
    first = false
  }
  out.write_char(']')
  out.to_string()
}

///|
fn lines_text(lines : Array[Int32]) -> String {
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
fn analyze(
  source : String,
  name : String,
  precise : Bool,
) -> (@core.Program, @core.Cfg, @core.DefUse, @core.Pdg) {
  let program = @parser_adapter.parse_source(source, name)
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = if precise {
    @cdg.build_precise(program, cfg)
  } else {
    @cdg.build(program, cfg)
  }
  let pdg = @pdg.build(defuse, cdg)
  (program, cfg, defuse, pdg)
}

///|
fn print_lines(result : @core.SliceResult) -> Unit {
  let mut out = ""
  let mut first = true
  for line in result.lines {
    if !first {
      out = out + ","
    }
    out = out + line.to_string()
    first = false
  }
  println(out)
}

///|
fn vars_str(vars : Array[@core.VarId]) -> String {
  let mut out = ""
  let mut first = true
  for v in vars {
    if !first {
      out = out + ","
    }
    out = out + v.name + "#" + v.scope.to_string()
    first = false
  }
  out
}

///|
fn edge_kind_name(kind : @core.EdgeKind) -> String {
  match kind {
    @core.EdgeKind::Data => "data"
    @core.EdgeKind::Control => "control"
  }
}

///|
fn kind_name(kind : @core.SNodeKind) -> String {
  match kind {
    @core.SNodeKind::Let => "Let"
    @core.SNodeKind::LetMut => "LetMut"
    @core.SNodeKind::Assign => "Assign"
    @core.SNodeKind::If => "If"
    @core.SNodeKind::While => "While"
    @core.SNodeKind::For => "For"
    @core.SNodeKind::Match => "Match"
    @core.SNodeKind::Return => "Return"
    @core.SNodeKind::Break => "Break"
    @core.SNodeKind::Continue => "Continue"
    @core.SNodeKind::Call => "Call"
    @core.SNodeKind::Expr => "Expr"
  }
}

///|
fn main {
  let argv = @env.args()
  json_mode[0] = prescan_json(argv)
  if argv.length() < 2 {
    usage()
    return
  }
  let command = argv[1]
  if command == "version" || command == "--version" {
    println("moon-slice 0.4.2")
    return
  }
  if command == "help" || command == "--help" {
    usage()
    return
  }
  if !known_command(command) {
    fail_code("unknown_command", "unknown command \{command}")
  }
  let mut file = ""
  let mut line = 0
  let mut direction = "backward"
  let mut format = "dot"
  let mut out = ""
  let mut json = false
  let mut interproc = false
  let mut from_var = ""
  let mut to_var = ""
  let mut node_override : Int32? = None
  let mut precise_cdg = false
  let mut diff_path = ""
  let mut with_control = false
  let mut i = 2
  while i < argv.length() {
    let arg = argv[i]
    if arg == "--file" {
      file = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--line" {
      line = parse_line(require_value(argv, i, arg))
      i = i + 2
    } else if arg == "--direction" {
      direction = require_value(argv, i, arg)
      if direction != "backward" && direction != "forward" {
        fail_code("bad_direction", "unsupported --direction \{direction} (use backward or forward)")
      }
      i = i + 2
    } else if arg == "--format" {
      format = require_value(argv, i, arg)
      if format != "dot" && format != "json" {
        fail_code("bad_format", "unsupported --format \{format} (use dot or json)")
      }
      i = i + 2
    } else if arg == "--out" {
      out = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--from" {
      from_var = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--to" {
      to_var = require_value(argv, i, arg)
      i = i + 2
    } else if arg == "--node" {
      node_override = Some(parse_line(require_value(argv, i, arg)).to_int64().to_int())
      i = i + 2
    } else if arg == "--json" {
      json = true
      i = i + 1
    } else if arg == "--interprocedural" {
      interproc = true
      i = i + 1
    } else if arg == "--precise" {
      precise_cdg = true
      i = i + 1
    } else if arg == "--with-control" {
      with_control = true
      i = i + 1
    } else if arg == "--diff" {
      diff_path = require_value(argv, i, arg)
      i = i + 2
    } else {
      fail_code("unknown_argument", "unknown argument \{arg}")
    }
  }
  if command == "review" {
    if diff_path == "" {
      fail_code("missing_diff", "--diff is required for review")
    }
    run_review(diff_path, json)
    return
  }
  if file == "" {
    fail_code("missing_file", "--file is required")
  }
  require_line(command, line)
  if command == "path" && (from_var == "" || to_var == "") {
    fail_code("missing_path_args", "--from and --to are required")
  }
  let source = read_source(file)
  let (program, cfg, defuse, pdg) = analyze(source, file, precise_cdg)
  if command != "dump-errors" && program.errors.length() > 0 {
    fail_code("parse_error", "source contains \{program.errors.length()} parser diagnostic(s); use dump-errors to inspect them")
  }
  match command {
    "slice" => {
      let target = select_target(program, line.to_int64().to_int(), node_override)
      let result = if direction == "forward" {
        @slice.forward(pdg, target, program~)
      } else {
        @slice.backward(pdg, target, program~)
      }
      let result = @core.SliceResult::{
        nodes: result.nodes,
        lines: @query.visible_lines(program, result.nodes),
      }
      let result = if interproc {
        @query.expand_calls(program, pdg, result)
      } else {
        result
      }
      if json {
        println(@report.to_json(program, result))
      } else {
        print_lines(result)
      }
    }
    "graph" =>
      if format == "json" {
        println(@report.to_graph_json(program, pdg))
      } else {
        println(@report.to_dot(pdg))
      }
    "compare" => {
      // Show what the post-dominator builder buys: the control edges the
      // structural rule invents, and (with --line) how the slice changes.
      let precise_cdg = @cdg.build_precise(program, cfg)
      let precise_pdg = @pdg.build(defuse, precise_cdg)
      let structural = control_edge_set(pdg)
      let precise = control_edge_set(precise_pdg)
      let removed : Array[(Int32, Int32)] = []
      for edge in structural {
        if !precise.contains(edge) {
          removed.push(edge)
        }
      }
      let added : Array[(Int32, Int32)] = []
      for edge in precise {
        if !structural.contains(edge) {
          added.push(edge)
        }
      }
      if json {
        println(
          "{\"structural_control_edges\":" +
          structural.length().to_string() +
          ",\"precise_control_edges\":" +
          precise.length().to_string() +
          ",\"removed\":" +
          pair_array_json(removed) +
          ",\"added\":" +
          pair_array_json(added) +
          "}",
        )
      } else {
        println("structural control edges: " + structural.length().to_string())
        println("precise control edges:    " + precise.length().to_string())
        println("removed by precise:       " + removed.length().to_string())
        for (from, to) in removed {
          println(
            "  n" +
            from.to_string() +
            " -> n" +
            to.to_string() +
            "  (lines " +
            program.nodes[from].loc.start_line.to_string() +
            " -> " +
            program.nodes[to].loc.start_line.to_string() +
            ")",
          )
        }
        println("added by precise:         " + added.length().to_string())
        for (from, to) in added {
          println(
            "  n" +
            from.to_string() +
            " -> n" +
            to.to_string() +
            "  (lines " +
            program.nodes[from].loc.start_line.to_string() +
            " -> " +
            program.nodes[to].loc.start_line.to_string() +
            ")",
          )
        }
        if line > 0 {
          let target = select_target(program, line.to_int64().to_int(), node_override)
          let before = @slice.backward(pdg, target, program~)
          let after = @slice.backward(precise_pdg, target, program~)
          let before_lines = @query.visible_lines(program, before.nodes)
          let after_lines = @query.visible_lines(program, after.nodes)
          println("slice line " + line.to_string() + " (structural): " + lines_text(before_lines))
          println("slice line " + line.to_string() + " (precise):    " + lines_text(after_lines))
        }
      }
    }
    "callgraph" => {
      let edges = @query.call_edges(program)
      if json {
        println(@report.to_call_json(edges))
      } else if edges.length() == 0 {
        println("no internal calls")
      } else {
        println(@report.to_call_dot(edges))
      }
    }
    "dead" => {
      let dead = @query.dead_nodes(program, defuse)
      let unreach = @query.unreachable_nodes(program, cfg)
      let all = @query.union_sorted(dead, unreach)
      let result = @core.SliceResult::{
        nodes: all,
        lines: @query.visible_lines(program, all),
      }
      if json {
        println(@report.to_json(program, result))
      } else {
        print_lines(result)
      }
    }
    "html" => {
      let target = select_target(program, line.to_int64().to_int(), node_override)
      let result = @slice.backward(pdg, target, program~)
      let result = @core.SliceResult::{
        nodes: result.nodes,
        lines: @query.visible_lines(program, result.nodes),
      }
      let result = if interproc {
        @query.expand_calls(program, pdg, result)
      } else {
        result
      }
      let html = @report.to_html(
        source,
        program,
        pdg,
        result,
        line.to_int64().to_int(),
        target,
      )
      if out == "" {
        println(html)
      } else {
        @fs.write_string_to_file(out, html) catch {
          @fs.IOError(msg) => fail_code("write_failed", "failed to write \{out}: \{msg}")
        }
        println("wrote \{out}")
      }
    }
    "path" => {
      if from_var == "" || to_var == "" {
        println("error: --from and --to are required")
        return
      }
      let mut starts = @query.nodes_defining_name(program, from_var)
      if starts.length() == 0 {
        starts = @query.nodes_with_name(program, from_var)
      }
      let mut goals = @query.nodes_using_name(program, to_var)
      if goals.length() == 0 {
        goals = @query.nodes_with_name(program, to_var)
      }
      match @query.path_between(pdg, starts, goals, with_control=with_control) {
        Some(path) => {
          let result = @core.SliceResult::{
            nodes: path,
            lines: @query.lines_of(program, path),
          }
          if json {
            println(@report.to_json(program, result))
          } else {
            let mut line_out = ""
            let mut first = true
            for id in path {
              if !first {
                line_out = line_out + " -> "
              }
              line_out = line_out +
                "n" +
                id.to_string() +
                " L" +
                program.nodes[id].loc.start_line.to_string()
              first = false
            }
            println(line_out)
          }
        }
        None =>
          if json {
            println("{\"found\":false}")
          } else {
            println("no path from \{from_var} to \{to_var}")
          }
      }
    }
    "dump-errors" => {
      println("errors \{program.errors.length()}")
      for e in program.errors {
        println(e)
      }
    }
    "dump-cfg" => {
      let cfg = @cfg.build(program)
      println("entry \{cfg.entry} exit \{cfg.exit}")
      for edge in cfg.edges {
        println("cfg \{edge.0} -> \{edge.1}")
      }
    }
    "dump-defuse" =>
      for pair in defuse.reaching {
        println("du \{pair.0} -> \{pair.1}")
      }
    "dump-pdg" =>
      for edge in pdg.edges {
        println("pdg \{edge.from} -> \{edge.to} \{edge_kind_name(edge.kind)}")
      }
    "dump" => {
      let ids = @query.nodes_at_line(program, line.to_int64().to_int())
      if ids.length() == 0 {
        println("no nodes at line \{line}")
      }
      for id in ids {
        let node = program.nodes[id]
        println(
          "node \{node.id} kind \{kind_name(node.kind)} line \{node.loc.start_line} defs [\{vars_str(node.defs)}] uses [\{vars_str(node.uses)}] children \{node.children.length()}",
        )
      }
    }
    _ => usage()
  }
}
