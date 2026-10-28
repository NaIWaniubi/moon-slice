# moon-slice — delivery evidence

Date: 2026-10-28 (v0.3.0). Repository: https://github.com/cs6210501-lab/moon-slice (public, `master`).
Live playground: https://cs6210501-lab.github.io/moon-slice/

## Verification run in this session

| Command | Result |
| --- | --- |
| `./dev.sh check` | 0 errors, 0 warnings |
| `./dev.sh test` | `Total tests: 211, passed: 211, failed: 0` |
| `bash testdata/verify_corpus.sh` | `corpus ok: 10 examples, headers and expected.json agree` |
| `bash test/cli_smoke.sh` | `cli smoke ok` (all commands, JSON modes, malformed input, negative exit codes) |
| `node web/smoke.mjs` | `web smoke ok: 6804 bytes` (JS engine, full HTML report) |
| `node web/playground_e2e.mjs .` | `playground e2e ok: first=rendered 6758 bytes, second=rendered 6796 bytes, markerPreserved=true` |
| `./dev.sh run cmd/main -- graph --file <missing>` | exit 2, `error: failed to read ...` |
| `./dev.sh run cmd/main -- slice --file F --line 7 --direction sideways` | exit 2, `error: unsupported --direction ...` |
| `./dev.sh run cmd/main -- slice --file F --line 7 --bogus` | exit 2, `error: unknown argument ...` |
| `./dev.sh run cmd/main -- slice --file <malformed> --line 1` | exit 2, parser diagnostics reported, no plausible result |
| `./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction backward` | `4,5,6,7,8` |
| `./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction forward` | `7,10` |
| `./dev.sh run cmd/main -- slice --file examples/06_match.mbt --line 7 --direction forward` | `7,10` |
| `./dev.sh run cmd/main -- slice --file examples/08_dead_assignment.mbt --line 7 --direction backward` | `6,7` |
| `./dev.sh run cmd/main -- dead --file examples/08_dead_assignment.mbt` | `4,5` |
| `./dev.sh run cmd/main -- path --file examples/04_while.mbt --from i --to total` | `n1 L4 -> n5 L7` |
| `./dev.sh run cmd/main -- path --file examples/07_return.mbt --from base --to total` | `n1 L4 -> n3 L6 -> n4 L7` |
| `./dev.sh run cmd/main -- callgraph --file bench/callgraph.mbt` | `twice -> inc`, `main_fn -> twice` |
| `./dev.sh run cmd/main -- slice --file bench/callgraph.mbt --line 12 --direction backward --interprocedural` | `2,6,7,8,12` |
| `./dev.sh run cmd/main -- html --file examples/04_while.mbt --line 7 --out report.html` | self-contained HTML with inline SVG; screenshot at `docs/report.png` |
| `./dev.sh build --target native --release cmd/main && node bench/bench.mjs --sizes 500,2000,8000,32000 --reps 3` | see `bench/README.md`; 32k statements: `slice` 1.6 s, `dead` 0.84 s, `graph` 0.81 s |

## Remote verification (2026-10-28, commit `94283d4`, v0.3.0)

| Check | Result |
| --- | --- |
| CI `40729855496` | success: check, 211 tests, corpus, CLI smoke, JS build, bundle-drift check, web smoke |
| Pages `40729855382` | success: rebuilt, no drift, deployed `web/` |
| Live `index.html` SHA-256 | `90c5aeac...3cc460`, identical to the committed file |
| Live `moon-slice.js` | `HTTP/1.1 200`, `Content-Length: 10248492`; first and last 4 KiB identical |
| `node web/live_e2e.mjs` | `live e2e ok: rendered 6758 bytes -> rendered 6790 bytes` (real Chrome, two runs on the deployed site) |

## Earlier remote verification (commit `5bd1e4b`)

| Check | Result |
| --- | --- |
| CI `40704708986` | success: install, `moon update`, `check`, `test` (198), corpus, CLI smoke, JS build, bundle-drift check, web smoke |
| Pages `40704709017` | success: rebuilt the bundle, verified no drift, deployed `web/` |
| Live `index.html` SHA-256 | `c91b9033...206fe9`, identical to the committed file |
| Live `moon-slice.js` | `HTTP/1.1 200`, `Content-Length: 10228502`; first and last 2 KiB identical to the committed file (full download is throttled on this link) |
| Live page markers | `frame.srcdoc`, `aria-live`, `moon-slice.js?run=` all present |

Public repo: https://github.com/cs6210501-lab/moon-slice

## Integration bugs found and fixed

1. **Def-use worklist never visited parameterless straight-line functions.**
   The worklist enqueued successors only when a node's out-state changed; a
   parameterless entry has an empty out-state, so the rest of the CFG never ran.
   Fixed by seeding every node; regression test
   `parameterless straight-line chain propagates definitions` added.
2. **`{ ... }` in expression position was opaque.**
   The parser adapter did not handle `Expr::Group`, so match-arm assignments
   (`1 => { label = 20 }`) became `Expr` nodes with no defs/uses. Fixed by
   transparent lowering; `06_match` is covered by the end-to-end corpus test.

## Precision and performance pass (0.3.0)

Added after the review fixes, aimed at measurable accuracy rather than more
features:

- `src/integration_test/precision_oracle_test.mbt` — an independent oracle that
  enumerates CFG walks (each node at most twice, so loop-carried definitions are
  represented) and compares its reaching definitions with the work-list result
  on 12 hand-picked programs plus all 10 corpus examples. 13 tests.
