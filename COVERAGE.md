# Coverage

Measured on 2026-11-06 (v0.10.2) with the legacy MoonBit reporter:

```bash
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage analyze
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage report -f summary
```

The default reporter currently fails on this project with
`conflicting trace metadata for file id`; the legacy reporter works and is what
the numbers below use. It lists only files that have uncovered lines, so
`src/scan/scan.mbt` does not appear: all 74 of its lines are covered, and that
is the difference between the total below and the sum of the rows.

| File | Lines |
| --- | --- |
| `src/cdg/cdg.mbt` | 294/314 |
| `src/cfg/cfg.mbt` | 117/123 |
| `src/defuse/defuse.mbt` | 117/120 |
| `src/interproc/interproc.mbt` | 149/168 |
| `src/liveness/liveness.mbt` | 128/147 |
| `src/parser_adapter/parser_adapter.mbt` | 425/525 |
| `src/parser_adapter/receivers.mbt` | 344/398 |
| `src/pdg/pdg.mbt` | 31/32 |
| `src/query/query.mbt` | 289/308 |
| `src/report/report.mbt` | 502/559 |
| `src/suppress/suppress.mbt` | 82/83 |
| `cmd/main/main.mbt` | 22/827 |
| `cmd/main/review.mbt` | 71/155 |
| `cmd/lsp/main.mbt` | 0/483 |
| **Total** | **2645/4316** |

Library packages only (excluding `cmd/`): **2552/2851 = 89.5%**.

`cmd/lsp` is the editor server: it is exercised end to end by
`test/lsp_client.mjs` (handshake and `serverInfo.version`, diagnostics on open,
both slices in hover, the quick-fix directive, diagnostics cleared on change,
the package scan and its cache, clean exit), which CI runs after building the
binary. `cmd/` is not executed by `moon test`; the CLI is covered by
[test/cli_smoke.sh](test/cli_smoke.sh) (every command, JSON and SARIF modes,
malformed input, in-source suppressions, receiver-call queries, type inference
through annotations/returns/records/fields/patterns and expansion, method
liveness, path SARIF, and the failure exit codes) and by the end-to-end corpus.
The lowest library numbers are the parser adapter and its receiver pass, whose
remaining branches are mostly unsupported-AST fallbacks exercised for
crash-safety by `src/defuse/pipeline_robust_test.mbt`.
