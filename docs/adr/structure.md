# ADR 디렉토리 구조와 매핑

`docs/adr/` 의 폴더 레이아웃, 카테고리 분할 규칙, ADR 레지스트리(`.mapping.json`) 정책을 모은다. 작성 규칙은 [`authoring-rules.md`](./authoring-rules.md), 개념과 의존성 모델은 [`README.md`](./README.md) 참조.

## 디렉토리 구조 — DDD 도메인(bounded context) × 피쳐(vertical slice)

폴더 트리는 **두 축**으로 조직한다 — 둘 다 기존 2단계 키 안에서 표현되며 새 깊이를 더하지 않는다.

- **최상위 폴더 = bounded context (DDD 도메인 단위)**. 도메인 전문가의 ubiquitous language 로 이름 붙인 모델 경계다 (`identity/`, `ordering/`, `catalog/`). 한 context 는 보통 **여러 피쳐를 품는다**.
- **sub-folder = 피쳐(vertical slice)**. 한 사용자 동작을 UI → API → Data 로 끝까지 추적하는 단위 (`identity/login/`, `ordering/checkout/`). ALPS Section 7 feature 와 1:1 로 매핑된다.

**context 가 피쳐를 하나만 가지면 sub-folder 를 생략하고 평면(flat) 구조로 둔다** — 단일 세그먼트 키는 context==feature 를 뜻한다. 워크숍·소규모 프로젝트나 기존 평면 레이아웃(`auth/`, 워크숍 Feature ID `f1/`)은 그대로 두면 되고, 별도 마이그레이션이 필요 없다 — 평면 폴더는 "피쳐 하나짜리 context" 로 재해석된다.

```
docs/adr/
├── README.md                    # 개념 인덱스 (ADR 목록도 트리도 두지 않음)
├── authoring-rules.md           # 작성 규칙 · 결정 로그 기준 · 리뷰 체크리스트
├── structure.md                 # 이 문서 — 디렉토리 레이아웃 · 매핑 정책
├── decision-log.template.md     # decision-log.md 시드 (읽기용 — 카테고리에 복사해 쓴다)
├── .mapping.json                # ADR 레지스트리/인덱스 (adrs·dependsOn·subdomainType. 코드 경로도 PRD 참조도 저장 안 함)
├── identity/                       # BOUNDED CONTEXT (core subdomain)
│   ├── 0001-token-rotation.md      # context 전반 cross-cutting 결정 (부모 폴더 직속)
│   ├── decision-log.md             # (선택) 이 카테고리의 major 결정 변경 이력 — 컨벤션 파일, 매핑 미등록
│   ├── login/                      # 피쳐 (vertical slice — UI/API/Data 모두 포함)
│   │   └── NNNN-kebab-title.md
│   └── signup/                     # 피쳐
│       └── NNNN-kebab-title.md
├── ordering/                       # BOUNDED CONTEXT (core subdomain)
│   ├── checkout/                   # 피쳐
│   │   └── NNNN-kebab-title.md
│   └── refund/                     # 피쳐
│       └── NNNN-kebab-title.md
├── pricing/                        # BOUNDED CONTEXT (supporting subdomain) — 단일 피쳐면 flat
│   └── NNNN-kebab-title.md
└── payments/                       # BOUNDED CONTEXT (generic subdomain) — 외부 게이트웨이 연동
    └── NNNN-kebab-title.md
```

규칙:

