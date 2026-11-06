# Changelog

## 0.9.0 — 2026-11-06

The Language Server does more than underline findings.

- **Hover shows the backward slice.** Ask for hover on any line and the server
  runs the same pipeline as `slice` — CFG, def-use, CDG, PDG, backward BFS — and
  answers with the statement count and the line list in Markdown. It is the
  first editor surface for the analysis itself, not just for the warnings.
- **A quick fix suppresses a finding.** `textDocument/codeAction` on a
  diagnostic returns one action that appends `// moon-slice: ignore[rule]` at
  the end of the line, which is exactly what the CLI and CI honour, so the
  editor and the gate agree by construction.
- **The client test covers both.** `test/lsp_client.mjs` now asserts the
  `hoverProvider` / `codeActionProvider` capabilities, that hover mentions the
  slice, and that the code action's edit carries the directive on the right
  line — before it checks that a clean rewrite clears the diagnostics.
- 376 unit tests unchanged; the new coverage is end-to-end, on Linux and
  Windows.

## 0.8.1 — 2026-11-06

Portability fixes for the LSP, found by CI rather than by the local toolchain.

- **The Json type is never named.** CI's newer core reports `@builtin.Json` as
  undefined while the local one resolves it; the server only needs the value
  `@json.parse` returns, so the handler pattern-matches on it instead of
  annotating a parameter.
- **The client accepts `lsp.exe` on Linux too.** MoonBit names the native
  artifact with the extension on every platform, so the suffix-less guess missed
  it; both names are now tried.
- No library or CLI behaviour changes: 376 unit tests, the CLI smoke, the bundle
  smokes and the LSP client all pass on Linux and Windows.

## 0.8.0 — 2026-11-06

The analysis now runs inside the editor.

- **`cmd/lsp`: a real Language Server.** `moonbitlang/async`'s stdio reader is
  the transport, so there is no hand-rolled buffer: `read_until` splits one
  header line at a time, `read_exactly` reads the body, and `Content-Length`
  framing stays exact for multi-byte UTF-8.
- **Diagnostics while typing.** `initialize` advertises full-text sync; every
  `didOpen` / `didChange` re-analyses the buffer and publishes `dead-store` and
  `unreachable-code` with the node's real column range, and a parser failure
  becomes one diagnostic per report instead of a guess.
- **A client test, not a unit test.** `test/lsp_client.mjs` spawns the binary,
  runs the handshake, asserts the diagnostic line and code, changes the buffer
  and asserts the diagnostics disappear, then shuts down and checks the exit
  status. CI builds the server and runs this client on every push.
- **`moonbitlang/async` is now a dependency**, used only by the LSP binary; the
  CLI stays synchronous.
- **376 unit tests** are unchanged; the new coverage is end-to-end.

## 0.7.9 — 2026-11-04

`match` arms bind their payload types, and declarations are shared across the
package.

- **`match e { Ok(p) => p.norm() }`** binds `p` the same way `let Ok(p) = e`
  does: the scrutinee names the enum, the variant names the payloads, and a
  generic parameter is substituted from the scrutinee's arguments. Cases are
  walked one at a time, with guards and bodies visited in their own context.
- **Nested patterns substitute through both enums.** `Wrap(Option[Point])`
  matched as `let Wrap(Some(p)) = w` types `p` as `Point`, because payload types
  now keep their type arguments.
- **Declarations are package-scoped.** `index` merges every file's result types,
  field types and enum variants before resolving any file, so a struct or enum
  declared in `types.mbt` types a receiver in `logic.mbt`. This also fixes the
  0.7.6/0.7.7 evidence, which was per-file only.
- **376 tests**, including five match cases and two cross-file cases.

## 0.7.8 — 2026-11-04

A `let` pattern now binds its payload type.

- **`let Ok(p) = result; p.norm()`** resolves when the enum is declared in the
  same file (`enum E { Ok(Point) }`) or is one of the prelude's `Option` /
  `Result`. A generic enum substitutes its parameter from the scrutinee:
  `let Wrap(p) = b` with `b : Box[Point]` types `p` as `Point`.
