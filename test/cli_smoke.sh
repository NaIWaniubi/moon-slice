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

# Version and help. The expected version comes from moon.mod, so a
# release that bumps one and forgets the other fails here.
manifest_version="$(sed -n 's/^version = "\(.*\)"$/\1/p' moon.mod | head -1)"
expect_eq "moon-slice $manifest_version" version
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
trap 'rm -rf "${tmp_html:-}" "${tmp_bad:-}" "${tmp_multi:-}" "${tmp_graph:-}" "${tmp_cmp:-}" "${tmp_ispat:-}" "${tmp_impl:-}" "${tmp_review_diff:-}" "${tmp_review_src:-}" "${tmp_sarif:-}" "${tmp_base:-}" "${tmp_dir_base:-}" "${dir_sarif:-}" "${tmp_unused_base:-}" "${unused_sarif:-}" "${unused_json_out:-}" "${tmp_pkg:-}" "${slice_pkg_out:-}" "${rw_dir:-}"' EXIT
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

# A binding typed by a declared return type resolves too.
cat > "$rc_dir/c.mbt" <<'MBT'
fn make_point() -> Point {
  Point::{ x : 1 }
}

fn via_return() -> Int {
  let p = make_point()
  p.norm()
}
MBT
rc_inferred="$(run callers --dir "$rc_dir" --name norm)"

# A field access carries its declared type into the receiver lookup.
cat > "$rc_dir/d.mbt" <<'MBT'
struct Holder {
  p : Point
}

fn via_field(h : Holder) -> Int {
  h.p.norm()
}
MBT
rc_field="$(run callers --dir "$rc_dir" --name norm)"
printf '%s' "$rc_field" | grep -Fq "d.mbt:6: via_field"

# A `let` pattern binds the enum payload type.
cat > "$rc_dir/e.mbt" <<'MBT'
enum MaybeP {
  Just(Point)
}

fn via_pattern(m : MaybeP) -> Int {
  let Just(p) = m
  p.norm()
}
MBT
rc_pattern="$(run callers --dir "$rc_dir" --name norm)"
printf '%s' "$rc_pattern" | grep -Fq "e.mbt:7: via_pattern"

# A `match` arm binds its payload type too.
cat > "$rc_dir/f.mbt" <<'MBT'
fn via_match(m : MaybeP) -> Int {
  match m {
    Just(p) => p.norm()
  }
}
MBT
rc_match="$(run callers --dir "$rc_dir" --name norm)"
printf '%s' "$rc_match" | grep -Fq "f.mbt:3: via_match"
printf '%s' "$rc_inferred" | grep -Fq "c.mbt:7: via_return"
rm -rf "$rc_dir"

# Methods are liveness candidates when they are inherent (`impl T with fn m`),
# and never when they belong to a trait impl; a leading underscore and any
# mention at a call site keep a declaration alive.
ml_dir="$(mktemp -d)"
cat > "$ml_dir/a.mbt" <<'MBT'
struct P {
  v : Int
}

impl P with unreferenced(self : P) -> Int {
  self.v
}

fn call(p : P) -> Int {
  p.used()
}

impl P with used(self : P) -> Int {
  self.v
}

impl Show for P with show(self : P) -> String {
  "p"
}

fn _marker() -> Int {
  1
}
MBT
ml_out="$(run unused --dir "$ml_dir")"
printf '%s\n' "$ml_out" | grep -Fq ":5: unreferenced"
printf '%s\n' "$ml_out" | grep -Fq ":9: call"
for hidden in used show _marker; do
  if printf '%s' "$ml_out" | grep -Fq " $hidden"; then
    printf 'FAIL: %s should not be reported\n  %s\n' "$hidden" "$ml_out" >&2
    exit 1
  fi
done
rm -rf "$ml_dir"

# A receiver call expands into the method body when the type is written down.
rx_dir="$(mktemp -d)"
cat > "$rx_dir/a.mbt" <<'MBT'
struct P {
  v : Int
}

impl P with norm(self : P) -> Int {
  self.v + 1
}

fn use(p : P) -> Int {
  p.norm()
}
MBT
rx_out="$(run slice --dir "$rx_dir" --file "$rx_dir/a.mbt" --line 10 --interprocedural)"
printf '%s' "$rx_out" | grep -Fq "6,10"
rm -rf "$rx_dir"

