// Seeded generator of small, syntactically valid MoonBit programs.
//
// The generator exists to feed the differential oracle, so it is built to make
// the *expected* answer unambiguous rather than to explore every corner of the
// language. Three rules follow from that:
//
//   * Statements are well typed enough for the parser adapter to lower them:
//     `let` bindings are immutable and never assigned, `let mut` bindings are the
//     only assignment targets, and every name is in scope where it is used.
//   * Control structure is flat. Branches and loop bodies are straight-line
//     statement sequences, and no control construct is nested inside another.
//     The pipelined `cdg` is the syntax-directed builder, which deliberately
//     over-approximates control dependence for nested constructs (a node nested
//     two levels deep is attributed to every enclosing branch, even when the
//     inner construct decides whether it runs). Keeping control flat keeps the
//     pipeline's answer exact, so a disagreement in the batch is a real
//     disagreement and not the documented over-approximation. The nested cases
//     are covered deliberately in `oracle_test.mbt` instead.
//   * No `return`, `break`, `continue` or `match`: those trigger the cdg escape
//     rule, which also over-approximates by design.
//
// The seed fully determines the text.

///|
/// Linear congruential generator. Small, fast and reproducible across
/// platforms; nothing here needs statistical quality, only reproducibility.
priv struct Rng {
  state : Array[Int]
}

///|
/// A generated program and its statement count.
pub(all) struct Generated {
  source : String
  /// Number of statements emitted, including those inside branches and loops.
  statements : Int
}

///|
/// Seed the generator. A seed of 0 would trap the multiplier at 0, so it is
/// mapped to a fixed non-zero constant instead.
fn rng_new(seed : Int32) -> Rng {
  let base = if seed == 0 { 123456789 } else { seed.to_int64().to_int() }
  { state: [((base * 1103515245 + 12345) & 1073741823)], }
}

///|
/// Next pseudo-random value in `0 … 1073741822`.
fn rng_next(rng : Rng) -> Int {
  let next = (rng.state[0] * 1103515245 + 12345) & 1073741823
  rng.state[0] = next
  next
}

///|
/// Uniform value in `0 … bound - 1` (`0` when `bound <= 0`).
fn rng_below(rng : Rng, bound : Int) -> Int {
  if bound <= 0 {
    0
  } else {
    rng_next(rng) % bound
  }
}

///|
/// Join generated lines with newlines.
fn concat_lines(lines : Array[String]) -> String {
  let out = StringBuilder()
  let mut i = 0
  while i < lines.length() {
    if i > 0 {
      out.write_string("\n")
    }
    out.write_string(lines[i])
    i = i + 1
  }
  out.to_string()
}

///|
/// One generated expression over the variables currently in scope.
fn gen_expr(rng : Rng, vars : Array[String]) -> String {
  let roll = rng_below(rng, 100)
  let left = vars[rng_below(rng, vars.length())]
  if roll < 25 {
    left
  } else if roll < 55 {
    let right = vars[rng_below(rng, vars.length())]
    left + " + " + right
  } else if roll < 75 {
    left + " * " + (1 + rng_below(rng, 4)).to_string()
  } else if roll < 90 {
    (rng_below(rng, 9)).to_string()
  } else {
    "helper(" + left + ")"
  }
}

///|
/// One generated condition over the variables in scope.
fn gen_cond(rng : Rng, vars : Array[String]) -> String {
  let left = vars[rng_below(rng, vars.length())]
  let roll = rng_below(rng, 3)
  if roll == 0 {
    left + " < " + (1 + rng_below(rng, 6)).to_string()
  } else if roll == 1 {
    left + " > " + vars[rng_below(rng, vars.length())]
  } else {
    left + " == " + (rng_below(rng, 5)).to_string()
  }
}

///|
/// A straight-line branch body: assignments to already-declared mutable
/// variables, plus the occasional branch-local `let`. `body_vars` collects the
/// names declared inside so later statements in the same body can read them.
fn gen_body(
  rng : Rng,
  muts : Array[String],
  outer_vars : Array[String],
  counter : Array[Int32],
  statements : Array[Int32],
) -> Array[String] {
  let lines : Array[String] = []
  let local_vars : Array[String] = []
  for name in outer_vars {
    local_vars.push(name)
  }
  let count = rng_below(rng, 3)
  let mut i = 0
  while i < count {
    let roll = rng_below(rng, 100)
    if roll < 65 || muts.length() == 0 {
      let name = "v" + counter[0].to_string()
      counter[0] = counter[0] + 1
      let expr = gen_expr(rng, local_vars)
      lines.push("    let " + name + " = " + expr)
      local_vars.push(name)
    } else {
      let target = muts[rng_below(rng, muts.length())]
      let expr = gen_expr(rng, local_vars)
      lines.push("    " + target + " = " + expr)
    }
    statements[0] = statements[0] + 1
    i = i + 1
  }
  lines
}

