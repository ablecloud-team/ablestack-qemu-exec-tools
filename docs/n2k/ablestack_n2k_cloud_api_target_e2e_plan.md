# ablestack_n2k ABLESTACK Cloud API target E2E test plan

## Purpose

This document defines the E2E test plan for the new `ablestack-cloud` target
provider in `ablestack_n2k`.

The goal is to validate that n2k can keep the proven Nutanix v3 snapshot/NFS
data path and replace the final target VM creation path with ABLESTACK Cloud
API calls:

```text
Nutanix snapshot data path
  -> n2k disk sync into target storage
  -> Cloud API listVolumesForImport/importVolume
  -> deployVirtualMachineForVolume
  -> attachVolume for data disks
  -> startVirtualMachine
```

This document is also the result ledger. Update every case with `PASS`, `FAIL`,
or `BLOCKED` after execution.

## Environment

Source Nutanix environment:

- Prism Central: `https://10.10.132.100:9440`
- Expected source data path: PC v4 discovery with PE v3 fallback, or forced v3
  path when the case requires deterministic source behavior.
- Prism user: `admin`
- Prism password: do not store in this repository or this document.

ABLESTACK Cloud management endpoint:

- API endpoint: `http://10.10.22.10:8080/client/api`
- Admin API key and secret key: use runtime-only environment variables or a
  protected local credential file. Do not store them in this repository or this
  document.
- API signature mode: `HmacSHA256`.

ABLESTACK target hosts:

- `10.10.22.1`
- `10.10.22.2`
- `10.10.22.3`
- SSH port: `10022`
- SSH user: `root`
- SSH password: do not store in this repository or this document.

Build baseline for this plan:

- Source branch: `feature/ablestack_n2k`
- Source commit: record the current commit before each execution.
- RPM build path:
  `/root/work/ablestack-qemu-exec-tools/build/rpm-n2k/ablestack_n2k-0.8.0-1.el9.el9.noarch.rpm`

## Cloud resource candidates

The following candidates were observed through the 22.x Cloud API on
2026-05-18. Reconfirm them before the first destructive E2E run because Cloud
resources can be changed outside n2k.

### Zone

| Name | ID |
| --- | --- |
| `Zone-22` | `d5551005-3372-43e5-8a2b-5742057bbabd` |

### Service offerings

The service offering is selected by `--cloud-service-offering-id` and is passed
to `deployVirtualMachineForVolume` as `serviceofferingid`.

| Name | ID | Notes |
| --- | --- | --- |
| `NoLimit-HA-WB` | `49b2a775-4dba-4b4b-8f92-554b111898bf` | Candidate for broad VM sizing |
| `CKS Instance` | `2c9b5a3e-ab94-4480-9c28-ddd1b26dc486` | 2 vCPU, 2048 MiB |
| `2Core 4GB - 16Core 32GB` | `a9745a6a-3732-43fd-8108-b8c255d8505b` | Candidate for Windows or larger Linux guests |
| `1C1GB-4C4GB` | `a9ca78f7-0e28-4a4e-b71d-3bb857fe49f0` | Candidate for small Linux guests |

Before running a case, choose one service offering and record it in the case
result. If the offering requires custom CPU or memory parameters that n2k does
not yet pass, stop and record the case as `BLOCKED` before modifying the engine.

### Networks

The network is selected by `--cloud-network-id` or `--cloud-network-ids` and is
passed to `deployVirtualMachineForVolume` as `networkids`.

| Name | ID | Type |
| --- | --- | --- |
| `L2-Network` | `fa2d6e6c-0003-4ab0-92a2-e3e41c9ccbac` | L2 |
| `L2-Network-ConfigDrive` | `2e352b75-962d-485c-b6ca-0674bf802b8c` | L2 |
| `isolated-network` | `41bd6bbf-ef3a-4791-9718-1d33d6189e7a` | Isolated |
| `WESTPAC-Net` | `ece83230-0af2-4439-a771-b8338a98f008` | Isolated |
| `foms-network` | `ff527c13-8d5b-44c8-9579-504ecada482c` | Isolated |

Recommended first pass: use `L2-Network` unless the test explicitly needs an
isolated network. The current Cloud target implementation selects the Cloud
network but does not yet force the original Nutanix NIC MAC address or IP
address. For this test pass, success means the VM is attached to the selected
Cloud network and boots. If exact MAC/IP preservation becomes mandatory, stop
and create a separate design before changing code.

### Primary storage

The import target storage is selected by `--cloud-storage-id` and is passed to
`listVolumesForImport` and `importVolume` as `storageid`.

| Name | ID | Type | Path |
| --- | --- | --- | --- |
| `Primary Storage Glue RBD` | `91cae554-3fce-3f93-89d1-cefaf9bf8122` | RBD | `rbd` |
| `ablecube22-1-local-4e929594` | `4e929594-99f4-4846-add9-bdf49cf71587` | Filesystem | `/var/lib/libvirt/images` |
| `ablecube22-2-local-aa5cf314` | `aa5cf314-1246-42b5-9783-4f1a3c1e1d19` | Filesystem | `/var/lib/libvirt/images` |
| `ablecube22-3-local-a872e82e` | `a872e82e-3f49-410e-a743-25ea04484fd1` | Filesystem | `/var/lib/libvirt/images` |

Required first target backend for this plan: RBD.

Filesystem and SharedMountPoint primary storage migrations must create the
qcow2 files directly under the selected Cloud storage pool path returned by
`listStoragePools`. n2k must not assume `/var/lib/libvirt/images`; that path is
valid only when it is the selected Cloud storage pool path. Host-local
Filesystem storage also requires the VM placement host to match the selected
storage, while cluster-scoped SharedMountPoint storage uses the shared mount
path and does not need a host id for file placement.

The 10.10.1.x SharedMountPoint test found a bug where n2k wrote qcow2 files
under `/var/lib/libvirt/images` even though the selected Cloud storage pool path
was `/mnt/glue-gfs`. That behavior is invalid and is superseded by
`docs/n2k/ablestack_n2k_cloud_storage_path_design.md`.

Filesystem import behavior was rechecked on 2026-05-19:

- `listVolumesForImport` accepts a file placed directly under the selected
  Cloud storage pool path when `path` is either the basename or the absolute
  `<storage-pool-path>/<file>.qcow2`.
- `listVolumesForImport` rejects files in a subdirectory under the selected
  Cloud storage pool path with HTTP 530.
- Therefore FileSystem/SharedMountPoint tests must write target qcow2 files
  directly under the selected Cloud storage pool path and must use
  `--target-map-json` or the wizard-generated map to avoid generic names such
  as `rhel-disk0.qcow2`.
- When `--cloud-disk-offering-id` is omitted, n2k must use or create its own
  visible writeback disk offering for the selected storage pool type. This
  avoids Cloud's implicit default import offering and prevents RBD-tagged
  offerings from being reused for local FileSystem imports.

LVM/block is out of scope for the current Cloud target test pass and should be
treated as a next version topic.

### Disk offerings

The disk offering can be overridden by `--cloud-disk-offering-id`. When it is
omitted, n2k resolves the selected Cloud storage pool and automatically uses or
creates an n2k-managed writeback offering, then passes that offering to
`importVolume` as `diskofferingid`.

| Name | ID | Notes |
| --- | --- | --- |
| `N2K Migration Writeback` | auto-created | Customized, untagged, `storagetype=shared`, `cachemode=writeback`; default for RBD/shared pools |
| `N2K Migration Writeback Local` | auto-created | Customized, untagged, `storagetype=local`, `cachemode=writeback`; default for host-local pools |
| `Custom1` | `1da3a4e3-3a1a-4afd-bd28-19df910b334a` | Customized, tag `rbd`; use for RBD tests only |
| `FTCTL Internal Root Disk` | `bf9b2567-abe0-420b-bdba-44c8779232f0` | Internal candidate, not preferred for n2k |
| `FTCTL Internal Data Disk` | `20de1c04-f650-4900-af23-34567bfe2fa9` | Internal candidate, not preferred for n2k |

