# Roadmap

The shipped surface is listed in `README.md`. This file records what is
deliberately missing and in what order it makes sense to add it.

## Shipped in 0.6.0 / 0.7.0

- **Cross-file expansion**: `slice --dir D` follows calls into sibling files.
- **Unused private functions**: `unused --dir D`, calibrated on 1987 upstream
  files.
- **Who calls what**: `callers --dir D --name F`, including qualified calls
  (`T::f(x)`).
- **Click-to-slice playground** with per-example, per-direction checks in CI.

## Shipped in 0.7.1 – 0.7.3

- **Published to mooncakes.io** as `NaIWaniubi/moon-slice`, so `moon add` is an
  install path next to cloning.
- **Suppressions inside the source**: `// moon-slice: ignore[dead-store]` on the
  finding's line, or on its own line above it. Suppressed findings still count
  in `suppressed` and still reach `--write-baseline`.
- **Receiver calls in `callers`** when the receiver's type is written in the
  source (parameter, annotated `let`, `self`) and the package declares that
  method on that type.
- **Receiver edges in slicing and liveness** (0.7.4): the interprocedural
  expansion pulls in `T::f`'s body, and `unused` treats inherent methods as
  candidates while leaving trait impls alone.
- **The path rule in SARIF** (0.7.5): `path --format sarif` reports the flow as
  one result with the later statements as related locations.

- **Type evidence beyond annotations** (0.7.6): declared return types, record
  literals that name their type, aliases and method results all resolve a
  receiver, with shadowing checked so a local never borrows a signature.
- **Field access** (0.7.7): `p.inner.norm()` and `let q = p.inner` carry the
  declared field type, through chains whose every link is written down.
- **`let` pattern payloads** (0.7.8): `let Ok(p) = e` types `p` from the enum
  declaration, with `Option` / `Result` built in and generic parameters
  substituted from the scrutinee.
- **`match` arm payloads and package-scoped declarations** (0.7.9): every case
  binds its pattern against the scrutinee's type, and all files' declarations
  are merged before resolution, so a type declared next door still counts.

- **Editor integration** (0.8.0): `cmd/lsp` speaks LSP over stdio and publishes
  dead stores and unreachable code as diagnostics; `moonbitlang/async` supplies
  the byte-level stdin the standard library does not.

- **Hover and quick fixes** (0.9.0): hover answers with the backward slice for
  the line, and the code action appends the same suppression directive the CLI
  honours.

## Next

1. **Package-wide diagnostics.** Today the server is single-file by design; a
   workspace scan would need incremental parsing to stay responsive.
2. **Forward slice on demand.** Hover answers "where did this come from"; a
   command could answer "what does this affect" with the same pipeline.

## Considered, not planned

- **Taint analysis as a product.** `path --from A --to B` is a useful query, but
  a real taint mode needs sources/sinks/sanitizers as first-class inputs; that is
  a different tool built on the same PDG.
- **Byte-for-byte reproducible JS bundles across platforms.** MoonBit's JS
  backend numbers internal symbols per build platform; CI verifies behaviour
  instead, and that trade-off is documented in `DELIVERY.md`.
