# AI Usage Menu Bar App Architecture

## 1. 배경

현재 저장소 기준으로 확인한 실제 구현은 다음과 같다.

- `update_ai_usage.py`
  - `tmux` 세션을 열어 `claude`와 `codex` TUI에 진입
  - Claude는 `/usage`, Codex는 `/status`를 입력
  - 화면을 `capture-pane`으로 가져와 정규식으로 파싱
  - 결과를 `~/.cache/ai_usage.json`에 저장
- `ai_usage.5m.py`
  - xbar 플러그인
  - 캐시 JSON만 읽어서 메뉴바/드롭다운 텍스트 출력
- `local.ai-usage-refresh.plist`
  - `launchd`로 updater를 주기 실행

추가로 실제 운영 경로는 저장소와 분리되어 있다.

- 작업본: `/Users/dev/Desktop/Project/manu-bar`
- 운영 updater: `/Users/dev/.config/ai-usage/update_ai_usage.py`
- 운영 LaunchAgent: `~/Library/LaunchAgents/local.ai-usage-refresh.plist`
- 운영 xbar plugin: `~/Library/Application Support/xbar/plugins/ai_usage.5m.py`

현재 구조에서 확인된 핵심 문제는 다음과 같다.

1. xbar는 단지 표시 레이어일 뿐이고, 본질적 난제는 collector 안정성이다.
2. interactive TUI 기반 수집은 공식 값에 가깝지만 flaky하다.
3. launchd 자동 실행 환경에서 타이밍 문제가 수동 실행보다 심하다.
4. 작업본과 운영본이 분리되어 있어 배포/동기화 drift가 발생한다.
5. 실제 캐시 예시와 xbar 표시 코드 간 필드명이 이미 어긋난 흔적이 있다.
   - 예: cache에는 `claude.five_hour_left`, `weekly_left`가 있으나
   - xbar 코드는 `claude.session_left`, `week_all_left`를 기대한다.

이 문서는 위 구현을 출발점으로, xbar 의존성을 제거하고 **독립 실행형 macOS 메뉴바 앱**으로 재구성하는 아키텍처를 정의한다.

---

## 2. 제품 컨셉

이 제품은 단순한 메뉴바 UI가 아니라 다음 성격을 가진다.

> **Claude/Codex usage 상태를 공통 규격으로 수집·정규화·캐시·표시하는 로컬 전용 macOS 시스템 도구**

핵심 원칙:

- 사용자 관점에서는 메뉴바 앱처럼 보여야 한다.
- 내부적으로는 수집기(collector)를 UI에서 분리해야 한다.
- 표시 기준은 provider마다 다르더라도 최종 출력은 항상 `left`로 통일한다.
- collector가 실패하더라도 메뉴바는 마지막 정상값과 오류 상태를 안정적으로 표시해야 한다.
- packaging 가능한 구조여야 하며, 수동 복사 배포를 끝내야 한다.

---

## 3. 목표 / 비목표

### 목표

- xbar 없이 동작하는 독립 메뉴바 앱 제공
- Claude/Codex usage를 공통 스키마로 정규화
- 자동 갱신, 수동 갱신, stale 표시 지원
- collector 실패 시 last-known-good 유지
- startup trust/update prompt 같은 blocker를 감지하고 UI에 노출
- 향후 배포 가능한 패키지 구조 확보
- 향후 collector 구현 교체가 쉬운 구조 확보

### 비목표

- Claude/Codex의 공식 API를 새로 정의하는 것
- provider 내부 세션 모델을 완전히 해결하는 것
- App Store 제약에 맞춘 샌드박스 앱 우선 설계

---

## 4. 제안 아키텍처

