# ablestack_n2k interactive migration design

## Purpose

This document describes the interactive migration command for `ablestack_n2k`.
The goal is to let an operator migrate a Nutanix VM by answering only the
minimum required questions while the tool discovers or derives the rest of the
runtime options.

The interactive command must not become a separate migration engine. It is a
thin operator-facing wrapper that collects inputs, resolves target resources,
builds a normal `ablestack_n2k run` argument list, shows a summary, and then
either prints or executes that run.

## Relation to existing designs

The command follows the same boundaries as the existing n2k designs:

- Source data movement remains the v3 snapshot/NFS data path until a verified
  v4 byte source exists.
- PC v4 discovery and PE v3 fallback behavior remain in the existing preflight
  and run path.
- ABLESTACK Cloud target creation uses the Cloud API target design:
  `importVolume`, `deployVirtualMachineForVolume`, `updateVolume` when needed,
  `attachVolume`, and `startVirtualMachine`.
- Secrets are runtime-only. They are never written to the manifest, generated
  docs, printed command, or logs.
- Cloud RBD remains the preferred target profile. Cloud FileSystem/qcow2 is the
  secondary profile. Cloud block/LVM is intentionally out of scope for this
  version.

## CLI surface

Add one implementation with three command names:

```text
ablestack_n2k wizard
ablestack_n2k migrate
ablestack_n2k interactive
```

All three command names call the same `n2k_cmd_wizard` function.

The command accepts the normal source and target options so it can be partially
or fully preseeded:

```text
--pc <host-or-url>
--vm <name-or-uuid>
--username <user>
--password <password>
--cred-file <file>
--insecure <0|1>

--target-profile <profile>
--target-provider <libvirt|ablestack-cloud>
--target-storage <rbd|file>
--target-format <raw|qcow2>
--dst <path>
--target-map-json <json>
--rbd-pool <pool>
--file-root <path>

--cloud-endpoint <url>
--cloud-api-key <key>
--cloud-secret-key <key>
--cloud-cred-file <file>
--cloud-zone-id <uuid>
--cloud-service-offering-id <uuid>
--cloud-network-id <uuid>
--cloud-network-ids <csv>
--cloud-storage-id <uuid>
--cloud-disk-offering-id <uuid>
--cloud-host-id <uuid>
--cloud-account <name>
--cloud-domain-id <uuid>
--cloud-project-id <uuid>
--cloud-name <name>
--cloud-display-name <name>
--cloud-cpu-speed <mhz>

--split <phase1|phase2|full>
--shutdown <guest|poweroff|manual|none>
--define-only
--apply
--start
--source-api <v3>
--force-v3
--yes
--print-command
```

## Target profiles

The profile is the operator-friendly selector. It expands to the lower-level
run options:

| Profile | Provider | Storage | Format | Notes |
| --- | --- | --- | --- | --- |
| `cloud-rbd` | `ablestack-cloud` | `rbd` | `raw` | Default and preferred profile |
| `cloud-filesystem` | `ablestack-cloud` | `file` | `qcow2` | Uses Cloud FileSystem primary storage and host placement |
| `cloud-qcow2` | `ablestack-cloud` | `file` | `qcow2` | Alias for `cloud-filesystem` |
| `libvirt-rbd` | `libvirt` | `rbd` | `raw` | Existing libvirt RBD target path |
| `libvirt-qcow2` | `libvirt` | `file` | `qcow2` | Existing libvirt file target path |

Cloud block/LVM is not exposed in the wizard because the Cloud target path does
not support block/LVM import yet.

## Operator flow

1. Resolve source credentials from CLI options, environment, or credential file.
2. Prompt for missing Prism endpoint, source username, and source password.
3. If `--vm` was not supplied, list Nutanix VMs through v4, v3, then v2 fallback
   and let the operator select a VM by number.
4. Select a target profile. The default is `cloud-rbd`.
5. For Cloud profiles, resolve Cloud credentials from CLI options, environment,
   or credential file.
6. For missing Cloud IDs, query Cloud API resources and prompt only when there
   is more than one valid choice. A single resource is selected automatically.
7. Derive VM name, target disk paths, CPU speed, shutdown policy, network mode,
   and cutover action from defaults.
8. Show a summary that contains no secrets.
9. Ask for final confirmation unless `--yes` or `--print-command` is used.
10. Execute `n2k_cmd_run` with the generated arguments, or print the generated
    command with secret values redacted.

Free-form prompts show an example value or a short input hint. Resource prompts
show a numbered list when more than one candidate exists; operators can enter
the list number, the resource ID, or the exact resource name. This avoids
requiring operators to copy UUIDs from another screen during the common path.

## Default behavior

The defaults are chosen to match the current tested production path:

