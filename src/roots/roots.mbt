// Reachability roots: a proof, not a verdict.
//
// `src/liveness` answers "does this name occur anywhere in the package?" — a
// lexical question with a lexical answer. That is safe, but it cannot show
// *why* a private function is dead: a name mentioned by another dead function
// looks used, and the finding stops at "nothing references it".
//
// This pass answers the same question on a graph. It builds the call/mention
// edges of one package, marks the functions the outside world can enter
// (public API, `main`/`init`, calls from `test` blocks and top-level
// expressions, trait impl methods, configured entry points), expands them with
// a breadth-first search over the edges, and keeps the witness of every visit
// so the result can be explained:
//
//   * `analyze`            — roots, reachable set, unreachable private
//                            functions, every edge, and the unresolved
//                            boundary of the package;
//   * `explain_live`       — the shortest call chain from a root to a function,
//                            each step carrying `file:line`;
//   * `explain_dead`       — the root set, the search scope, the incoming-edge
//                            evidence, and the call sites the analysis could
//                            not attribute.
//
// The interesting consequence is that reachability is transitive. A private
// function called only from another unreachable function is unreachable, and
// `explain_dead` names the caller that failed it. `liveness` cannot see that:
// it treats every mention as a use. The two agree whenever the references live
// in reachable code, which the package-level consistency tests check.
//
// Imprecision is recorded, never silently dropped: every call the graph could
// not attribute (a receiver whose type is unknown, a call into another
// package, a call through an expression) is listed in `boundaries`, so a dead
// claim can be read as "dead, as far as these unresolved sites".

///|
/// Why a name is a root: the places execution can enter the package.
pub(all) enum RootKind {
  /// A `pub` declaration is the package's API; another package may call it.
  PublicApi
  /// `main` and `init` are called by the runtime.
  EntryPoint
  /// A function mentioned by a `test` block.
  TestCall
  /// A method of a trait implementation: dispatch names the trait, not the
  /// method, so nothing in the source has to mention it.
  TraitImpl
  /// An entry point supplied by the caller of this analysis.
  Explicit
  /// A function mentioned by a top-level expression, `let`, or `view`.
  TopLevel
} derive(Debug, Eq)

///|
/// One root, with both the declaration it marks and the site that made it a
/// root (`site` is `path:line` for every kind except `Explicit`, which is
/// `"configuration"` when the name is not declared in the package).
pub(all) struct Root {
  name : String
  path : String
  line : Int32
  kind : RootKind
  site : String
} derive(Debug, Eq)

///|
/// One directed adjacency in the package graph: `caller` mentions or calls
/// `callee` at `path:line`. Mentions, not only calls, are edges on purpose —
/// a function passed as a value is a real use, and this keeps the graph in
/// step with the lexical reference set `src/liveness` uses.
pub(all) struct CallEdge {
  caller : String
  callee : String
  path : String
  line : Int32
} derive(Debug, Eq)

///|
/// One candidate `src/liveness` would report and this graph cannot reach.
pub(all) struct UnreachableFn {
  path : String
  name : String
  line : Int32
} derive(Debug, Eq)

///|
/// One step of an explained chain. The first step is the root's declaration;
/// every later step is the site (`path:line`) where the previous function
/// mentions the one it names.
pub(all) struct PathStep {
  function_name : String
  path : String
  line : Int32
} derive(Debug, Eq)

///|
/// A shortest chain from some root to the named function.
pub(all) struct LivePath {
  steps : Array[PathStep]
} derive(Debug, Eq)

///|
/// The proof that a function is dead.
pub(all) struct DeadExplanation {
  function_name : String
  path : String
  line : Int32
  /// One line per root, `"<kind>: <name> at <path>:<line>"`.
  root_summary : Array[String]
  /// How many files and declarations the search looked at.
  searched_files : Int
  searched_functions : Int
  /// Why the function is unreachable: no incoming edge, or incoming edges
  /// that all start at unreachable functions.
  evidence : Array[String]
  /// Package-wide call sites the graph could not attribute.
  boundaries : Array[String]
} derive(Debug, Eq)

