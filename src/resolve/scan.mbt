// The AST side of the pass: enumerate *every* `recv.method()` in a body,
// whatever the type story is, and remember enough about the receiver to explain
// a failure later.
//
// `parser_adapter` already walks the same bodies for the typed subset. This
// scanner deliberately does not try to type anything; matched against the
// adapter's facts by (caller, line, method), a site either inherits a receiver
// type or is reported as a miss. That keeps one inference engine in the repo
// and makes "resolved" mean exactly what `call_facts` means by it.

///|
/// One dot call seen in a body, before a type is attached.
priv struct DotSite {
  /// The function the call appears in, matching `ReceiverCall.caller`.
  caller : String
  /// Line of the method name.
  line : Int32
  method_name : String
  receiver_expr : String
  receiver_shape : ReceiverShape
}

///|
/// Whether the receiver expression is a name-shaped thing this pass could in
/// principle have typed, or a computed value.
priv enum ReceiverShape {
  Static
  Dynamic
}

///|
/// The scanner walks one body and appends every `DotApply` it meets.
priv struct DotScanner {
  caller : String
  sites : Array[DotSite]
}

///|
extend DotScanner with @syntax.IterVisitor::{base}

///|
impl @syntax.IterVisitor for DotScanner with fn visit_Expr_DotApply(
  env,
  self~,
  method_name~,
  args~,
  return_self~,
  loc~,
) {
  env.sites.push(DotSite::{
    caller: env.caller,
    line: loc.start.lnum,
    method_name: method_name.name,
    receiver_expr: expr_text(self),
    receiver_shape: shape_of(self),
  })
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
/// A receiver expression rendered the way an author would recognise it. Only the
/// shapes a reader can act on are spelled out; anything else is `?`, because a
/// half-rendered expression is worse than an honest placeholder.
fn expr_text(expr : @syntax.Expr) -> String {
  match expr {
    Ident(id~, ..) => long_ident_text(id.name)
    Field(record~, accessor~, ..) =>
      match accessor {
        Label(label) => expr_text(record) + "." + label.name
        _ => expr_text(record) + ".?"
      }
    Apply(func~, ..) => expr_text(func) + "(...)"
    Method(type_name~, method_name~, ..) =>
      long_ident_text(type_name.name) + "::" + method_name.name
    DotApply(self~, method_name~, ..) =>
      expr_text(self) + "." + method_name.name + "(...)"
    Record(type_name=Some(type_name), ..) =>
      long_ident_text(type_name.name) + " { ... }"
    _ => "?"
  }
}

///|
fn long_ident_text(name : @syntax.LongIdent) -> String {
  match name {
    Ident(name~) => name
    Dot(id~, ..) => "@" + id
  }
}

///|
/// A receiver this pass could have typed had the source said more about it stays
/// `Static`; a receiver that is itself a call or a literal is a `Dynamic` value
/// even before the type question is asked.
fn shape_of(expr : @syntax.Expr) -> ReceiverShape {
  match expr {
    Ident(..) | Field(..) | Constraint(..) => Static
    _ => Dynamic
  }
}

///|
fn walk_body(sites : Array[DotSite], caller : String, body : @syntax.Expr) -> Unit {
  let scanner : DotScanner = { caller: caller, sites: [] }
  @syntax.IterVisitor::visit_Expr(scanner, body)
  let mut i = 0
  while i < scanner.sites.length() {
    sites.push(scanner.sites[i])
    i = i + 1
  }
}

///|
/// Scan one file: every dot call, and the names of the types it declares.
///
/// The bodies walked here are the same three the adapter walks — plain
/// functions, impl methods and views — so the site list and the adapter's fact
/// list cover the same calls.
fn scan_file(
  source : String,
  name : String,
) -> (Array[DotSite], Array[String]) {
  let (impls, _) = @parser.parse_string(source, name~)
  let sites : Array[DotSite] = []
  let type_names : Array[String] = []
  impls.each(fn(impl_) {
    match impl_ {
      TopTypeDef(decl) => type_names.push(decl.tycon)
      TopFuncDef(fun_decl=decl, decl_body=DeclBody(expr=body), ..) =>
        walk_body(sites, decl.name.name, body)
      TopImpl(method_name~, body=DeclBody(expr=body), ..) =>
        walk_body(sites, method_name.name, body)
      TopView(view_func_name~, body~, ..) =>
        walk_body(sites, view_func_name.name, body)
      _ => ()
    }
  })
  (sites, type_names)
}
