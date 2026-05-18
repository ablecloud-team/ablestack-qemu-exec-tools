# ablestack_n2k ABLESTACK Cloud API target design

## Purpose

This document describes how `ablestack_n2k` should create the target VM through the ABLESTACK Cloud API instead of generating and applying a libvirt XML definition directly on the KVM host.

The existing migration data path remains valid:

```text
Nutanix source snapshot/recovery point
  -> n2k base/incremental/final disk sync
  -> target storage image or block device
```

The new design changes only the target cutover path:

```text
Current: generate libvirt XML -> virsh define -> virsh start
New:     Cloud API import volume -> deploy VM from imported volume -> attach data disks -> start VM
```

## Branch and API verification

The ABLESTACK Cloud source was checked in the local WSL clone:

```text
/root/work/ablestack-cloud
branch: ablestack-diplo
commit: 57aae906bf115e210f176f785be9600e99cda742
```

The `deployVirtualMachineForVolume` API exists in code and is registered as a management-server API command.

Relevant code paths:

| Area | File | Evidence |
| --- | --- | --- |
| User command | `/root/work/ablestack-cloud/api/src/main/java/org/apache/cloudstack/api/command/user/vm/DeployVMVolumeCmd.java` | `@APICommand(name = "deployVirtualMachineForVolume", ...)` |
| Admin command | `/root/work/ablestack-cloud/api/src/main/java/org/apache/cloudstack/api/command/admin/vm/DeployVMVolumeCmdByAdmin.java` | Admin view for the same API name |
| Command registration | `/root/work/ablestack-cloud/server/src/main/java/com/cloud/server/ManagementServerImpl.java` | Adds both `DeployVMVolumeCmdByAdmin.class` and `DeployVMVolumeCmd.class` |
| VM creation implementation | `/root/work/ablestack-cloud/server/src/main/java/com/cloud/vm/UserVmManagerImpl.java` | `createVirtualMachineVolume(DeployVMVolumeCmd cmd)` |
| Start implementation | `/root/work/ablestack-cloud/server/src/main/java/com/cloud/vm/UserVmManagerImpl.java` | `startVirtualMachineVolume(DeployVMVolumeCmd cmd)` |

The command accepts a `volumeid` parameter and the implementation marks the imported volume as device `0`, associates it with the dummy VM import template, and then creates a VM. This is the API path n2k should use for the target root disk.

## Runtime API findings

The 22.x ABLESTACK Cloud lab management API was tested at:

```text
http://10.10.22.10:8080/client/api
```

Credential handling note:

- API keys and secret keys must not be committed to this repository.
- Runtime code should accept them through environment variables, a protected credential file, or CLI options.
- Logs and manifest files must redact the secret key and signature.

Important authentication finding:

- This ABLESTACK Cloud branch verifies API signatures with `HmacSHA256`.
- Generic Apache CloudStack examples often use `HmacSHA1`; that fails with HTTP `401` in this environment.
- n2k must sign requests using `HmacSHA256`, lowercase the unsigned request string, and send the Base64 signature.

Observed API availability:

| API | Status |
| --- | --- |
| `listApis` | Available |
| `listZones` | Available |
| `listStoragePools` | Available |
| `listVolumesForImport` | Available |
| `importVolume` | Available |
| `unmanageVolume` | Available |
| `deployVirtualMachineForVolume` | Available |
| `attachVolume` | Available |
| `startVirtualMachine` | Available |
| `queryAsyncJobResult` | Available |

Observed target resources:

| Resource | Value |
| --- | --- |
| Zone | `Zone-22` |
| Zone ID | `d5551005-3372-43e5-8a2b-5742057bbabd` |
| Cluster | `Cluster` |
| RBD primary storage | `Primary Storage Glue RBD` |
| RBD storage ID | `91cae554-3fce-3f93-89d1-cefaf9bf8122` |
| RBD pool path | `rbd` |
| RBD storage provider | `ABLESTACK` |
| Active KVM hosts | `ablecube22-1`, `ablecube22-2`, `ablecube22-3` |
| Disk offering candidate | `Custom1`, tag `rbd` |

RBD import path behavior:

| n2k target path | Cloud import path |
| --- | --- |
| `rbd:rbd/<image>` | `<image>` preferred |
| `rbd:rbd/<image>` | `rbd/<image>` also accepted |
| `rbd:rbd/<image>` | `/rbd/<image>` rejected |

Validation result:

