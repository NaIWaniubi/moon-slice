# Changelog

## 0.2.0 — 2026-10-26

- Conservative inter-procedural expansion: `slice --interprocedural` and
  `html --interprocedural`; `Program.calls` records direct call sites.
- Call graph from recorded call sites, including calls in `let`/assign/return.
- Data-flow path query (`path --from A --to B`).
- `dead` now unions unused definitions and unreachable statements.
- Inline-SVG HTML report with source-order layout, slice-node table and metrics.
- Deterministic fuzz-style invariant tests; 188 tests total.
- Browser playground: `src/web` compiled to JavaScript + `web/index.html`;
  prebuilt engine and `web/smoke.mjs`.
- Zero compiler warnings; docs/ALGORITHMS.md, docs/DEMO.md, CI, benchmark.
