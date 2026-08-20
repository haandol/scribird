#!/usr/bin/env python3
"""SKILL.md가 플러그인 설치 위치와 무관하게 실행되는지 검사한다."""

from __future__ import annotations

import unittest
from pathlib import Path


SKILL_DIR = Path(__file__).resolve().parent.parent
SKILL_TEXT = (SKILL_DIR / "SKILL.md").read_text(encoding="utf-8")


class SkillPathTests(unittest.TestCase):
    def test_bundled_commands_use_the_absolute_skill_directory(self) -> None:
        """작업 디렉터리가 저장소 루트여도 스크립트를 찾을 수 있어야 한다."""
        self.assertIn(
            "`SKILL_DIR`은 미리 존재하는 환경 변수가 아니다.",
            SKILL_TEXT,
        )
        for script in ("run_transcribe.py", "merge_speakers.py"):
            self.assertIn(f'"$SKILL_DIR/scripts/{script}"', SKILL_TEXT)
            self.assertNotIn(f"/usr/bin/python3 scripts/{script}", SKILL_TEXT)

    def test_skill_requires_batch_s3_and_explicit_consent(self) -> None:
        """스킬은 AWS·S3 경계를 승인 전에 숨기면 안 된다."""
        self.assertIn("AWS CLI 자격 증명과 리전", SKILL_TEXT)
        self.assertIn("회의 M4A가 선택한 계정과 리전의 S3에 임시 저장", SKILL_TEXT)
        self.assertIn("스크립트를 실행하기 전에", SKILL_TEXT)
        self.assertIn("진행할지 확인", SKILL_TEXT)
        self.assertIn("확인받은 뒤에만 `--yes`", SKILL_TEXT)

    def test_streaming_path_is_not_supported(self) -> None:
        self.assertNotIn("stream_transcribe.py", SKILL_TEXT)
        self.assertFalse((SKILL_DIR / "scripts" / "stream_transcribe.py").exists())
        self.assertFalse((SKILL_DIR / "scripts" / "awsstream").exists())

    def test_skill_collects_names_locally_and_falls_back_to_unknown(self) -> None:
        self.assertIn("참석자 수와 이름을 먼저 묻는다", SKILL_TEXT)
        self.assertIn("로컬 이름 매칭에만 사용", SKILL_TEXT)
        self.assertIn("AWS 명령이나 업로드 파일에 넣지 않는다", SKILL_TEXT)
        self.assertIn("`Unknown 1`부터 표시", SKILL_TEXT)
        self.assertIn("references/speaker-name-matching.md", SKILL_TEXT)

    def test_name_matching_problems_do_not_abort_the_merge(self) -> None:
        self.assertIn("일부 항목이 누락되거나 충돌해도 병합은 계속", SKILL_TEXT)
        self.assertIn("적용되지 않은 화자가 `Unknown N`", SKILL_TEXT)


if __name__ == "__main__":
    unittest.main()
