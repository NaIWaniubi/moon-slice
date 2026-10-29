# Publishing to mooncakes.io

Status: **not yet published** as of 2026-10-29. Everything except the maintainer
login has been verified; this is the only acceptance item that cannot be done
from the repository alone.

## Verified locally

| Check | Result |
| --- | --- |
| `moonc -v` | `v0.10.17+d971670cd` (requirement: >= 0.10.16) |
| `moon check` | 0 errors, 0 warnings |
| `moon test` | 256 / 256 |
| `moon package` | `_build/publish/chen-moon-slice-0.5.0.zip` (976 KB, 122 files) |
| Manifest | name, version, readme, repository, license, keywords, description |
| License | Apache-2.0 (`LICENSE`), dependencies Apache-2.0 (`THIRD_PARTY.md`) |

## One-time login

`moon login` is interactive: it needs a terminal and a browser session for the
mooncakes.io account. It writes `~/.moon/credentials.json`.

```bash
moon login
```

## Publish 0.5.0

From the repository root, with the same account that owns the `chen` namespace:

```bash
moon publish --dry-run     # validates and prints what would be uploaded
moon publish
moon search moon-slice     # the registry should list chen/moon-slice 0.5.0
```

Or run the checked wrapper, which repeats the local verification, logs in if
needed, previews the upload and asks before publishing:

```bash
bash tools/publish.sh
```

`moon publish` uses the version in `moon.mod`; a version can be published once.
Bump `version` before the next release.

## If the account namespace is not `chen`

The module is `chen/moon-slice`. If the logged-in mooncakes account is named
differently, the registry will reject the namespace; rename the module and its
internal imports first:

```bash
# Replace <account> with the logged-in mooncakes username.
sed -i 's#^name = "chen/moon-slice"#name = "<account>/moon-slice"#' moon.mod
grep -rl '"chen/moon-slice/' --include=moon.pkg . \
  | xargs sed -i 's#"chen/moon-slice/#"<account>/moon-slice/#g'
grep -rl 'chen/moon-slice' README.md README.zh-CN.md PUBLISHING.md \
  | xargs sed -i 's#chen/moon-slice#<account>/moon-slice#g'

./dev.sh check && ./dev.sh test
moon publish
```

There are 11 `moon.pkg` files carrying the self-import; `moon check` catches any
that were missed.

## Verify the published package

In a scratch MoonBit module:

```bash
moon new /tmp/moon-slice-verify
cd /tmp/moon-slice-verify
moon add chen/moon-slice@0.5.0
moon check
```

Then import a library package, for example:

```moonbit
// moon.pkg: import { "chen/moon-slice/src/parser_adapter" }
let program = @parser_adapter.parse_source("fn f() -> Int { 1 }\n", "a.mbt")
println(program.errors.length()) // 0
```

## Why this is not in CI

`moon login` requires a TTY and an interactive account authorization, and the
credential file is account-scoped. Publishing is therefore a maintainer-local
step, not a GitHub Actions step; no credential is stored in the repository.
If mooncakes adds token-based CI authentication, this file should be updated with
the exact variable name rather than guessing one.