- **The scrutinee has to be typed**, and by the same evidence as everything
  else: an annotation, a declared return type, a field, an alias. `Option` with
  no arguments, an undeclared variant, and a payload the pass cannot name all
  resolve to nothing.
- **`match` arms are still out of scope** — they need a per-case scope, which
  this pass does not build. `let` patterns cover the common destructuring form;
  the limit is pinned by a test rather than left implicit.
- **370 tests**, including seven pattern cases with their negatives, plus a CLI
  smoke case.

## 0.7.7 — 2026-11-04

Field accesses now carry their declared type.

- **`p.inner.norm()` resolves** when the struct declares `inner : Q` and `Q`
  declares `norm`. The lookup walks as many links as the source spells out:
  `p.q.r.norm()` goes through two field declarations.
- **`let q = p.inner; q.norm()`** is typed the same way, so a field read followed
  by a method call no longer loses the type.
- **A field typed by a type parameter stays unresolved** — `struct Box[T] { v :
  T }` says nothing about `b.v`, and pretending otherwise would invent an edge.
  Tuple-index access (`p.0`) and undeclared fields are likewise left alone.
- **363 tests**, including six field cases with their negatives, plus a CLI
  smoke case that checks the reported caller.

## 0.7.6 — 2026-11-04

Receiver types are now read from every place the source states one, not just
annotations.

- **Declared return types.** `let p = make_point()` is typed when `fn
  make_point() -> Point` is declared in the same file, including a qualified
  constructor (`let p = Point::new()`). Types are only taken from signatures
  this file declares; anything imported stays unresolved.
- **Record literals that name their type.** `let p = Point::{ x: 1 }` states
  `Point`; a bare `{ x: 1 }` could be any type with that field and stays
  unresolved.
- **Aliases and method results.** `let q = p` keeps `p`'s type, and
  `let b = a.to_b()` is typed through `fn A::to_b(self) -> B`.
- **Shadowing blocks the shortcut.** A local binding (parameter, `let`,
  `let fn`) with the same name as a declared function means the call is on the
  local value, so the signature is not applied.
- On `moonbitlang/parser`'s `syntax` package `callers --name loc` now resolves
  four `self.loc()` sites, up from three.
- **357 tests**, including the negative cases above.

## 0.7.5 — 2026-11-04

The last command without a SARIF shape now has one.

- **`path --format sarif`** emits a single `data-flow-path` result: the first
  located statement is the result location, every later one a
  `relatedLocation`, and the message names both ends and the step count. That
  closes the fourth rule in the table (`dead-store`, `unreachable-code`,
  `unused-function`, `data-flow-path`).
- The run header and rule table are now built by one helper (`sarif_head`), so
  every SARIF document this tool emits carries the same four rules and the same
  `invocations` record.
- **349 tests**, plus a CLI smoke case that parses the emitted document and
  checks the rule index and the related lines.

## 0.7.4 — 2026-11-04

The receiver edges from 0.7.3 now reach the analysis, not just the query.

- **Interprocedural slicing follows `x.f()`.** When the slice selects a receiver
  call whose type is written in the source and whose method is declared in the
  package, `slice --dir D --interprocedural` pulls in that method's body from
  whichever file declares it. The whole body is included rather than the
  return-value cone: the IR does not record whether the call's result is used,
  and a side-effecting call must not be under-approximated.
- **`unused` sees inherent methods.** `impl T with fn m` and `fn T::m(self)` can
  only be reached by name, so an unreferenced one is reported like any private
  function. `impl Trait for T` stays out: the call site names the trait, never
  the method, so dispatching to it leaves no syntactic trace.
- **A leading underscore is honoured** as the language's "kept on purpose"
  marker, which is how `moonbitlang/x` keeps a `derive(Debug)` import alive.