```text
┌──────────────────────────────────────────────┐
│ AI Usage Menu Bar App (.app)                │
│----------------------------------------------│
│ Status Bar UI                                │
│ Dropdown UI                                  │
│ Refresh Coordinator                          │
│ App Settings                                 │
│ Cache Reader                                 │
└──────────────────────┬───────────────────────┘
                       │
             invokes / reads
                       │
┌──────────────────────▼───────────────────────┐
│ Collector Helper                             │
│----------------------------------------------│
│ Provider Registry                            │
│ Claude Collector                             │
│ Codex Collector                              │
│ Normalizer (used -> left 변환 포함)           │
│ Health / Retry / Timeout / Logging           │
└──────────────────────┬───────────────────────┘
                       │
                writes canonical
                       │
┌──────────────────────▼───────────────────────┐
│ Cache Store                                  │
│----------------------------------------------│
│ usage.json                                   │
│ logs/                                         │
│ debug captures/                               │
└──────────────────────────────────────────────┘
```

핵심은 다음 한 줄로 요약된다.

> **UI는 읽기 전용, collector는 쓰기 전용, 두 계층은 canonical cache schema로만 연결한다.**

---

## 5. 구성 요소

### 5.1 Menu Bar App

책임:

- 메뉴바 summary 표시
- 드롭다운 상세 표시
- 수동 refresh 버튼
- refresh 중 상태 표시
- stale/error 상태 표시
- 설정 화면 제공

앱은 provider 내부 파싱 로직을 몰라야 한다. 앱은 오직 canonical JSON만 읽고, 필요 시 helper를 실행한다.

### 5.2 Collector Helper

책임:

- 각 provider별 usage/status 수집
- 원본 출처별 결과를 공통 스키마로 정규화
- timeout, retry, backoff, stale 정책 적용
- 디버그 로그와 capture 저장

이 계층은 현재 `update_ai_usage.py`가 하던 일을 일반화한 것이다.

### 5.3 Provider Collector

각 provider는 독립 모듈로 분리한다.

- `ClaudeCollector`
- `CodexCollector`

각 collector는 다음 인터페이스를 따른다.

```text
collect() -> ProviderSnapshot
```

ProviderSnapshot은 raw 값일 수 있으나, helper 외부로 나갈 때는 반드시 canonical schema로 변환한다.

### 5.4 Cache Store

책임:

- last-known-good snapshot 저장
- 최근 갱신 시각 저장
- provider별 에러 상태 저장
- stale 판단에 필요한 메타데이터 저장

권장 저장 위치:

- `~/Library/Application Support/AIUsageMenuBar/usage.json`
- `~/Library/Application Support/AIUsageMenuBar/logs/...`

기존 `~/.cache/ai_usage.json`는 migration 대상이다.

---

## 6. Canonical Data Schema

모든 provider 출력은 아래 규격으로 맞춘다.

```json
{
  "schema_version": 1,
  "updated_at": "2026-04-15T14:38:34+09:00",
  "status": {
    "overall": "ok",
    "stale": false
  },
  "providers": {
    "codex": {
      "display_name": "Codex",
      "summary": {
        "primary_left": 99,
        "secondary_left": 94
      },
      "metrics": {
        "five_hour": {
          "left": 99,
          "reset_at_label": "18:32"
        },
        "weekly": {
          "left": 94,
          "reset_at_label": "15:04 on 17 Apr"
        }
      },
      "errors": [],
      "source": {
        "collector": "codex",
        "method": "interactive"
      }
    },
    "claude": {
      "display_name": "Claude",
      "summary": {
        "primary_left": 88,
        "secondary_left": 67
      },
      "metrics": {
        "five_hour": {
          "left": 88,
          "reset_at_label": "6pm (Asia/Seoul)"
        },
        "weekly": {
          "left": 67,
          "reset_at_label": "Apr 17 at 2pm (Asia/Seoul)"
        },
        "sonnet": {
          "left": 100,
          "reset_at_label": "6pm (Asia/Seoul)"
        }
      },
      "errors": [],
      "source": {
        "collector": "claude",
        "method": "interactive"
      }
    }
  }
}
```

표시 규칙:

- Claude `used`는 helper에서 `left = 100 - used`로 변환
- 앱은 오직 `left`만 사용
- 메뉴바 summary는
  - `Cdx {primary}/{secondary} · Cl {primary}/{secondary}`
- Claude `primary/secondary`
  - `five_hour / weekly`
