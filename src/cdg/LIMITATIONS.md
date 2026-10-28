# Control dependence: what this implementation models

`cdg::build` is intentionally *structured*, not post-dominator based. It reads
the `parent`/`children` tree of `@core.Program` and adds control-dependence
edges directly from the syntax. That choice is deliberate for the MVP: it needs
no post-dominator tree, no reverse CFG reachability per node, and no fixpoint,
so it is cheap and easy to explain.

## What is modelled

- **Nesting.** For a control node `C` of kind `If`, `While`, `For` or `Match`,
  every node nested in `C`'s subtree (at any depth) is control dependent on `C`.
  A statement in the body of an `if` inside a `while` is therefore controlled by
  both the `If` and the `While`, which is what a classic CDG also reports for
  structured code.
- **The controller is the control node.** The `If`/`While`/`For`/`Match` node
  itself is the controller; its `uses` are expected to hold the variables of
  the condition. No separate "condition expression" node is invented.
- **Escapes, over-approximated.** A `Return` inside the subtree makes the code
  after the region control dependent on the control node: it only runs when the
  protecting branch was not taken. `Break`/`Continue` do the same, bounded by
  the enclosing loop. A loop only does this for `Return`; a loop that merely
  `break`s is left alone, because exiting the loop is its normal termination.
- **Tree-shape tolerance.** `children` links and `parent` links are merged, so a
  front end may populate either side of the tree.

## What is *not* modelled

1. **No post-dominator computation.** Edges are structural, not semantic. Two
   nodes that are mutually reachable without passing through the controller do
   not get an edge unless one is nested in the other.
2. **No loop-carried control dependence.** In a real CDG, statements in a loop
   body are control dependent on the loop condition, and statements in nested
   loops are control dependent on the outer condition in ways that post-dominator
   analysis refines. Here every body node gets a single edge from each enclosing
   loop, regardless of which iteration it may execute in.
3. **Ancestors are excluded from escape sets.** The escape walk removes every
   ancestor of the controller from its region. That is what stops a controller
   from being marked dependent on its own loop header (which would make the loop
   condition look controlled by its own body). The cost is one lost route: if
   the *only* CFG path from an escape to some later node runs backwards through
   the loop header, that node is not marked. In the common shapes the escape
   statement has a forward edge to the code it skips, so the edge is still
   found; the gap only shows up when the CFG omits that forward edge.
4. **No unreachable-code inference.** Code after an unconditional top-level
   `return` is not marked as controlled by anything; there is no controller to
   attribute it to.
5. **`cfg` is trusted for structure only.** The walk uses `cfg.edges` to find
   the frontier; if the CFG omits an edge, the corresponding escape edge is
   missing. If the CFG contains edges across function boundaries, the walk
   follows them, so `cfg` is expected to be per-function.
6. **One `FunctionInfo` is not consulted.** Function boundaries are respected by
   the CFG, not by this module: `program.functions` is ignored.
7. **`switch`/`match` arms are flat.** All arms are children of the `Match`
   node; there is no per-arm guard modelling, so every node in every arm is
   controlled by the `Match` node.

## Why this is acceptable here

The tool's job is to answer "which statements may have produced this value" and
"which statements may this value affect". For that, an over-approximation is
usable: it never hides a real dependence, it only adds extra ones. The
limitations above are reported honestly in the README and in the CLI output,
rather than papered over.

## Precise mode: `build_precise`

`cdg::build_precise(program, cfg)` computes control dependence from the CFG
alone, using the classic Ferrante–Ottenstein–Warren definition:

> `Y` is control dependent on `X` when one successor of `X` post-dominates `Y`
> and another does not.

Post-dominators are solved as a backward fixed point per function:
`pdom[exit] = {exit}`, `pdom[n] = {n} ∪ ⋂ pdom[succ(n)]`. The walk then starts
at each successor that does not post-dominate `X` and climbs the post-dominator
tree until the immediate post-dominator of `X`.

What it buys, measured on the shipped examples:

- **No region-to-region edges.** `if c { x = 1 } else { x = 2 }` produces the
  structural edges `head -> region` (correct) plus `region -> other region`
  (impossible: a region has one CFG successor). Precise mode keeps only the
  former.
- **Fewer pseudo-controllers.** On `while { if c { return } ; x = x + 1 }` the
  structural builder emits 18 control edges, many of them "loop head controls
  the exit" or "inner if controls the loop head". Precise mode emits 7.
- **Loop-carried edges the syntax cannot express.** When a branch inside a loop
  can jump back to the loop head on one path and leave on another, the head is
  control dependent on that branch. The tree alone cannot say this.

What it still does not model:

- Interprocedural control dependence (each function is analysed on its own).
- Exception edges: `raise`/`try` are not CFG edges here, so their control
  dependence is not modelled by either builder.
- A CFG that omits per-function boundaries: precise mode falls back to whatever
  the edges imply and may report nothing.

`build` remains the default. It never depends on post-dominators, so it cannot
under-approximate; every edge it adds is either a real structural dependence or
a deliberate over-approximation. Use `build_precise` when you want the exact
answer for a well-formed CFG, and `build` when you want the conservative one.
