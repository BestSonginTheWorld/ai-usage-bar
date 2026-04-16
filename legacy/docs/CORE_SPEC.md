# AI Usage Menu Bar Core Spec v1

## 1. Purpose

이 문서는 `manu-bar`의 **v1 core** 계약을 정의한다.

여기서 core는 다음 범위를 뜻한다.

- provider별 usage/status 수집
- canonical schema로 정규화
- partial merge
- atomic cache write
- 상태/오류/신선도(freshness) 관리
- CLI 진입점 제공

이 문서는 **UI(xbar / native app)** 보다 아래 계층만 다룬다.

---

## 2. Current Implementation Facts

이 스펙은 현재 저장소와 실제 운영 파일을 읽고 정리한 사실을 기반으로 한다.

### Existing repo files

- `update_ai_usage.py`
  - `tmux` 세션 생성
  - `claude` TUI에서 `/usage`
  - `codex` TUI에서 `/status`
  - capture 텍스트를 정규식 파싱
  - `~/.cache/ai_usage.json` 저장
- `ai_usage.5m.py`
  - xbar 플러그인
  - cache JSON 읽어서 summary/dropdown 출력
- `local.ai-usage-refresh.plist`
  - `launchd`로 updater 주기 실행

### Existing deployed paths

- 운영 updater:
  - `/Users/dev/.config/ai-usage/update_ai_usage.py`
- 운영 LaunchAgent:
  - `~/Library/LaunchAgents/local.ai-usage-refresh.plist`
- 운영 xbar plugin:
  - `~/Library/Application Support/xbar/plugins/ai_usage.5m.py`

### Current problems observed from code/runtime

- 작업본과 운영본이 분리되어 drift 발생
- 현재 cache field와 xbar가 기대하는 field가 어긋남
- collector는 partial failure가 자주 발생 가능
- 현재 구현도 사실상 **one-shot collector** 모델임

---

## 3. v1 Scope

### In scope

- Python 기반 one-shot collector helper
- canonical config/cache contract
- `update` / `resolve` / `print` / `doctor` CLI
- provider enable/disable
- provider별 partial update
- structured error
- stale 판정
- App Support 경로 표준화

### Out of scope

- native macOS UI 구현
- App Store 대응
- provider 수집 방식의 장기적 재작성

---

## 4. Runtime Layout

## Decision 1

**Decision**: 런타임 산출물은 `~/Library/Application Support/AIUsageMenuBar/` 아래로 통일한다.

**Context**: 현재는 repo, `~/.config/ai-usage`, `~/.cache`, xbar plugin 경로, LaunchAgents로 흩어져 있어 drift와 운영 혼란이 발생한다.

**Options**:
1. Option A — 기존처럼 분산 유지  
   - pros: 지금 당장 migration이 적음  
   - cons: 설치/삭제/배포가 지저분하고 source of truth가 약함
2. Option B — macOS 표준 App Support 경로로 통일  
   - pros: 직관적, 패키징 쉬움, 런타임 파일 위치가 명확함  
   - cons: 기존 경로 migration이 필요함

**Chosen**: Option B because 설치/삭제가 직관적이고, macOS 메뉴바 앱으로 확장할 때도 가장 자연스럽기 때문이다.

**Consequences**:
- 런타임 경로가 한곳으로 모인다.
- 개발 소스(repo)와 운영 산출물(App Support)이 분리된다.

### Directory layout

```text
~/Library/Application Support/AIUsageMenuBar/
├─ config.json
├─ usage.json
├─ logs/
│  └─ collector.log
└─ debug/
   ├─ claude_capture.txt
   └─ codex_capture.txt
```

### File roles

- `config.json`
  - 기본 설정
- `usage.json`
  - canonical cache
- `logs/`
  - collector 실행 로그
- `debug/`
  - raw capture, diagnostics 산출물

---

## 5. CLI Surface

## Decision 2

**Decision**: core는 one-shot CLI collector로 제공한다.

**Context**: 현재 구현도 `launchd -> update_ai_usage.py -> 종료` 구조로 동작하고 있으며, 앱/수동 실행/자동화에서 모두 재사용하기 쉽다.

**Options**:
1. Option A — one-shot CLI  
   - pros: 단순함, 테스트 쉬움, 기존 모델과 일치  
   - cons: 매번 프로세스를 새로 띄워야 함
