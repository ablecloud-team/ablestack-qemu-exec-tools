# ablestack_vm_ftctl Runbook

## 목적

이 문서는 `ablestack_vm_ftctl` 운영 시 자주 쓰는 기본 절차를 정리한다.

## 기본 확인

버전 확인:

```bash
ablestack_vm_ftctl --version
```

cluster/host inventory 확인:

```bash
ablestack_vm_ftctl config show
ablestack_vm_ftctl config host-list
```

VM 보호 상태 확인:

```bash
ablestack_vm_ftctl status --vm <vm>
ablestack_vm_ftctl check --vm <vm>
```

## 보호 시작

HA:

```bash
ablestack_vm_ftctl protect --vm <vm> --mode ha --peer qemu+ssh://peer/system
```

DR:

```bash
ablestack_vm_ftctl protect --vm <vm> --mode dr --peer qemu+ssh://dr-site/system
```

FT:

```bash
ablestack_vm_ftctl protect --vm <vm> --mode ft --peer qemu+ssh://peer/system
```

## 운영 중 점검

주기 reconcile:

```bash
ablestack_vm_ftctl reconcile
```

단일 VM만 확인:

```bash
ablestack_vm_ftctl reconcile --vm <vm>
```

## 수동 fencing 확인

`manual-block` 정책일 때:

```bash
ablestack_vm_ftctl failover --vm <vm> --force
ablestack_vm_ftctl fence-confirm --vm <vm>
```

fencing 상태 초기화:

```bash
ablestack_vm_ftctl fence-clear --vm <vm>
```

## selftest

통합 dry-run/selftest:

```bash
ablestack_vm_ftctl_selftest
```

## 주의사항

- production failover 전에 cluster inventory가 맞는지 먼저 확인한다.
- `manual-block` 정책이면 운영자 승인이 있기 전까지 승격이 완료되지 않는다.
- FT/x-colo는 QMP 경로와 libvirt generated XML 경로를 둘 다 확인해야 한다.
