# Benchmark

Generate a straight-line program with `N` assignments:

```bash
node bench/gen.mjs 500 big.mbt
./dev.sh run cmd/main -- slice --file big.mbt --line 502 --direction backward
```

The output path defaults to `big.mbt` in the current directory, so the command
works the same on Windows and POSIX. Delete the generated file after measuring.

Measured on Windows 10, MoonBit `0.1.20261023`, warm `moon run` cache:

| Command | Wall time | Output |
| --- | --- | --- |
| `slice --line 502 --direction backward` | 1.58 s | one line: `478,...,502` |
| `dead` | 1.35 s | one line |
| `graph` | 0.9 s | 505 DOT lines |

The wall time includes `moon run` startup and process launch; the analysis
itself is linear-ish for the structured subset. This is a smoke benchmark to
show that a 500-statement function does not blow up, not a rigorous performance
claim. The HTML SVG is truncated at 200 nodes; DOT has no truncation.
