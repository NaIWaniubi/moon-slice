// Parser adapter: MoonBit source text -> frozen @core.Program IR.
//
// The MoonBit AST is continuation-shaped: `let`, `if`, `while`, ... each carry a
// `body` continuation holding the rest of the enclosing block. A statement list
// is therefore flattened into *sibling* nodes instead of nested ones, so that
// `SNode.children` never mixes "rest of the block" with "code nested inside me".
//
// Branching constructs are encoded as a head node plus one region node per body:
//
//     head node     kind = the construct, uses = condition / scrutinee / guards
//     region node   kind = the construct, loc = the construct's Loc,
//                   defs = pattern binders for `match` cases and nothing else,
//                   uses = nothing, children = the statements of that body
//
// `head.children` is ordered and positional, which is how the CFG tells the
// bodies apart:
//
//     If     [then-region, else-region?]
//     While  [body-region, else-region?]
//     For    [body-region, else-region?]
//     Match  [case0-region, case1-region, ...]
//
// A region keeps its owner's Loc, so it never introduces a source line that the
// construct does not already cover. A region carries no uses of its own except
// a `for` continue-block, which the CFG evaluates on the back edge; and no defs
// except the pattern binders of a `match` case or a `for` binder.
//
// Each function gets a synthetic entry node (kind `Expr`, `defs` = the parameter
// bindings) and a synthetic exit node, both pointing at the function's Loc.
// `FunctionInfo.entry` / `.exit` name them, and the CFG uses them as the
// function's single source and single sink.

///|
/// Mutable adapter state. The arrays are shared references, so pushing through
/// this by-value struct is visible to the caller; `scope_counter` is itself an
/// array because a scalar field would be copied on write.
priv struct Adapter {
  nodes : Array[@core.SNode]
  functions : Array[@core.FunctionInfo]
  calls : Array[@core.CallSite]
  env : Array[(String, @core.VarId)]
  // Positions in `env` for each name, so name resolution is O(1) instead of a
  // backward scan. A name can be bound several times (shadowing) and scopes are
  // popped by truncating `env`, so the stack is popped in step.
  env_pos : Map[String, Array[Int32]]
  scope_counter : Array[Int32]
  current_function : Array[String]
  // Variables read inside a local `fn` body. A closure can be called after the
  // definition that feeds it, which is outside the straight-line def-use model,
  // so these are recorded and attached to the enclosing function's exit node as
  // uses. That keeps an assignment captured only by a closure from looking dead
  // without inventing data edges between the closure body and its call sites.
  closure_captures : Array[@core.VarId]
}

///|
/// Parse `source` and lower every top-level `fn` body into `@core.Program`.
///
/// Lowered top-level items: free functions (`TopFuncDef`), methods declared as
/// `impl T with fn ...` (`TopImpl`), and views (`TopView`), each with a
/// `DeclBody` expression. Everything else (type definitions, `let` declarations,
/// tests, trait declarations) is skipped. Direct call sites are recorded
/// alongside the node IR so later passes can build a call graph and do
/// conservative inter-procedural expansion.
pub fn parse_source(source : String, name : String) -> @core.Program {
  let (impls, reports) = @parser.parse_string(source, name~)
  let ctx : Adapter = {
    nodes: [],
    functions: [],
    calls: [],
    env: [],
    env_pos: Map([]),
    scope_counter: [1],
    current_function: [""],
    closure_captures: [],
  }
  let errors : Array[String] = []
  reports.each(fn(report) {
    let pos = report.loc.start
    errors.push("\{name}:\{pos.lnum}:\{pos.column()}: \{report.msg}")
  })
  impls.each(fn(impl_) {
    match impl_ {
      TopFuncDef(fun_decl=decl, decl_body=body, ..) =>
        match body {
          DeclBody(expr=body_expr) => emit_function(ctx, decl, body_expr)
          DeclStubs(_) | DeclNone => ()
        }
      // `impl T with fn m(...) { ... }`: the method body is a real function.
      // Without this arm a file that defines all its logic in methods lowers to
      // an empty program, and `dead` reports "no dead code" for code it never
      // looked at — a wrong answer, not a conservative one.
      TopImpl(method_name=name, params=params, body=body, loc=loc, ..) =>
        match body {
          DeclBody(expr=body_expr) =>
            emit_method(ctx, name.name, params, body_expr, loc.start.lnum, loc.start.column())
          DeclStubs(_) | DeclNone => ()
        }
      // `impl T with view v(...) { ... }` has an expression body, not a
      // DeclBody, and no declared result type.
      TopView(view_func_name=name, parameters=params, body=body, loc=loc, ..) =>
        emit_method(ctx, name.name, params, body, loc.start.lnum, loc.start.column())
      _ => ()
    }
  })
  @core.Program::{
    nodes: ctx.nodes,
    functions: ctx.functions,
    calls: ctx.calls,
    errors,
  }
}

