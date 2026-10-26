// Deterministic fuzz-style invariant tests. No external fuzzer: a small LCG
// generates straight-line/if programs, and every statement line is sliced.
// The invariants are structural (no crash, target included, valid line range,
// sorted unique outputs, idempotence), not a second reference slicer.

///|
fn gen_program(seed : Int32, statements : Int32) -> String {
  let mut state = seed
  let mut source = "fn f() -> Int {\n  let mut x = 0\n"
  let mut i = 0
  while i < statements {
    state = (state * 73 + 41) % 1000003
    let op = state % 4
    let k = state % 9 + 1
    if op == 0 {
      source = source + "  x = x + " + k.to_string() + "\n"
    } else if op == 1 {
      source = source + "  x = x - " + k.to_string() + "\n"
    } else if op == 2 {
      source = source +
        "  if x > " +
        k.to_string() +
        " { x = x - 1 } else { x = x + 1 }\n"
    } else {
      source = source + "  x = x + x\n"
    }
    i = i + 1
  }
  source + "  return x\n}\n"
}

///|
fn assert_sorted_unique(xs : Array[Int32]) -> Unit raise {
  let mut i = 1
  while i < xs.length() {
    assert_true(xs[i - 1] < xs[i])
    i = i + 1
  }
}

///|
test "fuzz: random programs keep slice invariants" {
  let mut seed = 1
  let mut case = 0
  while case < 100 {
    let source = gen_program(seed, 12)
    let program = @parser_adapter.parse_source(source, "fuzz.mbt")
    assert_eq(program.errors.length(), 0)
    let cfg = @cfg.build(program)
    let defuse = @defuse.analyze(program, cfg)
    let cdg = @cdg.build(program, cfg)
    let pdg = @pdg.build(defuse, cdg)
    let mut line = 1
    while line <= 24 {
      let line32 : Int32 = line.to_int64().to_int()
      match @query.target_node(program, line32) {
        Some(node) => {
          let backward = @slice.backward(pdg, node, program~)
          let forward = @slice.forward(pdg, node, program~)
          assert_true(backward.lines.contains(line32))
          assert_true(forward.lines.contains(line32))
          assert_sorted_unique(backward.nodes)
          assert_sorted_unique(backward.lines)
          assert_sorted_unique(forward.nodes)
          assert_sorted_unique(forward.lines)
          for l in backward.lines {
            assert_true(l >= 1 && l <= 40)
          }
          for l in forward.lines {
            assert_true(l >= 1 && l <= 40)
          }
          let again = @slice.backward(pdg, node, program~)
          assert_eq(again.nodes, backward.nodes)
          assert_eq(again.lines, backward.lines)
        }
        None => ()
      }
      line = line + 1
    }
    seed = seed + 1
    case = case + 1
  }
}

///|
test "fuzz: interprocedural expansion is a superset" {
  let source = @fs.read_file_to_string("bench/callgraph.mbt") catch {
    _ => panic()
  }
  let program = @parser_adapter.parse_source(source, "bench/callgraph.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  let cdg = @cdg.build(program, cfg)
  let pdg = @pdg.build(defuse, cdg)
  let node = match @query.target_node(program, 12) {
    Some(id) => id
    None => panic()
  }
  let base = @slice.backward(pdg, node, program~)
  let base = @core.SliceResult::{
    nodes: base.nodes,
    lines: @query.visible_lines(program, base.nodes),
  }
  let expanded = @query.expand_calls(program, base)
  for id in base.nodes {
    assert_true(expanded.nodes.contains(id))
  }
  for line in base.lines {
    assert_true(expanded.lines.contains(line))
  }
}
