"""최소 WebSocket 클라이언트 (RFC 6455).

`websockets`나 `websocket-client`를 쓰지 않는 이유는 이 스킬이 추가 설치를 요구하지
않아야 하기 때문이다. macOS 기본 `/usr/bin/python3`으로 그냥 돌아가는 것이 목적이라,
필요한 만큼만 직접 짠다.

**구현하지 않는 것**과 그 근거:

- 확장(permessage-deflate) — Transcribe가 요구하지 않고, 오디오는 이미 압축돼 있거나
  PCM이라 협상해도 이득이 없다.
- 프래그먼트 재조립 — 서버가 보내는 이벤트 스트림 메시지는 단일 프레임으로 온다.
  다만 조각이 왔을 때 조용히 버리면 결과가 사라지므로, continuation 프레임은 명시적으로
  이어 붙인다.
- 자동 재연결 — 스트리밍 세션은 롤링 서명 체인에 묶여 있어서, 끊기면 처음부터
  다시 열어야 한다. 중간부터 이어붙이는 재연결은 존재할 수 없다.

서버→클라이언트 프레임은 마스킹하지 않고, 클라이언트→서버는 **반드시** 마스킹한다.
마스킹을 빼면 서버가 프로토콜 오류로 끊는다.
"""

from __future__ import annotations

import base64
import hashlib
import os
import socket
import ssl
import struct
import urllib.parse

# RFC 6455가 정한 상수. Sec-WebSocket-Accept 계산에만 쓰인다.
_HANDSHAKE_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

OPCODE_CONTINUATION = 0x0
OPCODE_TEXT = 0x1
OPCODE_BINARY = 0x2
OPCODE_CLOSE = 0x8
OPCODE_PING = 0x9
OPCODE_PONG = 0xA


class WebSocketError(RuntimeError):
    """핸드셰이크 실패나 프로토콜 위반."""