///|
fn emit_function(
  ctx : Adapter,
  fun_decl : @syntax.FunDecl,
  body : @syntax.Expr,
) -> Unit {
  // `FunDecl.loc` spans the signature only, so the body's own span is used for
  // the end. The result covers `fn` through the closing brace, which is what a
  // whole-function boundary node should report.
  let decl_loc = fun_decl.loc
  let body_loc = body.loc()
  let fn_loc : @core.Loc = {
    start_line: decl_loc.start.lnum,
    start_col: decl_loc.start.column(),
    end_line: body_loc.end.lnum,
    end_col: body_loc.end.column(),
  }
  emit_function_body(ctx, fun_decl.name.name, fun_decl.decl_params, body, fn_loc)
}

///|
/// Lower a method or view body. `loc` is the declaration's own span; the end of
/// the body is taken from the expression, so the boundary node covers the whole
/// method.
fn emit_method(
  ctx : Adapter,
  name : String,
  params : @syntax.Parameters,
  body : @syntax.Expr,
  start_line : Int32,
  start_col : Int32,
) -> Unit {
  let body_loc = body.loc()
  let fn_loc : @core.Loc = {
    start_line,
    start_col,
    end_line: body_loc.end.lnum,
    end_col: body_loc.end.column(),
  }
  emit_function_body(ctx, name, Some(params), body, fn_loc)
}

///|
/// Shared body lowering for free functions, methods and views. `params` binds
/// the names the body can see; `self` is just another parameter.
fn emit_function_body(
  ctx : Adapter,
  name : String,
  params : @syntax.Parameters?,
  body : @syntax.Expr,
  fn_loc : @core.Loc,
) -> Unit {
  ctx.current_function[0] = name
  let outer_mark = ctx.env.length()
  let param_ids : Array[@core.VarId] = []
  match params {
    Some(params) =>
      params.each(fn(param) {
        match param {
          Positional(binder~, ..) =>
            param_ids.push(bind_fresh(ctx, binder.name))
          Labelled(binder~, ..) => param_ids.push(bind_fresh(ctx, binder.name))
          Optional(binder~, ..) => param_ids.push(bind_fresh(ctx, binder.name))
          QuestionOptional(binder~, ..) =>
            param_ids.push(bind_fresh(ctx, binder.name))
          DiscardPositional(..) => ()
        }
      })
    None => ()
  }
  let entry = begin_node(
    ctx,
    @core.SNodeKind::Expr,
    fn_loc,
    param_ids,
    [],
    None,
  )
  let capture_mark = ctx.closure_captures.length()
  emit_expr(ctx, body, None)
  pop_env_to(ctx, outer_mark)
  let exit_uses : Array[@core.VarId] = []
  let mut capture = capture_mark
  while capture < ctx.closure_captures.length() {
    let variable = ctx.closure_captures[capture]
    if !exit_uses.contains(variable) {
      exit_uses.push(variable)
    }
    capture = capture + 1
  }
  ctx.closure_captures.truncate(capture_mark)
  let exit = begin_node(ctx, @core.SNodeKind::Expr, fn_loc, [], exit_uses, None)
  ctx.functions.push(@core.FunctionInfo::{
    name,
    entry: entry.id,
    exit: exit.id,
  })
  ctx.current_function[0] = ""
}

///|
fn record_call(ctx : Adapter, callee : String, loc : @core.Loc) -> Unit {
  if callee != "" && ctx.current_function[0] != "" {
    ctx.calls.push(@core.CallSite::{
      caller: ctx.current_function[0],
      callee,
      line: loc.start_line,
    })
  }
}

///|
fn record_calls_in_expr(ctx : Adapter, expr : @syntax.Expr) -> Unit {
  let collector : CallCollector = { names: [], }
  @syntax.IterVisitor::visit_Expr(collector, expr)
  collector.names.each(fn(pair) {
    // A name bound locally is a function value or a `let fn`, not a call to a
    // top-level function of the same name. Recording it would invent an edge.
    let resolved = resolve_name(ctx, pair.0)
    if resolved.scope == -1 {
      record_call(ctx, pair.0, pair.1)
    }
  })
}

///|
priv struct CallCollector {
  names : Array[(String, @core.Loc)]
}

///|
extend CallCollector with @syntax.IterVisitor::{base}