- **Re-calibrated with methods included**, on 2158 upstream files: 0 findings on
  `moonbitlang/async` (362), `moonbitlang/x` (116), `moonbitlang/core` (1471) and
  `moonbit-community/prettyprinter` (8); 10 on `moonbitlang/parser` (201), all
  private helpers in the unreleased `untyped_cst` package that occur exactly
  once in their own package.
- **347 tests**, plus CLI smoke cases for method liveness and receiver expansion.

## 0.7.3 — 2026-11-01

The call graph can now see `x.f()` — but only where the source says what `x` is.

- **Receiver calls with written types.** A dot call becomes an edge when the
  receiver's type appears in a parameter annotation, an annotated `let` /
  `let mut`, or as `self` inside an `impl` or `fn T::m(self)`. Types are read,
  never inferred: `let p = make(); p.norm()` stays unresolved, as do chained
  receivers (`a.b.f()`) and a name annotated with two different types.
- **An owner check keeps it honest.** `p.norm()` becomes an edge only when the
  package declares a method named `norm` on `Point`. Without that check the call
  would be credited to any free function named `norm` — the invented edge the
  call collector has always refused to make.
- **`callers --dir D --name f` includes those sites**, with the enclosing
  function, next to the qualified `T::f(x)` calls. On `moonbitlang/parser`'s
  `syntax` package it resolves `self.loc()` style calls across three files.
- **Interprocedural slicing is unchanged**: it still expands direct calls only,
  so a slice never widens because of a receiver edge that might belong to a
  trait method.
- **`src/parser_adapter::call_facts`** exposes the pass (`receivers`, `methods`)
  so other consumers can use it without re-deriving the AST walk. 18 tests in
  `receivers_test.mbt` and 5 in `interproc_test.mbt` pin the accepted and
  rejected forms.
- **338 tests.**

## 0.7.2 — 2026-11-01

Findings can now be silenced where they are written, which is the one thing a
baseline could not do: a baseline is keyed on line numbers and goes stale as
soon as the code above it moves.

- **`// moon-slice: ignore` directives.** A trailing directive covers its own
  line; a directive alone on a line covers the next line of code, skipping blank
  lines and comments. Naming rules narrows the effect —
  `// moon-slice: ignore[dead-store, unreachable-code]` — and bare `ignore`
  covers every rule, including ones added later.
- **A wrong name is inert, not a blank cheque.** Only `dead-store`,
  `unreachable-code` and `unused-function` are accepted; any other spelling,
  including `dead_stores`, leaves the directive with no effect, so a typo cannot
  silence a line. The directive also has to be the last thing on the line, which
  keeps `"// moon-slice: ignore"` inside a string literal from being read as one.
- **Suppressed is still counted and still recorded.** `suppressed` now counts
  inline suppressions together with baseline hits, and `--write-baseline` still
  writes every finding, so the baseline stays a full picture rather than
  silently inheriting the suppressions.
- **`src/suppress`** is a pure parser over source text: `parse` → directives,
  `suppresses` → bool. 21 tests cover the trailing/standalone forms, skip rules,
  bracket and space-separated lists, deduplication, CRLF, unknown names,
  unterminated and empty brackets, string-literal lookalikes, directives at end
  of file, and `empty()`.
- **315 tests**, plus CLI smoke cases for the single-file and package forms.

## 0.7.1 — 2026-11-01

Release hygiene: the version, the tag, the repository and the registry now name
the same thing.

- **Module namespace moved to the account that publishes it.** mooncakes rejects
  a module whose first path segment is not the logged-in username, so
  `chen/moon-slice` became `NaIWaniubi/moon-slice` in `moon.mod`, all 11
  `moon.pkg` self-imports, the generated `.mbti` files, and the shipped JS
  bundle (its mangled symbol names embed the package path, so it was rebuilt).
- **First publish.** `NaIWaniubi/moon-slice@0.7.0` went live on 2026-10-31 with
  `Server status: 200 OK`; a scratch module depending only on the registry copy
  prints `backward-lines=[4]` / `line=1..4`.
