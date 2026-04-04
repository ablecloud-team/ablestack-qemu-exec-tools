# events.log Format

`events.log` is written as JSON Lines.

Each line is a single event object.

## Current Event Shape

```json
{
  "ts": "2026-04-05T00:00:00+09:00",
  "run_id": "20260405-000000-abcdef12",
  "level": "INFO",
  "phase": "init",
  "disk_id": "",
  "event": "phase_start",
  "detail": {
    "vm": "my-vm"
  }
}
```

## Fields

| Field | Meaning |
| --- | --- |
| `ts` | RFC3339 timestamp |
| `run_id` | run identifier, or `unknown` for commands without an active run ID |
| `level` | `INFO`, `WARN`, `ERROR` |
| `phase` | logical phase such as `init`, `sync.base`, `cutover`, `runtime` |
| `disk_id` | disk identifier such as `scsi0:0`, or empty string |
| `event` | event name |
| `detail` | event-specific JSON object |

## Typical Events

Examples:

```json
{"phase":"init","event":"phase_start","detail":{"vm":"demo-vm"}}
{"phase":"cbt_enable","event":"phase_done","detail":{}}
{"phase":"sync.base","event":"disk_done","detail":{"target":"/var/lib/libvirt/images/demo-vm-disk0.qcow2"}}
{"phase":"cutover","event":"phase_done","detail":{}}
{"phase":"runtime","event":"force_block_device","detail":{"enabled":false}}
```

## How To Use It

- inspect progress during long-running sync operations
- correlate failures with `manifest.json`
- confirm split-run state transitions
- confirm compatibility-profile related behavior during `init`
