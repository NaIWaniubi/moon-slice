// Turning a pile of files into a package graph.
//
// A directory of `.mbt` files is not a compilation unit in MoonBit — a package
// is, and a package is a directory that also has a `moon.pkg` saying which other
// packages it needs. Everything downstream (what to rebuild after an edit, which
// tests a change can break) needs that structure, so it is recovered here from
// paths and text alone, with no filesystem access.

///|
/// The forward-slash form of `path`, with `./` prefixes and trailing `/`
/// removed.
///
/// Paths are compared textually further down, so two spellings of one file must
/// not look like two files. Windows separators are folded rather than rejected
/// because a build tool on Windows reports them, and a workspace graph that
/// silently split on `\` would report every package as changed.
pub fn normalize_path(path : String) -> String {
  let out = StringBuilder()
  for ch in path.iter() {
    if ch == '\\' {
      out.write_char('/')
    } else {
      out.write_char(ch)
    }
  }
  let mut text = out.to_string()
  let mut stripping = true
  while stripping {
    match text.strip_prefix("./") {
      Some(rest) => {
        text = rest.to_owned()
      }
      None => {
        stripping = false
      }
    }
  }
  let mut trailing = true
  while trailing {
    match text.strip_suffix("/") {
      Some(rest) => {
        text = rest.to_owned()
      }
      None => {
        trailing = false
      }
    }
  }
  text
}

///|
/// Split a normalised path into its directory and its file name.
///
/// The directory of a top-level file is `""`, the module root, not `.`; that
/// keeps `dir` directly usable as a package key and as the suffix of an import
/// path. Repeated separators collapse, because a doubled `/` names no other
/// directory.
fn split_dir_base(path : String) -> (String, String) {
  let dir = StringBuilder()
  let base = StringBuilder()
  for ch in path.iter() {
    if ch == '/' {
      if dir.is_empty() {
        dir.write_string(base.to_string())
      } else {
        dir.write_char('/')
        dir.write_string(base.to_string())
      }
      ignore(base.reset())
    } else {
      base.write_char(ch)
    }
  }
  (dir.to_string(), base.to_string())
}

///|
/// The package directory of `path`: everything before the last `/`.
///
/// `dir_of("src/a/a.mbt")` is `"src/a"`; `dir_of("a.mbt")` is `""`.
pub fn dir_of(path : String) -> String {
  let parts = split_dir_base(normalize_path(path))
  parts.0
}

///|
/// The last segment of `path`, which is the file name.
pub fn file_name(path : String) -> String {
  let parts = split_dir_base(normalize_path(path))
  parts.1
}

///|
/// Whether `path` is a test file of its package.
///
/// Both test forms belong to the package directory and neither is part of what
/// the package exports: `*_test.mbt` is a black-box test that sees only the
/// public API, `*_wbtest.mbt` a white-box test that sees the package internals.
pub fn is_test_path(path : String) -> Bool {
  let base = file_name(path)
  base.has_suffix("_test.mbt") || base.has_suffix("_wbtest.mbt")
}

///|
/// Sort a string array the way every list in this package is ordered.
fn sort_strings(items : Array[String]) -> Unit {
  items.sort_by(fn(a, b) { a.lexical_compare(b) })
}

///|
fn push_into(map : Map[String, Array[String]], key : String, value : String) -> Unit {
  match map.get(key) {
    Some(items) => push_unique(items, value)
    None => map.set(key, [value])
  }
}

///|
fn sorted_files(map : Map[String, Array[String]], dir : String) -> Array[String] {
  let out : Array[String] = []
  match map.get(dir) {
    Some(items) => {
      for item in items {
        out.push(item)
      }
    }
    None => ()
  }
  sort_strings(out)
  out
}

///|
/// The import path of a package: the module name for the root, and the module
/// name plus the directory for everything else.
fn package_name(module_name : String, dir : String) -> String {
  if dir == "" {
    module_name
  } else {
    module_name + "/" + dir
  }
}

///|
/// The workspace-relative directory an import path names, or `None` when the
/// import is a dependency of another module.
///
/// Only paths under the module itself can be resolved to a directory this graph
/// holds; `moonbitlang/parser` is a real dependency but not a package that a
/// change to this workspace can invalidate.
fn internal_dir(module_name : String, import_path : String) -> String? {
  if module_name.is_empty() {
    return None
  }
  if import_path == module_name {
    return Some("")
  }
  match import_path.strip_prefix(module_name + "/") {
    Some(rest) => Some(rest.to_owned())
    None => None
  }
}

