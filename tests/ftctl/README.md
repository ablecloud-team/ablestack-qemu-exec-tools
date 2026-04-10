# FTCTL Real-Environment Automation

## Purpose

This directory contains host-side automation scripts for real-environment FTCTL testing.

The current automation scope targets:

- `HA-IMG08-ST01`
- `HA-IMG02-ST02`
- `HA-IMG05-ST01`
- `HA-IMG09-ST01`
- `HA-IMG01-ST04`

These are the non-shared local-storage HA cases that use the `remote-nbd` backend mode.

## Files

- `automation.env`
  - site-wide automation settings
- `cases/*.env`
  - Test ID specific variables
- `run_case.sh`
  - generic runner
- `run_many.sh`
  - runs all IDs in `AUTOMATION_TARGET_IDS`
- `run_<TEST_ID>.sh`
  - convenience wrappers for individual tests
- `lib/common.sh`
  - shared helpers

## Execution

Run a single case:

```bash
tests/ftctl/run_HA-IMG08-ST01.sh
```

Run a case by env file:

```bash
tests/ftctl/run_case.sh tests/ftctl/cases/HA-IMG05-ST01.env
```

Run all configured cases:

```bash
tests/ftctl/run_many.sh
```

## Behavior

The runner performs the following high-level steps:

1. load site-wide automation config
2. load case-specific config
3. write/update FTCTL cluster config
4. optionally clone source disk images and build a fresh libvirt domain XML
5. write the FTCTL VM profile
6. cleanup previous case state and stale backend artifacts
7. optionally recreate the source VM
8. execute protect
9. collect status, runtime state, dumpxml, blockjob, and backend target evidence
10. run reconcile
11. collect a final bundle and summary

## Preconditions

- passwordless SSH to the secondary host
- FTCTL binaries installed on the primary host
- libvirt access available on both hosts
- firewalld service `ablestack-vm-ftctl-remote-nbd` applied for the configured NBD range

## Notes

- The runner can now build a fresh libvirt XML directly from automation settings when `RECREATE_VM=1`.
- Root and optional extra disks are created by cloning source image files.
- Shared-storage cases are supported through the shared-blockcopy backend mode.
- `HA-IMG01-ST04` assumes shared-visible storage is already mounted and accessible on both hosts.