- **0.7.1 republishes the same analysis** so that the git tag, `moon.mod` and the
  registry entry all point at one commit, and so the docs carry the verified
  artifact rather than a plan. No API or behaviour change.

## 0.7.0 — 2026-10-30

The analysis became package-scoped: calls are followed into sibling files, and
the mirror question — who calls this — has a command.

- **`slice --dir D --file F --line N [--interprocedural]`.** With `--dir`, the
  package is the scope: callees are looked up across every `.mbt` file under `D`
  instead of only the file being sliced. A bare call contributes the callee's
  whole body, a value-returning call contributes its return-value cone, and the
  result is reported per file because a node id only means something inside the
  program it came from. Verified on moon-slice itself: slicing the
  `run_review(...)` call in `cmd/main/main.mbt` pulls in 100+ lines from
  `cmd/main/review.mbt`.
- **`callers --dir D --name F`.** Every call site of `F` in the package, with the
  enclosing function; `--json` adds the caller names. On `moonbitlang/x`'s time
  package it lists the ten `Duration::parse_str` / `Period::parse_str` call sites
  across five files.
- **Qualified calls are now recorded.** `T::f(x)` is a `Method` node, a
  type-qualified reference to a function of that type, and recording it is what
  makes the two commands above work on real code — before this,
  `Duration::parse_str(str)`, which is how most MoonBit code calls its own
  functions, looked like a function nobody calls. `x.f()` is a `DotApply` and is
  deliberately *not* recorded: the receiver's type is unknown here, so
  attributing it to a function named `f` would invent a call. A regression test
  pins both halves.
- **`src/interproc`**: the package index and the two queries, with its own tests
  (cross-file expansion, return-cone precision, transitivity, local-wins,
  unknown callee, unparsable files, qualified vs receiver calls).
- **294 tests.** CI now also checks the playground presets, and the CLI smoke
  covers package-scope slicing and `callers`.
- **Published to mooncakes.io** on 2026-10-31 as
  `NaIWaniubi/moon-slice@0.7.0` (`Server status: 200 OK`). The module namespace
  moved from the old account name to `NaIWaniubi`, so every internal
  `moon.pkg` self-import and the packaged JS bundle were rebuilt to match; a
  scratch module that only depends on the registry copy runs the pipeline and
  prints `backward-lines=[4]` / `line=1..4`. Details in `PUBLISHING.md`.

## 0.6.0 — 2026-10-30

Dead code now means two things, and the browser demo became a tool.

- **`unused --dir D`** answers the question `dead` could not: which private
  functions does nothing in the package call? The unit is the package (one
  directory), because that is the scope a private function is visible in; a
  file-local answer would be wrong for callers in sibling files. Entry points
  (`main`, `init`), `pub` functions, methods (both `impl` and `fn T::m(self)`)
  and declaration-only stubs are excluded, and the result is filtered by an
  identifier scan over the whole package, so a name mentioned anywhere — a
  comment, an attribute, interpolation text — suppresses the finding.
- **Two false-positive classes found on real code and fixed**, each with a
  regression: `fn Decode::_use_decode_debug(self)` is a method, not a free
  function (`moonbitlang/x`), and `fn init { ... }` is a package initialiser the
  runtime calls (`moonbitlang/async`). After the fixes both repositories report
  nothing: 534 files, 0 findings.
- **Validation on the standard library**: `moonbitlang/core@56256d0`, 1452
  files, 4 findings — every one a function the library itself named
  `unused_function` / `suppress_unused_v128_import_on_*`. Exact, not noisy.
- **Baselines and the gate work for `unused` too**: `--write-baseline`,
  `--baseline` and `--fail-on-findings`, plus `--format sarif` with the new
  `unused-function` rule (index 2), so findings land in code scanning.
- **The playground is a tool now.** A clickable line gutter slices whatever line
  you click, marks the slice in green and the target in amber, offers five
  examples (including an interprocedural one), re-runs after edits, supports
  `Ctrl`+`Enter`, and can copy a link that reopens the exact example. The slice
  map is read back from the report's embedded JSON, so the report stays a
  standalone artefact.
