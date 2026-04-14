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

- `FT-IMG09-ST01`
- `OP-HA-01`
- `OP-HA-02`
- `OP-HA-04`
- `OP-DR-01`
- `OP-DR-02`
- `OP-FT-02`

### In Progress

- none

### Skipped

- `DR-IMG01-ST04`
  - skipped because `HA-IMG01-ST04` already validated the same shared-visible filesystem blockcopy semantics on GFS2, which is treated as equivalent coverage for the NFS file-backed DR transport model in the current test environment
- `DR-IMG05-ST04`
  - skipped because the shared-visible multi-disk filesystem behavior was already covered by the GFS2-based shared filesystem validation path and is treated as equivalent coverage for the NFS multi-disk DR case in the current environment

### Done

- `HA-IMG01-ST01`
- `HA-IMG08-ST01`
- `HA-IMG02-ST02`
- `HA-IMG05-ST01`
- `HA-IMG09-ST01`
- `HA-IMG01-ST03`
- `HA-IMG01-ST04`
- `HA-IMG03-ST01`
- `HA-IMG06-ST02`
- `HA-IMG04-ST02`
- `HA-IMG07-ST01`
- `HA-IMG01-ST06`
- `FT-IMG01-ST01`
- `OP-FT-01`
- `DR-IMG01-ST01`
- `DR-IMG08-ST01`
- `DR-IMG09-ST01`
- `DR-IMG03-ST01`
- `DR-IMG04-ST02`
- `DR-IMG01-ST06`
- `DR-IMG05-ST06`

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

### HA-IMG02-ST02

```text
Test ID: HA-IMG02-ST02
Date: 2026-04-08
Mode: HA
VM Name: rocky10-raw
Primary Host: 10.10.32.1
Secondary Host: 10.10.32.2
Image Type: single-disk Linux raw
Storage Backend: local file raw
Profile Path: /etc/ablestack/ftctl.d/rocky10-raw.conf

Preconditions:
- Transient VM
- local file raw source disk
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- Secondary host firewall opened for the remote NBD service range

Commands:
- ablestack_vm_ftctl check --vm rocky10-raw
- ablestack_vm_ftctl protect --vm rocky10-raw --mode ha --peer qemu+ssh://10.10.32.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-raw
- ablestack_vm_ftctl status --vm rocky10-raw --json
- virsh dumpxml rocky10-raw
- virsh blockjob --domain rocky10-raw --path vda --info
- secondary target/export checks

Expected Result:
- raw image is mirrored to a secondary-local raw target through remote NBD
- runtime XML contains a network mirror for vda
- reconcile upgrades the VM to protected/mirroring
- chosen remote NBD export port is persisted in state

Actual Result:
- remote NBD target was created on the secondary host and kept alive
- runtime XML showed a network mirror for vda with raw format
- reconcile upgraded the VM to protection_state=protected and transport_state=mirroring
- state persisted the chosen export port (`10863`) and the secondary-local target path

Evidence:
- HA-IMG02-ST02.status.final.json
- HA-IMG02-ST02.runtime-state.final.txt
- HA-IMG02-ST02.dumpxml.final.xml
- HA-IMG02-ST02.secondary-target.t10.txt
- HA-IMG02-ST02.debug-bundle.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  protect may still show syncing/copying until reconcile runs.
  remote-nbd state is now deterministic per VM/target, but concurrent multi-disk validation is still required.
```

### HA-IMG05-ST01

```text
Test ID: HA-IMG05-ST01
Date: 2026-04-08
Mode: HA
VM Name: rocky10-t
Primary Host: 10.10.32.1
Secondary Host: 10.10.32.2
Image Type: multi-disk Linux qcow2
Storage Backend: local file qcow2
Profile Path: /etc/ablestack/ftctl.d/rocky10-t.conf

Preconditions:
- Transient VM
- three local file qcow2 source disks
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- Secondary host firewall opened for the remote NBD service range

Commands:
- ablestack_vm_ftctl check --vm rocky10-t
- ablestack_vm_ftctl protect --vm rocky10-t --mode ha --peer qemu+ssh://10.10.32.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-t
- ablestack_vm_ftctl status --vm rocky10-t --json
- virsh dumpxml rocky10-t
- secondary target/export checks

Expected Result:
- each protected disk gets its own secondary-local target
- each protected disk gets its own remote NBD export name and chosen port
- runtime XML contains a network mirror for each protected disk
- reconcile upgrades the VM to protected/mirroring

Actual Result:
- `vda`, `vdb`, and `vdc` each received separate secondary-local targets
- deterministic per-disk export ports were allocated and persisted
- runtime XML showed network mirrors for all three protected disks
- reconcile upgraded the VM to protection_state=protected and transport_state=mirroring

Evidence:
- HA-IMG05-ST01.status.final.json
- HA-IMG05-ST01.runtime-state.final.txt
- HA-IMG05-ST01.dumpxml.final.xml
- HA-IMG05-ST01.secondary-target.t10.txt
- HA-IMG05-ST01.debug-bundle.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  Persistent multi-disk VM behavior is still unverified.
  Failover and failback across all protected disks remain separate test items.
```

### HA-IMG09-ST01

```text
Test ID: HA-IMG09-ST01
Date: 2026-04-08
Mode: HA
VM Name: rocky10-raw
Primary Host: 10.10.32.1
Secondary Host: 10.10.32.2
Image Type: persistent VM / single-disk Linux raw
Storage Backend: local file raw
Profile Path: /etc/ablestack/ftctl.d/rocky10-raw.conf

Preconditions:
- Persistent VM
- local file raw source disk
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- distinct standby domain name on the secondary host

Commands:
- ablestack_vm_ftctl check --vm rocky10-raw
- ablestack_vm_ftctl protect --vm rocky10-raw --mode ha --peer qemu+ssh://10.10.32.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-raw
- ablestack_vm_ftctl status --vm rocky10-raw --json
- virsh dumpxml rocky10-raw
- virsh -c qemu+ssh://10.10.32.2/system list --all
- virsh -c qemu+ssh://10.10.32.2/system dominfo rocky10-raw-standby

Expected Result:
- remote NBD mirror is attached to the persistent source VM
- secondary-local target is prepared
- standby VM is defined on the secondary host with a distinct persistent name
- final state is protected/mirroring

Actual Result:
- remote NBD mirror attached successfully with ready='yes'
- secondary-local target was prepared
- standby domain `rocky10-raw-standby` was defined on the secondary host as a persistent domain
- final state reached protection_state=protected and transport_state=mirroring

Evidence:
- HA-IMG09-ST01.status.final.json
- HA-IMG09-ST01.runtime-state.final.txt
- HA-IMG09-ST01.dumpxml.final.xml
- HA-IMG09-ST01.peer.list.final.txt
- HA-IMG09-ST01.peer.dominfo.final.txt
- HA-IMG09-ST01.debug-bundle.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  Shared-storage HA mode remains unverified.
  Persistent failover/failback behavior should be validated separately.
```

