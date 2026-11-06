# Editor integration (LSP)

`cmd/lsp` is a small Language Server for MoonBit. It speaks LSP 3.17 over stdio
and publishes the findings `dead` reports as diagnostics while you type.

## Build and run

```bash
./dev.sh build --target native --release cmd/lsp
_build/native/release/build/cmd/lsp/lsp.exe      # Windows
_build/native/release/build/cmd/lsp/lsp          # Linux / macOS
```

The binary takes no arguments; it reads framed messages from stdin and writes
to stdout. Editors start it themselves.

## What it does

| Capability | Behaviour |
| --- | --- |
| `textDocumentSync` | `1` (full text) — every change replaces the buffer |
| Diagnostics | `dead-store`, `unreachable-code` and parser failures |
| `shutdown` / `exit` | handled, so a client can close cleanly |

Diagnostics are recomputed from the buffer the client sends, so unsaved edits are
analysed exactly as written. A file that does not parse gets one diagnostic per
parser report instead of analysis results: guessing at a broken file would be
worse than saying it is broken.

The server is intentionally single-file. It answers "is this line dead?" while
typing, not "who calls this?" across a package — the CLI does that.

## VS Code

Any generic LSP client extension works; for example a `.vscode/settings.json`
entry with an extension that takes a command, or a small extension whose
`LanguageClient` is:

```json
{
  "command": "/absolute/path/to/lsp",
  "filetypes": ["moonbit"],
  "rootPatterns": ["moon.mod"]
}
```

## Neovim

```lua
vim.lsp.start({
  name = 'moon-slice',
  cmd = { '/absolute/path/to/lsp' },
  root_dir = vim.fs.dirname(vim.fs.find({ 'moon.mod' }, { upward = true })[1]),
})
```

## Checking it without an editor

`test/lsp_client.mjs` is a complete client: it spawns the binary, runs
`initialize`, opens a buffer with a dead store, asserts the diagnostic line and
code, changes the buffer to a clean program, asserts the diagnostics disappear,
then shuts down and checks the exit status. CI runs it on every push.

```bash
node test/lsp_client.mjs
# lsp client ok: initialize, diagnostics, change, shutdown, exit
```
