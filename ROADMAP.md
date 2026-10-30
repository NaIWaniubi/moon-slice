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

## Next

1. **Receiver calls.** `x.f()` is not followed: the receiver's type is unknown, so
   attributing it would invent a call. Real type resolution would close the last
   gap in the call graph and let `unused` see methods as well.
2. **A format for suppressions inside source.** Baselines are per line and
   survive edits poorly. A comment form (`// moon-slice: ignore dead-store`) is
   cheaper for reviewers and travels with the code.
3. **Editor integration.** The JSON contract is stable enough for a minimal
   LSP: didOpen/didChange → slice at cursor, publish the lines as diagnostics.
4. **A path rule in SARIF.** `dead-store`, `unreachable-code` and
   `unused-function` are reported today; `path --from A --to B` has no rule yet.

## Considered, not planned

- **Taint analysis as a product.** `path --from A --to B` is a useful query, but
  a real taint mode needs sources/sinks/sanitizers as first-class inputs; that is
  a different tool built on the same PDG.
- **Byte-for-byte reproducible JS bundles across platforms.** MoonBit's JS
  backend numbers internal symbols per build platform; CI verifies behaviour
  instead, and that trade-off is documented in `DELIVERY.md`.
- **Publishing to mooncakes.** The module is publishable (`moon publish`), but
  release credentials belong to the maintainer account; the repository stays the
  install path until then.
