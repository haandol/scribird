<div align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Scribird" />

  <h1>Scribird</h1>

  <p><strong>회의를 실시간으로 전사하는 macOS 메뉴바 앱. 전부 온디바이스에서.</strong></p>

  <p>
    <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT" /></a>
    <img src="https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg" alt="Platform: macOS 26+" />
    <img src="https://img.shields.io/badge/Swift-6.2%2B-orange.svg" alt="Swift 6.2+" />
    <a href="https://github.com/haandol/scribird/releases/latest"><img src="https://img.shields.io/github/v/release/haandol/scribird?label=release" alt="Latest release" /></a>
  </p>
</div>

Zoom·Teams 회의를 말하는 동시에 받아 적는다. 마이크는 「나」, 스피커로 나오는 소리는
「상대방」으로 자동 구분되고, 회의가 끝나면 회의록과 원본 오디오가 폴더 하나에 남는다.

전사·저장 전부 기기 안에서 처리된다. **회의 음성도 회의록도 기기를 떠나지 않는다.**
네트워크를 쓰는 곳은 사용자가 설정에서 «새 버전 확인»을 누를 때 한 번뿐이고, 그
요청에도 회의 내용·사용 통계·기기 식별자를 담지 않는다. 자동 조회는 없다.

## 왜 만들었나

회의 전사 서비스는 이미 많지만 대부분 음성을 서버로 보낸다. 고객사 이름, 미공개
일정, 인사 얘기가 섞이는 회의를 외부로 흘리지 않으려면 결국 기기 안에서 끝나야
한다. macOS 26의 온디바이스 `SpeechAnalyzer`가 그걸 가능하게 만들었고, 그 위에
**권한을 최소로 요구하는** 회의 녹취기를 올린 것이 Scribird다. 화면 녹화 권한도,
접근성 권한도 요구하지 않는다 — 마이크와 오디오 녹음, 둘뿐이다.

## 주요 기능

|  | |
|---|---|
| **화자 자동 구분** | 마이크는 「나」, 시스템 출력은 「상대방」. 오디오 경로가 화자를 정하므로 추론 오류가 없다 |
| **실시간 전사** | 말하는 중에는 흐리게, 확정되면 선명하게. 확정 즉시 디스크에 기록된다 |
| **한국어 + English** | 두 언어를 동시에 인식한다. 코드스위칭 회의도 토큰 단위 중재로 양쪽을 살린다 |
| **원본 오디오 보관** | 소스별 `.m4a`로 리샘플링 전 신호를 남긴다 — 나중에 재전사할 수 있다 |
| **조용한 실패를 드러냄** | 권한 거부는 오류 없이 무음만 흘려보낸다. 진폭으로 판정해 녹취 중에 경고한다 |
| **입력 레벨 미터** | 소스별 실시간 dBFS와 권장 구간 표시. 회의가 끝난 뒤에 알게 되는 일을 막는다 |
| **회의 단위 세션 경계** | 회의가 바뀌면 캡처를 끊지 않고 산출물만 갈아 끼운다 — 다음 회의 도입부를 놓치지 않는다 |
| **전역 단축키** | 어디서든 `⌥⌘S`로 전사 창을 띄운다. 포커스를 잃어도 닫히지 않는다 |

## 화면

전사 창 하나가 회의 중에 필요한 것을 다 담는다 — 상태와 경과 시간, 소스별 입력 레벨,
대화, 저장 폴더. 설정은 `⌘,`로 여는 별도 창에 있어서 전사를 가리지 않는다.

```
  ● 녹취 중  00:04:12                    한국어 + English   [✎]  [■ 중지]
 ───────────────────────────────────────────────────────────────────────
  🎙 나  ▐▐▐▐▐▐░░░ -19 dB        🔊 상대방  ▐▐▐▐░░░░░ -26 dB
 ───────────────────────────────────────────────────────────────────────

  🔊 상대방 · KO · 00:00:03
    ( 안녕하세요. 오늘 배포 일정 검토부터 시작하겠습니다. )

                                             00:00:11 · KO · 나 🎙
                    ( 네, 준비됐습니다. 화면 공유하겠습니다. )

  🔊 상대방 · EN · 00:00:18
    ( Sure. The release is scheduled for Friday afternoon. )

                                             00:00:24 · KO · 나 🎙
                    ( 좋습니다. 그럼 그렇게 진행하겠습니다 )   ← 잠정(흐림)

 ───────────────────────────────────────────────────────────────────────
  📁 저장 폴더 열기                  12개 발화     ⚙ 설정     ⏻ 종료
```

「나」는 오른쪽, 「상대방」은 왼쪽으로 정렬되고 색이 다르다. `KO`/`EN` 배지는 그 발화가
어느 언어로 인식됐는지 보여준다 — 다국어 회의에서 결과를 해석하려면 필요하다. 아직
확정되지 않은 발화는 흐리게 표시되고, 확정되는 순간 선명해지면서 디스크에 기록된다.

레벨 미터의 음영 구간은 권장 범위(-24~-3 dBFS)다. 바가 그 구간에 닿아야 나중에 들을
수 있는 녹음이다. 무음이 이어지면 그 자리에 원인과 시스템 설정 링크가 함께 뜬다.

