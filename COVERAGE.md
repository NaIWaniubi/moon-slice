# Coverage

Measured on 2026-10-26 with the legacy MoonBit reporter:

```bash
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage analyze
MOON_COVE_REPORT_ENABLED=0 ./dev.sh coverage report -f summary
```

The default reporter currently fails on this project with
`conflicting trace metadata for file id`; the legacy reporter works and is what
the numbers below use.

| File | Lines |
| --- | --- |
| `src/cdg/cdg.mbt` | 172/186 |
| `src/cfg/cfg.mbt` | 82/84 |
| `src/defuse/defuse.mbt` | 110/111 |
| `src/parser_adapter/parser_adapter.mbt` | 324/418 |
| `src/pdg/pdg.mbt` | 31/32 |
| `src/query/query.mbt` | 206/221 |
| `src/report/report.mbt` | 171/189 |
| `cmd/main/main.mbt` | 0/175 |
| **Total** | **1150/1470** |

Library packages only (excluding `cmd/main`): **1150/1295 = 88.8%**.

`cmd/main` is not executed by `moon test`; the CLI is covered by
[test/cli_smoke.sh](test/cli_smoke.sh) (every command, JSON modes, malformed
input) and by the end-to-end corpus. The lowest library number is the parser
adapter, whose remaining branches are mostly unsupported-AST fallbacks exercised
for crash-safety by `src/defuse/pipeline_robust_test.mbt`.