The n2k-managed offerings must be active, customized, untagged, and
`cachemode=writeback`. If a same-name offering exists with incompatible
properties, n2k must fail before `importVolume` so the operator can fix or delete
the conflicting offering. Explicit `--cloud-disk-offering-id` remains available
for compatibility and emergency override tests.

For C04-C06 FileSystem/local storage cases, the normal path should omit
`--cloud-disk-offering-id` and verify that n2k resolves
`N2K Migration Writeback Local`.

### Optional host placement

`--cloud-host-id` is optional and is passed as `hostid` only when provided.

| Host | ID | State |
| --- | --- | --- |
| `ablecube22-1` | `34ada5ae-05cd-42f2-92a7-71f462da6a2e` | Up |
| `ablecube22-2` | `56a141bf-4119-4bae-8599-ce8583a5b1e6` | Up |
| `ablecube22-3` | `0132ec7b-055b-44e2-b8a8-62bcc58c81e4` | Up |

Initial tests should omit host placement unless a case specifically validates
host selection.

## Scope

Source VMs:

| VM | Expected migration disks | Purpose |
| --- | ---: | --- |
| `rhel` | 3 | Linux UEFI, multi-disk attach validation |
| `win10` | 2 | Windows, multi-disk attach validation |
| `centos7-bios-ide` | 1 | Linux BIOS/IDE compatibility |

Excluded source VM:

| VM | Reason |
| --- | --- |
| `windows11` | Not in a normal running state in the current PC132 testbed |

If `rhel` does not expose exactly 3 migration disks, or `win10` does not expose
exactly 2 migration disks, stop the case and record it as `BLOCKED`.

## Global execution policy

Run one case at a time.

Before each case:

1. Confirm the source VM is `ON`.
2. Confirm there is no conflicting target VM in ABLESTACK Cloud.
3. Confirm there is no stale target RBD image with the case prefix.
4. Confirm no stale Nutanix `n2k-*` source snapshot remains from a previous
   case unless it is intentional failure evidence.
5. Confirm the selected zone, service offering, network, storage, and optional
   disk offering still exist.
6. Export all credentials at runtime only.

During cutoff:

- Use `--shutdown guest`.
- Use `--apply --start` for positive E2E cases.
- Use `--target-provider ablestack-cloud`.
- Do not manually enter source VM CPU, memory, firmware, or disk controller
  details. n2k must derive them from the source inventory and pass them to the
  Cloud deploy API.
- Use the Cloud CPU speed detail default of `1000` unless a case explicitly
  sets `--cloud-cpu-speed`.
- Expect root `importVolume` to create a detached `DATADISK` first. After
  `deployVirtualMachineForVolume`, n2k must verify the attached root volume and
  use `updateVolume type=ROOT` when the Cloud API leaves the imported boot disk
  as `DATADISK`.
- Do not pass a template ID for the current ABLESTACK Cloud build. The
  `ablestack-diplo` API does not expose `templateid` on
  `deployVirtualMachineForVolume`; its management server uses the KVM import
  dummy template internally.
- Use RBD first:
  - `--target-storage rbd`
  - `--target-format raw`
  - `--dst "rbd:rbd/${RBD_PREFIX}"`
  - `--cloud-storage-id 91cae554-3fce-3f93-89d1-cefaf9bf8122`
- Omit `--cloud-disk-offering-id` for the normal RBD pass and verify that n2k
  resolves `N2K Migration Writeback`. Use an explicit offering ID only for
  override compatibility cases.
- For FileSystem local storage:
  - Run n2k on the same ABLESTACK host selected by `--cloud-host-id`.
  - Use the matching host-scoped `--cloud-storage-id`.
  - Use `--target-storage file` and `--target-format qcow2`.
  - Use `--dst /var/lib/libvirt/images`.
  - Use `--target-map-json` so every target file is created directly under
    `/var/lib/libvirt/images` with a case-specific basename.
  - Omit `--cloud-disk-offering-id` for the normal path and verify that n2k
    resolves `N2K Migration Writeback Local`.

After each case:

1. Record `manifest.json`, `events.log`, command output, and Cloud VM ID.
2. Confirm `runtime.cloud` records imported volume IDs and async job IDs.
3. Confirm `runtime.cloud.deployment_properties` records derived CPU, default
   CPU speed, memory, boot type/mode, and disk controller parameters when those
   values exist in the source manifest.
4. Confirm the Cloud VM reaches a running state when `--start` is used.
5. Confirm Cloud root disk and data disks match the manifest disk count.
6. Confirm the Cloud VM uses the selected network ID.
7. Confirm Cloud VM details preserve the source shape as closely as the API
   allows:
   - CPU count from `.source.vm.cpu` maps to `cpuNumber`.
   - Memory from `.source.vm.memory_mb` maps to `memory`.
   - EFI/BIOS maps to `boottype` and `bootmode`.
   - Root/data disk controller maps to `rootDiskController` and
     `dataDiskController`.
8. Confirm source VM is `OFF` after successful cutoff.
9. Confirm Nutanix source snapshots were cleaned up after successful cutoff.
10. Stop and destroy the Cloud target VM before reusing the source VM.
11. Power the source VM back on only after the migrated Cloud VM is stopped or
   removed.

Do not run the source VM and migrated Cloud VM at the same time on the same
network.

## Runtime variables

Set these on the target host shell. Values shown as `<runtime-only>` must not be
committed.

```bash
export PC_URL='https://10.10.132.100:9440'
export PC_USER='admin'
export PC_PASS='<runtime-only>'
export N2K_INSECURE='1'

export CLOUD_ENDPOINT='http://10.10.22.10:8080/client/api'
export CLOUD_API_KEY='<runtime-only>'
export CLOUD_SECRET_KEY='<runtime-only>'
export CLOUD_ZONE_ID='d5551005-3372-43e5-8a2b-5742057bbabd'
export CLOUD_STORAGE_ID='91cae554-3fce-3f93-89d1-cefaf9bf8122'
# Optional override only. Normal tests omit this so n2k resolves its writeback offering.
# export CLOUD_DISK_OFFERING_ID='1da3a4e3-3a1a-4afd-bd28-19df910b334a'
export CLOUD_NETWORK_ID='fa2d6e6c-0003-4ab0-92a2-e3e41c9ccbac'
export CLOUD_SERVICE_OFFERING_ID='<select-before-test>'

export N2K_BASE_WORKDIR='/var/lib/ablestack/n2k-e2e/cloud-target'
export N2K_RBD_POOL='rbd'
export N2K_FILE_DST_ROOT='/var/lib/libvirt/images'
```

## Command templates

### Resource/API readiness

```bash
ablestack_n2k --json preflight \
  --pc "${PC_URL}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --target-provider ablestack-cloud \
  --cloud-endpoint "${CLOUD_ENDPOINT}" \
  --cloud-api-key "${CLOUD_API_KEY}" \
  --cloud-secret-key "${CLOUD_SECRET_KEY}" \
  --cloud-zone-id "${CLOUD_ZONE_ID}" \
  --cloud-service-offering-id "${CLOUD_SERVICE_OFFERING_ID}" \
  --cloud-network-id "${CLOUD_NETWORK_ID}" \
  --cloud-storage-id "${CLOUD_STORAGE_ID}" \
  --target-storage rbd
```

### Phase1 command

```bash
ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "rbd:${N2K_RBD_POOL}/${RBD_PREFIX}" \
  --target-storage rbd \
  --target-format raw \
  --target-provider ablestack-cloud \
  --cloud-endpoint "${CLOUD_ENDPOINT}" \
  --cloud-api-key "${CLOUD_API_KEY}" \
  --cloud-secret-key "${CLOUD_SECRET_KEY}" \
  --cloud-zone-id "${CLOUD_ZONE_ID}" \
  --cloud-service-offering-id "${CLOUD_SERVICE_OFFERING_ID}" \
  --cloud-network-id "${CLOUD_NETWORK_ID}" \
  --cloud-storage-id "${CLOUD_STORAGE_ID}" \
  --split phase1 \
  --force-v3
```