2. Option B — long-running daemon  
   - pros: 장기적으로 세밀한 상태 관리 가능  
   - cons: 현재 프로젝트 규모에 과하고 운영 복잡도가 큼

**Chosen**: Option A because 현재 프로젝트 규모와 기존 구현 방식에 가장 잘 맞고, 가장 가볍기 때문이다.

**Consequences**:
- 모든 호출자는 동일한 CLI 진입점을 사용한다.
- native app도 나중에 같은 명령을 subprocess로 호출하면 된다.

## Decision 3

**Decision**: CLI는 `update`, `resolve`, `print`, `doctor` 4개 명령을 제공한다.

**Context**: one-shot helper는 운영, 수동 점검, 설치 검증을 모두 지원해야 한다.

**Options**:
1. Option A — `update`만 제공  
   - pros: 구현이 가장 단순함  
   - cons: 디버깅/운영 점검이 불편함
2. Option B — `update` / `resolve` / `print` / `doctor` 제공  
   - pros: 운영성과 디버깅 편의가 높고, first-run blocker를 수동으로 해소할 수 있음  
   - cons: CLI 표면이 조금 넓어짐

**Chosen**: Option B because 작은 도구라도 `print`와 `doctor`는 운영 효율을 크게 높여주기 때문이다.

**Consequences**:
- UI 없이도 core를 독립적으로 검증할 수 있다.
- 설치 후 `doctor`로 즉시 상태 확인이 가능하다.

### Proposed CLI

```bash
ai-usage-collector update [--providers claude,codex] [--config PATH]
ai-usage-collector resolve [--providers claude,codex] [--config PATH]
ai-usage-collector print  [--format text|json] [--config PATH]
ai-usage-collector doctor [--config PATH]
```

### Command behavior

#### `update`

- config 로드
- 활성 provider 결정
- provider별 collect 실행
- canonical merge 수행
- atomic write
- 결과 요약 출력

#### `resolve`

- provider CLI를 hidden workdir에서 실행
- 첫 화면을 capture 후 classify
- trust/update/selection prompt면 사용자에게 터미널에서 확인 요청
- 사용자가 승인하면 Enter 1회 전송
- ready 상태가 되면 후속 `update`를 실행해 cache를 갱신

#### `print`

- 현재 `usage.json` 읽기
- 기본은 human-readable text
- 필요 시 `--format json` 제공

#### `doctor`

- Python 실행 환경 확인
- `claude`, `codex`, `tmux` 존재 여부 확인
- App Support 경로/쓰기 권한 확인
- config 파싱 확인
- enabled providers 기준으로 요구 dependency 확인

---

## 6. Provider Selection

## Decision 4

**Decision**: provider 활성화는 `enabled_providers` 설정으로 관리한다.

**Context**: 앞으로 Claude/Codex 둘 다가 아니라, 하나만 보도록도 지원해야 한다.

**Options**:
1. Option A — 항상 두 provider 고정  
   - pros: 단순함  
   - cons: single-provider 요구를 못 만족함
2. Option B — `enabled_providers` 목록으로 관리  
   - pros: 확장 가능, single/multi-provider 모두 지원  
   - cons: 설정 파일이 필요함

**Chosen**: Option B because 가장 단순하면서도 확장성 있고, 앞으로 provider가 늘어나도 같은 패턴을 유지할 수 있기 때문이다.

**Consequences**:
- collector는 활성 provider만 실행한다.
- exit code는 활성 provider 기준으로 계산한다.

## Decision 5

**Decision**: provider 선택은 config 기본값 + CLI override를 같이 지원한다.

**Context**: 상시 설정과 일회성 테스트/디버깅을 모두 만족해야 한다.

**Options**:
1. Option A — config file만 사용  
   - pros: 단순함  
   - cons: 테스트/디버깅이 불편함
2. Option B — config 기본값 + CLI override  
   - pros: 운영과 디버깅 둘 다 편함  
   - cons: 옵션 파싱이 조금 늘어남

**Chosen**: Option B because 메뉴바 앱의 기본 동작과 수동 점검 시나리오를 동시에 만족시키기 때문이다.

**Consequences**:
- 기본은 `config.json`
- 필요 시 `--providers claude` 같은 임시 override 가능

### Example config

```json
{
  "enabled_providers": ["claude", "codex"],
  "refresh_interval_seconds": 900,
  "stale_after_seconds": 1800,
  "stale_after_failures": 2,
  "debug_captures": true
}
```

