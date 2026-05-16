# ablestack_n2k v4 API improvement design for PC 10.10.132.100

Date: 2026-05-15  
Environment: Nutanix Prism Central `https://10.10.132.100:9440`

## Purpose

The existing `n2k` implementation has been validated against the older
10.10.131.11 testbed by using v3 VM snapshots, v3 changed regions, and NFS
snapshot files as the data plane. The new 10.10.132.100 environment exists to
validate the official Nutanix v4 path and to prepare `n2k` for newer PC/AOS
releases.

This design keeps the current v3 path as a proven fallback, but adds a first
class v4 source adapter.

## Environment findings

The first probe from the local workstation/WSL reached the Prism Central API and
confirmed that this environment is materially newer than the previous AOS 6.5.2
testbed.

Observed API availability:

| API | Endpoint | Result |
| --- | --- | --- |
| v1 cluster | `/PrismGateway/services/rest/v1/cluster` | HTTP `200` |
| v2 cluster | `/PrismGateway/services/rest/v2.0/cluster` | HTTP `200` |
| v3 clusters | `/api/nutanix/v3/clusters/list` | HTTP `200`, `2` entities |
| v3 VMs | `/api/nutanix/v3/vms/list` | HTTP `200`, `5` entities |
| v4.0 VMM VMs | `/api/vmm/v4.0/ahv/config/vms?$limit=100` | HTTP `200`, `5` VMs |
| v4.1 VMM VMs | `/api/vmm/v4.1/ahv/config/vms?$limit=100` | HTTP `200`, `5` VMs |
| v4.2 VMM VMs | `/api/vmm/v4.2/ahv/config/vms?$limit=100` | HTTP `404` |
| v4.0 Data Protection recovery points | `/api/dataprotection/v4.0/config/recovery-points?$limit=10` | HTTP `200`, `0` recovery points |
| v4.1 Data Protection recovery points | `/api/dataprotection/v4.1/config/recovery-points?$limit=10` | HTTP `200`, `0` recovery points |
| v4.2 Data Protection recovery points | `/api/dataprotection/v4.2/config/recovery-points?$limit=10` | HTTP `404` |
| v4.0 Prism clusters | `/api/prism/v4.0/config/clusters?$limit=100` | HTTP `404` |
| v4.0 Cluster Management clusters | `/api/clustermgmt/v4.0/config/clusters?$limit=100` | HTTP `200`, `2` clusters |

Observed version and cluster signals:

- Prism Central build family: `ganges`
- PC full version observed through v3 cluster list:
  `el8.5-release-ganges-7.3.1.9-stable-pc-bd4b15bc542578ffff1f5a12fe68e1cef3368031`
- NOS version observed through v3 cluster list: `7.3.1.9`
- A PE cluster was visible through v4 cluster management:
  - name: `test-cluster`
  - extId: `000651c1-7bba-d796-4637-020100d40001`
  - node count: `3`

Observed v4 VM inventory:

| VM | Power | Boot | Secure Boot | vCPU shape | Memory |
| --- | --- | --- | --- | --- | --- |
| `rhel` | `ON` | UEFI | true | `1 x 1` | `4 GiB` |
| `win10` | `ON` | UEFI | true | `4 x 1` | `4 GiB` |
| `centos7-bios-ide` | `ON` | Legacy BIOS | false | `1 x 1` | `4 GiB` |
| `PC-NameOption-1` | `ON` | Legacy BIOS | false | `6 x 1` | `28 GiB` |
| `windows11` | `ON` | UEFI | true | `4 x 1` | `16 GiB` |

Important network finding:

- After the initial successful probe, `10.10.132.100:9440` later returned TCP
  connection refused from the local workstation/WSL.
- The ABLESTACK host `10.10.22.1` also returned connection refused when running
  `ablestack_n2k init` against `10.10.132.100`.
- ICMP ping still succeeded from the workstation, so the host was reachable but
  Prism Gateway on `9440` was not accepting connections at that later check.
