# moon-slice — delivery evidence

Date: 2026-10-30 (v0.7.0). Repository: https://github.com/NaIWaniubi/moon-slice (public, `master`).
Live playground: https://NaIWaniubi.github.io/moon-slice/

## Verification run in this session

| Command | Result |
| --- | --- |
| `./dev.sh check` | 0 errors, 0 warnings |
| `./dev.sh test` | `Total tests: 294, passed: 294, failed: 0` |
| `bash testdata/verify_corpus.sh` | `corpus ok: 10 examples, headers and expected.json agree` |
| `bash test/cli_smoke.sh` | `cli smoke ok` (all commands, JSON modes, malformed input, negative exit codes) |
| `node web/smoke.mjs` | `web smoke ok: 7006 bytes` (JS engine, full HTML report) |
| `node web/playground_e2e.mjs .` | `playground e2e ok: first=rendered 6960 bytes, second=rendered 6998 bytes, markerPreserved=true` |
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
| `./dev.sh run cmd/main -- review --diff <synthetic diff>` | `review_probe.mbt: changed 1 line(s) -> affected 2 line(s)`, `affected lines: 3,4` (also in JSON) |
| `node tools/scan.mjs <release-binary> /tmp/async` | 368 files, 50,388 lines, 0 parse failures, 0 hits |
| `node tools/scan.mjs <release-binary> /tmp/x` | 166 files, 37,595 lines, 0 parse failures, 0 hits |
| `node tools/scan.mjs <release-binary> .` | 51 files, 10,401 lines, 0 parse failures, 6 files / 7 lines — all intentional dead stores in `examples/` |
| `dead --dir .` (release) | 51 files, 7 findings, 0 errors; identical to the independent `tools/scan.mjs` result |
| `dead --dir . --json` (in /tmp/async) | `files=368, findings=0, errors=0`; about 1.2 s |
| `dead --dir . --json` (in /tmp/x) | `files=166, findings=0, errors=0`; about 1.0 s |
| `dead --format sarif --out F` | parses as SARIF 2.1.0; 2 results on `examples/08`, rules/locations/fingerprints present |
| `dead --write-baseline` then `--baseline` | 2 findings → empty output, `"suppressed":2`; `--fail-on-findings` exits 1 before, 0 after |
| `action` steps simulated in /tmp/x | `review --diff .moon-slice/pr.diff` reports 4 files / 15 changed / 40 affected; `dead --dir . --format sarif` returns 0 findings |
| `unused --dir .` (release) in /tmp/async | 369 files, 54 packages, 0 findings, 0 parse failures; 1.09 s |
| `unused --dir .` (release) in /tmp/x | 166 files, 0 findings; 1.14 s |
| `unused --dir .` (release) in /tmp/core | 1452 files, 140 packages, 0 findings; 6.93 s |
| `unused --dir examples --json` | 10 findings, `packages=1`, `files=10`, `suppressed=0`, `errors=[]` |
| `unused --dir examples --write-baseline` then `--baseline --fail-on-findings` | gate exits 1 before the baseline, 0 after it |
| `unused --dir examples --format sarif` | `ruleId=unused-function`, `ruleIndex=2`, artifact URI and line present |
| `node web/presets.mjs` | all 5 page examples resolve; backward `4,5,6,7,8`, forward `7,10`, interprocedural `2,6,7,8,12` through the JS engine |
| `slice --dir pkg --file pkg/a.mbt --line 2 --interprocedural` | `pkg/a.mbt: 2` and `pkg/b.mbt: 2,6,7,8` — callee in a sibling file |
| `slice --dir cmd/main --file cmd/main/main.mbt --line 1086 --interprocedural` | `cmd/main/main.mbt` (47 lines) plus 100+ lines from `cmd/main/review.mbt` |
| `callers --dir . --name baseline_key` | 6 call sites in `cmd/main/main.mbt` with their enclosing functions |
| `callers --dir . --name parse_str` (in /tmp/x/time) | 10 call sites across 5 files — qualified `Duration::parse_str(...)` calls |
| `node web/playground_e2e.mjs .` | passes on 3 consecutive runs (gutter, status and escaping) |
| `./dev.sh build --target native --release cmd/main && node bench/bench.mjs --sizes 500,8000,32000 --reps 3` | see `bench/README.md`; 32k statements: `slice` 1.55 s, `dead` 0.80 s, `graph` 0.74 s |

## 0.7.0 package-scope analysis (2026-10-30)

