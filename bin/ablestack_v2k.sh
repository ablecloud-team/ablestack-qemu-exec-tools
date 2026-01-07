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

Commands:
  init --vm <name|moref> --vcenter <host> --dst <path> [--mode govc] [--cred-file <file>] \
       [--target-format qcow2|raw] [--target-storage file|block] [--target-map-json <json>]
  cbt enable|status
  snapshot base|incr|final [--name <snapname>]
  sync base|incr|final [--jobs N] [--coalesce-gap BYTES] [--chunk BYTES]
  verify [--mode quick] [--samples N]
  cutover [--shutdown guest|manual] [--define-only] [--start]
  cleanup [--keep-snapshots] [--keep-workdir]
  status

Notes:
  - VMware integration priority is govc. Changed areas query uses pyvmomi helper (python3 + pyvmomi).
  - Target override options set V2K_TARGET_* internally for this run (no need to export env vars).
  - Final default: shutdown -> final snapshot -> final sync (as approved).
EOF
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

# Resolve workdir/manifest/log lazily (init may generate)
v2k_set_paths \
  "${WORKDIR}" \
  "${RUN_ID}" \
  "${MANIFEST}" \
  "${EVENTS_LOG}"

case "${CMD}" in
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
    v2k_cmd_status "${shifted_args[@]}"
    ;;
  *)
    echo "Unknown command: ${CMD}" >&2
    usage
    exit 2
    ;;
esac
