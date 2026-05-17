# ablestack_n2k PC v4 / PE v4 native migration path design

Date: 2026-05-18  
Target environment: Prism Central `https://10.10.132.100:9440`, PE `10.10.132.10`

## Goal

Add a third source path to `ablestack_n2k` without regressing the two already
validated legacy paths.

The three supported source paths must be:

| Path | Purpose | Source API policy | Main endpoint |
| --- | --- | --- | --- |
| 1. v3/v2 legacy | Legacy PE/PC environments and explicit operator override | auto or forced `v3` | PE v3/v2 |
| 2. PC v4 / PE v3 fallback | PC advertises v4, but PE v4 content/data-plane is not verified | auto fallback | PC v4 inventory, PE v3 source operations |
| 3. PC v4 / PE v4 native | New preferred path for fully v4-capable environments | auto preferred or forced `v4` | PC v4 config + PE v4 content |

This document designs path 3. Path 1 and path 2 remain first-class regression
targets.

## Confirmed PC132 facts

Current PC132 validation changed the previous assumption about PE v4 behavior:

- PC `10.10.132.100` exposes v4.1 VMM, Data Protection config, Cluster
  Management, and Prism task APIs.
- `v4.2` is not exposed on this testbed.
- PE `10.10.132.10` still returns HTTP `404` for generic v4 namespace root
  probes.
- However, a real v4 Recovery Point flow succeeds when using the exact PC
  `discover-cluster` result:
  - PC Data Protection config revision: `v4.1`
  - PC `discover-cluster` returned PE `10.10.132.10`
  - JWT scope/content revision: `v4.0`
  - PE content path:
    `/api/dataprotection/v4.0/content/recovery-points/{rp}/vm-recovery-points/{vmrp}/disk-recovery-points/{diskrp}/$actions/compute-changed-regions`
  - PE `compute-changed-regions` returned HTTP `200`

Design conclusion: generic PE v4 root probing must not decide v4 content
availability. The only reliable signal is a live PC `discover-cluster` response
plus a successful JWT-authorized PE content action.

## Source path selection

Add `v4` as a first-class source API policy.

```text
--source-api auto|v3|v4
--force-v3
--force-v4
--mode auto|v4-incremental|v3-incremental|legacy-cbt|cold-export|manual-disk
```

Selection rules:

1. `--force-v3` or explicit `--source-api v3`
   - select path 1.
   - do not use v4 source operations even if PC v4 is available.
   - fail fast if combined with `--mode v4-incremental`.
2. `--force-v4` or explicit `--source-api v4`
   - select path 3.
   - require all v4-native capability bits.
   - fail fast instead of silently falling back to v3.
3. `--source-api auto`
   - prefer path 3 only when v4-native control-plane and data-plane are both
     verified.
   - otherwise select path 2 when PC v4 is available and PE v3 incremental is
     verified.
   - otherwise use path 1 or the existing cold/manual fallback.

## Capability model

Split v4 capability into independent bits. A PC v4 list endpoint is not enough
to run a v4 migration.

```json
{
  "api": {
    "v4": {
      "vmm_inventory": true,
      "dataprotection_config": true,
      "prism_tasks": true,
      "clustermgmt": true,
      "recovery_point_lifecycle": true,
      "dp_discover_cluster": true,
      "pe_compute_changed_regions": true,
      "byte_source": false,
      "data_plane": false,
      "native_incremental": false
    }
  }
}
```

`native_incremental` is true only when these are true:

- PC v4 VM inventory works.
- PC v4 Recovery Point create/get/delete works.
- PC v4 task wait works.
- PC `discover-cluster` works for Recovery Point disk references.
- PE JWT-authorized `compute-changed-regions` works.
- A reliable byte source for Recovery Point disk contents is verified.

Current PC132 status:

- v4 control-plane and changed-region metadata path: verified for a single-disk
  VM.
- v4 byte source: not yet verified.
- Therefore path 3 can be implemented behind capability gates, but must not be
  reported as E2E runnable until the byte source is proven.

## v4 native run flow

The v4 native flow mirrors the validated v3 incremental lifecycle, but replaces
v3 VM snapshots with v4 Recovery Points and replaces v3 changed-region calls
with the PC discover + PE content action.

### Full run

1. Initialize manifest from PC v4 VMM inventory.
2. Create base Recovery Point through PC v4 Data Protection config.
3. Resolve top-level Recovery Point, VM Recovery Point, and disk Recovery Point
   IDs.
4. Build a v4 Recovery Point disk index in the manifest.
5. Read base disk bytes through the selected v4 byte-source adapter.
6. Write base disks to target storage.
7. Create final Recovery Point.
8. Use PC `discover-cluster` and PE `compute-changed-regions` against the base
   Recovery Point.
9. Patch changed regions from the v4 byte source.
10. Define/start the target VM according to the cutover policy.
11. Delete all temporary v4 Recovery Points unless the operator requested
    retention.

### Phase1/Phase2 run

Phase1:

1. Create base Recovery Point.
2. Base sync through v4 byte source.
3. Create incremental Recovery Point.
4. Compute changed regions against base.
5. Patch target disks.
6. Stop after recording the phase1 marker.

