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

source_v2k_lib() {
  local name="$1"
  local installed="${ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/${name}"
  local source_tree="${ROOT_DIR}/lib/v2k/${name}"
  if [[ -f "${installed}" ]]; then
    # shellcheck source=/dev/null
    source "${installed}"
    return 0
  fi
  if [[ -f "${source_tree}" ]]; then
    # shellcheck source=/dev/null
    source "${source_tree}"
    return 0
  fi
  echo "Missing v2k library: ${name}" >&2
  exit 2
}

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

# Optional diagnostics
if [[ "${V2K_DEBUG_ENV:-0}" -eq 1 ]]; then
  echo "[DEBUG] V2K_COMPAT_ROOT='${V2K_COMPAT_ROOT-}'" >&2
  echo "[DEBUG] V2K_COMPAT_PROFILE='${V2K_COMPAT_PROFILE-}'" >&2
  echo "[DEBUG] V2K_COMPAT_SELECTED_PROFILE='${V2K_COMPAT_SELECTED_PROFILE-}'" >&2
  echo "[DEBUG] V2K_GOVC_BIN='${V2K_GOVC_BIN-}'" >&2
  echo "[DEBUG] V2K_PYTHON_BIN='${V2K_PYTHON_BIN-}'" >&2
  echo "[DEBUG] VDDK_LIBDIR='${VDDK_LIBDIR-}'" >&2
fi

usage() {
  cat <<'EOF'
ablestack_v2k - VMware -> ABLESTACK(KVM) minimal downtime migration tool (v1)

Usage:
  ablestack_v2k [global options] <command> [command options]
  ablestack_v2k <command> --help

Global options (all commands):
  --workdir <path>        Work directory (default: /var/lib/ablestack-v2k/<vm>/<run_id>)
  --run-id <id>           Run identifier (auto-generate if omitted)
  --manifest <path>       Manifest path (default: <workdir>/manifest.json)
  --log <path>            Events log path (default: <workdir>/events.log)
  --json                  Machine-readable JSON output (default: off)
  --dry-run               Do not execute destructive operations (default: off)
  --resume                Resume based on manifest (default: off)
  --force                 Force risky operations (default: off)
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

Examples:
  ablestack_v2k run --help
  ablestack_v2k init --help
  ablestack_v2k cbt --help
  ablestack_v2k cutover --help

Environment:
  GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD, GOVC_INSECURE
  VDDK_LIBDIR
  V2K_COMPAT_ROOT
  V2K_COMPAT_PROFILE
  V2K_COMPAT_SELECTED_PROFILE
  V2K_GOVC_BIN
  V2K_PYTHON_BIN
EOF
}

usage_run() {
  cat <<'EOF'
Usage:
  ablestack_v2k run [--foreground] [run options...]
  ablestack_v2k auto [--foreground] [run options...]

Required:
  --vm <name|moref>
  --vcenter <host>

Authentication:
  --cred-file <file>
  --vddk-cred-file <file>
  --username <user>
  --password <pass>
  --compat-profile <id|auto>   Compatibility profile (default: auto)
  --insecure <0|1>             GOVC insecure mode (default: 1)

Destination:
  --dst <path>                 Destination root (default: /var/lib/libvirt/images/<vm>)

Pipeline:
  --shutdown manual|guest|poweroff          Source shutdown policy (default: manual)
  --kvm-vm-policy none|define-only|define-and-start
                                            Target KVM policy (default: none)
  --incr-interval <sec>                     Incr loop interval (default: 10)
  --max-incr <N>                            Max incr loops (default: 6)
  --converge-threshold-sec <sec>            Convergence threshold (default: 120)
  --no-incr

Split-run:
  --split full|phase1|phase2                Split-run mode (default: full)
  --deadline-sec <sec>                      Phase2 deadline window (default: 120)
  --max-incr-phase2 <N>                     Phase2 incr cap (default: 20)

Sync defaults:
  --jobs <N>
  --chunk <BYTES>
  --coalesce-gap <BYTES>

Extra args:
  --base-args "<args>"
      Whitespace-split extra args for 'sync base'
      Example: --base-args "--jobs 4 --chunk 4194304"
  --incr-args "<args>"
      Whitespace-split extra args for 'sync incr'
      Example: --incr-args "--jobs 2 --coalesce-gap 65536"
  --cutover-args "<args>"
      Whitespace-split extra args for 'cutover'
      Example: --cutover-args "--define-only --bridge br0 --vcpu 4 --memory 8192"

Init-stage options:
  --mode govc                               Inventory mode (default: govc)
  --target-format qcow2|raw                 Target image format (default: qcow2)
  --target-storage file|block|rbd           Target storage type (default: file)
  --target-map-json <json>
      Required for block and rbd targets.
      block example: --target-map-json '{"scsi0:0":"/dev/sdb","scsi0:1":"/dev/sdc"}'
      rbd example:   --target-map-json '{"scsi0:0":"rbd:pool/vm-disk0","scsi0:1":"rbd:pool/vm-disk1"}'
  --force-block-device

Cleanup policy:
  --no-cleanup                              Skip cleanup (default: cleanup runs)
  --keep-snapshots                          Preserve migr-* snapshots (default: off)
  --keep-workdir                            Preserve workdir after cleanup (default: on)

Examples:
  ablestack_v2k run --vm my-vm --vcenter vc.example.local --cred-file ./govc.env
  ablestack_v2k run --vm my-vm --vcenter vc.example.local --cred-file ./govc.env --split phase1
  ablestack_v2k run --vm my-vm --vcenter vc.example.local --cred-file ./govc.env --target-storage rbd --target-map-json '{"scsi0:0":"rbd:pool/my-vm-disk0"}'
EOF
}

