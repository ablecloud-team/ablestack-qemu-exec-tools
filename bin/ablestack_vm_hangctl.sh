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

PROG="ablestack_vm_hangctl"
PROG_VERSION="0.0.0-dev"

EXIT_OK=0
EXIT_USAGE=2
EXIT_RUNTIME=10

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIBDIR="${REPO_ROOT}/lib/ablestack-qemu-exec-tools"

# CLI globals (commit 02)
CLI_CONFIG_PATH=""
CLI_POLICY=""
CLI_DRY_RUN="0"

_die_load() {
  echo "ERROR: $*" >&2
  exit "${EXIT_RUNTIME}"
}

_load_libs() {
  if [[ ! -d "${LIBDIR}" ]]; then
    _die_load "lib directory not found: ${LIBDIR}"
  fi
  # Load order is important.
  [[ -f "${LIBDIR}/hangctl/common.sh"  ]] || _die_load "missing: ${LIBDIR}/hangctl/common.sh"
  [[ -f "${LIBDIR}/hangctl/config.sh"  ]] || _die_load "missing: ${LIBDIR}/hangctl/config.sh"
  [[ -f "${LIBDIR}/hangctl/logging.sh" ]] || _die_load "missing: ${LIBDIR}/hangctl/logging.sh"
  [[ -f "${LIBDIR}/hangctl/libvirt_wrap.sh" ]] || _die_load "missing: ${LIBDIR}/hangctl/libvirt_wrap.sh"
  [[ -f "${LIBDIR}/hangctl/state_cache.sh" ]] || _die_load "missing: ${LIBDIR}/hangctl/state_cache.sh"
  [[ -f "${LIBDIR}/hangctl/detect.sh" ]] || _die_load "missing: ${LIBDIR}/hangctl/detect.sh"
  [[ -f "${LIBDIR}/hangctl/evidence.sh" ]] || _die_load "missing: ${LIBDIR}/hangctl/evidence.sh"
  [[ -f "${LIBDIR}/hangctl/actions.sh" ]] || _die_load "missing: ${LIBDIR}/hangctl/actions.sh"

  # shellcheck source=/dev/null
  source "${LIBDIR}/hangctl/common.sh"
  # shellcheck source=/dev/null
  source "${LIBDIR}/hangctl/config.sh"
  # shellcheck source=/dev/null
  source "${LIBDIR}/hangctl/logging.sh"
  # shellcheck source=/dev/null
  source "${LIBDIR}/hangctl/libvirt_wrap.sh"
  # shellcheck source=/dev/null
  source "${LIBDIR}/hangctl/state_cache.sh"
  # shellcheck source=/dev/null
  source "${LIBDIR}/hangctl/detect.sh"
  # shellcheck source=/dev/null
  source "${LIBDIR}/hangctl/evidence.sh"
  # shellcheck source=/dev/null
  source "${LIBDIR}/hangctl/actions.sh"
}

usage() {
  cat <<'EOF'
Usage:
  ablestack_vm_hangctl <command> [options]

Commands:
  scan     Scan running VMs (detect/probe/action/verify)
  check    Check a single VM (detect/probe only; no actions)
  act      Act on a single VM (detect/probe then action if confirmed)
  health   Check libvirtd health only

Global options:
  -h, --help       Show help
  -V, --version    Show version
      --config     Config file path (default: /etc/ablestack/ablestack-vm-hangctl.conf)
      --policy     Policy name (default: default)
      --dry-run    Do not take actions (log only)
      --vm NAME               Limit to a single VM (recommended for prod validation)
      --include-regex REGEX   Include only matching VMs (bash regex; scan only)
      --exclude-regex REGEX   Exclude matching VMs (bash regex; scan only)

Examples:
  ablestack_vm_hangctl --help
  ablestack_vm_hangctl --version
  ablestack_vm_hangctl scan --dry-run
  ablestack_vm_hangctl check --vm i-2-1147-VM
  ablestack_vm_hangctl act --vm i-2-1147-VM
EOF
}

print_version() {
  echo "${PROG} ${PROG_VERSION}"
}

_not_implemented() {
  echo "NOT IMPLEMENTED: $*" >&2
  exit "${EXIT_RUNTIME}"
}
 
