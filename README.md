# moon-slice

A program-slicing workbench for MoonBit. Point it at a `.mbt` source file and a
target line; get back the **backward slice** (which statements may have produced
the value at that line) and the **forward slice** (which statements that value
may affect).

Slicing is the standard way to answer "what here matters to this line", and it is
the usual first step for debugging, impact analysis before a refactor, and
narrowing down a diff during review.

## Status

The data model is frozen; the analysis passes are being built in parallel
missions and the CLI is wave 2. What is in the tree **today** is only
`src/core` (types) and `src/smoke` (a parser smoke test) — the rest of the table
is the target layout, not shipped code.

| Layer | Package | State |
| --- | --- | --- |
| Data model | `src/core` | **frozen**, present — types only, no logic |
| Parser adapter | `src/parser_adapter` | planned (mission 1) — not in this tree |
| CFG | `src/cfg` | planned (mission 1) — not in this tree |
| Def-use | `src/defuse` | planned (mission 1) — not in this tree |
| CDG | `src/cdg` | planned (mission 2) — not in this tree |
| PDG | `src/pdg` | planned (mission 2) — not in this tree |
| Slicing | `src/slice` | planned (mission 2) — not in this tree |
| Report (JSON/DOT) | `src/report` | wave 2 — not implemented |
| CLI (`slice`, `graph`, `dead`, `html`) | `cmd/main` | wave 2 — `cmd/main` currently only prints a placeholder |
| Example corpus | `examples/`, `testdata/` | **available now** |

The CLI does not exist yet. Until it lands, use the library API shown below.
The example corpus and its expected results *are* complete and validated, so
they can be used as the specification while the passes are written.

## Quickstart

Everything goes through the wrapper, which puts the MoonBit toolchain on `PATH`:

```bash
./dev.sh check      # type-check the whole module
./dev.sh test       # run the test suite
```

Run the CLI with `./dev.sh run cmd/main -- ...`. Once wave 2 lands, the commands
will be:

```bash
./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction backward
./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction forward
./dev.sh run cmd/main -- graph --file examples/04_while.mbt --format dot
./dev.sh run cmd/main -- dead  --file examples/08_dead_assignment.mbt
./dev.sh run cmd/main -- html  --file examples/04_while.mbt --line 7 --out report.html
```

Today those arguments are parsed by nothing: `cmd/main` ignores them and prints
`Hello`. Once the wave-1 packages land, the pipeline is driven from MoonBit code
like this (this snippet is the target API from `CONTRACT.md`, not code that
compiles in this tree yet):

```moonbit
let program = @parser_adapter.parse_source(source, "examples/04_while.mbt")
let cfg     = @cfg.build(program)
let defuse  = @defuse.analyze(program, cfg)
let cdg     = @cdg.build(program, cfg)
let pdg     = @pdg.build(defuse, cdg)
let result  = @slice.backward(pdg, target_node_id)
println(result.lines) // e.g. [4, 5, 6, 7, 8]
```

## Architecture

Five passes over one shared, immutable data model. Each stage consumes the
previous stage's output and nothing else, so each can be tested on a
hand-built input:

```text
.mbt source
    │
    ▼
parser adapter   moonbitlang/parser AST ──▶ @core.Program      (SNode tree, Loc, VarId)
    │
    ▼
CFG              @core.Program  ──▶ @core.Cfg                   (Int32×Int32 edges, entry, exit)
    │
    ▼
def-use          Program + Cfg  ──▶ @core.DefUse               (reaching definitions)
    │
    ▼
CDG              Program + Cfg  ──▶ @core.Cdg                   (controller → controlled)
    │
    ▼
PDG              DefUse + Cdg   ──▶ @core.Pdg                   (data + control edges)
    │
    ▼
slice            Pdg + target   ──▶ @core.SliceResult           (node ids, sorted lines)
    │
    ▼
report           Program + Result ──▶ JSON / DOT / HTML          (wave 2)
```

Design points worth knowing:

- **The IR is the contract.** `src/core/types.mbt` is frozen; every package
  agrees on `SNode`, `Cfg`, `DefUse`, `Cdg`, `Pdg`, `SliceResult`. This is what
  lets the passes be built and tested independently and in parallel.
- **Node ids are the unit; lines are the view.** A node carries a `Loc` and a
  `start_line`. `SliceResult` returns both `nodes` and `lines`; `lines` is the
  unique sorted projection used for display and for the example corpus.
- **Variables are `VarId { name, scope }`, not strings.** Shadowing therefore
  gives two distinct ids, and def-use does not conflate them.
- **Slices include the target.** The target statement's own definition is part
  of its slice, and the reported line lists are inclusive.

## Supported subset

