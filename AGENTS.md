# Mission rules for moon-slice

This repo is built by parallel Tower missions. Read `CONTRACT.md` first.

- Use `./dev.sh <cmd>` (Git Bash) or `dev.cmd <cmd>` (cmd/PowerShell) for all
  MoonBit commands. The wrappers add `%USERPROFILE%\.moon\bin` to `PATH`.
- `src/core/types.mbt` is frozen. Never edit it. If a type must change, write
  `CONTRACT_CHANGE.md` and stop.
- Touch only the directories assigned to your mission. Do not edit another
  mission's files, the root `moon.mod`, or another package's `moon.pkg`.
- Before finishing: `./dev.sh check` and `./dev.sh test` must pass.
- Add meaningful tests for every public function. Prefer small hand-built
  inputs with exact expected node/line sets over broad smoke tests.
- Commit with a message that names the mission and the feature. No empty or
  repeated commits.
- End your reply with:
  `TOWER_RESULT: {"summary":"...","tests":"pass|fail","files":["..."]}`

## MoonBit conventions

- MoonBit packages are directories; each has a `moon.pkg`. Blackbox tests end
  in `_test.mbt`, whitebox tests in `_wbtest.mbt`.
- Keep code in `///|`-separated blocks.
- Do **not** run `moon fmt` or `moon info`: they rewrite shared/frozen files
  and cause cross-mission merge conflicts. The coordinator formats after merge.
- `./dev.sh test` runs tests; `./dev.sh test --update` refreshes snapshots.
- Prefer `assert_eq`/`assert_true` for stable results; use `debug_inspect` for
  structured debugging snapshots.
- `./dev.sh coverage analyze > uncovered.log` shows uncovered code.
