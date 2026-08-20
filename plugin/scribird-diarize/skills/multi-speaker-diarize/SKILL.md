---
name: multi-speaker-diarize
description: >
  Scribird가 저장한 회의 녹음을 승인 후 S3에 업로드하고 AWS Transcribe 배치 작업으로
  다중 화자 분리(speaker diarization)를 돌려, 기존 온디바이스 전사(transcript.jsonl)와
  대조해 `Remote`를 실제 참석자 이름 또는 `Unknown 1/2/3`으로 세분화한 회의록과
  전사 차이 리포트를 만든다.
  사용자가 회의록에서 여러 참석자를 구분하고 싶다고 할 때, 녹음 파일의 화자를
  나누고 싶다고 할 때, 또는 AWS Transcribe·diarization·화자 분리·화자 구분·speaker
  label을 언급할 때 반드시 이 스킬을 쓴다. `~/Documents/Scribird/` 아래 세션,
  `me.m4a`/`remote.m4a`, `transcript.jsonl`을 언급하는 요청에도 쓴다. "상대방이
  여러 명인데 한 명으로 뭉쳐 있다", "누가 무슨 말을 했는지 모르겠다", "회의록 화자를
  나눠줘", "녹음에서 화자 몇 명인지 확인해줘" 같은 말도 이 스킬의 신호다. 전사 품질을
  서로 대조해 오인식을 찾아 달라는 요청(로컬 전사와 클라우드 전사 비교)도 포함한다.
argument-hint: "[session-dir] [--speakers N]"
---

# multi-speaker-diarize

Scribird는 회의 오디오를 **두 갈래로 따로** 받는다. 마이크는 반드시 이 기기를 쓰는
사람(`me`), 시스템 출력은 반드시 원격 참석자(`remote`)다. 추론이 아니라 **경로가**
화자를 정하므로 이 2분리는 틀릴 수 없다.

문제는 `remote`다. Zoom·Teams는 참석자별 스트림을 **믹스다운한 뒤** 시스템 오디오로
넘기므로, 5명이 참석해도 `remote.m4a` 안에서는 한 덩어리다. 이 스킬은 그 덩어리에 AWS
Transcribe의 speaker partitioning을 붙여 화자 경계를 얻고, **이미 있는 온디바이스
전사에 그 경계만 겹쳐** 실제 이름 또는 `Unknown 1/2/3`으로 쪼갠다.

```mermaid
flowchart LR
    JSONL["transcript.jsonl<br/>(온디바이스 전사)"] --> MERGE["경계 겹치기"]
    M4A["remote.m4a"] --> AWS["AWS Transcribe<br/>화자 경계"] --> MERGE
    MERGE --> OUT["세분화된 회의록"]
    MERGE --> DIFF["단어 차이 목록"] --> YOU(["당신이 판단"])
```

## 무엇이 사실이고 무엇이 추정인가

| | 출처 | 성질 |
|---|---|---|
| `me` vs `remote` | 오디오 경로 | **사실** — 추론이 아니다 |
| `Unknown 1` vs `Unknown 2` | AWS Transcribe | **추정** — 틀릴 수 있다 |
| 실제 참석자 이름 | 로컬 발화 근거와 사용자 확인 | **추정 또는 확인값** — AWS에는 보내지 않는다 |
| 발화 텍스트 | 온디바이스 전사 | 회의 언어에 맞춰 돌아간 결과 |

그래서 텍스트를 AWS 것으로 갈아치우지 않는다. AWS는 화자 경계를 얻으려고 부른 것이지
정답으로 부른 것이 아니다.

## 실행 경로

명령을 실행하기 전에 `SKILL_DIR`을 **이 `SKILL.md`가 들어 있는 디렉터리의 절대
경로**로 설정한다. 스킬 로더가 제공한 source locator에서 구하며, 현재 작업
디렉터리가 스킬 디렉터리라고 가정하지 않는다.

