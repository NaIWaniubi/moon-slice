///|
/// In-source suppression directives.
///
/// A finding that a reviewer has already judged can be silenced where it is
/// reported, instead of in a baseline file that goes stale as lines move:
///
/// ```moonbit
/// let unused = compute() // moon-slice: ignore dead-store
/// // moon-slice: ignore[unused-function]
/// fn helper() -> Unit { ... }
/// ```
///
/// A directive on a line with code applies to that line. A directive alone on
/// its line applies to the next line that is neither blank nor a comment. The
/// directive has to be the last thing on the line, and the only rule names it
/// understands are `dead-store`, `unreachable-code` and `unused-function`; any
/// other spelling leaves the directive inert rather than silencing a whole line
/// by accident.
const MARKER : String = "moon-slice:"

///|
let known_rules : Array[String] = [
  "dead-store",
  "unreachable-code",
  "unused-function",
]

///|
/// One directive, already resolved to the line it covers (`1`-based, the same
/// numbering findings use).
pub(all) struct Directive {
  line : Int
  /// Empty means every rule.
  rules : Array[String]
}

///|
/// The directives found in one file.
pub(all) struct Directives {
  items : Array[Directive]
}

///|
/// A file with no directives. Useful as the fallback for files that were not
/// scanned, so callers never special-case `Option`.
pub fn empty() -> Directives {
  Directives::{ items: [] }
}

///|
fn next_code_line(lines : Array[String], from : Int) -> Int {
  let mut i = from + 1
  while i < lines.length() {
    let text = lines[i].trim()
    if !text.is_empty() && !text.has_prefix("//") {
      return i
    }
    i = i + 1
  }
  -1
}

///|
fn is_standalone(line : String) -> Bool {
  match line.split_once(MARKER) {
    None => false
    Some((before, _)) => before.trim().to_owned() == "//"
  }
}

///|
/// Parses the directive carried by one line, or `None` when the line has none.
fn rules_on(line : String) -> Array[String]? {
  match line.split_once(MARKER) {
    None => None
    Some((before, after)) => {
      if !before.trim_end().has_suffix("//") {
        return None
      }
      let rest = after.trim()
      let tail = match rest.strip_prefix("ignore") {
        None => return None
        Some(tail) => tail.trim()
      }
      if tail.is_empty() {
        return Some([])
      }
      let body = match tail.strip_prefix("[") {
        Some(inner) =>
          match inner.strip_suffix("]") {
            Some(inner) => inner
            None => return None
          }
        None => tail
      }
      let names = StringBuilder()
      names.write_string(body.to_owned().replace_all(old=",", new=" "))
      let parsed : Array[String] = []
      let mut ok = true
      for token in names.to_string().split(" ") {
        let name = token.trim().to_owned()
        if name.is_empty() {
          continue
        }
        if !known_rules.contains(name) {
          ok = false
        } else if !parsed.contains(name) {
          parsed.push(name)
        }
      }
      if !ok || parsed.is_empty() {
        return None
      }
      Some(parsed)
    }
  }
}

///|
/// Reads every directive in `source`. Lines are split on `\n`; a trailing `\r`
/// from a CRLF file is ignored because comparisons go through `trim_space`.
pub fn parse(source : String) -> Directives {
  let lines : Array[String] = source.split("\n").map(l => l.to_owned()).to_array()
  let items : Array[Directive] = []
  for i = 0; i < lines.length(); i = i + 1 {
    match rules_on(lines[i]) {
      None => ()
      Some(rules) => {
        let target = if is_standalone(lines[i]) {
          next_code_line(lines, i)
        } else {
          i
        }
        if target >= 0 {
          items.push(Directive::{ line: target + 1, rules: rules })
        }
      }
    }
  }
  Directives::{ items: items }
}

///|
/// Whether a finding at `line` under `rule` is silenced.
pub fn suppresses(directives : Directives, line : Int, rule : String) -> Bool {
  for item in directives.items {
    if item.line == line {
      if item.rules.is_empty() {
        return true
      }
      if item.rules.contains(rule) {
        return true
      }
    }
  }
  false
}

///|
/// How many directives a file carries, for diagnostics.
pub fn count(directives : Directives) -> Int {
  directives.items.length()
}
