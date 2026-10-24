# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Single-consumer pipe framing for test clients; the caller owns the stream lifetime."""

import os
import select
import time


class PipeLineReader:
    """Keep read-ahead across manual and continuous reads of the same subprocess stdout.

    A dedicated reader may block on every platform. Deadline reads use POSIX pipe readiness.
    Never read the supplied stream through another buffered wrapper or consumer concurrently.
    Returned bytes include the newline, or an unterminated final line at EOF; empty bytes mean EOF.
    """

    def __init__(self, stream):
        self.stream = stream
        self._pending = bytearray()
        self._eof = False

    def read_line(self, *, deadline=None):
        while True:
            remaining = None if deadline is None else deadline - time.monotonic()
            if remaining is not None and remaining <= 0:
                raise TimeoutError('pipe line deadline expired')
            newline = self._pending.find(b'\n')
            if newline >= 0:
                line = bytes(self._pending[:newline+1])
                del self._pending[:newline+1]
                return line
            if self._eof:
                line = bytes(self._pending)
                self._pending.clear()
                return line
            if remaining is not None:
                ready, _, _ = select.select([self.stream], [], [], remaining)
                if not ready:
                    continue
            chunk = os.read(self.stream.fileno(), 64 * 1024)
            if chunk:
                self._pending.extend(chunk)
            else:
                self._eof = True
