# moon-slice — design contract

The invariants that keep the analysis trustworthy. They are the rules the code
base is held to; `CONTRIBUTING.md` covers how to run things.

## What the tool must answer

Point it at a statement and it must say, correctly and conservatively:

1. **backward** — which statements may have produced the value used here;
2. **forward** — which statements this value may affect;
3. **dead** — which writes nothing reads, which statements no path reaches, and
   (per package) which private functions nothing calls.

When the analysis cannot see something (dynamic dispatch, a macro, a `#cfg`
branch it did not take) it must **over-approximate**: include a statement that
might not matter, never drop one that does. A wrong line is worse than a missing
one, and every imprecision is documented in `README.md` under Limitations.

## Frozen data model

`src/core/types.mbt` is the shared contract between the passes: `SNode`, `VarId`,
`Loc`, `FunctionInfo`, `CallSite`, `Program`, `Cfg`, `DefUse`, `Cdg`, `Pdg`,
`SliceResult`.

Changing it is allowed but expensive, and the cost is the point:

- every producer and consumer is updated in the same change;
- `moon check` and `moon test` stay green;
- the change is described in `CHANGELOG.md` (the model is part of the public
  behaviour, so a change to it is a minor version bump);
- `COVERAGE.md` is refreshed in the same commit.

Nothing outside `src/core` defines a type that another package depends on.

## Package boundaries

| Package | May import | Must not |
| --- | --- | --- |
| `src/core` | nothing of ours | contain logic |
| `src/parser_adapter` | `core`, `moonbitlang/parser` | be imported by the analysis passes |
| `src/cfg` … `src/pdg` | `core` only | import the parser or the adapter |
| `src/slice`, `src/query` | `core` | reach into the AST |
| `src/liveness` | `moonbitlang/parser` | duplicate the IR passes |
| `src/interproc` | `core`, the passes, `query` | import the AST directly |
| `src/report` | `core` | know about the CLI |
| `cmd/main` | everything | contain analysis logic |

Two rules matter most. **Only `src/parser_adapter` and `src/liveness` see the
AST**: everything downstream works on `Program`, which is what makes the passes
testable without a parser and what keeps a parser upgrade contained. And
**`cmd/main` holds no analysis**: flags in, rendered text out, so the CLI can be
covered by `test/cli_smoke.sh` while the interesting logic is unit-tested.

## Frozen public APIs

Add helpers freely; do not rename or change these signatures.

```moonbit
// src/parser_adapter
pub fn parse_source(source : String, name : String) -> @core.Program

// src/cfg
pub fn build(program : @core.Program) -> @core.Cfg

// src/defuse
pub fn analyze(program : @core.Program, cfg : @core.Cfg) -> @core.DefUse

// src/cdg
pub fn build(program : @core.Program, cfg : @core.Cfg) -> @core.Cdg
pub fn build_precise(program : @core.Program, cfg : @core.Cfg) -> @core.Cdg

// src/pdg
pub fn build(defuse : @core.DefUse, cdg : @core.Cdg) -> @core.Pdg

// src/slice
pub fn backward(pdg : @core.Pdg, target : Int) -> @core.SliceResult
pub fn forward(pdg : @core.Pdg, target : Int) -> @core.SliceResult

// src/liveness
pub fn collect(path : String, source : String) -> FileFacts
pub fn unused_functions(facts : Array[FileFacts]) -> Array[UnusedFn]

// src/interproc
pub fn build_file(path : String, source : String, precise? : Bool = false) -> PackageFile?
pub fn index(files : Array[PackageFile]) -> PackageIndex
pub fn expand(index : PackageIndex, target : String, result : @core.SliceResult) -> Array[FileSlice]
pub fn callers(index : PackageIndex, name : String) -> Array[CallSiteRef]

// src/suppress
pub fn parse(source : String) -> Directives
pub fn suppresses(directives : Directives, line : Int, rule : String) -> Bool

// src/report
pub fn to_json(program : @core.Program, result : @core.SliceResult) -> String
pub fn to_dot(pdg : @core.Pdg) -> String
pub fn to_sarif_findings(findings : Array[SarifFinding], suppressed : Int,
                         version : String, files : Int, parse_failures : Int) -> String
```

`@core` is `NaIWaniubi/moon-slice/src/core`:

```text
import {
  "NaIWaniubi/moon-slice/src/core" @core,
}
```

## Rules every change follows

- Commands go through `./dev.sh` (Git Bash) or `dev.cmd` (cmd/PowerShell), which
  put `~/.moon/bin` on `PATH`. No global installs, no `npm install -g`.
- `moon check` stays at 0 warnings and `moon test` stays green.
- A fix for a wrong result arrives with the test that fails without it; a
  precision claim arrives with a number that can be reproduced.
- Output formats are contracts too: `--json` failures keep the shape
  `{"error":{"code","message"}}` and exit 2; the HTML report stays
  self-contained and escapes everything it interpolates.
- Anything a user can see (README, CHANGELOG, `docs/CASE_STUDY.md`) is updated in
  the same commit as the behaviour it describes.
