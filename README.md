# Scribird

macOS 26 `SpeechAnalyzer`로 Zoom·Teams 회의를 실시간 전사하는 메뉴바 앱.
전사·저장 전부 온디바이스에서 처리되며 네트워크로 나가는 데이터가 없다.

## 동작 방식

화자분리의 핵심은 오디오를 **섞기 전에** 나누는 것이다.

```
마이크 입력  ──→ SpeechAnalyzer #1 ──→ [나]     ─┐
                                                  ├─→ TranscriptTimeline ─→ JSONL + Markdown
시스템 출력  ──→ SpeechAnalyzer #2 ──→ [상대방] ─┘
   (Zoom/Teams가 재생하는 소리)
```

마이크로 들어온 소리는 반드시 나이고, 시스템이 재생하는 소리는 반드시 상대방이다.
소스별로 독립된 `SpeechAnalyzer`를 두면 화자 라벨이 추론 없이 확정된다.

ScreenCaptureKit 스트림 하나에서 `.microphone`과 `.audio` 출력을 동시에 받는다.
화면 픽셀은 쓰지 않으므로 2×2 해상도·1fps로 묶어 비용을 없앤다.

## 다국어 (한국어 + English)

메뉴바 팝오버에서 **한국어 / English / 한국어 + English**를 고른다. 기본값은 둘 다.

한 `SpeechAnalyzer`에 로케일별 `SpeechTranscriber`를 함께 물릴 수 있다. 문제는
**양쪽이 모두 결과를 낸다**는 것 — 자기 언어가 아닌 오디오에도 침묵하지 않고
엉뚱한 텍스트를 만든다. 실측:

```
영어 오디오 "Good morning everyone. Let's review the deployment schedule."
  en 전사기: conf=0.84~0.97  "Good morning, everyone." / "Let's review..."
  ko 전사기: conf=0.558      "Goodmorning everyone et' reve t Deploen cel."   ← 쓰레기
```

다행히 신뢰도가 뚜렷하게 갈려서 `LanguageArbiter`가 이를 걸러낸다. 판정을
**토큰(단어) 단위**로 하는 게 핵심이다. 세그먼트 단위로 비교하면 코드스위칭
회의에서 발화가 통째로 사라진다 — ko 전사기가 한→영→한 오디오를 하나의 긴
세그먼트로 뭉개고, 그 평균(0.832)이 en(0.871)에 지면 한국어 전체가 버려진다.

중재 규칙 세 가지는 모두 실측 실패 사례에서 나왔다.

1. **구역(region) 단위로 언어를 정한다** — 토큰 하나씩 겨루면 개별 단어의
   신뢰도가 출렁여 문장 중간에서 언어가 뒤집힌다. `en ' morning,' c=0.617` vs
   `ko ' morning' c=0.691`에서 ko가 이겨 영어 문장에 구멍이 났다.
2. **긴 단일 토큰은 구역 경계에서 제외한다** — 오답 모델은 못 알아들은 구간을
   한 단어로 길게 때운다 (`2.70~6.00s c=0.552 ' 네,'` — 한 음절이 3.3초).
   이걸 경계에 넣으면 인접 구역까지 삼켜서 멀쩡한 발화가 휩쓸려 나간다.
3. **신뢰도는 지속 시간으로 가중 평균한다** — 단순 평균은 짧은 조각 하나가 긴
   발화와 같은 무게를 갖는다.

검증 결과 (`say`로 만든 음성):

| 시나리오 | 결과 |
|---|---|
| 한국어만 | `안녕하세요. 오늘 회의를 시작하겠습니다.` ✅ |
| 영어만 | `Good morning, everyone. Let's review the deployment schedule.` ✅ |
| 코드스위칭 한→영→한 | `[ko] 안녕하세요. 일정` / `[en] Sure, the release is scheduled for Friday.` / `[ko] 좋습니다. 그럼 그렇게 진행하겠습니다.` ✅ |

코드스위칭 경계에서 `확인하겠습니다`가 잘렸다. 언어 전환 직전 토큰이 다음 구역과
겹치면 그쪽으로 휩쓸린다. 단일 언어 회의에서는 발생하지 않는다.

단일 언어를 고르면 중재기를 아예 만들지 않으므로 이런 손실이 없다. **회의 언어가
하나로 정해져 있다면 그쪽을 고르는 게 정확하다.**

