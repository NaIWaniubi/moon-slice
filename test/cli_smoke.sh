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
expect_eq "moon-slice 0.7.3" version
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

# SARIF and baselines: the CI-facing output must be valid SARIF 2.1.0, and a
# baseline must hide exactly the findings it recorded.
tmp_sarif="$(mktemp)"
run dead --file examples/08_dead_assignment.mbt --format sarif --out "$tmp_sarif" >/dev/null
node -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(j.version!=="2.1.0") throw new Error("not SARIF 2.1.0");
const run=j.runs[0];
if(!run||run.tool.driver.name!=="moon-slice") throw new Error("bad tool");
if(run.results.length!==2) throw new Error("expected 2 results, got "+run.results.length);
const r=run.results[0];
if(r.ruleId!=="dead-store"||r.level!=="warning") throw new Error("bad rule/level");
const loc=r.locations[0].physicalLocation;
if(loc.region.startLine!==4) throw new Error("bad line: "+loc.region.startLine);
if(!loc.artifactLocation.uri.endsWith("examples/08_dead_assignment.mbt")) throw new Error("bad uri: "+loc.artifactLocation.uri);
if(!r.partialFingerprints) throw new Error("no fingerprint");
' "$tmp_sarif"

tmp_base="$(mktemp)"
expect_contains "2 finding(s)" dead --file examples/08_dead_assignment.mbt --write-baseline "$tmp_base"
expect_eq "" dead --file examples/08_dead_assignment.mbt --baseline "$tmp_base"
expect_contains '"suppressed":2' dead --file examples/08_dead_assignment.mbt --baseline "$tmp_base" --json

# --fail-on-findings is the CI gate: findings exit 1, a suppressed baseline 0.
set +e
gate_out="$(run dead --file examples/08_dead_assignment.mbt --fail-on-findings)"
gate_rc=$?
set -e
if [ "$gate_rc" -ne 1 ]; then
  printf 'FAIL: --fail-on-findings exit %s (expected 1)\n' "$gate_rc" >&2
  exit 1
fi
printf '%s' "$gate_out" | grep -Fq '4,5'
set +e
run dead --file examples/08_dead_assignment.mbt --baseline "$tmp_base" --fail-on-findings >/dev/null
gate_rc=$?
set -e
if [ "$gate_rc" -ne 0 ]; then
  printf 'FAIL: baseline + --fail-on-findings exit %s (expected 0)\n' "$gate_rc" >&2
  exit 1
fi

expect_fail "only supported by dead" slice --file examples/04_while.mbt --line 7 --baseline "$tmp_base"
expect_json_error bad_format slice --file examples/04_while.mbt --line 7 --format sarif
expect_json_error read_failed dead --file examples/08_dead_assignment.mbt --baseline "$tmp_base.missing"

# Directory scan: one command over a tree, deterministic order, JSON/SARIF
# shapes, and the same baseline/gate semantics as the single-file mode.
dir_count="$(run dead --dir examples | wc -l | tr -d ' ')"
if [ "$dir_count" != "7" ]; then
  printf 'FAIL: dead --dir examples returned %s lines (expected 7)\n' "$dir_count" >&2
  exit 1
fi
expect_eq "" dead --dir src
expect_contains "examples/01_let.mbt:7" dead --dir examples
dir_json="$(run dead --dir examples --json)"
printf '%s' "$dir_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  if(j.files!==10) throw new Error("files != 10: "+j.files);
  if(j.findings.length!==7) throw new Error("findings != 7: "+j.findings.length);
  if(j.errors.length!==0) throw new Error("errors: "+j.errors);
  if(j.findings[0].file!=="examples/01_let.mbt") throw new Error("not sorted");
  if(j.findings[0].kind!=="dead-store") throw new Error("bad kind");
});'
dir_sarif="$(mktemp)"
run dead --dir examples --format sarif --out "$dir_sarif" >/dev/null
node -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const run=j.runs[0];
if(run.results.length!==7) throw new Error("results != 7");
if(run.properties.files!==10) throw new Error("files != 10");
if(run.properties.parseFailures!==0) throw new Error("parse failures");
if(run.invocations[0].executionSuccessful!==true) throw new Error("not successful");
' "$dir_sarif"
tmp_dir_base="$(mktemp)"
expect_contains "7 finding(s)" dead --dir examples --write-baseline "$tmp_dir_base"
expect_eq "" dead --dir examples --baseline "$tmp_dir_base"
set +e
run dead --dir examples --baseline "$tmp_dir_base" --fail-on-findings >/dev/null
gate_rc=$?
set -e
if [ "$gate_rc" -ne 0 ]; then
  printf 'FAIL: dir baseline gate exit %s (expected 0)\n' "$gate_rc" >&2
  exit 1