///|
impl @syntax.IterVisitor for CallCollector with fn visit_Expr_Apply(
  self,
  func~,
  args~,
  loc~,
) {
  match func {
    Ident(id~, ..) =>
      match id.name {
        Ident(name~) =>
          self.names.push((
            name,
            { start_line: loc.start.lnum, start_col: loc.start.column(), end_line: loc.end.lnum, end_col: loc.end.column() },
          ))
        // `@pkg.f(x)` is a dotted callee: it names a function of another
        // package. Recording the segment would make a local function of the
        // same name look called, so it is deliberately not recorded here.
        Dot(..) => ()
      }
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Apply(self.base(), func~, args~, loc~)
}

///|
/// `T::f(x)` is a `Method` node: a type-qualified call, which names a function
/// of that type explicitly. Recording it is what lets `callers`, the call graph
/// and the interprocedural expansion see the calls real MoonBit code makes —
/// `Duration::parse_str(str)` looked like a function nobody calls without it.
///
/// `x.f()` is a `DotApply` and is deliberately *not* recorded: the receiver's
/// type is unknown here, so attributing it to a function named `f` would invent
/// a call that does not exist. Receiver calls need type resolution, which this
/// pass does not do.
impl @syntax.IterVisitor for CallCollector with fn visit_Expr_Method(
  env,
  type_name~,
  method_name~,
  loc~,
) {
  ignore(type_name)
  ignore(loc)
  env.names.push((
    method_name.name,
    { start_line: method_name.loc.start.lnum, start_col: method_name.loc.start.column(), end_line: method_name.loc.end.lnum, end_col: method_name.loc.end.column() },
  ))
}

///|
/// Record direct calls in RHS/return position. The visitor also finds calls
/// nested inside arguments, so a statement containing `g(h(x))` records both
/// `g` and `h`.
fn record_call_in_expr(ctx : Adapter, expr : @syntax.Expr) -> Unit {
  record_calls_in_expr(ctx, expr)
}

///|
/// Lower one expression in statement position, appending zero or more sibling
/// statement nodes.
fn emit_expr(ctx : Adapter, whole : @syntax.Expr, parent : Int32?) -> Unit {
  match whole {
    // ---- statement lists --------------------------------------------------
    Sequence(exprs~, last_expr~, ..) => {
      exprs.each(fn(item) { emit_expr(ctx, item, parent) })
      emit_expr(ctx, last_expr, parent)
    }
    // A labelled block (and a plain braced arm body) is transparent for
    // statement lowering: the label is not part of the data flow.
    LabelledBlock(body~, ..) => emit_expr(ctx, body, parent)
    // `{ ... }` in expression position is a Group node around the inner
    // expression; the braces are not part of the data flow either.
    Group(expr~, ..) => emit_expr(ctx, expr, parent)
    // ---- bindings ---------------------------------------------------------
    Let(pattern=pat, expr=rhs, body=rest, ..) => {
      record_call_in_expr(ctx, rhs)
      let uses = uses_of(ctx, rhs)
      let bound : Array[String] = []
      let pattern_exprs : Array[@syntax.Expr] = []
      collect_pattern(pat, bound, pattern_exprs)
      pattern_exprs.each(fn(item) { append_uses(ctx, item, uses) })
      let node = begin_node(
        ctx,
        @core.SNodeKind::Let,
        loc_from_to(whole, rhs),
        [],
        uses,
        parent,
      )
      bound.each(fn(bound_name) { node.defs.push(bind_fresh(ctx, bound_name)) })
      emit_expr(ctx, rest, parent)
    }
    LetMut(binder~, expr=rhs, body=rest, ..) => {
      record_call_in_expr(ctx, rhs)
      let uses = uses_of(ctx, rhs)
      let node = begin_node(
        ctx,
        @core.SNodeKind::LetMut,
        loc_from_to(whole, rhs),
        [],
        uses,
        parent,
      )
      node.defs.push(bind_fresh(ctx, binder.name))
      emit_expr(ctx, rest, parent)
    }
    LetFn(name~, func=local_fn, body=rest, ..) => {
      let uses = uses_of(ctx, local_fn.body)
      // The closure body may run later, so everything it reads is a use of the
      // enclosing function at its exit.
      push_unique_vars(ctx.closure_captures, uses)
      let node = begin_node(
        ctx,
        @core.SNodeKind::Let,
        loc_from_to(whole, local_fn.body),
        [],
        uses,
        parent,
      )
      node.defs.push(bind_fresh(ctx, name.name))
      emit_expr(ctx, rest, parent)
    }
    LetAnd(bindings~, body=rest, ..) => {
      let uses : Array[@core.VarId] = []
      let node = begin_node(
        ctx,
        @core.SNodeKind::Let,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      bindings.each(fn(pair) {
        append_uses(ctx, pair.2.body, node.uses)
        node.defs.push(bind_fresh(ctx, pair.0.name))
      })
      emit_expr(ctx, rest, parent)
    }
    // ---- writes -----------------------------------------------------------
    Assign(var_~, expr=rhs, augmented_by~, ..) => {
      record_call_in_expr(ctx, rhs)
      let uses = uses_of(ctx, rhs)
      let target = var_id_of(ctx, var_)
      match augmented_by {
        Some(_) => push_unique_var(uses, target)
        None => ()
      }
      let node = begin_node(
        ctx,
        @core.SNodeKind::Assign,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      node.defs.push(target)
    }
    // A field write may redefine any field of its base variable, so the base is
    // treated as (may-)defined. Reads of the base afterwards then reach here
    // rather than the previous definition.
    Mutate(record=base, field=value, ..) => {
      let node = begin_node(
        ctx,
        @core.SNodeKind::Assign,
        loc_whole(whole),
        [],
        [],
        parent,
      )
      let base_uses = uses_of(ctx, base)
      push_unique_vars(node.defs, base_uses)
      push_unique_vars(node.uses, base_uses)
      append_uses(ctx, value, node.uses)
    }
    ArraySet(array=base, index=idx, value~, ..) =>
      emit_element_write(ctx, whole, base, idx, value, parent)
    ArrayAugmentedSet(array=base, index=idx, value~, ..) =>
      emit_element_write(ctx, whole, base, idx, value, parent)
    // ---- field / element reads -------------------------------------------
    // A read through a projection is a plain `Expr` node whose uses cover the
    // base, the index and any nested reads. `uses_of` already walks the whole
    // subtree, so these arms exist to pin the shape rather than to change it.
    Field(..) | ArrayGet(..) | ArrayGetSlice(..) => {
      let uses = uses_of(ctx, whole)
      let node = begin_node(
        ctx,
        @core.SNodeKind::Expr,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      ignore(node)
    }
    // ---- leaves -----------------------------------------------------------
    Ident(id~, ..) => {
      let node = begin_node(
        ctx,
        @core.SNodeKind::Expr,
        loc_whole(whole),
        [],
        [var_id_of(ctx, id)],
        parent,
      )
      ignore(node)
    }
    Constant(..) | Hole(..) => {
      let node = begin_node(
        ctx,
        @core.SNodeKind::Expr,
        loc_whole(whole),
        [],
        [],
        parent,
      )
      ignore(node)
    }
    Unit(..) => ()
    // ---- calls ------------------------------------------------------------
    Apply(func=callee, args=call_args, ..) => {
      record_calls_in_expr(ctx, whole)
      let uses = uses_of(ctx, callee)
      call_args.each(fn(arg) { append_uses(ctx, arg.value, uses) })
      let node = begin_node(
        ctx,
        @core.SNodeKind::Call,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      ignore(node)
    }
    DotApply(self=receiver, args=call_args, ..) => {
      record_calls_in_expr(ctx, whole)
      let uses = uses_of(ctx, receiver)
      call_args.each(fn(arg) { append_uses(ctx, arg.value, uses) })
      let node = begin_node(
        ctx,
        @core.SNodeKind::Call,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      ignore(node)
    }
    // ---- jumps ------------------------------------------------------------
    Return(return_value~, ..) => {
      let uses : Array[@core.VarId] = []
      match return_value {
        Some(value) => {
          append_uses(ctx, value, uses)
          record_call_in_expr(ctx, value)
        }
        None => ()
      }
      let node = begin_node(
        ctx,
        @core.SNodeKind::Return,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      ignore(node)
    }
    Break(arg~, ..) => {
      let uses : Array[@core.VarId] = []
      match arg {
        Some(value) => append_uses(ctx, value, uses)
        None => ()
      }
      let node = begin_node(
        ctx,
        @core.SNodeKind::Break,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      ignore(node)
    }
    Continue(args~, ..) => {
      let uses : Array[@core.VarId] = []
      args.each(fn(value) { append_uses(ctx, value, uses) })
      let node = begin_node(
        ctx,
        @core.SNodeKind::Continue,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      ignore(node)
    }
    // ---- conditional branches --------------------------------------------
    If(cond~, ifso~, ifnot~, ..) => {
      let loc = loc_whole(whole)
      record_calls_in_expr(ctx, cond)
      let head = begin_node(
        ctx,
        @core.SNodeKind::If,
        loc,
        [],
        uses_of(ctx, cond),
        parent,
      )
      emit_branch(ctx, head, @core.SNodeKind::If, ifso)
      match ifnot {
        Some(branch) => emit_branch(ctx, head, @core.SNodeKind::If, branch)
        None => ()
      }
    }
    Guard(cond~, otherwise~, body=rest, ..) => {
      let loc = loc_whole(whole)
      record_calls_in_expr(ctx, cond)
      let head = begin_node(
        ctx,
        @core.SNodeKind::If,
        loc,
        [],
        uses_of(ctx, cond),
        parent,
      )
      // A guard's successful continuation is the first branch; its `else`
      // body is a real alternate branch and must remain visible to CFG/PDG.
      emit_branch(ctx, head, @core.SNodeKind::If, rest)
      match otherwise {
        Some(branch) => emit_branch(ctx, head, @core.SNodeKind::If, branch)
        None => ()
      }
    }
    // ---- loops ------------------------------------------------------------
    While(loop_cond~, loop_body~, while_else~, ..) => {
      let loc = loc_whole(whole)
      record_calls_in_expr(ctx, loop_cond)
      let head = begin_node(
        ctx,
        @core.SNodeKind::While,
        loc,
        [],
        uses_of(ctx, loop_cond),
        parent,
      )
      emit_branch(ctx, head, @core.SNodeKind::While, loop_body)
      match while_else {
        Some(branch) => emit_branch(ctx, head, @core.SNodeKind::While, branch)
        None => ()
      }
    }
    For(binders~, condition~, continue_block~, body=loop_body, for_else~, ..) => {
      let loc = loc_whole(whole)
      // A C-style `for i = 0; cond; i = i + 1` initialiser runs **once**, before
      // the loop. Modelling it as a definition on the loop head made the head
      // re-run the initialiser on every iteration, which (a) hid the update's
      // definition behind it — the body's `i` then reached the initialiser
      // instead of `i = i + 1` — and (b) left the update node unreachable, so
      // `dead` reported the increment. The initialiser is therefore a real
      // assignment emitted before the head, and the head defines nothing.
      binders.each(fn(pair) {
        let initial = uses_of(ctx, pair.1)
        record_calls_in_expr(ctx, pair.1)
        let node = begin_node(
          ctx,
          @core.SNodeKind::Assign,
          loc_whole(pair.1),
          [],
          initial,
          parent,
        )
        node.defs.push(bind_fresh(ctx, pair.0.name))
      })
      let head = begin_node(ctx, @core.SNodeKind::For, loc, [], [], parent)
      match condition {
        Some(cond) => {
          record_calls_in_expr(ctx, cond)
          append_uses(ctx, cond, head.uses)
        }
        None => ()
      }
      let mark = ctx.env.length()
      let region = begin_region(ctx, head, @core.SNodeKind::For)
      emit_into_region(ctx, region, loop_body)
      emit_loop_updates(ctx, region, head, continue_block)
      pop_env_to(ctx, mark)
      match for_else {
        Some(branch) => emit_branch(ctx, head, @core.SNodeKind::For, branch)
        None => ()
      }
    }
    ForEach(
      patterns~,
      expr=iterated,
      init~,
      continue_block~,
      body=loop_body,
      else_block~,
      ..
    ) => {
      let loc = loc_whole(whole)
      record_calls_in_expr(ctx, iterated)
      let uses = uses_of(ctx, iterated)
      init.each(fn(pair) { append_uses(ctx, pair.1, uses) })
      continue_block.each(fn(pair) { append_uses(ctx, pair.1, uses) })
      let head = begin_node(ctx, @core.SNodeKind::For, loc, [], uses, parent)
      let mark = ctx.env.length()
      let bound : Array[String] = []
      let pattern_exprs : Array[@syntax.Expr] = []
      patterns.each(fn(pat) { collect_pattern(pat, bound, pattern_exprs) })
      pattern_exprs.each(fn(item) { append_uses(ctx, item, head.uses) })
      bound.each(fn(bound_name) { head.defs.push(bind_fresh(ctx, bound_name)) })
      let region = begin_region(ctx, head, @core.SNodeKind::For)
      emit_into_region(ctx, region, loop_body)
      continue_block.each(fn(pair) { append_uses(ctx, pair.1, region.uses) })
      pop_env_to(ctx, mark)
      match else_block {
        Some(branch) => emit_branch(ctx, head, @core.SNodeKind::For, branch)
        None => ()
      }
    }
    // ---- match ------------------------------------------------------------
    Match(expr=scrutinee, cases~, ..) => {
      let loc = loc_whole(whole)
      record_calls_in_expr(ctx, scrutinee)
      let uses = uses_of(ctx, scrutinee)
      cases.each(fn(case_) {
        match case_.guard_ {
          Some(guard_) => append_uses(ctx, guard_, uses)
          None => ()
        }
      })
      let head = begin_node(ctx, @core.SNodeKind::Match, loc, [], uses, parent)
      cases.each(fn(case_) {
        let mark = ctx.env.length()
        let region = begin_region(ctx, head, @core.SNodeKind::Match)
        let bound : Array[String] = []
        let pattern_exprs : Array[@syntax.Expr] = []
        collect_pattern(case_.pattern, bound, pattern_exprs)
        pattern_exprs.each(fn(item) { append_uses(ctx, item, region.uses) })
        bound.each(fn(bound_name) {
          region.defs.push(bind_fresh(ctx, bound_name))
        })
        match case_.guard_ {
          Some(guard_) => append_uses(ctx, guard_, region.uses)
          None => ()
        }
        emit_into_region(ctx, region, case_.body)
        pop_env_to(ctx, mark)
      })
    }
    // ---- constructs with a continuation ----------------------------------
    Defer(expr=deferred, body=rest, ..) => {
      let uses = uses_of(ctx, deferred)
      let node = begin_node(
        ctx,
        @core.SNodeKind::Expr,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      ignore(node)
      emit_expr(ctx, rest, parent)
    }
    ErrDefer(expr=deferred, body=rest, ..) => {
      let uses = uses_of(ctx, deferred)
      let node = begin_node(
        ctx,
        @core.SNodeKind::Expr,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      ignore(node)
      emit_expr(ctx, rest, parent)
    }
    // ---- everything else --------------------------------------------------
    // Unsupported forms become a single `Expr` node whose uses are every
    // identifier in the subtree. That over-approximates the reads (a nested
    // `let` inside such a subtree contributes its local names as free names)
    // but never invents a definition, so it cannot create a false data edge.
    _ => {
      let uses = uses_of(ctx, whole)
      let node = begin_node(
        ctx,
        @core.SNodeKind::Expr,
        loc_whole(whole),
        [],
        uses,
        parent,
      )
      ignore(node)
    }
  }
}

///|
fn emit_element_write(
  ctx : Adapter,
  whole : @syntax.Expr,
  base : @syntax.Expr,
  index : @syntax.Expr,
  value : @syntax.Expr,
  parent : Int32?,
) -> Unit {
  let node = begin_node(
    ctx,
    @core.SNodeKind::Assign,
    loc_whole(whole),
    [],
    [],
    parent,
  )
  let base_uses = uses_of(ctx, base)
  push_unique_vars(node.defs, base_uses)
  push_unique_vars(node.uses, base_uses)
  append_uses(ctx, index, node.uses)
  append_uses(ctx, value, node.uses)
}

///|
/// Lower loop update assignments as real nodes inside a dedicated step block.
///
/// The step block is an `Expr` node with the loop head's location, holding the
/// update assignments as children. The CFG treats a non-empty `Expr` block as a
/// sequence, which lets `continue` resume at the updates instead of skipping
/// them. It carries the head's `loc`, so it never introduces a source line of
/// its own.
fn emit_loop_updates(
  ctx : Adapter,
  region : @core.SNode,
  head : @core.SNode,
  updates : @list.List[(@syntax.Binder, @syntax.Expr)],
) -> Unit {
  if updates.is_empty() {
    return
  }
  let step = begin_node(
    ctx,
    @core.SNodeKind::Expr,
    head.loc,
    [],
    [],
    Some(region.id),
  )
  region.children.push(step.id)
  updates.each(fn(pair) {
    record_calls_in_expr(ctx, pair.1)
    let node = begin_node(
      ctx,
      @core.SNodeKind::Assign,
      loc_whole(pair.1),
      [],
      uses_of(ctx, pair.1),
      Some(step.id),
    )
    node.defs.push(resolve_name(ctx, pair.0.name))
    step.children.push(node.id)
  })
}

///|
/// Append a body as a fresh region of `head`.
fn emit_branch(
  ctx : Adapter,
  head : @core.SNode,
  kind : @core.SNodeKind,
  body : @syntax.Expr,
) -> Unit {
  let mark = ctx.env.length()
  let region = begin_region(ctx, head, kind)
  emit_into_region(ctx, region, body)
  pop_env_to(ctx, mark)
}

///|
fn emit_into_region(
  ctx : Adapter,
  region : @core.SNode,
  body : @syntax.Expr,
) -> Unit {
  let start = ctx.nodes.length()
  emit_expr(ctx, body, Some(region.id))
  let mut i = start
  while i < ctx.nodes.length() {
    match ctx.nodes[i].parent {
      Some(owner) =>
        if owner == region.id {
          region.children.push(ctx.nodes[i].id)
        }
      None => ()
    }
    i = i + 1
  }
}

///|
fn begin_region(
  ctx : Adapter,
  head : @core.SNode,
  kind : @core.SNodeKind,
) -> @core.SNode {
  let region = begin_node(ctx, kind, head.loc, [], [], Some(head.id))
  head.children.push(region.id)
  region
}

///|
fn begin_node(
  ctx : Adapter,
  kind : @core.SNodeKind,
  loc : @core.Loc,
  defs : Array[@core.VarId],
  uses : Array[@core.VarId],
  parent : Int32?,
) -> @core.SNode {
  let node : @core.SNode = {
    id: ctx.nodes.length(),
    kind,
    loc,
    defs,
    uses,
    children: [],
    parent,
  }
  ctx.nodes.push(node)
  node
}

// ---------------------------------------------------------------------------
// Name resolution
// ---------------------------------------------------------------------------

///|
fn bind_fresh(ctx : Adapter, name : String) -> @core.VarId {
  let scope = ctx.scope_counter[0]
  ctx.scope_counter[0] = scope + 1
  let id : @core.VarId = { name, scope, }
  let position = ctx.env.length()
  ctx.env.push((name, id))
  match ctx.env_pos.get(name) {
    None => ctx.env_pos.set(name, [position])
    Some(stack) => stack.push(position)
  }
  id
}

///|
/// Drop bindings registered after `mark`. The per-name stacks are popped in
/// step so `resolve_name` never sees a position that is no longer in `env`.
fn pop_env_to(ctx : Adapter, mark : Int32) -> Unit {
  let mut i = ctx.env.length() - 1
  while i >= mark {
    let name = ctx.env[i].0
    match ctx.env_pos.get(name) {
      None => ()
      Some(stack) =>
        if stack.length() > 0 {
          ignore(stack.pop())
        }
    }
    i = i - 1
  }
  ctx.env.truncate(mark)
}

///|
/// Resolve to the innermost visible binding. A name with no visible binding gets
/// the reserved scope -1, which keeps `uses` faithful to the source for
/// parameters of unlowered functions or for module-level values. Such a use has
/// no definition node, so it simply contributes no data edge.
fn resolve_name(ctx : Adapter, name : String) -> @core.VarId {
  match ctx.env_pos.get(name) {
    None => { name, scope: -1, }
    Some(stack) =>
      if stack.length() == 0 {
        { name, scope: -1, }
      } else {
        ctx.env[stack[stack.length() - 1]].1
      }
  }
}

///|
fn var_id_of(ctx : Adapter, var_ : @syntax.Var) -> @core.VarId {
  match var_.name {
    Ident(name~) => resolve_name(ctx, name)
    Dot(id~, ..) => resolve_name(ctx, id)
  }
}

// ---------------------------------------------------------------------------
// Use collection
// ---------------------------------------------------------------------------

///|
fn uses_of(ctx : Adapter, expr : @syntax.Expr) -> Array[@core.VarId] {
  let out : Array[@core.VarId] = []
  identifier_names(expr).each(fn(name) {
    push_unique_var(out, resolve_name(ctx, name))
  })
  out
}

///|
fn append_uses(
  ctx : Adapter,
  expr : @syntax.Expr,
  out : Array[@core.VarId],
) -> Unit {
  push_unique_vars(out, uses_of(ctx, expr))
}

///|
fn push_unique_vars(
  out : Array[@core.VarId],
  extra : Array[@core.VarId],
) -> Unit {
  extra.each(fn(id) { push_unique_var(out, id) })
}

///|
fn push_unique_var(out : Array[@core.VarId], needle : @core.VarId) -> Unit {
  let mut i = 0
  let mut found = false
  while i < out.length() {
    if out[i] == needle {
      found = true
    }
    i = i + 1
  }
  if !found {
    out.push(needle)
  }
}

///|
/// Collects identifiers in expression position. Assignment targets and binding
/// sites are `Var` / `Binder` values rather than `Expr::Ident`, so they are not
/// reported here and a node's uses never include its own definition.
priv struct IdCollector {
  names : Array[String]
}

///|
impl @syntax.IterVisitor for IdCollector with fn visit_Expr_Ident(
  self,
  id~,
  loc~,
) {
  ignore(loc)
  match id.name {
    Ident(name~) => self.names.push(name)
    Dot(id~, ..) => self.names.push(id)
  }
}

///|
/// String interpolations carry real expressions: in `"port=\{port}"` and
/// `"%\{interface}"` the variable is read at runtime.
///
/// In this parser version the elements are `Literal` and `Source`, where
/// `Source` holds the interpolation body as source *text*; the expression is
/// not lowered into an `Expr`. Scanning identifiers out of that text is the
/// only available option, and it is conservative in the safe direction: it can
/// add a use that the expression does not really have, never drop one. Without
/// it, a binding read only by an interpolation looked unused and `dead`
/// reported it (every `"%\{x}"` in real code).
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
impl @syntax.IterVisitor for IdCollector with fn visit_Expr_Interp(
  self,
  elems~,
  loc~,
) {
  ignore(loc)
  elems.each(fn(elem) {
    match elem {
      Literal(..) => ()
      Expr(expr~, ..) => @syntax.IterVisitor::visit_Expr(self, expr)
      Source(source) => collect_source_identifiers(source.source, self.names)
    }
  })
}

///|
fn identifier_names(expr : @syntax.Expr) -> Array[String] {
  let collector : IdCollector = { names: [], }
  @syntax.IterVisitor::visit_Expr(collector, expr)
  collector.names
}

// ---------------------------------------------------------------------------
// Pattern binders
// ---------------------------------------------------------------------------

///|
fn collect_pattern(
  pattern : @syntax.Pattern,
  names : Array[String],
  exprs : Array[@syntax.Expr],
) -> Unit {
  match pattern {
    Var(binder) => names.push(binder.name)
    Alias(pat~, alias_~, ..) => {
      collect_pattern(pat, names, exprs)
      names.push(alias_.name)
    }
    Tuple(pats~, ..) =>
      pats.each(fn(item) { collect_pattern(item, names, exprs) })
    Array(pats~, ..) =>
      match pats {
        Closed(items) =>
          items.each(fn(item) { collect_array_pattern(item, names, exprs) })
        Open(before, after, dotdot) => {
          before.each(fn(item) { collect_array_pattern(item, names, exprs) })
          after.each(fn(item) { collect_array_pattern(item, names, exprs) })
          match dotdot {
            Binder(binder) => names.push(binder.name)
            BinderAs(binder) => names.push(binder.name)
            Underscore | NoBinder => ()
          }
        }
      }
    Record(fields~, ..) =>
      fields.each(fn(field) { collect_pattern(field.pattern, names, exprs) })
    Constr(args~, ..) =>
      match args {
        Some(items) =>
          items.each(fn(item) { collect_pattern(item.pat, names, exprs) })
        None => ()
      }
    Or(pat1~, pat2~, ..) => {
      collect_pattern(pat1, names, exprs)
      collect_pattern(pat2, names, exprs)
    }
    Constraint(pat~, ..) => collect_pattern(pat, names, exprs)
    Range(lhs~, rhs~, ..) => {
      collect_pattern(lhs, names, exprs)
      collect_pattern(rhs, names, exprs)
    }
    With(pat~, bindings~, ..) => {
      collect_pattern(pat, names, exprs)
      bindings.each(fn(pair) { exprs.push(pair.1) })
    }
    Map(elems~, ..) =>
      elems.each(fn(elem) { collect_pattern(elem.pat, names, exprs) })
    SpecialConstr(binder~, args~, ..) => {
      names.push(binder.name)
      args.each(fn(item) { collect_pattern(item.pat, names, exprs) })
    }
    Any(..) | Constant(..) | ConstrAny(..) | ConstrUnknown(..) => ()
  }
}

///|
fn collect_array_pattern(
  item : @syntax.ArrayPattern,
  names : Array[String],
  exprs : Array[@syntax.Expr],
) -> Unit {
  match item {
    Pattern(pattern) => collect_pattern(pattern, names, exprs)
    ConstSpread(binder~, ..) => names.push(binder.name)
    StringSpread(..) | BytesSpread(..) => ()
  }
}

// ---------------------------------------------------------------------------
// Locations
// ---------------------------------------------------------------------------

///|
fn loc_whole(expr : @syntax.Expr) -> @core.Loc {
  loc_from_to(expr, expr)
}

///|
/// Span from the head's start to the tail's end. Used where the parser's Loc for
/// a node also covers its continuation (`let`, `let mut`, local `fn`), which
/// would make a one-line statement appear to span the rest of the block.
fn loc_from_to(head : @syntax.Expr, tail : @syntax.Expr) -> @core.Loc {
  let start = head.loc().start
  let stop = tail.loc().end
  {
    start_line: start.lnum,
    start_col: start.column(),
    end_line: stop.lnum,
    end_col: stop.column(),
  }
}
