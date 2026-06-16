# v2k/n2k RBD Sparse Migration Design

## Background

v2k and n2k can migrate disks to ABLESTACK Cloud RBD targets as raw RBD
images. Current RBD write paths preserve logical disk contents, but they do not
consistently preserve sparse allocation. As a result, a disk with large unused
or zero-filled ranges can allocate close to the full logical size in Ceph RBD.

The goal of this change is to keep RBD target images logically identical while
avoiding allocation for unused or zero-filled source ranges whenever the host
toolchain supports discard or sparse writes.

## Current Code Path Summary

### v2k base sync

`lib/v2k/transfer_base.sh` selects direct RBD output when
`target.storage.type == "rbd"` and runs `qemu-img convert` directly to the
`rbd:pool/image` URI.

Current behavior:

```bash
qemu-img convert -p -t none -T none -O raw "$uri" "$out_target"
```

The command does not pass `-S` and does not pre-create the RBD image for `-n`,
so sparse conversion is not explicitly requested.

### v2k incremental and final sync

`lib/v2k/transfer_patch.sh` gets VMware CBT changed areas and calls
`lib/v2k/patch_apply.py`. The Python helper reads each changed range from the
source NBD device and writes the bytes to the target block device.

VMware CBT changed areas do not carry a zero or hole type in the current helper
contract. Therefore, v2k must detect all-zero chunks during patch apply if it
wants to avoid allocating those chunks in RBD.

### n2k base sync

`lib/n2k/target_storage.sh` uses `qemu-img convert` for RBD target base sync.

Current behavior:

```bash
qemu-img convert -p -O raw "$source_path" "$target_path"
```

The command does not pass a sparse threshold.

### n2k incremental and final sync

`lib/n2k/transfer_patch.sh` already accepts region types:

- `regular`
- `zero`
- `zeros`
- `zeroed`
- `hole`

However, `lib/n2k/target_storage.sh` currently applies zero and hole regions by
writing `/dev/zero` to the mapped target. This makes the target contents
correct, but can allocate RBD objects for ranges that should remain sparse.

## Design Goals

- Preserve target disk logical size and data correctness.
- Enable sparse handling by default for RBD targets.
- Keep the change scoped to RBD target paths.
- Keep file, qcow2, and generic block target behavior unchanged unless
  explicitly required.
- Fall back to the current write behavior when sparse/discard operations are not
  supported by the runtime.
- Emit events or log lines that make it clear whether sparse handling was used,
  skipped, or degraded to fallback behavior.

## Proposed Runtime Controls

Use tool-specific environment variables so operators can tune or disable sparse
handling without changing CLI compatibility.

Common defaults:

```bash
V2K_RBD_SPARSE="${V2K_RBD_SPARSE:-1}"
V2K_RBD_SPARSE_SIZE="${V2K_RBD_SPARSE_SIZE:-4M}"
V2K_RBD_SPARSIFY_AFTER="${V2K_RBD_SPARSIFY_AFTER:-auto}"

N2K_RBD_SPARSE="${N2K_RBD_SPARSE:-1}"
N2K_RBD_SPARSE_SIZE="${N2K_RBD_SPARSE_SIZE:-4M}"
N2K_RBD_SPARSIFY_AFTER="${N2K_RBD_SPARSIFY_AFTER:-auto}"
```

`4M` is chosen as the first default because it commonly matches Ceph RBD object
size and avoids excessive metadata churn. The value remains configurable for
environments that need more aggressive zero detection.

## Proposed v2k Changes

### 1. RBD base sync sparse conversion

When target storage is RBD:

1. Ensure the RBD image exists and is at least the source logical size.
2. Run `qemu-img convert` with `-S`.
3. Add `-n` only when the RBD image did not exist before this run and was just
   created by the migration code. This avoids stale data risk on reused target
   images because sparse conversion can skip zero ranges.
4. Keep the current direct librbd URI path.

Target command shape:

Newly created target command shape:

```bash
qemu-img convert -p -t none -T none -n -S "$V2K_RBD_SPARSE_SIZE" -O raw "$uri" "$out_target"
```

Pre-existing target command shape:

```bash
qemu-img convert -p -t none -T none -S "$V2K_RBD_SPARSE_SIZE" -O raw "$uri" "$out_target"
```

If sparse mode is disabled, retain the current command.

### 2. RBD patch sparse zero handling

Extend `lib/v2k/patch_apply.py` with optional zero-chunk detection:

1. Read the source chunk as today.
2. If the chunk is all zero and RBD sparse patch mode is enabled, perform a
   discard or zero-unmap operation for that range.
3. If discard fails, write the zero chunk as fallback.
4. If the chunk is not all zero, write normally.

Because `patch_apply.py` currently receives only block device paths, the first
implementation should support mapped-device discard with `blkdiscard` for RBD
targets. If direct RBD URI discard is needed later, add a qemu-io path.

The shell caller should pass enough context to the helper, for example:

```bash
--target-kind rbd --sparse-zero on --discard-mode auto
```

### 3. Optional post-pass RBD sparsify

If discard support is unavailable or ambiguous, run `rbd sparsify` as a
compatibility fallback when available:

```bash
rbd sparsify pool/image --sparse-size "$V2K_RBD_SPARSE_SIZE"
```

This should be controlled by `V2K_RBD_SPARSIFY_AFTER`:

- `0`: never run.
- `1`: always run after RBD base/final sync.
- `auto`: run only when sparse conversion or discard support could not be
  confirmed.

## Proposed n2k Changes

### 1. RBD base sync sparse conversion

Update the RBD branch in `n2k_storage_copy_base` to use sparse conversion:

Newly created target command shape:

```bash
qemu-img convert -p -n -S "$N2K_RBD_SPARSE_SIZE" -O raw "$source_path" "$target_path"
```

Pre-existing target command shape:

```bash
qemu-img convert -p -S "$N2K_RBD_SPARSE_SIZE" -O raw "$source_path" "$target_path"
```

Before using `-n`, ensure the RBD image exists and has the expected logical
size, and confirm that it was not pre-existing.

### 2. RBD zero/hole patch discard

Update the RBD patch path so zero and hole regions do not use `dd if=/dev/zero`
by default.

Preferred order:

1. Use `qemu-io` against the direct `rbd:pool/image` URI with discard or
   zero-unmap.
2. Use `blkdiscard -o <offset> -l <length> <mapped_device>` when the RBD image is
   mapped as a block device.
3. Fall back to the current `/dev/zero` write when discard is unsupported.

Regular regions should continue to use the current write path.

### 3. Optional post-pass RBD sparsify

Use `rbd sparsify` with `N2K_RBD_SPARSIFY_AFTER` using the same semantics as v2k.

## Observability

Add structured events or clear log lines for RBD sparse behavior:

- base sparse enabled or disabled
- sparse size selected
- discard method selected
- discard fallback count
- optional `rbd sparsify` start/done/fail
- pre/post used bytes when `rbd du` is available

For v2k, the existing `v2k_fleet_used_bytes_rbd` helper already uses `rbd du`
and can be reused for validation or summary reporting.

## Validation Plan

### Unit-level validation

- Shell syntax checks for modified scripts.
- Python syntax check for `patch_apply.py`.
- Validate command generation for RBD base sync with sparse enabled and disabled.
- Validate n2k zero/hole region dispatch chooses discard before zero write.

### Local synthetic RBD validation

Use a synthetic source image with sparse and zero-filled ranges:

1. Create a logical 60 GiB source.
2. Write non-zero data to a few small ranges.
3. Run v2k/n2k RBD base sync logic.
4. Confirm `rbd info` reports the full logical size.
5. Confirm `rbd du` reports allocated usage close to written data, not 60 GiB.
6. Read back non-zero ranges and verify checksums.

### Incremental/final validation

1. Start with a target image containing allocated data in a test range.
2. Make the corresponding source range zero.
3. Run v2k final sync or n2k patch sync.
4. Confirm target reads zeros.
5. Confirm `rbd du` does not grow unnecessarily and decreases when discard is
   supported.

## Risks and Fallbacks

- `qemu-img -S` behavior depends on qemu and librbd capabilities.
- `blkdiscard` may not be supported by every RBD mapping mode.
- `qemu-io` discard support can differ across qemu builds.
- `rbd sparsify` is reliable but can be expensive on large disks.

For these reasons, sparse handling should be best-effort with safe fallback to
the current full zero write behavior. Correctness must take priority over
allocation efficiency.

## Implementation Order

1. Add RBD sparse helper functions and environment defaults.
2. Update v2k RBD base sync.
3. Update n2k RBD base sync.
4. Add n2k zero/hole discard handling for RBD patch.
5. Extend v2k patch apply for zero chunk detection and discard fallback.
6. Add optional `rbd sparsify` fallback.
7. Add targeted validation scripts or tests.
8. Build v2k and n2k RPMs.
