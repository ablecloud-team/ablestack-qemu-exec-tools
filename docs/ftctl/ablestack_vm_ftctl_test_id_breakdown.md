# ablestack_vm_ftctl Test ID Breakdown

## 1. Purpose

This document is the master test catalog for real-environment execution.

- Every real-environment test is executed by `Test ID`.
- Results are recorded against the `Test ID`.
- Failures, fixes, and re-runs are also tracked by the same `Test ID`.

## 2. ID Format

Format:

```text
<MODE>-<IMAGE>-<STORAGE>
```

Examples:

- `HA-IMG01-ST01`
- `DR-IMG05-ST04`
- `FT-IMG09-ST01`

Operational/fault-injection cases use:

```text
OP-<AREA>-<NN>
```

Examples:

- `OP-HA-01`
- `OP-DR-03`
- `OP-FT-02`

## 3. Image Type Reference

| Code | Description |
|---|---|
| `IMG01` | single-disk Linux qcow2 |
| `IMG02` | single-disk Linux raw |
| `IMG03` | single-disk Windows qcow2 |
| `IMG04` | single-disk Windows raw |
| `IMG05` | multi-disk Linux qcow2 |
| `IMG06` | multi-disk Linux raw |
| `IMG07` | mixed-size multi-disk Linux |
| `IMG08` | transient VM |
| `IMG09` | persistent VM |

## 4. Storage Backend Reference

| Code | Description |
|---|---|
| `ST01` | local file qcow2 |
| `ST02` | local file raw |
| `ST03` | local block device |
| `ST04` | shared NFS file |
| `ST05` | shared multipath block |
| `ST06` | Ceph RBD |

## 5. Execution Order

Recommended execution order:

1. HA baseline
2. HA image coverage
3. HA storage coverage
4. DR baseline
5. DR storage/backend coverage
6. FT baseline
7. FT extended coverage
8. Operational/fault-injection coverage

## 6. HA Test IDs

| Test ID | Image | Storage | Priority | Purpose | Status |
|---|---|---|---|---|---|
| `HA-IMG01-ST01` | `IMG01` | `ST01` | mandatory | HA baseline Linux qcow2 on local qcow2 | fail |
| `HA-IMG02-ST02` | `IMG02` | `ST02` | mandatory | HA baseline Linux raw on local raw | pass |
| `HA-IMG03-ST01` | `IMG03` | `ST01` | mandatory | HA baseline Windows qcow2 | pass |
| `HA-IMG04-ST02` | `IMG04` | `ST02` | recommended | HA Windows raw | pass |
| `HA-IMG05-ST01` | `IMG05` | `ST01` | mandatory | HA multi-disk Linux qcow2 | pass |
| `HA-IMG06-ST02` | `IMG06` | `ST02` | recommended | HA multi-disk Linux raw | pass |
| `HA-IMG07-ST01` | `IMG07` | `ST01` | recommended | HA mixed-size multi-disk | pass |
| `HA-IMG08-ST01` | `IMG08` | `ST01` | mandatory | HA transient VM behavior | pass |
| `HA-IMG09-ST01` | `IMG09` | `ST01` | mandatory | HA persistent VM behavior | pass |
| `HA-IMG01-ST03` | `IMG01` | `ST03` | mandatory | HA local block backend | pass |
| `HA-IMG01-ST04` | `IMG01` | `ST04` | recommended | HA shared-visible filesystem backend | pass |
| `HA-IMG01-ST05` | `IMG01` | `ST05` | recommended | HA multipath backend | pending |
| `HA-IMG01-ST06` | `IMG01` | `ST06` | recommended | HA Ceph RBD backend | pending |

## 7. DR Test IDs

| Test ID | Image | Storage | Priority | Purpose | Status |
|---|---|---|---|---|---|
| `DR-IMG01-ST01` | `IMG01` | `ST01` | mandatory | DR baseline Linux qcow2 | pass |
| `DR-IMG03-ST01` | `IMG03` | `ST01` | recommended | DR Windows qcow2 | pass |
| `DR-IMG04-ST02` | `IMG04` | `ST02` | recommended | DR Windows raw | pass |
| `DR-IMG08-ST01` | `IMG08` | `ST01` | mandatory | DR transient VM behavior | pass |
| `DR-IMG09-ST01` | `IMG09` | `ST01` | mandatory | DR persistent VM behavior | pass |
| `DR-IMG01-ST04` | `IMG01` | `ST04` | mandatory | DR NFS backend | pending |
| `DR-IMG01-ST06` | `IMG01` | `ST06` | mandatory | DR Ceph RBD backend | pending |
| `DR-IMG05-ST04` | `IMG05` | `ST04` | recommended | DR multi-disk on NFS | pending |
| `DR-IMG05-ST06` | `IMG05` | `ST06` | recommended | DR multi-disk on Ceph RBD | pending |

## 8. FT Test IDs

