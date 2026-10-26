// Headless smoke test for the browser engine: define the two globals the JS
// build expects, load the bundle, and assert that it produced a report.
import fs from 'node:fs';

const source = fs.readFileSync(new URL('../examples/04_while.mbt', import.meta.url), 'utf8');
let output = '';
globalThis.moonSliceReadInput = () => ['backward', '7', source].join('@@MOONSLICE@@');
globalThis.moonSliceWriteOutput = (html) => { output = html; };
await import('../web/moon-slice.js');
if (!output.includes('<!doctype html>')) throw new Error('no HTML document');
if (!output.includes('<svg')) throw new Error('no inline SVG');
if (!output.includes('class="hit"')) throw new Error('no highlighted source');
if (!output.includes('Slice nodes')) throw new Error('no slice table');
if (!output.includes('<td>4</td>')) throw new Error('missing line 4 in table');
if (!output.includes('<td>7</td>')) throw new Error('missing line 7 in table');
console.log('web smoke ok:', output.length, 'bytes');
