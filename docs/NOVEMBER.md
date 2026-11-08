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

Verify it yourself, in this order:

```bash
./dev.sh check && ./dev.sh test          # 752 tests
node test/lsp_client.mjs                 # diagnostics, both slices, quick fix, cache hit and invalidation
./dev.sh build --target native --release cmd/lsp
node bench/scan.mjs --dir ~/.moon/lib/core/builtin --reps 5
```

Commits in the period: `29d869e` (incremental scans, linear liveness),
`40f1254` and `2481217` (version strings, 0.10.2), `3aa2dd4` (Word copy of
the proposal), then the 0.11.0 wave: six package commits plus `tower(m-00x)`
merges for workspace, resolve, ssa, sidefx, roots, oracle, explain, LSP
liveness, impact and refactor.
Releases: `v0.10.1`, `v0.10.2`, `v0.11.0`, all on mooncakes.io.
