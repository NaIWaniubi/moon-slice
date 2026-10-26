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
    "  slice --file F --line N --direction backward|forward [--json]\n" +
    "  graph --file F [--format dot]\n" +
    "  dead  --file F\n" +
    "  path  --file F --from VAR --to VAR\n" +
    "  html  --file F --line N [--out report.html]\n" +
    "  dump  --file F --line N\n" +
    "  dump-errors / dump-cfg / dump-defuse / dump-pdg --file F\n",
  )
}

///|
fn read_source(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => {
      println("error: failed to read \{path}: \{msg}")
      ""
    }
  }
}

///|
fn analyze(
  source : String,
  name : String,
) -> (@core.Program, @core.DefUse, @core.Pdg) {
  let program = @parser_adapter.parse_source(source, name)
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  (program, defuse, pdg)
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
  if argv.length() < 2 {
    usage()
    return
  }
  let command = argv[1]
  let mut file = ""
  let mut line = 0
  let mut direction = "backward"
  let mut format = "dot"
  let mut out = ""
  let mut json = false
  let mut from_var = ""
  let mut to_var = ""
  let mut i = 2
  while i < argv.length() {
    let arg = argv[i]
    if arg == "--file" && i + 1 < argv.length() {
      file = argv[i + 1]
      i = i + 2
    } else if arg == "--line" && i + 1 < argv.length() {
      line = @string.parse_int(argv[i + 1]) catch { _ => 0 }
      i = i + 2
    } else if arg == "--direction" && i + 1 < argv.length() {
      direction = argv[i + 1]
      i = i + 2
    } else if arg == "--format" && i + 1 < argv.length() {
      format = argv[i + 1]
      i = i + 2
    } else if arg == "--out" && i + 1 < argv.length() {
      out = argv[i + 1]
      i = i + 2
    } else if arg == "--from" && i + 1 < argv.length() {
      from_var = argv[i + 1]
      i = i + 2
    } else if arg == "--to" && i + 1 < argv.length() {
      to_var = argv[i + 1]
      i = i + 2
    } else if arg == "--json" {
      json = true
      i = i + 1
    } else {
      println("error: unknown argument \{arg}")
      i = i + 1
    }
  }
  if file == "" {
    println("error: --file is required")
    return
  }
  let source = read_source(file)
  let (program, defuse, pdg) = analyze(source, file)
  match command {
    "slice" => {
      let target = match @query.target_node(program, line.to_int64().to_int()) {
        Some(id) => id
        None => {
          println("error: no node starts at line \{line}")
          return
        }
      }
      let result = if direction == "forward" {
        @slice.forward(pdg, target, program~)
      } else {
        @slice.backward(pdg, target, program~)
      }
      let result = @core.SliceResult::{
        nodes: result.nodes,
        lines: @query.visible_lines(program, result.nodes),
      }
      if json {
        println(@report.to_json(program, result))
      } else {
        print_lines(result)
      }
    }
    "graph" =>
      if format == "dot" {
        println(@report.to_dot(pdg))
      } else {
        println("error: unsupported --format \{format} (use dot)")
      }
    "dead" => {
      let dead = @query.dead_nodes(program, defuse)
      let cfg = @cfg.build(program)
      let unreach = @query.unreachable_nodes(program, cfg)
      let all = @query.union_sorted(dead, unreach)
      print_lines({ nodes: all, lines: @query.visible_lines(program, all), })
    }
    "html" => {
      let target = match @query.target_node(program, line.to_int64().to_int()) {
        Some(id) => id
        None => {
          println("error: no node starts at line \{line}")
          return
        }
      }
      let result = @slice.backward(pdg, target, program~)
      let result = @core.SliceResult::{
        nodes: result.nodes,
        lines: @query.visible_lines(program, result.nodes),
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
          @fs.IOError(msg) => println("error: failed to write \{out}: \{msg}")
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
      match @query.path_between(pdg, starts, goals) {
        Some(path) => {
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
        None => println("no path from \{from_var} to \{to_var}")
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