///|
/// Generate the source text of one program from `seed`.
pub fn generate_with_stats(seed : Int32) -> Generated {
  let rng = rng_new(seed)
  let counter : Array[Int32] = [0]
  let statements : Array[Int32] = [0]
  let header : Array[String] = [
    "fn helper(x : Int) -> Int {", "  x + 1", "}", "", "fn gen(a : Int, b : Int) -> Int {",
  ]
  let body : Array[String] = []
  let vars : Array[String] = ["a", "b"]
  let muts : Array[String] = []
  // Two mutable bindings up front, so assignments, branches and loops always
  // have a legal target and the early statements are never degenerate.
  let mut seed_index = 0
  while seed_index < 2 {
    let name = "v" + counter[0].to_string()
    counter[0] = counter[0] + 1
    let expr = gen_expr(rng, vars)
    body.push("  let mut " + name + " = " + expr)
    vars.push(name)
    muts.push(name)
    statements[0] = statements[0] + 1
    seed_index = seed_index + 1
  }
  let want = 6 + rng_below(rng, 9)
  let mut ifs = 0
  let mut loops = 0
  // The loop is bounded by the attempt counter as well as the target: a small
  // state machine that keeps drawing the same unavailable construct must still
  // terminate.
  let mut attempts = 0
  while statements[0] < want && attempts < 200 {
    attempts = attempts + 1
    let roll = rng_below(rng, 100)
    if roll < 28 {
      let name = "v" + counter[0].to_string()
      counter[0] = counter[0] + 1
      let expr = gen_expr(rng, vars)
      body.push("  let mut " + name + " = " + expr)
      vars.push(name)
      muts.push(name)
      statements[0] = statements[0] + 1
    } else if roll < 42 {
      let name = "v" + counter[0].to_string()
      counter[0] = counter[0] + 1
      let expr = gen_expr(rng, vars)
      body.push("  let " + name + " = " + expr)
      vars.push(name)
      statements[0] = statements[0] + 1
    } else if roll < 72 && muts.length() > 0 {
      let target = muts[rng_below(rng, muts.length())]
      let expr = gen_expr(rng, vars)
      body.push("  " + target + " = " + expr)
      statements[0] = statements[0] + 1
    } else if roll < 86 && ifs < 2 {
      let cond = gen_cond(rng, vars)
      body.push("  if " + cond + " {")
      for line in gen_body(rng, muts, vars, counter, statements) {
        body.push(line)
      }
      body.push("  } else {")
      for line in gen_body(rng, muts, vars, counter, statements) {
        body.push(line)
      }
      body.push("  }")
      ifs = ifs + 1
      statements[0] = statements[0] + 1
    } else if loops < 1 && muts.length() > 0 {
      let cond = gen_cond(rng, vars)
      body.push("  while " + cond + " {")
      for line in gen_body(rng, muts, vars, counter, statements) {
        body.push(line)
      }
      body.push("  }")
      loops = loops + 1
      statements[0] = statements[0] + 1
    } else if muts.length() > 0 {
      let target = muts[rng_below(rng, muts.length())]
      let expr = gen_expr(rng, vars)
      body.push("  " + target + " = " + expr)
      statements[0] = statements[0] + 1
    } else {
      let name = "v" + counter[0].to_string()
      counter[0] = counter[0] + 1
      body.push("  let mut " + name + " = " + gen_expr(rng, vars))
      vars.push(name)
      muts.push(name)
      statements[0] = statements[0] + 1
    }
  }
  let result = vars[rng_below(rng, vars.length())]
  body.push("  " + result)
  let lines : Array[String] = []
  for line in header {
    lines.push(line)
  }
  for line in body {
    lines.push(line)
  }
  lines.push("}")
  { source: concat_lines(lines) + "\n", statements: statements[0] }
}

///|
/// Generate one program's source text. Shorthand for
/// `generate_with_stats(seed).source`.
pub fn generate(seed : Int32) -> String {
  generate_with_stats(seed).source
}