///|
/// The whole result of one package analysis.
pub(all) struct Reachability {
  roots : Array[Root]
  reachable : Set[String]
  unreachable_fns : Array[UnreachableFn]
  edges : Array[CallEdge]
  files : Int
  functions : Int
  boundaries : Array[String]
  /// Witness for `explain_live`: `parents[callee]` is the function the BFS
  /// reached it from.
  parents : Map[String, String]
  /// The edge that reached a function, as a `PathStep` carrying its site.
  via : Map[String, PathStep]
  /// Declaration site of every function, used for the first path step.
  sites : Map[String, PathStep]
}

///|
fn is_exported(vis : @syntax.Visibility) -> Bool {
  match vis {
    @syntax.Visibility::Default => false
    @syntax.Visibility::Pub(..) => true
    @syntax.Visibility::Priv(..) => false
  }
}

///|
fn kind_label(kind : RootKind) -> String {
  match kind {
    PublicApi => "public api"
    EntryPoint => "entry point"
    TestCall => "test call"
    TraitImpl => "trait impl"
    Explicit => "explicit entry"
    TopLevel => "top-level"
  }
}

///|
fn fmt_site(path : String, line : Int32) -> String {
  path + ":" + "\{line}"
}

///|
fn resolution_key(
  path : String,
  caller : String,
  line : Int32,
  callee_method : String,
) -> String {
  path + "|" + caller + "|" + "\{line}" + "|" + callee_method
}

///|
/// `#warnings("-unused_value")` is the author saying "this mention is expected
/// to be unused". `src/liveness` drops the declaration from its candidates;
/// here the body is still a real body, so its mentions are treated like
/// top-level ones (they keep their targets alive) instead of vanishing.
fn opted_out(decl : @syntax.FunDecl) -> Bool {
  let found = [false]
  decl.attrs.to_array().each(fn(attr) {
    if attr.raw.contains("unused_value") {
      found[0] = true
    }
  })
  found[0]
}

///|
/// A declaration the graph knows about. Only the candidate flag matters for
/// the answer; the rest is dropped at registration so the struct stays small.
priv struct DeclInfo {
  name : String
  path : String
  line : Int32
  /// `src/liveness` would report this declaration if its name were never
  /// referenced: private, has a body, not dispatchable, not `main`/`init`, and
  /// not marked with a leading underscore.
  candidate : Bool
}

///|
fn register_decl(
  decls : Array[DeclInfo],
  decl_names : Set[String],
  sites : Map[String, PathStep],
  info : DeclInfo,
) -> Unit {
  decls.push(info)
  decl_names.add(info.name)
  if !sites.contains(info.name) {
    sites.set(
      info.name,
      PathStep::{ function_name: info.name, path: info.path, line: info.line },
    )
  }
}

///|
fn add_root(
  roots : Array[Root],
  seen : Set[String],
  root : Root,
) -> Unit {
  let key = kind_label(root.kind) + "|" + root.name + "|" + root.site
  if !seen.contains(key) {
    seen.add(key)
    roots.push(root)
  }
}

///|
fn add_edge(
  edges : Array[CallEdge],
  seen : Set[String],
  edge : CallEdge,
) -> Unit {
  let key = edge.caller + "|" + edge.callee + "|" + edge.path + "|" +
    "\{edge.line}"
  if !seen.contains(key) {
    seen.add(key)
    edges.push(edge)
  }
}

///|
fn add_boundary(
  boundaries : Array[String],
  seen : Set[String],
  text : String,
) -> Unit {
  if !seen.contains(text) {
    seen.add(text)
    boundaries.push(text)
  }
}

///|
/// What one body contributes to the graph. Mentions are recorded for every
/// identifier in expression position (the same conservative rule as
/// `src/liveness`); calls are tracked separately so a call to a name with no
/// declaration can be reported as an unresolved boundary rather than invented
/// as an edge.
priv struct Walker {
  caller : String
  path : String
  mentions : Array[(String, Int32)]
  dots : Array[(String, Int32)]
  calls : Array[(String, Int32)]
  external_calls : Array[String]
}

///|
extend Walker with @syntax.IterVisitor::{base}

///|
impl @syntax.IterVisitor for Walker with fn visit_Expr_Ident(
  self,
  id~,
  loc~,
) {
  let line = loc.start.lnum
  match id.name {
    @syntax.LongIdent::Ident(name~) => self.mentions.push((name, line))
    // `@pkg.f` is a call into another package, but the last segment is also a
    // local name. Recording it mirrors `src/liveness`, which is conservative
    // in the safe direction: it can keep a function alive, never kill one.
    @syntax.LongIdent::Dot(id~, ..) => self.mentions.push((id, line))
  }
}

