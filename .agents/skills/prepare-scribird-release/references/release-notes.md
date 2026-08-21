# Scribird 릴리즈 노트 작성 기준

## 사실을 모으는 순서

릴리즈 노트 초안이 사실의 원천이 되어서는 안 된다. 다음 증거를 하나의 릴리즈 레코드로 모은
뒤 사용자용 문장으로 편집한다.

1. 릴리즈 target SHA와 이전 공개 tag 사이의 실제 diff
2. commit 제목과 본문, 관련 PR·issue
3. 변경된 ADR, README, Troubleshooting, 권한·설치 문서
4. 테스트, release build, 서명, 수동 smoke test의 실제 출력
5. 지원·복구 정보와 알려진 문제

계획됐지만 target에 없는 변경은 제외한다. target에 있으나 사용자에게 의미 없는 refactor,
test-only, 문서 정리는 사용자 노트에서 생략할 수 있지만, 릴리즈 안전성이나 운영자 행동에
영향을 주면 검증 또는 기술 참고로 남긴다.

## 중요도 분류

초안을 쓰기 전에 항목을 분류한다.

- A: 새 기능, 큰 UX 변화, 호환성 파괴, 권한·접근·데이터 변화, 보안 수정, 사용자 조치 필요
- B: 기존 흐름의 의미 있는 개선, 사용자가 체감하는 신뢰성 수정, 중요한 설정 변화
- C: 작은 시각 보정, 낮은 가시성 수정, 내부 유지보수

A를 가장 먼저 쓰고 C가 더 중요한 내용을 묻지 않게 한다. C는 사용자에게 실제 결과가 없으면
공개 노트에서 제외한다.

## 문장 규칙

- 첫 구절에 사용자가 얻게 된 결과를 둔다.
- 어느 화면·상황·역할에 영향을 주는지 필요한 만큼만 밝힌다.
- 사용자가 해야 할 행동이 있으면 문장 끝이 아니라 눈에 띄는 별도 항목으로 둔다.
- 구현은 사용자 영향으로 번역하고, 이해에 필요하지 않은 내부 설명은 생략한다.
- `개선한 점`과 `고친 것`은 항목마다 짧은 제목과 1~2문장을 기본으로 한다.
- 원인 분석, 내부 처리 순서, 프레임워크·API·타입명, 포맷 변환 과정은 본문에 넣지 않는다.
- 재현 횟수, 대기 시간, 바이트 수, 내부 상태값 같은 측정 세부는 ADR·commit·검증 기록에
  남긴다.
- 정확한 값은 사용자 조치, 권한, 호환성, 데이터 보존, 보안, 알려진 문제, 복구에 꼭 필요할
  때만 사용자 본문에 쓴다.
- “버그 수정 및 개선”, “성능 최적화”, “안정성 향상”을 단독 문장으로 쓰지 않는다.
- ticket ID, 내부 타입명, commit hash는 일반 사용자 본문 대신 필요한 기술 부록이나 링크에 둔다.
- breaking change, 제거, deprecation, 권한 변화, 저장 형식 변화는 빠뜨리지 않는다.
- 보안 수정은 악용을 돕지 않는 범위에서 영향과 업데이트 필요성을 명확히 쓴다.

변환 패턴:

```text
내부 사실:
Speech model reservation과 installation state machine을 분리했다.

사용자 노트:
이미 설치된 한국어 모델이 사라지거나 설치가 0%에서 멈추던 문제를 고쳤습니다.
```

```text
내부 사실:
AudioRecorder가 두 source를 frame timeline에서 mono AAC로 합친다.

사용자 노트:
마이크와 시스템 오디오를 바로 재생할 수 있는 meeting.m4a 하나로 저장합니다.
```

## 기본 템플릿

내용이 없는 섹션은 제거한다.

```markdown
이번 릴리즈는 <가장 큰 사용자 가치>를 제공합니다.

## 새로운 기능

**<짧은 결과 중심 제목>.** <어디서 무엇이 달라졌고 왜 유용한지>.

## 개선한 점

**<짧은 결과 중심 제목>.** <기존 흐름이 어떻게 더 나아졌는지 1~2문장으로 설명>.

## 고친 것

**<사용자가 겪던 증상>.** <이제 어떻게 동작하는지 1~2문장으로 설명>.
<사용자 조치가 필요할 때만 복구 링크나 정확한 조건 추가>.

## 필요한 조치

- <업데이트 전후 사용자가 해야 할 일>

## 알려진 문제

- <영향 범위, 우회 방법, 후속 계획>

## 검증

- `swift test`: <통과 수와 실제 skip/failure>
- release build 및 <실제 서명 종류> 검증
- <실제로 수행한 관련 수동 smoke test>
- 릴리즈 ZIP SHA-256: `<digest>`

## 설치

`Scribird-X.Y.Z.zip`을 내려받아 압축을 풀고 `Scribird.app`을 응용 프로그램 폴더로
옮기세요. 현재 빌드는 notarized가 아니므로 macOS 26에서 처음 실행하면 *Move to Trash*와
*Done*만 있는 경고가 나타날 수 있습니다. **Done**을 누른 뒤 System Settings › Privacy &
Security의 **Security**에서 Scribird 옆 **Open Anyway**를 누르고 다시 **Open**을
확인하세요. 자세한 절차와 checksum 확인 방법은 README의 Installation을 참고하세요.
```

## 채널별 역할

- GitHub Release 본문: 사용자 가치, 필요한 행동, 알려진 문제, 설치, 검증
- tag와 commit: 정확한 변경 이력과 추적성
- ADR: 결정과 대안, 측정 근거
- Troubleshooting: 긴 복구 절차
- 자동 생성 GitHub notes: PR 누락을 찾는 대조표

같은 내용을 모든 채널에 복사하지 않는다. GitHub Release에서 긴 복구 절차가 필요하면 해당
버전의 `docs/Troubleshooting.md`로 연결한다.

## 참고한 베스트 프랙티스

- Capgo, “2026년 애플리케이션 릴리스 노트: 완전한 안내서”
  - https://capgo.app/ko/blog/application-release-notes/
  - 릴리즈 끝의 글쓰기 작업이 아니라 commit·ticket·QA·지원 정보를 모으는 입력 pipeline으로
    다루고, 사용자 영향으로 순위를 매기며, 자동화는 수집에 쓰고 최종 판단은 사람이 검토한다.
- Keep a Changelog 1.1.0
  - https://keepachangelog.com/en/1.1.0/
  - 노트는 사람이 읽는 선별된 기록이며 commit log dump가 아니다. 최신 릴리즈 우선, 날짜와
    변경 유형, breaking/deprecation/removal을 명확히 한다.
- GitHub Docs, Automatically generated release notes
  - https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes
  - 자동 노트는 merged PR, contributor, full changelog를 수집하고 label로 분류할 수 있지만,
    발행 전 포함·누락을 검토해야 한다.
- Semantic Versioning 2.0.0
  - https://semver.org/spec/v2.0.0.html
  - 버전은 호환성 의미를 전달하며 한번 공개한 버전의 내용은 바꾸지 않고 새 버전으로 수정한다.
- Conventional Commits 1.0.0
  - https://www.conventionalcommits.org/en/v1.0.0/
  - `feat`, `fix`, `BREAKING CHANGE`는 변경 의도를 구조화해 수집과 버전 판단을 돕지만,
    최종 사용자 노트는 그대로 복사하지 않고 사용자 영향으로 편집한다.
