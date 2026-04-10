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
4. write the FTCTL VM profile
5. cleanup previous case state and stale remote-nbd exports
6. optionally recreate the source VM
7. execute protect
8. collect status, runtime state, dumpxml, blockjob, and secondary target evidence
9. run reconcile
10. collect a final bundle and summary

## Preconditions

- passwordless SSH to the secondary host
- FTCTL binaries installed on the primary host
- libvirt access available on both hosts
- firewalld service `ablestack-vm-ftctl-remote-nbd` applied for the configured NBD range

## Notes

- The current automation uses `virsh dumpxml` of the existing VM as the XML source template when `RECREATE_VM=1`.
- For the currently committed case files, `RECREATE_VM=0` is used so the scripts operate on existing prepared VMs.
- Shared-storage cases are not automated yet in this directory.
- `HA-IMG01-ST04` assumes shared-visible storage is already mounted and accessible on both hosts.