- After Prism Gateway was restored, host-side reachability was rechecked on
  2026-05-15. ABLESTACK host `10.10.22.1` could open TCP `9440` to both
  `10.10.132.100` and the legacy PC `10.10.131.11`.

This means v4 support must include both API capability discovery and run-host
connectivity validation. A successful probe from the operator workstation is not
enough for a migration run if the ABLESTACK host executes the source API calls.

## Current implementation gaps

### API revision discovery

Current code probes only fixed v4.0 endpoints:

- `lib/n2k/nutanix_api.sh`
  - `/api/vmm/v4.0/ahv/config/vms?$limit=100`
- `lib/n2k/source_adapter.sh`
  - `/api/vmm/v4.0/ahv/config/vms?$limit=1`
  - `/api/dataprotection/v4.0/config/recovery-points?$limit=1`

The new testbed exposes v4.0 and v4.1, but not v4.2. The implementation should
select the highest compatible v4 revision per namespace, then record the chosen
revision in the manifest.

### v4 inventory normalization

The current normalizer can select a v4 VM from `.data[]`, but it does not fully
normalize newer v4 field names.

Required additions:

- firmware:
  - `bootConfig.$objectType == vmm.v4.ahv.config.UefiBoot` -> `efi`
  - `bootConfig.$objectType == vmm.v4.ahv.config.LegacyBoot` -> `bios`
- secure boot:
  - `bootConfig.isSecureBootEnabled`
- vTPM:
  - `vtpmConfig.isVtpmEnabled`
- disk identity and size:
  - `disks[].extId`
  - `disks[].backingInfo.diskExtId`
  - `disks[].backingInfo.diskSizeBytes`
  - `disks[].backingInfo.storageContainer.extId`
  - `disks[].diskAddress.busType`
  - `disks[].diskAddress.index`
- NIC identity:
  - `nics[].backingInfo.macAddress`
  - `nics[].networkInfo.subnet.extId`
  - `nics[].networkInfo.ipv4Config.ipAddress.value`
- CDROM handling:
  - keep using only `disks[]` for migration disks
  - do not treat `cdRoms[]` as migration disks

### v4 capability probing

Current `n2k_source_probe_v4` marks `changed_regions=true` when the Data
Protection recovery point list endpoint returns HTTP 2xx. That is too broad.

The new probe should split capability into:

- `vmm_inventory`: VM list/get works
- `clustermgmt`: cluster list works
- `dp_recovery_points`: recovery point list/create/get APIs are reachable
- `dp_discover_cluster`: PC discover-cluster action is reachable
- `dp_compute_changed_regions`: PE compute-changed-regions action is reachable
- `data_plane`: a usable byte source exists for recovery point disk contents
- `run_host_connectivity`: the actual ABLESTACK host can reach PC and returned
  PE endpoints on port `9440`

Only when all required capability bits are true should `plan` recommend
`v4-incremental`.

### v4 run orchestration

Current `run` supports only:

```text
--source-api v3
```

Required change:

```text
--source-api v4
```

The `v4` flow should mirror the validated v3 flow:

1. create base recovery point
2. build base disk source map
3. sync full disk
4. create incremental recovery point
5. compute changed regions against base
6. patch only changed regions
7. repeat phase2 incremental rounds until deadline criteria are met
8. automatically shut down guest or power off at final cutover boundary
9. create final recovery point
10. compute changed regions against latest incremental reference
11. final patch
12. cutover define/start

## Proposed v4 source adapter design

### API version selection

Add a namespace-aware version resolver:

```text
n2k_nutanix_v4_select_revision <namespace> <pc> <username> <password> <insecure>
```

Initial candidates:

| Namespace | Candidate order |
| --- | --- |
| `vmm` | `v4.1`, `v4.0` |
| `dataprotection` | `v4.1`, `v4.0` |
| `clustermgmt` | `v4.0` |

`v4.2` should be probeable but not preferred until an environment is available
where the endpoint is actually open. The selected revisions should be recorded:

