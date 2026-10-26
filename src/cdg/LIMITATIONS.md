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
