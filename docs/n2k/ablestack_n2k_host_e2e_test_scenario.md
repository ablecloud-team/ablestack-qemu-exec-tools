# ablestack_n2k Host E2E Test Scenario

## Purpose

This document defines the step-by-step E2E scenario for testing the rebuilt
`ablestack_n2k` RPM directly on ABLESTACK hosts.

The test is executed by the operator/agent in stages. A later stage starts only
after the previous stage has produced acceptable evidence.

## Environment

Source Nutanix environment:

- Prism endpoint: `https://10.10.131.11:9440`
- Prism user: `admin`
- Prism password: do not store in files; pass at runtime only
- NFS source host: `10.10.131.10`

Target ABLESTACK hosts:

- `10.10.22.1`
- `10.10.22.2`
- `10.10.22.3`
- SSH port: `10022`
- SSH user: `root`
- SSH password: do not store in files; pass at runtime only

Installed package:

- `ablestack_n2k-0.8.0-1.el9.el9.noarch`

## Test Policy

### Source VM Must Be Valid

A VM must pass source disk sanity checks before it can be used for an E2E
migration test.

Do not run E2E when the selected source disk is empty, sparse-zero only, missing
partition signatures, or otherwise not representative of a real guest disk.

The `windows11` VM is currently excluded from valid data-plane E2E because its
100 GiB SCSI DISK is effectively empty:

- logical size is 100 GiB
- actual allocation is about 512 bytes
- MBR signature is `0000`, not `55aa`
- GPT and NTFS signatures are not present

### Execution Style

- Run one host and one VM scenario at a time.
- Keep each stage observable through `manifest.json`, `events.log`, and command
  output.
- Use `--split phase1` and `--split phase2` for the main flow.
- Use `--shutdown guest` for Phase2. The implementation may fall back to
  `poweroff` when graceful guest shutdown fails.
- The first target cutover action is `define-only`; target boot/start is a
  separate stage.
- Do not delete or mutate Nutanix source disks.
- Do not delete source VMs.
- Do not start a target VM on the same L2 network while the source VM is still
  online.

## Candidate VM Order

The candidate list is intentionally gated by source sanity checks.

| Order | VM | Current Role | Status |
| ---: | --- | --- | --- |
| 1 | `rhel` | Linux guest | Candidate, must pass disk sanity first |
| 2 | `winsvr2022` | Windows Server guest | Candidate, WSL E2E already passed; currently may be OFF |
| 3 | `test` | basic smoke VM | Candidate only if source disk is non-empty and representative |
| - | `windows11` | Windows desktop guest | Excluded until rebuilt with a valid OS disk |

## Target Backend Order

Host E2E must cover all target backend categories, but the execution is staged.

| Order | Backend | Target Storage | Target Format | Purpose |
| ---: | --- | --- | --- | --- |
| 1 | RBD | `rbd` | `raw` | Primary ABLESTACK storage path |
| 2 | qcow2 file | `file` | `qcow2` | Reproducible fallback and debug path |
| 3 | block/LVM | `block` | `raw` | Direct block-device compatibility path |

The first E2E run should use RBD on `10.10.22.1` if the host reports a usable
RBD environment. RBD must be tested in both target access modes before qcow2 and
block/LVM are considered complete:

- `librbd`: libvirt uses an RBD network disk and the existing host Ceph secret,
  such as `client.admin secret`.
- `krbd`: n2k maps the RBD image with `rbd map`, and libvirt uses the block
  device path `/dev/rbd/<pool>/<image>`.

qcow2 and block/LVM are run only after the first RBD flow is stable.

## Stage 0 - Host And Package Verification

Run on each target host before any migration:

```bash
rpm -q ablestack_n2k
command -v ablestack_n2k
bash -n /usr/local/bin/ablestack_n2k /usr/local/lib/ablestack-qemu-exec-tools/n2k/*.sh
grep -q 'n2k_source_compact_json_value' /usr/local/lib/ablestack-qemu-exec-tools/n2k/source_adapter.sh
grep -q 'zeroed' /usr/local/lib/ablestack-qemu-exec-tools/n2k/target_storage.sh
```

Record storage capability:

```bash
command -v rbd || true
command -v qemu-img || true
command -v qemu-nbd || true
command -v virsh || true
command -v lvs || true
command -v lvcreate || true
df -h /var/lib/libvirt/images || true
virsh list --all || true
```

Acceptance:

