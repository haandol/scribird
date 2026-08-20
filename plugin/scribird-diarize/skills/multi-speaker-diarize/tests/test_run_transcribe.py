#!/usr/bin/env python3
"""run_transcribe 단위 테스트.

AWS를 호출하지 않는다. `run_aws`를 가로채 CLI에 넘어간 인자를 검사하고, 미리
정해둔 응답을 돌려준다. 실제 호출을 섞으면 테스트가 자격 증명·비용·네트워크에
의존하게 되고, 그러면 아무도 돌리지 않는 테스트가 된다.

여기서 인코딩하는 실패는 다음이다.

1. `ShowSpeakerLabels`를 `MaxSpeakerLabels` 없이 보내면 API가 거부한다.
2. us-east-1에 `LocationConstraint`를 주면 버킷 생성이 실패한다.
3. 작업 이름에 Transcribe가 받지 않는 문자가 들어가면 작업이 시작되지 않는다.
4. 승인 없이 업로드하면 온디바이스 앱의 오디오가 사용자 모르게 나간다.
5. `TranscriptFileUri`의 https URL을 그대로 받으면 서명이 없어 403이다.
6. 정리 실패로 예외를 던지면 이미 받아둔 결과를 못 쓰게 된다.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import run_transcribe as rt  # noqa: E402


CONTEXT = rt.AwsContext(account="111122223333", region="ap-northeast-2", profile=None)


class Recorder:
    """`run_aws`를 대신해 호출을 기록하고 정해진 응답을 돌려준다."""

    def __init__(self, responses: dict[str, dict] | None = None) -> None:
        self.calls: list[list[str]] = []
        self.responses = responses or {}
        self.failures: set[str] = set()

    def __call__(self, args: list[str], context: rt.AwsContext | None = None) -> dict:
        self.calls.append(args)
        joined = " ".join(args)
        # 접두사로 맞춘다. 명령마다 인자 수가 달라 고정 길이로 자르면
        # `s3api delete-object`처럼 짧은 키가 영영 매칭되지 않는다.
        for key in self.failures:
            if joined.startswith(key):
                raise rt.AwsError(f"의도된 실패: {key}")
        for key, response in self.responses.items():
            if joined.startswith(key):
                return response
        return {}

    def find(self, *prefix: str) -> list[str] | None:
        """주어진 접두사로 시작한 호출을 찾는다."""
        for call in self.calls:
            if call[: len(prefix)] == list(prefix):
                return call
        return None

    def arg_after(self, call: list[str], flag: str) -> str | None:
        if flag not in call:
            return None
        index = call.index(flag)
        return call[index + 1] if index + 1 < len(call) else None


class JobNameTests(unittest.TestCase):
    def test_unsafe_characters_are_replaced(self) -> None:
        """Transcribe는 `[0-9a-zA-Z._-]`만 받는다.

        세션 이름에는 `_`만 있어 안전하지만, 사용자가 디렉터리를 옮기며 공백이나
        한글을 넣는 일이 있다. 그대로 보내면 작업이 시작되지 않는다.
        """
        name = rt.safe_job_name("회의 2026 08", "remote", "20260803-140000")
        self.assertRegex(name, r"^[0-9a-zA-Z._-]+$")

    def test_name_stays_within_length_limit(self) -> None:
        name = rt.safe_job_name("x" * 500, "remote", "20260803-140000")
        self.assertLessEqual(len(name), 200)

    def test_stamp_makes_reruns_unique(self) -> None:
        """같은 세션을 다시 돌리는 일이 흔하다 — 상한을 올려 재시도 등.

        작업 이름은 계정+리전에서 유일해야 하므로, 시각이 붙지 않으면 두 번째
        실행이 `ConflictException`으로 실패한다.
        """
        first = rt.safe_job_name("s", "remote", "20260803-140000")
        second = rt.safe_job_name("s", "remote", "20260803-141000")
        self.assertNotEqual(first, second)


class BucketTests(unittest.TestCase):
    def test_default_bucket_includes_account_and_region(self) -> None:
        """S3 이름은 전역 네임스페이스라 짧은 이름은 이미 남이 쓰고 있다."""
        self.assertEqual(
            rt.default_bucket_name(CONTEXT),
            "scribird-diarize-111122223333-ap-northeast-2",
        )

    def test_existing_bucket_is_not_recreated(self) -> None:
        recorder = Recorder()
        with mock.patch.object(rt, "run_aws", recorder):
            created = rt.ensure_bucket("existing", CONTEXT)
        self.assertFalse(created)
        self.assertIsNone(recorder.find("s3api", "create-bucket"))

    def test_us_east_1_omits_location_constraint(self) -> None:
        """us-east-1에 LocationConstraint를 주면 InvalidLocationConstraint다.

        S3 API의 오래된 특이 케이스다. 다른 리전과 같이 처리하면 기본 리전을
        쓰는 사용자가 전원 실패한다.
        """
        recorder = Recorder()
        recorder.failures.add("s3api head-bucket")
        context = rt.AwsContext(account="1", region="us-east-1", profile=None)
        with mock.patch.object(rt, "run_aws", recorder):
            rt.ensure_bucket("b", context)
        call = recorder.find("s3api", "create-bucket")
        assert call is not None
        self.assertNotIn("--create-bucket-configuration", call)

    def test_other_regions_include_location_constraint(self) -> None:
        recorder = Recorder()
        recorder.failures.add("s3api head-bucket")
        with mock.patch.object(rt, "run_aws", recorder):
            rt.ensure_bucket("b", CONTEXT)
        call = recorder.find("s3api", "create-bucket")
        assert call is not None
        self.assertIn("LocationConstraint=ap-northeast-2", call)

    def test_new_bucket_blocks_public_access(self) -> None:
        """회의 오디오가 실수로 공개되는 일은 없어야 한다."""
        recorder = Recorder()
        recorder.failures.add("s3api head-bucket")
        with mock.patch.object(rt, "run_aws", recorder):
            rt.ensure_bucket("b", CONTEXT)
        call = recorder.find("s3api", "put-public-access-block")
        assert call is not None
        self.assertIn("BlockPublicAcls=true", " ".join(call))


class StartJobTests(unittest.TestCase):
    def start(self, **kwargs) -> Recorder:
        recorder = Recorder()
        defaults = dict(
            job_name="job",
            media_uri="s3://b/k.m4a",
            bucket="b",
            output_key="out.json",
            max_speakers=5,
            context=CONTEXT,
            language_code=None,
            language_options=None,
        )
        defaults.update(kwargs)
        with mock.patch.object(rt, "run_aws", recorder):
            rt.start_job(**defaults)  # type: ignore[arg-type]
        return recorder

    def test_speaker_labels_always_carry_max(self) -> None:
        """ShowSpeakerLabels는 MaxSpeakerLabels와 함께여야 한다.

        하나만 보내면 BadRequestException이다. 이 스킬의 존재 이유가 화자
        분리이므로, 이 설정이 빠지면 결과 JSON에 `speaker_labels`가 없어
        병합 단계가 전부 미배정으로 끝난다.
        """
        recorder = self.start(max_speakers=7)
        call = recorder.find("transcribe", "start-transcription-job")
        assert call is not None
        settings = recorder.arg_after(call, "--settings")
        self.assertEqual(settings, "ShowSpeakerLabels=true,MaxSpeakerLabels=7")

    def test_m4a_media_format_is_declared(self) -> None:
        """Scribird는 AAC(.m4a)로 저장한다 — CLI가 받는 값이다.

        AudioRecorder가 m4a를 쓰는 이유는 Apple이 mp3 인코딩을 지원하지 않기
        때문이다. 포맷을 잘못 선언하면 작업이 FAILED로 끝난다.
        """
        recorder = self.start()
        call = recorder.find("transcribe", "start-transcription-job")
        assert call is not None
        self.assertEqual(recorder.arg_after(call, "--media-format"), "m4a")

    def test_known_language_uses_language_code(self) -> None:
        """언어를 알면 지정하는 것이 가장 정확하다."""
        recorder = self.start(language_code="ko-KR")
        call = recorder.find("transcribe", "start-transcription-job")
        assert call is not None
        self.assertEqual(recorder.arg_after(call, "--language-code"), "ko-KR")
        self.assertNotIn("--identify-language", call)

    def test_multiple_options_trigger_multi_language(self) -> None:
        """후보가 여럿이면 코드스위칭 회의로 보고 다중 언어로 간다.

        단일 언어 식별로 돌리면 지배 언어가 아닌 구간이 전부 오인식된다 —
        한·영이 섞인 회의에서 영어 발화가 엉뚱한 한글로 찍힌다.
        """
        recorder = self.start(language_options=["ko-KR", "en-US"])
        call = recorder.find("transcribe", "start-transcription-job")
        assert call is not None
        self.assertIn("--identify-multiple-languages", call)
        self.assertIn("ko-KR", call)
        self.assertIn("en-US", call)

    def test_no_language_falls_back_to_identify(self) -> None:
        recorder = self.start()
        call = recorder.find("transcribe", "start-transcription-job")
        assert call is not None
        self.assertIn("--identify-language", call)

    def test_language_code_wins_over_options(self) -> None:
        # 둘 다 주면 명시한 코드가 이긴다 — 사용자가 확실히 아는 쪽이다.
        recorder = self.start(language_code="ko-KR", language_options=["ko-KR", "en-US"])
        call = recorder.find("transcribe", "start-transcription-job")
        assert call is not None
        self.assertNotIn("--identify-multiple-languages", call)


class DownloadTests(unittest.TestCase):
    def test_https_uri_is_converted_to_s3_copy(self) -> None:
        """https URL을 그대로 받으면 서명이 없어 403이다.

        OutputBucketName을 지정하면 TranscriptFileUri가 https로 온다. curl로
        받으려 하면 실패하므로 버킷/키를 뽑아 `aws s3 cp`로 받아야 한다.
        """
        recorder = Recorder()
        job = {
            "Transcript": {
                "TranscriptFileUri": "https://s3.ap-northeast-2.amazonaws.com/my-bucket/pre/fix/job.json"
            }
        }
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "out.json"
            with mock.patch.object(rt, "run_aws", recorder):
                rt.download_transcript(job, destination, CONTEXT)
        call = recorder.find("s3", "cp")
        assert call is not None
        self.assertEqual(call[2], "s3://my-bucket/pre/fix/job.json")

    def test_virtual_hosted_style_uri_is_parsed(self) -> None:
        recorder = Recorder()
        job = {
            "Transcript": {
                "TranscriptFileUri": "https://my-bucket.s3.ap-northeast-2.amazonaws.com/pre/job.json"
            }
        }
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(rt, "run_aws", recorder):
                rt.download_transcript(job, Path(tmp) / "out.json", CONTEXT)
        call = recorder.find("s3", "cp")
        assert call is not None
        self.assertEqual(call[2], "s3://my-bucket/pre/job.json")

    def test_s3_uri_is_used_directly(self) -> None:
        recorder = Recorder()
        job = {"Transcript": {"TranscriptFileUri": "s3://b/k.json"}}
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(rt, "run_aws", recorder):
                rt.download_transcript(job, Path(tmp) / "out.json", CONTEXT)
        call = recorder.find("s3", "cp")
        assert call is not None
        self.assertEqual(call[2], "s3://b/k.json")

    def test_unparseable_uri_raises(self) -> None:
        job = {"Transcript": {"TranscriptFileUri": "ftp://nope/k.json"}}
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(rt, "run_aws", Recorder()):
                with self.assertRaises(rt.AwsError):
                    rt.download_transcript(job, Path(tmp) / "o.json", CONTEXT)


class CleanupTests(unittest.TestCase):
    # 실측 목록. 2분짜리 작업 하나를 돌린 뒤 버킷에 남아 있던 객체들이다.
    # `.write_access_check_file.temp`는 우리가 만든 적이 없다 — Transcribe가
    # 출력 버킷에 쓰기 권한이 있는지 확인하려고 직접 만든 0바이트 파일이다.
    MEASURED_LISTING = {
        "s3api list-objects-v2": {
            "Contents": [
                {"Key": "s/stamp/remote.m4a"},
                {"Key": "s/stamp/job.json"},
                {"Key": "s/stamp/.write_access_check_file.temp"},
            ]
        }
    }

    def test_transcribe_created_file_is_also_deleted(self) -> None:
        """우리가 올린 키만 지우면 Transcribe가 만든 파일이 남는다.

        실측: 아는 키 2개(오디오, 출력 JSON)만 지웠더니 버킷에
        `2026-08-03_130000/20260803-162751/.write_access_check_file.temp`가
        남았다. 회의 오디오를 지우는 것이 목적인 단계가 무언가를 남기고 끝나면
        "작업 후 삭제합니다"라는 약속이 부분적으로만 참이 된다.
        """
        recorder = Recorder(self.MEASURED_LISTING)
        with mock.patch.object(rt, "run_aws", recorder):
            failed = rt.delete_prefix("b", "s/stamp/", CONTEXT)

        self.assertEqual(failed, [])
        deleted = {
            recorder.arg_after(call, "--key")
            for call in recorder.calls
            if call[:2] == ["s3api", "delete-object"]
        }
        self.assertEqual(
            deleted,
            {
                "s/stamp/remote.m4a",
                "s/stamp/job.json",
                "s/stamp/.write_access_check_file.temp",
            },
        )

    def test_delete_failure_does_not_raise(self) -> None:
        """정리 실패로 예외를 던지면 이미 받아둔 결과를 못 쓰게 된다.

        남은 객체는 사용자에게 경로를 알려주면 직접 지울 수 있다. 그게 결과를
        버리는 것보다 낫다.
        """
        recorder = Recorder(self.MEASURED_LISTING)
        recorder.failures.add("s3api delete-object")
        with mock.patch.object(rt, "run_aws", recorder):
            failed = rt.delete_prefix("b", "s/stamp/", CONTEXT)
        self.assertEqual(len(failed), 3)

    def test_unlistable_prefix_is_reported_not_swallowed(self) -> None:
        """목록을 못 읽으면 무엇이 남았는지 알 수 없다 — 접두사를 알린다.

        조용히 성공으로 처리하면 사용자는 오디오가 지워졌다고 믿는다.
        """
        recorder = Recorder()
        recorder.failures.add("s3api list-objects-v2")
        with mock.patch.object(rt, "run_aws", recorder):
            failed = rt.delete_prefix("b", "s/stamp/", CONTEXT)
        self.assertEqual(failed, ["s/stamp/"])

    def test_empty_prefix_deletes_nothing(self) -> None:
        recorder = Recorder({"s3api list-objects-v2": {}})
        with mock.patch.object(rt, "run_aws", recorder):
            failed = rt.delete_prefix("b", "s/stamp/", CONTEXT)
        self.assertEqual(failed, [])
        self.assertIsNone(recorder.find("s3api", "delete-object"))


class WaitTests(unittest.TestCase):
    def test_completed_job_is_returned(self) -> None:
        responses = {
            "transcribe get-transcription-job": {
                "TranscriptionJob": {"TranscriptionJobStatus": "COMPLETED", "x": 1}
            }
        }
        with mock.patch.object(rt, "run_aws", Recorder(responses)):
            job = rt.wait_for_job("j", CONTEXT, timeout=10, quiet=True)
        self.assertEqual(job["x"], 1)

    def test_failed_job_surfaces_reason(self) -> None:
        """FailureReason을 그대로 보여준다 — 사용자가 원인을 알아야 한다."""
        responses = {
            "transcribe get-transcription-job": {
                "TranscriptionJob": {
                    "TranscriptionJobStatus": "FAILED",
                    "FailureReason": "The media format is not valid.",
                }
            }
        }
        with mock.patch.object(rt, "run_aws", Recorder(responses)):
            with self.assertRaises(rt.AwsError) as caught:
                rt.wait_for_job("j", CONTEXT, timeout=10, quiet=True)
        self.assertIn("media format", str(caught.exception))

    def test_timeout_message_keeps_job_recoverable(self) -> None:
        """타임아웃에 걸려도 작업은 AWS에서 계속 돈다.

        작업 이름을 알려주지 않으면 사용자는 오디오를 다시 올려야 하고, 시간과
        비용을 두 번 낸다.
        """
        responses = {
            "transcribe get-transcription-job": {
                "TranscriptionJob": {"TranscriptionJobStatus": "IN_PROGRESS"}
            }
        }
        with mock.patch.object(rt, "run_aws", Recorder(responses)):
            with mock.patch.object(rt.time, "monotonic", side_effect=[0, 100, 100]):
                with self.assertRaises(rt.AwsError) as caught:
                    rt.wait_for_job("my-job-name", CONTEXT, timeout=1, quiet=True)
        message = str(caught.exception)
        self.assertIn("my-job-name", message)
        self.assertIn("get-transcription-job", message)


class ConsentTests(unittest.TestCase):
    """업로드는 사용자가 알고 승인해야 한다.

    Scribird는 아무것도 네트워크로 보내지 않는 온디바이스 앱이다. 이 스킬은
    그 성질을 의도적으로 벗어나므로, 조용히 올리면 사용자가 신뢰의 근거를
    잃는다.
    """

    def build_session(self, tmp: str) -> Path:
        session = Path(tmp) / "2026-08-03_140000"
        session.mkdir(parents=True)
        (session / "remote.m4a").write_bytes(b"\x00" * 2048)
        return session

    def test_without_yes_nothing_is_uploaded(self) -> None:
        recorder = Recorder()
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            with mock.patch.object(rt, "run_aws", recorder), mock.patch.object(
                rt, "resolve_context", return_value=CONTEXT
            ):
                code = rt.main(["--session", str(session), "--sources", "remote"])
        self.assertEqual(code, 3)
        # S3에 아무것도 올라가지 않았다.
        self.assertIsNone(recorder.find("s3", "cp"))
        self.assertIsNone(recorder.find("transcribe", "start-transcription-job"))

    def test_plan_discloses_aws_permissions_and_temporary_s3_storage(self) -> None:
        recorder = Recorder()
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            with mock.patch.object(rt, "run_aws", recorder), mock.patch.object(
                rt, "resolve_context", return_value=CONTEXT
            ), redirect_stderr(stderr):
                code = rt.main(["--session", str(session), "--sources", "remote"])

        self.assertEqual(code, 3)
        plan = stderr.getvalue()
        self.assertIn("s3:CreateBucket", plan)
        self.assertIn("s3:PutBucketPublicAccessBlock", plan)
        self.assertIn("transcribe:StartTranscriptionJob", plan)
        self.assertIn("S3 버킷에 임시 저장", plan)
        self.assertIn("remote.m4a", plan)
        self.assertIn("소스: remote", plan)
        self.assertIn(CONTEXT.account, plan)
        self.assertIn(CONTEXT.region, plan)
        self.assertIn(rt.default_bucket_name(CONTEXT), plan)
        self.assertIn("작업 후 S3 객체: 삭제합니다", plan)

    def test_default_source_is_remote_only(self) -> None:
        recorder = Recorder()
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            with mock.patch.object(rt, "run_aws", recorder), mock.patch.object(
                rt, "resolve_context", return_value=CONTEXT
            ), redirect_stderr(stderr):
                code = rt.main(["--session", str(session)])

        self.assertEqual(code, 3)
        plan = stderr.getvalue()
        self.assertIn("소스: remote", plan)
        self.assertNotIn("me.m4a", plan)

    def test_missing_audio_fails_before_any_aws_call(self) -> None:
        """파일이 없으면 자격 증명을 확인하기도 전에 멈춘다."""
        recorder = Recorder()
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "empty"
            session.mkdir()
            with mock.patch.object(rt, "run_aws", recorder):
                code = rt.main(["--session", str(session), "--sources", "remote"])
        self.assertEqual(code, 1)
        self.assertEqual(recorder.calls, [])

    def test_out_of_range_speaker_count_is_rejected(self) -> None:
        """2~30 밖의 값은 API가 거부한다 — 올리기 전에 걸러야 한다."""
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            for bad in ("1", "31"):
                code = rt.main(
                    ["--session", str(session), "--max-speakers", bad]
                )
                self.assertEqual(code, 2, f"--max-speakers {bad}")

    def test_unknown_source_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            code = rt.main(["--session", str(session), "--sources", "everyone"])
        self.assertEqual(code, 2)


class FullRunTests(unittest.TestCase):
    def test_yes_runs_upload_analyze_download_cleanup(self) -> None:
        """승인 후에는 업로드 → 분석 → 회수 → 정리가 순서대로 일어난다."""
        responses = {
            "transcribe get-transcription-job": {
                "TranscriptionJob": {
                    "TranscriptionJobStatus": "COMPLETED",
                    "Transcript": {"TranscriptFileUri": "s3://b/out.json"},
                }
            },
            # 마지막 항목은 Transcribe가 직접 만든 쓰기 권한 확인 파일에 해당한다.
            "s3api list-objects-v2": {
                "Contents": [
                    {"Key": "listed-a.m4a"},
                    {"Key": "listed-b.json"},
                    {"Key": "listed-.temp"},
                ]
            },
        }
        recorder = Recorder(responses)
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "2026-08-03_140000"
            session.mkdir(parents=True)
            (session / "remote.m4a").write_bytes(b"\x00" * 1024)

            with mock.patch.object(rt, "run_aws", recorder), mock.patch.object(
                rt, "resolve_context", return_value=CONTEXT
            ):
                code = rt.main(
                    [
                        "--session",
                        str(session),
                        "--sources",
                        "remote",
                        "--max-speakers",
                        "4",
                        "--language-code",
                        "ko-KR",
                        "--stamp",
                        "20260803-140000",
                        "--yes",
                        "--quiet",
                    ]
                )

        self.assertEqual(code, 0)
        # 업로드했다.
        upload = recorder.find("s3", "cp")
        assert upload is not None
        self.assertTrue(upload[3].startswith("s3://scribird-diarize-"))
        # 화자 분리를 켰다.
        start = recorder.find("transcribe", "start-transcription-job")
        assert start is not None
        self.assertIn("ShowSpeakerLabels=true,MaxSpeakerLabels=4", start)
        # 정리했다 — 접두사 아래 전부. Transcribe가 만든 파일까지 포함하려면
        # 목록을 읽고 지워야 하므로, 목록 호출이 있었는지도 함께 본다.
        self.assertIsNotNone(recorder.find("s3api", "list-objects-v2"))
        deleted = {
            recorder.arg_after(call, "--key")
            for call in recorder.calls
            if call[:2] == ["s3api", "delete-object"]
        }
        self.assertEqual(deleted, {"listed-a.m4a", "listed-b.json", "listed-.temp"})

    def test_keep_s3_skips_cleanup(self) -> None:
        responses = {
            "transcribe get-transcription-job": {
                "TranscriptionJob": {
                    "TranscriptionJobStatus": "COMPLETED",
                    "Transcript": {"TranscriptFileUri": "s3://b/out.json"},
                }
            }
        }
        recorder = Recorder(responses)
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "s"
            session.mkdir(parents=True)
            (session / "remote.m4a").write_bytes(b"\x00" * 512)
            with mock.patch.object(rt, "run_aws", recorder), mock.patch.object(
                rt, "resolve_context", return_value=CONTEXT
            ):
                rt.main(
                    [
                        "--session",
                        str(session),
                        "--yes",
                        "--quiet",
                        "--keep-s3",
                        "--stamp",
                        "x",
                    ]
                )
        self.assertIsNone(recorder.find("s3api", "delete-object"))

    def test_cleanup_failure_keeps_downloaded_result_and_reports_leftover(self) -> None:
        responses = {
            "transcribe get-transcription-job": {
                "TranscriptionJob": {
                    "TranscriptionJobStatus": "COMPLETED",
                    "Transcript": {"TranscriptFileUri": "s3://b/out.json"},
                }
            },
            "s3api list-objects-v2": {
                "Contents": [{"Key": "s/x/remote.m4a"}]
            },
        }
        recorder = Recorder(responses)
        recorder.failures.add("s3api delete-object")
        stdout = io.StringIO()

        def download(job: dict, destination: Path, context: rt.AwsContext) -> Path:
            destination.write_text("transcript", encoding="utf-8")
            return destination

        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "s"
            session.mkdir(parents=True)
            (session / "remote.m4a").write_bytes(b"\x00" * 512)
            with mock.patch.object(rt, "run_aws", recorder), mock.patch.object(
                rt, "resolve_context", return_value=CONTEXT
            ), mock.patch.object(rt, "download_transcript", side_effect=download), mock.patch(
                "sys.stdout", stdout
            ):
                code = rt.main(
                    [
                        "--session",
                        str(session),
                        "--yes",
                        "--quiet",
                        "--stamp",
                        "x",
                    ]
                )

            self.assertEqual(code, 0)
            self.assertEqual(
                (session / "aws-remote.json").read_text(encoding="utf-8"),
                "transcript",
            )
            self.assertIn("aws-remote.json", stdout.getvalue())
            self.assertIn("s3://", stdout.getvalue())
            self.assertIn("remote.m4a", stdout.getvalue())


class RegionTests(unittest.TestCase):
    def test_missing_region_is_an_error_not_a_guess(self) -> None:
        """리전을 임의로 고르면 의도하지 않은 곳에 데이터가 올라간다.

        비용도 그쪽에 붙고, 사용자는 왜 거기 있는지 모른다.
        """
        def fake_run(args: list[str], context=None) -> dict:
            if args[:2] == ["sts", "get-caller-identity"]:
                return {"Account": "1"}
            return {"raw": ""}

        with mock.patch.object(rt, "run_aws", fake_run):
            with self.assertRaises(rt.AwsError) as caught:
                rt.resolve_context(profile=None, region=None)
        self.assertIn("리전", str(caught.exception))

    def test_explicit_region_skips_config_lookup(self) -> None:
        recorder = Recorder({"sts get-caller-identity": {"Account": "42"}})
        with mock.patch.object(rt, "run_aws", recorder):
            context = rt.resolve_context(profile=None, region="us-west-2")
        self.assertEqual(context.region, "us-west-2")
        self.assertEqual(context.account, "42")
        self.assertIsNone(recorder.find("configure", "get", "region"))

    def test_profile_is_passed_to_every_call(self) -> None:
        """프로필을 빼먹으면 기본 계정에 올라간다 — 회사/개인 계정이 섞인다."""
        context = rt.AwsContext(account="1", region="us-west-2", profile="work")
        self.assertIn("--profile", context.base_args)
        self.assertIn("work", context.base_args)


if __name__ == "__main__":
    unittest.main(verbosity=2)