# `path --format sarif` reports the flow as one result with related locations.
path_sarif="$(run path --file examples/01_let.mbt --from a --to c --format sarif)"
printf '%s' "$path_sarif" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  const r=j.runs[0].results;
  if(r.length!==1) throw new Error("results != 1");
  if(r[0].ruleId!=="data-flow-path") throw new Error("bad rule");
  if(r[0].ruleIndex!==3) throw new Error("bad rule index");
  if(r[0].locations[0].physicalLocation.region.startLine!==4) throw new Error("bad start line");
  const rel=r[0].relatedLocations.map(x=>x.physicalLocation.region.startLine);
  if(JSON.stringify(rel)!==JSON.stringify([5,6,8])) throw new Error("bad related lines: "+JSON.stringify(rel));
});'

# Package reachability and receiver-call coverage: the semantics wave exposed
# on the CLI. One fixture: `main` -> `middle` -> `leaf`, an `orphan` nothing
# reaches, and one dot call per resolution category.
rw_dir="$(mktemp -d)"
cat > "$rw_dir/a.mbt" <<'MBT'
fn leaf() -> Int {
  1
}

fn middle() -> Int {
  leaf()
}

fn main {
  println(middle())
}

fn orphan() -> Int {
  0
}
MBT
cat > "$rw_dir/cov.mbt" <<'MBT'
struct Point {
  x : Int
}

struct Circle {
  r : Int
}

impl Point with norm(self : Point) -> Int {
  self.x
}

impl Circle with norm(self : Circle) -> Int {
  self.r
}

fn on_point(p : Point) -> Int {
  p.norm()
}

fn on_circle(c : Circle) -> Int {
  c.norm()
}

fn unknown() -> Int {
  let v = pick()
  v.norm()
}

fn ext(s : String) -> Int {
  s.len()
}

fn wrong(p : Point) -> Int {
  p.nope()
}
MBT

# explain-live: the shortest chain, one line per frame, each with its site.
expect_contains "a.mbt:9: main (root)" explain-live --dir "$rw_dir" --name leaf
expect_contains "a.mbt:10: main -> middle" explain-live --dir "$rw_dir" --name leaf
expect_contains "a.mbt:6: middle -> leaf" explain-live --dir "$rw_dir" --name leaf
live_json="$(run explain-live --dir "$rw_dir" --name leaf --json)"
printf '%s' "$live_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  if(j.name!=="leaf"||j.reachable!==true) throw new Error("bad header");
  const names=j.steps.map(x=>x.function);
  if(JSON.stringify(names)!==JSON.stringify(["main","middle","leaf"])) throw new Error("bad chain: "+names);
  if(j.steps[0].line!==9||j.steps[1].line!==10||j.steps[2].line!==6) throw new Error("bad sites");
  if(!j.steps[0].file.endsWith("a.mbt")) throw new Error("bad file");
  if(j.errors.length!==0) throw new Error("errors: "+j.errors);
});'

# A dead function gets a reason and exit 2, never an invented chain.
expect_fail "not reachable from any root" explain-live --dir "$rw_dir" --name orphan
expect_json_error unreachable explain-live --dir "$rw_dir" --name orphan
expect_json_error unknown_name explain-live --dir "$rw_dir" --name no_such_fn

# explain-dead: the root set, the evidence, and the unresolved boundaries.
expect_contains "entry point: main at" explain-dead --dir "$rw_dir" --name orphan
expect_contains "no function in the package calls or mentions \`orphan\`" explain-dead --dir "$rw_dir" --name orphan
expect_contains "call to \`println\`" explain-dead --dir "$rw_dir" --name orphan
dead_json="$(run explain-dead --dir "$rw_dir" --name orphan --json)"
printf '%s' "$dead_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  if(j.function!=="orphan") throw new Error("bad name");
  if(!j.file.endsWith("a.mbt")||j.line!==13) throw new Error("bad site");
  if(j.roots.length!==1||!j.roots[0].includes("entry point: main")) throw new Error("bad roots");
  if(!j.evidence.some(e=>e.includes("no function in the package calls"))) throw new Error("bad evidence");
  if(!j.boundaries.some(b=>b.includes("println"))) throw new Error("bad boundaries");
  if(j.searched_files!==2) throw new Error("bad file count: "+j.searched_files);
});'
# A live function has no dead proof to give.
expect_json_error reachable explain-dead --dir "$rw_dir" --name leaf

