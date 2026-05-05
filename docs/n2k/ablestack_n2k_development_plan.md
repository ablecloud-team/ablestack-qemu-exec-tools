# ablestack_n2k 개발 계획

## 목적

이 문서는 `ablestack_n2k` 개발을 단계별로 관리하기 위한 실행 계획이다. 설계 문서인 `ablestack_n2k_design.md`의 방향을 기준으로 하며, 구현 순서, 완료 기준, 테스트 준비 항목을 명확히 한다.

## 개발 원칙

- `ablestack_n2k`는 `ablestack_v2k`와 병합하지 않고 독립 구현한다.
- Markdown 문서는 한글로 작성하고 UTF-8/LF 상태를 유지한다.
- 리눅스 실행 코드는 반드시 LF 줄바꿈으로 관리한다.
- 소스코드, 소스코드 주석, 사용자 출력 메시지, 로그 메시지, 에러 메시지는 영어로 작성한다.
- 로컬 빌드는 수행하지 않는다.
- 빌드와 패키징 검증은 GitHub Actions에서 수행한다.
- 바이너리 파일은 명시 요청 없이는 수정하지 않는다.

## 개발 단계 요약

| 단계 | 이름 | 주요 산출물 | 완료 기준 | 상태 |
| --- | --- | --- | --- | --- |
| 0 | 기반 정리 | 문서, 브랜치 규칙, CI 원칙 | 설계/계획/테스트 문서 작성 | 완료 |
| 1 | CLI 골격 | `bin/ablestack_n2k.sh` | help, global option, command dispatch 동작 | 완료 |
| 2 | 공통 런타임 | `lib/n2k/logging.sh`, `manifest.sh`, `engine.sh` | manifest 생성/상태 갱신/이벤트 기록 가능 | 완료 |
| 3 | preflight/plan | `preflight`, `plan` 명령 | 환경별 지원 모드 판정 가능 | 완료 |
| 4 | Nutanix 인벤토리 | `lib/n2k/nutanix_api.*` | VM, disk, NIC, CPU, memory 정보 수집 | 완료 |
| 5 | cold-export | `sync base`, `cutover` 일부 | 전체 디스크 기반 KVM define 가능 | 완료 |
| 6 | v4 incremental PoC | recovery point, changed regions, patch | base/incr/final 흐름 검증 | 완료 |
| 7 | legacy fallback | legacy capability 탐지 | experimental 모드 또는 cold fallback 안내 | 완료 |
| 8 | 운영성 강화 | resume, cleanup, status | 중단/재개/정리 시나리오 관리 | 완료 |
| 9 | 패키징/CI | GitHub Actions, rpm/deb 반영 | CI에서 검증과 패키징 수행 | 완료 |

## 현재 구현 현황

마지막 갱신: 2026-04-30

현재 브랜치: `feature/ablestack_n2k`

현재 단계: 9단계 완료, preview 검증 준비

### 구현된 파일

