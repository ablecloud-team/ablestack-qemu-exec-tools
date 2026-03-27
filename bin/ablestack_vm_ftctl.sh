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

PROG="ablestack_vm_ftctl"
PROG_VERSION="0.1.0-skeleton"

EXIT_OK=0
EXIT_USAGE=2
EXIT_RUNTIME=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLI_COMMAND=""
CLI_VM=""
CLI_MODE=""
CLI_PEER=""
CLI_PROFILE=""
CLI_CONFIG_PATH=""
CLI_POLICY=""
CLI_DRY_RUN=""
CLI_JSON="0"
CLI_FORCE="0"

FTCTL_LIB_BASE=""

ftctl_die_load() {
  echo "ERROR: $*" >&2
  exit "${EXIT_RUNTIME}"
}

ftctl_resolve_lib_base() {
  local candidates=(
    "${ROOT_DIR}/lib"
    "${ROOT_DIR}/lib/ablestack-qemu-exec-tools"
    "/usr/local/lib/ablestack-qemu-exec-tools"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "${c}/ftctl" ]]; then
      FTCTL_LIB_BASE="${c}"
      return 0
    fi
  done
  ftctl_die_load "ftctl library directory not found"
}

ftctl_load_libs() {
  ftctl_resolve_lib_base

  local req=(
    common.sh
    config.sh
    logging.sh
    libvirt_wrap.sh
    state.sh
    profile.sh
    inventory.sh
    blockcopy.sh
    xcolo.sh
    fencing.sh
    failover.sh
    verify.sh
    orchestrator.sh
  )
  local f
  for f in "${req[@]}"; do
    [[ -f "${FTCTL_LIB_BASE}/ftctl/${f}" ]] || ftctl_die_load "missing: ${FTCTL_LIB_BASE}/ftctl/${f}"
  done

  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/common.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/config.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/logging.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/libvirt_wrap.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/state.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/profile.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/inventory.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/blockcopy.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/xcolo.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/fencing.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/failover.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/verify.sh"
  # shellcheck source=/dev/null
  source "${FTCTL_LIB_BASE}/ftctl/orchestrator.sh"
}

usage() {
  cat <<'EOF'
Usage:
  ablestack_vm_ftctl <command> [options]

Commands:
  protect            Register protection intent for a VM
  status             Show current protection status
  reconcile          Keep or re-arm replication state
  failover           Start failover workflow
  failback           Start failback workflow
  pause-protection   Pause reconciliation for a VM
  resume-protection  Resume reconciliation for a VM
  check              Probe VM/profile/peer reachability
  health             Check local libvirt health only

Global options:
  -h, --help         Show help
  -V, --version      Show version
      --vm NAME      VM name
      --mode MODE    Protection mode: ha|dr|ft
      --peer URI     Peer libvirt URI
      --profile ID   Profile name
      --config PATH  Config file path
      --policy NAME  Policy name
      --dry-run      Do not perform actions
      --json         JSON output where supported
      --force        Acknowledge risky transition commands
EOF
}

print_version() {
  echo "${PROG} ${PROG_VERSION}"
}

parse_args() {
  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit "${EXIT_OK}"
        ;;
      -V|--version)
        print_version
        exit "${EXIT_OK}"
        ;;
      protect|status|reconcile|failover|failback|pause-protection|resume-protection|check|health)
        [[ -z "${CLI_COMMAND}" ]] || {
          echo "ERROR: multiple commands specified" >&2
          exit "${EXIT_USAGE}"
        }
        CLI_COMMAND="$1"
        shift
        ;;
      --vm)
        CLI_VM="${2-}"
        shift 2
        ;;
      --mode)
        CLI_MODE="${2-}"
        shift 2
        ;;
      --peer)
        CLI_PEER="${2-}"
        shift 2
        ;;
      --profile)
        CLI_PROFILE="${2-}"
        shift 2
        ;;
      --config)
        CLI_CONFIG_PATH="${2-}"
        shift 2
        ;;
      --policy)
        CLI_POLICY="${2-}"
        shift 2
        ;;
      --dry-run)
        CLI_DRY_RUN="1"
        shift
        ;;
      --json)
        CLI_JSON="1"
        shift
        ;;
      --force)
        CLI_FORCE="1"
        shift
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        exit "${EXIT_USAGE}"
        ;;
    esac
  done
}

apply_common_config() {
  ftctl_config_init_defaults
  ftctl_config_load_file "${FTCTL_CONFIG_PATH}"
  ftctl_config_apply_cli "${CLI_CONFIG_PATH}" "${CLI_POLICY}" "${CLI_DRY_RUN}"
  ftctl_config_load_file "${FTCTL_CONFIG_PATH}"
  ftctl_ensure_runtime_dirs
  ftctl_lock_acquire_or_exit
}

require_vm() {
  [[ -n "${CLI_VM}" ]] || {
    echo "ERROR: --vm is required" >&2
    exit "${EXIT_USAGE}"
  }
}

require_mode() {
  [[ -n "${CLI_MODE}" ]] || {
    echo "ERROR: --mode is required" >&2
    exit "${EXIT_USAGE}"
  }
}

dispatch() {
  case "${CLI_COMMAND}" in
    protect)
      require_vm
      require_mode
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_profile_apply_cli "${CLI_VM}" "${CLI_MODE}" "${CLI_PEER}" "${CLI_PROFILE}"
      ftctl_orchestrator_protect "${CLI_VM}"
      ;;
    status)
      if [[ -n "${CLI_VM}" ]]; then
        ftctl_profile_load_vm "${CLI_VM}"
      fi
      ftctl_state_print_status "${CLI_VM}" "${CLI_JSON}"
      ;;
    reconcile)
      ftctl_orchestrator_reconcile "${CLI_VM}" "${CLI_JSON}"
      ;;
    failover)
      require_vm
      [[ "${CLI_FORCE}" == "1" ]] || {
        echo "ERROR: failover requires --force in skeleton mode" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_failover_request "${CLI_VM}" "manual"
      ;;
    failback)
      require_vm
      [[ "${CLI_FORCE}" == "1" ]] || {
        echo "ERROR: failback requires --force in skeleton mode" >&2
        exit "${EXIT_USAGE}"
      }
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_failback_request "${CLI_VM}" "manual"
      ;;
    pause-protection)
      require_vm
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_state_pause_vm "${CLI_VM}"
      ;;
    resume-protection)
      require_vm
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_state_resume_vm "${CLI_VM}"
      ;;
    check)
      require_vm
      ftctl_profile_load_vm "${CLI_VM}"
      ftctl_orchestrator_check_vm "${CLI_VM}" "${CLI_JSON}"
      ;;
    health)
      ftctl_local_health "${CLI_JSON}"
      ;;
    "")
      usage
      exit "${EXIT_USAGE}"
      ;;
    *)
      echo "ERROR: unsupported command: ${CLI_COMMAND}" >&2
      exit "${EXIT_USAGE}"
      ;;
  esac
}

main() {
  parse_args "$@"
  ftctl_load_libs
  apply_common_config
  dispatch
}

main "$@"
