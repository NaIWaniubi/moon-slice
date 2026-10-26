#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./dev.sh build --target js --release src/web
cp _build/js/release/build/src/web/web.js web/moon-slice.js
echo "wrote web/moon-slice.js"
