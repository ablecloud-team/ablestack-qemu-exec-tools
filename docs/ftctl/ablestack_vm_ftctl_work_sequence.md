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
- Current phase: `Step 12 in progress`

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

- Status: `in_progress`
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
- Progress:
  - `HA-IMG01-ST01`: `FAIL` after backend-model reclassification
  - `HA-IMG08-ST01`: `PASS` with `remote-nbd`
  - `HA-IMG02-ST02`: `PASS` with `remote-nbd`
  - `HA-IMG05-ST01`: `PASS` with `remote-nbd`
  - `HA-IMG09-ST01`: `PASS` with `remote-nbd`
  - `HA-IMG01-ST03`: `PASS` with `remote-nbd` and explicit secondary-local block target
  - `HA-IMG01-ST04`: `PASS` with `shared-blockcopy`
  - `HA-IMG03-ST01`: `PASS` with `remote-nbd` after explicit Windows 11 UEFI/TPM XML handling
  - `HA-IMG06-ST02`: `PASS` with `remote-nbd` for transient multi-disk raw images
  - `HA-IMG04-ST02`: `PASS` with `remote-nbd` for Windows 11 raw
  - `HA-IMG07-ST01`: `PASS` with `remote-nbd` for mixed-size multi-disk Linux
  - `DR-IMG01-ST01`: `PASS` with `remote-nbd` for DR baseline Linux qcow2
  - `DR-IMG04-ST02`: `PASS` with `remote-nbd` for DR Windows 11 raw
  - `DR-IMG08-ST01`: `PASS` with `remote-nbd` for DR transient VM behavior
  - `DR-IMG09-ST01`: `PASS` with `remote-nbd` for DR persistent VM behavior
  - `DR-IMG03-ST01`: `PASS` with `remote-nbd` for DR Windows qcow2
- Follow-up improvements discovered during real-environment testing:
  - HA protect success detection should prioritize runtime `virsh dumpxml` mirror metadata when `virsh blockjob --info` is empty or incomplete.
  - `virsh domblklist --details` should be treated as a secondary indicator because it may continue to show the original source path while an active mirror element exists in runtime XML.
  - The current blockcopy target model is not valid for non-shared host-local storage.
  - Real HA/DR support now needs explicit backend-mode redesign:
    - `shared-visible blockcopy mode`
    - `remote-local transport mode` such as NBD-backed remote sink
  - Current local-file, non-shared cases must not be treated as PASS even when runtime XML shows a mirror element on the primary host.
  - `remote-nbd` protect can still appear as `syncing/copying` until `reconcile` runs; status auto-refresh policy should be improved.
  - Per-VM/target deterministic remote NBD port allocation and firewalld service range support are now in place; multi-disk concurrency validation is the next priority.
  - Multi-disk `remote-nbd` validation is now complete for transient qcow2 VMs; persistent single-disk validation is also complete.
  - Shared-visible HA validation is now complete for the single-disk persistent case.
  - Local-block validation is now complete for the single-disk transient case.
  - Shared multipath `qcow2-on-block` is not currently supportable on the tested libvirt/QEMU stack:
    - `shared-blockcopy` rejects `/dev/...` qcow2 block targets at `blockdev-add`
    - `remote-nbd` block targets must currently be treated as raw-only
  - Windows qcow2 baseline is now complete after fixing UEFI/TPM VM generation.
  - Windows raw validation is now complete on the same UEFI/TPM generation path.
  - Mixed-size multi-disk validation is now complete for the transient local-file case.
  - Multi-disk raw validation is now complete for the transient local-file case.
  - DR transient VM behavior is now complete on the remote-nbd path.
  - DR baseline validation is now complete on the same remote-nbd backend model.
  - DR Windows raw validation is now complete on the same remote-nbd backend model.
  - DR persistent VM behavior is now complete on the same remote-nbd backend model.
  - DR Windows qcow2 now completes on the baseline path after secondary-space cleanup and remote-nbd observability/space-preflight hardening.
  - The remaining HA priorities are persistent local-block/raw variants and shared/multipath variants.

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
- Immediate sub-priority inside Step 12: `HA/DR backend redesign and test-matrix reclassification`
- Backend redesign reference:
  - `docs/ftctl/ablestack_vm_ftctl_blockcopy_backend_redesign.md`
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
