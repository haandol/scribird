# Scribird 플러그인

Scribird가 남긴 회의 산출물을 후처리하는 플러그인이다. **Claude Code와 Codex** 양쪽에서
같은 스킬을 쓴다.

앱과 같은 저장소에 두는 이유는 산출물 스키마(`transcript.jsonl`의 필드,
`me.m4a`/`remote.m4a` 파일명, 세션 디렉터리 규칙)가 앱과 함께 바뀌기 때문이다. 따로 두면
스키마를 고칠 때 두 저장소를 맞춰야 하고, 어긋난 조합이 사용자에게 먼저 도달한다.

## 설치

저장소 자체가 두 에이전트의 마켓플레이스다. 등록한 뒤 플러그인을 설치한다.

**Claude Code**

```bash
claude plugin marketplace add ~/git/scribird
claude plugin install scribird-diarize@scribird
```

세션 안에서라면 `/plugin marketplace add ~/git/scribird` 후 `/plugin`에서 고른다.
호출은 `/multi-speaker-diarize`.

**Codex**

```bash
codex plugin marketplace add ~/git/scribird
codex plugin add scribird-diarize@scribird
```

호출은 `$multi-speaker-diarize`. `codex plugin list`에 `installed, enabled`로 나오면
정상이다.

GitHub에 올라가 있으면 로컬 경로 대신 `haandol/scribird`를 넘겨 원격으로 등록할 수도
있다 — 같은 마켓플레이스를 Git으로 받는 것이다.

`SKILL.md`를 고치면 현재 세션에 바로 반영된다. `plugin.json`이나 스크립트를 고쳤을
때는 Claude Code에서 `/reload-plugins`, Codex에서는 세션 재시작이 필요하다.

## 두 에이전트를 지원하는 방식

매니페스트를 에이전트별로 하나씩 두고, **스킬은 하나만 둔다.**

```
scribird/
├── .claude-plugin/marketplace.json   # Claude Code 마켓플레이스
├── .agents/plugins/marketplace.json  # Codex 마켓플레이스
└── plugin/scribird-diarize/
    ├── .claude-plugin/plugin.json    # Claude Code 매니페스트
    ├── .codex-plugin/plugin.json     # Codex 매니페스트 (interface 블록 필요)
    └── skills/                       # 공용 — 양쪽이 이걸 읽는다
```

스킬을 복제하지 않는 것이 요점이다. 두 벌이 되면 한쪽만 고쳐지는 사고가 나고, 그 사고는
"어떤 에이전트에서는 되는데 다른 쪽에서는 안 된다"는 형태로 나타나 원인을 찾기 어렵다.

두 매니페스트의 차이:

| | Claude Code | Codex |
|---|---|---|
| 마켓플레이스 위치 | `.claude-plugin/marketplace.json` | `.agents/plugins/marketplace.json` |
| 플러그인 소스 표기 | `"source": "./plugin/..."` (문자열) | `"source": {"source":"local","path":"..."}` |
| 스킬 경로 | 기본 `skills/` 스캔 | `"skills": "./skills/"` 명시 |
| UI 메타데이터 | 불필요 | `interface` 블록 (표시 이름, 예시 프롬프트 등) |

## 들어 있는 플러그인

### scribird-diarize

`remote.m4a`를 AWS Transcribe로 화자 분리해 `Remote`를 실제 참석자 이름 또는
`Unknown 1/2/3`으로 세분화한다. 텍스트는 온디바이스 전사를 유지하고, 두 전사가
다르게 적은 곳을 전부 목록으로 남긴다.

앱은 오디오 경로로 `Me`와 `Remote`를 확정하고, 이 플러그인은 보관된 소스별 원본으로
원격 참석자만 회의 후에 세분화한다.

**이 플러그인은 오디오를 사용자의 AWS 계정으로 보낸다.** Scribird 본체는 아무것도
네트워크로 보내지 않으므로, 이건 앱의 성질을 의도적으로 벗어나는 동작이다. 스크립트는
`--yes` 없이는 보내지 않고 무엇을 어디로 보내는지 먼저 출력한다.

분석은 **S3 업로드와 AWS Transcribe 배치 작업으로만** 실행한다. 스킬은 필요한 AWS
조건, 전송할 파일과 용량, 계정, 리전, 버킷, 정리 정책을 먼저 보여주고 사용자가 승인한
뒤에만 업로드한다. 스트리밍 전사나 배치 실패 후 스트리밍 fallback은 없다.

스킬은 분석 전에 소스별 참석자 수와 이름, 선택적인 역할·소속 힌트를 묻는다. 이 정보는
AWS에 보내지 않고 첫 병합 결과의 발화 근거와 로컬에서만 대조한다. 직접 자기소개처럼
확실한 근거나 사용자 확인이 있는 이름만 적용하며, 이름을 찾지 못했거나 입력 일부가
잘못돼도 실패하지 않고 `Unknown N`으로 결과를 만든다.

필요한 것:

- `aws` CLI와 동작하는 자격 증명 (`aws sts get-caller-identity`로 확인)
- AWS 리전 설정
- Python 3 (macOS 기본 `/usr/bin/python3`, 3.9로 확인 — 추가 설치가 없다)
- `s3:CreateBucket`, `s3:PutBucketPublicAccessBlock`, `s3:PutObject`,
  `s3:GetObject`, `s3:DeleteObject`, `s3:ListBucket`,
  `transcribe:StartTranscriptionJob`, `transcribe:GetTranscriptionJob`

