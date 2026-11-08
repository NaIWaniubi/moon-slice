// Package-scope slicing: the inter-procedural expansion, but with the callee
// looked up across every file of the package instead of only the current one.
//
// The single-file expansion cannot see a callee that lives in a sibling file
// (a private function is visible to its whole package, so that is the normal
// case in real code). Rather than pretend the call has no body, this module
// builds a package index and expands across files.
//
// The result is per file, because a node id is only meaningful inside the
// program it came from.

///|
pub(all) struct PackageFile {
  path : String
  program : @core.Program
  pdg : @core.Pdg
  /// `x.f()` sites whose receiver type is written in the source.
  receivers : Array[@parser_adapter.ReceiverCall]
  /// Methods this file declares, so a dot call can be matched to a real owner.
  methods : Array[@parser_adapter.MethodDecl]
  /// Kept so `index` can resolve receiver calls again once every file's
  /// declarations are known: a struct or enum may live in a sibling file.
  source : String
}

///|
pub(all) struct PackageIndex {
  files : Array[PackageFile]
}

///|
pub(all) struct FileSlice {
  path : String
  nodes : Array[Int32]
  lines : Array[Int32]
}

///|
/// Parse one file and run the passes the expansion needs. Files that do not
/// parse are kept out of the index: a slice built on a file nobody could read
/// would be a guess.
pub fn build_file(
  path : String,
  source : String,
  precise? : Bool = false,
) -> PackageFile? {
  let program = @parser_adapter.parse_source(source, path)
  if program.errors.length() > 0 {
    return None
  }
  let cfg = @cfg.build(program)
  let defuse = @defuse.analyze(program, cfg)
  // The control-dependence choice changes the return cone, so `--precise`
  // reaches into the expansion as well.
  let cdg = if precise {
    @cdg.build_precise(program, cfg)
  } else {
    @cdg.build(program, cfg)
  }
  let pdg = @pdg.build(defuse, cdg)
  // A second parse, kept separate so `parse_source` stays the single place
  // that lowers the AST into the node IR.
  let facts = @parser_adapter.call_facts(source, path)
  Some(PackageFile::{
    path,
    program,
    pdg,
    receivers: facts.receivers,
    methods: facts.methods,
    source,
  })
}

///|
pub fn index(files : Array[PackageFile]) -> PackageIndex {
  // Receiver resolution needs the package's declarations, not just this file's:
  // a struct's fields or an enum's variants are often declared next door. Merge
  // first, then resolve every file again against the merged table.
  let merged : @parser_adapter.DeclTable = @parser_adapter.empty_decls()
  for file in files {
    @parser_adapter.merge_decls(
      merged,
      @parser_adapter.declared_types(file.source, file.path),
    )
  }
  let updated : Array[PackageFile] = []
  for file in files {
    let facts = @parser_adapter.call_facts(
      file.source,
      file.path,
      extra=merged,
    )
    updated.push(PackageFile::{
      path: file.path,
      program: file.program,
      pdg: file.pdg,
      receivers: facts.receivers,
      methods: file.methods,
      source: file.source,
    })
  }
  PackageIndex::{ files: updated }
}

///|
fn file_index_of(index : PackageIndex, path : String) -> Int {
  let mut found = -1
  let mut i = 0
  while i < index.files.length() {
    if index.files[i].path == path {
      found = i
    }
    i = i + 1
  }
  found
}

///|
/// Where `name` is defined: `(file index, entry, exit)`. The file the call
/// appears in is searched first, so a local definition always wins over a
/// same-named one elsewhere — the same choice the single-file expansion makes.
fn search_order(index : PackageIndex, from : Int) -> Array[Int] {
  let dir = package_dir(index.files[from].path)
  let order : Array[Int] = [from]
  let mut i = 0
  while i < index.files.length() {
    if i != from && package_dir(index.files[i].path) == dir {
      order.push(i)
    }
    i = i + 1
  }
  i = 0
  while i < index.files.length() {
    if i != from && package_dir(index.files[i].path) != dir {
      order.push(i)
    }
    i = i + 1
  }
  order
}