- Codex `primary/secondary`
  - `five_hour / weekly`

---

## 7. 핵심 플로우

### 7.1 앱 시작

1. 앱이 cache를 읽는다.
2. 값이 있으면 즉시 메뉴바에 표시한다.
3. stale이면 경고 스타일로 표시한다.
4. background refresh를 예약한다.

### 7.2 주기 갱신

1. Refresh Coordinator가 주기에 따라 helper를 실행한다.
2. helper가 provider별 collector를 실행한다.
3. 하나라도 성공하면 cache를 부분 갱신할 수 있다.
4. 실패한 provider는 기존 정상값 유지 + 에러만 갱신한다.
5. startup prompt가 감지되면 provider는 `blocked` 상태로 기록하고, UI는 경고와 해결 액션을 노출한다.
6. 앱은 cache 변경을 읽고 UI를 갱신한다.

### 7.3 수동 갱신

1. 사용자가 dropdown에서 Refresh를 누른다.
2. 앱이 helper를 즉시 실행한다.
3. 실행 중에는 `Refreshing...` 상태를 표시한다.
4. 완료 후 summary/dropdown을 다시 렌더링한다.

---

## 8. 기술 선택 및 결정 로그

아래 결정은 현재 저장소 구현과 운영 방식 문제를 기준으로 내린 것이다.

### Decision 1

**Decision**: xbar 플러그인 기반 구조를 종료하고 독립 macOS 메뉴바 앱으로 전환한다.

**Context**: 현재 `ai_usage.5m.py`는 캐시 JSON만 읽는 얇은 표시 레이어다. xbar는 제품의 본질이 아니라 렌더링 셸이다.

**Options**:
1. Option A — xbar를 유지한다  
   - pros: 현재 구현을 거의 그대로 유지 가능, 구현 속도가 빠름  
   - cons: xbar 설치가 필요함, 패키지 제품 경험이 약함, 독립 앱 목표와 맞지 않음
2. Option B — 독립 메뉴바 앱으로 전환한다  
   - pros: 제품 완성도가 높아짐, 설정/상태/에러 UI를 통합 가능, 배포 형태가 명확해짐  
   - cons: 앱 레이어를 새로 만들어야 함

**Chosen**: Option B because xbar는 쉽게 대체 가능하고, 사용자가 원하는 최종 형태는 독립 앱이기 때문이다.

**Consequences**: UI 품질과 배포 경험은 좋아진다. 대신 메뉴바 앱 레이어를 새로 구현해야 한다.

### Decision 2

**Decision**: UI와 collector를 프로세스 경계로 분리한다.

**Context**: 현재 문제의 대부분은 UI가 아니라 수집 로직에 있다. flaky한 collector를 UI 내부에 섞으면 앱 전체가 불안정해진다.

**Options**:
1. Option A — 앱 프로세스 안에 collector를 직접 내장한다  
   - pros: 구조가 단순해 보임, IPC가 필요 없음  
   - cons: 수집 실패가 UI에 직접 전파됨, 디버깅/교체가 어려움, 외부 CLI 실행 문제가 앱에 결합됨
2. Option B — 별도 helper 프로세스로 collector를 분리한다  
   - pros: 책임 분리가 명확함, timeout/retry를 독립 관리 가능, 앱은 읽기 전용으로 단순해짐  
   - cons: 프로세스 경계와 호출 계약을 관리해야 함

**Chosen**: Option B because 수집기의 불안정성을 UI와 격리하는 것이 가장 큰 품질 개선 포인트이기 때문이다.

**Consequences**: helper 설계와 데이터 계약이 중요해진다. 대신 앱은 훨씬 단순하고 안정적이 된다.

### Decision 3

**Decision**: provider별 raw 형식 대신 canonical schema를 제품 내부의 유일한 데이터 계약으로 사용한다.

**Context**: 현재 저장소와 실제 cache 사이에 필드 드리프트가 이미 발생했다. 앱과 collector가 raw 필드명에 직접 의존하면 같은 문제가 반복된다.

