# ablestack_n2k PC132 v3 force and fallback E2E test plan

## Purpose

This document defines the cutoff E2E test plan for the current PC132
environment where Prism Central supports v4 APIs, but the hosting PE is expected
to use the proven v2/v3 execution path.

The test has two goals:

1. Verify that an operator can force the v3 incremental path regardless of PC
   v4 capability.
2. Verify that `auto` mode detects PC v4 / PE non-v4 behavior and falls back to
   the PE v3 incremental path.

This document is also the test result ledger. Each case must be updated after it
is executed.

## Environment

Source Nutanix environment:

- Prism Central: `https://10.10.132.100:9440`
- Discovered PE v3 source endpoint: `10.10.132.10`
- Prism user: `admin`
- Prism password: do not store in this repository or this document.

Target ABLESTACK hosts:

- `10.10.22.1`
- `10.10.22.2`
- `10.10.22.3`
- SSH port: `10022`
- SSH user: `root`
- SSH password: do not store in this repository or this document.

Installed package baseline:

- RPM: `ablestack_n2k-0.8.0-1.el9.el9.noarch`
- Source commit in rebuilt RPM: `17070de`
- Build date: `2026-05-17 13:51:47 KST`
- RPM SHA256:
  `c9160bd2af8834855cd5bc4bfb30e60fc03d9431fdc4219de7e4e7361817a61c`

Target storage for this plan:

- Storage backend: RBD
- RBD pool: `rbd`
- Libvirt RBD access mode: `librbd`
- Host Ceph secret is expected to exist, for example
  `ceph client.admin secret`.

## Test scope

Only the following source VMs are in scope:

| VM | Guest type | Status |
| --- | --- | --- |
| `rhel` | Linux UEFI guest | Included |
| `centos7-bios-ide` | Linux BIOS/IDE guest | Included |
| `win10` | Windows guest | Included |

The following source VM is explicitly excluded:

| VM | Reason |
| --- | --- |
| `windows11` | Not in a normal running state in the current PC132 testbed |

`PC-NameOption-1` is also excluded because it appears to be infrastructure-like
and is not a migration workload for this E2E pass.

## Pre-run readiness result

Readiness checks were executed on 2026-05-16 before this plan was written.

Summary:

- All three ABLESTACK hosts have the rebuilt RPM installed.
- All three ABLESTACK hosts expose `--force-v3` and `--source-api v3`.
- All three ABLESTACK hosts passed synthetic force-v3 preflight smoke:
  - `recommended_mode=v4-incremental`
  - `selected_mode=v3-incremental`
  - `source_api_policy=v3`
  - `mode_forced=true`
  - `can_run=true`
- Against PC132, all three ABLESTACK hosts passed live readiness:
  - forced v3 preflight selected `v3-incremental`
  - auto plan selected `v3-incremental`
  - v3 source endpoint was `10.10.132.10`
  - target storage selected `rbd`
- Prepared host workdir root:
  `/var/lib/ablestack/n2k-e2e/pc132`

Known pre-run notes:

- `10.10.22.1` already has a libvirt domain named `rhel`; this plan avoids
  assigning `rhel` to `10.10.22.1`.
- Every case uses a unique workdir and RBD image prefix.
- Target libvirt domain names are generated from source VM names, so target VM
  cleanup is mandatory after each case before the same VM is tested again on the
  same host.

## Global execution policy

Run one case at a time.

Before each case:

1. Confirm the source VM is `ON` in PC132/PE inventory.
2. Confirm the source VM is not `windows11`.
3. Confirm there is no target libvirt domain conflict on the assigned host.
4. Confirm there is no RBD image with the case prefix.
5. Export credentials at runtime only.

During cutoff:

- Use `--shutdown guest`.
- Allow the implementation to fall back to `poweroff` if guest shutdown fails or
  times out.
- Use `--apply --start` so cutoff defines and starts the target VM.

After each case:

1. Record `manifest.json`, `events.log`, target XML path, and command outputs.
2. Confirm target VM reaches a libvirt running state or record the failure.
3. Stop and undefine the target VM before powering the source VM back on.
4. Power the source VM back on from Nutanix when it will be reused.
5. Keep the workdir as evidence unless explicitly cleaning a failed retry.
6. Remove or keep RBD images according to the result disposition recorded for
   the case.

Do not power the source VM back on while the migrated target VM is still running
on the same network.

## Runtime variables

Set these on the operator workstation or directly on the target host shell.

```bash
export PC_URL='https://10.10.132.100:9440'
export PC_USER='admin'
export PC_PASS='<runtime-only>'
export N2K_INSECURE='1'
export N2K_BASE_WORKDIR='/var/lib/ablestack/n2k-e2e/pc132'
export N2K_RBD_POOL='rbd'
```

SSH execution from the operator workstation should use:

```bash
ssh -p 10022 root@<target-host>
```

When automating SSH, pass the SSH password at runtime only. Do not write it into
scripts committed to the repository.

## Command templates

### Phase1 command

```bash
ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "rbd:${N2K_RBD_POOL}/${RBD_PREFIX}" \
  --target-storage rbd \
  --target-format raw \
  --rbd-access-mode librbd \
  --split phase1 \
  ${MODE_ARGS}
```

### Phase2 cutoff command

```bash
ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "rbd:${N2K_RBD_POOL}/${RBD_PREFIX}" \
  --target-storage rbd \
  --target-format raw \
  --rbd-access-mode librbd \
  --split phase2 \
  --shutdown guest \
  --shutdown-timeout-sec 300 \
  --shutdown-poll-sec 5 \
  --apply \
  --start \
  ${MODE_ARGS}
```

### Full cutoff command

```bash
ablestack_n2k --json \
  --workdir "${WORKDIR}" \
  run \
  --pc "${PC_URL}" \
  --vm "${VM}" \
  --username "${PC_USER}" \
  --password "${PC_PASS}" \
  --insecure "${N2K_INSECURE}" \
  --dst "rbd:${N2K_RBD_POOL}/${RBD_PREFIX}" \
  --target-storage rbd \
  --target-format raw \
  --rbd-access-mode librbd \
  --split full \
  --shutdown guest \
  --shutdown-timeout-sec 300 \
  --shutdown-poll-sec 5 \
  --apply \
  --start \
  ${MODE_ARGS}
```

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

## Cleanup commands

Run after evidence collection for each case.

```bash
virsh destroy "${VM}" 2>/dev/null || true
virsh undefine "${VM}" --nvram 2>/dev/null || virsh undefine "${VM}" 2>/dev/null || true
rbd ls "${N2K_RBD_POOL}" | grep "^${RBD_PREFIX}-disk" || true
```

If a retry must reuse the same RBD prefix and the previous run is no longer
needed:

```bash
for image in $(rbd ls "${N2K_RBD_POOL}" | grep "^${RBD_PREFIX}-disk"); do
  rbd rm "${N2K_RBD_POOL}/${image}"
done
```

Power the source VM back on only after the target VM is stopped/undefined.

## Test matrix

The complete matrix is 12 cutoff E2E runs:

| Case | Scenario | Cutoff style | VM | Host | Workdir suffix | RBD prefix | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `T01` | v3 force | Phase1/Phase2 | `rhel` | `10.10.22.2` | `T01-rhel-force-v3-split` | `n2k-pc132-t01-rhel-force-v3-split` | PASS |
| `T02` | v3 force | Phase1/Phase2 | `centos7-bios-ide` | `10.10.22.1` | `T02-centos-force-v3-split` | `n2k-pc132-t02-centos-force-v3-split` | PASS |
| `T03` | v3 force | Phase1/Phase2 | `win10` | `10.10.22.3` | `T03-win10-force-v3-split` | `n2k-pc132-t03-win10-force-v3-split` | PASS |
| `T04` | v3 force | full | `rhel` | `10.10.22.3` | `T04-rhel-force-v3-full` | `n2k-pc132-t04-rhel-force-v3-full` | PASS |
| `T05` | v3 force | full | `centos7-bios-ide` | `10.10.22.2` | `T05-centos-force-v3-full` | `n2k-pc132-t05-centos-force-v3-full` | PASS |
| `T06` | v3 force | full | `win10` | `10.10.22.1` | `T06-win10-force-v3-full` | `n2k-pc132-t06-win10-force-v3-full` | PASS |
| `T07` | PC v4 / PE v3 auto fallback | Phase1/Phase2 | `rhel` | `10.10.22.2` | `T07-rhel-auto-fallback-split` | `n2k-pc132-t07-rhel-auto-fallback-split` | PASS |
| `T08` | PC v4 / PE v3 auto fallback | Phase1/Phase2 | `centos7-bios-ide` | `10.10.22.1` | `T08-centos-auto-fallback-split` | `n2k-pc132-t08-centos-auto-fallback-split` | PASS |
| `T09` | PC v4 / PE v3 auto fallback | Phase1/Phase2 | `win10` | `10.10.22.3` | `T09-win10-auto-fallback-split` | `n2k-pc132-t09-win10-auto-fallback-split` | PASS |
| `T10` | PC v4 / PE v3 auto fallback | full | `rhel` | `10.10.22.3` | `T10-rhel-auto-fallback-full` | `n2k-pc132-t10-rhel-auto-fallback-full` | PASS |
| `T11` | PC v4 / PE v3 auto fallback | full | `centos7-bios-ide` | `10.10.22.2` | `T11-centos-auto-fallback-full` | `n2k-pc132-t11-centos-auto-fallback-full` | PASS |
| `T12` | PC v4 / PE v3 auto fallback | full | `win10` | `10.10.22.1` | `T12-win10-auto-fallback-full` | `n2k-pc132-t12-win10-auto-fallback-full` | PASS |

## Per-case result template

Copy this block for each test case when recording the result.

```text
Case:
Started at:
Completed at:
Operator:
Host:
VM:
Scenario:
Cutoff style:
Command mode args:
Workdir:
RBD prefix:

Pre-check:
- Source power state before run:
- Target domain conflict check:
- Existing RBD prefix check:
- Preflight selected mode:
- Preflight v3 source endpoint:

Execution:
- Phase1 result:
- Phase2/full result:
- Shutdown policy/result:
- Cutover apply/start result:
- Target VM libvirt state:
- Target VM boot observation:

Expected assertions:
- selected_mode is v3-incremental:
- source endpoint is 10.10.132.10:
- force-v3 metadata correct when applicable:
- auto fallback metadata correct when applicable:
- final sync completed:
- cutover phase completed:
- target started:

Artifacts:
- manifest.json:
- events.log:
- libvirt XML:
- command stdout/stderr:
- screenshots or operator observations:

Cleanup:
- Target VM stopped/undefined:
- Source VM powered back on:
- RBD images removed or preserved:
- Workdir preserved:

Result:
- PASS / FAIL / BLOCKED
- Failure summary:
- Follow-up issue or patch:
```

## Result ledger