///|
fn find_callee(
  index : PackageIndex,
  from : Int,
  name : String,
) -> (Int, @core.FunctionInfo)? {
  for candidate in search_order(index, from) {
    match @query.function_named(index.files[candidate].program, name) {
      Some(info) => return Some((candidate, info))
      None => ()
    }
  }
  None
}

///|
/// The function whose boundary starts at `line`. Two types may declare the same
/// method name in one file, so the declaration line is what makes the lookup
/// belong to one of them.
fn function_at_line(program : @core.Program, line : Int32) -> @core.FunctionInfo? {
  for info in program.functions {
    match @query.node_by_id(program, info.entry) {
      Some(node) =>
        if node.loc.start_line == line {
          return Some(info)
        }
      None => ()
    }
  }
  None
}

///|
/// Where `owner::name` is declared, in the same preference order as
/// `find_callee`: this file, then this directory, then the rest of the package.
fn find_method(
  index : PackageIndex,
  from : Int,
  owner : String,
  name : String,
) -> (Int, @core.FunctionInfo)? {
  for candidate in search_order(index, from) {
    let file = index.files[candidate]
    let mut line : Int32 = -1
    for decl in file.methods {
      if decl.owner == owner && decl.name == name {
        line = decl.line
      }
    }
    if line >= 0 {
      match function_at_line(file.program, line) {
        Some(info) => return Some((candidate, info))
        None => ()
      }
      // A multi-line signature can move the boundary off the name's line; fall
      // back to the name, which is what the qualified-call path already does.
      match @query.function_named(file.program, name) {
        Some(info) => return Some((candidate, info))
        None => ()
      }
    }
  }
  None
}

///|
fn call_lines_in(program : @core.Program, nodes : Array[Int32]) -> Set[Int32] {
  let lines : Set[Int32] = Set([])
  for id in nodes {
    match @query.node_by_id(program, id) {
      Some(node) =>
        if node.kind == @core.SNodeKind::Call {
          lines.add(node.loc.start_line)
        }
      None => ()
    }
  }
  lines
}

///|
fn push_new(target : Array[Int32], id : Int32) -> Bool {
  if target.contains(id) {
    false
  } else {
    target.push(id)
    true
  }
}

///|
fn add_whole_body(target : Array[Int32], info : @core.FunctionInfo) -> Bool {
  let mut changed = false
  let mut id = info.entry + 1
  while id < info.exit {
    if push_new(target, id) {
      changed = true
    }
    id = id + 1
  }
  changed
}

///|
/// Side-effect summaries of every function the package declares, keyed by name.
///
/// The batch is what closes the call graph: `pure` means "transitively
/// effect-free within this package", which is the verdict a bare call needs.
/// The first summary of a name wins, matching `@sidefx`'s own lookup.
fn summaries_of(index : PackageIndex) -> Map[String, @sidefx.SideEffects] {
  let sources : Array[@sidefx.FnSource] = []
  for file in index.files {
    for info in file.program.functions {
      sources.push(@sidefx.FnSource::{ name: info.name, source: file.source })
    }
  }
  let table : Map[String, @sidefx.SideEffects] = Map([])
  for summary in @sidefx.summarize_package(sources) {
    if !table.contains(summary.name) {
      table.set(summary.name, summary.effects)
    }
  }
  table
}

///|
/// Every name a call inside the package can resolve to: the functions and
/// methods it declares, the IO names, and the panic helpers. A call to anything
/// else is a boundary the summary cannot see through.
fn callable_names(index : PackageIndex) -> Set[String] {
  let known : Set[String] = Set([])
  for file in index.files {
    for info in file.program.functions {
      known.add(info.name)
    }
    for declared in file.methods {
      known.add(declared.name)
    }
  }
  for name in @sidefx.default_io_names() {
    known.add(name)
  }
  known.add("panic")
  known.add("fail")
  known.add("abort")
  known.add("unreachable")
  known
}

