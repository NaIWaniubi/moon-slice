// Side-effect summaries for MoonBit functions.
//
// A bare call statement currently pulls in the callee's whole body because the
// node IR cannot say "this function only reads a field". This package adds that
// missing level: it walks one function's AST and records the effects a slice
// cares about — which fields it reads, which it writes, whether it mutates its
// receiver, which functions it calls, whether it may raise or touch IO — and
// then closes the call graph over the package's own summaries so that `pure`
// means "transitively effect-free".
//
// The walk is deliberately conservative:
//
//   * every named field write is a write, including a compound assignment
//     (`p.x += 1`), which is also a read;
//   * assigning through `self` (`self.x = ...`, `self.items[i] = ...`, a nested
//     `self.inner.f = ...`, or `self = ...`) mutates the receiver;
//   * `raise`, `try!`, and the panic helpers (`panic`, `fail`, `abort`,
//     `unreachable`) make a function may-raise;
//   * a call to a name on the IO list makes it may-IO, and so does calling a
//     package function whose summary is may-IO;
//   * any function that lies on a call cycle is impure: a recursive body has
//     no summarisable base case.
//
// Only calls that resolve to another summary in the same batch take part in the
// closure. A call to an unknown name (a dependency, a function value, a method
// whose owner is not in the batch) does not by itself make the caller impure,
// and nothing behind it is visible to this summary.

///|
/// What one function may do when it runs.
///
/// `reads_fields` and `writes_fields` hold plain field labels, sorted and
/// deduplicated. `calls` holds the syntactic callee names (a dot call records
/// its method name), sorted and deduplicated. `pure` is the derived verdict: no
/// writes, no receiver mutation, no raise, no IO, and no call to an impure
/// function of the same batch.
pub(all) struct SideEffects {
  reads_fields : Array[String]
  writes_fields : Array[String]
  mutates_receiver : Bool
  calls : Array[String]
  may_raise : Bool
  may_io : Bool
  pure : Bool
}

///|
/// One function to summarise. `source` is any MoonBit source the parser accepts
/// (a whole file or a single `fn` item); `name` selects the declaration. An
/// empty `name` picks the only function of a single-function snippet.
pub(all) struct FnSource {
  name : String
  source : String
}

///|
/// The summary of one function, keyed by the name its declaration carries.
pub(all) struct FnSummary {
  name : String
  effects : SideEffects
}