| Case | Result | Started | Completed | Evidence path | Notes |
| --- | --- | --- | --- | --- | --- |
| `T01` | PASS | 2026-05-16 22:14 KST | 2026-05-16 23:01 KST | `/var/lib/ablestack/n2k-e2e/pc132/T01-rhel-force-v3-split/evidence` | Phase1 passed. Initial Phase2 exposed the PC-to-PE power endpoint issue, which was fixed by routing cutoff shutdown through selected PE `10.10.132.10`. A second retry exposed the target network assumption; the libvirt XML network path now supports `bridge` and `network` modes and T01 was rerun with `--network-mode bridge --bridge bridge0`. Final state: source `rhel` OFF, target `rhel` running on `10.10.22.2`, final sync `107` regions / `1929728` bytes. |
| `T02` | PASS | 2026-05-16 23:04 KST | 2026-05-16 23:08 KST | `/var/lib/ablestack/n2k-e2e/pc132/T02-centos-force-v3-split/evidence` | v3 force Phase1/Phase2 completed with selected PE endpoint `10.10.132.10`, guest shutdown OK, final sync `77` regions / `1471488` bytes, target `centos7-bios-ide` running on `10.10.22.1` with bridge `bridge0`, source VM OFF. |
| `T03` | PASS | 2026-05-16 23:12 KST | 2026-05-16 23:25 KST | `/var/lib/ablestack/n2k-e2e/pc132/T03-win10-force-v3-split/evidence` | v3 force Phase1/Phase2 completed with selected PE endpoint `10.10.132.10`, guest shutdown OK, final sync `141` regions / `2289664` bytes, target `win10` running on `10.10.22.3` with bridge `bridge0`, source VM OFF. |
| `T04` | PASS | 2026-05-17 00:07 KST | 2026-05-17 00:11 KST | `/var/lib/ablestack/n2k-e2e/pc132/T04-rhel-force-v3-full/evidence` | v3 force full run completed with selected PE endpoint `10.10.132.10`, guest shutdown OK, final sync `0` regions / `0` bytes, target `rhel` running on `10.10.22.3` with bridge `bridge0`, source VM OFF. Source snapshot cleanup deleted base/incr/final and final Nutanix `n2k-*` snapshot count is `0`. |
| `T05` | PASS | 2026-05-17 00:20 KST | 2026-05-17 00:23 KST | `/var/lib/ablestack/n2k-e2e/pc132/T05-centos-force-v3-full/evidence` | v3 force full run completed with selected PE endpoint `10.10.132.10`, guest shutdown OK, final sync `36` regions / `410624` bytes, target `centos7-bios-ide` running on `10.10.22.2` with bridge `bridge0`, source VM OFF. Source snapshot cleanup deleted base/incr/final and final Nutanix `n2k-*` snapshot count is `0`. |
| `T06` | PASS | 2026-05-17 00:30 KST | 2026-05-17 00:44 KST | `/var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full/evidence` | v3 force full run completed with selected PE endpoint `10.10.132.10`, guest shutdown OK, final sync `118` regions / `1335296` bytes, target `win10` running on `10.10.22.1` with bridge `bridge0`, source VM OFF. Initial `--start` failed because the test wrapper left `/var/lib/ablestack/n2k-e2e` and `pc132` as `700`, blocking qemu access to the UEFI VARS file; parent directory permissions were normalized and the same manifest reran cutover/start successfully. Source snapshot cleanup deleted base/incr/final and final Nutanix `n2k-*` snapshot count is `0`. |
| `T07` | PASS | 2026-05-17 01:02 KST | 2026-05-17 01:07 KST | `/var/lib/ablestack/n2k-e2e/pc132/T07-rhel-auto-fallback-split/evidence` | PC v4 / PE v3 auto fallback Phase1/Phase2 completed. Phase1 plan used `requested_mode=auto`, `source_api_policy=auto`, `mode_forced=false`, `v4_incremental_available=false`, `selected_mode=v3-incremental`, and v3 source endpoint `10.10.132.10`. Phase2 guest shutdown and cutoff used endpoint `10.10.132.10`; final sync `0` regions / `0` bytes; target `rhel` running on `10.10.22.2` with bridge `bridge0`; source VM OFF. Source snapshot cleanup deleted 4 v3 VM snapshots and final Nutanix `n2k-*` snapshot count is `0`. |
| `T08` | PASS | 2026-05-17 01:13 KST | 2026-05-17 01:17 KST | `/var/lib/ablestack/n2k-e2e/pc132/T08-centos-auto-fallback-split/evidence` | PC v4 / PE v3 auto fallback Phase1/Phase2 completed. Phase1 plan used `requested_mode=auto`, `source_api_policy=auto`, `mode_forced=false`, `v4_incremental_available=false`, `selected_mode=v3-incremental`, and v3 source endpoint `10.10.132.10`. Phase2 guest shutdown and cutoff used endpoint `10.10.132.10`; final sync `33` regions / `410112` bytes; target `centos7-bios-ide` running on `10.10.22.1` with bridge `bridge0`; source VM OFF. Source snapshot cleanup deleted 4 v3 VM snapshots and final Nutanix `n2k-*` snapshot count is `0`. |
| `T09` | PASS | 2026-05-17 01:23 KST | 2026-05-17 01:35 KST | `/var/lib/ablestack/n2k-e2e/pc132/T09-win10-auto-fallback-split/evidence` | PC v4 / PE v3 auto fallback Phase1/Phase2 completed. Phase1 plan used `requested_mode=auto`, `source_api_policy=auto`, `mode_forced=false`, `v4_incremental_available=false`, `selected_mode=v3-incremental`, and v3 source endpoint `10.10.132.10`. Phase2 guest shutdown and cutoff used endpoint `10.10.132.10`; final sync `145` regions / `1831424` bytes; target `win10` running on `10.10.22.3` with bridge `bridge0` and secure UEFI NVRAM; source VM OFF. Source snapshot cleanup deleted 4 v3 VM snapshots and final Nutanix `n2k-*` snapshot count is `0`. |
| `T10` | PASS | 2026-05-17 13:08 KST | 2026-05-17 13:12 KST | `/var/lib/ablestack/n2k-e2e/pc132/T10-rhel-auto-fallback-full/evidence` | PC v4 / PE v3 auto fallback full run completed. Plan used `requested_mode=auto`, `source_api_policy=auto`, `mode_forced=false`, `v4_incremental_available=false`, `selected_mode=v3-incremental`, and v3 source endpoint `10.10.132.10`. Guest shutdown and cutoff used endpoint `10.10.132.10`; base sync `107374182400` bytes; incremental sync before cutoff `0` regions / `0` bytes; final sync `0` regions / `0` bytes; target `rhel` running on `10.10.22.3` with bridge `bridge0` and secure UEFI NVRAM; source VM OFF. Source snapshot cleanup deleted 3 v3 VM snapshots and final Nutanix `n2k-*` snapshot count is `0`. |
| `T11` | PASS | 2026-05-17 13:25 KST | 2026-05-17 13:29 KST | `/var/lib/ablestack/n2k-e2e/pc132/T11-centos-auto-fallback-full/evidence` | PC v4 / PE v3 auto fallback full run completed. Plan used `requested_mode=auto`, `source_api_policy=auto`, `mode_forced=false`, `v4_incremental_available=false`, `selected_mode=v3-incremental`, and v3 source endpoint `10.10.132.10`. Guest shutdown and cutoff used endpoint `10.10.132.10`; base sync `107374182400` bytes; incremental sync before cutoff `0` regions / `0` bytes; final sync `34` regions / `414208` bytes; target `centos7-bios-ide` running on `10.10.22.2` with bridge `bridge0`, legacy BIOS XML, and target disk bus `sata`; source VM OFF. Source snapshot cleanup deleted 3 v3 VM snapshots and final Nutanix `n2k-*` snapshot count is `0`. |
| `T12` | PASS | 2026-05-17 14:01 KST | 2026-05-17 14:11 KST | `/var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full/evidence` | PC v4 / PE v3 auto fallback full run completed after fixing the large changed-region JSON handling and rerunning cleanly. Plan used `requested_mode=auto`, `source_api_policy=auto`, `mode_forced=false`, `v4_incremental_available=false`, `selected_mode=v3-incremental`, and v3 source endpoint `10.10.132.10`. Guest shutdown and cutoff used endpoint `10.10.132.10`; base sync `107374182400` bytes; incremental sync before cutoff `116` regions / `1953792` bytes; final sync `54` regions / `1216512` bytes; target `win10` running on `10.10.22.1` with bridge `bridge0`, secure UEFI NVRAM, and target disk bus `scsi`; source VM OFF. Source snapshot cleanup deleted 3 v3 VM snapshots and final Nutanix `n2k-*` snapshot count is `0`. Failed pre-fix workdir preserved at `/var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full.failed-arglimit-20260517-133919`. |

## Recorded case results

### T01 - v3 force Phase1/Phase2 rhel

```text
Case: T01
Started at: 2026-05-16 22:14 KST
Completed at: 2026-05-16 23:01 KST
Operator: Codex
Host: 10.10.22.2
VM: rhel
Scenario: v3 force
Cutoff style: Phase1/Phase2
Command mode args: --force-v3
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T01-rhel-force-v3-split
RBD prefix: n2k-pc132-t01-rhel-force-v3-split

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Preflight selected mode: v3-incremental
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Phase1 result: PASS
- Phase1 base sync: 107374182400 bytes
- Phase1 incremental sync: 3 changed regions, 24576 bytes
- Phase2 incremental result before cutoff: PASS
- Phase2 incremental sync before cutoff: 5 changed regions, 36864 bytes
- Initial shutdown policy/result: guest, FAIL until selected PE endpoint fix
- Retry shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 107 changed regions, 1929728 bytes
- Cutover apply/start result: PASS with --network-mode bridge --bridge bridge0
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes for v3 snapshot/changed-region path
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- final sync completed: yes
- cutover phase completed: yes
- target started: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T01-rhel-force-v3-split/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T01-rhel-force-v3-split/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T01-rhel-force-v3-split/artifacts/rhel.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T01-rhel-force-v3-split/evidence
- screenshots or operator observations: none

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS after engine and target network option follow-up
- Failure summary: Phase2 stopped before final snapshot because source VM
  shutdown used the original PC endpoint. In this environment PC supports v4
  APIs but does not service the required v2 power route for the hosted VM:
  `https://10.10.132.100:9440` v2 VM GET returned HTTP 412. The selected PE
  endpoint `10.10.132.10` returned HTTP 200 for the same v2 VM GET.
