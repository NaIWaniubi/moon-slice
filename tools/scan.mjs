// Scan a directory of MoonBit files with `moon-slice dead` and print a summary.
//
//   node tools/scan.mjs <path-to-moon-slice-binary> <source-root>
//
// Used for the real-world case study in docs/CASE_STUDY.md: it reports how many
// files parsed, how many reported dead code, and the per-file hits, so the
// numbers in the document can be reproduced instead of trusted.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [exe, root] = process.argv.slice(2);
if (!exe || !root) {
  console.error('usage: node tools/scan.mjs <moon-slice-binary> <source-root>');
  process.exit(2);
}

const files = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!['.git', '_build', '.mooncakes', 'node_modules'].includes(entry.name)) walk(full);
    } else if (entry.name.endsWith('.mbt')) {
      files.push(full);
    }
  }
})(root);

let parseFailures = 0;
let clean = 0;
let withHits = 0;
let hitLines = 0;
let sourceLines = 0;
const perFile = [];

for (const file of files) {
  sourceLines += fs.readFileSync(file, 'utf8').split('\n').length;
  const result = spawnSync(exe, ['dead', '--file', file, '--json'], {
    encoding: 'utf8',
    maxBuffer: 1 << 26,
  });
  if (result.status !== 0) {
    parseFailures++;
    continue;
  }
  const report = JSON.parse(result.stdout);
  if (report.errors && report.errors.length > 0) {
    parseFailures++;
    continue;
  }
  if (!report.lines || report.lines.length === 0) {
    clean++;
    continue;
  }
  withHits++;
  hitLines += report.lines.length;
  perFile.push({ file: path.relative(root, file), lines: report.lines });
}

perFile.sort((a, b) => b.lines.length - a.lines.length);
console.log(
  JSON.stringify(
    {
      root,
      files: files.length,
      sourceLines,
      parseFailures,
      clean,
      withHits,
      hitLines,
      perFile,
    },
    null,
    2,
  ),
);