- package is installed
- scripts parse successfully
- required helpers from the rebuilt RPM are present
- at least one target backend is available

## Stage 1 - Prism And Source VM Sanity

For each candidate VM, collect inventory and create or inspect a snapshot path
before migration.

The VM is eligible only when all checks pass:

- VM is resolvable through Prism API
- migration disk excludes CDROM and other non-disk devices
- selected disk logical size matches inventory
- selected disk has meaningful allocation or data
- selected disk has a partition table or filesystem/boot signature appropriate
  for the guest type

Recommended source disk checks:

```bash
stat -c 'logical_size=%s blocks=%b block_bytes=%B' "${SOURCE_DISK_PATH}"
du -h "${SOURCE_DISK_PATH}"
file -s "${SOURCE_DISK_PATH}" || true
blkid -p "${SOURCE_DISK_PATH}" || true
fdisk -l "${SOURCE_DISK_PATH}" || true
dd if="${SOURCE_DISK_PATH}" bs=1 skip=510 count=2 status=none | od -An -tx1
dd if="${SOURCE_DISK_PATH}" bs=1 skip=512 count=8 status=none | od -An -tc
```

Windows-specific minimum evidence:

- MBR `55 aa` or GPT `EFI PART`
- expected NTFS or EFI system partition evidence
- source disk is not sparse-zero only

Linux-specific minimum evidence:

- MBR/GPT partition table or recognizable filesystem signature
- source disk is not sparse-zero only

If a VM fails this gate, record the evidence and exclude it from E2E. Do not
continue to Phase1.

## Stage 2 - Host RBD E2E, Phase1

Initial target:

- host: `10.10.22.1`
- VM: first candidate that passes Stage 1, preferably `rhel`
- backend: RBD
- cutover mode: not reached in Phase1

Command shape:

```bash
export NUTANIX_USERNAME='admin'
read -rsp 'NUTANIX_PASSWORD: ' NUTANIX_PASSWORD
echo

VM='rhel'
PC='10.10.131.11'
NFS_HOST='10.10.131.10'
RUN_ID="$(date +%Y%m%d-%H%M%S)"
WORKDIR="/var/lib/ablestack-n2k/${VM}/${RUN_ID}"
DST="rbd:<pool>/n2k-${VM}-${RUN_ID}"

ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${WORKDIR}/manifest.json" \
  --log "${WORKDIR}/events.log" \
  run \
  --vm "${VM}" \
  --pc "${PC}" \
  --insecure 1 \
  --inventory-source api \
  --target-storage rbd \
  --target-format raw \
  --rbd-access-mode librbd \
  --dst "${DST}" \
  --split phase1 \
  --source-api v3 \
  --nfs-host "${NFS_HOST}" \
  --deadline-sec 120 \
  --max-incr-phase2 20
```

Before executing, replace `<pool>` with a confirmed writable RBD pool. Repeat
the RBD scenario with `--rbd-access-mode krbd`; the krbd cutover must expose the
target disk as `/dev/rbd/<pool>/<image>`.

Phase1 acceptance:

```bash
jq -e '.runtime.split.phase1.done == true' "${WORKDIR}/manifest.json"
jq '{phase1:.runtime.split.phase1, phases:.phases, sync:.runtime.sync}' "${WORKDIR}/manifest.json"
tail -n 50 "${WORKDIR}/events.log"
```

Expected:

- base sync done
- first incremental sync done
- Phase1 marker recorded
- source VM remains usable until Phase2 shutdown

## Stage 3 - Host RBD E2E, Phase2

Run only after Phase1 passes.

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${WORKDIR}/manifest.json" \
  --log "${WORKDIR}/events.log" \
  run \
  --vm "${VM}" \
  --pc "${PC}" \
  --insecure 1 \
  --inventory-source api \
  --target-storage rbd \
  --target-format raw \
  --rbd-access-mode librbd \
  --dst "${DST}" \
  --split phase2 \
  --source-api v3 \
  --nfs-host "${NFS_HOST}" \
  --deadline-sec 120 \
  --max-incr-phase2 3 \
  --shutdown guest \
  --shutdown-timeout-sec 300 \
  --shutdown-poll-sec 5 \
  --cutover-args "--define-only"
