#!/usr/bin/env python3
"""스트리밍 클라이언트 테스트. 네트워크와 AWS를 쓰지 않는다.

인코딩하는 실패:

1. WAVE 헤더 길이를 44로 가정하면 청크가 끼었을 때 잡음이 앞에 섞인다.
2. 스트리밍의 화자 라벨(`Speaker: "0"`)을 배치 표기(`spk_0`)로 바꾸지 않으면
   병합 쪽 이름 매핑이 어긋난다.
3. `IsPartial` 결과를 버리지 않으면 같은 말이 여러 번 들어간다.
4. `speaker-change` 항목을 단어로 취급하면 빈 텍스트가 전사에 섞인다.
5. 문장부호에 시각을 붙이면 배치 형식과 달라져 병합 쪽 대조가 깨진다.
"""

from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import stream_transcribe as st  # noqa: E402


def wave_file(extra_chunks: bytes = b"", data: bytes = b"\x01\x02\x03\x04") -> bytes:
    """WAVE 파일을 손으로 만든다. `extra_chunks`로 헤더 길이를 늘릴 수 있다."""
    fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
    body = (
        b"WAVE"
        + b"fmt "
        + struct.pack("<I", len(fmt))
        + fmt
        + extra_chunks
        + b"data"
        + struct.pack("<I", len(data))
        + data
    )
    return b"RIFF" + struct.pack("<I", len(body)) + body


def streaming_result(items: list[dict], is_partial: bool = False, start: float = 0.0) -> dict:
    return {
        "IsPartial": is_partial,
        "StartTime": start,
        "Alternatives": [{"Transcript": " ".join(i.get("Content", "") for i in items), "Items": items}],
    }


def word(content: str, start: float, end: float, speaker: str | None = None) -> dict:
    item: dict = {
        "Type": "pronunciation",
        "Content": content,
        "StartTime": start,
        "EndTime": end,
        "Confidence": 0.99,
    }
    if speaker is not None:
        item["Speaker"] = speaker
    return item


class WaveExtractionTests(unittest.TestCase):
    def test_extra_chunk_does_not_shift_the_audio(self) -> None:
        """헤더 길이를 44로 가정하면 안 된다.

        `afconvert`가 `LIST`나 `fact` 청크를 넣으면 그만큼 밀린다. 고정 길이로
        자르면 헤더 조각이 오디오로 해석돼 맨 앞에 잡음이 섞이는데, 전사 결과의
        첫 단어가 이상해지는 방식으로 나타나 원인을 찾기 어렵다.
        """
        plain = st.extract_wav_data(wave_file())
        with_list = st.extract_wav_data(
            wave_file(extra_chunks=b"LIST" + struct.pack("<I", 6) + b"INFOxx")
        )
        self.assertEqual(plain, with_list)
        self.assertEqual(plain, b"\x01\x02\x03\x04")

    def test_odd_sized_chunk_padding_is_skipped(self) -> None:
        """청크는 짝수 경계에 정렬되고 홀수면 패딩 1바이트가 붙는다."""
        odd = b"LIST" + struct.pack("<I", 3) + b"abc" + b"\x00"
        self.assertEqual(st.extract_wav_data(wave_file(extra_chunks=odd)), b"\x01\x02\x03\x04")

    def test_non_wave_input_is_rejected(self) -> None:
        with self.assertRaises(st.StreamError):
            st.extract_wav_data(b"not a wave file at all")

    def test_missing_data_chunk_is_rejected(self) -> None:
        fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
        body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt
        with self.assertRaises(st.StreamError):
            st.extract_wav_data(b"RIFF" + struct.pack("<I", len(body)) + body)