- **`web/presets.mjs`** checks every example the page offers *and* every
  direction through the JavaScript engine, with the same numbers the CLI
  documents; wired into CI.
- **284 tests.** New coverage: 19 liveness cases, the engine flow
  (`web_engine_test.mbt`), and the playground preset/direction matrix.

- **Also in this release**: whitebox tests for the diff parser and the review
  helper, `ACCEPTANCE.md` (the nine review items with evidence), `PUBLISHING.md`
  (verified packaging, credentials format, namespace rename), `THIRD_PARTY.md`,
  `tools/publish.sh`, and an explicit native release build step in CI.

## 0.5.0 — 2026-10-29

CI-facing output and tree-scale scanning. The tool now answers a reviewing
team's two questions with commands they can put in a workflow.

- **`dead --dir D`.** One process scans every `.mbt` file under a tree,
  skipping `.git`, `_build`, `target`, `.mooncakes` and `node_modules`. Parse
  failures are reported per file and do not abort the scan. On
  `moonbitlang/x` (166 files) the batch takes about 1.0 s, against 99 s for the
  old per-file process loop.
- **SARIF 2.1.0.** `dead --format sarif` emits one run with `dead-store` and
  `unreachable-code` rules, artifact locations, and stable partial fingerprints,
  ready for `github/codeql-action/upload-sarif`.
- **Baselines.** `--write-baseline FILE` records `path:line`; `--baseline FILE`
  hides those findings and reports how many it hid (`suppressed` in JSON).
  `--fail-on-findings` exits 1 only for findings that survive, so a repository
  can adopt the gate without fixing its history first.
- **`--out FILE` for `dead`**, in text, JSON and SARIF modes.
- **`action.yml` and `templates/review-workflow.yml`.** A composite action
  builds the pinned tag and runs `review` or `dead`; the template wires both a
  pull-request impact report and a SARIF upload.
- **Real-commit review case study.** On `moonbitlang/x@4705764`, 15 changed
  lines reach 40 lines across 6 functions in `duration.mbt` and 4 in
  `period.mbt`; the test files correctly reach 0. See `docs/CASE_STUDY.md`.
- **256 tests**, including scan-path normalisation, SARIF shape, and the
  directory-mode CLI end to end.

## 0.4.2 — 2026-10-29

Real-world validation and the `review` command. Numbers and commands are in
`docs/CASE_STUDY.md`; Chinese entry point in `README.zh-CN.md`.

- **`review --diff FILE` / `tools/review.sh`.** Forward-slices every line a diff
  adds and reports the affected lines and functions. `tools/review.sh` produces
  the diff with `git diff -U0`, so the analysis itself stays process-free and
  testable; `cli_smoke.sh` covers a synthetic diff end to end.
- **Validation against real code.** `tools/scan.mjs` runs `dead` over a source
  tree and reports parse failures and hits. On moonbitlang/async (368 files,
  50,233 lines) and moonbitlang/x (166 files, 37,595 lines): 100% parse success,
  0 dead-code hits. On moon-slice itself: 50 files, 9,712 lines, 7 hits, all
  verified true positives in the example corpus.
- **Six false-positive classes found by that scan and fixed**, each with a
  regression in `src/integration_test/real_world_test.mbt`:
  writes through parameters; field / read-modify-write stores; identifiers read
  only by a string interpolation; the C-style `for` update being orphaned in the
  CFG; the C-style `for` initialiser re-running on every iteration; structural
  containers reported as unreachable code. A seventh fix covers variables
  captured by a local closure (recorded as uses of the function exit).
- **`README.zh-CN.md`** is the Chinese entry point: quickstart, the three
  questions the tool answers, precision evidence, and the honest limits.

## 0.4.1 — 2026-10-29

Fixes from an adversarial review that simulated a competition judge. Three
findings were real defects, not polish.

