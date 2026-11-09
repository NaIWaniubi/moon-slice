# November 2026 — the period's work

The 十一月赛 accepts existing projects but counts only work completed in the
current period (`已有项目必须包含本期完成的实质新增工作`). This page lists what
changed between 2026-11-01 and 2026-11-07, with the commit, the release and the
check that proves each one.

| Area | What changed | Evidence |
| --- | --- | --- |
| Editor | Hover answers both directions from one PDG build: where the value came from and what the line affects | 0.10.0; `test/lsp_client.mjs` asserts both `backward slice` and `forward slice` |
| Editor | Package-wide `unused-function` on open/save, so a sibling file that was never opened is reported | 0.10.0; the client test opens one file and asserts the sibling's finding |
| Editor | Package scans are incremental: a file whose mtime and size are unchanged is never read or parsed again, and the open buffer's text is part of its key | 0.10.1; `bench/scan.mjs` (217-file package: 2.0–2.8 s cold → 0.20–0.23 s warm) |
| Analysis | `unused`'s lexical fallback went from rescanning every file per candidate to one word-count pass | 0.10.1; the same ten findings on `moonbitlang/parser`, still none on `moonbitlang/core` |
| Tooling | The version the CLI, SARIF and the HTML report print is checked against `moon.mod` by the CLI smoke test and the LSP client | 0.10.2; `test/cli_smoke.sh`, `test/lsp_client.mjs` |
| Analysis | Six new semantic packages: workspace graph, typed call resolution with coverage, SSA, side-effect summaries, root reachability proofs, independent differential oracle | 0.11.0; 281 new tests; `src/{workspace,resolve,ssa,sidefx,roots,oracle}` |
| CLI | `explain-live`, `explain-dead`, `coverage`, `impact`, `fix` — reachability proofs, resolution coverage, impact certificates, safe dead-code removal | 0.11.0; `test/cli_smoke.sh` 91 assertions; real-upstream runs recorded in `DELIVERY.md` |
| Editor | LSP hover appends liveness evidence for private functions; unused diagnostics carry reachability | 0.11.0; `test/lsp_client.mjs` |
| Analysis | Interprocedural expansion filters callee statements by side effects and maps actual arguments to parameters | 0.12.0; 54 new tests in `src/interproc` + `src/parser_adapter/calls.mbt` |
| Editor | LSP definition and references over the package, with `includeDeclaration` | 0.12.0; `test/lsp_client.mjs` |
| CI | `review --diff` prints an impact certificate per file (functions, entries, tests, evidence paths) | 0.12.0; `test/cli_smoke.sh` |
| Security | `taint --dir D [--config F]`: source→sink PDG paths, sanitizer cut-off, `--fail-on-findings` | 0.12.0; `src/taint` |
| Correctness | A match case's guard now reads its own pattern binder instead of an outer name of the same name (or scope -1), which had invented a data dependency and hidden a dead store | 0.12.1; two tests in `src/parser_adapter/parser_adapter_test.mbt`; fixture slice narrows from `2,3,5` to `3,5` |
| Correctness | The LSP no longer advertises `diagnosticProvider` it does not implement; `--baseline` is rejected where it is not honoured; the playground rejects an unknown direction | 0.12.1–0.12.2; `test/lsp_client.mjs`, `test/cli_smoke.sh` (exit code 2 pinned) |
| Tooling | Pre-submission review round: 55 confirmed defects triaged, every finding inside this repository fixed (benches, corpus checker, browser e2e, DOCX list style, temp-dir cleanup) | 0.12.1–0.12.2; `863 tests`, `cli smoke ok`, both e2e scripts green |


Verify it yourself, in this order:

```bash
./dev.sh check && ./dev.sh test          # 863 tests
node test/lsp_client.mjs                 # diagnostics, both slices, quick fix, cache hit and invalidation
./dev.sh build --target native --release cmd/lsp
node bench/scan.mjs --dir ~/.moon/lib/core/builtin --reps 5
```

Commits in the period: `29d869e` (incremental scans, linear liveness),
`40f1254` and `2481217` (version strings, 0.10.2), `3aa2dd4` (Word copy of
the proposal), then the 0.11.0 wave: six package commits plus `tower(m-00x)`
merges for workspace, resolve, ssa, sidefx, roots, oracle, explain, LSP
liveness, impact and refactor.
Releases: `v0.10.1`, `v0.10.2`, `v0.11.0`, `v0.12.0`, `v0.12.1`, `v0.12.2`, all
on mooncakes.io. The last two are the pre-submission review round; `CHANGELOG.md`
lists every fix.
