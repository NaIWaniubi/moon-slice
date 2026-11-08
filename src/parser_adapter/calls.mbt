// Calls: arguments and side-effecting statements.
//
// The node IR records that a statement calls a function, but not which argument
// feeds which parameter, and not which statement inside a callee is observable.
// Both questions are answered from the AST here and handed to `src/interproc`
// in a parser-free shape, so the expansion can be precise without the analysis
// layer reaching into `@syntax`.
//
// Two entry points:
//
//   * `call_arguments` — pair a call's arguments with the callee's parameters,
//     covering positional arguments, `name=expr` arguments and defaults;
//   * `effect_lines` — the lines of the statements a caller can observe:
//     field / element writes, receiver mutation, raises, IO calls, and every
//     call site in the body (so the expansion can follow the impure ones).
//
// Nothing here guesses. A call whose callee is not declared in the source has
// no parameter list, so the arguments are reported positionally with an empty
// `param_name`; the source text is still exact, which is what the expansion
// needs in that case.

///|
/// One argument bound to a parameter of the callee.
///
/// There is one entry per bindable parameter of the callee, in declaration
/// order. A parameter that the call does not supply keeps an empty `expr_text`
/// (that covers both "has a default" and "optional"), which is how a caller can
/// tell "omitted" from "passed".
pub(all) struct CallArgument {
  /// Position of the parameter in the callee's declaration, from 0. Discard
  /// parameters (`_ : Int`) keep their position but produce no entry.
  index : Int32
  /// The parameter's name; empty when the callee's declaration is unknown.
  param_name : String
  /// The argument's source text, trimmed; empty when the argument is omitted.
  expr_text : String
  /// Line the argument expression starts on; 0 when the argument is omitted.
  expr_line : Int32
}

///|
/// One call inside a function body: the line its callee name sits on, and the
/// name as the AST records it.
///
/// The name is `""` for a call through a function value and `"@"` for a call
/// qualified with a package (`@pkg.f`). Neither can be resolved inside the
/// package, and the expansion treats both as a boundary.
pub(all) struct EffectCall {
  line : Int32
  name : String
}

///|
/// The statements of one function body a caller can observe.
///
/// Every array is in source order and may repeat a line (two effects on one
/// line, or a call that is itself IO). Empty arrays mean the body does not do
/// that thing at all.
pub(all) struct EffectLines {
  /// Field writes, element writes and receiver mutation.
  writes : Array[Int32]
  /// `raise`, `try!` and the panic helpers.
  raises : Array[Int32]
  /// Calls whose name is on the default IO list.
  io : Array[Int32]
  /// Every call site in the body.
  calls : Array[EffectCall]
}

// ---------------------------------------------------------------------------
// Declarations of one source
// ---------------------------------------------------------------------------

///|
/// One function declaration a source makes visible: a free function, a
/// `fn T::m` method, an `impl` method, or a view.
priv struct FnDecl {
  name : String
  /// The type the declaration belongs to, or `""` for a free function.
  owner : String
  params : @syntax.Parameters?
  body : @syntax.Expr
}

///|
fn declared_functions(impls : Array[@syntax.Impl]) -> Array[FnDecl] {
  let out : Array[FnDecl] = []
  for impl_ in impls {
    match impl_ {
      TopFuncDef(fun_decl=decl, decl_body=DeclBody(expr=body), ..) => {
        let owner = match decl.type_name {
          Some(type_name) => type_name_of_decl(type_name)
          None => ""
        }
        out.push(FnDecl::{ name: decl.name.name, owner, params: decl.decl_params, body })
      }
      TopImpl(self_ty~, trait_~, method_name~, params~, body~, ..) =>
        match body {
          DeclBody(expr=body_expr) => {
            let owner = match optional_ty(self_ty) {
              Some(found) => found.name
              None => type_name_of_decl(trait_)
            }
            out.push(FnDecl::{
              name: method_name.name,
              owner,
              params: Some(params),
              body: body_expr,
            })
          }
          _ => ()
        }
      TopView(view_func_name~, parameters~, body~, ..) =>
        out.push(FnDecl::{
          name: view_func_name.name,
          owner: "",
          params: Some(parameters),
          body,
        })
      _ => ()
    }
  }
  out
}

