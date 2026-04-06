# manifest.json Specification

`manifest.json` is the source of truth for a `ablestack_v2k` run.

It records:

- source VM metadata
- target storage settings
- disk mapping state
- phase completion state
- runtime compatibility selection
- resume metadata

## Top-Level Shape

```json
{
  "schema": "ablestack-v2k/manifest-v1",
  "run": {},
  "source": {},
  "target": {},
  "disks": [],
  "phases": {},
  "runtime": {}
}
```

## Important Fields

| Path | Meaning |
| --- | --- |
| `run.run_id` | unique run identifier |
| `run.workdir` | workdir path |
| `source.vm` | source VM metadata |
| `source.vddk` | VDDK connection metadata |
| `source.compat` | selected compatibility profile and tool paths |
| `target.storage` | file/block/rbd target settings |
| `disks[]` | per-disk transfer state |
| `phases` | phase completion markers |
| `runtime` | resume, split-run, and sync-issue metadata |

## Compatibility Block

Current runtime writes compatibility details into `source.compat`.

Example:

```json
{
  "source": {
    "compat": {
      "requested_profile": "auto",
      "selected_profile": "vsphere80",
      "detected_vcenter_version": "8.0.1",
      "compat_root": "/usr/share/ablestack/v2k/compat",
      "tools": {
        "govc_bin": "/usr/share/ablestack/v2k/compat/vsphere80/bin/govc",
        "python_bin": "/usr/share/ablestack/v2k/compat/vsphere80/venv/bin/python3",
        "vddk_libdir": "/usr/share/ablestack/v2k/compat/vsphere80/vddk"
      }
    }
  }
}
```

## Phase Markers

Example:

```json
{
  "phases": {
    "init": { "done": true, "ts": "..." },
    "cbt_enable": { "done": true, "ts": "..." },
    "base_sync": { "done": true, "ts": "..." },
    "incr_sync": { "done": false, "ts": "" },
    "final_sync": { "done": false, "ts": "" },
    "cutover": { "done": false, "ts": "" }
  }
}
```

## Runtime Split State

Example:

```json
{
  "runtime": {
    "split": {
      "phase1": { "done": true, "ts": "..." },
      "phase2": { "done": false, "ts": "" }
    }
  }
}
```

## RBD Runtime State

For `target.storage.type=rbd`, mapped host block devices are recorded under:

```json
{
  "runtime": {
    "rbd": {
      "mapped": {
        "scsi0:0": {
          "uri": "rbd:rbd/vm-disk0",
          "dev_path": "/dev/rbd/rbd/vm-disk0",
          "mapped": true,
          "ts": "2026-04-05T00:00:00+09:00"
        }
      }
    }
  }
}
```

## Resume Model

The following files are expected inside the workdir:

- `manifest.json`
- `events.log`
- `govc.env`
- `vddk.cred`
- `compat.env`

Follow-up commands now restore `govc.env` and `vddk.cred` automatically from the workdir.