```

Phase2 acceptance:

```bash
jq -e '.runtime.split.phase2.done == true' "${WORKDIR}/manifest.json"
jq -e '.phases.final_sync.done == true and .phases.cutover.done == true' "${WORKDIR}/manifest.json"
jq '.runtime.source_shutdown' "${WORKDIR}/manifest.json"
test -s "${WORKDIR}/artifacts/${VM}.xml"
```

Expected:

- Phase2 incremental gate passes
- source VM shutdown is recorded
- final snapshot and final sync complete
- libvirt XML artifact is generated
- no NBD/NFS helper residue remains

## Stage 4 - Target Artifact Verification

Verify target storage and XML before any VM start.

For RBD:

```bash
rbd info <pool>/n2k-${VM}-${RUN_ID}-disk0
qemu-img info "rbd:<pool>/n2k-${VM}-${RUN_ID}-disk0"
virsh dumpxml "${VM}" | grep -E "protocol='rbd'|/dev/rbd/"
```

For qcow2:

```bash
qemu-img check "${TARGET_QCOW2}"
qemu-img info "${TARGET_QCOW2}"
```

For XML:

```bash
virsh define "${WORKDIR}/artifacts/${VM}.xml"
virsh dominfo "${VM}" || true
virsh dumpxml "${VM}" >/tmp/n2k-${VM}.xml
virsh undefine "${VM}" || true
```

Do not start the target VM in this stage unless the source VM is confirmed OFF
and the network mapping has been isolated or approved.

## Stage 5 - Optional Target Boot Test

Run only after Stage 4 passes and the operator accepts that the source VM is
stopped.

Boot policy:

- Linux VM: start with network isolated or disconnected first
- Windows VM: start only after virtio/UEFI/TPM requirements are reviewed
- Do not attach the target to the same production network while the source VM is
  online

Boot acceptance:

- `virsh start <vm>` succeeds
- console or guest agent evidence shows OS boot progress
- target disk is read as expected
- unexpected MAC/IP conflict does not occur

## Stage 6 - qcow2 Backend E2E

Run after the RBD scenario is stable.

Suggested target:

- host: `10.10.22.2`
- VM: same source VM if reusable, or next valid candidate
- backend: file/qcow2
- destination: `/var/lib/libvirt/images/n2k/${VM}/${RUN_ID}`

Use the same Stage 2 and Stage 3 flow with:

```bash
--target-storage file
--target-format qcow2
--dst "/var/lib/libvirt/images/n2k/${VM}/${RUN_ID}"
```

Acceptance:

- `qemu-img check` passes
- incremental qcow2 patch path uses `qemu-nbd`
- no stale `/dev/nbdX` pid remains

## Stage 7 - Block/LVM Backend E2E

Run after RBD and qcow2 are stable.

Suggested target:

- host: `10.10.22.3`
- VM: small valid Linux VM if available
- backend: block/LVM

Precondition:

- confirm a test VG with enough free space
- create a uniquely named test LV
- record the LV path in target map JSON
- never use an existing production LV

Acceptance:

- base sync writes to the test LV
- incremental patch writes to the block device
- XML references the intended block target
- test LV can be removed after evidence capture

## Evidence To Capture

For every stage:

- host name
- command line without passwords
- RPM version
- workdir
- manifest summary
- events tail
- target storage info
- source VM power state before and after Phase2
- generated XML path
- error logs and remediation if any

Recommended evidence summary:

```bash
jq '{
  source:.source.vm,
  target:.target,
  phases:.phases,
  split:.runtime.split,
  shutdown:.runtime.source_shutdown,
  sync:{
    last_kind:.runtime.sync.last_recovery_point_kind,
    last_changed_bytes:.runtime.sync.last_changed_bytes,
    last_region_count:.runtime.sync.last_region_count
  },
  disks:[.disks[] | {disk_id,size_bytes,target:.transfer.target_path,metrics}]
}' "${WORKDIR}/manifest.json"
```

## Stop Conditions

Stop immediately and report before proceeding when:

- source disk sanity fails
- target storage path cannot be verified
- Phase1 base sync fails
- changed-region payload cannot be validated
- qcow2 NBD attach leaves a stale device
- Phase2 cannot safely stop the source VM
- final sync fails
- generated XML points to the wrong disk, network, CPU, or memory
- target boot would risk MAC/IP conflict

## Initial Execution Plan

The first host E2E run should be:

1. Verify all three ABLESTACK hosts and installed RPM.
2. Run source sanity checks for `rhel`, `winsvr2022`, and `test`.
3. Exclude `windows11` until it is rebuilt with a valid OS disk.
4. Select the first valid source VM.
5. Run RBD Phase1 on `10.10.22.1`.
6. Review Phase1 evidence.
7. Run RBD Phase2 on `10.10.22.1`.
8. Verify final sync and XML artifact.
9. Decide whether to perform an isolated target boot test.
10. Continue with qcow2 and block/LVM backend scenarios only after RBD passes.

## Execution Log - 2026-05-15

### Stage 0 Result

- Hosts checked: `10.10.22.1`, `10.10.22.2`, `10.10.22.3`
- Installed package after rebuild: `ablestack_n2k-0.8.0-1.el9.el9.noarch`
- Latest installed RPM SHA256 after RBD access-mode and redefine retry fixes:
  `02b1fdba5452998749b4b098697b4fcf5afefd7a3adb2864efec0ad49037229d`
- RBD write check on `10.10.22.1`: temporary image create/info/remove passed in pool `rbd`
- Installed package syntax check: passed on all three hosts

### RBD Access Mode Smoke Result

Target host: `10.10.22.1`

Temporary RBD images were created in pool `rbd`, used for libvirt start, and
removed after the smoke test.

| Mode | Expected target attachment | Result |
| --- | --- | --- |
| `librbd` | libvirt network disk with Ceph auth `client.admin secret` | PASS; `virsh start` reached `running (booted)` |
| `krbd` | block disk from `/dev/rbd/rbd/<image>` | PASS; `rbd map` created the expected block device and `virsh start` reached `running (booted)` |

### Actual Cutover Apply/Start Result

Target host: `10.10.22.1`

Excluded source VMs:

- `windows11`: excluded by request and previous source-disk validation.
- `test`: excluded because the source disk was sparse/blank and not a valid
  migration source for this E2E run.

#### `rhel`

Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-rbd-cutover-rhel-20260515-084709
```

