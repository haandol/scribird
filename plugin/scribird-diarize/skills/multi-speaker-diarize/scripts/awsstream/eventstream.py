"""AWS 이벤트 스트림 바이너리 프레이밍.

Transcribe 스트리밍은 WebSocket 위에 이 프레이밍을 한 겹 더 쓴다. 오디오를 보낼
때도 결과를 받을 때도 이 형식이므로, 인코더와 디코더가 모두 필요하다.

메시지 하나의 구조 (모든 정수는 big-endian):

```
+--------------------+  4B  전체 길이 (prelude + headers + payload + 끝 CRC)
+--------------------+  4B  헤더부 길이
+--------------------+  4B  prelude CRC (위 8바이트에 대한 CRC32)
| 헤더들             |      각 헤더: 이름길이(1B) 이름 타입(1B) 값...
+--------------------+
| 페이로드           |
+--------------------+  4B  메시지 CRC (끝 4바이트를 제외한 전체에 대한 CRC32)
```

CRC는 CRC32(zlib)다. AWS 문서가 "CRC32"라고만 적어 혼동하기 쉬운데, 이벤트 스트림은
표준 CRC32를 쓴다 — S3 체크섬의 CRC32C(Castagnoli)와 다르다. 다항식이 다르므로
잘못 쓰면 서버가 조용히 프레임을 버린다.

의존성 없이 stdlib만 쓴다.
"""

from __future__ import annotations

import struct
import zlib

# 헤더 값 타입. Transcribe가 쓰는 것은 문자열(7)뿐이지만, 응답에는 다른 타입이
# 섞여 올 수 있어 디코더는 전부 다룬다.
_TYPE_BOOL_TRUE = 0
_TYPE_BOOL_FALSE = 1
_TYPE_BYTE = 2
_TYPE_SHORT = 3
_TYPE_INT = 4
_TYPE_LONG = 5
_TYPE_BYTES = 6
_TYPE_STRING = 7
_TYPE_TIMESTAMP = 8
_TYPE_UUID = 9

PRELUDE_LENGTH = 12
"""전체 길이(4) + 헤더부 길이(4) + prelude CRC(4)."""

_MIN_MESSAGE_LENGTH = PRELUDE_LENGTH + 4
"""prelude에 끝 CRC(4)만 붙은 빈 메시지."""


class EventStreamError(ValueError):
    """프레임이 깨졌을 때. CRC 불일치와 길이 모순을 모두 담는다."""


def encode_headers(headers: dict[str, str]) -> bytes:
    """문자열 헤더만 인코딩한다.

    Transcribe로 **보내는** 메시지의 헤더는 모두 문자열이다(`:message-type`,
    `:event-type`, `:content-type`, `:chunk-signature`는 예외로 bytes지만
    서명 헤더는 따로 다룬다). 그래서 인코더는 문자열만 지원한다 — 쓰지 않는
    타입을 구현해 두면 검증되지 않은 코드가 남는다.
    """
    out = bytearray()
    for name, value in headers.items():
        name_bytes = name.encode("utf-8")
        value_bytes = value.encode("utf-8")
        out += struct.pack("!B", len(name_bytes))
        out += name_bytes
        out += struct.pack("!B", _TYPE_STRING)
        out += struct.pack("!H", len(value_bytes))
        out += value_bytes
    return bytes(out)


def encode_binary_header(name: str, value: bytes) -> bytes:
    """bytes 값을 갖는 헤더 하나.

    `:chunk-signature`가 이 타입이다. 서명은 32바이트 raw이고, 이걸 hex 문자열로
    보내면 서버가 서명 불일치로 끊는다.
    """
    name_bytes = name.encode("utf-8")
    return (
        struct.pack("!B", len(name_bytes))
        + name_bytes
        + struct.pack("!B", _TYPE_BYTES)
        + struct.pack("!H", len(value))
        + value
    )


def encode_message(header_block: bytes, payload: bytes) -> bytes:
    """헤더부와 페이로드를 완전한 메시지로 감싼다.

    헤더를 dict가 아니라 이미 인코딩된 바이트로 받는 이유는, 서명 헤더가 bytes
    타입이라 문자열 헤더와 섞어야 하기 때문이다. 호출하는 쪽이 순서를 정한다 —
    서명 계산이 헤더 바이트열에 의존하므로 순서가 바뀌면 서명이 달라진다.
    """
    total_length = PRELUDE_LENGTH + len(header_block) + len(payload) + 4
    prelude = struct.pack("!II", total_length, len(header_block))
    prelude += struct.pack("!I", zlib.crc32(prelude) & 0xFFFFFFFF)

    body = prelude + header_block + payload
    return body + struct.pack("!I", zlib.crc32(body) & 0xFFFFFFFF)