**Options**:
1. Option A — 각 provider의 raw 필드를 그대로 앱에 노출한다  
   - pros: 초기 개발이 빠름  
   - cons: 필드명 충돌, drift, UI 조건문 증가, provider 교체 비용 증가
2. Option B — helper가 canonical schema로 정규화한다  
   - pros: 앱 단순화, backward compatibility 관리 용이, 테스트 쉬움  
   - cons: helper에 정규화 책임이 추가됨

**Chosen**: Option B because UI와 수집기의 결합을 끊는 핵심 장치가 canonical schema이기 때문이다.

**Consequences**: schema versioning이 필요해진다. 대신 UI는 provider 구현 세부사항에서 해방된다.

### Decision 4

**Decision**: 저장 형식은 JSON 파일 기반 last-known-good cache를 유지한다.

**Context**: 이 도구는 로컬 단일 사용자, 저용량, 주기 갱신 중심이다. 현재도 JSON 기반이며 사용량 데이터 구조는 작다.

**Options**:
1. Option A — JSON 파일 유지  
   - pros: 단순함, 디버깅 쉬움, 수동 확인 가능, 현재 구현과 호환됨  
   - cons: 동시성/이력 관리에는 약함
2. Option B — SQLite/Core Data로 전환  
   - pros: 이력, 쿼리, 원자성 측면에서 강함  
   - cons: 과한 복잡도, 초기 구현 비용 증가

**Chosen**: Option A because 현재 요구사항은 최신 상태와 최근 오류만 안정적으로 보관하면 충분하기 때문이다.

**Consequences**: 파일 원자적 쓰기 규칙이 필요하다. 대신 운영과 디버깅이 단순하다.

### Decision 5

**Decision**: 자동 갱신 주체는 launchd가 아니라 앱 내부 Refresh Coordinator로 옮긴다.

**Context**: 현재는 `launchd -> updater -> cache -> xbar`로 분리되어 있다. 독립 앱에서는 이 분리가 과하다.

**Options**:
1. Option A — launchd를 계속 유지한다  
   - pros: 앱이 꺼져도 갱신 가능, background update가 독립적임  
   - cons: 설치 지점 증가, 디버깅 복잡, 제품 구조가 분산됨
2. Option B — 앱 내부 timer가 helper를 실행한다  
   - pros: 구조 단순, 수동 refresh와 동일 경로 사용, UI/오류 상태를 한곳에서 제어 가능  
   - cons: 앱이 꺼져 있으면 갱신도 멈춤

**Chosen**: Option B because 메뉴바 앱은 상시 실행 도구이며, 제품 설치/운영 복잡도를 줄이는 편이 더 중요하기 때문이다.

**Consequences**: launchd 의존성은 줄어든다. 대신 auto-launch at login을 앱 레벨에서 제공해야 한다.

### Decision 6

**Decision**: collector는 provider별 adapter 구조로 설계한다.

**Context**: Claude와 Codex는 서로 다른 명령, 다른 화면, 다른 리셋 정보, 다른 실패 패턴을 가진다.

**Options**:
1. Option A — 단일 giant script에서 모든 provider를 처리한다  
   - pros: 파일 수가 적음, 빨리 시작 가능  
   - cons: 조건문이 커짐, provider별 수정 영향 범위가 넓음, 테스트가 어려움
2. Option B — provider adapter로 분리한다  
   - pros: 책임이 명확함, provider별 교체 쉬움, 테스트 범위가 작아짐  
   - cons: 인터페이스 설계가 필요함

**Chosen**: Option B because collector 전략을 바꾸더라도 앱 구조는 유지되어야 하기 때문이다.

**Consequences**: collector registry와 공통 결과 타입이 필요해진다. 대신 Claude/Codex 변경을 독립 처리할 수 있다.

### Decision 7

**Decision**: collector 구현 방식은 아키텍처상 고정하지 않고 pluggable method로 둔다.

**Context**: 현재 저장소 구현은 interactive TUI + tmux capture다. 하지만 사용자는 안 쉬운 부분에 대한 별도 해결 실마리를 이미 갖고 있다. 지금 시점에 구현 방식을 아키텍처에 박아 넣으면 미래 교체 비용이 커진다.

