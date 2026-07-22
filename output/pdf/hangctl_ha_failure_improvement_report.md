# hangctl HA 장애 분석 및 개선 보고서

문서 버전: 1.0  
작성일: 2026-07-22  
대상: ABLESTACK 22.x HA 환경  
작성 목적: 호스트 장애 HA 테스트 중 발생한 CCVM 기동 실패 원인과 hangctl 개선 조치 보고

## 1. 요약

2026-07-16 HA 테스트 중 host2 전원 종료로 CCVM 이동이 시작되었고, host1에서 CCVM incoming migration 처리가 진행되는 동안 source host가 중단되면서 libvirt/QEMU 연결 오류가 발생했습니다. 이후 host1의 `ablestack_vm_hangctl`은 libvirt health check가 2회 연속 실패한 것으로 판단하고 `libvirtd.service`를 자동 재시작했습니다.

이 재시작은 Pacemaker가 CCVM 리소스(`cloudcenter_res`)를 host1에서 시작하려는 시점과 겹쳤습니다. 그 결과 libvirt socket이 일시적으로 준비되지 않아 CCVM start가 실패했고, 이후 리소스 실패와 fencing 판단으로 이어졌습니다.

핵심 결론은 다음과 같습니다.

- hangctl이 CCVM을 hang VM으로 확정하여 종료한 것은 아닙니다.
- 직접적인 조치는 libvirt health gate가 `virsh list --name` timeout을 libvirtd 장애로 판단해 host-wide `systemctl restart libvirtd.service`를 수행한 것입니다.
- 문제의 본질은 HA 전환 중인 클러스터 상태를 확인하지 않고 libvirtd 자동 재시작을 수행한 설계입니다.
- 개선 방향은 libvirtd 재시작을 기본 비활성화하고, Pacemaker/PCS 상태 guard와 restart backoff를 통과한 경우에만 제한적으로 허용하는 것입니다.

## 2. 영향

영향 범위는 CCVM 단일 VM에 국한되지 않았습니다. `libvirtd.service` 재시작은 host의 가상화 제어면 전체에 영향을 주는 작업이며, 로그상 같은 시점에 `mold-agent.service`도 중지 및 재기동되었습니다.

운영상 확인된 영향은 다음과 같습니다.

| 구분 | 내용 |
|---|---|
| 주요 증상 | CCVM failover 중 host1에서 CCVM start 실패 |
| 직접 실패 지점 | Pacemaker의 `cloudcenter_res` start 시 libvirt socket 접속 실패 |
| 부가 영향 | libvirtd 재시작 중 `mold-agent.service` 재기동 |
| 최종 결과 | host1 fencing 및 수동 복구 후 CCVM 정상 기동 |

## 3. 주요 시계열

| 시각 | 이벤트 |
|---|---|
| 18:30:30 | HA 테스트를 위해 host2 전원 종료 진행. host2의 CCVM과 사용자 VM이 종료됨 |
| 18:30:35-18:30:36 | Pacemaker가 CCVM을 host1로 이동시키기 시작. host1에 incoming CCVM QEMU 프로세스 생성 |
| 18:30:55 | host1에서 CCVM QMP 응답 확인 실패. libvirt 로그에 연결 종료 및 I/O 오류 기록 |
| 18:31:00 | CCVM이 `paused (migrating)` 상태로 관찰됨. 이 시점에서 hangctl은 CCVM을 즉시 장애 VM으로 확정하지 않음 |
| 18:31:05 | host2 종료 영향으로 CCVM migration 지속 불가. host1 incoming CCVM 처리도 종료 |
| 18:31:52 | hangctl의 첫 번째 libvirt health check 실패. `virsh list --name` timeout성 실패 |
| 18:32:52 | 두 번째 libvirt health check 실패. fail threshold 도달로 libvirtd restart 시작 |
| 18:33:03 | 클러스터가 host2 장애를 fencing 처리 |
| 18:33:06-18:33:08 | Pacemaker가 host1에서 CCVM start 시도. 같은 시점 libvirtd 재시작 중이라 hypervisor 접속 실패 |
| 18:56:11 | CCVM 리소스 실패 누적으로 Pacemaker가 host1 fencing 결정 |
| 19:02:55 | host1 재부팅 확인 |
| 19:09경 | host1 재기동 후 CCVM 정상 기동 |

## 4. 원인 분석

### 4.1 직접 원인

hangctl은 scan 시작 시 VM 개별 점검보다 먼저 libvirt health gate를 수행합니다. 기존 코드의 health check는 다음 단일 명령에 의존했습니다.

```bash
virsh -c qemu:///system list --name
```

기존 기본값은 다음과 같이 공격적이었습니다.