| Field | Default |
| --- | --- |
| Target profile | `cloud-rbd` |
| Source API | `v3` with `--force-v3` |
| Migration split | `phase1` |
| Cutover action | `--apply --start` |
| Source shutdown | `guest` |
| Cloud CPU speed | `1000` |
| Cloud target VM name | prompt with default `n2k-<source-vm>-<timestamp>` |
| Migration work directory | `/var/lib/ablestack-n2k/<source-vm>/<run-id>` |
| RBD pool | `rbd` |
| File root | libvirt targets use `/var/lib/libvirt/images`; Cloud file targets use the selected Cloud storage pool path |
| Libvirt network | `bridge` with `bridge0` |

`phase1` is the default because the preferred production path is incremental
migration with a short final cutover. Operators can select `phase2` later with
the same workdir or manifest, or select `full` for a single-command validation
run.

For a new `phase1` or `full` run, the wizard does not require operators to
pre-create or pre-type a global `--workdir`. It generates a default work
directory after the source VM is known, prompts for confirmation in interactive
mode, and accepts the default automatically with `--yes`. For `phase2`, the
wizard must resume existing state, so it prompts for an existing work directory
when neither global `--workdir` nor global `--manifest` was provided.

For a new Cloud target run, the wizard also prompts for the target VM name. The
default remains `n2k-<source-vm>-<timestamp>`, but the operator can replace it
before the target disk names and Cloud VM metadata are derived. When resuming
from a manifest for `phase2`, the stored target VM name is reused without
renaming the migration.

When a manifest exists through global `--workdir` or `--manifest`, the wizard
loads source VM, Prism endpoint, target provider, target storage, and Cloud
resource IDs from that manifest before prompting. If the manifest has
`runtime.split.phase1.done=true` and `runtime.split.phase2.done!=true`, the
wizard defaults to `phase2`. This supports the required operator workflow:

```text
ablestack_n2k --workdir /var/lib/ablestack-n2k/rhel/<run-id> wizard --split phase1 ...
# process exits after phase1
ablestack_n2k --workdir /var/lib/ablestack-n2k/rhel/<run-id> wizard --split phase2 ...
```

The second command is a new process. It resumes from the manifest rather than
from any in-memory state.

## Resource discovery

The wizard uses existing API helpers and adds only light list/selection logic:

- Nutanix VM list:
  - `GET /api/vmm/v4.0/ahv/config/vms?$limit=100`
  - `POST /api/nutanix/v3/vms/list`
  - `GET /PrismGateway/services/rest/v2.0/vms`
- Cloud resource list:
  - `listZones`
  - `listServiceOfferings`
  - `listNetworks`
  - `listStoragePools`
  - `listHosts`

When a required value is supplied by option or environment, the wizard does not
override it. When an API list has exactly one item, that item is selected
without prompting. When multiple items exist, the operator chooses by number.
When running with `--yes` and a required multi-choice value is missing, the
wizard fails instead of guessing.

## Target map generation

For Cloud FileSystem/qcow2, the wizard must first resolve the selected Cloud
storage pool through `listStoragePools`. The resolved storage pool `path` is the
file root. The wizard then uses root-level qcow2 paths under that Cloud storage
path:

```text
/mnt/glue-gfs/<target-name>-disk0.qcow2
/mnt/glue-gfs/<target-name>-disk1.qcow2
```

The literal path is environment-dependent; `/mnt/glue-gfs` is an example from
the 10.10.1.x SharedMountPoint test environment. The wizard must not fall back
to `/var/lib/libvirt/images` for Cloud file targets unless that is the path
returned by Cloud for the selected storage pool. This avoids Cloud import
visibility problems caused by writing qcow2 files outside the selected Cloud
primary storage or inside arbitrary subdirectories.

For Cloud RBD and libvirt RBD, the wizard uses:

```text
rbd:<pool>/<target-name>-disk0
rbd:<pool>/<target-name>-disk1
```

If the wizard can fetch the normalized source inventory, it emits a
`--target-map-json` keyed by source disk IDs. Otherwise it falls back to the
existing `--dst` generation rules and lets `run/init` validate the result.

## Safety rules

- The wizard fails on non-TTY input unless all required values are supplied or
  `--yes` can safely accept a single available choice.
- It never persists source passwords, Cloud API keys, or Cloud secret keys.
- `--print-command` redacts secret-bearing arguments.
- The final summary always shows target provider, storage, Cloud resources,
  split mode, shutdown policy, and cutover action before execution.
- Existing non-interactive commands remain unchanged.

## Implementation files

Add:

```text
lib/n2k/interactive.sh
docs/n2k/ablestack_n2k_interactive_migration_design.md
```

Update:

```text
bin/ablestack_n2k.sh
lib/n2k/engine.sh
completions/ablestack_n2k
```

The implementation must call `n2k_cmd_run` internally. It must not duplicate
snapshot, sync, cutover, cleanup, or Cloud deployment logic.
