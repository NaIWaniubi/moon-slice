# Changelog

## 0.4.0 — 2026-10-29

Precision work, driven by an attempted multi-agent run whose workers could not
authenticate; the five planned missions were implemented directly instead.

- **Post-dominator control dependence (`cdg::build_precise`).** Solves
  post-dominators per function as a backward fixed point and derives control
  dependence with the Ferrante–Ottenstein–Warren walk. Exposed as
  `--precise` on every analysis command. Measured effects: no region-to-region
  pseudo edges, and on `while { if c { return }; x = x + 1 }` the structural
  builder's 18 control edges become 7. The structural `build` stays the default,
  because it cannot under-approximate.
- **Interprocedural argument mapping.** `expand_calls` now pairs a call site's
  arguments with the callee's parameters in declaration order and drops callee
  statements whose only parameter dependencies are parameters the caller did not
  supply. `two(a, b)` called as `two(x)` no longer pulls in the `b`-only branch.
  Statements that depend on a supplied argument, or on no parameter at all,
  stay; a bare call statement still expands the whole body.
- **Machine-readable contract.** With `--json`, every failure prints
  `{"error":{"code":..,"message":..}}` and exits 2, so automation never parses
  prose. `graph --format json` emits deterministic nodes and edges. The HTML
  report carries `<meta name="generator">` and a
  `<script type="application/json" id="moon-slice-result">` block with the
  target, nodes, lines and errors.
- **Path-based precision oracle.** The independent oracle is now derived from
  the path formulation ("a definition reaches a use when some path connects
  them with no intervening redefinition") instead of a bounded walk enumeration,
  so it stays correct on nested loops where a visit bound stops too early. This
  change was itself prompted by a property-test failure.
- **Property-based differential testing.** A seeded generator produces 40
  programs from a grammar covering let/let mut/assign/if-else/while/C-style
  for/guard/return/nested blocks; each is checked for structural invariants,
  agreement with the oracle, slice closure, criterion membership, line
  projection, and interprocedural superset-ness. Failures print the seed and
  source.
- **Def-use allocation and exactness.** A visit that changes nothing no longer
  retains its candidate state, and a 2000-statement chain asserts the exact
  closed-form pair count so a future optimisation cannot drop edges silently.

## 0.3.0 — 2026-10-28

Precision and robustness pass, driven by an independent audit. Every item has a
regression test or an acceptance check.

- **Independent precision oracle.** `src/integration_test/precision_oracle_test.mbt`
  re-derives reaching definitions by enumerating bounded CFG walks and compares
  the result with the work-list analysis on 12 programs plus the whole example
  corpus. Agreement is evidence, not a restatement of the implementation.
- **Report HTML escaping.** Escaping is per character, so a second `<script>` in
  the source can no longer reach the report; `"` and `'` are escaped too.
- **Playground repeat runs.** Each run executes in a fresh hidden iframe with a
  run token, so the bundle's top-level declarations cannot collide and a stale
  run cannot overwrite a newer report. Verified in headless Chrome
  (`web/playground_e2e.mjs`).
- **Playground input protocol.** `direction\nline\nnode\nsource`; source text is
  the unparsed remainder, so sentinel-like content is preserved.
- **CLI exit codes.** Unreadable files, write failures, unknown commands or
  flags, invalid `--line`/`--direction`/`--format` and malformed sources exit 2
  without emitting a plausible result.
- **Ambiguous target lines.** `statement_candidates` reports every statement on
  a line, the CLI prints a note with the candidate ids, and `--node ID` selects
  one; an unknown id is an error. The HTML report highlights the target row and
  names the selected node in its metrics.
- **`guard ... else`** is lowered as two branches instead of dropping the else.
- **C-style `for`.** The binder is bound before the condition, the update block
  is a real node, and `continue` resumes at the update instead of skipping it.
- **Calls.** Every free-function application in a statement is recorded,
  including nested ones (`g(h(x))`) and calls in conditions; method labels are
  never recorded; a name bound locally does not fabricate an edge; recursion is
  kept as a self-edge; interprocedural expansion matches call sites by callee
  name before line.
- **Def-use** no longer has a fixed worklist round cap (the lattice is finite and
  transfer monotone), and per-node GEN/USE indexes replace global scans.
- **Query helpers** resolve nodes by id (sparse ids cannot be misread) and build
  adjacency once, so `path` and `unreachable` are O(V+E).
- **Performance.** CFG edge dedupe uses a set, name resolution uses a per-name
  stack, and DOT/JSON/HTML are built with `StringBuilder`. A 32,000-statement
  function now takes about 1.2 s for `dead`/`graph` and 2.2 s for `slice`
  (`bench/bench.mjs`, native release).
- **Report SVG.** Truncation is stated in the graph instead of silently dropping
  the target; the SVG carries `role`/`title`/`desc` and table headers have
  `scope`.
- **CI and Pages** rebuild the tracked browser bundle, fail on drift, and run the
  browser smoke test before deploying.

## 0.2.0 — 2026-10-26

- Inter-procedural expansion: return-value cone for value-returning calls,
  whole body for bare call statements; `slice --interprocedural` and
  `html --interprocedural`; `Program.calls` records direct call sites.
- Call graph from recorded call sites, including calls in `let`/assign/return.
- Data-flow path query (`path --from A --to B`).
- `dead` now unions unused definitions and unreachable statements.
- Inline-SVG HTML report with source-order layout, slice-node table and metrics.
- Deterministic fuzz-style invariant tests; 190 tests total.
- Browser playground: `src/web` compiled to JavaScript + `web/index.html`;
  prebuilt engine and `web/smoke.mjs`.
- CLI: `version`/`help`, `--json` for dead/path/callgraph, and a full CLI smoke test.
- Zero compiler warnings; docs/ALGORITHMS.md, docs/DEMO.md, CI, benchmark.