fi
expect_fail "use either --file or --dir" dead --dir examples --file examples/01_let.mbt
expect_fail "not a directory" dead --dir examples/does_not_exist.mbt

# Package liveness: a private function nothing in its package calls. The
# examples are standalone snippets, so every one of them is reported.
expect_contains "examples/04_while.mbt:3: loop_sum" unused --dir examples
unused_json_out="$(mktemp)"
run unused --dir examples --json > "$unused_json_out"
node -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(j.packages!==1) throw new Error("packages != 1: "+j.packages);
if(j.files!==10) throw new Error("files != 10: "+j.files);
if(j.findings.length!==10) throw new Error("findings != 10: "+j.findings.length);
if(j.suppressed!==0) throw new Error("suppressed != 0");
if(j.errors.length!==0) throw new Error("errors: "+j.errors);
if(typeof j.findings[0].name!=="string") throw new Error("bad name field");
' "$unused_json_out"
tmp_unused_base="$(mktemp)"
expect_contains "10 finding(s)" unused --dir examples --write-baseline "$tmp_unused_base"
expect_eq "" unused --dir examples --baseline "$tmp_unused_base"
set +e
run unused --dir examples --baseline "$tmp_unused_base" --fail-on-findings >/dev/null
unused_rc=$?
set -e
if [ "$unused_rc" -ne 0 ]; then
  printf 'FAIL: unused baseline gate exit %s (expected 0)
' "$unused_rc" >&2
  exit 1
fi
set +e
run unused --dir examples --fail-on-findings >/dev/null
unused_rc=$?
set -e
if [ "$unused_rc" -ne 1 ]; then
  printf 'FAIL: unused gate exit %s (expected 1)
' "$unused_rc" >&2
  exit 1
fi
unused_sarif="$(mktemp)"
run unused --dir examples --format sarif --out "$unused_sarif" >/dev/null
node -e '
const fs=require("fs");
const run=JSON.parse(fs.readFileSync(process.argv[1],"utf8")).runs[0];
if(run.results.length!==10) throw new Error("sarif results != 10");
const r=run.results[0];
if(r.ruleId!=="unused-function"||r.ruleIndex!==2) throw new Error("bad rule");
if(!r.message.text.includes("never referenced")) throw new Error("bad message");
' "$unused_sarif"
expect_fail "not a directory" unused --dir examples/does_not_exist
expect_json_error missing_dir unused --file examples/01_let.mbt

# Package-scope slicing: the callee lives in a sibling file, so the single-file
# expansion cannot see it. `--dir D --file F` makes the package the scope.
tmp_pkg="$(mktemp -d)"
cat > "$tmp_pkg/a.mbt" <<'MBT'
fn main_fn(x : Int) -> Int {
  twice(x)
}
MBT
cat > "$tmp_pkg/b.mbt" <<'MBT'
fn inc(x : Int) -> Int {
  x + 1
}

fn twice(x : Int) -> Int {
  let a = inc(x)
  let b = inc(a)
  b
}
MBT
# Absolute paths are platform-dependent (the shell's /tmp becomes a Windows path
# in the binary), so the assertions name files by suffix.
pkg_line="$(run slice --dir "$tmp_pkg" --file "$tmp_pkg/a.mbt" --line 2)"
printf '%s' "$pkg_line" | grep -Fq "a.mbt: 2"
if printf '%s' "$pkg_line" | grep -Fq "b.mbt"; then
  printf 'FAIL: package slice expanded without --interprocedural
  got: %s
' "$pkg_line" >&2
  exit 1
