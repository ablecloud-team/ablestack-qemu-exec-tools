# ablestack_v2k CLI Guide

## Command Structure

```bash
ablestack_v2k [global options] <command> [command options]
```

## Global Options

| Option | Description |
|------|-------------|
| --workdir | Working directory |
| --run-id | Execution run ID |
| --manifest | Manifest path |
| --log | Events log path |
| --json | JSON output |
| --dry-run | No execution |
| --resume | Resume |
| --force | Allow risky operations |

## Commands

| Command | Description |
|--------|-------------|
| run / auto | Full automated pipeline |
| init | Initialize |
| cbt | CBT control |
| snapshot | base / incr / final |
| sync | base / incr / final |
| verify | Verification |
| cutover | VM cutover |
| cleanup | Cleanup |
| status | Status |

## run / auto

```bash
ablestack_v2k run [options]
```

Key options:

| Option | Description |
|-------|-------------|
| --vm | VMware VM |
| --vcenter | vCenter |
| --dst | Destination |
| --shutdown | manual / guest / poweroff |
| --split | full / phase1 / phase2 |
| --incr-interval | Increment interval |
| --max-incr | Max incr loops |

## init

```bash
ablestack_v2k init --vm <VM> --vcenter <VC> --dst <DST>
```

## snapshot / sync

```bash
ablestack_v2k snapshot base|incr|final
ablestack_v2k sync base|incr|final
```

## cutover

```bash
ablestack_v2k cutover --shutdown guest --start
```

## cleanup

```bash
ablestack_v2k cleanup
```

## status

```bash
ablestack_v2k status
```