- 최상위 폴더는 **bounded context(DDD 도메인) 단위**로 만든다 — 도메인 전문가가 인지하는 모델 경계 (`identity/`, `ordering/`, `catalog/`, `billing/`). 한 context 가 피쳐를 여럿 품으면 그 피쳐들을 sub-folder 로 둔다.
- sub-folder 는 **사용자가 인지하는 피쳐(vertical slice) 단위**로 만든다 (`identity/login/`, `ordering/checkout/`). 한 피쳐 안에서 UI / API / 데이터 결정이 모두 같은 sub-folder(또는 단일-피쳐 context 의 평면 폴더)에 모인다 — 다이어그램 하나로 user action → API → store 흐름이 끝까지 보여야 한다.
- **금지(양 레이어 모두 적용)**: `frontend/`, `backend/`, `api/`, `ui/`, `db/`, `controllers/`, `services/` 같은 기술 레이어 이름을 context 폴더에도 피쳐 sub-folder 에도 쓰지 않는다. 한 피쳐의 결정이 레이어별로 흩어지면 vertical slice 추적이 깨진다.
- context 전반에 걸친 cross-cutting 결정(예: `identity/` 전체의 토큰 회전 정책)은 **그 context 폴더 직속**에 둔다 (`identity/0001-token-rotation.md`) — 어느 피쳐 sub-folder 에도 속하지 않는 결정의 자리다.
- 시스템 전체에 걸친 cross-cutting context(`infra/`, `integration/`, `security/`, `platform/`)는 두 개 이상의 context/피쳐가 명시적으로 의존할 때만 만든다 (아래 "cross-cutting context — 정말 공유하는 결정만").
- 키는 **최대 2 세그먼트**(`<context>` 또는 `<context>/<feature>`). 그 이상으로 깊어지지 않는다.
- 파일명: `NNNN-kebab-case-title.md`. 번호는 그 폴더(context 직속 또는 피쳐 sub-folder) 안에서 순차 증가.
- 새 context/피쳐 폴더를 추가하면 `.mapping.json` 의 카테고리 키와 `adrs[]` path 를 갱신한다. 위 트리는 이 문서가 들고 있는 개념 예시이므로, 실제 레이아웃과 크게 어긋날 때만 함께 손본다 ([`README.md`](./README.md) 는 개념 인덱스만 두고 트리도 per-ADR 목록도 두지 않는다).

> **용어**: 이 문서에서 "카테고리(category)" 는 `.mapping.json` 의 entry 키 한 개를 가리키는 중립어다 — 단일-피쳐 context 면 `identity`, 다중-피쳐 context 면 `identity/login` 처럼 세그먼트 수가 다를 뿐 둘 다 한 개의 카테고리 entry 다. "bounded context" 는 최상위 폴더(도메인 경계), "피쳐(vertical slice)" 는 leaf(한 사용자 동작) 를 가리킨다.

### context 가 비대해질 때 — 피쳐 sub-folder 로 분할

ADR이 누적되면 한 context(또는 피쳐 폴더)에 결정이 쌓여 번호만 보고는 무엇을 다루는 ADR인지 찾기 어려워진다. context 가 여러 피쳐를 품는다는 원칙을 유지하면서, **평면(단일-피쳐) context 를 피쳐 sub-folder 로 풀어** 한 단계의 sub-folder 만 둘 수 있게 한다. 이것이 평면 키(`pricing`)가 2-세그먼트 키(`identity/login`)로 자라는 정상 경로다.

**분할 임계값**: 한 피쳐 sub-folder, 또는 context 직속에 평면으로 쌓인 ADR이 **15개 이상**이면 분할을 제안한다. context 가 이미 여러 피쳐 sub-folder 로 나뉘어 있고 각 sub-folder 가 15 미만이면 — context 전체 합계가 크더라도 — 분할하지 않는다 (한 context 가 피쳐를 여럿 품는 것은 정상이다). 평면 구조 유지가 기본 — 너무 이른 분할은 한 피쳐를 작게 쪼개 vertical slice 추적을 약화시킨다.

**분할 규칙**:

