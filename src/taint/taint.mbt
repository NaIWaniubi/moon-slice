// Taint analysis over the lowered `@core.Program` and its `@core.Pdg`.
//
// The rules are deliberately small and explainable:
//
//   * a **source** is a call whose syntactic name matches one of
//     `TaintConfig.sources`;
//   * a **sink** is a call matching `TaintConfig.sinks`;
//   * a **sanitizer** is a call matching `TaintConfig.sanitizers`; a tainted
//     value that reaches one is dropped there, and nothing beyond it is
//     reported.
//
// Taint flows along PDG **data** edges only. Control edges say "this statement
// runs because of that condition", which is not a value flow and would make
// every call inside an `if` look tainted by the condition.
//
// Names are matched case-sensitively either by the bare call name (`read`) or
// by a package-qualified rule (`env/read`), where the part after the last `/`
// is the call name the adapter recorded. The adapter records callees as bare
// identifiers, so `env/read` is how a rule says "the `read` belonging to the
// env package" while still hitting that recorded name.

///|
/// Which calls introduce, consume, and clear taint.
///
/// The lists are rules, not node ids: `analyze` resolves each rule against
/// `Program.calls`. An empty list disables that role, so
/// `TaintConfig::default()` is the only config with opinions.
pub(all) struct TaintConfig {
  sources : Array[String]
  sinks : Array[String]
  sanitizers : Array[String]
} derive(Debug, Eq)

///|
/// One source-to-sink flow.
///
/// `path` is the shortest chain of node ids from the matched source call to the
/// matched sink call, endpoints included, following data edges only. Every id
/// belongs to the program `analyze` was given.
///
/// `sanitized` is `false` for every finding `analyze` emits: a flow that met a
/// sanitizer is cut and is not reported at all. The field exists so that a
/// consumer can carry a downgraded finding through the same renderer, and so
/// `report_text` can mark one when it does.
pub(all) struct TaintFinding {
  source_name : String
  source_line : Int32
  sink_name : String
  sink_line : Int32
  path : Array[Int32]
  sanitized : Bool
} derive(Debug, Eq)

///|
/// The result of one `analyze` run.
///
/// `sources_seen` and `sinks_seen` count the distinct call nodes the config
/// matched, so a rule that names nothing in the program shows up as `0` instead
/// of silently producing an empty report. `truncated` counts the sanitizer
/// calls a tainted value actually reached, i.e. how many flows were cut.
pub(all) struct TaintReport {
  findings : Array[TaintFinding]
  sources_seen : Int32
  sinks_seen : Int32
  truncated : Int32
} derive(Debug, Eq)

///|
/// A starting rule set for MoonBit code: environment and file input as sources,
/// process and file sinks, and the escaping routines that usually clear a
/// value.
///
/// Qualified rules match the bare call name after the last `/`, so `env/read`
/// fires on a call written `read(...)`. Several rules can name the same call
/// name here (`env/read`, `fs/read`); `analyze` reports each node once, under
/// the first rule in the list.
pub fn default_config() -> TaintConfig {
  {
    sources: [
      "env/read",
      "env/args",
      "fs/read",
      "io/read",
      "process/args",
      "stdin/read",
    ],
    sinks: [
      "process/exec",
      "process/run",
      "process/spawn",
      "fs/write",
      "io/print",
      "io/println",
      "log/print",
    ],
    sanitizers: ["html/escape", "url/encode", "int/parse", "json/parse"],
  }
}

///|
/// Reads the string array under `key`, ignoring anything that is not a string.
fn strings_of(value : Json?) -> Array[String] {
  match value {
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        if item is String(text) {
          out.push(text)
        }
      }
      out
    }
    _ => []
  }
}

///|
/// Parses a `TaintConfig` from JSON text.
///
/// The shape is `{"sources":[...],"sinks":[...],"sanitizers":[...]}`; every
/// field is optional, and a missing or non-array field means "no rules for that
/// role". Non-string array entries are skipped rather than rejected. Malformed
/// JSON yields an all-empty config: the function has no error channel and a
/// half-parsed rule set would be worse than none.
pub fn parse_config(json_text : String) -> TaintConfig {
  let parsed = @json.parse(json_text) catch {
    _ => return { sources: [], sinks: [], sanitizers: [], }
  }
  match parsed {
    Object(fields) =>
      {
        sources: strings_of(fields.get("sources")),
        sinks: strings_of(fields.get("sinks")),
        sanitizers: strings_of(fields.get("sanitizers")),
      }
    _ => { sources: [], sinks: [], sanitizers: [], }
  }
}