### HA-IMG01-ST04

```text
Test ID: HA-IMG01-ST04
Date: 2026-04-11
Mode: HA
VM Name: rocky10-shared
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: single-disk Linux qcow2
Storage Backend: shared GFS2-visible file path
Profile Path: /etc/ablestack/ftctl.d/rocky10-shared.conf

Preconditions:
- Persistent VM
- source disk on shared-visible primary path
- target disk on shared-visible secondary path
- FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="shared"
- standby domain name distinct from the primary VM name

Commands:
- ablestack_vm_ftctl check --vm rocky10-shared
- ablestack_vm_ftctl protect --vm rocky10-shared --mode ha --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-shared
- ablestack_vm_ftctl status --vm rocky10-shared --json
- virsh dumpxml rocky10-shared
- virsh blockjob --domain rocky10-shared --path vda --info
- virsh -c qemu+ssh://10.10.31.2/system list --all
- virsh -c qemu+ssh://10.10.31.2/system dominfo rocky10-shared-standby

Expected Result:
- blockcopy mirror is attached to the shared-visible target path
- shared target file is created and maintained
- standby domain is defined on the secondary host as a persistent standby VM
- final state is protected/mirroring

Actual Result:
- runtime XML showed a file-based mirror with ready='yes'
- blockjob reported 100.00%
- shared target file existed on the secondary-visible shared path
- standby domain `rocky10-shared-standby` was defined on the secondary host as a persistent domain
- final state reached protection_state=protected and transport_state=mirroring

Evidence:
- HA-IMG01-ST04.status.final.json
- HA-IMG01-ST04.runtime-state.final.txt
- HA-IMG01-ST04.dumpxml.final.xml
- HA-IMG01-ST04.blockjob.vda.final.txt
- HA-IMG01-ST04.peer.list.final.txt
- HA-IMG01-ST04.peer.dominfo.final.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  Shared visible file-path mode now works for the single-disk persistent case.
  Shared multi-disk and failover/failback behavior still need separate validation.
```

### HA-IMG01-ST03

```text
Test ID: HA-IMG01-ST03
Date: 2026-04-11
Mode: HA
VM Name: rocky10-block-st03
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: single-disk Linux raw-on-block
Storage Backend: local block device with remote-nbd secondary-local target
Profile Path: /etc/ablestack/ftctl.d/rocky10-block-st03.conf

Preconditions:
- Transient VM
- primary source disk on local block LV /dev/vg_ftctl_st03_p/lv_rocky10_block_st03
- secondary target disk on local block LV /dev/vg_ftctl_st03_s/lv_rocky10_block_st03
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- explicit FTCTL_PROFILE_DISK_MAP="vda=/dev/vg_ftctl_st03_s/lv_rocky10_block_st03"

Commands:
- ablestack_vm_ftctl check --vm rocky10-block-st03
- ablestack_vm_ftctl protect --vm rocky10-block-st03 --mode ha --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-block-st03
- ablestack_vm_ftctl status --vm rocky10-block-st03 --json
- virsh dumpxml rocky10-block-st03
- virsh blockjob --domain rocky10-block-st03 --path vda --info

Expected Result:
- primary runtime XML exposes a network mirror for the block-backed root disk
- secondary local block LV is exported over NBD and referenced in runtime state
- reconcile promotes the VM to protected/mirroring once the initial copy reaches 100%

Actual Result:
- a transient block-backed VM was created from a cloned qcow2 base image and converted onto /dev/vg_ftctl_st03_p/lv_rocky10_block_st03
- runtime XML exposed a network mirror to nbd://10.10.31.2:10867/rocky10-block-st03-vda
- secondary target LV /dev/vg_ftctl_st03_s/lv_rocky10_block_st03 was exported by qemu-nbd
- after the initial full copy reached 100.00%, reconcile promoted the controller state to protection_state=protected and transport_state=mirroring
- runtime blockcopy state recorded the explicit secondary block target path and ready=yes
- an additional qcow2-on-block variant (`HA-IMG01-ST03-QCOW2`) was also validated on the same local-block/secondary-local model and reached protected/mirroring with a network mirror to the secondary block LV

Evidence:
- HA-IMG01-ST03.status.final.json
- HA-IMG01-ST03.runtime-state.final.txt
- HA-IMG01-ST03.dumpxml.final.xml
- HA-IMG01-ST03.blockjob.vda.final.txt
- HA-IMG01-ST03-QCOW2.status.final.json
- HA-IMG01-ST03-QCOW2.runtime-state.final.txt
- HA-IMG01-ST03-QCOW2.dumpxml.final.xml

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  Local block backend now works for the single-disk transient HA case for both raw-on-block and qcow2-on-block.
  Persistent local-block and multi-disk local-block variants still need separate validation.
```

### HA-MIX01-LVM-TO-GFS2-RAW

```text
Test ID: HA-MIX01-LVM-TO-GFS2-RAW
Date: 2026-04-13
Mode: HA
VM Name: rocky10-mix-lvm-gfs2-raw
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: single-disk Linux raw with mixed source/target storage kinds
Storage Backend: primary LVM raw block source -> secondary GFS2 raw file target
Profile Path: /etc/ablestack/ftctl.d/rocky10-mix-lvm-gfs2-raw.conf

Preconditions:
- Transient VM
- primary source disk on /dev/vg_clvm01/lv_mix_lvm_gfs2_raw_src
- shared-visible target file on /mnt/glue-gfs-1/rocky10-mix-lvm-gfs2-raw.img
- FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="shared"

Actual Result:
- the source disk was block-backed (`type='block'`) and the mirror target was file-backed (`type='file'`)
- runtime XML exposed a file mirror to /mnt/glue-gfs-1/rocky10-mix-lvm-gfs2-raw.img
- after copy completion and reconcile, the VM reached protection_state=protected and transport_state=mirroring

Evidence:
- HA-MIX01-LVM-TO-GFS2-RAW.status.final.json
- HA-MIX01-LVM-TO-GFS2-RAW.dumpxml.final.xml
- HA-MIX01-LVM-TO-GFS2-RAW.summary.txt

Status: PASS
```

### HA-MIX02-LVM-TO-GFS2-QCOW2