### Phase2 cutoff command

```bash
ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  run \
  --split phase2 \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --target-provider ablestack-cloud \
  --cloud-endpoint "${CLOUD_ENDPOINT}" \
  --cloud-api-key "${CLOUD_API_KEY}" \
  --cloud-secret-key "${CLOUD_SECRET_KEY}" \
  --cloud-zone-id "${CLOUD_ZONE_ID}" \
  --cloud-service-offering-id "${CLOUD_SERVICE_OFFERING_ID}" \
  --cloud-network-id "${CLOUD_NETWORK_ID}" \
  --cloud-storage-id "${CLOUD_STORAGE_ID}" \
  --shutdown guest \
  --apply \
  --start \
  --force-v3
```

### Full cutoff command

```bash
ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "rbd:${N2K_RBD_POOL}/${RBD_PREFIX}" \
  --target-storage rbd \
  --target-format raw \
  --target-provider ablestack-cloud \
  --cloud-endpoint "${CLOUD_ENDPOINT}" \
  --cloud-api-key "${CLOUD_API_KEY}" \
  --cloud-secret-key "${CLOUD_SECRET_KEY}" \
  --cloud-zone-id "${CLOUD_ZONE_ID}" \
  --cloud-service-offering-id "${CLOUD_SERVICE_OFFERING_ID}" \
  --cloud-network-id "${CLOUD_NETWORK_ID}" \
  --cloud-storage-id "${CLOUD_STORAGE_ID}" \
  --shutdown guest \
  --apply \
  --start \
  ${MODE_ARGS}
```

## Test matrix

| ID | VM | Source mode | Split | Target backend | Disk offering | Expected result | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C00 | n/a | n/a | n/a | n/a | n/a | Cloud API/resource readiness passes | PASS |
| C01 | `rhel` | forced v3 | Phase1/Phase2 | RBD | Provided | Cloud VM starts, 3 disks imported/attached | PASS |
| C02 | `win10` | auto fallback | Full | RBD | Provided | Cloud VM starts, 2 disks imported/attached | PASS |
| C03 | `centos7-bios-ide` | forced v3 | Full | RBD | Provided | Cloud VM starts, BIOS/IDE guest boots | PASS |
| C04 | `rhel` | forced v3 | Phase1/Phase2 | FileSystem/qcow2 | Omitted | Cloud VM starts from 22.1 local qcow2 with 3 disks | PASS |
| C05 | `win10` | auto fallback | Full | FileSystem/qcow2 | Omitted | Cloud VM starts from 22.2 local qcow2 with 2 disks | PASS |
| C06 | `centos7-bios-ide` | forced v3 | Full | FileSystem/qcow2 | Omitted | Cloud VM starts from 22.3 local qcow2 with BIOS/IDE | PASS |
| N01 | synthetic | n/a | cutover validation | RBD | Any | Missing service offering blocks before import/deploy | PASS |
| N02 | synthetic | n/a | cutover validation | RBD | Any | Missing network blocks before import/deploy | PASS |
| N03 | synthetic | n/a | cutover validation | block/LVM | Any | Cloud target rejects block/LVM as out of scope | PASS |

C04-C06 reuse the same source VMs as C01-C03 but change the target backend from
RBD to host-local FileSystem/qcow2. Before starting C04, remove the previous
C01-C03 Cloud target VMs or otherwise ensure the source VM and migrated target
VM are not running on the same network at the same time. LVM/block Cloud target
testing is explicitly out of scope for this version.

## FileSystem readiness snapshot

Checked on 2026-05-19:

- Cloud APIs required for local storage tests are exposed:
  `listHosts`, `listStoragePools`, `listVolumesForImport`, `importVolume`, and
  `deployVirtualMachineForVolume`.
- Host-scoped FileSystem primary storage pools are `Up` for all three
  ABLESTACK hosts.
- Local storage root `/var/lib/libvirt/images` is present on all three hosts.
  Available capacity at check time was approximately 247 GiB on 22.1, 301 GiB
  on 22.2, and 234 GiB on 22.3.
- Harmless 1 MiB qcow2 probes placed directly under `/var/lib/libvirt/images`
  were visible through `listVolumesForImport` on 22.1, 22.2, and 22.3 when
  queried by basename or absolute path.
- A qcow2 probe placed in a subdirectory under `/var/lib/libvirt/images` was
  rejected by `listVolumesForImport` with HTTP 530, so C04-C06 target files
  must be root-level files, not files under a case directory.
- No C04-C06 Cloud volumes or root-level C04-C06 local qcow2 files were present
  at check time.
- n2k preflight passed for all three FileSystem host/storage pairs:
  C04 on 22.1, C05 on 22.2, and C06 on 22.3. Each preflight selected
  `target.selected_storage=file`, `target.requested_format=qcow2`, and
  `selected_mode=v3-incremental`.
- The previous C01-C03 Cloud target VMs were still running at check time:
  `rhel` / `i-2-384-VM`, `win10` / `i-2-385-VM`, and
  `centos7-bios-ide` / `i-2-386-VM`. Clean these before starting C04-C06, then
  power the corresponding Nutanix source VM back on.

## Case detail

### C00 - Cloud API/resource readiness

Objective:

- Prove API signing and required APIs are still available.
- Prove the selected zone, service offering, network, storage, and optional disk
  offering exist.
- Prove `ablestack_n2k --help` and bash completion expose Cloud target options.

Evidence to record:

- `ablestack_n2k --json preflight ...`
- `ablestack_n2k run --help`
- Selected resource IDs.

Result:

- Status: `PASS`
- Evidence path: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/C00-readiness-20260519`
- Source commit: `a2744fd`
- RPM: `ablestack_n2k-0.8.0-1.el9.el9.noarch`
- Selected Cloud resources:
  - Zone: `Zone-22` / `d5551005-3372-43e5-8a2b-5742057bbabd`
  - Service offering: `NoLimit-HA-WB` / `49b2a775-4dba-4b4b-8f92-554b111898bf`
  - Network: `L2-Network` / `fa2d6e6c-0003-4ab0-92a2-e3e41c9ccbac`
  - Primary storage: `Primary Storage Glue RBD` / `91cae554-3fce-3f93-89d1-cefaf9bf8122`
  - Disk offering at the time: `Custom1` /
    `1da3a4e3-3a1a-4afd-bd28-19df910b334a`; current tests should omit explicit
    disk offering and verify the n2k-managed writeback offering.
- Required Cloud APIs are exposed: `listStoragePools`, `listDiskOfferings`,
  `createDiskOffering`, `listVolumesForImport`, `importVolume`,
  `deployVirtualMachineForVolume`, `attachVolume`, `startVirtualMachine`, and
  `queryAsyncJobResult`.
- Installed help and bash completion expose the Cloud target options.
- Note: an early check on 2026-05-19 saw the PC endpoint refuse TCP 9440, but
  a later C01 retry precheck confirmed both `https://10.10.132.100:9440` and
  `https://10.10.132.10:9440` were responding. Direct PE v3 preflight against
  `https://10.10.132.10:9440` passed for `rhel`, showing 3 disks and
  source-derived properties `cpu=1`, `memory_mb=4096`, `firmware=efi`,
  `secure_boot=true`, and SCSI disk controllers.

### C01 - RHEL Phase1/Phase2 RBD Cloud target

Objective:

- Validate the split migration flow with Cloud API cutoff.
- Validate multi-disk import and attach for 3 disks.
- Validate source snapshot cleanup after successful cutoff.

Execution:

1. Set `VM='rhel'`.
2. Set `RBD_PREFIX='n2k-cloud-c01-rhel'`.
3. Run Phase1 with `--force-v3`.
4. Run Phase2 with `--shutdown guest --apply --start --force-v3`.