1. **`slice --dir D --file F --line N [--interprocedural]`** follows calls into
   any file under `D`, reporting the slice per file because a node id only means
   something inside its own program. A bare call contributes the callee's whole
   body, a value-returning call its return-value cone; expansion is transitive and
   a same-file definition wins over a same-named one elsewhere. On moon-slice
   itself, slicing `run_review(...)` at `cmd/main/main.mbt:1086` adds 100+ lines
   from `cmd/main/review.mbt`.
2. **`callers --dir D --name F`** lists every call site of `F` in the package with
   the enclosing function, as text or JSON. On the `time` package of
   `moonbitlang/x` it finds the ten `Duration::parse_str` / `Period::parse_str`
   call sites across five files.
3. **Qualified calls are recorded.** `T::f(x)` is an `Expr::Method` — an explicit
   type-qualified reference — and recording it is what made points 1 and 2 work on
   real code. Before this, code called its own functions in a way the tool could
   not see. `x.f()` (`Expr::DotApply`) is deliberately *not* recorded: without the
   receiver's type, attributing it to a function named `f` would invent a call.
   Both halves have regression tests, including the existing test that caught the
   first attempt at this change.
4. **`src/interproc`** holds the package index, the expansion and the callers
   query, with nine tests of its own.
5. **Tests: 294.** New: cross-file expansion, return-cone precision across files,
   transitivity, local-wins, unknown callee, unparsable files, qualified vs
   receiver calls, and CLI smoke for both new commands.

## 0.6.0 liveness and playground (2026-10-30)

1. **`unused --dir D`** answers what `dead` cannot: which private functions the
   package no longer calls. It works per package (one directory), because that is
   the scope a private function is visible in. Entry points (`main`, `init`),
   `pub` functions, methods — `impl T with fn m` and `fn T::m(self)` — and
   declaration-only stubs are excluded, and a name that occurs anywhere else in
   the package suppresses the finding.
2. **Two false-positive classes found on real code and fixed**, each with a
   regression: `fn Decode::_use_decode_debug(self)` in `moonbitlang/x` is a
   method, and `fn init` in `moonbitlang/async`'s setup files is a package
   initialiser. The first scan of those two repositories produced 17 findings,
   all of them these two shapes; after the fixes the same scan produces none.
3. **Calibrated on the standard library.** `moonbitlang/core@56256d0`, 1452
   files, 140 packages: the first pass named 4 functions, and every one of them
   carries the library's own `#warnings("-unused_value")` opt-out
   (`unused_function`, `suppress_unused_v128_import_on_js` ×2,
   `suppress_unused_v128_import_on_scalar_targets`). The pass now honours that
   attribute, so all three corpora report nothing: **1987 files, 0 findings, 0
   parse failures**.
4. **The playground became a tool**: clickable line gutter, slice/target markers
   painted from the report's embedded JSON, five examples with their own target
   and direction, auto re-run after edits, `Ctrl`+`Enter`, and a copy-link
   button. `web/presets.mjs` checks every example and every direction through the
   JavaScript engine with the same numbers the CLI documents, and CI runs it.
5. **Tests: 284.** New: 20 liveness cases (interpolation references, `priv`,
   top-level `let`, `impl` bodies, opt-out attribute, sibling-file callers,
   unparsable packages), the engine-flow test, and the preset matrix.

## 0.5.0 CI integration (2026-10-29)

1. **`dead --dir D`** scans a tree in one process. It skips `.git`, `_build`,
   `target`, `.mooncakes` and `node_modules`, reports parse failures per file,
   and keeps a deterministic lexical order. On the same corpora as 0.4.2 the
   results are identical to the independent per-file `tools/scan.mjs`, but the
   run time drops from 99 s to about 1.0 s for 166 files.
2. **SARIF 2.1.0** (`dead --format sarif`) emits one run with the two rules
   `dead-store` and `unreachable-code`, artifact URIs, region lines, and partial
   fingerprints; `invocations[0].executionSuccessful` and
   `properties.parseFailures` distinguish clean from incomplete scans.
3. **Baselines and the gate.** `--write-baseline` records `path:line`;
   `--baseline` hides those entries and reports `suppressed`; `--fail-on-findings`
   exits 1 only for survivors (exit 2 remains usage/IO error).
4. **`--out` for `dead`** writes text, JSON or SARIF to a file, so a workflow
   does not need shell redirection.
5. **`action.yml` + `templates/review-workflow.yml`** build the pinned tag and
   run `review` (with `since` generating the diff) or `dead`; the template also
   uploads SARIF to code scanning.
6. **Real-commit review evidence.** On `moonbitlang/x@4705764`, 15 changed lines
   reach 40 lines: `duration.mbt` affects 6 functions / 36 lines and
   `period.mbt` affects 3 functions / 4 lines; both test files correctly reach 0.
