# Publishing to mooncakes.io

Status: **published** — `NaIWaniubi/moon-slice@0.7.0` went live on 2026-10-31,
0.7.1 republished the same analysis so that tag, manifest and registry agreed,
0.7.2 added in-source suppressions and 0.7.3 receiver calls in `callers`.

```
Server status: 200 OK
```

The registry entry is at <https://mooncakes.io/docs/NaIWaniubi/moon-slice>.

## Published artifact

| Check | Result |
| --- | --- |
| `moonc --version` | `v0.10.17+d971670cd` (requirement: >= 0.10.16) |
| `moon check` | 0 errors, 0 warnings |
| `moon test` | 294 / 294 |
| `moon package` | `_build/publish/NaIWaniubi-moon-slice-0.7.3.zip` (1,182,221 bytes, 146 files) |
| `moon publish` | `Server status: 200 OK` |
| Manifest | name, version, readme, repository, license, keywords, description |
| License | Apache-2.0 (`LICENSE`), dependencies Apache-2.0 (`THIRD_PARTY.md`) |

## Evidence from the registry

```bash
$ moon add NaIWaniubi/moon-slice@0.7.3
Downloading NaIWaniubi/moon-slice@0.7.3
```

A scratch module consuming the published package, not the working tree:

```moonbit
// cmd/main/moon.pkg imports NaIWaniubi/moon-slice/src/{parser_adapter,cfg,defuse,cdg,pdg,query,slice}
let program = @parser_adapter.parse_source(source, "consumer.mbt")
let cfg     = @cfg.build(program)
let defuse  = @defuse.analyze(program, cfg)
let cdg     = @cdg.build(program, cfg)
let pdg     = @pdg.build(defuse, cdg)
let node    = @query.target_node(program, 4).unwrap()
let result  = @slice.backward(pdg, node, program=program)
```

```
$ moon run cmd/main
backward-lines=[4]
line=1
line=2
line=3
line=4
```

The slice is `[1, 2, 3, 4]` for a target on line 4 — the parameter, both
intermediate bindings, and the target itself.

## One-time login

`moon login` is interactive: it needs a real terminal (it refuses a pipe with
`IO error: not a terminal`) and a browser session for the mooncakes.io account.
It writes `~/.moon/credentials.json`.

```bash
moon login      # Password or Github; the Github path prints an authorize URL
                # and then asks for the code shown on the callback page
```

## Republish / next release

From the repository root, as the account that owns the namespace:

```bash
moon publish --dry-run     # validates, packages, checks the extracted zip
moon publish
moon search moon-slice     # the registry should list NaIWaniubi/moon-slice
```

Or run the checked wrapper, which repeats the local verification, logs in if
needed, previews the upload and asks before publishing:

```bash
bash tools/publish.sh
```

`moon publish` uses the `version` in `moon.mod`; each version can be published
once. Bump `version` before the next release.

## If the account namespace changes

The registry rejects a module whose first path segment is not the logged-in
username:

```
Server status: 403 Forbidden, detail: User mismatch: The username in the module
config file (chen) does not match the authenticated user's username (NaIWaniubi).
```

If that happens, rename the module and every self-import first:

```bash
# Replace <account> with the logged-in mooncakes username.
python - <<'PY'
import os
old, new = b"chen/moon-slice", b"<account>/moon-slice"
skip = {"_build", ".git", "node_modules"}
for root, dirs, files in os.walk("."):
    dirs[:] = [d for d in dirs if d not in skip]
    for name in files:
        path = os.path.join(root, name)
        if path.lower().endswith((".png", ".jpg", ".gif", ".pdf", ".zip")):
            continue
        data = open(path, "rb").read()
        if old in data:
            open(path, "wb").write(data.replace(old, new))
PY

./dev.sh check && ./dev.sh test
bash web/build.sh          # the JS bundle embeds package names in symbol names
moon publish
```

Twelve `moon.pkg` files carry the self-import (32 files changed in total);
`moon check` catches any that were missed, and the playground presets catch a
stale bundle.

## Credentials format (verified)

`~/.moon/credentials.json` is read as:

```json
{"token": "<mooncakes token>", "username": "<account name>"}
```

`username` is optional. Do not commit this file.

## CI option

Publishing is not wired into this repository's CI because the token is
account-scoped. If you keep it as a repository secret
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
