#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# Match the installer's registry whitespace/comment handling; policy validation stays with callers.
beam_test_read_registry_entries() {
  awk '
    {
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 != "" && substr($0, 1, 1) != "#") {
        print
      }
    }
  ' "$1"
}
