# ablestack_v2k Operational Scenarios

This document lists practical run patterns for `ablestack_v2k`.

## 1. Standard File-Based Migration

Use this for the most common qcow2/file flow.

```bash
ablestack_v2k run \
  --vm <VM> \
  --vcenter <VCENTER> \
  --cred-file <govc.env> \
  --dst <DST> \
  --compat-profile auto \
  --target-format qcow2 \
  --target-storage file
```

## 2. Split-Run Migration

Use this when you want to separate daytime copy traffic from final cutover.

### Phase1

```bash
ablestack_v2k run \
  --split phase1 \
  --vm <VM> \
  --vcenter <VCENTER> \
  --cred-file <govc.env> \
  --dst <DST> \
  --compat-profile auto
```

### Phase2

```bash
ablestack_v2k run \
  --split phase2 \
  --vm <VM> \
  --vcenter <VCENTER> \
  --dst <DST> \
  --compat-profile auto
```

Phase2 reuses `govc.env`, `vddk.cred`, and `compat.env` from the existing workdir.

## 3. Full Real-Environment Sequence

Recommended order for one validation VM:

1. `init --compat-profile auto`
2. `cbt status`
3. `cbt enable`
4. `snapshot base`
5. `sync base`
6. `run --split phase1`
7. `run --split phase2`
8. restore source VM state if needed
9. `run` full

## 4. RBD Target Migration

For Ceph RBD targets:

```bash
ablestack_v2k run \
  --vm <VM> \
  --vcenter <VCENTER> \
  --cred-file <govc.env> \
  --dst <DST> \
  --compat-profile auto \
  --target-format raw \
  --target-storage rbd \
  --target-map-json '{"scsi0:0":"rbd:pool/vm-disk0"}'
```

Notes:

- `rbd` targets use host-side mapped block devices
- mapped paths are recorded in `manifest.runtime.rbd.mapped`
- cutover uses libvirt block-disk XML for mapped RBD devices

## 5. Windows Cutover

For Windows guests, ensure:

- WinPE ISO is present
- VirtIO ISO path is correct
- compatibility profile selection is verified in the manifest before cutover

Typical cutover:

```bash
ablestack_v2k --workdir <workdir> cutover --shutdown guest --define-only
```
