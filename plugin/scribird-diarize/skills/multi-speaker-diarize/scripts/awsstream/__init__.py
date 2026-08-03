"""AWS Transcribe 스트리밍을 stdlib만으로 부르기 위한 최소 구현.

배치 API가 S3를 요구하기 때문에 존재한다. 배치는 `Media.MediaFileUri`로 `s3://` URI만
받아서, 로컬 파일을 분석하려면 버킷을 만들고 업로드해야 한다. 스트리밍은 오디오를
직접 흘려보내므로 **버킷이 필요 없다** — 회의 오디오가 사용자 계정의 스토리지에
잠시라도 놓이지 않는다.

대가는 직접 구현해야 하는 세 겹이다.

| 겹 | 모듈 | 왜 직접 구현하나 |
|---|---|---|
| WebSocket | `websocket` | stdlib에 클라이언트가 없다 |
| 이벤트 스트림 프레이밍 | `eventstream` | AWS 고유 바이너리 형식 |
| SigV4 롤링 서명 | `sigv4` | 청크마다 직전 서명이 입력 |

`pip install`을 요구하지 않는 것이 이 겹들을 짜는 값이다 — macOS 기본
`/usr/bin/python3`에서 그대로 돈다.
"""

from .eventstream import EventStreamError, decode_all, encode_binary_header, encode_headers, encode_message
from .sigv4 import Credentials, presign_websocket_url, sign_chunk
from .websocket import WebSocket, WebSocketError

__all__ = [
    "Credentials",
    "EventStreamError",
    "WebSocket",
    "WebSocketError",
    "decode_all",
    "encode_binary_header",
    "encode_headers",
    "encode_message",
    "presign_websocket_url",
    "sign_chunk",
]
