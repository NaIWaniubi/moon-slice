#!/usr/bin/env bash
# Deterministic CLI smoke test. Runs the executable through dev.sh and asserts
# exact output for the commands used in the submission evidence.
set -euo pipefail
cd "$(dirname "$0")/.."

run() { ./dev.sh run cmd/main -- "$@" 2>/dev/null; }

expect_eq() {
  local want="$1"; shift
  local got; got="$(run "$@")"
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$*" "$want" "$got" >&2
    exit 1
  fi
}

expect_contains() {
  local want="$1"; shift
  local got; got="$(run "$@")"
  if ! printf '%s' "$got" | grep -Fq -- "$want"; then
    printf 'FAIL: %s\n  missing: %s\n' "$*" "$want" >&2
    exit 1
  fi
}

# Expect a nonzero exit and an error line. A successful command here is a bug:
# automation must never mistake a missing file or bad flag for a real result.
expect_fail() {
  local want="$1"; shift
  set +e
  local got; got="$(run "$@")"; local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'FAIL: %s exited 0 (expected failure)\n  output: %s\n' "$*" "$got" >&2
    exit 1
  fi
  if ! printf '%s' "$got" | grep -Fq -- "$want"; then
    printf 'FAIL: %s\n  missing: %s\n  output: %s\n' "$*" "$want" "$got" >&2
    exit 1
  fi
}

# Expect a nonzero exit AND a JSON error object with this code. `--json` callers
# must never have to parse human text, and a failed run must never exit 0.
expect_json_error() {
  local want_code="$1"; shift
  set +e
  local got; got="$(run "$@" --json)"; local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'FAIL: %s exited 0 (expected failure)
  output: %s
' "$*" "$got" >&2
    exit 1
  fi
  if ! printf '%s' "$got" | grep -Fq -- "\"code\":\"$want_code\""; then
    printf 'FAIL: %s
  missing error code: %s
  output: %s
' "$*" "$want_code" "$got" >&2
    exit 1
  fi
}

# Version and help
expect_eq "moon-slice 0.4.1" version
expect_contains "Commands:" help

# Core slicing
expect_eq "4,5,6,7,8" slice --file examples/04_while.mbt --line 7 --direction backward
expect_eq "7,10" slice --file examples/04_while.mbt --line 7 --direction forward
expect_eq "7,10" slice --file examples/06_match.mbt --line 7 --direction forward
expect_eq "6,7" slice --file examples/08_dead_assignment.mbt --line 7 --direction backward

# JSON
expect_contains '"lines":[4,5,6,7,8]' slice --file examples/04_while.mbt --line 7 --direction backward --json
expect_contains '"nodes":[1,2]' dead --file examples/08_dead_assignment.mbt --json
expect_contains '"nodes":[1,5]' path --file examples/04_while.mbt --from i --to total --json
expect_contains '{"found":false}' path --file examples/04_while.mbt --from total --to n --json
expect_contains '["twice","inc"]' callgraph --file bench/callgraph.mbt --json

# Dead / path / callgraph / graph
expect_eq "4,5" dead --file examples/08_dead_assignment.mbt
expect_eq "n1 L4 -> n5 L7" path --file examples/04_while.mbt --from i --to total
expect_eq "n1 L4 -> n3 L6 -> n4 L7" path --file examples/07_return.mbt --from base --to total
expect_contains '"twice" -> "inc"' callgraph --file bench/callgraph.mbt
expect_contains "digraph pdg" graph --file examples/04_while.mbt

# Interprocedural return cone
expect_eq "2,6,7,8,12" slice --file bench/callgraph.mbt --line 12 --direction backward --interprocedural

# HTML report
tmp_html="$(mktemp)"
trap 'rm -f "${tmp_html:-}" "${tmp_bad:-}" "${tmp_multi:-}" "${tmp_graph:-}" "${tmp_cmp:-}" "${tmp_ispat:-}" "${tmp_impl:-}"' EXIT
run html --file examples/04_while.mbt --line 7 --out "$tmp_html" >/dev/null
grep -Fq '<svg' "$tmp_html"
grep -Fq 'Slice nodes' "$tmp_html"