hangctl_apply_target_filters() {
  # usage: hangctl_apply_target_filters <in_array_name> <out_array_name>
  local -n _in="${1}"
  local -n _out="${2}"
  _out=()

  if [[ -n "${HANGCTL_TARGET_VM-}" ]]; then
    local found="0" v
    for v in "${_in[@]}"; do
      if [[ "${v}" == "${HANGCTL_TARGET_VM}" ]]; then found="1"; break; fi
    done
    if [[ "${found}" != "1" ]]; then
      return 3
    fi
    _out=("${HANGCTL_TARGET_VM}")
    return 0
  fi

  local inc="${HANGCTL_INCLUDE_REGEX-}"
  local exc="${HANGCTL_EXCLUDE_REGEX-}"
  local vm
  for vm in "${_in[@]}"; do
    if [[ -n "${inc}" ]] && ! [[ "${vm}" =~ ${inc} ]]; then
      continue
    fi
    if [[ -n "${exc}" ]] && [[ "${vm}" =~ ${exc} ]]; then
      continue
    fi
    _out+=("${vm}")
  done
  return 0
}

hangctl_detect_probe_maybe_act_one_vm() {
  # usage:
  #   hangctl_detect_probe_maybe_act_one_vm <vm> <do_action:0|1>
  local vm="${1-}"
  local do_action="${2-0}"

  local dom_out dom_err dom_rc
  dom_out=""; dom_err=""; dom_rc=0

  hangctl_virsh "${HANGCTL_VIRSH_TIMEOUT_SEC}" dom_out dom_err dom_rc -- -c qemu:///system domstate "${vm}" || true
  local dom_result
  dom_result="$(hangctl__result_from_rc "${dom_rc}")"
  if [[ "${dom_result}" != "ok" ]]; then
    local err_short="${dom_err:0:200}"
    hangctl_log_event "detect" "vm.domstate" "${dom_result}" "${vm}" "" "${dom_rc}" \
      "timeout_sec=${HANGCTL_VIRSH_TIMEOUT_SEC} err_url=${err_short// /%20}"
    return 0
  fi

  local domstate
  domstate="$(echo "${dom_out}" | head -n 1 | tr -d '\r' | xargs)"
  [[ -z "${domstate}" ]] && domstate="unknown"

  hangctl_state_update_domstate "${vm}" "${domstate}"
  local stuck_sec
  stuck_sec="$(hangctl_state_get_stuck_sec "${vm}")"

  local decision="clear"
  if [[ "${stuck_sec}" -ge "${HANGCTL_CONFIRM_WINDOW_SEC}" ]]; then
    decision="suspect"
  fi

  hangctl_log_event "detect" "vm.domstate" "ok" "${vm}" "" "" \
    "domstate=${domstate} stuck_sec=${stuck_sec} decision=${decision} confirm_window=${HANGCTL_CONFIRM_WINDOW_SEC}"

  if [[ "${decision}" != "suspect" ]]; then
    hangctl_log_event "detect" "vm.decision" "ok" "${vm}" "" "" \
      "final=clear reason=domstate_not_stuck domstate=${domstate} stuck_sec=${stuck_sec}"
    return 0
  fi

  local qmp_status qmp_rc qmp_result
  qmp_status=""; qmp_rc=0
  hangctl_probe_qmp_query_status "${vm}" qmp_status qmp_rc || true
  qmp_result="$(hangctl__result_from_rc "${qmp_rc}")"

  local has_qga qga_rc qga_result
  has_qga="unknown"; qga_rc=0
  hangctl_probe_qga_ping_optional "${vm}" has_qga qga_rc || true
  qga_result="$(hangctl__result_from_rc "${qga_rc}")"

  local final_decision="suspect"
  local confirm_reason="domstate_stuck"
  local qmp_status_lc
  qmp_status_lc="$(echo "${qmp_status}" | tr '[:upper:]' '[:lower:]' | xargs)"
  if [[ "${qmp_result}" != "ok" ]]; then
    final_decision="confirmed"
    confirm_reason="qmp_${qmp_result}"
  elif [[ "${qmp_status_lc}" == "paused" ]]; then
    final_decision="confirmed"
    confirm_reason="qmp_status_paused"
  elif [[ "${qmp_status_lc}" == "inmigrate" ]]; then
    final_decision="confirmed"
    confirm_reason="qmp_status_inmigrate"
  fi

  hangctl_log_event "detect" "vm.decision" "ok" "${vm}" "" "" \
    "final=${final_decision} reason=${confirm_reason} domstate=${domstate} stuck_sec=${stuck_sec} confirm_window=${HANGCTL_CONFIRM_WINDOW_SEC} qmp_result=${qmp_result} qmp_rc=${qmp_rc} qmp_status=${qmp_status} has_qga=${has_qga} qga_result=${qga_result} qga_rc=${qga_rc}"

  if [[ "${do_action}" == "1" && "${final_decision}" == "confirmed" ]]; then
    hangctl_action_handle_confirmed_vm "${vm}" "${confirm_reason}" "${domstate}" "${stuck_sec}" "${qmp_status}" || true
  fi
}