///|
impl @syntax.IterVisitor for Walker with fn visit_Expr_Apply(
  self,
  func~,
  args~,
  loc~,
) {
  let line = loc.start.lnum
  match func {
    @syntax.Expr::Ident(id~, ..) =>
      match id.name {
        @syntax.LongIdent::Ident(name~) => self.calls.push((name, line))
        @syntax.LongIdent::Dot(pkg~, id~) =>
          self.external_calls.push(
            fmt_site(self.path, line) + ": call to `@" + pkg + "." + id +
            "(..)` leaves the package",
          )
      }
    _ =>
      self.external_calls.push(
        fmt_site(self.path, line) + ": call through an expression",
      )
  }
  @syntax.IterVisitor::visit_Expr_Apply(self.base(), func~, args~, loc~)
}

///|
/// `T::m(x)` names the method explicitly, so it is a real edge even though the
/// base visitor only walks the type name.
impl @syntax.IterVisitor for Walker with fn visit_Expr_Method(
  self,
  type_name~,
  method_name~,
  loc~,
) {
  ignore(type_name)
  ignore(loc)
  self.mentions.push((method_name.name, method_name.loc.start.lnum))
}

///|
impl @syntax.IterVisitor for Walker with fn visit_Expr_DotApply(
  env,
  self~,
  method_name~,
  args~,
  return_self~,
  loc~,
) {
  env.dots.push((method_name.name, loc.start.lnum))
  @syntax.IterVisitor::visit_Expr_DotApply(
    env.base(),
    self~,
    method_name~,
    args~,
    return_self~,
    loc~,
  )
}

///|
fn is_word_start(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= 'A'.to_int() && code <= 'Z'.to_int()) || ch == '_'
}

///|
fn is_word_part(ch : Char) -> Bool {
  is_word_start(ch) || (ch.to_int() >= '0'.to_int() && ch.to_int() <= '9'.to_int())
}

///|
/// Interpolations carry their body as source text in this parser version, so
/// identifiers are scanned out of it. Conservative in the safe direction: it
/// can add a mention that is not real, never drop one.
fn collect_source_identifiers(text : String, out : Array[String]) -> Unit {
  let current = StringBuilder()
  let flush = fn() {
    if !current.is_empty() {
      out.push(current.to_string())
      ignore(current.reset())
    }
  }
  for ch in text.iter() {
    if is_word_start(ch) && current.is_empty() {
      current.write_char(ch)
    } else if is_word_part(ch) && !current.is_empty() {
      current.write_char(ch)
    } else {
      flush()
    }
  }
  flush()
}

///|
impl @syntax.IterVisitor for Walker with fn visit_Expr_Interp(
  self,
  elems~,
  loc~,
) {
  ignore(loc)
  elems.each(fn(elem) {
    match elem {
      @syntax.InterpElem::Literal(..) => ()
      @syntax.InterpElem::Expr(expr~, ..) =>
        @syntax.IterVisitor::visit_Expr(self, expr)
      @syntax.InterpElem::Source(source) => {
        let names : Array[String] = []
        collect_source_identifiers(source.source, names)
        names.each(fn(name) { self.mentions.push((name, 0)) })
      }
    }
  })
}

///|
fn walk(path : String, caller : String, expr : @syntax.Expr) -> Walker {
  let walker : Walker = {
    caller,
    path,
    mentions: [],
    dots: [],
    calls: [],
    external_calls: [],
  }
  @syntax.IterVisitor::visit_Expr(walker, expr)
  walker
}

///|
fn compare_pos(a_path : String, a_line : Int32, b_path : String, b_line : Int32) -> Int {
  let by_path = a_path.lexical_compare(b_path)
  if by_path < 0 {
    -1
  } else if by_path > 0 {
    1
  } else if a_line < b_line {
    -1
  } else if a_line > b_line {
    1
  } else {
    0
  }
}

