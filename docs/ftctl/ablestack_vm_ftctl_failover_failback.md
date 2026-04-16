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

- FT failback is not implemented yet.

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
- FT failback remains a separate future feature.