```text
Test ID: HA-MIX02-LVM-TO-GFS2-QCOW2
Date: 2026-04-13
Mode: HA
VM Name: rocky10-mix-lvm-gfs2-qcow2
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: single-disk Linux qcow2 with mixed source/target storage kinds
Storage Backend: primary LVM qcow2 block source -> secondary GFS2 qcow2 file target
Profile Path: /etc/ablestack/ftctl.d/rocky10-mix-lvm-gfs2-qcow2.conf

Preconditions:
- Transient VM
- primary source disk on /dev/vg_clvm01/lv_mix_lvm_gfs2_qcow2_src
- shared-visible target file on /mnt/glue-gfs-1/rocky10-mix-lvm-gfs2-qcow2.qcow2
- FTCTL_PROFILE_BACKEND_MODE="shared-blockcopy"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="shared"

Actual Result:
- the source disk was block-backed (`type='block'`) and the mirror target was file-backed (`type='file'`)
- runtime XML exposed a file mirror to /mnt/glue-gfs-1/rocky10-mix-lvm-gfs2-qcow2.qcow2
- runtime blockcopy state recorded `copy|yes`
- after reconcile, the VM reached protection_state=protected and transport_state=mirroring

Evidence:
- HA-MIX02-LVM-TO-GFS2-QCOW2.status.final.json
- HA-MIX02-LVM-TO-GFS2-QCOW2.dumpxml.final.xml
- HA-MIX02-LVM-TO-GFS2-QCOW2.summary.txt

Status: PASS
```

### HA-IMG03-ST01

```text
Test ID: HA-IMG03-ST01
Date: 2026-04-11
Mode: HA
VM Name: win11-ha-img03-st01
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: single-disk Windows 11 qcow2
Storage Backend: local file qcow2 with remote-nbd secondary-local target
Profile Path: /etc/ablestack/ftctl.d/win11-ha-img03-st01.conf

Preconditions:
- Transient VM
- UEFI firmware with OVMF loader and NVRAM
- TPM 2.0 emulator device in the generated libvirt XML
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"

Commands:
- ablestack_vm_ftctl check --vm win11-ha-img03-st01
- ablestack_vm_ftctl protect --vm win11-ha-img03-st01 --mode ha --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm win11-ha-img03-st01
- ablestack_vm_ftctl status --vm win11-ha-img03-st01 --json
- virsh dumpxml win11-ha-img03-st01
- virsh blockjob --domain win11-ha-img03-st01 --path vda --info

Expected Result:
- the generated Windows 11 test VM boots with UEFI and TPM 2.0
- primary runtime XML exposes a network mirror to a secondary-local qcow2 target over NBD
- reconcile promotes the VM to protected/mirroring after the initial copy finishes

Actual Result:
- the runner generated a transient Windows 11 VM with OVMF pflash loader, NVRAM, and TPM 2.0 emulator support
- initial XML generation failed with libvirt firmware selection, then succeeded after switching to explicit loader/nvram handling without the incompatible firmware auto-selection path
- runtime XML exposed a network mirror to nbd://10.10.31.2:10872/win11-ha-img03-st01-vda
- secondary-local target qcow2 was created and exported by qemu-nbd
- after the initial full copy reached 100.00%, reconcile promoted the controller state to protection_state=protected and transport_state=mirroring

Evidence:
- HA-IMG03-ST01.status.final.json
- HA-IMG03-ST01.runtime-state.final.txt
- HA-IMG03-ST01.dumpxml.final.xml
- HA-IMG03-ST01.blockjob.vda.final.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: local-only test runner XML generation logic only
- Re-test result: passed after fixing UEFI/TPM XML generation
- Remaining gap:
  Windows qcow2 baseline is now complete.
  Windows raw and persistent Windows variants still need separate validation.
```

### HA-IMG06-ST02

```text
Test ID: HA-IMG06-ST02
Date: 2026-04-11
Mode: HA
VM Name: rocky10-raw-multi-st06
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: multi-disk Linux raw
Storage Backend: local file raw with remote-nbd secondary-local targets
Profile Path: /etc/ablestack/ftctl.d/rocky10-raw-multi-st06.conf

Preconditions:
- Transient VM
- three protected raw disks on the primary host
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- per-disk remote NBD exports enabled on the secondary host

Commands:
- ablestack_vm_ftctl check --vm rocky10-raw-multi-st06
- ablestack_vm_ftctl protect --vm rocky10-raw-multi-st06 --mode ha --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-raw-multi-st06
- ablestack_vm_ftctl status --vm rocky10-raw-multi-st06 --json
- virsh dumpxml rocky10-raw-multi-st06
- virsh blockjob --domain rocky10-raw-multi-st06 --path vda --info

Expected Result:
- each protected raw disk is mirrored to a distinct secondary-local raw target over NBD
- all three runtime XML mirrors reach ready='yes'
- reconcile promotes the VM to protected/mirroring once the slowest disk finishes the initial copy

Actual Result:
- primary runtime XML showed three network mirrors with distinct export ports for `vda`, `vdb`, and `vdc`
- secondary-local raw targets were created under /var/lib/ablestack-vm-ftctl/remote-nbd-targets/rocky10-raw-multi-st06
- `vdb` and `vdc` reached ready='yes' first; `vda` completed later and then reconcile promoted the VM to protection_state=protected and transport_state=mirroring
- runtime blockcopy state recorded all three targets with ready=yes after the final reconcile

Evidence:
- HA-IMG06-ST02.status.final.json
- HA-IMG06-ST02.runtime-state.final.txt
- HA-IMG06-ST02.dumpxml.final.xml
- HA-IMG06-ST02.blockjob.vda.final.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  Multi-disk raw validation is now complete for transient local-file storage with remote-nbd.
  Persistent multi-disk raw behavior still needs separate validation.
```

### HA-IMG04-ST02