Pass criteria:

- Manifest has 3 migration disks.
- `runtime.cloud.deployment_properties` includes CPU, memory, boot, and root/data
  disk controller properties derived from the source manifest where present.
- `runtime.cloud.root_volume_id` is non-empty.
- `runtime.cloud.data_volumes` length is 2.
- Cloud VM is running.
- Cloud VM has 3 volumes.
- Nutanix `n2k-*` source snapshots for this run are removed.

Result:

- Status: `PASS`
- Workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/C01-rhel-phase12-postfix-20260519`
- Latest failed retest workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/C01-rhel-phase12-cpuspeed-20260519`
- Latest clean retest workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/C01-rhel-phase12-clean-20260519-1325`
- Latest failed Cloud VM ID: `4cdaf3d0-1e28-48ad-9d84-348fbd7e3313`
- Latest clean Cloud VM ID: `a88eeff4-d45d-4e18-9720-0283933b0b39`
- Notes:
  - Clean revalidation on 2026-05-19 passed after the root-volume path
    preservation fix was built and deployed to 10.10.22.1/2/3. Previous
    recovered Cloud VM, data volumes, stale C01 RBD images, and source
    snapshots were cleaned before the run. Source `rhel` was powered back on
    before Phase1.
  - Clean Phase1 completed with base snapshot
    `7fe5b0ec-96a4-4899-9b6f-93f1ce09f2ee` and incremental snapshot
    `fc281510-2590-473a-9931-3a5b82fd68b3`. Disk sync covered one 100 GiB
    root disk and two 10 GiB data disks. Phase1 incremental changed regions
    were 24 regions / 262144 bytes on disk0 and 0 on disk1/disk2.
  - Clean Phase2 with `--shutdown guest --apply --start --force-v3` completed.
    Phase2 incremental snapshot `4afaac21-656e-4ae1-8b94-daf41ab227a2`
    applied 7 regions / 86016 bytes. Guest shutdown via ACPI completed and
    source `rhel` reached `OFF`. Final snapshot
    `76e75a39-7948-4aed-98c9-51fdb6a9123d` applied 42 regions / 541184 bytes
    across all three disks.
  - Cloud deploy succeeded. VM `a88eeff4-d45d-4e18-9720-0283933b0b39`
    (`i-2-384-VM`) is `Running` on `ablecube22-3`. Service offering is
    `NoLimit-HA-WB`; effective shape is `cpuNumber=1`, `cpuSpeed=1000`, and
    `memory=4096`.
  - Cloud volume verification passed: root volume
    `c3720eec-b1d7-4752-8f15-3942ae0de034` is type `ROOT`, device 0, size
    100 GiB, and path `n2k-cloud-c01-rhel-clean-20260519-disk0`. Data volumes
    `2f4b5ea6-66b0-4a07-a450-cc8e681fb3c5` and
    `da5be1d8-95b1-4a68-93b6-f59aa8598299` are type `DATADISK`, devices 1 and
    2, size 10 GiB each, with paths
    `n2k-cloud-c01-rhel-clean-20260519-disk1` and
    `n2k-cloud-c01-rhel-clean-20260519-disk2`.
  - Host 22.3 verification passed: libvirt domain `i-2-384-VM` is `running`
    and uses `/dev/rbd/rbd/n2k-cloud-c01-rhel-clean-20260519-disk0`,
    `/dev/rbd/rbd/n2k-cloud-c01-rhel-clean-20260519-disk1`, and
    `/dev/rbd/rbd/n2k-cloud-c01-rhel-clean-20260519-disk2`.
  - Successful cutoff cleaned all four Nutanix source snapshots created by the
    run. Follow-up PE snapshot query returned no matching n2k snapshots.
  - Observation: PC v3 inventory reported source `rhel` disk_count 4 while the
    PE-selected manifest exposed 3 migration disks. The extra tiny
    SelfServiceContainer snapshot file was not mapped to a manifest disk and
    was skipped. C01 pass criteria remain based on the 3 manifest migration
    disks.
  - Non-blocking host observation: 22.3 Cloud agent logged a failed
    `rbd image-cache invalidate` command because that rbd CLI subcommand form
    is unsupported in the host build, but the VM remained running and disk
    attach verification passed.
  - Retry precheck confirmed PC and PE API reachability, no conflicting Cloud
    VM, no stale C01 RBD image, and source `rhel` in `ON` state with 3 disks.
  - Phase1 passed. Base and incremental v3 VM snapshots were created, RBD
    target images `n2k-cloud-c01-rhel-disk0/1/2` were populated, and changed
    regions were applied.
  - Phase2 incremental loop, guest shutdown, final snapshot, and final sync
    passed. Source `rhel` reached `OFF`.
  - Cloud `importVolume` succeeded for all 3 disks. Imported volumes were left
    in `Ready` state after the deploy failure.
  - Cloud `deployVirtualMachineForVolume` failed because map-style parameters
    such as `details[0].cpuNumber` were URL-encoding bracket characters in the
    signed query, causing CloudStack signature verification to return 401.
  - Follow-up fix: keep Cloud API parameter keys literal while URI-encoding
    values, and run curl with globbing disabled. The signature smoke then
    advanced from 401 to the expected fake-volume validation error 431, proving
    signature verification passed.
  - Fixed RPM was deployed and C01 was retried. Phase1 passed again, and Phase2
    passed through incremental sync, guest shutdown, final sync, and Cloud
    `importVolume` for all 3 disks.
  - Cloud `deployVirtualMachineForVolume` now reaches Cloud validation but
    returns error 431: `Invalid CPU speed value, specify a value between 1 and
    2147483647`.
  - The selected service offering `NoLimit-HA-WB`
    (`49b2a775-4dba-4b4b-8f92-554b111898bf`) is customized and returns null
    `cpunumber`, `cpuspeed`, and `memory` from `listServiceOfferings`.
    Therefore Cloud requires a CPU speed detail in addition to the source CPU
    count and memory details.
  - Current C01 state after this failure: source `rhel` is `OFF`, Cloud VM was
    not created, imported Cloud volumes and target RBD images remain for
    evidence/cleanup.
  - Follow-up implementation direction: n2k now defaults Cloud `cpuSpeed` to
    `1000`, exposes `--cloud-cpu-speed`, and verifies after
    `deployVirtualMachineForVolume` that the imported root volume was converted
    from detached `DATADISK` to attached `ROOT`. The current Cloud API does not
    expose a `templateid` parameter; ABLESTACK Cloud internally uses the KVM
    import dummy template for this flow.
  - Retest after the CPU speed/root-volume validation build was deployed did
    not pass. The command intentionally omitted `--cloud-cpu-speed` and the
    manifest deployment properties included default
    `details[0].cpuSpeed=1000`. Phase1, Phase2 incremental sync, guest
    shutdown, final snapshot, final sync, and root `importVolume` completed.
  - `deployVirtualMachineForVolume` created VM
    `4cdaf3d0-1e28-48ad-9d84-348fbd7e3313` and attached imported volume
    `7975dfec-e0b5-4b31-9895-92594ffea0e5`, but `listVolumes` still reported
    that volume as `DATADISK` with `deviceid=0`. n2k failed fast with
    `Cloud root volume was not converted to ROOT`.
  - A subsequent `startVirtualMachine` call also failed from Cloud with
    `Unable to deploy VM [4cdaf3d0-1e28-48ad-9d84-348fbd7e3313] because the
    ROOT volume is missing.`
  - Residual cleanup was completed after the failed retest: the Cloud VM was
    destroyed, the imported Cloud root volume was deleted, RBD images
    `n2k-cloud-c01-rhel-disk0/1/2` were removed, Nutanix VM snapshots
    `8e3ceada-d00c-4d35-ba96-9b39eac95838`,
    `9f30a649-e850-4f9e-853d-5aadab2bed53`,
    `b623c38c-3873-4e63-9449-266a3b7d8647`, and
    `d9050208-5417-423b-8688-c677a0f7c892` were deleted and verified as 404,
    and source `rhel` was powered back on.
  - Code inspection of `UserVmManagerImpl.createVirtualMachineVolume` shows the
    imported volume is assigned `deviceId=0` and the dummy template ID, but its
    `volume_type` is not changed to `ROOT`. `listApis` also shows that
    `updateVolume` exposes a `type` parameter, and
    `VolumeApiServiceImpl.updateVolume` applies it through
    `volume.setVolumeType(...)`. The next n2k build will use that API as a
    post-deploy root-volume correction before data-disk attach/start.
  - During the first post-fix C01 retry, 22.3 Cloud agent logs showed the VM
    still could not start because the ROOT volume path was `null`:
    `Failed to find volume:null` followed by a `NullPointerException`.
    This was not an RBD lock or watcher issue. The root-volume correction must
    call `updateVolume` with both `type=ROOT` and the original import `path` so
    Cloud does not clear the path before sending `StartCommand` to the agent.
  - Code was updated, built, pushed, and deployed to 10.10.22.1/2/3 so the
    root-volume correction now preserves the import path. The existing broken
    Cloud VM was repaired by calling `updateVolume` with
    `type=ROOT,path=n2k-cloud-c01-rhel-rootfix2-disk0`, after which
    `startVirtualMachine` succeeded.
  - Final recovery evidence: Cloud VM
    `bb4b9784-2453-4c07-b50f-916446e199e9` is `Running` on host
    `ablecube22-2` as `i-2-383-VM`; libvirt reports the domain `running`; qemu
    is using `/dev/rbd/rbd/n2k-cloud-c01-rhel-rootfix2-disk0/1/2`; all three
    RBD images have a single watcher and exclusive lock from `100.100.22.2`.

### C02 - Win10 full RBD Cloud target with auto fallback

Objective:

- Validate auto source route selection after the PC132 upgrade state.
- Validate Windows multi-disk import and attach for 2 disks.

Execution:

1. Set `VM='win10'`.
2. Set `RBD_PREFIX='n2k-cloud-c02-win10'`.
3. Run full cutoff command with `MODE_ARGS=''`.

Pass criteria:

- Plan/preflight records selected v3 fallback or another explicitly validated
  runnable source path.
- Manifest has 2 migration disks.
- `runtime.cloud.deployment_properties` includes Windows source CPU, memory,
  boot, and root/data disk controller properties where present.
- `runtime.cloud.root_volume_id` is non-empty.
- `runtime.cloud.data_volumes` length is 1.
- Cloud VM is running.
- Source snapshots are cleaned up.

Result:

- Status: `PASS`
- Workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/C02-win10-full-auto-20260519-1348`
- Cloud VM ID: `19a0a3ad-ed1b-4148-8ef1-2e52fce84a36`
- Notes:
  - Clean precheck on 2026-05-19 confirmed source `win10` was `ON`, no C02
    RBD images existed, no C02 Cloud volumes existed, and there was no
    conflicting Cloud VM named `win10`. An unrelated existing Cloud VM
    `tj-win10` was left untouched.
  - The full run was executed without `--force-v3`. Preflight detected PC v4
    VMM/Data Protection APIs but selected the runnable `v3-incremental` path
    through PE `10.10.132.10` because v4 changed-region/byte-source data plane
    is not verified. This validates the PC v4 / PE v3 auto fallback route.
  - Manifest contains 2 migration disks: a 100 GiB SCSI root disk and a 10 GiB
    SCSI data disk. Source-derived Cloud details were recorded as
    `details[0].cpuNumber=4`, `details[0].cpuSpeed=1000`,
    `details[0].memory=4096`, `rootDiskController=scsi`,
    `dataDiskController=scsi`, `boottype=UEFI`, and `bootmode=SECURE`.
  - Full migration completed with guest shutdown. Source `win10` reached `OFF`
    after ACPI shutdown. Final sync applied 253 regions / 2420736 bytes on
    disk0 and 0 regions / 0 bytes on disk1.
  - Cloud cutover succeeded. VM `19a0a3ad-ed1b-4148-8ef1-2e52fce84a36`
    (`i-2-385-VM`) is `Running` on `ablecube22-2` with service offering
    `NoLimit-HA-WB`, `cpunumber=4`, `cpuspeed=1000`, and `memory=4096`.
    Selected network is `L2-Network`
    (`fa2d6e6c-0003-4ab0-92a2-e3e41c9ccbac`).
  - Cloud volume verification passed: root volume
    `05d73a35-7067-40a6-bc3e-c585d8a77da8` is type `ROOT`, device 0, size
    100 GiB, and path `n2k-cloud-c02-win10-auto-20260519-disk0`. Data volume
    `4961bd27-eef0-4713-b34f-c65dea550d82` is type `DATADISK`, device 1, size
    10 GiB, and path `n2k-cloud-c02-win10-auto-20260519-disk1`.
  - Host 22.2 verification passed: libvirt domain `i-2-385-VM` is `running`
    and uses `/dev/rbd/rbd/n2k-cloud-c02-win10-auto-20260519-disk0` and
    `/dev/rbd/rbd/n2k-cloud-c02-win10-auto-20260519-disk1`.
  - Successful cutoff cleaned all three Nutanix source snapshots created by the
    run. Follow-up PE snapshot query returned no matching n2k snapshots.
  - Observation: PC inventory reported source `win10` disk_count 3 while the
    selected manifest exposed 2 migration disks. The extra 540672-byte
    SelfServiceContainer snapshot file was not mapped to a manifest disk and
    was skipped. C02 pass criteria remain based on the 2 manifest migration
    disks.
  - Non-blocking host observation: 22.2 Cloud agent logged failed
    `rbd image-cache invalidate` commands because that rbd CLI subcommand form
    is unsupported in the host build, but the VM remained running and disk
    attach verification passed.

