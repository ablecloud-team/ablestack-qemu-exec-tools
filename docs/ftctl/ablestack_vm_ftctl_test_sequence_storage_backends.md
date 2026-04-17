# ablestack_vm_ftctl Test Sequence by Storage Backend

## 1. Purpose

This document defines the real-environment test sequence by backend storage type.

## 2. Backend Matrix

Minimum backend coverage:

| ID | Backend Type | Example | Expected Coverage |
|---|---|---|---|
| ST-01 | local file qcow2 | `/var/lib/libvirt/images/*.qcow2` | mandatory |
| ST-02 | local file raw | `/var/lib/libvirt/images/*.raw` | mandatory |
| ST-03 | local block device | LVM / direct block | mandatory |
| ST-04 | shared NFS file | NFS mount | recommended |
| ST-05 | shared multipath block | FC/iSCSI multipath | recommended |
| ST-06 | Ceph RBD | `rbd:` path | recommended |

## 3. Common Sequence Per Backend

Run this sequence for each backend:

1. prepare test VM on the backend
2. create VM profile with correct disk mapping
3. run `protect`
4. verify standby/generated XML path rewrite
5. verify replication state
6. inject backend-specific failure
7. confirm reconcile / rearm / failover behavior
8. verify failback or reverse sync if supported

## 4. Backend-Specific Failure Injection

### ST-01 / ST-02 local file

- source host shutdown
- source VM destroy
- short replication path loss

### ST-03 local block

- block device path visibility check
- blockcopy target path reuse check
- reverse sync target path correctness

### ST-04 shared NFS

- NFS server temporary interruption
- mount recovery
- split-brain risk review

### ST-05 shared multipath block

- one path down
- all paths down
- path recovery

### ST-06 Ceph RBD

- RBD path availability
- naming/mapping correctness
- reverse sync target correctness

## 5. Validation Points

For every backend verify:

- generated XML points to the correct standby storage path
- failover uses the expected backend path on the peer
- reverse sync plan points back to the intended source path
- event log captures backend-related behavior

## 6. Mode Mapping

Recommended coverage by mode:

- HA:
  - ST-01
  - ST-02
  - ST-03
- DR:
  - ST-01
  - ST-04
  - ST-06
- FT:
  - start with ST-01
  - then ST-02 if stable

## 7. Result Template

For each backend case record:

- backend ID
- image type
- mode
- failover pass/fail
- failback pass/fail
- rearm pass/fail
- notes
