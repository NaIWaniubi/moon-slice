# Coverage

Measured on 2026-11-08 (v0.11.0) with the legacy MoonBit reporter:

```bash
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage analyze
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage report -f summary
```

The default reporter currently fails on this project with
`conflicting trace metadata for file id`; the legacy reporter works and is what
the numbers below use. It lists only files that have uncovered lines; fully
covered files (265 lines across the new packages) are included in the total
but not in the table.

| File | Lines |
| --- | --- |
| `src/cdg/cdg.mbt` | 294/314 |
| `src/cfg/cfg.mbt` | 117/123 |
| `src/defuse/defuse.mbt` | 117/120 |
| `src/impact/impact.mbt` | 261/276 |
| `src/interproc/interproc.mbt` | 150/168 |
| `src/liveness/liveness.mbt` | 130/147 |
| `src/oracle/diff.mbt` | 100/107 |
| `src/oracle/gen.mbt` | 131/139 |
| `src/oracle/oracle.mbt` | 295/343 |
| `src/parser_adapter/parser_adapter.mbt` | 429/525 |
| `src/parser_adapter/receivers.mbt` | 350/398 |
| `src/pdg/pdg.mbt` | 31/32 |
| `src/query/query.mbt` | 293/308 |
| `src/refactor/refactor.mbt` | 804/1028 |
| `src/report/report.mbt` | 504/559 |
| `src/resolve/scan.mbt` | 35/42 |
| `src/resolve/types.mbt` | 42/44 |
| `src/roots/roots.mbt` | 288/368 |
| `src/sidefx/sidefx.mbt` | 179/204 |
| `src/ssa/ssa.mbt` | 442/477 |
| `src/suppress/suppress.mbt` | 82/83 |
| `src/workspace/graph.mbt` | 136/140 |
| `src/workspace/lexer.mbt` | 116/149 |
| `src/workspace/mod.mbt` | 33/38 |
| `src/workspace/pkg.mbt` | 50/57 |
| `cmd/main/main.mbt` | 22/848 |
| `cmd/main/review.mbt` | 71/155 |
| `cmd/main/explain.mbt` | 112/292 |
| `cmd/main/fix.mbt` | 0/119 |
| `cmd/main/impact_cmd.mbt` | 0/133 |
| `cmd/lsp/main.mbt` | 0/580 |
| **Total** | **5879/8581** |

Library packages only (excluding `cmd/`): **5674/6454 = 87.9%**.

`cmd/lsp` is the editor server: it is exercised end to end by
`test/lsp_client.mjs` (handshake and `serverInfo.version`, diagnostics on open,
both slices in hover, liveness evidence, the quick-fix directive, diagnostics
cleared on change, the package scan and its cache, clean exit), which CI runs
after building the binary. `cmd/` is not executed by `moon test`; the CLI is
covered by [test/cli_smoke.sh](test/cli_smoke.sh) (every command including
explain-live/explain-dead/coverage/impact/fix, JSON and SARIF modes, malformed
input, in-source suppressions, receiver-call queries, type inference, method
liveness, path SARIF, and the failure exit codes) and by the end-to-end corpus.
The lowest library numbers are the parser adapter and its receiver pass, whose
remaining branches are mostly unsupported-AST fallbacks exercised for
crash-safety by `src/defuse/pipeline_robust_test.mbt`.
