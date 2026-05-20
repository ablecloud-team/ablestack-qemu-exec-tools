# ablestack_n2k PC132 qcow2 and LVM block cutoff E2E test plan

## Purpose

The previous PC132 cutoff E2E pass validated the migration flow with RBD target
storage. This document extends the same cutoff validation to two additional
target backends:

1. qcow2 files under the target host local image path
   `/var/lib/libvirt/images`.
2. raw block devices backed by LVM logical volumes created from confirmed empty
   disks.

This document is both the execution scenario and the result ledger. Every case
must be updated with a final `PASS`, `FAIL`, or `BLOCKED` result after it is
executed.

## Environment

Source Nutanix environment:

- Prism Central: `https://10.10.132.100:9440`
- Discovered PE v3 source endpoint: `10.10.132.10`
- Prism user: `admin`
- Prism password: do not store in this repository or this document.
- Expected selected data path: v3 incremental through PE `10.10.132.10`.

Target ABLESTACK hosts:

- `10.10.22.1`
- `10.10.22.2`
- `10.10.22.3`
- SSH port: `10022`
- SSH user: `root`
- SSH password: do not store in this repository or this document.

Installed package baseline:

- RPM: `ablestack_n2k-0.8.0-1.el9.el9.noarch`
- Build date: `2026-05-17 16:45:59 KST`
- RPM SHA256:
  `8090d318cd34e6803fdde228c7ddfa1d27f2df4c39dd521dcd82d5896da6772d`

## Scope

This plan originally repeated the full 12-case scenario shape for both qcow2
and LVM block backends. After Q01 through Q06 passed, the remaining execution
scope is reduced to abbreviated coverage:

- Completed baseline: qcow2 v3 force Phase1/Phase2 for `rhel`,
  `centos7-bios-ide`, and `win10`.
- Completed baseline: qcow2 v3 force full for `rhel`, `centos7-bios-ide`, and
  `win10`.
- Remaining abbreviated validation: three total runs, one per VM across the
  remaining qcow2 auto fallback and LVM block risks.

The abbreviated matrix preserves all VM disk topologies while avoiding repeated
combinations that Q01 through Q06 already validated.

The following VM remains excluded:

| VM | Reason |
| --- | --- |
| `windows11` | Not in a normal running state in the current PC132 testbed |

## Source VM disk topology

The PC132 testbed intentionally includes multi-disk guests for storage-path
stability validation. The source inventory must be re-read before every case,
but the expected topology for this pass is:

| VM | Expected migration disks | Purpose |
| --- | ---: | --- |
| `rhel` | 3 | Linux UEFI guest with one original disk plus two additional disks |
| `centos7-bios-ide` | 1 | Linux BIOS/IDE compatibility guest |
| `win10` | 2 | Windows guest with one original disk plus one additional disk |

If `rhel` does not expose exactly 3 migration disks, or `win10` does not expose
exactly 2 migration disks, stop the case before migration and record it as
`BLOCKED`. The extra disks are part of the test objective, not optional
capacity.

Every successful `rhel` and `win10` case must prove that all source disks were:

- discovered in the manifest,
- assigned unique target paths,
- base-synced,
- included in incremental/final sync accounting,
- emitted into the target libvirt XML, and
- visible as the expected number of target disks after cutoff.

## Backend goals

| Backend | Target storage | Target format | Primary validation |
| --- | --- | --- | --- |
| qcow2 file | `file` | `qcow2` | Local file target under `/var/lib/libvirt/images`; base convert plus qemu-nbd incremental patch path |
| LVM block | `block` | `raw` | Direct raw writes to LV-backed block devices; libvirt XML uses `<disk type='block'>` |

## Abbreviated coverage rationale

The reduced plan keeps the riskiest dimensions visible:

- Q01 through Q06 already proved v3 force, split/full cutoff styles, qcow2
  target creation, qemu-io/qemu-img patching, source shutdown, target
  define/start, and snapshot cleanup for all three supported test VMs.
- Q07 focuses on PC v4 / PE v3 auto fallback route selection in the qcow2
  backend with the BIOS/IDE compatibility VM.
- B01 and B02 focus on the LVM block backend with the two multi-disk guests.
- `rhel` and `win10` remain mandatory multi-disk checks; `centos7-bios-ide`
  remains the BIOS/IDE compatibility check.
- Every remaining successful case must still prove cutoff `--apply --start`,
  source shutdown, target boot, disk-count parity, and Nutanix snapshot cleanup.

## Global execution policy

Run one case at a time.

Before each case:

1. Confirm the source VM is `ON` in PC132/PE inventory.
2. Confirm the source VM is not `windows11`.
3. Confirm the source VM disk count matches the expected topology:
   - `rhel`: 3 migration disks.
   - `centos7-bios-ide`: 1 migration disk.
   - `win10`: 2 migration disks.
4. Confirm every discovered source disk has a non-empty disk ID and size.
5. Confirm there is no target libvirt domain conflict on the assigned host.
6. Confirm no stale Nutanix `n2k-*` snapshot exists unless it is intentional
   evidence from a failed case.
7. Confirm target backend readiness:
   - qcow2: enough free space under `/var/lib/libvirt/images`.
   - LVM block: candidate disks are confirmed empty and are not mounted, not in
     use, and not part of any existing VG unless that VG is the dedicated test
     VG for this plan.
8. Export credentials at runtime only.

During cutoff:

- Use `--shutdown guest`.
- Allow the implementation to fall back to `poweroff` if guest shutdown fails or
  times out.
- Use `--apply --start` so cutoff defines and starts the target VM.
- Use `--network-mode bridge --bridge bridge0` for these tests unless a case is
  explicitly changed to validate libvirt NAT network mode.

After each case:

1. Record `manifest.json`, `events.log`, generated libvirt XML, command output,
   and final verification summary.
2. Confirm the target VM reaches `running` or record the failure.
3. Confirm the target disk backend in libvirt XML:
   - qcow2: `<disk type='file'>`, driver type `qcow2`, source file under
     `/var/lib/libvirt/images`.
   - LVM block: `<disk type='block'>`, driver type `raw`, source device under
     the dedicated test VG.
4. Confirm the libvirt XML disk count matches the manifest disk count.
5. For `rhel` and `win10`, confirm every additional disk has a distinct target
   file or LV and is not collapsed into disk0.
6. Confirm source VM is `OFF` after successful cutoff.
7. Confirm Nutanix `n2k-*` source snapshots are cleaned up after successful
   cutoff.
8. Stop and undefine the target VM before powering the source VM back on for the
   next case.
9. Keep workdir evidence. Storage artifacts may be preserved only while space is
   acceptable; LVM LVs should normally be removed after evidence is collected.

Do not power the source VM back on while a migrated target VM with the same MAC
is still running on the same network.

## Runtime variables

Set these on the target host shell or through the operator SSH wrapper.

```bash
export PC_URL='https://10.10.132.100:9440'
export PC_USER='admin'
export PC_PASS='<runtime-only>'
export N2K_INSECURE='1'
export N2K_BASE_WORKDIR='/var/lib/ablestack/n2k-e2e/pc132-storage'
export N2K_QCOW2_ROOT='/var/lib/libvirt/images/n2k/pc132-storage'
export N2K_BLOCK_VG='n2k_pc132_e2e'
export N2K_BRIDGE='bridge0'
```

SSH execution from the operator workstation should use:

```bash
ssh -p 10022 root@<target-host>
```

When automating SSH, pass the SSH password at runtime only. Do not write it into
scripts committed to the repository.

## Readiness checks

Run on every target host before starting qcow2 or block cases:

```bash
rpm -q ablestack_n2k
command -v ablestack_n2k
bash -n /usr/local/bin/ablestack_n2k /usr/local/lib/ablestack-qemu-exec-tools/n2k/*.sh
command -v qemu-img
command -v qemu-nbd
command -v virsh
virsh list --all
ip link show "${N2K_BRIDGE}"
df -h /var/lib/libvirt/images
```

Additional qcow2 readiness:

```bash
mkdir -p "${N2K_QCOW2_ROOT}"
test -w "${N2K_QCOW2_ROOT}"
modprobe nbd max_part=16 || true
lsmod | grep '^nbd' || true
```

