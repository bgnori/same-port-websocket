"""Autobahn-Testsuite-style conformance tests for /ws-echo/socket.

The real Autobahn|Testsuite (crossbario/autobahn-testsuite) runs only under
Docker / Python 2; this repository's environments provide neither, so this
module reimplements the representative behaviour of its case classes with the
standard library only, against the same echo endpoint the Docker runner in
tools/autobahn/ targets:

  1.x  framing (text/binary echo across the length-encoding boundaries)
  2.x  pings/pongs
  3.x  reserved bits
  4.x  reserved opcodes
  5.x  fragmentation
  6.x  UTF-8 handling
  7.x  close behaviour (codes, echo, trailing data)
  9.x  limits (up to the server's 1 MiB default, plus the 1009 overflow reply)

Each test notes the Autobahn case class it mirrors. For a run of the original
suite under Docker, see tools/autobahn/README.md.
"""

import os
import socket
import struct
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

try:  # package context: python3 -m unittest tests.test_ws_autobahn
    from .test_ws_std import EchoSocket
except ImportError:  # discovery context: python3 -m unittest discover -s tests
    from test_ws_std import EchoSocket

ROOT = Path(__file__).resolve().parents[1]

MIB = 1 << 20


class AutobahnStyleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.log = tempfile.TemporaryFile(mode="w+")
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            cls.http_port = reservation.getsockname()[1]
        cls.process = subprocess.Popen(
            [str(ROOT / ".lake/build/bin/wsecho"), str(cls.http_port)],
            cwd=ROOT, stdout=cls.log, stderr=cls.log,
        )
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if cls.process.poll() is not None:
                    raise RuntimeError("Server exited during startup")
                try:
                    probe = socket.create_connection(("127.0.0.1", cls.http_port), timeout=1)
                    probe.close()
                    break
                except OSError:
                    time.sleep(0.05)
            else:
                raise RuntimeError("Server did not become ready")
        except BaseException:
            cls.tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        try:
            cls.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.process.kill()
            cls.process.wait()
        cls.log.seek(0)
        output = cls.log.read()
        cls.log.close()
        if cls.process.returncode not in (0, -15):
            raise AssertionError(f"Server failed:\n{output}")

    def connect(self):
        ws = EchoSocket(self.http_port)
        self.addCleanup(ws.close)
        return ws

    @staticmethod
    def raw_frame(data, opcode, final=True, rsv=0, masked=True):
        """Like EchoSocket.frame_bytes but with explicit RSV bits."""
        header = bytes([(0x80 if final else 0) | (rsv << 4) | opcode])
        size = len(data)
        mask_bit = 0x80 if masked else 0
        if size < 126:
            header += bytes([mask_bit | size])
        elif size < 65536:
            header += bytes([mask_bit | 126]) + struct.pack("!H", size)
        else:
            header += bytes([mask_bit | 127]) + struct.pack("!Q", size)
        mask = os.urandom(4)
        return header + mask + bytes(
            value ^ mask[index % 4] for index, value in enumerate(data)
        )

    # --- 1.x framing --------------------------------------------------------

    def test_1_text_echo_length_boundaries(self):
        ws = self.connect()
        for size in (0, 1, 125, 126, 127, 128, 65535, 65536):
            payload = ("a" * size).encode()
            ws.send_frame(payload, opcode=1)
            self.assertEqual(ws.frame(), (1, payload), f"text size={size}")

    def test_1_binary_echo_length_boundaries(self):
        ws = self.connect()
        for size in (0, 1, 125, 126, 127, 128, 65535, 65536):
            payload = os.urandom(size)
            ws.send_frame(payload, opcode=2)
            self.assertEqual(ws.frame(), (2, payload), f"binary size={size}")

    # --- 2.x pings/pongs ----------------------------------------------------

    def test_2_ping_payload_echoed_in_pong(self):
        ws = self.connect()
        for payload in (b"", b"ping!", os.urandom(125)):
            ws.send_frame(payload, opcode=9)
            self.assertEqual(ws.frame(), (10, payload))

    def test_2_ten_pings_answered_in_order(self):
        ws = self.connect()
        payloads = [f"ping-{i}".encode() for i in range(10)]
        for payload in payloads:
            ws.send_frame(payload, opcode=9)
        # Pongs must come back in order; a trailing echo shows data still flows.
        ws.send_frame(b"after", opcode=1)
        for payload in payloads:
            self.assertEqual(ws.frame(), (10, payload))
        self.assertEqual(ws.frame(), (1, b"after"))

    def test_2_unsolicited_pong_then_ping(self):
        ws = self.connect()
        ws.send_frame(b"orphan", opcode=10)
        ws.send_frame(b"probe", opcode=9)
        self.assertEqual(ws.frame(), (10, b"probe"))

    def test_2_oversized_ping_closes_1002(self):
        ws = self.connect()
        ws.send_frame(b"x" * 126, opcode=9)
        ws.expect_close(1002)

    # --- 3.x reserved bits --------------------------------------------------

    def test_3_reserved_bits_close_1002(self):
        for rsv in (1, 2, 4, 5):
            with self.subTest(rsv=rsv):
                ws = self.connect()
                ws.socket.sendall(self.raw_frame(b"rsv", opcode=1, rsv=rsv))
                ws.expect_close(1002)
                ws.expect_eof()

    # --- 4.x reserved opcodes -----------------------------------------------

    def test_4_reserved_opcodes_close_1002(self):
        for opcode in (3, 4, 5, 6, 7, 11, 12, 13, 14, 15):
            with self.subTest(opcode=opcode):
                ws = self.connect()
                ws.send_frame(b"", opcode=opcode)
                ws.expect_close(1002)
                ws.expect_eof()

    # --- 5.x fragmentation --------------------------------------------------

    def test_5_fragmented_ping_closes_1002(self):
        ws = self.connect()
        ws.send_frame(b"frag", opcode=9, final=False)
        ws.expect_close(1002)

    def test_5_text_in_many_small_fragments(self):
        ws = self.connect()
        ws.send_frame(b"f", opcode=1, final=False)
        for _ in range(30):
            ws.send_frame(b"r", opcode=0, final=False)
        ws.send_frame(b"!", opcode=0, final=True)
        self.assertEqual(ws.frame(), (1, b"f" + b"r" * 30 + b"!"))

    def test_5_empty_fragments_assemble(self):
        ws = self.connect()
        ws.send_frame(b"", opcode=1, final=False)
        ws.send_frame(b"", opcode=0, final=False)
        ws.send_frame(b"", opcode=0, final=True)
        self.assertEqual(ws.frame(), (1, b""))

    def test_5_pings_interleaved_with_fragments(self):
        ws = self.connect()
        ws.send_frame(b"one ", opcode=1, final=False)
        ws.send_frame(b"mid1", opcode=9)
        ws.send_frame(b"two ", opcode=0, final=False)
        ws.send_frame(b"mid2", opcode=9)
        ws.send_frame(b"three", opcode=0, final=True)
        self.assertEqual(ws.frame(), (10, b"mid1"))
        self.assertEqual(ws.frame(), (10, b"mid2"))
        self.assertEqual(ws.frame(), (1, b"one two three"))

    def test_5_new_data_frame_during_fragmentation_closes_1002(self):
        ws = self.connect()
        ws.send_frame(b"first", opcode=1, final=False)
        ws.send_frame(b"second", opcode=1, final=True)
        ws.expect_close(1002)

    def test_5_continuation_without_message_closes_1002(self):
        ws = self.connect()
        ws.send_frame(b"stray", opcode=0, final=True)
        ws.expect_close(1002)

    # --- 6.x UTF-8 ----------------------------------------------------------

    def test_6_multibyte_utf8_echo(self):
        ws = self.connect()
        for text in ("κόσμε", "こんにちは", "𐍈𝒜🤖", "a\u00e9\u4e16\U0001F600"):
            payload = text.encode()
            ws.send_frame(payload, opcode=1)
            self.assertEqual(ws.frame(), (1, payload))

    def test_6_invalid_utf8_single_frame_closes_1007(self):
        ws = self.connect()
        ws.send_frame(b"\xff\xfe\xfd", opcode=1)
        ws.expect_close(1007)

    def test_6_invalid_utf8_across_fragments_closes_1007(self):
        ws = self.connect()
        # A valid 3-byte sequence split so each fragment alone is incomplete,
        # followed by an invalid continuation byte in the final fragment.
        ws.send_frame(b"hello \xe4\xbd", opcode=1, final=False)
        ws.send_frame(b"\xff", opcode=0, final=True)
        ws.expect_close(1007)

    def test_6_multibyte_split_across_fragments_echoes(self):
        ws = self.connect()
        payload = "折り紙".encode()
        ws.send_frame(payload[:4], opcode=1, final=False)
        ws.send_frame(payload[4:], opcode=0, final=True)
        self.assertEqual(ws.frame(), (1, payload))

    # --- 7.x close behaviour ------------------------------------------------

    def test_7_close_without_payload_answered_with_1000(self):
        ws = self.connect()
        ws.send_frame(b"", opcode=8)
        ws.expect_close(1000)
        ws.expect_eof()

    def test_7_valid_close_codes_echoed(self):
        for code in (1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011,
                     3000, 3999, 4000, 4999):
            with self.subTest(code=code):
                ws = self.connect()
                ws.send_frame(struct.pack("!H", code), opcode=8)
                ws.expect_close(code)
                ws.expect_eof()

    def test_7_close_with_reason_echoes_code(self):
        ws = self.connect()
        reason = ("r" * 121).encode()
        ws.send_frame(struct.pack("!H", 1000) + reason, opcode=8)
        ws.expect_close(1000)
        ws.expect_eof()

    def test_7_invalid_close_codes_rejected_1002(self):
        for code in (0, 999, 1004, 1005, 1006, 1015, 1016, 2000, 2999):
            with self.subTest(code=code):
                ws = self.connect()
                ws.send_frame(struct.pack("!H", code), opcode=8)
                ws.expect_close(1002)
                ws.expect_eof()

    def test_7_close_code_with_one_byte_payload_closes_1002(self):
        ws = self.connect()
        ws.send_frame(b"\x03", opcode=8)
        ws.expect_close(1002)

    def test_7_close_reason_invalid_utf8_closes_1007(self):
        ws = self.connect()
        ws.send_frame(struct.pack("!H", 1000) + b"\xff\xff", opcode=8)
        ws.expect_close(1007)

    def test_7_data_after_close_is_ignored(self):
        ws = self.connect()
        ws.socket.sendall(
            EchoSocket.frame_bytes(struct.pack("!H", 1000), opcode=8)
            + EchoSocket.frame_bytes(b"late", opcode=1)
        )
        ws.expect_close(1000)
        ws.expect_eof()

    # --- 9.x limits ---------------------------------------------------------

    def test_9_large_binary_echo_up_to_the_limit(self):
        ws = self.connect()
        for size in (64 * 1024, 256 * 1024, MIB):
            payload = os.urandom(size)
            ws.send_frame(payload, opcode=2)
            self.assertEqual(ws.frame(), (2, payload), f"size={size}")

    def test_9_frame_over_the_limit_closes_1009(self):
        ws = self.connect()
        ws.send_frame(b"\x00" * (MIB + 1), opcode=2)
        ws.expect_close(1009)

    def test_9_fragmented_message_over_the_limit_closes_1009(self):
        ws = self.connect()
        ws.send_frame(b"\x00" * MIB, opcode=2, final=False)
        ws.send_frame(b"\x00", opcode=0, final=True)
        ws.expect_close(1009)


if __name__ == "__main__":
    unittest.main()
