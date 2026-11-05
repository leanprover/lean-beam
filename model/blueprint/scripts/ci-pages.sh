#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
lake exe vbp build
test -f _out/site/html-multi/index.html