///|
/// Consume one walked body. With `external` set, the mentions are entry sites
/// (roots); otherwise they are edges from the enclosing function.
fn consume_walk(
  walker : Walker,
  external : RootKind?,
  method_names : Set[String],
  resolved : Set[String],
  decl_names : Set[String],
  roots : Array[Root],
  root_seen : Set[String],
  edges : Array[CallEdge],
  edge_seen : Set[String],
  boundaries : Array[String],
  boundary_seen : Set[String],
) -> Unit {
  for pair in walker.mentions {
    let name = pair.0
    let line = pair.1
    if decl_names.contains(name) {
      match external {
        Some(kind) =>
          add_root(
            roots,
            root_seen,
            Root::{
              name,
              path: walker.path,
              line,
              kind,
              site: fmt_site(walker.path, line),
            },
          )
        None =>
          add_edge(
            edges,
            edge_seen,
            CallEdge::{
              caller: walker.caller,
              callee: name,
              path: walker.path,
              line,
            },
          )
      }
    }
  }
  for pair in walker.dots {
    let callee_method = pair.0
    let line = pair.1
    let attributed = match external {
      // A test or top-level block has no receiver type to resolve; a method
      // name declared anywhere in the package is close enough to be safe.
      Some(_) => method_names.contains(callee_method)
      None =>
        resolved.contains(
          resolution_key(walker.path, walker.caller, line, callee_method),
        )
    }
    if attributed && decl_names.contains(callee_method) {
      match external {
        Some(kind) =>
          add_root(
            roots,
            root_seen,
            Root::{
              name: callee_method,
              path: walker.path,
              line,
              kind,
              site: fmt_site(walker.path, line),
            },
          )
        None =>
          add_edge(
            edges,
            edge_seen,
            CallEdge::{
              caller: walker.caller,
              callee: callee_method,
              path: walker.path,
              line,
            },
          )
      }
    } else {
      add_boundary(
        boundaries,
        boundary_seen,
        fmt_site(walker.path, line) + ": unresolved method call `" + callee_method +
        "()`",
      )
    }
  }
  for pair in walker.calls {
    if !decl_names.contains(pair.0) {
      add_boundary(
        boundaries,
        boundary_seen,
        fmt_site(walker.path, pair.1) + ": call to `" + pair.0 +
        "` has no top-level declaration in the package",
      )
    }
  }
  for text in walker.external_calls {
    add_boundary(boundaries, boundary_seen, text)
  }
}

///|
fn candidate(
  name : String,
  exported : Bool,
  has_body : Bool,
  dispatchable : Bool,
) -> Bool {
  !exported && has_body && !dispatchable && name != "main" && name != "init" &&
  !name.has_prefix("_")
}