> 실제 화면 캡처는 아직 넣지 않았다. 위 도식은 실제 레이아웃을 그대로 옮긴 것이고,
> 캡처 이미지는 다음 릴리즈에 추가할 예정이다.

## 설치

### 릴리즈에서 받기

[최신 릴리즈](https://github.com/haandol/scribird/releases/latest)에서 `Scribird-<버전>.zip`을
받아 압축을 풀고 `Scribird.app`을 `/Applications`에 옮긴다.

> **공증(notarization)을 받지 않은 빌드다.** 처음 열 때 Gatekeeper가 막으므로 앱을
> **우클릭 → 열기**로 실행하거나, 시스템 설정 › 개인정보 보호 및 보안에서 «확인 없이
> 열기»를 누른다. 이 과정이 불편하면 아래처럼 직접 빌드하는 편이 깔끔하다.

### 소스에서 빌드

Swift 6.2 이상 툴체인과 macOS 26이 필요하다 (검증 환경: Swift 6.3.3 / macOS 26.5.2).

```bash
git clone https://github.com/haandol/scribird.git
cd scribird
./install.sh          # 릴리즈 빌드 후 /Applications/Scribird.app 으로 교체
```

빌드만 하고 그 자리에서 실행해 보려면:

```bash
./build.sh release
open build/Scribird.app
```

`.app` 번들로 감싸고 코드서명까지 해야 한다. 맨몸 실행 파일은 macOS가 권한(TCC)을
번들 식별자에 묶어 관리하기 때문에 마이크·오디오 캡처 권한을 받을 수 없다.

**서명은 배포용이 아니라 기능 요건이다.** `build.sh`는 키체인에서
`Developer ID Application` 또는 `Apple Development` 인증서를 찾아 서명한다
(`SIGN_IDENTITY`로 지정 가능). 없으면 애드혹으로 떨어지는데, 그 경우
TeamIdentifier가 비어 **시스템 오디오 캡처가 조용히 무음만 흘려보낸다.** 상대방
목소리가 안 잡히면 탭 설정보다 서명 identity를 먼저 확인하는 게 빠르다.

## 사용법

1. 메뉴바의 파형 아이콘을 클릭하거나 `⌥⌘S`를 눌러 전사 창을 띄운다.
2. **시작**을 누른다. 첫 실행이면 언어 모델을 내려받고 진행률이 표시된다.
3. 두 레벨 미터가 모두 움직이는지 확인한다 — 안 움직이면 그 소스는 들어오지 않는 것이다.
4. 회의가 바뀌면 ✎ 버튼으로 회의록을 끊는다. 캡처는 끊기지 않는다.
5. **중지**를 누르면 6초 안에 마무리하고 저장 폴더 링크가 뜬다.

회의 언어, 원본 오디오 저장, 단축키, 버전 확인은 `⌘,` 설정 창에 있다. 전사 화면에는
회의 중에 보는 것만 남겼다.

### 결과물

`~/Documents/Scribird/<날짜_시각>/`

| 파일 | 내용 |
|---|---|
| `transcript.jsonl` | 확정 발화 한 줄씩 (화자·시각·신뢰도·언어). 확정 즉시 flush |
| `transcript.md` | 화자별로 묶은 읽기용 회의록 |
| `me.m4a` | 마이크 원본 (AAC 128kbps/채널) |
| `remote.m4a` | 시스템 출력 원본 (AAC 128kbps/채널) |

## 권한

첫 실행 시 두 가지를 허용해야 한다. **화면 녹화 권한은 요구하지 않는다.**

| 권한 | 시스템 설정 항목 | 쓰임 |
|---|---|---|
| 마이크 | 개인정보 보호 및 보안 › 마이크 | 내 발언 전사 |
| 오디오 녹음 | 개인정보 보호 및 보안 › 오디오 녹음 | 상대방 목소리 전사 |

한쪽 권한이 없어도 다른 쪽은 계속 돌아간다. 회의 앱 없이 혼자 말해도 마이크 전사는
되고, 오디오 캡처 권한이 없어도 내 발언은 기록된다. 둘 다 실패했을 때만 세션을 접는다.

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

시스템 오디오를 ScreenCaptureKit이 아니라 **Core Audio Process Tap**으로 받는 이유는
권한이다. ScreenCaptureKit은 오디오만 원해도 화면녹화 권한
(`kTCCServiceScreenCapture`)부터 검사한다 — 진입점 `SCShareableContent`가 창·디스플레이
목록을 반환하는 API이고, 백엔드 데몬 `/usr/libexec/replayd`가 참조하는 TCC 서비스도
그것뿐이다. `NSAudioCaptureUsageDescription`만 넣은 번들로 호출하면
`-3801 (userDeclined)`로 막힌다. Process Tap은 `kTCCServiceAudioCapture`만 쓴다.

설계 판단의 배경과 검토한 대안은 [`docs/adr/`](./docs/adr/)에 ADR로 남겨 두었다.
왜 이렇게 됐는지 궁금하다면 그쪽이 원본이다.

- [시스템 오디오 캡처 경로](./docs/adr/capture/0001-system-audio-process-tap.md) — ScreenCaptureKit을 쓰지 않는 이유
- [조용한 캡처 실패 판정](./docs/adr/capture/0002-silent-capture-detection.md) — 반환값 대신 진폭으로 판정
- [소스 기반 화자 확정](./docs/adr/transcription/0001-source-based-speaker-attribution.md) — 2화자 상한을 수용한 근거
- [토큰 단위 언어 중재](./docs/adr/transcription/0002-token-level-language-arbitration.md) — 코드스위칭 실측과 세 규칙
- [회의록 내구성](./docs/adr/archive/0001-transcript-durability.md) — 확정 즉시 append
- [원본 오디오 포맷](./docs/adr/archive/0002-original-audio-format.md) — AAC 128k, 64k를 버린 이유

## 알아 둘 점

측정해서 알게 된 것들이다. 쓰기 전에 알아 두면 덜 당황한다.

- **화자는 「나」 vs 「상대방 전원」 2분리가 상한이다.** 참석자를 개인별로 구분하지
  못한다. Apple Speech에 diarization API가 없고, 회의 앱이 참석자별 스트림을
  믹스다운한 뒤 CoreAudio로 넘기기 때문이다. 원본 오디오를 소스별로 남기는 이유가
  이것이다 — 나중에 화자분리 모델을 붙여 재처리할 수 있다.
- **원격 오디오는 인식률이 낮다.** 상대방 목소리는 이미 코덱을 거쳐 재생된 신호다.
  한국어에서 특히 체감된다.
- **Zoom과 마이크를 같이 쓸 수 있다.** macOS 입력 장치는 멀티 클라이언트라 회의 앱이
  쓰는 중에도 함께 열린다. 단 회의 앱의 에코 제거가 켜져 있으면 마이크 신호 특성이
  바뀔 수 있다.
- **회의 언어가 하나면 그 언어를 고르는 게 정확하다.** 다국어 구성에서는 코드스위칭
  경계의 발화가 짧게 잘릴 수 있다. 단일 언어를 고르면 중재기를 아예 만들지 않으므로
  이런 손실이 없다.
- **녹취 중에는 언어와 원본 저장 여부가 잠긴다.** 이미 만들어진 전사기·파일 핸들과
  어긋나기 때문이다.
- **중지는 6초 안에 끝난다.** 전사기 하나가 응답하지 않아도 회의록과 오디오 파일은
  반드시 저장돼야 하므로, 초과하면 남은 태스크를 취소하고 확보한 것까지 기록한다.
- **App Sandbox는 꺼져 있다.** Core Audio 탭을 다루고 Documents에 회의록을 두는 데
  유리해서다. App Store 배포가 목표라면 켜고 파일 접근 범위를 조정해야 한다.

## 개발

```bash
swift build -c debug   # 액터 데이터 경합 검사 켜고 빌드
swift test             # 유닛 테스트 188개 (하드웨어·네트워크 불필요)
./build.sh release     # build/Scribird.app 생성 + 서명
./install.sh           # 릴리즈 빌드 후 /Applications 로 설치
```

앱은 맨몸 실행 파일이 아니라 번들로 실행해야 한다 — 권한(TCC)이 번들 식별자에 묶여
있다. 하드웨어 캡처·세션 경계·전역 단축키는 `swift test`로 덮을 수 없어 수동 스모크
테스트가 필요하다. 절차는 [AGENTS.md](./AGENTS.md)에 있다.

```
Sources/Scribird/
├─ ScribirdApp.swift             MenuBarExtra 진입점
├─ MeetingRecorder.swift         상태 기계 + 파이프라인 조립
├─ Audio/                        마이크·시스템 오디오 캡처, 변환, 레벨, 원본 저장
├─ Transcription/                SpeechAnalyzer 세션, 언어 구성, 모델 설치, 언어 중재
├─ Transcript/                   화자·세그먼트 모델, 시간축 병합, JSONL/Markdown 저장
└─ UI/                           전사 뷰, 설정 창, 플로팅 창, 전역 단축키, 버전 확인
```

구조와 코딩 규약, 그리고 **깨뜨리면 안 되는 아키텍처 불변식**은
[AGENTS.md](./AGENTS.md)에 정리해 두었다. 캡처나 전사 경로를 손대기 전에 먼저 읽는
것을 권한다 — 각 항목이 실측으로 정해진 것이고, 되돌리면 눈에 잘 안 띄는 버그가
다시 들어온다.

## 기여

이슈와 PR 모두 환영한다. 동작이 바뀌는 변경은 [`docs/adr/`](./docs/adr/)의 해당 ADR을
먼저 갱신한 뒤 코드를 맞춘다. 커밋 제목은 한국어로 짧게 쓰고, 본문에는 *왜*를 적는다 —
측정에서 나온 변경이면 그 숫자와 배제한 실패 모드까지 남긴다. 이 저장소의 하드웨어
동작 기록은 대부분 커밋 메시지에 있다.

**녹음된 회의 음성이나 생성된 회의록은 절대 커밋하지 않는다.**

## 라이선스

[MIT](./LICENSE)