Additional LVM block readiness:

```bash
command -v lsblk
command -v wipefs
command -v pvs
command -v vgs
command -v lvs
command -v pvcreate
command -v vgcreate
command -v lvcreate
lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,PKNAME
pvs --noheadings -o pv_name,vg_name,pv_size 2>/dev/null || true
vgs --noheadings -o vg_name,vg_size,vg_free 2>/dev/null || true
```

## LVM block disk safety gate

Block/LVM tests are destructive to the selected target disks. A disk is eligible
only when all checks pass:

- It is not the OS disk.
- It has no mounted filesystem.
- It has no holders under `/sys/class/block/<disk>/holders`.
- It is not part of an existing production VG.
- `wipefs -n` shows no signature, or the operator explicitly approves wiping a
  known previous test signature.
- No libvirt domain currently uses the disk or any LV created from it.

For the current lab, the known previous block candidates were `/dev/sdg` and
`/dev/sdh` on `10.10.22.1`, but they must be revalidated before reuse. Do not
assume those paths are still safe.

Candidate validation example:

```bash
for dev in /dev/sdg /dev/sdh; do
  echo "== ${dev} =="
  test -b "${dev}"
  lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS "${dev}"
  wipefs -n "${dev}" || true
  findmnt -S "${dev}" || true
  base="$(basename "${dev}")"
  find "/sys/class/block/${base}/holders" -mindepth 1 -maxdepth 1 -print
done
pvs --noheadings -o pv_name,vg_name | grep -E '/dev/sdg|/dev/sdh' || true
```

Dedicated test VG preparation example:

```bash
pvcreate -ff -y /dev/sdg /dev/sdh
vgcreate "${N2K_BLOCK_VG}" /dev/sdg /dev/sdh
vgs "${N2K_BLOCK_VG}"
```

After all block cases are complete and evidence has been collected:

```bash
vgremove -y "${N2K_BLOCK_VG}"
pvremove -ff -y /dev/sdg /dev/sdh
wipefs -a /dev/sdg /dev/sdh
```

## Source disk discovery for block target maps

`--target-storage block` requires a complete `--target-map-json` for every
source disk. Discover VM disk IDs and sizes before creating LVs:

```bash
DISCOVERY_WORKDIR="${N2K_BASE_WORKDIR}/discovery/${VM}"
rm -rf "${DISCOVERY_WORKDIR}"
ablestack_n2k --json \
  --workdir "${DISCOVERY_WORKDIR}" \
  --manifest "${DISCOVERY_WORKDIR}/manifest.json" \
  init \
  --vm "${VM}" \
  --pc "${PC_URL}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --inventory-source api \
  --dst "${DISCOVERY_WORKDIR}/dst" \
  --target-storage file \
  --target-format qcow2

jq -r '.disks[] | [.disk_id, .size_bytes] | @tsv' \
  "${DISCOVERY_WORKDIR}/manifest.json"
```

Validate the expected disk count immediately after discovery:

```bash
case "${VM}" in
  rhel) EXPECTED_DISKS=3 ;;
  centos7-bios-ide) EXPECTED_DISKS=1 ;;
  win10) EXPECTED_DISKS=2 ;;
  *) echo "Unexpected VM for this plan: ${VM}" >&2; exit 2 ;;
esac

ACTUAL_DISKS="$(jq -r '.disks | length' "${DISCOVERY_WORKDIR}/manifest.json")"
test "${ACTUAL_DISKS}" -eq "${EXPECTED_DISKS}"
jq -e '[.disks[] | select((.disk_id // "") == "" or (.size_bytes // 0) <= 0)] | length == 0' \
  "${DISCOVERY_WORKDIR}/manifest.json"
```

For each disk, create a dedicated LV with the same size as the source disk.
The current PC132 test objective expects `rhel` to have 3 migration disks and
`win10` to have 2 migration disks. Do not proceed with a reduced disk count.

Single-disk LV example:

```bash
DISK_ID='<disk-id-from-discovery>'
SIZE_BYTES='<size-bytes-from-discovery>'
LV_NAME='<case-safe-lv-name>_disk0'
LV_PATH="/dev/${N2K_BLOCK_VG}/${LV_NAME}"

lvcreate -y -L "${SIZE_BYTES}B" -n "${LV_NAME}" "${N2K_BLOCK_VG}"
test "$(blockdev --getsize64 "${LV_PATH}")" -ge "${SIZE_BYTES}"
TARGET_MAP_JSON="$(jq -nc --arg disk_id "${DISK_ID}" --arg path "${LV_PATH}" '{($disk_id):$path}')"
```

If a VM has multiple disks, create one LV per disk and include every disk ID in
`TARGET_MAP_JSON`.

Multi-disk LV map example:

```bash
VM_SAFE="$(printf '%s' "${VM}" | tr -c '[:alnum:]_' '_')"
CASE_SAFE="$(printf '%s' "${CASE_ID}" | tr -c '[:alnum:]_' '_')"
TARGET_MAP_JSON='{}'

idx=0
while IFS=$'\t' read -r disk_id size_bytes; do
  LV_NAME="${CASE_SAFE}_${VM_SAFE}_disk${idx}"
  LV_PATH="/dev/${N2K_BLOCK_VG}/${LV_NAME}"
  lvcreate -y -L "${size_bytes}B" -n "${LV_NAME}" "${N2K_BLOCK_VG}"
  test "$(blockdev --getsize64 "${LV_PATH}")" -ge "${size_bytes}"
  TARGET_MAP_JSON="$(jq -c \
    --arg disk_id "${disk_id}" \
    --arg path "${LV_PATH}" \
    '. + {($disk_id):$path}' <<<"${TARGET_MAP_JSON}")"
  idx=$((idx + 1))
done < <(jq -r '.disks[] | [.disk_id, .size_bytes] | @tsv' \
  "${DISCOVERY_WORKDIR}/manifest.json")

echo "${TARGET_MAP_JSON}" | jq -e --argjson expected "${EXPECTED_DISKS}" \
  'length == $expected'
```

## Command templates

Mode arguments:

| Scenario | `MODE_ARGS` |
| --- | --- |
| v3 force | `--force-v3` |
| PC v4 / PE v3 auto fallback | empty |

Expected mode assertions:

| Scenario | Expected fields |
| --- | --- |
| v3 force | `selected_mode=v3-incremental`, `source_api_policy=v3`, `mode_forced=true`, `api.v3.source_endpoint=10.10.132.10` |
| PC v4 / PE v3 auto fallback | `selected_mode=v3-incremental`, `source_api_policy=auto`, `mode_forced=false`, `api.v3.source_endpoint=10.10.132.10` |

### qcow2 Phase1

```bash
WORKDIR="${N2K_BASE_WORKDIR}/${CASE_ID}"
DST="${N2K_QCOW2_ROOT}/${CASE_ID}"

ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  --manifest "${WORKDIR}/manifest.json" \
  --log "${WORKDIR}/events.log" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "${DST}" \
  --target-storage file \
  --target-format qcow2 \
  --split phase1 \
  --network-mode bridge \
  --bridge "${N2K_BRIDGE}" \
  ${MODE_ARGS}
```

### qcow2 Phase2 cutoff

```bash
WORKDIR="${N2K_BASE_WORKDIR}/${CASE_ID}"
DST="${N2K_QCOW2_ROOT}/${CASE_ID}"

ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  --manifest "${WORKDIR}/manifest.json" \
  --log "${WORKDIR}/events.log" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "${DST}" \
  --target-storage file \
  --target-format qcow2 \
  --split phase2 \
  --shutdown guest \
  --shutdown-timeout-sec 300 \
  --shutdown-poll-sec 5 \
  --apply \
  --start \
  --network-mode bridge \
  --bridge "${N2K_BRIDGE}" \
  ${MODE_ARGS}
```

### qcow2 full cutoff

```bash
WORKDIR="${N2K_BASE_WORKDIR}/${CASE_ID}"
DST="${N2K_QCOW2_ROOT}/${CASE_ID}"

ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  --manifest "${WORKDIR}/manifest.json" \
  --log "${WORKDIR}/events.log" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "${DST}" \
  --target-storage file \
  --target-format qcow2 \
  --split full \
  --shutdown guest \
  --shutdown-timeout-sec 300 \
  --shutdown-poll-sec 5 \
  --apply \
  --start \
  --network-mode bridge \
  --bridge "${N2K_BRIDGE}" \
  ${MODE_ARGS}
```

