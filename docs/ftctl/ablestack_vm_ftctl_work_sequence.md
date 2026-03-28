# ablestack_vm_ftctl Work Sequence

## 1. Purpose

This document is the execution-order source of truth for `ablestack_vm_ftctl`.

- Work follows the order in this document.
- Status is updated as implementation progresses.
- Detailed design lives in `ablestack_vm_ftctl_design.md`.

## 2. Status Rules

- Allowed status values: `done`, `in_progress`, `pending`, `blocked`
- Prefer only one `in_progress` step at a time.

## 3. Current Summary

- Branch: `feature/vm-ha-dr-ft`
- Current phase: `Step 11 done, Step 12 ready`

Completed items:

- `ftctl` design document
- `ftctl` CLI skeleton
- state/logging/config/orchestrator skeleton
- shell completion
- Rocky Linux 9.6 based `build.yml` flow
- `install-linux.sh` / `uninstall-linux.sh`
- OS-specific ISO split
- profile schema and validation
- blockcopy inventory / start / job tracking
- XML backup and transient/persistent handling
- active/standby XML bundle handling
- cluster/host inventory model and config commands
- reconcile state machine and rearm thresholds
- fencing provider abstraction and manual confirm flow
- standby domain generation / activate flow
- HA/DR blockcopy hardening mini-phase
- x-colo wrapper and libvirt XML `qemu:commandline` support
- integrated selftest and validation document
- FTCTL packaging (RPM/spec/build/install integration)
- operations/runbook/failover-failback/ISO documentation
- Apache 2.0 header scan and missing-header fixes in touched FTCTL-related sources

## 4. Work Sequence

### Step 1. Profile schema freeze

- Status: `done`
- Goal:
  - Freeze `/etc/ablestack/ftctl.d/<vm>.conf`
  - Define required vs optional keys
  - Validate per-mode fields
- Delivered:
  - `docs/ftctl/ablestack_vm_ftctl_profile_schema.md`
  - `lib/ftctl/profile.sh` validation

### Step 2. blockcopy implementation

- Status: `done`
- Goal:
  - VM disk inventory
  - actual `virsh blockcopy`
  - block job tracking
  - XML backup and standby seed capture
- Delivered:
  - `lib/ftctl/blockcopy.sh`
  - XML backup bundle: `primary.xml`, `standby.xml`, `meta`

### Step 3. Cluster/Host inventory model

- Status: `done`
- Goal:
  - cluster-level config
  - host inventory with role/IP/URI separation
  - management vs data path address model
- Delivered:
  - `docs/ftctl/ablestack_vm_ftctl_cluster_schema.md`
  - `lib/ftctl/cluster.sh`
  - `ablestack_vm_ftctl config ...`

### Step 4. Reconcile state machine

- Status: `done`
- Goal:
  - `protected`, `degraded`, `rearming`, `failing_over`, `error` transitions
  - distinguish source fenced vs transient network loss
  - apply grace window / backoff / rearm thresholds
- Delivered:
  - `lib/ftctl/orchestrator.sh`
  - state fields such as `transport_loss_since`, `last_reconcile_ts`

### Step 5. Fencing provider abstraction

- Status: `done`
- Goal:
  - provider dispatch
  - failover path uses fencing result
- Delivered:
  - `manual-block`
  - `ssh`
  - `peer-virsh-destroy`
  - `fence-confirm`, `fence-clear`

### Step 6. Standby domain management

- Status: `done`
- Goal:
  - generate standby XML
  - define/start or create path
  - activate during failover
- Delivered:
  - `lib/ftctl/standby.sh`
  - `standby.generated.xml`
  - standby activate wiring in failover

### Step 7. HA/DR blockcopy hardening mini-phase

- Status: `done`
- Goal:
  - real rearm path
  - standby boot/network verify
  - reverse sync / failback base path
  - split-brain hardening support
- Delivered:
  - actual `blockcopy rearm`
  - standby verify
  - reverse sync plan/start path
  - `FTCTL_PROFILE_FAILBACK_DISK_MAP`

### Step 8. x-colo wrapper

- Status: `done`
- Goal:
  - QMP wrapper
  - `x-colo` protect/rearm/failover flow
  - libvirt XML `qemu:commandline` integration
- Delivered:
  - `lib/ftctl/xcolo.sh`
  - secondary NBD/QMP setup
  - primary blockdev/migrate setup
  - `x-colo-lost-heartbeat` failover path
  - generated XML `qemu:commandline` support

### Step 9. Integrated validation

- Status: `done`
- Goal:
  - repeatable validation procedure for HA/DR/FT
  - combine profile, cluster inventory, fencing, standby, rearm, x-colo paths
- Delivered:
  - `bin/ablestack_vm_ftctl_selftest.sh`
  - `docs/ftctl/ablestack_vm_ftctl_validation.md`
  - selftest execution passed

### Step 10. Packaging

- Status: `done`
- Goal:
  - finalize FTCTL packaging scope
  - completion coverage
  - systemd / install path finish
- Delivered:
  - `rpm/ablestack_vm_ftctl.spec`
  - `Makefile` `ftctl-rpm` target
  - `build.yml` FTCTL RPM build/repo/install integration
  - `install.sh` FTCTL/selftest install path
  - `make ftctl-rpm` build success verified

### Step 11. Documentation

- Status: `done`
- Goal:
  - operations runbook
  - failover/failback guide
  - ISO usage guide
  - copyright/license header check
- Delivered:
  - `docs/ftctl/ablestack_vm_ftctl_runbook.md`
  - `docs/ftctl/ablestack_vm_ftctl_failover_failback.md`
  - `docs/ftctl/ablestack_vm_ftctl_iso_guide.md`
  - Apache 2.0 header fixes in FTCTL-related sources and supporting scripts

### Step 12. Real-Environment Integration Testing

- Status: `pending`
- Goal:
  - run integrated HA/DR/FT tests on real ABLESTACK/libvirt/QEMU hosts
  - validate VM image type coverage
  - validate backend storage type coverage
  - validate operational runbook against real behavior
- Expected output:
  - real-environment test report
  - pass/fail matrix by image type
  - pass/fail matrix by storage backend
  - list of defects / gaps / mitigations

### Step 13. PR preparation

- Status: `pending`
- Goal:
  - summarize diff
  - summarize validation
  - capture known gaps
- Expected output:
  - PR description draft
  - final review checklist

## 5. Next Work

- Next priority: `Step 12. Real-Environment Integration Testing`
- Follow-up after real-environment testing: `Step 13. PR preparation`
- Follow-up after PR prep: `final review`

## 6. Update Rule

When progress changes:

- On completion:
  - mark the step `done`
  - record delivered outputs
- On start:
  - mark the step `in_progress`
- On blocker:
  - mark the step `blocked`
  - note cause and workaround
