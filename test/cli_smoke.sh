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

# Version and help
expect_eq "moon-slice 0.2.0" version
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
trap 'rm -f "$tmp_html" "$tmp_bad"' EXIT
run html --file examples/04_while.mbt --line 7 --out "$tmp_html" >/dev/null
grep -Fq '<svg' "$tmp_html"
grep -Fq 'Slice nodes' "$tmp_html"

# Malformed input reports diagnostics and does not crash
tmp_bad="$(mktemp)"
printf 'fn broken( {\n  let x =\n}\n' > "$tmp_bad"
expect_contains "errors" dump-errors --file "$tmp_bad"

# Error paths: these must exit nonzero and must not emit a plausible result.
expect_fail "failed to read" graph --file "$tmp_bad.missing.mbt"
expect_fail "unsupported --direction" slice --file examples/04_while.mbt --line 7 --direction sideways
expect_fail "unknown argument" slice --file examples/04_while.mbt --line 7 --bogus
expect_fail "requires a value" slice --file
expect_fail "parser diagnostic" slice --file "$tmp_bad" --line 1

printf 'cli smoke ok\n'