- A 1 GiB temporary RBD image was visible through `listVolumesForImport`.
- `importVolume` successfully registered it as a `DATADISK` volume in `Ready` state.
- `unmanageVolume` successfully removed CloudStack management of that test volume.
- The temporary RBD image was removed after the test.
- A 64 MiB image failed import because the Cloud disk policy requires at least 1 GiB.

## Design goals

- Keep the existing libvirt target path working unchanged.
- Add ABLESTACK Cloud API as a second target provider.
- Reuse the existing n2k source, snapshot, sync, RBD, qcow2, block, and phase1/phase2 machinery.
- Replace only the target VM creation/start path when Cloud API mode is selected.
- Support root disk and multiple data disks.
- Prefer RBD primary storage first, then add file primary storage support after path behavior is verified.
- Keep all secret material out of manifests, docs, shell history where possible, and logs.
- Make retry and cleanup behavior explicit because Cloud API operations are asynchronous.

## Target model

The current manifest stores:

```json
{
  "target": {
    "type": "kvm",
    "format": "raw",
    "storage": {
      "type": "rbd",
      "rbd_access_mode": "krbd"
    },
    "libvirt": {
      "name": "vm-name"
    }
  }
}
```

The design adds a target provider layer:

```json
{
  "target": {
    "type": "kvm",
    "provider": "ablestack-cloud",
    "format": "raw",
    "storage": {
      "type": "rbd",
      "rbd_access_mode": "krbd"
    },
    "cloud": {
      "endpoint": "http://10.10.22.10:8080/client/api",
      "zone_id": "d5551005-3372-43e5-8a2b-5742057bbabd",
      "service_offering_id": "",
      "network_ids": [],
      "storage_id": "91cae554-3fce-3f93-89d1-cefaf9bf8122",
      "disk_offering_id": "",
      "host_id": "",
      "account": "",
      "domain_id": "",
      "project_id": "",
      "vm_id": "",
      "imported_volumes": []
    }
  }
}
```

Secrets must not be stored in this structure. The API key can be stored only if the operator explicitly chooses a credential file path outside the manifest, but the default behavior should avoid storing both API key and secret.

## CLI additions

Add target provider options to `preflight`, `plan`, `init`, `run`, and `cutover`.

```text
--target-provider <provider>       libvirt|ablestack-cloud, default libvirt
--cloud-endpoint <url>             Cloud API endpoint
--cloud-api-key <key>              Cloud API key, runtime only
--cloud-secret-key <key>           Cloud secret key, runtime only
--cloud-cred-file <file>           Protected credential file
--cloud-zone-id <uuid>             Target zone
--cloud-service-offering-id <uuid> Target compute offering
--cloud-network-id <uuid>          Repeatable network ID option
--cloud-storage-id <uuid>          Target primary storage pool
--cloud-disk-offering-id <uuid>    Disk offering used by importVolume
--cloud-host-id <uuid>             Optional host placement
--cloud-account <name>             Optional target account
--cloud-domain-id <uuid>           Optional target domain
--cloud-project-id <uuid>          Optional target project
```

For later usability, allow names as a convenience only after UUID resolution is implemented:

```text
--cloud-zone <name>
--cloud-service-offering <name>
--cloud-network <name>
--cloud-storage <name>
--cloud-disk-offering <name>
```

Initial implementation should require UUIDs for `run/cutover` and allow name lookup only in `preflight/plan`.

## New library layout

Add:

```text
lib/n2k/cloudstack_api.sh
lib/n2k/target_cloud.sh
```

### `cloudstack_api.sh`

Responsibilities:

- Build signed Cloud API requests.
- Use `HmacSHA256`.
- Poll async jobs through `queryAsyncJobResult`.
- Return compact JSON for callers.
- Redact secrets in diagnostics.

Candidate functions:

```text
n2k_cloud_load_cred_file
n2k_cloud_require_credentials
n2k_cloud_sign_query
n2k_cloud_api_get
n2k_cloud_api_post
n2k_cloud_wait_job
n2k_cloud_response_body
n2k_cloud_api_available
```

Signing rule:

```text
1. Build params including command, apiKey, response=json.
2. Sort parameter names lexicographically.
3. URL-encode values with spaces as %20.
4. Join as name=value pairs.
5. Lowercase the full unsigned request string.
6. HMAC-SHA256 with the secret key.
7. Base64 encode the digest.
8. URL-encode the signature value.
```

### `target_cloud.sh`

Responsibilities:

- Resolve cloud target resources.
- Convert n2k target disk paths into Cloud import paths.
- Validate Cloud API import visibility.
- Import root and data volumes.
- Deploy the VM from the imported root volume.
- Attach data disks.
- Start and verify the VM.
- Record Cloud IDs in the manifest.
- Clean up partially created Cloud resources on failure when safe.

Candidate functions:

```text
n2k_cloud_target_preflight
n2k_cloud_target_disk_import_path
n2k_cloud_target_list_volume_for_import
n2k_cloud_target_import_volume
n2k_cloud_target_deploy_vm_for_volume
n2k_cloud_target_attach_data_volume
n2k_cloud_target_start_vm
n2k_cloud_target_verify_vm
n2k_cloud_target_cutover
n2k_cloud_target_cleanup_plan
```

## Cutover workflow

Cloud API cutover replaces libvirt XML generation.

```text
1. Load manifest and Cloud credentials.
2. Verify final sync is complete.
3. Verify target provider is ablestack-cloud.
4. For every disk:
   - derive Cloud import path
   - call listVolumesForImport(storageid, path)
   - fail if the disk is not visible or is already managed
5. Import root disk:
   - importVolume(storageid, path, name, diskofferingid, account/domain/project)
   - wait for async job
   - record volume ID
6. Deploy VM:
   - deployVirtualMachineForVolume(zoneid, serviceofferingid, volumeid, name, displayname, networkids, hostid, startvm=false)
   - wait for async job
   - record VM ID
7. Import every data disk:
   - importVolume(...)
   - wait for async job
   - record volume ID
8. Attach every data disk:
   - attachVolume(id, virtualmachineid, deviceid)
   - wait for async job
9. Start VM when requested:
   - startVirtualMachine(id)
   - wait for async job
10. Verify:
   - listVirtualMachines(id)
   - expected state is Running when start was requested
11. Mark cutover phase done.
```

Root disk deployment uses `deployVirtualMachineForVolume`, not the normal `deployVirtualMachine`. The imported root volume is initially a `DATADISK` from `importVolume`, and the Cloud implementation converts it into the root device during VM creation.

## Disk mapping

The manifest already knows disk order and target path.

For RBD:

```text
n2k target path:  rbd:rbd/<image>
Cloud import path: <image>
Cloud full path:   rbd/<image>
```

The first disk in manifest order is the root disk unless an explicit root marker is added later.

Data disks should preserve manifest order:

| Manifest disk index | Cloud role | Cloud attach device ID |
| ---: | --- | ---: |
| 0 | ROOT | 0 through deploy API |
| 1 | DATA | 1 |
| 2 | DATA | 2 |
| N | DATA | N |

CloudStack `attachVolume` supports `deviceid`. n2k should pass it for deterministic multi-disk ordering.

## Network mapping

libvirt mode currently has bridge/network options. Cloud mode must use Cloud network IDs.

Initial design:

- Require at least one `--cloud-network-id`.
- Pass all selected IDs as `networkids`.
- Preserve source MAC only after validating Cloud API accepts `macaddress` for the selected network type.
- For L2 networks, use network ID selection and keep IP preservation out of the first implementation.
- For isolated networks, support static IP later through `iptonetworklist`.

This avoids assuming that libvirt `bridge0` maps directly to a Cloud network.

## Firmware and VM details

Source inventory already captures firmware and secure boot where available. Cloud mode should map those fields to `deployVirtualMachineForVolume` parameters or details only where the target API supports them.

Initial mapping:

| Source | Cloud parameter |
| --- | --- |
| BIOS | default boot type |
| UEFI | `boottype=UEFI` |
| Secure Boot | `bootmode=SECURE` if supported |
| TPM | defer until verified |

If the Cloud API rejects a firmware parameter, n2k should fail during preflight or plan rather than during final cutover.

## Failure and rollback policy

Cloud operations are asynchronous and may partially succeed. The manifest must record every Cloud object as soon as it is created.

Suggested manifest state:

```json
{
  "target": {
    "cloud": {
      "vm_id": "",
      "imported_volumes": [
        {
          "disk_id": "disk-0",
          "role": "root",
          "path": "image-name",
          "volume_id": "",
          "state": "imported"
        }
      ],
      "jobs": []
    }
  }
}
```

Rollback behavior:

| Failure point | Safe action |
| --- | --- |
| Before import | Leave target disk image in n2k storage cleanup list |
| Root import succeeds, VM not created | `unmanageVolume`, then optional target image cleanup |
| VM created, data attach fails | Stop/destroy VM only with `--force-cleanup` or explicit cleanup command |
| Data volume imported but not attached | `unmanageVolume` |
| VM started but verification fails | Do not destroy automatically; report manual inspection requirement |

