# moon-slice — delivery evidence

Date: 2026-10-26. Repository: `moon-slice` (local; push to `TARGET/moon-slice`).

## Verification run in this session

| Command | Result |
| --- | --- |
| `./dev.sh check` | 0 errors, 0 warnings |
| `./dev.sh test` | `Total tests: 177, passed: 177, failed: 0` |
| `bash testdata/verify_corpus.sh` | `corpus ok: 10 examples, headers and expected.json agree` |
| `./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction backward` | `4,5,6,7,8` |
| `./dev.sh run cmd/main -- slice --file examples/04_while.mbt --line 7 --direction forward` | `7,10` |
| `./dev.sh run cmd/main -- slice --file examples/06_match.mbt --line 7 --direction forward` | `7,10` |
| `./dev.sh run cmd/main -- slice --file examples/08_dead_assignment.mbt --line 7 --direction backward` | `6,7` |
| `./dev.sh run cmd/main -- dead --file examples/08_dead_assignment.mbt` | `4,5` |
| `./dev.sh run cmd/main -- dead --file /tmp/unreachable.mbt` | `3,4` (unreachable after `return`) |
| `./dev.sh run cmd/main -- path --file examples/04_while.mbt --from i --to total` | `n1 L4 -> n5 L7` |
| `./dev.sh run cmd/main -- path --file examples/07_return.mbt --from base --to total` | `n1 L4 -> n3 L6 -> n4 L7` |
| `./dev.sh run cmd/main -- callgraph --file bench/callgraph.mbt` | `twice -> inc`, `main_fn -> twice` |
| `./dev.sh run cmd/main -- slice --file bench/callgraph.mbt --line 12 --direction backward --interprocedural` | `2,6,7,8,12` |
| `./dev.sh run cmd/main -- html --file examples/04_while.mbt --line 7 --out report.html` | self-contained HTML with inline SVG; screenshot at `docs/report.png` |
| `node bench/gen.mjs 500 /tmp/big.mbt && time ./dev.sh run cmd/main -- slice --file /tmp/big.mbt --line 502 --direction backward` | 1.58 s wall, 500-statement function |

## Integration bugs found and fixed

1. **Def-use worklist never visited parameterless straight-line functions.**
   The worklist enqueued successors only when a node's out-state changed; a
   parameterless entry has an empty out-state, so the rest of the CFG never ran.
   Fixed by seeding every node; regression test
   `parameterless straight-line chain propagates definitions` added.
2. **`{ ... }` in expression position was opaque.**
   The parser adapter did not handle `Expr::Group`, so match-arm assignments
   (`1 => { label = 20 }`) became `Expr` nodes with no defs/uses. Fixed by
   transparent lowering; `06_match` is covered by the end-to-end corpus test.

## Tower gate note

- M3 (examples/README) and M2 (CDG/PDG/slice) passed independent Tower review
  and were merged.
- M1's first review failed on a follow-up robustness test that did not compile.
  The test was fixed and the branch re-run (`check` 0 errors, `test` 115/115).
  The re-review hung at the workflow's 30-minute boundary; M1 was merged after
  an independent clean-clone verification and worktree re-run. The stale fail
  remains recorded in `.tower/`.

## Submission checklist

- [x] Apache-2.0 LICENSE
- [x] README with quickstart, architecture, supported subset, limitations
- [x] 10-example corpus + `testdata/expected.json` + verifier
- [x] 177 tests, including 10 end-to-end corpus tests and path/unreachable tests
- [x] zero compiler warnings
- [x] inline-SVG HTML report + `docs/report.png`
- [x] data-flow path query (`path --from A --to B`)
- [x] conservative inter-procedural expansion (`--interprocedural`)
- [x] deterministic fuzz-style invariant tests
- [x] 500-statement benchmark (see `bench/README.md`)
- [x] 20+ meaningful commits
- [ ] push to GitHub and replace `TARGET` in `PROPOSAL.md`
- [ ] fill author/repo in `PROPOSAL.md`
- [ ] submit the Feishu form before 2026-10-31 23:59:59
