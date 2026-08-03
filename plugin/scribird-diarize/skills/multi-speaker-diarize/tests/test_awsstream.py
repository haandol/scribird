#!/usr/bin/env python3
"""이벤트 스트림 프레이밍과 SigV4 서명 테스트.

네트워크를 쓰지 않는다. 이 두 계층은 순수 함수라 알려진 값과 왕복으로 검증할 수 있고,
실제 AWS 호출은 서명이 맞을 때만 진행되므로 여기서 틀리면 그 뒤가 전부 막힌다.

인코딩하는 실패:

1. 서명하는 `host`에 포트를 넣으면 `InvalidSignatureException` (실측).
2. 쿼리를 정렬하지 않으면 서명이 달라진다.
3. CRC를 검사하지 않으면 깨진 프레임이 엉뚱한 길이로 파싱된다.
4. WebSocket 프레임 하나에 이벤트 스트림 메시지가 여럿 오는데 첫 개만 읽으면
   결과가 사라진다.
5. 롤링 서명 체인이 끊기면 그 뒤 프레임이 전부 거부된다.
"""

from __future__ import annotations

import hashlib
import hmac
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from awsstream import eventstream as es  # noqa: E402
from awsstream import sigv4  # noqa: E402

# AWS SigV4 문서의 예시 자격 증명. 실제로 쓰이지 않는 공개 테스트 값이다.
EXAMPLE_SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
EXAMPLE_KEY = "AKIDEXAMPLE"
FIXED_DATE = "20150830T123600Z"

STREAM_QUERY = {
    "language-code": "en-US",
    "media-encoding": "pcm",
    "sample-rate": "16000",
    "show-speaker-label": "true",
}