| 파일 | 상태 | 설명 |
| --- | --- | --- |
| `docs/n2k/ablestack_n2k_design.md` | 완료 | n2k 전체 설계 문서 |
| `docs/n2k/ablestack_n2k_development_plan.md` | 진행 중 | 개발 단계와 구현 현황 관리 문서 |
| `docs/n2k/ablestack_n2k_test_scenarios.md` | 완료 | 단위/통합/실환경 테스트 시나리오 관리 문서 |
| `.github/workflows/n2k-ci.yml` | 9단계 완료 | n2k 전용 정적 검증, fixture smoke, RPM/DEB 빌드 workflow |
| `Makefile` | 9단계 완료 | `n2k-rpm`, `n2k-deb` 전용 패키징 target |
| `bin/ablestack_n2k.sh` | 1단계 완료 | CLI help, global option parsing, command dispatch, init/status 연결 |
| `completions/ablestack_n2k` | 9단계 완료 | bash completion |
| `deb/ablestack_n2k.control` | 9단계 완료 | n2k 전용 DEB control template |
| `rpm/ablestack_n2k.spec` | 9단계 완료 | n2k 전용 RPM spec |
| `lib/n2k/engine.sh` | 2단계 완료 | command handler, 기본 path 설정, init/status 실행 |
| `lib/n2k/logging.sh` | 2단계 완료 | JSON lines events log 기록 |
| `lib/n2k/manifest.sh` | 2단계 완료 | manifest v1 생성, phase 갱신, status summary 생성 |
| `lib/n2k/preflight.sh` | 3단계 완료 | capability 판정, mode selection, plan generation helper |
| `lib/n2k/nutanix_api.sh` | 4단계 완료 | Nutanix VM inventory parser, v4 VM list API helper |
| `lib/n2k/transfer_cold.sh` | 5단계 완료 | manual source-map 기반 cold-export base sync |
| `lib/n2k/transfer_patch.sh` | 6단계 완료 | changed-region 기반 raw file/block target patch sync |
| `lib/n2k/target_libvirt.sh` | 5단계 완료 | cold-export target libvirt XML artifact 생성 |
| `tests/fixtures/n2k/inventory/vm_linux.json` | 4단계 완료 | Linux VM inventory parser smoke fixture |
| `tests/fixtures/n2k/preflight/legacy_candidate.json` | 7단계 완료 | legacy 후보이나 endpoint 미검증 상태 fixture |
| `tests/fixtures/n2k/preflight/legacy_verified.json` | 7단계 완료 | legacy endpoint 검증 완료 상태 fixture |
| `tests/fixtures/n2k/changed_regions/non_empty.json` | 6단계 완료 | 증분/최종 동기화 smoke fixture |

### 현재 동작 범위

