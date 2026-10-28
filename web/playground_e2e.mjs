// Real-browser acceptance for the playground: one page, two consecutive runs.
// Uses headless Chrome via CDP, so a stale bundle or a re-declaration bug fails.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

const root = path.resolve(process.argv[2] ?? '.');
const chrome = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const port = 9411;
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'moon-slice-chrome-'));

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mbt': 'text/plain; charset=utf-8',
};
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  const rel = url.pathname === '/' ? '/web/index.html' : url.pathname;
  const file = path.resolve(root, '.' + rel);
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404);
    res.end('not found');
    return;
  }
  res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;

const proc = spawn(chrome, [
  '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run',
  `--user-data-dir=${profile}`, `--remote-debugging-port=${port}`, 'about:blank',
], { windowsHide: true, stdio: 'ignore' });

async function waitJson(url, tries = 80) {
  for (let i = 0; i < tries; i++) {
    try {
      const response = await fetch(url);
      if (response.ok) return await response.json();
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`no CDP endpoint at ${url}`);
}

let ws;
try {
  const version = await waitJson(`http://127.0.0.1:${port}/json/version`);
  ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });
  let id = 0;
  const pending = new Map();
  const exceptions = [];
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result);
    } else if (message.method === 'Runtime.exceptionThrown') {
      const details = message.params.exceptionDetails;
      exceptions.push(details.text + ': ' + (details.exception?.description ?? ''));
    }
  };
  const send = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      const messageId = ++id;
      pending.set(messageId, { resolve, reject });
      ws.send(JSON.stringify({ id: messageId, method, params, sessionId }));
    });

  const { targetId } = await send('Target.createTarget', { url: `${base}/web/index.html` });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  await send('Runtime.enable', {}, sessionId);
  await send('Page.enable', {}, sessionId);

  const evaluate = async (expression) => {
    const result = await send(
      'Runtime.evaluate',
      { expression, awaitPromise: true, returnByValue: true },
      sessionId,
    );
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text);
    }
    return result.result.value;
  };
  const statusText = `document.getElementById('status')?.textContent ?? ''`;
  const waitFor = async (expression, label, previous = null) => {
    for (let i = 0; i < 240; i++) {
      const value = await evaluate(expression);
      if (value && value !== previous) return value;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    const state = await evaluate(
      `JSON.stringify({
        status: ${statusText},
        out: document.getElementById('out')?.srcdoc?.slice(0, 300),
        engine: document.getElementById('engine')?.contentDocument?.documentElement?.innerHTML?.slice(0, 300),
      })`,
    );
    throw new Error(`timeout waiting for ${label}; state=${state}; exceptions=${exceptions.join(' | ')}`);
  };

  const first = await waitFor(
    `(${statusText}).startsWith('rendered') && (${statusText})`,
    'first render',
  );

  const probe = [
    '// @@MOONSLICE@@ marker must survive',
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
  const second = await waitFor(
    `(${statusText}).startsWith('rendered') && (${statusText})`,
    'second render',
    first,
  );

  const report = await evaluate(`document.getElementById('out').srcdoc`);
  const mutated = await evaluate(`document.documentElement.getAttribute('data-pwned')`);
  const markerPreserved = report.includes('@@MOONSLICE@@');

  if (!report.includes('&lt;script&gt;')) throw new Error('source was not HTML-escaped');
  if (report.includes('<script>document.documentElement')) throw new Error('raw script survived into the report');
  if (mutated !== null) throw new Error('injected script executed in the playground');
  if (!markerPreserved) throw new Error('source containing the old sentinel was truncated');
  if (exceptions.length) throw new Error('page exceptions: ' + exceptions.join(' | '));
  console.log(
    `playground e2e ok: first=${first.trim()}, second=${second.trim()}, bytes=${report.length}, markerPreserved=${markerPreserved}`,
  );
} finally {
  try {
    ws?.close();
  } catch {}
  proc.kill();
  server.close();
  await new Promise((resolve) => setTimeout(resolve, 500));
  try {
    fs.rmSync(profile, { recursive: true, force: true });
  } catch {}
}
