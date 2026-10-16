#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
FAKE_OWNER = """
import os, signal, sys, time
from pathlib import Path

if os.environ.get('STUBBORN_OWNER') == '1':
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
else:
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
Path(os.environ['OWNER_PID_FILE']).write_text(str(os.getpid()))
print('serving Beam session', file=sys.stderr, flush=True)
while True:
    time.sleep(1)
"""


class CompatibilityOwnerTests(unittest.TestCase):
    def run_owner_shell(self, commands, expected=0):
        with tempfile.TemporaryDirectory(prefix="beam-compat-owner-test-") as tmp:
            root = Path(tmp)
            owner = root / "owner.py"
            owner.write_text(FAKE_OWNER)
            script = f"""
set -euo pipefail
. tests/lib/wait.sh
. tests/lib/toolchain-compat-owner.sh
stale_owner_stdout={shlex.quote(str(root / 'owner.out'))}
stale_owner_stderr={shlex.quote(str(root / 'owner.err'))}
export OWNER_PID_FILE={shlex.quote(str(root / 'owner.pid'))}
stale_owner_pid=""
stale_wrapper_command=(python3 {shlex.quote(str(owner))})
run_stale_wrapper() {{ "${{stale_wrapper_command[@]}}" "$@"; }}
print_toolchain_context() {{ echo "$*" >&2; }}
{commands}
"""
            proc = subprocess.Popen(
                ["bash", "-c", script], cwd=ROOT, start_new_session=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                proc.wait(timeout=5)
            finally:
                # Every fake owner belongs to this test's process group.
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                out, err = proc.communicate()
            self.assertEqual(proc.returncode, expected, out + err)

    def test_old_readiness_cannot_admit_a_new_owner(self):
        self.run_owner_shell(r'''
printf 'serving Beam session: old generation\n' > "$stale_owner_stderr"
mkfifo "$stale_owner_stdout"
eval "$(declare -f wait_for_file_text | sed '1s/wait_for_file_text/wait_for_current_owner/')"
wait_for_file_text() {
  # Opening stdout blocks the child before its stderr redirection. This makes the old
  # marker race deterministic until the parent has cleared it and reached this poll.
  if grep -q 'old generation' "$stale_owner_stderr"; then
    echo 'accepted stale readiness' >&2
    return 1
  fi
  cat "$stale_owner_stdout" > /dev/null &
  fifo_reader_pid="$!"
  wait_for_current_owner "$@"
}
start_stale_owner
test "$stale_owner_pid" = "$(cat "$OWNER_PID_FILE")"
cleanup_stale_owner
wait "$fifo_reader_pid"
''')

    def test_cleanup_escalates_for_an_unresponsive_owner(self):
        self.run_owner_shell(r'''
export STUBBORN_OWNER=1
start_stale_owner
owner_pid="$stale_owner_pid"
eval "$(declare -f wait_for_exit | sed '1s/wait_for_exit/wait_for_owner_exit/')"
wait_for_exit() { wait_for_owner_exit "$1" "$2" 10 0.01; }
cleanup_stale_owner
test -z "$stale_owner_pid"
! kill -0 "$owner_pid" 2>/dev/null
cleanup_stale_owner
''')

    def test_exit_cleanup_preserves_the_test_failure(self):
        self.run_owner_shell(r'''
trap cleanup_stale_owner EXIT
start_stale_owner
exit 37
''', expected=37)


if __name__ == "__main__":
    unittest.main()