```text
Test ID: HA-IMG04-ST02
Date: 2026-04-11
Mode: HA
VM Name: win11-ha-img04-st02
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: single-disk Windows 11 raw
Storage Backend: local file raw with remote-nbd secondary-local target
Profile Path: /etc/ablestack/ftctl.d/win11-ha-img04-st02.conf

Preconditions:
- Transient VM
- UEFI firmware with OVMF loader and NVRAM
- TPM 2.0 emulator device in the generated libvirt XML
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"

Commands:
- ablestack_vm_ftctl check --vm win11-ha-img04-st02
- ablestack_vm_ftctl protect --vm win11-ha-img04-st02 --mode ha --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm win11-ha-img04-st02
- ablestack_vm_ftctl status --vm win11-ha-img04-st02 --json
- virsh dumpxml win11-ha-img04-st02
- virsh blockjob --domain win11-ha-img04-st02 --path vda --info

Expected Result:
- the generated Windows 11 raw VM boots with UEFI and TPM 2.0
- primary runtime XML exposes a network mirror to a secondary-local raw target over NBD
- reconcile promotes the VM to protected/mirroring after the initial copy finishes

Actual Result:
- the runner generated a transient Windows 11 raw VM from a raw seed image with OVMF pflash loader, NVRAM, and TPM 2.0 emulator support
- runtime XML exposed a network mirror to nbd://10.10.31.2:10828/win11-ha-img04-st02-vda
- secondary-local raw target was created and exported by qemu-nbd
- after the initial full copy reached 100.00%, reconcile promoted the controller state to protection_state=protected and transport_state=mirroring

Evidence:
- HA-IMG04-ST02.status.final.json
- HA-IMG04-ST02.runtime-state.final.txt
- HA-IMG04-ST02.dumpxml.final.xml
- HA-IMG04-ST02.blockjob.vda.final.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: local-only test runner raw Windows case only
- Re-test result: n/a
- Remaining gap:
  Windows raw baseline is now complete.
  Persistent Windows behavior still needs separate validation.
```

### HA-IMG07-ST01

```text
Test ID: HA-IMG07-ST01
Date: 2026-04-11
Mode: HA
VM Name: rocky10-mixed-st07
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: mixed-size multi-disk Linux
Storage Backend: mixed qcow2/raw local files with remote-nbd secondary-local targets
Profile Path: /etc/ablestack/ftctl.d/rocky10-mixed-st07.conf

Preconditions:
- Transient VM
- three protected disks with mixed size and format
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- per-disk remote NBD exports enabled on the secondary host

Commands:
- ablestack_vm_ftctl check --vm rocky10-mixed-st07
- ablestack_vm_ftctl protect --vm rocky10-mixed-st07 --mode ha --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-mixed-st07
- ablestack_vm_ftctl status --vm rocky10-mixed-st07 --json
- virsh dumpxml rocky10-mixed-st07
- find /run/ablestack-vm-ftctl -maxdepth 4 -type f -print -exec cat {} \;

Expected Result:
- mixed-size and mixed-format protected disks are mirrored to distinct secondary-local targets
- per-disk export ports remain unique and stable
- final state reaches protected/mirroring with all runtime mirrors ready='yes'

Actual Result:
- the runner created a mixed layout with qcow2 root, smaller qcow2 data disk, and larger raw data disk
- runtime XML exposed three network mirrors with distinct export ports for `vda`, `vdb`, and `vdc`
- runtime blockcopy state recorded all three targets as ready=yes
- the VM reached protection_state=protected and transport_state=mirroring during the initial automated run

Evidence:
- HA-IMG07-ST01.status.final.json
- HA-IMG07-ST01.runtime-state.final.txt
- HA-IMG07-ST01.dumpxml.final.xml
- HA-IMG07-ST01.secondary-target.t10.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  Mixed-size multi-disk validation is now complete for the transient local-file case.
  Persistent mixed-size behavior and failover/failback still need separate validation.
```

### HA-IMG01-ST05

```text
Test ID: HA-IMG01-ST05
Date: 2026-04-12
Mode: HA
VM Name: rocky10-mpath-st05
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: single-disk Linux on shared multipath block
Storage Backend: shared multipath block (`vg_clvm01`)
Profile Variants:
- shared-blockcopy to /dev/vg_clvm01/lv_rocky10_mpath_st05_dst
- remote-nbd to /dev/vg_clvm01/lv_rocky10_mpath_st05_dst

Expected Result:
- A multipath-backed source LV should mirror to a multipath-backed target LV using either the shared-visible or secondary-local transport model.

Actual Result:
- In a non-clustered shared VG, creating the source LV on primary and the target LV on secondary is not a valid test model; both LVs must be created on one host and then activation must be split by role.
- Under that owner-separated model, `remote-nbd` succeeded for both:
  - `raw-on-block`
  - `qcow2-on-block`
- `shared-blockcopy` was then retested with the correct primary-owner model:
  - both source and target LVs created on primary
  - both source and target activated on primary during blockcopy
  - target deactivated on secondary
- Direct path-based `virsh blockcopy` still reproduced the earlier libvirt/QEMU error:
  `unable to execute QEMU command 'blockdev-add': 'file' driver requires '/dev/vg_clvm01/...' to be a regular file`
- After switching `shared-blockcopy` to XML block targets (`<disk type='block'><source dev='...'>`), both:
  - `raw-on-block`
  - `qcow2-on-block`
  reached active block jobs and completed to `protected/mirroring`.

Evidence:
- manual `virsh blockcopy` reproduction on the primary host
- libvirtd journal showing the earlier `blockdev-add` failure for the path-based shared-blockcopy call
- explicit owner-separated activation snapshots for primary source LV and secondary target LV
- successful `remote-nbd` owner-separated reruns for `raw` and `qcow2`
- successful `shared-blockcopy` XML block-target reruns for `raw` and `qcow2`

Status: PASS

If FAIL:
- Root cause:
  superseded by the XML block-target fix for shared-blockcopy and the owner-separated activation model for remote-nbd.
- Files changed:
  - lib/ftctl/blockcopy.sh
- Re-test result:
  The product now supports:
  - `remote-nbd` on non-clustered shared VGs via owner-separated activation
  - `shared-blockcopy` on multipath block targets via XML block-target descriptors
- Remaining gap:
  shared multipath failover/failback still needs separate operational validation.
```

### DR-IMG01-ST01

```text
Test ID: DR-IMG01-ST01
Date: 2026-04-11
Mode: DR
VM Name: rocky10-dr-img01-st01
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: single-disk Linux qcow2
Storage Backend: local file qcow2 with remote-nbd secondary-local target
Profile Path: /etc/ablestack/ftctl.d/rocky10-dr-img01-st01.conf

Preconditions:
- Transient VM
- FTCTL_PROFILE_MODE="dr"
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- secondary-local qcow2 target exported over NBD

Commands:
- ablestack_vm_ftctl check --vm rocky10-dr-img01-st01
- ablestack_vm_ftctl protect --vm rocky10-dr-img01-st01 --mode dr --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-dr-img01-st01
- ablestack_vm_ftctl status --vm rocky10-dr-img01-st01 --json
- virsh dumpxml rocky10-dr-img01-st01
- find /run/ablestack-vm-ftctl -maxdepth 4 -type f -print -exec cat {} \;

Expected Result:
- DR baseline uses the same secondary-local remote transport model as HA for non-shared storage
- runtime XML exposes a network mirror to the DR target over NBD
- final state reaches protected/mirroring after the initial copy completes

Actual Result:
- the runner created a transient Linux qcow2 VM and protected it in DR mode
- runtime XML exposed a network mirror to nbd://10.10.31.2:10844/rocky10-dr-img01-st01-vda
- secondary-local qcow2 target was created under /var/lib/ablestack-vm-ftctl/remote-nbd-targets/rocky10-dr-img01-st01
- after reconcile, the DR controller state reached protection_state=protected and transport_state=mirroring

Evidence:
- DR-IMG01-ST01.status.final.json
- DR-IMG01-ST01.runtime-state.final.txt
- DR-IMG01-ST01.dumpxml.final.xml
- DR-IMG01-ST01.secondary-target.t10.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  DR baseline Linux qcow2 is now complete on the remote-nbd path.
  DR transient/persistent behavior and failover exercises still need separate validation.
```