///|
/// Analyze one package. `facts` must be every `.mbt` file of the package,
/// tests included — the same input `src/liveness` takes, so the two answers
/// can be compared directly. If any file failed to parse the package is
/// skipped, exactly as `unused_functions` does: an answer that depends on a
/// file nobody read would be worse than no answer.
///
/// `entries` are extra roots (a configured `main`, a framework callback) that
/// no declaration marks on its own.
pub fn analyze(
  facts : Array[@liveness.FileFacts],
  entries? : Array[String] = [],
) -> Reachability {
  let files = facts.length()
  let boundaries : Array[String] = []
  let boundary_seen : Set[String] = Set([])
  let mut unreadable = 0
  for file in facts {
    if file.parse_errors > 0 {
      unreadable = unreadable + 1
    }
  }
  if unreadable > 0 {
    return Reachability::{
      roots: [],
      reachable: Set([]),
      unreachable_fns: [],
      edges: [],
      files,
      functions: 0,
      boundaries: [
        "package skipped: " + "\{unreadable}" + " file(s) failed to parse",
      ],
      parents: Map([]),
      via: Map([]),
      sites: Map([]),
    }
  }
  // Receiver calls need the resolution work `src/parser_adapter` already does
  // (annotated lets, parameter types, record literals). Its method table is
  // also the package-wide set of method names a test block can reach.
  let call_facts : Array[@parser_adapter.CallFacts] = facts.map(fn(file) {
    @parser_adapter.call_facts(file.source, file.path)
  })
  let method_names : Set[String] = Set([])
  let resolved : Set[String] = Set([])
  let mut ci = 0
  while ci < call_facts.length() {
    for method_decl in call_facts[ci].methods {
      method_names.add(method_decl.name)
    }
    for call in call_facts[ci].receivers {
      resolved.add(
        resolution_key(facts[ci].path, call.caller, call.line, call.method_name),
      )
    }
    ci = ci + 1
  }
  // One parse per file, reused by both phases: declarations first, so every
  // name is known before a mention is classified as an edge or a boundary.
  let parsed : Array[@syntax.Impls] = []
  for file in facts {
    let (items, _) = @parser.parse_string(file.source, name=file.path)
    parsed.push(items)
  }
  let decls : Array[DeclInfo] = []
  let decl_names : Set[String] = Set([])
  let sites : Map[String, PathStep] = Map([])
  let roots : Array[Root] = []
  let root_seen : Set[String] = Set([])
  let mut fi = 0
  while fi < parsed.length() {
    let file = facts[fi]
    parsed[fi].each(fn(item) {
      match item {
        @syntax.Impl::TopFuncDef(fun_decl=decl, decl_body=body, ..) => {
          if !opted_out(decl) {
            let name = decl.name.name
            let line = decl.name.loc.start.lnum
            let exported = is_exported(decl.vis)
            let has_body = match body {
              @syntax.DeclBody::DeclBody(_) => true
              _ => false
            }
            let entry = name == "main" || name == "init"
            register_decl(
              decls,
              decl_names,
              sites,
              DeclInfo::{
                name,
                path: file.path,
                line,
                candidate: candidate(name, exported, has_body, false),
              },
            )
            if exported {
              add_root(
                roots,
                root_seen,
                Root::{
                  name,
                  path: file.path,
                  line,
                  kind: PublicApi,
                  site: fmt_site(file.path, line),
                },
              )
            }
            if entry {
              add_root(
                roots,
                root_seen,
                Root::{
                  name,
                  path: file.path,
                  line,
                  kind: EntryPoint,
                  site: fmt_site(file.path, line),
                },
              )
            }
          }
        }
        // self_ty is the type after `for`: `impl Show for T` sets it and is
        // reached by trait dispatch; `impl T with fn m` leaves it empty and is
        // an inherent method, a plain candidate. This is the same rule
        // `src/liveness` uses.
        @syntax.Impl::TopImpl(self_ty~, method_name~, vis~, body~, ..) =>
          match body {
            @syntax.DeclBody::DeclBody(_) => {
              let name = method_name.name
              let line = method_name.loc.start.lnum
              let exported = is_exported(vis)
              let dispatchable = match self_ty {
                Some(_) => true
                None => false
              }
              register_decl(
                decls,
                decl_names,
                sites,
                DeclInfo::{
                  name,
                  path: file.path,
                  line,
                  candidate: candidate(name, exported, true, dispatchable),
                },
              )
              if exported {
                add_root(
                  roots,
                  root_seen,
                  Root::{
                    name,
                    path: file.path,
                    line,
                    kind: PublicApi,
                    site: fmt_site(file.path, line),
                  },
                )
              }
              if dispatchable {
                add_root(
                  roots,
                  root_seen,
                  Root::{
                    name,
                    path: file.path,
                    line,
                    kind: TraitImpl,
                    site: fmt_site(file.path, line),
                  },
                )
              }
            }
            _ => ()
          }
        _ => ()
      }
    })
    fi = fi + 1
  }
  for name in entries {
    let (path, line) = match sites.get(name) {
      Some(step) => (step.path, step.line)
      None => ("", 0)
    }
    add_root(
      roots,
      root_seen,
      Root::{ name, path, line, kind: Explicit, site: "configuration" },
    )
  }
  // Second phase: every body, now that the whole package's names are known.
  let edges : Array[CallEdge] = []
  let edge_seen : Set[String] = Set([])
  let mut fi = 0
  while fi < parsed.length() {
    let file = facts[fi]
    parsed[fi].each(fn(item) {
      match item {
        @syntax.Impl::TopFuncDef(fun_decl=decl, decl_body=body, ..) =>
          match body {
            @syntax.DeclBody::DeclBody(expr~) => {
              if opted_out(decl) {
                consume_walk(
                  walk(file.path, "", expr),
                  Some(TopLevel),
                  method_names,
                  resolved,
                  decl_names,
                  roots,
                  root_seen,
                  edges,
                  edge_seen,
                  boundaries,
                  boundary_seen,
                )
              } else {
                consume_walk(
                  walk(file.path, decl.name.name, expr),
                  None,
                  method_names,
                  resolved,
                  decl_names,
                  roots,
                  root_seen,
                  edges,
                  edge_seen,
                  boundaries,
                  boundary_seen,
                )
              }
            }
            _ => ()
          }
        @syntax.Impl::TopImpl(method_name~, body~, ..) =>
          match body {
            @syntax.DeclBody::DeclBody(expr~) =>
              consume_walk(
                walk(file.path, method_name.name, expr),
                None,
                method_names,
                resolved,
                decl_names,
                roots,
                root_seen,
                edges,
                edge_seen,
                boundaries,
                boundary_seen,
              )
            _ => ()
          }
        @syntax.Impl::TopTest(expr~, ..) =>
          consume_walk(
            walk(file.path, "", expr),
            Some(TestCall),
            method_names,
            resolved,
            decl_names,
            roots,
            root_seen,
            edges,
            edge_seen,
            boundaries,
            boundary_seen,
          )
        @syntax.Impl::TopExpr(expr~, ..) =>
          consume_walk(
            walk(file.path, "", expr),
            Some(TopLevel),
            method_names,
            resolved,
            decl_names,
            roots,
            root_seen,
            edges,
            edge_seen,
            boundaries,
            boundary_seen,
          )
        @syntax.Impl::TopLetDef(expr~, ..) =>
          consume_walk(
            walk(file.path, "", expr),
            Some(TopLevel),
            method_names,
            resolved,
            decl_names,
            roots,
            root_seen,
            edges,
            edge_seen,
            boundaries,
            boundary_seen,
          )
        @syntax.Impl::TopView(body~, ..) =>
          consume_walk(
            walk(file.path, "", body),
            Some(TopLevel),
            method_names,
            resolved,
            decl_names,
            roots,
            root_seen,
            edges,
            edge_seen,
            boundaries,
            boundary_seen,
          )
        _ => ()
      }
    })
    fi = fi + 1
  }
  roots.sort_by(fn(a, b) {
    let by_pos = compare_pos(a.path, a.line, b.path, b.line)
    if by_pos != 0 {
      by_pos
    } else {
      let by_name = a.name.lexical_compare(b.name)
      if by_name < 0 {
        -1
      } else if by_name > 0 {
        1
      } else {
        let by_kind = kind_label(a.kind).lexical_compare(kind_label(b.kind))
        if by_kind < 0 {
          -1
        } else if by_kind > 0 {
          1
        } else {
          a.site.lexical_compare(b.site)
        }
      }
    }
  })
  edges.sort_by(fn(a, b) {
    let by_caller = a.caller.lexical_compare(b.caller)
    if by_caller < 0 {
      -1
    } else if by_caller > 0 {
      1
    } else {
      let by_callee = a.callee.lexical_compare(b.callee)
      if by_callee < 0 {
        -1
      } else if by_callee > 0 {
        1
      } else {
        compare_pos(a.path, a.line, b.path, b.line)
      }
    }
  })
  boundaries.sort_by(fn(a, b) { a.lexical_compare(b) })
  // BFS over the sorted adjacency, so a shortest chain is also a stable one.
  let adjacency : Map[String, Array[CallEdge]] = Map([])
  for edge in edges {
    match adjacency.get(edge.caller) {
      Some(out) => out.push(edge)
      None => adjacency.set(edge.caller, [edge])
    }
  }
  let reachable : Set[String] = Set([])
  let parents : Map[String, String] = Map([])
  let via : Map[String, PathStep] = Map([])
  let queue : Array[String] = []
  for root in roots {
    if !reachable.contains(root.name) {
      reachable.add(root.name)
      queue.push(root.name)
    }
  }
  let mut head = 0
  while head < queue.length() {
    let current = queue[head]
    head = head + 1
    match adjacency.get(current) {
      Some(out) =>
        out.each(fn(edge) {
          if !reachable.contains(edge.callee) {
            reachable.add(edge.callee)
            parents.set(edge.callee, edge.caller)
            via.set(
              edge.callee,
              PathStep::{
                function_name: edge.callee,
                path: edge.path,
                line: edge.line,
              },
            )
            queue.push(edge.callee)
          }
        })
      None => ()
    }
  }
  let unreachable_fns : Array[UnreachableFn] = []
  for decl in decls {
    if decl.candidate && !reachable.contains(decl.name) {
      unreachable_fns.push(UnreachableFn::{
        path: decl.path,
        name: decl.name,
        line: decl.line,
      })
    }
  }
  unreachable_fns.sort_by(fn(a, b) { compare_pos(a.path, a.line, b.path, b.line) })
  Reachability::{
    roots,
    reachable,
    unreachable_fns,
    edges,
    files,
    functions: decls.length(),
    boundaries,
    parents,
    via,
    sites,
  }
}