- Follow-up issue or patch: Engine change required. The final cutoff shutdown
  and poweroff fallback path must use the selected v3 source endpoint, or an
  equivalent recorded source endpoint, instead of always using the original PC
  endpoint. Testing is paused for approval before making this procedural engine
  change.
- Follow-up implementation: approved and implemented after this BLOCKED result.
  The `run` cutoff shutdown path now uses the selected v3 source endpoint for
  guest shutdown, poweroff fallback, and empty shutdown payload reconstruction.
- Build/deploy follow-up: rebuilt
  `ablestack_n2k-0.8.0-1.el9.el9.noarch.rpm` with SHA256
  `9dea359d800d4cdc7a78fd76d689f288735572c5e56f10fbd3ab80cda36ac6a5`
  and installed it on `10.10.22.1`, `10.10.22.2`, and `10.10.22.3`.
  Post-install force-v3 preflight for `rhel` selected
  `selected_mode=v3-incremental`, `source_endpoint=10.10.132.10`, and
  `can_run=true` on all three hosts.
- Network follow-up: the first post-fix retry reached target define/start but
  failed because the generated libvirt XML used the inactive NAT network
  `default`. The target XML path was updated to support selectable
  `--network-mode bridge|network`; the default and the T01 retry use
  `--network-mode bridge --bridge bridge0`. The RPM rebuilt for this update has
  SHA256 `144a7d32872ca91261f935469857c62500ae1ccf0d8f5ace4d979f1a98605db3`
  and was installed on `10.10.22.1`, `10.10.22.2`, and `10.10.22.3`.
- Final retry: `phase2_retry3` completed at `2026-05-16 23:00:42 KST` with
  exit code `0`. Manifest assertions: `final_sync=true`, `cutover=true`,
  `runtime.split.phase2.done=true`, `runtime.source_shutdown.ok=true`,
  shutdown source endpoint `10.10.132.10`, final sync `107` regions /
  `1929728` bytes. Target libvirt state is `running`; target XML uses
  `<interface type='bridge'>` and `<source bridge='bridge0'/>`. Source VM power
  state is `OFF`.
```

### T04 - v3 force full rhel

```text
Case: T04
Started at: 2026-05-17 00:07 KST
Completed at: 2026-05-17 00:11 KST
Operator: Codex
Host: 10.10.22.3
VM: rhel
Scenario: v3 force
Cutoff style: full
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T04-rhel-force-v3-full
RBD prefix: n2k-pc132-t04-rhel-force-v3-full

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Existing Nutanix `n2k-*` snapshot count: 0
- Target host bridge check: bridge0 UP
- Preflight selected mode: v3-incremental
- Preflight v3 source endpoint: 10.10.132.10
- Preflight source API policy: v3
- Preflight mode_forced: true

Execution:
- Full run result: PASS
- Base sync: 107374182400 bytes
- Incremental sync before cutoff: 0 changed regions, 0 bytes
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 0 changed regions, 0 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS, 3 v3 VM snapshots deleted
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge
- post-cutover Nutanix `n2k-*` snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T04-rhel-force-v3-full/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T04-rhel-force-v3-full/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T04-rhel-force-v3-full/artifacts/rhel.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T04-rhel-force-v3-full/evidence
- final dumpxml evidence: /var/lib/ablestack/n2k-e2e/pc132/T04-rhel-force-v3-full/evidence/full_dumpxml.xml

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Source Nutanix VM snapshots removed: yes
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `base_sync=true`, `incr_sync=true`, `final_sync=true`,
  `cutover=true`, `runtime.source_shutdown.ok=true`, source endpoint
  `10.10.132.10`, target libvirt state `running`, source VM power state `OFF`,
  source snapshot cleanup count `3`, Nutanix `n2k-*` snapshot count `0`.
```

### T05 - v3 force full centos7-bios-ide

```text
Case: T05
Started at: 2026-05-17 00:20 KST
Completed at: 2026-05-17 00:23 KST
Operator: Codex
Host: 10.10.22.2
VM: centos7-bios-ide
Scenario: v3 force
Cutoff style: full
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T05-centos-force-v3-full
RBD prefix: n2k-pc132-t05-centos-force-v3-full

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Existing Nutanix `n2k-*` snapshot count: 0
- Target host bridge check: bridge0 UP
- Preflight selected mode: v3-incremental
- Preflight v3 source endpoint: 10.10.132.10
- Preflight source API policy: v3
- Preflight mode_forced: true

Execution:
- Full run result: PASS
- Base sync: 107374182400 bytes
- Incremental sync before cutoff: 0 changed regions, 0 bytes
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 36 changed regions, 410624 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS, 3 v3 VM snapshots deleted
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge
- post-cutover Nutanix `n2k-*` snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T05-centos-force-v3-full/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T05-centos-force-v3-full/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T05-centos-force-v3-full/artifacts/centos7-bios-ide.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T05-centos-force-v3-full/evidence
- final dumpxml evidence: /var/lib/ablestack/n2k-e2e/pc132/T05-centos-force-v3-full/evidence/target.dumpxml
- manifest summary: /var/lib/ablestack/n2k-e2e/pc132/T05-centos-force-v3-full/evidence/manifest.summary.json

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Source Nutanix VM snapshots removed: yes
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `base_sync=true`, `incr_sync=true`, `final_sync=true`,
  `cutover=true`, `runtime.source_shutdown.ok=true`, source endpoint
  `10.10.132.10`, target libvirt state `running`, source VM power state `OFF`,
  source snapshot cleanup count `3`, Nutanix `n2k-*` snapshot count `0`.
```

### T06 - v3 force full win10

```text
Case: T06
Started at: 2026-05-17 00:30 KST
Completed at: 2026-05-17 00:44 KST
Operator: Codex
Host: 10.10.22.1
VM: win10
Scenario: v3 force
Cutoff style: full
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full
RBD prefix: n2k-pc132-t06-win10-force-v3-full

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Existing Nutanix `n2k-*` snapshot count: 0
- Target host bridge check: bridge0 UP
- Preflight selected mode: v3-incremental
- Preflight v3 source endpoint: 10.10.132.10
- Preflight source API policy: v3
- Preflight mode_forced: true

Execution:
- Full run result: PASS after retrying cutover/start with corrected test
  directory permissions
- Base sync: 107374182400 bytes
- Incremental sync before cutoff: completed
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 118 changed regions, 1335296 bytes
- First cutover apply/start result: target domain defined, start failed because
  qemu could not traverse `/var/lib/ablestack/n2k-e2e/pc132` to open the UEFI
  VARS file. This was caused by the test wrapper using restrictive directory
  permissions, not by an n2k engine patch requirement.
- Retry cutover apply/start result: PASS using the same manifest after
  normalizing parent directory permissions
