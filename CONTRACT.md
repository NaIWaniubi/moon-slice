# moon-slice — frozen contract

Goal: a MoonBit program-slicing workbench. Input a `.mbt` file and a target
statement; output the backward slice (what may have produced this value) and
the forward slice (what this value may affect), plus JSON/DOT/HTML reports.

## Hard rules

- `src/core/types.mbt` is frozen. Missions must not edit it. If a type must
  change, write `CONTRACT_CHANGE.md` and stop; the coordinator decides.
- Each mission owns only its own directories. Never edit another mission's
  files. Never edit `moon.mod`, `moon.pkg` of the root, or another package's
  `moon.pkg`.
- Every command goes through `./dev.sh` (Git Bash) or `dev.cmd` (cmd/PowerShell).
  Those wrappers put `%USERPROFILE%\.moon\bin` on `PATH`.
- Every mission must leave `./dev.sh check` and `./dev.sh test` green.
- Use meaningful commits; no empty/repeated commits.
- End the worker reply with one line:
  `TOWER_RESULT: {"summary":"...","tests":"pass|fail","files":["..."]}`

## Frozen package APIs

Implement exactly these signatures. Add helpers freely, but do not rename or
change the public ones.

```moonbit
// src/parser_adapter
pub fn parse_source(source : String, name : String) -> @core.Program

// src/cfg
pub fn build(program : @core.Program) -> @core.Cfg

// src/defuse
pub fn analyze(program : @core.Program, cfg : @core.Cfg) -> @core.DefUse

// src/cdg
pub fn build(program : @core.Program, cfg : @core.Cfg) -> @core.Cdg

// src/pdg
pub fn build(defuse : @core.DefUse, cdg : @core.Cdg) -> @core.Pdg

// src/slice
pub fn backward(pdg : @core.Pdg, target : Int) -> @core.SliceResult
pub fn forward(pdg : @core.Pdg, target : Int) -> @core.SliceResult

// src/report
pub fn to_json(program : @core.Program, result : @core.SliceResult) -> String
pub fn to_dot(pdg : @core.Pdg) -> String
```

`@core` is `chen/moon-slice/src/core`. Import it in each package's `moon.pkg`:

```text
import {
  "chen/moon-slice/src/core" @core,
}
```

## Mission ownership

### Mission 1 — parser adapter + CFG + def-use

Directories: `src/parser_adapter/`, `src/cfg/`, `src/defuse/`.

- `parser_adapter`: call `@parser.parse_string(source, name=name)`. Walk
  `@syntax.Impls`; for each `Impl::TopFuncDef(fun_decl~, decl_body~, ..)`
  and `DeclBody::DeclBody(expr~)`, build `SNode`s. Convert `Location` to
  `@core.Loc`. Support the subset: `let`, `let mut`, assignment, `if`,
  `while`, `for`/`for each`, `match`, `sequence`, `return`, `break`,
  `continue`, calls, identifiers, field/array access. Unsupported nodes:
  treat as `Expr`, collect all identifiers as `uses` (conservative).
- `cfg`: sequence edges, if/else edges, loop back edges, break/continue
  edges, entry/exit.
- `defuse`: reaching definitions for the modeled subset. Conservative for
  aliasing/field writes.
- Tests: parser smoke test; CFG edge tests; def-use tests; shadowing test.

### Mission 2 — control dependence + PDG + slicing

Directories: `src/cdg/`, `src/pdg/`, `src/slice/`.

- `cdg`: structured control dependence first. `if`/`while`/`for`/`match`
  conditions control the statements in their branches/body. Handle
  `return`/`break`/`continue` conservatively. Do not require post-dominators
  for the MVP; document the limitation.
- `pdg`: data edges from `DefUse.reaching`; control edges from `Cdg.edges`.
- `slice`: BFS/DFS over the PDG. `backward` follows incoming edges;
  `forward` follows outgoing edges. `nodes` sorted ascending; `lines` =
  unique sorted `loc.start_line`.
- Tests: build graphs by hand, assert exact node sets; a small end-to-end
  test with a manually built `Program`.
- Do not import `parser_adapter`, `cfg`, or `defuse`; depend only on
  `@core` types so this mission can run in parallel.

### Mission 3 — examples + test corpus + README

Directories: `examples/`, `testdata/`, `README.md`.

- 10 small MoonBit programs under `examples/`, each with a comment block
  `// EXPECT-BACKWARD line -> [lines]` and `// EXPECT-FORWARD line -> [lines]`.
  Cover: let, mut, if/else, while, for, match, return, dead assignment,
  shadowing, field write.
- A `testdata/README.md` table mapping each example to the expected slices.
- `README.md`: problem, quickstart (`./dev.sh run cmd/main -- ...`), design,
  supported subset, limitations, examples, license. Do not claim features
  the code does not have yet.
- No dependency on other missions' packages.

### Mission 4 — CLI + report + integration (wave 2)

Directories: `src/report/`, `cmd/main/`, `src/integration_test/`.

- `report::to_json` / `to_dot` as specified.
- CLI: `slice --file F --line N --direction backward|forward`, `graph
  --file F --format dot`, `dead --file F`, `html --file F --line N --out O`.
- End-to-end test: parse an example, build CFG/defuse/CDG/PDG, slice,
  assert the expected lines.
- `html`: self-contained file, source highlighted, graph embedded as DOT
  text or SVG. No network dependency.

## Definition of done (coordinator)

- `./dev.sh check` and `./dev.sh test` green on the merged base.
- `./dev.sh run cmd/main -- slice --file examples/bug.mbt --line <n>
  --direction backward` prints the expected lines.
- `README.md` has a reproducible demo and honest limitations.
- 10+ meaningful commits across missions.
- Apache-2.0 LICENSE present; parser dependency is Apache-2.0.