///|
fn resolve_dep(
  module_name : String,
  import_path : String,
  own_dir : String,
  known : Set[String],
  out : Array[String],
) -> Unit {
  match internal_dir(module_name, import_path) {
    Some(dir) => {
      if dir != own_dir && known.contains(dir) {
        push_unique(out, dir)
      }
    }
    None => ()
  }
}

///|
/// Build the package graph of a workspace.
///
/// `files` is every file the caller has: the `.mbt` files, the `moon.pkg` of
/// each package, and optionally `moon.mod`. A package is created for every
/// directory that holds a `moon.pkg` or a `.mbt` file, so a package whose
/// manifest is missing still appears — with `has_manifest == false` — instead of
/// its files vanishing from the graph.
///
/// A `moon.pkg` that does not parse contributes no dependencies rather than
/// aborting the build: one broken manifest should not make the other ninety
/// packages unknown. Callers that want the reason call `parse_pkg` directly.
pub fn build_graph(module_name : String, files : Array[WorkspaceFile]) -> PackageGraph {
  let sources : Map[String, Array[String]] = Map([])
  let tests : Map[String, Array[String]] = Map([])
  let manifests : Map[String, String] = Map([])
  let known : Set[String] = Set([])
  let dirs : Array[String] = []
  for file in files {
    let path = normalize_path(file.path)
    let dir = dir_of(path)
    let base = file_name(path)
    if base == "moon.pkg" {
      manifests.set(dir, file.content)
      if !known.contains(dir) {
        known.add(dir)
        dirs.push(dir)
      }
    } else if base == "moon.mod" {
      continue
    } else if base.has_suffix(".mbt") {
      if is_test_path(path) {
        push_into(tests, dir, path)
      } else {
        push_into(sources, dir, path)
      }
      if !known.contains(dir) {
        known.add(dir)
        dirs.push(dir)
      }
    }
  }
  let packages : Array[PackageNode] = []
  for dir in dirs {
    let imports : Array[String] = []
    let test_imports : Array[String] = []
    let mut pkgtype = PkgType::Library
    let mut is_main = false
    let mut has_manifest = false
    match manifests.get(dir) {
      Some(text) => {
        match parse_pkg(text) {
          Ok(manifest) => {
            for item in manifest.imports {
              push_unique(imports, item)
            }
            for item in manifest.test_imports {
              push_unique(test_imports, item)
            }
            pkgtype = manifest.pkgtype
            is_main = manifest.is_main
            has_manifest = true
          }
          Err(_) => ()
        }
      }
      None => ()
    }
    let deps : Array[String] = []
    for item in imports {
      resolve_dep(module_name, item, dir, known, deps)
    }
    for item in test_imports {
      resolve_dep(module_name, item, dir, known, deps)
    }
    sort_strings(deps)
    packages.push(PackageNode::{
      dir,
      name: package_name(module_name, dir),
      has_manifest,
      imports,
      test_imports,
      pkgtype,
      is_main,
      files: sorted_files(sources, dir),
      test_files: sorted_files(tests, dir),
      deps,
    })
  }
  packages.sort_by(fn(a, b) { a.dir.lexical_compare(b.dir) })
  PackageGraph::{ module_name, packages }
}

///|
/// The package rooted at `dir`, or `None` when the workspace has no such
/// directory.
pub fn find_package(graph : PackageGraph, dir : String) -> PackageNode? {
  let target = normalize_path(dir)
  for node in graph.packages {
    if node.dir == target {
      return Some(node)
    }
  }
  None
}

///|
/// The directories of every package, in graph order.
pub fn package_dirs(graph : PackageGraph) -> Array[String] {
  let out : Array[String] = []
  for node in graph.packages {
    out.push(node.dir)
  }
  out
}

///|
/// The packages that directly depend on `dir`, sorted.
///
/// Direct only: `invalidate` walks the result repeatedly to close over the whole
/// chain, and asking for the immediate answer is what makes one step of that
/// walk explainable.
pub fn dependents(graph : PackageGraph, dir : String) -> Array[String] {
  let out : Array[String] = []
  for node in graph.packages {
    if node.deps.contains(dir) {
      out.push(node.dir)
    }
  }
  sort_strings(out)
  out
}