```bash
HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC="3"
HANGCTL_LIBVIRTD_FAIL_THRESHOLD="2"
HANGCTL_LIBVIRTD_RESTART_ENABLED="1"
HANGCTL_LIBVIRTD_RESTART_COOLDOWN_SEC="180"
```

즉, 3초 timeout health check가 2회 연속 실패하면 libvirtd를 자동 재시작했습니다. 이번 장애에서는 18:31:52와 18:32:52에 연속 실패가 발생했고, 18:32:52에 자동 재시작이 실행되었습니다.

### 4.2 기여 원인

첫째, libvirt API timeout과 libvirtd daemon 장애를 구분하지 못했습니다. 이번 상황은 service inactive라기보다 CCVM incoming migration 실패와 클러스터 전환 중 libvirt API가 일시적으로 지연된 형태였습니다.

둘째, Pacemaker/PCS 상태를 확인하지 않았습니다. fencing, resource start/stop/migrate, membership 변경이 있는지 확인하지 않은 상태로 host-wide libvirtd restart가 실행되었습니다.

셋째, restart storm 방지가 충분하지 않았습니다. 기존 cooldown은 180초였고, 재시작 후 정상 확인이 실패하면 이후에도 주기적으로 재시작을 반복할 수 있었습니다.

넷째, VM-level migration 보호 로직은 이미 있었지만 libvirt health gate가 먼저 실패하면 VM별 migration 보호 경로까지 도달하지 못합니다. 따라서 이번 사고에는 기존 migration 보호만으로 충분하지 않았습니다.

## 5. 재발방지 설계 방향

개선 원칙은 다음과 같습니다.

- libvirtd health failure는 우선 탐지 및 기록한다.
- HA 환경에서 host-wide libvirtd restart는 기본적으로 수행하지 않는다.
- 자동 재시작이 필요한 경우에도 Pacemaker/PCS guard, health class, cooldown, backoff를 모두 통과해야 한다.
- `api_timeout`은 libvirtd daemon down과 다르게 취급한다.

개선 후 판단 흐름은 다음과 같습니다.

```text
libvirt health check
  -> ok: fail count reset
  -> fail/timeout: fail count 증가
     -> threshold 미만: 로그 후 종료
     -> restart disabled/dry-run: skip
     -> backoff/cooldown/max-per-hour: skip
     -> health class가 restart 부적합: skip
     -> Pacemaker/PCS guard busy/settle/unknown: skip
     -> 모든 조건 통과 시에만 libvirtd restart
```

## 6. 구현된 개선 내용

현재 작업 브랜치 `codex/hangctl-libvirtd-ha-guard-design`에 다음 개선을 구현했습니다.

| 영역 | 개선 내용 |
|---|---|
| Cluster guard | `lib/hangctl/cluster_guard.sh` 신규 추가. `crm_mon`, `pcs status --full` 기반으로 fencing, pending, resource action, quorum 문제 감지 |
| Health classification | libvirtd health 결과를 `ok`, `service_inactive`, `socket_missing`, `api_timeout`, `command_fail`로 분류 |
| Timeout 처리 | 기존 `124` 외에 `137`, `143`도 timeout성 실패로 분류 |
| 자동 restart 기본값 | `HANGCTL_LIBVIRTD_RESTART_ENABLED="0"`으로 변경 |
| HA-safe timeout | health timeout 기본값을 3초에서 10초로 완화 |
| Threshold | libvirtd fail threshold 기본값을 2회에서 5회로 완화 |
| API timeout 보호 | `api_timeout`은 기본적으로 libvirtd restart 대상에서 제외 |
| Restart backoff | restart 실패 또는 verify timeout 후 장시간 backoff 적용 |
| Restart 제한 | 시간당 restart 횟수 제한 추가 |
| Config 로딩 | `--config` 지정 시 실제 파일이 먼저 source되도록 버그 수정 |
| Sample config | 깨진 설정 주석과 병합된 migration 설정 라인 정리 |
| Event logging | `libvirtd.health`에 `class` 기록, restart skip reason 세분화 |

## 7. 검증 결과

### 7.1 로컬 검증

다음 검증을 통과했습니다.

```bash
bash -n bin/ablestack_vm_hangctl.sh lib/hangctl/*.sh tests/hangctl_*.sh etc/ablestack-vm-hangctl.conf
bash tests/hangctl_migration_protection_smoke.sh
bash tests/hangctl_libvirtd_health_classification_smoke.sh
bash tests/hangctl_cluster_guard_smoke.sh
bash tests/hangctl_libvirtd_restart_gate_smoke.sh
bash tests/hangctl_config_override_smoke.sh
bash tests/hangctl_config_sample_smoke.sh
```

테스트 결과:

| 테스트 | 결과 |
|---|---|
| 기존 migration protection smoke | 통과 |
| libvirtd health classification smoke | 통과 |
| cluster guard smoke | 통과 |
| libvirtd restart gate smoke | 통과 |
| config override smoke | 통과 |
| config sample smoke | 통과 |

### 7.2 RPM 빌드

hangctl RPM 빌드를 완료했습니다.

| 항목 | 값 |
|---|---|
| 빌드 명령 | `make hangctl-rpm` |
| 산출물 | `build/rpm-hangctl/ablestack_vm_hangctl-0.9.2-1.noarch.rpm` |
| SHA256 | `660bade6b85dba4271ddb902ac2dd3b18c11e7f0d8c5494c32e7bfa9f15477c9` |

### 7.3 22.x 테스트 서버 preflight

다음 서버에 최신 RPM을 설치하고 preflight를 수행했습니다.

| 서버 | 결과 |
|---|---|
| 10.10.22.1 | 설치 성공, `cluster_guard.sh` 설치 확인, health ok, CCVM scan dry-run 정상 |
| 10.10.22.2 | 설치 성공, `cluster_guard.sh` 설치 확인, health ok, CCVM 미실행 상태 정상 감지 |
| 10.10.22.3 | 설치 성공, `cluster_guard.sh` 설치 확인, health ok, CCVM 미실행 상태 정상 감지 |

공통 확인 사항:

- `libvirtd`: active
- `mold-agent.service`: active
- `ablestack-vm-hangctl.timer`: masked/inactive 상태 유지
- `--config`로 지정한 `HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC=7`이 이벤트 로그의 `timeout_sec=7`로 반영됨
- `libvirtd.health` 이벤트에 `class=ok` 기록됨

## 8. 운영 적용 시 주의사항

테스트 서버에는 기존 운영 config가 이미 존재했기 때문에 RPM 설치 시 새 sample config가 `/etc/ablestack/ablestack-vm-hangctl.conf.rpmnew`로 생성되었습니다. 운영 반영 시에는 기존 config와 `.rpmnew`를 비교해 안전 기본값을 병합해야 합니다.

권장 운영 기본값은 다음과 같습니다.

```bash
HANGCTL_LIBVIRTD_RESTART_ENABLED="0"
HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC="10"
HANGCTL_LIBVIRTD_FAIL_THRESHOLD="5"
HANGCTL_LIBVIRTD_RESTART_ON_API_TIMEOUT="0"
HANGCTL_CLUSTER_GUARD_ENABLE="1"
HANGCTL_CLUSTER_GUARD_FAIL_CLOSED="1"
HANGCTL_CLUSTER_GUARD_SETTLE_SEC="600"
```

자동 libvirtd restart를 다시 활성화해야 하는 경우에는 다음 조건을 충족한 뒤 제한적으로 적용해야 합니다.

- HA 전환 중이 아님
- Pacemaker resource action이 없음
- fencing 또는 quorum 문제가 없음
- `api_timeout`이 아니라 `service_inactive` 또는 `socket_missing` 유형임
- backoff 및 시간당 restart 제한을 통과함

## 9. 결론

이번 HA 실패는 CCVM 자체를 hangctl이 직접 종료한 문제가 아니라, HA 전환 중 libvirt API timeout을 libvirtd 장애로 판단한 hangctl이 host-wide libvirtd restart를 수행하면서 발생한 제어면 충돌입니다.

개선 구현은 다음 재발방지 효과를 제공합니다.

- HA failover 중 libvirtd 자동 재시작 방지
- Pacemaker/PCS 전환 상태 감지 후 restart skip
- libvirt API timeout과 daemon down 구분
- 반복 restart 방지
- 설정 파일 지정 오류 수정
- 고객 환경에서 안전한 기본값 제공

따라서 개선 코드 적용 후 동일한 장애 조건에서는 hangctl이 libvirtd를 즉시 재시작하지 않고, 이벤트 로그에 skip 사유를 남긴 뒤 HA 복구 흐름을 방해하지 않는 방향으로 동작합니다.

## 10. 부록: 주요 파일

| 파일 | 목적 |
|---|---|
| `lib/hangctl/cluster_guard.sh` | Pacemaker/PCS 상태 기반 restart guard |
| `lib/hangctl/libvirt_wrap.sh` | libvirtd health classification, restart gate, backoff |
| `lib/hangctl/config.sh` | HA-safe 기본값 및 config load helper |
| `bin/ablestack_vm_hangctl.sh` | guard 모듈 로드 및 config 로딩 순서 수정 |
| `etc/ablestack-vm-hangctl.conf` | 운영 sample config 정리 |
| `docs/hangctl/ablestack_vm_hangctl_libvirtd_ha_guard_design.md` | 상세 설계 문서 |
| `tests/hangctl_*_smoke.sh` | 회귀 방지 smoke tests |