///|
/// The declaration `name` in `decls`, preferring one declared on `owner`.
fn find_decl(decls : Array[FnDecl], name : String, owner : String) -> FnDecl? {
  if owner != "" {
    for decl in decls {
      if decl.name == name && decl.owner == owner {
        return Some(decl)
      }
    }
  }
  for decl in decls {
    if decl.name == name && decl.owner == "" {
      return Some(decl)
    }
  }
  for decl in decls {
    if decl.name == name {
      return Some(decl)
    }
  }
  None
}

// ---------------------------------------------------------------------------
// Call discovery
// ---------------------------------------------------------------------------

///|
/// A call found in a body, with everything the argument mapping needs.
priv struct CallAt {
  callee : String
  owner : String
  /// `x.m(...)` — the receiver is the implicit first argument, so a `self`
  /// parameter is already supplied.
  dot : Bool
  args : Array[@syntax.Argument]
}

///|
/// Collects the outermost call that starts on `line`.
///
/// The visitor sees a call before its arguments, so the first match is the
/// outermost one: for `f(g(x))` on one line the answer is `f`, whose argument
/// text is `g(x)` — the call the user pointed at.
priv struct CallFinder {
  line : Int32
  found : Array[CallAt]
}

///|
extend CallFinder with @syntax.IterVisitor::{ base }

///|
impl @syntax.IterVisitor for CallFinder with fn visit_Expr_Apply(
  env,
  func~,
  args~,
  loc~,
) {
  if env.found.length() == 0 && loc.start.lnum == env.line {
    let (callee, owner) = match func {
      Ident(id~, ..) =>
        match id.name {
          Ident(name~) => (name, "")
          // `@pkg.f(...)` names a function of another package; its parameters
          // are not in this source, so only the arguments can be reported.
          Dot(..) => ("", "")
        }
      Method(type_name~, method_name~, ..) =>
        (method_name.name, type_name_of_decl(type_name))
      _ => ("", "")
    }
    env.found.push(CallAt::{ callee, owner, dot: false, args: args.to_array() })
  }
  @syntax.IterVisitor::visit_Expr_Apply(env.base(), func~, args~, loc~)
}

///|
impl @syntax.IterVisitor for CallFinder with fn visit_Expr_DotApply(
  env,
  self~,
  method_name~,
  args~,
  return_self~,
  loc~,
) {
  if env.found.length() == 0 && loc.start.lnum == env.line {
    env.found.push(CallAt::{
      callee: method_name.name,
      owner: "",
      dot: true,
      args: args.to_array(),
    })
  }
  @syntax.IterVisitor::visit_Expr_DotApply(
    env.base(), self~, method_name~, args~, return_self~, loc~,
  )
}

// ---------------------------------------------------------------------------
// Source text
// ---------------------------------------------------------------------------

