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
- Include `--cloud-disk-offering-id 1da3a4e3-3a1a-4afd-bd28-19df910b334a` for
  the main RBD pass, then omit it in the compatibility case.

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
| C01 | `rhel` | forced v3 | Phase1/Phase2 | RBD | Provided | Cloud VM starts, 3 disks imported/attached | PASS |
| C02 | `win10` | auto fallback | Full | RBD | Provided | Cloud VM starts, 2 disks imported/attached | PASS |
| C03 | `centos7-bios-ide` | forced v3 | Full | RBD | Provided | Cloud VM starts, BIOS/IDE guest boots | PASS |
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
