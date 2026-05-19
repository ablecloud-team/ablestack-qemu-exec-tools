# ablestack_n2k Cloud storage path resolution design

## Purpose

This document records the storage path issue found during the 10.10.1.x Cloud
FileSystem/qcow2 migration test and defines the required fix.

When the target provider is `ablestack-cloud`, n2k must not assume a local host
default such as `/var/lib/libvirt/images`. The target qcow2 files must be
created under the actual mount path of the ABLESTACK Cloud primary storage pool
selected by the operator.

## Failure Found

Test host:

```text
10.10.1.1
```

Failed workdir:

```text
/var/lib/ablestack-n2k/rhel/20260519-202933-8980a495
```

Selected Cloud storage pool:

```text
id:   1c8c9a4b-bae2-4ccb-a61d-43a6579b0bed
path: /mnt/glue-gfs
type: SharedMountPoint
```

n2k created the migrated qcow2 files under:

```text
/var/lib/libvirt/images
```

Cloud `importVolume` then failed with:

```text
Cannot get volumes on storage pool via host Host {"id":1,"name":"ablecube1",...}
```

The error is not evidence that the selected storage is host-local. The Cloud
import implementation selects a host in the storage pool scope and sends
`GetVolumesOnStorageCommand` through that host. For a cluster-scoped
`SharedMountPoint` storage pool, the selected host is only the agent used to
inspect the shared pool. The file still has to exist under the selected pool's
mount path.

## Cloud Behavior

`ablestack-cloud` branch `ablestack-diplo` supports import for KVM storage pool
types:

```text
NetworkFilesystem
Filesystem
RBD
SharedMountPoint
```

For `Filesystem`, `NetworkFilesystem`, and `SharedMountPoint`, the KVM agent
looks up the volume in the selected storage pool. Even when n2k passes an
absolute path, the agent resolves the basename against the storage pool local
path and verifies that the resulting disk path matches. Therefore migrated
qcow2 files must be root-level files directly under the selected storage pool
path.

Example:

```text
storage pool path: /mnt/glue-gfs
valid import path: /mnt/glue-gfs/n2k-rhel-disk0.qcow2
invalid path:      /var/lib/libvirt/images/n2k-rhel-disk0.qcow2
invalid path:      /mnt/glue-gfs/subdir/n2k-rhel-disk0.qcow2
```

## Required Runtime Rules

When `--target-provider ablestack-cloud` and `--target-storage file` are used:

1. n2k must require `--cloud-storage-id`.
2. n2k must query `listStoragePools id=<cloud-storage-id>`.
3. n2k must accept only file-backed Cloud storage types:
   `Filesystem`, `NetworkFilesystem`, or `SharedMountPoint`.
4. n2k must resolve the selected storage pool path from the Cloud API response.
5. n2k must use that path as `target.dst_root`.
6. n2k must create every target qcow2 as a root-level file under that path.
7. If `--dst` is supplied, it must match the selected Cloud storage path.
8. If `--target-map-json` is supplied, every mapped path must be directly under
   the selected Cloud storage path.

## Scope-Specific Behavior

For cluster-scoped `SharedMountPoint` storage:

- host selection is not required for file placement;
- the storage path is authoritative;
- an optional host id may still be used for VM placement if the operator
  intentionally supplies one.

For host-scoped local `Filesystem` storage:

- the storage path is still resolved from `listStoragePools`;
- the target qcow2 files must be written under that path on the selected host;
- `--cloud-host-id` is required for VM placement when the storage scope is
  `HOST`.

For RBD:

- existing RBD image-name import behavior remains unchanged.

## Failure Handling

Cloud target cutover must be fail-fast. If any Cloud API step fails or returns
an empty id, n2k must stop immediately and must not continue to the next Cloud
operation.

On Cloud cutover failure, `run` must not:

- mark the `cutover` phase complete;
- clean source recovery points;
- mark `phase2` complete;
- print `Cloud cutover completed`.

This protects the source snapshots and preserves enough state for a corrected
retry.

## Manifest Additions

After resolving the Cloud storage pool, n2k records a non-secret summary:

```json
{
  "target": {
    "cloud": {
      "storage_pool": {
        "id": "...",
        "name": "...",
        "type": "SharedMountPoint",
        "scope": "CLUSTER",
        "path": "/mnt/glue-gfs",
        "cluster_id": "...",
        "cluster_name": "..."
      }
    }
  }
}
```

No Cloud API key or secret key is stored in the manifest.

## Related Documents

- `docs/n2k/ablestack_n2k_cloud_api_target_design.md`
- `docs/n2k/ablestack_n2k_interactive_migration_design.md`
- `docs/n2k/ablestack_n2k_cloud_api_target_e2e_plan.md`