| Test ID | Image | Storage | Priority | Purpose | Status |
|---|---|---|---|---|---|
| `FT-IMG01-ST01` | `IMG01` | `ST01` | mandatory | FT baseline Linux qcow2 | pending |
| `FT-IMG02-ST02` | `IMG02` | `ST02` | recommended | FT Linux raw | pending |
| `FT-IMG09-ST01` | `IMG09` | `ST01` | mandatory | FT persistent VM behavior | pending |
| `FT-IMG01-ST03` | `IMG01` | `ST03` | recommended | FT local block backend | pending |

## 9. Operational / Fault Injection IDs

| Test ID | Area | Priority | Purpose | Status |
|---|---|---|---|---|
| `OP-HA-01` | HA | mandatory | 1-second replication network blip | pending |
| `OP-HA-02` | HA | mandatory | 2-second replication network blip | pending |
| `OP-HA-03` | HA | recommended | 5-second replication network blip | pending |
| `OP-HA-04` | HA | mandatory | source host shutdown | pending |
| `OP-HA-05` | HA | mandatory | source VM destroy | pending |
| `OP-DR-01` | DR | mandatory | remote path transient loss | pending |
| `OP-DR-02` | DR | mandatory | site failover | pending |
| `OP-DR-03` | DR | recommended | reverse sync / failback after DR | pending |
| `OP-FT-01` | FT | mandatory | x-colo transient loss / rearm | pending |
| `OP-FT-02` | FT | mandatory | x-colo lost-heartbeat failover | pending |
| `OP-ST-01` | storage | recommended | NFS interruption | pending |
| `OP-ST-02` | storage | recommended | multipath partial path loss | pending |
| `OP-ST-03` | storage | recommended | multipath all-path loss | pending |
| `OP-LV-01` | libvirt | recommended | libvirtd restart during protection | pending |

## 10. Execution Rule

For each `Test ID`:

1. Collect environment facts from the operator
2. Generate exact commands
3. Execute on the real host by the operator
4. Collect evidence
5. Judge `PASS` / `FAIL` / `BLOCKED`
6. If failed, fix code and rerun the same `Test ID`

## 11. Recording Rule

Every `Test ID` should end with:

- execution date
- VM name
- primary/secondary host
- image type
- storage backend
- commands run
- expected result
- actual result
- evidence path or log excerpt
- pass/fail/block reason

## 12. Current Follow-Up Notes

- `HA-IMG01-ST01`
  - Result: `FAIL` after reclassification
  - Observation:
    - In the tested ABLESTACK/libvirt/QEMU environment, `virsh dumpxml` mirror metadata was a more reliable confirmation signal than `virsh blockjob --info` or `virsh domblklist --details`.
    - However, the mirror target was still created on the primary host local filesystem, so the test did not produce a usable secondary-side HA replica.
  - Follow-up improvement:
    - Update HA protect observability logic to prioritize runtime XML `<mirror ...>` inspection when blockjob visibility is incomplete.
    - Redesign HA/DR backend modes so non-shared local storage uses a remote transport path instead of a primary-local mirror target.

- `HA-IMG08-ST01`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - The original primary-local path model failed for non-shared local storage.
    - After backend redesign, `remote-nbd` produced a secondary-local target, active NBD export, and primary runtime network mirror.
  - Follow-up improvement:
    - Keep `remote-nbd` as the required mode for non-shared local storage.
    - Consider auto-refresh after protect so `status` can move to `protected/mirroring` without requiring a separate reconcile step.

- `HA-IMG02-ST02`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - The same non-shared local storage model also worked for raw images.
    - The selected export port was persisted in state after reconcile.
  - Follow-up improvement:
    - Validate the same backend under multi-disk load where multiple target-specific exports are active at once.

- `HA-IMG05-ST01`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - Multi-disk local qcow2 worked with per-disk remote NBD exports.
    - Distinct export ports were selected and persisted for `vda`, `vdb`, and `vdc`.
  - Follow-up improvement:
    - Validate the same backend for persistent multi-disk VMs.
    - Validate failover/failback behavior across all protected disks together.

- `HA-IMG09-ST01`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - Persistent VM behavior worked with secondary-local target preparation and persistent standby define.
    - The standby domain name separation model (`<vm>-standby`) worked as intended.
  - Follow-up improvement:
    - Validate persistent multi-disk behavior.
    - Validate persistent failover/failback under the same backend.

- `HA-IMG01-ST04`
  - Result: `PASS` with `shared-blockcopy` backend mode
  - Observation:
    - Shared-visible source and target paths worked with a file-based blockcopy mirror.
    - The persistent standby domain naming and define path worked as intended on the secondary host.
  - Follow-up improvement:
    - Validate the same backend for multi-disk shared-visible layouts.
    - Validate shared-visible failover/failback behavior.