### C03 - CentOS BIOS/IDE full RBD Cloud target

Objective:

- Validate one-disk BIOS/IDE compatibility through Cloud API deploy.

Execution:

1. Set `VM='centos7-bios-ide'`.
2. Set `RBD_PREFIX='n2k-cloud-c03-centos7-bios-ide'`.
3. Run full cutoff command with `MODE_ARGS='--force-v3'`.

Pass criteria:

- Manifest has 1 migration disk.
- `runtime.cloud.deployment_properties` preserves BIOS/IDE-compatible boot and
  root disk controller settings where present.
- Cloud VM deploys from the imported root disk.
- Cloud VM is running.
- Guest reaches bootable state through console or Cloud VM state evidence.

Result:

- Status: `PASS`
- Workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/C03-centos7-bios-ide-full-v3-20260519-1358`
- Cloud VM ID: `062e6d69-0bd0-4f39-9e41-81ec09fcaab1`
- Notes:
  - Clean precheck on 2026-05-19 confirmed source `centos7-bios-ide` was
    `ON`, no conflicting Cloud VM existed, no C03 RBD images existed, no C03
    Cloud volumes existed, and no matching n2k source snapshots remained.
  - The full run was executed with `--force-v3`. Preflight recorded
    `source_api_policy=v3`, `mode_forced=true`, and selected the runnable
    `v3-incremental` path through PE `10.10.132.10`.
  - Manifest contains 1 migration disk: a 100 GiB IDE disk with bus 0 / unit 1.
    Source-derived Cloud details were recorded as `details[0].cpuNumber=1`,
    `details[0].cpuSpeed=1000`, `details[0].memory=4096`,
    `details[0].rootDiskController=ide`, `boottype=BIOS`, and
    `bootmode=LEGACY`.
  - Full migration completed with guest shutdown. Source `centos7-bios-ide`
    reached `OFF` after ACPI shutdown. Incremental sync applied 5 regions /
    24576 bytes. Final sync applied 56 regions / 789504 bytes.
  - Cloud cutover succeeded. VM `062e6d69-0bd0-4f39-9e41-81ec09fcaab1`
    (`i-2-386-VM`) is `Running` on `ablecube22-2` with service offering
    `NoLimit-HA-WB`, `cpunumber=1`, `cpuspeed=1000`, and `memory=4096`.
    Selected network is `L2-Network`
    (`fa2d6e6c-0003-4ab0-92a2-e3e41c9ccbac`).
  - Cloud volume verification passed: root volume
    `852e27f5-0da1-451e-8842-d96ea345e266` is type `ROOT`, device 0, size
    100 GiB, and path
    `n2k-cloud-c03-centos7-bios-ide-v3-20260519-1358-disk0`.
  - Host 22.2 verification passed: libvirt domain `i-2-386-VM` is `running`,
    uses machine `pc-i440fx-9.2`, has no UEFI loader/nvram entries, and maps
    the root disk as IDE `hda` from
    `/dev/rbd/rbd/n2k-cloud-c03-centos7-bios-ide-v3-20260519-1358-disk0`.
    The Cloud agent also reported the VM as `PowerOn`.
  - Successful cutoff cleaned all three Nutanix source snapshots created by the
    run. Follow-up PE snapshot query returned no matching n2k snapshots.
  - Observation: PC inventory reported source `centos7-bios-ide` disk_count 2,
    while the selected manifest exposed 1 migration disk. The v3 snapshot path
    list contained only the 100 GiB Storage-Container vDisk, and no extra
    manifest disk was migrated.
  - Non-blocking host observation: 22.2 Cloud agent logged failed
    `rbd image-cache invalidate` commands because that rbd CLI subcommand form
    is unsupported in the host build, but the VM remained running and disk
    attach verification passed.

### C04 - RHEL Phase1/Phase2 FileSystem Cloud target

Objective:

- Validate the split migration flow with Cloud API cutoff on host-local
  FileSystem/qcow2 storage.
- Validate multi-disk import and attach for 3 disks.
- Validate source snapshot cleanup after successful cutoff.

Target placement:

| Item | Value |
| --- | --- |
| Execution host | `10.10.22.1` / `ablecube22-1` |
| Cloud host ID | `34ada5ae-05cd-42f2-92a7-71f462da6a2e` |
| Cloud storage ID | `4e929594-99f4-4846-add9-bdf49cf71587` |
| Cloud storage name | `ablecube22-1-local-4e929594` |
| Cloud storage path | `/var/lib/libvirt/images` |

Target map:

```json
{
  "ae29c318-5dca-44b3-93c6-f3f3714177ec": "/var/lib/libvirt/images/n2k-cloud-c04-rhel-fs-disk0.qcow2",
  "afe42ac0-bb0a-4022-b9cf-3a5409eb21fb": "/var/lib/libvirt/images/n2k-cloud-c04-rhel-fs-disk1.qcow2",
  "ee5d7f96-7d87-46e4-996c-efcc4d7d8dde": "/var/lib/libvirt/images/n2k-cloud-c04-rhel-fs-disk2.qcow2"
}
```

Execution:

1. Remove or stop the previous C01 Cloud target VM before powering on source
   `rhel`.
2. Set `VM='rhel'`.
3. Set `WORKDIR='/var/lib/ablestack/n2k-e2e/cloud-target/C04-rhel-fs-phase12-<timestamp>'`.
4. Run Phase1 on `10.10.22.1` with `--force-v3`, `--target-storage file`,
   `--target-format qcow2`, `--dst /var/lib/libvirt/images`,
   `--cloud-storage-id 4e929594-99f4-4846-add9-bdf49cf71587`,
   `--cloud-host-id 34ada5ae-05cd-42f2-92a7-71f462da6a2e`, and the target map
   above.
5. Run Phase2 with `--shutdown guest --apply --start --force-v3` and the same
   Cloud/FileSystem options.

Pass criteria:

- Manifest has 3 migration disks.
- All target qcow2 files are directly under `/var/lib/libvirt/images` on
  `10.10.22.1`.
- `runtime.cloud.deployment_properties` includes CPU, memory, boot, and SCSI
  controller properties derived from the source manifest.
- Cloud VM is running on `ablecube22-1`.
- Cloud VM has 3 volumes and each volume path matches the target map basename.
- Source `rhel` is `OFF` after successful cutoff.
- Nutanix `n2k-*` source snapshots for this run are removed.

Result:

- Status: `PASS`
- Workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/C04-rhel-fs-phase12-20260519-1428`
- Cloud VM ID: `a231e17e-c365-49d2-8e64-9918f0a8f68b`
- Notes:
  - The previous RBD C01 Cloud target VM named `rhel` was destroyed and expunged
    before C04 so the migrated Cloud VM would not collide by name or run on the
    same network as the source. C04 used Cloud name/display name
    `n2k-c04-rhel-fs`.
  - Source `rhel` was powered on before Phase1 and exposed 3 migration disks.
  - Phase1 with `--force-v3`, FileSystem/qcow2 target storage, host
    `ablecube22-1`, and the C04 target map completed. Base snapshot
    `73967551-ae08-4241-a2c5-a6150a563b4d` and incremental snapshot
    `0a005319-2e93-48aa-a08a-435bd0ce6c7b` were created. Phase1 incremental
    changed regions were 36 regions / 466944 bytes on disk0 and 0 on disk1/disk2.
  - Phase1 produced root-level local files
    `n2k-cloud-c04-rhel-fs-disk0.qcow2`,
    `n2k-cloud-c04-rhel-fs-disk1.qcow2`, and
    `n2k-cloud-c04-rhel-fs-disk2.qcow2` directly under
    `/var/lib/libvirt/images` on 22.1.
  - The first Phase2 attempt intentionally used the earlier RBD-style `Custom1`
    disk offering and failed at Cloud `importVolume` because that offering is
    not local-storage compatible. This was treated as a procedural parameter
    error, not a data sync failure. The runtime manifest was corrected to omit
    the disk offering before retry.
  - Observation for follow-up: the failed Phase2 attempt had already recorded
    `phases.cutover.done=true` even though Cloud apply did not complete. The
    test manifest checkpoint was reset to retry only the cutover path. This
    checkpoint behavior should be hardened before relying on automatic retry
    after cutover API failures.
  - Phase2 final sync had completed before the first Cloud import failure.
    Incremental snapshot `be1f7cde-63e6-4804-9846-19fc61b565a1` applied
    9 regions / 94208 bytes. Guest shutdown via ACPI completed and source
    `rhel` reached `OFF`. Final snapshot
    `f62d98f4-fc88-4036-9e9b-019b0b4520e1` applied 43 regions / 545280 bytes
    across all three disks.
  - Retrying the cutover without `--cloud-disk-offering-id` passed on the older
    behavior where Cloud selected its default local import offering. Current n2k
    builds should instead resolve `N2K Migration Writeback Local` before
    `importVolume`. Cloud imported the root qcow2 as volume
    `2d7778cc-b7ad-497a-820a-47406805c48b`, converted it to `ROOT`, deployed
    VM `a231e17e-c365-49d2-8e64-9918f0a8f68b`, attached data volumes
    `ad93fb6c-9307-4176-8647-9d9f5617fc77` and
    `c7b2279b-a233-4b1e-99b7-dffd51b92b0b`, and started the VM.
  - Cloud verification passed: VM `n2k-c04-rhel-fs` / `i-2-387-VM` is
    `Running` on `ablecube22-1`. VM details include `cpuNumber=1`,
    `cpuSpeed=1000`, `memory=4096`, `rootDiskController=scsi`,
    `dataDiskController=scsi`, and `UEFI=SECURE`.
  - Cloud volume verification passed: one `ROOT` volume and two `DATADISK`
    volumes are `Ready` on `ablecube22-1-local-4e929594`, with paths matching
    the C04 target map basenames and device IDs 0, 1, and 2.
  - Host 22.1 verification passed: libvirt domain `i-2-387-VM` is `running`,
    maps `sda`, `sdb`, and `sdc` to the three C04 qcow2 files under
    `/var/lib/libvirt/images`, and uses `bridge0` for its NIC.
  - Successful cleanup removed the four Nutanix source snapshots created by
    the run. Follow-up PE snapshot query returned no matching n2k snapshots.
    Source `rhel` remained `OFF` after cutoff.

