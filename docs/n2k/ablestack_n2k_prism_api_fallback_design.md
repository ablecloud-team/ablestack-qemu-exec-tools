# ablestack_n2k Prism API fallback design

## Background

`ablestack_n2k` migrates Nutanix AHV virtual machines to ABLESTACK KVM/libvirt hosts. The current `feature/ablestack_n2k` branch can build and install an RPM, but API inventory discovery was verified against a local Nutanix test environment before deeper migration testing.

Test date: 2026-05-13

## Test Environment

- Prism endpoint: `https://10.10.131.11:9440`
- Prism account: `admin`
- Credential handling: do not commit or persist passwords; pass secrets through environment variables, protected credential files, or the operator shell.
- Cluster name: `test1`
- Cluster UUID: `00065195-1260-564e-7bd8-020100cc00bb`
- AOS version: `6.5.2`
- Full version: `el7.3-release-fraser-6.5.2-stable-f2ce4db7d67f495ebfd6208bef9ab0afec9c74af`
- Node count: `1`
- Hypervisor type: `kKvm`
- Cluster external IP: `10.10.131.10`
- Test VMs discovered through Prism v2/v3 APIs:
  - `test`
  - `rhel`
  - `windows11`
  - `winsvr2022`

ABLESTACK target hosts used for reachability checks:

- `10.10.22.1`, SSH port `10022`
- `10.10.22.2`, SSH port `10022`
- `10.10.22.3`, SSH port `10022`

All three target hosts can reach `https://10.10.131.11:9440`.

## Observed API Behavior

The Prism UI responds with HTTP `302` to `/console/`.

Working endpoints:

- `GET /PrismGateway/services/rest/v1/cluster` -> HTTP `200`
- `GET /PrismGateway/services/rest/v2.0/cluster` -> HTTP `200`
- `GET /PrismGateway/services/rest/v2.0/vms` -> HTTP `200`, 4 VM entities
- `POST /api/nutanix/v3/clusters/list` -> HTTP `200`, 1 cluster entity
- `POST /api/nutanix/v3/vms/list` -> HTTP `200`, 4 VM entities

Non-working endpoint in this environment:

- `GET /api/vmm/v4.0/ahv/config/vms?$limit=100` -> HTTP `404`

Current `init --inventory-source api` behavior calls only the v4 VMM endpoint. Against this AOS 6.5.2 Prism Element environment, that makes VM inventory discovery fail even though v2/v3 APIs can list the VMs.

Observed smoke result:

```text
n2k_init_api=failed rc=4
curl: (22) The requested URL returned error: 404
VM not found in v4 VM list response: test
```

## Problem

The current API inventory implementation assumes v4 VMM API availability. That is too narrow for the expected migration environments, especially Prism Element or older AOS versions where v2/v3 APIs are available but v4 VMM routes are not.

This prevents `ablestack_n2k init --inventory-source api` from creating a manifest from real Nutanix inventory on the current testbed.

## Design Goals

- Keep the v4 VMM API as the first choice when it is available.
- Fall back to Prism v3 VM list when v4 returns `404`, `405`, or another endpoint-not-supported response.
- Fall back to Prism v2 VM list when v3 is unavailable or does not include enough VM details.
- Normalize v4, v3, and v2 VM payloads through the existing `n2k_nutanix_inventory_from_raw` function when possible.
- Preserve the current `--inventory-json` and `--inventory-file` fixture paths for repeatable tests.
- Avoid committing or logging passwords.
- Return clear diagnostics that identify which API family was used or why discovery failed.

## Proposed API Selection

For `n2k_nutanix_fetch_vm_inventory`:

1. Request v4 VM list:
   - `GET /api/vmm/v4.0/ahv/config/vms?$limit=100`
   - Select by VM name or UUID-like ID.
