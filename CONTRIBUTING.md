# Contributing

Thanks for looking. The project is small on purpose: one MoonBit module, no
runtime dependencies, and every behaviour backed by a test or a smoke script.

## Setup

```bash
curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash
export PATH="$HOME/.moon/bin:$PATH"

./dev.sh check
./dev.sh test
bash testdata/verify_corpus.sh
bash test/cli_smoke.sh
node web/smoke.mjs
```

On Windows, use `dev.cmd` instead of `./dev.sh` for the same commands.

## Layout

| Path | What lives there |
| --- | --- |
| `src/core/types.mbt` | frozen data model (`SNode`, `Cfg`, `DefUse`, `Cdg`, `Pdg`, `SliceResult`) |
| `src/parser_adapter` | MoonBit AST → `SNode`; the only package that knows the parser |
| `src/cfg`, `src/defuse`, `src/cdg`, `src/pdg` | the analysis passes |
| `src/slice`, `src/query` | backward/forward slicing and queries |
| `src/report` | JSON, DOT, SARIF, SVG and HTML rendering |
| `cmd/main` | flag parsing and output only; no analysis logic |
| `src/integration_test` | cross-package tests, oracle and property suite |
| `web/` | the prebuilt JS engine and the single-page playground |

`src/core/types.mbt` is a contract. Adding a field means updating every
producer and consumer; prefer deriving information in `query` when possible.

## Adding a test

- Analysis change: add a focused test in the package, then a cross-package
  expectation in `src/integration_test`.
- New syntax: add a small `.mbt` file under `examples/` with
  `EXPECT-BACKWARD` / `EXPECT-FORWARD` headers, mirror it in
  `testdata/expected.json`, and run `bash testdata/verify_corpus.sh`.
- CLI behaviour: extend `test/cli_smoke.sh`; failures must exit nonzero and
  `--json` failures must carry `{"error":{"code","message"}}`.
- Precision claim: add a case to `precision_oracle_test.mbt` and, if it is a
  generator-friendly shape, a seed to `property_test.mbt`.

## Style

- `moon check` must stay at 0 errors / 0 warnings.
- Keep functions small and comments limited to invariants the code cannot show.
- Public API lives in `src/*/moon.pkg`-visible modules; `pkg.generated.mbti`
  files are committed, so regenerate them via a normal build.
- Rendering code must escape untrusted input; see `escape_html`, `json_string`
  and the regression tests around them.

## Pull requests

1. One concern per PR, with the tests that justify it.
2. Run the five commands above and paste their last line in the description.
3. If a user-facing claim changes, update `README.md`, `README.zh-CN.md`,
   `CHANGELOG.md` and `docs/CASE_STUDY.md` in the same PR.

By contributing you agree that your work is licensed under Apache-2.0.
