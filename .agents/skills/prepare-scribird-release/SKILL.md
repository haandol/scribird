---
name: prepare-scribird-release
description: Prepare, audit, or publish a Scribird release from the repository's actual shipped changes, including version selection, Korean user-facing release notes, tests, signed app and ZIP verification, checksums, tags, and GitHub Release state. Use for current/next release preparation, release-note drafting, release readiness checks, or an explicitly requested release publication; do not use for ordinary feature development.
---

# Prepare Scribird Release

릴리즈의 실제 내용과 공개 설명이 어긋나지 않게 만든다. 기본 의미의 “준비”는 로컬 변경,
노트, 검증, 아티팩트까지이며 태그 push나 GitHub Release 생성·공개는 포함하지 않는다.

## 먼저 지킬 경계

- 저장소 루트의 `AGENTS.md`, `CONTRIBUTING.md`, `README.md`,
  `Resources/Info.plist`, `build.sh`를 먼저 읽는다. 영향을 받은 영역의 ADR과
  `docs/Troubleshooting.md`도 읽는다.
- 버전 증가, 노트 작성, 빌드, 패키징은 릴리즈 운영이므로 그 자체로 ADR을 만들지 않는다.
  준비 도중 제품 동작 계약을 바꿔야 한다면 릴리즈 작업과 섞지 말고 ADR admission gate부터
  적용한다.
- 사용자의 기존 변경을 릴리즈에 임의로 포함하거나 되돌리지 않는다. 작업 트리가 더러우면
  어떤 변경이 커밋 범위 밖인지 밝히고, 안전하게 분리할 수 없으면 패키징과 공개를 중단한다.
- 녹음 음성, 생성된 회의록, 자격 증명, 개인 경로는 노트·커밋·릴리즈 자산에 넣지 않는다.
- 이미 공개된 버전의 태그나 자산을 덮어쓰지 않는다. 수정이 필요하면 새 버전을 낸다.
- 검증하지 않은 결과를 통과했다고 쓰지 않는다. 실행한 것, 수동 확인이 남은 것, 실패하거나
  건너뛴 것을 구분한다.

## 1. 릴리즈 후보를 확정한다

저장소 루트에서 사실 수집기를 실행한다.

```bash
.agents/skills/prepare-scribird-release/scripts/collect_release_facts.sh --online
```

네트워크나 GitHub 인증을 쓸 수 없으면 `--online`을 빼고 로컬 사실만 수집한다. 다른 ref를
검토할 때는 `--target <ref>`를 추가한다.

다음 순서로 릴리즈 범위를 판정한다.

1. 대상 commit SHA와 작업 트리 상태를 고정한다.
2. 대상에서 도달 가능한 최신 `vN.N.N` 태그와 최신 공개 GitHub Release를 비교한다.
3. 태그 이후의 전체 commit 제목과 본문, changed files, ADR·문서 변경을 읽는다.
4. PR/issue 정보가 있으면 사용자 영향과 실제 배포 여부를 보강하는 데 사용한다.
5. GitHub 자동 생성 노트는 누락 탐지용 대조표로만 사용하고 최종 노트로 그대로 발행하지 않는다.

대상 SHA가 최신 공개 릴리즈 태그와 같고 이후 커밋도 없다면 새 릴리즈 후보가 아니다. 사용자가
명시적으로 감사를 요청하지 않았다면 현재 버전이 이미 공개됐다고 보고하고 중단한다. 다음
버전 번호를 자동으로 올려 빈 릴리즈를 만들지 않는다.

작업 트리의 미커밋 변경은 수집 결과에 표시하되 릴리즈 범위에는 포함하지 않는다. 포함해야 한다면
먼저 정상적인 변경 검토·테스트·커밋을 마친 뒤 대상 SHA를 다시 고정한다.

## 2. 버전을 결정한다

사용자가 버전을 지정했다면 호환성 의미와 저장소 상태가 모순되지 않는지 확인한다. 지정하지
않았다면 다음 증거를 함께 제시해 버전을 제안한다.

- `feat`, `fix`, `BREAKING CHANGE`를 포함한 Conventional Commits 신호
- 사용자에게 보이는 기능·호환성·저장 형식·최소 OS 요구사항의 변화
- 기존 Scribird 릴리즈의 버전 증가 관례
- 현재가 `0.y.z` 초기 개발 계열이라는 점

커밋 type만으로 버전을 자동 확정하지 않는다. 기능이 있더라도 이 저장소의 기존 `0.1.x`
관례와 공개 호환성 의미를 함께 판단한다. 호환성을 깨는 변화는 명시적으로 드러내고 사용자가
버전 의미를 확인하게 한다.

Scribird의 버전 표기는 함께 움직여야 한다.

- `Resources/Info.plist`의 `CFBundleShortVersionString`: 공개 버전 `X.Y.Z`
- `CFBundleVersion`: 이전 공개 build보다 큰 단조 증가 정수
- annotated tag: `vX.Y.Z`
- GitHub Release title: `Scribird X.Y.Z`
- asset: `build/Scribird-X.Y.Z.zip`

이미 존재하는 태그·릴리즈, 다른 SHA를 가리키는 태그, 버전/파일명 불일치가 있으면 먼저
해결하고 진행한다.

## 3. 릴리즈 노트를 작성한다

노트를 쓰거나 검토할 때
[references/release-notes.md](references/release-notes.md)를 끝까지 읽는다.

기본 산출물은 `build/release-notes-vX.Y.Z.md`다. `build/`는 생성물 디렉터리이므로
노트 파일을 소스처럼 커밋하지 않는다. 사용자가 별도 위치를 지정하면 따른다.

노트는 기존 Scribird GitHub Release와 같이 한국어로 작성한다. 제목 아래 1~2문장으로 가장
큰 사용자 가치를 먼저 설명하고, 내용이 있는 섹션만 사용한다.

