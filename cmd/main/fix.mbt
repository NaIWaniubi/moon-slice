// `fix`: turn the dead-code findings into line edits.
//
// The command is a renderer and a file writer, nothing more: `src/refactor`
// decides what is safe to remove and proves it. The default output is a unified
// diff on stdout so the change can be reviewed (or piped to `git apply`);
// `--write` is the only mode that touches the working tree. A second run after
// `--write` plans no edits, which is the idempotency the tests pin down.

///|
fn collect_package_files(dir : String, out : Array[String]) -> Unit {
  let entries : Array[String] = @fs.read_dir(dir) catch {
    @fs.IOError(_) => []
  }
  entries.sort_by(fn(a, b) { a.lexical_compare(b) })
  for name in entries {
    let path = if dir == "." { name } else { dir + "/" + name }
    let directory = @fs.is_dir(path) catch {
      @fs.IOError(_) => false
    }
    if !directory && is_mbt_file(name) {
      out.push(path)
    }
  }
}

///|
fn fix_sources(paths : Array[String]) -> Array[@refactor.SourceFile] {
  let files : Array[@refactor.SourceFile] = []
  for path in paths {
    files.push(@refactor.SourceFile::{
      path: normalize_path(path),
      source: read_source(path),
    })
  }
  files
}

///|
fn plan_target_file(target : String) -> (@refactor.SourceFile, Array[@refactor.SourceFile]) {
  let normalized = normalize_path(target)
  let target_source = read_source(target)
  let dir = package_key(normalized)
  let paths : Array[String] = []
  collect_package_files(dir, paths)
  let files : Array[@refactor.SourceFile] = []
  let mut seen = false
  for path in paths {
    let candidate = normalize_path(path)
    let source = if candidate == normalized {
      target_source
    } else {
      read_source(path)
    }
    if candidate == normalized {
      seen = true
    }
    files.push(@refactor.SourceFile::{ path: candidate, source })
  }
  if !seen {
    files.push(@refactor.SourceFile::{ path: normalized, source: target_source })
  }
  (
    @refactor.SourceFile::{ path: normalized, source: target_source },
    files,
  )
}

///|
fn plan_directory(dir : String) -> Array[@refactor.RemovalPlan] {
  let paths : Array[String] = []
  collect_mbt_files(dir, paths)
  let paths_sorted = paths.copy()
  paths_sorted.sort_by(fn(a, b) { a.lexical_compare(b) })
  let packages : Array[String] = []
  let groups : Map[String, Array[String]] = Map([])
  for path in paths_sorted {
    let key = package_key(path)
    match groups.get(key) {
      Some(group) => group.push(path)
      None => {
        packages.push(key)
        groups.set(key, [path])
      }
    }
  }
  packages.sort_by(fn(a, b) { a.lexical_compare(b) })
  let plans : Array[@refactor.RemovalPlan] = []
  for key in packages {
    match groups.get(key) {
      Some(group) => plans.push(@refactor.plan_package(fix_sources(group)))
      None => ()
    }
  }
  plans
}

///|
fn edits_for_file(edits : Array[@refactor.Edit], file : String) -> Array[@refactor.Edit] {
  let out : Array[@refactor.Edit] = []
  for edit in edits {
    if edit.file == file {
      out.push(edit)
    }
  }
  out
}

///|
/// Run `fix`. `target` is the `--file` argument, `dir` the `--dir` one; exactly
/// one of them is non-empty. `write` turns the plan into file changes.
fn run_fix(target : String, dir : String, json : Bool, write : Bool) -> Unit {
  let plans : Array[@refactor.RemovalPlan] = []
  let sources : Map[String, String] = Map([])
  if target != "" {
    let (source_file, package_files) = plan_target_file(target)
    sources.set(source_file.path, source_file.source)
    for file in package_files {
      sources.set(file.path, file.source)
    }
    plans.push(@refactor.plan_file(source_file, package_files))
  } else {
    let is_directory = @fs.is_dir(dir) catch {
      @fs.IOError(_) => false
    }
    if !is_directory {
      fail_code("read_failed", "not a directory: \{dir}")
    }
    let paths : Array[String] = []
    collect_mbt_files(dir, paths)
    for path in paths {
      let normalized = normalize_path(path)
      if !sources.contains(normalized) {
        sources.set(normalized, read_source(path))
      }
    }
    for plan in plan_directory(dir) {
      plans.push(plan)
    }
  }
  let plan = @refactor.merge_plans(plans)
  let files : Array[String] = []
  for edit in plan.edits {
    if !files.contains(edit.file) {
      files.push(edit.file)
    }
  }
  files.sort_by(fn(a, b) { a.lexical_compare(b) })
  if write {
    for file in files {
      let edits = edits_for_file(plan.edits, file)
      let source = match sources.get(file) {
        Some(text) => text
        None => ""
      }
      let edited = @refactor.apply_edits(source, edits)
      @fs.write_string_to_file(file, edited) catch {
        @fs.IOError(msg) => fail_code("write_failed", "failed to write \{file}: \{msg}")
      }
      if !json {
        println("wrote " + file + " (" + edits.length().to_string() + " edit(s))")
      }
    }
  } else if !json {
    let out = StringBuilder()
    for file in files {
      let edits = edits_for_file(plan.edits, file)
      let source = match sources.get(file) {
        Some(text) => text
        None => ""
      }
      out.write_string(@refactor.to_unified_diff(file, source, edits))
    }
    let rendered = out.to_string()
    if rendered != "" {
      println(rendered)
    }
  }
  if json {
    println(@refactor.to_json(plan))
  }
}
