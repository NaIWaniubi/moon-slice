// Poll the Tower engine until every mission reaches a terminal state, then
// print the final markdown table. Read-only: never starts/stops/merges.
// Usage: node tools/tower-watch.mjs [repo] [intervalSec] [maxMinutes]
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const repo = process.argv[2] || process.cwd();
const intervalSec = Number(process.argv[3] || 30);
const maxMinutes = Number(process.argv[4] || 120);
const fleet = 'C:/Users/chen/.zcode/cli/plugins/cache/dev-myzcode-default/zcode-fleet/0.5.6/bin/fleet.mjs';
const stateFile = path.join(repo, '.tower', 'state.json');
const terminal = new Set(['merged', 'approved', 'rejected', 'failed', 'cancelled', 'merge_conflict', 'regression', 'verify_failed']);

function readState() {
  try {
    return JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  } catch {
    return null;
  }
}

function poll() {
  // tower status advances the engine (finalizes dead workers, starts reviewers).
  const r = spawnSync(process.execPath, [fleet, 'tower', 'status', '--cwd', repo], {
    encoding: 'utf8',
    windowsHide: true,
    timeout: 120000,
  });
  if (r.status !== 0) {
    console.error(`poll failed: ${(r.stderr || r.stdout || '').slice(0, 300)}`);
  }
}

const deadline = Date.now() + maxMinutes * 60000;
let lastSig = '';
for (;;) {
  poll();
  const state = readState();
  if (!state) {
    console.error('no state yet');
  } else {
    const missions = state.missions || [];
    const sig = missions.map((m) => `${m.id}:${m.status}:${(m.commit || '').slice(0, 8)}:${m.review?.verdict || ''}`).join('|');
    if (sig !== lastSig) {
      lastSig = sig;
      const counts = {};
      for (const m of missions) counts[m.status] = (counts[m.status] || 0) + 1;
      console.log(`[${new Date().toISOString()}] phase=${state.phase} ${JSON.stringify(counts)}`);
      for (const m of missions) {
        console.log(`  ${m.id} ${m.status.padEnd(14)} ${(m.commit || '').slice(0, 8).padEnd(8)} ${m.review?.verdict || '-'}  ${m.title}`);
      }
    }
    const allTerminal = missions.length > 0 && missions.every((m) => terminal.has(m.status));
    if (allTerminal || state.phase === 'complete' || state.phase === 'error') {
      console.log('FINAL');
      console.log(state.markdown || JSON.stringify({ phase: state.phase, counts: state.counts }, null, 2));
      break;
    }
  }
  if (Date.now() > deadline) {
    console.log('TIMEOUT — engine may still be running; check .tower/state.json');
    break;
  }
  await new Promise((r) => setTimeout(r, intervalSec * 1000));
}