### LVM block Phase1

```bash
WORKDIR="${N2K_BASE_WORKDIR}/${CASE_ID}"
DST="/dev/${N2K_BLOCK_VG}"

ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  --manifest "${WORKDIR}/manifest.json" \
  --log "${WORKDIR}/events.log" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "${DST}" \
  --target-storage block \
  --target-format raw \
  --target-map-json "${TARGET_MAP_JSON}" \
  --split phase1 \
  --network-mode bridge \
  --bridge "${N2K_BRIDGE}" \
  ${MODE_ARGS}
```

### LVM block Phase2 cutoff

```bash
WORKDIR="${N2K_BASE_WORKDIR}/${CASE_ID}"
DST="/dev/${N2K_BLOCK_VG}"

ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  --manifest "${WORKDIR}/manifest.json" \
  --log "${WORKDIR}/events.log" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "${DST}" \
  --target-storage block \
  --target-format raw \
  --target-map-json "${TARGET_MAP_JSON}" \
  --split phase2 \
  --shutdown guest \
  --shutdown-timeout-sec 300 \
  --shutdown-poll-sec 5 \
  --apply \
  --start \
  --network-mode bridge \
  --bridge "${N2K_BRIDGE}" \
  ${MODE_ARGS}
```

### LVM block full cutoff

```bash
WORKDIR="${N2K_BASE_WORKDIR}/${CASE_ID}"
DST="/dev/${N2K_BLOCK_VG}"

ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  --manifest "${WORKDIR}/manifest.json" \
  --log "${WORKDIR}/events.log" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "${DST}" \
  --target-storage block \
  --target-format raw \
  --target-map-json "${TARGET_MAP_JSON}" \
  --split full \
  --shutdown guest \
  --shutdown-timeout-sec 300 \
  --shutdown-poll-sec 5 \
  --apply \
  --start \
  --network-mode bridge \
  --bridge "${N2K_BRIDGE}" \
  ${MODE_ARGS}
```

## Verification checklist

Run after each successful cutoff:

```bash
jq -e '.runtime.selected_mode == "v3-incremental"' "${WORKDIR}/manifest.json"
jq -e '.source.api.family == "v3"' "${WORKDIR}/manifest.json"
jq -e '.phases.final_sync.done == true' "${WORKDIR}/manifest.json"
jq -e '.phases.cutover.done == true' "${WORKDIR}/manifest.json"
jq -e '.runtime.source_shutdown.ok == true' "${WORKDIR}/manifest.json"
virsh domstate "${VM}"
virsh dumpxml "${VM}" > "${WORKDIR}/evidence/target.dumpxml"

case "${VM}" in
  rhel) EXPECTED_DISKS=3 ;;
  centos7-bios-ide) EXPECTED_DISKS=1 ;;
  win10) EXPECTED_DISKS=2 ;;
  *) echo "Unexpected VM for this plan: ${VM}" >&2; exit 2 ;;
esac

jq -e --argjson expected "${EXPECTED_DISKS}" '.disks | length == $expected' \
  "${WORKDIR}/manifest.json"
jq -e '[.disks[].transfer.target_path] | length == (unique | length)' \
  "${WORKDIR}/manifest.json"
jq -e '[.disks[] | select(.transfer.base_done != true)] | length == 0' \
  "${WORKDIR}/manifest.json"
test "$(grep -c "<disk type=" "${WORKDIR}/evidence/target.dumpxml")" -ge "${EXPECTED_DISKS}"
```

qcow2-specific checks:

```bash
jq -r '.disks[].transfer.target_path' "${WORKDIR}/manifest.json"
while IFS= read -r target_path; do
  test -f "${target_path}"
  qemu-img info "${target_path}"
done < <(jq -r '.disks[].transfer.target_path' "${WORKDIR}/manifest.json")
grep -q "type='file'" "${WORKDIR}/evidence/target.dumpxml"
grep -q "type='qcow2'" "${WORKDIR}/evidence/target.dumpxml"
grep -q "/var/lib/libvirt/images" "${WORKDIR}/evidence/target.dumpxml"
test "$(grep -c "type='file'" "${WORKDIR}/evidence/target.dumpxml")" -ge "${EXPECTED_DISKS}"
```

LVM block-specific checks:

```bash
jq -r '.disks[].transfer.target_path' "${WORKDIR}/manifest.json"
while IFS= read -r target_path; do
  test -b "${target_path}"
  blockdev --getsize64 "${target_path}"
done < <(jq -r '.disks[].transfer.target_path' "${WORKDIR}/manifest.json")
lvs "${N2K_BLOCK_VG}"
grep -q "type='block'" "${WORKDIR}/evidence/target.dumpxml"
grep -q "type='raw'" "${WORKDIR}/evidence/target.dumpxml"
grep -q "/dev/${N2K_BLOCK_VG}/" "${WORKDIR}/evidence/target.dumpxml"
test "$(grep -c "type='block'" "${WORKDIR}/evidence/target.dumpxml")" -ge "${EXPECTED_DISKS}"
```

Source cleanup checks:

```bash
# Use the existing PC132 helper or source API probe to confirm:
# - source VM power_state is OFF after cutoff
# - Nutanix snapshots whose names start with n2k- are 0 after successful cutoff
```

## Cleanup commands

Run after evidence collection and before reusing the same source VM.

Target domain cleanup:

```bash
virsh destroy "${VM}" 2>/dev/null || true
virsh undefine "${VM}" --nvram 2>/dev/null || virsh undefine "${VM}" 2>/dev/null || true
```

qcow2 cleanup, when storage evidence no longer needs to be preserved:

```bash
rm -rf "${N2K_QCOW2_ROOT:?}/${CASE_ID}"
```

LVM LV cleanup, when block evidence no longer needs to be preserved:

```bash
lvremove -y "${LV_PATH}"
```

Source VM restore for the next case:

```bash
# Start the source VM through the selected PE/PC only after the target VM is
# stopped and undefined.
```

## qcow2 test matrix

The qcow2 backend keeps completed Q01 through Q06 as the v3-force baseline.
Remaining qcow2 execution is reduced to Q07, one PC v4 / PE v3 auto-fallback
sample. Use
`/var/lib/libvirt/images/n2k/pc132-storage/<case-id>` as the destination root.

| Case | Scenario | Cutoff style | VM | Host | Case ID | Destination root | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `Q01` | v3 force | Phase1/Phase2 | `rhel` | `10.10.22.2` | `Q01-rhel-force-v3-split-qcow2-retest-20260517-155338` | `/var/lib/libvirt/images/n2k/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338` | PASS |
| `Q02` | v3 force | Phase1/Phase2 | `centos7-bios-ide` | `10.10.22.1` | `Q02-centos-force-v3-split-qcow2` | `/var/lib/libvirt/images/n2k/pc132-storage/Q02-centos-force-v3-split-qcow2` | PASS |
| `Q03` | v3 force | Phase1/Phase2 | `win10` | `10.10.22.3` | `Q03-win10-force-v3-split-qcow2` | `/var/lib/libvirt/images/n2k/pc132-storage/Q03-win10-force-v3-split-qcow2` | PASS |
| `Q04` | v3 force | full | `rhel` | `10.10.22.3` | `Q04-rhel-force-v3-full-qcow2` | `/var/lib/libvirt/images/n2k/pc132-storage/Q04-rhel-force-v3-full-qcow2` | PASS |
| `Q05` | v3 force | full | `centos7-bios-ide` | `10.10.22.2` | `Q05-centos-force-v3-full-qcow2` | `/var/lib/libvirt/images/n2k/pc132-storage/Q05-centos-force-v3-full-qcow2` | PASS |
| `Q06` | v3 force | full | `win10` | `10.10.22.1` | `Q06-win10-force-v3-full-qcow2` | `/var/lib/libvirt/images/n2k/pc132-storage/Q06-win10-force-v3-full-qcow2` | PASS |
| `Q07` | PC v4 / PE v3 auto fallback | Phase1/Phase2 | `centos7-bios-ide` | `10.10.22.1` | `Q07-centos-auto-fallback-split-qcow2` | `/var/lib/libvirt/images/n2k/pc132-storage/Q07-centos-auto-fallback-split-qcow2` | PASS |

