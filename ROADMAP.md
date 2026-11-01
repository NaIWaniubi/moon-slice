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

## Next

1. **Receiver edges beyond `callers`.** The slice expander and `unused` still
   ignore `x.f()`. Doing that safely needs more than annotations: a return-type
   environment, and a rule for methods reached through a trait.
2. **Editor integration.** The JSON contract is stable enough for a minimal
   LSP: didOpen/didChange → slice at cursor, publish the lines as diagnostics.
3. **A path rule in SARIF.** `dead-store`, `unreachable-code` and
   `unused-function` are reported today; `path --from A --to B` has no rule yet.

## Considered, not planned

- **Taint analysis as a product.** `path --from A --to B` is a useful query, but
  a real taint mode needs sources/sinks/sanitizers as first-class inputs; that is
  a different tool built on the same PDG.
- **Byte-for-byte reproducible JS bundles across platforms.** MoonBit's JS
  backend numbers internal symbols per build platform; CI verifies behaviour
  instead, and that trade-off is documented in `DELIVERY.md`.
