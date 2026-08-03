#!/usr/bin/env python3
"""AWS Transcribe 스트리밍으로 화자 분리한다 — S3 버킷을 쓰지 않는다.

배치 API는 `Media.MediaFileUri`로 `s3://` URI만 받아서, 로컬 파일을 분석하려면
버킷을 만들고 업로드해야 한다. 스트리밍은 오디오를 WebSocket으로 직접 흘려보내므로
**회의 오디오가 사용자 계정의 스토리지에 놓이지 않는다.** 정리할 객체도, 지우는 것을
잊어 남는 파일도 없다.

대가는 `awsstream/` 아래 세 겹(WebSocket, 이벤트 스트림 프레이밍, SigV4 롤링 서명)을
직접 구현한 것이다. 그 값으로 `pip install`이 필요 없는 상태를 유지한다.

배치와 다른 점 두 가지는 결과에 영향을 준다.

- **화자 수 상한을 줄 수 없다.** 스트리밍에는 `MaxSpeakerLabels`가 없다. AWS가 알아서
  나누고, 최대 10명까지 구분한다. 배치의 2~30 상한과 달리 조절할 수단이 없다.
- **다국어 식별을 쓸 수 없다.** 스트리밍은 언어를 하나 지정해야 한다. 코드스위칭
  회의라면 지배 언어를 골라야 하고, 그쪽이 아닌 구간은 오인식된다.

그래서 배치(`run_transcribe.py`)를 지우지 않고 남긴다. 어느 쪽을 쓸지는 상황이 정한다.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from awsstream import (  # noqa: E402
    Credentials,
    WebSocket,
    WebSocketError,
    decode_all,
    encode_binary_header,
    encode_headers,
    encode_message,
    presign_websocket_url,
    sign_chunk,
)

# 스트리밍이 요구하는 오디오 형식.
#
# 16kHz 모노 16-bit PCM으로 고정한다. Transcribe는 8k~48kHz를 받지만, 전사 모델이
# 내부적으로 16kHz를 쓰므로 그 이상은 대역폭만 늘린다. 모노인 이유는 채널 분리
# (`ChannelIdentification`)와 화자 분리를 동시에 쓸 수 없기 때문이다 — 우리가 원하는
# 것은 화자 분리다.
SAMPLE_RATE = 16_000
CHANNELS = 1
BYTES_PER_SAMPLE = 2

# 한 프레임에 담을 오디오 길이.
#
# 100ms(3200바이트)로 둔다. AWS 권장은 50~200ms다. 너무 작으면 프레임 하나당
# 이벤트 스트림 헤더(약 100바이트)와 서명 계산이 붙어 오버헤드가 커지고, 너무 크면
# 서버가 결과를 늦게 내놓는다. 파일을 밀어 넣는 용도라 지연은 중요하지 않지만,
# 프레임 수가 곧 서명 계산 횟수라 100ms가 균형점이다.
CHUNK_MILLISECONDS = 100
CHUNK_BYTES = SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE * CHUNK_MILLISECONDS // 1000

# 실시간보다 빠르게 밀어 넣되, 서버가 감당할 만큼만.
#
# 파일 전체를 한 번에 쏟으면 서버가 스로틀링하거나 연결을 끊는다. 실측 없이 안전한
# 쪽을 택해, 오디오 길이의 1/10 속도로 보낸다(2분 오디오 → 약 12초). 완전히 지연 없이
# 보내는 것보다 느리지만, 중간에 끊겨 처음부터 다시 하는 것보다 빠르다.
REALTIME_DIVISOR = 10

# 오디오를 다 보낸 뒤 남은 결과를 기다리는 시간.
#
# 마지막 발화의 확정 결과는 스트림을 닫은 뒤에 온다. 이 시간을 두지 않으면 회의
# 끝부분이 잘린다.
DRAIN_SECONDS = 15.0


class StreamError(RuntimeError):
    """스트리밍 세션이 실패했을 때."""


def load_credentials(profile: str | None) -> Credentials:
    """awscli에게 자격 증명을 물어본다.

    직접 `~/.aws/credentials`를 파싱하지 않는 이유는 그 파일이 자격 증명의 전부가
    아니기 때문이다 — SSO 캐시, assume-role, IMDS, 환경 변수, credential_process가
    모두 경로에 있다. `aws configure export-credentials`는 그 해석을 이미 끝낸
    결과를 준다.
    """
    args = ["aws", "configure", "export-credentials", "--format", "process"]
    if profile:
        args += ["--profile", profile]
    completed = subprocess.run(args, capture_output=True, text=True)
    if completed.returncode != 0:
        raise StreamError(
            "자격 증명을 가져올 수 없습니다. `aws sts get-caller-identity`로 확인하세요.\n"
            + completed.stderr.strip()
        )
    payload = json.loads(completed.stdout)
    return Credentials(
        access_key=payload["AccessKeyId"],
        secret_key=payload["SecretAccessKey"],
        session_token=payload.get("SessionToken"),
    )


def resolve_region(explicit: str | None, profile: str | None) -> str:
    """리전을 확정한다. 없으면 실패시킨다.

    임의로 고르면 사용자가 의도하지 않은 리전으로 오디오가 나가고, 비용도 그쪽에
    붙는다.
    """
    if explicit:
        return explicit
    args = ["aws", "configure", "get", "region"]
    if profile:
        args += ["--profile", profile]
    completed = subprocess.run(args, capture_output=True, text=True)
    region = completed.stdout.strip()
    if not region:
        raise StreamError(
            "리전을 알 수 없습니다. --region으로 지정하거나 `aws configure set region`을 실행하세요."
        )
    return region


def to_pcm(audio: Path) -> bytes:
    """오디오를 16kHz 모노 16-bit PCM으로 변환한다.

    `afconvert`를 쓴다 — macOS에 항상 있어서 추가 설치가 필요 없다. ffmpeg가 있으면
    더 빠르지만, 없는 기기에서 스킬이 멈추는 것보다 느린 편이 낫다.

    WAVE 헤더를 붙여 받은 뒤 data 청크만 떼어낸다. raw PCM(`-f caff` 등)으로 받으면
    형식별로 헤더 처리가 갈려서, 헤더가 있는 표준 형식으로 받고 잘라내는 편이 확실하다.
    """
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "converted.wav"
        completed = subprocess.run(
            [
                "afconvert",
                "-f", "WAVE",
                "-d", f"LEI16@{SAMPLE_RATE}",
                "-c", str(CHANNELS),
                str(audio),
                str(wav),
            ],
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0 or not wav.exists():
            raise StreamError(
                f"{audio.name}을 PCM으로 변환할 수 없습니다.\n{completed.stderr.strip()}"
            )
        return extract_wav_data(wav.read_bytes())


def extract_wav_data(wav: bytes) -> bytes:
    """WAVE 파일에서 `data` 청크의 내용만 꺼낸다.

    헤더 길이를 44바이트로 가정하지 않는다. `afconvert`가 `LIST`나 `fact` 청크를
    함께 넣으면 그만큼 밀리는데, 고정 길이로 자르면 헤더 조각이 오디오로 해석돼
    맨 앞에 잡음이 섞인다.
    """
    if len(wav) < 12 or wav[:4] != b"RIFF" or wav[8:12] != b"WAVE":
        raise StreamError("WAVE 파일이 아닙니다")

    offset = 12
    while offset + 8 <= len(wav):
        chunk_id = wav[offset : offset + 4]
        chunk_size = int.from_bytes(wav[offset + 4 : offset + 8], "little")
        body = offset + 8
        if chunk_id == b"data":
            return wav[body : body + chunk_size]
        # 청크는 짝수 경계에 정렬된다. 홀수 크기면 패딩 1바이트가 붙는다.
        offset = body + chunk_size + (chunk_size % 2)
    raise StreamError("WAVE에 data 청크가 없습니다")


def open_stream(
    *,
    region: str,
    credentials: Credentials,
    language_code: str,
    amz_date: str,
) -> tuple[WebSocket, str]:
    """화자 분리를 켜고 스트림을 연다.

    - Returns: (연결, seed 서명). seed는 첫 오디오 프레임 서명의 입력이다.

    `show-speaker-label=true`가 이 스킬의 목적이다. 빼면 결과에 `Speaker` 필드가
    오지 않아 화자 경계를 얻을 수 없다.
    """
    host = f"transcribestreaming.{region}.amazonaws.com:8443"
    url, seed = presign_websocket_url(
        host=host,
        path="/stream-transcription-websocket",
        region=region,
        credentials=credentials,
        query={
            "language-code": language_code,
            "media-encoding": "pcm",
            "sample-rate": str(SAMPLE_RATE),
            "show-speaker-label": "true",
        },
        amz_date=amz_date,
    )
    try:
        return WebSocket(url), seed
    except WebSocketError as error:
        raise StreamError(f"스트림을 열 수 없습니다: {error}") from error


def audio_frame(chunk: bytes, previous_signature: str, region: str, secret_key: str, amz_date: str) -> tuple[bytes, str]:
    """오디오 청크 하나를 서명된 이벤트 스트림 메시지로 감싼다.

    - Returns: (보낼 바이트, 이번 서명). 서명은 **다음 프레임에 물려야** 한다 —
      체인이 끊기면 그 뒤 전부가 거부된다.

    헤더 순서가 서명에 들어가므로 바꾸면 안 된다. `:chunk-signature`가 마지막에
    오는 것도 그 서명이 앞선 헤더들을 포함해 계산되기 때문이다.
    """
    headers = encode_headers(
        {
            ":message-type": "event",
            ":event-type": "AudioEvent",
            ":content-type": "application/octet-stream",
        }
    )
    signature = sign_chunk(
        previous_signature=previous_signature,
        header_block=headers,
        payload=chunk,
        region=region,
        secret_key=secret_key,
        amz_date=amz_date,
    )
    signed_headers = encode_binary_header(":chunk-signature", bytes.fromhex(signature))
    return encode_message(headers + signed_headers, chunk), signature


def collect_results(connection: WebSocket, deadline: float) -> list[dict]:
    """서버가 보내는 확정 결과를 모은다.

    `IsPartial`이 참인 결과는 버린다 — 말하는 중의 잠정 텍스트라서, 그대로 쌓으면
    같은 말이 여러 번 들어간다. 확정 결과가 최종본이다.

    예외 이벤트는 즉시 올린다. `BadRequestException` 같은 것을 무시하고 계속 기다리면
    타임아웃까지 아무 결과 없이 시간을 버린다.
    """
    results: list[dict] = []
    while time.monotonic() < deadline:
        message = connection.receive()
        if message is None:
            break
        _, payload = message
        for headers, body in decode_all(payload):
            message_type = headers.get(":message-type")
            if message_type == "exception":
                name = headers.get(":exception-type", "알 수 없는 예외")
                detail = body.decode("utf-8", "replace")
                raise StreamError(f"{name}: {detail}")
            if message_type != "event":
                continue
            try:
                event = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            for result in event.get("Transcript", {}).get("Results", []):
                if not result.get("IsPartial", True):
                    results.append(result)
    return results


def _start_time(result: dict) -> float:
    """정렬 키. 스트리밍 결과는 도착 순서가 시간순이 아닐 수 있다."""
    try:
        return float(result.get("StartTime", 0.0))
    except (TypeError, ValueError):
        return 0.0


def to_batch_shape(results: list[dict]) -> dict[str, object]:
    """스트리밍 결과를 배치 출력 형태로 바꾼다.

    `merge_speakers.py`가 배치 JSON을 읽도록 이미 만들어져 있고 그쪽에 테스트가
    붙어 있다. 스트리밍용 병합 경로를 따로 만들면 같은 로직이 두 벌이 되고, 한쪽만
    고쳐지는 사고가 난다. 그래서 여기서 형태를 맞춘다.

    두 형식의 차이:

    | | 배치 | 스트리밍 |
    |---|---|---|
    | 화자 라벨 | `speaker_labels.segments[]` | 항목마다 `Speaker` |
    | 라벨 값 | `spk_0` | `0` |
    | 시각 | 문자열 `"1.23"` | 숫자 `1.23` |

    스트리밍에는 화자 구간 목록이 없으므로 연속된 같은 화자의 항목을 묶어 만든다.
    """
    items: list[dict[str, object]] = []
    segments: list[dict[str, object]] = []
    current_label: str | None = None
    segment_start = 0.0
    segment_end = 0.0

    def flush() -> None:
        if current_label is not None:
            segments.append(
                {
                    "start_time": f"{segment_start:.3f}",
                    "end_time": f"{segment_end:.3f}",
                    "speaker_label": current_label,
                }
            )

    for result in sorted(results, key=_start_time):
        alternatives = result.get("Alternatives") or [{}]
        for item in alternatives[0].get("Items", []):
            item_type = item.get("Type")
            if item_type == "speaker-change":
                continue

            entry: dict[str, object] = {
                "type": "pronunciation" if item_type == "pronunciation" else "punctuation",
                "alternatives": [
                    {
                        "content": item.get("Content", ""),
                        "confidence": str(item.get("Confidence", 0.0)),
                    }
                ],
            }
            if item_type == "pronunciation":
                start = float(item.get("StartTime", 0.0))
                end = float(item.get("EndTime", 0.0))
                entry["start_time"] = f"{start:.3f}"
                entry["end_time"] = f"{end:.3f}"

                speaker = item.get("Speaker")
                if speaker is not None:
                    # 배치의 `spk_N` 표기로 맞춘다. 병합 쪽이 라벨 문자열을 그대로
                    # 이름 매핑 키로 쓰므로, 두 경로에서 같은 모양이어야 한다.
                    label = f"spk_{speaker}"
                    if label != current_label:
                        flush()
                        current_label = label
                        segment_start = start
                    segment_end = end
            items.append(entry)
    flush()

    transcript = " ".join(
        (r.get("Alternatives") or [{}])[0].get("Transcript", "")
        for r in sorted(results, key=_start_time)
    ).strip()

    return {
        "jobName": "streaming",
        "status": "COMPLETED",
        "results": {
            "transcripts": [{"transcript": transcript}],
            "speaker_labels": {
                "speakers": len({s["speaker_label"] for s in segments}),
                "segments": segments,
            },
            "items": items,
        },
    }


def stream_file(
    audio: Path,
    region: str,
    credentials: Credentials,
    language_code: str,
    quiet: bool = False,
) -> dict[str, object]:
    """파일 하나를 스트리밍으로 전사한다."""
    pcm = to_pcm(audio)
    duration = len(pcm) / (SAMPLE_RATE * CHANNELS * BYTES_PER_SAMPLE)
    if not quiet:
        print(
            f"  {audio.name}: {duration:.0f}초, {len(pcm) // CHUNK_BYTES + 1}개 프레임",
            file=sys.stderr,
        )

    amz_date = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    connection, signature = open_stream(
        region=region,
        credentials=credentials,
        language_code=language_code,
        amz_date=amz_date,
    )

    # 오디오 길이에 비례해 여유를 둔다. 짧은 파일에 30분을 기다리지 않고, 긴 파일이
    # 고정 한도에 걸려 잘리지도 않게 한다.
    deadline = time.monotonic() + duration / REALTIME_DIVISOR + DRAIN_SECONDS * 4

    with connection:
        pace = CHUNK_MILLISECONDS / 1000 / REALTIME_DIVISOR
        for offset in range(0, len(pcm), CHUNK_BYTES):
            frame, signature = audio_frame(
                pcm[offset : offset + CHUNK_BYTES],
                signature,
                region,
                credentials.secret_key,
                amz_date,
            )
            connection.send_binary(frame)
            time.sleep(pace)

        # 빈 페이로드 프레임이 스트림의 끝을 알린다. 이걸 보내지 않고 소켓을 닫으면
        # 서버가 마지막 발화를 확정하지 않고 세션을 버린다.
        end_frame, _ = audio_frame(
            b"", signature, region, credentials.secret_key, amz_date
        )
        connection.send_binary(end_frame)

        if not quiet:
            print("  오디오 전송 완료, 결과를 기다립니다…", file=sys.stderr)
        results = collect_results(connection, min(deadline, time.monotonic() + DRAIN_SECONDS * 4))

    if not results:
        raise StreamError(
            f"{audio.name}에서 결과를 받지 못했습니다. 오디오가 무음이거나 "
            f"언어({language_code})가 맞지 않을 수 있습니다."
        )
    return to_batch_shape(results)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="AWS Transcribe 스트리밍으로 화자 분리한다 (S3를 쓰지 않는다)."
    )
    parser.add_argument("--session", required=True, type=Path, help="세션 디렉터리")
    parser.add_argument(
        "--sources", default="remote", help="분석할 소스. `remote`, `me`, `remote,me`"
    )
    parser.add_argument(
        "--language-code",
        default="ko-KR",
        help="언어 (기본 ko-KR). 스트리밍은 다중 언어 식별을 지원하지 않는다",
    )
    parser.add_argument("--profile", help="AWS 프로필")
    parser.add_argument("--region", help="AWS 리전 (기본: 프로필 설정)")
    parser.add_argument(
        "--yes",
        action="store_true",
        help="전송 확인을 건너뛴다. 오디오가 AWS로 나가는 것에 동의한다는 뜻",
    )
    parser.add_argument("--quiet", action="store_true", help="진행 로그를 줄인다")
    parser.add_argument("--json", action="store_true", help="요약을 JSON으로 출력")
    args = parser.parse_args(argv)

    session: Path = args.session
    sources = [s.strip() for s in args.sources.split(",") if s.strip()]
    unknown = [s for s in sources if s not in ("me", "remote")]
    if unknown:
        print(f"오류: 알 수 없는 소스 {unknown}. `me` 또는 `remote`만 됩니다.", file=sys.stderr)
        return 2

    audio_files: list[tuple[str, Path]] = []
    for source in sources:
        path = session / f"{source}.m4a"
        if not path.exists():
            print(f"오류: {path}가 없습니다.", file=sys.stderr)
            return 1
        audio_files.append((source, path))

    try:
        region = resolve_region(args.region, args.profile)
        credentials = load_credentials(args.profile)
    except StreamError as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1

    # 오디오가 기기 밖으로 나가는 단계라 사용자가 알고 승인해야 한다. 배치와 달리
    # 저장되는 곳이 없다는 점이 이 방식의 요점이므로 함께 알린다.
    total_mb = sum(p.stat().st_size for _, p in audio_files) / 1_048_576
    print("AWS로 전송할 내용:", file=sys.stderr)
    for source, path in audio_files:
        print(f"  - {path} ({path.stat().st_size / 1_048_576:.1f} MB, 소스: {source})", file=sys.stderr)
    print(f"  대상: transcribestreaming.{region}.amazonaws.com (리전 {region})", file=sys.stderr)
    print(f"  합계 {total_mb:.1f} MB", file=sys.stderr)
    print("  S3에 저장하지 않습니다 — 스트리밍으로 직접 보내고 결과만 받습니다.", file=sys.stderr)
    if not args.yes:
        print("\n중단했습니다. 위 내용에 동의하면 --yes를 붙여 다시 실행하세요.", file=sys.stderr)
        return 3

    outputs: list[dict[str, object]] = []
    for source, path in audio_files:
        if not args.quiet:
            print(f"\n[{source}] 스트리밍 시작", file=sys.stderr)
        try:
            payload = stream_file(path, region, credentials, args.language_code, args.quiet)
        except StreamError as error:
            print(f"오류: {error}", file=sys.stderr)
            return 1
        destination = session / f"aws-{source}.json"
        destination.write_text(
            json.dumps(payload, ensure_ascii=False), encoding="utf-8"
        )
        labels = payload["results"]["speaker_labels"]  # type: ignore[index]
        outputs.append(
            {
                "source": source,
                "transcript": str(destination),
                "speakers": labels["speakers"],  # type: ignore[index]
            }
        )

    summary = {"region": region, "language_code": args.language_code, "results": outputs}
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print("\n화자 분리 결과를 받았습니다 (S3 사용 없음):")
        for entry in outputs:
            print(f"  {entry['source']}: 화자 {entry['speakers']}명 → {entry['transcript']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
