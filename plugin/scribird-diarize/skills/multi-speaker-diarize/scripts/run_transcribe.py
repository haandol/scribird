#!/usr/bin/env python3
"""로컬 AWS 자격 증명으로 AWS Transcribe 화자 분리 작업을 돌린다.

`awscli`를 subprocess로 호출한다. boto3를 쓰지 않는 이유는 설치 상태를 가정할
수 없기 때문이다 — awscli는 사용자가 이미 쓰고 있는 도구이고, 프로필·SSO·MFA
같은 자격 증명 해석을 CLI가 이미 처리한다. 같은 것을 SDK로 다시 구현하면
`aws sts get-caller-identity`로는 되는데 스킬로는 안 되는 상황이 생긴다.

이 스크립트는 오디오를 사용자 계정 밖으로 내보낸다. Scribird는 온디바이스
앱이므로 이는 앱의 기본 성질을 벗어나는 동작이다. 그래서 (1) 업로드 전에
무엇을 어디로 보내는지 출력하고, (2) `--yes` 없이는 진행하지 않으며,
(3) 기본값으로 작업이 끝나면 S3 객체를 지운다.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

# Transcribe batch가 받는 화자 수 상한. 2 미만이나 30 초과는 API가 거부한다.
MIN_SPEAKERS = 2
MAX_SPEAKERS = 30

# 작업 상태를 물어보는 간격.
#
# Transcribe batch는 짧은 파일도 준비에 수십 초가 걸린다. 1초마다 물으면
# API 호출만 늘고 얻는 것이 없으므로 5초로 둔다.
POLL_INTERVAL_SECONDS = 5

# 기본 대기 한도. 1시간 회의가 대략 10분 안에 끝나는 것을 기준으로 여유를 뒀다.
DEFAULT_TIMEOUT_SECONDS = 1800

# 기본 경로가 요구하는 AWS 권한. 기존 버킷을 쓰면 생성 관련 권한은 호출하지 않지만,
# 버킷이 없는 사용자도 실행할 수 있어야 하므로 승인 화면에는 전체 조건을 보여준다.
REQUIRED_PERMISSIONS = (
    "s3:CreateBucket",
    "s3:PutBucketPublicAccessBlock",
    "s3:PutObject",
    "s3:GetObject",
    "s3:DeleteObject",
    "s3:ListBucket",
    "transcribe:StartTranscriptionJob",
    "transcribe:GetTranscriptionJob",
)

# 작업 이름에 쓸 수 없는 문자. Transcribe는 [0-9a-zA-Z._-]만 받는다.
_UNSAFE_JOB_CHARS = re.compile(r"[^0-9a-zA-Z._-]")


class AwsError(RuntimeError):
    """awscli가 실패했을 때. 메시지에 CLI의 stderr를 그대로 담는다."""


@dataclass
class AwsContext:
    account: str
    region: str
    profile: str | None

    @property
    def base_args(self) -> list[str]:
        args = ["--region", self.region]
        if self.profile:
            args += ["--profile", self.profile]
        return args


def run_aws(args: list[str], context: AwsContext | None = None) -> dict:
    """awscli를 호출하고 JSON 출력을 파싱한다.

    출력이 비어 있는 명령(`s3 cp`, `s3api delete-object` 등)도 있어서 빈
    응답은 빈 dict로 돌려준다.
    """
    command = ["aws"] + args
    if context:
        command += context.base_args
    completed = subprocess.run(command, capture_output=True, text=True)
    if completed.returncode != 0:
        raise AwsError(
            f"`{' '.join(command)}` 실패 (exit {completed.returncode})\n"
            f"{completed.stderr.strip()}"
        )
    output = completed.stdout.strip()
    if not output:
        return {}
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return {"raw": output}


def resolve_context(profile: str | None, region: str | None) -> AwsContext:
    """계정과 리전을 확정한다.

    리전을 인자로 받지 않은 경우 프로필 설정에서 읽는다. 어느 쪽에도 없으면
    실패시킨다 — 임의의 리전을 골라 주면 사용자가 의도하지 않은 곳에 데이터가
    올라가고, 비용도 그쪽에 붙는다.
    """
    identity_args = ["sts", "get-caller-identity"]
    if profile:
        identity_args += ["--profile", profile]
    identity = run_aws(identity_args)

    if not region:
        config_args = ["configure", "get", "region"]
        if profile:
            config_args += ["--profile", profile]
        try:
            resolved = run_aws(config_args)
            region = resolved.get("raw", "").strip() if isinstance(resolved, dict) else ""
        except AwsError:
            region = ""
    if not region:
        raise AwsError(
            "리전을 알 수 없습니다. --region으로 지정하거나 `aws configure set region`을 실행하세요."
        )

    return AwsContext(account=identity["Account"], region=region, profile=profile)


def default_bucket_name(context: AwsContext) -> str:
    """`scribird-diarize-<account>-<region>`.

    S3 버킷 이름은 전역 네임스페이스라 짧은 이름은 이미 남이 쓰고 있다.
    계정과 리전을 넣으면 충돌하지 않고, 이름만 보고 무엇에 쓰는 버킷인지
    알 수 있다.
    """
    return f"scribird-diarize-{context.account}-{context.region}"


def ensure_bucket(bucket: str, context: AwsContext) -> bool:
    """버킷이 없으면 만든다.

    - Returns: 이번에 새로 만들었는지 여부.

    us-east-1은 `LocationConstraint`를 받지 않는다 — 넣으면
    `InvalidLocationConstraint`로 실패한다. S3 API의 오래된 특이 케이스다.
    """
    try:
        run_aws(["s3api", "head-bucket", "--bucket", bucket], context)
        return False
    except AwsError:
        pass

    create_args = ["s3api", "create-bucket", "--bucket", bucket]
    if context.region != "us-east-1":
        create_args += ["--create-bucket-configuration", f"LocationConstraint={context.region}"]
    run_aws(create_args, context)

    # 회의 오디오가 실수로 공개되는 일은 없어야 한다. 기본 차단을 명시적으로 켠다.
    run_aws(
        [
            "s3api",
            "put-public-access-block",
            "--bucket",
            bucket,
            "--public-access-block-configuration",
            "BlockPublicAcls=true,IgnorePublicAcls=true,"
            "BlockPublicPolicy=true,RestrictPublicBuckets=true",
        ],
        context,
    )
    return True


def safe_job_name(session: str, source: str, stamp: str) -> str:
    """Transcribe가 받는 문자만 남긴 작업 이름.

    작업 이름은 계정+리전에서 유일해야 한다. 같은 세션을 다시 돌리는 일이
    흔하므로(상한을 올려서 재시도 등) 호출 시각을 붙여 충돌을 피한다.
    """
    raw = f"scribird-{session}-{source}-{stamp}"
    return _UNSAFE_JOB_CHARS.sub("-", raw)[:200]


def upload(audio: Path, bucket: str, key: str, context: AwsContext) -> str:
    run_aws(["s3", "cp", str(audio), f"s3://{bucket}/{key}"], context)
    return f"s3://{bucket}/{key}"


def start_job(
    job_name: str,
    media_uri: str,
    bucket: str,
    output_key: str,
    max_speakers: int,
    context: AwsContext,
    language_code: str | None,
    language_options: list[str] | None,
) -> None:
    """화자 분리를 켜고 작업을 시작한다.

    `ShowSpeakerLabels`는 `MaxSpeakerLabels`와 함께여야 한다 — 하나만 주면
    `BadRequestException`이다.

    언어 지정 방식이 세 갈래인 이유는 정확도가 그만큼 달라지기 때문이다.
    언어를 알면 `--language-code`가 가장 정확하고, 코드스위칭 회의라면
    `--identify-multiple-languages`가 필요하고, 모르면 `--identify-language`로
    맡긴다. `LanguageOptions`는 후보를 좁혀 방언 오인을 줄인다.
    """
    args = [
        "transcribe",
        "start-transcription-job",
        "--transcription-job-name",
        job_name,
        "--media",
        f"MediaFileUri={media_uri}",
        "--media-format",
        "m4a",
        "--output-bucket-name",
        bucket,
        "--output-key",
        output_key,
        "--settings",
        f"ShowSpeakerLabels=true,MaxSpeakerLabels={max_speakers}",
    ]
    if language_code:
        args += ["--language-code", language_code]
    elif language_options and len(language_options) > 1:
        # 후보가 여럿이면 코드스위칭 가능성이 있다고 보고 다중 언어로 간다.
        args += ["--identify-multiple-languages", "--language-options"] + language_options
    else:
        args += ["--identify-language"]
        if language_options:
            args += ["--language-options"] + language_options
    run_aws(args, context)


def wait_for_job(
    job_name: str, context: AwsContext, timeout: float, quiet: bool = False
) -> dict:
    """작업이 끝날 때까지 기다린다.

    타임아웃에 걸려도 작업은 AWS에서 계속 돈다. 그래서 실패 메시지에 작업
    이름을 넣어, 사용자가 나중에 `get-transcription-job`으로 되짚을 수 있게
    한다 — 업로드한 오디오를 다시 올리게 만들면 시간과 비용을 두 번 낸다.
    """
    deadline = time.monotonic() + timeout
    while True:
        response = run_aws(
            ["transcribe", "get-transcription-job", "--transcription-job-name", job_name],
            context,
        )
        job = response["TranscriptionJob"]
        status = job["TranscriptionJobStatus"]
        if status == "COMPLETED":
            return job
        if status == "FAILED":
            raise AwsError(
                f"작업 {job_name} 실패: {job.get('FailureReason', '이유가 보고되지 않았습니다')}"
            )
        if time.monotonic() > deadline:
            raise AwsError(
                f"작업 {job_name}이 {timeout:.0f}초 안에 끝나지 않았습니다. "
                f"작업은 계속 돌고 있으니 나중에 "
                f"`aws transcribe get-transcription-job --transcription-job-name {job_name}`"
                f"으로 확인하세요."
            )
        if not quiet:
            print(f"  {job_name}: {status} …", file=sys.stderr)
        time.sleep(POLL_INTERVAL_SECONDS)


def download_transcript(job: dict, destination: Path, context: AwsContext) -> Path:
    """결과 JSON을 내려받는다.

    `TranscriptFileUri`는 `OutputBucketName`을 지정했을 때 https URL로 온다.
    그 URL을 그대로 curl하면 서명이 없어 403이므로, 버킷/키를 뽑아
    `aws s3 cp`로 받는다.
    """
    uri = job["Transcript"]["TranscriptFileUri"]
    destination.parent.mkdir(parents=True, exist_ok=True)

    if uri.startswith("s3://"):
        run_aws(["s3", "cp", uri, str(destination)], context)
        return destination

    # https://s3.<region>.amazonaws.com/<bucket>/<key> 또는
    # https://<bucket>.s3.<region>.amazonaws.com/<key>
    match = re.match(r"https://s3[.-][^/]+/([^/]+)/(.+)", uri)
    if match:
        bucket, key = match.group(1), match.group(2)
    else:
        match = re.match(r"https://([^.]+)\.s3[.-][^/]+/(.+)", uri)
        if not match:
            raise AwsError(f"결과 URI를 해석할 수 없습니다: {uri}")
        bucket, key = match.group(1), match.group(2)

    run_aws(["s3", "cp", f"s3://{bucket}/{key}", str(destination)], context)
    return destination


def delete_prefix(bucket: str, prefix: str, context: AwsContext) -> list[str]:
    """접두사 아래 객체를 모두 지운다.

    아는 키만 지우면 안 된다. Transcribe는 출력 버킷에 쓰기 권한이 있는지
    확인하려고 `.write_access_check_file.temp`를 직접 만드는데(실측: 2분짜리
    작업 하나가 0바이트 객체를 남겼다), 우리가 그 이름을 만든 적이 없으므로
    업로드·출력 키만 지우면 이 파일이 버킷에 계속 쌓인다. 회의 오디오를 지우는
    것이 목적인 정리 단계가 무언가를 남기고 끝나면, "작업 후 삭제합니다"라는
    약속이 부분적으로만 참이 된다.

    - Returns: 지우지 못한 키. 실패해도 예외를 던지지 않는다 — 정리 실패로
      이미 받아 둔 결과를 못 쓰게 되는 것이 더 나쁘고, 남은 객체는 사용자에게
      경로를 알려 주면 직접 지울 수 있다.
    """
    try:
        listing = run_aws(
            ["s3api", "list-objects-v2", "--bucket", bucket, "--prefix", prefix], context
        )
    except AwsError:
        # 목록을 못 읽으면 무엇을 지워야 할지 알 수 없다. 접두사를 돌려주어
        # 사용자가 직접 확인하게 한다.
        return [prefix]

    keys = [item["Key"] for item in listing.get("Contents", []) if "Key" in item]
    failed: list[str] = []
    for key in keys:
        try:
            run_aws(["s3api", "delete-object", "--bucket", bucket, "--key", key], context)
        except AwsError:
            failed.append(key)
    return failed


def diarize(
    audio: Path,
    source: str,
    session_name: str,
    bucket: str,
    context: AwsContext,
    max_speakers: int,
    out_dir: Path,
    stamp: str,
    language_code: str | None,
    language_options: list[str] | None,
    timeout: float,
    keep_s3: bool,
    quiet: bool,
) -> dict[str, object]:
    """오디오 하나를 업로드 → 분석 → 회수 → 정리한다."""
    job_name = safe_job_name(session_name, source, stamp)
    prefix = f"{session_name}/{stamp}"
    audio_key = f"{prefix}/{audio.name}"
    output_key = f"{prefix}/{job_name}.json"

    if not quiet:
        print(f"[{source}] 업로드: {audio.name} → s3://{bucket}/{audio_key}", file=sys.stderr)
    media_uri = upload(audio, bucket, audio_key, context)

    start_job(
        job_name=job_name,
        media_uri=media_uri,
        bucket=bucket,
        output_key=output_key,
        max_speakers=max_speakers,
        context=context,
        language_code=language_code,
        language_options=language_options,
    )
    job = wait_for_job(job_name, context, timeout, quiet=quiet)

    destination = out_dir / f"aws-{source}.json"
    download_transcript(job, destination, context)

    leftover: list[str] = []
    if keep_s3:
        if not quiet:
            print(
                f"[{source}] S3에 남겨둡니다: s3://{bucket}/{prefix}/",
                file=sys.stderr,
            )
    else:
        # 접두사 단위로 지운다. 우리가 올린 오디오와 출력 JSON 외에 Transcribe가
        # 직접 만든 쓰기 권한 확인 파일도 이 아래에 있다.
        leftover = delete_prefix(bucket, f"{prefix}/", context)
        if leftover and not quiet:
            print(
                f"[{source}] 경고: 다음 객체를 지우지 못했습니다 — "
                + ", ".join(f"s3://{bucket}/{key}" for key in leftover),
                file=sys.stderr,
            )

    return {
        "source": source,
        "job_name": job_name,
        "transcript": str(destination),
        "s3_prefix": f"s3://{bucket}/{prefix}/" if keep_s3 else None,
        "undeleted": leftover,
    }


def resolve_audio_files(session: Path, sources_arg: str) -> list[tuple[str, Path]]:
    """분석할 소스와 파일 경로를 확정한다.

    자격 증명을 확인하기 **전에** 호출한다. 파일이 없는데 AWS를 먼저 부르면
    무의미한 API 호출이 나가고, 사용자는 오류가 파일 때문인지 권한 때문인지
    헷갈린다.

    - Raises: ValueError. 잘못된 소스 이름이나 없는 파일.
    """
    sources = [s.strip() for s in sources_arg.split(",") if s.strip()]
    unknown = [s for s in sources if s not in ("me", "remote")]
    if unknown:
        raise ValueError(f"알 수 없는 소스 {unknown}. `me` 또는 `remote`만 됩니다.")

    audio_files: list[tuple[str, Path]] = []
    for source in sources:
        path = session / f"{source}.m4a"
        if not path.exists():
            raise ValueError(f"{path}가 없습니다.")
        audio_files.append((source, path))
    return audio_files


def print_upload_plan(
    audio_files: list[tuple[str, Path]], bucket: str, context: AwsContext, keep_s3: bool
) -> None:
    """업로드 전에 무엇이 어디로 나가는지 보여준다.

    Scribird는 아무것도 네트워크로 보내지 않는 온디바이스 앱이다. 이 스크립트는
    그 성질을 의도적으로 벗어나므로, 사용자가 대상 계정과 용량을 보고 승인해야
    한다. stderr로 내보내는 이유는 stdout이 `--json` 결과의 자리이기 때문이다.
    """
    total_mb = sum(path.stat().st_size for _, path in audio_files) / 1_048_576
    print("AWS로 업로드할 내용:", file=sys.stderr)
    for source, path in audio_files:
        print(
            f"  - {path} ({path.stat().st_size / 1_048_576:.1f} MB, 소스: {source})",
            file=sys.stderr,
        )
    print(
        f"  대상: s3://{bucket}/ (계정 {context.account}, 리전 {context.region})",
        file=sys.stderr,
    )
    print(f"  합계 {total_mb:.1f} MB", file=sys.stderr)
    print(f"  필요 권한: {', '.join(REQUIRED_PERMISSIONS)}", file=sys.stderr)
    print(
        "  회의 오디오는 위 S3 버킷에 임시 저장되고 AWS Transcribe 배치 작업이 읽습니다.",
        file=sys.stderr,
    )
    print(f"  작업 후 S3 객체: {'남겨둡니다' if keep_s3 else '삭제합니다'}", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Scribird 세션 오디오를 S3와 AWS Transcribe 배치 작업으로 화자 분리한다."
    )
    parser.add_argument("--session", required=True, type=Path, help="세션 디렉터리")
    parser.add_argument(
        "--sources",
        default="remote",
        help="분석할 소스. `remote`, `me`, `remote,me` (기본: remote)",
    )
    parser.add_argument(
        "--max-speakers",
        type=int,
        default=5,
        help=f"예상 최대 화자 수 ({MIN_SPEAKERS}~{MAX_SPEAKERS}, 기본 5)",
    )
    parser.add_argument("--profile", help="AWS 프로필 (기본: 기본 프로필)")
    parser.add_argument("--region", help="AWS 리전 (기본: 프로필 설정)")
    parser.add_argument("--bucket", help="쓸 S3 버킷 (기본: scribird-diarize-<account>-<region>)")
    parser.add_argument("--language-code", help="언어를 알 때 지정 (예: ko-KR)")
    parser.add_argument(
        "--language-options",
        nargs="+",
        help="후보 언어. 둘 이상이면 다중 언어 식별로 돌린다 (예: ko-KR en-US)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"작업 대기 한도(초). 기본 {DEFAULT_TIMEOUT_SECONDS}",
    )
    parser.add_argument(
        "--keep-s3", action="store_true", help="작업 후 S3 객체를 지우지 않는다"
    )
    parser.add_argument(
        "--stamp",
        help="S3 접두사와 작업 이름에 붙일 문자열 (기본: 현재 시각). 재현 실행에 쓴다",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="업로드 확인을 건너뛴다. 오디오가 AWS로 나가는 것에 동의한다는 뜻",
    )
    parser.add_argument("--quiet", action="store_true", help="진행 로그를 줄인다")
    parser.add_argument("--json", action="store_true", help="결과를 JSON으로 출력")
    return parser


def main(argv: list[str] | None = None) -> int:
    """종료 코드로 무엇이 막았는지 구분한다.

    0 성공 / 1 AWS 또는 파일 문제 / 2 인자 문제 / 3 승인 대기.

    3을 따로 두는 이유는 이것이 실패가 아니기 때문이다. 이 스크립트를 부르는
    에이전트가 "업로드 계획을 사용자에게 보여줄 차례"임을 알아야 한다.
    """
    args = build_parser().parse_args(argv)

    if not (MIN_SPEAKERS <= args.max_speakers <= MAX_SPEAKERS):
        print(
            f"오류: --max-speakers는 {MIN_SPEAKERS}~{MAX_SPEAKERS} 사이여야 합니다.",
            file=sys.stderr,
        )
        return 2

    session: Path = args.session
    try:
        audio_files = resolve_audio_files(session, args.sources)
    except ValueError as error:
        print(f"오류: {error}", file=sys.stderr)
        # 소스 이름이 틀린 것은 인자 문제, 파일이 없는 것은 환경 문제다.
        return 2 if "알 수 없는 소스" in str(error) else 1

    try:
        context = resolve_context(args.profile, args.region)
    except AwsError as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1

    bucket = args.bucket or default_bucket_name(context)
    print_upload_plan(audio_files, bucket, context, args.keep_s3)
    if not args.yes:
        print(
            "\n중단했습니다. 위 내용에 동의하면 --yes를 붙여 다시 실행하세요.",
            file=sys.stderr,
        )
        return 3

    stamp = args.stamp or time.strftime("%Y%m%d-%H%M%S")
    try:
        if ensure_bucket(bucket, context) and not args.quiet:
            print(f"버킷을 새로 만들었습니다: s3://{bucket}", file=sys.stderr)

        results = [
            diarize(
                audio=path,
                source=source,
                session_name=session.name,
                bucket=bucket,
                context=context,
                max_speakers=args.max_speakers,
                out_dir=session,
                stamp=stamp,
                language_code=args.language_code,
                language_options=args.language_options,
                timeout=args.timeout,
                keep_s3=args.keep_s3,
                quiet=args.quiet,
            )
            for source, path in audio_files
        ]
    except AwsError as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1

    summary = {
        "account": context.account,
        "region": context.region,
        "bucket": bucket,
        "max_speakers": args.max_speakers,
        "results": results,
    }
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print("\n화자 분리 결과를 받았습니다:")
        for result in results:
            print(f"  {result['source']} → {result['transcript']}")
        undeleted = [key for r in results for key in r["undeleted"]]  # type: ignore[union-attr]
        if undeleted:
            # 지우지 못한 객체는 회의 오디오일 수 있다. 조용히 넘기면 사용자는
            # 정리됐다고 믿는다.
            print(f"\n경고: S3에 남은 객체 {len(undeleted)}건 — 직접 지워야 합니다:")
            for key in undeleted:
                print(f"  s3://{bucket}/{key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
