// Query helpers over a lowered `@core.Program`.

///|
fn is_synthetic(program : @core.Program, node : @core.SNode) -> Bool {
  for f in program.functions {
    if node.id == f.entry || node.id == f.exit {
      return true
    }
  }
  false
}

///|
fn is_region(program : @core.Program, node : @core.SNode) -> Bool {
  let control = node.kind == @core.SNodeKind::If ||
    node.kind == @core.SNodeKind::While ||
    node.kind == @core.SNodeKind::For ||
    node.kind == @core.SNodeKind::Match
  if !control || node.uses.length() != 0 || node.children.length() == 0 {
    return false
  }
  match node.parent {
    None => false
    Some(pid) =>
      pid >= 0 &&
      pid < program.nodes.length() &&
      program.nodes[pid].kind == node.kind &&
      program.nodes[pid].loc == node.loc
  }
}

///|
fn is_statement_kind(kind : @core.SNodeKind) -> Bool {
  match kind {
    @core.SNodeKind::Let => true
    @core.SNodeKind::LetMut => true
    @core.SNodeKind::Assign => true
    @core.SNodeKind::Return => true
    @core.SNodeKind::Break => true
    @core.SNodeKind::Continue => true
    @core.SNodeKind::Call => true
    _ => false
  }
}

///|
/// All node ids whose `loc.start_line` equals `line`, ascending.
pub fn nodes_at_line(program : @core.Program, line : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  for node in program.nodes {
    if node.loc.start_line == line {
      out.push(node.id)
    }
  }
  out.sort()
  out
}

///|
/// Pick the best node for a source line.
///
/// Preference: a real statement node, then a control head, then any non-region
/// node, then anything at all (synthetic entry for a function header). Regions
/// and synthetic entry/exit nodes are excluded unless nothing else matches.
pub fn target_node(program : @core.Program, line : Int32) -> Int32? {
  let statement : Array[Int32] = []
  let control : Array[Int32] = []
  let other : Array[Int32] = []
  let fallback : Array[Int32] = []
  for node in program.nodes {
    if node.loc.start_line != line {
      continue
    }
    if is_synthetic(program, node) || is_region(program, node) {
      fallback.push(node.id)
      continue
    }
    if is_statement_kind(node.kind) {
      statement.push(node.id)
    } else if node.kind == @core.SNodeKind::If ||
      node.kind == @core.SNodeKind::While ||
      node.kind == @core.SNodeKind::For ||
      node.kind == @core.SNodeKind::Match {
      control.push(node.id)
    } else {
      other.push(node.id)
    }
  }
  let pick = if statement.length() > 0 {
    statement[0]
  } else if control.length() > 0 {
    control[0]
  } else if other.length() > 0 {
    other[0]
  } else if fallback.length() > 0 {
    fallback[0]
  } else {
    return None
  }
  Some(pick)
}

///|
/// Definition nodes whose definitions never reach a use.
pub fn dead_nodes(
  program : @core.Program,
  defuse : @core.DefUse,
) -> Array[Int32] {
  let used : Set[Int32] = Set([])
  for pair in defuse.reaching {
    used.add(pair.0)
  }
  let out : Array[Int32] = []
  for node in program.nodes {
    if node.defs.length() > 0 &&
      !is_synthetic(program, node) &&
      !used.contains(node.id) {
      out.push(node.id)
    }
  }
  out.sort()
  out
}

///|
/// Unique sorted start lines for the given node ids.
pub fn lines_of(program : @core.Program, nodes : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = []
  for id in nodes {
    if id >= 0 && id < program.nodes.length() {
      let line = program.nodes[id].loc.start_line
      if !out.contains(line) {
        out.push(line)
      }
    }
  }
  out.sort()
  out
}

///|
/// Like `lines_of`, but drops synthetic entry/exit nodes. Those nodes carry the
/// function signature's line, which is not a statement a user asked to slice.
pub fn visible_lines(
  program : @core.Program,
  nodes : Array[Int32],
) -> Array[Int32] {
  let out : Array[Int32] = []
  for id in nodes {
    if id >= 0 && id < program.nodes.length() {
      let node = program.nodes[id]
      if !is_synthetic(program, node) {
        let line = node.loc.start_line
        if !out.contains(line) {
          out.push(line)
        }
      }
    }
  }
  out.sort()
  out
}
