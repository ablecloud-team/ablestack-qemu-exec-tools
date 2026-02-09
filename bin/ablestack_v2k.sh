#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ---------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/engine.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/logging.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/manifest.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/orchestrator.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/fleet.sh"

v2k_resolve_vddk_libdir() {
  # Do NOT modify the path (no auto appending like /lib64).
  # VDDK plugin behavior is expected to work with distrib root.
  if [[ -n "${VDDK_LIBDIR-}" ]]; then
    export VDDK_LIBDIR
    return 0
  fi

  # 1) Load from /etc/profile.d (written by installer)
  if [[ -f /etc/profile.d/v2k-vddk.sh ]]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/v2k-vddk.sh >/dev/null 2>&1 || true
  fi

  # 2) If still empty, try the well-known symlink path
  if [[ -z "${VDDK_LIBDIR-}" && -d /opt/vmware-vix-disklib-distrib ]]; then
    VDDK_LIBDIR="/opt/vmware-vix-disklib-distrib"
  fi

  if [[ -n "${VDDK_LIBDIR-}" ]]; then
    export VDDK_LIBDIR
  fi
}

v2k_resolve_vddk_libdir

# Optional diagnostics
if [[ "${V2K_DEBUG_ENV:-0}" -eq 1 ]]; then
  echo "[DEBUG] VDDK_LIBDIR='${VDDK_LIBDIR-}'" >&2
fi

