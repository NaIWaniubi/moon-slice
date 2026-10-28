# Browser playground

`index.html` is a single-page playground: edit MoonBit source, choose a line
and direction, and render the full HTML report in the iframe. The analysis is
the same MoonBit pipeline compiled to JavaScript; there is no server and no
network dependency.

## Open it

Open `web/index.html` directly in a browser. The prebuilt engine is
`web/moon-slice.js`.

## Rebuild the engine

```bash
bash web/build.sh      # moon build --target js src/web + copy
node web/smoke.mjs     # headless assertion
node web/playground_e2e.mjs .   # real Chrome: two consecutive runs in one page
```

`playground_e2e.mjs` needs Chrome at the default Windows path. It serves the
repository over loopback, drives a headless browser through CDP, and asserts
that the first and second run both render, that source text containing the old
`@@MOONSLICE@@` sentinel is preserved, and that a `<script>` in the source is
escaped rather than executed.

The engine exposes two JS globals:

```js
moonSliceReadInput()          // "direction\\nline\\nsource"
moonSliceWriteOutput(html)    // receives the self-contained report
```

The host loads each run in a fresh hidden iframe. This keeps the generated
bundle's top-level declarations isolated, so repeated edits and clicks render
independent reports without redeclaration errors. The source is transmitted
as the remainder after the first two newline-delimited fields; source text is
not split on a sentinel string.