///|
/// A structural node with no source statement of its own: a branch region or a
/// loop's step block.
fn is_container_node(node : @core.SNode) -> Bool {
  node.children.length() > 0 && node.defs.length() == 0 && node.uses.length() == 0
}

///|
/// Add every node of `info`'s body that starts on `line`.
fn add_line_nodes(
  program : @core.Program,
  info : @core.FunctionInfo,
  line : Int32,
  target : Array[Int32],
) -> Bool {
  let mut grew = false
  for node in program.nodes {
    if node.id > info.entry && node.id < info.exit && node.loc.start_line == line {
      if push_new(target, node.id) {
        grew = true
      }
    }
  }
  grew
}

///|
/// The value a bare call hands back: every `Return` node of the body, or — for
/// a body whose value is its trailing expression — that last statement.
fn add_return_nodes(
  program : @core.Program,
  info : @core.FunctionInfo,
  target : Array[Int32],
) -> Bool {
  let mut grew = false
  let mut has_return = false
  for node in program.nodes {
    if node.id > info.entry && node.id < info.exit && node.kind == @core.SNodeKind::Return {
      has_return = true
      if push_new(target, node.id) {
        grew = true
      }
    }
  }
  if !has_return {
    let mut last : Int32 = -1
    for node in program.nodes {
      if node.id > info.entry &&
        node.id < info.exit &&
        !is_container_node(node) &&
        node.id > last {
        last = node.id
      }
    }
    if last >= 0 && push_new(target, last) {
      grew = true
    }
  }
  grew
}

///|
fn effect_lines_of(
  file : PackageFile,
  name : String,
  cache : Map[String, @parser_adapter.EffectLines],
) -> @parser_adapter.EffectLines {
  let key = file.path + "\u{0}" + name
  match cache.get(key) {
    Some(found) => found
    None => {
      let found = @parser_adapter.effect_lines(file.source, name)
      cache.set(key, found)
      found
    }
  }
}

///|
/// A callee in UpperCamelCase is a constructor application (`Some(v)`,
/// `Failure("x")`), which allocates a value and is not an edge the summary has
/// to resolve. `@sidefx` records it as a call because it cannot tell either; it
/// is filtered here so it does not force the whole body back in.
fn is_constructor_name(name : String) -> Bool {
  for ch in name.iter() {
    let code = ch.to_int()
    return code >= 'A'.to_int() && code <= 'Z'.to_int()
  }
  false
}

///|
/// Whether the summary can be acted on. A call the package does not declare — a
/// dependency, a function value, a method of an unknown type — may do anything,
/// so the summary is not a safe reason to drop the body.
fn summary_is_usable(
  effects : @sidefx.SideEffects,
  lines : @parser_adapter.EffectLines,
  known : Set[String],
) -> Bool {
  for name in effects.calls {
    if !known.contains(name) && !is_constructor_name(name) {
      return false
    }
  }
  for call in lines.calls {
    if call.name == "" || !known.contains(call.name) {
      return false
    }
  }
  true
}

///|
/// Pull in the statements of `info` a caller can observe. `effects` decides
/// whether the body does anything at all; `lines` says where.
fn add_observable(
  program : @core.Program,
  info : @core.FunctionInfo,
  effects : @sidefx.SideEffects,
  lines : @parser_adapter.EffectLines,
  summaries : Map[String, @sidefx.SideEffects],
  target : Array[Int32],
) -> Bool {
  if effects.pure {
    return false
  }
  let mut grew = false
  for line in lines.writes {
    if add_line_nodes(program, info, line, target) {
      grew = true
    }
  }
  for line in lines.raises {
    if add_line_nodes(program, info, line, target) {
      grew = true
    }
  }
  for line in lines.io {
    if add_line_nodes(program, info, line, target) {
      grew = true
    }
  }
  // Impurity also travels through calls. The call statement has to be part of
  // the slice, or the next round cannot follow it into the impure callee.
  for call in lines.calls {
    match summaries.get(call.name) {
      Some(callee_effects) =>
        if !callee_effects.pure {
          if add_line_nodes(program, info, call.line, target) {
            grew = true
          }
        }
      None => ()
    }
  }
  grew
}

