// Package-level liveness for top-level functions.
//
// The slicing pipeline answers questions about one file. "Is this private
// function still called?" is a different question: a private function is
// visible to its whole package, so a file-local answer would be wrong in both
// directions — it would report a function whose only caller lives in a sibling
// file, and it would miss one that nothing calls.
//
// This pass therefore works on a whole package (one directory), and it is
// deliberately conservative in three ways:
//
//   1. only free functions are candidates; methods — whether from `impl` or
//      from `fn T::m(self)` — are reached through dot syntax or trait
//      dispatch, which this pass does not model, and `main` / `init` are
//      runtime entry points;
//   2. `pub` functions are the package's API and are never reported;
//   3. a name that appears anywhere else in the package text is treated as a
//      reference, even if the AST walk did not see one.
//
// The last rule is what makes the result safe to act on: a function is reported
// only when its name occurs exactly once in the package — at its own
// definition.

///|
/// A top-level function declaration. `line` is 1-based.
pub(all) struct FnDecl {
  name : String
  line : Int32
  exported : Bool
  has_body : Bool
  /// `fn T::m(self)` declares a method, even outside an `impl` block. Methods
  /// are reached through dot syntax or trait dispatch, so this pass does not
  /// treat them as candidates.
  is_method : Bool
  /// A method reached through a trait: `impl Show for T` can be called by
  /// dispatch with no syntactic reference at all, so it is never a finding.
  /// Inherent methods (`impl T with fn m`) have no such caller and do become
  /// candidates.
  dispatchable : Bool
}

///|
/// What one file contributes to its package's liveness question.
pub(all) struct FileFacts {
  path : String
  source : String
  decls : Array[FnDecl]
  /// Identifiers the file's expressions reference, in any top-level item,
  /// including `test` blocks and `impl` bodies.
  referenced : Array[String]
  parse_errors : Int
}

///|
pub(all) struct UnusedFn {
  path : String
  name : String
  line : Int32
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
priv struct RefCollector {
  names : Array[String]
}

///|
/// Identifiers in expression position. Binding sites and assignment targets are
/// `Binder` / `Var` values rather than `Expr::Ident`, so a declaration's own
/// name is not collected here.
impl @syntax.IterVisitor for RefCollector with fn visit_Expr_Ident(
  self,
  id~,
  loc~,
) {
  ignore(loc)
  match id.name {
    @syntax.LongIdent::Ident(name~) => self.names.push(name)
    @syntax.LongIdent::Dot(id~, ..) => self.names.push(id)
  }
}

///|
/// Interpolations carry their body as source text in this parser version, so
/// identifiers are scanned out of it. Conservative in the safe direction: it
/// can add a reference that is not real, never drop one.
fn collect_source_identifiers(text : String, out : Array[String]) -> Unit {
  let current = StringBuilder()
  let flush = fn() {
    if !current.is_empty() {
      out.push(current.to_string())
      ignore(current.reset())
    }
  }
  for ch in text.iter() {
    let code = ch.to_int()
    let is_start = (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
      (code >= 'A'.to_int() && code <= 'Z'.to_int()) || ch == '_'
    let is_part = is_start || (code >= '0'.to_int() && code <= '9'.to_int())
    if is_start && current.is_empty() {
      current.write_char(ch)
    } else if is_part && !current.is_empty() {
      current.write_char(ch)
    } else {
      flush()
    }
  }
  flush()
}

///|
impl @syntax.IterVisitor for RefCollector with fn visit_Expr_Interp(
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
      @syntax.InterpElem::Source(source) =>
        collect_source_identifiers(source.source, self.names)
    }
  })
}