```json
{
  "source": {
    "api": {
      "selected": "v4",
      "v4": {
        "vmm_revision": "v4.1",
        "dataprotection_revision": "v4.1",
        "clustermgmt_revision": "v4.0"
      }
    }
  }
}
```

### Recovery point creation

Implement:

```text
n2k_source_v4_create_recovery_point
n2k_source_v4_wait_recovery_point
n2k_source_v4_get_recovery_point
n2k_source_v4_delete_recovery_point
```

The SDK documentation exposes `create_recovery_point`, `get_recovery_point_by_id`,
`get_vm_recovery_point_by_id`, and `delete_recovery_point_by_id`. The shell
implementation should use raw REST calls but keep payloads compatible with the
documented model names.

The manifest must normalize:

- top-level recovery point extId
- VM recovery point extId
- disk recovery point extId per VM disk
- recovery point creation time and expiration time
- source VM extId
- disk extId and disk size

### Changed regions

Official v4 changed-region retrieval is a two-step operation:

1. PC discover-cluster action for a recovery point operation.
2. PE compute-changed-regions action using the JWT returned by the first call.

Implement:

```text
n2k_source_v4_discover_changed_regions_cluster
n2k_source_v4_compute_changed_regions
n2k_source_v4_collect_changed_regions
```

The PC call should use operation `COMPUTE_CHANGED_REGIONS`. The PE call should
use the returned PE IP and send the JWT as:

```text
Cookie: NTNX_IGW_SESSION=<jwt>
```

The collector must support pagination/streaming:

- request `offset`, `length`, and `blockSizeByte`
- collect up to the server limit
- read `nextOffset` from response metadata
- continue until `nextOffset` is absent or `0`
- preserve zero-region markers so the writer can skip or punch holes

### Data plane

Changed-region metadata alone is not enough; `n2k` also needs bytes for the
base disk and changed regions.

Design decision:

- Treat v4 changed regions as the metadata/control plane.
- Add a separate v4-compatible data-plane capability bit.
- Prefer an official v4 recovery point disk content/export API if it is
  confirmed in the environment.
- If no official byte-stream endpoint is available, use one of these data-plane
  options behind a clearly named adapter:
  - recovery point clone/proxy VM hotplug
  - PE/CVM snapshot file access
  - existing v3/NFS source map if the v4 recovery point can be correlated to a
    readable container path

The plan must not report `v4-incremental` as fully runnable until both metadata
and data-plane paths are verified.

### Run-host connectivity preflight

Add a preflight command path that can run from the ABLESTACK host context:

```text
ablestack_n2k preflight --pc 10.10.132.100 --source-api v4 --check-connectivity
```

Required checks:

- PC `9440` reachable from the host where `n2k` runs
- selected PE `9440` reachable from the same host after discover-cluster
- NFS or clone/proxy data-plane endpoint reachable if used
- authentication failure reported separately from connection failure
- timeout configured, so a down Prism Gateway does not hang `init`

The 10.10.132.100 testbed showed why this matters: v4 endpoints were initially
available from the workstation, but later `9440` refused connections, and
`10.10.22.1` could not use the PC as a source endpoint during `init`.

## Implementation phases

## Implementation update - 2026-05-15

Implemented the safe foundation for Phase A and part of Phase B:

- v4 namespace revision selection now prefers `v4.1` and falls back to `v4.0`
  for VMM and Data Protection.
- Cluster Management v4 probing uses `v4.0`.
- API calls now have configurable curl timeout guards:
  - `N2K_NUTANIX_CONNECT_TIMEOUT`, default `10`
  - `N2K_NUTANIX_MAX_TIME`, default `120`
- v4 VM inventory normalization supports the observed Ganges/AOS 7.3 field
  layout:
  - `bootConfig.$objectType`
  - `bootConfig.isSecureBootEnabled`
  - `vtpmConfig.isVtpmEnabled`
  - `disks[].backingInfo.diskExtId`
  - `disks[].backingInfo.diskSizeBytes`
  - `disks[].backingInfo.storageContainer.extId`
  - `nics[].backingInfo.macAddress`
  - `nics[].networkInfo.subnet.extId`