7. **Tests: 263.** New coverage: scan path normalisation, SARIF shape, scan JSON,
   the directory CLI end to end (including both gate exit codes), and whitebox
   tests for the diff parser and review helper (7 cases, added after the tag).

## 0.4.2 precision hardening (2026-10-29)

1. **`review --diff`** — forward-slices every added line in a unified diff and
   reports the affected lines and functions per file; `tools/review.sh` wraps it
   for local use. JSON mode returns `files/changed/affected/records`.
2. **`tools/scan.mjs`** — runs `dead --json` over a source tree and aggregates
   parse failures and hits, so the precision claims are reproducible.
3. **Real-code validation** — 584 files / 97,695 lines across
   `moonbitlang/async` (`2632315`) and `moonbitlang/x` (`4705764`): 0 parse
   failures, 0 false positives. Scanning moon-slice itself returns 7 hits, all
   of them the dead stores planted in `examples/`.
4. **Seven false-positive classes found by that scan and fixed**, each with a
   regression test: parameter writes, field and index writes, identifiers inside
   interpolation source, the C-style `for` step block, C-style `for` initialiser
   re-execution, container nodes without a statement, and closure captures.
   Net effect on the upstream corpora: 176 hit lines → 0.
5. **Test suite** grew to 248 with `real_world_test.mbt`, the review smoke test,
   and the closure/`impl` regressions.

## Remote verification after the account rename (2026-10-31, commit `18cbd11`)

GitHub renamed `cs6210501-lab` to `NaIWaniubi`; the repository and the Pages site
moved with it. `tools/rename-owner.sh` rewrote 10 tracked files, regenerated the
bundle and the proposal PDF, and verified no old reference remained.

| Check | Result |
| --- | --- |
| CI `41156714579` | success on `NaIWaniubi/moon-slice`: check, native build, 294 tests, corpus, CLI smoke, bundle smokes, playground presets, action job |
| Pages `41156714577` | success: deployed `web/` under the new owner |
| New site | `https://naiwaniubi.github.io/moon-slice/` returns 200 |
| Live `index.html` SHA-256 | `77412b22...d26b48`, identical to the committed file |
| Live `moon-slice.js` | `HTTP/1.1 200`, `Content-Length: 10275869` |
| `node web/live_e2e.mjs` | `live e2e ok: rendered 6960 bytes -> rendered 7 node(s) · lines 4,5,6,7,8 · target line 7` |

## Remote verification (2026-10-30, commit `7e65306`, v0.7.0)

| Check | Result |
| --- | --- |
| CI `41027752741` | success: check, native release build, 294 tests, corpus, CLI smoke, committed-bundle smoke, rebuild, rebuilt-bundle smoke, playground presets, action job |
| Tag CI `41027752645` | success on `v0.7.0` |
| Pages `41027752809` | success: deployed the rebuilt `web/` |
| CI log evidence | `Total tests: 294, passed: 294, failed: 0`, `cli smoke ok`, `playground presets ok` |
| Live `index.html` SHA-256 | `77412b22...d26b48`, identical to the committed file |
| Live `moon-slice.js` | `HTTP/1.1 200`, contains `moon-slice 0.7.0` and no `0.6.0`, so the deployed engine is this release |
| `node web/live_e2e.mjs` | `live e2e ok: rendered 6960 bytes -> rendered 7 node(s) · lines 4,5,6,7,8 · target line 7` (real Chrome, two runs on the deployed site) |

## Remote verification (2026-10-30, commit `965e36c`, v0.6.0)

| Check | Result |
| --- | --- |
| CI `41014834580` | success: check, native release build, 284 tests, corpus, CLI smoke, committed-bundle smoke, rebuild, rebuilt-bundle smoke, playground presets, action job |
| Tag CI `41014834569` | success on `v0.6.0` |
| Pages `41014834554` | success: deployed the rebuilt `web/` |
| CI log evidence | `Total tests: 284, passed: 284, failed: 0`, `cli smoke ok`, `playground presets ok` |
| Live `index.html` SHA-256 | `77412b22...d26b48`, identical to the committed file |
| Live `moon-slice.js` | `HTTP/1.1 200`, `Content-Length: 10276204`; contains `moon-slice 0.6.0` and no `0.5.0`, so the deployed engine is this release |
| `node web/live_e2e.mjs` | `live e2e ok: rendered 6960 bytes -> rendered 7 node(s) · lines 4,5,6,7,8 · target line 7` (real Chrome, two runs on the deployed site) |

## Remote verification (2026-10-29, commit `72aca53`, v0.5.0)

