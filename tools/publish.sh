#!/usr/bin/env bash
# Publish the current moon.mod version to mooncakes.io.
#
# This is a maintainer-local command, not a CI step: `moon login` needs a TTY.
# It verifies the tree, packages it, logs in if needed, previews the upload, and
# only then publishes after an explicit confirmation.
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.moon/bin:$PATH"

version="$(sed -n 's/^version = "\(.*\)"/\1/p' moon.mod | head -1)"
name="$(sed -n 's/^name = "\(.*\)"/\1/p' moon.mod | head -1)"
if [ -z "$version" ] || [ -z "$name" ]; then
  echo "publish: could not read name/version from moon.mod" >&2
  exit 2
fi

echo "publish: $name $version"
moon check
moon test
moon package

if [ ! -f "$HOME/.moon/credentials.json" ]; then
  echo "publish: no mooncakes credentials; 'moon login' needs your browser."
  moon login
fi

echo "publish: preview"
moon publish --dry-run

printf 'Publish %s %s to mooncakes.io? A version can only be published once. [y/N] ' "$name" "$version"
read -r answer
case "$answer" in
  y|Y|yes|YES) ;;
  *) echo "publish: cancelled"; exit 1 ;;
esac

moon publish
moon search moon-slice
echo "publish: done. Verify in a scratch module with:"
echo "  moon add $name@$version"