## LVM block test matrix

The block backend is reduced to two cases for the two multi-disk VMs. Each case
is gated by confirmed empty LVM capacity on the assigned host. The current lab
default is `10.10.22.1` with revalidated empty `/dev/sdg` and `/dev/sdh`; if a
different storage-qualified host is used, record the override in the ledger
before running the case.

| Case | Scenario | Cutoff style | VM | Default host | Case ID | LV prefix | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `B01` | v3 force | Phase1/Phase2 | `rhel` | `10.10.22.1` | `B01-rhel-force-v3-split-block` | `b01_rhel_force_v3_split` | PASS |
| `B02` | PC v4 / PE v3 auto fallback | full | `win10` | `10.10.22.1` | `B02-win10-auto-fallback-full-block` | `b02_win10_auto_fallback_full` | PASS |

## Result ledger

| Case | Backend | Result | Started | Completed | Host | Evidence path | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `Q01` | qcow2 | PASS | 2026-05-17 15:53 KST | 2026-05-17 15:57 KST | `10.10.22.2` | `/var/lib/ablestack/n2k-e2e/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338/evidence` | Initial run failed after libvirt start because the guest entered dracut emergency mode and offline root LV mount failed. The engine was patched to materialize Nutanix NFS patch sources through read-only qemu-nbd virtual offsets and to write qcow2 target regions with qemu-io instead of target kernel NBD. Retest passed: Phase1/Phase2 selected `v3-incremental`, `source_api_policy=v3`, `mode_forced=true`, and selected PE endpoint `10.10.132.10` for source shutdown. Phase1 root LV read-only mount succeeded, final sync changed `46` regions / `586240` bytes, cutoff apply/start succeeded, QGA `guest-ping` succeeded, target `rhel` is running with three qcow2 file disks `sda/sdb/sdc`, source VM is `OFF`, and Nutanix `n2k-*` snapshot count is `0`. |
| `Q02` | qcow2 | PASS | 2026-05-17 16:03 KST | 2026-05-17 16:09 KST | `10.10.22.1` | `/var/lib/ablestack/n2k-e2e/pc132-storage/Q02-centos-force-v3-split-qcow2/evidence` | v3 force Phase1/Phase2 cutoff completed for `centos7-bios-ide` with 1 migration disk. Phase1 and Phase2 selected `v3-incremental`, `source_api_policy=v3`, `mode_forced=true`, and selected PE endpoint `10.10.132.10` for source shutdown. Base sync wrote `107374182400` bytes. Phase1 incremental changed `2` regions / `1536` bytes, Phase2 pre-cutoff incremental changed `0` regions / `0` bytes, and final sync changed `35` regions / `412672` bytes. Phase1 offline root mount succeeded with XFS `ro,norecovery`, cutoff apply/start succeeded, QGA `guest-ping` and `guest-get-osinfo` succeeded for CentOS Linux 7, target is running on bridge `bridge0` with one qcow2 disk `sda`, source VM is `OFF`, and Nutanix `n2k-*` snapshot count is `0`. |
| `Q03` | qcow2 | PASS | 2026-05-17 16:14 KST | 2026-05-17 16:26 KST | `10.10.22.3` | `/var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/evidence` | v3 force Phase1/Phase2 cutoff completed for `win10` with 2 migration disks. Phase1 and Phase2 selected `v3-incremental`, `source_api_policy=v3`, and `mode_forced=true`. Base sync wrote both source disks (`107374182400` and `10737418240` bytes). Phase1 incremental changed `17` regions / `540672` bytes, Phase2 pre-cutoff incremental changed `39` regions / `438272` bytes, and final sync changed `131` regions / `2928640` bytes. Cutoff apply/start succeeded through `bridge0`; target `win10` is running with two qcow2 file disks `sda/sdb`. QGA is not connected in this guest, so boot was verified through HMP console screendump showing the Windows 10 lock screen. Source VM is `OFF`, all recorded v3 recovery points were deleted, and Nutanix `n2k-*` snapshot count is `0`. Q03 also exposed a slow v3 shutdown polling path because inventory lookup attempted PE v4 first before falling back; the source tree has a local `N2K_NUTANIX_INVENTORY_SKIP_V4=1` fix prepared for the v3 shutdown path and should be rebuilt/deployed before the next case. |
| `Q04` | qcow2 | PASS | 2026-05-17 16:56 KST | 2026-05-17 17:00 KST | `10.10.22.3` | `/var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/evidence` | v3 force full cutoff completed for `rhel` with 3 migration disks. Source `rhel` was restored to `ON` only after the previous Q01 target `rhel` domain was stopped/undefined to avoid duplicate MAC use. Full run selected `v3-incremental` through PE endpoint `10.10.132.10`; base sync wrote all 3 disks (`107374182400`, `10737418240`, `10737418240` bytes), first incremental changed `132` regions / `2646016` bytes, and final sync changed `44` regions / `590336` bytes. Guest shutdown completed through `ACPI_SHUTDOWN`, cutoff apply/start succeeded, target `rhel` is running on `bridge0` with three qcow2 file disks `sda/sdb/sdc`, QGA `guest-ping` and OS info passed for Red Hat Enterprise Linux 8.8, guest disk/fs info shows the two extra disks backing `vg_data-lv_data` mounted on `/mnt`, source VM is `OFF`, all recorded v3 recovery points were deleted, and Nutanix `n2k-*` snapshot count is `0`. |
| `Q05` | qcow2 | PASS | 2026-05-17 17:07 KST | 2026-05-17 17:10 KST | `10.10.22.2` | `/var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/evidence` | v3 force full cutoff completed for `centos7-bios-ide` with 1 migration disk. The previous Q02 target `centos7-bios-ide` domain on 10.10.22.1 was stopped/undefined before the source was powered back on. Full run selected `v3-incremental` through PE endpoint `10.10.132.10`; base sync wrote `107374182400` bytes, first incremental changed `56` regions / `3103232` bytes, and final sync changed `38` regions / `438784` bytes. Guest shutdown completed through `ACPI_SHUTDOWN`, cutoff apply/start succeeded, target `centos7-bios-ide` is running on `bridge0` with one qcow2 file disk, QGA `guest-ping`, `guest-get-osinfo`, and `guest-get-fsinfo` passed for CentOS Linux 7. This older QGA does not support `guest-get-disks`, so disk validation used libvirt block list, fsinfo, and qemu-img check. Source VM is `OFF`, all recorded v3 recovery points were deleted, and Nutanix `n2k-*` snapshot count is `0`. |
| `Q06` | qcow2 | PASS | 2026-05-17 17:17 KST | 2026-05-17 17:21 KST | `10.10.22.1` | `/var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/evidence` | v3 force full cutoff completed for `win10` with 2 migration disks. The previous Q03 target `win10` domain on 10.10.22.3 was stopped/undefined before the source was powered back on. Full run selected `v3-incremental` through PE endpoint `10.10.132.10`; base sync wrote both source disks (`107374182400` and `10737418240` bytes), first incremental changed `2128` regions / `1126754816` bytes, and final sync changed `1818` regions / `38823424` bytes. Guest shutdown completed through `ACPI_SHUTDOWN`, cutoff apply/start succeeded, target `win10` is running on `bridge0` with two qcow2 file disks. QGA is not connected in this guest, so boot was verified through HMP console screendump showing the Windows 10 lock screen. Source VM is `OFF`, all recorded v3 recovery points were deleted, and Nutanix `n2k-*` snapshot count is `0`. |
| `Q07` | qcow2 | PASS | 2026-05-17 17:56 KST | 2026-05-17 18:00 KST | `10.10.22.1` | `/var/lib/ablestack/n2k-e2e/pc132-storage/Q07-centos-auto-fallback-split-qcow2/evidence` | PC v4 / PE v3 auto fallback Phase1/Phase2 cutoff completed for `centos7-bios-ide` with 1 migration disk. The run selected `v3-incremental`, `source_api_policy=auto`, `mode_forced=false`, and PE endpoint `10.10.132.10`. Base sync wrote `107374182400` bytes, Phase1 incremental changed `50` regions / `864768` bytes, Phase2 pre-cutoff incremental changed `0` regions / `0` bytes, and final sync changed `45` regions / `583680` bytes. Cutoff apply/start succeeded, target is running on `bridge0` with one qcow2 disk, source VM is `OFF`, and Nutanix `n2k-*` snapshot count is `0`. An initial wrapper attempt failed because `umask 077` made qcow2 storage inaccessible to qemu; the failed artifacts and snapshots were cleaned, the retry normalized permissions, and the final migration passed. The retry wrapper exited nonzero only because an assertion used stale manifest field paths; supplemental verification confirmed PASS. |
| `B01` | LVM block | PASS | 2026-05-17 18:05 KST | 2026-05-17 18:16 KST | `10.10.22.1` | `/var/lib/ablestack/n2k-e2e/pc132-storage/B01-rhel-force-v3-split-block/evidence` | v3 force Phase1/Phase2 cutoff completed for `rhel` with 3 migration disks on LV-backed raw block targets. The run selected `v3-incremental`, `source_api_policy=v3`, `mode_forced=true`, and PE endpoint `10.10.132.10`. Target LVs were `/dev/n2k_block_e2e/b01_rhel_force_v3_split_disk0`, `disk1`, and `disk2` sized `107374182400`, `10737418240`, and `10737418240` bytes. Phase1 incremental changed `12` regions / `151552` bytes, Phase2 pre-cutoff incremental changed `0` regions / `0` bytes, and final sync changed `43` regions / `532992` bytes. Cutoff apply/start succeeded, target `rhel` is running on `bridge0` with three `<disk type='block'>` raw devices, QGA `guest-ping` and OS info passed for RHEL 8.8, QGA fsinfo showed the two additional disks backing `/mnt`, source VM is `OFF`, and Nutanix `n2k-*` snapshot count is `0`. |
| `B02` | LVM block | PASS | 2026-05-17 18:18 KST | 2026-05-17 18:32 KST | `10.10.22.1` | `/var/lib/ablestack/n2k-e2e/pc132-storage/B02-win10-auto-fallback-full-block/evidence` | PC v4 / PE v3 auto fallback full cutoff completed for `win10` with 2 migration disks on LV-backed raw block targets. The run selected `v3-incremental`, `source_api_policy=auto`, `mode_forced=false`, and PE endpoint `10.10.132.10`. Target LVs were `/dev/n2k_block_e2e/b02_win10_auto_fallback_full_disk0` and `disk1` sized `107374182400` and `10737418240` bytes. Base sync completed for both disks, the first incremental pass changed `928` regions / `36303872` bytes, and final sync changed `1497` regions / `17106432` bytes. Cutoff apply/start succeeded, target `win10` is running on `bridge0` with two `<disk type='block'>` raw devices, QGA is not connected, and boot was verified by HMP screendump showing the Windows 10 lock screen. Source VM is `OFF` and Nutanix `n2k-*` snapshot count is `0`. The wrapper's in-evidence HMP path was not writable by qemu, so supplemental verification used `/tmp/win10-b02.ppm` and copied it into evidence as `win10-hmp.ppm`; this was a test harness permission issue, not an engine migration failure. |