- v4 probe output records selected namespace revisions and HTTP probe status.
- v2/v3 fallback order is preserved after v4 attempts.
- `plan` now requires a verified v4 recovery-point data plane before treating
  `v4-incremental` as runnable. The CLI includes `--v4-data-plane <0|1>` only
  as an explicit fixture/test override.

Validation results:

- Legacy PC `10.10.131.11` API inventory smoke still passed for `rhel`.
- v4 PC `10.10.132.100` API inventory smoke passed for `rhel`.
- v4 PC selected revisions:
  - VMM: `v4.1`
  - Data Protection: `v4.1`
  - Cluster Management: `v4.0`
- v4 fixture smoke covers UEFI secure boot and Legacy BIOS VM inventory shapes.
- Host-side connectivity from `10.10.22.1` to `10.10.132.100:9440` and
  `10.10.131.11:9440` passed.
- Full PC `10.10.132.100` inventory matrix passed with `init --inventory-source api`:

| VM | Firmware | Secure Boot | vTPM | CPU | Memory MiB | Disks | First Bus | First Size Bytes | NICs |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `rhel` | `efi` | true | false | 1 | 4096 | 1 | SCSI | 107374182400 | 1 |
| `win10` | `efi` | true | false | 4 | 4096 | 1 | SCSI | 107374182400 | 1 |
| `centos7-bios-ide` | `bios` | false | false | 1 | 4096 | 1 | IDE | 107374182400 | 1 |
| `PC-NameOption-1` | `bios` | false | false | 6 | 28672 | 7 | SCSI | 15728640 | 2 |
| `windows11` | `efi` | true | true | 4 | 16384 | 1 | SCSI | 107374182400 | 1 |

- PC `10.10.132.100` plan matrix detected v4 VMM, Data Protection, Cluster
  Management, and changed-region control-plane availability on all observed VMs,
  with revisions `v4.1`, `v4.1`, and `v4.0`. Because the v4 data plane is still
  `false`, automatic planning selected `manual-disk`, and explicit
  `--mode v4-incremental` returned `can_run=false`.

Additional Recovery Point PoC results:

- Data Protection v4 create/delete requests require `NTNX-Request-Id`.
- `POST /api/dataprotection/v4.1/config/recovery-points` accepted the minimal
  VM Recovery Point payload:
  - `name`
  - `expirationTime`
  - `vmRecoveryPoints[].vmExtId`
- Create and delete both return Prism task references. The create task's
  `completionDetails` includes `recoveryPointExtId`, which is more reliable than
  resolving the new Recovery Point by list/name.
- `GET /api/dataprotection/v4.1/config/recovery-points/{extId}` works.
- `GET /api/dataprotection/v4.1/config/recovery-points/{rpExtId}/vm-recovery-points/{vmRpExtId}`
  works.
- A live `rhel` Recovery Point produced:
  - top-level Recovery Point extId
  - VM Recovery Point extId
  - three disk recovery point identifiers
  - source VM disk correlation for the primary vDisk through `diskExtId`
- Delete cleanup completed successfully through the returned delete task.

Additional changed-region PoC results:

- PC `discover-cluster` works for `COMPUTE_CHANGED_REGIONS` when the request body
  includes:
  - top-level `$objectType`:
    `dataprotection.v4.content.ClusterDiscoverSpec`
  - `spec.$objectType`:
    `dataprotection.v4.content.ComputeChangedRegionsClusterDiscoverSpec`
  - VM disk references with `$objectType`:
    `dataprotection.v4.content.VmDiskRecoveryPointReference`
- PC `10.10.132.100` returned PE `10.10.132.10`, a JWT, and a redirection link
  for the PE compute call.
- The PE compute call is not yet runnable in this environment:
  - v4.1 discover returns a v4.1 redirection URL, but the JWT scope is
    `/api/dataprotection/v4.0/content`; PE returns HTTP `401` with
    `Scope claim value does not match API base path`.
  - v4.0 discover returns a v4.0 redirection URL with matching JWT scope, but PE
    returns HTTP `404` for the v4.0 content endpoint.
