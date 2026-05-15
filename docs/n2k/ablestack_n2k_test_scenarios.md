# ablestack_n2k 테스트 시나리오

## 목적

이 문서는 `ablestack_n2k`의 단위 테스트, 통합 테스트, 실제 환경 검증을 관리하기 위한 테스트 시나리오 목록이다. 각 테스트는 ID를 가진다. GitHub Actions, fixture 기반 테스트, 실제 환경 테스트 결과를 이 ID로 추적한다.

## 테스트 원칙

- 로컬 빌드는 수행하지 않는다.
- 빌드와 패키징 검증은 GitHub Actions에서 수행한다.
- 리눅스 실행 코드는 LF 줄바꿈을 유지한다.
- 소스코드, 주석, 사용자 메시지, 로그 메시지, 에러 메시지는 영어로 작성한다.
- Markdown 테스트 문서는 한글로 작성하고 한글 표시를 확인한다.
- 바이너리 fixture는 명시 필요 시에만 추가한다.
- 실제 Nutanix 환경 테스트는 destructive action 여부를 사전에 구분한다.

## 테스트 분류

| 분류 | 접두어 | 설명 |
| --- | --- | --- |
| 정적 검증 | `N2K-STATIC` | 파일 형식, 문법, lint, 줄바꿈 |
| 단위 테스트 | `N2K-UNIT` | 함수와 parser 단위 검증 |
| 통합 테스트 | `N2K-INT` | 명령 흐름과 manifest 상태 검증 |
| 실제 환경 테스트 | `N2K-REAL` | Nutanix/ABLESTACK 실제 환경 검증 |
| 패키징 테스트 | `N2K-PKG` | GitHub Actions 기반 패키징 검증 |
| 회귀 테스트 | `N2K-REG` | 버그 재발 방지 |

## 테스트 상태 값

| 상태 | 의미 |
| --- | --- |
| `planned` | 작성됨, 아직 구현 전 |
| `ready` | 테스트 구현 완료 |
| `blocked` | 외부 환경 또는 구현 의존성으로 대기 |
| `passed` | 통과 |
| `failed` | 실패 |
| `skipped` | 조건 불충족으로 생략 |

## 정적 검증 시나리오