usage() {
  cat <<'EOF'
ablestack_v2k - VMware -> ABLESTACK(KVM) minimal downtime migration tool (v1)

Usage:
  ablestack_v2k [global options] <command> [command options]

Global options (all commands):
  --workdir <path>        Work directory (default: /var/lib/ablestack-v2k/<vm>/<run_id>)
  --run-id <id>           Run identifier (auto-generate if omitted)
  --manifest <path>       Manifest path (default: <workdir>/manifest.json)
  --log <path>            Events log path (default: <workdir>/events.log)
  --json                  Machine-readable JSON output
  --dry-run               Do not execute destructive operations
  --resume                Resume based on manifest
  --force                 Force risky operations (required for some edge cases)
  -h, --help              Show help

Commands:
  run (alias: auto)       Full pipeline orchestration (init -> cbt -> base -> incr* -> final -> verify -> cutover -> cleanup)
  init                    Initialize workdir and manifest
  cbt                     CBT operations: enable|status
  snapshot                Snapshot operations: base|incr|final
  sync                    Data sync: base|incr|final
  verify                  Verification (quick sampling)
  cutover                 Define/start KVM VM and perform cutover operations
  cleanup                 Cleanup resources (snapshots/workdir policy)
  status                  Show current status (manifest + events)

----------------------------------------------------------------------
RUN / AUTO (pipeline orchestration)
----------------------------------------------------------------------
Usage:
  ablestack_v2k run [--foreground] [run options...]
  ablestack_v2k auto [--foreground] [run options...]

Run options (exactly parsed by orchestrator.sh):
  --foreground
      Run in foreground. (Default: background; logs to <workdir>/run.out)

  # Required init inputs for 'run' (phase2 can auto-discover cred files from workdir)
  --vm <name|moref>                   VM name or MoRef
  --vcenter <host>                    vCenter host
  --dst <path>                        Destination root path (work/meta path)

  # Optional auth shortcuts / files
  --username <user>                   vCenter username (optional shortcut)
  --password <pass>                   vCenter password (optional shortcut)
  --cred-file <file>                  govc env file (preferred)
  --vddk-cred-file <file>             VDDK cred file (for nbdkit/vddk plugin)
  --insecure <0|1>                    govc insecure (default: V2K_RUN_DEFAULT_INSECURE or 1)

  # Pipeline policy
  --shutdown manual|guest|poweroff    VMware VM shutdown policy for cutover (default: V2K_RUN_DEFAULT_SHUTDOWN or manual)
  --kvm-vm-policy none|define-only|define-and-start
                                     KVM VM action at cutover (default: V2K_RUN_DEFAULT_KVM_POLICY or none)
  --incr-interval <sec>               Interval between incremental loops (default: V2K_RUN_DEFAULT_INCR_INTERVAL or 10)
  --max-incr <N>                      Maximum number of incremental loops (default: V2K_RUN_DEFAULT_MAX_INCR or 6)
  --converge-threshold-sec <sec>      Stop incr loop early if (snapshot+sync) duration <= sec (default: V2K_RUN_DEFAULT_CONVERGE_THRESHOLD_SEC or 120)
  --no-incr                           Skip incremental loops (base -> final -> cutover)

  # Split-run mode
  --split full|phase1|phase2          Split-run mode (default: V2K_RUN_DEFAULT_SPLIT or full)
      full   : base + incr* + final + verify + cutover
      phase1 : base + incr1 then exit (no cutover)
      phase2 : resume from workdir; run incrN until a sync completes within deadline window, then cutover
  --deadline-sec <sec>                Phase2 deadline window seconds (default: V2K_RUN_DEFAULT_DEADLINE_SEC or 120)
  --max-incr-phase2 <N>               Phase2 safety cap for incr loops (default: V2K_RUN_DEFAULT_MAX_INCR_PHASE2 or 20)

  # Sync defaults (applied to base/incr/final sync when set)
  --jobs <N>                          Default jobs for sync steps
  --chunk <BYTES>                     Default chunk size for sync steps
  --coalesce-gap <BYTES>              Default coalesce gap for sync steps

  # Extra argument strings (split by whitespace; for complex quoting prefer discrete commands)
  --base-args "<...>"                 Extra args appended to 'sync base'
  --incr-args "<...>"                 Extra args appended to 'sync incr'
  --cutover-args "<...>"              Extra args appended to 'cutover'

  # Init parameters (passed into init stage inside run)
  --mode <govc>                       Init mode (default: govc)
  --target-format qcow2|raw
  --target-storage file|block|rbd
  --target-map-json <json>            Required for block/rbd targets (disk mapping)
  --force-block-device                Allow risky block/rbd operations

  # Cleanup policy for run
  --no-cleanup                        Do not call cleanup at the end
  --keep-snapshots                    Keep VMware snapshots during cleanup
  --keep-workdir                      Keep workdir during cleanup

Notes:
  - Phase2 will auto-discover creds from workdir when omitted:
      <workdir>/govc.env , <workdir>/vddk.cred
  - For Windows guests, run/auto may enable WinPE bootstrap at cutover depending on V2K_RUN_WINPE_BOOTSTRAP_AUTO.

----------------------------------------------------------------------
INIT
----------------------------------------------------------------------
Usage:
  ablestack_v2k init --vm <name|moref> --vcenter <host> --dst <path> [options...]

Options:
  --mode <govc>                       Init mode (default: govc)
  --cred-file <file>                  govc env file
  --vddk-cred-file <file>             VDDK cred file (for nbdkit/vddk plugin)
  --target-format qcow2|raw
  --target-storage file|block|rbd
  --target-map-json <json>            Disk mapping JSON (required for block/rbd)
  --force-block-device                Allow risky block/rbd operations

----------------------------------------------------------------------
CBT
----------------------------------------------------------------------
Usage:
  ablestack_v2k cbt enable
  ablestack_v2k cbt status

----------------------------------------------------------------------
SNAPSHOT
----------------------------------------------------------------------
Usage:
  ablestack_v2k snapshot base|incr|final [--name <snapname>]

Options:
  --name <snapname>                   Snapshot name override

----------------------------------------------------------------------
SYNC
----------------------------------------------------------------------
Usage:
  ablestack_v2k sync base|incr|final [options...]

Options:
  --jobs <N>                          Parallel jobs
  --coalesce-gap <BYTES>              Coalesce gap
  --chunk <BYTES>                     Chunk size

----------------------------------------------------------------------
VERIFY
----------------------------------------------------------------------
Usage:
  ablestack_v2k verify [--mode quick] [--samples N]

Options:
  --mode <quick>                      Verification mode
  --samples <N>                       Number of samples

----------------------------------------------------------------------
CUTOVER
----------------------------------------------------------------------
Usage:
  ablestack_v2k cutover [options...]

Common options (see engine.sh/target_libvirt.sh for full behavior):
  --shutdown manual|guest|poweroff
  --define-only
  --start
  --vcpu <N>
  --memory <MB>
  --network <name>
  --bridge <br>
  --vlan <id>
  --shutdown-timeout <SEC>
  --force-cleanup
  --winpe-bootstrap
  --winpe-iso <path>
  --virtio-iso <path>
  --winpe-timeout <SEC>

----------------------------------------------------------------------
CLEANUP / STATUS
----------------------------------------------------------------------
Usage:
  ablestack_v2k cleanup [--keep-snapshots] [--keep-workdir]
  ablestack_v2k status

----------------------------------------------------------------------
Environment variables
----------------------------------------------------------------------
Global behavior:
  V2K_JSON_OUT=1                      Same as --json
  V2K_DRY_RUN=1                       Same as --dry-run
  V2K_RESUME=1                        Same as --resume
  V2K_FORCE=1                         Same as --force

Paths:
  V2K_WORKDIR=<path>
  V2K_RUN_ID=<id>
  V2K_MANIFEST=<path>
  V2K_EVENTS_LOG=<path>

govc (common):
  GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_INSECURE

VDDK:
  VDDK_LIBDIR                          VDDK distrib root (no auto /lib64 append)
  V2K_DEBUG_ENV=1                       Print resolved VDDK_LIBDIR diagnostics

run defaults (orchestrator):
  V2K_RUN_DEFAULT_SHUTDOWN
  V2K_RUN_DEFAULT_KVM_POLICY
  V2K_RUN_DEFAULT_INCR_INTERVAL
  V2K_RUN_DEFAULT_MAX_INCR
  V2K_RUN_DEFAULT_CONVERGE_THRESHOLD_SEC
  V2K_RUN_DEFAULT_INSECURE
  V2K_RUN_WINPE_BOOTSTRAP_AUTO
  V2K_RUN_DEFAULT_SPLIT
  V2K_RUN_DEFAULT_DEADLINE_SEC
  V2K_RUN_DEFAULT_MAX_INCR_PHASE2

----------------------------------------------------------------------
Storage presets (init/run)
----------------------------------------------------------------------
1) qcow2 + file (image files under dst)
  ablestack_v2k run --vm <VM> --vcenter <VC> --dst /var/lib/libvirt/images/<vm> \
    --target-format qcow2 --target-storage file

