# Roadmap

The shipped surface is listed in `README.md`. This file records what is
deliberately missing and in what order it makes sense to add it.

## Next

1. **Cross-file call graph.** `dead --dir` analyses each file on its own, so a
   private function called from a sibling file is still an unknown. A
   package-level program (one `Program` per package, calls resolved across
   files) would make unused-function detection sound and improve
   `--interprocedural` beyond a single file.
2. **Unused function detection.** Blocked on the previous item: without
   visibility (`pub`) and cross-file calls it would produce false positives.
3. **A format for suppressions inside source.** Baselines are per line and
   survive edits poorly. A comment form (`// moon-slice: ignore dead-store`) is
   cheaper for reviewers and travels with the code.
4. **Editor integration.** The JSON contract is stable enough for a minimal
   LSP: didOpen/didChange → slice at cursor, publish the lines as diagnostics.
5. **More SARIF rules.** Today only `dead-store` and `unreachable-code`. A
   `no-path` result for a declared source→sink pair is the natural third rule.

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
