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
| `HA-IMG02-ST02` | `IMG02` | `ST02` | mandatory | HA baseline Linux raw on local raw | pending |
| `HA-IMG03-ST01` | `IMG03` | `ST01` | mandatory | HA baseline Windows qcow2 | pending |
| `HA-IMG04-ST02` | `IMG04` | `ST02` | recommended | HA Windows raw | pending |
| `HA-IMG05-ST01` | `IMG05` | `ST01` | mandatory | HA multi-disk Linux qcow2 | pending |
| `HA-IMG06-ST02` | `IMG06` | `ST02` | recommended | HA multi-disk Linux raw | pending |
| `HA-IMG07-ST01` | `IMG07` | `ST01` | recommended | HA mixed-size multi-disk | pending |
| `HA-IMG08-ST01` | `IMG08` | `ST01` | mandatory | HA transient VM behavior | pass |
| `HA-IMG09-ST01` | `IMG09` | `ST01` | mandatory | HA persistent VM behavior | pending |
| `HA-IMG01-ST03` | `IMG01` | `ST03` | mandatory | HA local block backend | pending |
| `HA-IMG01-ST04` | `IMG01` | `ST04` | recommended | HA NFS backend | pending |
| `HA-IMG01-ST05` | `IMG01` | `ST05` | recommended | HA multipath backend | pending |
| `HA-IMG01-ST06` | `IMG01` | `ST06` | recommended | HA Ceph RBD backend | pending |

## 7. DR Test IDs

| Test ID | Image | Storage | Priority | Purpose | Status |
|---|---|---|---|---|---|
| `DR-IMG01-ST01` | `IMG01` | `ST01` | mandatory | DR baseline Linux qcow2 | pending |
| `DR-IMG03-ST01` | `IMG03` | `ST01` | recommended | DR Windows qcow2 | pending |
| `DR-IMG08-ST01` | `IMG08` | `ST01` | mandatory | DR transient VM behavior | pending |
| `DR-IMG09-ST01` | `IMG09` | `ST01` | mandatory | DR persistent VM behavior | pending |
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