usage_init() {
  cat <<'EOF'
Usage:
  ablestack_v2k init --vm <name|moref> --vcenter <host> --dst <path> [options...]

Options:
  --mode govc                               Inventory mode (default: govc)
  --cred-file <file>
  --vddk-cred-file <file>
  --compat-profile <id|auto>   Compatibility profile (default: auto)
  --target-format qcow2|raw                 Target image format (default: qcow2)
  --target-storage file|block|rbd           Target storage type (default: file)
  --target-map-json <json>
      block example: '{"scsi0:0":"/dev/sdb","scsi0:1":"/dev/sdc"}'
      rbd example:   '{"scsi0:0":"rbd:pool/vm-disk0","scsi0:1":"rbd:pool/vm-disk1"}'
  --force-block-device

Notes:
  - If only --cred-file is provided, init auto-generates workdir/vddk.cred.
  - Compatibility selection is stored in manifest.json and compat.env.

Examples:
  ablestack_v2k init --vm my-vm --vcenter vc.example.local --cred-file ./govc.env --dst /var/lib/libvirt/images/my-vm
  ablestack_v2k init --vm my-vm --vcenter vc.example.local --cred-file ./govc.env --dst /data/migrate --target-storage block --target-map-json '{"scsi0:0":"/dev/sdb"}'
EOF
}

usage_cbt() {
  cat <<'EOF'
Usage:
  ablestack_v2k cbt enable
  ablestack_v2k cbt status

Notes:
  - Requires an existing workdir/manifest.
  - Restores govc.env automatically from the workdir.

Examples:
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> cbt status
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> cbt enable
EOF
}

usage_snapshot() {
  cat <<'EOF'
Usage:
  ablestack_v2k snapshot base|incr|final [options...]

Options:
  --name <snapshot-name>                    Default: migr-<base|incr|final>-<timestamp>
  --safe-mode                               Default: off

Examples:
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> snapshot base
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> snapshot incr --name migr-incr-manual
EOF
}

usage_sync() {
  cat <<'EOF'
Usage:
  ablestack_v2k sync base|incr|final [options...]

Options:
  --jobs <N>                                Default: 1
  --coalesce-gap <BYTES>                    Default: 65536
  --chunk <BYTES>                           Default: 4194304
  --force-cleanup                           Default: off
  --safe-mode                               Default: off

Examples:
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> sync base --jobs 4
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> sync incr --jobs 2 --coalesce-gap 65536
EOF
}

usage_verify() {
  cat <<'EOF'
Usage:
  ablestack_v2k verify [options...]

Options:
  --mode quick                              Default: quick
  --samples <N>                             Default: 64

Examples:
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> verify
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> verify --mode quick --samples 128
EOF
}

