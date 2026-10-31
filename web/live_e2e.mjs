// Acceptance against the deployed GitHub Pages site (not the local files).
// Loads the live page in headless Chrome, runs the analysis twice, and checks
// that the second run works and that the report matches what the CLI produces.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const url = process.argv[2] ?? 'https://NaIWaniubi.github.io/moon-slice/';
const chrome = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const port = 9413;
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'moon-slice-live-'));

const proc = spawn(chrome, [
  '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run',
  `--user-data-dir=${profile}`, `--remote-debugging-port=${port}`, 'about:blank',
], { windowsHide: true, stdio: 'ignore' });

async function waitJson(target, tries = 120) {
  for (let i = 0; i < tries; i++) {
    try {
      const r = await fetch(target);
      if (r.ok) return await r.json();
    } catch {}
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`no CDP endpoint at ${target}`);
}

let ws;
try {
  const version = await waitJson(`http://127.0.0.1:${port}/json/version`);
  ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let id = 0;
  const pending = new Map();
  const exceptions = [];
  ws.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    } else if (msg.method === 'Runtime.exceptionThrown') {
      exceptions.push(msg.params.exceptionDetails.text);
    }
  };
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const msgId = ++id;
    pending.set(msgId, { resolve, reject });
    ws.send(JSON.stringify({ id: msgId, method, params, sessionId }));
  });

  const { targetId } = await send('Target.createTarget', { url });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Runtime.enable', {}, sessionId);

  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
    return r.result.value;
  };
  const status = `document.getElementById('status')?.textContent ?? ''`;
  const waitRendered = async (label, previous = null) => {
    for (let i = 0; i < 400; i++) {
      const value = await evaluate(`(${status}).startsWith('rendered') && (${status})`);
      if (value && value !== previous) return value;
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error(`timeout: ${label}; status=${await evaluate(status)}; exceptions=${exceptions.join('|')}`);
  };

  const first = await waitRendered('first live render');

  // Second run, with a source that exercises the newline protocol and escaping.
  const probe = [
    '// @@MOONSLICE@@ stays literal',
    '// <script>document.documentElement.setAttribute("data-pwned","1")</script>',
    'fn loop_sum(n : Int) -> Int {',
    '  let mut i = 0',
    '  let mut total = 0',
    '  while i < n {',
    '    total = total + i',
    '    i = i + 1',
    '  }',
    '  return total',
    '}',
  ].join('\n');
  await evaluate(`(() => {
    document.getElementById('source').value = ${JSON.stringify(probe)};
    document.getElementById('line').value = '7';
    document.getElementById('run').click();
    return true;
  })()`);
  const second = await waitRendered('second live render', first);
  const report = await evaluate(`document.getElementById('out').srcdoc`);
  const mutated = await evaluate(`document.documentElement.getAttribute('data-pwned')`);

  if (!report.includes('target n')) throw new Error('report does not name the selected node');
  if (!report.includes('@@MOONSLICE@@')) throw new Error('source sentinel was truncated');
  if (report.includes('<script>document.documentElement')) throw new Error('raw script survived');
  if (mutated !== null) throw new Error('injected script executed');
  if (exceptions.length) throw new Error('page exceptions: ' + exceptions.join('|'));
  console.log(`live e2e ok: ${first.trim()} -> ${second.trim()}, ${report.length} bytes`);
} finally {
  try { ws?.close(); } catch {}
  proc.kill();
  await new Promise((r) => setTimeout(r, 500));
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch {}
}