### Notes

- `refresh_interval_seconds`
  - 앱/launchd 등 상위 레이어 기본값 참고용
- `stale_after_seconds`
  - provider stale 판정 기준
- `stale_after_failures`
  - provider stale 판정 보조 기준

---

## 7. Canonical Cache Schema

## Decision 6

**Decision**: cache는 explicit metric key + summary block 구조를 사용한다.

**Context**: top bar 요약값과 dropdown 상세값을 모두 쉽게 읽어야 하며, 작은 프로젝트에 맞는 boring한 구조가 필요하다.

**Options**:
1. Option A — explicit metric key만 사용  
   - pros: 구조가 단순함  
   - cons: top bar summary 계산을 UI가 직접 해야 함
2. Option B — generic list/array만 사용  
   - pros: 확장성 좋음  
   - cons: 읽기 어렵고 지금 규모엔 과함
3. Option C — explicit metric key + summary block  
   - pros: UI가 단순해지고 사람도 읽기 쉬움  
   - cons: 약간의 데이터 중복이 생김

**Chosen**: Option C because 이 프로젝트에서는 가벼운 중복보다 읽기 쉬운 구조가 더 중요하기 때문이다.

**Consequences**:
- `metrics`는 상세용
- `summary`는 상단 메뉴바용

## Decision 7

**Decision**: metric key는 canonical 이름으로 통일하고, provider의 공식 표현은 metadata로 보존한다.

**Context**: 사용자 표시 체계는 `left` 기준으로 통일해야 하지만, 원본 TUI 표현도 traceability를 위해 남길 가치가 있다.

**Options**:
1. Option A — provider 원문 키 유지  
   - pros: raw 대응이 쉬움  
   - cons: UI가 provider별 분기를 많이 알아야 함
2. Option B — canonical key만 유지  
   - pros: 가장 단순함  
   - cons: 원문 label trace가 사라짐
3. Option C — canonical key + official label 보존  
   - pros: 통일성과 traceability를 모두 확보  
   - cons: 필드가 조금 늘어남

**Chosen**: Option C because 내부 표현은 통일하되, 원본 TUI 맥락도 유지하는 것이 가장 균형이 좋기 때문이다.

**Consequences**:
- canonical metric key:
  - `five_hour`
  - `weekly`
  - `sonnet`
- provider별 공식 문구는 `official_label`로 저장한다.

### Canonical cache example

```json
{
  "schema_version": 1,
  "app_id": "AIUsageMenuBar",
  "written_at": "2026-04-15T15:10:00+09:00",
  "providers": {
    "claude": {
      "enabled": true,
      "status": "ok",
      "blocker": null,
      "last_attempt_at": "2026-04-15T15:10:00+09:00",
      "last_success_at": "2026-04-15T15:10:00+09:00",
      "consecutive_failures": 0,
      "stale": false,
      "summary": {
        "primary_left": 88,
        "secondary_left": 67,
        "primary_label": "5h",
        "secondary_label": "week"
      },
      "metrics": {
        "five_hour": {
          "left": 88,
          "reset_at_label": "6pm (Asia/Seoul)",
          "official_label": "Current session"
        },
        "weekly": {
          "left": 67,
          "reset_at_label": "Apr 17 at 2pm (Asia/Seoul)",
          "official_label": "Current week (all models)"
        },
        "sonnet": {
          "left": 100,
          "reset_at_label": "6pm (Asia/Seoul)",
          "official_label": "Current week (Sonnet only)"
        }
      },
      "error": null,
      "source": {
        "collector": "claude",
        "method": "interactive"
      }
    },
    "codex": {
      "enabled": true,
      "status": "ok",
      "blocker": null,
      "last_attempt_at": "2026-04-15T15:10:00+09:00",
      "last_success_at": "2026-04-15T15:10:00+09:00",
      "consecutive_failures": 0,
      "stale": false,
      "summary": {
        "primary_left": 99,
        "secondary_left": 94,
        "primary_label": "5h",
        "secondary_label": "week"
      },
      "metrics": {
        "five_hour": {
          "left": 99,
          "reset_at_label": "18:32",
          "official_label": "5h limit"
        },
        "weekly": {
          "left": 94,
          "reset_at_label": "15:04 on 17 Apr",
          "official_label": "Weekly limit"
        }
      },
      "error": null,
      "source": {
        "collector": "codex",
        "method": "interactive"
      }
    }
  }
}
```

