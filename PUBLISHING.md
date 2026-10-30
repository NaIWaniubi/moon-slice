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
| `moon package` | `_build/publish/chen-moon-slice-0.7.0.zip` (976 KB, 122 files) |
| Manifest | name, version, readme, repository, license, keywords, description |
| License | Apache-2.0 (`LICENSE`), dependencies Apache-2.0 (`THIRD_PARTY.md`) |

## One-time login

`moon login` is interactive: it needs a terminal and a browser session for the
mooncakes.io account. It writes `~/.moon/credentials.json`.

```bash
moon login
```

## Publish 0.7.0

From the repository root, with the same account that owns the `chen` namespace:

```bash
moon publish --dry-run     # validates and prints what would be uploaded
moon publish
moon search moon-slice     # the registry should list chen/moon-slice 0.7.0
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
moon add chen/moon-slice@0.7.0
moon check
```

Then import a library package, for example:

```moonbit
// moon.pkg: import { "chen/moon-slice/src/parser_adapter" }
let program = @parser_adapter.parse_source("fn f() -> Int { 1 }\n", "a.mbt")
println(program.errors.length()) // 0
```

## Credentials format (verified)

`~/.moon/credentials.json` is read as:

```json
{"token": "<mooncakes token>", "username": "<account name>"}
```

`username` is optional. The format was verified against the CLI's
`Credentials` struct and by a `moon publish --dry-run` probe: with a probe file
present the command passed its local checks and attempted
`POST https://mooncakes.io/api/v0/publish`. The request failed with the probe
token, nothing was published, and the probe file was deleted.

## CI option

Publishing is not wired into this repository's CI by default because the token
is account-scoped. If you keep it as a repository secret
(`MOONCAKES_CREDENTIALS`, the JSON above), a release job can write the file and
publish:

```yaml
- name: Write mooncakes credentials
  run: |
    mkdir -p "$HOME/.moon"
    printf '%s' "$MOONCAKES_CREDENTIALS" > "$HOME/.moon/credentials.json"
  env:
    MOONCAKES_CREDENTIALS: ${{ secrets.MOONCAKES_CREDENTIALS }}

- name: Publish
  run: moon publish
```

Do not commit the credentials file. `moon login` remains the simplest local
path and needs a TTY plus a browser session.
