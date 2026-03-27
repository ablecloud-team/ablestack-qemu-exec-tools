# ablestack_vm_ftctl 작업 시퀀스

## 1. 목적

이 문서는 `ablestack_vm_ftctl` 개발의 **실행 순서 기준 문서**다.

- 작업은 이 문서의 순서를 따른다.
- 작업 진행 중 상태가 바뀌면 이 문서를 업데이트한다.
- 설계 상세는 `ablestack_vm_ftctl_design.md`를 참고하고, 실제 구현 순서는 본 문서를 기준으로 한다.

## 2. 사용 규칙

- 상태 값은 `done`, `in_progress`, `pending`, `blocked`를 사용한다.
- 한 시점에 `in_progress`는 가능한 한 하나만 둔다.
- 구현 순서가 바뀌면 이유를 이 문서에 남긴다.

## 3. 현재 상태 요약

- 브랜치: `feature/vm-ha-dr-ft`
- 현재 단계: `Step 3 완료, Step 4 준비 완료`
- 완료된 항목:
  - `ftctl` 설계 문서 작성
  - `ftctl` CLI 스켈레톤 추가
  - `ftctl` 상태/로그/설정/오케스트레이터 골격 추가
  - shell completion 추가
  - `build.yml` Rocky Linux 9.6 기준 반영
  - `install-linux.sh` / `uninstall-linux.sh` 반영
  - OS별 ISO 분리 반영
  - profile schema 문서화 및 loader 검증 추가
  - blockcopy inventory 수집 / 실제 시작 / job info 추적 추가
  - primary domain XML 백업 및 transient/persistent 기록 추가
  - active/standby XML 번들 관리 추가
  - cluster/host inventory model 및 config 명령 추가

## 4. 작업 시퀀스

### Step 1. Profile 형식 고정

- 상태: `done`
- 목표:
  - `/etc/ablestack/ftctl.d/<vm>.conf` 스키마 확정
  - 필수값과 선택값 구분
  - mode별 허용 필드 정리
- 산출물:
  - profile 예제
  - profile loader 검증 로직
- 핵심 항목:
  - `FTCTL_PROFILE_MODE`
  - `FTCTL_PROFILE_PRIMARY_URI`
  - `FTCTL_PROFILE_SECONDARY_URI`
  - `disk_map`
  - `fencing_policy`
  - `transport_tolerance_sec`
  - `auto_rearm`
- 완료 메모:
  - `lib/ftctl/profile.sh`에 schema validation 추가
  - `docs/ftctl/ablestack_vm_ftctl_profile_schema.md` 추가
  - `ft` 전용 `FTCTL_PROFILE_XCOLO_*` 필드 정의 및 mode별 검증 반영

### Step 2. blockcopy 실제 구현

- 상태: `done`
- 목표:
  - `protect` 시 디스크 inventory 수집
  - `virsh blockcopy` 실제 실행
  - block job 상태 추적
  - disk별 job lifecycle 관리
- 산출물:
  - `lib/ftctl/blockcopy.sh` 실제 로직
  - `protect` 시 동작하는 최소 end-to-end 경로
- 핵심 항목:
  - `virsh blockcopy`
  - `virsh domjobinfo`
  - `virsh blockjob`
  - `--synchronous-writes`
- 완료 메모:
  - primary VM disk inventory 수집 구현
  - primary domain XML 백업 추가
  - `primary.xml`, `standby.xml`, `meta` 번들 관리 추가
  - transient/persistent 여부 기록 추가
  - `disk_map=auto` 또는 `target=dest` 매핑 지원
  - `virsh blockcopy --wait --verbose [--synchronous-writes]` 실제 호출 추가
  - blockcopy sidecar 상태 파일과 job info refresh 추가

### Step 3. Cluster/Host inventory model 구현

- 상태: `done`
- 목표:
  - cluster 정보 구조 고정
  - host 목록과 host별 role/ip/uri 관리 모델 추가
  - management IP와 data path IP 구분
- 산출물:
  - cluster config schema
  - cluster/host loader
  - 로컬 호스트 식별 로직