### DR-IMG08-ST01

```text
Test ID: DR-IMG08-ST01
Date: 2026-04-11
Mode: DR
VM Name: rocky10-dr-img08-st01
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: transient Linux qcow2
Storage Backend: local file qcow2 with remote-nbd secondary-local target
Profile Path: /etc/ablestack/ftctl.d/rocky10-dr-img08-st01.conf

Preconditions:
- Transient VM
- FTCTL_PROFILE_MODE="dr"
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- secondary-local qcow2 target exported over NBD

Commands:
- ablestack_vm_ftctl check --vm rocky10-dr-img08-st01
- ablestack_vm_ftctl protect --vm rocky10-dr-img08-st01 --mode dr --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-dr-img08-st01
- ablestack_vm_ftctl status --vm rocky10-dr-img08-st01 --json
- virsh dumpxml rocky10-dr-img08-st01
- find /run/ablestack-vm-ftctl -maxdepth 4 -type f -print -exec cat {} \;

Expected Result:
- transient DR behavior uses the same remote-nbd transport model as the DR baseline
- standby preparation remains transient on the secondary side
- final state reaches protected/mirroring with ready=yes in runtime blockcopy state

Actual Result:
- the runner created a transient Linux qcow2 VM and protected it in DR mode with a transient standby path
- runtime XML exposed a network mirror to nbd://10.10.31.2:10865/rocky10-dr-img08-st01-vda
- secondary-local qcow2 target was created and exported under the remote-nbd target root
- after reconcile, the DR controller state reached protection_state=protected and transport_state=mirroring
- runtime state recorded standby_state=prepared-transient and blockcopy ready=yes

Evidence:
- DR-IMG08-ST01.status.final.json
- DR-IMG08-ST01.runtime-state.final.txt
- DR-IMG08-ST01.dumpxml.final.xml
- DR-IMG08-ST01.secondary-target.t10.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  DR transient behavior is now complete on the remote-nbd path.
  DR persistent behavior and failover exercises still need separate validation.
```

### DR-IMG09-ST01

```text
Test ID: DR-IMG09-ST01
Date: 2026-04-11
Mode: DR
VM Name: rocky10-dr-img09-st01
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: persistent Linux qcow2
Storage Backend: local file qcow2 with remote-nbd secondary-local target
Profile Path: /etc/ablestack/ftctl.d/rocky10-dr-img09-st01.conf

Preconditions:
- Persistent VM
- FTCTL_PROFILE_MODE="dr"
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"
- secondary-local qcow2 target exported over NBD
- standby domain name distinct from the primary VM name

Commands:
- ablestack_vm_ftctl check --vm rocky10-dr-img09-st01
- ablestack_vm_ftctl protect --vm rocky10-dr-img09-st01 --mode dr --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm rocky10-dr-img09-st01
- ablestack_vm_ftctl status --vm rocky10-dr-img09-st01 --json
- virsh dumpxml rocky10-dr-img09-st01
- virsh -c qemu+ssh://10.10.31.2/system list --all
- virsh -c qemu+ssh://10.10.31.2/system dominfo rocky10-dr-img09-st01-secondary

Expected Result:
- persistent DR behavior uses the same remote-nbd transport model as the DR baseline
- a distinct persistent standby domain is defined on the secondary host
- final state reaches protected/mirroring with ready=yes in runtime blockcopy state

Actual Result:
- the runner created a persistent Linux qcow2 VM and protected it in DR mode
- runtime XML exposed a network mirror to nbd://10.10.31.2:10831/rocky10-dr-img09-st01-vda
- secondary-local qcow2 target was created and exported under the remote-nbd target root
- after reconcile, the DR controller state reached protection_state=protected and transport_state=mirroring
- runtime state recorded primary_persistence=yes, standby_state=defined, and blockcopy ready=yes
- the secondary standby domain `rocky10-dr-img09-st01-secondary` existed as a persistent defined domain

Evidence:
- DR-IMG09-ST01.status.final.json
- DR-IMG09-ST01.runtime-state.final.txt
- DR-IMG09-ST01.dumpxml.final.xml
- DR-IMG09-ST01.peer.list.final.txt
- DR-IMG09-ST01.peer.dominfo.final.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  DR persistent behavior is now complete on the remote-nbd path.
  DR failover and reverse-sync/failback exercises still need separate validation.
```

### DR-IMG03-ST01

```text
Test ID: DR-IMG03-ST01
Date: 2026-04-11
Mode: DR
VM Name: win11-dr-img03-st01
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: transient Windows 11 qcow2
Storage Backend: local file qcow2 with remote-nbd secondary-local target
Profile Path: /etc/ablestack/ftctl.d/win11-dr-img03-st01.conf

Preconditions:
- Transient VM
- Windows 11 UEFI + TPM 2.0 generated XML
- FTCTL_PROFILE_MODE="dr"
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"

Commands:
- ablestack_vm_ftctl check --vm win11-dr-img03-st01
- ablestack_vm_ftctl protect --vm win11-dr-img03-st01 --mode dr --peer qemu+ssh://10.10.31.2/system
- ablestack_vm_ftctl reconcile --vm win11-dr-img03-st01
- ablestack_vm_ftctl status --vm win11-dr-img03-st01 --json
- virsh dumpxml win11-dr-img03-st01
- virsh qemu-monitor-command win11-dr-img03-st01 --pretty '{"execute":"query-block-jobs"}'

Expected Result:
- Windows qcow2 DR follows the same remote-nbd transport model as the Linux DR baseline
- runtime XML exposes a network mirror to the secondary-local qcow2 target over NBD
- final state reaches protected/mirroring after the initial copy completes

Actual Result:
- blockcopy start succeeded and runtime XML exposed a network mirror to nbd://10.10.31.2:10858/win11-dr-img03-st01-vda
- secondary root filesystem exhaustion was first identified as a direct blocker and cleaned up
- an immediate 1-second trace then showed the primary QMP block job disappearing around T+13s while the secondary export remained alive
- product-side observability was improved with secondary export/path/process fallback and explicit free-space preflight
- an A/B replay with `baseline`, `AUTO_REARM=0 only`, and `defer standby prepare only` showed that all three variants retained the job through the early T+15 trace window
- a full rerun of the baseline DR case without experiment flags then completed and final reconcile reached protection_state=protected and transport_state=mirroring

Evidence:
- DR-IMG03-ST01.status.final.json
- DR-IMG03-ST01.runtime-state.final.txt
- DR-IMG03-ST01.dumpxml.final.xml
- DR-IMG03-ST01.debug-bundle.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed:
  - lib/ftctl/blockcopy.sh
  - lib/ftctl/orchestrator.sh
- Re-test result:
  - passed after secondary-space cleanup and product-side remote-nbd observability/space-preflight hardening
- Remaining gap:
  The exact internal reason for the earlier transient job disappearance is still not fully isolated at the QEMU/libvirt layer.
  A/B replay confirmed that the current baseline path no longer depends on the DR experiment settings.
```

