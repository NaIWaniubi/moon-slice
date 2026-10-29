# Coverage

Measured on 2026-10-29 with the legacy MoonBit reporter:

```bash
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage analyze
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage report -f summary
```

The default reporter currently fails on this project with
`conflicting trace metadata for file id`; the legacy reporter works and is what
the numbers below use.

| File | Lines |
| --- | --- |
| `src/cdg/cdg.mbt` | 295/314 |
| `src/cfg/cfg.mbt` | 112/118 |
| `src/defuse/defuse.mbt` | 117/120 |
| `src/parser_adapter/parser_adapter.mbt` | 377/477 |
| `src/pdg/pdg.mbt` | 31/32 |
| `src/query/query.mbt` | 272/292 |
| `src/report/report.mbt` | 343/388 |
| `cmd/main/main.mbt` | 0/306 |
| **Total** | **1601/2101** |

Library packages only (excluding `cmd/main`): **1601/1795 = 89.2%**.

`cmd/main` is not executed by `moon test`; the CLI is covered by
[test/cli_smoke.sh](test/cli_smoke.sh) (every command, JSON modes, malformed
input, and the failure exit codes) and by the end-to-end corpus. The lowest library number is the parser
adapter, whose remaining branches are mostly unsupported-AST fallbacks exercised
for crash-safety by `src/defuse/pipeline_robust_test.mbt`.