- Source snapshot cleanup result: PASS, 3 v3 VM snapshots deleted
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge
- target firmware/NVRAM: secure UEFI pflash with win10_VARS.fd
- post-cutover Nutanix `n2k-*` snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full/artifacts/win10.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full/evidence
- first run timing: /var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full/evidence/timing.json
- retry cutover timing: /var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full/evidence/retry2.timing.json
- final dumpxml evidence: /var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full/evidence/target.dumpxml
- manifest summary: /var/lib/ablestack/n2k-e2e/pc132/T06-win10-force-v3-full/evidence/manifest.summary.json

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Source Nutanix VM snapshots removed: yes
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `base_sync=true`, `incr_sync=true`, `final_sync=true`,
  `cutover=true`, `runtime.source_shutdown.ok=true`, source endpoint
  `10.10.132.10`, target libvirt state `running`, source VM power state `OFF`,
  source snapshot cleanup count `3`, Nutanix `n2k-*` snapshot count `0`.
```

### T07 - PC v4 / PE v3 auto fallback Phase1/Phase2 rhel

```text
Case: T07
Started at: 2026-05-17 01:02 KST
Completed at: 2026-05-17 01:07 KST
Operator: Codex
Host: 10.10.22.2
VM: rhel
Scenario: PC v4 / PE v3 auto fallback
Cutoff style: Phase1/Phase2
Command mode args: --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T07-rhel-auto-fallback-split
RBD prefix: n2k-pc132-t07-rhel-auto-fallback-split

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Existing Nutanix `n2k-*` snapshot count: 0
- Target host bridge check: bridge0 UP
- Phase1 preflight requested mode: auto
- Phase1 preflight source API policy: auto
- Phase1 preflight mode_forced: false
- Phase1 preflight selected mode: v3-incremental
- Phase1 preflight v4 incremental available: false
- Phase1 preflight v3 source endpoint: 10.10.132.10

Execution:
- Phase1 result: PASS
- Phase1 base sync: 107374182400 bytes
- Phase1 incremental sync: 0 changed regions, 0 bytes
- Phase2 incremental result before cutoff: PASS, 0 changed regions, 0 bytes
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 0 changed regions, 0 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS, 4 v3 VM snapshots deleted
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: not applicable
- auto fallback metadata correct when applicable: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge
- post-cutover Nutanix `n2k-*` snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T07-rhel-auto-fallback-split/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T07-rhel-auto-fallback-split/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T07-rhel-auto-fallback-split/artifacts/rhel.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T07-rhel-auto-fallback-split/evidence
- auto fallback summary: /var/lib/ablestack/n2k-e2e/pc132/T07-rhel-auto-fallback-split/evidence/auto_fallback.summary.json
- manifest summary: /var/lib/ablestack/n2k-e2e/pc132/T07-rhel-auto-fallback-split/evidence/manifest.summary.json
- final dumpxml evidence: /var/lib/ablestack/n2k-e2e/pc132/T07-rhel-auto-fallback-split/evidence/target.dumpxml

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Source Nutanix VM snapshots removed: yes
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `requested_mode=auto`, `source_api_policy=auto`,
  `mode_forced=false`, `v4_incremental_available=false`,
  `selected_mode=v3-incremental`, source endpoint `10.10.132.10`,
  `runtime.split.phase1.done=true`, `runtime.split.phase2.done=true`,
  `final_sync=true`, `cutover=true`, `runtime.source_shutdown.ok=true`,
  target libvirt state `running`, source VM power state `OFF`, source snapshot
  cleanup count `4`, Nutanix `n2k-*` snapshot count `0`.
```

### T08 - PC v4 / PE v3 auto fallback Phase1/Phase2 centos7-bios-ide

```text
Case: T08
Started at: 2026-05-17 01:13 KST
Completed at: 2026-05-17 01:17 KST
Operator: Codex
Host: 10.10.22.1
VM: centos7-bios-ide
Scenario: PC v4 / PE v3 auto fallback
Cutoff style: Phase1/Phase2
Command mode args: --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T08-centos-auto-fallback-split
RBD prefix: n2k-pc132-t08-centos-auto-fallback-split

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Existing Nutanix `n2k-*` snapshot count: 0
- Target host bridge check: bridge0 UP
- Phase1 preflight requested mode: auto
- Phase1 preflight source API policy: auto
- Phase1 preflight mode_forced: false
- Phase1 preflight selected mode: v3-incremental
- Phase1 preflight v4 incremental available: false
- Phase1 preflight v3 source endpoint: 10.10.132.10

Execution:
- Phase1 result: PASS
- Phase1 base sync: 107374182400 bytes
- Phase1 incremental sync: 0 changed regions, 0 bytes
- Phase2 incremental result before cutoff: PASS, 0 changed regions, 0 bytes
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 33 changed regions, 410112 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS, 4 v3 VM snapshots deleted
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: not applicable
- auto fallback metadata correct when applicable: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge
- post-cutover Nutanix `n2k-*` snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T08-centos-auto-fallback-split/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T08-centos-auto-fallback-split/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T08-centos-auto-fallback-split/artifacts/centos7-bios-ide.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T08-centos-auto-fallback-split/evidence
- auto fallback summary: /var/lib/ablestack/n2k-e2e/pc132/T08-centos-auto-fallback-split/evidence/auto_fallback.summary.json
- manifest summary: /var/lib/ablestack/n2k-e2e/pc132/T08-centos-auto-fallback-split/evidence/manifest.summary.json
- final dumpxml evidence: /var/lib/ablestack/n2k-e2e/pc132/T08-centos-auto-fallback-split/evidence/target.dumpxml

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Source Nutanix VM snapshots removed: yes
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `requested_mode=auto`, `source_api_policy=auto`,
  `mode_forced=false`, `v4_incremental_available=false`,
  `selected_mode=v3-incremental`, source endpoint `10.10.132.10`,
  `runtime.split.phase1.done=true`, `runtime.split.phase2.done=true`,
  `final_sync=true`, `cutover=true`, `runtime.source_shutdown.ok=true`,
  target libvirt state `running`, source VM power state `OFF`, source snapshot
  cleanup count `4`, Nutanix `n2k-*` snapshot count `0`.
```

### T09 - PC v4 / PE v3 auto fallback Phase1/Phase2 win10

```text
Case: T09
Started at: 2026-05-17 01:23 KST
Completed at: 2026-05-17 01:35 KST
Operator: Codex
Host: 10.10.22.3
VM: win10
Scenario: PC v4 / PE v3 auto fallback
Cutoff style: Phase1/Phase2
Command mode args: --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T09-win10-auto-fallback-split
RBD prefix: n2k-pc132-t09-win10-auto-fallback-split

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Existing Nutanix `n2k-*` snapshot count: 0
- Target host bridge check: bridge0 UP
- Phase1 preflight requested mode: auto
- Phase1 preflight source API policy: auto
- Phase1 preflight mode_forced: false
- Phase1 preflight selected mode: v3-incremental
- Phase1 preflight v4 incremental available: false
- Phase1 preflight v3 source endpoint: 10.10.132.10