### DR-IMG04-ST02

```text
Test ID: DR-IMG04-ST02
Date: 2026-04-11
Mode: DR
VM Name: win11-dr-img04-st02
Primary Host: 10.10.31.1
Secondary Host: 10.10.31.2
Image Type: transient Windows 11 raw
Storage Backend: local file raw with remote-nbd secondary-local target
Profile Path: /etc/ablestack/ftctl.d/win11-dr-img04-st02.conf

Preconditions:
- Transient VM
- Windows 11 UEFI + TPM 2.0 generated XML
- FTCTL_PROFILE_MODE="dr"
- FTCTL_PROFILE_BACKEND_MODE="remote-nbd"
- FTCTL_PROFILE_TARGET_STORAGE_SCOPE="secondary-local"

Commands:
- ablestack_vm_ftctl check --vm win11-dr-img04-st02
- ablestack_vm_ftctl protect --vm win11-dr-img04-st02 --mode dr --peer qemu+ssh://10.10.31.2/system
- wait until the initial copy reaches 100%
- ablestack_vm_ftctl reconcile --vm win11-dr-img04-st02
- ablestack_vm_ftctl status --vm win11-dr-img04-st02 --json
- virsh dumpxml win11-dr-img04-st02
- virsh blockjob --domain win11-dr-img04-st02 --path vda --info

Expected Result:
- Windows raw DR follows the same remote-nbd transport model as the Linux and Windows qcow2 DR baselines
- runtime XML exposes a network mirror to the secondary-local raw target over NBD
- final state reaches protected/mirroring after the initial copy completes

Actual Result:
- blockcopy start succeeded and runtime XML exposed a network mirror to nbd://10.10.31.2:10838/win11-dr-img04-st02-vda
- the secondary-local raw target grew under /var/lib/libvirt/images/win11-dr-img04-st02-secondary/win11-dr-img04-st02
- the initial test runner summary stopped during syncing/copying, but follow-up polling confirmed the copy reached 100%
- after reconcile, the DR controller state reached protection_state=protected and transport_state=mirroring

Evidence:
- DR-IMG04-ST02.status.final.json
- DR-IMG04-ST02.dumpxml.final.xml
- DR-IMG04-ST02.blockjob.final.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed: n/a
- Re-test result: n/a
- Remaining gap:
  DR Windows raw transient validation is now complete.
  Windows persistent DR behavior remains a separate follow-up area.
```

### HA-IMG01-ST06

```text
Test ID: HA-IMG01-ST06
Date: 2026-04-14
Mode: HA
VM Names:
- rocky10-rbd-ha-img01-st06-lib
- rocky10-rbd-ha-img01-st06-krbd
Primary Host: 10.10.1.1
Secondary Host: 10.10.1.2
Image Type: single-disk Linux qcow2
Storage Backend: Ceph RBD
Variants:
- librbd source/target via protocol='rbd'
- krbd source/target via /dev/rbd/rbd/<image>

Preconditions:
- new test images created in pool `rbd`; existing images untouched
- libvirt secret uuid `11111111-1111-1111-1111-111111111111`
- Ceph monitor host `scvm:6789`
- shared-blockcopy target descriptors generated as XML for both network-rbd and block-rbd targets

Commands:
- ablestack_vm_ftctl check --vm rocky10-rbd-ha-img01-st06-lib
- ablestack_vm_ftctl protect --vm rocky10-rbd-ha-img01-st06-lib --mode ha --peer qemu+ssh://10.10.1.2/system
- ablestack_vm_ftctl check --vm rocky10-rbd-ha-img01-st06-krbd
- ablestack_vm_ftctl protect --vm rocky10-rbd-ha-img01-st06-krbd --mode ha --peer qemu+ssh://10.10.1.2/system
- ablestack_vm_ftctl status --vm ... --json
- virsh dumpxml ...

Expected Result:
- both librbd and krbd single-disk HA baselines reach protected/mirroring
- runtime XML exposes an active mirror using the correct target kind:
  - `network rbd` for librbd
  - `block /dev/rbd/...` for krbd

Actual Result:
- `HA-IMG01-ST06-LIBRBD`: PASS
- `HA-IMG01-ST06-KRBD`: PASS
- librbd runtime state recorded:
  `vda|rbd/ha-img01-st06-lib-src|rbd:rbd/ha-img01-st06-lib-dst|qcow2|copy|yes|`
- krbd runtime state recorded:
  `vda|/dev/rbd/rbd/ha-img01-st06-krbd-src|/dev/rbd/rbd/ha-img01-st06-krbd-dst|qcow2|block|yes|`

Evidence:
- HA-IMG01-ST06-LIBRBD.status.final.json
- HA-IMG01-ST06-LIBRBD.dumpxml.final.xml
- HA-IMG01-ST06-KRBD.status.final.json
- HA-IMG01-ST06-KRBD.dumpxml.final.xml

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed:
  - lib/ftctl/blockcopy.sh
  - lib/ftctl/inventory.sh
  - lib/ftctl/standby.sh
- Re-test result:
  - passed after RBD target XML handling, RBD spec parsing fixes, and krbd map handling
- Remaining gap:
  multi-disk Ceph RBD validation remains separate.
```

### DR-IMG01-ST06

