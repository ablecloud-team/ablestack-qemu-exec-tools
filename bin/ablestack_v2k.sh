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

Global options:
  --workdir <path>        Work directory (default: /var/lib/ablestack-v2k/<vm>/<run_id>)
  --run-id <id>           Run identifier (init will generate if omitted)
  --manifest <path>       Manifest path (default: <workdir>/manifest.json)
  --log <path>            Events log path (default: <workdir>/events.log)
  --json                  Machine-readable JSON output
  --dry-run               Do not execute destructive operations
  --resume                Resume based on manifest
  --force                 Force risky operations
  -h, --help              Show help

Commands (existing):
  init --vm <name|moref> --vcenter <host> --dst <path> [--mode govc] [--cred-file <file>] \
       [--target-format qcow2|raw] [--target-storage file|block] [--target-map-json <json>] \
       [--force-block-device] \
       [--vddk-cred-file <file>]
  cbt enable|status
  snapshot base|incr|final [--name <snapname>]
  sync base|incr|final [--jobs N] [--coalesce-gap BYTES] [--chunk BYTES]
  verify [--mode quick] [--samples N]
  cutover [--shutdown manual|guest|poweroff] [--define-only] [--start] \
          [--vcpu N] [--memory MB] [--network <name>] [--bridge <br>] [--vlan <id>] \
          [--shutdown-timeout SEC] [--force-cleanup] \
          [--winpe-bootstrap] [--winpe-iso <path>] [--virtio-iso <path>] [--winpe-timeout SEC]
  cleanup [--keep-snapshots] [--keep-workdir]
  status

Commands (product automation):
  run  <pipeline options> <init args...>
  auto <same as run>

Pipeline options:
  --shutdown manual|guest|poweroff    VMware VM shutdown policy for cutover (default: manual)
  --kvm-vm-policy define-only|define-and-start
                                     KVM VM action at cutover (default: none)
  --incr-interval <sec>               Interval between incremental loops (default: 10)
  --max-incr <N>                      Maximum number of incremental loops (default: 6)
  --converge-threshold-sec <sec>      Stop incr loop early if (snapshot+sync) duration <= sec (default: 120)
  --no-incr                           Skip incremental loops (base -> cutover)

  --split <full|phase1|phase2>        Split-run mode (default: full)
    - phase1: base snap/sync + incr1 snap/sync then exit (no cutover)
    - phase2: incr2..N loop until a sync completes within --deadline-sec, then cutover
  --deadline-sec <sec>                Phase2 deadline window seconds (default: 120)
  --max-incr-phase2 <n>               Phase2 safety cap for incr loops (default: 20)

  --jobs <N>                          Default jobs for sync steps
  --chunk <BYTES>                     Default chunk size for sync steps
  --coalesce-gap <BYTES>              Default coalesce gap for sync steps

  --base-args "<...>"                 Extra args appended to base sync (quoted string)
  --incr-args "<...>"                 Extra args appended to incr sync (quoted string)
  --cutover-args "<...>"              Extra args appended to cutover (quoted string)

Notes:
  - For Windows guests, run/auto will automatically add --winpe-bootstrap to cutover unless V2K_RUN_WINPE_BOOTSTRAP_AUTO=0.
  - run/auto orchestrates by calling existing v2k_cmd_* functions in engine.sh.
  - init args are passed as-is after pipeline options.
  - For complex quoting, prefer running discrete commands rather than arg-string.
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