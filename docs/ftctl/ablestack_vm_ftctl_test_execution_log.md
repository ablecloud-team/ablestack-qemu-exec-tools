# ablestack_vm_ftctl Test Execution Log

## 1. Purpose

This document is the execution log template for real-environment testing.

Use one section per `Test ID`.

## 2. Template

```text
Test ID:
Date:
Mode:
VM Name:
Primary Host:
Secondary Host:
Image Type:
Storage Backend:
Profile Path:

Preconditions:

Commands:

Expected Result:

Actual Result:

Evidence:

Status: PASS | FAIL | BLOCKED

If FAIL:
- Root cause:
- Files changed:
- Re-test result:
- Remaining gap:
```

## 3. Active Execution List

### Pending

- `HA-IMG02-ST02`
- `HA-IMG03-ST01`
- `HA-IMG05-ST01`
- `HA-IMG08-ST01`
- `HA-IMG09-ST01`
- `HA-IMG01-ST03`
- `DR-IMG01-ST01`
- `DR-IMG08-ST01`
- `DR-IMG09-ST01`
- `DR-IMG01-ST04`
- `DR-IMG01-ST06`
- `FT-IMG01-ST01`
- `FT-IMG09-ST01`
- `OP-HA-01`
- `OP-HA-02`
- `OP-HA-04`
- `OP-DR-01`
- `OP-DR-02`
- `OP-FT-01`
- `OP-FT-02`

### In Progress

- none

### Done

- `HA-IMG01-ST01`

## 4. Execution Records

### HA-IMG01-ST01

```text
Test ID: HA-IMG01-ST01
Date: 2026-04-02
Mode: HA
VM Name: rhel8.8
Primary Host: 10.10.32.1
Secondary Host: 10.10.32.2
Image Type: single-disk Linux qcow2
Storage Backend: local file qcow2
Profile Path: /etc/ablestack/ftctl.d/rhel8.8.conf

Preconditions:
- Persistent VM
- local file qcow2 source disk
- FTCTL_PROFILE_DOMAIN_PERSISTENCE="yes"
- Secondary host reachable by qemu+ssh libvirt URI

Commands:
- ablestack_vm_ftctl check --vm rhel8.8
- ablestack_vm_ftctl protect --vm rhel8.8 --mode ha --peer qemu+ssh://root@10.10.32.2/system
- ablestack_vm_ftctl status --vm rhel8.8 --json
- virsh blockjob rhel8.8 vda --info
- virsh domblklist rhel8.8 --details
- virsh dumpxml rhel8.8
- virsh -c qemu+ssh://root@10.10.32.2/system list --all
- virsh -c qemu+ssh://root@10.10.32.2/system dominfo rhel8.8

Expected Result:
- protect completes without error
- primary disk enters blockcopy mirror state
- standby XML is generated and persistent standby domain is defined on the secondary host
- status shows no last_error

Actual Result:
- protect completed without controller error
- primary runtime XML exposed a <mirror ... job='copy' ready='yes'> element for vda
- secondary host contained persistent domain rhel8.8 in shut off state
- primary_persistence=yes and standby_state=defined were recorded in runtime state
- blockjob --info and domblklist --details were not sufficient observability signals in this environment

Evidence:
- HA-IMG01-ST01.status.after.retry4.json
- HA-IMG01-ST01.runtime-state.retry4.txt
- HA-IMG01-ST01.peer.list.retry4.txt
- HA-IMG01-ST01.peer.dominfo.retry4.txt
- HA-IMG01-ST01.dumpxml.retry4.xml

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  dumpxml mirror inspection is currently the most reliable success signal.
  blockjob --info and domblklist --details should be demoted to secondary observability signals for this libvirt/QEMU environment.
```