- **최대 1단계 깊이**: `docs/adr/<context>/<feature>/NNNN-...md` 까지만. 2단계 이상은 만들지 않는다 (`identity/login/social/...` 금지).
- **sub-folder 는 피쳐(vertical slice)**: ALPS Section 7 의 feature 와 1:1 로 매핑되는 사용자가 인지하는 단위로 자른다 — `identity/login/`, `identity/signup/`, `identity/password-reset/`, `ordering/checkout/`, `ordering/refund/` 처럼 한 사용자 동작에 해당하는 묶음. UI/API/Data 결정이 sub-folder 안에서 모두 끝나야 한다.
- **금지되는 sub-folder**: `identity/api/`, `identity/db/`, `identity/components/`, `identity/services/` 같은 **기술 레이어 분할** — 안티패턴 카테고리 규칙과 동일하게 vertical slice 가 깨진다. 분할 후에도 한 sub-folder 안에 UI → API → Data 가 모여야 한다.
- **번호 정책**: sub-folder 안에서 `NNNN` 을 새로 시작한다. 분할 시 기존 ADR 의 번호를 재배치하지 않는다 — 결번을 유지하고 git 이력으로 추적하며, 본문은 그대로 옮기기만 한다. (전체 renumber 정책은 [`authoring-rules.md`](./authoring-rules.md) "명명 규칙" — renumber 는 `adr-rollup` 만의 단계다.)
- **피쳐 sub-folder vs 형제 context (`identity-sso/`)**: 두 피쳐가 진짜로 독립된 모델 경계이고 cross-cutting 결정도 거의 공유하지 않으면 형제 context(`identity/`, `identity-sso/`)가 더 깔끔하다. 한 context 안에서 공통 결정(예: `identity/0001-token-rotation.md`)을 부모 폴더에 남겨야 하는 경우에만 피쳐 sub-folder 를 쓴다.
- **`.mapping.json` 인덱스**: sub-folder 가 생기면 `identity/login`, `identity/signup` 을 각각 별도 카테고리 키로 등록하고, 옮긴 ADR 의 `adrs[]` path 를 새 sub-folder 경로로 갱신한다. context 직속에 남은 cross-cutting ADR(예: `identity/0001-token-rotation.md`)은 부모 context 키의 `adrs[]` 에 그대로 둔다.
- **키 정책**: 피쳐 sub-folder 도 별도 카테고리 entry 로 등록한다 — 키는 `identity/login` 처럼 슬래시를 유지. 카테고리 키가 피쳐 디렉토리명과 일치하면 "관련 코드 찾기" 의 첫 후보로 쓰기 좋으니 키 형식의 일관성을 지킨다. `subdomainType`(core/supporting/generic)은 context 수준 entry 에 둔다 (아래 "ADR 레지스트리 (.mapping.json)").

```
docs/adr/
├── README.md
├── .mapping.json
├── identity/                    # bounded context (부모)
│   ├── 0001-token-rotation.md   # identity 전반에 걸친 cross-cutting 결정 (부모에 그대로)
│   ├── login/                   # 피쳐 (vertical slice)
│   │   ├── 0001-password-policy.md
│   │   ├── 0002-rate-limit.md
│   │   └── decision-log.md      # (선택) login 피쳐의 major 결정 변경 이력
│   └── signup/
│       └── 0001-email-verification.md
└── ordering/
    └── 0001-...md               # 임계값(15) 미만이면 분할하지 않는다 (단일-피쳐 context, flat)
```

**언제 sub-folder 를 만들지 않는가**:

- ADR 개수가 15 미만 — 평면 구조 유지 (단일-피쳐 context 그대로).
- ADR이 많아도 모두 같은 피쳐라면 — 그건 `/adr-rollup` 이 다룰 evolution chain 일 가능성이 높다. 먼저 rollup 으로 압축한 뒤 그래도 비대하면 분할.
- vertical slice 경계가 모호하면 분할하지 않는다 — 잘못 자르면 한 결정이 두 폴더에 흩어진다.

**점검·제안 절차** (`/adr-new`, `/adr-sync` 가 카테고리에 손댈 때 공통 호출):

