// Generate a straight-line benchmark program: N assignments plus a return.
// Usage: node bench/gen.mjs 500 > /tmp/big.mbt
import { writeFileSync } from 'node:fs';
const n = Number(process.argv[2] ?? 500);
const lines = ['fn big() -> Int {', '  let mut x = 0'];
for (let i = 0; i < n; i++) lines.push(`  x = x + ${i % 7 + 1}`);
lines.push('  return x', '}', '');
writeFileSync(process.argv[3] ?? '/tmp/big.mbt', lines.join('\n'));
console.log(`wrote ${n} assignments, target line ${n + 3}`);