Target disk:

```text
rbd:rbd/n2k-host-rbd-cutover-rhel-20260515-084709-disk0
```

Results:

- Source state before target start: `OFF`.
- Final sync had already completed in the same run; failed earlier only because
  the RBD libvirt XML lacked Ceph auth.
- `librbd` cutover retry passed after adding libvirt Ceph secret XML.
- `librbd` validation: `running (booted)` after 150 seconds; QEMU guest agent
  `guest-ping` returned `{}`.
- `krbd` validation: domain was redefined with block source
  `/dev/rbd/rbd/n2k-host-rbd-cutover-rhel-20260515-084709-disk0`; `running
  (booted)` after 90 seconds; QEMU guest agent `guest-ping` returned `{}`.

#### `winsvr2022`

Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-rbd-librbd-cutover-winsvr2022-20260515-102752
```

Target disk:

```text
rbd:rbd/n2k-host-rbd-librbd-cutover-winsvr2022-20260515-102752-disk0
```

Results:

- Fresh Phase1 and Phase2 were run after the RBD access-mode implementation.
- Source inventory normalized as `firmware=efi`, `secure_boot=true`.
- Source shutdown policy: `guest`; final source state: `OFF`.
- Phase2 final sync: `0` bytes, `0` regions.
- `librbd` validation: secure-boot OVMF XML, Ceph secret auth XML, and
  `running (booted)` after 180 seconds. QEMU guest agent was not connected, but
  libvirt DHCP lease showed `192.168.122.239/24`.
- `krbd` validation: domain was redefined with block source
  `/dev/rbd/rbd/n2k-host-rbd-librbd-cutover-winsvr2022-20260515-102752-disk0`;
  `running (booted)` after 150 seconds. QEMU guest agent remained unavailable,
  but libvirt DHCP lease again showed `192.168.122.239/24`.

Current target VM state after the krbd validation:

| VM | State | Current RBD access mode |
| --- | --- | --- |
| `rhel` | running | `krbd` |
| `winsvr2022` | running | `krbd` |

Host screenshot capture note:

- `virsh screenshot` could not save screenshots on this host because QEMU
  reported `Enable PNG support with libpng for screendump`. Runtime validation
  therefore used domain state, CPU time, QGA where available, libvirt DHCP lease,
  and qemu command-line/log evidence.

### Stage 1 Result

Source disk sanity was run from `10.10.22.1`.

Evidence root:

```text
/var/lib/ablestack-n2k/source-sanity/20260515-014042
```

| VM | Result | Finding |
| --- | --- | --- |
| `rhel` | OK | 100 GiB GPT disk, allocated data present, EFI/Linux/LVM layout detected |
| `winsvr2022` | OK | 100 GiB GPT disk, allocated data present, Windows MBR/GPT signatures detected |
| `test` | Excluded | 100 GiB logical disk, allocated `0`, no MBR/GPT/blkid signature, zero samples only |
| `windows11` | Excluded | Previous validation found a sparse/blank source disk; rebuild the source VM before E2E |

First RBD E2E candidate selected: `rhel`.

### RBD E2E Result

Target host: `10.10.22.1`  
Run ID: `host-rbd-rhel-20260515-014221`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-rbd-rhel-20260515-014221
```

