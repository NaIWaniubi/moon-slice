# Coverage

Measured on 2026-10-29 (v0.4.2) with the legacy MoonBit reporter:

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
| `src/parser_adapter/parser_adapter.mbt` | 414/520 |
| `src/pdg/pdg.mbt` | 31/32 |
| `src/query/query.mbt` | 289/308 |
| `src/report/report.mbt` | 343/388 |
| `cmd/main/main.mbt` | 0/312 |
| `cmd/main/review.mbt` | 0/155 |
| **Total** | **1659/2326** |

Library packages only (excluding `cmd/`): **1659/1859 = 89.2%**.

`cmd/` is not executed by `moon test`; the CLI is covered by
[test/cli_smoke.sh](test/cli_smoke.sh) (every command, JSON modes, malformed
input, and the failure exit codes) and by the end-to-end corpus. The lowest library number is the parser
adapter, whose remaining branches are mostly unsupported-AST fallbacks exercised
for crash-safety by `src/defuse/pipeline_robust_test.mbt`.
