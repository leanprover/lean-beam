#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
prefix="$(lean --print-prefix)"
build="$(mktemp -d)"
trap 'rm -f "$build/owned-process"; rmdir "$build"' EXIT
"${CC:-cc}" -std=c11 -I"$prefix/include" tests/native/owned_process_posix.c \
  -L"$prefix/lib/lean" -Wl,-rpath,"$prefix/lib/lean" -lleanshared -pthread -o "$build/owned-process"
"$build/owned-process"