### Field notes

- `written_at`
  - cache 파일이 마지막으로 기록된 시각
- `status`
  - `ok` / `error` / `blocked`
- `summary.primary_left`
  - top bar 첫 번째 값
- `summary.secondary_left`
  - top bar 두 번째 값
- `source.method`
  - `interactive`, `noninteractive`, 기타 collector strategy 식별용

---

## 8. Normalization Rules

## Decision 8

**Decision**: 모든 퍼센트는 최종적으로 `left` 기준으로 저장한다.

**Context**: Codex는 이미 `left` 중심이고, Claude는 `used` 중심이다. 최종 표시 체계를 하나로 맞춰야 UI와 cache가 단순해진다.

**Options**:
1. Option A — provider 원문 기준 유지  
   - pros: raw와 동일함  
   - cons: UI/비교가 복잡해짐
2. Option B — canonical `left`로 통일  
   - pros: 표시 규칙 일관, UI 단순  
   - cons: 일부 provider는 변환이 필요함

**Chosen**: Option B because 프로젝트 목표가 provider 간 동일 표현 체계이기 때문이다.

**Consequences**:
- Codex: 원문 `left` 그대로 사용
- Claude: `left = 100 - used`

### Canonical metric mapping

#### Claude

- `Current session` -> `five_hour`
- `Current week (all models)` -> `weekly`
- `Current week (Sonnet only)` -> `sonnet`

#### Codex

- `5h limit` -> `five_hour`
- `Weekly limit` -> `weekly`

---

## 9. Update / Merge Semantics

## Decision 9

**Decision**: cache update는 provider별 partial update를 허용하고, freshness metadata를 provider별로 유지한다.

**Context**: 실제 collector는 한 provider만 실패하는 경우가 많다. all-or-nothing은 성공률이 너무 낮아진다.

**Options**:
1. Option A — all-or-nothing  
   - pros: 전체 스냅샷 일관성  
   - cons: 현실적으로 취약함
2. Option B — partial update만  
   - pros: 실용적  
   - cons: freshness 정보가 부족함
3. Option C — partial update + provider freshness metadata  
   - pros: 가장 투명하고 튼튼함  
   - cons: 메타 필드가 늘어남

**Chosen**: Option C because 이 프로젝트는 일시 실패를 흡수해야 하고, 그 대신 freshness를 명시해야 하기 때문이다.

**Consequences**:
- provider별로 최신 성공 시각이 다를 수 있다.
- UI는 stale를 provider 단위로 판단할 수 있다.

### Merge rules

For each enabled provider:

1. `last_attempt_at`는 항상 갱신
2. collect 성공 시:
   - metrics 갱신
   - summary 갱신
   - `last_success_at` 갱신
   - `consecutive_failures = 0`
   - `status = "ok"`
   - `error = null`
3. collect 실패 시:
   - 이전 metrics 유지
   - `consecutive_failures += 1`
   - `status = "error"`
   - `error` 갱신
   - `last_success_at`는 유지
4. disabled provider:
   - 실행하지 않음
   - `enabled = false`

### Atomic write

- `usage.json.tmp`로 먼저 기록
- flush + rename
- 최종적으로 `usage.json` 교체

---

## 10. Error Model

## 10A. Blocker Model

**Decision**: trust/update/selection prompt는 `error`가 아니라 `blocker`로 저장한다.

**Context**: 이 상태는 수집 실패라기보다 사용자 입력 대기 상태에 가깝다. 메뉴바는 이를 실패와 구분해서 경고 표시와 해결 액션을 제공해야 한다.

**Options**:
1. Option A — error 문자열로만 저장  
   - pros: 구현이 단순함  
   - cons: 실패와 선택 대기를 구분할 수 없음
2. Option B — 별도 `blocker` object 저장  
   - pros: UI가 정확히 경고/액션을 표시할 수 있음  
   - cons: schema 필드가 늘어남

**Chosen**: Option B because blocker는 에러와 의미가 다르고, 메뉴바 액션과 직접 연결되어야 하기 때문이다.

**Consequences**:
- 자동 실행 중 blocker를 만나면 더 진행하지 않는다.
- 상단 메뉴바는 `!`와 같은 경고 표시를 붙일 수 있다.

### Blocker schema

