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
- `HA-IMG08-ST01`

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

Status: FAIL

If FAIL:
- Root cause:
  The current HA blockcopy implementation mirrors to a primary-host local path.
  For host-local, non-shared storage this does not create a usable secondary-side replica.
- Files changed:
  Multiple FTCTL runtime/controller fixes were applied during the investigation, but the final issue is architectural rather than a single command bug.
- Re-test result:
  Control-plane checks passed, but the data-plane target remained on the primary host.
- Remaining gap:
  This test must be re-run only after backend mode redesign.
  Success requires a secondary-usable replica, not just runtime XML mirror metadata on the primary host.
```

### HA-IMG08-ST01

```text
Test ID: HA-IMG08-ST01
Date: 2026-04-06
Mode: HA
VM Name: rocky10-t
Primary Host: 10.10.32.1
Secondary Host: 10.10.32.2
Image Type: transient VM / single-disk Linux qcow2
Storage Backend: local file qcow2
Profile Path: /etc/ablestack/ftctl.d/rocky10-t.conf

Preconditions:
- Transient VM
- local file qcow2 source disk
- FTCTL_PROFILE_DOMAIN_PERSISTENCE="no"
- Secondary host reachable by qemu+ssh libvirt URI

Commands:
- ablestack_vm_ftctl check --vm rocky10-t
- ablestack_vm_ftctl protect --vm rocky10-t --mode ha --peer qemu+ssh://10.10.32.2/system
- ablestack_vm_ftctl status --vm rocky10-t --json
- virsh domblklist rocky10-t --details
- virsh dumpxml rocky10-t
- virsh blockjob rocky10-t vda --info
- virsh -c qemu+ssh://10.10.32.2/system list --all
- virsh -c qemu+ssh://10.10.32.2/system dominfo rocky10-t

Expected Result:
- protect completes without error
- transient standby handling is selected
- a usable secondary-side replica is prepared for failover

Actual Result:
- transient control-plane handling was correct: primary_persistence=no and standby_state=prepared-transient
- runtime XML on the primary host contained a mirror element for vda
- the mirror target path was still a primary-host local path under /var/lib/ablestack-vm-ftctl/blockcopy/...
- no standby VM and no replica disk were created on the secondary host

Evidence:
- HA-IMG08-ST01.status.after.json
- HA-IMG08-ST01.runtime-state.txt
- HA-IMG08-ST01.dumpxml.xml
- HA-IMG08-ST01.peer.list.txt
- HA-IMG08-ST01.peer.dominfo.txt

Status: FAIL

If FAIL:
- Root cause:
  The current blockcopy target model assumes a path writable by the primary-host QEMU process.
  That is insufficient for non-shared local storage because it does not prepare a secondary-local replica.
- Files changed:
  n/a
- Re-test result:
  n/a
- Remaining gap:
  HA/DR backend mode redesign is required.
  This case should use a remote transport model such as NBD, not a primary-local file mirror target.
```

### HA-IMG08-ST01-remote-nbd

```text
Test ID: HA-IMG08-ST01-remote-nbd
Date: 2026-04-07
Mode: HA
VM Name: rocky10-t
Primary Host: 10.10.32.1
Secondary Host: 10.10.32.2
Image Type: transient VM / single-disk Linux qcow2
Storage Backend: local file qcow2
Profile Path: /etc/ablestack/ftctl.d/rocky10-t.conf

Preconditions:
- Transient VM
- local file qcow2 source disk
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- FTCTL_PROFILE_DOMAIN_PERSISTENCE="no"
- Secondary host qemu-nbd export port 10809/tcp reachable from the primary host

Commands:
- ablestack_vm_ftctl check --vm rocky10-t
- ablestack_vm_ftctl protect --vm rocky10-t --mode ha --peer qemu+ssh://10.10.32.2/system
- virsh dumpxml rocky10-t
- virsh blockjob --domain rocky10-t --path vda --info
- secondary target/export checks
- ablestack_vm_ftctl reconcile --vm rocky10-t
- ablestack_vm_ftctl status --vm rocky10-t --json

Expected Result:
- secondary-local target is created on the secondary host
- qemu-nbd export is started on the secondary host
- primary runtime XML contains a network mirror for vda
- reconcile upgrades the state to protected/mirroring

Actual Result:
- secondary-local target was created and maintained
- qemu-nbd export was reachable and active
- primary runtime XML showed <mirror type='network' ... ready='yes'> for vda
- runtime state recorded NBD target URI and secondary-local target path
- reconcile upgraded the VM to protection_state=protected and transport_state=mirroring

Evidence:
- HA-IMG08-ST01-remote-nbd.status.reconciled.final.json
- HA-IMG08-ST01-remote-nbd.runtime-state.reconciled.final.txt
- HA-IMG08-ST01-remote-nbd.dumpxml.reconciled.final.xml
- HA-IMG08-ST01-remote-nbd.secondary-target.t10.final.txt
- HA-IMG08-ST01-remote-nbd.debug-bundle.final.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  protect may still report syncing/copying until reconcile runs.
  dumpxml network-mirror metadata remains the strongest success signal for this backend.
```