- `ablestack_n2k --help` 형식의 전체 도움말을 제공한다.
- `ablestack_n2k <command> --help` 형식의 명령별 도움말을 제공한다.
- `completions/ablestack_n2k` bash completion 파일을 제공한다.
- 전역 옵션 `--workdir`, `--run-id`, `--manifest`, `--log`, `--json`, `--dry-run`, `--resume`, `--force`를 파싱한다.
- `preflight`, `plan`, `run`, `auto`, `init`, `snapshot`, `sync`, `verify`, `cutover`, `cleanup`, `status` 명령을 인식한다.
- `init` 명령은 최소 manifest v1 파일을 생성한다.
- `status` 명령은 manifest를 읽어 현재 run 요약을 출력한다.
- `preflight` 명령은 `--capability-json` 또는 명시 capability override를 기반으로 지원 가능한 migration mode를 판정한다.
- `plan` 명령은 preflight 판정 결과를 기반으로 VM별 실행 단계 계획을 출력한다.
- `preflight`와 `plan`은 text 출력과 JSON 출력을 모두 지원한다.
- `preflight`와 `plan`은 `v4-incremental`, `legacy-cbt`, `cold-export`, `manual-disk` 모드 판정을 지원한다.
- `legacy-cbt`는 후보 상태와 endpoint 검증 상태를 분리해 판정한다.
- `legacy-cbt`는 endpoint 검증이 없으면 `--allow-experimental`이 있어도 실행 가능 모드로 처리하지 않는다.
- `legacy-cbt`는 endpoint 검증과 `--allow-experimental`이 모두 있을 때만 실행 가능 모드로 처리한다.
- legacy 후보가 불확실한 경우 `fallback_mode`으로 `cold-export` 또는 `manual-disk`를 안내한다.
- manifest가 있는 상태에서 `preflight` 또는 `plan`을 실행하면 legacy 후보, 검증 여부, fallback mode가 manifest에 기록된다.
- `status` 명령은 progress, next step, next command, cleanup pending 수를 출력한다.
- `status --resume-plan`은 manifest 기준 다음 재개 단계를 출력한다.
- `run` 명령은 아직 전체 orchestration을 수행하지 않지만, 전역 `--resume`과 함께 실행하면 manifest 기준 resume plan을 출력한다.
- `init` 명령은 `--inventory-json` 또는 `--inventory-file`로 전달된 Nutanix VM inventory를 정규화해 manifest에 저장한다.
- `init --inventory-source api`는 Prism Central v4 VM list API helper를 통해 VM inventory 조회를 시도할 수 있다.
- 실제 Nutanix 환경에서의 API 조회 검증은 아직 수행하지 않았다. 현재 검증은 fixture 기반이다.
- `sync base`는 `--source-map-json` 또는 `--source-map-file`로 전달된 source disk 경로를 target file/block/rbd 경로로 복제한다.
- `sync base`는 현재 cold-export/manual-disk source map 기반으로 동작한다.
- `sync base`는 file target의 `raw` 복제와 `qcow2` 변환 경로를 지원한다. `qcow2`와 `rbd` 경로는 `qemu-img`가 필요하다.
- `cutover --define-only`는 libvirt XML artifact를 생성한다.
- `cutover`가 생성한 libvirt XML artifact는 cleanup 대상으로 manifest에 기록된다.
- `cutover --apply`를 명시한 경우에만 `virsh define`을 시도한다.
- `sync incr`와 `sync final`은 `--source-map-json` 또는 `--source-map-file`로 전달된 source disk 경로에서 changed-region 범위만 target disk에 patch한다.
- `sync incr`와 `sync final`은 `--changed-regions-json` 또는 `--changed-regions-file` 입력을 지원한다.
- changed-region 입력은 disk id, device key, label, index 기준 매칭을 지원한다.
- changed-region 입력은 `{ "disks": { "<disk-id>": [...] } }`, `{ "<disk-id>": [...] }`, 단일 disk의 `{ "disk_id": "...", "regions": [...] }` 형태를 지원한다.
- `sync incr`와 `sync final`은 현재 raw file target과 block target에 대한 offset patch를 지원한다.
- file target의 qcow2 incremental patch와 rbd incremental patch는 아직 지원하지 않는다.
- `sync incr`와 `sync final`은 manifest에 phase 완료, disk별 증분 순번, 증분 bytes, region 수, recovery point id를 기록한다.
- 실제 Nutanix recovery point 생성, changed-region API 조회, recovery point disk read path는 아직 구현하지 않았다. 현재 6단계는 fixture/manual source-map 기반 PoC이다.
- `cleanup`은 기본적으로 계획만 출력하며, `--apply`를 명시한 경우에만 manifest에 기록된 workdir 내부 artifact를 삭제한다.
- source 관련 cleanup은 기본적으로 보존하며, source point 삭제 옵션은 전역 `--force` 없이는 실행되지 않는다.
- `run`, `snapshot`, `verify`는 아직 실제 기능을 수행하지 않고 `not implemented` 상태를 반환한다. 단, `run`은 전역 `--resume`과 함께 실행하면 resume plan을 반환한다.
- `Makefile`은 GitHub Actions에서 사용할 `n2k-rpm`, `n2k-deb` target을 제공한다.
- `rpm/ablestack_n2k.spec`는 `/usr/local/bin/ablestack_n2k`, `/usr/local/lib/ablestack-qemu-exec-tools/n2k`, bash completion, n2k 문서를 패키징한다.
- `deb/ablestack_n2k.control`과 `n2k-deb` target은 동일한 n2k 실행 파일, 라이브러리, completion, 문서를 DEB 패키지에 포함한다.
- `.github/workflows/n2k-ci.yml`은 shell syntax, shellcheck, JSON fixture, LF, 소스 한글 금지, fixture smoke, RPM/DEB 패키징을 GitHub Actions에서 수행한다.
- 알 수 없는 명령은 영어 오류 메시지와 함께 실패한다.

### 아직 구현되지 않은 항목

- 실제 Nutanix 환경 API 접속 검증
- 실제 Nutanix disk export/read path
- 실제 Nutanix recovery point 생성과 삭제
- 실제 Nutanix changed-region API 조회
- recovery point disk read path
- qcow2/rbd incremental patch
- 실제 legacy changed-region API 호출과 데이터 전송
- 전체 run orchestration
- GitHub Actions 실제 실행 결과 확인
- 실제 설치 환경에서 RPM/DEB 설치 검증

### 최근 검증 기록

