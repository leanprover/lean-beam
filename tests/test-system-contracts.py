#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Exercise the exact-leaf filesystem FFI with real OS permissions and links."""

import csv
import os
from pathlib import Path
import stat
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
    info = path.stat()
    return info.st_mode, info.st_uid, info.st_gid


def inspect_foreign_owner():
    # Observe an existing OS-owned directory; no privileged setup or ownership changes.
    # Prefer a 0700 leaf to demonstrate that mode alone does not establish privacy.
    candidates = []
    for path in [Path("/root"), Path("/var/root"), Path("/")]:
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISDIR(info.st_mode) and info.st_uid != os.geteuid():
            candidates.append((path, info))
    assert candidates, "ownership regression needs an existing foreign-owned directory"
    path, before = min(candidates, key=lambda item: stat.S_IMODE(item[1].st_mode) != 0o700)
    print(run([COMMAND, "foreign-owner", path]).stdout, end="")
    after = path.lstat()
    # The OS account may use its directory concurrently; check the leaf's identity/access policy.
    fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid")
    assert all(getattr(before, field) == getattr(after, field) for field in fields), path
    print(f"foreign-owner fixture: {path}, uid={before.st_uid}, "
          f"euid={os.geteuid()}, mode={stat.S_IMODE(before.st_mode):04o}")


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
        (root / "file").chmod(0o600)
        (root / "executable").write_bytes(b"static inspection must not execute this file")
        (root / "executable").chmod(0o700)
        non_private = root / "non-private"
        non_private.mkdir()
        if os.name == "nt":
            # An explicit ordinary-account grant must remain rejected, without being repaired.
            run(["icacls", non_private, "/grant", "*S-1-1-0:(OI)(CI)RX"])
            user = next(csv.reader([run(["whoami", "/user", "/fo", "csv", "/nh"]).stdout.strip()]))
            owner_denied = root / "owner-denied"
            owner_denied.mkdir()
            run(["icacls", owner_denied, "/inheritance:r", "/grant:r", f"*{user[1]}:(OI)(CI)F"])
            run(["icacls", owner_denied, "/deny", f"*{user[1]}:(WD)"])
            # Metadata opens may succeed despite share locks or ACLs on a privileged runner.
            # Invalid spelling gives an OS failure independent of those access privileges.
            try:
                (root / "invalid<leaf").stat()
            except OSError as error:
                assert error.winerror == 123, error
            else:
                raise AssertionError("Windows invalid-name fixture was accepted")
        else:
            assert os.geteuid() != 0, "permission regression must run without root privileges"
            blocked = root / "blocked"
            blocked.mkdir()
            (blocked / "child").mkdir()
            non_private.chmod(0o755)
            blocked.chmod(0)
        before = {path: permissions(path) for path in [target, non_private]}
        try:
            print(run([COMMAND, "inspect", root]).stdout, end="")
            print(run([COMMAND, "create-race", root]).stdout, end="")
            assert sentinel.read_bytes() == b"existing leaf must stay unchanged"
            assert before == {path: permissions(path) for path in before}
            assert (root / "file").read_bytes() == b"ordinary file"
            assert (root / "executable").read_bytes() == b"static inspection must not execute this file"
            assert not missing_target.exists(), "a dangling link's target was recreated"
            if os.name != "nt":
                inspect_foreign_owner()
        finally:
            if os.name == "nt":
                # Restore the fixture's deletion rights before TemporaryDirectory cleanup.
                run(["icacls", owner_denied, "/remove:d", f"*{user[1]}"])
            else:
                blocked.chmod(0o700)


if __name__ == "__main__":
    main()
