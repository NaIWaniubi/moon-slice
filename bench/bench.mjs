// Reproducible benchmark for the analysis pipeline.
//
// Measures the native release binary, not `moon run`, so the numbers describe
// the analysis rather than the compiler's startup cost. Each size is run
// `REPS` times after a warm-up; the report gives the minimum, because that is
// the least noisy statistic on a desktop.
//
// Usage: node bench/bench.mjs [--sizes 500,2000,8000] [--reps 3]
// It builds the native release binary first, then generates inputs into the
// system temp directory (never into the repository).

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) {
  args.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1]);
}
const sizes = (args.get('sizes') ?? '500,2000,8000').split(',').map(Number);
const reps = Number(args.get('reps') ?? 3);

const root = path.resolve(new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const exe = path.join(root, '_build', 'native', 'release', 'build', 'cmd', 'main', 'main.exe');
if (!fs.existsSync(exe)) {
  throw new Error(`missing ${exe}; run: ./dev.sh build --target native --release cmd/main`);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'moon-slice-bench-'));

function generate(n, file) {
  const lines = ['fn big() -> Int {', '  let mut x = 0'];
  for (let i = 0; i < n; i++) lines.push(`  x = x + ${i % 7 + 1}`);
  lines.push('  return x', '}', '');
  fs.writeFileSync(file, lines.join('\n'));
}

function time(command, file) {
  const start = process.hrtime.bigint();
  const result = spawnSync(exe, [...command, '--file', file], { encoding: 'utf8', maxBuffer: 1 << 28 });
  const end = process.hrtime.bigint();
  if (result.status !== 0) {
    throw new Error(`${command.join(' ')} failed: ${result.stdout}${result.stderr}`);
  }
  return Number(end - start) / 1e6;
}

const rows = [];
try {
  for (const n of sizes) {
    const file = path.join(tmp, `big-${n}.mbt`);
    generate(n, file);
    // Warm the file cache and the binary.
    time(['slice', '--line', String(n + 3), '--direction', 'backward'], file);

    const cases = {
      slice: ['slice', '--line', String(n + 3), '--direction', 'backward'],
      dead: ['dead'],
      graph: ['graph'],
    };
    for (const [name, command] of Object.entries(cases)) {
      const samples = [];
      for (let r = 0; r < reps; r++) samples.push(time(command, file));
      rows.push({ statements: n, command: name, min_ms: Math.min(...samples).toFixed(0) });
    }
  }
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

console.log('| statements | command | min wall time (ms) |');
console.log('| --- | --- | --- |');
for (const row of rows) console.log(`| ${row.statements} | \`${row.command}\` | ${row.min_ms} |`);