Modeled with precise data and control edges:

- `let` and `let mut` bindings; assignment to a mutable binding
- `if` / `else` (including `else if` chains) and merges after the join
- `while` and `for` / `for .. in` loops, with loop-carried definitions
- `match` with multiple arms
- `return`, `break`, `continue`
- expression statements, operator expressions, calls
- identifiers and field access (`p.x`)

Anything else the adapter does not recognize is kept as a generic `Expr` node
whose **uses are all identifiers appearing in it** — deliberately conservative,
so the slice can only get bigger, never silently wrong.

Field and array writes are modeled as an access to the base variable `p`, not to
a distinct `p.left`. That is a heap abstraction choice, not an oversight; see
below.

## Limitations

These are real and intentional for the MVP. They are the places where the tool
may report a larger slice than a precise analysis would:

- **Intra-procedural only.** Each function is analyzed on its own. A call is a
  data dependency on its arguments; the callee body is not inlined, and its
  effect on arguments (mutation) is not propagated back. Slicing across
  functions is not supported.
- **Conservative aliasing.** Distinct names that may refer to the same object
  are not tracked. `p.left` and `p.right` are both treated as a use/def of `p`,
  so a write to one field is assumed to affect reads of any field. This shows up
  as extra lines in slices like `examples/10_field_write.mbt`; it never omits a
  line.
- **Structured control dependence.** The CDG is derived from the syntax tree —
  an `if`/`while`/`for`/`match` controls the statements lexically inside it —
  rather than from post-dominators on arbitrary CFGs. It is exact for the
  structured subset above, but it does not model irreducible control flow, and
  `return`/`break`/`continue` are handled conservatively (treated as depending
  on every enclosing controller).
- **No inter-procedural `dead` precision (wave 2).** The `dead` command will
  flag unreachable code after an unconditional `return`; a store that is dead
  only because a callee never reads it will not be flagged.
- **No points-to, no reflection, no macro expansion.** Dynamic dispatch and
  metaprogramming are opaque; the conservative "all identifiers are uses" rule
  applies.
- **Line granularity.** Results are sets of line numbers. Two statements on the
  same line collapse into one entry, and multi-line expressions are attributed
  to their first line.

## Examples

`examples/` holds ten small programs, one per modeling concern — `let`, `mut`,
`if/else`, `while`, `for`, `match`, `return`, dead assignment, shadowing, field
write. Each begins with its expected result:

```moonbit
// EXPECT-BACKWARD 7 -> [4, 5, 6, 7, 8]
// EXPECT-FORWARD 7 -> [7, 10]
fn loop_sum(n : Int) -> Int {
  let mut i = 0
  let mut total = 0
  while i < n {
    total = total + i // target
    i = i + 1
  }
  return total
}
```

`testdata/README.md` explains every expected set line by line, including the
deliberate edge cases: dead stores absent from the slice, loop-carried
definitions, control dependence contributing the loop header, and scope-sensitive
shadowing. `testdata/expected.json` is the same table in machine-readable form
for the wave-2 end-to-end test.

Note that line 8 is in the backward slice of line 7 — `i = i + 1` reaches the
next iteration of the loop body — while line 8's own value does not affect
`total` on this iteration. Loop-carried edges are the most common source of
surprise in a slicing result.

`examples/` has no `moon.pkg`, so the build never tries to compile it as a
package; it is data. The files are still valid MoonBit and were verified with
the real compiler.

## Verifying the corpus

The headers and `testdata/expected.json` must agree, and every mutation
described above must stay consistent. The table in `testdata/README.md` is the
human-readable version; the script does not parse that Markdown table, so keep
the table and JSON in sync by review. One script checks the headers and JSON:

```bash
bash testdata/verify_corpus.sh
# corpus ok: 10 examples, headers and expected.json agree
```

It enforces: exactly 10 examples, each file ≤ 30 lines, both `EXPECT-*` headers
present and well-formed, every listed line within the file, lists strictly
ascending, the target included in its own slice, and the JSON table matching the
headers. It is a plain shell + `node` script, independent of the MoonBit
packages, so it runs before the analysis passes exist.

## Development

```bash
./dev.sh check                    # type-check
./dev.sh test                     # run tests
./dev.sh test --update            # refresh snapshot tests
./dev.sh coverage analyze > uncovered.log
```

PowerShell / cmd users: replace `./dev.sh` with `dev.cmd`.

`moon fmt` and `moon info` are coordinate-after-merge steps in this repo; running
them inside a feature branch rewrites shared files and causes merge conflicts.

## License

Apache License 2.0 — see [LICENSE](LICENSE). The `moonbitlang/parser` dependency
is also Apache-2.0.
