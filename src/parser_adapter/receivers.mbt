// Receiver calls: `x.f()` where the type of `x` is written down in the source.
//
// The call collector deliberately ignores `DotApply`: with no type for the
// receiver, attributing `x.f()` to a free function named `f` invents an edge.
// This pass adds the part that can be answered honestly — the receiver's type
// is read from an annotation the author already wrote:
//
//   fn g(x : Point) { x.norm() }        // parameter type
//   let p : Point = ...; p.norm()       // annotated let
//   let mut p : Point = ...; p.norm()   // annotated let mut
//   impl Point { fn m(self) { self.norm() } }   // self in an impl
//   fn Point::m(self) { self.norm() }           // self in a qualified method
//
// Nothing is inferred from a return type, a field access or a constructor: a
// binding without an annotation is simply not resolved. When one name is bound
// with two different annotated types in the same body, the name is dropped —
// a wrong edge is worse than a missing one, and the docs promise no invented
// edges.

///|
/// One resolved receiver call.
pub(all) struct ReceiverCall {
  /// Line of the method name.
  line : Int32
  /// The type written for the receiver.
  receiver_type : String
  /// The method called on it.
  method_name : String
  /// The function the call appears in, for `callers`.
  caller : String
}

///|
/// A method declared in the file, with the type it belongs to.
pub(all) struct MethodDecl {
  owner : String
  name : String
}

///|
/// What one file contributes to the call graph beyond plain calls.
pub(all) struct CallFacts {
  receivers : Array[ReceiverCall]
  methods : Array[MethodDecl]
}

///|
fn short_type_name(name : @syntax.LongIdent) -> String {
  match name {
    Ident(name~) => name
    // `@pkg.Type`: the method set is still keyed by the short name, because a
    // package's methods cannot be declared on another package's type.
    Dot(id~, ..) => id
  }
}

///|
fn type_expr_name(ty : @syntax.Type) -> String? {
  match ty {
    Name(constr_id~, ..) => Some(short_type_name(constr_id.id))
    _ => None
  }
}

///|
fn optional_type_name(ty : @syntax.Type?) -> String? {
  match ty {
    Some(inner) => type_expr_name(inner)
    None => None
  }
}

///|
fn type_name_of_decl(name : @syntax.TypeName) -> String {
  short_type_name(name.name)
}

///|
/// The annotations seen for one body. A name annotated twice with different
/// types is marked conflicting and never resolved.
priv struct Annotations {
  types : Map[String, String]
  conflicts : Set[String]
}

///|
fn note_annotation(annotations : Annotations, name : String, ty : String?) -> Unit {
  match ty {
    None => ()
    Some(found) =>
      match annotations.types.get(name) {
        None => annotations.types.set(name, found)
        Some(existing) =>
          if existing != found {
            annotations.conflicts.add(name)
          }
      }
  }
}

///|
fn note_parameter(annotations : Annotations, param : @syntax.Parameter) -> Unit {
  match param {
    Positional(binder~, ty~) =>
      note_annotation(annotations, binder.name, optional_type_name(ty))
    Labelled(binder~, ty~) =>
      note_annotation(annotations, binder.name, optional_type_name(ty))
    Optional(binder~, ty~, ..) =>
      note_annotation(annotations, binder.name, optional_type_name(ty))
    QuestionOptional(binder~, ty~) =>
      note_annotation(annotations, binder.name, optional_type_name(ty))
    DiscardPositional(..) => ()
  }
}

///|
extend Annotations with @syntax.IterVisitor::{base}

