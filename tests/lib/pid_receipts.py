# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Read owned fixture PID receipts while their publisher finishes an atomic rename."""

import os


def _windows_error(code, path):
    import ctypes
    error = ctypes.WinError(code)
    error.filename = str(path)
    return error


def _windows_api():
    import ctypes
    from ctypes import wintypes

    api = ctypes.WinDLL("kernel32", use_last_error=True)
    api.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                               ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                               wintypes.HANDLE]
    api.CreateFileW.restype = wintypes.HANDLE
    api.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                            ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
    api.ReadFile.restype = wintypes.BOOL
    api.CloseHandle.argtypes = [wintypes.HANDLE]
    api.CloseHandle.restype = wintypes.BOOL
    return api


def _windows_read(path):
    import ctypes
    from ctypes import wintypes

    api = _windows_api()
    # A rename publishes the name before closing its DELETE-access handle. The CRT
    # reader does not share delete access, so it can reject that published file.
    # https://devblogs.microsoft.com/oldnewthing/20211022-00/?p=105822
    # GENERIC_READ, FILE_SHARE_READ|WRITE|DELETE, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL.
    handle = api.CreateFileW(str(path), 0x80000000, 7, None, 3, 0x80, None)
    if handle == ctypes.c_void_p(-1).value:
        raise _windows_error(ctypes.get_last_error(), path)
    failed = False
    try:
        parts = []
        buffer = ctypes.create_string_buffer(4096)
        count = wintypes.DWORD()
        while True:
            if not api.ReadFile(handle, buffer, len(buffer), ctypes.byref(count), None):
                raise _windows_error(ctypes.get_last_error(), path)
            if count.value == 0:
                return b"".join(parts).decode("ascii")
            parts.append(buffer.raw[:count.value])
    except BaseException:
        failed = True
        raise
    finally:
        if not api.CloseHandle(handle) and not failed:
            raise _windows_error(ctypes.get_last_error(), path)


def read_pid_receipt(path):
    """Allow rename sharing on Windows; preserve missing-file and genuine access failures."""
    if os.name == "nt":
        return _windows_read(path)
    return path.read_text(encoding="ascii")
