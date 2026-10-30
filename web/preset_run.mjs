// Runs the browser engine once for one example and prints its embedded result.
// A separate process per example keeps the bundle's module state fresh.
let output = '';
const spec = JSON.parse(process.argv[2]);
globalThis.moonSliceReadInput = () => [spec.direction || 'backward', String(spec.line), '', spec.source].join('\n');
globalThis.moonSliceWriteOutput = (html) => { output = html; };
await import('./moon-slice.js');
const match = output.match(/<script type="application\/json" id="moon-slice-result">([\s\S]*?)<\/script>/);
console.log(JSON.stringify({
  bytes: output.length,
  result: match ? JSON.parse(match[1]) : null,
}));