///|
fn is_space_char(ch : Char) -> Bool {
  ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

///|
fn trim_space(text : String) -> String {
  let chars : Array[Char] = []
  for ch in text.iter() {
    chars.push(ch)
  }
  let mut start = 0
  let mut stop = chars.length()
  while start < stop && is_space_char(chars[start]) {
    start = start + 1
  }
  while stop > start && is_space_char(chars[stop - 1]) {
    stop = stop - 1
  }
  let out = StringBuilder()
  let mut i = start
  while i < stop {
    out.write_char(chars[i])
    i = i + 1
  }
  out.to_string()
}

///|
/// Source text between two positions. Columns are 1-based code-point columns,
/// which is what `Position::column()` reports, so a comment or an identifier
/// written in a non-ASCII script does not shift the answer.
fn text_between(
  source : String,
  start_line : Int32,
  start_col : Int32,
  end_line : Int32,
  end_col : Int32,
) -> String {
  let out = StringBuilder()
  let mut line : Int32 = 1
  let mut col : Int32 = 1
  for ch in source.iter() {
    if ch == '\n' {
      if line >= start_line && line < end_line {
        out.write_char('\n')
      }
      line = line + 1
      col = 1
      continue
    }
    let after_start = line > start_line || (line == start_line && col >= start_col)
    let before_end = line < end_line || (line == end_line && col < end_col)
    if after_start && before_end {
      out.write_char(ch)
    }
    col = col + 1
  }
  trim_space(out.to_string())
}

///|
/// The argument's own source text and start line.
fn argument_text(source : String, arg : @syntax.Argument) -> (String, Int32) {
  let loc = arg.value.loc()
  let text = text_between(
    source,
    loc.start.lnum,
    loc.start.column(),
    loc.end.lnum,
    loc.end.column(),
  )
  (text, loc.start.lnum)
}

// ---------------------------------------------------------------------------
// Argument mapping
// ---------------------------------------------------------------------------

///|
/// The arguments of the call that starts on `line` inside `caller`, paired with
/// `caller`'s callee parameters.
///
/// Positional arguments fill the next positional parameter, `name=expr`
/// arguments bind by name, and every parameter the call leaves out is reported
/// with an empty `expr_text`. When the callee is not declared in `source` the
/// parameters cannot be named: every supplied argument is then reported in call
/// order with an empty `param_name`.
///
/// An empty result means the line holds no call inside `caller` — a comment, a
/// declaration, or a line the caller does not cover.
pub fn call_arguments(
  source : String,
  caller : String,
  line : Int32,
) -> Array[CallArgument] {
  let out : Array[CallArgument] = []
  let (impls, _) = @parser.parse_string(source)
  let decls = declared_functions(impls.to_array())
  let mut body : @syntax.Expr? = None
  for decl in decls {
    match body {
      None =>
        if decl.name == caller {
          body = Some(decl.body)
        }
      Some(_) => ()
    }
  }
  let expr = match body {
    None => return out
    Some(expr) => expr
  }
  let finder : CallFinder = { line, found: [] }
  @syntax.IterVisitor::visit_Expr(finder, expr)
  if finder.found.length() == 0 {
    return out
  }
  let call = finder.found[0]
  let decl = find_decl(decls, call.callee, call.owner)
  let params : Array[@syntax.Parameter] = match decl {
    Some(found) =>
      match found.params {
        Some(list) => list.to_array()
        None => []
      }
    None => []
  }
  let count = params.length()
  if count == 0 {
    // Unknown callee: report the supplied arguments in call order. The text is
    // still exact, which is all the expansion needs here.
    let mut ordinal : Int32 = 0
    for arg in call.args {
      let (text, arg_line) = argument_text(source, arg)
      out.push(CallArgument::{
        index: ordinal,
        param_name: label_of(arg.kind),
        expr_text: text,
        expr_line: arg_line,
      })
      ordinal = ordinal + 1
    }
    return out
  }
  let names : Array[String] = []
  let texts : Array[String] = []
  let lines : Array[Int32] = []
  let bindable : Array[Bool] = []
  let used : Array[Bool] = []
  let mut p = 0
  while p < count {
    match params[p] {
      Positional(binder~, ..) => {
        names.push(binder.name)
        bindable.push(true)
      }
      DiscardPositional(..) => {
        names.push("")
        bindable.push(true)
      }
      Labelled(binder~, ..) => {
        names.push(binder.name)
        bindable.push(false)
      }
      Optional(binder~, ..) => {
        names.push(binder.name)
        bindable.push(false)
      }
      QuestionOptional(binder~, ..) => {
        names.push(binder.name)
        bindable.push(false)
      }
    }
    texts.push("")
    lines.push(0)
    used.push(false)
    p = p + 1
  }
  // In a receiver call the receiver supplies `self` already; it must not be
  // filled by the first positional argument.
  if call.dot && count > 0 && names[0] == "self" {
    used[0] = true
    bindable[0] = false
  }
  let mut cursor = 0
  for arg in call.args {
    let (text, arg_line) = argument_text(source, arg)
    let mut target = -1
    match arg.kind {
      Positional => {
        let mut j = cursor
        while j < count && target < 0 {
          if bindable[j] && !used[j] {
            target = j
          }
          j = j + 1
        }
        if target >= 0 {
          cursor = target + 1
        }
      }
      Labelled(label) => target = index_of_name(names, label.name)
      LabelledPun(label) => target = index_of_name(names, label.name)
      LabelledOption(label~, ..) => target = index_of_name(names, label.name)
      LabelledOptionPun(label~, ..) => target = index_of_name(names, label.name)
    }
    if target >= 0 && !used[target] {
      used[target] = true
      texts[target] = text
      lines[target] = arg_line
    }
  }
  let mut ordinal : Int32 = 0
  let mut j = 0
  while j < count {
    if names[j] != "" {
      out.push(CallArgument::{
        index: ordinal,
        param_name: names[j],
        expr_text: texts[j],
        expr_line: lines[j],
      })
    }
    ordinal = ordinal + 1
    j = j + 1
  }
  out
}

///|
fn index_of_name(names : Array[String], name : String) -> Int {
  let mut found = -1
  let mut i = 0
  while i < names.length() {
    if found < 0 && names[i] == name {
      found = i
    }
    i = i + 1
  }
  found
}

///|
/// The label an argument carries, or `""` when it is positional.
fn label_of(kind : @syntax.ArgumentKind) -> String {
  match kind {
    Positional => ""
    Labelled(label) => label.name
    LabelledPun(label) => label.name
    LabelledOption(label~, ..) => label.name
    LabelledOptionPun(label~, ..) => label.name
  }
}

// ---------------------------------------------------------------------------
// Effect statements
// ---------------------------------------------------------------------------

///|
/// The IO-ish names recognised by default. Kept in step with
/// `@sidefx.default_io_names`: that package decides *whether* a function does
/// IO, this one decides *which statement* does it, and the two must agree.
fn io_names() -> Array[String] {
  [
    "println",
    "print",
    "eprintln",
    "eprint",
    "flush",
    "flush_stdout",
    "flush_stderr",
    "read",
    "write",
    "read_line",
    "write_line",
    "read_to_string",
    "write_string",
    "read_file",
    "write_file",
    "open_file",
    "open",
    "close",
    "connect",
    "listen",
    "accept",
    "socket",
    "send",
    "recv",
    "http_get",
    "http_post",
    "http_request",
    "sleep",
    "now",
    "random",
  ]
}

///|
fn is_panic_name(name : String) -> Bool {
  name == "panic" || name == "fail" || name == "abort" || name == "unreachable"
}

///|
/// A callee written in UpperCamelCase is a constructor application, not a call:
/// MoonBit names functions in snake case and data constructors in UpperCamel,
/// and `raise Failure("x")` / `Some(v)` are the common sightings. Recording one
/// as a call would make an unknown name look like a boundary and force the
/// expansion back to the whole body.
fn is_constructor_name(name : String) -> Bool {
  for ch in name.iter() {
    let code = ch.to_int()
    return code >= 'A'.to_int() && code <= 'Z'.to_int()
  }
  false
}

///|
fn note_call(lines : EffectLines, name : String, line : Int32) -> Unit {
  if is_constructor_name(name) {
    return
  }
  lines.calls.push(EffectCall::{ line, name })
  if io_names().contains(name) {
    lines.io.push(line)
  }
  if is_panic_name(name) {
    lines.raises.push(line)
  }
}

///|
priv struct FxLines {
  lines : EffectLines
}

///|
extend FxLines with @syntax.IterVisitor::{ base }

///|
impl @syntax.IterVisitor for FxLines with fn visit_Expr_Mutate(
  env,
  record~,
  accessor~,
  field~,
  augmented_by~,
  loc~,
) {
  env.lines.writes.push(loc.start.lnum)
  @syntax.IterVisitor::visit_Expr_Mutate(
    env.base(), record~, accessor~, field~, augmented_by~, loc~,
  )
}

///|
impl @syntax.IterVisitor for FxLines with fn visit_Expr_ArraySet(
  env,
  array~,
  index~,
  value~,
  loc~,
) {
  env.lines.writes.push(loc.start.lnum)
  @syntax.IterVisitor::visit_Expr_ArraySet(env.base(), array~, index~, value~, loc~)
}

///|
impl @syntax.IterVisitor for FxLines with fn visit_Expr_ArrayAugmentedSet(
  env,
  op~,
  array~,
  index~,
  value~,
  loc~,
) {
  env.lines.writes.push(loc.start.lnum)
  @syntax.IterVisitor::visit_Expr_ArrayAugmentedSet(
    env.base(), op~, array~, index~, value~, loc~,
  )
}

///|
/// `self = e` replaces the receiver wholesale, which the caller observes.
impl @syntax.IterVisitor for FxLines with fn visit_Expr_Assign(
  env,
  var_~,
  expr~,
  augmented_by~,
  loc~,
) {
  let mut on_self = false
  match var_.name {
    Ident(name~) =>
      if name == "self" {
        on_self = true
      }
    Dot(id~, ..) =>
      if id == "self" {
        on_self = true
      }
  }
  if on_self {
    env.lines.writes.push(loc.start.lnum)
  }
  @syntax.IterVisitor::visit_Expr_Assign(env.base(), var_~, expr~, augmented_by~, loc~)
}

///|
impl @syntax.IterVisitor for FxLines with fn visit_Expr_Raise(
  env,
  err_value~,
  loc~,
) {
  env.lines.raises.push(loc.start.lnum)
  @syntax.IterVisitor::visit_Expr_Raise(env.base(), err_value~, loc~)
}

///|
/// `try! e` re-raises the error it meets, so the statement can leave the
/// function.
impl @syntax.IterVisitor for FxLines with fn visit_Expr_TryOperator(
  env,
  body~,
  kind~,
  try_loc~,
  loc~,
) {
  env.lines.raises.push(loc.start.lnum)
  @syntax.IterVisitor::visit_Expr_TryOperator(env.base(), body~, kind~, try_loc~, loc~)
}

///|
impl @syntax.IterVisitor for FxLines with fn visit_Expr_Apply(
  env,
  func~,
  args~,
  loc~,
) {
  match func {
    Ident(id~, ..) =>
      match id.name {
        Ident(name~) => note_call(env.lines, name, loc.start.lnum)
        // A call through a package name is a boundary: its effects are not in
        // this source and the summary cannot see them.
        Dot(..) => note_call(env.lines, "@", loc.start.lnum)
      }
    Method(type_name~, method_name~, ..) => {
      ignore(type_name)
      note_call(env.lines, method_name.name, loc.start.lnum)
    }
    // A constructor applied as a function (`Failure("x")`, `Some(v)`): it
    // allocates a value and is not an edge to any function.
    Constr(..) => ()
    // A call through a function value: the callee is not nameable.
    _ => note_call(env.lines, "", loc.start.lnum)
  }
  @syntax.IterVisitor::visit_Expr_Apply(env.base(), func~, args~, loc~)
}

///|
impl @syntax.IterVisitor for FxLines with fn visit_Expr_DotApply(
  env,
  self~,
  method_name~,
  args~,
  return_self~,
  loc~,
) {
  note_call(env.lines, method_name.name, loc.start.lnum)
  @syntax.IterVisitor::visit_Expr_DotApply(
    env.base(), self~, method_name~, args~, return_self~, loc~,
  )
}

///|
/// The observable statements of `name` in `source`.
///
/// The first declaration with that name wins, which is the same choice the
/// side-effect summary makes. An unknown name yields an empty result, which the
/// expansion reads as "nothing to add" — it never reads it as "pure".
pub fn effect_lines(source : String, name : String) -> EffectLines {
  let lines : EffectLines = { writes: [], raises: [], io: [], calls: [] }
  let (impls, _) = @parser.parse_string(source)
  let decls = declared_functions(impls.to_array())
  let mut body : @syntax.Expr? = None
  for decl in decls {
    match body {
      None =>
        if decl.name == name {
          body = Some(decl.body)
        }
      Some(_) => ()
    }
  }
  match body {
    None => ()
    Some(expr) => {
      let visitor : FxLines = FxLines::{ lines }
      @syntax.IterVisitor::visit_Expr(visitor, expr)
    }
  }
  lines
}
