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
```

The engine exposes two JS globals:

```js
moonSliceReadInput()          // "direction@@MOONSLICE@@line@@MOONSLICE@@source"
moonSliceWriteOutput(html)    // receives the self-contained report
```

The `@@MOONSLICE@@` separator is chosen because it cannot occur in a MoonBit
source file in practice; the host page joins and the MoonBit side splits.
