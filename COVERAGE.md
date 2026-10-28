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
| `src/cfg/cfg.mbt` | 96/98 |
| `src/defuse/defuse.mbt` | 114/116 |
| `src/parser_adapter/parser_adapter.mbt` | 367/464 |
| `src/pdg/pdg.mbt` | 31/32 |
| `src/query/query.mbt` | 321/345 |
| `src/report/report.mbt` | 310/348 |
| `cmd/main/main.mbt` | 0/223 |
| **Total** | **1588/1994** |

Library packages only (excluding `cmd/main`): **1588/1771 = 89.7%**.

`cmd/main` is not executed by `moon test`; the CLI is covered by
[test/cli_smoke.sh](test/cli_smoke.sh) (every command, JSON modes, malformed
input, and the failure exit codes) and by the end-to-end corpus. The lowest library number is the parser
adapter, whose remaining branches are mostly unsupported-AST fallbacks exercised
for crash-safety by `src/defuse/pipeline_robust_test.mbt`.