Target disk:

```text
rbd:rbd/n2k-host-rbd-rhel-20260515-014221-disk0
```

Phase1 result:

- `snapshot base`: passed
- `sync base`: passed
- `snapshot incr`: passed
- `sync incr`: passed
- base logical bytes: `107374182400`
- first incremental: `12288` bytes, `2` regions

Phase2 result:

- phase2 incremental: `32768` bytes, `4` regions, ready in `6` seconds
- source shutdown policy: `guest`
- final sync: `1765888` bytes, `99` regions
- cutover artifact: `/var/lib/ablestack-n2k/e2e/host-rbd-rhel-20260515-014221/artifacts/rhel.xml`
- target RBD readback: GPT detected with EFI, Linux filesystem, and Linux LVM partitions

Observed issue:

- The source VM reached `OFF`, but the run manifest recorded `runtime.source_shutdown.response` as `{}`.
- Code was updated so a successful shutdown with an empty payload is reconstructed from a Prism power-state recheck. If the rechecked state is not `OFF`, the final snapshot path now fails instead of silently proceeding.
- The rebuilt RPM containing this guard was installed on all three ABLESTACK hosts.

Next recommended stage:

1. Continue to qcow2 backend E2E after RBD Linux and Windows coverage passes.
2. Run block/LVM backend E2E only after qcow2 is stable.
3. Investigate why `n2k_source_vm_shutdown` can return an empty stdout inside `run` even though the direct helper call returns JSON; the current guard prevents unsafe final snapshot progression and preserves evidence, but the root cause should still be cleaned up.

### RBD Windows Server E2E Result

Target host: `10.10.22.1`  
Run ID: `host-rbd-winsvr2022-20260515-015816`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-rbd-winsvr2022-20260515-015816
```

Target disk:

```text
rbd:rbd/n2k-host-rbd-winsvr2022-20260515-015816-disk0
```

Phase1 result:

- `snapshot base`: passed
- `sync base`: passed
- `snapshot incr`: passed
- `sync incr`: passed
- base logical bytes: `107374182400`
- first incremental: `0` bytes, `0` regions

Phase2 result:

- phase2 incremental: `0` bytes, `0` regions, ready in `7` seconds
- source shutdown policy: `guest`
- shutdown evidence: reconstructed from Prism state because helper stdout was empty; `after_state=OFF`
- final sync: `0` bytes, `0` regions
- cutover artifact: `/var/lib/ablestack-n2k/e2e/host-rbd-winsvr2022-20260515-015816/artifacts/winsvr2022.xml`
- target RBD readback: GPT detected with EFI, Microsoft reserved, Microsoft basic data, and Windows recovery partitions

### qcow2 E2E Result

Target host: `10.10.22.1`  
Target directory: `/var/lib/libvirt/images/n2k`  
Run ID: `host-qcow2-rhel-patched-20260515-074826`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-qcow2-rhel-patched-20260515-074826
```

Target disk:

```text
/var/lib/libvirt/images/n2k/host-qcow2-rhel-patched-20260515-074826/rhel-disk0.qcow2
```

Phase1 result:

- `snapshot base`: passed
- `sync base`: passed
- `snapshot incr`: passed
- `sync incr`: passed
- base logical bytes: `107374182400`
- first incremental: `0` bytes, `0` regions
- NBD state after Phase1: all `/dev/nbd*` devices returned to `0B`

Phase2 result:

- phase2 incremental: `0` bytes, `0` regions, ready in `6` seconds
- source shutdown policy: `guest`
- shutdown evidence: reconstructed from Prism state; `after_state=OFF`
- final sync: `0` bytes, `0` regions
- cutover artifact: `/var/lib/ablestack-n2k/e2e/host-qcow2-rhel-patched-20260515-074826/artifacts/rhel.xml`
- `qemu-img check`: no errors
- qcow2 virtual size: `100 GiB`
- qcow2 disk size: approximately `2.84 GiB`
- target readback through qemu-nbd: GPT detected with EFI, Linux filesystem, and Linux LVM partitions
- NBD state after Phase2 and readback: all `/dev/nbd*` devices returned to `0B`