| Check | Result |
| --- | --- |
| CI `40884027453` | success: check, 256 tests, corpus, CLI smoke, committed-bundle smoke, rebuild, rebuilt-bundle smoke |
| Tag CI `40884027671` | success on `v0.5.0` |
| Pages `40884027574` | success: deployed the rebuilt `web/` |
| CI log evidence | `Total tests: 263, passed: 263, failed: 0`, `cli smoke ok`, both bundle smokes `web smoke ok: 7006 bytes` |
| CI `40884391008` `action` job | success: `uses: ./` resolved `action.yml`, installed MoonBit, built `cmd/main`, and ran `dead --dir src --fail-on-findings` (58 s, exit 0) |
| Live `index.html` SHA-256 | `dce7b383...24b1980`, identical to the committed file |
| Live `moon-slice.js` | `HTTP/1.1 200`, `Content-Length: 10276204` (Linux rebuild; functionally identical to the committed Windows build) |
| `node web/live_e2e.mjs` | `live e2e ok: rendered 6960 bytes -> rendered 6992 bytes` (real Chrome, two runs on the deployed site) |

## Remote verification (2026-10-29, commit `8c33bfd`, v0.4.2)

| Check | Result |
| --- | --- |
| CI `40860284920` | success: check, 248 tests, corpus, CLI smoke, committed-bundle smoke, rebuild, rebuilt-bundle smoke |
| Pages `40860284910` | success: deployed the rebuilt `web/` |
| Live `index.html` SHA-256 | `dce7b383...24b1980`, identical to the committed file |
| Live `moon-slice.js` | `HTTP/1.1 200`, `Content-Length: 10276204` (Linux rebuild; functionally identical to the committed Windows build) |
| `node web/live_e2e.mjs` | `live e2e ok: rendered 6960 bytes -> rendered 6992 bytes` (real Chrome, two runs on the deployed site) |

## Remote verification (2026-10-29, commit `3a5a406`, v0.4.0)

| Check | Result |
| --- | --- |
| CI `40746363985` | success: check, 238 tests, corpus, CLI smoke, JS build, bundle-drift check, web smoke |
| Pages `40746364235` | success: rebuilt, no drift, deployed `web/` |
| Live `index.html` SHA-256 | `90c5aeac...3cc460`, identical to the committed file |
| Live `moon-slice.js` | `HTTP/1.1 200`, `Content-Length: 10268679`, equal to the committed file |
| `node web/live_e2e.mjs` | `live e2e ok: rendered 6960 bytes -> rendered 6992 bytes` (real Chrome, two runs on the deployed site) |

## Earlier remote verification (commit `94284d4`, v0.3.0)

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

Public repo: https://github.com/NaIWaniubi/moon-slice

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

## 0.4.1 adversarial-review fixes (2026-10-29, commit `8716527`)

Pushed and verified on the remote at `ace07c4`.

| Command | Result |
| --- | --- |
| `./dev.sh check` | 0 errors, 0 warnings |
| `./dev.sh test` | `Total tests: 241, passed: 241, failed: 0` |
| `bash testdata/verify_corpus.sh` | `corpus ok: 10 examples` |
| `bash test/cli_smoke.sh` | `cli smoke ok` (now covers `compare`, data-only `path`, `impl` lowering) |
| `node web/smoke.mjs` | `web smoke ok: 7006 bytes` |
| `node web/playground_e2e.mjs .` | `playground e2e ok: 6960 -> 6998 bytes` |
| `./dev.sh run cmd/main -- compare --file bench/precise_cdg.mbt --line 7` | `structural 18 / precise 7`, 12 removed, 1 added |
| `./dev.sh run cmd/main -- dead --file <impl method with a dead store>` | reports line 6 (previously: empty output) |
| `./dev.sh run cmd/main -- path --from o --to v` | `no path from o to v` (data edges only) |
| `time main.exe html --file <8000 lines> --out x.html` | 496 ms (previously ~15 s) |

## Remote verification (2026-10-29, commit `ace07c4`, v0.4.1)

| Check | Result |
| --- | --- |
| CI `40836926750` | success: check, 241 tests, corpus, CLI smoke, committed-bundle smoke, rebuild, rebuilt-bundle smoke |
| Pages `40836926751` | success: deployed the rebuilt `web/` |
| Live `index.html` SHA-256 | `dce7b383...24b1980`, identical to the committed file |
| Live `moon-slice.js` | `HTTP/1.1 200`, `Content-Length: 10273212` (Linux rebuild; functionally identical to the committed Windows build, see the CI note below) |
| `node web/live_e2e.mjs` | `live e2e ok: rendered 6960 bytes -> rendered 6992 bytes` (real Chrome, two runs on the deployed site) |