## 화자분리의 한계

**`나` vs `상대방 전원` 2분리가 상한이다.** 참석자를 개인별로 구분하지 못한다.

이유는 SpeechAnalyzer가 아니라 오디오 경로에 있다. Apple Speech 프레임워크에는
diarization API가 없고(SDK 심볼 레벨에서 확인), Teams·Zoom은 참석자별 스트림을
**믹스다운한 뒤** CoreAudio로 넘긴다. 우리가 탭하는 지점은 이미 섞인 다음이다.
WebRTC 레벨의 화자 정보(SSRC, active-speaker 이벤트)는 앱 프로세스 내부에만 있다.

다중화자까지 가려면:

| 방법 | 실시간 | 참석자 이름 | 제약 |
|---|---|---|---|
| 화자 임베딩 클러스터링 (sherpa-onnx/pyannote → Core ML) | O | X (`화자 A/B/C`) | 온디바이스 유지, 목소리 비슷하면 섞임 |
| 접근성 API로 화면의 활성 발화자 읽기 | O | O | Teams/Zoom UI 구조 의존, 업데이트마다 깨짐 |
| Zoom 참석자별 개별 오디오 녹음 | X (회의 후) | O | 파일이 회의 종료 후 생성 |
| Microsoft Graph 통신 봇 | O | O | 테넌트 관리자 동의 + 서버 필요 |
| 클라우드 STT diarization | O | X | 오프라인·프라이버시 포기 |

확장 지점은 `TranscriptTimeline.ingest` 앞단이다. `Speaker`를 `case remote(id: Int)`
형태로 넓히면 나머지 코드는 대부분 그대로 간다. 원본 오디오를 소스별로 따로
저장해 두는 이유도 이것이다 — 나중에 화자분리 모델을 붙여 재처리할 수 있다.

## 빌드

```bash
./build.sh release
open build/Scribird.app
```

`.app` 번들로 감싸고 코드서명까지 해야 한다. 맨몸 실행 파일은 macOS가 권한(TCC)을
번들 식별자에 묶어 관리하기 때문에 마이크·화면녹음 권한을 받을 수 없다.

코드를 수정한 뒤 빌드해서 `/Applications`에 설치하려면:

```bash
./install.sh
```

기존 `Scribird.app`은 새 빌드로 교체된다. 설치된 앱이 실행 중이면 종료한 뒤
다시 실행해야 새 빌드가 적용된다.

## 권한

첫 실행 시 두 가지를 허용해야 한다.

- **마이크** — 내 발언 전사
- **화면 및 시스템 오디오 녹음** — 상대방 목소리 전사 (화면 영상은 저장하지 않음)

시스템 설정 › 개인정보 보호 및 보안에서 확인·변경할 수 있다.

언어 모델은 첫 녹취 시작 시 자동으로 내려받는다. 진행률이 메뉴바 팝오버에
표시된다. `en_US`를 요청하면 영어 변형 전체(`en_GB`, `en_AU` 등)가 함께 설치된다.

지원 로케일은 30개다 (`ko_KR`, `en_*`, `ja_JP`, `zh_*`, `de_*`, `fr_*`, `es_*`,
`it_*`, `pt_*`, `yue_CN`). 다른 언어를 쓰려면 `TranscriptionLanguage`에 케이스를
추가하면 된다. 동시 예약 한도는 5개.

## 출력

`~/Documents/Scribird/<날짜_시각>/`

| 파일 | 내용 |
|---|---|
| `transcript.jsonl` | 확정 발화 한 줄씩 (화자·시각·신뢰도·언어). 확정 즉시 flush |
| `transcript.md` | 화자별로 묶은 읽기용 회의록 |
| `me.m4a` | 마이크 원본 (AAC 128kbps/채널) |
| `remote.m4a` | 시스템 출력 원본 (AAC 128kbps/채널) |

JSONL을 즉시 append하는 이유는 크래시 내구성이다. 메모리에 모아 두고 종료 시
한 번에 쓰면 앱이 죽을 때 회의록 전체를 잃는다.

원본 오디오는 리샘플링 **이전** 버퍼를 저장한다. 전사용 16kHz 모노로 줄인 뒤
저장하면 나중에 재처리할 때 쓸 정보가 사라진다. 저장을 끄려면 팝오버 하단의
체크박스를 해제한다.

