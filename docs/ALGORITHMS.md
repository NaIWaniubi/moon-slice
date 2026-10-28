# Algorithms

This document is the technical map of `moon-slice`; it is written for a reader
who wants to verify the claims in the README rather than take them on faith.

## Pipeline

```text
MoonBit source
  └─ @parser.parse_string            (official moonbitlang/parser)
       └─ parser adapter             AST → @core.Program (SNode IR)
            └─ CFG                   sequence / branch / loop / jump edges
                 └─ def-use          reaching definitions
                      └─ CDG         structured control dependence
                           └─ PDG    data edges + control edges
                                └─ slice   backward / forward BFS
                                     └─ report  JSON / DOT / SVG / HTML
```

Each package consumes only the previous stage's public types, so it can be
tested on a hand-built input. The shared types live in `src/core/types.mbt` and
are frozen.

## Parser adapter

The adapter walks `@syntax.Impl::TopFuncDef` / `DeclBody::DeclBody` and lowers
the MoonBit expression tree into a flat statement IR:

- `let`, `let mut`, assignment, array/field writes become `Let`/`LetMut`/
  `Assign` nodes with `defs` and `uses`.
- `if`/`while`/`for`/`match` become a head node plus one region node per body.
  The head carries the condition/scrutinee uses; the region is the parent of the
  body's statements and the definition site for match-arm binders.
- `sequence`, `labelled block`, and `group` (`{ ... }`) are transparent: their
  inner statements are lowered in place, so a match-arm assignment is a real
  `Assign` node rather than an opaque expression.
- Anything outside the modeled subset becomes one `Expr` node whose uses are all
  identifiers in the subtree. This is deliberately conservative: it can add a
  false dependence, never hide a real one.

Every function gets a synthetic entry node (parameter definitions) and a
synthetic exit node. Synthetic nodes are excluded from user-facing line sets.

## CFG

`src/cfg` adds edges for:

- sequence: statement → next statement;
- `if`: head → each region → first body statement; bodies fall through to the
  join;
- `while`/`for`: head → body → back edge to head; head → next on exit;
- `return` → exit, `break`/`continue` → the enclosing loop's exit/head;
- `match`: head → one region per case; cases fall through to the join.

The CFG is deliberately conservative: it never removes an edge a real execution
could take. Unreachable code after `return` still has no incoming edge from the
reachable prefix, which is what the `dead` command uses.

## Def-use

`src/defuse` is a forward reaching-definitions analysis over the CFG:

- facts are `(definition node, VarId)` and `(use node, VarId)`;
- `transfer` kills definitions of a variable redefined by the current node and
  adds the node's own definitions;
- the work-list seeds **every** node, not only roots. A parameterless entry has
  an empty out-state, so a change-driven work-list would never enqueue its
  successors; this was a real bug caught by the parameterless regression test.
- a field or array write defines the base variable (`p`), not `p.x`; this is a
  heap abstraction that can inflate a slice but cannot hide a dependence.

Output: sorted, deduplicated `(definition, use)` pairs.

## CDG

`src/cdg` uses structured control dependence: an `if`/`while`/`for`/`match`
condition controls every node lexically inside its branches or body, at any
depth. `return`/`break`/`continue` are handled with a CFG frontier walk that
marks the skipped region as controlled. This is exact for the structured subset
and does not require post-dominators on arbitrary irreducible CFGs.

## PDG and slicing

`src/pdg` turns def-use pairs into `Data` edges and CDG pairs into `Control`
edges, dropping self-edges and deduplicating. `src/slice` runs BFS over the
inverted graph (backward) or the forward graph (forward), seeded with the
criterion node, and returns sorted node ids plus unique sorted source lines.

The CLI maps a source line to the best statement node (`target_node`) and
filters synthetic entry/exit nodes from the displayed line set.

## Path query

`src/query::path_between` is a BFS from a set of start nodes to a set of goal
nodes with a parent map, returning the shortest directed PDG path. The CLI
`path --from A --to B` seeds starts with definitions of `A` and goals with uses
of `B`, which is the taint-lite source→sink query.

## Call graph

`src/query::call_edges` reads `Program.calls`, the direct call sites recorded
by the parser adapter. The adapter walks each statement expression, so nested
applications (`g(h(x))`) and calls in conditions are recorded too; method
labels are never recorded, because a method name is not a function in the
program. Edges are emitted only when the callee is defined in the same program,
and a recursive call is kept as a self-edge. Function values are not resolved.
The CLI `callgraph` renders the result as DOT.

## Inter-procedural expansion

`src/query::expand_calls` is a fixed-point expansion. For a value-returning
call (its caller node is a `let`/assignment/return), it adds the callee's
return-value cone computed by backward-slicing every return node, so dead stores
are excluded. For a bare call statement it adds the whole body, because side
effects are not summarized yet. The loop repeats so chains expand transitively.
Argument-to-parameter mapping and mutation summaries remain future work.
`slice --interprocedural` and `html --interprocedural` use it; the default is
intra-procedural.

## Complexity and bounds

- CFG: O(N) edges for N statements.
- Def-use: work-list to a fixed point. The lattice is finite and transfer is
  monotone, so it terminates without a round cap; worst case O(N·E) with the
  flat set representation.
- Slicing: O(V+E) per query.
- HTML SVG: truncated at 200 nodes so a huge file cannot produce a
  multi-megabyte report; the graph states that it is truncated and the metrics
  and node table still cover the full result. The DOT output has no truncation.

## Known limits

- Intra-procedural by default; `--interprocedural` adds the callee return-value
  cone for value-returning calls and the whole body for bare calls. It does not
  map arguments to parameters or summarize side effects.
- No points-to, reflection, or macro expansion; dynamic dispatch is opaque.
- Field/array writes use the base-variable abstraction.
- `dead` is definition- and reachability-based; it does not infer that a store
  is dead only because a callee never reads it.

## References

- Mark Weiser, *Program Slicing*, ICSE 1981.
- Jeanne Ferrante, Karl Ottenstein, Joe Warren, *The Program Dependence Graph
  and Its Use in Optimization*, TOPLAS 1987.