### Why the bundle is no longer compared byte-for-byte

The first 0.4.1 CI run failed on `git diff --exit-code -- web/moon-slice.js`:
the Linux rebuild numbered MoonBit's internal JS symbols differently from the
Windows build in the repository (`S9822` vs `S4692`), so the two artifacts were
textually different but functionally identical. Both workflows now smoke-test
the committed bundle, rebuild, then smoke-test the rebuild — which catches a
stale committed artifact (step 1 fails on behaviour) and a broken rebuild
(step 2 fails) without promising cross-platform byte equality.

## 0.4.0 precision pass (2026-10-29)

Five upgrades, all landed directly after a multi-agent attempt whose workers
could not authenticate against their provider (five workers failed with
`invalid_api_key` before writing any code; the worktrees were clean and were
removed).

1. **`cdg::build_precise`** — post-dominators per function, Ferrante–Ottenstein–
   Warren control dependence, exposed as `--precise`. Removes region-to-region
   pseudo edges and the loop-head/exit over-approximations: on
   `while { if c { return }; x = x + 1 }` 18 structural edges become 7.
2. **Interprocedural argument mapping** — callee parameters are paired with
   caller arguments in order; a callee statement whose only parameter
   dependencies are unsupplied parameters is dropped. `two(a,b)` called as
   `two(x)` no longer pulls in the `b`-only branch.
3. **Machine-readable contract** — `--json` failures print
   `{"error":{"code","message"}}` and exit 2; `graph --format json` emits
   deterministic nodes/edges; the HTML report carries a generator tag and an
   embedded `moon-slice-result` JSON block.
4. **Path-based precision oracle** — replaces the bounded walk enumeration with
   the path formulation (BFS with no iteration bound), fixing a real failure the
   property suite found on nested loops.
5. **Seeded property testing** — 40 generated programs per run checked for
   structural invariants, oracle agreement, slice closure, criterion membership,
   line projection, and interprocedural superset-ness; failures print the seed
   and source.

Two defects were found by these new checks and fixed in the same pass: the JSON
escaper did not escape `<`/`>`, so an error string containing `</script>` could
break out of the report's embedded JSON block; and the first post-dominator
implementation dropped the node from its own set during the intersection, which
collapsed the lattice.

## Earlier precision and performance pass (0.3.0)

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
- [x] 294 tests, including 10 end-to-end corpus tests, a path-based precision
  oracle, a seeded property suite, real-repository regressions, review, and
  path/unreachable tests
- [x] zero compiler warnings
- [x] CLI smoke test with every command, JSON mode and malformed input
- [x] library line coverage 89.2% (see COVERAGE.md; legacy reporter)
- [x] inline-SVG HTML report + `docs/report.png`
- [x] browser playground (`web/index.html`, prebuilt JS engine, smoke test)
- [x] GitHub Pages workflow for `web/`
- [x] data-flow path query (`path --from A --to B`)
- [x] inter-procedural return-value cone (whole body for bare calls)
- [x] deterministic fuzz-style invariant tests
- [x] diff-aware impact analysis (`review`, `tools/review.sh`)
- [x] real-world validation over 585 files / 98,384 lines with 0 false positives
- [x] package liveness over 1987 files (async, x, core) with 0 false positives
- [x] cross-file expansion and a `callers` query, both covered by CLI smoke
- [x] click-to-slice playground with preset and direction checks in CI
  (`docs/CASE_STUDY.md`, `tools/scan.mjs`)
- [x] 500-statement benchmark (see `bench/README.md`)
- [x] 20+ meaningful commits
- [x] push to GitHub: public repo `NaIWaniubi/moon-slice`, branch `master`
- [x] GitHub Actions CI and Pages workflows added; Pages enabled for `web/`
- [x] `action.yml` exercised by CI through `uses: ./`
- [x] contribution guide, roadmap, and issue forms
- [x] acceptance checklist mapping every guide item (`ACCEPTANCE.md`)
- [x] third-party license inventory (`THIRD_PARTY.md`)
- [x] `moon package` produces `chen-moon-slice-0.5.0.zip` (976 KB, 122 files)
- [ ] `moon publish` to mooncakes.io — requires the maintainer's interactive
  `moon login`; see `PUBLISHING.md`
- [x] live playground verified at https://NaIWaniubi.github.io/moon-slice/
- [ ] fill author / team / contact in `PROPOSAL.md`
- [ ] submit the Feishu form before 2026-10-31 23:59:59