Phase2:

1. Repeat incremental Recovery Point creation and changed-region patching until
   deadline criteria are met.
2. At cutoff, run the configured source shutdown policy.
3. Create final Recovery Point after shutdown.
4. Compute changed regions against the last incremental Recovery Point.
5. Final patch.
6. Cutover define/start.
7. Cleanup v4 Recovery Points.

## Endpoint and token handling

Path 3 uses two endpoint classes:

- PC config endpoint:
  - v4 VMM inventory
  - v4 Data Protection Recovery Point lifecycle
  - v4 Prism task wait
  - v4 Data Protection `discover-cluster`
- PE content endpoint:
  - PE IP and JWT are obtained from `discover-cluster`.
  - content API revision is derived from the returned JWT scope or redirect
    link.
  - generic PE v4 root probes are informational only.

JWT handling rules:

- Do not persist JWT values in the manifest or logs.
- Store only non-sensitive metadata:
  - PE IP
  - content revision
  - content path template
  - HTTP status
  - region counts and file size
- Refresh JWTs by calling `discover-cluster` again when needed because the token
  is short lived.

## Byte-source design

Changed-region metadata tells `n2k` which offsets changed; it does not provide
the bytes to write. Path 3 therefore needs an explicit v4 byte-source adapter.

Introduce:

```text
--v4-byte-source auto|recovery-point-export|recovery-point-nfs|restore-proxy
--source-map-from-v4-rp
```

Adapter contract:

```text
n2k_source_v4_build_source_map <manifest> <rp-index> <strategy>
n2k_source_v4_prepare_read <disk-ref> <offset> <length>
n2k_source_v4_read_chunk <disk-ref> <offset> <length> <output-file>
n2k_source_v4_cleanup_read_context
```

Candidate strategies:

1. `recovery-point-export`
   - Preferred if an official v4 Recovery Point disk content/export endpoint is
     discovered through API links or documentation.
   - Must support full-disk reads and arbitrary changed-region offsets.
2. `recovery-point-nfs`
   - Acceptable only if the v4 Recovery Point metadata can be mapped to a stable
     read-only PE/CVM file path without using v3 snapshot APIs.
   - Must be validated against large offsets and multi-disk VMs.
3. `restore-proxy`
   - Restore the Recovery Point to a temporary powered-off VM, then use a
     verified read path for the restored VM disks.
   - Current PC132 validation shows v3 live disk data is limited and is not
     suitable for full-disk reads, so this remains a candidate, not a runnable
     default.

Rules:

- `--source-api v4` must fail if no v4 byte source is verified.
- `auto` must fall back to path 2 when v4 changed-region metadata is available
  but byte source is not.
- The code may collect and record v4 changed-region metadata before byte-source
  completion, but it must not claim `v4-incremental can_run=true`.

## Byte-source validation result

Validation date: 2026-05-18  
Probe target VM: `centos7-bios-ide`

The PC132/PE132 environment verifies v4 Recovery Point lifecycle and PE v4
changed-region metadata, but no usable v4 byte source was found yet.

| Candidate | Result | Evidence |
| --- | --- | --- |
| Direct source VM v4 disk data/export/read | Failed | PC VMM `ahv/config` and `ahv/content` disk `data`, `bytes`, `download`, `$actions/export`, and `$actions/read` candidates returned HTTP `404`. |
| Direct Recovery Point disk data/export/read | Failed | PC and PE Data Protection Recovery Point disk content candidates returned HTTP `404`; several action-style candidates returned HTTP `500` JSON errors rather than disk bytes. |
| PC discover + PE compute-changed-regions | Passed | PC `discover-cluster` returned PE `10.10.132.10` and a JWT-scoped `v4.0` content path; PE `compute-changed-regions` returned HTTP `200` with region data. |
| Restore-proxy through temporary VM | Not viable | Restoring the Recovery Point to a temporary powered-off VM succeeded, but v4 byte endpoints for the restored VM returned HTTP `404`. The v3 live disk data endpoint could read small windows only and failed beyond the known 16 MiB offset ceiling, so it cannot be used as a full-disk source. |
| Cleanup | Passed | Temporary Recovery Points and the restore-proxy temporary VM were deleted; follow-up v4 list probes found no `n2k-v4-*` byte-source leftovers. |

Decision:

- Keep `byte_source=false`, `data_plane=false`, and
  `native_incremental=false` for PC132 until a full-disk byte source is
  verified.
- `--source-api v4` must continue to fail fast with a byte-source missing
  reason.
- `--source-api auto` must continue to choose the PC v4 / PE v3 fallback path
  when v4 changed-region metadata is available but byte reads are not.
- The next implementation step is to identify a vendor-supported Recovery Point
  disk export/read mechanism or a stable read-only Recovery Point file mapping
  that supports arbitrary full-disk offsets and multi-disk VMs.

## Code changes

### `lib/n2k/nutanix_api.sh`

- Add `prism` to v4 namespace revision selection.
- Prefer `v4.1`, then `v4.0` for `vmm`, `dataprotection`, `clustermgmt`, and
  `prism`.
