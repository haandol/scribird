# Scribird

macOS 26 `SpeechAnalyzer`로 Zoom·Teams 회의를 실시간 전사하는 메뉴바 앱.
전사·저장 전부 온디바이스에서 처리되며 네트워크로 나가는 데이터가 없다.

## 동작 방식

화자분리의 핵심은 오디오를 **섞기 전에** 나누는 것이다.

```
마이크 입력  ──→ AVAudioEngine 탭      ──→ SpeechAnalyzer #1 ──→ [나]     ─┐
                                                                            ├─→ TranscriptTimeline ─→ JSONL + Markdown
시스템 출력  ──→ Core Audio Process Tap ──→ SpeechAnalyzer #2 ──→ [상대방] ─┘
   (Zoom/Teams가 재생하는 소리)
```

마이크로 들어온 소리는 반드시 나이고, 시스템이 재생하는 소리는 반드시 상대방이다.
소스별로 독립된 `SpeechAnalyzer`를 두면 화자 라벨이 추론 없이 확정된다.

두 경로는 **완전히 독립**이다. 한쪽 권한이 없어도 다른 쪽은 계속 돌아간다. 회의 앱
없이 혼자 말해도 마이크 전사는 되고, 오디오 캡처 권한이 없어도 내 발언은 기록된다.
둘 다 실패했을 때만 세션을 접고, 하나만 켜졌으면 무엇이 빠졌는지 팝오버에 띄운다.

### 시스템 오디오는 ScreenCaptureKit이 아니라 Core Audio Process Tap으로 받는다

ScreenCaptureKit으로도 시스템 오디오를 받을 수 있지만 **화면녹화 권한**
(`kTCCServiceScreenCapture`)을 요구한다. 오디오만 필요한데 화면 권한을 받는 것은
과도하다. 실측으로 확인한 이유 두 가지:

- ScreenCaptureKit의 진입점 `SCShareableContent`가 창·디스플레이 목록을 반환하므로,
  오디오만 원해도 화면 권한부터 검사한다. `NSAudioCaptureUsageDescription`만 넣은
  번들로 호출하면 `-3801 (userDeclined)`로 막힌다.
- 백엔드 데몬 `/usr/libexec/replayd`가 참조하는 TCC 서비스는
  `kTCCServiceScreenCapture`뿐이다. `kTCCServiceAudioCapture`는 보지 않는다.

Process Tap은 `kTCCServiceAudioCapture`만 쓴다. 화면 권한이 필요 없고, 화면 프레임을
만들지 않으므로 더 가볍다. 구조는 탭을 만들고 → 그 탭을 품은 비공개 aggregate
device를 만들고 → 그 장치에 IO 프로시저를 붙여 샘플을 받는 3단계다.

우리 앱 소리는 탭에서 제외한다. 그러지 않으면 되돌아온 소리가 다시 전사된다.

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
세그먼트로 뭉개고, 그 평균(0.823)이 en(0.877)에 지면 한국어 전체가 버려진다.

중재 규칙 세 가지는 모두 실측 실패 사례에서 나왔다.

1. **구역(region) 단위로 언어를 정한다** — 토큰 하나씩 겨루면 개별 단어의
   신뢰도가 출렁여 문장 중간에서 언어가 뒤집힌다. `en ' morning,' c=0.617` vs
   `ko ' morning' c=0.691`에서 ko가 이겨 영어 문장에 구멍이 났다.
2. **긴 단일 토큰은 구역 경계에서 제외한다** — 오답 모델은 못 알아들은 구간을
   한 단어로 길게 때운다 (`2.70~6.00s c=0.562 ' 네,'` — 한 음절이 3.3초).
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
번들 식별자에 묶어 관리하기 때문에 마이크·오디오 캡처 권한을 받을 수 없다.

`build.sh`는 키체인에서 `Developer ID Application` 또는 `Apple Development`
인증서를 찾아 서명한다. 없으면 애드혹으로 떨어지면서 경고하는데, 그 경우 시스템
오디오 캡처는 동작하지 않는다(아래 「권한」 참조). `SIGN_IDENTITY` 환경변수로 원하는
인증서를 지정할 수 있다.

코드를 수정한 뒤 빌드해서 `/Applications`에 설치하려면:

```bash
./install.sh
```

기존 `Scribird.app`은 새 빌드로 교체된다. 설치된 앱이 실행 중이면 종료한 뒤
다시 실행해야 새 빌드가 적용된다. `/Applications`에 쓰기 권한이 없으면 설치 단계에만
`sudo`를 쓴다. `INSTALL_DIR`로 설치 위치를 바꿀 수 있다.

빌드 요구사항은 Swift 6.2 이상 툴체인과 macOS 26이다 (검증 환경: Swift 6.3.3 /
macOS 26.5.2). 디버그 빌드는 액터 데이터 경합 검사가 켜진다.

