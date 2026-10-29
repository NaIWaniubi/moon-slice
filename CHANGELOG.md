# Changelog

## 0.5.0 — 2026-10-29

CI-facing output and tree-scale scanning. The tool now answers a reviewing
team's two questions with commands they can put in a workflow.

- **`dead --dir D`.** One process scans every `.mbt` file under a tree,
  skipping `.git`, `_build`, `target`, `.mooncakes` and `node_modules`. Parse
  failures are reported per file and do not abort the scan. On
  `moonbitlang/x` (166 files) the batch takes about 1.0 s, against 99 s for the
  old per-file process loop.
- **SARIF 2.1.0.** `dead --format sarif` emits one run with `dead-store` and
  `unreachable-code` rules, artifact locations, and stable partial fingerprints,
  ready for `github/codeql-action/upload-sarif`.
- **Baselines.** `--write-baseline FILE` records `path:line`; `--baseline FILE`
  hides those findings and reports how many it hid (`suppressed` in JSON).
  `--fail-on-findings` exits 1 only for findings that survive, so a repository
  can adopt the gate without fixing its history first.
- **`--out FILE` for `dead`**, in text, JSON and SARIF modes.
- **`action.yml` and `templates/review-workflow.yml`.** A composite action
  builds the pinned tag and runs `review` or `dead`; the template wires both a
  pull-request impact report and a SARIF upload.
- **Real-commit review case study.** On `moonbitlang/x@4705764`, 15 changed
  lines reach 40 lines across 6 functions in `duration.mbt` and 4 in
  `period.mbt`; the test files correctly reach 0. See `docs/CASE_STUDY.md`.
- **256 tests**, including scan-path normalisation, SARIF shape, and the
  directory-mode CLI end to end.

## 0.4.2 — 2026-10-29

Real-world validation and the `review` command. Numbers and commands are in
`docs/CASE_STUDY.md`; Chinese entry point in `README.zh-CN.md`.

- **`review --diff FILE` / `tools/review.sh`.** Forward-slices every line a diff
  adds and reports the affected lines and functions. `tools/review.sh` produces
  the diff with `git diff -U0`, so the analysis itself stays process-free and
  testable; `cli_smoke.sh` covers a synthetic diff end to end.
- **Validation against real code.** `tools/scan.mjs` runs `dead` over a source
  tree and reports parse failures and hits. On moonbitlang/async (368 files,
  50,233 lines) and moonbitlang/x (166 files, 37,595 lines): 100% parse success,
  0 dead-code hits. On moon-slice itself: 50 files, 9,712 lines, 7 hits, all
  verified true positives in the example corpus.
- **Six false-positive classes found by that scan and fixed**, each with a
  regression in `src/integration_test/real_world_test.mbt`:
  writes through parameters; field / read-modify-write stores; identifiers read
  only by a string interpolation; the C-style `for` update being orphaned in the
  CFG; the C-style `for` initialiser re-running on every iteration; structural
  containers reported as unreachable code. A seventh fix covers variables
  captured by a local closure (recorded as uses of the function exit).
- **`README.zh-CN.md`** is the Chinese entry point: quickstart, the three
  questions the tool answers, precision evidence, and the honest limits.

## 0.4.1 — 2026-10-29

Fixes from an adversarial review that simulated a competition judge. Three
findings were real defects, not polish.

- **`impl` method bodies are now analysed.** Previously only free functions were
  lowered, so a file whose logic lived in `impl T with fn ...` produced an empty
  program and `dead` answered "no dead code" for code it never looked at. That
  is a wrong answer, not a conservative one. `TopImpl` and `TopView` are lowered
  as functions, with `self` as an ordinary parameter.
- **The interprocedural argument filter is removed.** The previous version
  inferred argument count from identifier uses, so `add(1, 2)` looked like a
  zero-argument call and the whole callee was dropped — an under-approximation.
  The deeper problem is that any positional filter is unsound for MoonBit:
  omitted parameters may have defaults, and labelled arguments need not be in
  declaration order. `expand_calls` is back to the whole return cone, which
  cannot under-approximate. `docs/ALGORITHMS.md` explains why.
- **`path` follows data edges only.** It used to traverse control edges too, so
  `path --from o --to v` could report "o flows into v" through an `if`
  condition, a false positive for a taint-style user. `--with-control` restores
  the old search.
- **The property suite's closure check is real.** It previously asserted only
  that the slice was non-empty; it now verifies that every node in a backward
  slice can reach the criterion using only nodes in the slice.
- **Report generation is linear.** The HTML source block used per-line string
  concatenation and a linear membership scan, so an 8,000-line file took about
  15 s. `StringBuilder` plus a set brings it to about 0.5 s.
- **Sparse node ids no longer mis-index.** `cfg`, `defuse` and the report rows
  looked nodes up by array position; a hand-built `Program` with id gaps would
  read the wrong node or panic. They index by declared id now, and the SVG
  refuses to draw (instead of drawing the wrong graph) when ids are not dense.
- **The playground caches the engine.** Each click used to request
  `moon-slice.js?run=N`, so the 10 MB bundle was re-downloaded every time. A
  stable URL keeps the fresh-iframe isolation and lets the browser cache it.
- **`--precise` and `compare` are discoverable.** Both were reachable but
  missing from `help`. `compare` shows the structural vs precise control-edge
  difference directly (18 vs 7 on `bench/precise_cdg.mbt`).
- **Docs re-synced.** Test counts, the stale `docs/report.html`, the demo's
  nonexistent `/tmp` input, and the "exact for the structured subset" claim
  (contradicted by its own LIMITATIONS) are corrected.

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