class WebSocket:
    """하나의 WebSocket 연결. `with`으로 쓰면 닫힘이 보장된다."""

    def __init__(self, url: str, timeout: float = 30.0) -> None:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "wss":
            # ws://를 허용하지 않는다. 회의 오디오를 평문으로 보내는 실수를
            # 코드 수준에서 막는다.
            raise WebSocketError(f"wss만 지원합니다: {parsed.scheme}")

        host = parsed.hostname or ""
        port = parsed.port or 443
        path = parsed.path or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"

        raw = socket.create_connection((host, port), timeout=timeout)
        context = ssl.create_default_context()
        self._socket = context.wrap_socket(raw, server_hostname=host)
        self._buffer = bytearray()
        self._closed = False
        self._handshake(host, path)

    def _handshake(self, host: str, path: str) -> None:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self._socket.sendall(request.encode("ascii"))

        # 헤더 끝까지 읽는다. 응답 바디(에러 메시지)가 같은 read에 섞여 올 수 있으므로
        # 남은 바이트는 버퍼에 남겨 둔다.
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = self._socket.recv(4096)
            if not chunk:
                raise WebSocketError("핸드셰이크 중 연결이 끊겼습니다")
            response += chunk

        header_end = response.index(b"\r\n\r\n") + 4
        head = response[:header_end].decode("latin-1")
        self._buffer += response[header_end:]

        status_line = head.split("\r\n", 1)[0]
        if "101" not in status_line:
            # 403이면 서명 문제다. 바디에 이유가 담겨 오므로 함께 보여준다 —
            # "403"만 알려주면 서명·권한·리전 중 무엇인지 알 수 없다.
            body = bytes(self._buffer[:512]).decode("utf-8", "replace").strip()
            raise WebSocketError(
                f"업그레이드가 거부됐습니다: {status_line}"
                + (f"\n{body}" if body else "")
            )

        expected = base64.b64encode(
            hashlib.sha1((key + _HANDSHAKE_GUID).encode("ascii")).digest()
        ).decode("ascii")
        for line in head.split("\r\n"):
            if line.lower().startswith("sec-websocket-accept:"):
                if line.split(":", 1)[1].strip() != expected:
                    raise WebSocketError("Sec-WebSocket-Accept가 맞지 않습니다")
                break
        else:
            raise WebSocketError("응답에 Sec-WebSocket-Accept가 없습니다")

    def send_binary(self, payload: bytes) -> None:
        self._send_frame(OPCODE_BINARY, payload)

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self._closed:
            raise WebSocketError("이미 닫힌 연결에 쓰려고 했습니다")

        frame = bytearray([0x80 | opcode])  # FIN=1
        length = len(payload)
        # 클라이언트 프레임은 마스킹이 필수라 길이 바이트에 0x80을 세운다.
        if length < 126:
            frame.append(0x80 | length)
        elif length < 65536:
            frame.append(0x80 | 126)
            frame += struct.pack("!H", length)
        else:
            frame.append(0x80 | 127)
            frame += struct.pack("!Q", length)

        mask = os.urandom(4)
        frame += mask
        frame += bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
        self._socket.sendall(bytes(frame))

    def receive(self) -> tuple[int, bytes] | None:
        """다음 메시지 하나. 연결이 정상 종료되면 None.

        - Returns: (opcode, payload). ping은 여기서 pong으로 자동 응답하고
          다음 메시지를 계속 기다린다 — 호출하는 쪽이 프로토콜 유지 책임을
          지지 않게 한다.

        프래그먼트는 이어 붙인다. Transcribe가 단일 프레임으로 보내더라도,
        조각이 왔을 때 첫 조각만 반환하면 결과가 잘린 JSON이 되어 파싱 오류로
        나타난다 — 원인을 찾기 어려운 실패다.
        """
        fragments = bytearray()
        fragment_opcode: int | None = None

        while True:
            frame = self._read_frame()
            if frame is None:
                return None
            fin, opcode, payload = frame

            if opcode == OPCODE_CLOSE:
                self._closed = True
                return None
            if opcode == OPCODE_PING:
                self._send_frame(OPCODE_PONG, payload)
                continue
            if opcode == OPCODE_PONG:
                continue

            if opcode == OPCODE_CONTINUATION:
                if fragment_opcode is None:
                    raise WebSocketError("시작 프레임 없이 continuation이 왔습니다")
                fragments += payload
            else:
                fragment_opcode = opcode
                fragments = bytearray(payload)

            if fin:
                return fragment_opcode, bytes(fragments)

    def _read_frame(self) -> tuple[bool, int, bytes] | None:
        header = self._read_exactly(2)
        if header is None:
            return None
        fin = bool(header[0] & 0x80)
        opcode = header[0] & 0x0F
        masked = bool(header[1] & 0x80)
        length = header[1] & 0x7F

        if length == 126:
            extended = self._read_exactly(2)
            if extended is None:
                return None
            (length,) = struct.unpack("!H", extended)
        elif length == 127:
            extended = self._read_exactly(8)
            if extended is None:
                return None
            (length,) = struct.unpack("!Q", extended)

        # 서버는 마스킹하지 않는다. 마스킹된 프레임이 오면 프로토콜 위반이지만,
        # 키를 읽지 않고 넘어가면 이후 프레임 경계가 전부 밀리므로 읽어서 푼다.
        mask = self._read_exactly(4) if masked else None
        payload = self._read_exactly(length) if length else b""
        if payload is None:
            return None
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload

    def _read_exactly(self, count: int) -> bytes | None:
        """정확히 count 바이트. 연결이 끊기면 None.

        TCP는 요청한 만큼을 한 번에 주지 않는다. `recv(n)`을 한 번 부르고 끝내면
        큰 프레임에서 조용히 잘린다.
        """
        while len(self._buffer) < count:
            chunk = self._socket.recv(65536)
            if not chunk:
                return None
            self._buffer += chunk
        out = bytes(self._buffer[:count])
        del self._buffer[:count]
        return out

    def close(self) -> None:
        if not self._closed:
            try:
                self._send_frame(OPCODE_CLOSE, struct.pack("!H", 1000))
            except (OSError, WebSocketError):
                # 이미 서버가 끊었을 수 있다. 닫는 중의 오류로 결과를 잃지 않는다.
                pass
            self._closed = True
        try:
            self._socket.close()
        except OSError:
            pass

    def __enter__(self) -> WebSocket:
        return self

    def __exit__(self, *args: object) -> None:
        self.close()