fi
pkg_cross="$(run slice --dir "$tmp_pkg" --file "$tmp_pkg/a.mbt" --line 2 --interprocedural)"
printf '%s' "$pkg_cross" | grep -Fq "a.mbt: 2"
printf '%s' "$pkg_cross" | grep -Fq "b.mbt: 2,6,7,8"
slice_pkg_out="$(mktemp)"
run slice --dir "$tmp_pkg" --file "$tmp_pkg/a.mbt" --line 2 --interprocedural --json > "$slice_pkg_out"
node -e '
const fs=require("fs");
const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
if(j.files.length!==2) throw new Error("expected 2 files, got "+j.files.length);
const b=j.files.find(f=>f.file.endsWith("b.mbt"));
if(!b) throw new Error("no b.mbt record");
if(JSON.stringify(b.lines)!==JSON.stringify([2,6,7,8])) throw new Error("bad b.mbt lines: "+b.lines);
if(b.nodes.length===0) throw new Error("no nodes");
if(j.errors.length!==0) throw new Error("errors: "+j.errors);
' "$slice_pkg_out"
expect_json_error missing_file slice --dir "$tmp_pkg" --line 2

# `callers`: who calls a function, across the package. Qualified calls
# (`T::f(x)`) count; receiver calls do not, because the receiver's type is
# unknown and guessing would invent a call.
expect_contains "a.mbt:2: main_fn" callers --dir "$tmp_pkg" --name twice
expect_eq "" callers --dir "$tmp_pkg" --name nobody_calls_this
callers_json="$(run callers --dir "$tmp_pkg" --name twice --json)"
printf '%s' "$callers_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  if(j.name!=="twice") throw new Error("bad name");
  if(j.callers.length!==1) throw new Error("expected 1 caller, got "+j.callers.length);
  const c=j.callers[0];
  if(!c.file.endsWith("a.mbt")||c.line!==2||c.caller!=="main_fn") throw new Error("bad caller: "+JSON.stringify(c));
  if(j.errors.length!==0) throw new Error("errors: "+j.errors);
});'
cat >> "$tmp_pkg/b.mbt" <<'MBT'

fn T::qualified(x : Int) -> Int {
  x * 2
}
MBT
cat >> "$tmp_pkg/a.mbt" <<'MBT'

fn uses_qualified() -> Int {
  T::qualified(3)
}
MBT
expect_contains "a.mbt:6: uses_qualified" callers --dir "$tmp_pkg" --name qualified
expect_eq "" callers --dir "$tmp_pkg" --name unqualified_missing

# Interprocedural return cone
expect_eq "2,6,7,8,12" slice --file bench/callgraph.mbt --line 12 --direction backward --interprocedural

# HTML report
tmp_html="$(mktemp)"
trap 'rm -rf "${tmp_html:-}" "${tmp_bad:-}" "${tmp_multi:-}" "${tmp_graph:-}" "${tmp_cmp:-}" "${tmp_ispat:-}" "${tmp_impl:-}" "${tmp_review_diff:-}" "${tmp_review_src:-}" "${tmp_sarif:-}" "${tmp_base:-}" "${tmp_dir_base:-}" "${dir_sarif:-}" "${tmp_unused_base:-}" "${unused_sarif:-}" "${unused_json_out:-}" "${tmp_pkg:-}" "${slice_pkg_out:-}"' EXIT
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

# Diff-aware review: a synthetic diff that adds one line must report the lines
# that line can affect.
tmp_review_src="review_probe.mbt"
tmp_review_diff="$(mktemp)"
cat > "$tmp_review_src" <<'MBT'
fn probe(x : Int) -> Int {
  let a = x + 1
  let b = a + 1
  return b
}
MBT
cat > "$tmp_review_diff" <<'DIFF'
--- a/review_probe.mbt
+++ b/review_probe.mbt
@@ -2,0 +3,1 @@
+  let b = a + 1
DIFF
review_out="$(run review --diff "$tmp_review_diff")"
printf '%s' "$review_out" | grep -Fq 'review_probe.mbt: changed 1 line(s) -> affected 2 line(s)'
printf '%s' "$review_out" | grep -Fq 'affected lines: 3,4'
review_json="$(run review --diff "$tmp_review_diff" --json)"
printf '%s' "$review_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  if(j.changed!==1) throw new Error("changed != 1: "+j.changed);
  if(j.affected!==2) throw new Error("affected != 2: "+j.affected);
  const r=j.records[0];
  if(r.file!=="review_probe.mbt") throw new Error("bad file");
  if(JSON.stringify(r.affected)!==JSON.stringify([3,4])) throw new Error("bad affected lines");
});'
rm -f "$tmp_review_src"