1. 작업 대상 폴더(피쳐 sub-folder 또는 context 직속)의 `*.md` 개수를 센다 — 매핑의 `adrs[]` 가 아니라 실제 파일 기준.
2. **15개 미만이면 그대로 진행**. 분할은 제안조차 하지 않는다.
3. **15개 이상이면 한 번 제안한다**. 사용자가 거절하면 같은 세션에서 다시 묻지 않고 계속 진행한다 — 분할은 강제가 아니다.
4. 제안할 때 피쳐 후보를 함께 보여준다. 기존 ADR 제목·Decision 한 줄 요약을 훑어 사용자가 인지하는 단위(로그인, 가입, 비밀번호 재설정 같은 한 동작)로 묶고, ALPS Section 7 feature 가 있으면 그대로 매핑한다. context 전체에 걸친 cross-cutting ADR 은 부모 폴더 직속에 남기고, 기술 레이어 분할(아래 "안티패턴 카테고리")은 후보로 만들지 않는다.
5. 분할이 합의되면 위 분할 규칙(1단계 깊이, `.mapping.json` 인덱스·키)에 따라 폴더 이동을 수행한다.
6. 같은 logical decision 의 evolution chain 이 보이면 분할 전에 `/adr-rollup` 부터 권한다 — 분할로 흩으면 chain 추적이 어려워진다.

> `/adr-rollup` 은 evolution chain 압축에만 집중하고 분할 제안은 하지 않는다 — 두 작업이 섞이면 사용자가 한 사이클에서 너무 많은 결정을 떠맡게 된다.

## 구현 레퍼런스

- ALPS PRD: `prd/<doc>.alps.xml` (Section 7이 feature spec의 source of truth — `/feature-to-adr` importer 가 한 번 읽는 원본일 뿐, 매핑은 이 경로를 참조하지 않는다)
- 매핑: `docs/adr/.mapping.json` (ADR 레지스트리/인덱스. **코드 경로도 PRD 참조도 저장하지 않는다** — 관련 코드는 ADR 을 읽고 그때그때 찾는다)

> **권장**: 이 섹션 아래에 프로젝트별 **피쳐 진입점**을 명시한다. vertical slice 구조에서는 한 피쳐의 UI/API/Data 코드가 같은 폴더 트리에 모이므로, 피쳐(leaf) → 진입점 매핑이 자연스럽게 1:1 이 된다. context 는 보통 여러 피쳐를 품으므로 context → 코드 는 1:다 가 될 수 있다.
>
> 예:
>
> - `identity/login/` ADR → `src/features/login/` (UI 컴포넌트, 핸들러, 토큰 정책 모두 포함)
> - `identity/signup/` ADR → `src/features/signup/`
> - `ordering/checkout/` ADR → `src/features/checkout/`
> - `identity/` 직속 cross-cutting ADR → context 전반 코드 (`src/features/identity/shared/` 등)
> - `infra/` ADR (system-wide cross-cutting) → `src/shared/infra/`, `infra/`
>
> ADR 본문에서는 폴더 단위까지만 참조하므로, 진입점 매핑을 이 절에 적어두면 검토자가 빠르게 코드를 찾을 수 있다. 한 피쳐의 결정이 여러 진입점에 흩어진다면 그 자체가 vertical slice 위반 신호다.

## 흔한 context · subdomain 예시

bounded context(도메인) 폴더가 기본이고, 그 안의 피쳐가 UI → API → Data 슬라이스를 담당한다. DDD subdomain 분류(core/supporting/generic)는 `.mapping.json` 의 `subdomainType` 으로 표시하는 **선택적 메타데이터**다 — 폴더 계층이 아니라 entry 의 한 필드이며, 강제되지 않는다.

### core / supporting subdomain context — 기본

제품의 경쟁력이 걸린 핵심 도메인(core)과 이를 떠받치되 차별화 요소는 아닌 도메인(supporting)이다. 각 context 는 한 개 이상의 피쳐(vertical slice)를 품고, 각 피쳐는 UI → API → 데이터까지를 모두 다룬다.

| context (subdomain)       | 품는 피쳐(vertical slice)와 다루는 결정                                                                            |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `identity/` (core)        | `login/`, `signup/`, `sso/` — 폼 UX, 토큰 정책, users 테이블 키 패턴 (context 직속에 토큰 회전 같은 cross-cutting) |
| `catalog/` (core)         | `listing/`, `search/`, `filter/` — 리스트 UI, 검색 API, 인덱스 구조                                                |
| `ordering/` (core)        | `checkout/`, `cancel/`, `status/` — 체크아웃 UI, 주문 API, 주문 상태 머신                                          |
| `billing/` (supporting)   | `plan/`, `payment/`, `refund/` — 결제 UI, 결제 게이트웨이, 트랜잭션 기록                                           |
| `messaging/` (supporting) | `chat/`, `thread/`, `notification/` — 채팅 UI, WebSocket 연결, 메시지 저장                                         |

