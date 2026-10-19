#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Exercise the exact-leaf filesystem FFI with real OS permissions and links."""

import csv
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
EXE = ".exe" if os.name == "nt" else ""
COMMAND = ROOT / ".lake/build/bin" / ("beam-system-contract-test" + EXE)


def run(args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True,
                            text=True, encoding="utf-8", errors="replace", timeout=30)
    assert result.returncode == 0, f"{args}: {result.returncode}\n{result.stdout}\n{result.stderr}"
    return result


def directory_link(path, target):
    if os.name == "nt":
        run(["cmd", "/d", "/c", "mklink", "/J", path, target])
    else:
        path.symlink_to(target, target_is_directory=True)


def permissions(path):
    if os.name == "nt":
        return run(["icacls", path]).stdout
    return path.stat().st_mode


def main():
    with tempfile.TemporaryDirectory(prefix="beam system contracts-") as temporary:
        root = Path(temporary).resolve()
        target = root / "target"
        target.mkdir()
        sentinel = target / "sentinel"
        sentinel.write_bytes(b"existing leaf must stay unchanged")
        directory_link(root / "link", target)
        missing_target = root / "missing-target"
        missing_target.mkdir()
        directory_link(root / "dangling", missing_target)
        missing_target.rmdir()
        (root / "file").write_bytes(b"ordinary file")
        non_private = root / "non-private"
        non_private.mkdir()
        blocked = root / "blocked"
        blocked.mkdir()
        (blocked / "child").mkdir()
        if os.name == "nt":
            import ctypes
            from ctypes import wintypes
            # An explicit ordinary-account grant must remain rejected, without being repaired.
            run(["icacls", non_private, "/grant", "*S-1-1-0:(OI)(CI)RX"])
            user = next(csv.reader([run(["whoami", "/user", "/fo", "csv", "/nh"]).stdout.strip()]))
            owner_denied = root / "owner-denied"
            owner_denied.mkdir()
            run(["icacls", owner_denied, "/inheritance:r", "/grant:r", f"*{user[1]}:(OI)(CI)F"])
            run(["icacls", owner_denied, "/deny", f"*{user[1]}:(WD)"])
            # Attribute-only opens do not reliably conflict with a share-mode lock. Deny the
            # actual requested right and verify this fixture fails before invoking Beam.
            blocked_child = blocked / "child"
            run(["icacls", blocked_child, "/deny", f"*{user[1]}:(RA)"])
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                          wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
            kernel.CreateFileW.restype = wintypes.HANDLE
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            handle = kernel.CreateFileW(str(blocked_child), 0x80, 7, None, 3, 0x02200000, None)
            if handle != wintypes.HANDLE(-1).value:
                kernel.CloseHandle(handle)
                raise AssertionError("Windows permission fixture still permits reading attributes")
            assert ctypes.get_last_error() == 5, ctypes.get_last_error()
        else:
            assert os.geteuid() != 0, "permission regression must run without root privileges"
            non_private.chmod(0o755)
            blocked.chmod(0)
        before = {path: permissions(path) for path in [target, non_private]}
        try:
            print(run([COMMAND, "inspect", root]).stdout, end="")
            print(run([COMMAND, "create-race", root]).stdout, end="")
            assert sentinel.read_bytes() == b"existing leaf must stay unchanged"
            assert before == {path: permissions(path) for path in before}
            assert (root / "file").read_bytes() == b"ordinary file"
            assert not missing_target.exists(), "a dangling link's target was recreated"
        finally:
            if os.name == "nt":
                # Restore the fixture's deletion rights before TemporaryDirectory cleanup.
                run(["icacls", blocked_child, "/remove:d", f"*{user[1]}"])
                run(["icacls", owner_denied, "/remove:d", f"*{user[1]}"])
            else:
                blocked.chmod(0o700)


if __name__ == "__main__":
    main()