class EventStreamTests(unittest.TestCase):
    def test_roundtrip_preserves_headers_and_payload(self) -> None:
        header_block = es.encode_headers(
            {":message-type": "event", ":event-type": "AudioEvent"}
        )
        header_block += es.encode_binary_header(":chunk-signature", bytes(range(32)))
        message = es.encode_message(header_block, b"PCMDATA")

        headers, payload, consumed = es.decode_message(message)
        self.assertEqual(consumed, len(message))
        self.assertEqual(payload, b"PCMDATA")
        self.assertEqual(headers[":event-type"], "AudioEvent")

    def test_signature_header_stays_raw_bytes(self) -> None:
        """`:chunk-signature`는 bytes 타입이다.

        hex 문자열로 보내면 서버가 서명 불일치로 끊는다. 문자열 헤더(타입 7)와
        bytes 헤더(타입 6)는 인코딩이 달라서, 같은 함수로 처리하면 이 실패가 난다.
        """
        raw = bytes.fromhex("ab" * 32)
        block = es.encode_binary_header(":chunk-signature", raw)
        headers, _, _ = es.decode_message(es.encode_message(block, b""))
        self.assertEqual(headers[":chunk-signature"], raw)
        self.assertNotIsInstance(headers[":chunk-signature"], str)

    def test_multiple_messages_in_one_buffer_are_all_decoded(self) -> None:
        """한 WebSocket 프레임에 여러 이벤트가 올 수 있다.

        첫 메시지만 읽고 버리면 전사 결과가 조용히 사라진다 — 결과가 적게 나오는
        방식으로 실패하므로 알아채기 어렵다.
        """
        first = es.encode_message(es.encode_headers({":event-type": "A"}), b"1")
        second = es.encode_message(es.encode_headers({":event-type": "B"}), b"2")

        decoded = es.decode_all(first + second)
        self.assertEqual([h[":event-type"] for h, _ in decoded], ["A", "B"])

    def test_corrupted_crc_is_rejected(self) -> None:
        """CRC를 검사하지 않으면 길이 필드가 엉뚱한 값으로 읽힌다."""
        message = bytearray(
            es.encode_message(es.encode_headers({":event-type": "A"}), b"x")
        )
        message[-1] ^= 0xFF
        with self.assertRaises(es.EventStreamError):
            es.decode_message(bytes(message))

    def test_corrupted_prelude_is_rejected_before_length_is_trusted(self) -> None:
        message = bytearray(es.encode_message(b"", b""))
        message[0] = 0xFF  # 전체 길이를 크게 조작
        with self.assertRaises(es.EventStreamError):
            es.decode_message(bytes(message))

    def test_partial_buffer_yields_nothing_rather_than_garbage(self) -> None:
        """조각이 덜 오면 빈 리스트다.

        TCP는 프레임 경계를 지켜주지 않으므로 반쪽 메시지가 정상적으로 발생한다.
        그때 예외를 던지면 정상 흐름이 실패로 보이고, 억지로 파싱하면 쓰레기가 나온다.
        """
        message = es.encode_message(es.encode_headers({":event-type": "A"}), b"payload")
        self.assertEqual(es.decode_all(message[: len(message) // 2]), [])

    def test_empty_payload_frame_is_valid(self) -> None:
        """빈 페이로드가 스트림의 끝을 알린다 — 유효한 메시지여야 한다."""
        headers, payload, _ = es.decode_message(
            es.encode_message(es.encode_headers({":event-type": "AudioEvent"}), b"")
        )
        self.assertEqual(payload, b"")
        self.assertEqual(headers[":event-type"], "AudioEvent")


class SigV4Tests(unittest.TestCase):
    def credentials(self, token: str | None = None) -> sigv4.Credentials:
        return sigv4.Credentials(EXAMPLE_KEY, EXAMPLE_SECRET, token)

    def presign(self, host: str) -> tuple[str, str]:
        return sigv4.presign_websocket_url(
            host=host,
            path="/stream-transcription-websocket",
            region="us-east-1",
            credentials=self.credentials(),
            query=STREAM_QUERY,
            amz_date=FIXED_DATE,
        )

    def test_signing_key_derivation_matches_spec(self) -> None:
        """네 단계 HMAC 유도가 SigV4 명세와 같다."""

        def step(key: bytes, message: str) -> bytes:
            return hmac.new(key, message.encode(), hashlib.sha256).digest()

        expected = step(
            step(
                step(step(f"AWS4{EXAMPLE_SECRET}".encode(), "20150830"), "us-east-1"),
                "transcribe",
            ),
            "aws4_request",
        )
        self.assertEqual(
            sigv4.signing_key(EXAMPLE_SECRET, "20150830", "us-east-1"), expected
        )

    def test_port_is_excluded_from_the_signed_host(self) -> None:
        """포트를 서명에 넣으면 `InvalidSignatureException`이 온다.

        실측: 8443 포트를 포함해 서명했더니 서버가 거부하면서 자신이 기대한
        canonical string을 알려줬는데, 그 `host:` 행이
        `transcribestreaming.us-east-1.amazonaws.com`으로 **포트가 없었다**.
        접속은 8443으로 하고 서명은 포트 없이 해야 한다.

        이 테스트는 두 host가 같은 서명을 내는지로 확인한다 — 포트가 서명에
        섞여 들어가면 값이 달라진다.
        """
        _, with_port = self.presign("transcribestreaming.us-east-1.amazonaws.com:8443")
        _, without_port = self.presign("transcribestreaming.us-east-1.amazonaws.com")
        self.assertEqual(with_port, without_port)

    def test_connect_url_keeps_the_port(self) -> None:
        """서명에서만 포트를 뺀다 — 접속 URL에는 남아야 한다.

        포트를 URL에서도 지우면 443으로 붙어 연결이 실패한다.
        """
        url, _ = self.presign("transcribestreaming.us-east-1.amazonaws.com:8443")
        self.assertIn(":8443/stream-transcription-websocket", url)

    def test_query_parameters_are_sorted_regardless_of_input_order(self) -> None:
        """정렬하지 않으면 서명이 달라진다.

        서버는 정렬된 canonical query로 계산하므로, 순서가 다르면
        `InvalidSignatureException`이 온다.

        **입력 순서를 뒤집어 넣는 것이 이 테스트의 핵심이다.** `STREAM_QUERY`를
        그대로 쓰면 dict 리터럴 순서가 우연히 정렬돼 있어서, 소스에서 `sorted()`를
        지워도 테스트가 통과한다 — 판별력 확인에서 실제로 그랬다. 역순으로 넣으면
        정렬이 없으면 반드시 갈린다.
        """
        reversed_query = dict(reversed(list(STREAM_QUERY.items())))
        self.assertNotEqual(
            list(reversed_query), sorted(reversed_query)
        )  # 입력이 실제로 정렬되지 않았음을 확인

        url, signature = sigv4.presign_websocket_url(
            host="host.example.com",
            path="/p",
            region="us-east-1",
            credentials=self.credentials(),
            query=reversed_query,
            amz_date=FIXED_DATE,
        )

        # 출력이 정렬돼 있다.
        keys = [
            part.split("=")[0]
            for part in url.split("?", 1)[1].split("&")
            if not part.startswith("X-Amz-Signature=")
        ]
        self.assertEqual(keys, sorted(keys))

        # 입력 순서가 서명을 바꾸지 않는다 — 정렬이 빠지면 이 값이 갈린다.
        _, from_sorted_input = sigv4.presign_websocket_url(
            host="host.example.com",
            path="/p",
            region="us-east-1",
            credentials=self.credentials(),
            query=dict(sorted(STREAM_QUERY.items())),
            amz_date=FIXED_DATE,
        )
        self.assertEqual(signature, from_sorted_input)

    def test_speaker_label_flag_survives_into_the_url(self) -> None:
        """이 플래그가 스킬의 목적이다.

        빠지면 결과에 `Speaker` 필드가 오지 않아 화자 경계를 전혀 얻지 못한다 —
        전사는 성공하는데 분리만 안 되는, 알아채기 늦는 실패다.
        """
        url, _ = self.presign("host.example.com")
        self.assertIn("show-speaker-label=true", url)

    def test_session_token_is_included_when_present(self) -> None:
        """임시 자격 증명(SSO·assume-role)은 토큰이 없으면 거부된다."""
        url, _ = sigv4.presign_websocket_url(
            host="host.example.com",
            path="/p",
            region="us-east-1",
            credentials=self.credentials("TOKEN123"),
            query=STREAM_QUERY,
            amz_date=FIXED_DATE,
        )
        self.assertIn("X-Amz-Security-Token=TOKEN123", url)

    def test_session_token_is_omitted_when_absent(self) -> None:
        url, _ = self.presign("host.example.com")
        self.assertNotIn("X-Amz-Security-Token", url)

    def test_presign_is_deterministic(self) -> None:
        """같은 입력에 같은 서명. 그렇지 않으면 테스트가 무의미해진다."""
        _, first = self.presign("host.example.com")
        _, second = self.presign("host.example.com")
        self.assertEqual(first, second)
        self.assertEqual(len(first), 64)

    def test_chunk_signature_chains_on_the_previous_one(self) -> None:
        """직전 서명이 바뀌면 결과가 바뀐다.

        체인이므로 프레임을 건너뛰거나 순서를 바꾸면 그 뒤 전부가 거부된다.
        이 의존이 없으면 서버가 재생 공격을 막을 수 없다.
        """
        common = dict(
            header_block=b"HEADERS",
            payload=b"AUDIO",
            region="us-east-1",
            secret_key=EXAMPLE_SECRET,
            amz_date=FIXED_DATE,
        )
        first = sigv4.sign_chunk(previous_signature="a" * 64, **common)
        second = sigv4.sign_chunk(previous_signature="b" * 64, **common)
        self.assertNotEqual(first, second)

    def test_chunk_signature_depends_on_payload(self) -> None:
        common = dict(
            previous_signature="a" * 64,
            header_block=b"HEADERS",
            region="us-east-1",
            secret_key=EXAMPLE_SECRET,
            amz_date=FIXED_DATE,
        )
        self.assertNotEqual(
            sigv4.sign_chunk(payload=b"AUDIO", **common),
            sigv4.sign_chunk(payload=b"OTHER", **common),
        )

    def test_chunk_signature_differs_from_presign_string_to_sign(self) -> None:
        """청크 서명은 presign과 다른 string_to_sign을 쓴다.

        이벤트 스트림은 `AWS4-HMAC-SHA256-PAYLOAD`에 직전 서명과 헤더 해시를
        끼워 넣는다. presign 로직을 재사용하면 서버가 계산한 값과 달라진다.
        """
        _, seed = self.presign("host.example.com")
        chunk = sigv4.sign_chunk(
            previous_signature=seed,
            header_block=b"",
            payload=b"",
            region="us-east-1",
            secret_key=EXAMPLE_SECRET,
            amz_date=FIXED_DATE,
        )
        self.assertNotEqual(chunk, seed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