class BatchShapeTests(unittest.TestCase):
    def test_speaker_label_is_translated_to_batch_notation(self) -> None:
        """스트리밍은 `"0"`, 배치는 `spk_0`이다.

        병합 쪽이 라벨 문자열을 그대로 이름 매핑 키로 쓰므로, 표기를 맞추지 않으면
        같은 코드가 두 경로에서 다르게 동작한다.
        """
        shaped = st.to_batch_shape([streaming_result([word("hi", 0.0, 1.0, "0")])])
        segments = shaped["results"]["speaker_labels"]["segments"]  # type: ignore[index]
        self.assertEqual(segments[0]["speaker_label"], "spk_0")

    def test_consecutive_same_speaker_words_form_one_segment(self) -> None:
        """스트리밍에는 화자 구간 목록이 없어서 직접 만든다.

        단어마다 구간을 만들면 병합 쪽 겹침 계산이 조각난 구간과 대조하게 되어
        배정률이 떨어진다.
        """
        shaped = st.to_batch_shape(
            [
                streaming_result(
                    [
                        word("one", 0.0, 1.0, "0"),
                        word("two", 1.0, 2.0, "0"),
                        word("three", 2.0, 3.0, "1"),
                    ]
                )
            ]
        )
        segments = shaped["results"]["speaker_labels"]["segments"]  # type: ignore[index]
        self.assertEqual(len(segments), 2)
        self.assertEqual(segments[0]["speaker_label"], "spk_0")
        self.assertEqual(float(segments[0]["end_time"]), 2.0)
        self.assertEqual(segments[1]["speaker_label"], "spk_1")

    def test_speaker_change_marker_is_not_a_word(self) -> None:
        """`speaker-change`는 경계 표시일 뿐 내용이 없다.

        단어로 취급하면 빈 문자열이 전사와 항목 목록에 섞인다.
        """
        shaped = st.to_batch_shape(
            [
                streaming_result(
                    [
                        word("before", 0.0, 1.0, "0"),
                        {"Type": "speaker-change", "StartTime": 1.0, "EndTime": 1.0},
                        word("after", 1.2, 2.0, "1"),
                    ]
                )
            ]
        )
        items = shaped["results"]["items"]  # type: ignore[index]
        self.assertEqual(len(items), 2)
        self.assertEqual(
            [i["alternatives"][0]["content"] for i in items], ["before", "after"]
        )

    def test_punctuation_carries_no_timestamps(self) -> None:
        """배치 형식의 문장부호에는 시각이 없다.

        병합 쪽이 `type == "pronunciation"`만 대조에 쓰는데, 문장부호에 시각을
        붙이면 형식이 갈려 나중에 그 필터를 신뢰할 수 없게 된다.
        """
        shaped = st.to_batch_shape(
            [streaming_result([word("hi", 0.0, 1.0, "0"), {"Type": "punctuation", "Content": "."}])]
        )
        punctuation = shaped["results"]["items"][-1]  # type: ignore[index]
        self.assertEqual(punctuation["type"], "punctuation")
        self.assertNotIn("start_time", punctuation)

    def test_speaker_count_reflects_distinct_labels(self) -> None:
        shaped = st.to_batch_shape(
            [
                streaming_result(
                    [
                        word("a", 0.0, 1.0, "0"),
                        word("b", 1.0, 2.0, "1"),
                        word("c", 2.0, 3.0, "0"),
                    ]
                )
            ]
        )
        self.assertEqual(shaped["results"]["speaker_labels"]["speakers"], 2)  # type: ignore[index]

    def test_results_are_sorted_by_start_time(self) -> None:
        """도착 순서가 시간순이 아닐 수 있다.

        정렬하지 않으면 화자 구간이 뒤엉켜 병합 쪽 겹침 계산이 엉뚱한 발화를 짝짓는다.
        """
        late = streaming_result([word("late", 5.0, 6.0, "1")], start=5.0)
        early = streaming_result([word("early", 0.0, 1.0, "0")], start=0.0)
        shaped = st.to_batch_shape([late, early])
        contents = [
            i["alternatives"][0]["content"] for i in shaped["results"]["items"]  # type: ignore[index]
        ]
        self.assertEqual(contents, ["early", "late"])

    def test_words_without_speaker_still_appear(self) -> None:
        """화자 라벨이 없는 단어도 전사에는 남아야 한다.

        AWS가 라벨을 못 붙이는 구간이 있다. 그 단어를 버리면 회의록에서 말이
        사라지는데, 화자를 모르는 것보다 훨씬 나쁘다.
        """
        shaped = st.to_batch_shape([streaming_result([word("unlabeled", 0.0, 1.0)])])
        self.assertEqual(len(shaped["results"]["items"]), 1)  # type: ignore[index]
        self.assertEqual(shaped["results"]["speaker_labels"]["segments"], [])  # type: ignore[index]

    def test_empty_results_produce_valid_but_empty_output(self) -> None:
        """빈 결과가 병합 쪽을 깨뜨리지 않아야 한다."""
        shaped = st.to_batch_shape([])
        self.assertEqual(shaped["results"]["speaker_labels"]["speakers"], 0)  # type: ignore[index]
        self.assertEqual(shaped["results"]["items"], [])  # type: ignore[index]


class ChunkSizeTests(unittest.TestCase):
    def test_chunk_matches_the_declared_duration(self) -> None:
        """청크 크기가 샘플레이트·채널·비트폭과 맞아야 한다.

        어긋나면 서버가 오디오를 잘못된 속도로 해석해 전사가 전부 이상해진다 —
        오류 없이 결과만 나빠지는 실패다.
        """
        expected = (
            st.SAMPLE_RATE * st.CHANNELS * st.BYTES_PER_SAMPLE * st.CHUNK_MILLISECONDS // 1000
        )
        self.assertEqual(st.CHUNK_BYTES, expected)

    def test_chunk_duration_is_within_the_recommended_range(self) -> None:
        """AWS 권장은 50~200ms다. 벗어나면 스로틀링이나 지연이 생긴다."""
        self.assertGreaterEqual(st.CHUNK_MILLISECONDS, 50)
        self.assertLessEqual(st.CHUNK_MILLISECONDS, 200)

    def test_mono_16k_is_required_for_diarization(self) -> None:
        """채널 분리와 화자 분리는 동시에 쓸 수 없다 — 모노여야 한다."""
        self.assertEqual(st.CHANNELS, 1)
        self.assertEqual(st.SAMPLE_RATE, 16_000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