## 권한

첫 실행 시 두 가지를 허용해야 한다. **화면 녹화 권한은 요구하지 않는다.**

| 권한 | 시스템 설정 항목 | 쓰임 |
|---|---|---|
| 마이크 | 개인정보 보호 및 보안 › 마이크 | 내 발언 전사 |
| 오디오 녹음 | 개인정보 보호 및 보안 › 오디오 녹음 | 상대방 목소리 전사 |

### 권한 거부는 조용히 실패한다

macOS는 두 경로 모두 **권한이 없어도 오류를 내지 않는다.** 콜백을 정상적으로
보내면서 내용만 0으로 채운다. 특히 Core Audio는 탭 생성과 aggregate device 구성을
성공(`status=0`)으로 반환한다. 실측한 실패 모드:

```
tap 생성 status=0, aggregate status=0, 콜백 374회
→ 논제로 샘플 0개, 최대 진폭 0.00000
```

탭 구성을 다섯 가지(전역/PID 명시/private 여부/서브디바이스 유무)로 바꿔 시험해도
결과가 같았으므로 구성 문제가 아니라 권한 문제다. 반환값만 믿으면 "정상 녹음 중"으로
보이기 때문에 **진폭을 근거로 따로 판정**해서 팝오버에 경고와 설정 링크를 띄운다.

같은 이유로 **애드혹 서명(`-`)으로는 시스템 오디오 캡처가 동작하지 않는다.**
TeamIdentifier가 비어 TCC가 앱을 안정적으로 식별하지 못한다. 마이크처럼
AVFoundation이 명시적으로 요청하는 권한은 그래도 뜨지만, 프로세스 탭
(`kTCCServiceAudioCapture`)은 프롬프트가 아예 나타나지 않고 무음만 흘려보냈다.
`build.sh`가 키체인의 실제 인증서를 우선 찾아 쓰는 이유다.

### 언어 모델

첫 녹취 시작 시 자동으로 내려받고 진행률이 팝오버에 표시된다. `en_US`를 요청하면
영어 변형 전체(`en_GB`, `en_AU` 등)가 함께 설치된다.

지원 로케일은 30개다 (`ko_KR`, `en_*`(9), `ja_JP`, `zh_*`, `de_*`, `fr_*`, `es_*`,
`it_*`, `pt_*`, `yue_CN`). 다른 언어를 쓰려면 `TranscriptionLanguage`에 케이스를
추가하면 된다. 동시 예약 한도(`AssetInventory.maximumReservedLocales`)는 5개다.

## 입력 레벨

녹취 중 팝오버에 소스별 실시간 레벨 미터와 dBFS 수치가 뜬다. 바에 권장 구간
(-24~-3 dBFS)을 음영으로 표시해서 "지금 레벨이 적당한가"를 눈으로 판단할 수 있다.

미터가 필요한 이유는 조용한 녹음이 **실패로 보이지 않는다**는 것이다. 전사는 낮은
레벨에서도 되므로 회의가 끝난 뒤 파일을 열어 봐야 알게 된다. 실측 사례에서 저장
파일의 피크는 -11.6 dBFS로 정상 범위였지만 발화 구간 RMS가 -47.6 dBFS로 권장치보다
24dB 낮았다. 피크가 정상이므로 파이프라인 감쇠가 아니라 녹음 조건(마이크 거리)
문제였다. 원본 보존을 위해 게인 보정은 넣지 않고 녹취 중에 확인만 하게 했다.

`AudioLevelTracker`가 세 값을 나눠 추적한다. 하나로는 안 되기 때문이다.

| 값 | 용도 | 왜 따로 두는가 |
|---|---|---|
| `recentLevel` | 미터 표시 | 상승 즉시·하강 감쇠. 세션 최대값은 한 번 튀면 남아서 미터로 못 쓴다 |
| `sessionPeak` | 무음(권한 거부) 판정 | 최근 레벨은 순간 무음에도 0이 되어 판정에 못 쓴다 |
| `averageActiveLevel` | 레벨 적정성 경고 | 피크로 보면 위 사례(피크 정상·평균 낮음)를 놓친다 |

레벨 경고는 피크가 아니라 **발화 구간 평균**으로 판정한다. 무음 구간은 게이트
(약 -50 dBFS)로 제외해서 조용한 시간이 길어도 평균이 희석되지 않게 했다.

진폭 측정은 `peakAmplitude()`로 통일했다. 흔한 `floatChannelData[0][frame]` 접근은
**디인터리브** 배치를 가정하는데, Core Audio 프로세스 탭은 Float32
**인터리브**(`L,R,L,R...`)로 준다. 엉뚱한 위치를 짚어 시스템 오디오가 항상 무음으로
오진되는 버그가 실제로 있었다. 지금은 인터리브 여부와 Int16/Int32/Float32를 모두
구분해서 읽는다.