## Recorded case results

### Q01 - qcow2 v3 force Phase1/Phase2 rhel

```text
Case: Q01
Backend: qcow2
Started at: 2026-05-17 15:53 KST
Completed at: 2026-05-17 15:57 KST
Operator: Codex
Host: 10.10.22.2
VM: rhel
Scenario: v3 force
Cutoff style: Phase1/Phase2
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338
Target root or LV path: /var/lib/libvirt/images/n2k/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338
Target map JSON: not applicable for qcow2 file target

Pre-check:
- Source power state before run: ON
- Expected migration disk count: 3
- Actual migration disk count: 3
- Source disk IDs and sizes:
  ae29c318-5dca-44b3-93c6-f3f3714177ec / 107374182400
  afe42ac0-bb0a-4022-b9cf-3a5409eb21fb / 10737418240
  ee5d7f96-7d87-46e4-996c-efcc4d7d8dde / 10737418240
- Target domain conflict check: none on 10.10.22.2
- Existing target storage artifact check: none
- Existing Nutanix n2k-* snapshot count: 0
- Target host bridge check: bridge0 UP
- Backend readiness: qemu-img, qemu-io, qemu-nbd, virsh present; /var/lib/libvirt/images available
- Preflight selected mode: v3-incremental
- Preflight source API policy: v3
- Preflight mode_forced: true
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Phase1 result: PASS
- Phase1 base sync: 3 disks, 107374182400 / 10737418240 / 10737418240 bytes
- Phase1 incremental sync: 23 regions / 229376 bytes
- Phase1 offline root mount check: PASS; `/dev/rhel_rhel/root` mounted read-only and `/etc/fstab` was readable
- Phase2 result: PASS
- Phase2 incremental sync before cutoff: 1 region / 16384 bytes
- Shutdown policy/result: guest, PASS through selected PE endpoint 10.10.132.10
- Final sync result: PASS, 46 regions / 586240 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS; final Nutanix n2k-* snapshot count is 0
- Target VM libvirt state: running
- Target VM boot observation: PASS; QGA `guest-ping` returned successfully

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- all expected source disks are present in manifest: yes
- all target paths are unique: yes
- all disks base-synced: yes
- all disks have target backend artifacts: yes
- libvirt XML disk count matches manifest: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode is bridge0: yes
- qcow2 libvirt XML matches backend: yes, three file/qcow2 disks
- source Nutanix n2k-* snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338/evidence/target.dumpxml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338/evidence
- boot evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338/evidence/phase1.guestfish-root.txt
- QGA evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q01-rhel-force-v3-split-qcow2-retest-20260517-155338/evidence/qga-ping.json

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- qcow2 image or LV removed/preserved: preserved for running target
- Workdir preserved: yes
- Runtime credential file removed: not applicable; credentials were passed only at runtime

Result:
- PASS

Fix and retest summary:
- Initial Q01 run failed after libvirt start because the guest entered dracut emergency mode and offline root LV mount failed.
- The engine now materializes Nutanix NFS patch sources through read-only qemu-nbd virtual offsets and writes qcow2 target regions through qemu-io, avoiding direct file-offset patching and target kernel-NBD writes.
- Retest final assertions: `source_api_family=v3`, `selected_mode=v3-incremental`,
  `source_api_policy=v3`, `mode_forced=true`, PE endpoint `10.10.132.10`,
  3 manifest disks, 3 unique qcow2 target paths, Phase1 root LV mount OK,
  QGA `guest-ping` OK, target `rhel` running, source `rhel` OFF, and
  Nutanix `n2k-*` snapshot count `0`.
```

### Q02 - qcow2 v3 force Phase1/Phase2 centos7-bios-ide