이 스킬에 포함된 스크립트와 테스트는 항상 `"$SKILL_DIR/..."` 절대 경로로 실행한다.
`SKILL_DIR`은 미리 존재하는 환경 변수가 아니다. 각 도구 호출에서 실제 절대 경로를
직접 대입하거나 같은 셸 명령 안에서 설정하며, 이전 호출의 셸 환경이 남아 있다고
가정하지 않는다. 저장소 루트나 사용자의 작업 디렉터리에서 `scripts/...`를 직접
찾으면 안 된다.

## 판단은 스크립트가 하지 않는다

스크립트는 차이를 **측정**하고, 그 차이가 문제인지는 **당신이** 판단한다. 린터가
경고를 나열하고 무엇을 고칠지는 사람이 정하는 것과 같다.

| | 담당 |
|---|---|
| 시간 정렬 · 화자 배정 · 어느 단어가 다른가 | 스크립트 (기계적) |
| **그 차이가 뜻을 바꾸나** | **당신** (의미 판단) |

임계값으로 걸러내는 방식을 **의도적으로 버렸다.** 문자 유사도는 뜻의 보존과 순서가
어긋난다 — 뜻이 바뀌는 `care`/`car`가 0.857인데, 뜻이 보존되는 `ok`/`okay`는 0.667로
**더 낮다**. 어떤 문턱을 잡아도 한쪽이 틀리고, 틀리는 방향이 나쁘다: 문턱을 내리면
회의록의 `배포`가 `대포`로 남은 것을 아무도 모르게 된다. 실측 전체와 유일한 예외
(`spacing_only`)는 [references/thresholds.md](references/thresholds.md).

## 작업 흐름

### 1. 세션을 찾는다

```bash
ls -dt ~/Documents/Scribird/*/ | head -10
```

사용자가 어느 회의인지 말하지 않았으면 목록을 보여주고 고르게 한다. 최근 것을 임의로
고르면 엉뚱한 회의를 분석해 비용만 쓴다.

`transcript.jsonl`(필수)과 `remote.m4a`가 있어야 한다. `remote.m4a`가 없으면 시스템
오디오 캡처가 실패한 세션이라 분리할 대상이 없다 — 사용자에게 알리고 멈춘다.

### 2. 참석자 정보, 언어, 화자 수 상한을 정한다

분석할 소스마다 사용자가 아는 참석자 수와 이름을 먼저 묻는다. 역할, 소속,
자기소개할 때 쓰는 표현처럼 식별에 도움이 되는 힌트도 선택적으로 받는다.

- `remote`를 분석하면 원격 참석자만 받는다.
- 대면 회의라 `me`도 분석하면 이 기기 사용자와 같은 공간의 참석자를 받는다.
- 참석자 이름과 힌트는 로컬 이름 매칭에만 사용하며 AWS 명령이나 업로드 파일에 넣지 않는다.
- 사용자가 이름을 모르거나 제공하지 않아도 중단하지 않는다. 감지된 화자를
  `Unknown 1`부터 표시한다고 알리고 계속한다.

언어는 정확도에 크게 영향을 준다. 물어보기 전에 온디바이스 전사가 쓴 로케일을 먼저 본다:

```bash
jq -r '.locale' ~/Documents/Scribird/<세션>/transcript.jsonl | sort -u
```

로케일이 하나면 `--language-code`로 그대로 쓴다. 여럿이면 실제 회의에서 두 언어가 모두
쓰였는지 확인하고, 그렇다면 `--language-options`로 후보를 모두 넘긴다. 언어를 알 수
없으면 언어 인자를 생략해 AWS 자동 식별을 쓴다.

화자 수 상한은 2~30이다. 참석자 수를 받았으면 분석할 소스의 예상 인원에 맞추고,
1명이라고 해도 AWS 지원 범위 때문에 2를 쓴다. 알 수 없으면 기본값 5를 쓴다는 사실을
알린다. 감지 화자 수가 상한과 같으면 더 많은 사람이 잘렸을 수 있으므로 결과 단계에서
다시 알린다.

