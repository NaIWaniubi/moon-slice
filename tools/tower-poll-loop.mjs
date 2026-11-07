// Poll the Tower engine every 60s, print state changes, exit when all terminal.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
const repo = process.argv[2];
const fleet = 'C:/Users/chen/.zcode/cli/plugins/cache/dev-myzcode-default/zcode-fleet/0.5.6/bin/fleet.mjs';
const terminal = new Set(['merged','approved','rejected','failed','cancelled','merge_conflict','regression','verify_failed']);
let last = '';
for (let i = 0; i < 180; i++) {
  spawnSync(process.execPath, [fleet, 'tower', 'status', '--cwd', repo], { encoding: 'utf8', windowsHide: true, timeout: 120000 });
  let s;
  try { s = JSON.parse(fs.readFileSync(repo + '/.tower/state.json', 'utf8')); } catch { await new Promise(r => setTimeout(r, 60000)); continue; }
  const sig = s.missions.map(m => `${m.id}:${m.status}:${(m.commit||'').slice(0,8)}:${m.review?.verdict||''}`).join('|');
  if (sig !== last) {
    last = sig;
    console.log(`[${new Date().toISOString()}] phase=${s.phase}`);
    for (const m of s.missions) console.log(`  ${m.id} ${m.status.padEnd(14)} ${(m.commit||'').slice(0,8).padEnd(8)} ${m.review?.verdict||'-'}  ${m.title}`);
  }
  if (s.missions.length > 0 && s.missions.every(m => terminal.has(m.status))) { console.log('ALL TERMINAL'); break; }
  await new Promise(r => setTimeout(r, 60000));
}