```text
Case: Q02
Backend: qcow2
Started at: 2026-05-17 16:03 KST
Completed at: 2026-05-17 16:09 KST
Operator: Codex
Host: 10.10.22.1
VM: centos7-bios-ide
Scenario: v3 force
Cutoff style: Phase1/Phase2
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132-storage/Q02-centos-force-v3-split-qcow2
Target root or LV path: /var/lib/libvirt/images/n2k/pc132-storage/Q02-centos-force-v3-split-qcow2
Target map JSON: not applicable for qcow2 file target

Pre-check:
- Source power state before run: ON
- Expected migration disk count: 1
- Actual migration disk count: 1
- Source disk IDs and sizes:
  ea40360c-6263-4bdb-9630-0925bfcc660e / 107374182400
- Source controller: IDE bus 0 unit 1
- Target domain conflict check: none on 10.10.22.1
- Existing target storage artifact check: none
- Target host bridge check: bridge0 UP
- Backend readiness: qemu-img, qemu-io, qemu-nbd, virsh present; /var/lib/libvirt/images available
- Preflight selected mode: v3-incremental
- Preflight source API policy: v3
- Preflight mode_forced: true
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Phase1 result: PASS
- Phase1 base sync: 1 disk, 107374182400 bytes
- Phase1 incremental sync: 2 regions / 1536 bytes
- Phase1 offline root mount check: PASS; `/dev/centos_centos7-bios-ide/root` mounted read-only with XFS `ro,norecovery`, and `/etc/fstab` plus GRUB root entries were readable
- Phase2 result: PASS
- Phase2 incremental sync before cutoff: 0 regions / 0 bytes
- Shutdown policy/result: guest, PASS through selected PE endpoint 10.10.132.10
- Final sync result: PASS, 35 regions / 412672 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS; final Nutanix n2k-* snapshot count is 0
- Target VM libvirt state: running
- Target VM boot observation: PASS; QGA `guest-ping` returned successfully
- Guest OS observation: CentOS Linux 7 (Core), kernel 3.10.0-1127.el7.x86_64

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- all expected source disks are present in manifest: yes
- all target paths are unique: yes
- all disks base-synced: yes
- all disks have target backend artifacts: yes
- libvirt XML disk count matches manifest: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode is bridge0: yes
- qcow2 libvirt XML matches backend: yes, one file/qcow2 disk
- source Nutanix n2k-* snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132-storage/Q02-centos-force-v3-split-qcow2/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132-storage/Q02-centos-force-v3-split-qcow2/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132-storage/Q02-centos-force-v3-split-qcow2/evidence/target.dumpxml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132-storage/Q02-centos-force-v3-split-qcow2/evidence
- boot evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q02-centos-force-v3-split-qcow2/evidence/phase1.qemu-nbd-lvm-ro-check.txt
- QGA evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q02-centos-force-v3-split-qcow2/evidence/qga-ping.json
- final verify summary: /var/lib/ablestack/n2k-e2e/pc132-storage/Q02-centos-force-v3-split-qcow2/evidence/final_verify.summary.json

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- qcow2 image or LV removed/preserved: preserved for running target
- Workdir preserved: yes
- Runtime credential file removed: not applicable; credentials were passed only at runtime

Result:
- PASS

Final assertions:
- `source_api_family=v3`, `selected_mode=v3-incremental`, `source_api_policy=v3`,
  `mode_forced=true`, PE endpoint `10.10.132.10`, 1 manifest disk, 1 unique
  qcow2 target path, Phase1 root LV mount OK, QGA `guest-ping` OK, target
  `centos7-bios-ide` running, source `centos7-bios-ide` OFF, and Nutanix
  `n2k-*` snapshot count `0`.
```

### Q03 - qcow2 v3 force Phase1/Phase2 win10

```text
Case: Q03
Backend: qcow2
Started at: 2026-05-17 16:14 KST
Completed at: 2026-05-17 16:26 KST
Operator: Codex
Host: 10.10.22.3
VM: win10
Scenario: v3 force
Cutoff style: Phase1/Phase2
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2
Target root or LV path: /var/lib/libvirt/images/n2k/pc132-storage/Q03-win10-force-v3-split-qcow2
Target map JSON: not applicable for qcow2 file target

Pre-check:
- Source power state before run: ON
- Expected migration disk count: 2
- Actual migration disk count: 2
- Source disk IDs and sizes:
  de061be4-fe34-412e-931b-b5163b03d81c / 107374182400
  ee1cbd9e-6692-4ec5-9131-d54bce8a4bf9 / 10737418240
- Source controller: SCSI unit 0 and SCSI unit 1
- Target domain conflict check: none on 10.10.22.3
- Existing target storage artifact check: none
- Target host bridge check: bridge0 UP
- Backend readiness: qemu-img, qemu-io, qemu-nbd, virsh present; /var/lib/libvirt/images available
- Preflight selected mode: v3-incremental
- Preflight source API policy: v3
- Preflight mode_forced: true
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Phase1 result: PASS
- Phase1 base sync: 2 disks, 107374182400 / 10737418240 bytes
- Phase1 incremental sync: 17 regions / 540672 bytes
- Phase1 disk sanity check: PASS; qemu-img check found no qcow2 errors, disk0 exposed GPT with EFI/MSR/NTFS partitions, and disk1 exposed GPT with MSR plus NTFS data partition
- Phase2 result: PASS
- Phase2 incremental sync before cutoff: 39 regions / 438272 bytes
- Shutdown policy/result: guest, PASS through selected PE endpoint 10.10.132.10; source VM reached OFF
- Final sync result: PASS, 131 regions / 2928640 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS; all recorded base/incr/final v3 recovery points were deleted and final Nutanix n2k-* snapshot count is 0
- Target VM libvirt state: running
- Target VM boot observation: PASS; QGA is not connected in this Windows guest, so boot was verified by HMP `screendump` showing the Windows 10 lock screen
- Target VM network observation: bridge0, virtio NIC, MAC 50:6b:8d:f6:87:16
- Target VM disk observation: two qcow2 file disks `sda` and `sdb`

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- all expected source disks are present in manifest: yes
- all target paths are unique: yes
- all disks base-synced: yes
- all disks have target backend artifacts: yes
- libvirt XML disk count matches manifest: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode is bridge0: yes
- qcow2 libvirt XML matches backend: yes, two file/qcow2 disks
- source Nutanix n2k-* snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/evidence/target.dumpxml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/evidence
- Phase1 disk sanity evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/evidence/phase1.qcow2-disk-sanity.txt
- target verification evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/evidence/q03-final-target-verify.txt
- non-QGA verification evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/evidence/q03-final-nonqga-verify.txt
- final verify summary: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/evidence/final_verify.summary.json
- console screendump: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/evidence/win10-hmp.ppm
- network clue evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q03-win10-force-v3-split-qcow2/evidence/q03-network-clues.txt

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- qcow2 image or LV removed/preserved: preserved for running target
- Workdir preserved: yes
- Runtime credential file removed: not applicable; credentials were passed only at runtime

Result:
- PASS

Follow-up issue:
- Q03 completed, but Phase2 source shutdown took longer than necessary because the shutdown inventory path attempted PE v4 before falling back to v3 even though this case was explicitly `--force-v3`.
- The local source tree now has a v3 shutdown-path guard that runs `n2k_source_vm_shutdown` with `N2K_NUTANIX_INVENTORY_SKIP_V4=1` when `source_api=v3`.
- Rebuild and deploy this RPM before the next case so future v3 force and PE-v3 fallback tests do not wait for the PE v4 timeout during shutdown polling.
```

### Q04 - qcow2 v3 force full rhel

```text
Case: Q04
Backend: qcow2
Started at: 2026-05-17 16:56 KST
Completed at: 2026-05-17 17:00 KST
Operator: Codex
Host: 10.10.22.3
VM: rhel
Scenario: v3 force
Cutoff style: full
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2
Target root or LV path: /var/lib/libvirt/images/n2k/pc132-storage/Q04-rhel-force-v3-full-qcow2
Target map JSON: not applicable for qcow2 file target

Pre-check:
- Previous Q01 target `rhel` domain on 10.10.22.2 was stopped/undefined before starting the source VM again.
- Source power state before run: ON
- Expected migration disk count: 3
- Actual migration disk count: 3
- Source disk IDs and sizes:
  ae29c318-5dca-44b3-93c6-f3f3714177ec / 107374182400
  afe42ac0-bb0a-4022-b9cf-3a5409eb21fb / 10737418240
  ee5d7f96-7d87-46e4-996c-efcc4d7d8dde / 10737418240
- Source controller: SCSI units 0, 1, and 2
- Target domain conflict check: none on 10.10.22.3
- Existing target storage artifact check: cleaned before run
- Existing Nutanix n2k-* snapshot count: 0
- Target host bridge check: bridge0 UP
- Backend readiness: ablestack_n2k 0.8.0-1.el9.el9, qemu-img, qemu-io, qemu-nbd, virsh present; /var/lib/libvirt/images available
- Preflight selected mode: v3-incremental
- Preflight source API policy: v3
- Preflight mode_forced: true
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Full run result: PASS
- Base sync: 3 disks, 107374182400 / 10737418240 / 10737418240 bytes
- First incremental sync before shutdown: 132 regions / 2646016 bytes
- Shutdown policy/result: guest, PASS through selected PE endpoint 10.10.132.10; source VM reached OFF
- Final sync result: PASS, 44 regions / 590336 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS; base, incr, and final v3 recovery points were deleted and final Nutanix n2k-* snapshot count is 0
- Target VM libvirt state: running
- Target VM boot observation: PASS; QGA `guest-ping` returned successfully
- Guest OS observation: Red Hat Enterprise Linux 8.8 (Ootpa), kernel 4.18.0-477.10.1.el8_8.x86_64
- Guest disk observation: `/dev/sda` OS disk plus `/dev/sdb` and `/dev/sdc` extra disks visible through QGA; the extra disks back `vg_data-lv_data` mounted on `/mnt`
- Target VM network observation: bridge0, virtio NIC, MAC 50:6b:8d:bb:91:08, guest IP 10.10.254.136/16

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- all expected source disks are present in manifest: yes
- all target paths are unique: yes
- all disks base-synced: yes
- all disks have target backend artifacts: yes
- libvirt XML disk count matches manifest: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode is bridge0: yes
- qcow2 libvirt XML matches backend: yes, three file/qcow2 disks
- source Nutanix n2k-* snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/evidence/target.dumpxml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/evidence
- full summary: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/evidence/full.summary.json
- target verification evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/evidence/final-target-verify.txt
- QGA evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/evidence/qga-ping.json
- QGA disk evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/evidence/qga-disks.json
- final verify summary: /var/lib/ablestack/n2k-e2e/pc132-storage/Q04-rhel-force-v3-full-qcow2/evidence/final_verify.summary.json

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- qcow2 image or LV removed/preserved: preserved for running target
- Workdir preserved: yes
- Runtime credential file removed: yes; temporary `/run/n2k-q04-full.*` credential file was removed by the runner trap

Result:
- PASS
```

