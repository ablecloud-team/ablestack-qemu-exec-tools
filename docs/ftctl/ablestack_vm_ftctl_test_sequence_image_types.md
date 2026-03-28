# ablestack_vm_ftctl Test Sequence by VM Image Type

## 1. Purpose

This document defines the real-environment test sequence by VM image type.

## 2. Image Type Matrix

Minimum coverage:

| ID | Image Type | Disk Format | Expected Coverage |
|---|---|---|---|
| IMG-01 | single-disk Linux | qcow2 | mandatory |
| IMG-02 | single-disk Linux | raw | mandatory |
| IMG-03 | single-disk Windows | qcow2 | mandatory |
| IMG-04 | single-disk Windows | raw | recommended |
| IMG-05 | multi-disk Linux | qcow2 + qcow2 | mandatory |
| IMG-06 | multi-disk Linux | raw + raw | recommended |
| IMG-07 | mixed-size multi-disk Linux | qcow2/raw | recommended |
| IMG-08 | transient VM | qcow2 | mandatory |
| IMG-09 | persistent VM | qcow2 | mandatory |

## 3. Common Sequence Per Image Type

Run this sequence for each image type:

1. Prepare VM profile and cluster inventory
2. Run `protect`
3. Confirm blockcopy or x-colo enters expected state
4. Confirm standby XML / generated XML is correct
5. Inject transient network loss
6. Confirm `reconcile` behavior
7. Trigger failover
8. Verify boot and network on secondary
9. Trigger failback if supported
10. Record result and event log

## 4. HA Cases

For each applicable image type:

- `protect --mode ha`
- short network blip
- source host stop
- source VM stop/destroy
- manual fencing flow where applicable

## 5. DR Cases

For each applicable image type:

- `protect --mode dr`
- WAN-like latency or delayed path where possible
- transient loss / recovery
- site failover
- reverse sync / failback path

## 6. FT Cases

For each applicable image type selected for FT:

- `protect --mode ft`
- x-colo dry-run or real setup
- `x-colo-lost-heartbeat` failover
- secondary promotion behavior

Recommended FT image subset:

- single-disk Linux qcow2
- persistent VM
- low-memory VM

## 7. Special Checks by Image Type

### Windows

- boot completion
- network address assignment
- guest responsiveness

### Multi-disk VMs

- all protected disks mapped correctly
- standby XML uses expected disk paths
- reverse sync plan contains all disks

### Transient VMs

- XML backup exists
- standby/generated XML can recreate domain

### Persistent VMs

- peer `define` path works
- peer `start` path works

## 8. Result Template

For each case record:

- image ID
- mode
- storage backend
- pass/fail
- observed state transitions
- notes