Execution:
- Phase1 result: PASS
- Phase1 base sync: 107374182400 bytes
- Phase1 incremental sync: 20 changed regions, 386560 bytes
- Phase2 incremental result before cutoff: PASS, 64 changed regions, 925696 bytes
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 145 changed regions, 1831424 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS, 4 v3 VM snapshots deleted
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: not applicable
- auto fallback metadata correct when applicable: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge
- target firmware/NVRAM: secure UEFI pflash with win10_VARS.fd
- post-cutover Nutanix `n2k-*` snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T09-win10-auto-fallback-split/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T09-win10-auto-fallback-split/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T09-win10-auto-fallback-split/artifacts/win10.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T09-win10-auto-fallback-split/evidence
- auto fallback summary: /var/lib/ablestack/n2k-e2e/pc132/T09-win10-auto-fallback-split/evidence/auto_fallback.summary.json
- manifest summary: /var/lib/ablestack/n2k-e2e/pc132/T09-win10-auto-fallback-split/evidence/manifest.summary.json
- final dumpxml evidence: /var/lib/ablestack/n2k-e2e/pc132/T09-win10-auto-fallback-split/evidence/target.dumpxml

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Source Nutanix VM snapshots removed: yes
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `requested_mode=auto`, `source_api_policy=auto`,
  `mode_forced=false`, `v4_incremental_available=false`,
  `selected_mode=v3-incremental`, source endpoint `10.10.132.10`,
  `runtime.split.phase1.done=true`, `runtime.split.phase2.done=true`,
  `final_sync=true`, `cutover=true`, `runtime.source_shutdown.ok=true`,
  target libvirt state `running`, source VM power state `OFF`, source snapshot
  cleanup count `4`, Nutanix `n2k-*` snapshot count `0`.
```

### T10 - PC v4 / PE v3 auto fallback full rhel

```text
Case: T10
Started at: 2026-05-17 13:08 KST
Completed at: 2026-05-17 13:12 KST
Operator: Codex
Host: 10.10.22.3
VM: rhel
Scenario: PC v4 / PE v3 auto fallback
Cutoff style: full
Command mode args: --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T10-rhel-auto-fallback-full
RBD prefix: n2k-pc132-t10-rhel-auto-fallback-full

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Existing workdir check: none
- Existing Nutanix `n2k-*` snapshot count: 0
- Target host bridge check: bridge0 UP
- Preflight requested mode: auto
- Preflight source API policy: auto
- Preflight mode_forced: false
- Preflight selected mode: v3-incremental
- Preflight v4 incremental available: false
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Full run result: PASS
- Base sync: 107374182400 bytes
- Incremental sync before cutoff: 0 changed regions, 0 bytes
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 0 changed regions, 0 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS, 3 v3 VM snapshots deleted
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: not applicable
- auto fallback metadata correct when applicable: yes
- full base sync completed: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge
- target firmware/NVRAM: secure UEFI pflash with rhel_VARS.fd
- post-cutover Nutanix `n2k-*` snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T10-rhel-auto-fallback-full/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T10-rhel-auto-fallback-full/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T10-rhel-auto-fallback-full/artifacts/rhel.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T10-rhel-auto-fallback-full/evidence
- final verify summary: /var/lib/ablestack/n2k-e2e/pc132/T10-rhel-auto-fallback-full/evidence/final_verify.summary.json

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Source Nutanix VM snapshots removed: yes
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `requested_mode=auto`, `source_api_policy=auto`,
  `mode_forced=false`, `v4_incremental_available=false`,
  `selected_mode=v3-incremental`, source endpoint `10.10.132.10`,
  base sync `107374182400` bytes, incremental sync `0` regions / `0` bytes,
  `final_sync=true`, final sync `0` regions / `0` bytes, `cutover=true`,
  `runtime.source_shutdown.ok=true`, target libvirt state `running`, target
  bridge `bridge0`, target secure UEFI NVRAM present, source VM power state
  `OFF`, source snapshot cleanup count `3`, Nutanix `n2k-*` snapshot count `0`.
```

### T11 - PC v4 / PE v3 auto fallback full centos7-bios-ide

```text
Case: T11
Started at: 2026-05-17 13:25 KST
Completed at: 2026-05-17 13:29 KST
Operator: Codex
Host: 10.10.22.2
VM: centos7-bios-ide
Scenario: PC v4 / PE v3 auto fallback
Cutoff style: full
Command mode args: --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T11-centos-auto-fallback-full
RBD prefix: n2k-pc132-t11-centos-auto-fallback-full

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Existing workdir check: none
- Existing Nutanix `n2k-*` snapshot count: 0
- Target host bridge check: bridge0 UP
- Preflight requested mode: auto
- Preflight source API policy: auto
- Preflight mode_forced: false
- Preflight selected mode: v3-incremental
- Preflight v4 incremental available: false
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Full run result: PASS
- Base sync: 107374182400 bytes
- Incremental sync before cutoff: 0 changed regions, 0 bytes
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 34 changed regions, 414208 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS, 3 v3 VM snapshots deleted
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: not applicable
- auto fallback metadata correct when applicable: yes
- full base sync completed: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge
- target firmware/NVRAM: legacy BIOS, no UEFI loader or NVRAM
- target disk bus observed in libvirt XML: sata
- post-cutover Nutanix `n2k-*` snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T11-centos-auto-fallback-full/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T11-centos-auto-fallback-full/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T11-centos-auto-fallback-full/artifacts/centos7-bios-ide.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T11-centos-auto-fallback-full/evidence
- final verify summary: /var/lib/ablestack/n2k-e2e/pc132/T11-centos-auto-fallback-full/evidence/final_verify.summary.json

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Source Nutanix VM snapshots removed: yes
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `requested_mode=auto`, `source_api_policy=auto`,
  `mode_forced=false`, `v4_incremental_available=false`,
  `selected_mode=v3-incremental`, source endpoint `10.10.132.10`,
  base sync `107374182400` bytes, incremental sync `0` regions / `0` bytes,
  `final_sync=true`, final sync `34` regions / `414208` bytes,
  `cutover=true`, `runtime.source_shutdown.ok=true`, target libvirt state
  `running`, target bridge `bridge0`, target legacy BIOS XML with no UEFI
  loader/NVRAM, target disk bus `sata`, source VM power state `OFF`, source
  snapshot cleanup count `3`, Nutanix `n2k-*` snapshot count `0`.
```

### T12 - PC v4 / PE v3 auto fallback full win10

```text
Case: T12
Started at: 2026-05-17 14:01 KST
Completed at: 2026-05-17 14:11 KST
Operator: Codex
Host: 10.10.22.1
VM: win10
Scenario: PC v4 / PE v3 auto fallback
Cutoff style: full
Command mode args: --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full
RBD prefix: n2k-pc132-t12-win10-auto-fallback-full

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Existing workdir check: none
- Existing Nutanix `n2k-*` snapshot count: 0
- Target host bridge check: bridge0 UP
- Installed source adapter check: deployed RPM contains `--slurpfile regions`
- Preflight requested mode: auto
- Preflight source API policy: auto
- Preflight mode_forced: false
- Preflight selected mode: v3-incremental
- Preflight v4 incremental available: false
- Preflight v3 source endpoint: 10.10.132.10