- `HA-IMG01-ST03`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - The local block backend required a secondary-local block target rather than a shared-visible path model.
    - An explicit `FTCTL_PROFILE_DISK_MAP` to the secondary LV path allowed `remote-nbd` to export a block device target and mirror the primary block-backed root disk over NBD.
  - Follow-up improvement:
    - Validate the same backend for persistent local-block VMs.
    - Validate multi-disk local-block behavior and failover/failback.

- `HA-IMG01-ST05`
  - Result: `pending`
  - Observation:
    - The shared multipath environment itself is healthy and `vg_clvm01` has sufficient free capacity.
    - `shared-blockcopy` with `qcow2` source and `/dev/...` multipath LV target is rejected by libvirt/QEMU with `blockdev-add: 'file' driver requires ... to be a regular file`.
    - `remote-nbd` with `/dev/...` secondary block target and `qcow2` source also does not produce an active block job, so the controller must not treat this combination as a valid syncing state.
  - Follow-up improvement:
    - Keep the new fail-fast validation that blocks non-raw block targets for `shared-blockcopy` and `remote-nbd`.
    - Re-run `ST05` as a raw-only experiment before treating multipath as supported.

- `HA-IMG03-ST01`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - The Windows 11 baseline required explicit UEFI loader/NVRAM handling and TPM 2.0 in the generated libvirt XML.
    - Once the VM creation path was corrected, the same secondary-local remote-nbd model used for Linux local-file qcow2 worked for Windows 11 qcow2 as well.
  - Follow-up improvement:
    - Validate Windows raw images.
    - Validate persistent Windows behavior and failover/failback.

- `HA-IMG06-ST02`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - Multi-disk raw images followed the same secondary-local remote transport model as the qcow2 multi-disk case.
    - Per-disk export ports were selected independently and the final reconcile promoted the VM only after the slowest raw root disk completed.
  - Follow-up improvement:
    - Validate persistent multi-disk raw behavior.
    - Validate mixed-size raw multi-disk layouts and failover/failback.

- `HA-IMG04-ST02`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - The same Windows 11 UEFI/TPM generation path used for the qcow2 baseline also worked when the primary source disk and secondary target were raw files.
    - The controller promoted normally after the initial full copy completed.
  - Follow-up improvement:
    - Validate persistent Windows behavior.
    - Validate mixed-size Windows multi-disk layouts only if they become a target scope later.

- `HA-IMG07-ST01`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - Mixed-size and mixed-format multi-disk layouts also worked on the same secondary-local remote transport model.
    - Distinct export ports were allocated across the qcow2/qcow2/raw combination and all mirrors reached ready=yes in a single run.
  - Follow-up improvement:
    - Validate persistent mixed-size multi-disk behavior.
    - Validate failover/failback once this image mix is included in the HA operational suite.

- `DR-IMG01-ST01`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - The DR baseline on non-shared local qcow2 storage followed the same secondary-local transport model as the HA baseline.
    - `mode=dr` did not require additional backend changes once the remote-nbd path was in place.
  - Follow-up improvement:
    - Validate DR transient and persistent image-behavior cases.
    - Validate DR site failover and reverse-sync/failback exercises.

- `DR-IMG08-ST01`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - DR transient VM behavior followed the same remote-nbd model as the DR baseline.
    - The standby side remained transient (`prepared-transient`) while still reaching protected/mirroring after reconcile.
  - Follow-up improvement:
    - Validate persistent DR behavior.
    - Validate DR failover/failback flows on the same backend.

- `DR-IMG09-ST01`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - Persistent DR behavior followed the same remote-nbd transport path as the DR baseline and transient case.
    - The standby domain naming and persistent define path worked as intended in DR mode as well.
  - Follow-up improvement:
    - Validate DR failover/failback and reverse-sync behavior.
    - Validate Windows DR behavior on the same backend.

- `DR-IMG03-ST01`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - Windows qcow2 DR initially exposed a mode-specific job disappearance after blockcopy start while the secondary export remained alive.
    - Secondary local target ENOSPC was identified and cleaned up.
    - An A/B replay of `baseline`, `AUTO_REARM=0 only`, and `defer standby prepare only` kept the job alive through the early trace window in all three cases.
    - A full rerun of the baseline case without experiment flags then completed and reached protected/mirroring.
  - Follow-up improvement:
    - Keep the remote-nbd free-space preflight and observability hardening.
    - Validate DR Windows persistent behavior after the DR transient path is fully normalized.

- `DR-IMG04-ST02`
  - Result: `PASS` with `remote-nbd` backend mode
  - Observation:
    - Windows raw DR followed the same remote-nbd model as the Windows qcow2 DR case.
    - The Windows 11 UEFI + TPM 2.0 generation path remained valid for raw source images in DR mode.
    - After the initial full copy completed, reconcile promoted the VM to protected/mirroring.
  - Follow-up improvement:
    - Validate DR Windows persistent behavior on both qcow2 and raw variants.
    - Keep checking secondary-local capacity because raw targets allocate aggressively during copy.