# coverage: every dot call gets a verdict, and the three outcomes sum to total.
expect_contains "total: 5" coverage --dir "$rw_dir"
expect_contains "resolved: 2" coverage --dir "$rw_dir"
expect_contains "ambiguous: 1" coverage --dir "$rw_dir"
expect_contains "unresolved: 2" coverage --dir "$rw_dir"
expect_contains "method_not_declared: 1" coverage --dir "$rw_dir"
cov_json="$(run coverage --dir "$rw_dir" --json)"
printf '%s' "$cov_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  if(j.total!==5||j.resolved!==2||j.ambiguous!==1||j.unresolved!==2) throw new Error("bad counters: "+JSON.stringify(j));
  if(j.resolved+j.ambiguous+j.unresolved!==j.total) throw new Error("invariant broken");
  if(j.by_reason.method_not_declared!==1||j.by_reason.external_package!==1) throw new Error("bad reasons: "+JSON.stringify(j.by_reason));
  if(j.errors.length!==0) throw new Error("errors: "+j.errors);
});'

# The new commands keep the CLI contract: bad input exits 2, --json keeps the
# {"error":{"code","message"}} shape.
expect_fail "not a directory" coverage --dir "$rw_dir/does_not_exist"
expect_json_error missing_dir explain-dead --name orphan
expect_fail "is not used by coverage" coverage --dir "$rw_dir" --name leaf

rm -rf "$rw_dir"

# impact: the certificate reports the forward-slice union, one evidence path per
# affected statement, and the same proof in text and JSON.
expect_contains "affected statements: 5,7" impact --file examples/04_while.mbt --lines 7
expect_contains '"affected_statements":[5,7]' impact --file examples/04_while.mbt --lines 7 --json
expect_contains '"evidence":[{"node":5,"line":7,"path":[5]},{"node":7,"line":10,"path":[5,7]}]' impact --file examples/04_while.mbt --lines 7 --json
expect_contains "evidence:" impact --file examples/04_while.mbt --lines 7
expect_fail "is required for impact" impact --file examples/04_while.mbt
tmp_empty_patch="$(mktemp)"
expect_fail "the diff adds no .mbt line" impact --diff "$tmp_empty_patch"
rm -f "$tmp_empty_patch"

# impact --diff takes the changed lines from a unified patch, one certificate
# per touched file.
tmp_impact_patch="$(mktemp)"
cat > "$tmp_impact_patch" <<'PATCH'
--- a/examples/04_while.mbt
+++ b/examples/04_while.mbt
@@ -7 +7 @@
-    total = total + i // target
+    total = total + i // changed
PATCH
expect_contains '"files":1' impact --diff "$tmp_impact_patch" --json
expect_contains '"certificate":{"changed_lines":[7]' impact --diff "$tmp_impact_patch" --json
rm -f "$tmp_impact_patch"

# Package scope: the change is in a private helper, but the proof names the
# public entry that reaches it and the test that has to be run.
impact_dir="$(mktemp -d)"
cat > "$impact_dir/a.mbt" <<'MBT'
pub fn api() -> Int {
  helper()
}
MBT
cat > "$impact_dir/b.mbt" <<'MBT'
fn helper() -> Int {
  let mut x = 1
  x = x + 1
  x
}
MBT
cat > "$impact_dir/a_test.mbt" <<'MBT'
test "api" {
  assert_eq(api(), 2)
}
MBT
impact_out="$(run impact --file "$impact_dir/b.mbt" --lines 3 --dir "$impact_dir" --json)"
printf '%s' "$impact_out" | grep -Fq '"affected_functions":["helper"]'
printf '%s' "$impact_out" | grep -Fq '"reachable_entries":["api (public api)","api (test call)"]'
printf '%s' "$impact_out" | grep -Fq 'a_test.mbt:2: api'
rm -rf "$impact_dir"

# `fix`: plan the dead code that can be deleted safely. The default prints a
# unified diff and must not touch the file; impure dead code is never removed;
# --write applies the plan and a second run plans nothing (idempotency).
# Each subdirectory is its own package, so an unresolved boundary in one fixture
# cannot disable function removal in another.
fix_dir="$(mktemp -d)"
mkdir -p "$fix_dir/clean" "$fix_dir/impure" "$fix_dir/guarded"
cat > "$fix_dir/clean/fixable.mbt" <<'MBT'
fn orphan() -> Int {
  7
}

fn keep(x : Int) -> Int {
  let unused = 1
  x
}

