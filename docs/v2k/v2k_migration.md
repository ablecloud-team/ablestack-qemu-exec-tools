# ablestack_v2k Overview

`ablestack_v2k` is a VMware-to-KVM migration CLI for ABLESTACK environments.

It supports:

- VMware CBT-based base, incremental, and final sync
- `file`, `block`, and `rbd` target storage modes
- split-run workflows (`phase1` / `phase2`)
- WinPE-assisted Windows cutover
- manifest-driven resume and status inspection
- compatibility-profile based runtime selection for different vCenter generations

## Main Components

| File | Role |
| --- | --- |
| `bin/ablestack_v2k.sh` | CLI entrypoint |
| `lib/v2k/engine.sh` | command execution engine |
| `lib/v2k/orchestrator.sh` | `run` / `auto` orchestration |
| `lib/v2k/manifest.sh` | manifest creation and mutation |
| `lib/v2k/logging.sh` | `events.log` writer |
| `lib/v2k/vmware_govc.sh` | VMware integration via `govc` |
| `lib/v2k/transfer_base.sh` | base transfer logic |
| `lib/v2k/transfer_patch.sh` | incremental/final transfer logic |
| `lib/v2k/compat.sh` | compatibility profile selection and runtime wrappers |

## Compatibility Profiles

The runtime can select a profile automatically based on the detected vCenter version.

Current profile IDs:

- `vsphere60`
- `vsphere67`
- `vsphere80`

Each profile owns:

- `govc`
- `python3` / `pyVmomi`
- `VDDK`

Installed profile root:

```text
/usr/share/ablestack/v2k/compat/<profile>/
```

The selected profile is written into:

- `manifest.json`
- `compat.env`

## Minimal Example

```bash
ablestack_v2k run \
  --vm my-vm \
  --vcenter vc.example.local \
  --cred-file ./govc.env \
  --dst /var/lib/libvirt/images/my-vm \
  --compat-profile auto \
  --target-format qcow2 \
  --target-storage file
```

## Real-World Validation Status

The current implementation has been validated in the following order:

- installer-managed compatibility profile install
- `init --compat-profile auto`
- `cbt status`
- `cbt enable`
- `snapshot base`
- `sync base`

For split/full orchestration validation, use the operational sequence in `v2k_scenaris.md`.
