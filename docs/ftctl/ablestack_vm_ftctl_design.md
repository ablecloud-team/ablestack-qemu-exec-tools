# ablestack_vm_ftctl 설계안

## 1. 목표

`ablestack_vm_ftctl`은 QEMU/libvirt 기반 VM에 대해 다음 세 가지 보호 모드를 통합 관리하는 제어기이다.

- `ha`: 동일 사이트 또는 metro 수준 이중화. 스토리지는 `virsh blockcopy`로 미러링한다.
- `dr`: 원격 사이트 재해복구. 스토리지는 `virsh blockcopy`로 미러링하고, 원격 사이트에서 빠르게 기동할 수 있도록 대기 구성을 유지한다.
- `ft`: 무중단에 가까운 장애 승계를 위한 Fault Tolerance. QEMU `x-colo`를 사용해 실행 상태를 이중화한다.

최종 목표는 "RTO 0에 근접"한 운영 경험이다. 다만 기술적으로는 다음처럼 구분해야 한다.

- `ft/x-colo`: 계산 상태까지 복제하므로 가장 낮은 RTO를 기대할 수 있다.
- `ha/dr + blockcopy`: 디스크 복제는 거의 실시간으로 유지할 수 있지만, 장애 시 대상 측 VM 승격 및 기동 시간이 필요하므로 엄밀한 의미의 RTO 0은 아니다.

즉, 본 설계는 "모든 VM을 동일 방식으로 처리"하지 않고, VM 중요도에 따라 `ha`, `dr`, `ft`를 선택하는 계층형 보호 모델을 전제로 한다.

## 2. 핵심 제약

### 2.1 blockcopy 기반 HA/DR

- libvirt `blockcopy`는 대상 디스크로 활성 복제를 수행한 뒤, 미러링 상태를 유지할 수 있다.
- 운영 중 쓰기 수렴을 위해 `--synchronous-writes` 사용이 사실상 필수다.
- 초기 sync 완료 뒤에도 실제 서비스 전환은 `blockjob --pivot` 또는 대상 측 기동 절차가 필요하다.
- 따라서 blockcopy만으로는 "실행 중인 CPU/메모리 상태"가 복제되지 않는다.

### 2.2 x-colo 기반 FT

- QEMU 공식 문서 기준으로 COLO heartbeat는 내장 구현이 없으며, failover는 `x-colo-lost-heartbeat` QMP 명령으로 직접 트리거해야 한다.
- 보조 측은 추가 메모리 자원을 많이 사용한다. 공식 문서는 secondary 측에 guest RAM의 2배 수준 여유를 요구한다.
- 양측 QEMU 버전과 머신 호환성이 사실상 동일해야 한다.
- 네트워크 비교/복제 프록시, 디스크 복제, QMP 제어를 모두 안정적으로 운영해야 한다.

### 2.3 순간 네트워크 단절에 대한 제약

- `blockcopy`와 `x-colo` 모두 네트워크 경로에 의존하므로, 1초에서 2초 수준의 순간 단절만으로도 replication session이 깨질 수 있다.
- 이때 source 측이 명시적으로 fenced된 것이 아니라면, 이를 즉시 failover 조건으로 해석하면 안 된다.
- 따라서 `ftctl`은 "source fenced/irreversible loss"와 "일시 네트워크 단절"을 구분해야 하며, 후자의 경우 기존 세션을 정리하고 동일 명령을 재실행해 미러링 상태를 복원해야 한다.
- 즉, replication 유지 전략은 "한 번 걸어 두는 복제"가 아니라 "끊기면 자동으로 다시 거는 self-healing 복제"여야 한다.

이 제약 때문에 `ftctl`은 단순 명령 래퍼가 아니라, 상태 추적, health 판단, fencing, failover orchestration을 가진 제어기로 설계해야 한다.

## 3. 상위 아키텍처

`ftctl`은 기존 `hangctl`과 같은 구조를 따르되, "감시 + 상태기계 + 실행기"를 분리한다.

### 3.1 제안 디렉터리 구조

