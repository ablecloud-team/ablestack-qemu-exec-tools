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
  [[ -f "${LIBDIR}/hangctl/storage_guard.sh" ]] || _die_load "missing: ${LIBDIR}/hangctl/storage_guard.sh"
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
  source "${LIBDIR}/hangctl/storage_guard.sh"
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
  #    hangctl_detect_probe_maybe_act_one_vm <vm> <do_action:0|1>
  local vm="${1-}"
  local do_action="${2-0}"

  # --- [단계 1] VM 상태 수집 및 초기 분석 ---
  local qmp_status qmp_rc qmp_result
  qmp_status=""; qmp_rc=0
  
  # QMP 프로토콜 실행
  hangctl_probe_qmp_query_status "${vm}" qmp_status qmp_rc || true
  qmp_result="$(hangctl__result_from_rc "${qmp_rc}")"

  # QMP 상태의 문법 규칙
  local qmp_status_lc
  qmp_status_lc="$(echo "${qmp_status}" | tr '[:upper:]' '[:lower:]' | xargs)"

  # 블록 I/O 계측 집계 Stall 감지
  local curr_rd=0 curr_wr=0
  hangctl_probe_blockstats "${vm}" curr_rd curr_wr || true
  
  local io_stall=1
  # 0이면 Stall 의심, 1이면 정상 (이전 스캔 시점과 비교)
  hangctl_detect_block_stall "${vm}" "${curr_rd}" "${curr_wr}" || io_stall=$?

  # virsh를 통한 도메인 상태 확인
  local dom_out dom_err dom_rc
  dom_out=""; dom_err=""; dom_rc=0
  hangctl_virsh "${HANGCTL_VIRSH_TIMEOUT_SEC}" dom_out dom_err dom_rc -- -c qemu:///system domstate --reason "${vm}" || true
  
  # 상태 문자열 파싱 (예: "paused (in-migration)")
  local domstate_full
  domstate_full="$(echo "${dom_out}" | head -n 1 | tr '[:upper:]' '[:lower:]' | xargs)"
  local domstate="${domstate_full%% *}" 
  [[ -z "${domstate}" ]] && domstate="unknown"

  # --- [단계 2] 시간 초기화에 따른 적적 결정 (I/O Stall 반영) ---
  if [[ "${qmp_rc}" == "0" && -n "${qmp_status_lc}" && "${qmp_status_lc}" != "unknown" && "${io_stall}" == "1" ]]; then
      hangctl_state_touch_heartbeat "${vm}"
      hangctl_log_event "detect" "vm.heartbeat" "ok" "${vm}" "" "" "reason=healthy status=${qmp_status_lc}"
  else
      # QMP 응답 실패 또는 Stall 감지 시 기존 heartbeat 타임스탬프 확인
      local existing_ts
      existing_ts="$(hangctl_state__read_kv "$(hangctl_state__path "${vm}")" "last_change_ts" || true)"
      
      local fail_type="qmp_issue"
      [[ "${io_stall}" == "0" ]] && fail_type="io_stall_detected"

      if [[ -z "${existing_ts}" ]]; then
          hangctl_state_touch_heartbeat "${vm}"
          hangctl_log_event "detect" "vm.heartbeat" "warn" "${vm}" "" "" "reason=failure_start_detected type=${fail_type}"
      else
          hangctl_log_event "detect" "vm.heartbeat" "warn" "${vm}" "" "" "reason=failure_continuing type=${fail_type} status=${qmp_status_lc}"
      fi
  fi

  # 마지막 heartbeat(또는 QMP/IO 실패 시작)로부터 경과 시간 계산
  local duration_sec
  duration_sec="$(hangctl_state_get_duration_sec "${vm}")"
  local stuck_sec="${duration_sec}"

  # --- [단계 3] 마이그레이션/백업 작업 인식 및 계측 결정 ---
  local is_migration=0
  [[ "${domstate_full}" == *"migration"* ]] && is_migration=1
  
  # libvirt가 자체적으로 감지한 에러 상태 확인
  local is_disk_error=0
  [[ "${domstate_full}" == *"disk error"* ]] && is_disk_error=1

  # [규칙] 백업/스냅샷 작업 여부 확인 (domjobinfo 이용)
  local job_out job_type
  job_out=$(virsh -c qemu:///system domjobinfo "${vm}" 2>/dev/null || true)
  job_type=$(echo "${job_out}" | grep "Job type:" | awk '{print $3}' || echo "None")
  
  local is_backup=0
  # Job type이 None이거나 Completed가 아니면 작업 중으로 간주
  [[ "${job_type}" != "None" && "${job_type}" != "Completed" && -n "${job_type}" ]] && is_backup=1

  local current_window="${HANGCTL_CONFIRM_WINDOW_SEC}"
  if [[ "${is_migration}" -eq 1 || "${is_backup}" -eq 1 ]]; then
    # 마이그레이션 또는 백업 중인 경우 용인 계측을 1800초로 용인하여 보호
    current_window="${HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC}"
  elif [[ "${domstate}" == "paused" || "${is_disk_error}" -eq 1 ]]; then
    # 일반 paused 상태에서 에러가 명시된 경우 별도 계측 적용
    current_window="${HANGCTL_PAUSED_CONFIRM_WINDOW_SEC}"
  fi

  # --- [단계 4] 의심 상태(suspect) 1차 결정 ---
  local decision="normal"
  if [[ "${duration_sec}" -ge "${current_window}" ]]; then
    decision="suspect"
  fi

  hangctl_log_event "detect" "vm.status_check" "ok" "${vm}" "" "" \
    "domstate=${domstate_full} duration_sec=${duration_sec} decision=${decision} confirm_window=${current_window} job_type=${job_type} io_stall=${io_stall}"

  # 의심 상황이 아니면 다음 VM으로 넘어감
  if [[ "${decision}" != "suspect" ]]; then
    return 0
  fi

  # --- [단계 5] 추가 검증(마이그레이션 좀비체크) ---
  if [[ "${is_migration}" -eq 1 ]]; then
    if ! hangctl_probe_migration_zombie_check "${vm}"; then
      hangctl_log_event "detect" "vm.migration_check" "ok" "${vm}" "" "" \
        "status=progressing note=protecting_active_migration stuck_sec=${stuck_sec}"
      return 0
    fi
  fi

  # --- [단계 6] 최종 결정 로직 ---
  local final_decision="suspect"
  local confirm_reason="domstate_stuck"

  if [[ "${is_migration}" -eq 1 ]]; then
    final_decision="confirmed"
    confirm_reason="migration_zombie_no_progress"
  elif [[ "${is_backup}" -eq 1 ]]; then
    # 백업 시 계측 초과 시 결정 (이전 시간에 기록했으므로 애초에 단)
    final_decision="confirmed"
    confirm_reason="backup_stuck_over_threshold"
  elif [[ "${is_disk_error}" -eq 1 ]]; then
    final_decision="confirmed"
    confirm_reason="libvirt_reported_disk_error"
  elif [[ "${io_stall}" == "0" ]]; then
    final_decision="confirmed"
    confirm_reason="continuous_io_stall_detected"
  elif [[ "${domstate}" == "paused" ]]; then
    final_decision="confirmed"
    confirm_reason="stuck_in_paused_state"
  elif [[ "${qmp_rc}" == "124" || "${qmp_status_lc}" == "unknown" || -z "${qmp_status_lc}" ]]; then
    final_decision="confirmed"
    confirm_reason="qmp_no_response"
  elif [[ "${qmp_status_lc}" == "running" ]]; then
    final_decision="clear"
    confirm_reason="qmp_responding_running"
  elif [[ "${qmp_status_lc}" == "paused" ]]; then
    final_decision="confirmed"
    confirm_reason="qmp_status_paused_stuck"
  else
    final_decision="confirmed"
    confirm_reason="qmp_fail_unknown"
  fi

  hangctl_log_event "detect" "vm.decision" "ok" "${vm}" "" "" \
    "final=${final_decision} reason=${confirm_reason} domstate=${domstate_full} stuck_sec=${stuck_sec}"

  # 최종 결정이 clear 또는 normal이면 조치 없이 종료
  if [[ "${final_decision}" == "clear" || "${final_decision}" == "normal" ]]; then
    return 0
  fi

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
  # Logging config (rotate) is applied in hangctl_log_rotate_if_needed called by scan lifecycle events, so no need to handle here separately.
  hangctl_log_rotate_if_needed

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
  # HANGCTL_VIRSH_TIMEOUT_SEC 초과 시 rc=124, libvirt 오류 시 rc=1, 성공 시 rc=0
  hangctl_virsh "${HANGCTL_VIRSH_TIMEOUT_SEC}" out err rc -- -c qemu:///system list --state-running --state-paused --name
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
    # 1. 각 VM 처리의 서브쉘( ) 에서 실행하여 변수 간섭 방지
    # 2. < /dev/null 을 통해 불필요한 입력 차단 방지
    (
      hangctl_detect_probe_maybe_act_one_vm "${vm}" "1" || {
        hangctl_log_event "scan" "vm.skip" "fail" "${vm}" "" "" "reason=function_failed"
      }
    ) < /dev/null
  done

  # Commit 09 scope: cleanup orphan state files for VMs that no longer exist (not in current vm_array)
  local state_dir="${HANGCTL_STATE_DIR}"
  if [[ -d "${state_dir}" ]]; then
    for state_file in "${state_dir}"/*.state; do
      [[ -e "${state_file}" ]] || continue
      local cached_vm
      cached_vm=$(basename "${state_file}" .state)
      
      # vm_array에 cached_vm이 있는지 확인
      local found=0
      for v in "${vm_array[@]}"; do
        if [[ "$(hangctl_state__vm_key "${v}")" == "${cached_vm}" ]]; then
          found=1; break
        fi
      done
      
      if [[ "${found}" -eq 0 ]]; then
        # 실행 중이 아니므로 상태 초기화
        hangctl_state_reset_vm "${cached_vm}"
      fi
    done
  fi

  # Commit 06 scope ends here: no further VM probing yet (QMP/QGA later).
  hangctl_log_event "scan" "scan.end" "ok" "" "" "" \
    "policy=${HANGCTL_POLICY} dry_run=${HANGCTL_DRY_RUN} scanned_vms=${vm_count}"
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
      --dry-run) dry="1"; shift ;; # 무시하지만 글로벌 옵션 처리
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
