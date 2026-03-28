# ablestack_vm_ftctl Failover and Failback

## 1. Failover

### HA/DR

흐름:

1. fencing 수행
2. standby XML activate
3. standby boot verify
4. `active_side=secondary`

명령:

```bash
ablestack_vm_ftctl failover --vm <vm> --force
```

수동 fencing 정책일 때:

```bash
ablestack_vm_ftctl fence-confirm --vm <vm>
```

### FT/x-colo

흐름:

1. fencing 수행
2. `x-colo-lost-heartbeat`
3. secondary 승격

## 2. Failback

현재 구현 수준:

- failback은 `reverse sync` 시작 경로까지 구현되어 있다.
- full 자동 복귀 절차는 후속 작업이 필요하다.

명령:

```bash
ablestack_vm_ftctl failback --vm <vm> --force
```

전제 조건:

- `active_side=secondary`
- standby/secondary가 active-ready 상태
- reverse sync 대상 경로가 profile에 맞게 정의되어 있음

## 3. Failback disk map

기본값:

```bash
FTCTL_PROFILE_FAILBACK_DISK_MAP="source"
```

명시적 매핑 예:

```bash
FTCTL_PROFILE_FAILBACK_DISK_MAP="vda=/primary/demo-vda.qcow2;vdb=/primary/demo-vdb.qcow2"
```

## 4. 운영 메모

- failback은 아직 “reverse sync 시작” 기준이다.
- production에서는 reverse sync 완료 확인 절차를 별도 운영 runbook으로 가져가는 것이 안전하다.
