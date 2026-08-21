#!/usr/bin/env python3
"""스킬 진입점과 단계별 참조의 실행 계약을 검사한다."""

from __future__ import annotations

import unittest
from pathlib import Path


SKILL_DIR = Path(__file__).resolve().parent.parent
SKILL_TEXT = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")
BATCH_TEXT = (SKILL_DIR / "references" / "batch-job.md").read_text(encoding="utf-8")
MERGE_TEXT = (SKILL_DIR / "references" / "merge-review.md").read_text(encoding="utf-8")
NAME_TEXT = (SKILL_DIR / "references" / "speaker-name-matching.md").read_text(
    encoding="utf-8"
)
ALL_INSTRUCTIONS = "\n".join((SKILL_TEXT, BATCH_TEXT, MERGE_TEXT, NAME_TEXT))


class SkillPathTests(unittest.TestCase):
    def test_entrypoint_stays_small_and_routes_to_stage_specific_references(self) -> None:
        """항상 로드되는 진입점은 경계와 라우팅만 유지해야 한다."""
        self.assertLessEqual(len(SKILL_TEXT.split()), 500)
        self.assertIn("references/batch-job.md", SKILL_TEXT)
        self.assertIn("references/merge-review.md", SKILL_TEXT)
        self.assertIn("AWS 명령을 실행하기 전에", SKILL_TEXT)

    def test_bundled_commands_use_the_absolute_skill_directory(self) -> None:
        """작업 디렉터리가 저장소 루트여도 스크립트를 찾을 수 있어야 한다."""
        self.assertIn(
            "미리 존재하는 환경",
            SKILL_TEXT,
        )
        for script in ("run_transcribe.py", "merge_speakers.py"):
            self.assertIn(f'"$SKILL_DIR/scripts/{script}"', ALL_INSTRUCTIONS)
            self.assertNotIn(f"/usr/bin/python3 scripts/{script}", ALL_INSTRUCTIONS)

    def test_skill_requires_batch_s3_and_explicit_consent(self) -> None:
        """스킬은 AWS·S3 경계를 승인 전에 숨기면 안 된다."""
        self.assertIn("AWS CLI 자격 증명과 명시된 리전", BATCH_TEXT)
        self.assertIn("S3에 임시 저장", BATCH_TEXT)
        self.assertIn("먼저 `--yes` 없이", SKILL_TEXT)
        self.assertIn("확인받은 뒤에만 같은 명령에 `--yes`", BATCH_TEXT)
        self.assertIn("S3 쓰기나 작업 생성은 하지 않는다", BATCH_TEXT)

    def test_streaming_path_is_not_supported(self) -> None:
        self.assertNotIn("stream_transcribe.py", SKILL_TEXT)
        self.assertFalse((SKILL_DIR / "scripts" / "stream_transcribe.py").exists())
        self.assertFalse((SKILL_DIR / "scripts" / "awsstream").exists())

    def test_skill_collects_names_locally_and_falls_back_to_unknown(self) -> None:
        self.assertIn("참석자 수와 이름을 묻는다", BATCH_TEXT)
        self.assertIn("로컬 매칭에만 사용", BATCH_TEXT)
        self.assertIn("AWS 명령이나 업로드 파일에 넣지", BATCH_TEXT)
        self.assertIn("`Unknown 1`부터 표시", BATCH_TEXT)
        self.assertIn("references/speaker-name-matching.md", SKILL_TEXT)

    def test_name_matching_problems_do_not_abort_the_merge(self) -> None:
        self.assertIn("일부 항목이 누락되거나 충돌해도 병합은 계속", MERGE_TEXT)
        self.assertIn("적용되지 않은 화자가 `Unknown N`", MERGE_TEXT)


if __name__ == "__main__":
    unittest.main()