///|
/// Collect the facts one file contributes. `path` is used only for reporting.
pub fn collect(path : String, source : String) -> FileFacts {
  let (items, reports) = @parser.parse_string(source, name=path)
  let decls : Array[FnDecl] = []
  let referenced : Array[String] = []
  let collector : RefCollector = { names: referenced, }
  items.each(fn(item) {
    match item {
      @syntax.Impl::TopFuncDef(fun_decl=decl, decl_body=body, ..) => {
        let has_body = match body {
          @syntax.DeclBody::DeclBody(_) => true
          _ => false
        }
        let is_method = match decl.type_name {
          None => false
          Some(_) => true
        }
        // `#warnings("-unused_value")` is the author saying "this mention is
        // expected to be unused". The MoonBit standard library puts it on
        // functions that exist only to keep an import alive, so honouring it is
        // reading the author's intent rather than hiding a finding.
        let opted_out = [false]
        decl.attrs.to_array().each(fn(attr) {
          if attr.raw.contains("unused_value") {
            opted_out[0] = true
          }
        })
        if !opted_out[0] {
          decls.push(FnDecl::{
            name: decl.name.name,
            line: decl.loc.start.lnum,
            exported: is_exported(decl.vis),
            has_body,
            is_method,
            dispatchable: false,
          })
        }
        match body {
          @syntax.DeclBody::DeclBody(expr~) =>
            @syntax.IterVisitor::visit_Expr(collector, expr)
          _ => ()
        }
      }
      // `impl T with fn m` is an inherent method: the only way to reach it is
      // `T::m(...)` or `x.m()`, both of which mention the name, so an
      // unreferenced one really is dead. `impl Trait for T` is different — a
      // trait call names the trait, not the method — so those stay out.
      @syntax.Impl::TopImpl(self_ty~, method_name~, vis~, body~, ..) =>
        match body {
          @syntax.DeclBody::DeclBody(expr~) => {
            let dispatchable = match self_ty {
              Some(_) => true
              None => false
            }
            decls.push(FnDecl::{
              name: method_name.name,
              line: method_name.loc.start.lnum,
              exported: is_exported(vis),
              has_body: true,
              is_method: true,
              dispatchable,
            })
            @syntax.IterVisitor::visit_Expr(collector, expr)
          }
          _ => ()
        }
      @syntax.Impl::TopView(body=body, ..) =>
        @syntax.IterVisitor::visit_Expr(collector, body)
      @syntax.Impl::TopTest(expr~, ..) =>
        @syntax.IterVisitor::visit_Expr(collector, expr)
      @syntax.Impl::TopExpr(expr~, ..) =>
        @syntax.IterVisitor::visit_Expr(collector, expr)
      @syntax.Impl::TopLetDef(expr~, ..) =>
        @syntax.IterVisitor::visit_Expr(collector, expr)
      _ => ()
    }
  })
  FileFacts::{
    path,
    source,
    decls,
    referenced,
    parse_errors: reports.length(),
  }
}

///|
fn is_word_char(ch : Char) -> Bool {
  let code = ch.to_int()
  (code >= 'a'.to_int() && code <= 'z'.to_int()) ||
  (code >= 'A'.to_int() && code <= 'Z'.to_int()) ||
  (code >= '0'.to_int() && code <= '9'.to_int()) || ch == '_'
}

///|
fn bump_word(counts : Map[String, Int], word : String) -> Unit {
  let next = match counts.get(word) {
    Some(count) => count + 1
    None => 1
  }
  counts.set(word, next)
}

///|
/// Whole-word occurrence counts for every word in the package, built in one
/// pass. Asking the same question per candidate — rescanning every file for
/// each name that no expression references — is correct but quadratic, and it
/// was the dominant cost of `unused` and of the editor's package scan on real
/// packages: a save over `moonbitlang/core` took seconds.
fn word_counts(facts : Array[FileFacts]) -> Map[String, Int] {
  let counts : Map[String, Int] = Map([])
  for file in facts {
    let current = StringBuilder()
    let mut length = 0
    for ch in file.source.iter() {
      if is_word_char(ch) {
        current.write_char(ch)
        length = length + 1
      } else if length > 0 {
        bump_word(counts, current.to_string())
        ignore(current.reset())
        length = 0
      }
    }
    if length > 0 {
      bump_word(counts, current.to_string())
    }
  }
  counts
}

///|
/// Private free functions of one package that nothing in that package
/// references.
///
/// `facts` must be *every* `.mbt` file of the package, tests included. If any
/// file failed to parse the answer would depend on a file nobody read, so the
/// package is skipped entirely.
pub fn unused_functions(facts : Array[FileFacts]) -> Array[UnusedFn] {
  let out : Array[UnusedFn] = []
  let referenced : Set[String] = Set([])
  let mut parse_failures = 0
  for file in facts {
    if file.parse_errors > 0 {
      parse_failures = parse_failures + 1
    }
    for name in file.referenced {
      referenced.add(name)
    }
  }
  if parse_failures > 0 {
    return out
  }
  let candidates : Array[(FileFacts, FnDecl)] = []
  for file in facts {
    for decl in file.decls {
      if decl.exported || !decl.has_body || decl.dispatchable {
        continue
      }
      // `main` and `init` are entry points: the runtime calls them.
      if decl.name == "main" || decl.name == "init" {
        continue
      }
      // A leading underscore is the language's own way of saying "bound on
      // purpose, never read" — `moonbitlang/x` uses it for a method that only
      // keeps a `derive(Debug)` import alive. Reporting those would be noise
      // about the author's intent, not about dead code.
      if decl.name.has_prefix("_") {
        continue
      }
      if referenced.contains(decl.name) {
        continue
      }
      candidates.push((file, decl))
    }
  }
  if candidates.length() == 0 {
    return out
  }
  // Lexical net: the name may be referenced where the AST walk does not look
  // (an attribute, a comment, interpolation text). Exactly one occurrence
  // means the definition itself is the only mention. The counts are built once
  // for the whole package rather than once per candidate.
  let counts = word_counts(facts)
  for candidate in candidates {
    let file = candidate.0
    let decl = candidate.1
    let occurrences = match counts.get(decl.name) {
      Some(count) => count
      None => 0
    }
    if occurrences == 1 {
      out.push(UnusedFn::{ path: file.path, name: decl.name, line: decl.line })
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