| ID | 이름 | 입력 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-STATIC-001` | Markdown UTF-8 확인 | `docs/n2k/*.md` | UTF-8 text로 인식 | planned |
| `N2K-STATIC-002` | Markdown LF 확인 | `docs/n2k/*.md` | CRLF 없음 | planned |
| `N2K-STATIC-003` | Shell LF 확인 | `bin/ablestack_n2k.sh`, `lib/n2k/*.sh` | CRLF 없음 | planned |
| `N2K-STATIC-004` | Shell syntax 확인 | shell scripts | syntax error 없음 | passed |
| `N2K-STATIC-005` | Shellcheck | shell scripts | shellcheck 통과 또는 명시 suppress | planned |
| `N2K-STATIC-006` | 소스코드 한글 금지 | `bin/`, `lib/n2k/`, `tests/n2k/` | 한글 주석/메시지 없음 | passed |
| `N2K-STATIC-007` | JSON fixture 검증 | `tests/fixtures/n2k/*.json` | `jq` parse 가능 | passed |
| `N2K-STATIC-008` | Markdown lint | `docs/n2k/*.md` | lint 통과 | planned |

## 단위 테스트 시나리오

### CLI

| ID | 이름 | 입력 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-UNIT-CLI-001` | global help | `ablestack_n2k --help` | command list 출력 | planned |
| `N2K-UNIT-CLI-002` | command help | `ablestack_n2k preflight --help` | preflight help 출력 | planned |
| `N2K-UNIT-CLI-003` | unknown command | `ablestack_n2k unknown` | 영어 오류와 exit code 2 | planned |
| `N2K-UNIT-CLI-004` | global option parsing | `--workdir`, `--run-id`, `--manifest`, `--json` | runtime env 정상 설정 | planned |
| `N2K-UNIT-CLI-005` | dry-run flag | `--dry-run` | destructive action skip flag 설정 | planned |

### manifest

| ID | 이름 | 입력 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-UNIT-MANIFEST-001` | manifest 생성 | 최소 VM inventory fixture | schema `ablestack-n2k/manifest-v1` 생성 | planned |
| `N2K-UNIT-MANIFEST-002` | VM 이름 정규화 | 공백, slash 포함 VM 이름 | 안전한 target file prefix 생성 | planned |
| `N2K-UNIT-MANIFEST-003` | target file path 생성 | file/qcow2 target | disk별 qcow2 path 생성 | planned |
| `N2K-UNIT-MANIFEST-004` | block target map 필수 | block target without map | validation 실패 | planned |
| `N2K-UNIT-MANIFEST-005` | rbd target map 검증 | rbd target map | `rbd:` prefix 확인 | planned |
| `N2K-UNIT-MANIFEST-006` | phase done 갱신 | phase name | `done=true`, timestamp 기록 | planned |
| `N2K-UNIT-MANIFEST-007` | sync issue 기록 | failure metadata | runtime sync issue append | planned |
| `N2K-UNIT-MANIFEST-008` | recovery point 기준 갱신 | previous/current RP | disk runtime 기준 RP 갱신 | planned |

### logging

| ID | 이름 | 입력 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-UNIT-LOG-001` | event 기록 | phase, disk, event | JSON line 기록 | planned |
| `N2K-UNIT-LOG-002` | JSON escaping | quote 포함 메시지 | valid JSON 유지 | planned |
| `N2K-UNIT-LOG-003` | status summary | events log fixture | 최근 상태 요약 출력 | planned |

### preflight와 mode selection

| ID | 이름 | 입력 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-UNIT-PREFLIGHT-001` | v4 가능 환경 | v4 namespace fixture | `v4-incremental` 권장 | planned |
| `N2K-UNIT-PREFLIGHT-002` | v4 dataprotection 불가 | vmm only fixture | `cold-export` fallback | planned |
| `N2K-UNIT-PREFLIGHT-003` | legacy 후보 가능 | legacy capability fixture | `legacy-cbt` 후보 표시 | passed |
| `N2K-UNIT-PREFLIGHT-004` | legacy without allow | legacy candidate, no allow flag | 자동 실행 차단 | passed |
| `N2K-UNIT-PREFLIGHT-005` | API 접속 실패 | connection error fixture | 명확한 failure reason | planned |
| `N2K-UNIT-PREFLIGHT-006` | target dependency 부족 | missing command fixture | unavailable dependency 표시 | planned |

### Nutanix API parser

| ID | 이름 | 입력 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-UNIT-API-001` | VM inventory parsing | v4 VM fixture | CPU, memory, firmware 파싱 | planned |
| `N2K-UNIT-API-002` | NIC parsing | NIC fixture | MAC 목록 정렬 | planned |
| `N2K-UNIT-API-003` | disk parsing | disk fixture | disk_id, size, bus/unit 생성 | planned |
| `N2K-UNIT-API-004` | recovery point parsing | RP fixture | VM RP와 disk RP 식별 | planned |
| `N2K-UNIT-API-005` | changed regions parsing | changed regions fixture | offset/length list 생성 | ready |
| `N2K-UNIT-API-006` | empty changed regions | empty fixture | no-op sync로 판정 | planned |
| `N2K-UNIT-API-007` | PE redirect parsing | discover cluster fixture | PE endpoint와 token 정보 추출 | planned |
| `N2K-UNIT-API-008` | legacy response parsing | legacy fixture | 지원 가능 여부와 제한 사항 추출 | ready |

### transfer와 patch

| ID | 이름 | 입력 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-UNIT-XFER-001` | target kind 결정 | file/qcow2 | file-qcow2 path 선택 | planned |
| `N2K-UNIT-XFER-002` | target kind 결정 | block map | block device 선택 | planned |
| `N2K-UNIT-XFER-003` | target kind 결정 | rbd map | rbd target 선택 | planned |
| `N2K-UNIT-XFER-004` | changed region coalesce | 인접 region fixture | coalesced range 생성 | planned |
| `N2K-UNIT-XFER-005` | no changed regions | empty list | patch 생략, manifest 갱신 | ready |
| `N2K-UNIT-XFER-006` | final sync failure | simulated read error | cutover 중단 | planned |

## 통합 테스트 시나리오

### dry-run 기반

| ID | 이름 | 흐름 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-INT-DRY-001` | preflight dry-run | `preflight --json` | capability JSON 출력 | planned |
| `N2K-INT-DRY-002` | plan dry-run | `plan --vm app-01 --json` | mode recommendation 출력 | planned |
| `N2K-INT-DRY-003` | run auto dry-run | `run --mode auto --dry-run` | destructive action 없이 plan 출력 | planned |
| `N2K-INT-DRY-004` | cold-export dry-run | `run --mode cold-export --dry-run` | full-copy 계획 출력 | planned |
| `N2K-INT-DRY-005` | legacy blocked dry-run | `plan --mode legacy-cbt` | allow flag 없으면 차단 | passed |

### fixture 기반 end-to-end

| ID | 이름 | 흐름 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-INT-FIX-001` | init fixture | fixture inventory to init | manifest 생성 | planned |
| `N2K-INT-FIX-002` | status fixture | manifest + events | status 요약 출력 | passed |
| `N2K-INT-FIX-003` | v4 incremental fixture | base RP, incr RP, changed regions | incr sync 상태 갱신 | passed |
| `N2K-INT-FIX-004` | final sync abort fixture | final changed regions read error | define/start 미수행 | planned |
| `N2K-INT-FIX-005` | cleanup fixture | manifest temporary resources | 기록된 리소스만 정리 대상으로 표시 | passed |
| `N2K-INT-FIX-006` | resume fixture | interrupted manifest | 다음 단계 결정 | passed |

### target storage 통합

| ID | 이름 | 흐름 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-INT-STOR-001` | file qcow2 target | file/qcow2 manifest | target path와 XML 생성 | planned |
| `N2K-INT-STOR-002` | file raw target | file/raw manifest | raw target path 생성 | planned |
| `N2K-INT-STOR-003` | block target | block map manifest | block target validation 통과 | planned |
| `N2K-INT-STOR-004` | rbd target | rbd map manifest | rbd target validation 통과 | planned |

## 실제 환경 테스트 시나리오

실제 환경 테스트는 별도 승인과 테스트 VM을 사용한다. 원본 VM 삭제, 원본 disk 삭제, 원본 snapshot 전체 삭제는 기본 테스트 범위에 포함하지 않는다.

Nutanix 테스트베드의 VM 종류별 실제 이관 절차와 판정 기준은 `docs/n2k/ablestack_n2k_real_migration_test_scenarios.md`에서 관리한다.

실제 이관 테스트의 주 흐름은 증분 마이그레이션이다. `cold-export`는 증분 capability가 없거나 증분 경로가 실패한 경우의 fallback으로 검증한다. target storage는 RBD, qcow2, block/LVM 순서로 모두 테스트한다.

| ID | 이름 | 환경 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-REAL-001` | 구버전 preflight | PC/AOS v4 미지원 환경 | cold fallback 안내 | blocked |
| `N2K-REAL-002` | 구버전 cold-export | PC/AOS v4 미지원 환경 | VM define-only 성공 | blocked |
| `N2K-REAL-003` | v4 preflight | PC/AOS v4 지원 환경 | v4-incremental 권장 | blocked |
| `N2K-REAL-004` | v4 base sync | v4 지원 테스트 VM | base target disk 생성 | blocked |
| `N2K-REAL-005` | v4 incr sync | v4 지원 테스트 VM | changed regions만 반영 | blocked |
| `N2K-REAL-006` | v4 final cutover | v4 지원 테스트 VM | target VM define/start 성공 | blocked |
| `N2K-REAL-007` | Linux guest cutover | Linux VM | first boot 성공 | blocked |
| `N2K-REAL-008` | Windows guest cutover | Windows VM | virtio/WinPE 후 boot 성공 | blocked |
| `N2K-REAL-009` | rbd target | ABLESTACK RBD 환경 | target VM define 가능 | blocked |
| `N2K-REAL-010` | failure cleanup | 강제 실패 주입 | source 원본 보존 | blocked |

## 패키징 테스트 시나리오

| ID | 이름 | 흐름 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-PKG-001` | RPM build in CI | GitHub Actions | rpm artifact 생성 | ready |
| `N2K-PKG-002` | DEB build in CI | GitHub Actions | deb artifact 생성 | ready |
| `N2K-PKG-003` | install file list | package inspect | `bin/ablestack_n2k.sh`, `lib/n2k` 포함 | ready |
| `N2K-PKG-004` | completion packaging | package inspect | completion file 포함 | ready |
| `N2K-PKG-005` | upgrade path | package test | 기존 파일 보존 정책 확인 | planned |

## 회귀 테스트 관리

버그가 발견되면 다음 형식으로 회귀 테스트를 추가한다.

| ID | 원인 | 재현 조건 | 기대 결과 | 상태 |
| --- | --- | --- | --- | --- |
| `N2K-REG-001` | 예약 | 예약 | 예약 | planned |

## 테스트 fixture 계획

초기 fixture는 텍스트 JSON으로만 구성한다.

```text
tests/fixtures/n2k/preflight/v4_available.json
tests/fixtures/n2k/preflight/v4_without_dataprotection.json
tests/fixtures/n2k/preflight/legacy_candidate.json
tests/fixtures/n2k/preflight/legacy_verified.json
tests/fixtures/n2k/inventory/vm_linux.json
tests/fixtures/n2k/inventory/vm_windows.json
tests/fixtures/n2k/recovery_point/base.json
tests/fixtures/n2k/recovery_point/incr.json
tests/fixtures/n2k/changed_regions/non_empty.json
tests/fixtures/n2k/changed_regions/empty.json
tests/fixtures/n2k/errors/api_connection_failed.json
```

바이너리 디스크 이미지는 초기 fixture에 포함하지 않는다.

## 테스트 결과 기록 형식

테스트 결과는 문서 또는 CI artifact에서 다음 항목을 포함한다.

| 항목 | 설명 |
| --- | --- |
| Test ID | 테스트 ID |
| Date | 실행 날짜 |
| Branch | 실행 브랜치 |
| Commit | 실행 커밋 |
| Environment | fixture, CI, real Nutanix 등 |
| Result | passed, failed, skipped |
| Evidence | log, artifact, screenshot, manifest 경로 |
| Notes | 추가 설명 |

## 릴리스 게이트

초기 preview 릴리스 전 최소 통과 조건은 다음과 같다.

- 모든 `N2K-STATIC-*` 통과
- CLI 관련 `N2K-UNIT-CLI-*` 통과
- manifest 관련 핵심 테스트 통과
- `N2K-INT-DRY-*` 통과
- `cold-export` fixture flow 통과
- GitHub Actions 패키징 테스트 통과

정식 릴리스 전 최소 통과 조건은 다음과 같다.

- preview 릴리스 조건 전체 통과
- `v4-incremental` fixture flow 통과
- 최소 1개 v4 지원 실제 환경에서 base/incr/final 검증
- 최소 1개 구버전 또는 v4 미지원 환경에서 cold fallback 검증
- Linux guest 실제 boot 검증
- Windows guest 실제 boot 검증