| 날짜 | 검증 | 결과 |
| --- | --- | --- |
| 2026-04-28 | Markdown UTF-8 확인 | 통과 |
| 2026-04-28 | Markdown LF 확인 | 통과 |
| 2026-04-28 | `bin/ablestack_n2k.sh` 문법 확인 | 통과 |
| 2026-04-28 | `lib/n2k/*.sh` 문법 확인 | 통과 |
| 2026-04-28 | CLI help smoke 확인 | 통과 |
| 2026-04-28 | `init` manifest 생성 smoke 확인 | 통과 |
| 2026-04-28 | `status` manifest summary smoke 확인 | 통과 |
| 2026-04-28 | 소스코드 한글 포함 여부 확인 | 통과 |
| 2026-04-28 | 로컬 빌드 미수행 원칙 확인 | 통과 |
| 2026-04-30 | `preflight` v4 mode selection smoke 확인 | 통과 |
| 2026-04-30 | `plan` v4 incremental steps smoke 확인 | 통과 |
| 2026-04-30 | `plan` legacy experimental opt-in smoke 확인 | 통과 |
| 2026-04-30 | `preflight/plan` JSON output smoke 확인 | 통과 |
| 2026-04-30 | `preflight/plan` manifest phase 갱신 smoke 확인 | 통과 |
| 2026-04-30 | Nutanix inventory fixture JSON 검증 | 통과 |
| 2026-04-30 | `init --inventory-file` manifest 반영 smoke 확인 | 통과 |
| 2026-04-30 | `sync base` cold-export raw file target smoke 확인 | 통과 |
| 2026-04-30 | `cutover --define-only` libvirt XML artifact smoke 확인 | 통과 |
| 2026-04-30 | changed-region fixture JSON 검증 | 통과 |
| 2026-04-30 | `sync incr` raw file patch smoke 확인 | 통과 |
| 2026-04-30 | `sync final` raw file patch smoke 확인 | 통과 |
| 2026-04-30 | `init` -> `sync base` -> `sync incr` -> `sync final` fixture 흐름 확인 | 통과 |
| 2026-04-30 | legacy 후보 미검증 시 cold fallback smoke 확인 | 통과 |
| 2026-04-30 | legacy 검증 완료 및 `--allow-experimental` 누락 시 실행 차단 smoke 확인 | 통과 |
| 2026-04-30 | legacy 검증 완료 및 `--allow-experimental` 지정 시 실행 가능 smoke 확인 | 통과 |
| 2026-04-30 | legacy preflight 결과 manifest 기록 smoke 확인 | 통과 |
| 2026-04-30 | legacy endpoint 미검증 및 `--allow-experimental` 지정 시 실행 차단 smoke 확인 | 통과 |
| 2026-04-30 | `status --resume-plan` manifest 기반 다음 단계 확인 | 통과 |
| 2026-04-30 | `run --resume` resume plan 출력 확인 | 통과 |
| 2026-04-30 | `cutover --define-only` artifact cleanup 등록 확인 | 통과 |
| 2026-04-30 | `cleanup` 기본 dry-run 계획 확인 | 통과 |
| 2026-04-30 | `cleanup --apply` workdir artifact 삭제 확인 | 통과 |
| 2026-04-30 | `n2k-rpm` Makefile dry-run 구조 확인 | 통과 |
| 2026-04-30 | `n2k-deb` Makefile dry-run 구조 확인 | 통과 |
| 2026-04-30 | n2k completion shell syntax 확인 | 통과 |
| 2026-04-30 | n2k 패키징/CI 신규 파일 LF 확인 | 통과 |
| 2026-04-30 | n2k 패키징/CI 신규 소스 한글 포함 여부 확인 | 통과 |
| 2026-04-30 | n2k workflow YAML parse 확인 | 통과 |
| 2026-04-30 | n2k workflow fixture smoke 명령 확인 | 통과 |
| 2026-04-30 | shellcheck 로컬 확인 | 미수행: 로컬 도구 없음, GitHub Actions에서 수행 |
| 2026-04-30 | 로컬 빌드 미수행 원칙 확인 | 통과 |

## 0단계: 기반 정리

### 작업

- `docs/n2k/ablestack_n2k_design.md` 유지
- 개발 계획 문서 작성
- 테스트 시나리오 문서 작성
- 브랜치 규칙 문서 내 명시
- 구현 중 로컬 빌드 금지 원칙 확인

### 완료 기준

