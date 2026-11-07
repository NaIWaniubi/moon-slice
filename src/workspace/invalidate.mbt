// Incremental invalidation: what an edit actually forces to be rebuilt.
//
// The interesting part is not which files changed — comparing two hash tables
// answers that — but which packages that reaches. A change to a leaf package
// forces everything that depends on it, directly or through a chain, because
// every consumer's compiled interface is downstream of it. A change to a package
// nothing imports reaches nothing else. Both answers come from the package graph,
// so the caller never has to walk it.

///|
fn graph_has_dir(graph : PackageGraph, dir : String) -> Bool {
  let target = normalize_path(dir)
  for node in graph.packages {
    if node.dir == target {
      return true
    }
  }
  false
}

///|
/// Seed the affected set with the packages a changed path touches.
///
/// `moon.mod` names no package, but it names the module: its name and version
/// prefix every import path in the workspace, so a change to it invalidates
/// everything. That over-approximation is the correct direction — a needless
/// rebuild is cheap, a stale artifact is not.
fn seed_package(
  graph : PackageGraph,
  path : String,
  affected : Set[String],
  queue : Array[String],
) -> Unit {
  let normalized = normalize_path(path)
  if file_name(normalized) == "moon.mod" {
    for node in graph.packages {
      if !affected.contains(node.dir) {
        affected.add(node.dir)
        queue.push(node.dir)
      }
    }
  } else {
    let dir = dir_of(normalized)
    if graph_has_dir(graph, dir) && !affected.contains(dir) {
      affected.add(dir)
      queue.push(dir)
    }
  }
}

///|
/// Compare two fingerprint tables and report what changed and what must be
/// rebuilt.
///
/// A file is `changed` when its hash or its size differs; `added` and `removed`
/// are set differences. All three lists are sorted, and so is `packages`.
///
/// `packages` is the transitive closure of "a file of mine changed" over the
/// dependency edges: the package the file belongs to, then every package that
/// depends on that one, then theirs, until nothing new appears. A file that
/// belongs to no package in the graph (a README, a script) invalidates nothing;
/// `moon.mod`, which also belongs to no package, invalidates everything.
pub fn invalidate(
  old : Array[FileFingerprint],
  new : Array[FileFingerprint],
  graph : PackageGraph,
) -> Invalidation {
  let before : Map[String, FileFingerprint] = Map([])
  for item in old {
    before.set(normalize_path(item.path), item)
  }
  let after : Map[String, FileFingerprint] = Map([])
  for item in new {
    after.set(normalize_path(item.path), item)
  }
  let changed : Array[String] = []
  let added : Array[String] = []
  let removed : Array[String] = []
  for item in new {
    let path = normalize_path(item.path)
    match before.get(path) {
      None => {
        added.push(path)
      }
      Some(previous) => {
        if previous.hash != item.hash || previous.size != item.size {
          changed.push(path)
        }
      }
    }
  }
  for item in old {
    let path = normalize_path(item.path)
    match after.get(path) {
      None => {
        removed.push(path)
      }
      Some(_) => ()
    }
  }
  sort_strings(changed)
  sort_strings(added)
  sort_strings(removed)
  let affected : Set[String] = Set([])
  let queue : Array[String] = []
  for path in changed {
    seed_package(graph, path, affected, queue)
  }
  for path in added {
    seed_package(graph, path, affected, queue)
  }
  for path in removed {
    seed_package(graph, path, affected, queue)
  }
  // Breadth-first closure over reverse edges. `queue` doubles as the visited
  // set: a directory is appended exactly when it is first marked affected.
  let mut cursor = 0
  while cursor < queue.length() {
    let dir = queue[cursor]
    for dependent in dependents(graph, dir) {
      if !affected.contains(dependent) {
        affected.add(dependent)
        queue.push(dependent)
      }
    }
    cursor = cursor + 1
  }
  let packages : Array[String] = []
  for dir in queue {
    packages.push(dir)
  }
  sort_strings(packages)
  Invalidation::{ changed, added, removed, packages }
}