def decode_message(data: bytes) -> tuple[dict[str, object], bytes, int]:
    """메시지 하나를 푼다.

    - Returns: (헤더, 페이로드, 소비한 바이트 수).

    소비한 바이트 수를 함께 돌려주는 이유는 WebSocket 프레임 하나에 이벤트 스트림
    메시지가 여러 개 들어올 수 있기 때문이다. 첫 메시지만 읽고 버리면 결과가 조용히
    사라진다.

    CRC를 검사한다. 깨진 프레임을 그대로 파싱하면 길이 필드가 엉뚱한 값이 되어
    메모리를 크게 잡거나 무한 루프에 빠진다.
    """
    if len(data) < _MIN_MESSAGE_LENGTH:
        raise EventStreamError(f"메시지가 너무 짧습니다: {len(data)}바이트")

    total_length, header_length = struct.unpack("!II", data[:8])
    (prelude_crc,) = struct.unpack("!I", data[8:12])
    if zlib.crc32(data[:8]) & 0xFFFFFFFF != prelude_crc:
        raise EventStreamError("prelude CRC가 맞지 않습니다")

    if total_length < _MIN_MESSAGE_LENGTH or total_length > len(data):
        raise EventStreamError(
            f"길이가 모순입니다: 선언 {total_length}, 남은 {len(data)}"
        )

    message = data[:total_length]
    (message_crc,) = struct.unpack("!I", message[-4:])
    if zlib.crc32(message[:-4]) & 0xFFFFFFFF != message_crc:
        raise EventStreamError("메시지 CRC가 맞지 않습니다")

    headers = _decode_headers(message[PRELUDE_LENGTH : PRELUDE_LENGTH + header_length])
    payload = message[PRELUDE_LENGTH + header_length : total_length - 4]
    return headers, payload, total_length


def decode_all(data: bytes) -> list[tuple[dict[str, object], bytes]]:
    """버퍼에 담긴 완전한 메시지를 모두 푼다.

    끝에 남은 불완전한 조각은 무시한다 — 호출하는 쪽이 더 받아서 다시 부른다.
    """
    messages: list[tuple[dict[str, object], bytes]] = []
    offset = 0
    while offset < len(data):
        try:
            headers, payload, consumed = decode_message(data[offset:])
        except EventStreamError:
            # 조각이 덜 왔거나 깨졌다. 여기서 멈추고 이미 푼 것만 돌려준다.
            break
        messages.append((headers, payload))
        offset += consumed
    return messages


def _decode_headers(block: bytes) -> dict[str, object]:
    headers: dict[str, object] = {}
    offset = 0
    while offset < len(block):
        name_length = block[offset]
        offset += 1
        name = block[offset : offset + name_length].decode("utf-8")
        offset += name_length
        value_type = block[offset]
        offset += 1

        if value_type in (_TYPE_BOOL_TRUE, _TYPE_BOOL_FALSE):
            headers[name] = value_type == _TYPE_BOOL_TRUE
        elif value_type == _TYPE_BYTE:
            headers[name] = struct.unpack("!b", block[offset : offset + 1])[0]
            offset += 1
        elif value_type == _TYPE_SHORT:
            headers[name] = struct.unpack("!h", block[offset : offset + 2])[0]
            offset += 2
        elif value_type == _TYPE_INT:
            headers[name] = struct.unpack("!i", block[offset : offset + 4])[0]
            offset += 4
        elif value_type in (_TYPE_LONG, _TYPE_TIMESTAMP):
            headers[name] = struct.unpack("!q", block[offset : offset + 8])[0]
            offset += 8
        elif value_type in (_TYPE_BYTES, _TYPE_STRING):
            (length,) = struct.unpack("!H", block[offset : offset + 2])
            offset += 2
            raw = block[offset : offset + length]
            offset += length
            headers[name] = raw.decode("utf-8") if value_type == _TYPE_STRING else raw
        elif value_type == _TYPE_UUID:
            headers[name] = block[offset : offset + 16]
            offset += 16
        else:
            raise EventStreamError(f"알 수 없는 헤더 타입 {value_type} ({name})")
    return headers