2) raw + file (raw image files under dst)
  ablestack_v2k run --vm <VM> --vcenter <VC> --dst /var/lib/libvirt/images/<vm> \
    --target-format raw --target-storage file

3) raw + block (direct block devices; requires target map)
  ablestack_v2k run --vm <VM> --vcenter <VC> --dst /var/lib/libvirt/images/<vm> \
    --target-format raw --target-storage block \
    --target-map-json '{"scsi0:0":"/dev/sdb"}'

4) raw + rbd (Ceph RBD; requires target map)
  ablestack_v2k run --vm <VM> --vcenter <VC> --dst /var/lib/libvirt/images/<vm> \
    --target-format raw --target-storage rbd \
    --target-map-json '{"scsi0:0":"rbd:pool/myvm-disk0"}'

----------------------------------------------------------------------
Step-by-step examples (run first, then discrete steps)
----------------------------------------------------------------------
Full automation:
  ablestack_v2k run --vm <VM> --vcenter <VC> --dst <DST> --target-format qcow2 --target-storage file

Manual steps:
  ablestack_v2k init --vm <VM> --vcenter <VC> --dst <DST> --target-format qcow2 --target-storage file
  ablestack_v2k cbt enable
  ablestack_v2k snapshot base
  ablestack_v2k sync base --jobs 8
  ablestack_v2k snapshot incr
  ablestack_v2k sync incr --jobs 8
  ablestack_v2k snapshot final
  ablestack_v2k sync final --jobs 8
  ablestack_v2k verify --mode quick --samples 50
  ablestack_v2k cutover --shutdown guest --start --vcpu 4 --memory 8192 --bridge br0
  ablestack_v2k cleanup
  ablestack_v2k status
