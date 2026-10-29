// Regressions from a scan of real MoonBit repositories.
//
// The cases here were found by running `dead` over moonbitlang/async (368 files)
// and moonbitlang/x (166 files). Each one was a false positive that a real
// file triggered and no hand-written example did.

///|
fn real_world_pipeline(
  source : String,
) -> (@core.Program, @core.Cfg, @core.DefUse) {
  let program = @parser_adapter.parse_source(source, "real.mbt")
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  (program, cfg, defuse)
}

///|
test "an identifier read only by a string interpolation is a use" {
  // `"x=\{port}"` reads `port` at runtime. Before the fix the interpolation was
  // not traversed, so `port` looked unused and `dead` reported the binding.
  let source = "fn f(port : Int) -> String {\n  \"x=\\{port}\"\n}\n"
  let (program, _, _) = real_world_pipeline(source)
  assert_eq(program.errors.length(), 0)
  let expr = program.nodes[1]
  let mut found = false
  for variable in expr.uses {
    if variable.name == "port" {
      found = true
    }
  }
  assert_true(found)
}

///|
test "an interpolation reads every identifier inside it" {
  // `"\{ip >> 24}.\{port}"` reads both. Scanning the interpolation source text
  // keeps this conservative: extra names are harmless, a missing one is not.
  let source = "fn f(ip : Int, port : Int) -> String {\n  \"x=\\{ip >> 24}.\\{port}\"\n}\n"
  let (program, _, _) = real_world_pipeline(source)
  assert_eq(program.errors.length(), 0)
  let expr = program.nodes[1]
  let names : Array[String] = []
  expr.uses.each(fn(v) { names.push(v.name) })
  assert_true(names.contains("ip"))
  assert_true(names.contains("port"))
}

///|
test "a write through a parameter is not reported as dead" {
  // Trait setters (`self.field = value`) and buffer updates (`input.len += n`)
  // mutate caller-visible state. Reporting them as dead stores flagged every
  // setter in moonbitlang/async's queue implementation.
  let source = "struct T {\n  mut v : Int\n}\n\nimpl T with set_v(self : T, value : Int) -> Unit {\n  self.v = value\n}\n"
  let (program, _, defuse) = real_world_pipeline(source)
  assert_eq(program.errors.length(), 0)
  assert_eq(@query.dead_nodes(program, defuse), [])
}

///|
test "a read-modify-write through a local is not reported as dead" {
  // `buf.len = dropped - len` reads and writes the same base, which is how the
  // adapter represents a field write. Without escape analysis it must be
  // treated as observable.
  let source = "fn f(buf : B, dropped : Int, len : Int) -> Unit {\n  buf.len = dropped - len\n}\n"
  let (program, _, defuse) = real_world_pipeline(source)
  assert_eq(program.errors.length(), 0)
  assert_eq(@query.dead_nodes(program, defuse), [])
}

///|
test "a plain local store that is never read is still reported" {
  // The command must keep its purpose: `let unused = 1` and `x = 1` where `x`
  // is a local are the cases it exists for.
  let source = "fn f() -> Int {\n  let mut x = 0\n  x = 1\n  0\n}\n"
  let (program, _, defuse) = real_world_pipeline(source)
  let dead = @query.dead_nodes(program, defuse)
  assert_true(dead.length() >= 2)
}

///|
test "a C-style for runs its initialiser once and reaches the update" {
  // The initialiser used to be a definition on the loop head, so the head
  // re-ran it every iteration. Two symptoms: the update `i = i + 1` was
  // unreachable (reported dead), and the body's `i` reached the initialiser
  // instead of the update.
  let source = "fn f(n : Int) -> Int {\n  let mut k = 0\n  for i = 0; i < n; i = i + 1 {\n    k = k + i\n  }\n  return k\n}\n"
  let (program, cfg, defuse) = real_world_pipeline(source)
  assert_eq(program.errors.length(), 0)
  assert_eq(@query.dead_nodes(program, defuse), [])
  // The update node must be reachable and must reach the loop head.
  let head = program.nodes[3]
  assert_eq(head.kind, @core.SNodeKind::For)
  let mut update = -1
  for node in program.nodes {
    if node.kind == @core.SNodeKind::Assign && node.loc.start_line == 3 {
      let mut defines_i = false
      for variable in node.defs {
        if variable.name == "i" {
          defines_i = true
        }
      }
      if defines_i && node.uses.length() > 0 {
        update = node.id
      }
    }
  }
  assert_true(update >= 0)
  let mut reaches_head = false
  for edge in cfg.edges {
    if edge.0 == update && edge.1 == head.id {
      reaches_head = true
    }
  }
  assert_true(reaches_head)
}

///|
test "a structural container is not reported as unreachable code" {
  // The step block of `for i = 0, j = 0; ...` is an `Expr` container whose
  // children are reached through `continue`. Reporting the container named a
  // line with no statement to blame.
  let source = "fn f(n : Int) -> Int {\n  for i = 0, j = 0; i < n; i = i + 1 {\n    continue i + 1, j + 1\n  } nobreak {\n    i\n  }\n}\n"
  let (program, cfg, _) = real_world_pipeline(source)
  assert_eq(program.errors.length(), 0)
  let dead_code = @query.unreachable_nodes(program, cfg)
  for id in dead_code {
    let node = program.nodes[id]
    assert_true(!(node.children.length() > 0 && node.defs.length() == 0 && node.uses.length() == 0))
  }
}
