# Coverage

Measured on 2026-11-01 (v0.7.2) with the legacy MoonBit reporter:

```bash
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage analyze
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage report -f summary
```

The default reporter currently fails on this project with
`conflicting trace metadata for file id`; the legacy reporter works and is what
the numbers below use.

| File | Lines |
| --- | --- |
| `src/cdg/cdg.mbt` | 294/314 |
| `src/cfg/cfg.mbt` | 117/123 |
| `src/defuse/defuse.mbt` | 117/120 |
| `src/interproc/interproc.mbt` | 95/112 |
| `src/liveness/liveness.mbt` | 113/130 |
| `src/parser_adapter/parser_adapter.mbt` | 420/525 |
| `src/pdg/pdg.mbt` | 31/32 |
| `src/query/query.mbt` | 289/308 |
| `src/report/report.mbt` | 453/506 |
| `src/suppress/suppress.mbt` | 82/83 |
| `cmd/main/main.mbt` | 22/824 |
| `cmd/main/review.mbt` | 71/155 |
| **Total** | **2158/3286** |

Library packages only (excluding `cmd/`): **2065/2307 = 89.5%**.

`cmd/` is not executed by `moon test`; the CLI is covered by
[test/cli_smoke.sh](test/cli_smoke.sh) (every command, JSON modes, malformed
input, in-source suppressions, and the failure exit codes) and by the
end-to-end corpus. The lowest library number is the parser adapter, whose
remaining branches are mostly unsupported-AST fallbacks exercised for
crash-safety by `src/defuse/pipeline_robust_test.mbt`.
