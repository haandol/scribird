#!/usr/bin/env python3
"""merge_speakers 단위 테스트.

`/usr/bin/python3 -m unittest discover tests` 로 돈다. 네트워크도 AWS도
건드리지 않는다 — 픽스처는 모두 손으로 만든 JSON이다.

테스트가 인코딩하는 실패는 다음 다섯 가지다. 각각 실제로 깨지는 방식이 있고,
그 방식대로 깨졌을 때 실패하도록 입력을 골랐다.

1. 절대 겹침으로 화자를 고르면 긴 AWS 구간이 짧은 발화를 가로챈다.
2. 경계에 스친 이웃 화자가 라벨을 훔친다 (겹침 임계값이 없을 때).
3. 세션 회전으로 밀린 시간축을 보정하지 않으면 라벨이 옆 발화로 옮겨 붙는다.
4. AWS 단어가 없는 구간을 유사도 0으로 처리하면 거짓 불일치가 쏟아진다.
5. 한글 NFD 입력을 정규화하지 않으면 같은 문장이 불일치로 잡힌다.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from merge_speakers import (  # noqa: E402
    AwsResult,
    AwsSpeakerSegment,
    AwsWord,
    LocalSegment,
    annotate_text_comparison,
    assign_speakers,
    aws_text_for_range,
    ALIGNMENT_SUSPECT_THRESHOLD,
    compare_text,
    find_best_offset,
    find_word_diffs,
    load_aws_result,
    load_local_segments,
    merge,
    name_speakers,
    normalize_text,
    overlap_seconds,
    render_report,
)


def segment(start: float, end: float, text: str = "말", speaker: str = "remote") -> LocalSegment:
    return LocalSegment(
        id=f"{speaker}-{start}",
        speaker=speaker,
        start=start,
        end=end,
        text=text,
    )


def aws(*spans: tuple[float, float, str]) -> AwsResult:
    segments = [AwsSpeakerSegment(start=s, end=e, label=l) for s, e, l in spans]
    return AwsResult(
        speaker_count=len({l for _, _, l in spans}),
        segments=segments,
        words=[],
    )


class OverlapTests(unittest.TestCase):
    def test_disjoint_ranges_overlap_zero(self) -> None:
        self.assertEqual(overlap_seconds(0.0, 1.0, 2.0, 3.0), 0.0)

    def test_touching_ranges_overlap_zero(self) -> None:
        # 끝과 시작이 같은 경계는 겹치지 않는다. 여기서 양수가 나오면 인접
        # 발화가 서로의 화자를 물어간다.
        self.assertEqual(overlap_seconds(0.0, 1.0, 1.0, 2.0), 0.0)

    def test_contained_range_returns_inner_length(self) -> None:
        self.assertAlmostEqual(overlap_seconds(0.0, 10.0, 3.0, 5.0), 2.0)


class AssignSpeakerTests(unittest.TestCase):
    def test_ratio_beats_absolute_overlap(self) -> None:
        """긴 AWS 구간이 짧은 발화를 가로채지 않는다.

        실패 방식: 절대 겹침 길이로 고르면 spk_1(6초 겹침)이 spk_0(0.9초)을
        이긴다. 하지만 이 발화는 1초짜리이고 그 중 0.9초가 spk_0이므로
        주인은 spk_0이다. 비율로 판정해야 옳다.
        """
        target = segment(10.0, 11.0)
        result = aws((9.5, 10.9, "spk_0"), (10.9, 17.0, "spk_1"))
        assign_speakers([target], result)
        self.assertEqual(target.aws_label, "spk_0")

    def test_grazing_neighbor_does_not_steal_label(self) -> None:
        """경계에 스친 화자에게 라벨을 주지 않는다.

        실패 방식: 임계값 없이 "가장 많이 겹치는 화자"를 고르면, 발화의 10%만
        걸친 spk_9가 유일한 후보라는 이유로 라벨을 가져간다. 근거가 약하면
        미배정으로 남기는 것이 회의록에는 낫다.
        """
        target = segment(20.0, 30.0)
        result = aws((29.0, 31.0, "spk_9"))
        assign_speakers([target], result)
        self.assertIsNone(target.aws_label)
        # 판정 근거는 남겨야 사람이 왜 비었는지 알 수 있다.
        self.assertAlmostEqual(target.overlap_ratio, 0.1, places=3)

    def test_majority_overlap_is_assigned(self) -> None:
        target = segment(20.0, 30.0)
        result = aws((19.0, 27.0, "spk_2"))
        assign_speakers([target], result)
        self.assertEqual(target.aws_label, "spk_2")
        self.assertAlmostEqual(target.overlap_ratio, 0.7, places=3)

    def test_zero_duration_segment_is_skipped(self) -> None:
        # 잠정 결과가 확정 직전에 빈 구간으로 오는 경우가 있다. 0으로 나누면
        # 스크립트 전체가 죽는다.
        target = segment(5.0, 5.0)
        assign_speakers([target], aws((0.0, 10.0, "spk_0")))
        self.assertIsNone(target.aws_label)

    def test_no_aws_segments_leaves_everything_unassigned(self) -> None:
        # 화자 분리가 켜지지 않은 출력(speaker_labels 없음)을 받아도 죽지 않고
        # 원래 라벨을 유지해야 한다.
        targets = [segment(0.0, 1.0), segment(1.0, 2.0)]
        assign_speakers(targets, AwsResult(speaker_count=0, segments=[], words=[]))
        self.assertTrue(all(t.aws_label is None for t in targets))


class OffsetTests(unittest.TestCase):
    def test_aligned_timelines_pick_zero_offset(self) -> None:
        """이미 맞은 시간축은 0으로 둔다.

        AnalyzerInputPump.submit이 같은 버퍼로 AudioRecorder에 먼저 쓰고
        framesSent를 올리므로, 정상 세션에서는 오프셋이 0이다. 근거 없이
        밀어 두면 이후 진단이 엉뚱한 곳을 본다.
        """
        local = [segment(0.0, 2.0), segment(3.0, 5.0)]
        result = aws((0.0, 2.0, "spk_0"), (3.0, 5.0, "spk_1"))
        offset, _ = find_best_offset(local, result.segments)
        self.assertEqual(offset, 0.0)

    def test_shifted_timeline_is_recovered(self) -> None:
        """세션 회전으로 1.5초 밀린 시간축을 되찾는다.

        실패 방식: 보정하지 않으면 spk_0 구간이 두 번째 발화와 겹쳐, 첫
        발화의 화자가 두 번째 발화에 붙는다. 라벨이 비는 것보다 나쁘다.
        """
        local = [segment(0.0, 2.0), segment(3.0, 5.0)]
        shifted = aws((-1.5, 0.5, "spk_0"), (1.5, 3.5, "spk_1"))
        offset, _ = find_best_offset(local, shifted.segments)
        self.assertAlmostEqual(offset, 1.5, places=2)

        assign_speakers(local, shifted, offset)
        self.assertEqual(local[0].aws_label, "spk_0")
        self.assertEqual(local[1].aws_label, "spk_1")

    def test_without_offset_correction_labels_land_wrong(self) -> None:
        """보정을 끄면 실제로 틀린다 — 위 테스트가 무언가를 증명함을 보인다.

        밀린 시간축을 그대로 쓰면 두 발화 모두 겹침이 절반을 못 넘겨
        미배정으로 떨어진다. 보정한 경우(위 테스트)는 둘 다 제 화자를
        찾으므로, 두 결과가 갈린다는 것이 보정이 일하고 있다는 증거다.
        """
        local = [segment(0.0, 2.0), segment(3.0, 5.0)]
        shifted = aws((-1.5, 0.5, "spk_0"), (1.5, 3.5, "spk_1"))
        assign_speakers(local, shifted, offset=0.0)
        self.assertIsNone(local[0].aws_label)
        self.assertIsNone(local[1].aws_label)

    def test_shift_beyond_search_range_is_not_invented(self) -> None:
        """탐색 범위를 넘는 밀림은 억지로 맞추지 않는다.

        오프셋 탐색은 세션 경계의 작은 밀림을 보정하려는 것이다. 20초씩
        밀린 것은 다른 세션의 오디오를 짝지었다는 뜻이므로, 그때 그럴듯한
        오프셋을 만들어 내면 엉뚱한 화자 라벨이 확신을 갖고 붙는다.
        """
        local = [segment(0.0, 2.0)]
        far = aws((20.0, 22.0, "spk_0"))
        offset, score = find_best_offset(local, far.segments)
        self.assertEqual(offset, 0.0)
        self.assertEqual(score, 0.0)

    def test_empty_inputs_return_zero(self) -> None:
        self.assertEqual(find_best_offset([], []), (0.0, 0.0))
        self.assertEqual(find_best_offset([segment(0.0, 1.0)], []), (0.0, 0.0))


class SpeakerNamingTests(unittest.TestCase):
    def test_remote_speakers_named_by_talk_time(self) -> None:
        """발화량이 많은 쪽이 A다. 회의록은 주 발언자가 먼저 보여야 한다."""
        local = [
            segment(0.0, 2.0),  # spk_1 → 2초
            segment(2.0, 12.0),  # spk_0 → 10초
        ]
        local[0].aws_label = "spk_1"
        local[1].aws_label = "spk_0"
        names = name_speakers("remote", local)
        self.assertEqual(names["spk_0"], "Remote A")
        self.assertEqual(names["spk_1"], "Remote B")

    def test_me_source_names_dominant_speaker_as_me(self) -> None:
        """마이크에서는 최대 발화자가 기기 주인이다.

        대면 회의에서 상대방이 내 마이크로 함께 들어오는 경우(ADR에 기록된
        Risk)를 다룬다. `나`가 사라지면 회의록의 화자 체계가 무너진다.
        """
        local = [
            segment(0.0, 9.0, speaker="me"),
            segment(9.0, 11.0, speaker="me"),
        ]
        local[0].aws_label = "spk_0"
        local[1].aws_label = "spk_1"
        names = name_speakers("me", local)
        self.assertEqual(names["spk_0"], "Me")
        self.assertEqual(names["spk_1"], "In-person B")

    def test_unassigned_segments_do_not_get_names(self) -> None:
        local = [segment(0.0, 5.0)]
        names = name_speakers("remote", local)
        self.assertEqual(names, {})

    def test_tie_is_broken_deterministically(self) -> None:
        # 발화량이 같으면 라벨 이름순으로 정한다. 실행마다 A/B가 뒤집히면
        # 같은 입력에 다른 회의록이 나온다.
        local = [segment(0.0, 5.0), segment(5.0, 10.0)]
        local[0].aws_label = "spk_1"
        local[1].aws_label = "spk_0"
        names = name_speakers("remote", local)
        self.assertEqual(names["spk_0"], "Remote A")


class TextComparisonTests(unittest.TestCase):
    def test_measured_misrecognition_is_surfaced(self) -> None:
        """실측된 오인식이 목록에 오른다 — 문장 유사도로는 묻힘을 함께 못박는다.

        `배포` → `대포`는 AudioRecorder 주석에 기록된 실제 64k 재전사
        오인식이다. 이 문장의 문장 단위 유사도는 0.9를 넘어 정렬 의심
        임계값(0.75)을 통과한다 — 뜻이 바뀌는 한 단어가 문장 길이에 희석되기
        때문이다. 그래서 단어 단위로 뽑아 내놓아야 한다.
        """
        local = "네, 그럼 배포 일정은 다음 주로 하죠."
        remote = "네 그럼 대포 일정은 다음 주로 하죠"

        similarity = compare_text(local, remote)
        assert similarity is not None
        self.assertGreater(similarity, ALIGNMENT_SUSPECT_THRESHOLD)

        diffs = find_word_diffs(local, remote)
        self.assertEqual([(d.local, d.aws) for d in diffs], [("배포", "대포")])
        # 붙여쓰기 차이가 아니라는 표시가 붙어야 훑는 쪽이 뜻을 따져본다.
        self.assertFalse(diffs[0].spacing_only)

    def test_similarity_ranks_meaning_changes_above_harmless_ones(self) -> None:
        """유사도 순서가 뜻의 보존과 어긋난다 — 임계값을 없앤 결정적 근거.

        임계값이 통하려면 "뜻이 바뀌는 쌍은 낮고 안 바뀌는 쌍은 높다"가
        성립해야 한다. 실측은 그 반대다.

        | 로컬 | AWS | 유사도 | 뜻 |
        |---|---|---:|---|
        | `care` | `car` | 0.857 | **바뀜** |
        | `ok` | `okay` | 0.667 | 보존 |
        | `데이터` | `데이타` | 0.667 | 보존 |

        뜻이 바뀌는 `care`/`car`가 뜻이 보존되는 두 쌍보다 **높다**. 어떤 값을
        문턱으로 잡아도 `care`/`car`를 버리거나 나머지를 신고하게 되므로,
        스크립트는 순위를 매기지 않고 전량을 내놓는다.
        """
        meaning_changed = find_word_diffs("delivering care", "delivering car")
        harmless_abbreviation = find_word_diffs("그건 ok 입니다", "그건 okay 입니다")
        harmless_loanword = find_word_diffs("데이터 확인", "데이타 확인")

        for diffs in (meaning_changed, harmless_abbreviation, harmless_loanword):
            self.assertEqual(len(diffs), 1)

        # 순서가 뒤집혀 있다 — 이 한 줄이 임계값 방식을 무효로 만든다.
        self.assertGreater(meaning_changed[0].similarity, harmless_abbreviation[0].similarity)
        self.assertGreater(meaning_changed[0].similarity, harmless_loanword[0].similarity)

        # 셋 다 붙여쓰기 차이가 아니므로 스크립트는 어느 것도 가려낼 수 없다.
        for diffs in (meaning_changed, harmless_abbreviation, harmless_loanword):
            self.assertFalse(diffs[0].spacing_only)

    def test_spacing_only_is_the_one_safe_classification(self) -> None:
        """공백을 지워 같아지는 쌍만 스크립트가 가른다.

        이건 의미 판단이 아니라 문자열 동일성이므로 틀릴 수 없다. 실측:
        `일정은`/`일정 은`과 `그때`/`그 때`는 유사도 1.00에 `spacing_only`다.
        """
        for local, aws in (("배포 일정은 내일", "배포 일정 은 내일"), ("저는 그때", "저는 그 때")):
            diffs = find_word_diffs(local, aws)
            self.assertEqual(len(diffs), 1, f"{local} vs {aws}")
            self.assertTrue(diffs[0].spacing_only)
            self.assertEqual(diffs[0].similarity, 1.0)

    def test_spacing_only_difference_is_listed_but_marked(self) -> None:
        """붙여쓰기 차이는 버리지 않고 표시만 한다.

        예전에는 유사도 문턱으로 버렸는데, 같은 문턱이 뜻이 바뀌는 오인식도
        함께 버렸다. 회의록의 `배포`가 `대포`로 남는 것을 아무도 모르게 되는
        쪽이 노이즈보다 위험하므로, 전량을 내놓고 구분만 붙인다.
        """
        diffs = find_word_diffs("배포 일정은 내일", "배포 일정 은 내일")
        self.assertEqual(len(diffs), 1)
        self.assertTrue(diffs[0].spacing_only)

    def test_insertion_is_not_reported(self) -> None:
        """한쪽에만 있는 단어는 내놓지 않는다.

        두 엔진의 발화 경계가 조금씩 달라 한쪽 구간에 이웃 단어가 하나 더
        들어오는 일이 흔하다. 그건 "다르게 적었다"가 아니라 "구간이 조금
        다르다"이므로, 목록에 올리면 훑는 쪽의 시간을 버린다.
        """
        self.assertEqual(find_word_diffs("배포 일정", "배포 일정 입니다"), [])

    def test_word_diff_needs_both_sides(self) -> None:
        self.assertEqual(find_word_diffs("무언가", ""), [])
        self.assertEqual(find_word_diffs("", "something"), [])

    def test_punctuation_only_difference_scores_identical(self) -> None:
        """문장부호 차이는 정렬 의심으로 이어지지 않는다.

        두 엔진은 문장부호를 늘 다르게 찍는다. 이걸 유사도에 반영하면 정상
        구간이 정렬 의심으로 올라가 진짜 정렬 실패가 묻힌다.
        """
        self.assertEqual(compare_text("안녕하세요.", "안녕하세요"), 1.0)

    def test_nfd_korean_matches_nfc(self) -> None:
        """자모 분리된 한글도 같은 문장으로 본다.

        실패 방식: macOS 경유로 들어온 문자열은 NFD로 자모가 분리돼 있다.
        정규화하지 않으면 눈에 같은 `한국어`가 코드포인트 수준에서 달라
        유사도가 크게 떨어지고 정상 구간이 정렬 의심으로 올라간다.
        """
        nfc = "한국어 회의"
        nfd = unicodedata.normalize("NFD", nfc)
        self.assertNotEqual(nfc, nfd)  # 입력이 실제로 다름을 확인
        self.assertEqual(normalize_text(nfc), normalize_text(nfd))
        self.assertEqual(compare_text(nfc, nfd), 1.0)

    def test_case_difference_is_folded(self) -> None:
        self.assertEqual(compare_text("Deploy Schedule", "deploy schedule"), 1.0)

    def test_measured_misrecognition_surfaces_end_to_end(self) -> None:
        """단어 차이가 발화에 채워지고, 정렬 의심으로는 올라가지 않는다.

        한 단어만 다른 발화는 정렬이 제대로 된 것이다. 그걸 정렬 의심으로
        표시하면 훑는 쪽이 "이 구간의 단어 차이는 믿지 말라"는 안내를 잘못
        받아 진짜 오인식을 넘긴다.
        """
        target = segment(0.0, 4.0, text="네, 그럼 배포 일정은 다음 주로 하죠.")
        words = [
            AwsWord(start=0.0, end=0.5, content="네"),
            AwsWord(start=0.5, end=1.0, content="그럼"),
            AwsWord(start=1.0, end=1.8, content="대포"),
            AwsWord(start=1.8, end=2.4, content="일정은"),
            AwsWord(start=2.4, end=4.0, content="다음 주로 하죠"),
        ]
        result = AwsResult(speaker_count=1, segments=[], words=words)
        annotate_text_comparison([target], result)
        self.assertTrue(target.has_diffs)
        self.assertEqual([(d.local, d.aws) for d in target.word_diffs], [("배포", "대포")])
        self.assertFalse(target.alignment_suspect)

    def test_wrong_segment_comparison_is_flagged_as_alignment_suspect(self) -> None:
        """전혀 다른 발화를 짝지으면 정렬 의심으로 올라간다.

        이건 정렬을 수행한 스크립트 자신에 대한 진단이므로 스크립트가 판정해도
        된다. 이 신호가 없으면 훑는 쪽이 무의미한 단어 쌍 수십 개를 하나씩
        의미 판단하느라 시간을 버린다.
        """
        target = segment(0.0, 4.0, text="배포 일정을 다음 주로 미루겠습니다")
        words = [
            AwsWord(start=0.0, end=2.0, content="완전히"),
            AwsWord(start=2.0, end=4.0, content="관계없는 내용입니다"),
        ]
        result = AwsResult(speaker_count=1, segments=[], words=words)
        annotate_text_comparison([target], result)
        self.assertTrue(target.alignment_suspect)

    def test_missing_aws_text_yields_no_similarity(self) -> None:
        """대조할 근거가 없으면 유사도를 내지 않는다.

        실패 방식: 빈 AWS 텍스트를 유사도 0.0으로 처리하면, AWS가 그 구간을
        아예 듣지 못한 것과 다르게 들은 것이 같은 취급을 받아 리포트가 거짓
        불일치로 넘친다.
        """
        self.assertIsNone(compare_text("무언가 말했다", ""))
        self.assertIsNone(compare_text("", "something"))

    def test_grazing_word_is_excluded_from_range(self) -> None:
        """경계에 스친 단어는 구간 텍스트에 넣지 않는다.

        실패 방식: 조금이라도 걸치면 포함하면, 이웃 발화의 끝말이 섞여 들어와
        실제로는 일치하는 문장이 불일치로 신고된다.
        """
        words = [
            AwsWord(start=0.0, end=1.0, content="안녕"),
            AwsWord(start=1.0, end=2.0, content="하세요"),
            # 구간(0~2) 끝에 0.1초만 걸친 단어 — 다음 발화의 것이다.
            AwsWord(start=1.9, end=2.9, content="다음발화"),
        ]
        text = aws_text_for_range(words, 0.0, 2.0)
        self.assertEqual(text, "안녕 하세요")


class LoadingTests(unittest.TestCase):
    def test_truncated_jsonl_line_is_skipped(self) -> None:
        """잘린 마지막 줄 하나로 회의록 전체를 잃지 않는다.

        TranscriptStore는 발화당 한 줄을 즉시 append하므로, 크래시 시점의
        마지막 줄이 잘려 있을 수 있다. 그게 파일을 못 읽는 이유가 되면
        즉시 append의 목적(크래시 생존)이 무의미해진다.
        """
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "transcript.jsonl"
            path.write_text(
                '{"id":"a","speaker":"me","start":0,"end":1,"text":"안녕"}\n'
                '{"id":"b","speaker":"remote","start":1,"end":2,"text":"네"}\n'
                '{"id":"c","speaker":"remote","start":2,"end":3,"te',
                encoding="utf-8",
            )
            segments = load_local_segments(path)
        self.assertEqual([s.id for s in segments], ["a", "b"])

    def test_segments_are_sorted_by_start(self) -> None:
        """두 소스가 비동기로 도착하므로 파일 순서가 시간순이 아닐 수 있다."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "transcript.jsonl"
            path.write_text(
                '{"id":"late","speaker":"me","start":5,"end":6,"text":"나중"}\n'
                '{"id":"early","speaker":"remote","start":1,"end":2,"text":"먼저"}\n',
                encoding="utf-8",
            )
            segments = load_local_segments(path)
        self.assertEqual([s.id for s in segments], ["early", "late"])

    def test_punctuation_items_are_dropped(self) -> None:
        """시각 없는 문장부호 항목은 버린다 — 구간 대조에 쓸 수 없다."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "aws.json"
            path.write_text(
                json.dumps(
                    {
                        "results": {
                            "speaker_labels": {
                                "speakers": 2,
                                "segments": [
                                    {
                                        "start_time": "0.0",
                                        "end_time": "1.0",
                                        "speaker_label": "spk_0",
                                    }
                                ],
                            },
                            "items": [
                                {
                                    "type": "pronunciation",
                                    "start_time": "0.0",
                                    "end_time": "0.5",
                                    "alternatives": [{"content": "안녕", "confidence": "0.99"}],
                                },
                                {
                                    "type": "punctuation",
                                    "alternatives": [{"content": ".", "confidence": "0.0"}],
                                },
                            ],
                        }
                    }
                ),
                encoding="utf-8",
            )
            result = load_aws_result(path)
        self.assertEqual([w.content for w in result.words], ["안녕"])
        self.assertEqual(result.speaker_count, 2)

    def test_missing_speaker_labels_does_not_crash(self) -> None:
        """화자 분리를 켜지 않은 출력도 읽는다.

        `ShowSpeakerLabels`를 빼고 돌린 작업의 결과를 실수로 넘기는 일이
        생긴다. 그때 예외로 죽으면 사용자는 무엇이 잘못됐는지 알 수 없다.
        """
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "aws.json"
            path.write_text(json.dumps({"results": {"items": []}}), encoding="utf-8")
            result = load_aws_result(path)
        self.assertEqual(result.segments, [])
        self.assertEqual(result.speaker_count, 0)

    def test_multi_language_codes_are_read(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "aws.json"
            path.write_text(
                json.dumps(
                    {
                        "results": {
                            "language_codes": [
                                {"language_code": "ko-KR", "duration_in_seconds": 5.0},
                                {"language_code": "en-US", "duration_in_seconds": 2.0},
                            ],
                            "items": [],
                        }
                    }
                ),
                encoding="utf-8",
            )
            result = load_aws_result(path)
        self.assertEqual(result.languages, ["ko-KR", "en-US"])


class MergeEndToEndTests(unittest.TestCase):
    """실제 파일을 만들어 전체 경로를 돌린다."""

    def build_session(self, tmp: str) -> Path:
        session = Path(tmp) / "2026-08-03_140000"
        session.mkdir(parents=True)

        # 로컬 전사: remote 2명이 한 라벨로 뭉쳐 있고 me가 하나 섞인 회의.
        lines = [
            {"id": "1", "speaker": "me", "start": 0.0, "end": 2.0, "text": "안녕하세요, 시작하겠습니다.", "confidence": 0.95, "locale": "ko-KR"},
            {"id": "2", "speaker": "remote", "start": 2.5, "end": 6.0, "text": "네, 그럼 배포 일정은 다음 주로 하죠.", "confidence": 0.91, "locale": "ko-KR"},
            {"id": "3", "speaker": "remote", "start": 6.5, "end": 10.0, "text": "저는 그 다음 주가 좋습니다.", "confidence": 0.88, "locale": "ko-KR"},
        ]
        (session / "transcript.jsonl").write_text(
            "\n".join(json.dumps(line, ensure_ascii=False) for line in lines) + "\n",
            encoding="utf-8",
        )

        # AWS remote: 두 화자로 갈렸고, `배포`를 `대포`로 잘못 들었다.
        aws_remote = {
            "results": {
                "speaker_labels": {
                    "speakers": 2,
                    "segments": [
                        {"start_time": "2.4", "end_time": "6.1", "speaker_label": "spk_0"},
                        {"start_time": "6.4", "end_time": "10.1", "speaker_label": "spk_1"},
                    ],
                },
                "items": [
                    {"type": "pronunciation", "start_time": "2.5", "end_time": "3.0", "alternatives": [{"content": "네", "confidence": "0.9"}]},
                    {"type": "pronunciation", "start_time": "3.0", "end_time": "3.6", "alternatives": [{"content": "그럼", "confidence": "0.9"}]},
                    {"type": "pronunciation", "start_time": "3.6", "end_time": "4.4", "alternatives": [{"content": "대포", "confidence": "0.6"}]},
                    {"type": "pronunciation", "start_time": "4.4", "end_time": "5.0", "alternatives": [{"content": "일정은", "confidence": "0.9"}]},
                    {"type": "pronunciation", "start_time": "5.0", "end_time": "6.0", "alternatives": [{"content": "다음 주로 하죠", "confidence": "0.9"}]},
                    {"type": "pronunciation", "start_time": "6.5", "end_time": "10.0", "alternatives": [{"content": "저는 그 다음 주가 좋습니다", "confidence": "0.9"}]},
                ],
            }
        }
        (session / "aws-remote.json").write_text(
            json.dumps(aws_remote, ensure_ascii=False), encoding="utf-8"
        )
        return session

    def test_merge_splits_remote_into_two_speakers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            summary = merge(
                session=session,
                aws_paths={"remote": session / "aws-remote.json"},
                out_dir=session,
            )

            self.assertEqual(summary["sources"]["remote"]["aws_speakers"], 2)
            self.assertEqual(summary["sources"]["remote"]["assigned"], 2)

            records = [
                json.loads(line)
                for line in (session / "transcript.speakers.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()
            ]
            by_id = {r["id"]: r for r in records}

            # remote가 A/B로 갈렸다.
            self.assertEqual(by_id["2"]["speaker"], "Remote A")
            self.assertEqual(by_id["3"]["speaker"], "Remote B")
            # me는 손대지 않았다 — 마이크 입력의 화자는 이미 확정이다.
            self.assertEqual(by_id["1"]["speaker"], "Me")
            # 원래 소스가 남아 있어 추정 없는 2분리로 되돌릴 수 있다.
            self.assertEqual({r["source"] for r in records}, {"me", "remote"})

    def test_local_text_is_never_replaced_by_aws(self) -> None:
        """본문은 로컬 전사를 유지한다.

        AWS는 화자 경계를 얻으려고 부른 것이지 정답으로 부른 것이 아니다.
        온디바이스 전사가 이 회의의 언어로 돌아간 결과를 덮어쓰면, 픽스처의
        `배포`가 `대포`로 바뀌어 회의록이 나빠진다.
        """
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            merge(
                session=session,
                aws_paths={"remote": session / "aws-remote.json"},
                out_dir=session,
            )
            markdown = (session / "transcript.speakers.md").read_text(encoding="utf-8")
        self.assertIn("배포 일정", markdown)

    def test_word_diffs_are_listed_without_a_verdict(self) -> None:
        """차이는 목록으로 남고, 옳고 그름은 리포트가 정하지 않는다.

        리포트를 읽는 것은 이 스킬을 실행하는 에이전트다. 스크립트가 "이건
        오인식"이라고 단정해 버리면 그 판정이 틀렸을 때 되돌릴 근거가 없고,
        걸러낸 항목은 아예 보이지 않는다. 그래서 전량을 내놓고 판단을 넘긴다.
        """
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            summary = merge(
                session=session,
                aws_paths={"remote": session / "aws-remote.json"},
                out_dir=session,
            )
            report = (session / "diarization-report.md").read_text(encoding="utf-8")

        self.assertGreaterEqual(summary["word_diffs"], 1)
        # 다르게 적은 단어가 보인다.
        self.assertIn("대포", report)
        # 판단을 넘긴다는 것이 리포트에 적혀 있어야 읽는 쪽이 자기 일을 안다.
        self.assertIn("판단하지 않습니다", report)
        # 화자별 발화량이 있어야 A/B가 뒤집혔는지 판단할 수 있다.
        self.assertIn("발화 시간", report)

    def test_spacing_only_diff_is_kept_and_marked(self) -> None:
        """붙여쓰기 차이는 버리지 않고 표시만 한다.

        훑는 쪽이 무엇을 건너뛸지 바로 알아야 하고, 동시에 버려진 것이 없어야
        한다 — 예전 임계값 방식은 이 둘을 함께 만족하지 못했다.

        인접하지 않은 차이로 픽스처를 짠 이유는 difflib이 붙어 있는 치환을 한
        쌍으로 뭉치기 때문이다(실측: `배포 일정 은` vs `대포 일정은`은 한 건으로
        나온다). 두 쌍이 따로 잡히는지 보려면 사이에 일치하는 토큰이 있어야 한다.
        """
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "s"
            session.mkdir()
            # `일정 은`은 붙여쓰기만, `배포`는 뜻이 바뀐다. 사이에 `다음`이
            # 일치해 difflib이 두 구간으로 끊는다.
            (session / "transcript.jsonl").write_text(
                '{"id":"1","speaker":"remote","start":0,"end":6,'
                '"text":"배포 다음 주 일정 은 확정"}\n',
                encoding="utf-8",
            )
            words = [("대포", 0, 1), ("다음", 1, 2), ("주", 2, 3), ("일정은", 3, 4.5), ("확정", 4.5, 6)]
            (session / "aws.json").write_text(
                json.dumps(
                    {
                        "results": {
                            "speaker_labels": {
                                "speakers": 1,
                                "segments": [
                                    {"start_time": "0", "end_time": "6", "speaker_label": "spk_0"}
                                ],
                            },
                            "items": [
                                {
                                    "type": "pronunciation",
                                    "start_time": str(start),
                                    "end_time": str(end),
                                    "alternatives": [{"content": content}],
                                }
                                for content, start, end in words
                            ],
                        }
                    }
                ),
                encoding="utf-8",
            )
            summary = merge(
                session=session,
                aws_paths={"remote": session / "aws.json"},
                out_dir=session,
            )
            records = [
                json.loads(line)
                for line in (session / "transcript.speakers.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()
            ]

        # 둘 다 남았다 — 붙여쓰기 차이를 버리지 않았다.
        self.assertEqual(summary["word_diffs"], 2)
        self.assertEqual(summary["spacing_only_diffs"], 1)

        diffs = {d["local"]: d for d in records[0]["word_diffs"]}
        self.assertFalse(diffs["배포"]["spacing_only"])
        self.assertTrue(diffs["일정 은"]["spacing_only"])
        # 유사도도 함께 실려야 읽는 쪽이 판단 재료를 갖는다.
        self.assertIn("similarity", diffs["배포"])

    def test_adjacent_diffs_merge_but_stay_visible(self) -> None:
        """인접한 차이가 뭉쳐도 실제 차이를 숨기지 않는다.

        difflib이 붙어 있는 치환을 한 쌍으로 묶으므로 `배포`→`대포`와
        `일정 은`→`일정은`이 하나로 나온다. 뭉친 쌍은 `spacing_only`가 False가
        되어 확인 대상으로 남으므로, 안전한 방향으로 틀린다.
        """
        diffs = find_word_diffs("배포 일정 은 다음 주", "대포 일정은 다음 주")
        self.assertEqual(len(diffs), 1)
        self.assertFalse(diffs[0].spacing_only)
        self.assertIn("대포", diffs[0].aws)

    def test_original_transcript_is_untouched(self) -> None:
        """원본 JSONL은 절대 수정하지 않는다.

        원본은 오디오 경로가 보장한 사실이고 이 스크립트의 판정은 추정이다.
        사실을 추정으로 덮으면 틀렸을 때 되돌릴 근거가 사라진다.
        """
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            original = (session / "transcript.jsonl").read_bytes()
            merge(
                session=session,
                aws_paths={"remote": session / "aws-remote.json"},
                out_dir=session,
            )
            self.assertEqual((session / "transcript.jsonl").read_bytes(), original)

    def test_missing_transcript_raises_clear_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "empty"
            session.mkdir()
            with self.assertRaises(FileNotFoundError):
                merge(session=session, aws_paths={}, out_dir=session)

    def test_out_dir_can_differ_from_session(self) -> None:
        # 원본 디렉터리를 건드리지 않고 결과만 따로 받고 싶은 경우.
        with tempfile.TemporaryDirectory() as tmp:
            session = self.build_session(tmp)
            out = Path(tmp) / "out"
            merge(
                session=session,
                aws_paths={"remote": session / "aws-remote.json"},
                out_dir=out,
            )
            self.assertTrue((out / "transcript.speakers.md").exists())
            self.assertFalse((session / "transcript.speakers.md").exists())


class ReportTests(unittest.TestCase):
    def test_speaker_cap_reached_is_surfaced(self) -> None:
        """감지 화자 수가 요청 상한과 같으면 잘렸을 수 있다.

        조용히 넘기면 사용자는 감지된 수가 실제 참석자 수라고 믿는다.
        """
        with tempfile.TemporaryDirectory() as tmp:
            session = Path(tmp) / "s"
            session.mkdir()
            (session / "transcript.jsonl").write_text(
                '{"id":"1","speaker":"remote","start":0,"end":5,"text":"가"}\n'
                '{"id":"2","speaker":"remote","start":5,"end":10,"text":"나"}\n',
                encoding="utf-8",
            )
            (session / "aws.json").write_text(
                json.dumps(
                    {
                        "results": {
                            "speaker_labels": {
                                "speakers": 2,
                                "segments": [
                                    {"start_time": "0", "end_time": "5", "speaker_label": "spk_0"},
                                    {"start_time": "5", "end_time": "10", "speaker_label": "spk_1"},
                                ],
                            },
                            "items": [],
                        }
                    }
                ),
                encoding="utf-8",
            )
            summary = merge(
                session=session,
                aws_paths={"remote": session / "aws.json"},
                out_dir=session,
                max_speakers_hint=2,
            )
        self.assertEqual(summary["sources"]["remote"]["aws_speakers"], 2)

    def test_report_states_offset_applied(self) -> None:
        """적용한 오프셋을 리포트에 적는다 — 시간축이 밀렸다는 신호다."""
        local = [segment(0.0, 2.0)]
        local[0].aws_label = "spk_0"
        report = render_report(
            local,
            {"remote": (aws((0.0, 2.0, "spk_0")), 1.5)},
            {"remote": {"spk_0": "Remote A"}},
        )
        self.assertIn("+1.50초", report)
        self.assertIn("세션 경계", report)


if __name__ == "__main__":
    unittest.main(verbosity=2)