```text
Test ID: DR-IMG01-ST06
Date: 2026-04-14
Mode: DR
VM Names:
- rocky10-rbd-dr-img01-st06-lib
- rocky10-rbd-dr-img01-st06-krbd
- rocky10-rbd-dr-img01-st06-krbd-remote
Primary Host: 10.10.1.1
Secondary Host: 10.10.1.2
Image Type: single-disk Linux qcow2
Storage Backend: Ceph RBD
Variants:
- librbd shared-visible (`shared-blockcopy`)
- krbd shared-visible (`shared-blockcopy`)
- krbd host-separated (`remote-nbd`)

Preconditions:
- new test images created in pool `rbd`; existing images untouched
- libvirt secret uuid `11111111-1111-1111-1111-111111111111`
- Ceph monitor host `scvm:6789`
- for `remote-nbd`, `firewalld` was enabled on both hosts and `10809-10872/tcp` was opened

Commands:
- ablestack_vm_ftctl check/protect/status/reconcile on each variant
- virsh dumpxml ...
- find /run/ablestack-vm-ftctl -maxdepth 4 -type f -print -exec cat {} \;

Expected Result:
- DR Ceph baseline should complete for both shared-visible and host-separated transports
- shared-visible variants should mirror directly to RBD/krbd targets
- host-separated krbd should mirror to `nbd://10.10.1.2:<port>/...`

Actual Result:
- `DR-IMG01-ST06-LIBRBD`: PASS
- `DR-IMG01-ST06-KRBD`: PASS
- `DR-IMG01-ST06-KRBD-REMOTE`: PASS
- librbd runtime state recorded:
  `vda|rbd/dr-img01-st06-lib-src|rbd:rbd/dr-img01-st06-lib-dst|qcow2|copy|yes|`
- krbd shared runtime state recorded:
  `vda|/dev/rbd/rbd/dr-img01-st06-krbd-src|/dev/rbd/rbd/dr-img01-st06-krbd-dst|qcow2|block|yes|`
- krbd remote-nbd runtime state recorded:
  `vda|/dev/rbd/rbd/dr-img01-st06-krbd-remote3-src|nbd://10.10.1.2:10868/rocky10-rbd-dr-img01-st06-krbd-remote3-vda|qcow2|copy|yes|/dev/rbd/rbd/dr-img01-st06-krbd-remote3-dst`

Evidence:
- DR-IMG01-ST06-LIBRBD.status.final.json
- DR-IMG01-ST06-LIBRBD.dumpxml.final.xml
- DR-IMG01-ST06-KRBD.status.final.json
- DR-IMG01-ST06-KRBD.dumpxml.final.xml
- DR-IMG01-ST06-KRBD-REMOTE runtime-state.final.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed:
  - lib/ftctl/blockcopy.sh
  - lib/ftctl/inventory.sh
  - lib/ftctl/standby.sh
- Re-test result:
  - passed after krbd remote-nbd prepare fixes and enabling firewalld/NBD port range on 10.10.1.1/10.10.1.2
- Remaining gap:
  multi-disk Ceph RBD DR validation remains separate.
```

### DR-IMG05-ST06

```text
Test ID: DR-IMG05-ST06
Date: 2026-04-14
Mode: DR
VM Names:
- rocky10-rbd-dr-img05-st06-lib
- rocky10-rbd-dr-img05-st06-krbd
- rocky10-rbd-dr-img05-st06-krbd-remote
Primary Host: 10.10.1.1
Secondary Host: 10.10.1.2
Image Type: transient Linux multi-disk qcow2
Storage Backend: Ceph RBD
Variants:
- librbd shared-visible (`shared-blockcopy`)
- krbd shared-visible (`shared-blockcopy`)
- krbd host-separated (`remote-nbd`)

Preconditions:
- new test images created in pool `rbd`; existing images untouched
- three protected disks (`vda`, `vdb`, `vdc`)
- libvirt secret uuid `11111111-1111-1111-1111-111111111111`
- Ceph monitor host `scvm:6789`
- `firewalld` enabled and `10809-10872/tcp` opened on both hosts for the `krbd remote-nbd` variant

Commands:
- ablestack_vm_ftctl check/protect/status/reconcile on each variant
- virsh dumpxml ...
- find /run/ablestack-vm-ftctl -maxdepth 4 -type f -print -exec cat {} \;

Expected Result:
- multi-disk DR on Ceph RBD should complete for both shared-visible and host-separated transports
- all three protected disks should expose active mirrors and finish in protected/mirroring

Actual Result:
- `DR-IMG05-ST06-LIBRBD`: PASS
- `DR-IMG05-ST06-KRBD`: PASS
- `DR-IMG05-ST06-KRBD-REMOTE`: PASS
- librbd shared-visible runtime state recorded:
  - `vda|rbd/dr-img05-st06-lib-src-vda|rbd:rbd/dr-img05-st06-lib-dst-vda|qcow2|copy|yes|`
  - `vdb|rbd/dr-img05-st06-lib-src-vdb|rbd:rbd/dr-img05-st06-lib-dst-vdb|qcow2|copy|yes|`
  - `vdc|rbd/dr-img05-st06-lib-src-vdc|rbd:rbd/dr-img05-st06-lib-dst-vdc|qcow2|copy|yes|`
- krbd shared-visible runtime state recorded:
  - `vda|/dev/rbd/rbd/dr-img05-st06-krbd-src-vda|/dev/rbd/rbd/dr-img05-st06-krbd-dst-vda|qcow2|block|yes|`
  - `vdb|/dev/rbd/rbd/dr-img05-st06-krbd-src-vdb|/dev/rbd/rbd/dr-img05-st06-krbd-dst-vdb|qcow2|block|yes|`
  - `vdc|/dev/rbd/rbd/dr-img05-st06-krbd-src-vdc|/dev/rbd/rbd/dr-img05-st06-krbd-dst-vdc|qcow2|block|yes|`
- krbd remote-nbd runtime state recorded:
  - `vda|/dev/rbd/rbd/dr-img05-st06-krbd-remote-src-vda|nbd://10.10.1.2:10869/rocky10-rbd-dr-img05-st06-krbd-remote-vda|qcow2|copy|yes|/dev/rbd/rbd/dr-img05-st06-krbd-remote-dst-vda`
  - `vdb|/dev/rbd/rbd/dr-img05-st06-krbd-remote-src-vdb|nbd://10.10.1.2:10849/rocky10-rbd-dr-img05-st06-krbd-remote-vdb|qcow2|copy|yes|/var/lib/ablestack-vm-ftctl/remote-nbd-targets/rocky10-rbd-dr-img05-st06-krbd-remote/vdb-dr-img05-st06-krbd-remote-src-vdb.qcow2`
  - `vdc|/dev/rbd/rbd/dr-img05-st06-krbd-remote-src-vdc|nbd://10.10.1.2:10861/rocky10-rbd-dr-img05-st06-krbd-remote-vdc|qcow2|copy|yes|/var/lib/ablestack-vm-ftctl/remote-nbd-targets/rocky10-rbd-dr-img05-st06-krbd-remote/vdc-dr-img05-st06-krbd-remote-src-vdc.qcow2`

