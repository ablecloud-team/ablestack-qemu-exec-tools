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

source_n2k_lib() {
  local name="$1"
  local installed="${ROOT_DIR}/lib/ablestack-qemu-exec-tools/n2k/${name}"
  local source_tree="${ROOT_DIR}/lib/n2k/${name}"
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
  echo "Missing n2k library: ${name}" >&2
  exit 2
}

usage() {
  cat <<'EOF'
ablestack_n2k - Nutanix AHV -> ABLESTACK(KVM) migration tool

Usage:
  ablestack_n2k [global options] <command> [command options]
  ablestack_n2k <command> --help

Global options:
  --workdir <path>        Work directory
  --run-id <id>           Run identifier
  --manifest <path>       Manifest path
  --log <path>            Events log path
  --json                  Emit machine-readable JSON output
  --dry-run               Plan without destructive actions
  --resume                Resume from an existing manifest
  --force                 Allow risky operations
  -h, --help              Show help

Commands:
  preflight               Check Nutanix/API/target host capabilities
  plan                    Build a migration plan for a VM
  run (alias: auto)       Run the migration pipeline
  init                    Initialize workdir and manifest
  snapshot                Create or select a source snapshot/recovery point
  sync                    Data sync: base|incr|final
  verify                  Verify migration state and target data
  cutover                 Final sync and target VM define/start
  cleanup                 Clean temporary migration resources
  status                  Show migration status
EOF
}

usage_preflight() {
  cat <<'EOF'
Usage:
  ablestack_n2k preflight --pc <host> [options]

Options:
  --pc <host>             Prism Central host
  --username <user>       Prism Central username
  --password <pass>       Prism Central password
  --cred-file <file>      Credential file
  --insecure <0|1>        Skip TLS verification when set to 1
  --mode <mode>           auto|v4-incremental|legacy-cbt|cold-export|manual-disk
  --capability-json <js>  Capability JSON string or file path
  --v4-vmm <0|1>          Override v4 vmm capability
  --v4-dataprotection <0|1>
                           Override v4 dataprotection capability
  --legacy-changed-regions <0|1>
                           Override legacy changed-region capability
  --legacy-endpoint-verified <0|1>
                           Override legacy endpoint verification
  --cold-export-available <0|1>
                           Override cold export availability
  --manual-disk-available <0|1>
                           Override manual disk availability
  --allow-experimental    Allow experimental legacy paths

Notes:
  - This command will check API family, namespace, and target host capabilities.
  - Direct Nutanix API probing is planned for the inventory/API phases.
EOF
}

usage_plan() {
  cat <<'EOF'
Usage:
  ablestack_n2k plan --vm <name|uuid> --pc <host> [options]

Options:
  --vm <name|uuid>        Source Nutanix VM
  --pc <host>             Prism Central host
  --cred-file <file>      Credential file
  --mode <mode>           auto|v4-incremental|legacy-cbt|cold-export|manual-disk
  --capability-json <js>  Capability JSON string or file path
  --v4-vmm <0|1>          Override v4 vmm capability
  --v4-dataprotection <0|1>
                           Override v4 dataprotection capability
  --legacy-changed-regions <0|1>
                           Override legacy changed-region capability
  --legacy-endpoint-verified <0|1>
                           Override legacy endpoint verification
  --cold-export-available <0|1>
                           Override cold export availability
  --manual-disk-available <0|1>
                           Override manual disk availability
  --allow-experimental    Allow experimental legacy paths

Notes:
  - This command will produce a VM-specific migration plan.
  - Direct Nutanix API inventory lookup is planned in development phase 4.
EOF
}

usage_run() {
  cat <<'EOF'
Usage:
  ablestack_n2k run --vm <name|uuid> --pc <host> [options]
  ablestack_n2k auto --vm <name|uuid> --pc <host> [options]

Options:
  --vm <name|uuid>        Source Nutanix VM
  --pc <host>             Prism Central host
  --cred-file <file>      Credential file
  --mode <mode>           auto|v4-incremental|legacy-cbt|cold-export|manual-disk
  --dst <path>            Destination root
  --target-format <fmt>   qcow2|raw
  --target-storage <type> file|block|rbd
  --target-map-json <js>  Per-disk target map
  --allow-experimental    Allow experimental legacy paths

Notes:
  - With global --resume, this command prints the manifest-based resume plan.
  - Full orchestration is planned after preflight, manifest, and transfer layers.
EOF
}

usage_init() {
  cat <<'EOF'
Usage:
  ablestack_n2k init --vm <name|uuid> --pc <host> --dst <path> [options]

Options:
  --vm <name|uuid>        Source Nutanix VM
  --pc <host>             Prism Central host
  --cred-file <file>      Credential file
  --username <user>       Prism Central username
  --password <pass>       Prism Central password
  --insecure <0|1>        Skip TLS verification when set to 1
  --dst <path>            Destination root
  --mode <mode>           auto|v4-incremental|legacy-cbt|cold-export|manual-disk
  --inventory-json <json> Normalized or raw VM inventory JSON
  --inventory-file <file> Normalized or raw VM inventory JSON file
  --inventory-source <s>  none|fixture|api
  --target-format <fmt>   qcow2|raw
  --target-storage <type> file|block|rbd
  --target-map-json <js>  Per-disk target map

Notes:
  - This command creates the initial n2k manifest.
  - Direct API inventory lookup runs only with --inventory-source api.
EOF
}

