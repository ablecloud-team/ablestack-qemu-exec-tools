# ablestack_vm_ftctl Profile Schema

## Purpose

This document defines the profile format for:

```bash
/etc/ablestack/ftctl.d/<vm>.conf
```

The runtime validator is implemented in `lib/ftctl/profile.sh`.

## Format Rules

- One `KEY=VALUE` pair per line
- Quote values when they contain special characters or separators
- `;` is used inside map fields
- `#` starts a comment

## Required Fields

- `FTCTL_PROFILE_MODE`
  - allowed:
    - `ha`
    - `dr`
    - `ft`
- `FTCTL_PROFILE_SECONDARY_URI`
  - example:
    - `qemu+ssh://peer/system`

## Common Optional Fields

- `FTCTL_PROFILE_NAME`
  - default:
    - `default`
- `FTCTL_PROFILE_PRIMARY_URI`
  - default:
    - global `FTCTL_DEFAULT_PRIMARY_URI`
- `FTCTL_PROFILE_DISK_MAP`
  - default:
    - `auto`
  - format:
    - `auto`
    - `vda=/path/to/disk1;vdb=/path/to/disk2`
- `FTCTL_PROFILE_NETWORK_MAP`
  - default:
    - `inherit`
  - format:
    - `inherit`
    - `service=br-prod;backup=br-backup`
- `FTCTL_PROFILE_FENCING_POLICY`
  - default:
    - `manual-block`
  - allowed:
    - `manual-block`
    - `ssh`
    - `peer-virsh-destroy`
    - `ipmi`
    - `redfish`
- `FTCTL_PROFILE_FENCING_SSH_USER`
  - default:
    - global `FTCTL_FENCING_SSH_USER`
- `FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC`
  - unsigned integer
  - default:
    - global `FTCTL_TRANSIENT_NET_GRACE_SEC`
- `FTCTL_PROFILE_AUTO_REARM`
  - allowed:
    - `0`
    - `1`
  - default:
    - `1`
- `FTCTL_PROFILE_RECOVERY_PRIORITY`
  - unsigned integer
  - default:
    - `100`
- `FTCTL_PROFILE_QGA_POLICY`
  - allowed:
    - `optional`
    - `required`
    - `off`
  - default:
    - `optional`

## FT-Specific Fields

These fields are only valid when `FTCTL_PROFILE_MODE=ft`.

- `FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT`
  - example:
    - `tcp:10.10.10.21:9000`
- `FTCTL_PROFILE_XCOLO_NBD_ENDPOINT`
  - example:
    - `tcp:10.10.20.21:10809`
- `FTCTL_PROFILE_XCOLO_MIGRATE_URI`
  - example:
    - `tcp:10.10.20.21:9998`
- `FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE`
  - default:
    - `parent0`
- `FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE`
  - default:
    - `colo-disk0`
- `FTCTL_PROFILE_XCOLO_NBD_NODE`
  - default:
    - `nbd0`
- `FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY`
  - default:
    - `2000`
- `FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY`
  - optional
  - format:
    - `arg1;arg2;arg3`
- `FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY`
  - optional
  - format:
    - `arg1;arg2;arg3`

`ha` and `dr` profiles must not include `FTCTL_PROFILE_XCOLO_*`.

## Mode-Specific Notes

### HA

- `FTCTL_PROFILE_MODE=ha`
- `FTCTL_PROFILE_SECONDARY_URI` required
- `FTCTL_PROFILE_DISK_MAP` recommended
- `FTCTL_PROFILE_XCOLO_*` forbidden

### DR

- `FTCTL_PROFILE_MODE=dr`
- `FTCTL_PROFILE_SECONDARY_URI` required
- `FTCTL_PROFILE_DISK_MAP` recommended
- `FTCTL_PROFILE_XCOLO_*` forbidden

### FT

- `FTCTL_PROFILE_MODE=ft`
- `FTCTL_PROFILE_SECONDARY_URI` required
- `FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT` required
- `FTCTL_PROFILE_XCOLO_NBD_ENDPOINT` required
- `FTCTL_PROFILE_XCOLO_MIGRATE_URI` required