- `docs/n2k/` 아래 설계, 개발 계획, 테스트 계획 문서가 존재한다.
- 문서는 UTF-8이며 LF 줄바꿈을 사용한다.
- 한글 표시가 정상이다.

## 1단계: CLI 골격 구현

### 작업

- `bin/ablestack_n2k.sh` 생성
- global option 파싱 구현
- command dispatch 구현
- 명령별 help 출력 구현
- `preflight`, `plan`, `run`, `init`, `snapshot`, `sync`, `verify`, `cutover`, `cleanup`, `status` command placeholder 연결

### 구현 기준

- 코드는 영어만 사용한다.
- 사용자 메시지와 에러 메시지도 영어로 작성한다.
- shell script는 LF 줄바꿈을 유지한다.

### 완료 기준

- `ablestack_n2k --help`가 명령 목록을 출력한다.
- `ablestack_n2k <command> --help`가 명령별 help를 출력한다.
- 미지원 명령 입력 시 명확한 영어 오류를 반환한다.

### 구현 기록

- 2026-04-28: `bin/ablestack_n2k.sh`를 추가했다.
- 2026-04-28: global option parsing과 command dispatch를 구현했다.
- 2026-04-28: 명령별 help 출력을 구현했다.
- 2026-04-28: 빈 command argument 처리 오류를 수정했다.

## 2단계: 공통 런타임 구현

### 작업

- `lib/n2k/logging.sh` 구현
- `lib/n2k/manifest.sh` 구현
- `lib/n2k/engine.sh` 구현
- workdir, run-id, manifest, events log 경로 초기화
- JSON/text output 정책 구현
- phase 상태 갱신 함수 구현

### 완료 기준

- `init` 명령으로 manifest v1 파일을 생성할 수 있다.
- phase start/done/fail 이벤트를 events log에 기록할 수 있다.
- `status` 명령이 manifest와 events log를 읽어 요약을 출력한다.

### 구현 기록

- 2026-04-28: `lib/n2k/logging.sh`를 추가했다.
- 2026-04-28: `lib/n2k/manifest.sh`를 추가했다.
- 2026-04-28: `lib/n2k/engine.sh`를 추가했다.
- 2026-04-28: `init` 명령에서 최소 manifest v1 생성 흐름을 구현했다.
- 2026-04-28: `status` 명령에서 manifest summary 출력 흐름을 구현했다.
- 2026-04-28: 미구현 명령은 JSON 또는 text 형태로 `not_implemented`를 반환하도록 정리했다.

## 3단계: preflight/plan 구현

### 작업

- Prism Central 접속 점검
- Prism Element 또는 cluster endpoint 탐지
- 인증 방식 점검
- API family와 namespace capability 점검
- v4 `vmm`, `dataprotection` 사용 가능 여부 확인
- legacy changed-region 후보 기능 탐지
- cold export 가능성 점검
- target host command dependency 점검
- 지원 가능한 migration mode 판정

### 모드 판정 정책

| 조건 | 권장 모드 |
| --- | --- |
| v4 VM 조회와 v4 changed regions 모두 가능 | `v4-incremental` |
| legacy changed-region 기능 확인, 명시 허용 옵션 있음 | `legacy-cbt` |
| 전체 디스크 export/copy 가능 | `cold-export` |
| API 기반 source 접근 불가, 사용자가 disk 제공 | `manual-disk` |

### 완료 기준

- `preflight`가 환경 정보를 수집하고 지원 가능 모드를 출력한다.
- `plan`이 VM 단위 migration plan을 manifest 또는 JSON으로 출력한다.
- v4가 불가능한 환경에서도 cold fallback 가능성을 안내한다.

### 구현 기록

- 2026-04-30: `lib/n2k/preflight.sh`를 추가했다.
- 2026-04-30: `preflight` 명령에서 capability JSON 또는 명시 override 기반 mode selection을 구현했다.
- 2026-04-30: `plan` 명령에서 선택된 migration mode별 실행 단계 생성을 구현했다.
- 2026-04-30: `legacy-cbt`는 `--allow-experimental`이 있을 때만 실행 가능 모드로 판단하도록 구현했다.
- 2026-04-30: `v4-incremental`, `legacy-cbt`, `cold-export`, `manual-disk` 판정 결과를 text와 JSON으로 출력하도록 구현했다.
- 2026-04-30: 직접 Nutanix API probing은 4단계 인벤토리/API 구현으로 넘긴다.

