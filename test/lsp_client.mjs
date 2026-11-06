// A tiny LSP client: proves the server speaks the protocol and publishes the
// right diagnostics for a buffer, without needing an editor.
//
// Usage: node test/lsp_client.mjs [path-to-lsp-binary]
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';

const suffix = process.platform === 'win32' ? '.exe' : '';
const bin =
  process.argv[2] ?? `_build/native/release/build/cmd/lsp/lsp${suffix}`;
if (!existsSync(bin)) {
  console.error(`lsp client: no binary at ${bin}; build it with \`moon build --target native --release cmd/lsp\``);
  process.exit(2);
}

const child = spawn(bin, [], { stdio: ['pipe', 'pipe', 'inherit'] });

let buffer = Buffer.alloc(0);
const messages = [];
const waiters = [];

child.stdout.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  for (;;) {
    const headerEnd = buffer.indexOf('\r\n\r\n');
    if (headerEnd < 0) return;
    const header = buffer.slice(0, headerEnd).toString('ascii');
    const match = /Content-Length:\s*(\d+)/i.exec(header);
    if (!match) {
      console.error('lsp client: bad header', header);
      process.exit(1);
    }
    const length = Number(match[1]);
    if (buffer.length < headerEnd + 4 + length) return;
    const body = buffer.slice(headerEnd + 4, headerEnd + 4 + length).toString('utf8');
    buffer = buffer.slice(headerEnd + 4 + length);
    const message = JSON.parse(body);
    const waiter = waiters.shift();
    if (waiter) waiter(message);
    else messages.push(message);
  }
});

const send = (message) => {
  const body = Buffer.from(JSON.stringify(message), 'utf8');
  child.stdin.write(`Content-Length: ${body.length}\r\n\r\n`);
  child.stdin.write(body);
};

const next = () =>
  new Promise((resolve, reject) => {
    if (messages.length > 0) return resolve(messages.shift());
    const timer = setTimeout(() => reject(new Error('lsp client: timed out')), 15000);
    waiters.push((message) => {
      clearTimeout(timer);
      resolve(message);
    });
  });

const nextDiagnostics = async (uri) => {
  for (;;) {
    const message = await next();
    if (message.method === 'textDocument/publishDiagnostics' && message.params?.uri === uri) {
      return message.params.diagnostics;
    }
  }
};

const uri = 'file:///probe.mbt';
const deadSource = 'fn compute() -> Int {\n  let a = 1\n  let b = 2\n  a\n}\n';
const cleanSource = 'fn compute() -> Int {\n  let a = 1\n  a\n}\n';

try {
  send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { capabilities: {} } });
  const init = await next();
  if (init.id !== 1) throw new Error('initialize: wrong id');
  if (init.result?.capabilities?.textDocumentSync !== 1) {
    throw new Error(`initialize: unexpected capabilities ${JSON.stringify(init.result)}`);
  }

  send({ jsonrpc: '2.0', method: 'initialized', params: {} });
  send({
    jsonrpc: '2.0',
    method: 'textDocument/didOpen',
    params: { textDocument: { uri, languageId: 'moonbit', version: 1, text: deadSource } },
  });
  const first = await nextDiagnostics(uri);
  if (first.length !== 1) throw new Error(`didOpen: expected 1 diagnostic, got ${first.length}`);
  if (first[0].range.start.line !== 2) {
    throw new Error(`didOpen: expected line 2 (0-based), got ${first[0].range.start.line}`);
  }
  if (first[0].code !== 'dead-store') throw new Error(`didOpen: unexpected code ${first[0].code}`);

  send({
    jsonrpc: '2.0',
    method: 'textDocument/didChange',
    params: { textDocument: { uri, version: 2 }, contentChanges: [{ text: cleanSource }] },
  });
  const second = await nextDiagnostics(uri);
  if (second.length !== 0) throw new Error(`didChange: expected 0 diagnostics, got ${second.length}`);

  send({ jsonrpc: '2.0', id: 2, method: 'shutdown' });
  const shutdown = await next();
  if (shutdown.id !== 2 || shutdown.result !== null) throw new Error('shutdown: bad response');

  send({ jsonrpc: '2.0', method: 'exit' });
  const code = await new Promise((resolve) => child.on('exit', resolve));
  if (code !== 0) throw new Error(`exit code ${code}`);
  console.log('lsp client ok: initialize, diagnostics, change, shutdown, exit');
} catch (error) {
  console.error(`lsp client FAILED: ${error.message}`);
  child.kill();
  process.exit(1);
}
