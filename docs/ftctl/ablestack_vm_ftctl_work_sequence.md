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
  - Local-block validation is now complete for the single-disk transient case, including qcow2-on-block and raw-on-block.
  - Shared multipath now works on the tested stack when:
    - both source and target LVs are created on one host
    - activation ownership is split by role
    - secondary block-target activation performs stale dm cleanup and VG refresh before `lvchange -ay`
  - `remote-nbd` works for both raw-on-block and qcow2-on-block under that owner-separated model.
  - `shared-blockcopy` also works for raw-on-block and qcow2-on-block after switching block targets to XML `<disk type='block'>` descriptors instead of plain path arguments.
  - Mixed-kind HA validation is now complete for:
    - LVM raw block source -> GFS2 raw file target
    - LVM qcow2 block source -> GFS2 qcow2 file target
  - Windows qcow2 baseline is now complete after fixing UEFI/TPM VM generation.
  - Windows raw validation is now complete on the same UEFI/TPM generation path.
  - Mixed-size multi-disk validation is now complete for the transient local-file case.
  - Multi-disk raw validation is now complete for the transient local-file case.
  - DR transient VM behavior is now complete on the remote-nbd path.
  - DR baseline validation is now complete on the same remote-nbd backend model.
  - DR Windows raw validation is now complete on the same remote-nbd backend model.
  - DR persistent VM behavior is now complete on the same remote-nbd backend model.
  - DR Windows qcow2 now completes on the baseline path after secondary-space cleanup and remote-nbd observability/space-preflight hardening.
  - HA Ceph RBD baseline is now complete for:
    - `librbd` shared-visible mirroring
    - `krbd` shared-visible mirroring
  - DR Ceph RBD baseline is now complete for:
    - `librbd` shared-visible mirroring
    - `krbd` shared-visible mirroring
    - `krbd` host-separated `remote-nbd`
  - DR multi-disk Ceph RBD validation is now complete for:
    - `librbd` shared-visible mirroring
    - `krbd` shared-visible mirroring
    - `krbd` host-separated `remote-nbd`
  - FT/x-colo readiness is now complete on the `10.10.1.x` hosts:
    - sacrificial primary/secondary VM pair created with different backing qcow2 files
    - `parent0` / `colo-disk0` block graph created through qemu commandline
    - firewalld ports `9000/tcp`, `9998/tcp`, `10809/tcp` opened
  - FT baseline protect/failover is now complete for `FT-IMG01-ST01`:
    - protect reaches `colo_running`
    - failover reaches `failed_over` with `active_side=secondary`
  - FT persistent baseline is now complete for `FT-IMG09-ST01`
  - FT raw baseline is now complete for `FT-IMG02-ST02`
    - raw sources work when the secondary replication chain uses qcow2 overlays
  - FT local-block baseline is now complete for `FT-IMG01-ST03`
    - block-backed FT uses cold conversion, not the existing file-backed live protect path
    - primary and secondary generated XML use block-backed dummy disks with boot order lowered
    - post-boot QMP attach builds the local-block FT graph before x-colo handshake
  - `OP-FT-01` is now complete:
    - first reconcile after induced transient loss enters `transient_loss` during the grace window
    - second reconcile after the grace window re-enters `xcolo_rearm()`
    - final FT state returns to `colo_running` / `mirroring` with `rearm_count=1`
  - `OP-FT-02` is now complete:
    - explicit `x-colo-lost-heartbeat` failover promotes the secondary side
    - final FT state reaches `failed_over` / `colo_failover`
  - FT `xcolo` planning now suppresses misleading standby materialization errors when `standby_xml_seed` is absent and the FT pair is pre-provisioned externally.
  - Host virtualization service model must remain untouched during testing:
    - do not switch hosts between `libvirtd` and modular libvirt daemons
    - do not enable/disable/mask libvirt host services from test automation
    - if `systemctl status libvirtd` or `virsh list --all` prechecks fail, stop the test and restore host health first
  - `OP-HA-01`, `OP-HA-02`, and `OP-HA-03` are now complete on the `10.10.31.x` `remote-nbd` HA baseline:
    - 1-second, 2-second, and 5-second export-port blips all recovered back to `protected / mirroring`
    - neither case incremented `rearm_count`
  - `OP-HA-04` is now complete with IPMI fencing on the `10.10.31.x` HA baseline:
    - the source host can be powered off through OOB/IPMI
    - secondary-side reconcile triggers fencing and standby activation
    - final state reaches `failed_over / failed_over` with the standby domain running on the secondary host
  - `OP-HA-05` should be executed only under the following design constraints:
    - preflight must verify both hosts respond to `virsh list --all` within a bounded timeout
    - the injected fault is limited to `virsh destroy <primary-vm>` on the protected source VM
    - test code must not touch host libvirt service-unit configuration or service model
    - success criteria are secondary standby activation and final HA failover state, not host service recovery
  - `OP-HA-05` is now complete on the `10.10.31.x` HA baseline:
    - source VM destroy triggers HA failover
    - final state reaches `failed_over` with the secondary side running
  - `OP-DR-01` is now complete on the `10.10.31.x` DR baseline:
    - a 2-second remote-path interruption recovered back to `protected / mirroring`
    - `rearm_count` remained `0`
  - `OP-DR-02` is now complete:
    - DR failover now tears down secondary `qemu-nbd` export handles before standby activation
    - standby verify no longer false-fails because the verify helper now propagates the observed domain state correctly
    - final state reaches `failed_over / failed_over`
  - `OP-DR-03` is now complete to the currently implemented scope:
    - after DR failover, `failback --force` starts reverse sync successfully
    - final state reaches `failing_back / reverse_syncing`
    - `.state.blockcopy.reverse` is created as expected
  - `OP-ST-01` is now reproducible on the dedicated `glue-gfs-2` filesystem path and currently fails:
    - pacemaker-managed GFS2 interruption is reproduced through cluster resource control
    - the engine currently ends in `standby_activate_failed`
  - `OP-ST-02` is now complete on dedicated `mpathk`:
    - one path can be forced `offline`
    - the engine remains `protected / mirroring`
  - `OP-ST-03` is now complete on dedicated `mpathl`:
    - all paths can be forced `offline`
    - the engine still remains `protected / mirroring`
  - `OP-LV-01` is now complete:
    - restarting `libvirtd` on the primary host during protection does not break the protected pair
    - after reconcile, the final state returns to `protected / mirroring`
  - Block-backed FT now has an explicit product policy split from file-backed FT:
    - file-backed FT keeps the current validated protect flow
    - block-backed FT must use cold conversion, not the existing live protect path
    - the current `FT-IMG01-ST03` direction is generated FT runtime XML plus block-backed restart conversion
  - On the `10.10.1.x` RBD hosts, `krbd + remote-nbd` required:
    - `firewalld` enabled on both hosts
    - `10809-10872/tcp` opened on both hosts
    - `krbd` secondary-target prepare to skip LVM-specific handoff steps and only perform idempotent `rbd map` plus target-format initialization
  - In the current multi-disk `krbd + remote-nbd` implementation, only explicitly mapped targets stay on `/dev/rbd/...`; unmapped secondary data disks fall back to file targets under `/var/lib/ablestack-vm-ftctl/remote-nbd-targets/...`, which is acceptable for current coverage but should be tightened if full per-disk krbd ownership is required.
  - NFS-backed DR filesystem cases are skipped in the current environment because GFS2 shared-visible filesystem validation is treated as equivalent coverage.
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
