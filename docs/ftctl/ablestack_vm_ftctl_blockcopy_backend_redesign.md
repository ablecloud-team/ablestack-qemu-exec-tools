# ablestack_vm_ftctl Blockcopy Backend Redesign

## 1. Purpose

This document formalizes the HA/DR backend redesign discovered during real-environment testing.

The original implementation proved that control-plane orchestration could:

- collect inventory
- start a libvirt blockcopy mirror
- generate standby XML
- define persistent standby domains

However, real-environment validation showed that the current blockcopy target model is not sufficient for host-local, non-shared storage.

## 2. Problem Statement

Observed behavior:

- runtime `virsh dumpxml` on the primary host showed a valid `<mirror ...>` element
- the mirror target path was still a primary-host local filesystem path
- the secondary host did not receive a usable replica disk
- failover-ready standby storage was therefore not guaranteed

Implication:

- a runtime XML mirror element on the primary host is not enough to declare HA/DR success
- the data plane must prepare a storage target that the secondary host can actually use

## 3. Required Backend Split

HA/DR blockcopy must be split into at least two backend modes.

### 3.1 `shared-visible blockcopy mode`

Use this mode when:

- primary and secondary hosts can both access the target storage path
- storage is shared or otherwise visible from both sides
- the target path is valid for both replication and later standby activation

Examples:

- shared NFS
- shared multipath-backed filesystem
- storage systems where both hosts can access the same replicated target path

Behavior:

1. primary starts `blockcopy` to a shared-visible target path
2. standby XML is generated for the secondary host
3. the secondary domain is defined with a distinct standby domain name
4. failover starts the secondary domain against the shared-visible target path

Notes:

- the primary and secondary domain names should not be identical on the same cluster
- service identity and domain identity should be separated

Recommended fields:

- `service_id`
- `primary_domain_name`
- `secondary_domain_name`
- `target_storage_scope=shared`

### 3.2 `remote-local transport mode`

Use this mode when:

- primary and secondary hosts do not share storage
- the destination must live on the secondary host local storage
- the hosts may be in different sites

Examples:

- local file qcow2 on each host
- local raw file on each host
- remote DR host without shared storage

Behavior:

1. secondary prepares a local target file or block device
2. secondary exports that target through a remote transport such as NBD
3. primary mirrors to that remote sink
4. standby XML on the secondary host references the secondary-local path
5. failover activates the secondary domain against its local replica

Notes:

- simple primary-local filesystem paths are invalid for this mode
- plain local `virsh blockcopy` destination paths must not be used as a substitute for remote replication

Recommended fields:

- `target_storage_scope=secondary-local`
- `transport_mode=remote-nbd`
- `secondary_target_dir`
- `secondary_target_path`
- `secondary_export_addr`
- `secondary_export_port`
- `secondary_export_name`

## 4. Validation Rules

The controller must validate backend assumptions before `protect`.

### 4.1 Reject unsupported layouts

The controller must reject:

- local file backend
- local block backend
- non-shared storage
- shared-visible blockcopy mode selected

Reason:

- this would create a primary-local mirror target instead of a usable secondary-side replica

### 4.2 Accept shared-visible layouts

The controller may accept:

- shared paths visible from both hosts
- target paths explicitly marked as shared-visible

### 4.3 Accept remote-local transport layouts

The controller may accept:

- secondary-local storage
- remote transport settings fully provided
- remote sink reachability validated before `protect`

## 5. Runtime Success Criteria

`blockjob --info` alone is not a sufficient success signal in every libvirt/QEMU environment.

Protect success should be judged from multiple signals:

- runtime XML mirror metadata in `virsh dumpxml`
- target path storage scope validation
- actual target existence on the correct host
- secondary standby XML correctness
- secondary domain define/create readiness

For non-shared local storage, success requires:

- target exists on the secondary side
- standby XML references the secondary-local target
- the failover path can boot from the secondary-local replica

## 6. Test Matrix Impact

The real-environment test matrix must be interpreted with backend-awareness.

### 6.1 Reclassified tests

- `HA-IMG01-ST01`: failed as a true HA data-plane test under current implementation
- `HA-IMG08-ST01`: failed as a true HA data-plane test under current implementation

Reason:

- both tests used local file qcow2 without a valid secondary-side data-plane replica

### 6.2 New expectation

Before re-running local-storage HA/DR tests, the implementation must support:

- `remote-local transport mode`

Shared-storage tests may continue under:

- `shared-visible blockcopy mode`

## 7. Next Implementation Tasks

1. Add backend mode fields to profile schema
2. Add validation that rejects invalid storage/layout combinations
3. Implement `remote-local transport mode` for non-shared local storage
4. Separate service identity from standby domain name
5. Update real-environment test IDs and expectations by backend mode