### generic subdomain · system-wide cross-cutting context — 정말 공유하는 결정만

차별화 요소가 아니어서 기성품으로 대체 가능한 도메인(generic), 또는 두 개 이상의 context/피쳐가 같은 결정에 의존하는 횡단 관심사다. 한 피쳐만의 DB/인프라 결정은 그 피쳐 폴더(또는 그 context 직속)에 둔다.

| context (subdomain)      | 다루는 결정                                                                  |
| ------------------------ | ---------------------------------------------------------------------------- |
| `data/` (generic)        | 여러 피쳐가 공유하는 단일 테이블 디자인, 글로벌 키 컨벤션, 마이그레이션 전략 |
| `infra/` (generic)       | 배포 토폴로지, 모니터링/알람, CDN, 비용 최적화 — 전 시스템에 영향            |
| `integration/` (generic) | LLM·결제·메일·푸시 등 여러 피쳐가 함께 의존하는 외부 서비스 연동 정책        |
| `security/` (generic)    | 비밀 관리, 토큰 회전 정책, 감사 로그 — 시스템 전체 정책                      |
| `platform/` (generic)    | 라우팅 컨벤션, 디자인 시스템, 공통 상태 관리 — 모든 피쳐 UI 가 따르는 규약   |

### 안티패턴 카테고리 (context 폴더·피쳐 sub-folder 모두 금지)

이런 이름은 context 폴더에도 피쳐 sub-folder 에도 쓰지 않는다 — 한 피쳐의 결정이 흩어져 vertical slice 가 깨진다.

- `frontend/`, `backend/`, `mobile/`, `web/` — 기술 레이어/플랫폼 단위
- `api/`, `ui/`, `db/`, `cache/` — 시스템 레이어 단위
- `controllers/`, `services/`, `repositories/` — 코드 구조 단위
- `bugfix/`, `refactor/` — 작업 종류 단위 (애초에 ADR 대상 아님)

> **DDD 주의**: bounded context 는 **모델 경계**이지 기술 레이어가 아니다. `identity/`(도메인)는 OK 지만 `identity/api/`(레이어)는 금지 — subdomain 분류(core/supporting/generic)는 어느 도메인이 경쟁력의 핵심인지를 나타내는 메타데이터일 뿐, 폴더를 레이어로 쪼개라는 뜻이 아니다.

## ADR 레지스트리 (.mapping.json)

`docs/adr/.mapping.json` 은 이 프로젝트의 **단일 ADR 인덱스**다 — 카테고리(키) → `adrs`(각 adr = `{path, status, summary}`)와 카테고리 간 `dependsOn` 을 기록한다. **코드 경로도, PRD 참조도 저장하지 않는다** (adr-writer 는 standalone 이며 ALPS 를 참조하지 않는다). 한 ADR 이 다스리는 코드 위치는 ADR Decision 을 읽고 그때그때 repo 를 탐색해 찾는다 (아래 "관련 코드 찾기"). 코드 구조가 리팩토링으로 바뀌어도 매핑은 손댈 필요가 없다 — 결정이 안 바뀌었으면 ADR 도 매핑도 그대로다.