///|
/// A bare call: the observable statements plus the returned value, or the whole
/// body when the summary cannot be trusted.
fn expand_bare_call(
  index : PackageIndex,
  callee_file : Int,
  info : @core.FunctionInfo,
  sets : Array[Array[Int32]],
  summaries : Map[String, @sidefx.SideEffects],
  known : Set[String],
  cache : Map[String, @parser_adapter.EffectLines],
) -> Bool {
  let file = index.files[callee_file]
  let target = sets[callee_file]
  let effects = match summaries.get(info.name) {
    Some(found) => found
    None => return add_whole_body(target, info)
  }
  let lines = effect_lines_of(file, info.name, cache)
  if !summary_is_usable(effects, lines, known) {
    return add_whole_body(target, info)
  }
  let mut grew = false
  if add_return_nodes(file.program, info, target) {
    grew = true
  }
  if add_observable(file.program, info, effects, lines, summaries, target) {
    grew = true
  }
  grew
}

///|
/// A value-returning call keeps its return cone and gains the callee's
/// observable statements: a write before the `return` is part of what the call
/// does, even though it does not produce the value.
fn add_value_effects(
  index : PackageIndex,
  callee_file : Int,
  info : @core.FunctionInfo,
  target : Array[Int32],
  summaries : Map[String, @sidefx.SideEffects],
  cache : Map[String, @parser_adapter.EffectLines],
) -> Bool {
  let effects = match summaries.get(info.name) {
    Some(found) => found
    None => return false
  }
  let file = index.files[callee_file]
  let lines = effect_lines_of(file, info.name, cache)
  add_observable(file.program, info, effects, lines, summaries, target)
}

///|
fn is_ident_char(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
  (code >= '0'.to_int() && code <= '9'.to_int()) ||
  ch == '_'
}

///|
fn flush_name(out : Array[String], buffer : StringBuilder) -> Unit {
  if !buffer.is_empty() {
    let name = buffer.to_string()
    if !out.contains(name) {
      out.push(name)
    }
    ignore(buffer.reset())
  }
}

///|
/// The names an argument expression mentions. A bare identifier is its own
/// name; a compound expression is tokenised, which over-approximates a string
/// literal but never drops a variable the expression really reads.
fn argument_names(text : String) -> Array[String] {
  let out : Array[String] = []
  let buffer = StringBuilder()
  for ch in text.iter() {
    if is_ident_char(ch) {
      buffer.write_char(ch)
    } else {
      flush_name(out, buffer)
    }
  }
  flush_name(out, buffer)
  out
}

///|
/// The definition of `name` in `info` that reaches `before`: the last defining
/// node strictly inside the body and before the call.
fn definition_before(
  program : @core.Program,
  info : @core.FunctionInfo,
  before : Int32,
  name : String,
) -> Int32? {
  let mut best : Int32 = -1
  for node in program.nodes {
    if node.id > info.entry && node.id < info.exit && node.id < before {
      for variable in node.defs {
        if variable.name == name && node.id > best {
          best = node.id
        }
      }
    }
  }
  if best >= 0 { Some(best) } else { None }
}

