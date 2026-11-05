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
//   let u = holder.point; u.norm()        // declared field type
//   let Ok(p) = e; p.norm()               // enum payload of a `let` pattern
//   impl Point { fn m(self) { self.norm() } }   // self in an impl
//   fn Point::m(self) { self.norm() }           // self in a qualified method
//
// Nothing is guessed: a call to a function this file does not declare has no
// type here, a field typed by a type parameter stays unresolved, a name
// shadowed by a local binding is never resolved through the file-level
// signature, and when one name is bound with two different types the name is
// dropped. A wrong edge is worse than a missing one, and the docs promise no
// invented edges.

///|
/// A type as this pass can state it: a short name plus one level of arguments,
/// which is what `Box[Point]` needs to substitute `T` in `enum Box[T] { Wrap(T) }`.
priv struct Ty {
  name : String
  args : Array[String]
}

///|
fn same_ty(a : Ty, b : Ty) -> Bool {
  if a.name != b.name || a.args.length() != b.args.length() {
    return false
  }
  let mut i = 0
  while i < a.args.length() {
    if a.args[i] != b.args[i] {
      return false
    }
    i = i + 1
  }
  true
}

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
/// One enum as a declaration table stores it: payloads reduced to names, which
/// is all a sibling file needs to bind a pattern variable.
pub(all) struct EnumDecl {
  params : Array[String]
  variants : Map[String, Array[String]]
}

///|
/// The declared types of one file, in a form another file can merge. Types are
/// short names: a package shares one namespace for its own types.
pub(all) struct DeclTable {
  returns : Map[String, String]
  method_returns : Map[String, String]
  fields : Map[String, String]
  enums : Map[String, EnumDecl]
}

///|
pub fn empty_decls() -> DeclTable {
  DeclTable::{
    returns: Map([]),
    method_returns: Map([]),
    fields: Map([]),
    enums: Map([]),
  }
}