- **`impl` method bodies are now analysed.** Previously only free functions were
  lowered, so a file whose logic lived in `impl T with fn ...` produced an empty
  program and `dead` answered "no dead code" for code it never looked at. That
  is a wrong answer, not a conservative one. `TopImpl` and `TopView` are lowered
  as functions, with `self` as an ordinary parameter.
- **The interprocedural argument filter is removed.** The previous version
  inferred argument count from identifier uses, so `add(1, 2)` looked like a
  zero-argument call and the whole callee was dropped — an under-approximation.
  The deeper problem is that any positional filter is unsound for MoonBit:
  omitted parameters may have defaults, and labelled arguments need not be in
  declaration order. `expand_calls` is back to the whole return cone, which
  cannot under-approximate. `docs/ALGORITHMS.md` explains why.
- **`path` follows data edges only.** It used to traverse control edges too, so
  `path --from o --to v` could report "o flows into v" through an `if`
  condition, a false positive for a taint-style user. `--with-control` restores
  the old search.
- **The property suite's closure check is real.** It previously asserted only
  that the slice was non-empty; it now verifies that every node in a backward
  slice can reach the criterion using only nodes in the slice.
- **Report generation is linear.** The HTML source block used per-line string
  concatenation and a linear membership scan, so an 8,000-line file took about
  15 s. `StringBuilder` plus a set brings it to about 0.5 s.
- **Sparse node ids no longer mis-index.** `cfg`, `defuse` and the report rows
  looked nodes up by array position; a hand-built `Program` with id gaps would
  read the wrong node or panic. They index by declared id now, and the SVG
  refuses to draw (instead of drawing the wrong graph) when ids are not dense.
- **The playground caches the engine.** Each click used to request
  `moon-slice.js?run=N`, so the 10 MB bundle was re-downloaded every time. A
  stable URL keeps the fresh-iframe isolation and lets the browser cache it.
- **`--precise` and `compare` are discoverable.** Both were reachable but
  missing from `help`. `compare` shows the structural vs precise control-edge
  difference directly (18 vs 7 on `bench/precise_cdg.mbt`).
- **Docs re-synced.** Test counts, the stale `docs/report.html`, the demo's
  nonexistent `/tmp` input, and the "exact for the structured subset" claim
  (contradicted by its own LIMITATIONS) are corrected.

## 0.4.0 — 2026-10-29

Precision work, driven by an attempted multi-agent run whose workers could not
authenticate; the five planned missions were implemented directly instead.

- **Post-dominator control dependence (`cdg::build_precise`).** Solves
  post-dominators per function as a backward fixed point and derives control
  dependence with the Ferrante–Ottenstein–Warren walk. Exposed as
  `--precise` on every analysis command. Measured effects: no region-to-region
  pseudo edges, and on `while { if c { return }; x = x + 1 }` the structural
  builder's 18 control edges become 7. The structural `build` stays the default,
  because it cannot under-approximate.
- **Interprocedural argument mapping.** `expand_calls` now pairs a call site's
  arguments with the callee's parameters in declaration order and drops callee
  statements whose only parameter dependencies are parameters the caller did not
  supply. `two(a, b)` called as `two(x)` no longer pulls in the `b`-only branch.
  Statements that depend on a supplied argument, or on no parameter at all,
  stay; a bare call statement still expands the whole body.
- **Machine-readable contract.** With `--json`, every failure prints
  `{"error":{"code":..,"message":..}}` and exits 2, so automation never parses
  prose. `graph --format json` emits deterministic nodes and edges. The HTML
  report carries `<meta name="generator">` and a
  `<script type="application/json" id="moon-slice-result">` block with the
  target, nodes, lines and errors.