# In-source suppressions: a directive hides the finding on its line, a bare one
# hides every rule, and a named one hides only that rule. The `suppressed`
# counter proves the finding was seen and dropped, not that it never existed.
supp_dir="$(mktemp -d)"
cat > "$supp_dir/plain.mbt" <<'MBT'
fn compute() -> Int {
  let a = 1
  let b = 2
  a
}
MBT
cat > "$supp_dir/trailing.mbt" <<'MBT'
fn compute() -> Int {
  let a = 1
  let b = 2 // moon-slice: ignore dead-store
  a
}
MBT
cat > "$supp_dir/standalone.mbt" <<'MBT'
fn compute() -> Int {
  let a = 1
  // moon-slice: ignore
  let b = 2
  a
}
MBT
expect_eq "3" dead --file "$supp_dir/plain.mbt"
expect_eq "{\"nodes\":[],\"lines\":[],\"errors\":[],\"suppressed\":1}" dead --file "$supp_dir/trailing.mbt" --json
expect_eq "{\"nodes\":[],\"lines\":[],\"errors\":[],\"suppressed\":1}" dead --file "$supp_dir/standalone.mbt" --json

# A directive that names the wrong rule changes nothing: unreachable code stays
# visible when only dead-store is named.
cat > "$supp_dir/wrong_rule.mbt" <<'MBT'
fn broken() -> Int {
  return 1
  println("never") // moon-slice: ignore dead-store
}
MBT
expect_eq "3" dead --file "$supp_dir/wrong_rule.mbt"

cat > "$supp_dir/right_rule.mbt" <<'MBT'
fn broken() -> Int {
  return 1
  println("never") // moon-slice: ignore unreachable-code
}
MBT
expect_eq "{\"nodes\":[],\"lines\":[],\"errors\":[],\"suppressed\":1}" dead --file "$supp_dir/right_rule.mbt" --json

# An unknown rule name is inert rather than a silent blanket ignore.
cat > "$supp_dir/typo.mbt" <<'MBT'
fn compute() -> Int {
  let a = 1
  let b = 2 // moon-slice: ignore dead_stores
  a
}
MBT
expect_eq "3" dead --file "$supp_dir/typo.mbt"

# Package mode: the declaration is suppressed, the other private function is not.
cat > "$supp_dir/pkg.mbt" <<'MBT'
fn helper() -> Int {
  1
}

// moon-slice: ignore[unused-function]
fn orphan() -> Int {
  2
}

fn main {
  println(helper())
}
MBT
supp_pkg="$(run unused --dir "$supp_dir" --json)"
printf '%s' "$supp_pkg" | grep -Fq '"suppressed":1'

rm -rf "$supp_dir"


# Receiver calls in `callers`: a dot call is an edge only when the receiver's
# type is written in the source and the package declares that method on it.
rc_dir="$(mktemp -d)"
cat > "$rc_dir/a.mbt" <<'MBT'
struct Point {
  x : Int
}

fn use_point(p : Point) -> Int {
  p.norm()
}

fn unannotated() -> Int {
  let p = make()
  p.norm()
}
MBT
cat > "$rc_dir/b.mbt" <<'MBT'
impl Point with fn norm(self) -> Int {
  self.wrap()
}

fn Point::wrap(self) -> Int {
  self.x
}
MBT
rc_out="$(run callers --dir "$rc_dir" --name norm)"
# The tool normalizes paths to the platform form, so match on file:line:caller.
printf '%s\n' "$rc_out" | grep -Fq "a.mbt:6: use_point"
# The unannotated receiver on line 11 must not appear.
if printf '%s' "$rc_out" | grep -Fq "a.mbt:11"; then
  printf 'FAIL: an unannotated receiver produced a caller edge\n  %s\n' "$rc_out" >&2
  exit 1
fi
rc_self="$(run callers --dir "$rc_dir" --name wrap)"
printf '%s' "$rc_self" | grep -Fq "b.mbt:2: norm"

rm -rf "$rc_dir"

printf 'cli smoke ok\n'