**Options**:
1. Option A — interactive tmux capture를 아키텍처 핵심으로 고정한다  
   - pros: 현재 구현을 그대로 설명 가능  
   - cons: flaky한 방식이 제품 구조에 고착됨
2. Option B — collector method를 전략으로 분리한다  
   - pros: interactive, non-interactive, helper shim 등 어떤 수집 방식도 수용 가능  
   - cons: 초기 설계가 약간 더 추상적임

**Chosen**: Option B because 실제 수집 방식은 바뀔 수 있지만, 앱-collector-cache 경계는 오래 유지되어야 하기 때문이다.

**Consequences**: provider source metadata를 저장해야 한다. 대신 hard part를 나중에 갈아끼우기 쉬워진다.

### Decision 8

**Decision**: 운영본 수동 복사 구조를 없애고, 저장소를 단일 source of truth로 만든다.

**Context**: 현재는 저장소 파일과 `~/.config/ai-usage`, xbar plugin 경로, LaunchAgent가 분리되어 있다. 이미 설정 drift가 발생했다.

**Options**:
1. Option A — 계속 수동 복사/직접 수정한다  
   - pros: 지금 당장은 빠름  
   - cons: 어떤 파일이 최신인지 불명확, 배포 자동화 불가, 회귀가 잦음
2. Option B — 저장소 기준 build/install 단계로만 배포한다  
   - pros: 재현 가능, 패키지화 가능, 테스트/릴리즈 흐름 정립 가능  
   - cons: install script나 build pipeline을 만들어야 함

**Chosen**: Option B because 패키지화 목표를 달성하려면 source of truth가 하나여야 하기 때문이다.

**Consequences**: 빌드/설치 스크립트가 필요하다. 대신 배포 일관성이 생긴다.

### Decision 9

**Decision**: stale-last-known-good 정책을 기본 동작으로 채택한다.

**Context**: collector는 실패 가능성이 높다. 메뉴바가 빈 값만 보여주면 제품 신뢰성이 더 낮아진다.

**Options**:
1. Option A — 수집 실패 시 즉시 빈 값 표시  
   - pros: 데이터 신선도 의미가 명확함  
   - cons: 사용자 경험이 불안정하고 노이즈가 큼
2. Option B — 마지막 정상값 유지 + stale/error 표시  
   - pros: 메뉴바 안정성 높음, collector 일시 실패에 강함  
   - cons: 오래된 데이터를 보여줄 위험이 있음

**Chosen**: Option B because 이 제품은 실시간 트레이딩 도구가 아니라 상태 모니터이고, 안정성이 더 중요하기 때문이다.

**Consequences**: stale 기준 시간과 UI 표기가 필요하다. 대신 일시적 수집 실패가 제품 품질을 무너뜨리지 않는다.

### Decision 10

**Decision**: macOS 앱 구현은 SwiftUI 기반 메뉴바 앱 + 필요한 경우 AppKit bridge를 사용한다.

**Context**: 목표 플랫폼이 macOS이고, 앱 형태가 메뉴바 유틸리티다.

**Options**:
1. Option A — SwiftUI/AppKit 네이티브 앱  
   - pros: macOS 메뉴바와 자연스럽게 맞음, 배포/권한/성능 측면에서 유리, boring tech에 가깝다  
   - cons: 현재 Python 코드와 언어가 달라짐
2. Option B — Electron/Tauri 등 크로스플랫폼 앱  
   - pros: JS 생태계 활용 가능  
   - cons: 이 프로젝트는 macOS 메뉴바가 핵심이라 장점이 적고, 런타임이 무거워질 수 있음

**Chosen**: Option A because 이 프로젝트는 macOS 전용 로컬 유틸리티이며, 네이티브 메뉴바 경험이 가장 중요하기 때문이다.

**Consequences**: UI는 Swift 생태계로 간다. collector helper는 초기에는 Python이어도 되지만 장기적으로는 분리 유지가 필요하다.

### Decision 11

