# Editor integration (LSP)

`cmd/lsp` is a small Language Server for MoonBit. It speaks LSP 3.17 over stdio,
publishes the findings the CLI reports as diagnostics, and answers hover and
quick-fix requests from the same analysis.

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
| Diagnostics | `dead-store`, `unreachable-code`, parser failures while typing; `unused-function` for the whole package on open and save |
| `textDocument/hover` | both slices for the line: backward (where it came from) and forward (what it affects) |
| `textDocument/codeAction` | quick fix appending `// moon-slice: ignore[rule]` |
| `shutdown` / `exit` | handled, so a client can close cleanly |

## When each pass runs

Typing (`didChange`) re-runs the file-local rules: dead stores, unreachable
code, parse failures. That is cheap enough to run on every keystroke and it is
what a squiggle needs.

Opening and saving run the package pass: every `.mbt` file next to the edited
one is analysed as one package, because that is what `unused-function` needs —
a private function may be called from a sibling file, or from nowhere. The file
you have open is analysed from the buffer, so unsaved edits count; its siblings
come from disk.

The package pass is incremental. Each file is remembered with its modification
time and size; a file whose stamp is unchanged is neither read nor parsed again.
For the open file the buffer text is part of the key, so an unsaved edit is
never mistaken for an unchanged file, and files that disappear from the
directory are dropped from the cache rather than kept for the session.

The pass reports its own accounting on stderr, one line per scan:

```
moon-slice: package /path/to/pkg: 1200 files, 1200 re-read, 0 cached
moon-slice: package /path/to/pkg: 1200 files, 0 re-read, 1200 cached
```

stdout carries the protocol and nothing else, so this cannot corrupt the stream;
editors that show a server log will display it. `bench/scan.mjs` turns those
lines into cold and warm numbers.

A file that does not parse gets one diagnostic per parser report instead of
analysis results: guessing at a broken file would be worse than saying it is
broken. If the directory cannot be listed, the open file still gets its
file-local diagnostics.

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

`test/lsp_client.mjs` is a complete client. It spawns the binary and asserts the
advertised capabilities, that `serverInfo.version` matches `moon.mod`, that a
dead store produces the expected diagnostic, that hover returns both slices,
that the quick fix carries the suppression directive, and that rewriting the
buffer clean clears the diagnostic. It then writes a two-file package to a temp
directory, opens one file, and asserts that the sibling's unused function is
reported — and that a save with nothing changed re-reads no file while a
rewritten sibling is read again. CI runs it on every push.

```bash
node test/lsp_client.mjs
# lsp client ok: initialize, diagnostics, hover, code action, change, package scan, package cache, shutdown, exit
```

## Benchmarks

`bench/scan.mjs` measures the package pass on a generated package or on a real
directory:

```bash
node bench/scan.mjs --files 1200 --reps 3
node bench/scan.mjs --dir /path/to/a/real/package --reps 3
```

It prints the cold (first open) and warm (save with nothing changed) times and
the speedup between them.
