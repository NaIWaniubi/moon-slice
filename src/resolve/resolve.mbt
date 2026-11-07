// Resolution: pair every scanned dot call with the type the adapter could state
// for its receiver, then ask the declaration tables who owns the method.
//
// The classification is deliberately mechanical, so a reader can predict it:
//
//   receiver type known —
//     exactly one `Owner::method`  -> resolved
//     more than one                -> ambiguous, candidates listed
//     none, owner is a local type  -> unresolved / method_not_declared
//     none, owner is not local     -> unresolved / external_package
//
//   receiver type unknown —
//     the name is declared on >= 2 types -> ambiguous, candidates listed
//     otherwise                          -> unresolved / unknown_receiver_type
//                                           for a name-shaped receiver,
//                                           dynamic_value for a computed one
//
// The `>= 2 types` rule is what turns the classic "`norm` exists on Point and
// on Circle, and this receiver could be either" into an explicit ambiguity
// instead of an anonymous failure. With one owner there is nothing to list, and
// the honest answer is that the receiver's type is what is missing.

///|
/// One method declaration, in package order.
priv struct MethodEntry {
  owner : String
  method_name : String
  line : Int32
}

///|
/// What a package knows about methods and types. Built once per package so every
/// file resolves against the same answer.
priv struct MethodIndex {
  entries : Array[MethodEntry]
  /// Types declared by a `struct`/`enum`/`impl` in this package. A known
  /// receiver type that is not here belongs to another package.
  types : Set[String]
  /// `Owner::method` keys from a merged declaration table. A method declared by
  /// a file outside the one being resolved is still a real declaration, even
  /// though its line number is not available here.
  declared : Set[String]
}

///|
fn build_index(
  facts_list : Array[@parser_adapter.CallFacts],
  type_names : Array[String],
  table : @parser_adapter.DeclTable,
) -> MethodIndex {
  let index : MethodIndex = { entries: [], types: Set([]), declared: Set([]) }
  let mut i = 0
  while i < type_names.length() {
    index.types.add(type_names[i])
    i = i + 1
  }
  table.method_returns.to_array().each(fn(pair) {
    index.declared.add(pair.0)
  })
  i = 0
  while i < facts_list.length() {
    let facts = facts_list[i]
    let mut j = 0
    while j < facts.methods.length() {
      let decl = facts.methods[j]
      index.entries.push(MethodEntry::{
        owner: decl.owner,
        method_name: decl.name,
        line: decl.line,
      })
      // A method's owner is a type of this package even when the file declares
      // it through `impl` without a separate `struct`.
      index.types.add(decl.owner)
      j = j + 1
    }
    i = i + 1
  }
  index
}

///|
/// Every declaration of `name`, optionally restricted to one owner. Kept in
/// package order so a report and its test agree on candidate order.
fn candidates_for(
  index : MethodIndex,
  owner : String?,
  name : String,
) -> Array[Candidate] {
  let found : Array[Candidate] = []
  let mut i = 0
  while i < index.entries.length() {
    let entry = index.entries[i]
    let owner_matches = match owner {
      Some(name) => entry.owner == name
      None => true
    }
    if owner_matches && entry.method_name == name {
      found.push(Candidate::{
        owner: entry.owner,
        method_name: entry.method_name,
        line: entry.line,
      })
    }
    i = i + 1
  }
  found
}

///|
/// The distinct types declaring a method name, in package order.
fn distinct_owners(index : MethodIndex, name : String) -> Array[String] {
  let owners : Array[String] = []
  let mut i = 0
  while i < index.entries.length() {
    let entry = index.entries[i]
    if entry.method_name == name && !owners.contains(entry.owner) {
      owners.push(entry.owner)
    }
    i = i + 1
  }
  owners
}

///|
fn site_call(
  site : DotSite,
  receiver_type : String,
  owner : String,
  status : CallStatus,
  reason : ResolveReason,
  candidates : Array[Candidate],
) -> ResolvedCall {
  ResolvedCall::{
    line: site.line,
    receiver_expr: site.receiver_expr,
    receiver_type: receiver_type,
    method_name: site.method_name,
    owner: owner,
    status: status,
    reason: reason,
    candidates: candidates,
  }
}

///|
/// Decide one call. `receiver_type` is `Some` exactly when `call_facts` typed the
/// receiver, which is the one thing this pass does not re-derive.
fn resolve_site(
  index : MethodIndex,
  site : DotSite,
  receiver_type : String?,
) -> ResolvedCall {
  match receiver_type {
    Some(owner) => {
      let candidates = candidates_for(index, Some(owner), site.method_name)
      if candidates.length() == 1 {
        site_call(site, owner, owner, Resolved, NoReason, [])
      } else if candidates.length() > 1 {
        site_call(site, owner, "", Ambiguous, NoReason, candidates)
      } else if index.declared.contains(owner + "::" + site.method_name) {
        // Declared by a file whose method list this package did not scan: the
        // merged table still names the owner, so the call is resolved.
        site_call(site, owner, owner, Resolved, NoReason, [])
      } else if index.types.contains(owner) {
        site_call(site, owner, "", Unresolved, MethodNotDeclared, [])
      } else {
        site_call(site, owner, "", Unresolved, ExternalPackage, [])
      }
    }
    None => {
      let owners = distinct_owners(index, site.method_name)
      if owners.length() >= 2 {
        let candidates = candidates_for(index, None, site.method_name)
        site_call(site, "", "", Ambiguous, NoReason, candidates)
      } else {
        let reason = match site.receiver_shape {
          Static => UnknownReceiverType
          Dynamic => DynamicValue
        }
        site_call(site, "", "", Unresolved, reason, [])
      }
    }
  }
}

