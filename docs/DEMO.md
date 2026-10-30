# Demo

Run these from the repository root. The wrapper puts `moon` on `PATH`, so the
commands work in Git Bash (`./dev.sh`) and in cmd/PowerShell (`dev.cmd`).

## 1. Backward and forward slicing

```bash
./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction backward
# 4,5,6,7,8
./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction forward
# 7,10
```

Line 7 is `total = total + i`. The backward slice includes the loop preheader,
the guard, the target, and the loop-carried `i = i + 1`; the forward slice
includes the target and `return total`.

## 1b. Picking a statement when a line holds several

```bash
cat > multi.mbt <<'MBT'
fn f(x : Int) -> Int {
  let a = x + 1; let b = x + 2; a
}
MBT
./dev.sh run cmd/main -- slice --file multi.mbt --line 2 --direction backward
# note: line 2 has 3 statements; using node 1. Pass --node ID to choose another (candidates: 1,2,3)
# 2
./dev.sh run cmd/main -- slice --file multi.mbt --line 2 --direction backward --node 3
# 2
```

The note names the candidates; `--node 3` targets the trailing `a`. An unknown
id exits 2. The HTML report marks the chosen node in its metrics and highlights
its table row.

## 2. A match arm is a real assignment

```bash
./dev.sh run cmd/main -- slice --file examples/06_match.mbt --line 7 --direction forward
# 7,10
```

The parser represents `{ label = 20 }` as a `Group`; the adapter lowers it
transparently, so the arm is an `Assign` with a `label` definition rather than an
opaque `Expr`.

## 3. Dead stores and unreachable code

```bash
./dev.sh run cmd/main -- dead --file examples/08_dead_assignment.mbt
# 4,5
```

`dead` unions two sets: definitions with no reaching use, and statements not
reachable from any function entry. For the unreachable half, write the file
first (the command reads a real path, not a magic `/tmp` location):

```bash
cat > unreachable.mbt <<'MBT'
fn f() -> Int {
  return 1
  let x = 2
  x
}
MBT
./dev.sh run cmd/main -- dead --file unreachable.mbt
# 3,4
```

## 4. Data-flow path (taint-lite)

```bash
./dev.sh run cmd/main -- path --file examples/04_while.mbt --from i --to total
# n1 L4 -> n5 L7
./dev.sh run cmd/main -- path --file examples/07_return.mbt --from base --to total
# n1 L4 -> n3 L6 -> n4 L7
```

Starts are definitions of `--from`; goals are uses of `--to`; the output is the
shortest directed PDG path.

## 5. Call graph

```bash
./dev.sh run cmd/main -- callgraph --file bench/callgraph.mbt
# digraph callgraph { "twice" -> "inc"; "main_fn" -> "twice"; }
```

A function-level dependency overview; nested calls and recursive calls are
included, while method calls and function values are omitted.

## 6. Inter-procedural mode

```bash
./dev.sh run cmd/main -- slice --file bench/callgraph.mbt --line 12 --direction backward --interprocedural
# 2,6,7,8,12
```

The call at line 12 expands `twice`'s return-value cone (lines 6-8), whose
calls expand `inc`'s return cone (line 2) transitively. A bare call statement
still expands the whole body; a value-returning call excludes dead stores.

## 7. HTML report

```bash
./dev.sh run cmd/main -- html --file examples/04_while.mbt --line 7 --out report.html
```

Open `report.html`. It contains:

- an inline SVG of the PDG, laid out in source order (solid = data, dashed =
  control; orange = target, green = slice);
- the source with slice lines highlighted;
- metrics (nodes, edges, slice size) and parse errors;
- the DOT text in a collapsible section.

The rendered page is `docs/report.png`.

## 8. Browser playground

Open `web/index.html` directly. It renders the live report in an iframe; the
engine is `web/moon-slice.js`, rebuilt with `bash web/build.sh` and asserted by
`node web/smoke.mjs` and `node web/presets.mjs`.

Or open the hosted copy: https://cs6210501-lab.github.io/moon-slice/

What to do there:

1. click a **line number in the left gutter** — the slice for that statement
   appears on the right, and the gutter turns the slice green and the target
   amber;
2. switch **Direction** to `forward` on the while example: `4,5,6,7,8` becomes
   `7,10`;
3. pick the **interprocedural** example and direction: the slice of `twice(x)`
   becomes `2,6,7,8,12`, including the callee bodies;
4. edit the source: the page re-runs after a pause (`Ctrl`+`Enter` runs at once);
5. press **Copy link**: the URL now reopens the exact source, line and direction.

## 9. JSON

```bash
./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction backward --json
# {"nodes":[0,1,2,3,4,5,6],"lines":[4,5,6,7,8],"errors":[]}
```

## 10. Dead code and unused functions across a tree

```bash
./dev.sh run cmd/main -- dead --dir examples          # writes nobody reads
./dev.sh run cmd/main -- unused --dir src             # private functions nothing calls
./dev.sh run cmd/main -- unused --dir examples        # 10: the snippets are standalone
```

`unused` works per package (one directory) because that is the scope a private
function is visible in. Entry points (`main`, `init`), `pub` functions, methods
and declaration-only stubs are excluded, and a name mentioned anywhere else in the
package — comments included — suppresses the finding. A function annotated
`#warnings("-unused_value")` is the author saying it is intentionally unused, and
is not reported.

## 11. CI output: SARIF, baseline, gate

```bash
tmp="$(mktemp)"
./dev.sh run cmd/main -- dead --dir examples --format sarif --out /tmp/dead.sarif
./dev.sh run cmd/main -- unused --dir examples --write-baseline "$tmp"
./dev.sh run cmd/main -- unused --dir examples --baseline "$tmp"          # empty
./dev.sh run cmd/main -- unused --dir examples --fail-on-findings; echo "exit $?"
# 10 findings printed, exit 1
```

Both commands take `--format sarif` (rules `dead-store`, `unreachable-code`,
`unused-function`), `--out FILE`, `--baseline`/`--write-baseline` and
`--fail-on-findings`, so the same gate works for either.

## 12. Full verification

```bash
./dev.sh check
./dev.sh test
bash testdata/verify_corpus.sh
bash test/cli_smoke.sh
node web/smoke.mjs
node web/presets.mjs
```

Expected: 0 errors, `Total tests: 284, passed: 284, failed: 0`,
`corpus ok: 10 examples, headers and expected.json agree`, `cli smoke ok`,
`web smoke ok: 7006 bytes`, `playground presets ok`.