### 왜 mp3가 아니고 m4a인가

**mp3는 쓸 수 없다.** Apple은 mp3 디코딩만 지원하고 인코딩은 지원하지 않는다.
`kAudioFormatMPEGLayer3`로 파일을 만들면 `'fmt?'`
(`kAudioFormatUnsupportedDataFormatError`)로 실패한다. mp3로 저장하려면 LAME 같은
외부 인코더를 번들에 넣어야 하는데, 의존성 없는 온디바이스 앱이라는 성격에
맞지 않는다. AAC는 같은 비트레이트에서 mp3보다 음질이 좋고 OS가 직접 지원한다.

인코딩 가능 여부 실측:

| 포맷 | 쓰기 | 크기 (모노 1시간) |
|---|---|---|
| **AAC 128k (채택)** | O | 54 MB |
| AAC 64k | O | 29 MB |
| ALAC 무손실 | O | 139 MB |
| WAV PCM16 | O | 331 MB |
| mp3 | **X** | — |
| FLAC | X (`afconvert`는 되지만 `AVAudioFile`은 실패) | — |

비트레이트를 128k로 정한 근거는 **재전사 정확도**다. 이 파일의 용도가 재처리이므로
압축이 인식률을 떨어뜨리면 저장 자체가 무의미하다. 같은 음성을 포맷별로 저장한 뒤
다시 전사한 결과:

| 포맷 | 재전사 결과 |
|---|---|
| 원본 WAV | 원문 일치 ✅ |
| ALAC 무손실 | 원문 일치 ✅ |
| AAC 128k | 원문 일치 ✅ |
| AAC 64k | `배포 일정` → **`대포 일정`** ❌ |

64k에서 오인식이 발생했다. 저장 공간(29→54MB)보다 재처리 정확도가 중요하다고 봤다.
무손실이 필요하면 `AudioRecorder`의 `AVFormatIDKey`를 `kAudioFormatAppleLossless`로
바꾸면 된다 (확장자는 `.m4a` 그대로).

## 구조

```
Sources/Scribird/
├─ ScribirdApp.swift          MenuBarExtra 진입점
├─ MeetingRecorder.swift         상태 기계 + 파이프라인 조립
├─ Audio/
│  ├─ AudioCaptureEngine.swift   ScreenCaptureKit → 소스별 AsyncStream
│  ├─ AudioStreamConverter.swift  AVAudioConverter 래퍼 (샘플레이트 변환)
│  ├─ AudioRecorder.swift        원본 오디오를 소스별 파일로 저장
│  └─ CMSampleBuffer+PCM.swift   CMSampleBuffer → AVAudioPCMBuffer
├─ Transcription/
│  ├─ TranscriptionSession.swift  SpeechAnalyzer 한 개 = 소스 한 개 (로케일 N개)
│  ├─ TranscriptionLanguage.swift 언어 구성 (한국어/영어/둘 다)
│  ├─ LanguageArbiter.swift       다국어 결과를 토큰 단위로 판정
│  └─ SpeechModelInstaller.swift  AssetInventory 다운로드 플로우
├─ Transcript/
│  ├─ Speaker.swift              화자 구분 (확장 지점)
│  ├─ TranscriptSegment.swift    발화 한 조각
│  ├─ TranscriptTimeline.swift   두 소스 머지 + 잠정/확정 결과 관리
│  └─ TranscriptStore.swift      JSONL/Markdown 저장
└─ UI/
   └─ TranscriptView.swift       팝오버 (실시간 대화 뷰)
```

## 알아 둘 점

- **마이크 공유** — macOS 입력 장치는 멀티 클라이언트라 Zoom이 쓰는 중에도 같이
  열린다. 단 Zoom의 에코 제거가 켜져 있으면 마이크 신호 특성이 바뀔 수 있다.
- **원격 오디오 품질** — 상대방 목소리는 이미 코덱을 거쳐 재생된 신호라 원본보다
  인식률이 낮다. 한국어에서 특히 체감된다.
- **잠정 결과** — 말하는 중에는 흐린 텍스트로 표시되고, 확정되면 선명해지면서
  디스크에 기록된다. 잠정 결과는 저장하지 않는다.
