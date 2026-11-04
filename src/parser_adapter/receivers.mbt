// Receiver calls: `x.f()` where the type of `x` is written down in the source.
//
// The call collector deliberately ignores `DotApply`: with no type for the
// receiver, attributing `x.f()` to a free function named `f` invents an edge.
// This pass adds the part that can be answered honestly — the receiver's type
// is read from something the author already wrote:
//
//   fn g(x : Point) { x.norm() }          // parameter type
//   let p : Point = ...; p.norm()         // annotated let
//   let mut p : Point = ...; p.norm()     // annotated let mut
//   let p = Point::new(); p.norm()        // declared return type
//   let p = { x : 1 }; p.norm()           // record literal names its type
//   let q = p; q.norm()                   // alias of a known binding
//   impl Point { fn m(self) { self.norm() } }   // self in an impl
//   fn Point::m(self) { self.norm() }           // self in a qualified method
//
// Nothing is guessed: a call to a function this file does not declare has no
// type here, a name shadowed by a local binding is never resolved through the
// file-level signature, and when one name is bound with two different types the
// name is dropped. A wrong edge is worse than a missing one, and the docs
// promise no invented edges.

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
  /// Line of the declaration, so a caller can find the body it belongs to when
  /// two types in one file declare a method with the same name.
  line : Int32
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
/// The declared result types in one file. A function that is not in these maps
/// has no type this pass can state, so its callers stay unresolved.
priv struct Signatures {
  returns : Map[String, String]
  method_returns : Map[String, String]
  /// `Owner::field` -> the field's declared type.
  fields : Map[String, String]
}

///|
fn note_signature(
  signatures : Signatures,
  owner : String?,
  name : String,
  ret : @syntax.Type?,
) -> Unit {
  match optional_type_name(ret) {
    None => ()
    Some(result) =>
      match owner {
        None => signatures.returns.set(name, result)
        Some(owner) => signatures.method_returns.set(owner + "::" + name, result)
      }
  }
}