- Keep `v4.2` as an optional future probe only after a real environment exposes
  it.

### `lib/n2k/source_adapter.sh`

- Promote the existing v4 Recovery Point lifecycle helpers into a formal source
  adapter surface.
- Add a controlled live v4 capability probe:
  - create short-retention RP
  - discover cluster
  - compute a bounded changed-region window
  - delete RP
- Record `dp_discover_cluster` and `pe_compute_changed_regions` separately.
- Add v4 byte-source adapter stubs and structured failure messages.
- Do not save JWTs.

### `lib/n2k/preflight.sh`

- Accept `source_api_policy=auto|v3|v4`.
- Report three path decisions:
  - `v3_legacy`
  - `pc_v4_pe_v3_fallback`
  - `pc_v4_pe_v4_native`
- `selected_mode=v4-incremental` only when `native_incremental=true`.
- If `source_api_policy=v4` and byte source is missing, return `can_run=false`
  with a clear reason.

### `lib/n2k/engine.sh`

- Allow `run --source-api v4`.
- Build `snapshot_common` differently by source API:
  - v3: `--create-vm-snapshot`, PE source endpoint, v3 NFS source map.
  - v4: `--create-recovery-point`, PC endpoint, v4 RP source map.
- Add v4 shutdown handling through v4 VM power APIs instead of forcing v2/v3
  inventory.
- Add v4 cleanup:
  - delete v4 Recovery Points through PC v4 Data Protection config.
  - keep existing v3 VM snapshot cleanup through the selected PE.
- Keep Phase1/Phase2 state machine unchanged where possible.

### `lib/n2k/transfer_cold.sh` and `lib/n2k/transfer_patch.sh`

- Add `nutanix-v4-rp://` or equivalent internal source-map handling.
- Reuse existing zero-region handling in the patch writer.
- Ensure reads are chunked and bounded by the byte-source adapter, not by the
  changed-region page size.

### `lib/n2k/manifest.sh`

Record:

- selected source path: `v3_legacy`, `pc_v4_pe_v3_fallback`, or
  `pc_v4_pe_v4_native`
- selected v4 revisions per namespace
- PC endpoint and PE content endpoint
- RP/VMRP/diskRP identifiers
- changed-region compute metadata
- byte-source strategy and verification status
- cleanup status per Recovery Point

Do not record:

- Prism password
- JWT token
- temporary bearer/session secrets

## Test plan

### Non-mutating tests

- PC v4 namespace revision selection.
- v3/v2 fallback selection on legacy PC131.
- `--force-v3` conflict and selection behavior.
- `--force-v4` failure when byte source is not verified.
- Manifest schema update tests.

### Controlled v4 smoke tests

Run against PC132:

1. single-disk VM no-reference changed-region smoke.
2. two-Recovery-Point incremental comparison smoke.
3. pagination until `nextOffset=0`.
4. multi-disk VM smoke for `rhel`.
5. multi-disk VM smoke for `win10`.
6. cleanup verification after every failure and success path.

### E2E tests after byte source is verified

Run the same source API matrix across target storage types:

| Test | Source path | Target | VM coverage |
| --- | --- | --- | --- |
| V4-RBD | PC v4 / PE v4 native | RBD | `centos7-bios-ide`, `rhel`, `win10` |
| V4-QCOW2 | PC v4 / PE v4 native | `/var/lib/libvirt/images` qcow2 | one Linux + one Windows |
| V4-LVM | PC v4 / PE v4 native | block/LVM | one Linux |

Regression tests:

- Path 1: forced v3 Phase1/Phase2 and full.
- Path 2: PC v4 with PE v3 fallback Phase1/Phase2 and full.

## Acceptance criteria

- `--source-api v3` never uses v4 source operations.
- `--source-api v4` never silently falls back to v3.
- `--source-api auto` prefers path 3 only when v4 native is fully verified.
- PC132 v4 changed-region compute succeeds through PC discover + PE content.
- v4 Recovery Points are deleted after successful cutoff unless retained by
  operator request.
- No JWT or passwords are written to manifest, logs, or docs.
- Existing v3/v2 E2E tests continue to pass.

## Implementation order

1. Update source API policy parsing and preflight output for `auto|v3|v4`.
2. Add v4.1-first `clustermgmt` and `prism` revision selection.
3. Add live v4 content probe command path with strict cleanup.
4. Add `run --source-api v4` orchestration skeleton using v4 Recovery Points and
   v4 changed-region collection.
5. Add v4 cleanup routing.
6. Implement and validate v4 byte-source adapter.
7. Enable `v4-incremental can_run=true`.
8. Run PC132 E2E on RBD, qcow2, and LVM targets.

## References

- Nutanix v4 API reference and namespace requirements:
  `https://www.nutanix.dev/api-reference-v4/`
- Nutanix REST API and SDK version overview:
  `https://www.nutanix.dev/api-versions/`
- Nutanix v4 changed-region flow:
  `https://www.nutanix.dev/2025/01/15/nutanix-v4-disaster-recovery-api-series-part-2-changed-blocks-tracking-cbt-and-changed-regions-tracking-crt/`
