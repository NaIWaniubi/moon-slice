// A tiny LSP client: proves the server speaks the protocol, publishes the right
// diagnostics, and answers hover and code actions, without needing an editor.
//
// Usage: node test/lsp_client.mjs [path-to-lsp-binary]
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

// MoonBit names the native artifact `lsp.exe` on every platform; accept the
// suffix-less name too so a future toolchain that drops it keeps working.
const candidates = process.argv[2]
  ? [process.argv[2]]
  : [
      '_build/native/release/build/cmd/lsp/lsp.exe',
      '_build/native/release/build/cmd/lsp/lsp',
    ];
const bin = candidates.find((path) => existsSync(path));
if (!bin) {
  console.error(
    `lsp client: no binary at ${candidates.join(' or ')}; ` +
      'build it with `moon build --target native --release cmd/lsp`',
  );
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

// A response can arrive after notifications (the package scan publishes for
// other files), so wait for the matching id rather than the next message.
const nextResponse = async (id) => {
  for (;;) {
    const message = await next();
    if (message.id === id) return message;
  }
};

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
  const init = await nextResponse(1);
  if (init.id !== 1) throw new Error('initialize: wrong id');
  const caps = init.result?.capabilities ?? {};
  if (caps.textDocumentSync !== 1) {
    throw new Error(`initialize: unexpected capabilities ${JSON.stringify(init.result)}`);
  }
  if (caps.hoverProvider !== true) throw new Error('initialize: no hoverProvider');
  if (caps.codeActionProvider !== true) throw new Error('initialize: no codeActionProvider');

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

  // Hover on the dead line: the backward slice should name the statement count.
  send({
    jsonrpc: '2.0',
    id: 3,
    method: 'textDocument/hover',
    params: { textDocument: { uri }, position: { line: 2, character: 4 } },
  });
  const hover = await nextResponse(3);
  if (hover.id !== 3) throw new Error('hover: wrong id');
  const hoverText = hover.result?.contents?.value ?? '';
  if (!hoverText.includes('backward slice')) {
    throw new Error(`hover: unexpected contents ${JSON.stringify(hover.result)}`);
  }
  if (!hoverText.includes('lines:')) throw new Error(`hover: no line list in ${hoverText}`);

  // Code action: the quick fix appends the same directive the CLI honours.
  send({
    jsonrpc: '2.0',
    id: 4,
    method: 'textDocument/codeAction',
    params: {
      textDocument: { uri },
      range: first[0].range,
      context: { diagnostics: first },
    },
  });
  const actions = await nextResponse(4);
  if (actions.id !== 4) throw new Error('codeAction: wrong id');
  const action = actions.result?.[0];
  if (!action) throw new Error('codeAction: no action returned');
  const edit = action.edit?.changes?.[uri]?.[0];
  if (!edit) throw new Error('codeAction: no edit returned');
  if (!edit.newText.includes('moon-slice: ignore[dead-store]')) {
    throw new Error(`codeAction: unexpected newText ${edit.newText}`);
  }
  if (edit.range.start.line !== 2) throw new Error('codeAction: edit on the wrong line');

  send({
    jsonrpc: '2.0',
    method: 'textDocument/didChange',
    params: { textDocument: { uri, version: 2 }, contentChanges: [{ text: cleanSource }] },
  });
  const second = await nextDiagnostics(uri);
  if (second.length !== 0) throw new Error(`didChange: expected 0 diagnostics, got ${second.length}`);

  // Package-wide diagnostics: an unused private function in a sibling file is
  // reported even though only the other file is open.
  const packageDir = mkdtempSync(join(tmpdir(), 'moon-slice-lsp-'));
  const mainSource =
    'fn helper() -> Int {\n  1\n}\n\nfn main {\n  println(helper())\n}\n';
  writeFileSync(join(packageDir, 'a.mbt'), mainSource);
  writeFileSync(join(packageDir, 'b.mbt'), 'fn orphan() -> Int {\n  2\n}\n');
  const aUri = pathToFileURL(join(packageDir, 'a.mbt')).href;
  const bUri = pathToFileURL(join(packageDir, 'b.mbt')).href;
  send({
    jsonrpc: '2.0',
    method: 'textDocument/didOpen',
    params: {
      textDocument: { uri: aUri, languageId: 'moonbit', version: 1, text: mainSource },
    },
  });
  const sibling = await nextDiagnostics(bUri);
  if (sibling.length !== 1) throw new Error(`package: expected 1 sibling diagnostic, got ${sibling.length}`);
  if (sibling[0].code !== 'unused-function') {
    throw new Error(`package: unexpected code ${sibling[0].code}`);
  }
  if (!sibling[0].message.includes('orphan')) {
    throw new Error(`package: message does not name the function: ${sibling[0].message}`);
  }
  rmSync(packageDir, { recursive: true, force: true });

  send({ jsonrpc: '2.0', id: 2, method: 'shutdown' });
  const shutdown = await nextResponse(2);
  if (shutdown.id !== 2 || shutdown.result !== null) throw new Error('shutdown: bad response');

  send({ jsonrpc: '2.0', method: 'exit' });
  const code = await new Promise((resolve) => child.on('exit', resolve));
  if (code !== 0) throw new Error(`exit code ${code}`);
  console.log('lsp client ok: initialize, diagnostics, hover, code action, change, package scan, shutdown, exit');
} catch (error) {
  console.error(`lsp client FAILED: ${error.message}`);
  child.kill();
  process.exit(1);
}
