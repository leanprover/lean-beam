#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Test-side process watchdog; no dependency of the installed Beam commands."""

from __future__ import annotations

import argparse
import math
import os
import signal
import subprocess
import sys
import tempfile


def _tail(stream, limit=1024 * 1024):
    # Read a fixed snapshot: an inherited writer must not extend collection indefinitely.
    end = stream.seek(0, os.SEEK_END)
    start = max(0, end - limit)
    stream.seek(start)
    text = stream.read(end - start).decode("utf-8", errors="replace")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return ("[earlier output omitted]\n" if start else "") + text


def _terminate_tree(proc):
    if os.name == "posix":
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    else:
        # Scope cleanup to the process this watchdog started and its descendants.
        cleanup_error = None
        try:
            result = subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    timeout=5, check=False)
            if result.returncode != 0 and proc.poll() is None:
                cleanup_error = OSError(f"taskkill exited with code {result.returncode}")
        except (OSError, subprocess.TimeoutExpired) as error:
            cleanup_error = error
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
        if cleanup_error is not None:
            raise cleanup_error
        return
    proc.wait(timeout=5)


def run_with_watchdog(command, *, timeout, cwd=None, env=None):
    """Return bounded output tails, preserve exit status, and raise TimeoutExpired on timeout.

    Output goes to files so descendants retaining stdout/stderr cannot block collection.
    Returned strings are bounded; the temporary files have no disk-usage limit.
    Timeout cleanup targets the owned POSIX process group or Windows process tree. Each
    cleanup wait is bounded separately; the timeout is not an OS process-creation bound.
    """
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("watchdog timeout must be finite and positive")
    command = [os.fspath(arg) for arg in command]
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        proc = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                stdout=out, stderr=err,
                                start_new_session=(os.name == "posix"))
        try:
            proc.wait(timeout=timeout)
        except BaseException as failure:
            cleanup_message = ""
            try:
                _terminate_tree(proc)
            except (OSError, subprocess.TimeoutExpired) as cleanup:
                cleanup_message = f"\nwatchdog cleanup failed: {cleanup}\n"
            if isinstance(failure, subprocess.TimeoutExpired):
                failure.output = _tail(out)
                failure.stderr = _tail(err) + cleanup_message
            elif cleanup_message:
                sys.stderr.write(cleanup_message)
            raise
        return subprocess.CompletedProcess(command, proc.returncode, _tail(out), _tail(err))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    try:
        result = run_with_watchdog(command, timeout=args.timeout)
    except ValueError as error:
        parser.error(str(error))
    except subprocess.TimeoutExpired as error:
        sys.stdout.write(error.output or "")
        sys.stderr.write(error.stderr or "")
        sys.stderr.write(f"\nexternal watchdog expired after {args.timeout:g} seconds\n")
        return 124
    else:
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == "__main__":
    sys.exit(main())