```json
{
  "$schema": "https://raw.githubusercontent.com/haandol/alps-writer-plugins/main/plugins/adr-writer/templates/adr/mapping.schema.json",
  "categories": {
    "identity": {
      "feature": "Identity & Access",
      "subdomainType": "core",
      "adrs": [
        {
          "path": "docs/adr/identity/0001-token-rotation.md",
          "status": "Accepted (2026-02-14)",
          "summary": "refresh token 은 7일 만료로 회전하고 재사용 감지 시 계열을 폐기한다"
        }
      ]
    },
    "identity/login": {
      "feature": "Login",
      "adrs": [
        {
          "path": "docs/adr/identity/login/0001-password-policy.md",
          "status": "Accepted (2026-03-02)",
          "summary": "최소 길이·복잡도 규칙과 argon2id 해시 정책을 고정한다"
        }
      ],
      "tableDocs": ["docs/tables/users.md"]
    },
    "catalog/search": {
      "feature": "Catalog Search",
      "subdomainType": "core",
      "adrs": [
        {
          "path": "docs/adr/catalog/search/0001-listing-search.md",
          "status": "Proposed",
          "summary": "리스팅 검색은 역색인 + prefix 필터로 처리하고 정렬 키를 분리한다"
        }
      ],
      "dependsOn": ["identity/login"],
      "tableDocs": ["docs/tables/listings.md"]
    }
  }
}
```

매핑 파일은 `/adr-new`(빈 골격 생성 + entry 작성)와 `/feature-to-adr`(ALPS Section 7 일괄 변환)로 생성·갱신된다. 카테고리 키는 feature 이름에서 canonical 하게 파생하고(`login`, `identity/login`), Feature ID 는 **어디에도 저장하지 않는다** — `/adr-impl` 은 카테고리 키로만 대상을 해석하므로 ID 를 따로 보존할 필요가 없다. feature 이름이 없어 의미 있는 kebab 을 못 뽑는 워크숍/번호 기반 PRD 에서만 `f1`, `f2` 를 fallback 키로 쓴다 — 그때는 `f1` 이 평범한 literal 카테고리 키이므로 `/adr-impl f1` 도 그 키에 정상적으로 매칭된다 (Feature ID 매칭이 아니라 키 매칭이다).

- `adrs` — 이 카테고리에 속한 ADR 레코드 배열. 각 항목은 `{ path, status, summary }` 객체다: `path` 는 repo-relative ADR 경로, `status` 는 ADR 본문의 `## Status` 줄을 그대로 미러링(`Proposed` | `Accepted (YYYY-MM-DD)` | `Deprecated (YYYY-MM-DD)` | `Superseded by [ADR ...](...)`), `summary` 는 Key Decision 한 줄 요약이다. **이 배열이 곧 ADR 인덱스다** — README 는 별도 목록을 두지 않고, UserPromptSubmit hook 이 이 레코드를 매 턴 렌더링한다. `status`·`summary` 는 본문이 바뀔 때 함께 갱신한다 (status 는 `/adr-impl`·`/adr-sync` 가 본문 `## Status` 와 lockstep 으로 유지).
- `subdomainType` — context 의 DDD subdomain 분류(`core`/`supporting`/`generic`). **선택적·advisory 메타데이터**다: 강제되지 않고, `/adr-new` 가 매번 묻지 않으며, 있으면 `/adr-sync`·hook 스냅샷이 도메인별 그룹핑/주석으로 표시한다. context 수준 entry(최상위 세그먼트, 또는 단일-피쳐 평면 entry)에 둔다 — 피쳐 sub-folder entry 는 개념적으로 부모 context 의 분류를 상속하므로 생략해도 된다. 알 수 없으면 생략한다 (없어도 매핑은 유효하다).
- `dependsOn` — 이 카테고리가 의존하는 선행 카테고리 키 배열. `/adr-impl` 의 선행 게이트가 읽어 선행 ADR 을 먼저 구현하도록 정렬한다. ALPS 가 있으면 `/feature-to-adr` 가 Section 6.3 에서 옮겨오고, ALPS 없이 `/adr-new` 로 직접 작성하면 작성자가 지목한 선행을 기록한다. **기존 카테고리 키만 참조하고 비순환(self-edge 금지)을 유지**한다 — `/adr-sync` 6단계가 dangling·순환을 점검한다. 엣지는 **context 경계를 가로질러도 된다** (예: `catalog/search` 가 `identity/login` 에 의존 — DDD context 사이 관계가 ADR 의존으로 나타난 정상 케이스).

### 결정 로그 (decision-log.md) — 매핑에 등록하지 않는 컨벤션 파일