Observed and fixed issue:

- During the first qcow2 readback, the Linux guest LVM partition under `/dev/nbd0p3` was auto-detected by host LVM and left `rhel_rhel-root` / `rhel_rhel-swap` device-mapper nodes behind.
- This kept `/dev/nbd0` busy after `qemu-nbd --disconnect`.
- `target_storage.sh` was updated so qcow2 NBD cleanup removes device-mapper nodes that depend on the mapped NBD device when their open count is zero, then retries disconnect.
- The patched cleanup was verified through a fresh qcow2 E2E run and an explicit installed-helper readback.

### Block/LVM E2E Result

Target host: `10.10.22.1`  
Target disks: `/dev/sdg`, `/dev/sdh`  
Target VG: `n2k_block_e2e`  
Final Run ID: `host-block-rhel-exact-20260515-081242`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-block-rhel-exact-20260515-081242
```

Target LV:

```text
/dev/n2k_block_e2e/n2k_host_block_rhel_exact_20260515_081242_disk0
```

Disk precheck:

- `/dev/sdg`: 2.18 TiB, no filesystem, no partition table, no wipefs signature, no mount/swap/holders
- `/dev/sdh`: 2.18 TiB, no filesystem, no partition table, no wipefs signature, no mount/swap/holders
- Both disks were converted to PVs in the test VG `n2k_block_e2e`

Sizing correction:

- First block run used a 120 GiB LV and passed, but `fdisk` reported a GPT backup-table location warning because the source disk is exactly 100 GiB.
- The 120 GiB test LV was removed.
- The final run used an exact 100 GiB LV (`107374182400` bytes), matching the source disk size.

Phase1 result:

- `snapshot base`: passed
- `sync base`: passed
- `snapshot incr`: passed
- `sync incr`: passed
- base logical bytes: `107374182400`
- first incremental: `0` bytes, `0` regions

Phase2 result:

- phase2 incremental: `0` bytes, `0` regions, ready in `6` seconds
- source shutdown policy: `guest`
- shutdown evidence: reconstructed from Prism state; `after_state=OFF`
- final sync: `0` bytes, `0` regions
- cutover artifact: `/var/lib/ablestack-n2k/e2e/host-block-rhel-exact-20260515-081242/artifacts/rhel.xml`
- target readback: MBR `55aa`, GPT `EFI PART`, `PTTYPE=gpt`
- target partition layout: EFI, Linux filesystem, Linux LVM
- NBD state after run: all `/dev/nbd*` devices remained `0B`

Current test storage left in place:

- VG `n2k_block_e2e` remains on `/dev/sdg` and `/dev/sdh`
- LV `/dev/n2k_block_e2e/n2k_host_block_rhel_exact_20260515_081242_disk0` remains as the block E2E evidence target
- `/dev/sdh` is in the VG but still fully free

Observed unrelated host condition:

- Existing host LVM commands warn about duplicate VG name `rl` from already-mapped RBD devices.
- This was not caused by the block/LVM test and was not modified during this run.

### qcow2 Actual Cutover Apply/Start Result

Target host: `10.10.22.1`  
Target directory: `/var/lib/libvirt/images/n2k`  
Source VMs tested: `rhel`, `winsvr2022`

#### rhel

Run ID: `host-qcow2-cutover-rhel-20260515-105453`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-qcow2-cutover-rhel-20260515-105453
```

Target disk:

```text
/var/lib/libvirt/images/n2k/host-qcow2-cutover-rhel-20260515-105453/rhel-disk0.qcow2
```

Results:

- Phase1, Phase2, final sync, `cutover --apply`, and target start passed.
- After 90 seconds, libvirt reported `running (booted)`.
- CPU time advanced, confirming the VM was executing after start.
- QEMU guest agent ping returned `{}`.
- After the target domain was stopped and undefined, `qemu-img check` reported no image errors.
- `qemu-img info` reported virtual size `100 GiB` and disk size approximately `2.86 GiB`.

#### winsvr2022

