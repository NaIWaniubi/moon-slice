// Verifies the playground's own example presets: each must name a line that
// holds a statement and produce a non-empty slice. Reads the data straight out
// of index.html, so a mistyped line number in the page fails here.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';

const page = fs.readFileSync(new URL('./index.html', import.meta.url), 'utf8');
const start = page.indexOf('const EXAMPLES = {');
const end = page.indexOf('\n  };', start);
if (start < 0 || end < 0) throw new Error('EXAMPLES block not found');
const EXAMPLES = eval('(' + page.slice(start + 'const EXAMPLES = '.length, end + 4) + ')');

let bad = 0;
for (const [name, example] of Object.entries(EXAMPLES)) {
  const run = spawnSync(process.execPath, [
    new URL('./preset_run.mjs', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'),
    JSON.stringify({ line: example.line, source: example.source, direction: example.direction }),
  ], { encoding: 'utf8' });
  const lineCount = example.source.split('\n').length - 1;
  if (run.status !== 0) {
    console.log(`${name}: engine failed\n${run.stderr}`);
    bad++;
    continue;
  }
  const { result } = JSON.parse(run.stdout);
  const ok = result && result.target && result.target.line === example.line && result.nodes.length > 0;
  if (!ok) bad++;
  console.log(
    `${name}: line ${example.line} of ${lineCount} -> target ${result?.target?.line}, ` +
    `nodes ${result?.nodes?.length}, lines ${result?.lines?.join(',')} ${ok ? '' : ' <-- BAD'}`,
  );
}
if (bad) throw new Error(`${bad} preset(s) do not resolve`);

// The engine must honour every direction the page offers, not only the default.
// These expectations are the same numbers the CLI documents for the same input.
function runOne(source, line, direction) {
  const engine = spawnSync(process.execPath, [
    new URL('./preset_run.mjs', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'),
    JSON.stringify({ line, source, direction }),
  ], { encoding: 'utf8' });
  if (engine.status !== 0) throw new Error(`engine failed for ${direction}\n${engine.stderr}`);
  return JSON.parse(engine.stdout).result;
}

const looping = EXAMPLES.while.source;
const directions = [
  ['backward', looping, 7, [4, 5, 6, 7, 8]],
  ['forward', looping, 7, [7, 10]],
  ['interprocedural', EXAMPLES.interproc.source, 12, [2, 6, 7, 8, 12]],
];
for (const [direction, source, line, expected] of directions) {
  const got = runOne(source, line, direction).lines;
  if (JSON.stringify(got) !== JSON.stringify(expected)) {
    throw new Error(`${direction} slice of line ${line}: expected ${expected}, got ${got}`);
  }
  console.log(`direction ${direction}: lines ${got.join(',')}`);
}
console.log('playground presets ok');