```text
bin/
  ablestack_vm_ftctl.sh
lib/
  ftctl/
    common.sh
    config.sh
    logging.sh
    libvirt_wrap.sh
    inventory.sh
    profile.sh
    state.sh
    blockcopy.sh
    xcolo.sh
    failover.sh
    verify.sh
    orchestrator.sh
    fencing.sh
    systemd/
      ablestack-vm-ftctl.service
      ablestack-vm-ftctl.timer
etc/
  ablestack-vm-ftctl.conf
docs/
  ftctl/
    ablestack_vm_ftctl_design.md
    ablestack_vm_ftctl_events.md
```

### 3.2 제어 plane

- `inventory`: 보호 대상 VM, 디스크, NIC, storage pool, peer host, mode를 해석한다.
- `profile`: VM별 보호 정책을 만든다.
- `orchestrator`: desired state와 current state를 비교해 sync, resume, failover, failback을 결정한다.
- `state`: `/run/ablestack-vm-ftctl` 아래 런타임 상태를 저장한다.
- `logging`: `/var/log/ablestack-vm-ftctl/events.log`에 append-only JSONL을 기록한다.
- `fencing`: split-brain 방지를 위해 원격 호스트 또는 원본 VM을 차단한다.

### 3.3 데이터 plane

- `ha/dr`: `virsh blockcopy`, `virsh blockjob`, 필요 시 `virsh domjobinfo`
- `ft`: `virsh qemu-monitor-command` 또는 QMP socket을 통한 `x-colo`, `nbd-server-*`, migration capability 제어

## 4. 운영 모델

### 4.1 보호 단위

보호 단위는 "VM profile"이다. VM마다 아래 속성을 가진다.

- `mode`: `ha`, `dr`, `ft`
- `primary_uri`: 예: `qemu:///system`
- `secondary_uri`: 예: `qemu+ssh://peer/system`
- `disk_map`: 소스 디스크와 대상 디스크 경로 매핑
- `network_map`: 브리지, tap, MAC, failover 시 붙일 네트워크 매핑
- `fencing_policy`: `ipmi`, `redfish`, `ssh-poweroff`, `manual-block`
- `recovery_priority`: 승격 순서와 동시 기동 제한
- `qga_policy`: guest freeze/thaw 가능 여부
- `transport_tolerance_sec`: 일시 네트워크 단절 허용 시간
- `auto_rearm`: blockcopy/x-colo 세션 자동 재수립 허용 여부

### 4.2 상태기계

모든 모드는 공통적으로 아래 상태를 가진다.

- `unprotected`
- `pairing`
- `syncing`
- `protected`
- `degraded`
- `rearming`
- `failing_over`
- `failed_over`
- `failing_back`
- `error`

`ft` 모드는 추가로 다음 세부 상태를 가진다.

- `colo_preparing`
- `colo_running`
- `colo_rearming`
- `colo_failover_pending`
- `colo_promoted`

`rearming`은 source fenced가 아닌 상태에서 replication transport만 끊어진 경우 진입하는 복구 상태다. 이 상태에서는 failover 대신 다음 순서를 수행한다.

1. peer reachability, libvirtd, qmp 응답을 재확인
2. source fenced 여부를 확정
3. fenced가 아니면 기존 blockcopy/x-colo 세션 정리
4. 동일 profile로 replication 명령 재실행
5. 복구 성공 시 `protected` 또는 `colo_running`으로 복귀

## 5. CLI 제안

```bash
ablestack_vm_ftctl protect  --vm <vm> --mode <ha|dr|ft> --peer <uri> [--profile <name>]
ablestack_vm_ftctl status   [--vm <vm>] [--json]
ablestack_vm_ftctl reconcile [--vm <vm>] [--dry-run]
ablestack_vm_ftctl failover --vm <vm> [--force]
ablestack_vm_ftctl failback --vm <vm> [--force]
ablestack_vm_ftctl pause-protection --vm <vm>
ablestack_vm_ftctl resume-protection --vm <vm>
ablestack_vm_ftctl check --vm <vm>
ablestack_vm_ftctl health
```

의미는 다음과 같다.

- `protect`: profile 생성, 대상 리소스 검증, 초기 sync 시작
- `status`: mode, replication lag, active side, last checkpoint, fencing 상태 출력
- `reconcile`: 주기 실행. 보호 상태 유지, 순간 단절 판별, blockcopy/x-colo 재실행 담당
- `failover`: 장애 승격 실행
- `failback`: 원복
- `pause-protection` / `resume-protection`: 유지보수 윈도우 처리