Run ID: `host-qcow2-cutover-winsvr2022-20260515-105949`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-qcow2-cutover-winsvr2022-20260515-105949
```

Target disk:

```text
/var/lib/libvirt/images/n2k/host-qcow2-cutover-winsvr2022-20260515-105949/winsvr2022-disk0.qcow2
```

Results:

- Phase1, Phase2, final sync, `cutover --apply`, and target start passed.
- After 150 seconds, libvirt reported `running (booted)`.
- CPU time advanced, confirming the VM was executing after start.
- QEMU guest agent was not available in the guest, so network readiness was checked through libvirt DHCP lease data.
- DHCP lease was observed as `192.168.122.239/24`.
- After the target domain was stopped and undefined, `qemu-img check` reported no image errors.
- `qemu-img info` reported virtual size `100 GiB` and disk size approximately `20.4 GiB`.

### Block/LVM Actual Cutover Apply/Start Result

Target host: `10.10.22.1`  
Target disks: `/dev/sdg`, `/dev/sdh`  
Target VG: `n2k_block_e2e`  
Source VMs tested: `rhel`, `winsvr2022`

The block backend was prepared from the empty `/dev/sdg` and `/dev/sdh` disks.
Both disks were added to VG `n2k_block_e2e`, with total VG size under `4.37 TiB`.

#### rhel

Run ID: `host-block-cutover-rhel-20260515-110543`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-block-cutover-rhel-20260515-110543
```

Target LV:

```text
/dev/n2k_block_e2e/host_block_cutover_rhel_20260515_110543_disk0
```

Results:

- Phase1, Phase2, final sync, `cutover --apply`, and target start passed.
- `blockdev --getsize64` returned `107374182400`, matching the 100 GiB source disk.
- Target readback found GPT with EFI System Partition, XFS, and Linux LVM partitions.
- After 90 seconds, libvirt reported `running (booted)`.
- CPU time advanced, confirming the VM was executing after start.
- QEMU guest agent ping returned `{}`.

#### winsvr2022

Run ID: `host-block-cutover-winsvr2022-20260515-111536`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-block-cutover-winsvr2022-20260515-111536
```

Target LV:

```text
/dev/n2k_block_e2e/host_block_cutover_winsvr2022_20260515_111536_disk0
```

Results:

- Phase1, Phase2, final sync, `cutover --apply`, and target start passed.
- `blockdev --getsize64` returned `107374182400`, matching the 100 GiB source disk.
- Target readback found GPT with EFI, Microsoft reserved, NTFS basic data, and NTFS recovery partitions.
- After 150 seconds, libvirt reported `running (booted)`.
- CPU time advanced, confirming the VM was executing after start.
- QEMU guest agent was not available in the guest, so network readiness was checked through libvirt DHCP lease data.
- DHCP lease was observed as `192.168.122.239/24`.

Current block/LVM evidence left in place:

| VM | Domain state | Target LV |
| --- | --- | --- |
| `rhel` | `running` | `/dev/n2k_block_e2e/host_block_cutover_rhel_20260515_110543_disk0` |
| `winsvr2022` | `running` | `/dev/n2k_block_e2e/host_block_cutover_winsvr2022_20260515_111536_disk0` |

The VG and both target LVs remain active intentionally so the migrated guests can
be inspected on `10.10.22.1`.

### Full One-Shot Run Result

Target host: `10.10.22.1`  
Target backend: file/qcow2  
Source VM tested: `rhel`

This run verifies the one-shot `run --split full` path. Unlike the main
Phase1/Phase2 flow, this mode does not set `runtime.split.phase1.done` or
`runtime.split.phase2.done`; instead it performs base sync, first incremental
sync, final sync, and cutover in a single `run` invocation.

Before the run, the previous block/LVM target domain named `rhel` was stopped
and undefined to avoid a libvirt name conflict. The block/LVM evidence LV was
not deleted.

Run ID: `host-qcow2-full-rhel-20260515-133357`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-qcow2-full-rhel-20260515-133357
```

Target disk:

```text
/var/lib/libvirt/images/n2k/host-qcow2-full-rhel-20260515-133357/rhel-disk0.qcow2
```

Command shape:

```bash
ablestack_n2k run \
  --vm rhel \
  --pc 10.10.131.11 \
  --inventory-source api \
  --target-storage file \
  --target-format qcow2 \
  --dst /var/lib/libvirt/images/n2k/host-qcow2-full-rhel-20260515-133357 \
  --split full \
  --source-api v3 \
  --nfs-host 10.10.131.10 \
  --shutdown guest \
  --apply \
  --start
```

Manifest evidence:

- `runtime.split.phase1.done=false`
- `runtime.split.phase2.done=false`
- `phases.base_sync.done=true`
- `phases.incr_sync.done=true`
- `phases.final_sync.done=true`
- `phases.cutover.done=true`
- shutdown policy `guest`, final source state `OFF`
- final sync changed bytes: `0`
- final sync changed regions: `0`

Runtime validation:

- After 90 seconds, libvirt reported `running`.
- CPU time advanced to `67.5s`, confirming the guest was executing.
- QEMU guest agent ping returned `{}`.
- The target was shut down for image validation, and `qemu-img check` reported no image errors.
- `qemu-img info` reported virtual size `100 GiB` and disk size approximately `2.86 GiB`.
- The target domain was restarted after image validation and QEMU guest agent ping returned `{}` again.

State immediately after this validation:

| VM | Domain state | Backend |
| --- | --- | --- |
| `rhel` | `running` | qcow2 full one-shot target |
| `winsvr2022` | `running` | block/LVM target from previous backend validation |

### RBD krbd Full One-Shot Run Result

Target host: `10.10.22.1`  
Target backend: RBD raw  
RBD access mode: `krbd`  
Source VM tested: `winsvr2022`

This run verifies the one-shot `run --split full` path with the target attached
through a kernel RBD device. The libvirt target disk must be a block device
source under `/dev/rbd/<pool>/<image>`, not a librbd network disk.

Before the run, the previous block/LVM target domain named `winsvr2022` was
stopped and undefined to avoid a libvirt name conflict. The block/LVM evidence
LV was not deleted. The Nutanix source VM was already `OFF` during the precheck,
so the final shutdown step recorded `after_state=OFF` but did not exercise a
live guest shutdown transition in this run.

Run ID: `host-rbd-krbd-full-winsvr2022-20260515-140407`  
Workdir:

```text
/var/lib/ablestack-n2k/e2e/host-rbd-krbd-full-winsvr2022-20260515-140407
```

Target disk:

```text
rbd:rbd/n2k-host-rbd-krbd-full-winsvr2022-20260515-140407-disk0
```

Mapped krbd device:

```text
/dev/rbd/rbd/n2k-host-rbd-krbd-full-winsvr2022-20260515-140407-disk0
```

Command shape:

```bash
ablestack_n2k run \
  --vm winsvr2022 \
  --pc 10.10.131.11 \
  --inventory-source api \
  --target-storage rbd \
  --target-format raw \
  --rbd-access-mode krbd \
  --dst rbd:rbd/n2k-host-rbd-krbd-full-winsvr2022-20260515-140407 \
  --split full \
  --source-api v3 \
  --nfs-host 10.10.131.10 \
  --shutdown guest \
  --apply \
  --start
```

Manifest evidence:

- `target.storage.rbd_access_mode=krbd`
- `runtime.split.phase1.done=false`
- `runtime.split.phase2.done=false`
- `phases.base_sync.done=true`
- `phases.incr_sync.done=true`
- `phases.final_sync.done=true`
- `phases.cutover.done=true`
- shutdown policy `guest`, final source state `OFF`
- final sync changed bytes: `0`
- final sync changed regions: `0`

Runtime validation:

- After 180 seconds, libvirt reported `running`.
- CPU time advanced to `124.1s`, confirming the guest was executing.
- QEMU guest agent was not available in the guest, so network readiness was checked through libvirt DHCP lease data.
- DHCP lease was observed as `192.168.122.239/24`.
- `rbd showmapped` showed the target image mapped to `/dev/rbd1`.
- `/dev/rbd/rbd/n2k-host-rbd-krbd-full-winsvr2022-20260515-140407-disk0` existed as a block device.
- `blockdev --getsize64` returned `107374182400`, matching the 100 GiB source disk.
- libvirt XML used `<disk type='block'>` with `<source dev='/dev/rbd/rbd/n2k-host-rbd-krbd-full-winsvr2022-20260515-140407-disk0'>`.
- libvirt XML used secure boot OVMF: `OVMF_CODE.secboot.fd` and `OVMF_VARS.secboot.fd`.
- Target readback found GPT with EFI, Microsoft reserved, NTFS basic data, and NTFS recovery partitions.

Current state after validation:

| VM | Domain state | Backend |
| --- | --- | --- |
| `rhel` | `running` | qcow2 full one-shot target |
| `winsvr2022` | `running` | RBD krbd full one-shot target |