**Decision**: 배포 방식은 우선 direct distribution `.app` 중심으로 설계한다.

**Context**: 현재 구조는 외부 CLI 실행과 사용자 홈 디렉토리 자원 접근을 필요로 한다.

**Options**:
1. Option A — direct distribution (`.app`, zip, dmg)  
   - pros: 현재 구조와 잘 맞음, 외부 helper/CLI 의존성을 유지하기 쉬움  
   - cons: 자동 업데이트/배포 체계를 따로 설계해야 함
2. Option B — Mac App Store 우선  
   - pros: 사용자 설치 경험은 좋을 수 있음  
   - cons: sandbox와 외부 프로세스 실행 제약상 현재 구조와 맞지 않음

**Chosen**: Option A because 제품의 본질이 로컬 CLI orchestration에 가깝고, App Store 제약은 현재 단계에서 과도하기 때문이다.

**Consequences**: notarization/signing 전략은 필요하다. 대신 제품 구조를 억지로 바꾸지 않아도 된다.

---

## 9. 권장 디렉토리 구조

```text
manu-bar/
├─ ARCHITECTURE.md
├─ collector/
│  ├─ main.py
│  ├─ providers/
│  │  ├─ claude.py
│  │  └─ codex.py
│  ├─ schema.py
│  ├─ cache_store.py
│  └─ diagnostics.py
├─ app/
│  ├─ AIUsageMenuBarApp.swift
│  ├─ RefreshCoordinator.swift
│  ├─ CacheModels.swift
│  ├─ CacheReader.swift
│  ├─ StatusBarViewModel.swift
│  └─ SettingsView.swift
├─ scripts/
│  ├─ install.sh
│  ├─ package.sh
│  └─ dev-refresh.sh
└─ fixtures/
   ├─ claude/
   └─ codex/
```

설명:

- `collector/`: helper 프로세스
- `app/`: 독립 메뉴바 앱
- `scripts/`: 개발/설치/패키징
- `fixtures/`: raw capture 회귀 테스트용 샘플

---

## 10. Migration Plan

### Phase 1 — schema 고정

- 기존 `update_ai_usage.py` 출력 필드를 canonical schema로 맞춘다.
- xbar도 새 schema만 읽도록 바꾼다.
- 이 단계의 목적은 UI 교체 전에 데이터 계약을 안정화하는 것이다.

### Phase 2 — collector 모듈화

- Claude/Codex 파서를 provider adapter로 분리한다.
- timeout/retry/stale 정책을 helper 공통부로 이동한다.
- debug capture와 로그 경로를 정리한다.

### Phase 3 — native menu bar app 도입

- SwiftUI/AppKit 기반 메뉴바 앱을 만든다.
- 앱은 canonical cache만 읽고 helper를 실행한다.
- xbar 의존성을 제거한다.

### Phase 4 — packaging

- repo를 source of truth로 확정한다.
- 수동 복사 대신 install/build 스크립트를 만든다.
- direct distribution 기준 패키지를 만든다.

---

## 11. 운영 규칙

- 앱은 raw provider 형식을 직접 읽지 않는다.
- helper만 외부 명령과 수집 방식을 안다.
- cache write는 atomic하게 수행한다.
- provider 하나가 실패해도 다른 provider 성공값은 버리지 않는다.
- error는 사용자에게 숨기지 않되, 메뉴바 summary를 망가뜨리지 않는다.
- schema 변경 시 `schema_version`을 올린다.

---

## 12. 최종 요약

이 프로젝트의 본질은 xbar 플러그인이 아니라 다음 구조다.

> **Provider-specific collector → canonical normalization → local cache → native menu bar UI**

가장 중요한 설계 포인트는 두 가지다.

1. **hard part인 collector를 UI와 분리할 것**
2. **provider 차이를 canonical schema 뒤로 숨길 것**

이 두 가지를 지키면:

- xbar에서 독립 앱으로 자연스럽게 갈 수 있고
- packaging도 가능해지고
- 수집 방식이 바뀌어도 앱 전체를 다시 설계할 필요가 없어진다.
