# ablestack_vm_ftctl Failover and Failback

## 1. Failover

### HA/DR

Current behavior:

1. fencing
2. standby activate
3. standby boot verify
4. active side promotion to secondary

Command:

```bash
ablestack_vm_ftctl failover --vm <vm> --force
```

If the policy is manual fencing:

```bash
ablestack_vm_ftctl fence-confirm --vm <vm>
```

### FT/x-colo

Current behavior:

1. fencing
2. `x-colo-lost-heartbeat`
3. secondary promotion

## 2. Failback

### HA/DR

Current behavior:

- `failback --force` is now a one-shot full failback path for `ha` and `dr`.
- The engine performs:
  1. reverse sync start
  2. reverse sync completion wait
  3. cutback to the original primary side
  4. steady-state return to `protected / mirroring`

Command:

```bash
ablestack_vm_ftctl failback --vm <vm> --force
```

Preconditions:

- `active_side=secondary`
- standby/secondary is active-ready
- reverse sync target path is defined correctly for the profile
- the original primary host/libvirt path is reachable again before cutback

### FT

- FT failback support is split by backend.
- file-based FT:
  - `failback --force` is implemented as a full cutback path.
  - the engine stages the active secondary qcow2 back onto the original primary, re-activates the original primary, re-activates the secondary seed VM, and re-enters the validated prebuilt COLO protect flow.
- block-backed FT:
  - failback is not implemented yet.
  - current status is `block-ft-cold-cutback` placeholder and must be treated as unsupported.

## 2.1 FT file-based alignment note

For file-based FT, implementation must follow the QEMU COLO test procedure as the primary source of truth.

Startup alignment checklist:

1. Primary startup
   - `mirror0` listens with `wait=off`
   - `compare1` listens with `wait=on`
   - `compare0`, `compare0-0`, `compare_out`, `compare_out0` use local loopback
   - `filter-mirror`, `filter-redirector`, `colo-compare` objects are present
   - root disk is attached as `if=ide` quorum
   - startup uses `-S`
2. Secondary startup
   - `red0` and `red1` reconnect to the primary
   - `filter-redirector` and `filter-rewriter` objects are present
   - `parent0`, `childs0`, and `colo-disk0` are created exactly as in the COLO procedure
   - `-incoming` is present
   - startup does not use `-S`
3. Protect QMP sequence
   - secondary: `qmp_capabilities`
   - secondary: `migrate-set-capabilities` with `x-colo`
   - secondary: `nbd-server-start`
   - secondary: `nbd-server-add parent0`
   - primary: `qmp_capabilities`
   - primary: `blockdev-add nbd0`
   - primary: `x-blockdev-change parent=colo-disk0 node=nbd0`
   - primary: `migrate-set-capabilities` with `x-colo`
   - primary: `migrate`

The engine must not mark file-based FT as `colo_running` unless both sides are actually `running=true` in QMP.
The engine must also reject prebuilt file-based FT pairs when the following virtual sizes do not match:

- primary source
- secondary parent
- secondary hidden overlay
- secondary active overlay

## 3. Failback Disk Map

Default:

```bash
FTCTL_PROFILE_FAILBACK_DISK_MAP="source"
```

Explicit mapping example:

```bash
FTCTL_PROFILE_FAILBACK_DISK_MAP="vda=/primary/demo-vda.qcow2;vdb=/primary/demo-vdb.qcow2"
```

## 4. Operational Notes

- For `ha` and `dr`, failback success means:
  - `active_side=primary`
  - `protection_state=protected`
  - `transport_state=mirroring`
- `remote-nbd` failback requires reverse NBD export orchestration and primary-side handoff.
- FT block-backed failback remains a separate future feature.
