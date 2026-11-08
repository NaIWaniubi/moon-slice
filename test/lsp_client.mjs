// A tiny LSP client: proves the server speaks the protocol, publishes the right
// diagnostics, and answers hover and code actions, without needing an editor.
//
// Usage: node test/lsp_client.mjs [path-to-lsp-binary]
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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

const child = spawn(bin, [], { stdio: ['pipe', 'pipe', 'pipe'] });

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

// The server reports each package scan on stderr (stdout carries the protocol).
// The line says how many files were read and how many came from the cache,
// which is how this test observes that a second save does no work.
let stderrPending = '';
const logLines = [];
const logWaiters = [];

const flushLogs = () => {
  for (let i = 0; i < logWaiters.length; i += 1) {
    const waiter = logWaiters[i];
    const index = logLines.findIndex((line) => waiter.pattern.test(line));
    if (index >= 0) {
      const [line] = logLines.splice(index, 1);
      logWaiters.splice(i, 1);
      i -= 1;
      clearTimeout(waiter.timer);
      waiter.resolve(line);
    }
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

const nextLog = (pattern) =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`no stderr line matching ${pattern}`)),
      15000,
    );
    logWaiters.push({ pattern, resolve, reject, timer });
    flushLogs();
  });

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
  // Navigation is advertised as part of the same capability set.
  if (caps.definitionProvider !== true) throw new Error('initialize: no definitionProvider');
  if (caps.referencesProvider !== true) throw new Error('initialize: no referencesProvider');

  // The version the server reports is the version in the manifest; a release
  // that bumps one and forgets the other fails here rather than in the wild.
  const manifest = readFileSync(new URL('../moon.mod', import.meta.url), 'utf8');
  const declared = /^\s*version\s*=\s*"([^"]+)"/m.exec(manifest)?.[1];
  const reported = init.result?.serverInfo?.version;
  if (reported !== declared) {
    throw new Error(`initialize: serverInfo.version is ${JSON.stringify(reported)}, moon.mod says ${declared}`);
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
  // reported even though only the other file is open. The scan line reports
  // what it read, and both files are new on this first pass.
  const packageDir = mkdtempSync(join(tmpdir(), 'moon-slice-lsp-'));
  const tag = packageDir.split(/[\\/]/).pop();
  const scanLine = (files, reread, cached) =>
    new RegExp(
      `^moon-slice: package .*${tag}: ${files} files, ${reread} re-read, ${cached} cached$`,
    );
  const mainSource =
    'fn helper() -> Int {\n  1\n}\n\nfn main {\n  println(helper())\n}\n';
  writeFileSync(join(packageDir, 'a.mbt'), mainSource);
  writeFileSync(join(packageDir, 'b.mbt'), 'fn orphan() -> Int {\n  2\n}\n');
  const aUri = pathToFileURL(join(packageDir, 'a.mbt')).href;
  const bUri = pathToFileURL(join(packageDir, 'b.mbt')).href;
  const didSave = () =>
    send({
      jsonrpc: '2.0',
      method: 'textDocument/didSave',
      params: { textDocument: { uri: aUri } },
    });
  send({
    jsonrpc: '2.0',
    method: 'textDocument/didOpen',
    params: {
      textDocument: { uri: aUri, languageId: 'moonbit', version: 1, text: mainSource },
    },
  });
  await nextLog(scanLine(2, 2, 0));
  const sibling = await nextDiagnostics(bUri);
  if (sibling.length !== 1) throw new Error(`package: expected 1 sibling diagnostic, got ${sibling.length}`);
  if (sibling[0].code !== 'unused-function') {
    throw new Error(`package: unexpected code ${sibling[0].code}`);
  }
  if (!sibling[0].message.includes('orphan')) {
    throw new Error(`package: message does not name the function: ${sibling[0].message}`);
  }
  // The finding carries `src/roots`' evidence: how many roots were expanded and
  // why none of them reaches the name.
  if (!sibling[0].message.includes('reachability:')) {
    throw new Error(`package: message has no reachability evidence: ${sibling[0].message}`);
  }
  if (!sibling[0].message.includes('no function in the package calls')) {
    throw new Error(`package: message does not explain the missing edge: ${sibling[0].message}`);
  }

  // Hover on a private function declaration appends a liveness paragraph. For
  // a function `main` calls, that paragraph is the shortest chain from a root.
  const hoverAt = async (requestId, targetUri, line) => {
    send({
      jsonrpc: '2.0',
      id: requestId,
      method: 'textDocument/hover',
      params: { textDocument: { uri: targetUri }, position: { line, character: 3 } },
    });
    const response = await nextResponse(requestId);
    return response.result?.contents?.value ?? '';
  };
  const liveHover = await hoverAt(5, aUri, 0);
  if (!liveHover.includes('**liveness**')) {
    throw new Error(`hover: no liveness section for a private function: ${liveHover}`);
  }
  if (!liveHover.includes('reachable') || !liveHover.includes('`main`')) {
    throw new Error(`hover: no live chain through main: ${liveHover}`);
  }

  // The same paragraph on an unreachable function is the `explain_dead`
  // evidence: the root count and the incoming-edge accounting.
  const deadHover = await hoverAt(6, bUri, 0);
  if (!deadHover.includes('**liveness**') || !deadHover.includes('unreachable')) {
    throw new Error(`hover: no liveness evidence for a dead function: ${deadHover}`);
  }
  if (!deadHover.includes('no function in the package calls')) {
    throw new Error(`hover: the dead paragraph has no edge evidence: ${deadHover}`);
  }

  // Existing paragraphs are still there; the liveness one is additive.
  if (!liveHover.includes('backward slice') || !liveHover.includes('forward slice')) {
    throw new Error(`hover: slice paragraphs disappeared: ${liveHover}`);
  }

  // A save with nothing changed reuses both files: neither is read again.
  didSave();
  await nextLog(scanLine(2, 0, 2));
  const unchanged = await nextDiagnostics(bUri);
  if (unchanged.length !== 1) {
    throw new Error(`package: the cached scan changed its mind (${unchanged.length} findings)`);
  }

  // Rewriting a sibling changes its stamp, so it is read again while the open
  // file stays a hit — and the stale finding on the sibling disappears.
  writeFileSync(
    join(packageDir, 'b.mbt'),
    'pub fn spare() -> Int {\n  3\n}\n\npub fn other() -> Int {\n  4\n}\n',
  );
  didSave();
  await nextLog(scanLine(2, 1, 1));
  const cleared = await nextDiagnostics(bUri);
  if (cleared.length !== 0) {
    throw new Error(
      `package: expected the stale finding to clear, got ${JSON.stringify(cleared)}`,
    );
  }
  rmSync(packageDir, { recursive: true, force: true });

  // Navigation: `textDocument/definition` and `textDocument/references` work
  // on the package, not just the open file. The fixture's line numbers are
  // commented so the expected positions are readable next to them.
  const navDir = mkdtempSync(join(tmpdir(), 'moon-slice-nav-'));
  const navSource = [
    'struct Point {', // 0
    '  x : Int', // 1
    '  y : Int', // 2
    '}', // 3
    '', // 4
    'enum Shape {', // 5
    '  Circle(Int)', // 6
    '  Empty', // 7
    '}', // 8
    '', // 9
    'fn make(value : Int) -> Point {', // 10
    '  Point::{ x: value, y: value }', // 11
    '}', // 12
    '', // 13
    'fn helper() -> Int {', // 14
    '  let total = 0', // 15
    '  total', // 16
    '}', // 17
    '', // 18
    'impl Point with fn distance(self) -> Int {', // 19
    '  self.x', // 20
    '}', // 21
    '', // 22
    'fn main {', // 23
    '  let point = make(1)', // 24
    '  let shape = Shape::Circle(1)', // 25
    '  println(helper())', // 26
    '  println(point.distance())', // 27
    '}', // 28
  ].join('\n') + '\n';
  const navPath = join(navDir, 'a.mbt');
  writeFileSync(navPath, navSource);
  const navUri = pathToFileURL(navPath).href;

  const definitionAt = async (requestId, line, character) => {
    send({
      jsonrpc: '2.0',
      id: requestId,
      method: 'textDocument/definition',
      params: { textDocument: { uri: navUri }, position: { line, character } },
    });
    const response = await nextResponse(requestId);
    return response.result;
  };
  const referencesAt = async (requestId, line, character, includeDeclaration) => {
    send({
      jsonrpc: '2.0',
      id: requestId,
      method: 'textDocument/references',
      params: {
        textDocument: { uri: navUri },
        position: { line, character },
        context: { includeDeclaration },
      },
    });
    const response = await nextResponse(requestId);
    return response.result;
  };

  // `helper()` on line 26 jumps to its `fn helper` declaration on line 14.
  const helperDef = await definitionAt(10, 26, 11);
  if (!helperDef || !helperDef.uri.endsWith('/a.mbt')) {
    throw new Error(`definition: no location for helper ${JSON.stringify(helperDef)}`);
  }
  if (helperDef.range.start.line !== 14 || helperDef.range.start.character !== 3) {
    throw new Error(`definition: helper landed on ${JSON.stringify(helperDef.range)}`);
  }
  if (helperDef.range.end.line !== 14 || helperDef.range.end.character !== 9) {
    throw new Error(`definition: helper range has the wrong end ${JSON.stringify(helperDef.range.end)}`);
  }

  // A struct field: `self.x` on line 20 jumps to the field declared on line 1.
  const fieldDef = await definitionAt(11, 20, 7);
  if (!fieldDef || fieldDef.range.start.line !== 1 || fieldDef.range.start.character !== 2) {
    throw new Error(`definition: struct field landed on ${JSON.stringify(fieldDef?.range)}`);
  }

  // An enum variant: `Shape::Circle(1)` on line 25 jumps to line 6.
  const variantDef = await definitionAt(12, 25, 22);
  if (!variantDef || variantDef.range.start.line !== 6 || variantDef.range.start.character !== 2) {
    throw new Error(`definition: enum variant landed on ${JSON.stringify(variantDef?.range)}`);
  }

  // An `impl T with fn m` method: `point.distance()` on line 27 jumps to line 19.
  const methodDef = await definitionAt(13, 27, 18);
  if (!methodDef || methodDef.range.start.line !== 19 || methodDef.range.start.character !== 19) {
    throw new Error(`definition: impl method landed on ${JSON.stringify(methodDef?.range)}`);
  }

  // A `let` binding: `point` on line 27 jumps to `let point` on line 24.
  const letDef = await definitionAt(14, 27, 11);
  if (!letDef || letDef.range.start.line !== 24 || letDef.range.start.character !== 6) {
    throw new Error(`definition: let binding landed on ${JSON.stringify(letDef?.range)}`);
  }

  // A word with no declaration anywhere in the package is an explicit null.
  const unknownDef = await definitionAt(15, 26, 3);
  if (unknownDef !== null) {
    throw new Error(`definition: unknown name must be null, got ${JSON.stringify(unknownDef)}`);
  }

  // References include the declaration when the client asks for it: `helper`
  // is declared on line 14 and called on line 26.
  const helperRefs = await referencesAt(16, 14, 4, true);
  if (!Array.isArray(helperRefs) || helperRefs.length !== 2) {
    throw new Error(`references: expected 2 locations for helper, got ${JSON.stringify(helperRefs)}`);
  }
  const helperRefLines = helperRefs.map((location) => location.range.start.line);
  if (!helperRefLines.includes(14) || !helperRefLines.includes(26)) {
    throw new Error(`references: helper locations are ${JSON.stringify(helperRefLines)}`);
  }

  // ...and omit it when it does not.
  const helperUses = await referencesAt(17, 14, 4, false);
  if (!Array.isArray(helperUses) || helperUses.length !== 1) {
    throw new Error(`references: expected 1 use of helper, got ${JSON.stringify(helperUses)}`);
  }
  if (helperUses.some((location) => location.range.start.line === 14)) {
    throw new Error('references: the declaration leaked into a use-only result');
  }

  // Asking from the call site gives the same answer: the declaration is on
  // line 10, the call on line 24.
  const makeUses = await referencesAt(18, 24, 15, false);
  if (!Array.isArray(makeUses) || makeUses.length !== 1 || makeUses[0].range.start.line !== 24) {
    throw new Error(`references: make uses are ${JSON.stringify(makeUses)}`);
  }
  const makeAll = await referencesAt(19, 10, 4, true);
  if (!Array.isArray(makeAll) || makeAll.length !== 2) {
    throw new Error(`references: make with declaration is ${JSON.stringify(makeAll)}`);
  }

  // Unknown methods still fail as MethodNotFound, so a client never waits.
  send({ jsonrpc: '2.0', id: 20, method: 'textDocument/navigateNowhere', params: {} });
  const unknownMethod = await nextResponse(20);
  if (unknownMethod.error?.code !== -32601) {
    throw new Error(`unknown method: expected -32601, got ${JSON.stringify(unknownMethod)}`);
  }

  // Navigation changed nothing about hover on the same file.
  send({
    jsonrpc: '2.0',
    id: 21,
    method: 'textDocument/hover',
    params: { textDocument: { uri: navUri }, position: { line: 24, character: 3 } },
  });
  const navHover = (await nextResponse(21)).result?.contents?.value ?? '';
  if (!navHover.includes('backward slice') || !navHover.includes('forward slice')) {
    throw new Error(`hover: navigation regressed the slice paragraphs: ${navHover}`);
  }
  rmSync(navDir, { recursive: true, force: true });

  send({ jsonrpc: '2.0', id: 2, method: 'shutdown' });
  const shutdown = await nextResponse(2);
  if (shutdown.id !== 2 || shutdown.result !== null) throw new Error('shutdown: bad response');

  send({ jsonrpc: '2.0', method: 'exit' });
  const code = await new Promise((resolve) => child.on('exit', resolve));
  if (code !== 0) throw new Error(`exit code ${code}`);
  console.log(
    'lsp client ok: initialize, diagnostics, hover, code action, change, ' +
      'package scan, unused evidence, liveness hover, package cache, ' +
      'definition, references, includeDeclaration, unknown method, shutdown, exit',
  );
} catch (error) {
  console.error(`lsp client FAILED: ${error.message}`);
  if (logLines.length > 0) console.error(`server stderr:\n${logLines.join('\n')}`);
  child.kill();
  process.exit(1);
}
