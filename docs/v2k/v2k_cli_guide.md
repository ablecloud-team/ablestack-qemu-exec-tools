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
| --target-format | `qcow2` / `raw` |
| --target-storage | `file` / `block` / `rbd` |
| --target-map-json | block / rbd 대상 디스크 매핑 JSON |
| --shutdown | manual / guest / poweroff |
| --split | full / phase1 / phase2 |
| --incr-interval | Increment interval |
| --max-incr | Max incr loops |

## init

```bash
ablestack_v2k init --vm <VM> --vcenter <VC> --dst <DST>
```

RBD 예시:

```bash
ablestack_v2k init \
  --vm <VM> \
  --vcenter <VC> \
  --dst <DST> \
  --target-format raw \
  --target-storage rbd \
  --target-map-json '{"scsi0:0":"rbd:rbd/vm-disk0"}'
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

RBD cutover 시 참고:

- cutover 직전에 `rbd map`으로 `/dev/rbd/<pool>/<image>`를 준비
- libvirt XML은 `<disk type='block'>`로 생성
- mapped 경로는 `manifest.runtime.rbd.mapped`에 기록
- VM 기동 이후 활성 RBD map은 자동 unmap하지 않음

## cleanup

```bash
ablestack_v2k cleanup
```

## status

```bash
ablestack_v2k status
```
