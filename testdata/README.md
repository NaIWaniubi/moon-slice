# Slice test corpus

Each file in `examples/` is a small, self-contained MoonBit program with two
header lines that pin the expected result of slicing:

```text
// EXPECT-BACKWARD <target-line> -> [<line>, ...]
// EXPECT-FORWARD  <target-line> -> [<line>, ...]
```

Grammar (one directive per line, first two lines of the file):

```text
EXPECT-BACKWARD \s+ (\d+) \s* -> \s* \[ \s* (\d+ (\s*,\s* \d+)*)? \s* \]
EXPECT-FORWARD  \s+ (\d+) \s* -> \s* \[ \s* (\d+ (\s*,\s* \d+)*)? \s* \]
```

Both slices are **inclusive of the target line**, because a statement's own
definition is part of its slice. Line lists are unique and ascending; they are
`loc.start_line` of the slice nodes, so one line may stand for one node only
(these examples keep one statement per line).

`examples/` deliberately has no `moon.pkg`: the directory is data for the
test corpus, not a package, so `moon check` and `moon test` never try to build
it. All files are nevertheless valid MoonBit — they were type-checked with the
real compiler (0 errors; 12 `unused_value` warnings and one `missing_priv`
warning, both inherent to standalone snippets).

`expected.json` is the same table in machine-readable form, for the wave-2
end-to-end test.

## Expected slices

| Example | Target | Statement at target | Backward | Forward | Why |
| --- | --- | --- | --- | --- | --- |
| `01_let.mbt` | 5 | `let b = a + 2` | `[4, 5]` | `[5, 6, 8]` | `b` reads the `a` defined on 4; `b` then feeds `c` on 6 and `c` reaches `return c` on 8. |
| `02_mut.mbt` | 6 | `n = n + 2` | `[5, 6]` | `[6, 7, 8]` | The store on 5 kills the initializer on 4, so `n` read here is 5's value; this store then reaches 7 and `return n` on 8. |
| `03_if_else.mbt` | 6 | `tag = 1` (then-branch) | `[5, 6]` | `[6, 10]` | A literal store has no data input, but it is control-dependent on the `if` header on 5; the value it writes can reach the join at 10. |
| `04_while.mbt` | 7 | `total = total + i` | `[4, 5, 6, 7, 8]` | `[7, 10]` | `total` and `i` each have two reaching definitions (loop preheader on 4/5 and loop back edge on 7/8) plus the guard on 6; the accumulated `total` escapes the loop at 10. |
| `05_for.mbt` | 7 | `acc = acc + scaled` | `[4, 5, 6, 7]` | `[7, 9]` | `scaled` comes from 6, the `for` header on 5 defines the iterator `i`, `acc` is carried by 4 and by this store itself; the result leaves via `return acc` on 9. |
| `06_match.mbt` | 7 | `label = 20` (second arm) | `[5, 7]` | `[7, 10]` | The arm is control-dependent on the `match` header on 5 and writes nothing else; `label` reaches the join at 10. |
| `07_return.mbt` | 6 | `let total = base + cap` | `[4, 5, 6]` | `[6, 7, 8, 10]` | `total` feeds the guard on 7, which controls the early `return` on 8, and `total` is also returned directly on 10. |
| `08_dead_assignment.mbt` | 7 | `cache = cache + 4` | `[6, 7]` | `[7, 8, 9]` | The stores on 4 and 5 are dead (killed on 6 before any read) and correctly absent from the backward slice; this store reaches `result` on 8 and `return` on 9. |
| `09_shadowing.mbt` | 6 | `let b = a + 3` | `[5, 6]` | `[6, 7]` | `a` here resolves to the inner binding on 5 (`scope` distinguishes the two `VarId`s), so the outer `let a = 1` on 4 must not appear; `b` is read on 7. |
| `10_field_write.mbt` | 11 | `let total = p.left + p.right` | `[9, 10, 11]` | `[11, 12]` | Field access is modeled conservatively as a read of `p`, so both the struct literal on 9 and the field store on 10 reach this line; `total` is returned on 12. |

## Notes on the expected sets

These are the deliberate edge cases baked into the corpus, and they are what
the implementation must reproduce:

- **Backward does not mean "all preceding statements".** `01` excludes 7 and
  `08` excludes 4 and 5: dead code is not in the slice.
- **Definitions are included, but only the reaching ones.** `02` contains 5 and
  not 4, because the store on 5 kills the initializer.
- **Control dependence shows up as a line.** `03`, `05`, `06` include their
  enclosing `if`/`for`/`match` header even though the condition value is not
  data-used by the target. This is the structured control-dependence rule.
- **Loops produce loop-carried edges.** `04` includes 8 (`i = i + 1`) in the
  backward slice of 7, because 8's value reaches the next iteration of 7, and
  7 itself is a reaching definition of `total` on the back edge.
- **Forward stops at the last use.** `03` forward is `[6, 10]`, not every later
  line: 8 is a sibling branch and is not affected by 6's write.
- **Shadowing is scope-sensitive.** `09` backward excludes 4; a name-based
  (scope-insensitive) def-use would wrongly include it.
- **Fields alias conservatively.** `10` treats `p.left` and `p.right` as
  accesses to `p`, so 9 and 10 both reach 11. A field-sensitive analysis would
  still include both here, but for different reasons (weak vs. strong update).