usage_snapshot() {
  cat <<'EOF'
Usage:
  ablestack_n2k snapshot base|incr|final [options]

Options:
  --name <name>           Snapshot or recovery point name

Notes:
  - Nutanix snapshot/recovery point support is planned in later phases.
EOF
}

usage_sync() {
  cat <<'EOF'
Usage:
  ablestack_n2k sync base|incr|final [options]

Options:
  --jobs <N>              Parallel job count
  --chunk <bytes>         Transfer chunk size
  --coalesce-gap <bytes>  Changed-region coalesce gap
  --source-map-json <js>  Cold-export source map JSON
  --source-map-file <file>
                           Cold-export source map JSON file
  --changed-regions-json <js>
                           Changed-region JSON for incr/final sync
  --changed-regions-file <file>
                           Changed-region JSON file for incr/final sync
  --recovery-point-id <id>
                           Recovery point identifier for manifest recording

Notes:
  - base sync supports cold-export/manual-disk source maps.
  - incr/final sync currently supports raw file or block targets.
EOF
}

usage_verify() {
  cat <<'EOF'
Usage:
  ablestack_n2k verify [options]

Options:
  --mode <mode>           quick|full
  --samples <N>           Sample count for quick verification

Notes:
  - Verification support is planned after manifest and transfer layers.
EOF
}

usage_cutover() {
  cat <<'EOF'
Usage:
  ablestack_n2k cutover [options]

Options:
  --shutdown <policy>     manual|guest|poweroff
  --define-only           Define target VM without starting it
  --apply                 Run virsh define for the generated XML
  --start                 Start target VM after definition

Notes:
  - Without --apply, this command only generates the libvirt XML artifact.
EOF
}

usage_cleanup() {
  cat <<'EOF'
Usage:
  ablestack_n2k cleanup [options]

Options:
  --keep-source-points    Keep source snapshots or recovery points
  --keep-workdir          Keep local workdir
  --remove-source-points  Remove recorded source points, requires global --force
  --remove-workdir        Remove empty workdir entries, requires global --force
  --apply                 Apply the cleanup plan

Notes:
  - Without --apply, this command only prints the cleanup plan.
  - Cleanup only removes resources recorded in the manifest.
EOF
}

usage_status() {
  cat <<'EOF'
Usage:
  ablestack_n2k status [options]

Options:
  --vm <name|uuid>        Show latest run status for a VM
  --watch                 Refresh status output
  --resume-plan           Show only the next resumable step

Notes:
  - This command reads the current manifest and prints a status summary.
EOF
}

usage_command() {
  local cmd="${1:-}"
  case "${cmd}" in
    preflight) usage_preflight ;;
    plan) usage_plan ;;
    run|auto) usage_run ;;
    init) usage_init ;;
    snapshot) usage_snapshot ;;
    sync) usage_sync ;;
    verify) usage_verify ;;
    cutover) usage_cutover ;;
    cleanup) usage_cleanup ;;
    status) usage_status ;;
    *) usage ;;
  esac
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

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
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --log) EVENTS_LOG="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift 1 ;;
    --dry-run) DRY_RUN=1; shift 1 ;;
    --resume) RESUME=1; shift 1 ;;
    --force) FORCE=1; shift 1 ;;
    -h|--help) usage; exit 0 ;;
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
shifted_args=()
if [[ ${#ARGS[@]} -gt 1 ]]; then
  shifted_args=("${ARGS[@]:1}")
fi

if [[ ${#shifted_args[@]} -gt 0 ]]; then
  case "${shifted_args[0]}" in
    -h|--help)
      usage_command "${CMD}"
      exit 0
      ;;
  esac
fi

export N2K_ROOT_DIR="${ROOT_DIR}"
export N2K_WORKDIR="${WORKDIR}"
export N2K_RUN_ID="${RUN_ID}"
export N2K_MANIFEST="${MANIFEST}"
export N2K_EVENTS_LOG="${EVENTS_LOG}"
export N2K_JSON_OUT="${JSON_OUT}"
export N2K_DRY_RUN="${DRY_RUN}"
export N2K_RESUME="${RESUME}"
export N2K_FORCE="${FORCE}"

source_n2k_lib engine.sh

n2k_call_command() {
  local fn="$1"
  if [[ ${#shifted_args[@]} -gt 0 ]]; then
    "${fn}" "${shifted_args[@]}"
  else
    "${fn}"
  fi
}

case "${CMD}" in
  preflight) n2k_call_command n2k_cmd_preflight ;;
  plan) n2k_call_command n2k_cmd_plan ;;
  run|auto) n2k_call_command n2k_cmd_run ;;
  init) n2k_call_command n2k_cmd_init ;;
  snapshot) n2k_call_command n2k_cmd_snapshot ;;
  sync) n2k_call_command n2k_cmd_sync ;;
  verify) n2k_call_command n2k_cmd_verify ;;
  cutover) n2k_call_command n2k_cmd_cutover ;;
  cleanup) n2k_call_command n2k_cmd_cleanup ;;
  status) n2k_call_command n2k_cmd_status ;;
  *)
    die "Unknown command: ${CMD}"
    ;;
esac
