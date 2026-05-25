# ABLESTACK N2K Source Cache Cleanup Design

## Purpose

N2K incremental and final sync can materialize Nutanix changed regions into a
temporary raw file under the migration work directory before patching the target
disk. This document defines the cache lifecycle so large migrations do not fill
the conversion host local disk.

## Current Risk

Base sync streams or converts directly from the Nutanix snapshot/NFS source to
the target storage, so it does not require a full local source cache.

Incremental and final sync may create sparse raw files under:

```text
<workdir>/source-cache/<phase>-<disk>.raw
```

The file is sparse, but it can still consume significant local space when many
regular changed regions are written or when changed-region metadata falls back
to a full-copy region. Failed or interrupted runs can also leave stale cache
files behind.

## Lifecycle Policy

- By default, N2K removes a materialized source-cache file immediately after the
  target patch operation finishes.
- The cache file is removed even when the target patch operation returns an
  error, as long as the cache path was created and identified.
- Operators can preserve cache files for diagnostics with:

```bash
ablestack_n2k sync incr --keep-source-cache ...
ablestack_n2k sync final --keep-source-cache ...
```

or with:

```bash
export N2K_KEEP_SOURCE_CACHE=1
```

## Capacity Guard

Before materializing a cache file, N2K estimates the regular changed-region
bytes for the disk and compares it with free space on the cache filesystem.

Default reserved margin:

```text
N2K_SOURCE_CACHE_MIN_FREE_BYTES=1073741824
```

The default margin is 1 GiB. Operators can override it when the conversion host
uses a dedicated large work directory.

## Garbage Collection

For stale cache files from failed or interrupted runs, use:

```bash
ablestack_n2k --workdir <workdir> cleanup --remove-source-cache --apply
```

The alias below is equivalent:

```bash
ablestack_n2k --workdir <workdir> cleanup --gc-source-cache --apply
```

The cleanup command only removes `<workdir>/source-cache`. It does not delete
target disks, source snapshots, or the work directory unless the corresponding
cleanup options are also provided.

## Operational Recommendation

For large Nutanix VM migrations, place `--workdir` on a filesystem with enough
free space for the largest expected incremental/final changed-region set plus
the safety margin. The cache directory should not be placed on a small root
filesystem unless the operator has confirmed enough free space.
