#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""PID readiness preserves real failures and tolerates a publisher's rename handle."""

from contextlib import contextmanager
import ctypes
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import Mock

from lib.pid_receipts import _windows_api, _windows_read, read_pid_receipt

spec = importlib.util.spec_from_file_location(
    "helper_lifetime", Path(__file__).with_name("test-lake-helper-lifetime.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class ReceiptsTest(unittest.TestCase):
    def test_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            fixture.check_pid_receipts(Path(temporary))

    def test_read_and_missing(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receipt.pid"
            with self.assertRaises(FileNotFoundError):
                read_pid_receipt(path)
            path.write_text("123", encoding="ascii")
            self.assertEqual(read_pid_receipt(path), "123")

    def test_access_failure_is_not_pending_or_retried(self):
        error = PermissionError(13, "denied")
        with patch.object(fixture, "read_pid_receipt", side_effect=error) as read:
            with self.assertRaises(PermissionError) as caught:
                fixture.pid_receipts(Path("unused"))
        self.assertIs(caught.exception, error)
        self.assertEqual(read.call_count, 1)

    def test_native_handle_closed_on_read_failure(self):
        api = Mock()
        api.CreateFileW.return_value = 42
        error = OSError("read failed")
        api.ReadFile.side_effect = error
        api.CloseHandle.return_value = False
        with patch("lib.pid_receipts._windows_api", return_value=api):
            with self.assertRaises(OSError) as caught:
                _windows_read(Path("unused"))
        self.assertIs(caught.exception, error)
        api.CloseHandle.assert_called_once_with(42)

    def test_native_read_error_captured_before_close(self):
        api = Mock()
        api.CreateFileW.return_value = 42
        api.ReadFile.return_value = False
        error = OSError("native read failed")
        with patch("lib.pid_receipts._windows_api", return_value=api), \
                patch.object(ctypes, "get_last_error", return_value=5, create=True), \
                patch.object(ctypes, "WinError", return_value=error, create=True) as winerror:
            with self.assertRaises(OSError) as caught:
                _windows_read(Path("unused"))
        self.assertIs(caught.exception, error)
        winerror.assert_called_once_with(5)
        api.CloseHandle.assert_called_once_with(42)

    def test_native_short_reads_and_successful_close(self):
        from ctypes import wintypes
        api = Mock()
        api.CreateFileW.return_value = 42
        parts = iter([b"12", b"3", b""])

        def read(handle, buffer, length, count, overlapped):
            data = next(parts)
            ctypes.memmove(buffer, data, len(data))
            ctypes.cast(count, ctypes.POINTER(wintypes.DWORD)).contents.value = len(data)
            return True

        api.ReadFile.side_effect = read
        with patch("lib.pid_receipts._windows_api", return_value=api):
            self.assertEqual(_windows_read(Path("unused")), "123")
        api.CloseHandle.assert_called_once_with(42)


@unittest.skipUnless(os.name == "nt", "requires real Windows file sharing")
class WindowsReceiptsTest(unittest.TestCase):
    @contextmanager
    def hold(self, path, access, sharing):
        api = _windows_api()
        handle = api.CreateFileW(str(path), access, sharing, None, 3, 0x80, None)
        if handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            yield
        finally:
            self.assertTrue(api.CloseHandle(handle))

    def test_delete_handle_reproduces_old_reader_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "helper.pid").write_text("123", encoding="ascii")
            path = root / "descendant.pid"
            path.write_text("456", encoding="ascii")
            # DELETE access models the handle still open after publishing a rename.
            with self.hold(path, 0x10000, 7):
                with self.assertRaises(PermissionError):
                    path.read_text(encoding="ascii")
                self.assertEqual(fixture.pid_receipts(root), [123, 456])

    def test_denied_read_sharing_still_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receipt.pid"
            path.write_text("123", encoding="ascii")
            with self.hold(path, 0x40000000, 0):
                with self.assertRaises(OSError) as caught:
                    read_pid_receipt(path)
                self.assertEqual(caught.exception.winerror, 32)

    def test_success_closes_reader(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receipt.pid"
            path.write_text("123", encoding="ascii")
            self.assertEqual(read_pid_receipt(path), "123")
            # This exclusive open would fail if the read handle leaked.
            with self.hold(path, 0x80000000, 0):
                pass


if __name__ == "__main__":
    unittest.main()