## 4단계: Nutanix 인벤토리 수집

### 작업

- VM 식별자 해석
- VM power state 조회
- CPU, memory 조회
- firmware, secure boot, TPM 정보 조회
- NIC, MAC, subnet 정보 조회
- disk 목록, size, bus/unit 정보 조회
- recovery point 관련 식별자 모델링

### 완료 기준

- 인벤토리 결과가 `ablestack-n2k/manifest-v1` 구조에 저장된다.
- disk별 `disk_id`, source identifier, target path가 안정적으로 생성된다.
- target map validation이 동작한다.

### 구현 기록

- 2026-04-30: `lib/n2k/nutanix_api.sh`를 추가했다.
- 2026-04-30: Nutanix VM inventory raw JSON을 n2k 표준 inventory 구조로 정규화하는 parser를 구현했다.
- 2026-04-30: Prism Central v4 VM list API helper 골격을 구현했다.
- 2026-04-30: `init --inventory-json`과 `init --inventory-file` 옵션을 추가했다.
- 2026-04-30: `init --inventory-source api` 옵션을 추가했다.
- 2026-04-30: inventory 기반 disk target path 생성과 target map validation을 manifest 생성에 연결했다.
- 2026-04-30: `tests/fixtures/n2k/inventory/vm_linux.json` fixture를 추가했다.
- 2026-04-30: 실제 Nutanix 환경 API 검증은 아직 수행하지 않았으며, fixture 기반 smoke 검증만 완료했다.

## 5단계: cold-export 구현

### 작업

- source VM shutdown 또는 snapshot 기준점 확보
- 전체 디스크 read path 구현
- target file/qcow2 우선 지원
- target raw, block, rbd 확장
- libvirt XML 생성 경로 연결
- define-only와 start 정책 구현

### 완료 기준

- VM 1대의 전체 디스크를 target qcow2로 복제할 수 있다.
- 복제된 디스크로 libvirt domain XML을 생성할 수 있다.
- `--define-only`로 VM을 정의할 수 있다.
- source 원본 데이터 삭제 없이 cleanup이 동작한다.

### 구현 기록

- 2026-04-30: `lib/n2k/transfer_cold.sh`를 추가했다.
- 2026-04-30: `sync base --source-map-json`과 `sync base --source-map-file` 옵션을 추가했다.
- 2026-04-30: source map의 disk id, device key, label, index 기반 source path 매칭을 구현했다.
- 2026-04-30: file target의 raw 복제 경로를 구현했다.
- 2026-04-30: file target의 qcow2 변환 경로를 구현했다. 이 경로는 `qemu-img`가 필요하다.
- 2026-04-30: block target 복제 경로를 구현했다. 대상은 block device여야 한다.
- 2026-04-30: rbd target 변환 경로를 구현했다. 이 경로는 `qemu-img`가 필요하다.
- 2026-04-30: cold-export source path와 base sync metrics를 manifest에 기록하도록 구현했다.
- 2026-04-30: `lib/n2k/target_libvirt.sh`를 추가했다.
- 2026-04-30: `cutover --define-only`에서 libvirt XML artifact를 생성하도록 구현했다.
- 2026-04-30: `cutover --apply`를 명시한 경우에만 `virsh define`을 실행하도록 구현했다.
- 2026-04-30: 실제 Nutanix disk export/read path는 아직 구현하지 않았다. 현재 cold-export는 manual source-map 기반이다.

## 6단계: v4 incremental PoC 구현

### 작업

- VM recovery point 생성
- VM recovery point와 disk recovery point 식별
- changed regions discover cluster flow 구현
- PE endpoint/JWT 기반 changed regions 조회
- changed region list 정규화
- target disk patch 적용
- base/incr/final 기준 recovery point 갱신

### 완료 기준

- base sync 후 incr sync가 changed regions만 반영한다.
- final sync 실패 시 libvirt define/start를 중단한다.
- 성공 시 manifest에 final sync 완료와 기준 recovery point가 기록된다.

