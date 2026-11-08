// Benchmark for the editor's package scan.
//
// The Language Server re-analyses a whole package on open and on save. This
// script measures that pass twice: cold, with nothing cached, and warm, with
// every file untouched — the second number is what the per-file cache buys.
//
// Usage: node bench/scan.mjs [--dir PATH] [--files 1200] [--reps 3]
//
// Without --dir it generates a package of `--files` small files in the system
// temp directory. With --dir it scans that directory as-is (it must contain
// `.mbt` files) and opens the first one in sorted order, which makes the
// numbers comparable across runs on a real package.
//
// The server reports each scan on stderr, so the time from sending the message
// to receiving that line is the scan itself, measured by the same clock.

import { spawn } from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pathToFileURL } from 'node:url';

const args = new Map();
for (let i = 2; i < process.argv.length; i += 2) {
  args.set(process.argv[i].replace(/^--/, ''), process.argv[i + 1]);
}
const reps = Number(args.get('reps') ?? 3);
if (!Number.isFinite(reps) || reps < 1) {
  console.error('scan bench: --reps must be a positive integer');
  if (cleanup) cleanup();
  process.exit(2);
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const exe = [
  join(root, '_build', 'native', 'release', 'build', 'cmd', 'lsp', 'lsp.exe'),
  join(root, '_build', 'native', 'release', 'build', 'cmd', 'lsp', 'lsp'),
].find((path) => existsSync(path));
if (!exe) {
  console.error(
    'scan bench: build the server first: ./dev.sh build --target native --release cmd/lsp',
  );
  process.exit(2);
}

// A package of small files with no unused functions: one exported entry per
// file calls one private helper, so the liveness pass has nothing to chase and
// the measurement is the parse.
const synthetic = (i) =>
  `pub fn entry_${i}(x : Int) -> Int {\n` +
  `  let y = x + ${i % 97}\n` +
  `  helper_${i}(y)\n` +
  '}\n\n' +
  `fn helper_${i}(x : Int) -> Int {\n` +
  '  let z = x * 2\n' +
  '  z\n' +
  '}\n';

let dir = args.get('dir');
let cleanup = null;
if (dir) {
  dir = resolve(dir);
} else {
  const count = Number(args.get('files') ?? 1200);
  dir = mkdtempSync(join(tmpdir(), 'moon-slice-scan-'));
  cleanup = () => rmSync(dir, { recursive: true, force: true });
  for (let i = 0; i < count; i += 1) {
    writeFileSync(join(dir, `f${String(i).padStart(5, '0')}.mbt`), synthetic(i));
  }
}

const files = readdirSync(dir).filter((name) => name.endsWith('.mbt')).sort();
if (files.length === 0) {
  console.error(`scan bench: no .mbt files in ${dir}`);
  if (cleanup) cleanup();
  process.exit(2);
}
const anchor = join(dir, files[0]);
const anchorUri = pathToFileURL(anchor).href;
const anchorText = readFileSync(anchor, 'utf8');

const child = spawn(exe, [], { stdio: ['pipe', 'pipe', 'pipe'] });

let incoming = Buffer.alloc(0);
const responses = new Map();

child.stdout.on('data', (chunk) => {
  incoming = Buffer.concat([incoming, chunk]);
  for (;;) {
    const headerEnd = incoming.indexOf('\r\n\r\n');
    if (headerEnd < 0) return;
    const match = /Content-Length:\s*(\d+)/i.exec(incoming.slice(0, headerEnd).toString('ascii'));
    if (!match) {
      console.error('scan bench: bad header', incoming.slice(0, headerEnd).toString('ascii'));
      child.kill();
      process.exit(1);
    }
    const length = Number(match[1]);
    if (incoming.length < headerEnd + 4 + length) return;
    const body = incoming.slice(headerEnd + 4, headerEnd + 4 + length).toString('utf8');
    incoming = incoming.slice(headerEnd + 4 + length);
    let message;
    try {
      message = JSON.parse(body);
    } catch (error) {
      console.error('scan bench: non-JSON body from server:', body.slice(0, 120));
      child.kill();
      process.exit(1);
    }
    if (message.id !== undefined && responses.has(message.id)) {
      responses.get(message.id)(message);
      responses.delete(message.id);
    }
  }
});

let stderrPending = '';
const logLines = [];
const logWaiters = [];

const flushLogs = () => {
  while (logWaiters.length > 0 && logLines.length > 0) {
    const line = logLines.shift();
    const waiter = logWaiters.shift();
    clearTimeout(waiter.timer);
    waiter.resolve(line);
  }
};

child.stderr.setEncoding('utf8');
child.stderr.on('data', (chunk) => {
  stderrPending += chunk;
  let newline;
  while ((newline = stderrPending.indexOf('\n')) >= 0) {
    const line = stderrPending.slice(0, newline).trim();
    stderrPending = stderrPending.slice(newline + 1);
    if (line) logLines.push(line);
  }
  flushLogs();
});

const nextLog = () =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('scan bench: timed out')), 120000);
    logWaiters.push({ resolve, reject, timer });
    flushLogs();
  });

const send = (message) => {
  const body = Buffer.from(JSON.stringify(message), 'utf8');
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
};

const request = (id, method, params) =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`scan bench: ${method} timed out`)), 120000);
    responses.set(id, (message) => {
      clearTimeout(timer);
      resolve(message);
    });
    send({ jsonrpc: '2.0', id, method, params });
  });

const scan = async (message) => {
  const started = process.hrtime.bigint();
  send(message);
  const line = await nextLog();
  return { ms: Number(process.hrtime.bigint() - started) / 1e6, line };
};

const main = async () => {
  await request(1, 'initialize', { capabilities: {} });
  send({ jsonrpc: '2.0', method: 'initialized', params: {} });

  // The first open is the only cold scan: once the directory is cached a
  // second open would already be warm.
  const cold = await scan({
    jsonrpc: '2.0',
    method: 'textDocument/didOpen',
    params: {
      textDocument: { uri: anchorUri, languageId: 'moonbit', version: 1, text: anchorText },
    },
  });

  const warm = [];
  for (let i = 0; i < reps; i += 1) {
    warm.push(
      await scan({
        jsonrpc: '2.0',
        method: 'textDocument/didSave',
        params: { textDocument: { uri: anchorUri } },
      }),
    );
  }

  const coldMs = cold.ms;
  const warmMs = Math.min(...warm.map((run) => run.ms));
  if (!Number.isFinite(coldMs) || !Number.isFinite(warmMs)) {
    console.error('scan bench: no samples were taken');
    if (cleanup) cleanup();
    process.exit(1);
  }
  const perFile = (ms) => (ms / files.length).toFixed(3);
  console.log(`scan bench: ${files.length} files in ${dir}`);
  console.log(`  cold (first open): ${coldMs.toFixed(1)} ms (${perFile(coldMs)} ms/file)`);
  console.log(`  warm (no change):  ${warmMs.toFixed(1)} ms (${perFile(warmMs)} ms/file)`);
  console.log(`  speedup: ${(coldMs / warmMs).toFixed(1)}x`);
  console.log(`  ${cold.line}`);
  if (warm[0]) console.log(`  ${warm[0].line}`);
};

main()
  .then(async () => {
    await request(2, 'shutdown', undefined);
    send({ jsonrpc: '2.0', method: 'exit' });
    child.on('exit', (code) => {
      if (cleanup) cleanup();
      process.exit(code ?? 0);
    });
  })
  .catch((error) => {
    console.error(`scan bench FAILED: ${error.message}`);
    if (cleanup) cleanup();
    child.kill();
    process.exit(1);
  });