## 6. HA/DR 설계: blockcopy

### 6.1 기본 전략

`ha`와 `dr`은 모두 active-passive 구조다.

1. primary VM의 각 보호 디스크에 대해 secondary 측 목적지 볼륨을 준비한다.
2. `virsh blockcopy`로 초기 full sync를 수행한다.
3. sync 완료 후 mirror 상태를 유지한다.
4. secondary 측에는 "대기용 domain XML"을 미리 정의해 둔다.
5. replication transport가 순간 끊기면 `reconcile`이 blockcopy를 재실행해 mirror 상태를 복원한다.
6. 장애 시 fencing 후 secondary VM을 기동한다.

### 6.2 blockcopy 실행 규칙

디스크별로 다음 정책을 적용한다.

- 기본 옵션: `--wait --verbose --synchronous-writes`
- 장기 보호 job은 `ftctl`이 직접 추적한다.
- transient domain 제한이 문제 되면 `--transient-job` 사용 여부를 profile에서 선택한다.
- raw/qcow2 형식 불일치와 sparse 정책은 사전 검증 단계에서 차단한다.
- source 미fenced 상태에서 block job이 비정상 종료되면 `abort-or-cleanup -> 재검증 -> blockcopy 재실행` 순서로 self-heal 한다.

초기 sync 후 mirror를 유지하는 이유는 다음과 같다.

- 장애 순간 직전 데이터까지 최대한 반영하기 위함
- failover 전 `blockjob --pivot` 또는 failover site 부팅 준비를 단순화하기 위함

### 6.3 blockcopy 재무장(re-arm) 절차

순간 단절이 감지되면 바로 failover하지 않고 아래 절차를 먼저 수행한다.

1. source host와 guest가 아직 살아 있는지 확인
2. fencing 기록 또는 explicit operator action이 있는지 확인
3. source가 살아 있으면 protection state를 `rearming`으로 전환
4. 끊어진 block job과 stale destination handle을 정리
5. 대상 디스크가 일관성 있는지 검증
6. `virsh blockcopy`를 동일 인수로 재실행
7. sync 재개 후 mirror steady state를 확인

이 절차는 "네트워크 일시 단절"을 "장애 확정"과 분리하기 위한 방어선이다.

### 6.4 HA failover 절차

1. primary health check 실패 감지
2. secondary에서 fencing 가능 여부 확인
3. primary host 또는 primary VM을 반드시 fencing
4. 마지막 block job 상태 확인
5. secondary 디스크를 승격 가능한 상태로 전환
6. secondary domain XML define 또는 start
7. 네트워크 attachment/ARP 갱신
8. post-boot verify

### 6.5 DR failover 절차

`dr`은 `ha`와 동일한 흐름이지만, 아래 차이를 둔다.

- WAN 지연을 고려해 bandwidth cap과 lag threshold를 profile에 둔다.
- `dr`은 RTO보다 사이트 생존성이 우선이므로, "sync lag 허용 범위"와 "강제 승격 허용"이 별도 정책으로 필요하다.
- DR site에서 필요한 auxiliary resource를 사전 정의한다.
  - 네트워크
- cloud-init seed 또는 guest customization
- DNS/IP 재지정 스크립트

### 6.6 blockcopy 기반 한계와 보완

blockcopy는 스토리지만 복제하므로 아래 보완이 필요하다.

- standby XML 사전 정의
- libvirt network object 사전 준비
- guest agent를 통한 pre-failover freeze/thaw
- 순간 단절 시 blockcopy 재무장 로직
- fencing 없이는 split-brain 방지 불가
- failover 후 reverse sync 자동화

결론적으로 `ha/dr`은 "초저RTO"는 가능하지만 "RTO 0"은 아니다. 설계 목표는 수 초에서 수십 초 수준의 자동 승격이다.

## 7. FT 설계: x-colo

### 7.1 기본 전략

`ft`는 active-secondary 동시 실행 구조다.

- primary: 실제 서비스 응답
- secondary: COLO standby
- proxy/comparator: 네트워크 패킷 비교 및 checkpoint 유도
- disk replication: secondary 디스크 일관성 유지
- qmp control: `x-colo` lifecycle 제어

### 7.2 구성 요소

