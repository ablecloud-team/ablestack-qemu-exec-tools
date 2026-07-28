# V2K N2K Alignment Design

## Purpose

Improve `ablestack_v2k` with the newer migration flow patterns that were added to
`ablestack_n2k`, while preserving the existing VMware CBT/VDDK procedure and
current command contracts.

The compatibility goal is conservative:

- Existing `ablestack_v2k run/init/snapshot/sync/cutover/status` invocations must
  continue to default to the current libvirt target flow.
- New Cloud target behavior is opt-in through `--target-provider ablestack-cloud`
  or the new wizard target profiles.
- Secrets remain runtime-only or in operator-provided credential files. They must
  not be written to the manifest.

## Current Gap

`ablestack_n2k` now has a newer operator flow:

- `wizard/migrate/interactive` entrypoint with minimum required prompts.
- Target profiles such as Cloud RBD, Cloud FileSystem, libvirt RBD, and libvirt
  qcow2.
- ABLESTACK Cloud API target cutover using `importVolume`,
  `deployVirtualMachineForVolume`, `attachVolume`, and `startVirtualMachine`.
- Automatic writeback disk offering resolution/creation.
- Manifest-based target provider and Cloud runtime result recording.
- More explicit resume/status state around split `phase1` and `phase2`.
- Source NIC MAC carry-over for the default Cloud network.

`ablestack_v2k` already has VMware-specific strengths that should remain intact:

- VMware CBT enablement and changed-block sync through VDDK.
- vCenter/govc compatibility profiles.
- `phase1`/`phase2` split-run and fleet execution.
- Windows WinPE and Linux initramfs bootstrap for libvirt targets.

The missing pieces are mostly target orchestration and UX, not VMware data-plane
replacement.

The original alignment left two NIC-related gaps:

- Wizard network selection returned only one Cloud network even when the source
  VM had multiple NICs.
- v2k inventory preserved source MAC addresses, but the Cloud deployment request
  did not pass them. Copying the n2k `macaddress` behavior would preserve only
  the first/default NIC and is not sufficient for multi-NIC migration.

## Target Architecture

### Provider Model

Add a provider field to the v2k manifest:

```json
{
  "target": {
    "provider": "libvirt",
    "cloud": {}
  }
}
```

Provider values:

- `libvirt`: default and current behavior.
- `ablestack-cloud`: ABLESTACK Cloud API cutover.

For a Cloud target, the manifest also freezes the ordered source-NIC-to-network
mapping:

```json
{
  "target": {
    "cloud": {
      "network_ids": ["network-a", "network-b"],
      "nic_mappings": [
        {
          "source_index": 0,
          "source_key": "4000",
          "source_label": "Network adapter 1",
          "source_network": "VM Network",
          "mac": "52:54:00:12:34:56",
          "network_id": "network-a",
          "default": true
        },
        {
          "source_index": 1,
          "source_key": "4001",
          "source_label": "Network adapter 2",
          "source_network": "Backup Network",
          "mac": "52:54:00:65:43:20",
          "network_id": "network-b",
          "default": false
        }
      ]
    }
  }
}
```

Source NICs are ordered by VMware device key. `network_ids` must contain exactly
one unique Cloud network ID per source NIC in that order. The first mapping is
the Cloud default NIC.

### Cloud Target Flow

For `target.provider == "ablestack-cloud"`:

1. Validate Cloud credentials and required target config.
2. Validate each migrated disk is visible to Cloud `listVolumesForImport`.
3. Resolve the selected primary storage pool.
4. If no explicit disk offering is supplied, resolve or create a writeback
   offering:
   - Shared storage: `V2K Migration Writeback`
   - Host-local storage: `V2K Migration Writeback Local`
   - Required: `customized=true`, `cachemode=writeback`, active, no tags
5. Validate source NIC count, unique target networks, and valid unique unicast
   source MAC addresses.
6. Import disk 0 as the root volume.
7. Deploy the stopped VM from the imported root volume using
   `iptonetworklist[n].networkid` and `iptonetworklist[n].mac`. Do not combine
   `iptonetworklist` with `networkids`.
8. Read the deployed VM NICs with `listVirtualMachines` and verify every target
   network/MAC pair plus the default NIC before continuing. A mismatch leaves
   the VM stopped.
9. Ensure/convert the root volume type to `ROOT` if Cloud returns it as data.
10. Import and attach remaining disks as data volumes.
11. Optionally start the VM.
12. Record Cloud VM/volume/job IDs and NIC verification in `runtime.cloud`.

The Cloud path initially supports the target storage types that Cloud import can
consume from migrated artifacts:

- `file`/`qcow2`: migrated files must be root-level files under the selected
  file-backed primary storage path.
- `rbd`/`raw`: import path is the image name derived from the `rbd:pool/image`
  target path.

Cloud LVM/block is explicitly out of scope for this phase.

### CLI Additions

Extend these existing commands:

- `init`: accept `--target-provider` and Cloud config options and persist only
  non-secret Cloud target metadata into the manifest.
- `run`: forward provider/Cloud options to `init` and `cutover`.
- `cutover`: dispatch to Cloud target when the manifest provider is
  `ablestack-cloud`; keep libvirt path unchanged otherwise.

Add:

- `wizard`, aliases `migrate` and `interactive`.

Wizard responsibilities:

- Prompt for vCenter and source VM when omitted.
- Prompt/select migration split, defaulting to `phase1`.
- Prompt/select target profile:
  - `cloud-rbd`
  - `cloud-filesystem`
  - `libvirt-rbd`
  - `libvirt-qcow2`
- Prompt/list Cloud zone, service offering, network, storage pool, and host when
  needed.
- Read source NIC label, MAC, VMware network/backing, and connection state.
- Prompt for one unique Cloud network per source NIC and show the ordered
  mapping in the final summary.
- Derive workdir, target VM name, `dst`, and target map where possible.
- Show a summary and optionally print the generated `run --foreground` command
  with secrets redacted.

### Resume and Status Follow-up

The first implementation keeps existing v2k status behavior. A later pass should
normalize duplicate split-marker helpers and add a v2k resume summary similar to
n2k:

- `phase1 done -> run --split phase2`
- `final_sync done -> cutover`
- `cutover done -> cleanup`

## Implementation Plan

1. Keep the existing v2k Cloud API and provider dispatch.
2. Enrich VMware NIC inventory with label, backing network, portgroup/switch
   identifiers, and connection state.
3. Derive and persist ordered `target.cloud.nic_mappings` during `init`.
4. Extend the wizard to select one Cloud network for each source NIC.
5. Generate per-NIC `iptonetworklist` Cloud parameters and verify deployed NICs
   before root conversion, data-volume attachment, or VM start.
6. Add focused smoke checks:
   - `bash -n` for changed shell files.
   - Help output for `wizard`, `run`, `init`, and `cutover`.
   - Two-NIC inventory metadata extraction.
   - Ordered manifest mapping and per-NIC Cloud request generation.
   - NIC/network count mismatch, duplicate networks, invalid/non-unicast MAC,
     and post-deploy mismatch failures.

## Non-goals For This Pass

- Replacing VMware CBT/VDDK transfer logic.
- Changing the default v2k `run` behavior.
- Cloud LVM/block target support.
- Persisting API keys/secrets in manifest or docs.
- Full fleet wizard support.
- Automatically matching VMware portgroup names to Cloud network names.
- Silently generating or accepting a replacement MAC when Cloud reports a
  conflict.