### 구현 기록

- 2026-04-30: `lib/n2k/transfer_patch.sh`를 추가했다.
- 2026-04-30: `sync incr`와 `sync final`에 `--changed-regions-json`, `--changed-regions-file`, `--recovery-point-id` 옵션을 추가했다.
- 2026-04-30: changed-region JSON을 disk id, device key, label, index 기준으로 target disk에 매칭하도록 구현했다.
- 2026-04-30: `offset`, `start`, `start_offset`와 `length`, `len`, `size` 필드명을 정규화하도록 구현했다.
- 2026-04-30: raw file target과 block target에 대해 offset 기반 patch를 적용하도록 구현했다.
- 2026-04-30: file target의 qcow2 incremental patch와 rbd incremental patch는 명시 오류로 중단하도록 구현했다.
- 2026-04-30: manifest에 증분 순번, 증분 bytes, region 수, `incr_sync` 또는 `final_sync` phase, recovery point id를 기록하도록 구현했다.
- 2026-04-30: `tests/fixtures/n2k/changed_regions/non_empty.json` fixture를 추가했다.
- 2026-04-30: 실제 Nutanix recovery point 생성, changed-region API 조회, recovery point disk read path는 아직 구현하지 않았다. 현재 6단계는 fixture/manual source-map 기반 PoC이다.

## 7단계: legacy fallback 구현

### 작업

- legacy API capability 탐지
- legacy changed-region 후보 endpoint 검증
- experimental 실행 보호 옵션 구현
- 실패 시 cold fallback 안내

### 완료 기준

- legacy 기능이 불확실한 환경에서 자동으로 성공 처리하지 않는다.
- `--allow-experimental` 없이 `legacy-cbt`가 실행되지 않는다.
- legacy 기능 사용 여부가 manifest와 events log에 기록된다.

### 구현 기록

- 2026-04-30: legacy changed-region 후보 상태와 endpoint 검증 상태를 분리했다.
- 2026-04-30: `--legacy-endpoint-verified` 옵션을 추가했다.
- 2026-04-30: capability JSON의 `legacy.verified`, `legacy.endpoint_verified`, `legacy.probe.status` 값을 legacy endpoint 검증 근거로 사용하도록 구현했다.
- 2026-04-30: legacy 후보가 있어도 endpoint 검증이 없으면 `legacy-cbt`를 실행 가능 모드로 처리하지 않도록 변경했다.
- 2026-04-30: legacy endpoint 검증이 있어도 `--allow-experimental`이 없으면 `legacy-cbt`를 실행 가능 모드로 처리하지 않도록 유지했다.
- 2026-04-30: legacy 실행 불가 시 `fallback_mode`을 통해 `cold-export` 또는 `manual-disk`를 안내하도록 구현했다.
- 2026-04-30: preflight/plan 결과를 manifest의 `runtime.preflight`, `source.api`, `source.fallback`에 기록하도록 구현했다.
- 2026-04-30: `tests/fixtures/n2k/preflight/legacy_candidate.json` fixture를 추가했다.
- 2026-04-30: `tests/fixtures/n2k/preflight/legacy_verified.json` fixture를 추가했다.
- 2026-04-30: 실제 legacy changed-region API 호출과 legacy 데이터 전송은 아직 구현하지 않았다.

## 8단계: 운영성 강화

### 작업

- resume 정책 구현
- cleanup 안전장치 구현
- interrupted run 복구 처리
- status 요약 강화
- dry-run 동작 정리
- JSON output 안정화

### 완료 기준

- 중단된 run을 manifest 기반으로 재개할 수 있다.
- cleanup은 manifest에 기록된 임시 리소스만 정리한다.
- source VM과 source disk는 기본적으로 보존된다.

### 구현 기록