- `새로운 기능`
- `개선한 점`
- `고친 것`
- `알려진 문제` 또는 `필요한 조치`
- 관련될 때만 `화자 분리 플러그인`
- `검증`
- `설치`

각 항목은 눈에 보이는 결과 → 영향을 받는 화면·흐름·사용자 → 이점이나 필요한 행동 순으로
쓴다. 내부 타입명, 티켓 나열, 단순 diff 요약은 본문에서 제외한다. 다만 권한, 데이터 보존,
호환성, 복구 절차, 측정으로 입증된 실패를 이해하는 데 필요한 기술 사실과 수치는 보존한다.
`버그 수정 및 개선`처럼 무엇이 달라졌는지 알 수 없는 문장은 허용하지 않는다.

검증 섹션에는 실제 결과만 기록한다. 테스트 개수, skip, 서명 종류, 수동 확인, SHA-256을
추측하지 말고 해당 실행 출력에서 가져온다. 문서 링크는 가능하면 `main` 대신 릴리즈 태그
`vX.Y.Z`를 가리켜 나중에도 같은 내용을 보여주게 한다.

## 4. 로컬 릴리즈를 준비하고 검증한다

대상 버전이 아직 반영되지 않았다면 `Info.plist`의 두 버전을 함께 갱신한다. 버전 변경만
커밋할 때는 저장소 규칙에 맞는 `chore: bump version to X.Y.Z`를 사용한다. 사용자가
커밋까지 요청하지 않았다면 로컬 변경으로 남긴다.

최소 자동 검증:

```bash
swift test
./build.sh release
codesign --verify --deep --strict --verbose=2 build/Scribird.app
codesign -dv --verbose=4 build/Scribird.app
```

`codesign -dv` 출력에서 `TeamIdentifier`가 비어 있지 않고 실제 `Apple Development` 또는
`Developer ID Application` 신원으로 서명됐는지 확인한다. ad-hoc 서명은 빌드 성공이어도
시스템 오디오 캡처 릴리즈로 승인하지 않는다. 이 프로젝트는 현재 notarization을 제공하지
않으므로 notarized라고 쓰지 않는다. 설치 안내는 우클릭 `Open`만 권하지 말고, 다운로드
빌드가 차단될 때 `Done` → System Settings › Privacy & Security › Security ›
`Open Anyway` → `Open` 순서와 checksum 확인을 포함한다.

영향받은 영역에 해당하는 `AGENTS.md` 수동 smoke test를 수행하거나, 실행할 수 없으면 릴리즈
차단 항목으로 남긴다. 캡처·세션 회전·전역 단축키·설정 창·실시간 언어 변경처럼 실제 앱과
하드웨어가 필요한 검증을 unit test로 대체했다고 주장하지 않는다.

서명된 앱을 macOS 메타데이터를 보존하는 ZIP으로 만든다. 같은 이름의 파일이 있으면 자동으로
덮어쓰지 말고 기존 파일의 출처를 확인한다.

```bash
version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
archive="build/Scribird-${version}.zip"
test ! -e "$archive"
ditto -c -k --sequesterRsrc --keepParent build/Scribird.app "$archive"
unzip -t "$archive"
shasum -a 256 "$archive"
```

`mktemp -d`로 만든 임시 디렉터리에 ZIP을 풀어 앱 버전과 서명을 다시 검증한다. 임시 디렉터리는
정확한 경로가 확인된 뒤에만 정리한다. 최종적으로 아래가 모두 일치해야 한다.

- `Info.plist` 공개 버전
- 앱 번들 안의 공개 버전과 build 번호
- tag와 Release title
- ZIP 파일명
- 노트에 적은 버전과 checksum

## 5. 준비 결과를 보고한다

다음을 한 번에 요약한다.

- 대상 버전, target SHA, 비교한 이전 릴리즈
- 사용자에게 보이는 주요 변경
- 노트 파일 경로
- 테스트·빌드·서명 결과와 수동 검증 상태
- ZIP 경로, 크기, SHA-256
- 커밋·태그·push·GitHub draft·공개 중 어디까지 완료했는지
- 남은 blocker

## 6. 원격 릴리즈는 명시적으로 요청받았을 때만 수행한다

첫 원격 변경 전에 정확한 버전, target SHA, 제목, 최종 노트, asset checksum을 사용자에게
보여준다. 사용자가 이미 이 값들을 보고 해당 릴리즈의 push·공개를 명시적으로 요청했다면
같은 내용을 다시 묻지 않는다.

원격 작업은 commit과 tag가 준비되고 검증된 뒤 다음 순서를 따른다.

1. annotated tag `vX.Y.Z`를 정확한 release commit에 만든다.
2. branch와 tag를 push한다.
3. 먼저 GitHub draft를 만들고 ZIP을 첨부한다.
4. draft 본문, target SHA, asset 이름과 digest를 다시 확인한다.
5. 공개 승인이 있으면 draft를 publish하고 `Latest` 상태를 확인한다.

예시:

```bash
gh release create "v${version}" "$archive" \
  --repo haandol/scribird \
  --draft \
  --verify-tag \
  --fail-on-no-commits \
  --title "Scribird ${version}" \
  --notes-file "build/release-notes-v${version}.md"
```

`--clobber`로 공개 asset을 교체하지 않는다. 공개 후에는 `gh release view`로 tag, target,
본문, 공개 상태, asset digest를 확인하고, 가능하면 새 임시 디렉터리에 asset을 다시 받아
로컬 SHA-256 및 서명을 대조한다. 문제가 발견되면 공개된 버전을 조용히 수정하지 말고 상태를
명확히 알린 뒤 새 버전으로 수정한다.