버킷이 없으면 계정과 리전을 포함한 이름으로 만들고 공개 접근을 차단한다. 성공한 작업은
결과를 회수한 뒤 실행별 S3 객체를 삭제하며, `--keep-s3`를 명시한 경우에만 남긴다.

## 테스트

```bash
cd plugin/scribird-diarize/skills/multi-speaker-diarize
/usr/bin/python3 -m unittest discover -s tests
```

테스트는 네트워크·AWS·오디오 하드웨어를 건드리지 않는다. AWS 호출은 `run_aws`를
가로채 CLI에 넘어간 인자와 업로드 승인 경계를 검사한다.

앱 쪽 테스트 규약이 여기에도 적용된다.

- **측정된 실패를 인코딩한다.** 예: `배포` → `대포`는 `AudioRecorder`가 64k AAC에서
  실측한 오인식이다. 그 문장이 문장 단위 유사도 0.93으로 어떤 임계값도 통과한다는
  사실과, `care`/`car`(0.857, 뜻 바뀜)가 `ok`/`okay`(0.667, 뜻 보존)보다 높다는
  사실을 테스트가 함께 못박는다 — 두 번째가 유사도 임계값을 제거한 근거다.
- **테스트가 판별력이 있는지 확인한다.** 불변식을 소스에서 깨뜨려 테스트가 실제로
  실패하는지 확인했다. 검증한 항목:

  | 깨뜨린 것 | 잡은 테스트 수 |
  |---|---:|
  | 겹침 비율 대신 절대 길이로 화자 판정 | 2 |
  | 오프셋 자동 탐색 무력화 | 1 |
  | 단어 단위 대조 제거 (문장 유사도만) | 2 |
  | 한글 NFC 정규화 제거 | 1 |
  | 근거 없는 구간을 유사도 0.0으로 처리 | 1 |
  | 이름 근거가 없을 때 `Unknown N` fallback 제거 | 2 |
  | 중복·잘못된 이름 매칭을 오류로 전파 | 3 |
  | `MaxSpeakerLabels` 누락 | 2 |
  | us-east-1에 `LocationConstraint` 전달 | 1 |
  | 승인(`--yes`) 없이 업로드 | 1 |
  | 정리 실패를 예외로 전파 | 1 |
  | 리전 미설정 시 임의 리전 추측 | 1 |
  | `--media-format m4a` 선언 제거 | 1 |
  | 우리가 올린 키만 지우고 접두사를 남김 | 4 |
  | 승인 화면에서 AWS 권한·S3 임시 저장 고지 제거 | 2 |

  접두사 전체 정리 항목은 실측에서 나왔다. Transcribe는 쓰기 권한 확인용
  `.write_access_check_file.temp`를 직접 만들어서 아는 키만 지우면 버킷에 남는다.

  쿼리 정렬 테스트는 처음에 **판별력이 없었다.** `sorted()`를 지워도 dict 리터럴
  순서가 우연히 정렬돼 있어 통과했다. 입력을 역순으로 넣도록 고쳐서 잡히게 했다 —
  판별력 확인이 없었으면 무의미한 테스트가 남았을 것이다.

## 스킬 구조

`SKILL.md`는 공통 경계와 단계 라우팅만 담는다. AWS 실행 전 단계와 병합 후 검토는
각 단계에 진입할 때만 읽는 참조로 분리했고, 이름 매칭·판정 근거·문제 해결도 필요할
때만 읽는다. 스킬이 트리거될 때마다 진입점 전체가 컨텍스트에 들어가기 때문이다.

```
skills/multi-speaker-diarize/
├── SKILL.md                        # 공통 경계와 참조 라우터
├── references/
│   ├── batch-job.md                # 세션 선택, AWS preflight·승인·실행
│   ├── merge-review.md             # 병합, 산출물 검토, 재실행 조건
│   ├── thresholds.md               # 판정 기준의 실측 근거, 시간 정렬
│   ├── speaker-name-matching.md     # 참석자 정보와 근거 기반 실제 이름 매칭
│   └── troubleshooting.md          # AWS·S3·배치 작업의 증상별 대응
├── scripts/
│   ├── run_transcribe.py           # S3 업로드 + Transcribe 배치
│   └── merge_speakers.py           # 경계 겹치기 + 차이 측정
└── tests/
```

## 판단을 스크립트가 하지 않는 이유

`merge_speakers.py`는 두 전사가 다르게 적은 단어를 **전부** 내놓고, 무엇이 오인식인지는
스킬을 실행하는 에이전트가 판단한다. 유사도로 걸러내는 방식이 원래 있었는데, 실측이
그 방식을 무효로 만들었다 — 문자 유사도의 순서가 뜻의 보존과 어긋난다.

| 로컬 | AWS | 유사도 | 뜻 |
|---|---|---:|---|
| `care` | `car` | 0.857 | **바뀜** |
| `ok` | `okay` | 0.667 | 보존 |
| `배포` | `대포` | 0.500 | **바뀜** |

문턱을 올리면 표기 차이가 쏟아지고, 내리면 회의록의 `배포`가 `대포`로 남은 것을 아무도
모르게 된다. 후자가 훨씬 위험하다. 예외는 공백을 지워 같아지는 쌍(`spacing_only`)뿐 —
의미 판단이 아니라 문자열 동일성이라 틀릴 수 없다. 자세한 근거는
[`references/thresholds.md`](./scribird-diarize/skills/multi-speaker-diarize/references/thresholds.md).

## 새 플러그인을 추가할 때

1. `plugin/<이름>/.claude-plugin/plugin.json`을 만든다
2. 최상위 `.claude-plugin/marketplace.json`의 `plugins` 배열에 항목을 넣는다
3. `claude plugin validate .`로 확인한다