- 2026-04-30: manifest phase 상태를 기준으로 next step, next command, progress를 산출하는 resume summary를 구현했다.
- 2026-04-30: `status` 출력에 progress, next step, next command, cleanup pending 수를 추가했다.
- 2026-04-30: `status --resume-plan` 옵션을 추가했다.
- 2026-04-30: 전역 `--resume`과 함께 `run`을 실행하면 전체 orchestration 대신 resume plan을 출력하도록 구현했다.
- 2026-04-30: cleanup 대상 artifact를 manifest의 `runtime.cleanup.items`에 기록하는 helper를 추가했다.
- 2026-04-30: `cutover`에서 생성한 libvirt XML artifact를 cleanup 대상으로 기록하도록 구현했다.
- 2026-04-30: `cleanup` 명령을 구현했다. 기본 동작은 계획 출력이며, `--apply`를 지정한 경우에만 manifest에 기록된 workdir 내부 artifact를 삭제한다.
- 2026-04-30: `--remove-source-points`와 `--remove-workdir`는 전역 `--force` 없이는 차단되도록 했다.
- 2026-04-30: source VM, source disk, source recovery point는 기본 cleanup 대상에서 제외된다.

## 9단계: 패키징과 GitHub Actions

### 작업

- install script 반영
- rpm/deb packaging 반영
- bash completion 추가
- GitHub Actions workflow 추가 또는 확장
- 문서 lint, shellcheck, unit test, fixture test, package validation 추가

### 완료 기준

- 로컬 빌드 없이 GitHub Actions에서 검증된다.
- 패키지에 `ablestack_n2k` 실행 파일과 `lib/n2k` 모듈이 포함된다.
- CI 실패 시 원인을 추적할 수 있는 로그가 남는다.

### 구현 기록

- 2026-04-30: `.github/workflows/n2k-ci.yml` workflow를 추가했다.
- 2026-04-30: n2k workflow에 shell syntax, shellcheck, JSON fixture, LF, 소스 한글 금지 검증을 추가했다.
- 2026-04-30: n2k workflow에 fixture 기반 `init` -> `sync base` -> `sync incr` smoke를 추가했다.
- 2026-04-30: n2k workflow에 RPM build job과 DEB build job을 추가했다.
- 2026-04-30: `Makefile`에 `n2k-rpm`, `n2k-deb` target을 추가했다.
- 2026-04-30: `rpm/ablestack_n2k.spec`를 추가했다.
- 2026-04-30: `deb/ablestack_n2k.control`을 추가했다.
- 2026-04-30: `completions/ablestack_n2k`를 추가했다.
- 2026-04-30: `install.sh` source installer에 `ablestack_n2k` 실행 파일과 completion 설치를 추가했다.
- 2026-04-30: 로컬에서는 실제 RPM/DEB 빌드를 수행하지 않았고, `make -n n2k-rpm`, `make -n n2k-deb`로 target 구조만 확인했다.

## 구현 후 테스트 단계

### 1단계: 정적 검증

- shell syntax check
- shellcheck
- Markdown lint
- JSON fixture validation
- LF 줄바꿈 확인
- 소스코드 한글 포함 여부 확인

### 2단계: 단위 테스트

- CLI option parsing
- manifest helper
- mode selection
- Nutanix API response parser
- target path assignment
- changed region normalization
- event log writer

### 3단계: 통합 테스트

- preflight to plan
- init to manifest
- cold-export dry-run
- cold-export define-only
- v4 incremental fixture flow
- legacy fallback decision
- cleanup safety

### 4단계: 실제 환경 검증

- 구버전 Nutanix 환경에서 `preflight`와 `cold-export`
- v4 지원 Nutanix 환경에서 `v4-incremental`
- Windows VM cutover
- Linux VM cutover
- file/block/rbd target별 검증

### 5단계: 패키징 검증

- GitHub Actions 기반 rpm/deb build
- 설치 후 command path 확인
- completion 설치 확인
- uninstall 또는 upgrade 동작 확인

## 릴리스 전 체크리스트

- 문서가 한글로 작성되어 있고 한글 깨짐이 없다.
- 리눅스 실행 코드는 LF 줄바꿈이다.
- 소스코드, 주석, 메시지는 영어이다.
- 로컬 빌드를 수행하지 않았다.
- GitHub Actions 검증이 통과했다.
- source 원본 삭제 또는 위험 cleanup 기본값이 없다.
- `cold-export` fallback이 문서화되어 있다.
- `legacy-cbt`는 experimental로 보호되어 있다.
- `v4-incremental` 실패 시 안전하게 중단한다.