### 3. 필요한 AWS 조건을 알리고 배치 작업을 돌린다

이 스킬은 다음 조건을 필요로 한다.

- 동작하는 AWS CLI 자격 증명과 리전
- S3 버킷 생성·공개 차단·업로드·다운로드·목록·삭제 권한
- AWS Transcribe 배치 작업 생성·조회 권한
- 회의 M4A가 선택한 계정과 리전의 S3에 임시 저장되는 것에 대한 사용자 동의

스크립트를 실행하기 전에 이 조건이 스킬 사용에 필수라는 사실을 사용자에게 설명하고
진행할지 확인한다. 사용자가 동의하지 않거나 AWS 조건을 준비할 수 없으면 여기서 멈춘다.

오디오는 AWS Transcribe Streaming으로 보내지 않는다. 모든 분석은 S3 입력을 사용하는
배치 작업이다. 버킷이 없으면 비공개 버킷을 만들며, 기본값은 결과 회수 후 실행별 객체를
삭제하는 것이다.

```bash
/usr/bin/python3 "$SKILL_DIR/scripts/run_transcribe.py" \
  --session ~/Documents/Scribird/<세션> \
  --sources remote --language-code ko-KR --max-speakers 5
```

**먼저 `--yes` 없이 실행한다.** 이 호출은 파일 존재와 AWS 자격 증명·계정·리전을
확인하고, 대상 소스와 용량, 계정, 리전, 버킷, 필요한 권한, 임시 저장과 정리 정책을
출력한 뒤 exit 3으로 멈춘다. S3 쓰기나 Transcribe 작업 생성은 하지 않는다.

**그 출력을 사용자에게 그대로 보여주고, AWS와 S3가 필요하며 회의 오디오가 임시
업로드된다는 사실을 확인받은 뒤에만 `--yes`를 붙여 다시 실행한다.**

`--sources`는 기본이 `remote`다. `me`를 넣는 경우는 **대면 회의**뿐이다 — 상대방이 내
마이크로 함께 들어왔다면 `me.m4a`에도 여러 화자가 있다. 그렇지 않으면 보내지 않는다:
내 목소리가 기기 밖으로 나가지 않는 편이 낫고, 마이크 입력의 화자는 이미 확정이라 얻을
것도 없다.

결과는 `aws-<source>.json`으로 저장된다. S3 객체를 남겨야 하는 명시적인 이유가 있을
때만 `--keep-s3`를 사용하고, 그 선택도 승인 전에 사용자에게 알린다.

종료 코드: `0` 성공 / `1` AWS·파일 문제 / `2` 인자 문제 / `3` 승인 대기(실패 아님).

### 4. 병합한다

```bash
/usr/bin/python3 "$SKILL_DIR/scripts/merge_speakers.py" \
  --session ~/Documents/Scribird/<세션> \
  --aws-remote ~/Documents/Scribird/<세션>/aws-remote.json \
  --max-speakers 5
```

`me`도 분석했으면 `--aws-me`를 함께 넘긴다. 원본 `transcript.jsonl`은 수정하지 않는다.
이 첫 병합에서 이름을 확정하지 못한 모든 감지 화자는 `Unknown 1`부터 표시된다.

| 산출물 | 내용 |
|---|---|
| `transcript.speakers.md` | 세분화된 회의록. 본문은 로컬 전사, 차이는 각주 |
| `transcript.speakers.jsonl` | `source`에 원래 `me`/`remote`가 남아 되돌릴 수 있다. `word_diffs`에 차이 **전량** |
| `diarization-report.md` | 배정률·화자별 발화량·오프셋·단어 차이 목록 |

### 5. 실제 이름을 최대한 매칭하고 차이를 판단한다

사용자가 참석자 이름을 제공했다면
[references/speaker-name-matching.md](references/speaker-name-matching.md)를 읽는다.
첫 병합의 `transcript.speakers.jsonl`을 소스와 `aws_label`별로 모아 각 화자의 발화를
검토하고, 직접 자기소개나 한 사람에게만 맞는 1인칭 역할·소속 진술을 찾는다.

