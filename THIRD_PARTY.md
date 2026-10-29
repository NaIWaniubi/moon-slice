# Third-party notices

moon-slice is original code released under Apache-2.0 (`LICENSE`). It depends on
two MoonBit packages, both Apache-2.0:

| Package | Version | License | Used for |
| --- | --- | --- | --- |
| `moonbitlang/parser` | 0.4.6 | Apache-2.0 | MoonBit syntax tree front end (`src/parser_adapter`) |
| `moonbitlang/x` | 0.5.1 | Apache-2.0 | filesystem and process shims (`cmd/main`) |

Their license texts are distributed inside the module cache
(`.mooncakes/moonbitlang/*/LICENSE`) and are not copied into this repository.
The `moon.mod` `import` block pins both versions.

The algorithms are from the literature, not from another codebase:

- Mark Weiser, *Program Slicing* (1981) — the slicing formulation.
- Jeanne Ferrante, Karl Ottenstein, Joe Warren, *The Program Dependence Graph
  and Its Use in Optimization* (1987) — control dependence via post-dominators.

No source code from other slicers is copied. The playground and reports use no
third-party JavaScript; `web/moon-slice.js` is a build of this repository's
MoonBit sources.
