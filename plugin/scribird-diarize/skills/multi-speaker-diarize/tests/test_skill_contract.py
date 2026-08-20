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
        for script in ("stream_transcribe.py", "merge_speakers.py"):
            self.assertIn(f'"$SKILL_DIR/scripts/{script}"', SKILL_TEXT)
            self.assertNotIn(f"/usr/bin/python3 scripts/{script}", SKILL_TEXT)


if __name__ == "__main__":
    unittest.main()