2. If v4 is unsupported, request v3 VM list:
   - `POST /api/nutanix/v3/vms/list`
   - Body: `{"kind":"vm","length":100}`
   - Select by `.spec.name`, `.status.name`, `.metadata.uuid`, or `.uuid`.
3. If v3 is unsupported or insufficient, request v2 VM list:
   - `GET /PrismGateway/services/rest/v2.0/vms`
   - Select by `.name`, `.uuid`, or `.vm_id`.
4. Emit an error that includes attempted API families if no matching VM is found.

## Payload Normalization Notes

The existing jq normalizer already checks several possible field shapes:

- names: `.name`, `.spec.name`, `.status.name`
- IDs: `.extId`, `.ext_id`, `.metadata.uuid`, `.uuid`
- disks: `.disks`, `.disk_list`, `.resources.disk_list`, `.status.resources.disk_list`
- NICs: `.nics`, `.nic_list`, `.resources.nic_list`, `.status.resources.nic_list`
- power and resource fields across direct, `resources`, and `status.resources` forms

The fallback implementation should wrap the selected v3/v2 entity in a shape that the existing normalizer can consume, or extend the normalizer only where the observed payload requires it.

## Test Plan

Use the WSL Rocky 9.7 test workspace:

```bash
cd /root/work/ablestack-qemu-exec-tools
```

Connectivity/API probe:

```bash
NUTANIX_USERNAME=admin \
NUTANIX_PASSWORD='<secret>' \
/root/work/tools/nutanix_probe.py --base https://10.10.131.11:9440
```

Expected probe result for the current testbed:

- v2 cluster: HTTP `200`
- v2 VMs: HTTP `200`, 4 entities
- v3 clusters/list: HTTP `200`
- v3 vms/list: HTTP `200`, 4 entities
- v4 VMM VMs: HTTP `404`

Smoke test after code changes:

```bash
export N2K_WORKDIR=/root/work/n2k-smoke/test-api
rm -rf "$N2K_WORKDIR"
./bin/ablestack_n2k.sh init \
  --vm test \
  --pc 10.10.131.11 \
  --username admin \
  --password '<secret>' \
  --insecure 1 \
  --inventory-source api \
  --dst /tmp/n2k-test-dst
jq . "$N2K_WORKDIR/manifest.json"
```

Expected result:

- `init` succeeds.
- `manifest.json` is created.
- `manifest.json` includes VM inventory for `test`.
- Events include an inventory-loaded record.

Packaging and deployment after validation:

```bash
make n2k-rpm
```

Then reinstall the rebuilt RPM on:

- `10.10.22.1:10022`
- `10.10.22.2:10022`
- `10.10.22.3:10022`

## Open Follow-Up

After inventory fallback works, run real migration phase testing per VM type:

- Linux VM: `rhel`
- Windows desktop VM: `windows11`
- Windows server VM: `winsvr2022`
- General test VM: `test`

## Implementation Result

Implemented and smoke-tested on 2026-05-13.

- `init --inventory-source api` now falls back from v4 to v3 and then v2.
- The current testbed uses v3 for VM inventory because v4 VMM returns HTTP `404`.
- v3 disk payloads are normalized from `status.resources.disk_list`.
- v3 CDROM entries are excluded from migration disks.
- v3 NIC payloads are normalized from `status.resources.nic_list`.
- Installed RPM path resolution was fixed so `/usr/local/bin/ablestack_n2k` can source libraries from `/usr/local/lib/ablestack-qemu-exec-tools/n2k`.
- Event logging payload default handling was fixed so valid JSON payloads are not recorded as `{"invalid_payload":true}`.
- Source-map and changed-region jq variables no longer use `$label`, avoiding a jq keyword conflict.

Smoke results:

- Source tree fixture smoke: passed.
- Source tree API init smoke: passed for `test`, `rhel`, `windows11`, `winsvr2022`.
- Rebuilt RPM install smoke: passed on `10.10.22.1`, `10.10.22.2`, `10.10.22.3`.