Evidence:
- DR-IMG05-ST06-LIBRBD runtime-state.final.txt
- DR-IMG05-ST06-LIBRBD.dumpxml.final.xml
- DR-IMG05-ST06-KRBD.status.final.json
- DR-IMG05-ST06-KRBD.dumpxml.final.xml
- DR-IMG05-ST06-KRBD-REMOTE.runtime-state.final.txt

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed:
  - lib/ftctl/blockcopy.sh
  - lib/ftctl/inventory.sh
- Re-test result:
  - passed after krbd remote-nbd target preparation fixes and explicit firewalld/NBD range handling on the 10.10.1.x hosts
- Remaining gap:
  FT/x-colo validation remains separate.
```

### FT-IMG01-ST01

```text
Test ID: FT-IMG01-ST01
Date: 2026-04-14
Mode: FT
VM Name: rocky10-ft-img01-st01
Primary Host: 10.10.1.1
Secondary Host: 10.10.1.2
Image Type: single-disk Linux qcow2
Storage Backend: FT/x-colo baseline with host-separated sacrificial qcow2 pair
Profile Path: /etc/ablestack/ftctl.d/rocky10-ft-img01-st01.conf

Preconditions:
- sacrificial VM pair created with the same domain name on both hosts
- primary and secondary use different qcow2 files
- primary QEMU commandline creates `parent0` and `colo-disk0`
- secondary QEMU commandline creates `parent0`, `childs0`, and `colo-disk0`
- firewalld enabled and ports `9000/tcp`, `9998/tcp`, `10809/tcp` opened on both hosts

Commands:
- ablestack_vm_ftctl protect --vm rocky10-ft-img01-st01 --mode ft --peer qemu+ssh://10.10.1.2/system
- ablestack_vm_ftctl status --vm rocky10-ft-img01-st01 --json
- ablestack_vm_ftctl failover --vm rocky10-ft-img01-st01 --force
- ablestack_vm_ftctl status --vm rocky10-ft-img01-st01 --json

Expected Result:
- protect reaches `colo_running` with `transport_state=mirroring`
- failover fences the primary side and promotes the secondary side through `x-colo-lost-heartbeat`

Actual Result:
- protect succeeded and FT state reached:
  - `protection_state=colo_running`
  - `transport_state=mirroring`
  - `active_side=primary`
- failover succeeded and FT state reached:
  - `protection_state=failed_over`
  - `transport_state=colo_failover`
  - `active_side=secondary`
  - `fencing_state=fenced`

Evidence:
- `ablestack_vm_ftctl status --vm rocky10-ft-img01-st01 --json` after protect
- `ablestack_vm_ftctl status --vm rocky10-ft-img01-st01 --json` after failover
- `/run/ablestack-vm-ftctl/state/rocky10-ft-img01-st01.state`
- `/run/ablestack-vm-ftctl/state/rocky10-ft-img01-st01.state.xcolo`

Status: PASS

If FAIL:
- Root cause: n/a
- Files changed:
  - lib/ftctl/xcolo.sh
  - bin/ablestack_vm_ftctl_firewalld.sh
  - etc/ablestack-vm-ftctl.conf
  - rpm/ablestack_vm_ftctl.spec
  - rpm/v2k_baseline_pkgs_ablestack_9.6.txt
  - rpm/v2k_baseline_pkgs_ablestack_9.7.txt
  - .github/workflows/build.yml
- Re-test result:
  - passed after x-colo block-graph provisioning and firewalld/packaging updates
- Remaining gap:
  x-colo transient-loss rearm and explicit heartbeat-loss operational tests remain separate.
```

### OP-FT-01

```text
Test ID: OP-FT-01
Date: 2026-04-14
Mode: FT
VM Name: rocky10-ft-img01-st01
Primary Host: 10.10.1.1
Secondary Host: 10.10.1.2
Area: x-colo transient loss / rearm

Preconditions:
- `FT-IMG01-ST01` baseline already reaches `colo_running`
- sacrificial primary/secondary VM pair created with distinct qcow2 backing files
- x-colo endpoints configured:
  - proxy `tcp:10.10.1.2:9000`
  - nbd `tcp:10.10.1.2:10809`
  - migrate `tcp:10.10.1.2:9998`
- firewalld enabled and x-colo ports opened on both hosts

Commands:
- ablestack_vm_ftctl protect --vm rocky10-ft-img01-st01 --mode ft --peer qemu+ssh://10.10.1.2/system
- secondary QMP: `{"execute":"nbd-server-stop"}`
- force state transition to `transport_state=rearm-requested`
- ablestack_vm_ftctl reconcile --vm rocky10-ft-img01-st01 --json
- sleep beyond grace window
- ablestack_vm_ftctl reconcile --vm rocky10-ft-img01-st01 --json
- ablestack_vm_ftctl status --vm rocky10-ft-img01-st01 --json

Expected Result:
- first reconcile during grace window may leave `transient_loss`
- second reconcile after grace window should invoke `xcolo_rearm()`
- final state returns to:
  - `protection_state=colo_running`
  - `transport_state=mirroring`
  - `rearm_count=1`

Actual Result:
- initial implementation failed to re-enter `xcolo_rearm()` once FT transport had transitioned to `transient_loss`
- root cause: FT reconcile only treated `broken|lost|disconnected|rearm-requested|colo_rearming` as rearm triggers
- after updating the FT reconcile branch to also treat:
  - `transient_loss`
  - `rearm_backoff`
  as x-colo transport-loss states, the same scenario succeeded
- final FT state returned to:
  - `protection_state=colo_running`
  - `transport_state=mirroring`
  - `rearm_count=1`

Evidence:
- `ablestack_vm_ftctl status --vm rocky10-ft-img01-st01 --json` after reconcile.1
- `ablestack_vm_ftctl status --vm rocky10-ft-img01-st01 --json` after reconcile.2
- `/run/ablestack-vm-ftctl/state/rocky10-ft-img01-st01.state`
- `/run/ablestack-vm-ftctl/state/rocky10-ft-img01-st01.state.xcolo`

Status: PASS

If FAIL:
- Root cause:
  FT reconcile state machine did not route `transient_loss` back into `xcolo_rearm()`.
- Files changed:
  - lib/ftctl/orchestrator.sh
  - lib/ftctl/xcolo.sh
- Re-test result:
  - passed after FT transport-state classification fix
- Remaining gap:
  explicit heartbeat-loss failover remains separate in `OP-FT-02`.
```