- **Path-based precision oracle.** The independent oracle is now derived from
  the path formulation ("a definition reaches a use when some path connects
  them with no intervening redefinition") instead of a bounded walk enumeration,
  so it stays correct on nested loops where a visit bound stops too early. This
  change was itself prompted by a property-test failure.
- **Property-based differential testing.** A seeded generator produces 40
  programs from a grammar covering let/let mut/assign/if-else/while/C-style
  for/guard/return/nested blocks; each is checked for structural invariants,
  agreement with the oracle, slice closure, criterion membership, line
  projection, and interprocedural superset-ness. Failures print the seed and
  source.
- **Def-use allocation and exactness.** A visit that changes nothing no longer
  retains its candidate state, and a 2000-statement chain asserts the exact
  closed-form pair count so a future optimisation cannot drop edges silently.

## 0.3.0 — 2026-10-28

Precision and robustness pass, driven by an independent audit. Every item has a
regression test or an acceptance check.

- **Independent precision oracle.** `src/integration_test/precision_oracle_test.mbt`
  re-derives reaching definitions by enumerating bounded CFG walks and compares
  the result with the work-list analysis on 12 programs plus the whole example
  corpus. Agreement is evidence, not a restatement of the implementation.
- **Report HTML escaping.** Escaping is per character, so a second `<script>` in
  the source can no longer reach the report; `"` and `'` are escaped too.
- **Playground repeat runs.** Each run executes in a fresh hidden iframe with a
  run token, so the bundle's top-level declarations cannot collide and a stale
  run cannot overwrite a newer report. Verified in headless Chrome
  (`web/playground_e2e.mjs`).
- **Playground input protocol.** `direction\nline\nnode\nsource`; source text is
  the unparsed remainder, so sentinel-like content is preserved.
- **CLI exit codes.** Unreadable files, write failures, unknown commands or
  flags, invalid `--line`/`--direction`/`--format` and malformed sources exit 2
  without emitting a plausible result.
- **Ambiguous target lines.** `statement_candidates` reports every statement on
  a line, the CLI prints a note with the candidate ids, and `--node ID` selects
  one; an unknown id is an error. The HTML report highlights the target row and
  names the selected node in its metrics.
- **`guard ... else`** is lowered as two branches instead of dropping the else.
- **C-style `for`.** The binder is bound before the condition, the update block
  is a real node, and `continue` resumes at the update instead of skipping it.
- **Calls.** Every free-function application in a statement is recorded,
  including nested ones (`g(h(x))`) and calls in conditions; method labels are
  never recorded; a name bound locally does not fabricate an edge; recursion is
  kept as a self-edge; interprocedural expansion matches call sites by callee
  name before line.
- **Def-use** no longer has a fixed worklist round cap (the lattice is finite and
  transfer monotone), and per-node GEN/USE indexes replace global scans.
- **Query helpers** resolve nodes by id (sparse ids cannot be misread) and build
  adjacency once, so `path` and `unreachable` are O(V+E).
- **Performance.** CFG edge dedupe uses a set, name resolution uses a per-name
  stack, and DOT/JSON/HTML are built with `StringBuilder`. A 32,000-statement
  function now takes about 1.2 s for `dead`/`graph` and 2.2 s for `slice`
  (`bench/bench.mjs`, native release).
- **Report SVG.** Truncation is stated in the graph instead of silently dropping
  the target; the SVG carries `role`/`title`/`desc` and table headers have
  `scope`.
- **CI and Pages** rebuild the tracked browser bundle, fail on drift, and run the
  browser smoke test before deploying.

## 0.2.0 — 2026-10-26

- Inter-procedural expansion: return-value cone for value-returning calls,
  whole body for bare call statements; `slice --interprocedural` and
  `html --interprocedural`; `Program.calls` records direct call sites.
- Call graph from recorded call sites, including calls in `let`/assign/return.
- Data-flow path query (`path --from A --to B`).
- `dead` now unions unused definitions and unreachable statements.
- Inline-SVG HTML report with source-order layout, slice-node table and metrics.
- Deterministic fuzz-style invariant tests; 190 tests total.
- Browser playground: `src/web` compiled to JavaScript + `web/index.html`;
  prebuilt engine and `web/smoke.mjs`.
- CLI: `version`/`help`, `--json` for dead/path/callgraph, and a full CLI smoke test.
- Zero compiler warnings; docs/ALGORITHMS.md, docs/DEMO.md, CI, benchmark.