///|
pub fn Reachability::is_reachable(self : Reachability, name : String) -> Bool {
  self.reachable.contains(name)
}

///|
/// The reachable names in sorted order, for rendering or stable assertions.
pub fn Reachability::reachable_names(self : Reachability) -> Array[String] {
  let out = self.reachable.to_array()
  out.sort_by(fn(a, b) { a.lexical_compare(b) })
  out
}

///|
/// The shortest chain from a root to `name`, or `None` when no root reaches
/// it. The first step is the root's declaration; every later step names the
/// function and the `path:line` where its caller mentions it.
pub fn Reachability::live_path(
  self : Reachability,
  name : String,
) -> LivePath? {
  if !self.reachable.contains(name) {
    return None
  }
  let reversed : Array[PathStep] = []
  let seen : Set[String] = Set([])
  let mut current = name
  let mut done = false
  while !done && !seen.contains(current) {
    seen.add(current)
    match self.parents.get(current) {
      Some(prev) => {
        let step = match self.via.get(current) {
          Some(step) => step
          None => PathStep::{ function_name: current, path: "", line: 0 }
        }
        reversed.push(step)
        current = prev
      }
      None => done = true
    }
  }
  let root_step = match self.sites.get(current) {
    Some(step) => step
    None => PathStep::{ function_name: current, path: "", line: 0 }
  }
  reversed.push(root_step)
  Some(LivePath::{ steps: reversed.rev() })
}

