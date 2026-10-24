#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Check framing and buffer ownership independently of Lean and MCP routing."""

from contextlib import contextmanager
import os
import time
import unittest
from unittest import mock

from lib.pipe_lines import PipeLineReader


class PipeLinesTest(unittest.TestCase):
    @contextmanager
    def pipe(self):
        incoming, outgoing = os.pipe()
        with os.fdopen(incoming, 'rb', buffering=0) as stream:
            try:
                yield PipeLineReader(stream), outgoing
            finally:
                os.close(outgoing)

    def test_continuous_and_deadline_reads_share_buffer(self):
        with self.pipe() as (reader, writer):
            os.write(writer, b'first\nsecond\nthird\n')
            with mock.patch('lib.pipe_lines.select.select', return_value=([reader.stream], [], [])):
                self.assertEqual(reader.read_line(deadline=time.monotonic()+5), b'first\n')
            # A new consumer must inherit read-ahead, rather than wait for new pipe bytes.
            with mock.patch('lib.pipe_lines.os.read', side_effect=AssertionError('unexpected OS read')):
                self.assertEqual(reader.read_line(), b'second\n')
                self.assertEqual(reader.read_line(deadline=time.monotonic()+5), b'third\n')

    @unittest.skipUnless(os.name == 'posix', 'deadline pipe readiness is POSIX-only')
    def test_incomplete_line_survives_timeout(self):
        with self.pipe() as (reader, writer):
            os.write(writer, b'partial')
            with self.assertRaises(TimeoutError):
                reader.read_line(deadline=time.monotonic()+0.02)
            os.write(writer, b' tail\n')
            self.assertEqual(reader.read_line(deadline=time.monotonic()+5), b'partial tail\n')

    def test_split_utf8_is_only_decoded_after_framing(self):
        with self.pipe() as (reader, _):
            chunks = ['λ'.encode()[:1], 'λ'.encode()[1:]+b'\n']
            with mock.patch('lib.pipe_lines.os.read', side_effect=chunks):
                self.assertEqual(reader.read_line().decode('utf-8'), 'λ\n')

    def test_eof_returns_unterminated_tail_once(self):
        with self.pipe() as (reader, _):
            with mock.patch('lib.pipe_lines.os.read', side_effect=[b'first\ntail', b'']):
                self.assertEqual(reader.read_line(), b'first\n')
                self.assertEqual(reader.read_line(), b'tail')
                self.assertEqual(reader.read_line(), b'')
                self.assertEqual(reader.read_line(), b'')

    def test_expired_deadline_does_not_consume_pending_line(self):
        with self.pipe() as (reader, writer):
            os.write(writer, b'first\nsecond\n')
            self.assertEqual(reader.read_line(), b'first\n')
            with self.assertRaises(TimeoutError):
                reader.read_line(deadline=time.monotonic()-1)
            self.assertEqual(reader.read_line(), b'second\n')


if __name__ == '__main__':
    unittest.main()