cmd_scan() {
  # Commit 02 scope:
  # - load config
  # - ensure runtime dirs
  # - emit stub scan lifecycle events
  local cfg="" pol="" dry="${CLI_DRY_RUN}"
  local target_vm="" include_re="" exclude_re=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        cfg="${2-}"
        shift 2
        ;;
      --policy)
        pol="${2-}"
        shift 2
        ;;
      --dry-run)
        dry="1"
        shift
        ;;
      --vm)
        target_vm="${2-}"
        shift 2
        ;;
      --include-regex)
        include_re="${2-}"
        shift 2
        ;;
      --exclude-regex)
        exclude_re="${2-}"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "ERROR: unknown option for scan: $1" >&2
        usage >&2
        exit "${EXIT_USAGE}"
        ;;
      *)
        # ignore positional args for now
        shift
        ;;
    esac
  done

  hangctl_config_init_defaults
  # config load first (base)
  hangctl_config_load_file "${HANGCTL_CONFIG_PATH}"
  # CLI overrides last (highest precedence)
  hangctl_config_apply_cli "${cfg}" "${pol}" "${dry}"

  # Commit 08.1: CLI overrides for filters
  [[ -n "${target_vm}" ]] && HANGCTL_TARGET_VM="${target_vm}"
  [[ -n "${include_re}" ]] && HANGCTL_INCLUDE_REGEX="${include_re}"
  [[ -n "${exclude_re}" ]] && HANGCTL_EXCLUDE_REGEX="${exclude_re}"

  hangctl_ensure_runtime_dirs
  hangctl_lock_acquire_or_exit

  local scan_id
  scan_id="$(hangctl_new_scan_id)"
  hangctl_set_scan_id "${scan_id}"
  hangctl_log_event "scan" "scan.start" "ok" "" "" "" \
    "policy=${HANGCTL_POLICY} dry_run=${HANGCTL_DRY_RUN} config=${HANGCTL_CONFIG_PATH}"

  # -------------------------------------------------------------------
  # Commit 10: Circuit breaker + safe restart
  # - Trigger: consecutive failures (default 2)
  # - Cooldown: restart storm protection
  # -------------------------------------------------------------------
  if ! hangctl_libvirtd_health_gate "scan"; then
    hangctl_log_event "scan" "scan.end" "warn" "" "" "" \
      "policy=${HANGCTL_POLICY} dry_run=${HANGCTL_DRY_RUN} branch=libvirtd_unhealthy"
    exit 0
  fi

  # -------------------------------------------------------------------
  # Collect target running VMs (names) for this scan
  # -------------------------------------------------------------------
  local out err
  local vm_count
  vm_count=0
  # Keep vm list in-memory for next commits (state cache / probing).
  # In commit 05.1 we only collect it and log count.
  local -a vm_array
  vm_array=()

  rc=0
  # We need the stdout to count VMs, so run virsh wrapper and log a separate event with count.
  hangctl_virsh "${HANGCTL_VIRSH_TIMEOUT_SEC}" out err rc -- -c qemu:///system list --state-running --name || true
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    local err_short2="${err:0:200}"
    hangctl_log_event "scan" "scan.targets" "${result}" "" "" "${rc}" \
      "timeout_sec=${HANGCTL_VIRSH_TIMEOUT_SEC} err_url=${err_short2// /%20}"
    hangctl_log_event "scan" "scan.end" "warn" "" "" "" \
      "policy=${HANGCTL_POLICY} dry_run=${HANGCTL_DRY_RUN} branch=targets_failed"
    exit 0
  fi

  # Normalize list: remove empty lines
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    vm_array+=("${line}")
  done <<< "${out}"
  vm_count="${#vm_array[@]}"

  # Commit 08.1: apply filters
  local -a vm_filtered
  vm_filtered=()
  if ! hangctl_apply_target_filters vm_array vm_filtered; then
    if [[ -n "${HANGCTL_TARGET_VM-}" ]]; then
      hangctl_log_event "scan" "scan.targets" "warn" "" "" "" "running=0 filter_vm=${HANGCTL_TARGET_VM}"
      hangctl_log_event "scan" "scan.end" "warn" "" "" "" \
        "policy=${HANGCTL_POLICY} dry_run=${HANGCTL_DRY_RUN} branch=target_vm_not_running filter_vm=${HANGCTL_TARGET_VM}"
      exit 0
    fi
  fi
  vm_array=("${vm_filtered[@]}")
  vm_count="${#vm_array[@]}"

  local inc_url exc_url
  inc_url="${HANGCTL_INCLUDE_REGEX-}"; inc_url="${inc_url// /%20}"
  exc_url="${HANGCTL_EXCLUDE_REGEX-}"; exc_url="${exc_url// /%20}"
  if [[ -n "${HANGCTL_TARGET_VM-}" ]]; then
    hangctl_log_event "scan" "scan.targets" "ok" "" "" "" "running=${vm_count} filter_vm=${HANGCTL_TARGET_VM}"
  elif [[ -n "${HANGCTL_INCLUDE_REGEX-}" || -n "${HANGCTL_EXCLUDE_REGEX-}" ]]; then
    hangctl_log_event "scan" "scan.targets" "ok" "" "" "" "running=${vm_count} include_re_url=${inc_url} exclude_re_url=${exc_url}"
  else
    hangctl_log_event "scan" "scan.targets" "ok" "" "" "" "running=${vm_count}"
  fi

  # -------------------------------------------------------------------
  # Commit 06: domstate cache + stuck estimation (confirm_window based)
  # - For each running VM:
  #   - virsh domstate (timeout controlled)
  #   - update cache (last_state, last_change_ts)
  #   - compute stuck_sec
  #   - log vm.domstate (+ basic suspect/clear)
  # -------------------------------------------------------------------
  local vm
  for vm in "${vm_array[@]}"; do
    hangctl_detect_probe_maybe_act_one_vm "${vm}" "1"
  done

  # Commit 06 scope ends here: no further VM probing yet (QMP/QGA later).
  hangctl_log_event "scan" "scan.end" "ok" "" "" "" \
    "policy=${HANGCTL_POLICY} dry_run=${HANGCTL_DRY_RUN} running=${vm_count}"
}