각 카테고리 폴더(`docs/adr/<category>/`)는 선택적으로 `decision-log.md` 하나를 둘 수 있다 — 그 카테고리의 **major 결정 변경 이력**(채택 대안 교체·핵심 알고리즘/아키텍처 변경·Driver 반전·폐기)을 역순으로 담는 파일이다. ADR 본문은 현재 상태만 서술하므로, "무엇이 왜 바뀌었나" 의 시간축은 이 로그가 보존한다. 기록 기준은 `authoring-rules.md` "결정 로그 기록 기준".

- **시드에서 복사해 만든다** — 첫 major 전환이 생기면 `docs/adr/decision-log.template.md`(없으면 `${CLAUDE_PLUGIN_ROOT}/templates/adr/decision-log.template.md`)를 `docs/adr/<category>/decision-log.md` 로 복사하고 `<category>` 와 엔트리를 채운다. 포맷을 기억에서 재작성하지 않는다. **남길 전환이 생기기 전에는 만들지 않는다** — 빈 로그를 미리 두지 않는다.
- **`.mapping.json` 에 등록하지 않는다** — 로그는 ADR 이 아니라 컨벤션 파일이다. 매핑 스키마에 `decisionLog` 같은 필드를 두지 않으며(엔트리는 `additionalProperties:false`), 스킬은 카테고리 폴더에서 존재 여부만 확인한다.
- **ADR 로 검사되지 않는다** — `adr-structure-lint` 는 `NNNN-` 로 시작하는 파일만 ADR 로 열거하므로 `decision-log.md` 는 per-ADR 검사·인덱스 정합·orphan 검사 어디에도 걸리지 않는다. `/adr-sync` 의 디스크 ADR 전수 조회도 이 파일을 제외한다. **단 로그의 ADR 포인터 실재는 하네스가 검사한다**(`decision-log-link-broken`) — rollup renumber 후 포인터를 안 고치면 로그가 사라진 경로를 가리키는데, `<cat>/NNNN` 토큰을 찾는 stale-citation finder 도 `NNNN-*.md` 본문만 보는 R10 도 이걸 잡지 못하기 때문이다. (루트의 `decision-log.template.md` 시드는 스캐폴딩이라 제외된다.)
- **참조 방향은 log → ADR 단방향** — 로그는 `현재 ADR` 링크만 담고 코드·PRD 를 참조하지 않는다. ADR 본문(Related 포함)은 로그를 역으로 링크하지 않는다.
- 생성·갱신 주체: `/adr-impl`·`/adr-sync`(major 결정 변경 시 append/harvest), `/adr-rollup`(체인의 major 전환 harvest). 자세한 흐름은 각 스킬 참조.

### 관련 코드 찾기

`/adr-sync`, `/adr-impl`, `/adr-rollup` 등이 한 ADR 의 코드 정합을 검증할 때, 그 ADR 이 다스리는 코드를 매 실행마다 다음으로 좁힌다 (매핑에 경로를 저장하지 않는 이유: 코드 구조 변경이 안정 레이어인 매핑·ADR 을 끌고 다니지 않게 하려는 것):

1. ADR 의 Decision / Mermaid / 제목에서 도메인 키워드(엔티티명·동작·API path·상태값) 추출.
2. `Glob`/`Grep` 으로 그 키워드가 사는 코드를 찾는다 — vertical slice 프로젝트면 보통 `src/features/<feature>/`, 레이어 단위 모노레포면 여러 레이어 폴더(`packages/web/...`, `services/...`)에 흩어져 있다. 카테고리 키(`auth`, `orders`)가 디렉토리명과 일치하는 경우가 많으니 첫 후보로 삼는다.
3. 찾은 범위가 ADR Decision 과 맞는지 대조한 뒤 그 범위에서 검증한다. 한 번 찾은 범위는 그 명령 실행 동안만 재사용하고 매핑에 영구 저장하지 않는다.

**추측 금지**: 코드 베이스를 한 번도 보지 않은 채 범위를 단정하지 않는다 — 항상 `Glob`/`Grep` 으로 실제 구조를 확인한 뒤 검증한다.