Execution:
- Initial pre-fix run result: BLOCKED by `jq` argument limit while handling a
  large changed-region response.
- Follow-up patch/deploy: changed large changed-region JSON handoff to file or
  stdin based `jq` input, rebuilt and deployed RPM SHA256
  `c9160bd2af8834855cd5bc4bfb30e60fc03d9431fdc4219de7e4e7361817a61c`.
- Failed workdir preservation: /var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full.failed-arglimit-20260517-133919
- Clean full rerun result: PASS
- Base sync: 107374182400 bytes
- Incremental sync before cutoff: 116 changed regions, 1953792 bytes
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 54 changed regions, 1216512 bytes
- Cutover apply/start result: PASS
- Source snapshot cleanup result: PASS, 3 v3 VM snapshots deleted
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: not applicable
- auto fallback metadata correct when applicable: yes
- full base sync completed: yes
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge
- target firmware/NVRAM: secure UEFI pflash with win10_VARS.fd
- target disk bus observed in libvirt XML: scsi
- post-cutover Nutanix `n2k-*` snapshot count is 0: yes

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full/artifacts/win10.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full/evidence
- final verify summary: /var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full/evidence/final_verify.summary.json
- target dumpxml evidence: /var/lib/ablestack/n2k-e2e/pc132/T12-win10-auto-fallback-full/evidence/target.dumpxml

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Source Nutanix VM snapshots removed: yes
- Workdir preserved: yes
- Failed pre-fix workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `requested_mode=auto`, `source_api_policy=auto`,
  `mode_forced=false`, `v4_incremental_available=false`,
  `selected_mode=v3-incremental`, source endpoint `10.10.132.10`,
  source API family `v3`, base sync `107374182400` bytes, incremental sync
  `116` regions / `1953792` bytes, `final_sync=true`, final sync `54`
  regions / `1216512` bytes, `cutover=true`,
  `runtime.source_shutdown.ok=true`, target libvirt state `running`, target
  bridge `bridge0`, target secure UEFI NVRAM present, target disk bus `scsi`,
  source VM power state `OFF`, source snapshot cleanup count `3`, Nutanix
  `n2k-*` snapshot count `0`.
```

### T02 - v3 force Phase1/Phase2 centos7-bios-ide

```text
Case: T02
Started at: 2026-05-16 23:04 KST
Completed at: 2026-05-16 23:08 KST
Operator: Codex
Host: 10.10.22.1
VM: centos7-bios-ide
Scenario: v3 force
Cutoff style: Phase1/Phase2
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T02-centos-force-v3-split
RBD prefix: n2k-pc132-t02-centos-force-v3-split

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Target host bridge check: bridge0 UP
- Preflight selected mode: v3-incremental
- Preflight v3 source endpoint: 10.10.132.10
- Preflight source API policy: v3
- Preflight mode_forced: true

Execution:
- Phase1 result: PASS
- Phase1 base sync: 107374182400 bytes
- Phase1 incremental sync: 0 changed regions, 0 bytes
- Phase2 incremental result before cutoff: PASS
- Phase2 incremental sync before cutoff: 0 changed regions, 0 bytes
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 77 changed regions, 1471488 bytes
- Cutover apply/start result: PASS
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T02-centos-force-v3-split/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T02-centos-force-v3-split/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T02-centos-force-v3-split/artifacts/centos7-bios-ide.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T02-centos-force-v3-split/evidence
- final dumpxml evidence: /var/lib/ablestack/n2k-e2e/pc132/T02-centos-force-v3-split/evidence/phase2_dumpxml.xml

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `runtime.split.phase1.done=true`, `final_sync=true`,
  `cutover=true`, `runtime.split.phase2.done=true`,
  `runtime.source_shutdown.ok=true`, source endpoint `10.10.132.10`, target
  libvirt state `running`, source VM power state `OFF`.
```

### T03 - v3 force Phase1/Phase2 win10

```text
Case: T03
Started at: 2026-05-16 23:12 KST
Completed at: 2026-05-16 23:25 KST
Operator: Codex
Host: 10.10.22.3
VM: win10
Scenario: v3 force
Cutoff style: Phase1/Phase2
Command mode args: --force-v3 --network-mode bridge --bridge bridge0
Workdir: /var/lib/ablestack/n2k-e2e/pc132/T03-win10-force-v3-split
RBD prefix: n2k-pc132-t03-win10-force-v3-split

Pre-check:
- Source power state before run: ON
- Target domain conflict check: none
- Existing RBD prefix check: none
- Target host bridge check: bridge0 UP
- Preflight selected mode: v3-incremental
- Preflight v3 source endpoint: 10.10.132.10
- Preflight source API policy: v3
- Preflight mode_forced: true

Execution:
- Phase1 result: PASS
- Phase1 base sync: 107374182400 bytes
- Phase1 incremental sync: 147 changed regions, 2072576 bytes
- Phase2 incremental result before cutoff: PASS
- Shutdown policy/result: guest, PASS through source endpoint 10.10.132.10
- Final sync result: PASS, 141 changed regions, 2289664 bytes
- Cutover apply/start result: PASS
- Target VM libvirt state: running
- Target VM boot observation: libvirt state reached running

Expected assertions:
- selected_mode is v3-incremental: yes
- source endpoint is 10.10.132.10: yes
- force-v3 metadata correct when applicable: yes
- auto fallback metadata correct when applicable: not applicable
- final sync completed: yes
- cutover phase completed: yes
- target started: yes
- target network mode: bridge0 bridge

Artifacts:
- manifest.json: /var/lib/ablestack/n2k-e2e/pc132/T03-win10-force-v3-split/manifest.json
- events.log: /var/lib/ablestack/n2k-e2e/pc132/T03-win10-force-v3-split/events.log
- libvirt XML: /var/lib/ablestack/n2k-e2e/pc132/T03-win10-force-v3-split/artifacts/win10.xml
- command stdout/stderr: /var/lib/ablestack/n2k-e2e/pc132/T03-win10-force-v3-split/evidence
- final dumpxml evidence: /var/lib/ablestack/n2k-e2e/pc132/T03-win10-force-v3-split/evidence/phase2_dumpxml.xml

Cleanup:
- Target VM stopped/undefined: no; target VM is running for operator observation
- Source VM powered back on: no; source VM remains OFF after successful cutoff
- RBD images removed or preserved: preserved for running target
- Workdir preserved: yes
- Runtime credential file removed: yes

Result:
- PASS
- Final assertions: `runtime.split.phase1.done=true`, `final_sync=true`,
  `cutover=true`, `runtime.split.phase2.done=true`,
  `runtime.source_shutdown.ok=true`, source endpoint `10.10.132.10`, target
  libvirt state `running`, source VM power state `OFF`.
```

### Preparation before T04-T06 full tests

```text
Completed at: 2026-05-16 23:33 KST
Operator: Codex
Purpose: Restore the PC132 testbed and ABLESTACK targets after T01-T03 before
running the v3 force full migration cases T04-T06.

