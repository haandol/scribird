---
name: multi-speaker-diarize
description: >
  Scribird 회의 녹음에 AWS Transcribe 배치 diarization을 적용해 원격 참석자를
  세분화하고, 필요하면 실제 이름을 근거 기반으로 매칭하며 로컬·클라우드 전사 차이를
  검토한다. Scribird 녹음의 다중 화자 분리, speaker label, 참석자 식별, 또는
  로컬 전사와 AWS 전사 비교를 요청할 때 사용한다.
argument-hint: "[session-dir] [--speakers N]"
---

# multi-speaker-diarize

과거 Scribird 세션의 `remote.m4a` 등 소스별 녹음에 AWS 화자 경계를 겹쳐,
원격 참석자를 `Unknown N` 또는 근거가 확인된 이름으로 구분한다. 현재 앱의 합본
`meeting.m4a`는 이 워크플로의 입력이 아니다.

회의 요약은 `summarize-scribird-meetings`로 처리한다. 요약만 요청받았다면 AWS 분석이나
화자 분리가 필요하지 않으며, 작업별 전사 파서·클라이언트·보고서 생성 스크립트를 만들지 않는다.

## 공통 경계

- 원본 오디오와 `transcript.jsonl`을 보존한다. AWS 전사로 본문을 교체하지 않는다.
  `me`/`remote`는 캡처 경로이고, AWS 라벨과 실제 이름은 추정일 수 있다.
- 참석자 이름·역할·소속·식별 힌트는 로컬 매칭에만 사용한다. AWS 명령, 업로드 객체나
  작업 이름에 넣지 않는다.
- 외부 처리는 S3 입력을 쓰는 Transcribe 배치뿐이다. 먼저 `--yes` 없이 preflight를
  실행하고 전송 범위·계정·리전·정리 정책·비용을 보여준다. 승인 전에는 S3 쓰기나 작업
  생성을 하지 않으며 Streaming으로 우회하지 않는다. 같은 구체적 실행 범위에 대한
  승인이 이미 있으면 재확인을 반복하지 않는다.
- 번들 스크립트는 정렬·배정·차이를 측정한다. 의미 변화와 이름 근거는 직접 검토하고,
  불확실한 이름은 `Unknown N`으로 둔다. 원문 수정은 별도 사용자 요청 범위에서만 한다.

## 실행 경로

`SKILL_DIR`은 이 파일이 있는 디렉터리의 절대 경로이며, 미리 존재하는 환경 변수가 아니다.
명령마다 실제 경로를 사용하고 셸 호출 사이에 값이 유지된다고 가정하지 않는다.
번들 명령은 `"$SKILL_DIR/scripts/..."`로 실행한다.

## 현재 단계의 참조를 읽는다

| 단계 | 읽을 문서 |
| --- | --- |
| 세션 선택·업로드·분석 | **AWS 명령을 실행하기 전에** [references/batch-job.md](references/batch-job.md)를 읽는다. 입력, 참석자·언어, preflight, 승인과 종료 상태를 다룬다. |
| 결과 병합·검토 | `aws-<source>.json`이 준비되면 [references/merge-review.md](references/merge-review.md)를 읽는다. |
| 실제 이름 적용 | 이름이 제공됐거나 실명 적용을 요청받으면 [references/speaker-name-matching.md](references/speaker-name-matching.md)를 추가로 읽는다. |
| 진단 | 정렬·판정 기준은 [references/thresholds.md](references/thresholds.md), AWS·잔여 객체·작업 오류는 [references/troubleshooting.md](references/troubleshooting.md)를 읽는다. |

테스트가 필요하면 다음을 실행한다. 네트워크는 사용하지 않는다.

```bash
/usr/bin/python3 -m unittest discover -s "$SKILL_DIR/tests"
```
