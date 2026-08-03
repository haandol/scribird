# 증상별 대응

## 스트리밍과 배치 중 무엇을 쓰나

**스트리밍이 기본이다** — S3를 쓰지 않는다. 배치가 필요한 경우는 두 가지뿐이다.

| | 스트리밍 (`stream_transcribe.py`) | 배치 (`run_transcribe.py`) |
|---|---|---|
| S3 | **쓰지 않음** | 버킷 생성 → 업로드 → 삭제 |
| 화자 수 | 지정 불가, 최대 10명 | `--max-speakers` 2~30 |
| 다국어 | 언어 하나만 | 다중 언어 식별 가능 |

즉 **참석자가 10명을 넘거나, 한·영이 비슷한 비중으로 섞였을 때만** 배치로 간다.

배치가 S3를 피할 수 없는 이유: `Media.MediaFileUri`가 `s3://` URI만 받는다. AWS 문서
원문 — *"For batch transcription, the media file must be uploaded to an Amazon S3 bucket
beforehand."* 출력 버킷은 생략할 수 있지만(AWS 관리 버킷, 90일 후 삭제) 입력은 아니다.
출력까지 자기 버킷에 넣는 이유는 정리 때문이다 — AWS 관리 버킷은 사용자가 지울 수 없다.

구현 세부와 실측한 함정은 [streaming.md](streaming.md).

## 스트리밍이 실패한다

**`InvalidSignatureException`.** 서명 계산이 틀렸다. 서버가 자신이 기대한 canonical
string을 오류 메시지에 담아 보내므로, 우리 것과 한 줄씩 비교하면 어디가 다른지 바로
보인다. 실측으로 잡힌 원인은 `host`에 포트를 포함한 것이었다 —
[streaming.md](streaming.md)에 기록해 두었다.

**`BrokenPipeError`가 뜬다.** 서버가 오류를 보내고 끊었는데 계속 쓰기만 한 것이다.
원인은 파이프가 아니라 그 직전에 온 예외 이벤트이므로, 몇 프레임 보낸 뒤 `receive()`로
읽어 보면 실제 이유가 나온다.

**결과를 받지 못했다.** 오디오가 무음이거나 언어가 맞지 않는다. 무음 확인:

```bash
afinfo <파일>    # 길이가 0에 가까우면 캡처 실패한 세션
```

언어는 `--language-code`를 바꿔 본다. 스트리밍은 지정한 언어로만 인식하므로, 한국어
회의에 `en-US`를 주면 결과가 거의 나오지 않는다.

**감지 화자가 10명이다.** 스트리밍의 상한에 걸렸다. 참석자가 더 있으면 배치로
`--max-speakers`를 올려야 한다.

## 자격 증명

**`aws sts get-caller-identity`가 실패한다.** 자격 증명이 없거나 만료됐다. SSO라면
`aws sso login --profile <프로필>`이 필요한데 대화형 로그인이라 직접 실행할 수 없다.
사용자에게 `! aws sso login --profile <프로필>`을 입력하도록 안내한다.

**`AccessDeniedException`이 난다.** 필요한 권한:

```
s3:CreateBucket, s3:PutObject, s3:GetObject, s3:DeleteObject, s3:ListBucket
transcribe:StartTranscriptionJob, transcribe:GetTranscriptionJob
```

어느 것이 없는지 오류 메시지에 나온다.

**리전을 알 수 없다는 오류.** 임의로 고르지 않는다 — 의도하지 않은 곳에 데이터가
올라가고 비용도 그쪽에 붙는다. `--region`으로 지정하거나 `aws configure set region`을
안내한다.

**리전에서 Transcribe를 쓸 수 없다.** 일부 리전은 지원하지 않는다. `--region us-east-1`
처럼 지원 리전을 지정하되, 데이터가 그 리전으로 간다는 것을 사용자에게 알린다.

## 작업 실패

**작업이 `FAILED`로 끝난다.** `FailureReason`을 그대로 보여준다. 흔한 원인은 오디오가
비어 있는 경우다 — 캡처가 조용히 실패한 세션(권한 거부)에서는 `.m4a`에 무음만 들어
있다. 확인:

```bash
afinfo <파일>    # 길이가 0에 가까우면 캡처 실패
```

**타임아웃에 걸렸다.** 작업은 AWS에서 **계속 돈다.** 스크립트가 작업 이름을 알려주므로
회수할 수 있다 — 오디오를 다시 올리게 만들지 않는다:

```bash
aws transcribe get-transcription-job --transcription-job-name <이름>
```

**S3에 객체가 남았다.** 스크립트가 경로를 출력한다. Transcribe는 쓰기 권한 확인용
`.write_access_check_file.temp`를 직접 만들기 때문에 접두사 단위로 지우는데, 그 삭제가
실패하면 남는다. 직접 지우거나 다음 실행에서 정리된다.

## 병합 결과가 이상하다

**배정률이 0%다.** 시간 정렬이 완전히 어긋났거나 다른 세션의 파일을 짝지었다. 리포트의
오프셋과 세션 디렉터리를 확인한다. 자세히는
[thresholds.md](thresholds.md)의 "시간 정렬이 어긋날 때".

**화자 A/B가 뒤집힌 것 같다.** 이름은 발화량 순서로 정한다. `me` 소스에서는 최대
발화자를 `나`로 두는데, 내가 거의 듣고만 있던 회의에서는 이 전제가 깨진다. 리포트의
화자별 발화 시간 표를 사용자에게 보여주고 판단하게 한다 — 스크립트가 고칠 수 없다.

**단어 차이가 수백 건이다.** 정상이다. 두 엔진은 늘 다르게 적는다. 먼저 정렬 의심
구간이 있는지 보고(있으면 그쪽이 원인일 수 있다), `붙여쓰기만` 표시가 없는 것만 훑는다.
전량은 `transcript.speakers.jsonl`의 `word_diffs`에 있다.

**감지 화자 수가 요청 상한과 같다.** 참석자가 더 있는데 잘렸을 수 있다. 상한을 올려
다시 돌릴 것을 제안한다 — 다만 오디오를 또 올려야 하므로 사용자에게 승인을 받는다.