///|
/// The caller side of a call edge: the definition of every variable the call
/// passes. A slice started at the call statement then reports where each
/// argument came from, which is the dependency the edge represents.
fn add_argument_nodes(
  file : PackageFile,
  caller : @core.FunctionInfo,
  call_node : Int32,
  line : Int32,
  target : Array[Int32],
  cache : Map[String, Array[@parser_adapter.CallArgument]],
) -> Bool {
  let key = file.path + "\u{0}" + caller.name + "\u{0}" + line.to_string()
  let arguments = match cache.get(key) {
    Some(found) => found
    None => {
      let found = @parser_adapter.call_arguments(file.source, caller.name, line)
      cache.set(key, found)
      found
    }
  }
  let mut grew = false
  for argument in arguments {
    if argument.expr_text == "" {
      continue
    }
    for name in argument_names(argument.expr_text) {
      match definition_before(file.program, caller, call_node, name) {
        Some(id) =>
          if push_new(target, id) {
            grew = true
          }
        None => ()
      }
    }
  }
  grew
}

///|
/// Expand `result` (a slice of `target`) to a fixed point, following call sites
/// into whichever file of the package defines the callee.
///
/// A bare call statement is answered with the callee's side-effect summary, not
/// its whole body: only the statements a caller can observe — a field or element
/// write, a receiver mutation, a raise, an IO call, a call to a function that is
/// itself impure — and the value it hands back are pulled in. When the summary
/// cannot be trusted (the callee is unknown, its body does not parse, or it
/// calls something this package does not declare) the whole body is the safe
/// answer and is used instead.
///
/// A value-returning call keeps its return-value cone and gains those same
/// observable statements, so an assignment position no longer hides a write
/// that happens before the value is produced.
///
/// Arguments are mapped onto parameters: the definition of every variable the
/// call passes is part of the slice, which is the caller side of the call edge.
pub fn expand(index : PackageIndex, target : String, result : @core.SliceResult) -> Array[FileSlice] {
  let start = file_index_of(index, target)
  if start < 0 {
    return []
  }
  let sets : Array[Array[Int32]] = []
  for file in index.files {
    sets.push(if file.path == target { result.nodes.copy() } else { [] })
  }
  let summaries = summaries_of(index)
  let known = callable_names(index)
  let effect_cache : Map[String, @parser_adapter.EffectLines] = Map([])
  let argument_cache : Map[String, Array[@parser_adapter.CallArgument]] = Map([])
  // A receiver call only becomes an edge when this package declares that method
  // on the receiver's type; otherwise it may belong to a dependency.
  let declared : Set[String] = Set([])
  for file in index.files {
    for decl in file.methods {
      declared.add(decl.owner + "::" + decl.name)
    }
  }
  let mut changed = true
  let mut rounds = 0
  let mut function_count = 0
  for file in index.files {
    function_count = function_count + file.program.functions.length()
  }
  let max_rounds = function_count + 4
  while changed && rounds < max_rounds {
    changed = false
    rounds = rounds + 1
    let mut i = 0
    while i < index.files.length() {
      let file = index.files[i]
      let nodes = sets[i]
      if nodes.length() > 0 {
        for call in file.program.calls {
          match @query.function_named(file.program, call.caller) {
            None => ()
            Some(caller) =>
              match @query.call_site_node(file.program, caller, call.callee, call.line, nodes) {
                None => ()
                Some(node) =>
                  match find_callee(index, i, call.callee) {
                    None => ()
                    Some((callee_file, info)) => {
                      let callee_nodes = sets[callee_file]
                      let mut grew = false
                      if node.kind == @core.SNodeKind::Call {
                        if expand_bare_call(
                          index,
                          callee_file,
                          info,
                          sets,
                          summaries,
                          known,
                          effect_cache,
                        ) {
                          grew = true
                        }
                      } else {
                        let cone = @query.return_cone(
                          index.files[callee_file].program,
                          index.files[callee_file].pdg,
                          info,
                        )
                        if cone.length() == 0 {
                          if add_whole_body(callee_nodes, info) {
                            grew = true
                          }
                        } else {
                          for id in cone {
                            if push_new(callee_nodes, id) {
                              grew = true
                            }
                          }
                        }
                        if add_value_effects(
                          index,
                          callee_file,
                          info,
                          callee_nodes,
                          summaries,
                          effect_cache,
                        ) {
                          grew = true
                        }
                      }
                      if add_argument_nodes(
                        file,
                        caller,
                        node.id,
                        call.line,
                        nodes,
                        argument_cache,
                      ) {
                        grew = true
                      }
                      if grew {
                        changed = true
                      }
                    }
                  }
              }
          }
        }
        // `p.norm()` where `p : Point` and the package declares `Point::norm`.
        // The whole body is pulled in: the IR does not say whether the result
        // is used, and a side-effecting call must not be under-approximated.
        if file.receivers.length() > 0 {
          let call_lines = call_lines_in(file.program, nodes)
          for receiver in file.receivers {
            if call_lines.contains(receiver.line) &&
              declared.contains(receiver.receiver_type + "::" + receiver.method_name) {
              match find_method(
                index,
                i,
                receiver.receiver_type,
                receiver.method_name,
              ) {
                None => ()
                Some((callee_file, info)) =>
                  if add_whole_body(sets[callee_file], info) {
                    changed = true
                  }
              }
            }
          }
        }
      }
      i = i + 1
    }
  }
  let out : Array[FileSlice] = []
  let mut i = 0
  while i < index.files.length() {
    let file = index.files[i]
    let nodes = sets[i]
    if nodes.length() > 0 {
      nodes.sort()
      out.push(FileSlice::{
        path: file.path,
        nodes,
        lines: @query.visible_lines(file.program, nodes),
      })
    }
    i = i + 1
  }
  out
}