### Q05 - qcow2 v3 force full centos7-bios-ide

```text
Case: Q05
Backend: qcow2
Started at: 2026-05-17 17:07 KST
Completed at: 2026-05-17 17:10 KST
Operator: Codex
Host: 10.10.22.2
VM: centos7-bios-ide
Scenario: v3 force
Cutoff style: full
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2
Target root or LV path: /var/lib/libvirt/images/n2k/pc132-storage/Q05-centos-force-v3-full-qcow2
Target map JSON: not applicable for qcow2 file target

Pre-check:
- Previous Q02 target `centos7-bios-ide` domain on 10.10.22.1 was stopped/undefined before starting the source VM again.
- Source power state before run: ON
- Expected migration disk count: 1
- Actual migration disk count: 1
- Source disk IDs and sizes:
  ea40360c-6263-4bdb-9630-0925bfcc660e / 107374182400
- Source controller: IDE bus 0 unit 1
- Target domain conflict check: none on 10.10.22.2
- Existing target storage artifact check: cleaned before run
- Existing Nutanix n2k-* snapshot count: 0
- Target host bridge check: bridge0 UP
- Backend readiness: ablestack_n2k 0.8.0-1.el9.el9, qemu-img, qemu-io, qemu-nbd, virsh present; /var/lib/libvirt/images available
- Preflight selected mode: v3-incremental
- Preflight source API policy: v3
- Preflight mode_forced: true
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Full run result: PASS
- Base sync: 1 disk, 107374182400 bytes
- First incremental sync before shutdown: 56 regions / 3103232 bytes
- Shutdown policy/result: guest, PASS through selected PE endpoint 10.10.132.10; source VM reached OFF
- Final sync result: PASS, 38 regions / 438784 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS; base, incr, and final v3 recovery points were deleted and final Nutanix n2k-* snapshot count is 0
- Target VM libvirt state: running
- Target VM boot observation: PASS; QGA `guest-ping` returned successfully
- Guest OS observation: CentOS Linux 7 (Core), kernel 3.10.0-1127.el7.x86_64
- Guest disk observation: libvirt shows one qcow2 file disk; QGA fsinfo shows `/boot` and `/` from the migrated disk
- Target VM network observation: bridge0, virtio NIC, MAC 50:6b:8d:9d:b1:cf, guest IP 10.10.254.137/16
- Compatibility note: this older QGA does not support `guest-get-disks`; disk validation used libvirt block list, QGA fsinfo, and qemu-img check

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- all expected source disks are present in manifest: yes
- all target paths are unique: yes
- all disks base-synced: yes
- all disks have target backend artifacts: yes
- libvirt XML disk count matches manifest: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode is bridge0: yes
- qcow2 libvirt XML matches backend: yes, one file/qcow2 disk
- source Nutanix n2k-* snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/evidence/target.dumpxml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/evidence
- full summary: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/evidence/full.summary.json
- target verification evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/evidence/final-target-verify.txt
- QGA evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/evidence/qga-ping.json
- QGA fs evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/evidence/qga-fsinfo.json
- final verify summary: /var/lib/ablestack/n2k-e2e/pc132-storage/Q05-centos-force-v3-full-qcow2/evidence/final_verify.summary.json

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- qcow2 image or LV removed/preserved: preserved for running target
- Workdir preserved: yes
- Runtime credential file removed: yes; temporary `/run/n2k-q05-full.*` credential file was removed by the runner trap

Result:
- PASS
```

### Q06 - qcow2 v3 force full win10

```text
Case: Q06
Backend: qcow2
Started at: 2026-05-17 17:17 KST
Completed at: 2026-05-17 17:21 KST
Operator: Codex
Host: 10.10.22.1
VM: win10
Scenario: v3 force
Cutoff style: full
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2
Target root or LV path: /var/lib/libvirt/images/n2k/pc132-storage/Q06-win10-force-v3-full-qcow2
Target map JSON: not applicable for qcow2 file target

Pre-check:
- Previous Q03 target `win10` domain on 10.10.22.3 was stopped/undefined before starting the source VM again.
- Source power state before run: ON
- Expected migration disk count: 2
- Actual migration disk count: 2
- Source disk IDs and sizes:
  de061be4-fe34-412e-931b-b5163b03d81c / 107374182400
  ee1cbd9e-6692-4ec5-9131-d54bce8a4bf9 / 10737418240
- Source controller: SCSI units 0 and 1
- Target domain conflict check: none on 10.10.22.1
- Existing target storage artifact check: cleaned before run
- Existing Nutanix n2k-* snapshot count: 0
- Target host bridge check: bridge0 UP
- Backend readiness: ablestack_n2k 0.8.0-1.el9.el9, qemu-img, qemu-io, qemu-nbd, virsh present; /var/lib/libvirt/images available
- Preflight selected mode: v3-incremental
- Preflight source API policy: v3
- Preflight mode_forced: true
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Full run result: PASS
- Base sync: 2 disks, 107374182400 / 10737418240 bytes
- First incremental sync before shutdown: 2128 regions / 1126754816 bytes
- Shutdown policy/result: guest, PASS through selected PE endpoint 10.10.132.10; source VM reached OFF
- Final sync result: PASS, 1818 regions / 38823424 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS; base, incr, and final v3 recovery points were deleted and final Nutanix n2k-* snapshot count is 0
- Target VM libvirt state: running
- Target VM boot observation: PASS; QGA is not connected in this Windows guest, so boot was verified by HMP `screendump` showing the Windows 10 lock screen
- Target VM network observation: bridge0, virtio NIC, MAC 50:6b:8d:f6:87:16
- Target VM disk observation: two qcow2 file disks `sda` and `sdb`

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- all expected source disks are present in manifest: yes
- all target paths are unique: yes
- all disks base-synced: yes
- all disks have target backend artifacts: yes
- libvirt XML disk count matches manifest: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode is bridge0: yes
- qcow2 libvirt XML matches backend: yes, two file/qcow2 disks
- source Nutanix n2k-* snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/evidence/target.dumpxml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/evidence
- full summary: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/evidence/full.summary.json
- target verification evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/evidence/final-target-verify.txt
- non-QGA boot evidence: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/evidence/nonqga-boot-verify.txt
- console screendump: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/evidence/win10-hmp.ppm
- final verify summary: /var/lib/ablestack/n2k-e2e/pc132-storage/Q06-win10-force-v3-full-qcow2/evidence/final_verify.summary.json

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- qcow2 image or LV removed/preserved: preserved for running target
- Workdir preserved: yes
- Runtime credential file removed: yes; temporary `/run/n2k-q06-full.*` credential file was removed by the runner trap

Result:
- PASS
```

