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
  Some(PackageFile::{ path, program, pdg, receivers: facts.receivers, methods: facts.methods })
}

///|
pub fn index(files : Array[PackageFile]) -> PackageIndex {
  PackageIndex::{ files, }
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
fn find_callee(
  index : PackageIndex,
  from : Int,
  name : String,
) -> (Int, @core.FunctionInfo)? {
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
  for candidate in order {
    match @query.function_named(index.files[candidate].program, name) {
      Some(info) => return Some((candidate, info))
      None => ()
    }
  }
  None
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
/// Expand `result` (a slice of `target`) to a fixed point, following call sites
/// into whichever file of the package defines the callee.
///
/// Semantics match the single-file expansion exactly: a bare call statement
/// contributes the callee's whole body (its side effects cannot be summarised),
/// while a value-returning call contributes only the callee's return-value
/// cone. Arguments are never mapped onto parameters, for the soundness reason
/// documented on `@query.expand_calls`.
pub fn expand(index : PackageIndex, target : String, result : @core.SliceResult) -> Array[FileSlice] {
  let start = file_index_of(index, target)
  if start < 0 {
    return []
  }
  let sets : Array[Array[Int32]] = []
  for file in index.files {
    sets.push(if file.path == target { result.nodes.copy() } else { [] })
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
                      let grew = if node.kind == @core.SNodeKind::Call {
                        add_whole_body(callee_nodes, info)
                      } else {
                        let cone = @query.return_cone(
                          index.files[callee_file].program,
                          index.files[callee_file].pdg,
                          info,
                        )
                        if cone.length() == 0 {
                          add_whole_body(callee_nodes, info)
                        } else {
                          let mut grew = false
                          for id in cone {
                            if push_new(callee_nodes, id) {
                              grew = true
                            }
                          }
                          grew
                        }
                      }
                      if grew {
                        changed = true
                      }
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
