# ablestack_vm_ftctl Runbook

## Purpose

This runbook summarizes the operational commands and decision points for
`ablestack_vm_ftctl`.

## Basic Checks

Version:

```bash
ablestack_vm_ftctl --version
```

Cluster and host inventory:

```bash
ablestack_vm_ftctl config show
ablestack_vm_ftctl config host-list
```

Per-VM protection state:

```bash
ablestack_vm_ftctl status --vm <vm>
ablestack_vm_ftctl check --vm <vm>
```

## Start Protection

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

FT backend note:

- file-based FT:
  - uses the prebuilt x-colo path
  - supports full `failover --force` and full `failback --force`
- block-backed FT:
  - uses cold conversion on protect
  - uses cold-cutback on failback
  - requires an explicit block-backed `FTCTL_PROFILE_DISK_MAP`

## Reconcile

Global reconcile:

```bash
ablestack_vm_ftctl reconcile
```

Single-VM reconcile:

```bash
ablestack_vm_ftctl reconcile --vm <vm>
```

## Manual Fencing

For `manual-block`:

```bash
ablestack_vm_ftctl failover --vm <vm> --force
ablestack_vm_ftctl fence-confirm --vm <vm>
```

Clear fencing state:

```bash
ablestack_vm_ftctl fence-clear --vm <vm>
```

## Failback

HA/DR:

```bash
ablestack_vm_ftctl failback --vm <vm> --force
```

Expected final state:

- `active_side=primary`
- `protection_state=protected`
- `transport_state=mirroring`

FT file-based:

```bash
ablestack_vm_ftctl failback --vm <vm> --force
```

Expected final state:

- `active_side=primary`
- `protection_state=colo_running`
- `transport_state=mirroring`

FT block-backed:

```bash
ablestack_vm_ftctl failback --vm <vm> --force
```

Current operational meaning:

1. stop active secondary
2. copy the active secondary block overlay state back to the original primary block source
3. re-activate the original primary VM
4. re-enter the validated block-backed cold conversion protect flow

Expected final state:

- `active_side=primary`
- `protection_state=colo_running`
- `transport_state=mirroring`

## Selftest

```bash
ablestack_vm_ftctl_selftest
```

## Operational Notes

- Verify cluster inventory before any production failover.
- If `manual-block` is used, do not treat the operation as complete until
  explicit operator confirmation is recorded.
- For FT/x-colo, always verify both:
  - QMP/runtime state
  - generated XML / runtime graph state
- File-based FT sacrificial pairs must keep the following virtual sizes
  identical:
  - primary source
  - secondary parent
  - secondary hidden overlay
  - secondary active overlay
- `OP-ST-01` is a shared-storage total-outage scenario, not a one-host path-loss
  scenario.
  - standby activation is not expected to succeed during the outage window
  - PASS means no false-success failover, no split-brain, and deterministic
    convergence after storage restore