`unmanageVolume` removes CloudStack management of a volume without deleting the underlying disk image. Destructive storage deletion should stay in the n2k cleanup command and should require explicit confirmation or cleanup policy.

## Preflight checks

Cloud target preflight should verify:

- Endpoint reachable.
- API key and secret authenticate with `HmacSHA256`.
- API user is admin or has enough permissions.
- Required APIs exist.
- Zone, service offering, network, storage pool, and disk offering resolve.
- Storage pool type is supported by `importVolume`.
- RBD target path uses a Cloud import-compatible image name.
- `listVolumesForImport` can see a known target image after sync.
- Disk size is at least the selected disk offering minimum.

RBD-specific checks:

- `rbd` command works on the migration host.
- Target pool exists.
- Image names are unique.
- Existing image handling is explicit: reuse only with `--resume`; otherwise fail.

## Test plan

### T0: Auth and inventory smoke

Goal: verify signed API requests.

Expected:

- `listZones` succeeds.
- `listApis` includes required APIs.
- `listStoragePools` sees `Primary Storage Glue RBD`.

### T1: RBD import visibility

Goal: verify n2k disk path to Cloud import path mapping.

Steps:

1. Create a 1 GiB temporary RBD image.
2. Call `listVolumesForImport(storageid, path=<image>)`.
3. Confirm `path=<image>`, `fullpath=rbd/<image>`, `format=raw`.
4. Delete the temporary image.

### T2: RBD import/unmanage round trip

Goal: verify Cloud import workflow before VM creation.

Steps:

1. Create a 1 GiB temporary RBD image.
2. `importVolume`.
3. Poll async job.
4. Confirm volume is `Ready`.
5. `unmanageVolume`.
6. Delete RBD image.
7. Confirm `listVolumes` no longer shows the probe volume.

This test already passed manually in the 22.x lab.

### T3: Single-disk Linux VM full migration

Goal: replace libvirt cutover with Cloud VM creation.

Steps:

1. Run n2k full sync to RBD.
2. Cloud cutover with `deployVirtualMachineForVolume`.
3. Start VM.
4. Verify VM state through `listVirtualMachines`.
5. Verify console or guest boot manually.

### T4: Multi-disk VM migration

Goal: verify data disk attach order.

Steps:

1. Migrate a source VM with at least two data disks.
2. Import root disk.
3. Deploy VM.
4. Import and attach data disks with deterministic `deviceid`.
5. Verify all disks appear in Cloud and guest OS.

### T5: Phase1/Phase2 cutover

Goal: verify the existing minimum-downtime sync pipeline with Cloud target cutover.

Steps:

1. Run `--split phase1`.
2. Run `--split phase2`.
3. Perform final sync.
4. Execute Cloud cutover.
5. Verify VM boot and source snapshot cleanup behavior.

## Implementation order

1. Add `cloudstack_api.sh` with SHA256 signing and async job polling.
2. Add read-only `preflight` support for Cloud target resources.
3. Extend manifest schema with `target.provider` and `target.cloud`.
4. Add `target_cloud.sh` import visibility and import/unmanage helpers.
5. Add `cutover --target-provider ablestack-cloud --define-only` equivalent that performs dry-run validation only.
6. Add actual Cloud cutover for root disk only.
7. Add data disk import and attach.
8. Add `run` integration and phase1/phase2 cutover forwarding.
9. Update help and bash completion.
10. Build RPM and run T0-T5 tests.

## Open decisions

| Decision | Proposed default |
| --- | --- |
| Target provider default | `libvirt` for backward compatibility |
| Cloud disk path for RBD | Use image name, not `/rbd/image` |
| Cloud VM start timing | Create stopped first, attach data disks, then start |
| Secret storage | Runtime env or protected credential file only |
| Auto rollback | Conservative; unmanage unattached volumes, do not destroy started VMs automatically |
| Name resolution | Preflight/plan only at first; run/cutover should use UUIDs |

## Summary

ABLESTACK Cloud API target mode is feasible with the current `ablestack-diplo` API surface. The key implementation path is:

```text
RBD/raw target image
  -> listVolumesForImport
  -> importVolume
  -> deployVirtualMachineForVolume
  -> importVolume + attachVolume for data disks
  -> startVirtualMachine
```

This gives n2k a Cloud-managed VM outcome while preserving the existing Nutanix source handling and target disk sync engine.