///|
/// Resolve every site of one file against the package index. A site inherits a
/// receiver type only from an adapter fact with the same caller, line and
/// method; facts are consumed in order so two identical calls on one line stay
/// one-to-one.
fn resolve_calls_in(
  sites : Array[DotSite],
  facts : @parser_adapter.CallFacts,
  index : MethodIndex,
) -> Array[ResolvedCall] {
  let used : Array[Bool] = []
  let mut i = 0
  while i < facts.receivers.length() {
    used.push(false)
    i = i + 1
  }
  let calls : Array[ResolvedCall] = []
  i = 0
  while i < sites.length() {
    let site = sites[i]
    let mut matched = -1
    let mut j = 0
    while j < facts.receivers.length() {
      if !used[j] {
        let fact = facts.receivers[j]
        if fact.line == site.line &&
          fact.method_name == site.method_name &&
          fact.caller == site.caller {
          used[j] = true
          matched = j
          break
        }
      }
      j = j + 1
    }
    let receiver_type : String? = if matched >= 0 {
      Some(facts.receivers[matched].receiver_type)
    } else {
      None
    }
    calls.push(resolve_site(index, site, receiver_type))
    i = i + 1
  }
  calls
}

///|
fn push_all(into : Array[String], from : Array[String]) -> Unit {
  let mut i = 0
  while i < from.length() {
    into.push(from[i])
    i = i + 1
  }
}

///|
fn resolve_with(
  sources : Array[SourceFile],
  table : @parser_adapter.DeclTable,
) -> Array[FileResolution] {
  let facts_list : Array[@parser_adapter.CallFacts] = []
  let site_lists : Array[Array[DotSite]] = []
  let type_names : Array[String] = []
  let mut i = 0
  while i < sources.length() {
    let file = sources[i]
    facts_list.push(@parser_adapter.call_facts(
      file.source,
      file.name,
      extra=table,
    ))
    let (sites, names) = scan_file(file.source, file.name)
    site_lists.push(sites)
    push_all(type_names, names)
    i = i + 1
  }
  let index = build_index(facts_list, type_names, table)
  let results : Array[FileResolution] = []
  i = 0
  while i < sources.length() {
    let calls = resolve_calls_in(site_lists[i], facts_list[i], index)
    results.push(FileResolution::{
      file: sources[i].name,
      calls: calls,
      coverage: coverage_of(calls),
    })
    i = i + 1
  }
  results
}

///|
/// The declarations of one file, in the form `resolve_package` and the `extra?`
/// argument take. A caller that resolves a package a file at a time merges these
/// with `merge_tables` first.
pub fn declarations(source : String, name : String) -> @parser_adapter.DeclTable {
  @parser_adapter.declared_types(source, name)
}

///|
/// An empty declaration table, for a caller that merges into it file by file.
pub fn empty_table() -> @parser_adapter.DeclTable {
  @parser_adapter.empty_decls()
}

///|
/// Merge `from` into `into` with the adapter's rule: a later file wins on a name
/// clash, which is the package's own scan order.
pub fn merge_tables(
  into : @parser_adapter.DeclTable,
  from : @parser_adapter.DeclTable,
) -> Unit {
  @parser_adapter.merge_decls(into, from)
}

///|
/// Resolve one file. `extra` is the merged declaration table of the files that
/// were resolved before this one; the file's own declarations are added on top,
/// so a self-contained call needs no `extra` at all.
pub fn resolve_source(
  source : String,
  name : String,
  extra? : @parser_adapter.DeclTable = @parser_adapter.empty_decls(),
) -> FileResolution {
  let table = @parser_adapter.empty_decls()
  @parser_adapter.merge_decls(table, extra)
  @parser_adapter.merge_decls(table, @parser_adapter.declared_types(source, name))
  let sources : Array[SourceFile] = [SourceFile::{ name: name, source: source }]
  resolve_with(sources, table)[0]
}

///|
/// Resolve a whole package: merge every file's declarations first, then resolve
/// each file's bodies against the merged table and one shared method index. The
/// result is in input order, one entry per file.
pub fn resolve_package(sources : Array[SourceFile]) -> Array[FileResolution] {
  let table = @parser_adapter.empty_decls()
  let mut i = 0
  while i < sources.length() {
    let file = sources[i]
    @parser_adapter.merge_decls(table, @parser_adapter.declared_types(
      file.source,
      file.name,
    ))
    i = i + 1
  }
  resolve_with(sources, table)
}

///|
/// The whole-package coverage: the sum of the per-file reports, recomputed from
/// the calls themselves so the invariant holds once for the package.
pub fn merged_coverage(results : Array[FileResolution]) -> CoverageReport {
  let calls : Array[ResolvedCall] = []
  let mut i = 0
  while i < results.length() {
    let file_calls = results[i].calls
    let mut j = 0
    while j < file_calls.length() {
      calls.push(file_calls[j])
      j = j + 1
    }
    i = i + 1
  }
  coverage_of(calls)
}