### C05 - Win10 full FileSystem Cloud target with auto fallback

Objective:

- Validate the auto source route with Cloud API cutoff on host-local
  FileSystem/qcow2 storage.
- Validate Windows multi-disk import and attach for 2 disks.

Target placement:

| Item | Value |
| --- | --- |
| Execution host | `10.10.22.2` / `ablecube22-2` |
| Cloud host ID | `56a141bf-4119-4bae-8599-ce8583a5b1e6` |
| Cloud storage ID | `aa5cf314-1246-42b5-9783-4f1a3c1e1d19` |
| Cloud storage name | `ablecube22-2-local-aa5cf314` |
| Cloud storage path | `/var/lib/libvirt/images` |

Target map:

```json
{
  "de061be4-fe34-412e-931b-b5163b03d81c": "/var/lib/libvirt/images/n2k-cloud-c05-win10-fs-disk0.qcow2",
  "ee1cbd9e-6692-4ec5-9131-d54bce8a4bf9": "/var/lib/libvirt/images/n2k-cloud-c05-win10-fs-disk1.qcow2"
}
```

Execution:

1. Remove or stop the previous C02 Cloud target VM before powering on source
   `win10`.
2. Set `VM='win10'`.
3. Set `WORKDIR='/var/lib/ablestack/n2k-e2e/cloud-target/C05-win10-fs-full-<timestamp>'`.
4. Run full cutoff on `10.10.22.2` without `--force-v3`, using
   `--target-storage file`, `--target-format qcow2`,
   `--dst /var/lib/libvirt/images`,
   `--cloud-storage-id aa5cf314-1246-42b5-9783-4f1a3c1e1d19`,
   `--cloud-host-id 56a141bf-4119-4bae-8599-ce8583a5b1e6`, and the target map
   above.