- host A primary QEMU
- host B secondary QEMU
- COLO proxy 또는 동등 네트워크 비교 경로
- secondary 측 NBD server
- dedicated replication NIC
- dedicated heartbeat/control NIC

### 7.3 x-colo lifecycle

`ftctl`은 아래 흐름을 캡슐화한다.

1. secondary QEMU 준비
2. QMP capability negotiation
3. secondary 측 `nbd-server-start`, `nbd-server-add`
4. primary/secondary에 `x-colo` migration capability 활성화
5. COLO running 진입
6. health loop에서 primary/secondary/proxy 상태 감시
7. transport만 끊기면 `colo_rearming`으로 전환 후 x-colo를 재수립
8. 장애 시 `x-colo-lost-heartbeat` 실행
9. secondary를 새 primary로 promote

### 7.4 heartbeat 문제 보완

QEMU 공식 문서상 heartbeat는 내장 구현이 없다. 따라서 `ftctl`이 다음 감시 경로를 가져야 한다.

- host-to-host heartbeat: management NIC ping 또는 agent RPC
- qmp liveliness: `query-status`, `query-migrate`
- libvirt domain event 감시
- proxy process health
- disk replication backlog

failover 트리거는 단일 지표가 아니라 quorum 규칙으로 결정한다.

- 예: `host heartbeat lost + qmp unreachable + fencing success`

반대로 아래 조건이면 failover 대신 `colo_rearming`을 우선 시도한다.

- source fenced 아님
- source host alive
- guest 또는 qmp 재응답 가능
- replication/control NIC만 순간 단절됨

### 7.5 x-colo 재무장(re-arm) 절차

1. source fenced 여부 확인
2. primary/secondary qmp 재접속 시도
3. proxy/comparator 프로세스 상태 확인
4. stale COLO capability와 NBD session 정리
5. 필요한 경우 secondary QEMU를 재prepare
6. `x-colo` 관련 QMP 명령을 다시 실행
7. checkpoint 정상화 후 `colo_running` 복귀

### 7.6 FT failover 절차

1. primary 이상 감지
2. secondary가 독립적으로 기동 가능한지 확인
3. primary host fencing
4. secondary QMP에 `x-colo-lost-heartbeat`
5. secondary 네트워크를 active로 전환
6. secondary 상태 검증
7. former primary를 재동기화 대상으로 재등록

### 7.7 FT 대상 선정 기준

`ft`는 모든 VM에 적용하지 않는다.

- 작은 메모리 풋프린트
- deterministic workload
- 낮은 디바이스 다양성
- 동일한 CPU 모델과 QEMU 버전 확보 가능
- 추가 네트워크/메모리 비용 수용 가능

DB, 대용량 메모리 VM, 고성능 NIC passthrough VM은 초기 대상에서 제외하는 것이 안전하다.

## 8. Fencing 설계

Near-zero RTO보다 더 중요한 것은 split-brain 방지다. 따라서 `ftctl`은 fencing 성공 전 승격하지 않는다.

지원 우선순위:

1. `redfish`
2. `ipmi`
3. `virsh destroy` on peer via trusted channel
4. host SSH shutdown
5. manual hold

정책:

- `ha/dr`: primary fencing 성공 전 secondary start 금지
- `ft`: primary fencing 또는 primary irreversible loss 판단 전 promotion 금지
- 순간 단절만 확인된 경우에는 failover보다 `rearming`을 우선 시도
- fencing 실패 시 상태를 `degraded` 또는 `error`로 두고 운영자 개입을 요구

## 9. 상태 저장과 이벤트 로그

### 9.1 런타임 상태

`/run/ablestack-vm-ftctl/state/<vm>.state`

예상 키:

- `mode`
- `active_side`
- `protection_state`
- `last_healthy_ts`
- `last_sync_ts`
- `replication_lag_ms`
- `transport_state`
- `rearm_count`
- `last_rearm_ts`
- `fencing_state`
- `failover_count`
- `last_error`

### 9.2 이벤트 로그

`/var/log/ablestack-vm-ftctl/events.log`

stage 예시:

- `inventory`
- `sync`
- `mirror`
- `colo`
- `rearm`
- `health`
- `fencing`
- `failover`
- `failback`
- `verify`
- `error`

이 형식은 기존 `hangctl`의 JSONL 이벤트 로그 스타일을 재사용한다.

## 10. 설정 파일 초안