- Therefore `data_plane=false` remains correct, and `v4-incremental` must stay
  blocked until the PE content API revision/scope mismatch is resolved.

The run data plane for official v4 recovery points remains an open item. The
current implementation improves API detection, inventory, and path selection,
while deliberately blocking v4 incremental runs until recovery-point disk bytes
are verified. The already validated v3/NFS source path remains the runnable
migration path.

### Phase A - Safe v4 inventory readiness

Deliverables:

- v4 revision resolver
- v4.1-aware VM inventory fetch
- v4 inventory normalizer field additions
- fixtures captured from the 10.10.132.100 environment
- unit tests for:
  - UEFI secure boot VM
  - Legacy BIOS VM
  - nested v4 disk size and storage container fields
  - nested v4 NIC MAC/subnet fields

Acceptance:

- `init --inventory-source api` works for `rhel`, `win10`,
  `centos7-bios-ide`, and `windows11` when PC `9440` is reachable.
- Manifest disks have non-zero `size_bytes`.
- UEFI and secure boot are detected from v4 fields.
- CDROM entries are excluded.

### Phase B - v4 capability and preflight accuracy

Deliverables:

- capability JSON separates VMM, DP list/create, changed-region discover,
  changed-region compute, data plane, and run-host connectivity
- `plan` recommends `v4-incremental` only when all required bits are true
- timeout and error classification for refused/unreachable PC

Acceptance:

- 10.10.132.100 reports v4 VMM/DP available when service is up.
- If `9440` is refused, `plan` returns a connection failure and chooses a safe
  fallback or blocked state instead of hanging.
- The previous 10.10.131.11 environment still falls back to v3/v2 inventory.

### Phase C - v4 recovery point PoC

Deliverables:

- create/list/get/delete recovery point through v4 Data Protection
- recovery point manifest model
- cleanup safety for test recovery points

Acceptance:

- base and incremental recovery points can be created for a small test VM.
- Each VM disk maps to a v4 disk recovery point extId.
- Recovery points are cleaned up or expire according to policy.

Status: implemented and live-validated for `rhel` on PC `10.10.132.100`.

### Phase D - v4 changed-region PoC

Deliverables:

- PC discover-cluster action
- PE compute-changed-regions action
- JWT cookie handling
- pagination/streaming collector
- normalized changed-region schema reused by the existing patch writer

Acceptance:

- base recovery point alone returns full changed-region coverage.
- incremental recovery point against base returns only changed regions.
- zero-region metadata is preserved.

Status: PC discover-cluster is live-validated. PE compute is blocked by the
observed JWT scope/API revision mismatch and remains open.

Additional validation on 2026-05-16:

- A new `rhel` recovery point was created and cleaned up through v4.1.
- PC `discover-cluster` succeeded for `v4.1`, `v4.0`, and `v4.0.b1`.
- Every successful discover response returned PE `10.10.132.10`.
- The returned JWT scope was consistently:
  `/api/dataprotection/v4.0/content`
- PE compute path results:
  - `/api/dataprotection/v4.1/content/.../$actions/compute-changed-regions`
    returned HTTP `401`, `Scope claim value does not match API base path`.
  - `/api/dataprotection/v4.0/content/.../$actions/compute-changed-regions`
    returned HTTP `404`.
  - `/api/dataprotection/v4.0.b1/content/.../$actions/compute-changed-regions`
    returned HTTP `401`, also due API base path/scope mismatch.
- The code now decodes the discover JWT scope and prefers that content revision
  for the PE compute call. This makes newer or correctly aligned environments
  runnable without hard-coding the PC config API revision as the PE content API
  revision.
- Because this testbed still returns `v4.0` scope with no matching PE content
  route, `data_plane=false` and v4 incremental blocking remain correct for
  PC132.

Endpoint variant validation on 2026-05-16:

- PC `config` list endpoints remain reachable:
  - `/api/dataprotection/v4.0/config/recovery-points?$limit=1` -> HTTP `200`
  - `/api/dataprotection/v4.1/config/recovery-points?$limit=1` -> HTTP `200`
- PE `10.10.132.10` does not expose generic v4 Data Protection list roots:
  - `/api/dataprotection/v4.0/content` -> HTTP `404`
  - `/api/dataprotection/v4.1/content` -> HTTP `404`
  - `/api/dataprotection/v4.0/config/recovery-points?$limit=1` -> HTTP `404`
  - `/api/dataprotection/v4.1/config/recovery-points?$limit=1` -> HTTP `404`
- Exact PE compute endpoint variants were tested with a live `rhel` recovery
  point and then cleaned up:
  - v4.0 `$actions` and `%24actions` paths -> HTTP `404`
  - v4.1 `$actions` path -> HTTP `401`, scope/base-path mismatch
  - paths without `/api` -> HTTP `404`
  - paths without `$actions` -> HTTP `404`
  - `Authorization: Bearer <JWT>` on v4.1 -> HTTP `403`
  - lowercase `cookie` header behaves the same as `Cookie`
  - PC content POST on the v4.0 compute path -> HTTP `501`
- Current conclusion: this is not a shell URL escaping or header casing bug in
  `n2k`. PC132 returns a JWT scoped to `v4.0` content while the PE only shows a
  routable compute action at the `v4.1` base path, where the JWT is rejected.
  Treat this as an environment/product API alignment issue unless Nutanix
  provides a different supported PE content endpoint or cluster setting.
- `n2k_source_probe_v4` now reports v4 recovery point config APIs separately
  from changed-region compute/data-plane readiness. A reachable recovery point
  list endpoint no longer implies `changed_regions=true`.

### Phase E - v4 data-plane and E2E

Deliverables:

- confirmed byte source for v4 recovery point disk contents
- `run --source-api v4 --split phase1/phase2/full`
- RBD, qcow2, and block/LVM target coverage reusing the already validated target
  adapters

Acceptance:

- `rhel` v4 Phase1/Phase2 E2E passes.
- one Windows VM v4 Phase1/Phase2 E2E passes.
- one full one-shot v4 E2E passes.
- v3 fallback remains functional.

## Open items

1. Keep Prism Gateway on `10.10.132.100:9440` under observation during live
   testing. It recovered and passed host-side connectivity checks, but earlier
   probes saw TCP connection refused.
2. Repeat host-side reachability checks from `10.10.22.2` and `10.10.22.3`
   before using either host for v4 source operations. `10.10.22.1` has already
   reached `10.10.132.100:9440` successfully.
3. Confirm the official or supported byte-stream data plane for v4 recovery
   point disks. Changed-region APIs identify what changed, but `n2k` still needs
   a reliable way to read the corresponding bytes.
4. Resolve the PC132 changed-region compute mismatch:
   - v4.1 redirection with v4.0 JWT scope returns HTTP `401`.
   - v4.0 redirection with matching scope returns HTTP `404`.
   - v4.0.b1 content path also returns HTTP `401` because its base path does
     not match the JWT scope.
   - This must be resolved before setting v4 `changed_regions` and `data_plane`
     to fully runnable for E2E.
5. Decide whether v4.1 should become the default preferred revision when both
   v4.1 and v4.0 are available. Based on this environment, v4.1 is available and
   v4.2 is not.

## References

- Nutanix v4 API/SDK GA announcement:
  `https://www.nutanix.com/blog/announcing-the-v4-api-and-sdk-general-availability-in-pc-2024-3-aos-7-0`
- Nutanix v4 changed-region flow:
  `https://www.nutanix.dev/2025/01/15/nutanix-v4-disaster-recovery-api-series-part-2-changed-blocks-tracking-cbt-and-changed-regions-tracking-crt/`
- Nutanix Data Protection SDK recovery point API:
  `https://developers.nutanix.com/api/v1/sdk/namespaces/main/dataprotection/versions/v4.0/languages/python/ntnx_dataprotection_py_client.api.recovery_points_api.html`