```json
{
  "code": "trust_required",
  "message": "Claude needs workspace trust approval",
  "detected_at": "2026-04-15T20:30:00+09:00",
  "screen_excerpt": "Do you trust this folder?\nPress Enter to continue",
  "resolution": {
    "type": "resolve_command",
    "command": ["python3", "ai_usage_collector.py", "resolve", "--providers", "claude"]
  }
}
```

Suggested blocker codes:

- `trust_required`
- `update_required`
- `selection_required`
- `unknown_prompt`

## Decision 10

**Decision**: error는 structured object로 저장하고, raw/debug 데이터는 cache가 아니라 diagnostics 파일에 둔다.

**Context**: collector는 실패가 정상적으로 일어날 수 있다. error를 단순 문자열로만 두면 UI/운영/디버깅이 약해진다.

**Options**:
1. Option A — string error  
   - pros: 가장 단순함  
   - cons: 상태 분류가 어려움
2. Option B — structured error  
   - pros: UI/운영/디버깅에 충분함  
   - cons: 필드 설계가 필요함
3. Option C — structured error + raw excerpt를 cache에 포함  
   - pros: 디버깅 강함  
   - cons: cache가 지저분해짐

**Chosen**: Option B because cache는 제품 계약으로 깔끔하게 유지하고, raw/debug는 별도 파일로 분리하는 편이 낫기 때문이다.

**Consequences**:
- cache는 앱/플러그인이 안정적으로 읽기 좋다.
- raw capture는 `debug/`에서 별도로 확인한다.

### Error schema

```json
{
  "code": "parse_failed",
  "message": "Could not parse Claude usage from capture",
  "at": "2026-04-15T15:10:00+09:00"
}
```

### Suggested error codes

- `command_not_found`
- `command_failed`
- `tmux_failed`
- `timeout`
- `capture_failed`
- `parse_failed`
- `write_failed`
- `config_invalid`

---

## 11. Freshness / Stale Rules

## Decision 11

**Decision**: stale는 시간 기준 + 연속 실패 횟수 기준을 같이 사용한다.

**Context**: partial update 구조에서는 단순 실패 여부보다 “마지막 성공 이후 얼마나 지났는지”와 “실패가 계속되는지”가 더 중요하다.

**Options**:
1. Option A — 시간 기준만 사용  
   - pros: 단순함  
   - cons: transient failure를 잘 구분하지 못함
2. Option B — 시간 + 연속 실패 횟수  
   - pros: 실용적인 균형  
   - cons: 메타 데이터가 조금 늘어남
3. Option C — `fresh/degraded/stale` 다단계  
   - pros: 표현력 높음  
   - cons: 현재 규모엔 조금 과함

**Chosen**: Option B because 지금 규모에서 가장 단순하면서도 노이즈를 줄이는 방식이기 때문이다.

**Consequences**:
- stale 판정 로직이 config 값에 의해 조정 가능하다.
- UI는 provider별 stale만 알면 충분하다.

### Stale predicate

Provider is stale if either:

- `now - last_success_at > stale_after_seconds`
- `consecutive_failures >= stale_after_failures`

If `last_success_at` is missing and provider has never succeeded:

- provider is considered stale

---

## 12. Exit Code Contract

## Decision 12

**Decision**: `update`는 활성 provider 중 하나라도 성공하면 exit `0`, 전부 실패하거나 fatal이면 non-zero로 간다.

**Context**: partial update를 허용하고, single-provider 옵션도 지원하기 때문에, 전체 성공만을 정상으로 보는 것은 맞지 않는다.

**Options**:
1. Option A — 전체 성공만 exit 0  
   - pros: 엄격함  
   - cons: partial update와 single-provider 요구와 충돌
2. Option B — 활성 provider 중 하나라도 성공하면 exit 0  
   - pros: partial update와 일관적, 실용적  
   - cons: 부분 실패 상세는 별도 확인 필요
3. Option C — partial 전용 exit code 도입  
   - pros: 더 정교함  
   - cons: 지금 규모엔 과함

**Chosen**: Option B because partial update 정책과 single-provider 지원을 가장 자연스럽게 만족하기 때문이다.

**Consequences**:
- `claude`만 활성화한 경우, Claude만 성공해도 정상 종료
- `codex`만 활성화한 경우도 동일

### Exit codes

- `0`
  - 활성 provider 중 하나 이상 성공
- `1`
  - 활성 provider 전부 실패