`/etc/ablestack/ablestack-vm-ftctl.conf`

```bash
FTCTL_POLICY="default"
FTCTL_DRY_RUN="0"
FTCTL_RUN_DIR="/run/ablestack-vm-ftctl"
FTCTL_LOG_DIR="/var/log/ablestack-vm-ftctl"
FTCTL_EVENTS_LOG="/var/log/ablestack-vm-ftctl/events.log"

FTCTL_DEFAULT_PRIMARY_URI="qemu:///system"
FTCTL_DEFAULT_PEER_URI="qemu+ssh://peer/system"

FTCTL_HEALTH_INTERVAL_SEC="2"
FTCTL_FAILOVER_CONFIRM_SEC="4"
FTCTL_FENCING_TIMEOUT_SEC="15"
FTCTL_TRANSIENT_NET_GRACE_SEC="3"
FTCTL_MAX_REARM_ATTEMPTS="5"
FTCTL_REARM_BACKOFF_SEC="2"
FTCTL_BLOCKCOPY_BANDWIDTH_MIB="0"
FTCTL_BLOCKCOPY_SYNC_WRITES="1"
FTCTL_BLOCKCOPY_GRANULARITY="0"

FTCTL_XCOLO_CONTROL_NET="10.10.10.0/24"
FTCTL_XCOLO_REPL_NET="10.10.20.0/24"
FTCTL_XCOLO_QMP_TIMEOUT_SEC="3"

FTCTL_PROFILE_DIR="/etc/ablestack/ftctl.d"
```

VM별 설정은 단일 전역 conf가 아니라 `/etc/ablestack/ftctl.d/<vm>.conf` 드롭인으로 분리하는 것이 적합하다.

## 11. 검증 전략

### 11.1 HA/DR

- single-disk VM
- multi-disk VM
- qcow2/raw 혼합 차단
- primary host down
- libvirtd hung
- network partition
- 1초, 2초 수준의 replication network blip 후 blockcopy 자동 재실행
- storage full
- failback after failover

### 11.2 FT

- primary QEMU kill
- secondary QEMU kill
- control network loss
- replication network loss
- 1초, 2초 수준의 control/replication blip 후 x-colo 자동 재수립
- proxy process crash
- fencing failure
- split-brain guard validation

## 12. 구현 단계 제안

### Phase 1

- `ftctl` skeleton
- profile/state/logging
- `ha/dr`용 inventory와 blockcopy orchestration
- network blip 감지와 blockcopy re-arm
- `status`, `check`, `reconcile` 구현

### Phase 2

- `ha/dr` 자동 failover
- fencing provider abstraction
- standby XML define/start
- failback workflow

### Phase 3

- `x-colo` wrapper
- COLO health monitor
- x-colo re-arm sequence
- FT failover state machine
- FT profile validation

### Phase 4

- systemd timer/service
- install.sh/Makefile/RPM 반영
- 운영 문서와 장애 runbook 작성

## 13. 저장소 반영 포인트

향후 구현 시 함께 수정될 파일은 다음이 될 가능성이 높다.

- `bin/ablestack_vm_ftctl.sh`
- `lib/ftctl/*.sh`
- `etc/ablestack-vm-ftctl.conf`
- `install.sh`
- `Makefile`
- `rpm/ablestack_vm_ftctl.spec`
- `docs/ftctl/*.md`

현재 커밋에서는 설계 문서만 추가하고, 실제 구현은 다음 단계에서 진행하는 것이 안전하다.

## 14. 설계 결론

- umbrella 제어기 이름은 `ablestack_vm_ftctl`로 둔다.
- `ha/dr`는 blockcopy 기반 active-passive로 설계한다.
- `ft`는 x-colo 기반 active-secondary로 설계한다.
- RTO 0에 가장 가까운 경로는 `ft`이며, `ha/dr`는 near-zero RTO를 목표로 한다.
- source가 fenced되지 않은 순간 네트워크 단절은 failover 조건이 아니라 replication 재무장 조건으로 처리한다.
- 실제 운영 안전성의 핵심은 replication보다 fencing과 state machine이다.

## 15. 참고 자료

- libvirt virsh manpage: https://www.libvirt.org/manpages/virsh.html
- QEMU COLO documentation: https://www.qemu.org/docs/master/system/qemu-colo.html
