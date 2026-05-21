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

`ablestack_v2k` already has VMware-specific strengths that should remain intact:

- VMware CBT enablement and changed-block sync through VDDK.
- vCenter/govc compatibility profiles.
- `phase1`/`phase2` split-run and fleet execution.
- Windows WinPE and Linux initramfs bootstrap for libvirt targets.

The missing pieces are mostly target orchestration and UX, not VMware data-plane
replacement.

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
5. Import disk 0 as the root volume.
6. Deploy the VM from the imported root volume.
7. Ensure/convert the root volume type to `ROOT` if Cloud returns it as data.
8. Import and attach remaining disks as data volumes.
9. Optionally start the VM.
10. Record Cloud VM/volume/job IDs in `runtime.cloud`.

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

1. Add v2k Cloud API and target helper libraries.
2. Extend v2k manifest schema with provider/Cloud fields.
3. Extend `init`, `run`, and `cutover` to parse and forward provider/Cloud
   options.
4. Add wizard entrypoint and help text.
5. Add focused smoke checks:
   - `bash -n` for changed shell files.
   - Help output for `wizard`, `run`, `init`, and `cutover`.
   - Manifest JSON generation path with dry/fixture-style inputs where possible.

## Non-goals For This Pass

- Replacing VMware CBT/VDDK transfer logic.
- Changing the default v2k `run` behavior.
- Cloud LVM/block target support.
- Persisting API keys/secrets in manifest or docs.
- Full fleet wizard support.
