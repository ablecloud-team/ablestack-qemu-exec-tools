# ablestack_vm_ftctl Real-Environment Integration Test Plan

## 1. Purpose

This document defines the next execution phase after implementation:

- validate `HA`, `DR`, and `FT` in a real ABLESTACK/libvirt/QEMU environment
- validate behavior across VM image types
- validate behavior across backend storage types
- capture operational gaps before PR / production review

## 2. Scope

The following must be verified in a real environment:

- `protect`
- `status`
- `check`
- `reconcile`
- `failover`
- `failback`
- `fence-confirm`
- `fence-clear`
- standby XML generation and activation
- blockcopy rearm
- x-colo protect / rearm / failover

## 3. Environment Requirements

- ABLESTACK cluster with at least 2 libvirt/QEMU hosts
- working `qemu+ssh://peer/system` connectivity
- fencing path available for at least one provider
- networks separated where possible:
  - management
  - blockcopy replication
  - x-colo control
  - x-colo data/NBD
- test VMs for each image/storage combination

## 4. Test Order

Recommended execution order:

1. cluster inventory sanity check
2. HA tests
3. DR tests
4. FT/x-colo tests
5. failback tests
6. long-running rearm / transient network loss tests

## 5. Mandatory Dimensions

Two dimensions must both be covered:

1. VM image type
2. backend storage type

These are split into separate runbooks:

- [ablestack_vm_ftctl_test_sequence_image_types.md](/c:/Users/ablecloud/Documents/GitHub/dhslove/ablestack-qemu-exec-tools/docs/ftctl/ablestack_vm_ftctl_test_sequence_image_types.md#L1)
- [ablestack_vm_ftctl_test_sequence_storage_backends.md](/c:/Users/ablecloud/Documents/GitHub/dhslove/ablestack-qemu-exec-tools/docs/ftctl/ablestack_vm_ftctl_test_sequence_storage_backends.md#L1)

## 6. Common Success Criteria

For each test case, verify at least:

- protection command succeeds
- expected state transition occurs
- standby XML is generated correctly
- data path is consistent after failover
- no split-brain condition is observed
- reconcile reacts correctly to transient failure
- logs/events are written

## 7. Common Failure Injection

Use these injections where applicable:

- peer management network loss
- replication network loss
- short network blip
  - 1 sec
  - 2 sec
  - 5 sec
- source host shutdown
- source VM destroy
- libvirtd restart
- storage path loss

## 8. Deliverables

The real-environment phase should end with:

- per-test execution log
- matrix summary
- known defects list
- design/implementation follow-up list