## 출력

`~/Documents/Scribird/<날짜_시각>/`

| 파일 | 내용 |
|---|---|
| `transcript.jsonl` | 확정 발화 한 줄씩 (화자·시각·신뢰도·언어). 확정 즉시 flush |
| `transcript.md` | 화자별로 묶은 읽기용 회의록 |
| `me.m4a` | 마이크 원본 (AAC 128kbps/채널) |
| `remote.m4a` | 시스템 출력 원본 (AAC 128kbps/채널) |

JSONL을 즉시 append하는 이유는 내구성이다. 메모리에 모아 두고 종료 시 한 번에 쓰면
앱이 죽을 때 회의록 전체를 잃는다. 발화마다 쓰기를 내보내는 것만으로 앱 크래시는
막히고, 디스크 동기화까지 요청해 OS 패닉·전원 손실도 대비한다.

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
├─ ScribirdApp.swift             MenuBarExtra 진입점
├─ MeetingRecorder.swift         상태 기계 + 파이프라인 조립
├─ Audio/
│  ├─ MicrophoneCapture.swift    AVAudioEngine 탭 → 내 목소리 스트림
│  ├─ SystemAudioCapture.swift   Core Audio Process Tap → 상대방 목소리 스트림
│  ├─ AudioStreamConverter.swift AVAudioConverter 래퍼 (샘플레이트 변환)
│  ├─ AudioRecorder.swift        원본 오디오를 소스별 파일로 저장
│  ├─ AudioLevelTracker.swift    입력 레벨 추적 (미터·무음·평균)
│  └─ AVAudioPCMBuffer+Peak.swift 인터리브/비트깊이별 진폭 측정
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
   ├─ TranscriptView.swift            실시간 대화 뷰 (팝오버·플로팅 창 공용)
   ├─ FloatingTranscriptWindow.swift  포커스를 잃어도 닫히지 않는 떠 있는 창
   ├─ GlobalHotKey.swift              Carbon RegisterEventHotKey 등록
   ├─ HotKeyShortcut.swift            단축키 조합 + 저장/복원
   └─ HotKeySettings.swift            단축키 설정·등록 상태
```

## 알아 둘 점

- **마이크 공유** — macOS 입력 장치는 멀티 클라이언트라 Zoom이 쓰는 중에도 같이
  열린다. 단 Zoom의 에코 제거가 켜져 있으면 마이크 신호 특성이 바뀔 수 있다.
- **원격 오디오 품질** — 상대방 목소리는 이미 코덱을 거쳐 재생된 신호라 원본보다
  인식률이 낮다. 한국어에서 특히 체감된다.
- **잠정 결과** — 말하는 중에는 흐린 텍스트로 표시되고, 확정되면 선명해지면서
  디스크에 기록된다. 잠정 결과는 저장하지 않는다.
- **세션 중 설정 변경** — 언어와 음성 원본 저장 여부는 녹취 시작 시점에 고정된다.
  이미 만들어진 전사기·파일 핸들과 어긋나므로 녹취 중에는 잠긴다.
- **새 세션은 캡처를 끊지 않는다** — 회의가 바뀔 때 ✎ 버튼을 누르면 현재 회의록을
  마무리하고 새 회의록으로 이어서 기록한다. 중지 후 재시작과 달리 모델 확보 단계를
  다시 통과하지 않으므로 다음 회의 도입부를 놓치지 않는다. 다만 경계 직전의 발화
  하나는 확정을 기다리지 못해 짧게 끊길 수 있다.
- **전역 단축키** — 기본 `⌥⌘S`로 어디서든 전사 창을 띄운다. 이 창은 포커스를 잃어도
  닫히지 않아 회의 화면 곁에 둘 수 있다. 조합은 푸터에서 바꿀 수 있고 다시 켜도
  유지된다. 다른 앱이 같은 조합을 점유해 등록이 실패하면 푸터에 사유가 뜬다 —
  그때도 메뉴바 아이콘 경로는 그대로 동작한다.
- **중지는 6초 안에 끝난다** — 전사기 마무리를 무한정 기다리지 않는다. 하나가
  응답하지 않아도 회의록과 오디오 파일은 반드시 저장돼야 하기 때문이다. 시간이
  초과되면 남은 태스크를 취소하고 확보한 것까지 기록한다.
- **App Sandbox는 꺼져 있다** — Documents 밖에 회의록을 두거나 Core Audio 탭을
  다루는 데 유리해서다. App Store 배포가 목표라면 켜고 파일 접근 범위를 조정해야 한다.
