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

Scribird의 `me`와 `remote`는 추론 결과가 아니라 독립된 캡처 경로다. 이 스킬은
`remote.m4a`처럼 여러 사람의 음성이 믹스된 소스에 AWS 화자 경계를 겹쳐
`Unknown 1/2/3` 또는 확인된 참석자 이름으로 세분화한다.

## 반드시 지킬 경계

- `me`/`remote` 구분은 사실이지만 AWS 화자 라벨과 실제 이름은 추정일 수 있다.
- 회의록 본문은 온디바이스 `transcript.jsonl`을 유지한다. AWS 텍스트로 원본을
  대체하거나 원본 파일을 수정하지 않는다.
- 참석자 이름·역할·소속·식별 힌트는 로컬에서만 사용하며 AWS 명령, 업로드 객체,
  작업 이름에 넣지 않는다.
- 외부 처리는 S3 입력을 쓰는 AWS Transcribe 배치 작업뿐이다. Streaming 경로는
  사용하지 않는다.
- 오디오 업로드와 비용 발생 가능성을 사용자가 승인하기 전에는 S3 쓰기나 Transcribe
  작업 생성을 하지 않는다. 먼저 `--yes` 없이 preflight를 실행하고, 그 출력을
  사용자에게 보여준 뒤 명시적으로 확인받아야 한다.
- `me.m4a`는 대면 회의에서 한 마이크에 여러 사람이 녹음된 경우에만 분석 대상으로
  제안한다. 그 외에는 기본값인 `remote`만 사용한다.
- 스크립트는 정렬·화자 배정·단어 차이를 측정한다. 차이가 뜻을 바꾸는지, 이름 근거가
  충분한지는 직접 검토한다. 전사 수정을 발견해도 사용자 확인 없이 덮어쓰지 않는다.

## 실행 경로

`SKILL_DIR`은 이 `SKILL.md`가 들어 있는 디렉터리의 절대 경로다. 미리 존재하는 환경
변수가 아니며 셸 호출 사이에 유지된다고 가정하지 않는다. 포함된 스크립트와 테스트는
항상 `"$SKILL_DIR/..."` 절대 경로로 실행하고, 작업 디렉터리에서 `scripts/...`를
직접 찾지 않는다.

## 필요한 모듈만 읽는 작업 흐름

1. 세션 확인부터 AWS 결과 생성까지 수행할 때는, **AWS 명령을 실행하기 전에**
   [references/batch-job.md](references/batch-job.md)를 읽는다. 세션 선택, 입력 검증,
   언어·화자 수 결정, preflight, 승인, 업로드와 정리 정책이 있다.
2. `aws-<source>.json`이 준비된 뒤 병합하거나 결과를 검토할 때는
   [references/merge-review.md](references/merge-review.md)를 읽는다. 산출물, 병합
   명령, 검토 순서와 재실행 조건이 있다.
3. 사용자가 참석자 이름을 제공했거나 실제 이름을 붙이려면
   [references/speaker-name-matching.md](references/speaker-name-matching.md)를
   추가로 읽는다. 근거가 부족한 화자는 오류가 아니라 `Unknown N`으로 둔다.
4. 정렬·배정·단어 차이 판정의 이유를 확인하거나 오프셋을 조정할 때만
   [references/thresholds.md](references/thresholds.md)를 읽는다.
5. AWS 자격 증명, S3 정리, 작업 실패, 이상한 병합 결과가 발생했을 때만
   [references/troubleshooting.md](references/troubleshooting.md)를 읽는다.

테스트가 필요하면 다음을 실행한다. 네트워크는 사용하지 않는다.

```bash
/usr/bin/python3 -m unittest discover -s "$SKILL_DIR/tests"
```