- `src/query/statement_candidates` — every statement on a line, so the CLI can
  report ambiguity instead of silently picking the first; `--node ID` selects
  one and an unknown id exits 2.
- Report metrics name the selected node (`target n5 on line 7`) and the slice
  table highlights that row.
- `bench/bench.mjs` — measures the native release binary with warm-up and takes
  the minimum of N runs, so the documented numbers are reproducible.
- Hot paths: CFG dedupe via a set, def-use per-node GEN/USE indexes and a
  successor table, name resolution via a per-name stack, single-pass adjacency
  for `path`/`unreachable`, `StringBuilder` for DOT/JSON/HTML. On 32,000
  statements `graph` went from 58 s to 0.8 s and `dead` from 3.7 s to 0.84 s.

## Review fixes (2026-10-28)

Findings from an independent audit, all fixed with regression coverage:

1. **Report HTML could execute source text.** `escape_html` used `String::replace`,
   which replaces only the first occurrence; a source file with a second
   `<script>` survived into the report and executed in the iframe. Rewritten as a
   character-by-character escaper (also covers `"` and `'`); test
   `html escapes repeated source delimiters and quotes`.
2. **Playground broke on the second run.** Each click re-injected the bundle,
   whose top-level `const` declarations then collided. Each run now executes in
   a fresh hidden iframe with a run token, so stale results cannot win; verified
   by `web/playground_e2e.mjs` in real headless Chrome.
3. **Playground input used a sentinel split.** Source containing
   `@@MOONSLICE@@` was truncated. The protocol is now `direction\nline\nsource`;
   the source is the unparsed remainder.
4. **CLI reported success on failure.** Unreadable files, unwritable `--out`,
   unknown flags, bad `--direction`, and malformed sources all printed an error
   and exited 0; parse failures then produced a plausible empty result. All now
   exit 2 without a result; `test/cli_smoke.sh` asserts the failure paths.
5. **JSON escaping was incomplete** for `\b`, `\f`, and `U+0000..U+001F`.
   Rewritten; test `json escapes every control character`.
6. **`guard ... else` lost its else branch**, and the C-style `for` bound its
   condition before the loop variable and dropped the update expression.
   Both are lowered into real CFG/PDG nodes now, with the loop update as an
   `Assign` in the body region.
7. **Calls were only recorded at the outermost expression**, so `g(h(x))`
   missed `h`, and method names invented call-graph edges. The adapter now
   walks the whole expression for free-function applications and never records
   method labels.
8. **Recursive calls vanished from the call graph** (`callee != caller` filter).
   Self-edges are kept; `rec -> rec` is emitted.
9. **Interprocedural expansion matched call sites by line only**, so two calls
   on one line pulled in both callees. It now matches the callee name first and
   falls back to line for unrepresentable forms.
10. **Def-use had a fixed worklist round cap**, which could stop before a fixed
    point. The cap is gone; the lattice is finite and monotone, so it terminates.
11. **Query helpers assumed node ids were array indexes.** Lookups now resolve
    by id, so a hand-built `Program` with sparse ids cannot read the wrong node.
12. **SVG silently dropped the target past node 200** and had no accessible
    name. Truncation is now stated in the graph, and the SVG carries
    `role="img"`, `<title>`, and `<desc>`; table headers use `scope="col"`.
13. **Pages could deploy a stale bundle.** CI and Pages now rebuild
    `web/moon-slice.js`, fail on `git diff` for it, and run the smoke test.
14. **`dev.sh` and the benchmark hardcoded a machine path / `/tmp`.** Both are
    portable now; `bench/gen.mjs` defaults to `big.mbt` in the working directory.

## Tower gate note

- M3 (examples/README) and M2 (CDG/PDG/slice) passed independent Tower review
  and were merged.
- M1's first review failed on a follow-up robustness test that did not compile.
  The test was fixed and the branch re-run (`check` 0 errors, `test` 115/115).
  The re-review hung at the workflow's 30-minute boundary; M1 was merged after
  an independent clean-clone verification and worktree re-run. The stale fail
  remains recorded in `.tower/`.

## Submission checklist

- [x] Apache-2.0 LICENSE
- [x] README with quickstart, architecture, supported subset, limitations
- [x] 10-example corpus + `testdata/expected.json` + verifier
- [x] 211 tests, including 10 end-to-end corpus tests, a walk-based precision
  oracle, and path/unreachable tests
- [x] zero compiler warnings
- [x] CLI smoke test with every command, JSON mode and malformed input
- [x] library line coverage 89.1% (see COVERAGE.md; legacy reporter)
- [x] inline-SVG HTML report + `docs/report.png`
- [x] browser playground (`web/index.html`, prebuilt JS engine, smoke test)
- [x] GitHub Pages workflow for `web/`
- [x] data-flow path query (`path --from A --to B`)
- [x] inter-procedural return-value cone (whole body for bare calls)
- [x] deterministic fuzz-style invariant tests
- [x] 500-statement benchmark (see `bench/README.md`)
- [x] 20+ meaningful commits
- [x] push to GitHub: public repo `cs6210501-lab/moon-slice`, branch `master`
- [x] GitHub Actions CI and Pages workflows added; Pages enabled for `web/`
- [x] live playground verified at https://cs6210501-lab.github.io/moon-slice/
- [ ] fill author / team / contact in `PROPOSAL.md`
- [ ] submit the Feishu form before 2026-10-31 23:59:59
