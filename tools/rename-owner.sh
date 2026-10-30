#!/usr/bin/env bash
# Rewrite every reference to the repository owner, for after a GitHub account
# rename. The rename itself happens in GitHub's web settings; this script only
# makes the repository agree with it.
#
#   tools/rename-owner.sh --dry-run NaiWaniubi   # show what would change
#   tools/rename-owner.sh NaiWaniubi             # do it
#
# After it runs: push, wait for CI/Pages, then verify the new live URL. Old
# repository URLs keep redirecting, but the GitHub Pages URL changes, so the
# README badge and clone lines must point at the new owner.
set -euo pipefail
cd "$(dirname "$0")/.."

old="cs6210501-lab"
dry=""
owner="${1:-}"
if [ "$owner" = "--dry-run" ]; then
  dry="1"
  owner="${2:-}"
fi
if [ -z "$owner" ]; then
  echo "usage: tools/rename-owner.sh [--dry-run] <new-owner>" >&2
  exit 2
fi
if [ "$owner" = "$old" ]; then
  echo "rename-owner: already $old, nothing to do"
  exit 0
fi

# Tracked text files only: the generated bundle and the PDF are rebuilt below.
mapfile -t files < <(git grep -l "$old" -- '*.md' '*.mbt' '*.mjs' '*.yml' '*.yaml' '*.sh' 'moon.mod' | sort)

if [ "${#files[@]}" -eq 0 ]; then
  echo "rename-owner: no references to $old"
  exit 0
fi

printf 'rename-owner: %s -> %s in %d file(s)\n' "$old" "$owner" "${#files[@]}"
for file in "${files[@]}"; do
  count="$(grep -c "$old" "$file" || true)"
  printf '  %-40s %s\n' "$file" "$count"
done

if [ -n "$dry" ]; then
  echo "rename-owner: dry run, nothing written"
  exit 0
fi

for file in "${files[@]}"; do
  sed -i "s/${old}/${owner}/g" "$file"
done

# The bundle is a build of src/ and the PDF is generated from PROPOSAL.md, so
# both are regenerated rather than patched.
bash web/build.sh >/dev/null
if command -v pandoc >/dev/null 2>&1; then
  pandoc PROPOSAL.md --from=gfm --to=html5 --standalone --css=proposal.css -o submission/PROPOSAL.html
  if [ -n "${CHROME:-}" ] && [ -x "${CHROME:-}" ]; then
    html="$(cygpath -m "$PWD/submission/PROPOSAL.html" 2>/dev/null || echo "$PWD/submission/PROPOSAL.html")"
    pdf="$(cygpath -m "$PWD/submission/PROPOSAL.pdf" 2>/dev/null || echo "$PWD/submission/PROPOSAL.pdf")"
    "$CHROME" --headless=new --disable-gpu --no-sandbox --no-pdf-header-footer \
      --print-to-pdf="$pdf" "file:///$html" >/dev/null 2>&1 || true
  fi
  rm -f submission/PROPOSAL.html
fi

leftover="$(git grep -c "$old" -- '*.md' '*.mbt' '*.mjs' '*.yml' '*.yaml' '*.sh' 'moon.mod' 2>/dev/null || true)"
if [ -n "$leftover" ]; then
  echo "rename-owner: references still present:" >&2
  echo "$leftover" >&2
  exit 1
fi

cat <<EOF
rename-owner: done. Next:

  git add -A && git commit -m "chore: point the repository at ${owner} after the account rename"
  git remote set-url origin https://github.com/${owner}/moon-slice.git
  git push origin master --tags

Then wait for CI and Pages, and verify the new site:

  curl -sS https://${owner}.github.io/moon-slice/ | sha256sum
  node web/live_e2e.mjs
EOF
