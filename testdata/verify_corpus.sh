#!/usr/bin/env bash
# Cross-check the example corpus: EXPECT headers <-> testdata/expected.json.
# Every file in examples/ must carry both headers, the target line must exist,
# every listed line must exist, and the JSON table must agree with the headers.
# Run from the repo root:  bash testdata/verify_corpus.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail=0
err() { printf 'FAIL %s\n' "$*" >&2; fail=1; }

shopt -s nullglob
files=(examples/*.mbt)
if [ "${#files[@]}" -ne 10 ]; then
  err "expected 10 examples, found ${#files[@]}"
fi

# Parse one directive: verify_corpus.sh parse <file> <BACKWARD|FORWARD>
# Prints "<target>|<l1,l2,...>" with spaces removed from the list only.
parse() {
  local file="$1" dir="$2" line
  line="$(grep -m1 -E "^// EXPECT-${dir} [0-9]+ -> \[" "$file" || true)"
  [ -n "$line" ] || { echo "MISSING"; return 0; }
  printf '%s\n' "$line" \
    | sed -E "s#^// EXPECT-${dir} ([0-9]+) -> \[(.*)\][[:space:]]*#\\1|\\2#" \
    | awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $1 "|" $2}'
}

for f in "${files[@]}"; do
  total_lines="$(wc -l < "$f" | tr -d ' ')"
  if [ "$total_lines" -gt 30 ]; then
    err "$f: $total_lines lines (> 30)"
  fi

  for dir in BACKWARD FORWARD; do
    parsed="$(parse "$f" "$dir")"
    if [ "$parsed" = "MISSING" ]; then
      err "$f: missing or malformed EXPECT-$dir header"
      continue
    fi
    target="${parsed%%|*}"
    listed="${parsed#*|}"
    case "$target" in ''|*[!0-9]*) err "$f: EXPECT-$dir non-numeric target '$target'"; continue;; esac
    [ "$target" -ge 1 ] && [ "$target" -le "$total_lines" ] \
      || err "$f: EXPECT-$dir target line $target outside 1..$total_lines"

    prev=0
    for n in $(printf '%s' "$listed" | tr ',' ' '); do
      case "$n" in (*[!0-9]*) err "$f: EXPECT-$dir non-numeric entry '$n'"; continue;; esac
      [ "$n" -ge 1 ] && [ "$n" -le "$total_lines" ] \
        || err "$f: EXPECT-$dir line $n outside 1..$total_lines"
      [ "$n" -gt "$prev" ] || err "$f: EXPECT-$dir lines not strictly ascending at $n"
      prev="$n"
    done

    case ",$listed," in
      *",$target,"*) : ;;
      *) err "$f: EXPECT-$dir target $target not included in its own slice" ;;
    esac
  done
done

# JSON agreement, using node (present in this environment).
if command -v node >/dev/null 2>&1; then
  if ! node - "$root" <<'JS'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const data = JSON.parse(fs.readFileSync(path.join(root, "testdata/expected.json"), "utf8"));
let bad = 0;
const seen = new Set();
for (const ex of data.examples) {
  seen.add(ex.file);
  const file = path.join(root, ex.file);
  if (!fs.existsSync(file)) { console.error(`FAIL ${ex.file}: missing`); bad++; continue; }
  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
  for (const dir of ["BACKWARD", "FORWARD"]) {
    const key = dir.toLowerCase();
    const re = new RegExp(`^// EXPECT-${dir} (\\d+) -> \\[([^\\]]*)\\]`);
    const hit = lines.find((l) => re.test(l));
    if (!hit) { console.error(`FAIL ${ex.file}: no EXPECT-${dir}`); bad++; continue; }
    const m = hit.match(re);
    const target = Number(m[1]);
    const listed = m[2].split(",").map((s) => Number(s.trim())).filter((n) => !Number.isNaN(n));
    if (target !== ex.target_line) {
      console.error(`FAIL ${ex.file}: JSON target ${ex.target_line} != header ${target}`);
      bad++;
    }
    const want = ex[key];
    if (JSON.stringify(listed) !== JSON.stringify(want)) {
      console.error(`FAIL ${ex.file}: ${key} header [${listed}] != JSON [${want}]`);
      bad++;
    }
  }
}
const want = data.examples.map((e) => e.file);
for (const f of want) if (!fs.existsSync(path.join(root, f))) { console.error(`FAIL JSON lists missing ${f}`); bad++; }
process.exit(bad ? 1 : 0);
JS
  then
    fail=1
  fi
else
  printf 'SKIP testdata/expected.json agreement (node not found)\n' >&2
fi

if [ "$fail" -ne 0 ]; then
  printf '\ncorpus check FAILED\n' >&2
  exit 1
fi
printf 'corpus ok: %d examples, headers and expected.json agree\n' "${#files[@]}"