cmd_check()  {
  local cfg="" pol="" dry="${CLI_DRY_RUN}"
  local vm=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) cfg="${2-}"; shift 2 ;;
      --policy) pol="${2-}"; shift 2 ;;
      --dry-run) dry="1"; shift ;;
      --vm) vm="${2-}"; shift 2 ;;
      --) shift; break ;;
      -*) echo "ERROR: unknown option for check: $1" >&2; usage >&2; exit "${EXIT_USAGE}" ;;
      *) shift ;;
    esac
  done
  if [[ -z "${vm}" ]]; then
    echo "ERROR: check requires --vm NAME" >&2
    exit "${EXIT_USAGE}"
  fi

  hangctl_config_init_defaults
  hangctl_config_load_file "${HANGCTL_CONFIG_PATH}"
  hangctl_config_apply_cli "${cfg}" "${pol}" "${dry}"
  hangctl_ensure_runtime_dirs
  hangctl_lock_acquire_or_exit

  local scan_id
  scan_id="$(hangctl_new_scan_id)"
  hangctl_set_scan_id "${scan_id}"
  hangctl_log_event "check" "check.start" "ok" "${vm}" "" "" \
    "policy=${HANGCTL_POLICY} dry_run=${HANGCTL_DRY_RUN} config=${HANGCTL_CONFIG_PATH}"

  # health gate
  local rc=0
  hangctl_virsh_event "check" "libvirtd.health" "${HANGCTL_VIRSH_TIMEOUT_SEC}" -- -c qemu:///system list --name || rc=$?
  local result
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    hangctl_log_event "check" "check.end" "warn" "${vm}" "" "" "branch=libvirtd_unhealthy"
    exit 0
  fi

  hangctl_detect_probe_maybe_act_one_vm "${vm}" "0"
  hangctl_log_event "check" "check.end" "ok" "${vm}" "" "" "done=1"
}