///|
/// The files of `index` whose directory is `key`: a MoonBit package is one
/// directory, so this is the set that shares visibility.
pub fn files_in_package(index : PackageIndex, key : String) -> Array[String] {
  let out : Array[String] = []
  for file in index.files {
    if package_dir(file.path) == key {
      out.push(file.path)
    }
  }
  out
}

///|
pub fn package_dir(path : String) -> String {
  let mut last = -1
  let mut i = 0
  for ch in path.iter() {
    if ch == '/' {
      last = i
    }
    i = i + 1
  }
  if last < 0 { "." } else { path[:last].to_owned() }
}

///|
pub(all) struct CallSiteRef {
  path : String
  line : Int32
  caller : String
}

///|
/// Every place in the index that calls `name`, with the enclosing function.
///
/// This is the mirror of the expansion: `expand` answers "what does this call
/// run?", this answers "who runs this function?". Both work across the package,
/// which is the scope a private function is visible in.
pub fn callers(index : PackageIndex, name : String) -> Array[CallSiteRef] {
  // A dot call is only an edge when the receiver's type declares that method in
  // this package. Without the owner check `p.norm()` would be credited to any
  // free function named `norm`, which is exactly the invented edge the call
  // collector refuses to make.
  let declared : Set[String] = Set([])
  for file in index.files {
    for owner_of in file.methods {
      declared.add(owner_of.owner + "::" + owner_of.name)
    }
  }
  let out : Array[CallSiteRef] = []
  for file in index.files {
    for call in file.program.calls {
      if call.callee == name {
        let caller = match @query.function_named(file.program, call.caller) {
          Some(info) => info.name
          None => call.caller
        }
        out.push(CallSiteRef::{ path: file.path, line: call.line, caller })
      }
    }
    for receiver in file.receivers {
      if receiver.method_name == name &&
        declared.contains(receiver.receiver_type + "::" + name) {
        out.push(CallSiteRef::{
          path: file.path,
          line: receiver.line,
          caller: receiver.caller,
        })
      }
    }
  }
  out.sort_by(fn(a, b) {
    let by_file = a.path.lexical_compare(b.path)
    if by_file < 0 {
      -1
    } else if by_file > 0 {
      1
    } else if a.line < b.line {
      -1
    } else if a.line > b.line {
      1
    } else {
      0
    }
  })
  out
}