# Malformed input reports diagnostics and does not crash
tmp_bad="$(mktemp)"
printf 'fn broken( {\n  let x =\n}\n' > "$tmp_bad"
expect_contains "errors" dump-errors --file "$tmp_bad"

# Ambiguous lines: the CLI reports the candidates and honours --node.
tmp_multi="$(mktemp)"
printf 'fn f(x : Int) -> Int {
  let a = x + 1; let b = x + 2; a
}
' > "$tmp_multi"
expect_contains "has 3 statements" slice --file "$tmp_multi" --line 2 --direction backward
expect_eq "2" slice --file "$tmp_multi" --line 2 --direction backward --node 3
expect_fail "no node with id" slice --file "$tmp_multi" --line 2 --node 999

# Error paths: these must exit nonzero and must not emit a plausible result.
expect_fail "failed to read" graph --file "$tmp_bad.missing.mbt"
expect_fail "unsupported --direction" slice --file examples/04_while.mbt --line 7 --direction sideways
expect_fail "unknown argument" slice --file examples/04_while.mbt --line 7 --bogus
expect_fail "requires a value" slice --file
expect_fail "parser diagnostic" slice --file "$tmp_bad" --line 1

# Machine-readable contract: --json errors and graph --format json.
expect_json_error read_failed graph --file "$tmp_bad.missing.mbt"
expect_json_error unknown_argument slice --file examples/04_while.mbt --line 7 --bogus
expect_json_error no_node_at_line slice --file examples/04_while.mbt --line 9999

tmp_graph="$(mktemp)"
run graph --file examples/04_while.mbt --format json > "$tmp_graph"
node -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(!Array.isArray(j.nodes)||j.nodes.length===0) throw new Error("no nodes");
if(!Array.isArray(j.edges)||j.edges.length===0) throw new Error("no edges");
if(!j.nodes.every(n=>typeof n.id==="number"&&typeof n.kind==="string"&&typeof n.line==="number")) throw new Error("bad node shape");
if(!j.edges.every(e=>typeof e.from==="number"&&typeof e.to==="number"&&(e.kind==="data"||e.kind==="control"))) throw new Error("bad edge shape");
' "$tmp_graph"

# The HTML report carries the same result as embedded JSON plus a generator tag.
grep -Fq 'name="generator" content="moon-slice' "$tmp_html"
node -e '
const fs=require("fs");
const html=fs.readFileSync(process.argv[1],"utf8");
const m=html.match(/<script type="application\/json" id="moon-slice-result">([\s\S]*?)<\/script>/);
if(!m) throw new Error("no embedded result block");
const j=JSON.parse(m[1]);
if(typeof j.target.line!=="number"||typeof j.target.node!=="number") throw new Error("bad target");
if(!Array.isArray(j.nodes)||!Array.isArray(j.lines)) throw new Error("bad arrays");
' "$tmp_html"

# Precision comparison: the two control-dependence builders must differ on the
# shipped demo input, and the difference must be the documented one.
tmp_cmp="$(mktemp)"
run compare --file bench/precise_cdg.mbt --line 7 > "$tmp_cmp"
grep -Fq 'structural control edges: 18' "$tmp_cmp"
grep -Fq 'precise control edges:    7' "$tmp_cmp"
grep -Fq 'removed by precise:       12' "$tmp_cmp"
grep -Fq 'added by precise:         1' "$tmp_cmp"

# `path` is data flow: a route through an `if` condition must not be reported
# unless --with-control is passed.
tmp_ispat="$(mktemp)"
cat > "$tmp_ispat" <<'MBT'
fn f(o : Int?, d : Int) -> Int {
  if o is Some(v) {
    return v + 1
  }
  return d
}
MBT
expect_contains 'no path from o to v' path --file "$tmp_ispat" --from o --to v
expect_contains 'n0 L1' path --file "$tmp_ispat" --from o --to v --with-control

# An impl method body is analysed, not silently skipped.
tmp_impl="$(mktemp)"
cat > "$tmp_impl" <<'MBT'
struct T {
  mut v : Int
}

impl T with bump(self : T) -> Int {
  let unused = 1
  self.v = self.v + 1
  self.v
}
MBT
expect_eq "6" dead --file "$tmp_impl"
expect_eq "7" slice --file "$tmp_impl" --line 7 --direction backward

printf 'cli smoke ok\n'