Pass criteria:

- Plan/preflight records selected v3 fallback or another explicitly validated
  runnable source path.
- Manifest has 2 migration disks.
- Both target qcow2 files are directly under `/var/lib/libvirt/images` on
  `10.10.22.2`.
- Cloud VM is running on `ablecube22-2`.
- Cloud VM has 2 volumes and each volume path matches the target map basename.
- Source `win10` is `OFF` after successful cutoff.
- Source snapshots are cleaned up.

Result:

- Status: `PASS`
- Workdir: `10.10.22.2:/var/lib/ablestack/n2k-e2e/cloud-target/C05-win10-fs-full-20260519-1451`
- Cloud VM ID: `1acbfb58-b7a6-486f-934f-d40495b704e7`
- Notes:
  - The previous RBD C02 Cloud target VM named `win10`
    (`19a0a3ad-ed1b-4148-8ef1-2e52fce84a36` / `i-2-385-VM`) was destroyed
    and expunged before C05, and its leftover C02 data volume was removed.
    No C05 Cloud target VM or root-level C05 qcow2 file existed before the run.
  - Source `win10` was powered back on before the test. The PE-selected n2k
    manifest exposed 2 migration disks even though the raw snapshot path list
    also included one small SelfServiceContainer file. The extra file was not
    mapped to a manifest disk and was skipped.
  - Full run started from PC `https://10.10.132.100:9440` without `--force-v3`.
    Planning selected the validated `v3-incremental` path automatically and
    selected PE source endpoint `10.10.132.10`; this validates the PC v4 / PE
    v3 fallback route for the C05 FileSystem case.
  - Base snapshot `a33abb17-9a11-41a1-bf6e-f408872c68e6`, incremental snapshot
    `b10bbbea-a341-42a8-bb0d-c7dac1bd3492`, and final snapshot
    `84dc3649-ed1f-4568-927e-bf0f49fe21fb` were created. Incremental sync
    applied 603 regions / 7474688 bytes, and final sync applied 1440 regions /
    18617344 bytes. Each changed-region calculation skipped the unmapped tiny
    SelfServiceContainer snapshot file.
  - Guest shutdown via ACPI completed during cutoff and source `win10` reached
    `OFF`.
  - Target files were created directly under `/var/lib/libvirt/images` on
    `ablecube22-2`: `n2k-cloud-c05-win10-fs-disk0.qcow2` and
    `n2k-cloud-c05-win10-fs-disk1.qcow2`.
  - Cloud cutover succeeded without `--cloud-disk-offering-id` on the older
    behavior where Cloud selected `Default Custom Offering for Volume Import -
    Local Storage`. Current n2k builds should instead resolve
    `N2K Migration Writeback Local` before `importVolume`. The run imported the
    root qcow2 as volume `a7f6f959-58bc-4d78-8d02-5a630d452b61`, converted it
    to `ROOT`, deployed VM `1acbfb58-b7a6-486f-934f-d40495b704e7`, attached
    data volume `ae2d2361-a0eb-4ab3-9454-2899374333c0`, and started the VM.
  - Cloud verification passed: VM `n2k-c05-win10-fs` / `i-2-388-VM` is
    `Running` on `ablecube22-2`. VM details include `cpuNumber=4`,
    `cpuSpeed=1000`, `memory=4096`, `rootDiskController=scsi`,
    `dataDiskController=scsi`, and `UEFI=SECURE`.
  - Cloud volume verification passed: one `ROOT` volume and one `DATADISK`
    volume are `Ready` on `ablecube22-2-local-aa5cf314`, with paths matching
    the C05 target map basenames and device IDs 0 and 1.
  - Host 22.2 verification passed: libvirt domain `i-2-388-VM` is `running`,
    maps `sda` and `sdb` to the two C05 qcow2 files under
    `/var/lib/libvirt/images`, and uses `bridge0` for its NIC.
  - Successful cleanup removed all three Nutanix source snapshots created by
    the run. Follow-up PE snapshot query returned no matching n2k snapshots.
    Source `win10` remained `OFF` after cutoff.

### C06 - CentOS BIOS/IDE full FileSystem Cloud target

Objective:

- Validate one-disk BIOS/IDE compatibility through Cloud API deploy on
  host-local FileSystem/qcow2 storage.

Target placement:

| Item | Value |
| --- | --- |
| Execution host | `10.10.22.3` / `ablecube22-3` |
| Cloud host ID | `0132ec7b-055b-44e2-b8a8-62bcc58c81e4` |
| Cloud storage ID | `a872e82e-3f49-410e-a743-25ea04484fd1` |
| Cloud storage name | `ablecube22-3-local-a872e82e` |
| Cloud storage path | `/var/lib/libvirt/images` |

Target map:

```json
{
  "ea40360c-6263-4bdb-9630-0925bfcc660e": "/var/lib/libvirt/images/n2k-cloud-c06-centos7-bios-ide-fs-disk0.qcow2"
}
```

Execution:

1. Remove or stop the previous C03 Cloud target VM before powering on source
   `centos7-bios-ide`.
2. Set `VM='centos7-bios-ide'`.
3. Set `WORKDIR='/var/lib/ablestack/n2k-e2e/cloud-target/C06-centos7-bios-ide-fs-full-<timestamp>'`.
4. Run full cutoff on `10.10.22.3` with `--force-v3`,
   `--target-storage file`, `--target-format qcow2`,
   `--dst /var/lib/libvirt/images`,
   `--cloud-storage-id a872e82e-3f49-410e-a743-25ea04484fd1`,
   `--cloud-host-id 0132ec7b-055b-44e2-b8a8-62bcc58c81e4`, and the target map
   above.

Pass criteria:

- Manifest has 1 migration disk.
- Target qcow2 file is directly under `/var/lib/libvirt/images` on
  `10.10.22.3`.
- `runtime.cloud.deployment_properties` preserves BIOS/IDE-compatible boot and
  root disk controller settings where present.