### Q07 - qcow2 auto fallback Phase1/Phase2 centos7-bios-ide

```text
Case: Q07
Backend: qcow2
Started at: 2026-05-17 17:56 KST
Completed at: 2026-05-17 18:00 KST
Operator: Codex
Host: 10.10.22.1
VM: centos7-bios-ide
Scenario: PC v4 / PE v3 auto fallback
Cutoff style: Phase1/Phase2
Command mode args: --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132-storage/Q07-centos-auto-fallback-split-qcow2
Target root or LV path: /var/lib/libvirt/images/n2k/pc132-storage/Q07-centos-auto-fallback-split-qcow2
Target map JSON: not applicable for qcow2 file target

Result summary:
- PASS
- selected_mode: v3-incremental
- source_api_policy: auto
- mode_forced: false
- selected PE endpoint: 10.10.132.10
- expected/actual disk count: 1 / 1
- Phase1 incremental: 50 regions / 864768 bytes
- Phase2 pre-cutoff incremental: 0 regions / 0 bytes
- Final sync: 45 regions / 583680 bytes
- Target state: running
- Target backend: one file/qcow2 disk on bridge0
- Source state after cutoff: OFF
- Nutanix n2k-* snapshot count after cleanup: 0

Notes:
- The first Q07 attempt failed before a successful cutoff because the test
  wrapper used umask 077, which left qcow2 artifacts unreadable by qemu.
- Failed Q07 artifacts and Nutanix snapshots were cleaned before the retry.
- The successful retry's wrapper exited nonzero only because a validation jq
  expression used stale manifest paths. Supplemental verification of manifest,
  libvirt state, source power state, and snapshot cleanup passed.
```

### B01 - LVM block v3 force Phase1/Phase2 rhel

```text
Case: B01
Backend: LVM block
Started at: 2026-05-17 18:05 KST
Completed at: 2026-05-17 18:16 KST
Operator: Codex
Host: 10.10.22.1
VM: rhel
Scenario: v3 force
Cutoff style: Phase1/Phase2
Command mode args: --force-v3 --target-storage block --target-format raw --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132-storage/B01-rhel-force-v3-split-block
Target root or LV path: /dev/n2k_block_e2e
Target map JSON: /var/lib/ablestack/n2k-e2e/pc132-storage/B01-rhel-force-v3-split-block/evidence/target-map.json

Result summary:
- PASS
- selected_mode: v3-incremental
- source_api_policy: v3
- mode_forced: true
- selected PE endpoint: 10.10.132.10
- expected/actual disk count: 3 / 3
- Target LVs:
  /dev/n2k_block_e2e/b01_rhel_force_v3_split_disk0 / 107374182400 bytes
  /dev/n2k_block_e2e/b01_rhel_force_v3_split_disk1 / 10737418240 bytes
  /dev/n2k_block_e2e/b01_rhel_force_v3_split_disk2 / 10737418240 bytes
- Phase1 incremental: 12 regions / 151552 bytes
- Phase2 pre-cutoff incremental: 0 regions / 0 bytes
- Final sync: 43 regions / 532992 bytes
- Target state: running
- Target backend: three block/raw disks on bridge0
- Guest verification: QGA guest-ping passed; OS info reports RHEL 8.8
- Extra disk verification: QGA fsinfo shows the two additional disks backing /mnt
- Source state after cutoff: OFF
- Nutanix n2k-* snapshot count after cleanup: 0
```

### B02 - LVM block auto fallback full win10

```text
Case: B02
Backend: LVM block
Started at: 2026-05-17 18:18 KST
Completed at: 2026-05-17 18:32 KST
Operator: Codex
Host: 10.10.22.1
VM: win10
Scenario: PC v4 / PE v3 auto fallback
Cutoff style: full
Command mode args: --target-storage block --target-format raw --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132-storage/B02-win10-auto-fallback-full-block
Target root or LV path: /dev/n2k_block_e2e
Target map JSON: /var/lib/ablestack/n2k-e2e/pc132-storage/B02-win10-auto-fallback-full-block/evidence/target-map.json

Result summary:
- PASS
- selected_mode: v3-incremental
- source_api_policy: auto
- mode_forced: false
- selected PE endpoint: 10.10.132.10
- expected/actual disk count: 2 / 2
- Target LVs:
  /dev/n2k_block_e2e/b02_win10_auto_fallback_full_disk0 / 107374182400 bytes
  /dev/n2k_block_e2e/b02_win10_auto_fallback_full_disk1 / 10737418240 bytes
- First incremental pass: 928 regions / 36303872 bytes
- Final sync: 1497 regions / 17106432 bytes
- Target state: running
- Target backend: two block/raw disks on bridge0
- Guest verification: QGA not connected; HMP screendump shows Windows 10 lock screen
- Source state after cutoff: OFF
- Nutanix n2k-* snapshot count after cleanup: 0

Notes:
- The wrapper's original HMP output path under the evidence directory was not
  writable by the qemu process, so supplemental verification wrote the console
  screenshot to /tmp/win10-b02.ppm and copied it back to evidence as
  win10-hmp.ppm.
- This was a test harness permission issue after the engine had already
  completed cutoff/start and snapshot cleanup.
```

## Per-case result template

```text
Case:
Backend:
Started at:
Completed at:
Operator:
Host:
VM:
Scenario:
Cutoff style:
Command mode args:
Workdir:
Target root or LV path:
Target map JSON:

Pre-check:
- Source power state before run:
- Expected migration disk count:
- Actual migration disk count:
- Source disk IDs and sizes:
- Target domain conflict check:
- Existing target storage artifact check:
- Existing Nutanix n2k-* snapshot count:
- Target host bridge check:
- Backend readiness:
- Preflight selected mode:
- Preflight source API policy:
- Preflight mode_forced:
- Preflight v3 source endpoint:

Execution:
- Phase1 result:
- Phase2/full result:
- Shutdown policy/result:
- Final sync result:
- Cutover apply/start result:
- Source snapshot cleanup result:
- Target VM libvirt state:
- Target VM boot observation:

Expected assertions:
- selected_mode is v3-incremental:
- source endpoint is 10.10.132.10:
- force-v3 metadata correct when applicable:
- auto fallback metadata correct when applicable:
- all expected source disks are present in manifest:
- all target paths are unique:
- all disks base-synced:
- all disks have target backend artifacts:
- libvirt XML disk count matches manifest:
- final sync completed:
- cutover phase completed:
- target started:
- target network mode is bridge0:
- qcow2 or block libvirt XML matches backend:
- source Nutanix n2k-* snapshot count is 0:

Artifacts:
- manifest.json:
- events.log:
- libvirt XML:
- command stdout/stderr:
- final verify summary:

Cleanup:
- Target VM stopped/undefined:
- Source VM powered back on:
- qcow2 image or LV removed/preserved:
- Workdir preserved:
- Runtime credential file removed:

Result:
- PASS / FAIL / BLOCKED
- Failure summary:
- Follow-up issue or patch:
```

## Completion criteria

The qcow2/LVM backend validation is complete only when:

- Q01 through Q06 remain PASS as the completed qcow2 v3-force baseline.
- Q07 has final evidence and result for qcow2 PC v4 / PE v3 auto fallback.
- B01 and B02 have final evidence and result for LVM block.
- The remaining abbreviated cases cover `rhel`, `centos7-bios-ide`, and
  `win10` exactly once each.
- Q08 through Q12 and B03 through B12 are no longer required unless a failure
  uncovers a new untested risk.
- Every successful case selects `v3-incremental`.
- Every successful case records PE endpoint `10.10.132.10`.
- Every successful force-v3 case records `mode_forced=true`.
- Every successful auto fallback case records `mode_forced=false`.
- Every successful cutoff starts the target VM.
- Every successful cutoff removes Nutanix `n2k-*` source snapshots.
- Every `rhel` case proves 3 migrated disks end to end.
- Every `win10` case proves 2 migrated disks end to end.
- Every `centos7-bios-ide` case proves 1 migrated disk end to end.
- qcow2 cases prove file/qcow2 XML and qemu-img metadata.
- LVM block cases prove block/raw XML and LV size compatibility.