Target cleanup:
- Removed target libvirt domain `rhel` from 10.10.22.2.
- Removed target libvirt domain `centos7-bios-ide` from 10.10.22.1.
- Removed target libvirt domain `win10` from 10.10.22.3.
- Removed RBD image `n2k-pc132-t01-rhel-force-v3-split-disk0`.
- Removed RBD image `n2k-pc132-t02-centos-force-v3-split-disk0`.
- Removed RBD image `n2k-pc132-t03-win10-force-v3-split-disk0`.

Source restore:
- Started source VM `rhel`; final power state: ON.
- Started source VM `centos7-bios-ide`; final power state: ON.
- Started source VM `win10`; final power state: ON.

Snapshot cleanup:
- Deleted 10 leftover Nutanix v3 VM snapshots whose names started with `n2k-`.
- Final `n2k-` VM snapshot count: 0.

Final verification:
- Target domain state for T01/T02/T03 names: absent.
- RBD image count for T01/T02/T03 prefixes: 0.
- Source VMs for T04-T06: ON.
- Workdirs and evidence directories were preserved.
```

### Preparation before T07-T12 auto fallback tests

```text
Completed at: 2026-05-17 01:03 KST
Operator: Codex
Purpose: Restore the PC132 testbed and ABLESTACK targets after T04-T06 before
running the PC v4 / PE v3 auto fallback migration cases T07-T12.

Target cleanup:
- Removed target libvirt domain `win10` from 10.10.22.1.
- Removed old n2k target libvirt domain `rhel` from 10.10.22.1.
- Removed target libvirt domain `centos7-bios-ide` from 10.10.22.2.
- Removed target libvirt domain `rhel` from 10.10.22.3.
- Removed RBD image `n2k-pc132-t04-rhel-force-v3-full-disk0`.
- Removed RBD image `n2k-pc132-t05-centos-force-v3-full-disk0`.
- Removed RBD image `n2k-pc132-t06-win10-force-v3-full-disk0`.

Garbage cleanup:
- Removed T04/T05/T06 workdirs under `/var/lib/ablestack/n2k-e2e/pc132`.
- Removed old 10.10.22.1 qcow2 test workdir
  `/var/lib/ablestack-n2k/e2e/host-qcow2-full-rhel-20260515-133357`.
- Removed old 10.10.22.1 qcow2 test image directory
  `/var/lib/libvirt/images/n2k/host-qcow2-full-rhel-20260515-133357`.

Source restore:
- Started source VM `rhel`; final power state: ON.
- Started source VM `centos7-bios-ide`; final power state: ON.
- Started source VM `win10`; final power state: ON.

Snapshot cleanup:
- No Nutanix v3 VM snapshots whose names started with `n2k-` remained before
  cleanup.
- Final `n2k-` VM snapshot count: 0.

Final verification:
- Target domain state for `rhel`, `centos7-bios-ide`, and `win10`: absent on
  10.10.22.1, 10.10.22.2, and 10.10.22.3.
- RBD image count for T04/T05/T06 prefixes: 0.
- Workdir/log garbage count for T04/T05/T06 prefixes: 0.
- Source VMs for T07-T12: ON.
```

### Preparation before T10-T12 auto fallback full tests

```text
Completed at: 2026-05-17 01:45 KST
Operator: Codex
Purpose: Restore the PC132 testbed and ABLESTACK targets after T07-T09 before
running the PC v4 / PE v3 auto fallback full migration cases T10-T12.

Target cleanup:
- Removed target libvirt domain `centos7-bios-ide` from 10.10.22.1.
- Removed target libvirt domain `rhel` from 10.10.22.2.
- Removed target libvirt domain `win10` from 10.10.22.3.
- Removed RBD image `n2k-pc132-t07-rhel-auto-fallback-split-disk0`.
- Removed RBD image `n2k-pc132-t08-centos-auto-fallback-split-disk0`.
- Removed RBD image `n2k-pc132-t09-win10-auto-fallback-split-disk0`.

Garbage cleanup:
- Removed T07/T08/T09 workdirs under `/var/lib/ablestack/n2k-e2e/pc132`.
- Verified no T10/T11/T12 workdirs existed before the next full-run group.

Source restore:
- Started source VM `rhel`; final power state: ON.
- Started source VM `centos7-bios-ide`; final power state: ON.
- Started source VM `win10`; final power state: ON.

Snapshot cleanup:
- No Nutanix v3 VM snapshots whose names started with `n2k-` remained before
  cleanup.
- Final `n2k-` VM snapshot count: 0.

Final verification:
- Target domain state for `rhel`, `centos7-bios-ide`, and `win10`: absent on
  10.10.22.1, 10.10.22.2, and 10.10.22.3.
- RBD image count for T07/T08/T09/T10/T11/T12 prefixes: 0.
- Workdir/log garbage count for T07/T08/T09/T10/T11/T12 prefixes: 0.
- Source VMs for T10-T12: ON.
```

### Source snapshot cleanup behavior update

```text
Recorded at: 2026-05-16
Reason: T01-T03 left Nutanix v3 VM snapshots after successful cutoff. This is
not acceptable for normal migration completion because post-cutoff snapshots are
temporary migration artifacts.

Implementation update:
- `run` now deletes pending Nutanix v3 VM snapshots automatically after a
  successful cutover.
- Created recovery points are appended to `runtime.recovery_point_history`, so
  repeated incremental rounds and retried Phase2 runs can clean up older
  snapshots that are no longer the current `base`, `incr`, or `final` entry.
- Cleanup is performed only after cutover succeeds. If define/start fails, the
  source snapshots are preserved for investigation and retry.
- Cleanup failures make the `run` command fail instead of silently passing.
- Operators can retain source snapshots explicitly with `--keep-source-points`.
- Idempotent cleanup treats an already-missing v3 VM snapshot as successfully
  absent.

Validation:
- Local mock validation confirmed that base, old incr, current incr, and final
  v3 snapshots are all selected for deletion and marked with cleanup metadata
  in the manifest.
- Rebuilt RPM SHA256:
  `fa8f04212c6bbb10286827ca76839334e151a6d417072652d9d2c3b99c8af59c`.
- Installed the rebuilt RPM on `10.10.22.1`, `10.10.22.2`, and `10.10.22.3`;
  each host exposes `--cleanup-source-points` and `--keep-source-points` in
  `ablestack_n2k run --help`.
```

## Completion criteria

The PC132 v3 force/fallback E2E pass is complete only when all 12 cases have a
final `PASS`, `FAIL`, or `BLOCKED` result with evidence paths.

Release-quality pass criteria:

- All v3 force cases pass, or failures are fixed and rerun successfully.
- All PC v4 / PE v3 auto fallback cases pass, or failures are fixed and rerun
  successfully.
- Every successful case records the expected v3 source endpoint
  `10.10.132.10`.
- Every successful force-v3 case records `mode_forced=true`.
- Every successful auto fallback case records `mode_forced=false` and still
  selects `v3-incremental`.
- Source VM reuse is performed safely: target VM is stopped before source VM is
  powered back on.
