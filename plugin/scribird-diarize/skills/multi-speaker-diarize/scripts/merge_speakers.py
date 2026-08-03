#!/usr/bin/env python3
"""로컬 전사에 AWS Transcribe diarization 결과를 겹쳐 화자를 세분화한다.

Scribird의 `transcript.jsonl`은 화자가 `me`/`remote` 두 개다. 오디오 경로가
화자를 확정하므로 이 2분리는 틀릴 수 없지만, `remote`는 회의 앱이 참석자를
믹스다운한 뒤의 스트림이라 여러 명이 한 라벨에 뭉쳐 있다. AWS Transcribe의
speaker partitioning으로 그 안의 화자 경계를 얻어 `상대방 A/B/...`로 쪼갠다.

원본 `transcript.jsonl`은 절대 수정하지 않는다 — 이 스크립트의 판정은 확률적
추정이고, 원본은 오디오 경로가 보장한 사실이다. 사실을 추정으로 덮어쓰면
잘못됐을 때 되돌릴 근거가 사라진다. 결과는 항상 새 파일로 나간다.

의존성은 Python 3 표준 라이브러리뿐이다. macOS의 /usr/bin/python3에서 그대로
돈다 — 스킬이 pip 설치를 요구하면 쓰이지 않기 때문이다.
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

# ── 시간 정렬 ────────────────────────────────────────────────────────────────

# 오프셋 자동 탐색 범위와 간격.
#
# 이론적으로 오프셋은 0이어야 한다. AnalyzerInputPump.submit은 같은 버퍼로
# 먼저 AudioRecorder에 원본을 쓰고 그 다음 framesSent를 올리므로, m4a의 첫
# 샘플과 transcript 시간축의 0이 같은 버퍼에서 시작한다.
#
# 그래도 탐색하는 이유는 세션 경계다. 세션을 회전하면 transcript는 wall-clock
# (Date 기준 boundary)으로 0을 다시 잡고 오디오는 프레임 기준으로 이어지므로,
# 두 시간축이 서로 조금 밀린다. 밀림을 모르고 병합하면 화자 라벨이 옆 발화로
# 옮겨 붙는다 — 라벨이 비어 있는 것보다 나쁜 결과다.
OFFSET_SEARCH_SECONDS = 5.0
OFFSET_SEARCH_STEP = 0.05

# 리포트 본문에 펼쳐 쓸 단어 차이의 최대 개수.
#
# 두 시간짜리 회의는 차이가 수백 건 나온다. 전부 펼치면 리포트를 읽을 수 없고
# 이 결과를 받는 에이전트의 컨텍스트도 잡아먹는다. 넘치는 분량은 JSONL에 온전히
# 남고, 리포트에는 몇 건을 접었는지 명시한다 — 조용히 자르면 "전부 봤다"로
# 읽히기 때문이다.
DIFF_REPORT_LIMIT = 60

# 이 비율 아래로 겹치면 화자를 배정하지 않는다.
#
# 겹침이 조금이라도 있으면 배정하는 편이 배정률 숫자는 좋아지지만, 발화 경계에
# 살짝 걸친 이웃 화자의 라벨을 가져오는 사고가 난다. 절반 이상 겹치는 화자만
# 그 발화의 주인으로 인정하고, 나머지는 미배정으로 남겨 사람이 보게 한다.
MIN_OVERLAP_RATIO = 0.5

# 문장 전체가 이 유사도 미만이면 **시간 정렬**을 의심한다.
#
# 이 판정은 이 스크립트가 해도 되는 종류다 — 두 구간을 짝지은 것이 이 스크립트이고,
# "내가 짝지은 두 구간이 서로 다른 발화인 것 같다"는 자기 작업에 대한 진단이다.
# 어느 쪽 단어가 옳은지와는 무관하다.
#
# 반대로 **단어 차이가 뜻을 바꾸는지는 판정하지 않는다.** 문자 유사도로는
# "같은 말의 다른 표기"와 "비슷하게 생긴 다른 말"을 원리적으로 구분할 수 없다.
# 실측: `care`/`car`는 0.86, `일정은`/`일정 은`도 0.86이다. 앞은 뜻이 바뀌고
# 뒤는 안 바뀌는데 숫자가 같으므로, 임계값을 어디에 두어도 한쪽이 틀린다.
#
# 그래서 이 스크립트는 차이를 측정해서 전부 내놓고, 무엇이 문제인지는 이 결과를
# 받는 에이전트가 의미를 보고 판단한다. 린터가 경고를 나열하고 무엇을 고칠지는
# 사람이 정하는 것과 같은 분담이다.
ALIGNMENT_SUSPECT_THRESHOLD = 0.75


def overlap_seconds(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    """두 구간이 겹치는 길이. 겹치지 않으면 0."""
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


# ── 입력 로딩 ────────────────────────────────────────────────────────────────


@dataclass
class WordDiff:
    """두 전사가 같은 자리에 다르게 적은 단어 쌍.

    `similarity`를 함께 담는 이유는 이 값을 판정에 쓰지 않고 **넘기기** 위해서다.
    0.86이 `care`/`car`(뜻이 바뀜)일 수도 `일정은`/`일정 은`(안 바뀜)일 수도
    있으므로, 숫자를 근거로 걸러내는 대신 숫자와 단어를 함께 보여주고 뜻을 아는
    쪽이 정하게 한다.
    """

    local: str
    aws: str
    similarity: float

    @property
    def spacing_only(self) -> bool:
        """공백을 지우면 같아지는가.

        이것만은 스크립트가 판정해도 안전하다 — 의미 판단이 아니라 문자열
        동일성이기 때문이다. `일정은` vs `일정 은`처럼 두 엔진이 어절을 다르게
        끊은 경우가 여기 걸리고, 이 사실을 표시해 두면 에이전트가 훑을 때
        의미를 따져볼 필요가 없다는 것을 바로 안다.
        """
        return self.local.replace(" ", "") == self.aws.replace(" ", "")


@dataclass
class LocalSegment:
    """`transcript.jsonl` 한 줄."""

    id: str
    speaker: str
    start: float
    end: float
    text: str
    confidence: float | None = None
    locale: str | None = None
    # 배정 결과. 병합 단계에서 채운다.
    aws_label: str | None = None
    overlap_ratio: float = 0.0
    aws_text: str | None = None
    similarity: float | None = None
    # 두 전사가 서로 다르게 적은 단어 쌍. 뜻이 바뀌는지 여부는 판정하지 않고
    # 측정값(유사도)만 함께 담아 그대로 넘긴다.
    word_diffs: list[WordDiff] = field(default_factory=list)

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)

    @property
    def has_diffs(self) -> bool:
        """두 전사가 다르게 적은 단어가 있는가.

        이름을 `is_mismatch`에서 바꾼 이유는 그 이름이 판정을 함축했기
        때문이다. 차이가 있다는 것은 관측이고, 그 차이가 문제인지는 뜻을 아는
        쪽이 정한다.
        """
        return bool(self.word_diffs)

    @property
    def alignment_suspect(self) -> bool:
        """짝지은 두 구간이 서로 다른 발화인 것 같은가.

        이건 정렬을 수행한 이 스크립트 자신에 대한 진단이므로 여기서 판정한다.
        단어 차이가 아주 많은데 문장 유사도까지 낮으면, 어느 단어가 옳은지의
        문제가 아니라 애초에 다른 구간을 비교했을 가능성이 크다.
        """
        return self.similarity is not None and self.similarity < ALIGNMENT_SUSPECT_THRESHOLD


@dataclass
class AwsSpeakerSegment:
    start: float
    end: float
    label: str


@dataclass
class AwsWord:
    start: float
    end: float
    content: str


@dataclass
class AwsResult:
    """AWS Transcribe 출력에서 병합에 필요한 부분만."""

    speaker_count: int
    segments: list[AwsSpeakerSegment]
    words: list[AwsWord]
    languages: list[str] = field(default_factory=list)


def load_local_segments(path: Path) -> list[LocalSegment]:
    """`transcript.jsonl`을 읽는다.

    JSONL은 발화당 한 줄을 즉시 append하는 형식이라, 크래시로 마지막 줄이
    잘려 있을 수 있다. 그 줄 하나 때문에 회의록 전체를 못 읽는 것은 손해가
    크므로, 깨진 줄은 경고만 남기고 건너뛴다.
    """
    segments: list[LocalSegment] = []
    with path.open(encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                print(
                    f"경고: {path.name} {lineno}번째 줄을 읽을 수 없어 건너뜁니다.",
                    file=sys.stderr,
                )
                continue
            segments.append(
                LocalSegment(
                    id=str(record.get("id", f"line-{lineno}")),
                    speaker=record.get("speaker", "unknown"),
                    start=float(record.get("start", 0.0)),
                    end=float(record.get("end", 0.0)),
                    text=record.get("text", ""),
                    confidence=record.get("confidence"),
                    locale=record.get("locale"),
                )
            )
    segments.sort(key=lambda s: s.start)
    return segments


def load_aws_result(path: Path) -> AwsResult:
    """Transcribe 출력 JSON에서 화자 구간과 단어를 뽑는다.

    `speaker_labels.segments[].items[]`는 시각과 라벨만 담고 텍스트가 없다.
    텍스트는 `results.items[]` 쪽에 있으므로 둘을 따로 읽어 시각으로 잇는다.
    """
    with path.open(encoding="utf-8") as handle:
        payload = json.load(handle)

    results = payload.get("results", {})
    labels = results.get("speaker_labels") or {}

    segments: list[AwsSpeakerSegment] = []
    for raw in labels.get("segments", []):
        try:
            segments.append(
                AwsSpeakerSegment(
                    start=float(raw["start_time"]),
                    end=float(raw["end_time"]),
                    label=raw["speaker_label"],
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    segments.sort(key=lambda s: s.start)

    words: list[AwsWord] = []
    for item in results.get("items", []):
        # 문장부호 항목에는 시각이 없다. 구간 대조에 쓸 수 없으므로 버린다.
        if item.get("type") != "pronunciation":
            continue
        alternatives = item.get("alternatives") or [{}]
        content = alternatives[0].get("content", "")
        try:
            words.append(
                AwsWord(
                    start=float(item["start_time"]),
                    end=float(item["end_time"]),
                    content=content,
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    words.sort(key=lambda w: w.start)

    languages = [
        entry.get("language_code", "")
        for entry in results.get("language_codes", [])
        if entry.get("language_code")
    ]

    declared = labels.get("speakers")
    speaker_count = (
        int(declared) if isinstance(declared, (int, float)) else len({s.label for s in segments})
    )

    return AwsResult(
        speaker_count=speaker_count,
        segments=segments,
        words=words,
        languages=languages,
    )


# ── 오프셋 탐색 ──────────────────────────────────────────────────────────────


def total_overlap(
    local: list[LocalSegment], aws_segments: list[AwsSpeakerSegment], offset: float
) -> float:
    """AWS 구간을 offset만큼 밀었을 때 로컬 발화와 겹치는 총 길이."""
    total = 0.0
    for segment in local:
        for aws in aws_segments:
            total += overlap_seconds(
                segment.start, segment.end, aws.start + offset, aws.end + offset
            )
    return total


def find_best_offset(
    local: list[LocalSegment],
    aws_segments: list[AwsSpeakerSegment],
    search: float = OFFSET_SEARCH_SECONDS,
    step: float = OFFSET_SEARCH_STEP,
) -> tuple[float, float]:
    """겹침 총량을 최대로 만드는 오프셋을 찾는다.

    - Returns: (오프셋, 그때의 겹침 총량). 후보가 없으면 (0.0, 0.0).

    동률일 때 0에 가까운 쪽을 고른다. 시간축이 이미 맞아 있다는 것이 기본
    가정이므로, 근거 없이 밀어 두면 이후 진단이 엉뚱한 곳을 보게 된다.
    """
    if not local or not aws_segments:
        return 0.0, 0.0

    steps = int(round(search / step))
    best_offset = 0.0
    best_score = total_overlap(local, aws_segments, 0.0)
    for index in range(-steps, steps + 1):
        offset = round(index * step, 4)
        if offset == 0.0:
            continue
        score = total_overlap(local, aws_segments, offset)
        # 동률은 갱신하지 않는다 — 먼저 자리를 잡은 0에 가까운 후보가 남는다.
        if score > best_score:
            best_score = score
            best_offset = offset
    return best_offset, best_score


# ── 화자 배정 ────────────────────────────────────────────────────────────────


def assign_speakers(
    local: list[LocalSegment],
    aws: AwsResult,
    offset: float = 0.0,
    min_overlap_ratio: float = MIN_OVERLAP_RATIO,
) -> None:
    """각 로컬 발화에 가장 많이 겹치는 AWS 화자 라벨을 붙인다 (제자리 수정).

    발화 길이에 대한 겹침 비율로 판정한다. 절대 겹침 길이로 판정하면 긴 AWS
    구간이 짧은 발화를 늘 이기므로, 실제 주인이 아닌 화자가 배정된다.
    """
    for segment in local:
        if segment.duration <= 0:
            continue
        best_label: str | None = None
        best_overlap = 0.0
        for candidate in aws.segments:
            shared = overlap_seconds(
                segment.start, segment.end, candidate.start + offset, candidate.end + offset
            )
            if shared > best_overlap:
                best_overlap = shared
                best_label = candidate.label
        ratio = best_overlap / segment.duration
        if best_label is not None and ratio >= min_overlap_ratio:
            segment.aws_label = best_label
            segment.overlap_ratio = ratio
        else:
            # 근거가 약하면 라벨을 비워 둔다. 원래의 me/remote 라벨은 그대로
            # 남으므로 정보가 줄지는 않는다.
            segment.aws_label = None
            segment.overlap_ratio = ratio


def name_speakers(source: str, local: list[LocalSegment]) -> dict[str, str]:
    """AWS의 `spk_0`을 사람이 읽는 이름으로 바꾼다.

    `spk_N`의 번호는 등장 순서일 뿐 의미가 없어서, 그대로 회의록에 쓰면 읽는
    사람이 매번 누구인지 되짚어야 한다.

    소스에 따라 이름 규칙이 다른 이유는 두 소스의 성질이 다르기 때문이다.

    - `remote`: 시스템 출력이므로 전원이 원격 참석자다. 발화량이 많은 순서로
      `상대방 A`, `상대방 B`를 준다. 회의에서는 보통 주 발언자가 먼저 눈에
      들어와야 한다.
    - `me`: 마이크 입력이므로 이 기기 사용자가 주인이다. 발화량이 가장 많은
      화자를 `나`로 두고, 남는 화자는 `대면 참석자 B`로 부른다. 이는
      "상대방이 내 마이크로 함께 들어오는 대면 회의"에서만 생기는 경우이고,
      그때도 기기 주인이 최대 발화자라는 전제에 기댄다. 전제가 깨지는
      배치(내가 거의 듣고만 있는 회의)에서는 라벨이 뒤집히므로, 리포트에
      화자별 발화량을 함께 적어 사람이 검증할 수 있게 한다.
    """
    duration_by_label: dict[str, float] = {}
    for segment in local:
        if segment.aws_label is None:
            continue
        duration_by_label[segment.aws_label] = (
            duration_by_label.get(segment.aws_label, 0.0) + segment.duration
        )

    ordered = sorted(duration_by_label.items(), key=lambda item: (-item[1], item[0]))
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    names: dict[str, str] = {}

    for index, (label, _) in enumerate(ordered):
        if source == "me":
            names[label] = "나" if index == 0 else f"대면 참석자 {alphabet[index % 26]}"
        else:
            names[label] = f"상대방 {alphabet[index % 26]}"
    return names


# ── 텍스트 대조 ──────────────────────────────────────────────────────────────

_PUNCTUATION = re.compile(r"[^\w\s]", re.UNICODE)
_WHITESPACE = re.compile(r"\s+")


def normalize_text(text: str) -> str:
    """표기 차이를 걷어내고 비교 가능한 형태로 만든다.

    한글은 NFC로 모은다. macOS 파일시스템과 일부 도구가 자모를 분리(NFD)해
    내보내는데, 그러면 눈에 같은 글자가 코드포인트 수준에서 달라 유사도가
    엉뚱하게 낮아진다.

    문장부호와 공백을 지우는 이유는 두 엔진의 차이 대부분이 여기서 나오기
    때문이다 — 로컬이 `안녕하세요.`, AWS가 `안녕하세요`로 적는 것은 사람에게
    같은 말이다. 대소문자도 접어 영어 구간의 차이를 줄인다.
    """
    folded = unicodedata.normalize("NFC", text).lower()
    folded = _PUNCTUATION.sub("", folded)
    return _WHITESPACE.sub("", folded).strip()


def normalize_words(text: str) -> list[str]:
    """단어 단위 비교용 토큰. 문장부호를 떼고 공백으로 나눈다.

    `normalize_text`와 달리 공백을 남긴다 — 단어 경계가 비교의 단위이기
    때문이다. 한국어는 조사가 붙어 어절이 곧 단어는 아니지만, 두 엔진이
    같은 어절을 다르게 들었는지 보는 데는 어절이 충분한 단위다.
    """
    folded = unicodedata.normalize("NFC", text).lower()
    folded = _PUNCTUATION.sub(" ", folded)
    return [token for token in _WHITESPACE.split(folded) if token]


def find_word_diffs(local_text: str, aws_text: str) -> list[WordDiff]:
    """두 전사가 같은 자리에 다르게 적은 단어 쌍을 **전부** 찾는다.

    치환(replace)만 본다. 삽입·삭제는 무시하는데, 두 엔진의 발화 경계가
    조금씩 달라 한쪽 구간에 이웃 단어가 하나 더 들어오는 일이 흔하고, 그건
    "다르게 적었다"가 아니라 "구간이 조금 다르다"이기 때문이다.

    **유사도로 걸러내지 않는다.** 예전에는 0.8을 문턱으로 두고 그 위를 "같은
    말의 표기 차이"로 버렸는데, 실측해 보니 그 문턱이 뜻을 가르지 못했다 —
    `care`/`car`(뜻이 바뀜)와 `일정은`/`일정 은`(안 바뀜)이 똑같이 0.86이다.
    임계값을 올리면 표기 차이가 쏟아지고 내리면 진짜 오인식이 조용히 사라지는데,
    후자가 훨씬 위험하다. 회의록의 `배포`가 `대포`로 남는 것을 아무도 모르게
    되기 때문이다.

    그래서 전부 내놓고, 각 쌍에 유사도와 `spacing_only`를 붙여 훑는 쪽이
    판단할 재료를 준다.

    **인접한 차이는 한 쌍으로 뭉친다.** difflib이 붙어 있는 치환 구간을 하나로
    묶기 때문이다 — 실측: `배포 일정 은` vs `대포 일정은`은 두 건이 아니라
    `배포 일정 은` → `대포 일정은` 한 건으로 나온다. 두 엔진이 어절을 다르게
    끊으면 토큰 경계가 밀려 이런 뭉침이 자주 생긴다.

    이 동작을 그대로 두는 이유는 안전한 방향으로 틀리기 때문이다. 뭉친 쌍은
    공백을 지워도 같아지지 않으므로 `spacing_only`가 False가 되고, 결국 "확인
    대상"으로 남는다. 실제 차이를 숨기는 방향으로는 틀리지 않는다. 뭉침이
    커지지도 않는다 — 사이에 일치하는 토큰이 하나라도 있으면 difflib이 구간을
    끊는다.
    """
    local_words = normalize_words(local_text)
    aws_words = normalize_words(aws_text)
    if not local_words or not aws_words:
        return []

    diffs: list[WordDiff] = []
    matcher = difflib.SequenceMatcher(None, local_words, aws_words)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "replace":
            continue
        left = " ".join(local_words[i1:i2])
        right = " ".join(aws_words[j1:j2])
        diffs.append(
            WordDiff(
                local=left,
                aws=right,
                similarity=difflib.SequenceMatcher(
                    None, left.replace(" ", ""), right.replace(" ", "")
                ).ratio(),
            )
        )
    return diffs


def aws_text_for_range(words: list[AwsWord], start: float, end: float, offset: float = 0.0) -> str:
    """구간에 걸치는 AWS 단어를 이어 붙인다.

    단어의 절반 이상이 구간 안에 들어올 때만 포함한다. 경계에 스친 단어까지
    가져오면 이웃 발화의 끝말이 섞여 들어와, 실제로는 일치하는 문장을
    불일치로 신고하게 된다.
    """
    picked: list[str] = []
    for word in words:
        word_start = word.start + offset
        word_end = word.end + offset
        span = max(1e-6, word_end - word_start)
        if overlap_seconds(start, end, word_start, word_end) / span >= 0.5:
            picked.append(word.content)
    return " ".join(picked)


def compare_text(local_text: str, aws_text: str) -> float | None:
    """두 전사의 유사도(0.0~1.0). 비교할 수 없으면 None.

    AWS 쪽이 빈 문자열이면 유사도를 내지 않는다. 그 구간에 AWS 단어가 없다는
    것은 "다르게 들었다"가 아니라 "대조할 근거가 없다"는 뜻이고, 둘을 같은
    0.0으로 뭉치면 리포트가 거짓 불일치로 넘친다.
    """
    normalized_local = normalize_text(local_text)
    normalized_aws = normalize_text(aws_text)
    if not normalized_local or not normalized_aws:
        return None
    return difflib.SequenceMatcher(None, normalized_local, normalized_aws).ratio()


def annotate_text_comparison(local: list[LocalSegment], aws: AwsResult, offset: float = 0.0) -> None:
    """각 발화에 대응하는 AWS 텍스트·유사도·단어 차이를 채운다 (제자리 수정)."""
    for segment in local:
        segment.aws_text = aws_text_for_range(aws.words, segment.start, segment.end, offset)
        segment.similarity = compare_text(segment.text, segment.aws_text)
        # 대조할 근거가 없는 구간에서는 단어 차이도 내지 않는다. AWS가 그
        # 구간을 듣지 못한 것을 "전부 다르게 들었다"로 보고하면 안 된다.
        segment.word_diffs = (
            find_word_diffs(segment.text, segment.aws_text) if segment.similarity is not None else []
        )


# ── 출력 ─────────────────────────────────────────────────────────────────────


def format_timecode(seconds: float) -> str:
    """`00:01:23` 형태. transcript.md와 같은 표기를 쓴다."""
    total = int(max(0.0, seconds))
    return f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"


def display_name(segment: LocalSegment, names: dict[str, dict[str, str]]) -> str:
    """세분화된 이름. 배정에 실패했으면 원래 라벨로 되돌린다."""
    fallback = {"me": "나", "remote": "상대방"}.get(segment.speaker, segment.speaker)
    if segment.aws_label is None:
        return fallback
    return names.get(segment.speaker, {}).get(segment.aws_label, fallback)


def write_jsonl(path: Path, local: list[LocalSegment], names: dict[str, dict[str, str]]) -> None:
    """재라벨된 세그먼트를 JSONL로 쓴다.

    원본 필드를 모두 남기고 판정 결과를 덧붙인다. `source`에 원래의
    `me`/`remote`가 그대로 남으므로, 이 파일만 있어도 추정 없이 확정된
    2분리로 되돌릴 수 있다.
    """
    with path.open("w", encoding="utf-8") as handle:
        for segment in local:
            record = {
                "id": segment.id,
                "source": segment.speaker,
                "speaker": display_name(segment, names),
                "aws_label": segment.aws_label,
                "overlap_ratio": round(segment.overlap_ratio, 3),
                "start": segment.start,
                "end": segment.end,
                "text": segment.text,
                "confidence": segment.confidence,
                "locale": segment.locale,
                "aws_text": segment.aws_text,
                "text_similarity": (
                    round(segment.similarity, 3) if segment.similarity is not None else None
                ),
                # 걸러내지 않은 전량. 유사도와 `spacing_only`를 함께 담아,
                # 이 파일을 읽는 쪽이 자기 기준으로 훑을 수 있게 한다.
                "word_diffs": [
                    {
                        "local": diff.local,
                        "aws": diff.aws,
                        "similarity": round(diff.similarity, 3),
                        "spacing_only": diff.spacing_only,
                    }
                    for diff in segment.word_diffs
                ],
                "alignment_suspect": segment.alignment_suspect,
            }
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def render_markdown(local: list[LocalSegment], names: dict[str, dict[str, str]], title: str) -> str:
    """사람이 읽는 회의록. 화자가 바뀔 때 단락을 끊는다.

    불일치 구간에는 AWS가 들은 문장을 각주로 붙인다. 텍스트 자체는 로컬을
    유지한다 — 온디바이스 전사가 이 회의의 언어에 맞춰 돌아간 결과이고, AWS는
    화자 경계를 얻으려고 부른 것이지 정답으로 부른 것이 아니다.
    """
    lines = [f"# {title}", ""]
    lines.append(
        "화자 세분화: AWS Transcribe speaker partitioning 결과를 겹쳐 붙였습니다. "
        "`나`/`상대방` 2분리는 오디오 경로가 확정한 사실이고, 그 안의 A/B 구분은 추정입니다."
    )
    lines.append("")

    current: str | None = None
    buffer: list[str] = []
    footnotes: list[str] = []
    block_start = 0.0

    def flush() -> None:
        nonlocal buffer, footnotes
        if current is None or not buffer:
            return
        lines.append(f"**{current}** `{format_timecode(block_start)}`")
        lines.append("")
        lines.append(" ".join(buffer))
        if footnotes:
            lines.append("")
            lines.extend(footnotes)
        lines.append("")
        buffer = []
        footnotes = []

    for segment in local:
        name = display_name(segment, names)
        if name != current:
            flush()
            current = name
            block_start = segment.start
        buffer.append(segment.text.strip())

        # 회의록 각주에는 붙여쓰기만 다른 쌍을 넣지 않는다. 이건 의미 판단이
        # 아니라 문자열 동일성이므로 안전하게 걸러도 되고, 읽는 흐름을 끊을
        # 이유가 없다. 걸러낸 것도 JSONL과 리포트에는 남는다.
        notable = [d for d in segment.word_diffs if not d.spacing_only]
        if notable:
            pairs = ", ".join(f"`{d.local}` → `{d.aws}`" for d in notable)
            footnotes.append(
                f"> ⚠ `{format_timecode(segment.start)}` AWS는 {pairs} 로 적었습니다"
            )
        elif segment.alignment_suspect:
            # 다른 구간을 비교했을 가능성. 단어 쌍을 나열해 봐야 의미가 없으므로
            # 문장을 통째로 보여주고 정렬을 의심하게 한다.
            measured = (
                f"문장 유사도 {segment.similarity:.2f}"
                if segment.similarity is not None
                else "유사도를 낼 수 없음"
            )
            footnotes.append(
                f"> ⚠ `{format_timecode(segment.start)}` AWS는 "
                f'"{segment.aws_text}" 로 적었습니다 '
                f"({measured} — 구간 정렬을 확인하세요)"
            )
    flush()

    return "\n".join(lines)


SOURCE_LABELS = {"me": "me (마이크 = 나)", "remote": "remote (시스템 출력 = 상대방)"}


def _render_source_section(
    source: str,
    aws: AwsResult,
    offset: float,
    segments: list[LocalSegment],
    names: dict[str, dict[str, str]],
) -> list[str]:
    """소스 하나의 배정 결과.

    화자별 발화량을 굳이 적는 이유는 이름 규칙이 발화량 순서에 기대기 때문이다.
    읽는 쪽이 이 표를 보고 A와 B가 뒤집혔는지 바로 판단할 수 있어야 한다.
    """
    assigned = [s for s in segments if s.aws_label is not None]
    label = SOURCE_LABELS.get(source, source)

    lines = [f"## {label}", ""]
    lines.append(f"- AWS가 감지한 화자 수: **{aws.speaker_count}**")
    lines.append(
        f"- 화자 배정: {len(assigned)}/{len(segments)} 발화"
        + (f" ({len(assigned) / len(segments) * 100:.0f}%)" if segments else "")
    )
    lines.append(
        f"- 적용한 시간 오프셋: **{offset:+.2f}초**"
        + ("" if abs(offset) < 0.1 else " — 세션 경계에서 시간축이 밀린 흔적입니다")
    )
    if aws.languages:
        lines.append(f"- AWS가 감지한 언어: {', '.join(aws.languages)}")
    lines.append("")

    stats: dict[str, tuple[float, int]] = {}
    for segment in assigned:
        name = display_name(segment, names)
        duration, count = stats.get(name, (0.0, 0))
        stats[name] = (duration + segment.duration, count + 1)
    if stats:
        lines.append("| 화자 | 발화 시간 | 발화 수 |")
        lines.append("|---|---:|---:|")
        for name, (duration, count) in sorted(stats.items(), key=lambda i: -i[1][0]):
            lines.append(f"| {name} | {duration:.1f}초 | {count} |")
        lines.append("")

    unassigned = [s for s in segments if s.aws_label is None]
    if unassigned:
        lines.append(
            f"미배정 {len(unassigned)}건 — 겹침이 {MIN_OVERLAP_RATIO:.0%}에 못 미쳐 "
            f"원래 라벨(`{source}`)을 유지했습니다."
        )
        lines.append("")
        for segment in unassigned[:DIFF_REPORT_LIMIT]:
            lines.append(
                f"- `{format_timecode(segment.start)}` 겹침 "
                f"{segment.overlap_ratio:.0%} — {segment.text.strip()[:40]}"
            )
        if len(unassigned) > DIFF_REPORT_LIMIT:
            lines.append(f"- … 그 외 {len(unassigned) - DIFF_REPORT_LIMIT}건")
        lines.append("")
    return lines


def _render_alignment_suspects(
    local: list[LocalSegment], names: dict[str, dict[str, str]]
) -> list[str]:
    """정렬 의심 구간.

    단어 차이보다 **먼저** 나온다. 애초에 다른 발화를 비교했다면 그 구간의 단어
    쌍은 전부 무의미하므로, 읽는 쪽이 시간을 버리기 전에 알아야 한다.
    """
    suspects = [s for s in local if s.alignment_suspect]
    if not suspects:
        return []

    lines = ["## 정렬 의심 구간", ""]
    lines.append(
        f"{len(suspects)}건 — 짝지은 두 구간의 문장 유사도가 "
        f"{ALIGNMENT_SUSPECT_THRESHOLD:.2f} 아래입니다. 단어를 다르게 적은 것이 아니라 "
        "서로 다른 발화를 비교했을 가능성이 있으니, 이 구간의 단어 차이는 신뢰하지 "
        "마세요. 위의 시간 오프셋을 함께 확인하세요."
    )
    lines.append("")
    for segment in suspects[:DIFF_REPORT_LIMIT]:
        similarity = f"{segment.similarity:.2f}" if segment.similarity is not None else "—"
        lines.append(
            f"### `{format_timecode(segment.start)}` "
            f"{display_name(segment, names)} (유사도 {similarity})"
        )
        lines.append("")
        lines.append(f"- 로컬: {segment.text.strip()}")
        lines.append(f"- AWS: {segment.aws_text}")
        lines.append("")
    return lines


def _render_word_diffs(local: list[LocalSegment], names: dict[str, dict[str, str]]) -> list[str]:
    """단어 차이 전량. 이 리포트의 본론이다.

    판정하지 않는다는 말을 여기 적는 이유는, 이 표를 읽는 쪽이 자기 일이 무엇인지
    알아야 하기 때문이다. 표만 있으면 이미 걸러진 목록으로 오해한다.
    """
    total = sum(len(s.word_diffs) for s in local)
    lines = ["## 두 전사가 다르게 적은 단어", ""]
    if not total:
        lines.append("두 전사가 같은 단어를 썼습니다.")
        return lines

    with_diffs = sum(1 for s in local if s.has_diffs)
    spacing_only = sum(1 for s in local for d in s.word_diffs if d.spacing_only)
    lines.append(
        f"{with_diffs}개 발화에서 {total}건입니다"
        + (f" (그 중 {spacing_only}건은 붙여쓰기만 다릅니다)" if spacing_only else "")
        + "."
    )
    lines.append("")
    lines.append(
        "**이 목록은 걸러내지 않은 전량입니다.** 어느 쪽이 옳은지, 그 차이가 뜻을 "
        "바꾸는지는 이 스크립트가 판단하지 않습니다. 문자 유사도로는 가릴 수 없기 "
        "때문입니다 — 실측으로 뜻이 바뀌는 `care`/`car`가 0.86인데, 뜻이 보존되는 "
        "`ok`/`okay`는 0.67로 그보다 **낮습니다**. 그래서 유사도 열은 참고용일 뿐이고, "
        "단어 자체를 보고 판단하세요. 회의록 본문은 로컬(온디바이스) 전사를 그대로 "
        "두었으니, 고칠 것이 있으면 원본 오디오의 해당 시각을 들어 확인하면 됩니다."
    )
    lines.append("")
    lines.append("| 시각 | 화자 | 로컬 | AWS | 유사도 | 붙여쓰기만 |")
    lines.append("|---|---|---|---|---:|:---:|")

    shown = 0
    for segment in local:
        for diff in segment.word_diffs:
            if shown >= DIFF_REPORT_LIMIT:
                break
            lines.append(
                f"| `{format_timecode(segment.start)}` "
                f"| {display_name(segment, names)} "
                f"| {diff.local} | {diff.aws} "
                f"| {diff.similarity:.2f} "
                f"| {'예' if diff.spacing_only else ''} |"
            )
            shown += 1
        if shown >= DIFF_REPORT_LIMIT:
            break
    lines.append("")

    if total > shown:
        # 무엇을 접었는지 밝힌다. 조용히 자르면 이 표가 전량이라고 읽힌다.
        lines.append(
            f"위는 앞 {shown}건입니다. 남은 {total - shown}건은 "
            "`transcript.speakers.jsonl`의 `word_diffs`에 전부 들어 있습니다."
        )
        lines.append("")
    return lines


def render_report(
    local: list[LocalSegment],
    per_source: dict[str, tuple[AwsResult, float]],
    names: dict[str, dict[str, str]],
) -> str:
    """검증용 리포트. 소스별 배정 → 정렬 의심 → 단어 차이 순서로 담는다.

    이 순서는 읽는 쪽의 판단 순서와 같다. 정렬이 깨졌다면 단어 차이를 볼 필요가
    없고, 화자 배정이 엉망이면 어느 화자의 말인지부터 다시 봐야 한다.
    """
    lines = ["# 화자 세분화 리포트", ""]
    for source, (aws, offset) in sorted(per_source.items()):
        lines += _render_source_section(
            source, aws, offset, [s for s in local if s.speaker == source], names
        )
    lines += _render_alignment_suspects(local, names)
    lines += _render_word_diffs(local, names)
    return "\n".join(lines)


# ── 엔트리 포인트 ────────────────────────────────────────────────────────────


def merge(
    session: Path,
    aws_paths: dict[str, Path],
    out_dir: Path,
    offsets: dict[str, float] | None = None,
    auto_offset: bool = True,
    max_speakers_hint: int | None = None,
) -> dict[str, object]:
    """세션 하나를 병합한다.

    - Parameter aws_paths: 소스(`me`/`remote`) → Transcribe 출력 JSON 경로.
    - Parameter offsets: 소스별 수동 오프셋. 주어지면 자동 탐색을 건너뛴다.
    - Returns: 요약 dict. 호출한 스킬이 사용자에게 보고할 숫자들.
    """
    jsonl = session / "transcript.jsonl"
    if not jsonl.exists():
        raise FileNotFoundError(f"전사 파일이 없습니다: {jsonl}")

    local = load_local_segments(jsonl)
    if not local:
        raise ValueError(f"{jsonl}에 발화가 없습니다.")

    offsets = dict(offsets or {})
    per_source: dict[str, tuple[AwsResult, float]] = {}
    names: dict[str, dict[str, str]] = {}

    for source, path in aws_paths.items():
        aws = load_aws_result(path)
        subset = [s for s in local if s.speaker == source]
        if not subset:
            print(
                f"경고: {source} 발화가 전사에 없어 {path.name}을 건너뜁니다.",
                file=sys.stderr,
            )
            continue

        if source in offsets:
            offset = offsets[source]
        elif auto_offset:
            offset, _ = find_best_offset(subset, aws.segments)
        else:
            offset = 0.0

        assign_speakers(subset, aws, offset)
        annotate_text_comparison(subset, aws, offset)
        names[source] = name_speakers(source, subset)
        per_source[source] = (aws, offset)

    out_dir.mkdir(parents=True, exist_ok=True)
    jsonl_out = out_dir / "transcript.speakers.jsonl"
    md_out = out_dir / "transcript.speakers.md"
    report_out = out_dir / "diarization-report.md"

    write_jsonl(jsonl_out, local, names)
    md_out.write_text(
        render_markdown(local, names, f"회의록 (화자 세분화) — {session.name}"),
        encoding="utf-8",
    )
    report_out.write_text(render_report(local, per_source, names), encoding="utf-8")

    return build_summary(
        session=session,
        local=local,
        per_source=per_source,
        names=names,
        outputs=[jsonl_out, md_out, report_out],
        max_speakers_hint=max_speakers_hint,
    )


def build_summary(
    session: Path,
    local: list[LocalSegment],
    per_source: dict[str, tuple[AwsResult, float]],
    names: dict[str, dict[str, str]],
    outputs: list[Path],
    max_speakers_hint: int | None = None,
) -> dict[str, object]:
    """호출한 쪽이 보고할 숫자들.

    여기 담는 값은 모두 **관측값**이다. `word_diffs`는 걸러내지 않은 전량이고
    `spacing_only_diffs`는 그 중 문자열 동일성만으로 안전하게 가릴 수 있는
    몫이다. 뜻이 바뀌는 차이가 몇 건인지는 이 스크립트가 셀 수 없으므로 넣지
    않는다 — 넣으면 그 숫자를 받은 쪽이 판단을 건너뛴다.
    """
    sources: dict[str, object] = {}
    for source, (aws, offset) in per_source.items():
        subset = [s for s in local if s.speaker == source]
        sources[source] = {
            "aws_speakers": aws.speaker_count,
            "assigned": sum(1 for s in subset if s.aws_label is not None),
            "total": len(subset),
            "offset": round(offset, 3),
            "names": names.get(source, {}),
        }
        # 상한에 걸렸다면 참석자가 더 있는데 잘렸을 수 있다. 조용히 넘기면
        # 사용자는 감지된 수가 실제 수라고 믿는다.
        if max_speakers_hint and aws.speaker_count >= max_speakers_hint:
            print(
                f"참고: {source}의 감지 화자 수({aws.speaker_count})가 요청 상한"
                f"({max_speakers_hint})과 같습니다. 참석자가 더 있었다면 상한을 올려 다시 돌리세요.",
                file=sys.stderr,
            )

    return {
        "session": str(session),
        "outputs": [str(path) for path in outputs],
        "segments": len(local),
        "word_diffs": sum(len(s.word_diffs) for s in local),
        "spacing_only_diffs": sum(1 for s in local for d in s.word_diffs if d.spacing_only),
        "alignment_suspects": sum(1 for s in local if s.alignment_suspect),
        "sources": sources,
    }


def print_summary(summary: dict[str, object]) -> None:
    """사람이 읽는 요약. 다음에 무엇을 해야 하는지까지 알린다.

    숫자만 찍으면 이 스크립트를 실행한 에이전트가 "끝났다"로 읽는다. 단어 차이는
    아직 판단이 남은 항목이므로, 몇 건이 확인 대상인지 함께 말해 준다.
    """
    print(f"발화 {summary['segments']}건을 병합했습니다.")
    sources: dict[str, dict[str, object]] = summary["sources"]  # type: ignore[assignment]
    for source, info in sources.items():
        print(
            f"  {source}: 화자 {info['aws_speakers']}명, "
            f"배정 {info['assigned']}/{info['total']}, 오프셋 {info['offset']:+.2f}초"
        )
        for label, name in info["names"].items():  # type: ignore[union-attr]
            print(f"    {label} → {name}")

    diffs: int = summary["word_diffs"]  # type: ignore[assignment]
    spacing: int = summary["spacing_only_diffs"]  # type: ignore[assignment]
    print(
        f"단어 차이 {diffs}건 — 붙여쓰기만 다른 {spacing}건을 빼면 "
        f"{diffs - spacing}건이 뜻을 확인할 대상입니다."
    )
    if summary["alignment_suspects"]:
        print(
            f"정렬 의심 {summary['alignment_suspects']}건 — 그 구간의 단어 차이는 믿지 마세요."
        )
    for path in summary["outputs"]:  # type: ignore[union-attr]
        print(f"  → {path}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Scribird 전사에 AWS Transcribe 화자 분리 결과를 병합한다."
    )
    parser.add_argument(
        "--session", required=True, type=Path, help="세션 디렉터리 (transcript.jsonl이 있는 곳)"
    )
    parser.add_argument("--aws-remote", type=Path, help="remote.m4a의 Transcribe 출력 JSON")
    parser.add_argument("--aws-me", type=Path, help="me.m4a의 Transcribe 출력 JSON")
    parser.add_argument(
        "--out", type=Path, help="결과를 쓸 디렉터리 (기본: 세션 디렉터리)"
    )
    parser.add_argument(
        "--offset-remote", type=float, help="remote 시간 오프셋을 직접 지정 (자동 탐색 생략)"
    )
    parser.add_argument(
        "--offset-me", type=float, help="me 시간 오프셋을 직접 지정 (자동 탐색 생략)"
    )
    parser.add_argument(
        "--no-auto-offset",
        action="store_true",
        help="오프셋 자동 탐색을 끄고 0으로 둔다",
    )
    parser.add_argument(
        "--max-speakers", type=int, help="Transcribe에 요청한 화자 상한 (상한 도달 경고용)"
    )
    parser.add_argument("--json", action="store_true", help="요약을 JSON으로 출력")
    args = parser.parse_args(argv)

    aws_paths: dict[str, Path] = {}
    if args.aws_remote:
        aws_paths["remote"] = args.aws_remote
    if args.aws_me:
        aws_paths["me"] = args.aws_me
    if not aws_paths:
        parser.error("--aws-remote 또는 --aws-me 중 하나는 필요합니다.")

    offsets: dict[str, float] = {}
    if args.offset_remote is not None:
        offsets["remote"] = args.offset_remote
    if args.offset_me is not None:
        offsets["me"] = args.offset_me

    try:
        summary = merge(
            session=args.session,
            aws_paths=aws_paths,
            out_dir=args.out or args.session,
            offsets=offsets,
            auto_offset=not args.no_auto_offset,
            max_speakers_hint=args.max_speakers,
        )
    except (FileNotFoundError, ValueError, json.JSONDecodeError) as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print_summary(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
