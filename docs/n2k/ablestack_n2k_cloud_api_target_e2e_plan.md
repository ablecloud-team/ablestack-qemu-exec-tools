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

Filesystem primary storage can be validated after RBD passes. LVM/block is out
of scope for the current Cloud target test pass and should be treated as a next
version topic.

### Disk offerings

The disk offering is selected by `--cloud-disk-offering-id` and is passed to
`importVolume` as `diskofferingid` only when provided.

| Name | ID | Notes |
| --- | --- | --- |
| `Custom1` | `1da3a4e3-3a1a-4afd-bd28-19df910b334a` | Customized, tag `rbd` |
| `FTCTL Internal Root Disk` | `bf9b2567-abe0-420b-bdba-44c8779232f0` | Internal candidate, not preferred for n2k |
| `FTCTL Internal Data Disk` | `20de1c04-f650-4900-af23-34567bfe2fa9` | Internal candidate, not preferred for n2k |

Disk offering is intentionally optional in n2k. One negative/compatibility case
must omit `--cloud-disk-offering-id` and verify that n2k does not block before
the Cloud API call. If Cloud rejects the import due policy, record that as a
Cloud policy result rather than an n2k argument validation failure.

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
- Use RBD first:
  - `--target-storage rbd`
  - `--target-format raw`
  - `--dst "rbd:rbd/${RBD_PREFIX}"`
  - `--cloud-storage-id 91cae554-3fce-3f93-89d1-cefaf9bf8122`
- Include `--cloud-disk-offering-id 1da3a4e3-3a1a-4afd-bd28-19df910b334a` for
  the main RBD pass, then omit it in the compatibility case.

After each case:

1. Record `manifest.json`, `events.log`, command output, and Cloud VM ID.
2. Confirm `runtime.cloud` records imported volume IDs and async job IDs.
3. Confirm `runtime.cloud.deployment_properties` records derived CPU, memory,
   boot type/mode, and disk controller parameters when those values exist in
   the source manifest.
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
export CLOUD_DISK_OFFERING_ID='1da3a4e3-3a1a-4afd-bd28-19df910b334a'
export CLOUD_NETWORK_ID='fa2d6e6c-0003-4ab0-92a2-e3e41c9ccbac'
export CLOUD_SERVICE_OFFERING_ID='<select-before-test>'

export N2K_BASE_WORKDIR='/var/lib/ablestack/n2k-e2e/cloud-target'
export N2K_RBD_POOL='rbd'
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
  --cloud-disk-offering-id "${CLOUD_DISK_OFFERING_ID}" \
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
  --cloud-disk-offering-id "${CLOUD_DISK_OFFERING_ID}" \
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
  --cloud-disk-offering-id "${CLOUD_DISK_OFFERING_ID}" \
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
  --cloud-disk-offering-id "${CLOUD_DISK_OFFERING_ID}" \
  --shutdown guest \
  --apply \
  --start \
  ${MODE_ARGS}
```

## Test matrix

| ID | VM | Source mode | Split | Target backend | Disk offering | Expected result | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C00 | n/a | n/a | n/a | n/a | n/a | Cloud API/resource readiness passes | PASS |
| C01 | `rhel` | forced v3 | Phase1/Phase2 | RBD | Provided | Cloud VM starts, 3 disks imported/attached | BLOCKED |
| C02 | `win10` | auto fallback | Full | RBD | Provided | Cloud VM starts, 2 disks imported/attached | TODO |
| C03 | `centos7-bios-ide` | forced v3 | Full | RBD | Provided | Cloud VM starts, BIOS/IDE guest boots | TODO |
| C04 | `rhel` | auto fallback | Full | RBD | Omitted | n2k does not block on missing disk offering; Cloud result recorded | TODO |
| C05 | n/a | n/a | n/a | Filesystem | Provided or omitted | `listVolumesForImport` path behavior is characterized only | TODO |
| N01 | synthetic | n/a | cutover validation | RBD | Any | Missing service offering blocks before import/deploy | TODO |
| N02 | synthetic | n/a | cutover validation | RBD | Any | Missing network blocks before import/deploy | TODO |
| N03 | synthetic | n/a | cutover validation | block/LVM | Any | Cloud target rejects block/LVM as out of scope | TODO |

Do not run C05 as a full migration until the filesystem import path is proven
against the matching host-local primary storage. LVM/block Cloud target testing
is explicitly out of scope for this version.

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
  - Disk offering: `Custom1` / `1da3a4e3-3a1a-4afd-bd28-19df910b334a`
- Required Cloud APIs are exposed: `listVolumesForImport`, `importVolume`,
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

- Status: `BLOCKED`
- Workdir: `10.10.22.1:/var/lib/ablestack/n2k-e2e/cloud-target/C01-rhel-phase12-rerun-20260519`
- Cloud VM ID: n/a
- Notes:
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
    signature verification passed. C01 must be retried after the fixed RPM is
    deployed and the imported volumes/RBD images/source snapshots are cleaned.

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

- Status: `TODO`
- Workdir:
- Cloud VM ID:
- Notes:

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

- Status: `TODO`
- Workdir:
- Cloud VM ID:
- Notes:

### C04 - RBD Cloud target without disk offering

Objective:

- Confirm n2k treats disk offering as optional.
- Distinguish n2k validation behavior from Cloud policy behavior.

Execution:

1. Set `VM='rhel'`.
2. Set `RBD_PREFIX='n2k-cloud-c04-rhel-no-diskoffering'`.
3. Run full cutoff command with the `--cloud-disk-offering-id` option removed.

Pass criteria:

- n2k does not fail local validation only because disk offering is omitted.
- If Cloud accepts the import, continue to boot validation.
- If Cloud rejects the import, record the Cloud error and classify the case as
  Cloud policy `BLOCKED`, not n2k validation failure.

Result:

- Status: `TODO`
- Workdir:
- Cloud VM ID:
- Cloud error, if any:
- Notes:

### C05 - Filesystem primary storage path characterization

Objective:

- Characterize ABLESTACK Cloud `listVolumesForImport` path behavior for
  Filesystem primary storage.
- Do not run a full migration until path behavior is proven.

Execution outline:

1. Select the host-local primary storage matching the target host.
2. Create or reuse a harmless test qcow2/raw image under the storage path.
3. Call `listVolumesForImport` through n2k Cloud helper or a protected API
   probe.
4. Record whether Cloud expects basename, relative path, or absolute path.
5. Delete the harmless test image.

Result:

- Status: `TODO`
- Storage ID:
- Accepted path format:
- Notes:

### N01 - Missing service offering validation

Objective:

- Confirm n2k blocks Cloud target cutover before import/deploy when service
  offering is missing.

Pass criteria:

- Command exits before `importVolume`.
- Error mentions Cloud target required config.
- No Cloud volume or VM is created.

Result:

- Status: `TODO`
- Notes:

### N02 - Missing network validation

Objective:

- Confirm n2k blocks Cloud target cutover before import/deploy when network ID
  is missing.

Pass criteria:

- Command exits before `importVolume`.
- Error mentions Cloud target required config or network requirement.
- No Cloud volume or VM is created.

Result:

- Status: `TODO`
- Notes:

### N03 - Cloud target block/LVM out-of-scope validation

Objective:

- Confirm current code rejects `--target-storage block` for Cloud target.

Pass criteria:

- Command exits before Cloud API modification.
- Error says Cloud target import does not support block/LVM target paths.

Result:

- Status: `TODO`
- Notes:

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
