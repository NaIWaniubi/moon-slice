# Benchmark

Two things live here: a generator for a straight-line function, and a script
that measures the native release binary (not `moon run`, whose compile and
startup cost would dominate).

## Reproducible measurement

```bash
./dev.sh build --target native --release cmd/main
node bench/bench.mjs --sizes 500,2000,8000,32000 --reps 3
```

The script generates inputs in the system temp directory, warms each size, takes
the minimum of `--reps` runs, and prints a Markdown table. Measured on Windows
11, MoonBit `0.1.20261023`, native release:

| statements | command | min wall time (ms) |
| --- | --- | --- |
| 500 | `slice` | 41 |
| 500 | `dead` | 38 |
| 500 | `graph` | 44 |
| 2000 | `slice` | 77 |
| 2000 | `dead` | 72 |
| 2000 | `graph` | 82 |
| 8000 | `slice` | 299 |
| 8000 | `dead` | 257 |
| 8000 | `graph` | 223 |
| 32000 | `slice` | 1559 |
| 32000 | `dead` | 839 |
| 32000 | `graph` | 806 |

Wall time includes process start and output writing; `slice` on the largest
size prints about 32k line numbers, which is why it is the slowest command
at that size. Growth is roughly linear in the input size.

## Generating a single input

```bash
node bench/gen.mjs 500 big.mbt
./dev.sh run cmd/main -- slice --file big.mbt --line 503 --direction backward
```

The output path defaults to `big.mbt` in the current directory, so the command
works the same on Windows and POSIX. Delete the generated file after measuring.
The HTML SVG is truncated at 200 nodes and says so; DOT has no truncation.