///|
/// Merge `from` into `into`; a later file wins on a name clash, which is what
/// the package's own scan order gives.
pub fn merge_decls(into : DeclTable, from : DeclTable) -> Unit {
  from.returns.to_array().each(fn(pair) { into.returns.set(pair.0, pair.1) })
  from.method_returns.to_array().each(fn(pair) {
    into.method_returns.set(pair.0, pair.1)
  })
  from.fields.to_array().each(fn(pair) { into.fields.set(pair.0, pair.1) })
  from.enums.to_array().each(fn(pair) { into.enums.set(pair.0, pair.1) })
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
fn type_name_of_decl(name : @syntax.TypeName) -> String {
  short_type_name(name.name)
}

///|
fn type_ty(ty : @syntax.Type) -> Ty? {
  match ty {
    Name(constr_id~, tys~, ..) => {
      let args : Array[String] = []
      tys.each(fn(arg) {
        match type_ty(arg) {
          Some(inner) => args.push(inner.name)
          // A type argument this pass cannot name is recorded as empty, so a
          // substitution through it resolves to nothing instead of guessing.
          None => args.push("")
        }
      })
      Some(Ty::{ name: short_type_name(constr_id.id), args })
    }
    _ => None
  }
}

///|
fn optional_ty(ty : @syntax.Type?) -> Ty? {
  match ty {
    Some(inner) => type_ty(inner)
    None => None
  }
}

///|
/// The variants of one enum, so a `let Ok(p) = e` can type `p`.
priv struct EnumInfo {
  params : Array[String]
  /// Variant name -> payload types, in source order. A payload may name one of
  /// `params`, which is what substitution resolves against the scrutinee.
  variants : Map[String, Array[Ty]]
}

///|
/// The declared types in one file: result types, field types, enums.
priv struct Signatures {
  returns : Map[String, Ty]
  method_returns : Map[String, Ty]
  /// `Owner::field` -> the field's declared type.
  fields : Map[String, Ty]
  enums : Map[String, EnumInfo]
}

///|
fn note_signature(
  signatures : Signatures,
  owner : String?,
  name : String,
  ret : @syntax.Type?,
) -> Unit {
  match optional_ty(ret) {
    None => ()
    Some(result) =>
      match owner {
        None => signatures.returns.set(name, result)
        Some(owner) => signatures.method_returns.set(owner + "::" + name, result)
      }
  }
}

///|
/// `Option` and `Result` are prelude types: their declarations are not in the
/// file being analysed, but every MoonBit program uses them. Their payloads are
/// type parameters, so the substitution below resolves `Option[Point]`.
fn builtin_enums() -> Map[String, EnumInfo] {
  let param = fn(name : String) { Ty::{ name, args: [] } }
  let option_variants : Map[String, Array[Ty]] = Map([])
  option_variants.set("None", [])
  option_variants.set("Some", [param("T")])
  let result_variants : Map[String, Array[Ty]] = Map([])
  result_variants.set("Ok", [param("T")])
  result_variants.set("Err", [param("E")])
  let enums : Map[String, EnumInfo] = Map([])
  enums.set("Option", EnumInfo::{ params: ["T"], variants: option_variants })
  enums.set("Result", EnumInfo::{ params: ["T", "E"], variants: result_variants })
  enums
}

///|
/// The annotations seen for one body. A name annotated twice with different
/// types is marked conflicting and never resolved.
priv struct Annotations {
  types : Map[String, Ty]
  conflicts : Set[String]
  signatures : Signatures
  /// Names bound inside this body (parameters included). A file-level function
  /// of the same name is shadowed here, so it must not type a call.
  shadowed : Set[String]
}

///|
fn note_annotation(annotations : Annotations, name : String, ty : Ty?) -> Unit {
  match ty {
    None => ()
    Some(found) =>
      match annotations.types.get(name) {
        None => annotations.types.set(name, found)
        Some(existing) =>
          if !same_ty(existing, found) {
            annotations.conflicts.add(name)
          }
      }
  }
}

///|
/// The type of a receiver expression this body already knows: a plain name with
/// one annotation (conflicting names are dropped), or a field access whose
/// every link is written down.
fn receiver_ty_of(annotations : Annotations, expr : @syntax.Expr) -> Ty? {
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
    Field(record~, accessor~, ..) =>
      match accessor {
        Label(label) =>
          match receiver_ty_of(annotations, record) {
            Some(owner) =>
              annotations.signatures.fields.get(owner.name + "::" + label.name)
            None => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// The type of an expression the source itself states: a call to a function
/// declared in this file, a field, a record literal, or a binding already
/// resolved in this body.
fn infer_expr(annotations : Annotations, expr : @syntax.Expr) -> Ty? {
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
    Record(type_name=Some(type_name), ..) =>
      Some(Ty::{ name: type_name_of_decl(type_name), args: [] })
    Field(..) => receiver_ty_of(annotations, expr)
    DotApply(self~, method_name~, ..) =>
      match receiver_ty_of(annotations, self) {
        Some(owner) =>
          annotations.signatures.method_returns.get(
            owner.name + "::" + method_name.name,
          )
        None => None
      }
    // `(expr : T)` states the type directly.
    Constraint(ty~, ..) => type_ty(ty)
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
/// Substitute the enum's parameters with the scrutinee's arguments: for
/// `Box[Point]`, the payload `T` becomes `Point`.
fn substitute_payload(
  info : EnumInfo,
  payload : Ty,
  args : Array[String],
) -> Ty? {
  let mut i = 0
  while i < info.params.length() {
    if info.params[i] == payload.name {
      if i < args.length() && args[i] != "" {
        return Some(Ty::{ name: args[i], args: [] })
      }
      return None
    }
    i = i + 1
  }
  Some(payload)
}

///|
fn note_parameter(annotations : Annotations, param : @syntax.Parameter) -> Unit {
  match param {
    Positional(binder~, ty~) => {
      annotations.shadowed.add(binder.name)
      note_annotation(annotations, binder.name, optional_ty(ty))
    }
    Labelled(binder~, ty~) => {
      annotations.shadowed.add(binder.name)
      note_annotation(annotations, binder.name, optional_ty(ty))
    }
    Optional(binder~, ty~, ..) => {
      annotations.shadowed.add(binder.name)
      note_annotation(annotations, binder.name, optional_ty(ty))
    }
    QuestionOptional(binder~, ty~) => {
      annotations.shadowed.add(binder.name)
      note_annotation(annotations, binder.name, optional_ty(ty))
    }
    DiscardPositional(..) => ()
  }
}

///|
/// Bind the variables a pattern introduces, given the type the value has:
/// `Ok(p)` binds `p` to the variant's payload, `x` binds the value itself,
/// `p as x` binds both, `A | B` binds what each side introduces.
fn bind_pattern(
  annotations : Annotations,
  pattern : @syntax.Pattern,
  ty : Ty?,
) -> Unit {
  match pattern {
    Var(binder) => {
      annotations.shadowed.add(binder.name)
      note_annotation(annotations, binder.name, ty)
    }
    Constraint(pat~, ty~, ..) =>
      bind_pattern(annotations, pat, type_ty(ty))
    Alias(pat~, alias_~, ..) => {
      annotations.shadowed.add(alias_.name)
      note_annotation(annotations, alias_.name, ty)
      bind_pattern(annotations, pat, ty)
    }
    Or(pat1~, pat2~, ..) => {
      bind_pattern(annotations, pat1, ty)
      bind_pattern(annotations, pat2, ty)
    }
    Constr(constr~, args~, ..) =>
      match ty {
        None => ()
        Some(value) =>
          match annotations.signatures.enums.get(value.name) {
            None => ()
            Some(info) =>
              match info.variants.get(constr.name.name) {
                None => ()
                Some(payloads) =>
                  match args {
                    None => ()
                    Some(args) => {
                      let list = args.to_array()
                      let mut i = 0
                      while i < list.length() {
                        let payload = if i < payloads.length() {
                          substitute_payload(info, payloads[i], value.args)
                        } else {
                          None
                        }
                        bind_pattern(annotations, list[i].pat, payload)
                        i = i + 1
                      }
                    }
                  }
              }
          }
      }
    _ => ()
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
          note_annotation(env, binder.name, type_ty(ty))
        }
        _ => ()
      }
    Var(binder) => {
      env.shadowed.add(binder.name)
      note_annotation(env, binder.name, infer_expr(env, expr))
    }
    _ => bind_pattern(env, pattern, infer_expr(env, expr))
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
  match optional_ty(ty) {
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
/// `match e { Ok(p) => ... }`: every case pattern gets the scrutinee's type, and
/// the case body sees the bindings. Cases are walked one at a time so a binding
/// added by one arm cannot change how the next is read.
impl @syntax.IterVisitor for Annotations with fn visit_Expr_Match(
  env,
  expr~,
  cases~,
  match_loc~,
  loc~,
) {
  ignore(match_loc)
  ignore(loc)
  let scrutinee = infer_expr(env, expr)
  @syntax.IterVisitor::visit_Expr(env.base(), expr)
  cases.each(fn(arm) {
    bind_pattern(env, arm.pattern, scrutinee)
    match arm.guard_ {
      Some(guard_) => @syntax.IterVisitor::visit_Expr(env.base(), guard_)
      None => ()
    }
    @syntax.IterVisitor::visit_Expr(env.base(), arm.body)
  })
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
  // Only a plain identifier or a field chain has an annotation to look up.
  // `f().g()` needs a full typed environment, so it stays unresolved.
  match receiver_ty_of(env.annotations, self) {
    Some(receiver) =>
      env.calls.push(ReceiverCall::{
        line: loc.start.lnum,
        receiver_type: receiver.name,
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
    Some(owner) => annotations.types.set("self", Ty::{ name: owner, args: [] })
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
/// Record the declarations one file contributes into `signatures`: result
/// types, field types and enums. Kept separate from resolution so a package can
/// merge every file's declarations before resolving any body.
fn scan_declarations(impls : Array[@syntax.Impl], signatures : Signatures) -> Unit {
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
        let owner = match optional_ty(self_ty) {
          Some(found) => Some(found.name)
          None => Some(type_name_of_decl(trait_))
        }
        note_signature(signatures, owner, method_name.name, ret_ty)
      }
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
              match type_ty(field.ty) {
                Some(field_type) =>
                  if !params.contains(field_type.name) {
                    signatures.fields.set(
                      decl.tycon + "::" + field.name.label,
                      field_type,
                    )
                  }
                None => ()
              }
            })
          }
          @syntax.TypeDesc::Variant(constructors) => {
            let params : Array[String] = []
            decl.params.each(fn(param) {
              match param.name {
                Some(name) => params.push(name)
                None => ()
              }
            })
            let variants : Map[String, Array[Ty]] = Map([])
            constructors.each(fn(constr) {
              let payloads : Array[Ty] = []
              match constr.args {
                Some(args) =>
                  args.each(fn(arg) {
                    match type_ty(arg.ty) {
                      Some(payload) => payloads.push(payload)
                      // A payload that is not a named type leaves the variant
                      // with fewer entries than it has arguments, so those
                      // positions resolve to nothing.
                      None => ()
                    }
                  })
                None => ()
              }
              variants.set(constr.name.name, payloads)
            })
            signatures.enums.set(decl.tycon, EnumInfo::{ params, variants })
          }
          _ => ()
        }
      _ => ()
    }
  })

}

///|
fn signatures_with(extra : DeclTable) -> Signatures {
  let signatures : Signatures = {
    returns: Map([]),
    method_returns: Map([]),
    fields: Map([]),
    enums: builtin_enums(),
  }
  extra.returns.to_array().each(fn(pair) {
    signatures.returns.set(pair.0, Ty::{ name: pair.1, args: [] })
  })
  extra.method_returns.to_array().each(fn(pair) {
    signatures.method_returns.set(pair.0, Ty::{ name: pair.1, args: [] })
  })
  extra.fields.to_array().each(fn(pair) {
    signatures.fields.set(pair.0, Ty::{ name: pair.1, args: [] })
  })
  extra.enums.to_array().each(fn(pair) {
    let variants : Map[String, Array[Ty]] = Map([])
    pair.1.variants.to_array().each(fn(entry) {
      variants.set(entry.0, entry.1.map(fn(name) { Ty::{ name, args: [] } }))
    })
    signatures.enums.set(
      pair.0,
      EnumInfo::{ params: pair.1.params, variants },
    )
  })
  signatures
}

///|
fn to_decl_table(signatures : Signatures) -> DeclTable {
  let table = empty_decls()
  signatures.returns.to_array().each(fn(pair) {
    table.returns.set(pair.0, pair.1.name)
  })
  signatures.method_returns.to_array().each(fn(pair) {
    table.method_returns.set(pair.0, pair.1.name)
  })
  signatures.fields.to_array().each(fn(pair) {
    table.fields.set(pair.0, pair.1.name)
  })
  signatures.enums.to_array().each(fn(pair) {
    let variants : Map[String, Array[String]] = Map([])
    pair.1.variants.to_array().each(fn(entry) {
      variants.set(entry.0, entry.1.map(fn(ty) { ty.name }))
    })
    table.enums.set(pair.0, EnumDecl::{ params: pair.1.params, variants })
  })
  table
}

///|
/// The declarations of one file, for a caller that is about to resolve a whole
/// package. `Option` and `Result` are added on the resolving side, so they are
/// not repeated here.
pub fn declared_types(source : String, name : String) -> DeclTable {
  let (impls, _) = @parser.parse_string(source, name~)
  let signatures : Signatures = {
    returns: Map([]),
    method_returns: Map([]),
    fields: Map([]),
    enums: Map([]),
  }
  scan_declarations(impls.to_array(), signatures)
  to_decl_table(signatures)
}

///|
/// Scan one file for receiver calls and for the methods it declares. The callee
/// still has to be declared by the package before a receiver call becomes an
/// edge; that check lives in `interproc`, where the whole package is visible.
pub fn call_facts(
  source : String,
  name : String,
  extra? : DeclTable = empty_decls(),
) -> CallFacts {
  let (impls, _) = @parser.parse_string(source, name~)
  let receiver_calls : Array[ReceiverCall] = []
  let methods : Array[MethodDecl] = []
  let signatures = signatures_with(extra)

  scan_declarations(impls.to_array(), signatures)
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
        let owner = match optional_ty(self_ty) {
          Some(name) => Some(name.name)
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
