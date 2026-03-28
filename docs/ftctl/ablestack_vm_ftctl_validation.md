# ablestack_vm_ftctl Validation

## 목적

이 문서는 `ftctl` 기능을 반복 가능한 방식으로 검증하기 위한 절차를 정리한다.

현재 기준 검증 범위:

- shell 구문 검사
- shellcheck
- cluster config CLI
- HA/DR blockcopy + standby dry-run
- reconcile + fencing 상태기계
- FT x-colo dry-run + libvirt XML `qemu:commandline`

## 자동 검증

기본 검증 스크립트:

```bash
bin/ablestack_vm_ftctl_selftest.sh
```

기본 출력 예:

```text
[SELFTEST] running bash -n
[SELFTEST] running shellcheck
[SELFTEST] cluster config CLI
[SELFTEST] blockcopy/standby dry-run
[SELFTEST] reconcile/fencing state machine
[SELFTEST] x-colo dry-run and XML commandline
[SELFTEST] all checks passed
```

## 검증 항목

### 1. Cluster config CLI

- `config init-cluster`
- `config host-upsert`
- 설정 파일 생성 여부

### 2. HA/DR blockcopy + standby

- standby XML generated 경로 생성
- disk source rewrite
- dry-run activate 시 `active_side=secondary`

### 3. Reconcile + fencing

- `transient_loss`
- `rearm_pending`
- `manual-block` fencing
- `fence-confirm`

### 4. FT x-colo

- `colo_running`
- `x-colo failover`
- generated XML에 `qemu:commandline` 삽입

## 수동 확인 권장 항목

자동 검증만으로 부족한 항목:

- 실제 libvirt/qemu 환경에서의 `virsh blockcopy`
- 실제 peer host에서의 `define/start/create`
- 실제 `virsh qemu-monitor-command` 경로
- 실제 fencing provider
- 실제 guest boot/network readiness

## 운영 전 최종 점검

운영 환경 투입 전에는 아래를 별도로 수행하는 것이 좋다.

1. blockcopy 실제 protect/rearm
2. standby boot 실제 verify
3. failover/failback 실제 경로
4. x-colo primary/secondary 실제 연동
5. split-brain 방지 절차 점검
