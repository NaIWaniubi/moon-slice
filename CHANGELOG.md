# Changelog

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
