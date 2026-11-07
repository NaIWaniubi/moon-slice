// Cross-check against the exact (post-dominator based) control dependence in
// `src/cdg`.
//
// The reference relation has two ingredients: control dependence computed from
// the enumerated executions, and one IR convention — a region node governs its
// own body, because the adapter materialises every branch and loop body as a
// node. `cdg.build_precise` computes the same control dependence without the
// region convention, so the reference must contain its edges exactly, and the
// surplus must consist of nothing but region edges. That is a second,
// independent confirmation of the path-enumeration result.

///|
fn pt_has_pair(items : Array[(Int32, Int32)], needle : (Int32, Int32)) -> Bool {
  let mut i = 0
  let mut found = false
  while i < items.length() {
    if items[i].0 == needle.0 && items[i].1 == needle.1 {
      found = true
    }
    i = i + 1
  }
  found
}

///|
/// True when `id` is a region node: a control kind owned by another control node.
fn pt_is_region(program : @core.Program, id : Int32) -> Bool {
  let mut owner_id = -1
  let mut kind = ""
  for node in program.nodes {
    match node.parent {
      Some(owner) =>
        if node.id == id {
          owner_id = owner
        }
      None => ()
    }
  }
  for node in program.nodes {
    if node.id == id {
      kind = match node.kind {
        @core.If => "if"
        @core.While => "while"
        @core.For => "for"
        @core.Match => "match"
        _ => ""
      }
    }
  }
  if kind == "" || owner_id < 0 {
    return false
  }
  for node in program.nodes {
    if node.id == owner_id {
      return match node.kind {
        @core.If | @core.While | @core.For | @core.Match => true
        _ => false
      }
    }
  }
  false
}

///|
fn pt_sources() -> Array[String] {
  [
    "fn f(a : Int, b : Int) -> Int {\n  let mut x = a\n  if a < b {\n    x = b\n  } else {\n    x = a + 1\n  }\n  x\n}\n",
    "fn f(a : Int, b : Int) -> Int {\n  let mut x = a\n  if a < b {\n    if a < 1 {\n      x = 2\n    }\n  }\n  x\n}\n",
    "fn f(a : Int) -> Int {\n  let mut x = a\n  if a < 1 {\n    return 2\n  }\n  x = 3\n  x\n}\n",
    "fn f(a : Int, b : Int) -> Int {\n  let mut x = a\n  while b < 3 {\n    while x < 4 {\n      x = x + 1\n    }\n    b = b + 1\n  }\n  x\n}\n",
    "fn f(a : Int, b : Int) -> Int {\n  let mut x = a\n  while b < 3 {\n    if x < 2 {\n      x = x + 1\n    }\n    b = b + 1\n  }\n  x\n}\n",
  ]
}

///|
test "the reference contains every exact control dependence" {
  for source in pt_sources() {
    let program = @oracle.parse(source)
    let reference = @oracle.reference_dependences(program)
    let cfg = @cfg.build(program)
    let precise = @cdg.build_precise(program, cfg)
    for pair in precise.edges {
      assert_true(pt_has_pair(reference.control, pair))
    }
  }
}

///|
test "the reference adds only region edges on top of exact control dependence" {
  for source in pt_sources() {
    let program = @oracle.parse(source)
    let reference = @oracle.reference_dependences(program)
    let cfg = @cfg.build(program)
    let precise = @cdg.build_precise(program, cfg)
    for pair in reference.control {
      if !pt_has_pair(precise.edges, pair) {
        assert_true(pt_is_region(program, pair.0))
      }
    }
  }
}
