// Typed receiver-call resolution: every `recv.method()` in a file gets a
// verdict, not just the calls whose receiver type the source writes down.
//
// `parser_adapter.call_facts` answers "which calls can be typed from something
// the author already wrote?" and silently drops the rest — the right thing for
// a call graph, where an invented edge is worse than a missing one. A report
// needs the rest as well: a call that lost its type is information. This pass
// keeps the three outcomes apart and attaches a reason to every failure:
//
//   resolved    — the receiver's type is known and exactly one method of that
//                 name belongs to it;
//   ambiguous   — more than one declaration could be the target; the candidates
//                 are listed so the reader knows what needs disambiguating;
//   unresolved  — no owner can be named; `reason` says which question failed.
//
// The promises of `parser_adapter` still hold: nothing is guessed here either.
// An unknown receiver type never becomes an edge, and a name bound with two
// different types stays unresolved.

///|
/// How one dot call came out.
pub(all) enum CallStatus {
  Resolved
  Ambiguous
  Unresolved
}

///|
/// The wire name of a status: `resolved`, `ambiguous` or `unresolved`.
pub fn status_name(status : CallStatus) -> String {
  match status {
    Resolved => "resolved"
    Ambiguous => "ambiguous"
    Unresolved => "unresolved"
  }
}

///|
/// Why a call has no owner. `NoReason` is what a resolved or an ambiguous call
/// carries: those are answers, not failures.
pub(all) enum ResolveReason {
  NoReason
  // The receiver is a plain name or a field chain, but the source never states
  // its type (`let p = make()` where `make` is not declared in this package).
  UnknownReceiverType
  // The receiver's type is known and declared in this package, and it does not
  // declare a method with this name.
  MethodNotDeclared
  // The receiver's type is not declared in this package: its methods live in
  // another package (`Array`, `String`, an annotated `@pkg.Type`).
  ExternalPackage
  // The receiver is the result of a call or another computed expression, so no
  // written type reaches it.
  DynamicValue
}

///|
/// The wire name of a reason: the empty string for `NoReason`, otherwise the
/// category used in `CoverageReport.by_reason`.
pub fn reason_name(reason : ResolveReason) -> String {
  match reason {
    NoReason => ""
    UnknownReceiverType => "unknown_receiver_type"
    MethodNotDeclared => "method_not_declared"
    ExternalPackage => "external_package"
    DynamicValue => "dynamic_value"
  }
}

///|
/// One declaration a call could target. Two types declaring `norm`, or one type
/// declaring it twice through two impls, are two candidates.
pub(all) struct Candidate {
  owner : String
  /// The called name. Spelled `method_name` because `method` is reserved.
  method_name : String
  /// Line of the declaration, so two same-named methods on one owner stay
  /// distinguishable.
  line : Int32
}

///|
/// `Candidate` rendered for a report: `Owner::method@line`.
pub fn candidate_text(candidate : Candidate) -> String {
  candidate.owner +
  "::" +
  candidate.method_name +
  "@" +
  candidate.line.to_string()
}

///|
/// One dot call in one file, with the outcome and the evidence behind it.
pub(all) struct ResolvedCall {
  /// Line of the method name.
  line : Int32
  /// The receiver as source text, best effort: `p`, `p.inner`, `make(...)`.
  receiver_expr : String
  /// The receiver type when the source states one, otherwise `""`.
  receiver_type : String
  /// The method called. Spelled `method_name` because `method` is reserved.
  method_name : String
  /// The one type that owns the method, for a resolved call; `""` otherwise.
  owner : String
  status : CallStatus
  reason : ResolveReason
  /// Populated for `Ambiguous`; empty for the other two statuses.
  candidates : Array[Candidate]
}

///|
/// The per-file accounting of dot calls. `resolved + ambiguous + unresolved`
/// is always `total`, and `by_reason` covers exactly the unresolved ones.
pub(all) struct CoverageReport {
  total : Int
  resolved : Int
  ambiguous : Int
  unresolved : Int
  /// Unresolved calls per `reason_name`. Every category is present with a zero
  /// when it did not occur, so a report does not need to special-case absence.
  by_reason : Map[String, Int]
}

///|
/// One file's resolution result.
pub(all) struct FileResolution {
  file : String
  calls : Array[ResolvedCall]
  coverage : CoverageReport
}

///|
/// A file as the package-level entry point takes it.
pub(all) struct SourceFile {
  name : String
  source : String
}

///|
/// Build the input of `resolve_package` without naming the struct literal.
pub fn source_file(name : String, source : String) -> SourceFile {
  SourceFile::{ name: name, source: source }
}

///|
/// A fresh report: all counters zero, every reason category present.
pub fn empty_report() -> CoverageReport {
  let by_reason : Map[String, Int] = Map([])
  by_reason.set("unknown_receiver_type", 0)
  by_reason.set("method_not_declared", 0)
  by_reason.set("external_package", 0)
  by_reason.set("dynamic_value", 0)
  CoverageReport::{
    total: 0,
    resolved: 0,
    ambiguous: 0,
    unresolved: 0,
    by_reason: by_reason,
  }
}

///|
/// How many calls fell into one reason category. An absent key reads as zero.
pub fn reason_count(report : CoverageReport, reason : ResolveReason) -> Int {
  let key = reason_name(reason)
  match report.by_reason.get(key) {
    Some(count) => count
    None => 0
  }
}

///|
/// Count the calls by outcome. This is the single place the invariant
/// `resolved + ambiguous + unresolved == total` is established.
pub fn coverage_of(calls : Array[ResolvedCall]) -> CoverageReport {
  let mut resolved = 0
  let mut ambiguous = 0
  let mut unresolved = 0
  let by_reason : Map[String, Int] = Map([])
  by_reason.set("unknown_receiver_type", 0)
  by_reason.set("method_not_declared", 0)
  by_reason.set("external_package", 0)
  by_reason.set("dynamic_value", 0)
  let mut i = 0
  while i < calls.length() {
    let call = calls[i]
    match call.status {
      Resolved => resolved = resolved + 1
      Ambiguous => ambiguous = ambiguous + 1
      Unresolved => {
        unresolved = unresolved + 1
        let key = reason_name(call.reason)
        let previous = match by_reason.get(key) {
          Some(count) => count
          None => 0
        }
        by_reason.set(key, previous + 1)
      }
    }
    i = i + 1
  }
  CoverageReport::{
    total: calls.length(),
    resolved: resolved,
    ambiguous: ambiguous,
    unresolved: unresolved,
    by_reason: by_reason,
  }
}