- 직접적이고 모순 없는 근거나 사용자 확인이 있으면 `verified`로 기록한다.
- 그보다 약한 근거는 `candidate`로 기록하고 근거 시각과 문장을 사용자에게 보여준다.
- 다른 사람이 이름을 부른 문장, 참석자 목록 순서, 발화량 순서만으로 이름을 확정하지 않는다.
- 매칭하지 못한 화자는 오류가 아니라 `Unknown N`으로 둔다.

세션 폴더에 `speaker-names.json`을 만든 뒤 다시 병합한다:

```bash
/usr/bin/python3 "$SKILL_DIR/scripts/merge_speakers.py" \
  --session ~/Documents/Scribird/<세션> \
  --aws-remote ~/Documents/Scribird/<세션>/aws-remote.json \
  --speaker-names ~/Documents/Scribird/<세션>/speaker-names.json \
  --max-speakers 5
```

이름 파일의 일부 항목이 누락되거나 충돌해도 병합은 계속된다. 스크립트가 경고를
출력하면 해당 항목만 검토하고, 최종 산출물에서 적용되지 않은 화자가 `Unknown N`인지
확인한다. 실제 이름을 적용해도 JSONL의 원래 `source`와 `aws_label`은 보존된다.

여기가 당신의 일이다.

**정렬 의심 구간을 먼저 처리한다.** 리포트 맨 위에 나온다. 이 구간의 단어 차이는 읽을
필요가 없다 — 서로 다른 발화를 비교한 것이라 전부 무의미하다. 오프셋을 확인하고 필요하면
다시 돌린다.

**단어 차이를 훑어 뜻이 바뀌는 것만 골라낸다.** `붙여쓰기만`에 표시가 있으면 건너뛴다.
나머지는 **유사도를 신뢰하지 말고** 단어 자체를 보고 판단한다. 어려우면 원본 오디오의
해당 시각을 들어보라고 안내한다.

회의록 본문은 로컬 전사를 그대로 두었다. 고칠 것이 있으면 어느 시각의 무엇인지 알려
주고 고칠지 **물어본다** — 임의로 덮어쓰지 않는다.

**화자 이름 근거를 확인한다.** 리포트의 화자 이름 매칭 섹션에서 적용한 이름, 후보,
근거 발화, 원래 AWS 라벨을 확인한다. 근거가 약하거나 모순되면 실제 이름을 제거하고
`Unknown N`으로 다시 병합한다.

**감지 화자 수가 요청 상한과 같으면** 더 많은 사람이 잘렸을 수 있다.
`--max-speakers`를 올려 다시 돌릴 수 있다고 알린다. 다시 실행하면 오디오를 또
업로드하므로 새 승인을 받는다.

**미배정이 30% 넘으면** 시간 정렬이 어긋났을 가능성이 있다. 리포트의 오프셋을 확인한다.

## 참조

- [references/thresholds.md](references/thresholds.md) — 판정 기준의 실측 근거,
  시간 정렬이 어긋날 때
- [references/speaker-name-matching.md](references/speaker-name-matching.md) —
  참석자 정보 형식과 근거 기반 이름 매칭 절차
- [references/troubleshooting.md](references/troubleshooting.md) — AWS 자격 증명,
  S3 정리, 배치 작업과 병합의 증상별 대응

## 참고

- 테스트: `/usr/bin/python3 -m unittest discover -s "$SKILL_DIR/tests"` (네트워크 불필요)
- 모든 스크립트가 Python 3 표준 라이브러리만 쓴다. `/usr/bin/python3`(3.9)에서 그대로
  돈다
- 자격 증명은 `awscli`에서 가져온다(`aws configure export-credentials`). 프로필·SSO·
  MFA 해석을 CLI에 맡기는 것이 목적이다 — 직접 파싱하면 `aws` 명령으로는 되는데
  스킬로는 안 되는 상황이 생긴다