- Cloud VM is running on `ablecube22-3`.
- Cloud VM has 1 ROOT volume and its path matches the target map basename.
- Guest reaches bootable state through libvirt/Cloud VM state evidence.
- Source snapshots are cleaned up.

Result:

- Status: `PASS`
- Workdir: `10.10.22.3:/var/lib/ablestack/n2k-e2e/cloud-target/C06-centos7-bios-ide-fs-full-20260519-1506`
- Cloud VM ID: `7b84acd0-107c-49c5-b4bb-c4c1bf50b37f`
- Notes:
  - The previous RBD C03 Cloud target VM named `centos7-bios-ide`
    (`062e6d69-0bd0-4f39-9e41-81ec09fcaab1` / `i-2-386-VM`) was destroyed
    and expunged before C06. No C06 Cloud target VM or root-level C06 qcow2
    file existed on 22.3 before the run.
  - Source `centos7-bios-ide` was powered back on before the test. Raw Nutanix
    v3 VM inventory reported two disk-list entries, but the PE-selected n2k
    manifest exposed the single 100 GiB IDE migration disk expected for this
    case.
  - Full run started from PC `https://10.10.132.100:9440` with `--force-v3`.
    Planning selected the validated `v3-incremental` path and PE source
    endpoint `10.10.132.10`.
  - Base snapshot `a57bac88-c11a-4641-a4c0-d3ea7c5ee204`, incremental snapshot
    `dc8a857f-1bab-4a47-9774-6a0450115330`, and final snapshot
    `c2d882bf-e925-40e7-894e-afd884443054` were created. Incremental sync
    applied 53 regions / 885248 bytes, and final sync applied 36 regions /
    409600 bytes.
  - Guest shutdown via ACPI completed during cutoff and source
    `centos7-bios-ide` reached `OFF`.
  - Target file `n2k-cloud-c06-centos7-bios-ide-fs-disk0.qcow2` was created
    directly under `/var/lib/libvirt/images` on `ablecube22-3`.
  - Cloud cutover succeeded without `--cloud-disk-offering-id` on the older
    behavior where Cloud selected `Default Custom Offering for Volume Import -
    Local Storage`. Current n2k builds should instead resolve
    `N2K Migration Writeback Local` before `importVolume`. The run imported the
    root qcow2 as volume `6b01a1ef-6693-4654-a583-bee56025c2ee`, converted it
    to `ROOT`, deployed VM `7b84acd0-107c-49c5-b4bb-c4c1bf50b37f`, and started
    the VM.
  - Cloud verification passed: VM `n2k-c06-centos7-bios-ide-fs` /
    `i-2-389-VM` is `Running` on `ablecube22-3`. VM details include
    `cpuNumber=1`, `cpuSpeed=1000`, `memory=4096`,
    `rootDiskController=ide`, `boottype=BIOS`, and `bootmode=LEGACY`.
  - Cloud volume verification passed: one `ROOT` volume is `Ready` on
    `ablecube22-3-local-a872e82e`, with path
    `n2k-cloud-c06-centos7-bios-ide-fs-disk0.qcow2` and device ID 0.
  - Host 22.3 verification passed: libvirt domain `i-2-389-VM` is `running`,
    uses machine `pc-i440fx-9.2`, maps IDE disk `hda` to the C06 qcow2 file
    under `/var/lib/libvirt/images`, and uses `bridge0` for its NIC. The QEMU
    log also shows `ide-hd` for the boot disk.
  - Successful cleanup removed all three Nutanix source snapshots created by
    the run. Follow-up PE snapshot query returned no matching n2k snapshots.
    Source `centos7-bios-ide` remained `OFF` after cutoff.

### N01 - Missing service offering validation

Objective:

- Confirm n2k blocks Cloud target cutover before import/deploy when service
  offering is missing.

Pass criteria:

- Command exits before `importVolume`.
- Error mentions Cloud target required config.
- No Cloud volume or VM is created.

Result:

- Status: `PASS`
- Workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/negative-remaining-20260519-1535/N01-missing-service-offering`
- Notes:
  - Initial execution before the fix printed the expected required-config error
    but still attempted Cloud `importVolume`/`deployVirtualMachineForVolume`.
    This failed the "block before import/deploy" criterion and exposed a retry
    safety bug in Cloud cutover validation.
  - Code fix `ac97469` makes `n2k_cloud_target_cutover` explicitly return
    after Cloud config validation failures even when the function is executed
    inside command substitution. The fixed RPM was rebuilt and deployed to
    `10.10.22.1`, `10.10.22.2`, and `10.10.22.3`.
  - Retest on 2026-05-19 passed. The command exited with rc 2 and only printed
    `Cloud target requires zone_id, service_offering_id, network_ids,
    storage_id, and a positive numeric cpu_speed.`
  - The retest log contained no `importVolume`, `deployVirtualMachineForVolume`,
    Cloud async job, or curl HTTP failure output. Cloud follow-up query found
    no `n2k-negative-*` VM or volume, and 22.1 had no `n2k-negative*` local
    files.

### N02 - Missing network validation

Objective:

- Confirm n2k blocks Cloud target cutover before import/deploy when network ID
  is missing.

Pass criteria:

- Command exits before `importVolume`.
- Error mentions Cloud target required config or network requirement.
- No Cloud volume or VM is created.

Result:

- Status: `PASS`
- Workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/negative-remaining-20260519-1535/N02-missing-network`
- Notes:
  - Initial execution before the fix printed the expected required-config error
    but still attempted Cloud import/deploy work, so it did not satisfy the
    "block before import/deploy" criterion.
  - After code fix `ac97469` was rebuilt and deployed, the retest on
    2026-05-19 exited with rc 2 and only printed the required-config error.
  - The retest log contained no `importVolume`, `deployVirtualMachineForVolume`,
    Cloud async job, or curl HTTP failure output. Cloud follow-up query found
    no `n2k-negative-*` VM or volume, and 22.1 had no `n2k-negative*` local
    files.

### N03 - Cloud target block/LVM out-of-scope validation

Objective:

- Confirm current code rejects `--target-storage block` for Cloud target.

Pass criteria:

- Command exits before Cloud API modification.
- Error says Cloud target import does not support block/LVM target paths.

Result:

- Status: `PASS`
- Workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/negative-remaining-20260519-1535/N03-block-lvm-out-of-scope`
- Notes:
  - Initial execution before the fix printed the expected
    `ABLESTACK Cloud target import does not support block/LVM target paths.`
    error but still attempted later Cloud import/deploy steps. This failed the
    "no Cloud API modification" criterion.
  - Code fix `ac97469` also makes `n2k_cloud_target_cutover` explicitly return
    when `n2k_cloud_target_import_path` rejects a block/LVM target path.
  - After rebuild and deployment, the retest on 2026-05-19 exited with rc 2 and
    only printed the block/LVM unsupported error.
  - The retest log contained no `importVolume`, `deployVirtualMachineForVolume`,
    Cloud async job, or curl HTTP failure output. Cloud follow-up query found
    no `n2k-negative-*` VM or volume, and 22.1 had no `n2k-negative*` local
    files.

## Cleanup checklist

After every positive or partially successful Cloud case:

1. Stop the Cloud VM if it was started.
2. Destroy/delete the Cloud VM and associated imported volumes according to the
   Cloud UI/API cleanup procedure.
3. Remove target RBD images with the case prefix after evidence is collected.
4. Confirm no Nutanix `n2k-*` snapshots remain for the source VM.
5. Keep the n2k workdir until the result is reviewed.

## Open validation points

- Exact service offering choice for Windows and Linux guests must be confirmed
  before C01.
- Cloud target currently selects network IDs but does not preserve original
  Nutanix MAC/IP. Treat MAC/IP preservation as a separate requirement if needed.
- Filesystem primary storage path handling is not yet proven and is isolated to
  C05.
- Cloud target LVM/block support is intentionally deferred to a later version.