- `2`
  - fatal usage/config/runtime error

Examples of fatal:

- config file parse 불가
- App Support 디렉토리 생성 실패
- cache atomic write 불가

---

## 13. Output Rules

### `print` default text format

```text
Cdx 99/94 · Cl 88/67

Codex
- 5h: 99% left (reset 18:32)
- week: 94% left (reset 15:04 on 17 Apr)

Claude
- 5h: 88% left (reset 6pm (Asia/Seoul))
- week: 67% left (reset Apr 17 at 2pm (Asia/Seoul))
- sonnet: 100% left (reset 6pm (Asia/Seoul))
```

### Summary rendering rules

- both enabled:
  - `Cdx {5h}/{week} · Cl {5h}/{week}`
- only codex enabled:
  - `Cdx {5h}/{week}`
- only claude enabled:
  - `Cl {5h}/{week}`

If stale:

- 표시 계층은 warning style 또는 stale marker를 붙일 수 있음
- core는 `stale: true`만 제공

---

## 14. Config Defaults

### Recommended defaults

```json
{
  "enabled_providers": ["claude", "codex"],
  "refresh_interval_seconds": 900,
  "stale_after_seconds": 1800,
  "stale_after_failures": 2,
  "debug_captures": true
}
```

### Default behavior if config missing

- App Support 디렉토리 생성
- default config in memory 사용
- 필요 시 `doctor`가 config 생성 안내

---

## 15. Migration Notes from Current Script

### Existing field drift

현재 구현 기준으로 다음 불일치가 이미 보였다.

- current xbar code expects:
  - `claude.session_left`
  - `claude.week_all_left`
- current cache observed:
  - `claude.five_hour_left`
  - `claude.weekly_left`

v1 core에서는 이 문제를 다음 방식으로 끝낸다.

- raw provider field 사용 금지
- canonical cache만 public contract로 사용

### Mapping from current script to v1

- `claude.session_left` -> `providers.claude.metrics.five_hour.left`
- `claude.session_reset` -> `providers.claude.metrics.five_hour.reset_at_label`
- `claude.week_all_left` -> `providers.claude.metrics.weekly.left`
- `claude.week_all_reset` -> `providers.claude.metrics.weekly.reset_at_label`
- `claude.sonnet_left` -> `providers.claude.metrics.sonnet.left`
- `codex.five_hour_left` -> `providers.codex.metrics.five_hour.left`
- `codex.weekly_left` -> `providers.codex.metrics.weekly.left`

---

## 16. Implementation Order

## Decision 13

**Decision**: 구현은 bottom-up으로 진행한다. 즉 collector core를 먼저 고정하고, 그 위에 xbar/native app을 얹는다.

**Context**: 현재 병목은 UI가 아니라 collector 안정성과 cache contract이다.

**Options**:
1. Option A — UI부터 재작성  
   - pros: 눈에 보이는 결과가 빨리 나옴  
   - cons: core가 흔들리면 다시 엎어야 함
2. Option B — collector + canonical schema부터 고정  
   - pros: 리스크가 가장 큰 부분부터 해결, 상위 레이어 재사용 가능  
   - cons: 초반에는 UI 진척이 덜 보일 수 있음

**Chosen**: Option B because 이 프로젝트에서 진짜 어려운 부분은 collector이고, UI는 그 위에 나중에 붙일 수 있기 때문이다.

**Consequences**:
- 먼저 Python collector를 정리한다.
- 다음에 xbar를 canonical cache 기준으로 바꾼다.
- 그 후 native macOS app을 붙인다.

### Recommended sequence

1. 현재 `update_ai_usage.py`를 모듈화
2. `config.json`/`usage.json` canonical contract 구현
3. `update`/`print`/`doctor` CLI 추가
4. 기존 xbar plugin을 새 cache schema에 맞춤
5. native macOS app 구현 시작

---

## 17. Final Summary

v1 core는 다음 한 줄로 요약된다.

> **Python one-shot collector가 활성 provider를 수집하고, canonical cache를 App Support 아래에 partial-update 방식으로 기록하며, UI는 그 결과만 읽는다.**

핵심 고정점:

- one-shot CLI
- Python v1 유지
- App Support 표준 경로
- config + CLI override
- provider enable/disable
- canonical `left` 기준
- explicit metrics + summary
- structured error
- stale = 시간 + 연속 실패
- partial update + provider freshness
