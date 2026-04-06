# ablestack_v2k CLI Guide

## Command Structure

```bash
ablestack_v2k [global options] <command> [command options]
```

## Global Options

| Option | Description |
| --- | --- |
| `--workdir <path>` | Use an explicit work directory |
| `--run-id <id>` | Override the generated run ID |
| `--manifest <path>` | Override the manifest path |
| `--log <path>` | Override the events log path |
| `--json` | Emit machine-readable JSON output |
| `--dry-run` | Skip destructive operations |
| `--resume` | Resume from the existing manifest |
| `--force` | Allow risky operations |

## Commands

| Command | Description |
| --- | --- |
| `run` / `auto` | Orchestrated end-to-end migration pipeline |
| `init` | Create workdir and manifest |
| `cbt` | Query or enable CBT |
| `snapshot` | Create base/incr/final snapshots |
| `sync` | Run base/incr/final transfer |
| `verify` | Run quick verification |
| `cutover` | Run cutover operations |
| `cleanup` | Remove temporary resources |
| `status` | Show manifest and recent event summary |

## Compatibility Profiles

`ablestack_v2k` can select a VMware compatibility runtime automatically.

Supported profile IDs in the current implementation:

- `auto`
- `vsphere60`
- `vsphere67`
- `vsphere80`

Use `--compat-profile auto` for normal operation. The selected profile is saved in the manifest and reused for follow-up commands.

## `run` / `auto`

```bash
ablestack_v2k run [--foreground] [options]
```

Common options:

| Option | Description |
| --- | --- |
| `--vm <name|moref>` | Source VMware VM |
| `--vcenter <host>` | Source vCenter host |
| `--cred-file <file>` | GOVC credential file |
| `--vddk-cred-file <file>` | Explicit VDDK credential file |
| `--dst <path>` | Destination root path |
| `--compat-profile <id|auto>` | Compatibility profile selection |
| `--target-format qcow2|raw` | Output image format |
| `--target-storage file|block|rbd` | Target storage type |
| `--target-map-json <json>` | Required for `block` and `rbd` targets. Block example: `{"scsi0:0":"/dev/sdb"}`. RBD example: `{"scsi0:0":"rbd:pool/vm-disk0"}` |
| `--split full|phase1|phase2` | Split-run mode |
| `--shutdown manual|guest|poweroff` | Source shutdown policy |
| `--kvm-vm-policy none|define-only|define-and-start` | Target KVM policy |

Example:

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

Quoted extra-argument examples:

```bash
ablestack_v2k run \
  --vm my-vm \
  --vcenter vc.example.local \
  --cred-file ./govc.env \
  --dst /var/lib/libvirt/images/my-vm \
  --compat-profile auto \
  --base-args "--jobs 4 --chunk 4194304" \
  --incr-args "--jobs 2 --coalesce-gap 65536" \
  --cutover-args "--define-only --bridge br0 --vcpu 4 --memory 8192"
```

## `init`

```bash
ablestack_v2k init \
  --vm <name|moref> \
  --vcenter <host> \
  --cred-file <file> \
  --dst <path> \
  --compat-profile auto
```

Target map examples:

```bash
ablestack_v2k init \
  --vm <VM> \
  --vcenter <VC> \
  --cred-file ./govc.env \
  --dst <DST> \
  --target-format raw \
  --target-storage block \
  --target-map-json '{"scsi0:0":"/dev/sdb","scsi0:1":"/dev/sdc"}'
```

```bash
ablestack_v2k init \
  --vm <VM> \
  --vcenter <VC> \
  --cred-file ./govc.env \
  --dst <DST> \
  --target-format raw \
  --target-storage rbd \
  --target-map-json '{"scsi0:0":"rbd:pool/vm-disk0","scsi0:1":"rbd:pool/vm-disk1"}'
```

Notes:

- `init` writes `govc.env`, `vddk.cred`, `manifest.json`, and `events.log` into the workdir.
- If only `--cred-file` is given, `init` now derives `vddk.cred` automatically for follow-up sync commands.

## `cbt`

```bash
ablestack_v2k cbt status
ablestack_v2k cbt enable
```

After `init`, `--workdir` is enough. The command restores `govc.env` and `vddk.cred` automatically from the workdir.

## `snapshot`

```bash
ablestack_v2k snapshot base
ablestack_v2k snapshot incr
ablestack_v2k snapshot final
```

Optional flags:

- `--name <snapshot-name>`
- `--safe-mode`

## `sync`

```bash
ablestack_v2k sync base --jobs 1
ablestack_v2k sync incr --jobs 1
ablestack_v2k sync final --jobs 1
```

Optional flags:

- `--jobs <N>`
- `--coalesce-gap <bytes>`
- `--chunk <bytes>`
- `--force-cleanup`
- `--safe-mode`

## `verify`

```bash
ablestack_v2k verify --mode quick --samples 64
```

## `cutover`

```bash
ablestack_v2k cutover --shutdown guest --define-only
```

Important options:

- `--shutdown manual|guest|poweroff`
- `--define-only`
- `--start`
- `--vcpu <N>`
- `--memory <MB>`
- `--network <name>`
- `--bridge <br>`
- `--vlan <id>`
- `--winpe-bootstrap`
- `--no-winpe-bootstrap`
- `--winpe-iso <path>`
- `--virtio-iso <path>`

## `cleanup`

```bash
ablestack_v2k cleanup
ablestack_v2k cleanup --keep-snapshots --keep-workdir
```

## `status`

```bash
ablestack_v2k status
```

This reads the manifest and recent `events.log` entries and shows:

- phase completion state
- selected compatibility profile
- disk CBT state
- recent sync issues