fn main {
  keep(1)
}
MBT
fix_diff="$(run fix --dir "$fix_dir/clean")"
printf '%s' "$fix_diff" | grep -Fq -- "-  let unused = 1"
printf '%s' "$fix_diff" | grep -Fq -- "-fn orphan() -> Int {"
# Diff mode must leave the working tree alone.
grep -Fq "let unused = 1" "$fix_dir/clean/fixable.mbt"

fix_json="$(run fix --dir "$fix_dir/clean" --json)"
printf '%s' "$fix_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  if(!Array.isArray(j.edits)||j.edits.length!==2) throw new Error("edits != 2: "+JSON.stringify(j.edits));
  const e=j.edits[0];
  if(typeof e.file!=="string"||typeof e.start_line!=="number"||typeof e.end_line!=="number"||typeof e.reason!=="string") throw new Error("bad edit shape: "+JSON.stringify(e));
  if(!Array.isArray(j.proof)||j.proof.length===0) throw new Error("no proof");
});'

run fix --dir "$fix_dir/clean" --write >/dev/null
if grep -Fq "let unused = 1" "$fix_dir/clean/fixable.mbt"; then
  printf 'FAIL: --write did not remove the unused binding\n' >&2
  exit 1
fi
if grep -Fq "fn orphan" "$fix_dir/clean/fixable.mbt"; then
  printf 'FAIL: --write did not remove the unreachable function\n' >&2
  exit 1
fi
fix_after="$(run fix --dir "$fix_dir/clean" --json)"
printf '%s' "$fix_after" | grep -Fq '"edits":[]'

# A side-effecting initializer is dead but not removable, and the proof says
# why. `println` also leaves an unresolved boundary, so no function goes either.
cat > "$fix_dir/impure/impure.mbt" <<'MBT'
fn keep(x : Int) -> Int {
  let ghost = println("side effect")
  x
}

fn main {
  keep(1)
}
MBT
impure_diff="$(run fix --dir "$fix_dir/impure" --json)"
if printf '%s' "$impure_diff" | grep -Fq -- '"edits":[{'; then
  printf 'FAIL: fix removed a side-effecting binding\n  %s\n' "$impure_diff" >&2
  exit 1
fi
printf '%s' "$impure_diff" | grep -Fq 'would perform I/O'

# A suppression directive wins over the planner, and a public function is never
# touched: both stay in the file after --write.
cat > "$fix_dir/guarded/guarded.mbt" <<'MBT'
// moon-slice: ignore[unused-function]
fn suppressed() -> Int {
  1
}

pub fn api() -> Int {
  2
}

fn main {
  api()
}
MBT
run fix --dir "$fix_dir/guarded" --write >/dev/null
grep -Fq "fn suppressed() -> Int {" "$fix_dir/guarded/guarded.mbt"
grep -Fq "pub fn api() -> Int {" "$fix_dir/guarded/guarded.mbt"
# Scans must not descend into tool/workspace directories: a dead binding inside
# .tower, .v2c, _build or .mooncakes is not part of the package under test.
skip_dir="$(mktemp -d)"
mkdir -p "$skip_dir/.tower" "$skip_dir/.v2c" "$skip_dir/_build" "$skip_dir/.mooncakes" "$skip_dir/pkg"
for hidden in .tower .v2c _build .mooncakes; do
  cat > "$skip_dir/$hidden/hidden.mbt" <<'MBT'
fn keep() -> Int {
  let unused = 1
  7
}

fn main {
  keep()
}
MBT
done
cat > "$skip_dir/pkg/visible.mbt" <<'MBT'
fn keep() -> Int {
  let unused = 1
  7
}

fn main {
  keep()
}
MBT
skip_json="$(run fix --dir "$skip_dir" --json)"
printf '%s' "$skip_json" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  const j=JSON.parse(s);
  if(j.edits.length!==1) throw new Error("expected 1 edit, got "+j.edits.length+": "+JSON.stringify(j.edits));
  if(!j.edits[0].file.includes("pkg/visible.mbt")) throw new Error("wrong file: "+j.edits[0].file);
});'
run fix --dir "$skip_dir" --write >/dev/null
for hidden in .tower .v2c _build .mooncakes; do
  if ! grep -Fq "let unused = 1" "$skip_dir/$hidden/hidden.mbt"; then
    printf 'FAIL: fix scanned %s\n' "$hidden" >&2
    exit 1
  fi
done
rm -rf "$skip_dir"
rm -rf "$fix_dir"

printf 'cli smoke ok\n'