///|
/// The proof that `name` is unreachable: the root set, the search scope, the
/// incoming-edge evidence, and the package's unresolved call sites.
/// `None` when the function is reachable or not declared in the package.
pub fn Reachability::dead_reason(
  self : Reachability,
  name : String,
) -> DeadExplanation? {
  if self.reachable.contains(name) {
    return None
  }
  let site = match self.sites.get(name) {
    Some(site) => site
    None => return None
  }
  let incoming : Array[CallEdge] = []
  for edge in self.edges {
    if edge.callee == name {
      incoming.push(edge)
    }
  }
  let evidence : Array[String] = []
  if self.roots.length() == 0 {
    evidence.push(
      "the package has no roots: no public function, main/init, test block call, trait impl method, or explicit entry",
    )
  } else {
    evidence.push(
      "\{self.roots.length()} root(s) were expanded and none reaches `" + name +
      "`",
    )
  }
  if incoming.length() == 0 {
    evidence.push("no function in the package calls or mentions `" + name + "`")
  } else {
    let callers : Set[String] = Set([])
    let sites : Array[String] = []
    for edge in incoming {
      if !callers.contains(edge.caller) {
        callers.add(edge.caller)
        sites.push("`" + edge.caller + "` at " + fmt_site(edge.path, edge.line))
      }
    }
    evidence.push(
      "all " + "\{incoming.length()}" +
      " incoming edge(s) come from functions that are themselves unreachable: " +
      sites.join(", "),
    )
  }
  let root_summary : Array[String] = []
  for root in self.roots {
    root_summary.push(
      kind_label(root.kind) + ": " + root.name + " at " +
      fmt_site(root.path, root.line),
    )
  }
  Some(DeadExplanation::{
    function_name: name,
    path: site.path,
    line: site.line,
    root_summary,
    searched_files: self.files,
    searched_functions: self.functions,
    evidence,
    boundaries: self.boundaries,
  })
}

///|
/// Convenience: analyze the package and return the shortest live chain to
/// `name`.
pub fn explain_live(
  facts : Array[@liveness.FileFacts],
  name : String,
  entries? : Array[String] = [],
) -> LivePath? {
  analyze(facts, entries~).live_path(name)
}

///|
/// Convenience: analyze the package and explain why `name` is dead.
pub fn explain_dead(
  facts : Array[@liveness.FileFacts],
  name : String,
  entries? : Array[String] = [],
) -> DeadExplanation? {
  analyze(facts, entries~).dead_reason(name)
}