usage_cutover() {
  cat <<'EOF'
Usage:
  ablestack_v2k cutover [options...]

Options:
  --shutdown manual|guest|poweroff          Default: guest
  --shutdown-force                          Hard poweroff fallback is enabled by default
  --shutdown-timeout <SEC>                  Default: 300
  --define-only                             Default: off
  --start                                   Default: auto when WinPE is skipped and --define-only is not set
  --vcpu <N>                                Default: source VM CPU, else 2
  --memory <MB>                             Default: source VM memory_mb, else 2048
  --network <name>                          Default: default
  --bridge <br>                             Default: auto-detect host bridge
  --vlan <id>                               Default: unset
  --winpe-bootstrap                         Default: on for Windows guests, auto-skip for non-Windows
  --no-winpe-bootstrap
  --winpe-iso <path>                        Default: /usr/share/ablestack/v2k/winpe.iso
  --virtio-iso <path>                       Default: /usr/share/virtio-win/virtio-win.iso
  --winpe-timeout <SEC>                     Default: 600
  --linux-bootstrap                         Default: auto for Linux guests
  --no-linux-bootstrap
  --safe-mode                               Default: off
  --force-cleanup                           Default: off

Notes:
  - Current libvirt XML generation uses VM inventory values for CPU/memory and source MAC plus auto-detected host bridge.
  - --vcpu, --memory, --network, --bridge, and --vlan are accepted by cutover but are not currently reflected in the generated XML.

Examples:
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> cutover --shutdown guest --define-only
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> cutover --shutdown poweroff --no-winpe-bootstrap --start
EOF
}

usage_cleanup() {
  cat <<'EOF'
Usage:
  ablestack_v2k cleanup [options...]

Options:
  --keep-snapshots                          Default: off
  --keep-workdir                            Default: off

Examples:
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> cleanup
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> cleanup --keep-snapshots --keep-workdir
EOF
}

usage_status() {
  cat <<'EOF'
Usage:
  ablestack_v2k status
  ablestack_v2k status --vm <name[,name...]>
  ablestack_v2k status --vm <name[,name...]> --watch

Notes:
  - Reads manifest.json and events.log from the selected workdir.
  - With --vm, fleet status mode scans the work root and shows the latest run per VM.
  - --watch is available only with fleet status mode and is off by default.

Examples:
  ablestack_v2k --workdir /var/lib/ablestack-v2k/my-vm/<run_id> status
  ablestack_v2k --workdir /var/lib/ablestack-v2k status --vm "my-vm"
  ablestack_v2k --workdir /var/lib/ablestack-v2k status --vm "vm-a,vm-b" --watch
EOF
}

usage_command() {
  local cmd="${1:-}"
  case "${cmd}" in
    run|auto) usage_run ;;
    init) usage_init ;;
    cbt) usage_cbt ;;
    snapshot) usage_snapshot ;;
    sync) usage_sync ;;
    verify) usage_verify ;;
    cutover) usage_cutover ;;
    cleanup) usage_cleanup ;;
    status) usage_status ;;
    *) usage ;;
  esac
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
    *)
      ARGS=("$@")
      break
      ;;
  esac
done

if [[ ${#ARGS[@]} -lt 1 ]]; then
  usage
  exit 2
fi

CMD="${ARGS[0]}"
shifted_args=("${ARGS[@]:1}")

if [[ ${#shifted_args[@]} -gt 0 ]]; then
  case "${shifted_args[0]}" in
    -h|--help)
      usage_command "${CMD}"
      exit 0
      ;;
  esac
fi

export V2K_JSON_OUT="${JSON_OUT}"
export V2K_DRY_RUN="${DRY_RUN}"
export V2K_RESUME="${RESUME}"
export V2K_FORCE="${FORCE}"

source_v2k_lib compat.sh
source_v2k_lib engine.sh
source_v2k_lib logging.sh
source_v2k_lib manifest.sh
source_v2k_lib orchestrator.sh
source_v2k_lib fleet.sh

v2k_compat_bootstrap_env "" "" || true
v2k_resolve_vddk_libdir

v2k_set_paths \
  "${WORKDIR}" \
  "${RUN_ID}" \
  "${MANIFEST}" \
  "${EVENTS_LOG}"

v2k_compat_bootstrap_env "${V2K_MANIFEST:-}" "${V2K_WORKDIR:-}" || true
v2k_resolve_vddk_libdir

# [NEW] Ensure NBD module is loaded (Auto-recovery after reboot)
if ! lsmod | grep -q "^nbd"; then
    v2k_event INFO "linux_bootstrap" "" "loading_nbd_module" "{}"
    if modprobe nbd max_part=16 >/dev/null 2>&1; then
      udevadm settle >/dev/null 2>&1 || true
    else
      v2k_event WARN "linux_bootstrap" "" "nbd_module_load_failed" "{\"note\":\"continuing; commands that require nbd may fail later\"}"
    fi
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
