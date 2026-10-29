#!/usr/bin/env bash
# What does a diff affect? Produce a -U0 diff with git, then forward-slice
# every changed .mbt line.
#
#   bash tools/review.sh            # changes since HEAD~1
#   bash tools/review.sh origin/main
#   bash tools/review.sh HEAD~3 --json
#
# Arguments after the first are passed to `moon-slice review` unchanged.
set -euo pipefail
since="${1:-HEAD~1}"
shift || true

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

git diff -U0 "$since" -- '*.mbt' > "$tmp"
if [ ! -s "$tmp" ]; then
  echo "review: no .mbt changes since $since"
  exit 0
fi

./dev.sh run cmd/main -- review --diff "$tmp" "$@"