EOF
}

die() { echo "ERROR: $*" >&2; exit 2; }

parse_arg_string() {
  local s="${1-}"
  local -n _out_arr="${2}"
  _out_arr=()
  [[ -z "${s}" ]] && return 0
  # shellcheck disable=SC2162
  read -r -a _out_arr <<<"${s}"
}

# ---------------------------
# Global arg parsing
# ---------------------------
WORKDIR=""
RUN_ID=""
MANIFEST=""
EVENTS_LOG=""
JSON_OUT=0
DRY_RUN=0
RESUME=0
FORCE=0

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) WORKDIR="${2:-}"; shift 2;;
    --run-id) RUN_ID="${2:-}"; shift 2;;
    --manifest) MANIFEST="${2:-}"; shift 2;;
    --log) EVENTS_LOG="${2:-}"; shift 2;;
    --json) JSON_OUT=1; shift 1;;
    --dry-run) DRY_RUN=1; shift 1;;
    --resume) RESUME=1; shift 1;;
    --force) FORCE=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) ARGS+=("$1"); shift 1;;
  esac
done

if [[ ${#ARGS[@]} -lt 1 ]]; then
  usage
  exit 2
fi

CMD="${ARGS[0]}"
shifted_args=("${ARGS[@]:1}")

export V2K_JSON_OUT="${JSON_OUT}"
export V2K_DRY_RUN="${DRY_RUN}"
export V2K_RESUME="${RESUME}"
export V2K_FORCE="${FORCE}"

v2k_set_paths \
  "${WORKDIR}" \
  "${RUN_ID}" \
  "${MANIFEST}" \
  "${EVENTS_LOG}"

# [NEW] Ensure NBD module is loaded (Auto-recovery after reboot)
if ! lsmod | grep -q "^nbd"; then
    v2k_event INFO "linux_bootstrap" "" "loading_nbd_module" "{}"
    modprobe nbd max_part=16
    udevadm settle
fi

case "${CMD}" in
  run|auto)
    if v2k_fleet_should_handle_run "${shifted_args[@]}"; then
      v2k_fleet_cmd_run "${shifted_args[@]}"
    else
      v2k_cmd_run "${shifted_args[@]}"
    fi
    ;;
  init)
    v2k_cmd_init "${shifted_args[@]}"
    ;;
  cbt)
    v2k_cmd_cbt "${shifted_args[@]}"
    ;;
  snapshot)
    v2k_cmd_snapshot "${shifted_args[@]}"
    ;;
  sync)
    v2k_cmd_sync "${shifted_args[@]}"
    ;;
  verify)
    v2k_cmd_verify "${shifted_args[@]}"
    ;;
  cutover)
    v2k_cmd_cutover "${shifted_args[@]}"
    ;;
  cleanup)
    v2k_cmd_cleanup "${shifted_args[@]}"
    ;;
  status)
    if v2k_fleet_should_handle_status "${shifted_args[@]}"; then
      v2k_fleet_cmd_status "${shifted_args[@]}"
    else
      v2k_cmd_status "${shifted_args[@]}"
    fi
    ;;
  *)
    echo "Unknown command: ${CMD}" >&2
    usage
    exit 2
    ;;
esac
