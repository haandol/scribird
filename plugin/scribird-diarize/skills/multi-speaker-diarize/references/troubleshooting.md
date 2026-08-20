# 증상별 대응

## 왜 S3가 필요한가

배치가 S3를 피할 수 없는 이유: `Media.MediaFileUri`가 `s3://` URI만 받는다. AWS 문서
원문 — *"For batch transcription, the media file must be uploaded to an Amazon S3 bucket
beforehand."* 출력 버킷은 생략할 수 있지만(AWS 관리 버킷, 90일 후 삭제) 입력은 아니다.
출력까지 자기 버킷에 넣는 이유는 정리 때문이다 — AWS 관리 버킷은 사용자가 지울 수 없다.

버킷이 아직 없어도 된다. 기본 경로는 계정과 리전을 포함한 이름으로 비공개 버킷을 만들고
공개 접근을 차단한다. 성공한 작업은 결과를 받은 뒤 실행별 접두사 아래 객체를 삭제하지만
버킷 자체는 다음 실행에 재사용한다.

## 자격 증명

**`aws sts get-caller-identity`가 실패한다.** 자격 증명이 없거나 만료됐다. SSO라면
`aws sso login --profile <프로필>`이 필요한데 대화형 로그인이라 직접 실행할 수 없다.
사용자에게 `! aws sso login --profile <프로필>`을 입력하도록 안내한다.

**`AccessDeniedException`이 난다.** 필요한 권한:

```
s3:CreateBucket, s3:PutBucketPublicAccessBlock
s3:PutObject, s3:GetObject, s3:DeleteObject, s3:ListBucket
transcribe:StartTranscriptionJob, transcribe:GetTranscriptionJob
```

기존 버킷을 지정하면 생성과 공개 차단 권한은 사용하지 않지만, 기본 경로는 버킷이 없을
때 만들 수 있어야 한다. 어느 권한이 없는지는 AWS 오류 메시지에 나온다.

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

**실제 이름이 적용되지 않았다.** 직접 자기소개나 고유한 1인칭 역할·소속 진술처럼
화자 본인을 가리키는 근거가 없으면 정상적으로 `Unknown N`이 남는다. 리포트의 이름
매칭 경고와 후보 근거를 확인하고, 사용자가 후보를 확인하면 `speaker-names.json`에서
그 항목을 `verified`로 바꿔 병합만 다시 실행한다.

**이름 매칭 경고가 나왔다.** 잘못된 항목만 건너뛰고 병합은 계속된다. 중복 실명,
참석자 목록에 없는 이름, 근거가 없는 항목, 감지되지 않은 AWS 라벨을 확인한다. 수정하지
않아도 해당 화자는 `Unknown N`으로 남으며 기존 결과 파일은 생성된다.

**단어 차이가 수백 건이다.** 정상이다. 두 엔진은 늘 다르게 적는다. 먼저 정렬 의심
구간이 있는지 보고(있으면 그쪽이 원인일 수 있다), `붙여쓰기만` 표시가 없는 것만 훑는다.
전량은 `transcript.speakers.jsonl`의 `word_diffs`에 있다.

**감지 화자 수가 요청 상한과 같다.** 참석자가 더 있는데 잘렸을 수 있다. 상한을 올려
다시 돌릴 것을 제안한다 — 다만 오디오를 또 올려야 하므로 사용자에게 승인을 받는다.
