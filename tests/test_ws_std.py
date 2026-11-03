"""Integration tests for the StdExt same-port WebSocket API (/ws-echo/socket).

Unlike /chat/ and /chat-ws/, this endpoint runs on the *same* port as the HTTP
server via the StdExt upgrade API (`Std.Http.Server.serveUpgradable` +
`Std.Http.WebSocket.upgrade`), so no endpoint discovery is needed.
Only Python's standard library is used.
"""

import base64
import hashlib
import http.client
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class EchoSocket:
    """Minimal RFC 6455 client for the /ws-echo/socket endpoint."""

    def __init__(self, port, origin=None, path="/ws-echo/socket", initial_bytes=b"",
                 sock=None):
        self.socket = sock or socket.create_connection(("127.0.0.1", port), timeout=5)
        self.socket.settimeout(5)
        key = base64.b64encode(os.urandom(16)).decode()
        headers = [
            f"GET {path} HTTP/1.1", f"Host: 127.0.0.1:{port}",
            "Upgrade: websocket", "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13",
        ]
        if origin is not None:
            headers.append(f"Origin: {origin}")
        self.socket.sendall(("\r\n".join(headers) + "\r\n\r\n").encode() + initial_bytes)
        head = bytearray()
        try:
            while not head.endswith(b"\r\n\r\n"):
                head.extend(self.read(1))
                if len(head) > 16384:
                    raise AssertionError("Oversized handshake")
            expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest())
            if not head.startswith(b"HTTP/1.1 101 ") or expected.lower() not in head.lower():
                raise ConnectionError(f"Upgrade rejected: {head!r}")
        except BaseException:
            self.socket.close()
            raise

    def read(self, size):
        data = bytearray()
        while len(data) < size:
            chunk = self.socket.recv(size - len(data))
            if not chunk:
                raise ConnectionError("WebSocket disconnected")
            data.extend(chunk)
        return bytes(data)

    @staticmethod
    def frame_bytes(data, opcode=1, final=True, masked=True):
        header = bytes([(0x80 if final else 0) | opcode])
        size = len(data)
        mask_bit = 0x80 if masked else 0
        if size < 126:
            header += bytes([mask_bit | size])
        elif size < 65536:
            header += bytes([mask_bit | 126]) + struct.pack("!H", size)
        else:
            header += bytes([mask_bit | 127]) + struct.pack("!Q", size)
        if not masked:
            return header + data
        mask = os.urandom(4)
        return header + mask + bytes(
            value ^ mask[index % 4] for index, value in enumerate(data)
        )

    def send_frame(self, data, opcode=1, final=True, masked=True):
        self.socket.sendall(self.frame_bytes(data, opcode, final, masked))

    def frame(self):
        first, second = self.read(2)
        if second & 0x80:
            raise AssertionError("Server frames must not be masked")
        size = second & 0x7F
        if size == 126:
            size = struct.unpack("!H", self.read(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", self.read(8))[0]
        return first & 0x0F, self.read(size)

    def expect_close(self, code):
        opcode, payload = self.frame()
        if opcode != 8:
            raise AssertionError(f"Expected close frame, got opcode {opcode}: {payload!r}")
        if len(payload) < 2:
            raise AssertionError(f"Close frame without code: {payload!r}")
        received = struct.unpack("!H", payload[:2])[0]
        if received != code:
            raise AssertionError(f"Expected close code {code}, got {received}")

    def expect_eof(self):
        try:
            data = self.socket.recv(1)
        except OSError:
            return
        if data:
            raise AssertionError(f"Expected EOF, got {data!r}")

    def close(self):
        self.socket.close()


class StdWsEchoTests(unittest.TestCase):
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
        cls.origin = f"http://127.0.0.1:{cls.http_port}"
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if cls.process.poll() is not None:
                    raise RuntimeError("Server exited during startup")
                try:
                    status, _, _ = cls.request("/health")
                    if status == 200:
                        break
                except (OSError, http.client.HTTPException):
                    pass
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

    @classmethod
    def request(cls, path, method="GET", headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", cls.http_port, timeout=30)
        try:
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            lowered = {name.lower(): value for name, value in response.getheaders()}
            return response.status, lowered, response.read()
        finally:
            connection.close()

    def connect(self, **kwargs):
        ws = EchoSocket(self.http_port, **kwargs)
        self.addCleanup(ws.close)
        return ws

    # --- Happy path -------------------------------------------------------

    def test_text_echo(self):
        ws = self.connect(origin=self.origin)
        message = "こんにちは WebSocket".encode()
        ws.send_frame(message)
        self.assertEqual(ws.frame(), (1, message))

    def test_binary_echo_extended_lengths(self):
        ws = self.connect()
        for size in (0, 125, 126, 65535, 70000):
            payload = os.urandom(size)
            ws.send_frame(payload, opcode=2)
            self.assertEqual(ws.frame(), (2, payload), f"size={size}")

    def test_fragmented_message_reassembled(self):
        ws = self.connect()
        ws.send_frame(b"Hello, ", opcode=1, final=False)
        ws.send_frame(b"fragmented ", opcode=0, final=False)
        ws.send_frame(b"world", opcode=0, final=True)
        self.assertEqual(ws.frame(), (1, b"Hello, fragmented world"))

    def test_control_frame_between_fragments(self):
        ws = self.connect()
        ws.send_frame(b"first ", opcode=1, final=False)
        ws.send_frame(b"probe", opcode=9)  # ping
        self.assertEqual(ws.frame(), (10, b"probe"))
        ws.send_frame(b"second", opcode=0, final=True)
        self.assertEqual(ws.frame(), (1, b"first second"))

    def test_ping_pong(self):
        ws = self.connect()
        ws.send_frame(b"liveness", opcode=9)
        self.assertEqual(ws.frame(), (10, b"liveness"))

    def test_unsolicited_pong_ignored(self):
        ws = self.connect()
        ws.send_frame(b"spontaneous", opcode=10)
        ws.send_frame(b"still echoing")
        self.assertEqual(ws.frame(), (1, b"still echoing"))

    def test_close_handshake_echoes_code(self):
        ws = self.connect()
        ws.send_frame(struct.pack("!H", 3001) + b"done", opcode=8)
        ws.expect_close(3001)
        ws.expect_eof()

    def test_preread_bytes_survive_handoff(self):
        # Frames that ride in the same packets as the handshake must reach the
        # continuation through the preread buffer.
        early = EchoSocket.frame_bytes("early \u00e9cho".encode())
        ws = self.connect(initial_bytes=early)
        self.assertEqual(ws.frame(), (1, "early \u00e9cho".encode()))

    def test_upgrade_after_keep_alive_request(self):
        # The upgrade may arrive as a later request on a keep-alive connection.
        sock = socket.create_connection(("127.0.0.1", self.http_port), timeout=5)
        sock.settimeout(5)
        try:
            sock.sendall(
                f"GET /health HTTP/1.1\r\nHost: 127.0.0.1:{self.http_port}\r\n\r\n".encode())
            head = bytearray()
            while b"\r\n\r\n" not in head:
                head.extend(sock.recv(1))
            headers = head.decode().lower()
            self.assertIn("content-length:", headers)
            length = int(headers.split("content-length:")[1].splitlines()[0])
            body = bytearray()
            while len(body) < length:
                body.extend(sock.recv(length - len(body)))
            ws = EchoSocket(self.http_port, sock=sock)
            ws.send_frame(b"after keep-alive")
            self.assertEqual(ws.frame(), (1, b"after keep-alive"))
        finally:
            sock.close()

    def test_concurrent_connections(self):
        sockets = [self.connect() for _ in range(4)]
        for index, ws in enumerate(sockets):
            ws.send_frame(f"client {index}".encode())
        for index, ws in enumerate(sockets):
            self.assertEqual(ws.frame(), (1, f"client {index}".encode()))

    def test_http_still_served_on_same_port(self):
        status, _, body = self.request("/health")
        self.assertEqual(status, 200)
        self.assertTrue(body)

    # --- Handshake rejections --------------------------------------------

    def test_rejected_handshake_keeps_http_connection_usable(self):
        status, _, body = self.request("/ws-echo/socket")
        self.assertEqual(status, 400)
        self.assertIn(b"Upgrade", body)

    def test_post_is_rejected(self):
        status, headers, _ = self.request("/ws-echo/socket", method="POST", headers={
            "Upgrade": "websocket", "Connection": "Upgrade",
            "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version": "13"})
        self.assertEqual(status, 405)
        self.assertEqual(headers.get("allow"), "GET")

    def test_wrong_version_asks_for_13(self):
        status, headers, _ = self.request("/ws-echo/socket", headers={
            "Upgrade": "websocket", "Connection": "Upgrade",
            "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version": "8"})
        self.assertEqual(status, 426)
        self.assertEqual(headers.get("sec-websocket-version"), "13")

    def test_invalid_key_rejected(self):
        status, _, _ = self.request("/ws-echo/socket", headers={
            "Upgrade": "websocket", "Connection": "Upgrade",
            "Sec-WebSocket-Key": "too-short",
            "Sec-WebSocket-Version": "13"})
        self.assertEqual(status, 400)

    def test_foreign_origin_rejected(self):
        status, _, _ = self.request("/ws-echo/socket", headers={
            "Upgrade": "websocket", "Connection": "Upgrade",
            "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version": "13",
            "Origin": "http://evil.example"})
        self.assertEqual(status, 403)

    def test_same_origin_accepted(self):
        ws = self.connect(origin=self.origin)
        ws.send_frame(b"origin ok")
        self.assertEqual(ws.frame(), (1, b"origin ok"))

    # --- Protocol violations after the upgrade ----------------------------

    def test_unmasked_client_frame_closes_1002(self):
        ws = self.connect()
        ws.send_frame(b"unmasked", masked=False)
        ws.expect_close(1002)
        ws.expect_eof()

    def test_invalid_utf8_text_closes_1007(self):
        ws = self.connect()
        ws.send_frame(b"\xff\xfe\xfd", opcode=1)
        ws.expect_close(1007)
        ws.expect_eof()

    def test_oversized_control_frame_closes_1002(self):
        ws = self.connect()
        ws.send_frame(b"x" * 126, opcode=9)
        ws.expect_close(1002)
        ws.expect_eof()

    def test_fragmented_control_frame_closes_1002(self):
        ws = self.connect()
        ws.send_frame(b"", opcode=9, final=False)
        ws.expect_close(1002)
        ws.expect_eof()

    def test_unexpected_continuation_closes_1002(self):
        ws = self.connect()
        ws.send_frame(b"stray", opcode=0, final=True)
        ws.expect_close(1002)
        ws.expect_eof()

    def test_reserved_close_code_closes_1002(self):
        ws = self.connect()
        ws.send_frame(struct.pack("!H", 1005), opcode=8)
        ws.expect_close(1002)
        ws.expect_eof()

    def test_abrupt_disconnect_is_tolerated(self):
        ws = self.connect()
        ws.send_frame(b"going away")
        self.assertEqual(ws.frame(), (1, b"going away"))
        ws.close()
        # The server must keep serving afterwards.
        status, _, _ = self.request("/health")
        self.assertEqual(status, 200)


if __name__ == "__main__":
    unittest.main()