///|
/// `let x : T = ...` arrives as a `Constraint` pattern; `let mut x : T = ...`
/// carries its type on the node itself.
impl @syntax.IterVisitor for Annotations with fn visit_Expr_Let(
  env,
  pattern~,
  expr~,
  body~,
  loc~,
) {
  match pattern {
    Constraint(pat~, ty~, ..) =>
      match pat {
        Var(binder) => note_annotation(env, binder.name, type_expr_name(ty))
        _ => ()
      }
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Let(env.base(), pattern~, expr~, body~, loc~)
}

///|
impl @syntax.IterVisitor for Annotations with fn visit_Expr_LetMut(
  env,
  binder~,
  ty~,
  expr~,
  body~,
  loc~,
) {
  note_annotation(env, binder.name, optional_type_name(ty))
  @syntax.IterVisitor::visit_Expr_LetMut(env.base(), binder~, ty~, expr~, body~, loc~)
}

///|
/// Second pass: resolve `receiver.method()` against the annotations.
priv struct ReceiverCollector {
  annotations : Annotations
  caller : String
  calls : Array[ReceiverCall]
}

///|
extend ReceiverCollector with @syntax.IterVisitor::{base}

///|
impl @syntax.IterVisitor for ReceiverCollector with fn visit_Expr_DotApply(
  env,
  self~,
  method_name~,
  args~,
  return_self~,
  loc~,
) {
  match self {
    // Only a plain identifier has an annotation to look up. `a.b.f()` and
    // `f().g()` need real type inference, so they stay unresolved.
    Ident(id~, ..) =>
      match id.name {
        Ident(name~) =>
          if !env.annotations.conflicts.contains(name) {
            match env.annotations.types.get(name) {
              Some(receiver_type) =>
                env.calls.push(ReceiverCall::{
                  line: loc.start.lnum,
                  receiver_type,
                  method_name: method_name.name,
                  caller: env.caller,
                })
              None => ()
            }
          }
        Dot(..) => ()
      }
    _ => ()
  }
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
fn collect_body(
  out : Array[ReceiverCall],
  caller : String,
  params : @syntax.Parameters?,
  self_type : String?,
  body : @syntax.Expr,
) -> Unit {
  let annotations : Annotations = { types: Map([]), conflicts: Set([]) }
  match params {
    Some(params) => params.each(fn(param) { note_parameter(annotations, param) })
    None => ()
  }
  match self_type {
    Some(owner) => annotations.types.set("self", owner)
    None => ()
  }
  @syntax.IterVisitor::visit_Expr(annotations, body)
  let collector : ReceiverCollector = {
    annotations,
    caller,
    calls: [],
  }
  @syntax.IterVisitor::visit_Expr(collector, body)
  collector.calls.each(fn(call) { out.push(call) })
}

///|
/// Scan one file for receiver calls and for the methods it declares. The callee
/// still has to be declared by the package before a receiver call becomes an
/// edge; that check lives in `interproc`, where the whole package is visible.
pub fn call_facts(source : String, name : String) -> CallFacts {
  let (impls, _) = @parser.parse_string(source, name~)
  let receivers : Array[ReceiverCall] = []
  let methods : Array[MethodDecl] = []
  impls.each(fn(impl_) {
    match impl_ {
      TopFuncDef(fun_decl=decl, decl_body=DeclBody(expr=body), ..) => {
        let self_type = match decl.type_name {
          Some(type_name) => Some(type_name_of_decl(type_name))
          None => None
        }
        // `fn T::m(self)` declares a method of `T` even outside an impl block.
        match decl.type_name {
          Some(type_name) =>
            methods.push(MethodDecl::{
              owner: type_name_of_decl(type_name),
              name: decl.name.name,
            })
          None => ()
        }
        collect_body(receivers, decl.name.name, decl.decl_params, self_type, body)
      }
      TopImpl(self_ty~, trait_~, method_name~, params~, body~, ..) => {
        // `impl Point with fn m(...)` puts the type in `trait_` and leaves
        // `self_ty` empty; `impl Show for Point` does the opposite. Either way
        // the methods belong to the concrete type.
        let owner = match optional_type_name(self_ty) {
          Some(name) => Some(name)
          None => Some(type_name_of_decl(trait_))
        }
        match owner {
          Some(owner) => methods.push(MethodDecl::{ owner, name: method_name.name })
          None => ()
        }
        match body {
          DeclBody(expr=body) =>
            collect_body(receivers, method_name.name, Some(params), owner, body)
          _ => ()
        }
      }
      TopView(view_func_name~, parameters~, body~, ..) =>
        collect_body(receivers, view_func_name.name, Some(parameters), None, body)
      _ => ()
    }
  })
  CallFacts::{ receivers, methods }
}