///|
/// The IO-ish names recognised by default. Matching is exact on the callee name
/// the AST records, so `println` matches `println(...)` and a dot call records
/// only its method segment (`fs.read` records `read`). Pass a different array to
/// `summarize_package` when the project has its own convention.
pub fn default_io_names() -> Array[String] {
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
/// The raw facts the AST walk collects for one body. The two flags are arrays so
/// the visitor can set them through a by-value struct.
priv struct Facts {
  reads : Array[String]
  writes : Array[String]
  calls : Array[String]
  // [0] = mutates the receiver, [1] = contains a raise / propagating `try!`.
  flags : Array[Bool]
}

///|
fn push_once(target : Array[String], value : String) -> Unit {
  if !target.contains(value) {
    target.push(value)
  }
}

///|
/// The variable a field path starts at: `self` in `self.a.b`. Only identifiers
/// and the wrappers that do not change the base are followed.
fn root_name(expr : @syntax.Expr) -> String? {
  match expr {
    @syntax.Expr::Ident(id~, ..) =>
      match id.name {
        @syntax.LongIdent::Ident(name~) => Some(name)
        @syntax.LongIdent::Dot(..) => None
      }
    @syntax.Expr::Field(record~, ..) => root_name(record)
    @syntax.Expr::Group(expr~, ..) => root_name(expr)
    @syntax.Expr::Constraint(expr~, ..) => root_name(expr)
    @syntax.Expr::As(expr~, ..) => root_name(expr)
    _ => None
  }
}

///|
fn is_receiver(expr : @syntax.Expr) -> Bool {
  match root_name(expr) {
    Some(name) => name == "self"
    None => false
  }
}

///|
/// The callee named by an `Apply`. A dotted callee (`@pkg.f`) is skipped: its
/// name belongs to another package and matching it against a local summary would
/// invent an edge. A `T::f` call and a field that holds a function are recorded
/// under their last segment.
fn callee_name(expr : @syntax.Expr) -> String? {
  match expr {
    @syntax.Expr::Ident(id~, ..) =>
      match id.name {
        @syntax.LongIdent::Ident(name~) => Some(name)
        @syntax.LongIdent::Dot(..) => None
      }
    @syntax.Expr::Method(method_name~, ..) => Some(method_name.name)
    @syntax.Expr::Field(accessor~, ..) =>
      match accessor {
        @syntax.Accessor::Label(label) => Some(label.name)
        _ => None
      }
    @syntax.Expr::Group(expr~, ..) => callee_name(expr)
    _ => None
  }
}

///|
priv struct FxCollector {
  facts : Facts
}

///|
extend FxCollector with @syntax.IterVisitor::{ base }

///|
/// `x.f` in expression position is a read of `f`. The accessor's label is the
/// only recordable name; a tuple index (`pair.0`) or a newtype unwrap is not a
/// field.
impl @syntax.IterVisitor for FxCollector with fn visit_Expr_Field(
  env,
  record~,
  accessor~,
  loc~,
) {
  match accessor {
    @syntax.Accessor::Label(label) => push_once(env.facts.reads, label.name)
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Field(env.base(), record~, accessor~, loc~)
}

///|
/// `x.f = e` writes `f`; `x.f += e` also reads it. A path rooted at `self`
/// mutates the receiver, which is what makes a mutating method impure even when
/// the field it touches belongs to a nested value.
impl @syntax.IterVisitor for FxCollector with fn visit_Expr_Mutate(
  env,
  record~,
  accessor~,
  field~,
  augmented_by~,
  loc~,
) {
  match accessor {
    @syntax.Accessor::Label(label) => {
      push_once(env.facts.writes, label.name)
      match augmented_by {
        Some(_) => push_once(env.facts.reads, label.name)
        None => ()
      }
    }
    _ => ()
  }
  if is_receiver(record) {
    env.facts.flags[0] = true
  }
  @syntax.IterVisitor::visit_Expr_Mutate(
    env.base(), record~, accessor~, field~, augmented_by~, loc~,
  )
}

///|
/// `self = e` replaces the receiver wholesale. Assignments to other names are
/// local rebindings and leave the receiver alone.
impl @syntax.IterVisitor for FxCollector with fn visit_Expr_Assign(
  env,
  var_~,
  expr~,
  augmented_by~,
  loc~,
) {
  match var_.name {
    @syntax.LongIdent::Ident(name~) =>
      if name == "self" {
        env.facts.flags[0] = true
      }
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Assign(env.base(), var_~, expr~, augmented_by~, loc~)
}

///|
/// `self.items[i] = e` writes through a field even though the syntactic target
/// is an array element: the receiver's observable state changes.
impl @syntax.IterVisitor for FxCollector with fn visit_Expr_ArraySet(
  env,
  array~,
  index~,
  value~,
  loc~,
) {
  if is_receiver(array) {
    env.facts.flags[0] = true
  }
  @syntax.IterVisitor::visit_Expr_ArraySet(env.base(), array~, index~, value~, loc~)
}

///|
impl @syntax.IterVisitor for FxCollector with fn visit_Expr_ArrayAugmentedSet(
  env,
  op~,
  array~,
  index~,
  value~,
  loc~,
) {
  if is_receiver(array) {
    env.facts.flags[0] = true
  }
  @syntax.IterVisitor::visit_Expr_ArrayAugmentedSet(
    env.base(), op~, array~, index~, value~, loc~,
  )
}

///|
impl @syntax.IterVisitor for FxCollector with fn visit_Expr_Apply(
  env,
  func~,
  args~,
  loc~,
) {
  match callee_name(func) {
    Some(name) => push_once(env.facts.calls, name)
    None => ()
  }
  @syntax.IterVisitor::visit_Expr_Apply(env.base(), func~, args~, loc~)
}

///|
/// `x.m(...)` is a call. The receiver's type is not known here, so the method
/// name is what the summary records; the package closure matches it against a
/// same-named declaration when there is one.
impl @syntax.IterVisitor for FxCollector with fn visit_Expr_DotApply(
  env,
  self~,
  method_name~,
  args~,
  return_self~,
  loc~,
) {
  push_once(env.facts.calls, method_name.name)
  @syntax.IterVisitor::visit_Expr_DotApply(
    env.base(), self~, method_name~, args~, return_self~, loc~,
  )
}

///|
impl @syntax.IterVisitor for FxCollector with fn visit_Expr_Raise(
  env,
  err_value~,
  loc~,
) {
  env.facts.flags[1] = true
  @syntax.IterVisitor::visit_Expr_Raise(env.base(), err_value~, loc~)
}

///|
/// `try! e` re-raises the error it meets, so the surrounding function may raise.
impl @syntax.IterVisitor for FxCollector with fn visit_Expr_TryOperator(
  env,
  body~,
  kind~,
  try_loc~,
  loc~,
) {
  env.facts.flags[1] = true
  @syntax.IterVisitor::visit_Expr_TryOperator(env.base(), body~, kind~, try_loc~, loc~)
}

///|
fn collect_facts(body : @syntax.Expr) -> Facts {
  let facts : Facts = { reads: [], writes: [], calls: [], flags: [false, false] }
  let visitor : FxCollector = FxCollector::{ facts: facts }
  @syntax.IterVisitor::visit_Expr(visitor, body)
  facts
}

///|
/// Every function declaration in one source, in source order. Free functions and
/// methods declared as `fn T::m(...)` are `TopFuncDef`s; inherent methods are
/// `TopImpl`s; views are `TopView`s. Their bodies are all `Expr`.
fn functions_in_source(source : String) -> Array[(String, @syntax.Expr)] {
  let (items, _reports) = @parser.parse_string(source)
  let out : Array[(String, @syntax.Expr)] = []
  for item in items {
    match item {
      @syntax.Impl::TopFuncDef(fun_decl=decl, decl_body=body, ..) =>
        match body {
          @syntax.DeclBody::DeclBody(expr~) => out.push((decl.name.name, expr))
          _ => ()
        }
      @syntax.Impl::TopImpl(method_name~, body~, ..) =>
        match body {
          @syntax.DeclBody::DeclBody(expr~) => out.push((method_name.name, expr))
          _ => ()
        }
      @syntax.Impl::TopView(view_func_name~, body~, ..) =>
        out.push((view_func_name.name, body))
      _ => ()
    }
  }
  out
}

///|
/// The facts of the function `wanted` in `source`. An empty `wanted` picks the
/// only function of a single-function snippet, which is how `summarize_source`
/// is used on a `fn foo() { ... }` fragment. The declared name is returned so
/// the summary is keyed by what callers actually write.
fn facts_of(source : String, wanted : String) -> (String, Facts)? {
  let found = functions_in_source(source)
  let mut chosen : (String, @syntax.Expr)? = None
  for pair in found {
    if pair.0 == wanted {
      match chosen {
        None => chosen = Some(pair)
        Some(_) => ()
      }
    }
  }
  let selected = match chosen {
    Some(pair) => Some(pair)
    None =>
      if wanted == "" && found.length() == 1 {
        Some(found[0])
      } else {
        None
      }
  }
  match selected {
    Some(pair) => Some((pair.0, collect_facts(pair.1)))
    None => None
  }
}

///|
fn is_panic(name : String) -> Bool {
  name == "panic" || name == "fail" || name == "abort" || name == "unreachable"
}

///|
fn has_panic_call(calls : Array[String]) -> Bool {
  let mut found = false
  for name in calls {
    if is_panic(name) {
      found = true
    }
  }
  found
}

///|
fn has_io_call(calls : Array[String], io_names : Array[String]) -> Bool {
  let mut found = false
  for name in calls {
    if io_names.contains(name) {
      found = true
    }
  }
  found
}

///|
/// True when `start` can reach itself through package calls, i.e. it lies on a
/// cycle. A direct self-call counts. Calls to names outside the batch are not
/// edges, so an external function that happens to call back is not modelled.
fn on_cycle(
  start : Int,
  facts_list : Array[Facts],
  index : Map[String, Int],
) -> Bool {
  let seen : Array[Bool] = []
  let mut i = 0
  while i < facts_list.length() {
    seen.push(false)
    i = i + 1
  }
  let stack : Array[Int] = []
  for callee in facts_list[start].calls {
    match index.get(callee) {
      Some(next) =>
        if !seen[next] {
          seen[next] = true
          stack.push(next)
        }
      None => ()
    }
  }
  let mut found = false
  let mut top = stack.length() - 1
  while top >= 0 {
    let current = stack[top]
    top = top - 1
    if current == start {
      found = true
    }
    let before = stack.length()
    for callee in facts_list[current].calls {
      match index.get(callee) {
        Some(next) =>
          if !seen[next] {
            seen[next] = true
            stack.push(next)
          }
        None => ()
      }
    }
    // A push appends after the slot we just consumed, so the cursor has to jump
    // to the new tail rather than step to the old previous element.
    if stack.length() > before {
      top = stack.length() - 1
    }
  }
  found
}

///|
fn sorted(values : Array[String]) -> Array[String] {
  let out = values.copy()
  out.sort()
  out
}

///|
/// Summarise one function. The result is the fixed point over the single
/// function's own call graph, so a recursive function is conservatively impure
/// even when its body is otherwise effect-free.
pub fn summarize_source(
  source : String,
  name : String,
  io_names? : Array[String],
) -> SideEffects? {
  let io = match io_names {
    Some(names) => names
    None => default_io_names()
  }
  let summaries = summarize_package(
    [FnSource::{ name: name, source: source }],
    io_names=io,
  )
  if summaries.length() > 0 {
    Some(summaries[0].effects)
  } else {
    None
  }
}

///|
/// Summarise a batch of functions and close the call graph between them.
///
/// Purity is a fixed point: a function is impure when it writes a field, mutates
/// its receiver, may raise, may do IO, lies on a call cycle, or calls any
/// function of the batch that is impure. `may_raise` and `may_io` are closed the
/// same way, so a wrapper around `println` is may-IO and a wrapper around a
/// raising function is may-raise.
///
/// Summaries come back in input order. When two entries declare the same name,
/// the first one is the one the closure uses.
pub fn summarize_package(
  functions : Array[FnSource],
  io_names? : Array[String],
) -> Array[FnSummary] {
  let io = match io_names {
    Some(names) => names
    None => default_io_names()
  }
  let names : Array[String] = []
  let facts_list : Array[Facts] = []
  for input in functions {
    match facts_of(input.source, input.name) {
      Some(pair) => {
        names.push(pair.0)
        facts_list.push(pair.1)
      }
      None => ()
    }
  }
  let count = names.length()
  let index : Map[String, Int] = Map([])
  let mut i = 0
  while i < count {
    match index.get(names[i]) {
      Some(_) => ()
      None => index.set(names[i], i)
    }
    i = i + 1
  }
  // Local facts. `impure` starts from what the body itself does; the call cycle
  // and the closure below add what the callees do.
  let raises : Array[Bool] = []
  let ios : Array[Bool] = []
  let impure : Array[Bool] = []
  i = 0
  while i < count {
    let facts = facts_list[i]
    let local_raise = facts.flags[1] || has_panic_call(facts.calls)
    let local_io = has_io_call(facts.calls, io)
    raises.push(local_raise)
    ios.push(local_io)
    impure.push(
      local_raise ||
      local_io ||
      facts.flags[0] ||
      facts.writes.length() > 0 ||
      on_cycle(i, facts_list, index),
    )
    i = i + 1
  }
  // Least fixed point over the call edges. All the flags only ever turn on, so
  // the loop terminates after at most one full round per flag.
  let changed : Array[Bool] = [true]
  while changed[0] {
    changed[0] = false
    let mut caller = 0
    while caller < count {
      for callee in facts_list[caller].calls {
        match index.get(callee) {
          Some(target) => {
            if raises[target] && !raises[caller] {
              raises[caller] = true
              changed[0] = true
            }
            if ios[target] && !ios[caller] {
              ios[caller] = true
              changed[0] = true
            }
            if impure[target] && !impure[caller] {
              impure[caller] = true
              changed[0] = true
            }
          }
          None => ()
        }
      }
      caller = caller + 1
    }
  }
  let out : Array[FnSummary] = []
  i = 0
  while i < count {
    let facts = facts_list[i]
    out.push(FnSummary::{
      name: names[i],
      effects: SideEffects::{
        reads_fields: sorted(facts.reads),
        writes_fields: sorted(facts.writes),
        mutates_receiver: facts.flags[0],
        calls: sorted(facts.calls),
        may_raise: raises[i],
        may_io: ios[i],
        pure: !impure[i],
      },
    })
    i = i + 1
  }
  out
}
