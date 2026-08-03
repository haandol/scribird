"""AWS Signature Version 4 — presigned WebSocket URL과 청크별 롤링 서명.

Transcribe 스트리밍의 서명은 두 단계다.

1. **presigned URL** — WebSocket 업그레이드 요청을 쿼리스트링으로 서명한다. 여기서
   나온 서명이 이후 롤링 서명의 시작점(seed)이 된다.
2. **청크별 서명** — 오디오 프레임마다 직전 서명을 입력으로 새 서명을 만든다.
   그래서 프레임 하나를 건너뛰거나 순서를 바꾸면 그 다음부터 전부 깨진다.

두 단계가 같은 서명 키를 쓰지만 canonical request의 모양이 다르다. 이 파일은 그
차이만 담고, 프레이밍은 `eventstream`이 맡는다.

stdlib(`hmac`, `hashlib`)만 쓴다.
"""

from __future__ import annotations

import hashlib
import hmac
import urllib.parse
from dataclasses import dataclass

ALGORITHM = "AWS4-HMAC-SHA256"
SERVICE = "transcribe"

# 빈 문자열의 SHA256. 여러 곳에서 payload 해시로 쓰인다.
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


@dataclass(frozen=True)
class Credentials:
    """자격 증명 한 벌.

    `session_token`은 임시 자격 증명(SSO·assume-role)에서만 온다. 있으면
    `X-Amz-Security-Token`으로 함께 보내야 하고, 빼면 인증이 거부된다.
    """

    access_key: str
    secret_key: str
    session_token: str | None = None


def _sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def signing_key(secret_key: str, date_stamp: str, region: str) -> bytes:
    """날짜·리전·서비스로 좁힌 서명 키.

    이 키를 유도해 두면 청크마다 다시 만들 필요가 없다. 날짜가 넘어가면 무효해지지만,
    한 스트리밍 세션이 자정을 넘겨 실패하는 경우는 세션을 다시 열면 해결된다 —
    세션 중 키를 갱신하려면 롤링 서명의 seed까지 다시 잡아야 해서 더 복잡하다.
    """
    key = _sign(f"AWS4{secret_key}".encode("utf-8"), date_stamp)
    key = _sign(key, region)
    key = _sign(key, SERVICE)
    return _sign(key, "aws4_request")


def credential_scope(date_stamp: str, region: str) -> str:
    return f"{date_stamp}/{region}/{SERVICE}/aws4_request"


def presign_websocket_url(
    *,
    host: str,
    path: str,
    region: str,
    credentials: Credentials,
    query: dict[str, str],
    amz_date: str,
    expires: int = 300,
) -> tuple[str, str]:
    """WebSocket 업그레이드용 presigned URL을 만든다.

    - Parameter host: 연결할 호스트. 포트를 붙여도 된다 (`...:8443`).
    - Parameter amz_date: `YYYYMMDDTHHMMSSZ`. 인자로 받는 이유는 테스트가 알려진
      값을 그대로 넣어 검증할 수 있어야 하기 때문이다.
    - Returns: (URL, seed 서명). seed는 첫 청크 서명의 입력이다.

    쿼리 파라미터는 **정렬해서** canonical request에 넣는다. 정렬을 빼먹으면
    서버가 계산한 서명과 달라진다.

    **서명하는 `host` 헤더에서 포트를 뺀다.** Transcribe 스트리밍은 8443 포트로
    접속하지만, 서버는 포트 없는 호스트명으로 서명을 계산한다. 실측: 포트를 넣어
    서명하면 `InvalidSignatureException`이 오고, 그 메시지에 서버가 기대한
    canonical string이 담겨 오는데 그 `host:` 행이
    `transcribestreaming.us-east-1.amazonaws.com`(포트 없음)이었다. 접속은 포트로
    하고 서명은 포트 없이 해야 한다 — 둘이 갈린다는 것이 이 함수의 요점이다.
    """
    date_stamp = amz_date[:8]
    # 접속용 host는 그대로 두고, 서명용으로만 포트를 떼어낸다.
    signed_host = host.rsplit(":", 1)[0] if ":" in host else host
    scope = credential_scope(date_stamp, region)

    params = {
        "X-Amz-Algorithm": ALGORITHM,
        "X-Amz-Credential": f"{credentials.access_key}/{scope}",
        "X-Amz-Date": amz_date,
        "X-Amz-Expires": str(expires),
        "X-Amz-SignedHeaders": "host",
        **query,
    }
    if credentials.session_token:
        params["X-Amz-Security-Token"] = credentials.session_token

    canonical_query = "&".join(
        f"{urllib.parse.quote(k, safe='-_.~')}={urllib.parse.quote(str(v), safe='-_.~')}"
        for k, v in sorted(params.items())
    )
    canonical_request = "\n".join(
        ["GET", path, canonical_query, f"host:{signed_host}\n", "host", EMPTY_SHA256]
    )
    string_to_sign = "\n".join(
        [
            ALGORITHM,
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(
        signing_key(credentials.secret_key, date_stamp, region),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()

    url = f"wss://{host}{path}?{canonical_query}&X-Amz-Signature={signature}"
    return url, signature


def sign_chunk(
    *,
    previous_signature: str,
    header_block: bytes,
    payload: bytes,
    region: str,
    secret_key: str,
    amz_date: str,
) -> str:
    """오디오 프레임 하나의 서명.

    `previous_signature`가 체인을 만든다 — 첫 프레임은 presign에서 받은 seed를,
    이후는 직전 프레임의 서명을 넣는다. 이 값을 잘못 넘기면 그 프레임부터 전부
    거부되므로, 호출하는 쪽은 반환값을 반드시 다음 호출에 물려야 한다.

    string_to_sign의 마지막 두 줄이 presign과 다르다: 이벤트 스트림은 "직전 서명"과
    "빈 헤더 해시"를 끼워 넣는다. 그래서 presign 로직을 재사용할 수 없다.
    """
    date_stamp = amz_date[:8]
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256-PAYLOAD",
            amz_date,
            credential_scope(date_stamp, region),
            previous_signature,
            hashlib.sha256(header_block).hexdigest(),
            hashlib.sha256(payload).hexdigest(),
        ]
    )
    return hmac.new(
        signing_key(secret_key, date_stamp, region),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