///|
/// The annotations seen for one body. A name annotated twice with different
/// types is marked conflicting and never resolved.
priv struct Annotations {
  types : Map[String, String]
  conflicts : Set[String]
  signatures : Signatures
  /// Names bound inside this body (parameters included). A file-level function
  /// of the same name is shadowed here, so it must not type a call.
  shadowed : Set[String]
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
/// The type of a receiver expression this body already knows: a plain name with
/// one annotation (conflicting names are dropped).
fn receiver_type_of(annotations : Annotations, expr : @syntax.Expr) -> String? {
  match expr {
    Ident(id~, ..) =>
      match id.name {
        Ident(name~) =>
          if annotations.conflicts.contains(name) {
            None
          } else {
            annotations.types.get(name)
          }
        Dot(..) => None
      }
    // `p.inner` has the type the struct declares for that field, so a chain
    // resolves as long as every link is written down.
    Field(record~, accessor~, ..) =>
      match accessor {
        Label(label) =>
          match receiver_type_of(annotations, record) {
            Some(owner) =>
              annotations.signatures.fields.get(owner + "::" + label.name)
            None => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// The type of an expression the source itself states: a call to a function
/// declared in this file, a record literal, a constructor, or a binding already
/// resolved in this body.
fn infer_expr(annotations : Annotations, expr : @syntax.Expr) -> String? {
  match expr {
    Apply(func~, ..) =>
      match func {
        Ident(id~, ..) =>
          match id.name {
            Ident(name~) =>
              if annotations.shadowed.contains(name) {
                None
              } else {
                annotations.signatures.returns.get(name)
              }
            Dot(..) => None
          }
        Method(type_name~, method_name~, ..) => {
          let owner = type_name_of_decl(type_name)
          annotations.signatures.method_returns.get(
            owner + "::" + method_name.name,
          )
        }
        _ => None
      }
    Record(type_name=Some(type_name), ..) => Some(type_name_of_decl(type_name))
    // `p.inner` / `holder.point`: the field's declared type.
    Field(..) => receiver_type_of(annotations, expr)
    // `a.to_b()` names a method whose result type this file declares.
    DotApply(self~, method_name~, ..) =>
      match receiver_type_of(annotations, self) {
        Some(owner) =>
          annotations.signatures.method_returns.get(
            owner + "::" + method_name.name,
          )
        None => None
      }
    // `(expr : T)` states the type directly.
    Constraint(ty~, ..) => type_expr_name(ty)
    Ident(id~, ..) =>
      match id.name {
        Ident(name~) =>
          if annotations.conflicts.contains(name) {
            None
          } else {
            annotations.types.get(name)
          }
        Dot(..) => None
      }
    _ => None
  }
}

///|
fn note_parameter(annotations : Annotations, param : @syntax.Parameter) -> Unit {
  match param {
    Positional(binder~, ty~) => {
      annotations.shadowed.add(binder.name)
      note_annotation(annotations, binder.name, optional_type_name(ty))
    }
    Labelled(binder~, ty~) => {
      annotations.shadowed.add(binder.name)
      note_annotation(annotations, binder.name, optional_type_name(ty))
    }
    Optional(binder~, ty~, ..) => {
      annotations.shadowed.add(binder.name)
      note_annotation(annotations, binder.name, optional_type_name(ty))
    }
    QuestionOptional(binder~, ty~) => {
      annotations.shadowed.add(binder.name)
      note_annotation(annotations, binder.name, optional_type_name(ty))
    }
    DiscardPositional(..) => ()
  }
}

///|
extend Annotations with @syntax.IterVisitor::{base}

///|
/// `let x : T = ...` arrives as a `Constraint` pattern; `let x = expr` has no
/// annotation, so the type is read from `expr` when the source states one.
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
        Var(binder) => {
          env.shadowed.add(binder.name)
          note_annotation(env, binder.name, type_expr_name(ty))
        }
        _ => ()
      }
    Var(binder) => {
      env.shadowed.add(binder.name)
      note_annotation(env, binder.name, infer_expr(env, expr))
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
  env.shadowed.add(binder.name)
  match optional_type_name(ty) {
    Some(_) as found => note_annotation(env, binder.name, found)
    None => note_annotation(env, binder.name, infer_expr(env, expr))
  }
  @syntax.IterVisitor::visit_Expr_LetMut(env.base(), binder~, ty~, expr~, body~, loc~)
}

///|
impl @syntax.IterVisitor for Annotations with fn visit_Expr_LetFn(
  env,
  name~,
  func~,
  body~,
  loc~,
) {
  env.shadowed.add(name.name)
  @syntax.IterVisitor::visit_Expr_LetFn(env.base(), name~, func~, body~, loc~)
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
  // Only a plain identifier has an annotation to look up. `a.b.f()` and
  // `f().g()` need a full typed environment, so they stay unresolved.
  match receiver_type_of(env.annotations, self) {
    Some(receiver_type) =>
      env.calls.push(ReceiverCall::{
        line: loc.start.lnum,
        receiver_type,
        method_name: method_name.name,
        caller: env.caller,
      })
    None => ()
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
  signatures : Signatures,
  caller : String,
  params : @syntax.Parameters?,
  self_type : String?,
  body : @syntax.Expr,
) -> Unit {
  let annotations : Annotations = {
    types: Map([]),
    conflicts: Set([]),
    signatures,
    shadowed: Set([]),
  }
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
  let receiver_calls : Array[ReceiverCall] = []
  let methods : Array[MethodDecl] = []
  let signatures : Signatures = {
    returns: Map([]),
    method_returns: Map([]),
    fields: Map([]),
  }

  // First pass: the result types this file declares, so a `let` anywhere in it
  // can be typed regardless of declaration order.
  impls.each(fn(impl_) {
    match impl_ {
      TopFuncDef(fun_decl=decl, ..) => {
        let owner = match decl.type_name {
          Some(type_name) => Some(type_name_of_decl(type_name))
          None => None
        }
        note_signature(signatures, owner, decl.name.name, decl.return_type)
      }
      TopImpl(self_ty~, trait_~, method_name~, ret_ty~, ..) => {
        let owner = match optional_type_name(self_ty) {
          Some(found) => Some(found)
          None => Some(type_name_of_decl(trait_))
        }
        note_signature(signatures, owner, method_name.name, ret_ty)
      }
      // `struct T { f : U }`: the field types this file declares.
      TopTypeDef(decl) =>
        match decl.components {
          @syntax.TypeDesc::Record(fields~, ..) => {
            // A field declared as a type parameter has no concrete type here:
            // `struct Box[T] { v : T }` says nothing about `b.v`.
            let params : Set[String] = Set([])
            decl.params.each(fn(param) {
              match param.name {
                Some(name) => params.add(name)
                None => ()
              }
            })
            fields.each(fn(field) {
              match type_expr_name(field.ty) {
                Some(field_type) =>
                  if !params.contains(field_type) {
                    signatures.fields.set(
                      decl.tycon + "::" + field.name.label,
                      field_type,
                    )
                  }
                None => ()
              }
            })
          }
          _ => ()
        }
      _ => ()
    }
  })

  // Second pass: the bodies themselves.
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
              line: decl.name.loc.start.lnum,
            })
          None => ()
        }
        collect_body(
          receiver_calls,
          signatures,
          decl.name.name,
          decl.decl_params,
          self_type,
          body,
        )
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
          Some(owner) =>
            methods.push(MethodDecl::{
              owner,
              name: method_name.name,
              line: method_name.loc.start.lnum,
            })
          None => ()
        }
        match body {
          DeclBody(expr=body) =>
            collect_body(
              receiver_calls,
              signatures,
              method_name.name,
              Some(params),
              owner,
              body,
            )
          _ => ()
        }
      }
      TopView(view_func_name~, parameters~, body~, ..) =>
        collect_body(
          receiver_calls,
          signatures,
          view_func_name.name,
          Some(parameters),
          None,
          body,
        )
      _ => ()
    }
  })
  CallFacts::{ receivers: receiver_calls, methods }
}
