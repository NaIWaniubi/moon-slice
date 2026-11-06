// Reuse across package scans: a file's facts are kept and handed back as long
// as nothing about the file changed. The editor server re-runs the package scan
// on every open and save, and parsing every file each time is what made that
// expensive on large packages; this makes an unchanged file cost one stat.
//
// The rule is deliberately strict. A cache entry is only reused when the disk
// stamp (mtime plus size) matches *and*, for the file the editor has open, the
// buffer text matches what was analysed last time. A buffer can change without
// touching mtime, so the text is part of the key rather than an afterthought.

///|
/// A file's identity on disk: modification time in seconds and nanoseconds,
/// plus its size. Equal stamps mean the file was not rewritten in between.
pub(all) struct Stamp {
  seconds : Int64
  nanos : Int
  size : Int64
}

///|
/// Compared field by field rather than through `derive(Eq)`: the equality this
/// cache needs is exactly "same seconds, same nanoseconds, same size", and
/// spelling it out keeps that visible.
fn same_stamp(a : Stamp, b : Stamp) -> Bool {
  a.seconds == b.seconds && a.nanos == b.nanos && a.size == b.size
}

///|
pub fn Stamp::new(seconds : Int64, nanos : Int, size : Int64) -> Stamp {
  { seconds, nanos, size }
}

///|
/// What one file contributed, plus the conditions it was produced under.
struct Entry {
  stamp : Stamp
  buffer : String?
  facts : @liveness.FileFacts
}

///|
/// One directory's cache, held for the duration of one scan. `reuse` carries a
/// surviving entry into the next generation; `Cache::commit` swaps that
/// generation in, so files that disappeared are dropped rather than kept.
pub struct Scan {
  directory : String
  previous : Map[String, Entry]
  current : Map[String, Entry]
}

///|
/// The cache itself: one generation of entries per directory that has been
/// scanned. Directories are independent, so a file with the same name in two
/// packages can never share facts.
pub struct Cache {
  directories : Map[String, Map[String, Entry]]
}

///|
pub fn Cache::new() -> Cache {
  { directories: Map([]) }
}

///|
pub fn Cache::begin(self : Cache, directory : String) -> Scan {
  let previous = match self.directories.get(directory) {
    Some(entries) => entries
    None => Map([])
  }
  { directory, previous, current: Map([]) }
}

///|
/// The facts for `path` when the file is exactly as the previous scan left it:
/// same stamp, and the same buffer text when the editor has it open. A hit is
/// carried into the next generation, so a package that never changes stays warm.
pub fn Scan::reuse(
  self : Scan,
  path : String,
  stamp : Stamp,
  buffer : String?,
) -> @liveness.FileFacts? {
  let entry = match self.previous.get(path) {
    Some(entry) => entry
    None => return None
  }
  if !same_stamp(entry.stamp, stamp) || entry.buffer != buffer {
    return None
  }
  self.current.set(path, entry)
  Some(entry.facts)
}

///|
/// Store the facts just computed for `path`, so the next scan can reuse them.
pub fn Scan::record(
  self : Scan,
  path : String,
  stamp : Stamp,
  buffer : String?,
  facts : @liveness.FileFacts,
) -> Unit {
  self.current.set(path, { stamp, buffer, facts })
}

///|
pub fn Cache::commit(self : Cache, scan : Scan) -> Unit {
  self.directories.set(scan.directory, scan.current)
}