## Validation Rules

The current validator checks:

- valid `mode`
- required `PRIMARY_URI` / `SECONDARY_URI`
- `DISK_MAP` / `NETWORK_MAP` syntax
- allowed `FENCING_POLICY` / `QGA_POLICY`
- `AUTO_REARM` in `0|1`
- integer fields for transport tolerance / recovery priority
- `ft` profiles require `XCOLO_*`
- `ha/dr` profiles reject `XCOLO_*`

## Backend Mode Additions

HA/DR profiles also use backend-mode fields.

### New HA/DR fields

- `FTCTL_PROFILE_BACKEND_MODE`
  - allowed:
    - `shared-blockcopy`
    - `remote-nbd`
  - default:
    - `shared-blockcopy`
- `FTCTL_PROFILE_TARGET_STORAGE_SCOPE`
  - allowed:
    - `shared`
    - `secondary-local`
  - default:
    - `shared`
- `FTCTL_PROFILE_SECONDARY_VM_NAME`
  - standby domain name on the secondary host
  - default:
    - `<vm>-standby`
- `FTCTL_PROFILE_SECONDARY_TARGET_DIR`
  - required for `remote-nbd`
- `FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR`
  - required for `remote-nbd`
- `FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT`
  - default:
    - `10809`
- `FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME`
  - default:
    - `<vm>`

### Current backend behavior

- `shared-blockcopy`
  - requires:
    - `FTCTL_PROFILE_TARGET_STORAGE_SCOPE=shared`
    - explicit `FTCTL_PROFILE_DISK_MAP`
    - `FTCTL_PROFILE_SECONDARY_VM_NAME` different from the primary VM name for `ha` and `dr`
- `remote-nbd`
  - validated and implemented for the tested HA/DR paths:
    - protect
    - failover
    - full failback

## FT Backend Notes

### File-based FT

- uses the prebuilt x-colo path
- supports:
  - protect
  - failover
  - full failback
- preflight size validation now enforces equality of:
  - primary source
  - secondary parent
  - secondary hidden overlay
  - secondary active overlay

### Block-backed FT

- uses cold conversion on protect
- uses cold-cutback on failback
- baseline protect/failover/full failback are validated on the tested local-block path
- `FTCTL_PROFILE_DISK_MAP` should explicitly point each target at the correct secondary block path

## Practical Rules

- Do not use `DISK_MAP=auto` for shared blockcopy.
- Do not point a shared-blockcopy destination into a known primary-local path such as:
  - `/var/lib/ablestack-vm-ftctl/blockcopy/...`
- Use a distinct standby domain name on the secondary host for `ha` and `dr`.
- For file-based FT sacrificial pairs, do not create fixed-size hidden/active overlays unless they match the primary source virtual size.

## IPMI Fencing Fields

When `FTCTL_PROFILE_FENCING_POLICY=ipmi`, the profile must provide:

- `FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST`
- `FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST`
- `FTCTL_PROFILE_FENCING_IPMI_USER`
  - default:
    - global `FTCTL_FENCING_IPMI_USER`
- `FTCTL_PROFILE_FENCING_IPMI_PASSWORD`
  - default:
    - global `FTCTL_FENCING_IPMI_PASSWORD`
- `FTCTL_PROFILE_FENCING_IPMI_INTERFACE`
  - default:
    - global `FTCTL_FENCING_IPMI_INTERFACE`
  - example:
    - `lanplus`

Example:

```bash
FTCTL_PROFILE_FENCING_POLICY="ipmi"
FTCTL_PROFILE_FENCING_IPMI_PRIMARY_HOST="10.10.31.251"
FTCTL_PROFILE_FENCING_IPMI_SECONDARY_HOST="10.10.31.252"
FTCTL_PROFILE_FENCING_IPMI_USER="root"
FTCTL_PROFILE_FENCING_IPMI_PASSWORD="Ablecloud1!"
FTCTL_PROFILE_FENCING_IPMI_INTERFACE="lanplus"
```