cmd_act()    {
  local cfg="" pol="" dry="${CLI_DRY_RUN}"
  local vm=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) cfg="${2-}"; shift 2 ;;
      --policy) pol="${2-}"; shift 2 ;;
      --dry-run) dry="1"; shift ;;
      --vm) vm="${2-}"; shift 2 ;;
      --) shift; break ;;
      -*) echo "ERROR: unknown option for act: $1" >&2; usage >&2; exit "${EXIT_USAGE}" ;;
      *) shift ;;
    esac
  done
  if [[ -z "${vm}" ]]; then
    echo "ERROR: act requires --vm NAME" >&2
    exit "${EXIT_USAGE}"
  fi

  hangctl_config_init_defaults
  hangctl_config_load_file "${HANGCTL_CONFIG_PATH}"
  hangctl_config_apply_cli "${cfg}" "${pol}" "${dry}"
  hangctl_ensure_runtime_dirs
  hangctl_lock_acquire_or_exit

  local scan_id
  scan_id="$(hangctl_new_scan_id)"
  hangctl_set_scan_id "${scan_id}"
  hangctl_log_event "act" "act.start" "ok" "${vm}" "" "" \
    "policy=${HANGCTL_POLICY} dry_run=${HANGCTL_DRY_RUN} config=${HANGCTL_CONFIG_PATH}"

  local rc=0
  hangctl_virsh_event "act" "libvirtd.health" "${HANGCTL_VIRSH_TIMEOUT_SEC}" -- -c qemu:///system list --name || rc=$?
  local result
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    hangctl_log_event "act" "act.end" "warn" "${vm}" "" "" "branch=libvirtd_unhealthy"
    exit 0
  fi

  hangctl_detect_probe_maybe_act_one_vm "${vm}" "1"
  hangctl_log_event "act" "act.end" "ok" "${vm}" "" "" "done=1"
}

cmd_health() {
  local cfg="" dry="${CLI_DRY_RUN}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) cfg="${2-}"; shift 2 ;;
      --dry-run) dry="1"; shift ;; # 의미는 없지만 글로벌 옵션 일관성 유지
      --) shift; break ;;
      -*) echo "ERROR: unknown option for health: $1" >&2; usage >&2; exit "${EXIT_USAGE}" ;;
      *) shift ;;
    esac
  done

  hangctl_config_init_defaults
  hangctl_config_load_file "${HANGCTL_CONFIG_PATH}"
  hangctl_config_apply_cli "${cfg}" "" "${dry}"
  hangctl_ensure_runtime_dirs
  hangctl_lock_acquire_or_exit

  local scan_id
  scan_id="$(hangctl_new_scan_id)"
  hangctl_set_scan_id "${scan_id}"
  hangctl_log_event "health" "health.start" "ok" "" "" "" \
    "config=${HANGCTL_CONFIG_PATH}"

  # health command: check only (no restart)
  local out err rc
  out=""; err=""; rc=0
  hangctl_libvirtd_health_check_raw "${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC}" out err rc
  local result
  result="$(hangctl__result_from_rc "${rc}")"
  local fc
  if [[ "${result}" == "ok" ]]; then
    hangctl_libvirtd_failcount_set 0
    fc="0"
    hangctl_log_event "health" "libvirtd.health" "ok" "" "" 0 \
      "timeout_sec=${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC} fail_count=${fc}"
    hangctl_log_event "health" "health.end" "ok" "" "" 0 "result=ok"
    echo "libvirtd.health: ok"
    return 0
  fi
  fc="$(hangctl_libvirtd_failcount_inc)"
  hangctl_log_event "health" "libvirtd.health" "${result}" "" "" "${rc}" \
    "timeout_sec=${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC} fail_count=${fc}"
  hangctl_log_event "health" "health.end" "fail" "" "" "${rc}" "result=${result}"
  echo "libvirtd.health: ${result}"
  exit "${EXIT_RUNTIME}"
}
 
main() {
  _load_libs

  if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    usage
    exit "${EXIT_OK}"
  fi
  if [[ "${1-}" == "-V" || "${1-}" == "--version" ]]; then
    print_version
    exit "${EXIT_OK}"
  fi

  local cmd="${1-}"
  if [[ -z "${cmd}" ]]; then
    usage >&2
    exit "${EXIT_USAGE}"
  fi
  shift || true

  case "${cmd}" in
    scan)   cmd_scan "$@" ;;
    check)  cmd_check "$@" ;;
    act)    cmd_act "$@" ;;
    health) cmd_health "$@" ;;
    -h|--help) usage; exit "${EXIT_OK}" ;;
    -V|--version) print_version; exit "${EXIT_OK}" ;;
    *)
      echo "ERROR: unknown command: ${cmd}" >&2
      usage >&2
      exit "${EXIT_USAGE}"
      ;;
  esac
}

main "$@"