- 핵심 항목:
  - cluster name
  - local host id
  - host inventory
  - management ip
  - libvirt uri
  - blockcopy replication ip
  - x-colo control ip
  - x-colo data/nbd ip
- 완료 메모:
  - `/etc/ablestack/ablestack-vm-ftctl-cluster.conf` 전역 설정 추가
  - `/etc/ablestack/ftctl-cluster.d/hosts/<host>.conf` host inventory 형식 추가
  - `ablestack_vm_ftctl config ...` 서브커맨드 추가
  - cluster schema 문서 추가

### Step 4. reconcile 상태기계 구체화

- 상태: `pending`
- 목표:
  - `protected`, `degraded`, `rearming`, `failing_over` 전이 조건 확정
  - source fenced와 순간 네트워크 단절 판별
  - 재시도/backoff/error 전환 기준 반영
- 산출물:
  - `lib/ftctl/orchestrator.sh` 상태 전이 로직
  - `lib/ftctl/state.sh` 상태 필드 확장
- 핵심 항목:
  - `transport_state`
  - `rearm_count`
  - `last_rearm_ts`
  - `FTCTL_TRANSIENT_NET_GRACE_SEC`

### Step 5. Fencing provider abstraction 구현

- 상태: `pending`
- 목표:
  - 최소 fencing provider 구현
  - failover 전 fencing 강제
- 산출물:
  - `lib/ftctl/fencing.sh` 확장
- 우선순위:
  - `manual-block`
  - `ssh`
  - `virsh destroy on peer`
- 후속 확장:
  - `ipmi`
  - `redfish`

### Step 6. Standby domain 관리 구현

- 상태: `pending`
- 목표:
  - secondary XML 준비
  - failover 시 define/start
  - 네트워크 attach와 boot verify 연결
- 산출물:
  - standby domain define/start 로직
  - failover 후 verify

### Step 7. x-colo 래퍼 구현

- 상태: `pending`
- 목표:
  - QMP wrapper 추가
  - `x-colo` 시작/상태조회/재무장/승격 로직 추가
- 산출물:
  - `lib/ftctl/xcolo.sh` 실제 구현
- 핵심 항목:
  - `x-colo-lost-heartbeat`
  - `colo_rearming`
  - QMP capability negotiation

### Step 8. 검증 시나리오 스크립트화

- 상태: `pending`
- 목표:
  - 구문 검증
  - shellcheck
  - profile 샘플 검증
  - rearm 상태 전이 검증
  - build 산출물 경로 검증
- 산출물:
  - 반복 실행 가능한 검증 절차
  - 필요 시 테스트용 helper script

### Step 9. 패키징 마감

- 상태: `pending`
- 목표:
  - `ftctl` 패키징 범위 확정
  - completion 포함 범위 확정
  - systemd/unit/install path 마감
- 산출물:
  - 필요 시 `ftctl` 전용 RPM spec
  - installer/package 반영 정리

### Step 10. 문서 보강

- 상태: `pending`
- 목표:
  - 운영 runbook 작성
  - failover/failback 절차 작성
  - ISO별 사용법 정리
- 산출물:
  - 운영 문서
  - 관리자용 절차서

### Step 11. PR 준비

- 상태: `pending`
- 목표:
  - diff 정리
  - 검증 결과 정리
  - known gap 정리
- 산출물:
  - PR 설명 초안
  - 검증 체크리스트

## 5. 다음 작업

- 다음 우선 작업: `Step 4. reconcile 상태기계 구체화`
- 그 다음 작업: `Step 5. Fencing provider abstraction 구현`
- 그 다음 작업: `Step 6. Standby domain 관리 구현`

## 6. 업데이트 규칙

이후 진행 시 아래처럼 갱신한다.

- 완료 시:
  - 해당 step 상태를 `done`으로 변경
  - 완료된 산출물을 간단히 기록
- 진행 시작 시:
  - 해당 step 상태를 `in_progress`로 변경
- 이슈 발생 시:
  - 해당 step 상태를 `blocked`로 변경
  - 원인과 우회안을 기록
