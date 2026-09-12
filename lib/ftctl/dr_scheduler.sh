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

FTCTL_DR_SCHEDULER_INTERVAL_SEC="${FTCTL_DR_SCHEDULER_INTERVAL_SEC:-60}"
FTCTL_DR_SCHEDULER_MAX_CYCLES="${FTCTL_DR_SCHEDULER_MAX_CYCLES:-0}"
FTCTL_DR_SCHEDULER_DISABLE="${FTCTL_DR_SCHEDULER_DISABLE:-0}"
FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC="${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC:-600}"
FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC="${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC:-5}"
FTCTL_DR_SCHEDULER_HEARTBEAT_TIMEOUT_SEC="${FTCTL_DR_SCHEDULER_HEARTBEAT_TIMEOUT_SEC:-30}"
FTCTL_DR_CANCEL_STOP_TIMEOUT_SEC="${FTCTL_DR_CANCEL_STOP_TIMEOUT_SEC:-20}"
FTCTL_DR_FULL_SEED_MAX_CONCURRENT="${FTCTL_DR_FULL_SEED_MAX_CONCURRENT:-2}"
FTCTL_DR_INCREMENTAL_MAX_CONCURRENT="${FTCTL_DR_INCREMENTAL_MAX_CONCURRENT:-4}"
FTCTL_DR_RESOURCE_RETRY_SEC="${FTCTL_DR_RESOURCE_RETRY_SEC:-15}"
FTCTL_DR_RESOURCE_RETRY_MAX_SEC="${FTCTL_DR_RESOURCE_RETRY_MAX_SEC:-300}"
FTCTL_DR_SOURCE_RETRY_SEC="${FTCTL_DR_SOURCE_RETRY_SEC:-15}"
FTCTL_DR_SOURCE_RETRY_MAX_SEC="${FTCTL_DR_SOURCE_RETRY_MAX_SEC:-300}"
FTCTL_DR_INITIAL_JITTER_MAX_SEC="${FTCTL_DR_INITIAL_JITTER_MAX_SEC:-0}"
FTCTL_DR_CONTROL_PROTOCOL_VERSION="4"

ftctl_dr_scheduler_resource_retry_delay() {
  local attempt="${1-1}" base="${FTCTL_DR_RESOURCE_RETRY_SEC}" maximum="${FTCTL_DR_RESOURCE_RETRY_MAX_SEC}" delay multiplier=1
  [[ "${attempt}" =~ ^[1-9][0-9]*$ ]] || attempt=1
  [[ "${base}" =~ ^[1-9][0-9]*$ ]] || base=15
  [[ "${maximum}" =~ ^[1-9][0-9]*$ ]] || maximum=300
  (( maximum >= base )) || maximum="${base}"
  (( attempt > 10 )) && attempt=10
  multiplier=$((1 << (attempt - 1)))
  delay=$((base * multiplier))
  (( delay <= maximum )) || delay="${maximum}"
  printf '%s\n' "${delay}"
}

ftctl_dr_scheduler_source_retry_delay() {
  local plan="${1-}" attempt="${2-1}" base="${FTCTL_DR_SOURCE_RETRY_SEC}" maximum="${FTCTL_DR_SOURCE_RETRY_MAX_SEC}"
  local delay multiplier=1 jitter=0 hash
  [[ "${attempt}" =~ ^[1-9][0-9]*$ ]] || attempt=1
  [[ "${base}" =~ ^[1-9][0-9]*$ ]] || base=15
  [[ "${maximum}" =~ ^[1-9][0-9]*$ ]] || maximum=300
  (( maximum >= base )) || maximum="${base}"
  (( attempt > 10 )) && attempt=10
  multiplier=$((1 << (attempt - 1)))
  delay=$((base * multiplier))
  (( delay <= maximum )) || delay="${maximum}"
  hash="$(printf '%s:%s' "${plan}" "${attempt}" | cksum | awk '{print $1}')"
  (( delay >= maximum )) || jitter=$((hash % (base + 1)))
  delay=$((delay + jitter))
  (( delay <= maximum )) || delay="${maximum}"
  printf '%s\n' "${delay}"
}

ftctl_dr_scheduler_slot_class() {
  local cycle_type="${1-}"
  case "${cycle_type}" in
    full-seed|full-reseed|full-reverse-seed) printf 'full-seed\n' ;;
    *) printf 'incremental\n' ;;
  esac
}

ftctl_dr_scheduler_slot_limit() {
  local profile_file="${1-}" slot_class="${2-}" configured profile_limit
  if [[ "${slot_class}" == "full-seed" ]]; then
    configured="${FTCTL_DR_FULL_SEED_MAX_CONCURRENT}"
    profile_limit="$(ftctl_dr_scheduler_profile_int "${profile_file}" "policy.fullSeedMaxConcurrent" "${configured}")"
  else
    configured="${FTCTL_DR_INCREMENTAL_MAX_CONCURRENT}"
    profile_limit="$(ftctl_dr_scheduler_profile_int "${profile_file}" "policy.incrementalMaxConcurrent" "${configured}")"
  fi
  [[ "${configured}" =~ ^[1-9][0-9]*$ ]] || configured=1
  [[ "${profile_limit}" =~ ^[1-9][0-9]*$ ]] || profile_limit="${configured}"
  (( profile_limit > configured )) && profile_limit="${configured}"
  printf '%s\n' "${profile_limit}"
}

ftctl_dr_scheduler_slot_acquire() {
  local plan="${1-}" profile_file="${2-}" cycle_type="${3-}" fd="${4-203}"
  local slot_class limit slot slot_path
  slot_class="$(ftctl_dr_scheduler_slot_class "${cycle_type}")"
  limit="$(ftctl_dr_scheduler_slot_limit "${profile_file}" "${slot_class}")"
  ftctl_ensure_dir "${FTCTL_RUN_DIR}/dr-resource-slots/${slot_class}" "0755"
  for ((slot=0; slot<limit; slot++)); do
    slot_path="${FTCTL_RUN_DIR}/dr-resource-slots/${slot_class}/${slot}.lock"
    eval "exec ${fd}>\"${slot_path}\""
    if flock -n "${fd}"; then
      {
        printf 'plan=%s\n' "${plan}"
        printf 'cycle_type=%s\n' "${cycle_type}"
        printf 'pid=%s\n' "$$"
        printf 'started_at=%s\n' "$(ftctl_now_iso8601)"
      } > "${slot_path}.meta" 2>/dev/null || true
      FTCTL_DR_HELD_RESOURCE_SLOT="${slot_class}:${slot}:${slot_path}"
      return 0
    fi
    eval "exec ${fd}>&-" 2>/dev/null || true
  done
  FTCTL_DR_WAITING_SLOT_CLASS="${slot_class}"
  FTCTL_DR_WAITING_SLOT_LIMIT="${limit}"
  return 97
}

ftctl_dr_scheduler_slot_release() {
  local fd="${1-203}" held="${FTCTL_DR_HELD_RESOURCE_SLOT:-}" slot_path=""
  [[ -n "${held}" ]] && slot_path="${held#*:*:}"
  flock -u "${fd}" 2>/dev/null || true
  eval "exec ${fd}>&-" 2>/dev/null || true
  [[ -n "${slot_path}" ]] && rm -f "${slot_path}.meta" 2>/dev/null || true
  FTCTL_DR_HELD_RESOURCE_SLOT=""
}

ftctl_dr_scheduler_initial_jitter() {
  local plan="${1-}" profile_file="${2-}" interval="${3-0}" salt="${4-0}" configured jitter hash
  configured="$(ftctl_dr_scheduler_profile_int "${profile_file}" "schedule.jitterSeconds" "${FTCTL_DR_INITIAL_JITTER_MAX_SEC}")"
  [[ "${configured}" =~ ^[0-9]+$ ]] || configured=0
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval=0
  (( configured > FTCTL_DR_INITIAL_JITTER_MAX_SEC )) && configured="${FTCTL_DR_INITIAL_JITTER_MAX_SEC}"
  (( interval > 1 && configured >= interval )) && configured=$((interval - 1))
  (( configured > 0 )) || { printf '0\n'; return 0; }
  hash="$(printf '%s:%s' "${plan}" "${salt}" | cksum | awk '{print $1}')"
  printf '%s\n' $((hash % (configured + 1)))
}

ftctl_dr_scheduler_execution_budget_seconds() {
  local restore_points_path="${1-}" target_rpo_seconds="${2-300}"
  [[ "${target_rpo_seconds}" =~ ^[1-9][0-9]*$ ]] || target_rpo_seconds=300
  python3 - "${restore_points_path}" "${target_rpo_seconds}" <<'PY'
import json
import math
import os
import sys

path = sys.argv[1]
rpo = max(1, int(sys.argv[2]))
samples = []
if path and os.path.exists(path):
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            try:
                value = json.loads(line).get("schedulerDurationSeconds")
            except (TypeError, ValueError):
                continue
            if isinstance(value, int) and not isinstance(value, bool) and value > 0:
                samples.append(value)
samples = sorted(samples[-10:])
if samples:
    index = max(0, math.ceil(len(samples) * 0.95) - 1)
    budget = samples[index]
else:
    budget = max(30, rpo // 5)
budget = max(15, min(budget, max(15, rpo // 2)))
print(budget)
PY
}

ftctl_dr_scheduler_next_deadline_epoch() {
  local durable_at="${1-}" target_rpo_seconds="${2-}" execution_budget_seconds="${3-}" jitter_seconds="${4-0}"
  local durable_epoch
  [[ "${target_rpo_seconds}" =~ ^[1-9][0-9]*$ ]] || return 65
  [[ "${execution_budget_seconds}" =~ ^[0-9]+$ ]] || return 65
  [[ "${jitter_seconds}" =~ ^[0-9]+$ ]] || jitter_seconds=0
  durable_epoch="$(ftctl_iso_to_epoch "${durable_at}")" || return 65
  printf '%s\n' $((durable_epoch + target_rpo_seconds - execution_budget_seconds - jitter_seconds))
}

ftctl_dr_scheduler_dir() {
  local plan="${1-}"
  printf '%s/scheduler\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_scheduler_launch_state_path() {
  local plan="${1-}"
  printf '%s/launch.state\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_unit_name() {
  local plan="${1-}"
  [[ "${plan}" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 2
  printf 'ablestack-vm-ftctl-dr@%s.service\n' "${plan}"
}

ftctl_dr_scheduler_systemd_available() {
  local plan="${1-}" unit load_state
  [[ -d /run/systemd/system ]] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  unit="$(ftctl_dr_scheduler_unit_name "${plan}" 2>/dev/null || true)"
  [[ -n "${unit}" ]] || return 1
  load_state="$(systemctl show "${unit}" -p LoadState --value 2>/dev/null || true)"
  [[ "${load_state}" == "loaded" ]]
}

ftctl_dr_scheduler_process_cgroup() {
  local pid="${1-}"
  [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/cgroup" ]] || return 1
  awk -F: '$1 == "0" {print $3; exit}' "/proc/${pid}/cgroup" 2>/dev/null
}

ftctl_dr_scheduler_write_launch_state() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}" trigger="${6-START}"
  local launch_path session authority_sequence
  launch_path="$(ftctl_dr_scheduler_launch_state_path "${plan}")"
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  ftctl_ensure_dir "$(dirname "${launch_path}")" "0755"
  ftctl_state_write_kv_all "${launch_path}" \
    "version=1" \
    "plan_uuid=${plan}" \
    "run_uuid=${run}" \
    "scheduler_session_uuid=${session}" \
    "profile_path=${profile_file}" \
    "state_path=${state_path}" \
    "status_path=${status_path}" \
    "desired_state=RUNNING" \
    "active_side=SOURCE" \
    "authority_sequence=${authority_sequence}" \
    "recovery_trigger=${trigger}" \
    "updated_at=$(ftctl_now_iso8601)"
}

ftctl_dr_scheduler_update_unit_projection() {
  local plan="${1-}" state_path="${2-}" status_path="${3-}" recovery_state="${4-NONE}" trigger="${5-}"
  local unit active_state sub_state cgroup main_pid
  unit="$(ftctl_dr_scheduler_unit_name "${plan}" 2>/dev/null || true)"
  active_state="$(systemctl show "${unit}" -p ActiveState --value 2>/dev/null || true)"
  sub_state="$(systemctl show "${unit}" -p SubState --value 2>/dev/null || true)"
  cgroup="$(systemctl show "${unit}" -p ControlGroup --value 2>/dev/null || true)"
  main_pid="$(systemctl show "${unit}" -p MainPID --value 2>/dev/null || true)"
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_desired_state=RUNNING" \
    "scheduler_service_unit=${unit}" \
    "scheduler_unit_active_state=${active_state}" \
    "scheduler_unit_sub_state=${sub_state}" \
    "scheduler_cgroup=${cgroup}" \
    "scheduler_unit_main_pid=${main_pid}" \
    "scheduler_recovery_state=${recovery_state}" \
    "scheduler_recovery_trigger=${trigger}" \
    "scheduler_launch_mode=systemd" \
    "updated_at=$(ftctl_now_iso8601)" || true
}

ftctl_dr_scheduler_launch_via_systemd() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}" trigger="${6-START}"
  local unit
  ftctl_dr_scheduler_systemd_available "${plan}" || return 69
  ftctl_dr_scheduler_write_launch_state "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "${trigger}" || return $?
  unit="$(ftctl_dr_scheduler_unit_name "${plan}")"
  systemctl reset-failed "${unit}" >/dev/null 2>&1 || true
  systemctl start --no-block "${unit}" >/dev/null 2>&1 || return 69
  ftctl_dr_scheduler_update_unit_projection "${plan}" "${state_path}" "${status_path}" "RECOVERING" "${trigger}"
}

ftctl_dr_scheduler_run_from_launch() {
  local plan="${1-}" json="${2-0}" launch_path run profile_file state_path status_path rc=0
  ftctl_dr_runtime_require_plan "${plan}" || return 2
  launch_path="$(ftctl_dr_scheduler_launch_state_path "${plan}")"
  [[ -f "${launch_path}" ]] || {
    [[ "${json}" == "1" ]] && printf '{"command":"dr-scheduler-run","result":"not_found","plan_uuid":"%s","exit_code":2}\n' "$(ftctl__json_escape "${plan}")"
    return 2
  }
  run="$(ftctl_state_read_kv "${launch_path}" "run_uuid" 2>/dev/null || true)"
  profile_file="$(ftctl_state_read_kv "${launch_path}" "profile_path" 2>/dev/null || true)"
  state_path="$(ftctl_state_read_kv "${launch_path}" "state_path" 2>/dev/null || true)"
  status_path="$(ftctl_state_read_kv "${launch_path}" "status_path" 2>/dev/null || true)"
  [[ -n "${run}" && -f "${profile_file}" && -f "${state_path}" && -n "${status_path}" ]] || return 30
  export FTCTL_DR_RUNTIME_WORKER=1
  export FTCTL_DR_SCHEDULER_FOREGROUND=1
  ftctl_dr_scheduler_worker "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" || rc=$?
  if [[ "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "nbd_teardown_state")" == "QUARANTINED" ]]; then
    return 0
  fi
  return "${rc}"
}

ftctl_dr_scheduler_nbd_recovery_tool() {
  local candidate
  for candidate in \
    "${FTCTL_DR_NBD_RECOVERY_TOOL:-}" \
    "${FTCTL_LIB_BASE:-}/ftctl/dr_vmware_mover.sh" \
    "/usr/local/lib/ablestack-qemu-exec-tools/ftctl/dr_vmware_mover.sh"; do
    [[ -n "${candidate}" && -x "${candidate}" ]] || continue
    printf '%s\n' "${candidate}"
    return 0
  done
  return 65
}

ftctl_dr_scheduler_recover_nbd_quarantine() {
  local plan="${1-}" state_path="${2-}" status_path="${3-}" recovery_tool rc=0
  [[ "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "nbd_teardown_state")" == "QUARANTINED" ]] || return 0
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_recovery_stage=NBD_RECOVERY" \
    "scheduler_recovery_rc=" \
    "updated_at=$(ftctl_now_iso8601)" || true
  recovery_tool="$(ftctl_dr_scheduler_nbd_recovery_tool 2>/dev/null || true)"
  if [[ -z "${recovery_tool}" ]]; then
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_recovery_state=FAILED" \
      "scheduler_recovery_stage=NBD_RECOVERY_TOOL_RESOLUTION" \
      "scheduler_recovery_rc=65" \
      "error_code=DR_NBD_RECOVERY_TOOL_UNAVAILABLE" \
      "error_message=Installed NBD recovery tool is unavailable" \
      "updated_at=$(ftctl_now_iso8601)" || true
    return 65
  fi
  "${recovery_tool}" --recover-nbd "${plan}" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_recovery_state=FAILED" \
      "scheduler_recovery_stage=NBD_RECOVERY" \
      "scheduler_recovery_rc=${rc}" \
      "error_code=DR_NBD_RECOVERY_FAILED" \
      "error_message=NBD recovery tool failed with exit code ${rc}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    return "${rc}"
  fi
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "nbd_teardown_state=DRAINED" \
    "nbd_quarantined_device_count=0" \
    "nbd_teardown_error_code=" \
    "nbd_teardown_error_message=" \
    "scheduler_recovery_state=RECOVERING" \
    "scheduler_recovery_stage=NBD_RECOVERY_COMPLETED" \
    "scheduler_recovery_rc=0" \
    "error_code=" \
    "error_message=" \
    "updated_at=$(ftctl_now_iso8601)" || true
}

ftctl_dr_scheduler_recover() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}" trigger="${6-MANUAL}"
  local state active_side control_state transition_state recovery_state reseed_reason authority_rc=0
  [[ -f "${profile_file}" && -f "${status_path}" ]] || return 2
  # Package replacement or process death can leave status.state owned by an
  # older failover Run. Reconcile only from a newer, fully acknowledged
  # failback journal; a genuine TARGET authority remains suppressed below.
  if declare -F ftctl_dr_runtime_converge_completed_failback_authority >/dev/null 2>&1; then
    ftctl_dr_runtime_converge_completed_failback_authority \
      "${plan}" "${state_path}" "${status_path}" || authority_rc=$?
    [[ "${authority_rc}" != "2" ]] || return 41
  fi
  state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "state")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "active_side")"
  control_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "control_state")"
  transition_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "transition_state")"
  [[ "${active_side^^}" != "TARGET" && "${state}" != "FAILED_OVER" ]] || return 41
  if [[ "${control_state}" == "STOPPED" ]]; then
    recovery_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" scheduler_recovery_state)"
    reseed_reason="$(ftctl_dr_runtime_state_get_from_path "${status_path}" reseed_reason)"
    case "${recovery_state}" in
      REQUIRED|FAILED) ;;
      *) return 42 ;;
    esac
    [[ "${reseed_reason}" == "OPERATOR_CANCELED_TRANSFER" ]] || return 42
    ftctl_dr_scheduler_control_set "${plan}" "run" "cancel-recovery" "${run}" "false" >/dev/null || return $?
    ftctl_state_set_path "$(ftctl_dr_scheduler_sequence_path "${plan}")" \
      "pending_reseed_run=${run}" \
      "pending_reseed_request_bound=true" \
      "requested_cycle_owner_run=${run}" \
      "requested_cycle_mode=FULL_RESEED" \
      "requested_cycle_state=PENDING" || return $?
    control_state="RUNNING"
  fi
  [[ "${control_state}" != "PAUSED" ]] || return 42
  case "${transition_state}" in
    ""|IDLE|COMPLETED|SUCCEEDED) ;;
    *) return 43 ;;
  esac
  ftctl_dr_scheduler_recover_nbd_quarantine "${plan}" "${state_path}" "${status_path}" || return $?
  if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
    return 0
  fi
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=RECOVERING" \
    "scheduler_health=RECOVERING" \
    "scheduler_recovery_state=RECOVERING" \
    "scheduler_recovery_stage=SCHEDULER_LAUNCH" \
    "scheduler_recovery_rc=" \
    "scheduler_recovery_trigger=${trigger}" \
    "replication_activity=RECOVERING" \
    "protection_state=DEGRADED" \
    "error_code=" \
    "error_message=" \
    "updated_at=$(ftctl_now_iso8601)" || true
  ftctl_dr_scheduler_launch_via_systemd "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "${trigger}"
}

ftctl_dr_scheduler_reconcile_plan() {
  local plan="${1-}" profile_file status_path state active_side control_state transition_state run="" state_path
  local control_command scheduler_desired_state recovery_state recovery_trigger transient_error=false next_retry now
  profile_file="$(ftctl_dr_runtime_profile_path "${plan}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  [[ -f "${profile_file}" && -f "${status_path}" ]] || return 0
  if ftctl_dr_runtime_remote_source_transition "${profile_file}" \
      && [[ "$(ftctl_dr_runtime_local_worker_role "${plan}")" == "target" ]]; then
    if [[ "$(ftctl_dr_scheduler_control_command "${plan}")" != "stop" ]]; then
      ftctl_dr_scheduler_control_set "${plan}" "stop" "remote-source-target-suppressed" "" "false" >/dev/null || true
    fi
    if ftctl_dr_scheduler_systemd_available "${plan}"; then
      systemctl stop --no-block "$(ftctl_dr_scheduler_unit_name "${plan}")" >/dev/null 2>&1 || true
    fi
    ftctl_dr_runtime_path_set "${status_path}" \
      "scheduler_state=STOPPED" "scheduler_desired_state=STOPPED" \
      "scheduler_health=SUPPRESSED" "scheduler_recovery_state=SUPPRESSED" \
      "replication_activity=STOPPED" "scheduler_pid_alive=false" \
      "owner_matched=false" "active_worker_run_uuid=" "active_worker_pid=" \
      "active_worker_start_ticks=" "worker_heartbeat_at=" \
      "control_state=STOPPED" "updated_at=$(ftctl_now_iso8601)" || true
    return 0
  fi
  if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
    return 0
  fi
  # The durable scheduler control file is authoritative during operator stop
  # and cancel. Plan status projection can lag while systemd is stopping.
  control_command="$(ftctl_dr_scheduler_control_command "${plan}")"
  [[ "${control_command}" != "stop" ]] || return 0
  state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "state")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "active_side")"
  control_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "control_state")"
  scheduler_desired_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "scheduler_desired_state")"
  transition_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "transition_state")"
  if [[ "${state}" == "ERROR" && "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "retryable")" == "true" ]]; then
    case "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "error_code")" in
      DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE|DR_QCOW2_OFFLINE_SOURCE_BUSY) transient_error=true ;;
    esac
  fi
  [[ "${state}" == "READY" || "${state}" == "SYNCING" || "${transient_error}" == "true" ||
    "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "nbd_teardown_state")" == "QUARANTINED" ]] || return 0
  [[ "${active_side^^}" != "TARGET" ]] || return 0
  [[ "${control_state}" == "RUNNING" ]] || return 0
  [[ "${scheduler_desired_state}" != "STOPPED" ]] || return 0
  case "${transition_state}" in
    ""|IDLE|COMPLETED|SUCCEEDED) ;;
    *) return 0 ;;
  esac
  recovery_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "scheduler_recovery_state")"
  recovery_trigger="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "scheduler_recovery_trigger")"
  if [[ "${recovery_state}" == "REQUIRED" && "${recovery_trigger}" == "CANCEL_AUTO_RECOVERY" ]]; then
    run="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "scheduler_recovery_run_uuid")"
  fi
  [[ -n "${run}" ]] || run="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "latest_completed_producer_run_uuid")"
  [[ -n "${run}" ]] || run="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "run")"
  [[ -n "${run}" ]] || return 0
  state_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  [[ -f "${state_path}" ]] || state_path="${status_path}"
  if [[ "${transient_error}" == "true" ]]; then
    now="$(date +%s)"
    next_retry="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "local_recovery_next_retry_epoch")"
    [[ "${next_retry}" =~ ^[0-9]+$ ]] || next_retry=0
    (( now >= next_retry )) || return 0
    ftctl_dr_runtime_path_set "${status_path}" "local_recovery_next_retry_epoch=$((now + 60))" || return $?
  fi
  ftctl_dr_scheduler_recover "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "LOCAL_RECONCILE"
}

ftctl_dr_scheduler_reconcile_all() {
  local json="${1-0}" root profile plan recovered=0 failed=0 rc
  root="$(ftctl_dr_runtime_root)/plans"
  [[ -d "${root}" ]] || {
    [[ "${json}" == "1" ]] && printf '{"command":"dr-reconcile","result":"ok","recovered":0,"failed":0}\n'
    return 0
  }
  for profile in "${root}"/*/profile.json; do
    [[ -f "${profile}" ]] || continue
    plan="$(basename "$(dirname "${profile}")")"
    rc=0
    ftctl_dr_scheduler_reconcile_plan "${plan}" || rc=$?
    if [[ "${rc}" == "0" ]]; then
      if [[ "$(ftctl_dr_runtime_state_get_from_path "$(ftctl_dr_runtime_status_path "${plan}")" "scheduler_recovery_trigger")" == "LOCAL_RECONCILE" ]]; then
        recovered=$((recovered + 1))
      fi
    else
      failed=$((failed + 1))
    fi
  done
  [[ "${json}" == "1" ]] && printf '{"command":"dr-reconcile","result":"ok","recovered":%s,"failed":%s}\n' "${recovered}" "${failed}"
  [[ "${failed}" == "0" ]]
}

ftctl_dr_scheduler_pid_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.pid\n' "$(ftctl_dr_scheduler_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_scheduler_owner_lock_path() {
  local plan="${1-}"
  printf '%s/owner.lock\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_lease_path() {
  local plan="${1-}"
  printf '%s/lease.state\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_active_pid_path() {
  local plan="${1-}"
  printf '%s/active.pid\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_sequence_path() {
  local plan="${1-}"
  printf '%s/sequence.state\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_session_uuid() {
  local plan="${1-}" profile_file="${2-}" session=""
  if [[ -n "${profile_file}" && -f "${profile_file}" ]]; then
    session="$(ftctl_dr_runtime_profile_value "${profile_file}" "schedulerSessionUuid" 2>/dev/null || true)"
  fi
  [[ -n "${session}" ]] || session="${plan}"
  printf '%s\n' "${session}"
}

ftctl_dr_scheduler_process_start_ticks() {
  local pid="${1-}"
  [[ "${pid}" =~ ^[0-9]+$ && -r "/proc/${pid}/stat" ]] || return 1
  awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null
}

ftctl_dr_scheduler_active_value() {
  local plan="${1-}" key="${2-}"
  ftctl_state_read_kv "$(ftctl_dr_scheduler_active_pid_path "${plan}")" "${key}" 2>/dev/null || true
}

ftctl_dr_scheduler_lease_value() {
  local plan="${1-}" key="${2-}"
  ftctl_state_read_kv "$(ftctl_dr_scheduler_lease_path "${plan}")" "${key}" 2>/dev/null || true
}

ftctl_dr_scheduler_active_worker_valid() {
  local plan="${1-}" expected_session="${2-}"
  local pid start_ticks recorded_start session cmdline
  pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  recorded_start="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
  session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" >/dev/null 2>&1 || return 1
  start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${pid}" 2>/dev/null || true)"
  [[ -n "${recorded_start}" && "${start_ticks}" == "${recorded_start}" ]] || return 1
  [[ -z "${expected_session}" || "${session}" == "${expected_session}" ]] || return 1
  cmdline="$(cat "/proc/${pid}/cmdline" 2>/dev/null | tr '\0' ' ' || true)"
  [[ "${cmdline}" == *"--plan ${plan}"* ]] || return 1
  return 0
}

ftctl_dr_scheduler_repair_self_ownership() {
  local plan="${1-}" session="${2-}" epoch="${3-}" run="${4-}" pid="${5-}" start_ticks="${6-}"
  local actual_start lease_epoch active_pid active_start active_session active_epoch
  [[ "${pid}" == "$$" && "${pid}" =~ ^[0-9]+$ ]] || return 1
  actual_start="$(ftctl_dr_scheduler_process_start_ticks "${pid}" 2>/dev/null || true)"
  [[ "${start_ticks}" =~ ^[0-9]+$ && "${actual_start}" == "${start_ticks}" ]] || return 1

  # The caller owns the Plan scheduler flock while this repair runs. A newer
  # lease is the only durable evidence that this worker has lost authority.
  lease_epoch="$(ftctl_dr_scheduler_current_lease_epoch "${plan}")"
  [[ "${lease_epoch}" =~ ^[0-9]+$ && "${epoch}" =~ ^[0-9]+$ ]] || return 1
  (( lease_epoch <= epoch )) || return 1

  active_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  active_start="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
  active_session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  active_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
  if [[ "${active_pid}" =~ ^[0-9]+$ && "${active_pid}" != "${pid}" ]] \
      && kill -0 "${active_pid}" >/dev/null 2>&1 \
      && [[ "$(ftctl_dr_scheduler_process_start_ticks "${active_pid}" 2>/dev/null || true)" == "${active_start}" ]] \
      && [[ "${active_session}" != "${session}" || "${active_epoch}" -gt "${epoch}" ]]; then
    return 1
  fi

  ftctl_dr_scheduler_write_heartbeat "${plan}" "${session}" "${epoch}" "${run}" "${pid}" "${start_ticks}" || return 1
  ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"
}

ftctl_dr_scheduler_current_lease_epoch() {
  local plan="${1-}" epoch
  epoch="$(ftctl_dr_scheduler_lease_value "${plan}" "lease_epoch")"
  [[ "${epoch}" =~ ^[0-9]+$ ]] || epoch=0
  printf '%s\n' "${epoch}"
}

ftctl_dr_scheduler_current_authority_sequence() {
  local plan="${1-}" sequence
  sequence="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_sequence_path "${plan}")" "authority_sequence" 2>/dev/null || true)"
  [[ "${sequence}" =~ ^[0-9]+$ ]] || sequence=0
  printf '%s\n' "${sequence}"
}

ftctl_dr_scheduler_floor_authority_sequence() {
  local plan="${1-}" floor="${2-}" sequence_path current cycle_sequence rc=0
  local lock_fd=206
  [[ -n "${plan}" && "${floor}" =~ ^[0-9]+$ ]] || return 2

  ftctl_dr_scheduler_lock_acquire "${plan}" "authority-sequence" "${lock_fd}" 5 \
    "authority-floor:${floor}" || return $?
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  current="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  if (( current < floor )); then
    cycle_sequence="$(ftctl_state_read_kv "${sequence_path}" "plan_cycle_sequence" 2>/dev/null || true)"
    [[ "${cycle_sequence}" =~ ^[0-9]+$ ]] || cycle_sequence=0
    ftctl_state_set_path "${sequence_path}" \
      "plan_cycle_sequence=${cycle_sequence}" \
      "authority_sequence=${floor}" \
      "authority_floor_source=cloud" \
      "authority_floor_updated_at=$(ftctl_now_iso8601)" || rc=$?
    (( rc == 0 )) && current="${floor}"
  fi
  ftctl_dr_scheduler_lock_release "${plan}" "authority-sequence" "${lock_fd}"
  (( rc == 0 )) || return "${rc}"
  printf '%s\n' "${current}"
}

ftctl_dr_scheduler_current_plan_sequence() {
  local plan="${1-}" sequence
  sequence="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_sequence_path "${plan}")" "plan_cycle_sequence" 2>/dev/null || true)"
  [[ "${sequence}" =~ ^[0-9]+$ ]] || sequence=0
  printf '%s\n' "${sequence}"
}

ftctl_dr_scheduler_next_authority_sequence() {
  local plan="${1-}" sequence_path cycle_sequence authority_sequence rc=0
  local lock_fd=206
  ftctl_dr_scheduler_lock_acquire "${plan}" "authority-sequence" "${lock_fd}" 5 \
    "authority-next" || return $?
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${sequence_path}")" "0755"
  cycle_sequence="$(ftctl_state_read_kv "${sequence_path}" "plan_cycle_sequence" 2>/dev/null || true)"
  authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  [[ "${cycle_sequence}" =~ ^[0-9]+$ ]] || cycle_sequence=0
  authority_sequence=$((authority_sequence + 1))
  ftctl_state_set_path "${sequence_path}" \
    "plan_cycle_sequence=${cycle_sequence}" \
    "authority_sequence=${authority_sequence}" || rc=$?
  ftctl_dr_scheduler_lock_release "${plan}" "authority-sequence" "${lock_fd}"
  (( rc == 0 )) || return "${rc}"
  printf '%s\n' "${authority_sequence}"
}

ftctl_dr_scheduler_record_plan_sequence() {
  local plan="${1-}" cycle_sequence="${2-}" sequence_path authority_sequence rc=0
  local lock_fd=206
  ftctl_dr_scheduler_lock_acquire "${plan}" "authority-sequence" "${lock_fd}" 5 \
    "authority-record:${cycle_sequence}" || return $?
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${sequence_path}")" "0755"
  authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  authority_sequence=$((authority_sequence + 1))
  ftctl_state_set_path "${sequence_path}" \
    "plan_cycle_sequence=${cycle_sequence}" \
    "authority_sequence=${authority_sequence}" || rc=$?
  ftctl_dr_scheduler_lock_release "${plan}" "authority-sequence" "${lock_fd}"
  (( rc == 0 )) || return "${rc}"
  printf '%s\n' "${authority_sequence}"
}

ftctl_dr_scheduler_seed_resume_checkpoint() {
  local plan="${1-}" baseline="${2-}" minimum="${3-}" owner_run="${4-}"
  local sequence_path current authority_sequence
  [[ "${baseline}" =~ ^[0-9]+$ && "${minimum}" =~ ^[0-9]+$ ]] || return 2
  (( minimum > baseline )) || return 2
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  current="$(ftctl_dr_scheduler_current_plan_sequence "${plan}")"
  (( current >= baseline )) || current="${baseline}"
  authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  ftctl_state_set_path "${sequence_path}" \
    "plan_cycle_sequence=${current}" \
    "authority_sequence=${authority_sequence}" \
    "resume_baseline_checkpoint_sequence=${baseline}" \
    "minimum_completed_checkpoint_sequence=${minimum}" \
    "immediate_cycle_pending=true" \
    "immediate_cycle_owner_run=${owner_run}" \
    "resume_checkpoint_seeded_at=$(ftctl_now_iso8601)"
}

ftctl_dr_scheduler_seed_relocated_baseline() {
  local plan="${1-}" profile_file="${2-}" state_path="${3-}" status_path="${4-}"
  local baseline="${5-}" minimum="${6-}" checkpoint_state="" checkpoint_ref=""
  local checkpoint_cycle_type="" checkpoint_cycle_token="" checkpoint_effective_mode=""
  local checkpoint_source_at="" checkpoint_target_at="" checkpoint_incremental_verified=""
  local source_provider="" target_provider=""

  [[ -f "${profile_file}" ]] || return 0
  source_provider="$(ftctl_dr_runtime_profile_value "${profile_file}" "source.provider" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
  target_provider="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.provider" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
  [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "ABLESTACK" ]] || return 0

  [[ "${baseline}" =~ ^[1-9][0-9]*$ ]] \
    || baseline="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.resumeBaselineCheckpointSequence" 2>/dev/null || true)"
  [[ "${baseline}" =~ ^[1-9][0-9]*$ ]] \
    || baseline="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.checkpointSequence" 2>/dev/null || true)"
  [[ "${baseline}" =~ ^[1-9][0-9]*$ ]] || return 0
  [[ "${minimum}" =~ ^[1-9][0-9]*$ ]] \
    || minimum="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.minimumCompletedCheckpointSequence" 2>/dev/null || true)"
  [[ "${minimum}" =~ ^[1-9][0-9]*$ ]] || minimum=$((baseline + 1))
  (( minimum > baseline )) || return 2

  checkpoint_state="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.checkpointState" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
  checkpoint_ref="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.checkpointRef" 2>/dev/null || true)"
  checkpoint_target_at="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.checkpointTargetReadyAt" 2>/dev/null || true)"
  [[ "${checkpoint_state}" == "READY" || "${checkpoint_state}" == "TARGET_READY" ]] || return 2
  [[ -n "${checkpoint_ref}" && -n "${checkpoint_target_at}" ]] || return 2

  ftctl_dr_scheduler_seed_resume_checkpoint "${plan}" "${baseline}" "${minimum}" \
    "$(ftctl_dr_runtime_state_get_from_path "${state_path}" run)" || return $?

  checkpoint_cycle_type="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.checkpointCycleType" 2>/dev/null || true)"
  checkpoint_cycle_token="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.checkpointCycleToken" 2>/dev/null || true)"
  checkpoint_effective_mode="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.checkpointEffectiveMode" 2>/dev/null || true)"
  checkpoint_source_at="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.checkpointSourceCreatedAt" 2>/dev/null || true)"
  # The controller reference preserves durability, but carries no local NBD drain
  # evidence. Do not claim locally verified incremental I/O on the new worker.
  checkpoint_incremental_verified=""
  [[ -n "${checkpoint_cycle_type}" ]] || checkpoint_cycle_type="incremental"
  [[ -n "${checkpoint_cycle_token}" ]] || checkpoint_cycle_token="${plan}:${baseline}"

  # Checkpoint sequences are producer-local. A numerically larger value left
  # by a former worker does not supersede the controller-selected durable
  # checkpoint after relocation. Keep the local Plan counter monotonic in the
  # sequence file, but always seed the accepted checkpoint provenance into the
  # new Run and Plan status before the scheduler chooses its first cycle type.
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "latest_completed_checkpoint_sequence=${baseline}" \
    "latest_completed_checkpoint_cycle_type=${checkpoint_cycle_type}" \
    "latest_completed_checkpoint_ref=${checkpoint_ref}" \
    "latest_completed_checkpoint_state=TARGET_READY" \
    "latest_completed_source_checkpoint_at=${checkpoint_source_at}" \
    "latest_completed_target_durable_at=${checkpoint_target_at}" \
    "latest_completed_effective_mode=${checkpoint_effective_mode}" \
    "latest_completed_incremental_verified=${checkpoint_incremental_verified}" \
    "latest_completed_baseline_generation=${baseline}" \
    "latest_completed_cycle_token=${checkpoint_cycle_token}" \
    "baseline_state=LOCAL_DURABLE" \
    "data_commit_state=LOCAL_DURABLE" \
    "target_durable=true" \
    "relocated_baseline_seeded_at=$(ftctl_now_iso8601)"
}

ftctl_dr_scheduler_mark_resume_checkpoint_completed() {
  local plan="${1-}" completed="${2-}" sequence_path minimum pending
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  minimum="$(ftctl_state_read_kv "${sequence_path}" "minimum_completed_checkpoint_sequence" 2>/dev/null || true)"
  pending="$(ftctl_state_read_kv "${sequence_path}" "immediate_cycle_pending" 2>/dev/null || true)"
  [[ "${pending}" == "true" && "${minimum}" =~ ^[0-9]+$ && "${completed}" =~ ^[0-9]+$ ]] || return 0
  (( completed >= minimum )) || return 0
  ftctl_state_set_path "${sequence_path}" \
    "immediate_cycle_pending=false" \
    "resume_checkpoint_completed_sequence=${completed}" \
    "resume_checkpoint_completed_at=$(ftctl_now_iso8601)"
}

ftctl_dr_scheduler_write_heartbeat() {
  local plan="${1-}" session="${2-}" epoch="${3-}" run="${4-}" pid="${5-}" start_ticks="${6-}" now
  now="$(ftctl_now_iso8601)"
  ftctl_state_write_kv_all "$(ftctl_dr_scheduler_active_pid_path "${plan}")" \
    "pid=${pid}" \
    "start_ticks=${start_ticks}" \
    "scheduler_session_uuid=${session}" \
    "lease_epoch=${epoch}" \
    "worker_run_uuid=${run}" \
    "heartbeat_at=${now}"
  ftctl_state_write_kv_all "$(ftctl_dr_scheduler_lease_path "${plan}")" \
    "version=1" \
    "plan_uuid=${plan}" \
    "scheduler_session_uuid=${session}" \
    "lease_epoch=${epoch}" \
    "worker_pid=${pid}" \
    "worker_start_ticks=${start_ticks}" \
    "worker_run_uuid=${run}" \
    "heartbeat_at=${now}" \
    "state=ACTIVE"
}

ftctl_dr_scheduler_mark_lease_stopped() {
  local plan="${1-}" session="${2-}" epoch="${3-}" run="${4-}" pid="${5-}" start_ticks="${6-}"
  ftctl_state_write_kv_all "$(ftctl_dr_scheduler_lease_path "${plan}")" \
    "version=1" \
    "plan_uuid=${plan}" \
    "scheduler_session_uuid=${session}" \
    "lease_epoch=${epoch}" \
    "worker_pid=${pid}" \
    "worker_start_ticks=${start_ticks}" \
    "worker_run_uuid=${run}" \
    "heartbeat_at=$(ftctl_now_iso8601)" \
    "state=STOPPED" || true
  rm -f "$(ftctl_dr_scheduler_active_pid_path "${plan}")" 2>/dev/null || true
}

ftctl_dr_scheduler_control_path() {
  local plan="${1-}"
  printf '%s/control.state\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_control_ack_path() {
  local plan="${1-}"
  printf '%s/control.ack\n' "$(ftctl_dr_scheduler_dir "${plan}")"
}

ftctl_dr_scheduler_lock_dir() {
  local plan="${1-}"
  printf '%s/locks\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_scheduler_lock_path() {
  local plan="${1-}" scope="${2-}"
  printf '%s/%s.lock\n' "$(ftctl_dr_scheduler_lock_dir "${plan}")" "$(ftctl_dr_runtime_key "${scope}")"
}

ftctl_dr_scheduler_checkpoint_lease_path() {
  local plan="${1-}" sequence="${2-}"
  printf '%s/checkpoint-%s.lease\n' "$(ftctl_dr_scheduler_lock_dir "${plan}")" "$(ftctl_dr_runtime_key "${sequence:-latest}")"
}

ftctl_dr_scheduler_lock_acquire() {
  local plan="${1-}" scope="${2-}" fd="${3-}" timeout_sec="${4-0}" owner="${5-unknown}"
  local lock_path
  [[ "${fd}" =~ ^[0-9]+$ ]] || return 2
  lock_path="$(ftctl_dr_scheduler_lock_path "${plan}" "${scope}")"
  ftctl_ensure_dir "$(dirname "${lock_path}")" "0755"
  eval "exec ${fd}>\"${lock_path}\""
  if ! flock -w "${timeout_sec}" "${fd}"; then
    eval "exec ${fd}>&-"
    return 20
  fi
  {
    printf 'pid=%s\n' "$$"
    printf 'owner=%s\n' "${owner}"
    printf 'scope=%s\n' "${scope}"
    printf 'started_at=%s\n' "$(ftctl_now_iso8601)"
  } > "${lock_path}.meta" 2>/dev/null || true
}

ftctl_dr_scheduler_lock_release() {
  local plan="${1-}" scope="${2-}" fd="${3-}"
  local lock_path
  [[ "${fd}" =~ ^[0-9]+$ ]] || return 0
  lock_path="$(ftctl_dr_scheduler_lock_path "${plan}" "${scope}")"
  flock -u "${fd}" 2>/dev/null || true
  eval "exec ${fd}>&-" 2>/dev/null || true
  rm -f "${lock_path}.meta" 2>/dev/null || true
}

ftctl_dr_scheduler_restore_points_path() {
  local plan="${1-}"
  printf '%s/restore-points.jsonl\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_scheduler_log_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/dr-scheduler-%s-%s.log\n' "${FTCTL_LOG_DIR}" "$(ftctl_dr_runtime_key "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_scheduler_profile_provider() {
  local profile_file="${1-}" endpoint="${2-}"
  ftctl_dr_runtime_profile_value "${profile_file}" "${endpoint}.provider" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true
}

ftctl_dr_scheduler_profile_int() {
  local profile_file="${1-}" field="${2-}" default_value="${3-}"
  local value
  value="$(ftctl_dr_runtime_profile_value "${profile_file}" "${field}" 2>/dev/null || true)"
  if [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${default_value}"
  fi
}

ftctl_dr_scheduler_interval() {
  local profile_file="${1-}"
  local interval
  interval="$(ftctl_dr_scheduler_profile_int "${profile_file}" "schedule.intervalSeconds" "${FTCTL_DR_SCHEDULER_INTERVAL_SEC}")"
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval="${FTCTL_DR_SCHEDULER_INTERVAL_SEC}"
  printf '%s\n' "${interval}"
}

ftctl_dr_scheduler_max_cycles() {
  local profile_file="${1-}"
  local max_cycles
  max_cycles="$(ftctl_dr_scheduler_profile_int "${profile_file}" "request.maxCycles" "${FTCTL_DR_SCHEDULER_MAX_CYCLES}")"
  [[ "${max_cycles}" =~ ^[0-9]+$ ]] || max_cycles="${FTCTL_DR_SCHEDULER_MAX_CYCLES}"
  printf '%s\n' "${max_cycles}"
}

ftctl_dr_scheduler_pid_alive() {
  local pid_path="${1-}" expected_plan="${2-}" expected_run="${3-}" pid cmdline
  [[ -n "${pid_path}" && -f "${pid_path}" ]] || return 1
  pid="$(tr -d '[:space:]' < "${pid_path}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" >/dev/null 2>&1 || return 1
  if [[ -n "${expected_plan}" || -n "${expected_run}" ]]; then
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    [[ -z "${expected_plan}" || "${cmdline}" == *"--plan ${expected_plan}"* ]] || return 1
    [[ -z "${expected_run}" || "${cmdline}" == *"--run ${expected_run}"* ]] || return 1
  fi
  return 0
}

ftctl_dr_scheduler_profile_has_data_plane() {
  local profile_file="${1-}"
  local source_provider target_provider
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  [[ "${source_provider}" == "ABLESTACK" || "${target_provider}" == "ABLESTACK" ||
      "${source_provider}" == "VMWARE" || "${target_provider}" == "VMWARE" ]]
}

ftctl_dr_scheduler_control_generation() {
  local plan="${1-}" control_path generation
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  generation="$(ftctl_state_read_kv "${control_path}" "generation" 2>/dev/null || true)"
  [[ "${generation}" =~ ^[0-9]+$ ]] || generation=0
  printf '%s\n' "${generation}"
}

ftctl_dr_scheduler_control_set() {
  local plan="${1-}" command="${2-}" reason="${3-operator}" owner_run="${4-}" resume_after_cleanup="${5-false}"
  local control_path generation
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${control_path}")" "0755"
  ftctl_dr_scheduler_lock_acquire "${plan}" "plan" 204 "${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC}" "control:${command}:${owner_run}" || return $?
  generation=$(( $(ftctl_dr_scheduler_control_generation "${plan}") + 1 ))
  if ! ftctl_state_write_kv_all "${control_path}" \
    "version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "generation=${generation}" \
    "command=${command}" \
    "reason=${reason}" \
    "owner_run=${owner_run}" \
    "resume_after_cleanup=${resume_after_cleanup}" \
    "requested_at=$(ftctl_now_iso8601)" \
    "updated_at=$(ftctl_now_iso8601)"; then
    ftctl_dr_scheduler_lock_release "${plan}" "plan" 204
    return 2
  fi
  ftctl_dr_scheduler_lock_release "${plan}" "plan" 204
  printf '%s\n' "${generation}"
}

# Process startup is not an operator Resume. Initialize only under the same
# Plan lock used by control_set, so a concurrent PAUSE/STOP cannot be lost.
# A new source assignment supersedes only a host-local target-role suppression.
# Operator pause/stop and lifecycle authority are not changed by relocation.
ftctl_dr_scheduler_restore_source_role_control() {
  local plan="${1-}" run="${2-}" path command reason owner generation rc=0
  path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_dr_scheduler_lock_acquire "${plan}" "plan" 204 "${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC}" "source-role:${run}" || return $?
  command="$(ftctl_state_read_kv "${path}" command 2>/dev/null || true)"
  reason="$(ftctl_state_read_kv "${path}" reason 2>/dev/null || true)"
  owner="$(ftctl_state_read_kv "${path}" owner_run 2>/dev/null || true)"
  generation="$(ftctl_state_read_kv "${path}" generation 2>/dev/null || true)"
  if [[ "${command}" == stop && "${reason}" == remote-source-target-suppressed && -z "${owner}" ]]; then
    if [[ "${generation}" =~ ^[1-9][0-9]*$ && -n "${run}" ]]; then
      ftctl_state_write_kv_all "${path}" \
        "version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" "generation=$((generation + 1))" \
        "command=run" "reason=source-role-reassigned" "owner_run=${run}" \
        "resume_after_cleanup=false" "requested_at=$(ftctl_now_iso8601)" \
        "updated_at=$(ftctl_now_iso8601)" || rc=$?
    else
      rc=2
    fi
  fi
  ftctl_dr_scheduler_lock_release "${plan}" "plan" 204
  return "${rc}"
}

ftctl_dr_scheduler_initialize_control() {
  local plan="${1-}" run="${2-}" path command generation rc=0
  path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${path}")" "0755"
  ftctl_dr_scheduler_lock_acquire "${plan}" "plan" 204 "${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC}" "initialize:${run}" || return $?
  command="$(ftctl_state_read_kv "${path}" command 2>/dev/null || true)"
  generation="$(ftctl_state_read_kv "${path}" generation 2>/dev/null || true)"
  if [[ ! -e "${path}" ]]; then
    generation=1
    ftctl_state_write_kv_all "${path}" \
      "version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" "generation=1" \
      "command=run" "reason=scheduler-initialize" "owner_run=${run}" \
      "resume_after_cleanup=false" "requested_at=$(ftctl_now_iso8601)" \
      "updated_at=$(ftctl_now_iso8601)" || rc=$?
  elif [[ ! "${generation}" =~ ^[1-9][0-9]*$ ]] || [[ "${command}" != run && "${command}" != pause && "${command}" != stop ]]; then
    rc=2
  fi
  ftctl_dr_scheduler_lock_release "${plan}" "plan" 204
  (( rc == 0 )) || return "${rc}"
  printf '%s\n' "${generation}"
}

ftctl_dr_scheduler_control_command() {
  local plan="${1-}"
  local control_path
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_state_read_kv "${control_path}" "command" 2>/dev/null || true
}

ftctl_dr_scheduler_control_value() {
  local plan="${1-}" key="${2-}" control_path
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ftctl_state_read_kv "${control_path}" "${key}" 2>/dev/null || true
}

ftctl_dr_scheduler_project_requested_cycle_run() {
  local plan="${1-}" owner_run="${2-}" status_path="${3-}" state="${4-}" step="${5-}" progress="${6-}"
  local error_code="${7-}" error_message="${8-}" run_path now terminal="false"
  local terminal_state="" terminal_exit_code="0" launch_nonce generation

  [[ -n "${plan}" && -n "${owner_run}" && -n "${status_path}" && -f "${status_path}" ]] || return 2
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${owner_run}")"
  now="$(ftctl_now_iso8601)"
  if [[ "${state}" == "READY" && "${step}" == "full-resync-completed" \
        && "${progress}" == "100" && -z "${error_code}" ]]; then
    terminal="true"
    terminal_state="SUCCEEDED"
  elif [[ "${state}" == "ERROR" || "${state}" == "FAILED" ]]; then
    terminal="true"
    terminal_state="FAILED"
    terminal_exit_code="1"
  fi
  if [[ "${terminal}" == "true" ]]; then
    launch_nonce="$(ftctl_dr_runtime_state_get_from_path "${status_path}" scheduler_session_uuid)"
    generation="$(ftctl_dr_runtime_state_get_from_path "${status_path}" scheduler_lease_epoch)"
    [[ -n "${launch_nonce}" ]] || launch_nonce="scheduler:${plan}"
    [[ "${generation}" =~ ^[0-9]+$ ]] || generation="0"
    # Publish the durable terminal owner before the scheduler can advance to
    # another cycle. dr-status --run then remains stable across that race.
    ftctl_dr_runtime_terminal_journal_write "${plan}" "${owner_run}" \
      "${launch_nonce}" "${generation}" "${terminal_state}" \
      "${terminal_exit_code}" "${error_code}" "${now}" || return $?
  fi
  if command -v ftctl_dr_runtime_atomic_copy >/dev/null 2>&1; then
    ftctl_dr_runtime_atomic_copy "${status_path}" "${run_path}" "0644" || return $?
  else
    cp -f "${status_path}" "${run_path}" || return $?
    chmod 0644 "${run_path}" 2>/dev/null || true
  fi
  ftctl_state_set_path "${run_path}" \
    "plan=${plan}" \
    "run=${owner_run}" \
    "action=dr-sync-start" \
    "state=${state}" \
    "step=${step}" \
    "progress=${progress}" \
    "accepted=true" \
    "control_request_run_uuid=${owner_run}" \
    "requested_cycle_mode=FULL_RESEED" \
    "requested_cycle_owner_run=${owner_run}" \
    "requested_cycle_state=$([[ "${terminal}" == "true" ]] && printf COMPLETED || printf RUNNING)" \
    "error_code=${error_code}" \
    "error_message=${error_message}" \
    "updated_at=${now}"
  if [[ "${terminal}" == "true" ]]; then
    ftctl_state_set_path "${run_path}" \
      "worker_state=TERMINAL_PUBLISHED" \
      "worker_exit_code=${terminal_exit_code}" \
      "transfer_activity_state=IDLE" \
      "terminal_source=ENGINE_TERMINAL" \
      "terminal_version=1" \
      "terminal_authoritative=true" \
      "runtime_endpoints_drained=true" \
      "terminal_publication_pending=false" \
      "terminal_publication_pending_since=" \
      "updated_at=${now}" || return $?
  fi
}

ftctl_dr_scheduler_publish_requested_cycle_terminal() {
  local plan="${1-}" owner_run="${2-}" status_path="${3-}" sequence_path="${4-}" sequence="${5-}"
  local retry_sec="${FTCTL_DR_TERMINAL_PUBLISH_RETRY_SEC:-2}" now command

  [[ "${retry_sec}" =~ ^[1-9][0-9]*$ ]] || retry_sec=2
  while true; do
    now="$(ftctl_now_iso8601)"
    ftctl_state_set_path "${sequence_path}" \
      "requested_cycle_state=TERMINALIZING" \
      "requested_cycle_sequence=${sequence}" \
      "requested_cycle_error=" \
      "requested_cycle_terminalizing_at=${now}" || true
    ftctl_dr_runtime_path_set "${status_path}" \
      "cycle_state=TERMINALIZING" \
      "replication_activity=IDLE" \
      "terminal_publication_pending=true" \
      "updated_at=${now}" || true
    if ftctl_dr_scheduler_project_requested_cycle_run "${plan}" "${owner_run}" "${status_path}" \
        "READY" "full-resync-completed" "100" "" ""; then
      now="$(ftctl_now_iso8601)"
      if ftctl_state_set_path "${sequence_path}" \
          "requested_cycle_state=COMPLETED" \
          "requested_cycle_error=" \
          "requested_cycle_completed_at=${now}"; then
        ftctl_dr_runtime_path_set "${status_path}" \
          "cycle_state=IDLE" \
          "replication_activity=IDLE" \
          "terminal_publication_pending=false" \
          "updated_at=${now}" || true
        return 0
      fi
    fi
    ftctl_log_event "dr-runtime" "dr.scheduler.terminal-publish" "retry" "DR_TERMINAL_PUBLICATION_PENDING" "" \
      "plan=${plan} run=${owner_run} sequence=${sequence} retry_after=${retry_sec}"
    command="$(ftctl_dr_scheduler_control_command "${plan}")"
    [[ "${command}" != "stop" ]] || return 1
    sleep "${retry_sec}"
  done
}

ftctl_dr_scheduler_request_cycle() {
  local plan="${1-}" owner_run="${2-}" requested_mode="${3-}" run_path="${4-}" status_path="${5-}" force_immediate="${6-true}"
  local sequence_path generation now normalized_mode

  normalized_mode="$(printf '%s' "${requested_mode}" | tr '[:lower:]' '[:upper:]')"
  [[ -n "${plan}" && -n "${owner_run}" && "${normalized_mode}" == "FULL_RESEED" ]] || return 2
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_lock_acquire "${plan}" "plan" 204 "${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC}" \
    "cycle-request:${normalized_mode}:${owner_run}" || return $?
  if ! ftctl_state_set_path "${sequence_path}" \
      "requested_cycle_mode=${normalized_mode}" \
      "requested_cycle_owner_run=${owner_run}" \
      "requested_cycle_state=PENDING" \
      "requested_cycle_sequence=" \
      "requested_cycle_at=${now}" \
      "requested_cycle_completed_at=" \
      "requested_cycle_error="; then
    ftctl_dr_scheduler_lock_release "${plan}" "plan" 204
    return 2
  fi
  ftctl_dr_scheduler_lock_release "${plan}" "plan" 204

  generation="$(ftctl_dr_scheduler_control_set "${plan}" "run" "manual-full-resync" "${owner_run}" "false")" || return $?
  ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
    "state=SYNCING" \
    "step=full-resync-queued" \
    "progress=1" \
    "accepted=true" \
    "requested_cycle_mode=${normalized_mode}" \
    "requested_cycle_owner_run=${owner_run}" \
    "requested_cycle_state=PENDING" \
    "control_generation=${generation}" \
    "control_state=RUNNING" \
    "force_immediate_cycle=${force_immediate}" \
    "updated_at=${now}" || true
}

ftctl_dr_scheduler_control_ack() {
  local plan="${1-}" generation="${2-}" state="${3-}" cycle_state="${4-IDLE}" worker_run="${5-}"
  local session="${6-}" lease_epoch="${7-}" worker_pid="${8-}" worker_start_ticks="${9-}"
  local ack_path request_run
  ack_path="$(ftctl_dr_scheduler_control_ack_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${ack_path}")" "0755"
  request_run="$(ftctl_dr_scheduler_control_value "${plan}" "owner_run")"
  [[ -n "${session}" ]] || session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  [[ -n "${lease_epoch}" ]] || lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
  [[ -n "${worker_pid}" ]] || worker_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  [[ -n "${worker_start_ticks}" ]] || worker_start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
  ftctl_state_write_kv_all "${ack_path}" \
    "version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "generation=${generation}" \
    "state=${state}" \
    "cycle_state=${cycle_state}" \
    "owner_run=${request_run}" \
    "request_run_uuid=${request_run}" \
    "active_worker_run_uuid=${worker_run}" \
    "scheduler_session_uuid=${session}" \
    "lease_epoch=${lease_epoch}" \
    "worker_pid=${worker_pid}" \
    "worker_start_ticks=${worker_start_ticks}" \
    "owner_matched=true" \
    "acknowledged_at=$(ftctl_now_iso8601)"
}

ftctl_dr_scheduler_wait_for_ack() {
  local plan="${1-}" generation="${2-}" expected_state="${3-}" timeout_sec="${4-${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}}"
  local expected_request_run="${5-}" expected_session="${6-}" expected_epoch="${7-}"
  local expected_pid="${8-}" expected_start_ticks="${9-}"
  local ack_path deadline ack_generation ack_state ack_request_run ack_session ack_epoch ack_pid ack_start_ticks
  ack_path="$(ftctl_dr_scheduler_control_ack_path "${plan}")"
  [[ "${timeout_sec}" =~ ^[0-9]+$ ]] || timeout_sec="${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}"
  deadline=$(( $(date +%s) + timeout_sec ))
  while (( $(date +%s) <= deadline )); do
    ack_generation="$(ftctl_state_read_kv "${ack_path}" "generation" 2>/dev/null || true)"
    ack_state="$(ftctl_state_read_kv "${ack_path}" "state" 2>/dev/null || true)"
    ack_request_run="$(ftctl_state_read_kv "${ack_path}" "request_run_uuid" 2>/dev/null || true)"
    ack_session="$(ftctl_state_read_kv "${ack_path}" "scheduler_session_uuid" 2>/dev/null || true)"
    ack_epoch="$(ftctl_state_read_kv "${ack_path}" "lease_epoch" 2>/dev/null || true)"
    ack_pid="$(ftctl_state_read_kv "${ack_path}" "worker_pid" 2>/dev/null || true)"
    ack_start_ticks="$(ftctl_state_read_kv "${ack_path}" "worker_start_ticks" 2>/dev/null || true)"
    if [[ "${ack_generation}" == "${generation}" && "${ack_state}" == "${expected_state}" \
          && ( -z "${expected_request_run}" || "${ack_request_run}" == "${expected_request_run}" ) \
          && ( -z "${expected_session}" || "${ack_session}" == "${expected_session}" ) \
          && ( -z "${expected_epoch}" || "${ack_epoch}" == "${expected_epoch}" ) \
          && ( -z "${expected_pid}" || "${ack_pid}" == "${expected_pid}" ) \
          && ( -z "${expected_start_ticks}" || "${ack_start_ticks}" == "${expected_start_ticks}" ) ]]; then
      # STOPPED is a terminal acknowledgement. The worker exits immediately
      # after writing it, so requiring a live active.pid here creates a race
      # where a valid fence is reported as a timeout.
      if [[ "${expected_state}" == "STOPPED" ]]; then
        return 0
      fi
      if [[ "${ack_epoch}" == "$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")" \
            && "${ack_pid}" == "$(ftctl_dr_scheduler_active_value "${plan}" "pid")" \
            && "${ack_start_ticks}" == "$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")" ]] \
            && ftctl_dr_scheduler_active_worker_valid "${plan}" "${expected_session}"; then
        return 0
      fi
    fi
    sleep 1
  done
  return 21
}

ftctl_dr_scheduler_has_live_worker() {
  local plan="${1-}" pid_path
  if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
    return 0
  fi
  shopt -s nullglob
  for pid_path in "$(ftctl_dr_scheduler_dir "${plan}")"/*.pid; do
    if ftctl_dr_scheduler_pid_alive "${pid_path}"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

ftctl_dr_scheduler_request_and_wait() {
  local plan="${1-}" command="${2-}" expected_state="${3-}" reason="${4-operator}" owner_run="${5-}" resume_after_cleanup="${6-false}"
  local generation session lease_epoch worker_pid worker_start_ticks
  session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
  worker_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  worker_start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
  generation="$(ftctl_dr_scheduler_control_set "${plan}" "${command}" "${reason}" "${owner_run}" "${resume_after_cleanup}")" || return $?
  if ! ftctl_dr_scheduler_has_live_worker "${plan}" && [[ "${command}" != "run" ]]; then
    ftctl_dr_scheduler_control_ack "${plan}" "${generation}" "${expected_state}" "IDLE" "${owner_run}"
    printf '%s\n' "${generation}"
    return 0
  fi
  ftctl_dr_scheduler_wait_for_ack "${plan}" "${generation}" "${expected_state}" \
    "${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}" "${owner_run}" "${session}" \
    "${lease_epoch}" "${worker_pid}" "${worker_start_ticks}" || return $?
  printf '%s\n' "${generation}"
}

ftctl_dr_scheduler_cancel_active_transfer() {
  local plan="${1-}" owner_run="${2-}" run_path="${3-}" status_path="${4-}"
  local generation session lease_epoch worker_pid worker_start_ticks unit deadline active_state now
  local sequence_path sequence transfer_active="false"

  session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
  worker_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  worker_start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
  generation="$(ftctl_dr_scheduler_control_set "${plan}" "stop" "dr-cancel" "${owner_run}" "false")" || return $?

  case "$(ftctl_dr_runtime_state_get_from_path "${status_path}" transfer_activity_state)" in
    COPYING|CONNECTING|FLUSHING|VERIFYING) transfer_active="true" ;;
  esac
  [[ "$(ftctl_dr_runtime_state_get_from_path "${status_path}" cycle_state)" != "RUNNING" ]] || transfer_active="true"

  if ftctl_dr_scheduler_systemd_available "${plan}" && ftctl_dr_scheduler_has_live_worker "${plan}"; then
    unit="$(ftctl_dr_scheduler_unit_name "${plan}")"
    systemctl stop --no-block "${unit}" >/dev/null 2>&1 || return 69
    deadline=$(( $(date +%s) + FTCTL_DR_CANCEL_STOP_TIMEOUT_SEC ))
    while (( $(date +%s) <= deadline )); do
      active_state="$(systemctl show "${unit}" -p ActiveState --value 2>/dev/null || true)"
      [[ "${active_state}" == "inactive" || "${active_state}" == "failed" ]] && break
      sleep 1
    done
    active_state="$(systemctl show "${unit}" -p ActiveState --value 2>/dev/null || true)"
    [[ "${active_state}" == "inactive" || "${active_state}" == "failed" ]] || return 21
    ftctl_dr_scheduler_mark_lease_stopped "${plan}" "${session}" "${lease_epoch}" \
      "${owner_run}" "${worker_pid}" "${worker_start_ticks}"
    ftctl_dr_scheduler_control_ack "${plan}" "${generation}" "STOPPED" "IDLE" "${owner_run}" \
      "${session}" "${lease_epoch}" "${worker_pid}" "${worker_start_ticks}"
  elif ! ftctl_dr_scheduler_has_live_worker "${plan}"; then
    # A completed one-shot transfer may leave no scheduler process to ACK the
    # stop generation. The absence of a live owner is already the durable
    # drain boundary, so acknowledge STOP locally instead of waiting forever
    # for a worker that cannot respond.
    ftctl_dr_scheduler_control_ack "${plan}" "${generation}" "STOPPED" "IDLE" "${owner_run}" \
      "${session}" "${lease_epoch}" "${worker_pid}" "${worker_start_ticks}"
  else
    ftctl_dr_scheduler_wait_for_ack "${plan}" "${generation}" "STOPPED" \
      "${FTCTL_DR_CANCEL_STOP_TIMEOUT_SEC}" "${owner_run}" "${session}" \
      "${lease_epoch}" "${worker_pid}" "${worker_start_ticks}" || return $?
  fi

  now="$(ftctl_now_iso8601)"
  if [[ "${transfer_active}" == "true" ]]; then
    sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
    sequence="$(ftctl_state_read_kv "${sequence_path}" plan_cycle_sequence 2>/dev/null || true)"
    [[ "${sequence}" =~ ^[1-9][0-9]*$ ]] || sequence="$(ftctl_dr_runtime_state_get_from_path "${status_path}" plan_cycle_sequence)"
    ftctl_state_set_path "${sequence_path}" \
      "pending_reseed_sequence=${sequence}" \
      "pending_reseed_cycle_type=full-reseed" \
      "pending_reseed_run=" \
      "pending_reseed_request_bound=false" \
      "pending_reseed_reason=OPERATOR_CANCELED_TRANSFER" \
      "requested_cycle_state=CANCELED" \
      "requested_cycle_completed_at=${now}" || return $?
  fi
  ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
    "scheduler_state=STOPPED" \
    "scheduler_health=STOPPED" \
    "scheduler_desired_state=STOPPED" \
    "scheduler_recovery_state=$([[ "${transfer_active}" == "true" ]] && printf REQUIRED || printf NONE)" \
    "baseline_state=$([[ "${transfer_active}" == "true" ]] && printf INVALID || ftctl_dr_runtime_state_get_from_path "${status_path}" baseline_state)" \
    "reseed_reason=$([[ "${transfer_active}" == "true" ]] && printf OPERATOR_CANCELED_TRANSFER || ftctl_dr_runtime_state_get_from_path "${status_path}" reseed_reason)" \
    "current_checkpoint_state=$([[ "${transfer_active}" == "true" ]] && printf CANCELED || ftctl_dr_runtime_state_get_from_path "${status_path}" current_checkpoint_state)" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${generation}" \
    "control_ack_generation=${generation}" \
    "control_state=STOPPED" \
    "cycle_state=IDLE" \
    "replication_activity=STOPPED" \
    "transfer_activity_state=CANCELED" \
    "runtime_endpoints_drained=true" \
    "updated_at=${now}" || return $?
  printf '%s\n' "${generation}"
}

ftctl_dr_scheduler_cancel_auto_recovery_enabled() {
  local profile_file="${1-}" direction transport_mode
  [[ -f "${profile_file}" ]] || return 1
  direction="$(ftctl_dr_runtime_profile_value "${profile_file}" "direction" 2>/dev/null || true)"
  transport_mode="$(ftctl_dr_runtime_profile_value "${profile_file}" "transport.mode" 2>/dev/null || true)"
  [[ "${direction^^}" == "KVM_TO_KVM" && "${transport_mode}" == "site-agent-nbd" ]]
}

ftctl_dr_scheduler_queue_cancel_recovery() {
  local plan="${1-}" canceled_run="${2-}" status_path="${3-}"
  local profile_file sequence_path recovery_run recovery_path generation now
  local driver driver_state

  profile_file="$(ftctl_dr_runtime_profile_path "${plan}")"
  ftctl_dr_scheduler_cancel_auto_recovery_enabled "${profile_file}" || return 1
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  recovery_run="$(ftctl_dr_runtime_launch_nonce)"
  [[ -n "${recovery_run}" ]] || return 2
  recovery_path="$(ftctl_dr_runtime_run_path "${plan}" "${recovery_run}")"
  now="$(ftctl_now_iso8601)"
  driver="$(ftctl_dr_runtime_state_get_from_path "${status_path}" driver)"
  driver_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" driver_state)"

  # A recovery Run has a new UUID, so its state file does not exist yet.
  # Initialize it through the canonical writer before applying scheduler-only
  # fields. ftctl_dr_runtime_path_set intentionally updates existing files.
  ftctl_dr_runtime_write_state "${recovery_path}" "${plan}" "${recovery_run}" \
    "dr-scheduler-run" "READY" "cancel-recovery-pending" "0" "${recovery_run}" "" || return $?
  ftctl_dr_runtime_path_set "${recovery_path}" \
    "accepted=true" \
    "control_request_run_uuid=" \
    "driver=${driver}" \
    "driver_state=${driver_state}" \
    "scheduler_recovery_parent_run_uuid=${canceled_run}" \
    "terminal_authoritative=false" \
    "updated_at=${now}" || return $?
  ftctl_state_set_path "${sequence_path}" \
    "pending_reseed_run=${recovery_run}" \
    "pending_reseed_request_bound=false" \
    "requested_cycle_owner_run=" \
    "requested_cycle_mode=FULL_RESEED" \
    "requested_cycle_state=PENDING" \
    "requested_cycle_at=${now}" || return $?
  generation="$(ftctl_dr_scheduler_control_set "${plan}" "run" "cancel-auto-recovery" "${recovery_run}" "false")" || return $?
  ftctl_dr_scheduler_update_state "${recovery_path}" "${status_path}" \
    "state=READY" \
    "step=cancel-recovery-pending" \
    "progress=100" \
    "scheduler_state=RECOVERING" \
    "scheduler_health=RECOVERING" \
    "scheduler_desired_state=RUNNING" \
    "scheduler_recovery_state=REQUIRED" \
    "scheduler_recovery_trigger=CANCEL_AUTO_RECOVERY" \
    "scheduler_recovery_run_uuid=${recovery_run}" \
    "scheduler_recovery_parent_run_uuid=${canceled_run}" \
    "automatic_recovery_queued=true" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${generation}" \
    "control_state=RUNNING" \
    "cycle_state=IDLE" \
    "replication_activity=RECOVERING" \
    "runtime_endpoints_drained=true" \
    "updated_at=${now}" || return $?
  ftctl_log_event "dr-runtime" "dr.cancel.recovery.queued" "ok" "" "" \
    "plan=${plan} canceled_run=${canceled_run} recovery_run=${recovery_run}"
  printf '%s\n' "${recovery_run}"
}

ftctl_dr_scheduler_ensure_running() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}"
  local pid_path generation now session systemd_launch_expected=0

  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" && -f "${state_path}" ]] || return 2
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  if ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"; then
    return 0
  fi
  pid_path="$(ftctl_dr_scheduler_pid_path "${plan}" "${run}")"
  if ftctl_dr_scheduler_pid_alive "${pid_path}" "${plan}" "${run}"; then
    return 0
  fi
  if ftctl_dr_scheduler_has_live_worker "${plan}"; then
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=ERROR" \
      "scheduler_health=DUPLICATE_WORKER" \
      "owner_matched=false" \
      "error_code=DR_SCHEDULER_DUPLICATE_WORKER" \
      "error_message=Another run owns a live scheduler for this Plan" \
      "updated_at=$(ftctl_now_iso8601)" || true
    return 23
  fi

  now="$(ftctl_now_iso8601)"
  generation=$(( $(ftctl_dr_scheduler_control_generation "${plan}") + 1 ))
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=RECOVERING" \
    "scheduler_pid_alive=false" \
    "runtime_generation=${generation}" \
    "worker_pid=" \
    "updated_at=${now}" || return $?
  rm -f "${pid_path}" 2>/dev/null || true
  if ftctl_dr_scheduler_systemd_available "${plan}"; then
    systemd_launch_expected=1
  fi
  ftctl_dr_scheduler_start "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "false" || return $?

  # The shell-owned background path writes the run PID before returning. The
  # systemd path uses start --no-block and publishes only the Plan-owned
  # active.pid after the service acquires its lease, so its missing run PID is
  # not a startup failure. Let the ownership loop below establish the barrier.
  if [[ ! -s "${pid_path}" && "${systemd_launch_expected}" != "1" ]]; then
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=ERROR" \
      "scheduler_pid_alive=false" \
      "error_code=DR_SCHEDULER_NOT_RUNNING" \
      "error_message=Scheduler did not create an owned PID" \
      "updated_at=$(ftctl_now_iso8601)" || true
    return 22
  fi

  local deadline=$(( $(date +%s) + FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC ))
  while (( $(date +%s) <= deadline )); do
    if ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"; then
      local active_pid lease_epoch authority_sequence start_ticks
      active_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
      start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
      lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
      authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "scheduler_state=RUNNING" \
        "scheduler_health=HEALTHY" \
        "scheduler_pid_alive=true" \
        "scheduler_session_uuid=${session}" \
        "scheduler_lease_epoch=${lease_epoch}" \
        "authority_sequence=${authority_sequence}" \
        "active_worker_run_uuid=${run}" \
        "active_worker_pid=${active_pid}" \
        "active_worker_start_ticks=${start_ticks}" \
        "owner_matched=true" \
        "updated_at=$(ftctl_now_iso8601)" || true
      return 0
    fi
    sleep 1
  done

  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=ERROR" \
    "scheduler_pid_alive=false" \
    "error_code=DR_SCHEDULER_NOT_RUNNING" \
    "error_message=Scheduler process ownership could not be established" \
    "updated_at=$(ftctl_now_iso8601)" || true
  return 22
}

ftctl_dr_scheduler_checkpoint_lease_acquire() {
  local plan="${1-}" sequence="${2-}" run="${3-}" ref="${4-}" lease_path
  lease_path="$(ftctl_dr_scheduler_checkpoint_lease_path "${plan}" "${sequence}")"
  ftctl_ensure_dir "$(dirname "${lease_path}")" "0755"
  ftctl_state_write_kv_all "${lease_path}" \
    "plan=${plan}" \
    "run=${run}" \
    "checkpoint_sequence=${sequence}" \
    "checkpoint_ref=${ref}" \
    "state=LEASED" \
    "leased_at=$(ftctl_now_iso8601)"
  printf '%s\n' "${lease_path}"
}

ftctl_dr_scheduler_checkpoint_lease_release() {
  local plan="${1-}" sequence="${2-}"
  rm -f "$(ftctl_dr_scheduler_checkpoint_lease_path "${plan}" "${sequence}")" 2>/dev/null || true
}

ftctl_dr_scheduler_checkpoint_lease_release_owned() {
  local plan="${1-}" sequence="${2-}" run="${3-}" lease_path owner
  [[ -n "${plan}" && -n "${sequence}" && -n "${run}" ]] || return 2
  lease_path="$(ftctl_dr_scheduler_checkpoint_lease_path "${plan}" "${sequence}")"
  [[ -f "${lease_path}" ]] || return 0
  owner="$(ftctl_state_read_kv "${lease_path}" "run" 2>/dev/null || true)"
  [[ "${owner}" == "${run}" ]] || return 3
  rm -f "${lease_path}"
}

ftctl_dr_scheduler_transition_begin() {
  local plan="${1-}" run="${2-}" action="${3-}" run_path="${4-}" status_path="${5-}"
  local generation now
  ftctl_dr_scheduler_lock_acquire "${plan}" "transition" 203 "${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC}" "${action}:${run}" || return $?
  FTCTL_DR_TRANSITION_LOCK_HELD=1
  generation="$(ftctl_dr_scheduler_request_and_wait "${plan}" "pause" "PAUSED" "${action}" "${run}" "true")" || {
    ftctl_dr_scheduler_transition_end "${plan}"
    return 21
  }
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${generation}" \
    "control_ack_generation=${generation}" \
    "control_state=PAUSED" \
    "cycle_state=IDLE" \
    "transition_state=QUIESCED" \
    "transition_action=${action}" \
    "transition_quiesced_at=${now}" \
    "updated_at=${now}" || true
}

ftctl_dr_scheduler_transition_end() {
  local plan="${1-}"
  if [[ "${FTCTL_DR_TRANSITION_LOCK_HELD:-0}" == "1" ]]; then
    ftctl_dr_scheduler_lock_release "${plan}" "transition" 203
  fi
  FTCTL_DR_TRANSITION_LOCK_HELD=0
}

ftctl_dr_scheduler_resume_after_transition() {
  local plan="${1-}" run="${2-}" reason="${3-transition-complete}" run_path="${4-}" status_path="${5-}"
  local generation now profile_file scheduler_run scheduler_run_path producer_run session
  local wait_rc=0 ack_generation control_generation control_command control_state="RUNNING"
  profile_file="$(ftctl_dr_runtime_profile_path "${plan}")"
  scheduler_run="${run}"
  scheduler_run_path="${run_path}"
  if ! ftctl_dr_scheduler_has_live_worker "${plan}"; then
    producer_run="$(ftctl_dr_scheduler_latest_producer_run "$(ftctl_dr_scheduler_restore_points_path "${plan}")" "${plan}")"
    if [[ -n "${producer_run}" && -f "$(ftctl_dr_runtime_run_path "${plan}" "${producer_run}")" ]]; then
      scheduler_run="${producer_run}"
      scheduler_run_path="$(ftctl_dr_runtime_run_path "${plan}" "${producer_run}")"
    fi
  fi
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  generation="$(ftctl_dr_scheduler_control_set "${plan}" "run" "${reason}" "${run}" "false")" || return $?
  ftctl_dr_scheduler_ensure_running "${plan}" "${scheduler_run}" "${profile_file}" "${scheduler_run_path}" "${status_path}" || return $?
  ftctl_dr_scheduler_wait_for_ack "${plan}" "${generation}" "RUNNING" \
    "${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}" "${run}" "${session}" || wait_rc=$?
  if [[ "${wait_rc}" != "0" ]]; then
    control_generation="$(ftctl_dr_scheduler_control_generation "${plan}")"
    control_command="$(ftctl_dr_scheduler_control_command "${plan}")"
    if [[ "${wait_rc}" != "21" || "${control_generation}" != "${generation}" ||
          "${control_command}" != "run" ]] ||
        ! ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"; then
      return "${wait_rc}"
    fi
    # A running worker can finish an in-flight RPO cycle before acknowledging
    # the new generation. The live lease and unchanged RUN request prove that
    # source protection is active while the protocol ACK converges.
    control_state="RUNNING_PENDING_ACK"
  fi
  ack_generation="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_control_ack_path "${plan}")" \
    "generation" 2>/dev/null || true)"
  [[ "${ack_generation}" =~ ^[0-9]+$ ]] || ack_generation=0
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${generation}" \
    "control_ack_generation=${ack_generation}" \
    "control_state=${control_state}" \
    "cycle_state=IDLE" \
    "transition_state=COMPLETED" \
    "updated_at=${now}" || true
}

ftctl_dr_scheduler_activate_reprotected_profile() {
  local plan="${1-}" reprotect_run="${2-}" profile_file="${3-}" reprotect_path="${4-}" status_path="${5-}"
  local scheduler_run scheduler_path generation session checkpoint_sequence target_durable_at source_checkpoint_at
  local sequence_path current_plan_sequence key value
  local -a authority_updates=()

  [[ -n "${plan}" && -n "${reprotect_run}" && -f "${profile_file}" && -f "${reprotect_path}" ]] || return 2
  scheduler_run="$(ftctl_dr_runtime_launch_nonce)"
  [[ -n "${scheduler_run}" ]] || return 2
  scheduler_path="$(ftctl_dr_runtime_run_path "${plan}" "${scheduler_run}")"
  checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${reprotect_path}" checkpoint_sequence)"
  target_durable_at="$(ftctl_dr_runtime_state_get_from_path "${reprotect_path}" last_target_durable_at)"
  source_checkpoint_at="$(ftctl_dr_runtime_state_get_from_path "${reprotect_path}" last_source_checkpoint_at)"
  [[ "${checkpoint_sequence}" =~ ^[0-9]+$ ]] || return 2
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  current_plan_sequence="$(ftctl_dr_scheduler_current_plan_sequence "${plan}")"
  [[ "${current_plan_sequence}" =~ ^[0-9]+$ ]] || current_plan_sequence=0
  (( current_plan_sequence >= checkpoint_sequence )) || current_plan_sequence="${checkpoint_sequence}"

  ftctl_dr_runtime_write_state "${scheduler_path}" "${plan}" "${scheduler_run}" \
    "dr-scheduler-run" "READY" "reprotect-scheduler-starting" "100" "${scheduler_run}" "" || return $?
  ftctl_dr_runtime_path_set "${scheduler_path}" \
    "accepted=true" \
    "active_side=TARGET" \
    "protection_state=READY" \
    "baseline_state=LOCAL_DURABLE" \
    "data_commit_state=LOCAL_DURABLE" \
    "target_durable=true" \
    "checkpoint_sequence=${checkpoint_sequence}" \
    "current_checkpoint_sequence=${checkpoint_sequence}" \
    "current_checkpoint_state=COMPLETED" \
    "latest_completed_checkpoint_sequence=${checkpoint_sequence}" \
    "latest_completed_checkpoint_state=READY" \
    "last_source_checkpoint_at=${source_checkpoint_at}" \
    "last_target_durable_at=${target_durable_at}" \
    "latest_completed_source_checkpoint_at=${source_checkpoint_at}" \
    "latest_completed_target_durable_at=${target_durable_at}" \
    "reprotect_parent_run_uuid=${reprotect_run}" \
    "scheduler_desired_state=RUNNING" \
    "scheduler_health=RECOVERING" \
    "updated_at=$(ftctl_now_iso8601)" || return $?
  for key in \
    cloud_authority_generation \
    cloud_authority_sequence_floor \
    cloud_cutover_session_id \
    target_power_state \
    target_promotion_state \
    source_fence_state \
    source_power_state; do
    value="$(ftctl_dr_runtime_state_get_from_path "${reprotect_path}" "${key}")"
    [[ -n "${value}" ]] && authority_updates+=("${key}=${value}")
  done
  (( ${#authority_updates[@]} == 0 )) || \
    ftctl_dr_runtime_path_set "${scheduler_path}" "${authority_updates[@]}" || return $?
  ftctl_state_set_path "${sequence_path}" \
    "plan_cycle_sequence=${current_plan_sequence}" \
    "reprotect_baseline_sequence=${checkpoint_sequence}" \
    "reprotect_baseline_run_uuid=${reprotect_run}" \
    "reprotect_baseline_committed_at=$(ftctl_now_iso8601)" || return $?

  generation="$(ftctl_dr_scheduler_control_set "${plan}" "run" "reprotect-complete" "${scheduler_run}" "false")" || return $?
  ftctl_dr_scheduler_ensure_running "${plan}" "${scheduler_run}" "${profile_file}" \
    "${scheduler_path}" "${status_path}" || return $?
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  ftctl_dr_scheduler_wait_for_ack "${plan}" "${generation}" "RUNNING" \
    "${FTCTL_DR_CONTROL_ACK_TIMEOUT_SEC}" "${scheduler_run}" "${session}" || return $?
  ftctl_dr_runtime_path_set "${reprotect_path}" \
    "scheduler_owner_run_uuid=${scheduler_run}" \
    "scheduler_session_uuid=${session}" \
    "scheduler_state=RUNNING" \
    "scheduler_health=HEALTHY" \
    "scheduler_desired_state=RUNNING" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${generation}" \
    "control_ack_generation=${generation}" \
    "control_state=RUNNING" \
    "updated_at=$(ftctl_now_iso8601)" || return $?
  FTCTL_DR_REPROTECT_SCHEDULER_RUN="${scheduler_run}"
}

ftctl_dr_scheduler_update_state() {
  local state_path="${1-}" status_path="${2-}"
  shift 2
  ftctl_dr_runtime_path_set "${state_path}" "$@" || return $?
  ftctl_dr_runtime_atomic_copy "${state_path}" "${status_path}" "0644" || return $?
}

ftctl_dr_scheduler_checkpoint_value() {
  local checkpoint_path="${1-}" field="${2-}" expected_type="${3-string}"
  [[ -n "${checkpoint_path}" && -f "${checkpoint_path}" ]] || return 1
  python3 - "${checkpoint_path}" "${field}" "${expected_type}" <<'PY' 2>/dev/null
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(sys.argv[2])
expected = sys.argv[3]
if value is None:
    print("")
elif expected == "boolean":
    if not isinstance(value, bool):
        raise SystemExit(65)
    print("true" if value else "false")
elif expected == "integer":
    if isinstance(value, bool) or not isinstance(value, int):
        raise SystemExit(65)
    print(value)
elif expected == "string":
    if not isinstance(value, str):
        raise SystemExit(65)
    print(value)
else:
    raise SystemExit(65)
PY
}

ftctl_dr_scheduler_append_restore_point() {
  local restore_points_path="${1-}" plan="${2-}" run="${3-}" sequence="${4-}" cycle_type="${5-}" driver="${6-}" manifest_path="${7-}" checkpoint_path="${8-}" scheduler_duration_seconds="${9-}"
  ftctl_ensure_dir "$(dirname "${restore_points_path}")" "0755"
  python3 - "${restore_points_path}" "${plan}" "${run}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" "$(ftctl_now_iso8601)" "${scheduler_duration_seconds}" <<'PY'
import json
import os
import sys

restore_path, plan, run, sequence, cycle_type, driver, manifest_path, checkpoint_path, now, scheduler_duration = sys.argv[1:11]
checkpoint = {}
if os.path.exists(checkpoint_path):
    with open(checkpoint_path, "r", encoding="utf-8") as fh:
        checkpoint = json.load(fh)
record = {
    "planUuid": plan,
    "runUuid": run,
    "producerRunUuid": run,
    "checkpointSequence": int(sequence),
    "checkpointRef": f"ftctl:{plan}:{run}:{sequence}",
    "cycleType": cycle_type,
    "driver": driver,
    "manifest": manifest_path,
    "checkpoint": checkpoint_path,
    "sourceCheckpointAt": checkpoint.get("sourceCheckpointAt"),
    "targetDurableAt": checkpoint.get("targetDurableAt"),
    "targetReadyRpoSeconds": checkpoint.get("targetReadyRpoSeconds"),
    "state": checkpoint.get("state"),
    "recordedAt": now,
}
if scheduler_duration.isdigit():
    record["schedulerDurationSeconds"] = int(scheduler_duration)
metrics = checkpoint.get("cycleMetrics") or {}
if metrics:
    record["cycleMetrics"] = metrics
    for key in (
        "cycleUuid", "cycleToken", "requestedMode", "effectiveMode",
        "automaticReseed", "modeDecisionCode", "reseedReason", "invalidBaselineDiskCount",
        "incrementalVerified", "metricsEstimated", "baselineGeneration", "cycleCommitState", "cycleMetricsPath",
        "virtualBytes", "changedBytes", "sourceReadBytes", "targetWrittenBytes",
        "transferPayloadBytes", "changedExtentCount", "durationMs", "throughputBps",
        "nbdTeardownState", "nbdTeardownStartedAtEpochMs", "nbdTeardownCompletedAtEpochMs",
        "nbdTeardownDurationMs", "nbdSourceDeviceCount", "nbdTargetDeviceCount",
        "nbdQuarantinedDeviceCount", "nbdTeardownErrorCode", "nbdTeardownErrorMessage",
    ):
        if key in metrics:
            record[key] = metrics[key]
if os.path.exists(restore_path):
    with open(restore_path, encoding="utf-8") as previous:
        for line in previous:
            existing = json.loads(line)
            if existing.get("checkpointRef") == record["checkpointRef"]:
                if existing.get("checkpointSequence") != record["checkpointSequence"] or existing.get("producerRunUuid") != record["producerRunUuid"]:
                    raise SystemExit("DR_CHECKPOINT_IDENTITY_MISMATCH")
                raise SystemExit(0)
with open(restore_path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
    fh.flush()
    os.fsync(fh.fileno())
PY
}

ftctl_dr_scheduler_driver_name() {
  local source_provider="${1-}" target_provider="${2-}"
  if [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "ABLESTACK" ]]; then
    printf 'ABLESTACK\n'
  elif [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "VMWARE" ]]; then
    printf 'KVM_VDDK_WRITER\n'
  elif [[ "${source_provider}" == "VMWARE" && "${target_provider}" == "ABLESTACK" ]]; then
    printf 'VMWARE_CBT_READER\n'
  elif [[ "${source_provider}" == "VMWARE" && "${target_provider}" == "VMWARE" ]]; then
    printf 'VMWARE\n'
  else
    printf 'MIXED\n'
  fi
}

ftctl_dr_scheduler_cycle_type() {
  local sequence="${1-}" source_provider="${2-}" state_path="${3-}" disk_map="" latest_completed_sequence=""
  local target_provider="${4-}" plan="${5-}" baseline=""
  if [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "VMWARE" ]]; then
    baseline="$(ftctl_dr_kvm_vmware_baseline_path "${plan}" 2>/dev/null || true)"
    if [[ ! -f "${baseline}" ]] || ! jq -e '.state == "LOCAL_DURABLE" and (.disks | length > 0)' "${baseline}" >/dev/null 2>&1; then
      printf 'full-reverse-seed\n'
    else
      printf 'reverse-incremental\n'
    fi
  elif [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "ABLESTACK" ]]; then
    latest_completed_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "latest_completed_checkpoint_sequence" 2>/dev/null || true)"
    if [[ ! "${latest_completed_sequence}" =~ ^[1-9][0-9]*$ ]]; then
      printf 'full-seed\n'
    else
      printf 'incremental\n'
    fi
  elif [[ "${sequence}" == "1" ]]; then
    printf 'full-seed\n'
  elif [[ "${source_provider}" == "VMWARE" ]]; then
    disk_map="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_disk_map_path")"
    if [[ -n "${disk_map}" && -f "${disk_map}" ]] &&
        jq -e '.disks | [
          .[] | select(
            (.changeId // .cbtChangeId // "") == ""
            or ((.baselineState // "") != "" and .baselineState != "LOCAL_DURABLE")
            or (.baselineGeneration // 0) <= 0
          )
        ] | length > 0' "${disk_map}" >/dev/null 2>&1; then
      printf 'full-reseed\n'
    else
      printf 'incremental\n'
    fi
  else
    printf 'incremental\n'
  fi
}

ftctl_dr_scheduler_run_cycle() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" sequence="${4-}" cycle_type="${5-}"
  local source_provider target_provider
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  if [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "ABLESTACK" ]]; then
    ftctl_dr_ablestack_replication_cycle "${plan}" "${run}" "${profile_file}" "${sequence}" "${cycle_type}"
    return $?
  fi
  if [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "VMWARE" ]]; then
    ftctl_dr_kvm_vmware_replication_cycle "${plan}" "${run}" "${profile_file}" "${sequence}" "${cycle_type}"
    return $?
  fi
  if [[ "${source_provider}" == "VMWARE" ]]; then
    ftctl_dr_vmware_replication_cycle "${plan}" "${run}" "${profile_file}" "${sequence}" "${cycle_type}"
    return $?
  fi
  return 66
}

ftctl_dr_scheduler_sleep_or_stop() {
  local plan="${1-}" interval="${2-}" expected_generation="${3-}"
  local deadline_epoch now_epoch command generation session epoch run pid start_ticks
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval="0"
  deadline_epoch=$(( $(ftctl_dr_scheduler_now_epoch) + interval ))
  while true; do
    now_epoch="$(ftctl_dr_scheduler_now_epoch)"
    (( now_epoch < deadline_epoch )) || break
    command="$(ftctl_dr_scheduler_control_command "${plan}")"
    generation="$(ftctl_dr_scheduler_control_generation "${plan}")"
    [[ "${command}" != "stop" && "${command}" != "pause" ]] || return 1
    if [[ "${expected_generation}" =~ ^[0-9]+$ && "${generation}" != "${expected_generation}" ]]; then
      return 1
    fi
    if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
      session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
      epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
      run="$(ftctl_dr_scheduler_active_value "${plan}" "worker_run_uuid")"
      pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
      start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
      ftctl_dr_scheduler_write_heartbeat "${plan}" "${session}" "${epoch}" "${run}" "${pid}" "${start_ticks}" || true
    fi
    sleep 1
  done
  return 0
}

ftctl_dr_scheduler_now_epoch() {
  date +%s
}

ftctl_dr_scheduler_last_sequence() {
  local restore_points_path="${1-}" plan="${2-}" run="${3-}"
  [[ -f "${restore_points_path}" ]] || {
    printf '0\n'
    return 0
  }
  python3 - "${restore_points_path}" "${plan}" <<'PY'
import json
import sys

path, plan = sys.argv[1:3]
latest = 0
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            record = json.loads(line)
        except (TypeError, ValueError):
            continue
        if record.get("planUuid") != plan:
            continue
        try:
            latest = max(latest, int(record.get("checkpointSequence") or 0))
        except (TypeError, ValueError):
            pass
print(latest)
PY
}

ftctl_dr_scheduler_latest_producer_run() {
  local restore_points_path="${1-}" plan="${2-}"
  [[ -f "${restore_points_path}" ]] || return 0
  python3 - "${restore_points_path}" "${plan}" <<'PY'
import json
import sys

path, plan = sys.argv[1:3]
latest = None
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            record = json.loads(line)
        except (TypeError, ValueError):
            continue
        if record.get("planUuid") == plan and record.get("runUuid"):
            latest = record
if latest:
    print(latest["runUuid"])
PY
}

ftctl_dr_scheduler_iso_from_epoch() {
  local epoch="${1-}"
  [[ "${epoch}" =~ ^[0-9]+$ ]] || return 1
  date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ'
}

ftctl_dr_scheduler_worker() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}"
  local pid_path restore_points_path interval max_cycles sequence=0 command cycle_type source_provider target_provider driver
  local output rc manifest_path checkpoint_path source_at target_at rpo now error_code error_message failed_component data_commit_state cycle_retry_mode checkpoint_ref
  local requested_mode effective_mode automatic_reseed mode_decision_code reseed_reason invalid_baseline_disk_count
  local incremental_verified metrics_estimated virtual_bytes changed_bytes source_read_bytes target_written_bytes transfer_payload_bytes changed_extent_count duration_ms throughput_bps baseline_generation cycle_token cycle_metrics_path
  local nbd_teardown_state nbd_teardown_started_at_ms nbd_teardown_completed_at_ms nbd_teardown_duration_ms
  local nbd_source_device_count nbd_target_device_count nbd_quarantined_device_count nbd_teardown_error_code nbd_teardown_error_message
  local cycle_started_epoch cycle_completed_epoch cycle_wall_duration_seconds
  local next_cycle_epoch next_cycle_at wait_seconds control_generation next_sequence execution_budget_seconds max_jitter_seconds
  local cycle_run cycle_request_mode cycle_request_owner cycle_request_state cycle_request_bound sequence_path transfer_progress_path
  local session lease_epoch authority_sequence start_ticks owner_lock_path
  local initial_jitter cycle_jitter bandwidth_limit_mbps resource_retry_sec resource_retry_attempt resource_retry_delay
  local resource_error_code resource_error_message resource_step resource_component
  local source_retry_attempt source_retry_delay source_outage_since cleanup_retry_attempt cleanup_retry_delay
  local pending_resource_sequence pending_resource_cycle_type pending_resource_run pending_resource_request_bound
  local pending_source_sequence pending_source_cycle_type pending_source_run pending_source_request_bound
  local pending_cleanup_sequence pending_cleanup_cycle_type pending_cleanup_run pending_cleanup_request_bound
  local pending_reseed_sequence pending_reseed_cycle_type pending_reseed_run pending_reseed_request_bound
  local pending_reseed_reason pending_reseed_attempt automatic_reseed_guard_generation current_baseline_generation
  local scheduler_code_path scheduler_code_sha256 scheduler_started_at worker_process_pid

  [[ -n "${plan}" && -n "${run}" && -f "${profile_file}" && -f "${state_path}" ]] || return 2
  ftctl_ensure_dir "$(ftctl_dr_scheduler_dir "${plan}")" "0755"
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  owner_lock_path="$(ftctl_dr_scheduler_owner_lock_path "${plan}")"
  exec 205>"${owner_lock_path}"
  if ! flock -n 205; then
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=ERROR" \
      "scheduler_health=DUPLICATE_WORKER" \
      "owner_matched=false" \
      "error_code=DR_SCHEDULER_DUPLICATE_WORKER" \
      "error_message=Plan scheduler owner lock is already held" \
      "updated_at=$(ftctl_now_iso8601)" || true
    exec 205>&-
    return 23
  fi
  lease_epoch=$(( $(ftctl_dr_scheduler_current_lease_epoch "${plan}") + 1 ))
  worker_process_pid="${BASHPID:-$$}"
  start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${worker_process_pid}" 2>/dev/null || true)"
  [[ "${start_ticks}" =~ ^[0-9]+$ ]] || start_ticks=0
  ftctl_dr_scheduler_write_heartbeat "${plan}" "${session}" "${lease_epoch}" "${run}" "${worker_process_pid}" "${start_ticks}"
  pid_path="$(ftctl_dr_scheduler_pid_path "${plan}" "${run}")"
  restore_points_path="$(ftctl_dr_scheduler_restore_points_path "${plan}")"
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  sequence="$(ftctl_dr_scheduler_last_sequence "${restore_points_path}" "${plan}" "${run}" || printf '0')"
  [[ "${sequence}" =~ ^[0-9]+$ ]] || sequence=0
  local persisted_sequence
  persisted_sequence="$(ftctl_dr_scheduler_current_plan_sequence "${plan}")"
  (( sequence >= persisted_sequence )) || sequence="${persisted_sequence}"
  interval="$(ftctl_dr_scheduler_interval "${profile_file}")"
  max_cycles="$(ftctl_dr_scheduler_max_cycles "${profile_file}")"
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  driver="$(ftctl_dr_scheduler_driver_name "${source_provider}" "${target_provider}")"
  bandwidth_limit_mbps="$(ftctl_dr_scheduler_profile_int "${profile_file}" "policy.bandwidthLimitMbps" "0")"
  [[ "${bandwidth_limit_mbps}" =~ ^[0-9]+$ ]] || bandwidth_limit_mbps=0
  resource_retry_sec="${FTCTL_DR_RESOURCE_RETRY_SEC}"
  [[ "${resource_retry_sec}" =~ ^[1-9][0-9]*$ ]] || resource_retry_sec=15
  scheduler_code_path="${BASH_SOURCE[0]}"
  scheduler_code_sha256="$(sha256sum "${scheduler_code_path}" 2>/dev/null | awk '{print $1}')"
  scheduler_started_at="$(ftctl_now_iso8601)"

  printf '%s\n' "${worker_process_pid}" > "${pid_path}"
  control_generation="$(ftctl_dr_scheduler_initialize_control "${plan}" "${run}")" || return $?
  local startup_state=RUNNING startup_activity=IDLE
  command="$(ftctl_dr_scheduler_control_command "${plan}")"
  case "${command}" in
    pause) startup_state=PAUSED; startup_activity=PAUSED ;;
    stop) startup_state=STOPPED; startup_activity=STOPPED ;;
  esac
  ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "${startup_state}" "IDLE" "${run}" \
    "${session}" "${lease_epoch}" "${worker_process_pid}" "${start_ticks}"
  authority_sequence="$(ftctl_dr_scheduler_next_authority_sequence "${plan}")"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "scheduler_state=${startup_state}" \
    "scheduler_health=HEALTHY" \
    "replication_activity=${startup_activity}" \
    "protection_state=$([[ "${sequence}" -gt 0 ]] && printf READY || printf SYNCING)" \
    "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
    "control_generation=${control_generation}" \
    "control_ack_generation=${control_generation}" \
    "control_state=${startup_state}" \
    "cycle_state=IDLE" \
    "worker_pid=${worker_process_pid}" \
    "scheduler_session_uuid=${session}" \
    "scheduler_lease_epoch=${lease_epoch}" \
    "authority_sequence=${authority_sequence}" \
    "active_worker_run_uuid=${run}" \
    "active_worker_pid=${worker_process_pid}" \
    "active_worker_start_ticks=${start_ticks}" \
    "scheduler_code_path=${scheduler_code_path}" \
    "scheduler_code_sha256=${scheduler_code_sha256}" \
    "scheduler_started_at=${scheduler_started_at}" \
    "worker_heartbeat_at=${now}" \
    "owner_matched=true" \
    "restore_points_path=${restore_points_path}" \
    "driver=${driver}" \
    "updated_at=${now}" || true
  ftctl_log_event "dr-runtime" "dr.scheduler.start" "ok" "" "" \
    "plan=${plan} run=${run} driver=${driver} interval=${interval} max_cycles=${max_cycles}"

  cycle_request_state="$(ftctl_state_read_kv "${sequence_path}" "requested_cycle_state" 2>/dev/null || true)"
  if [[ "${command}" == "run" && "${cycle_request_state}" != "PENDING" ]]; then
    initial_jitter="$(ftctl_dr_scheduler_initial_jitter "${plan}" "${profile_file}" "${interval}")"
    if [[ "${initial_jitter}" =~ ^[1-9][0-9]*$ ]]; then
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "scheduler_state=${startup_state}" \
        "scheduler_health=HEALTHY" \
        "replication_activity=WAITING_SCHEDULE" \
        "initial_jitter_seconds=${initial_jitter}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      ftctl_dr_scheduler_sleep_or_stop "${plan}" "${initial_jitter}" "${control_generation}" || true
    fi
  fi

  while true; do
    if ! ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}" \
        && ! ftctl_dr_scheduler_repair_self_ownership "${plan}" "${session}" "${lease_epoch}" "${run}" "${worker_process_pid}" "${start_ticks}"; then
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=ERROR" \
        "scheduler_state=ERROR" \
        "scheduler_health=OWNER_MISMATCH" \
        "replication_activity=STOPPED" \
        "owner_matched=false" \
        "error_code=DR_SCHEDULER_OWNER_MISMATCH" \
        "error_message=Scheduler lease no longer belongs to this worker" \
        "updated_at=$(ftctl_now_iso8601)" || true
      break
    fi
    ftctl_dr_scheduler_write_heartbeat "${plan}" "${session}" "${lease_epoch}" "${run}" "${worker_process_pid}" "${start_ticks}" || true
    command="$(ftctl_dr_scheduler_control_command "${plan}")"
    control_generation="$(ftctl_dr_scheduler_control_value "${plan}" "generation")"
    if [[ "${command}" == "stop" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "STOPPED" "IDLE" "${run}" \
        "${session}" "${lease_epoch}" "${worker_process_pid}" "${start_ticks}"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=CANCELED" \
        "step=scheduler-stopped" \
        "progress=100" \
        "scheduler_state=STOPPED" \
        "scheduler_health=STOPPED" \
        "replication_activity=STOPPED" \
        "control_generation=${control_generation}" \
        "control_ack_generation=${control_generation}" \
        "control_state=STOPPED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      break
    fi

    if [[ "${command}" == "pause" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "PAUSED" "IDLE" "${run}" \
        "${session}" "${lease_epoch}" "${worker_process_pid}" "${start_ticks}"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=PAUSED" \
        "step=sync-paused" \
        "scheduler_state=PAUSED" \
        "scheduler_health=HEALTHY" \
        "replication_activity=PAUSED" \
        "protection_state=PAUSED" \
        "control_generation=${control_generation}" \
        "control_ack_generation=${control_generation}" \
        "control_state=PAUSED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      sleep 1
      continue
    fi

    ftctl_dr_scheduler_control_ack "${plan}" "${control_generation}" "RUNNING" "IDLE" "${run}" \
      "${session}" "${lease_epoch}" "${worker_process_pid}" "${start_ticks}"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=RUNNING" \
      "scheduler_health=HEALTHY" \
      "replication_activity=IDLE" \
      "protection_state=$([[ "${sequence}" -gt 0 ]] && printf READY || printf SYNCING)" \
      "control_generation=${control_generation}" \
      "control_ack_generation=${control_generation}" \
      "control_state=RUNNING" \
      "cycle_state=IDLE" \
      "retryable=false" \
      "retry_after_sec=" \
      "error_code=" \
      "error_message=" \
      "updated_at=$(ftctl_now_iso8601)" || true

    persisted_sequence="$(ftctl_dr_scheduler_current_plan_sequence "${plan}")"
    (( sequence >= persisted_sequence )) || sequence="${persisted_sequence}"
    pending_resource_sequence="$(ftctl_state_read_kv "${sequence_path}" "pending_resource_sequence" 2>/dev/null || true)"
    pending_resource_cycle_type="$(ftctl_state_read_kv "${sequence_path}" "pending_resource_cycle_type" 2>/dev/null || true)"
    pending_resource_run="$(ftctl_state_read_kv "${sequence_path}" "pending_resource_run" 2>/dev/null || true)"
    pending_resource_request_bound="$(ftctl_state_read_kv "${sequence_path}" "pending_resource_request_bound" 2>/dev/null || true)"
    resource_retry_attempt="$(ftctl_state_read_kv "${sequence_path}" "resource_retry_attempt" 2>/dev/null || true)"
    [[ "${resource_retry_attempt}" =~ ^[0-9]+$ ]] || resource_retry_attempt=0
    pending_source_sequence="$(ftctl_state_read_kv "${sequence_path}" "pending_source_sequence" 2>/dev/null || true)"
    pending_source_cycle_type="$(ftctl_state_read_kv "${sequence_path}" "pending_source_cycle_type" 2>/dev/null || true)"
    pending_source_run="$(ftctl_state_read_kv "${sequence_path}" "pending_source_run" 2>/dev/null || true)"
    pending_source_request_bound="$(ftctl_state_read_kv "${sequence_path}" "pending_source_request_bound" 2>/dev/null || true)"
    source_retry_attempt="$(ftctl_state_read_kv "${sequence_path}" "source_retry_attempt" 2>/dev/null || true)"
    [[ "${source_retry_attempt}" =~ ^[0-9]+$ ]] || source_retry_attempt=0
    pending_cleanup_sequence="$(ftctl_state_read_kv "${sequence_path}" "pending_cleanup_sequence" 2>/dev/null || true)"
    pending_cleanup_cycle_type="$(ftctl_state_read_kv "${sequence_path}" "pending_cleanup_cycle_type" 2>/dev/null || true)"
    pending_cleanup_run="$(ftctl_state_read_kv "${sequence_path}" "pending_cleanup_run" 2>/dev/null || true)"
    pending_cleanup_request_bound="$(ftctl_state_read_kv "${sequence_path}" "pending_cleanup_request_bound" 2>/dev/null || true)"
    cleanup_retry_attempt="$(ftctl_state_read_kv "${sequence_path}" "cleanup_retry_attempt" 2>/dev/null || true)"
    [[ "${cleanup_retry_attempt}" =~ ^[0-9]+$ ]] || cleanup_retry_attempt=0
    pending_reseed_sequence="$(ftctl_state_read_kv "${sequence_path}" "pending_reseed_sequence" 2>/dev/null || true)"
    pending_reseed_cycle_type="$(ftctl_state_read_kv "${sequence_path}" "pending_reseed_cycle_type" 2>/dev/null || true)"
    pending_reseed_run="$(ftctl_state_read_kv "${sequence_path}" "pending_reseed_run" 2>/dev/null || true)"
    pending_reseed_request_bound="$(ftctl_state_read_kv "${sequence_path}" "pending_reseed_request_bound" 2>/dev/null || true)"
    pending_reseed_reason="$(ftctl_state_read_kv "${sequence_path}" "pending_reseed_reason" 2>/dev/null || true)"
    pending_reseed_attempt="$(ftctl_state_read_kv "${sequence_path}" "pending_reseed_attempt" 2>/dev/null || true)"
    [[ "${pending_reseed_attempt}" =~ ^[0-9]+$ ]] || pending_reseed_attempt=0
    automatic_reseed_guard_generation="$(ftctl_state_read_kv "${sequence_path}" "automatic_reseed_guard_generation" 2>/dev/null || true)"
    [[ "${automatic_reseed_guard_generation}" =~ ^[0-9]+$ ]] || automatic_reseed_guard_generation=""
    if [[ "${pending_reseed_sequence}" =~ ^[1-9][0-9]*$ ]]; then
      next_sequence="${pending_reseed_sequence}"
    elif [[ "${pending_cleanup_sequence}" =~ ^[1-9][0-9]*$ ]]; then
      next_sequence="${pending_cleanup_sequence}"
    elif [[ "${pending_source_sequence}" =~ ^[1-9][0-9]*$ ]]; then
      next_sequence="${pending_source_sequence}"
    elif [[ "${pending_resource_sequence}" =~ ^[1-9][0-9]*$ ]]; then
      next_sequence="${pending_resource_sequence}"
    else
      next_sequence=$((sequence + 1))
    fi
    cycle_run="${run}"
    cycle_request_bound="false"
    cycle_request_state="$(ftctl_state_read_kv "${sequence_path}" "requested_cycle_state" 2>/dev/null || true)"
    cycle_request_mode="$(ftctl_state_read_kv "${sequence_path}" "requested_cycle_mode" 2>/dev/null || true)"
    cycle_request_owner="$(ftctl_state_read_kv "${sequence_path}" "requested_cycle_owner_run" 2>/dev/null || true)"
    if [[ "${pending_reseed_sequence}" =~ ^[1-9][0-9]*$ && -n "${pending_reseed_cycle_type}" ]]; then
      cycle_type="${pending_reseed_cycle_type}"
      [[ -n "${pending_reseed_run}" ]] && cycle_run="${pending_reseed_run}"
      cycle_request_bound="${pending_reseed_request_bound:-false}"
    elif [[ "${pending_cleanup_sequence}" =~ ^[1-9][0-9]*$ && -n "${pending_cleanup_cycle_type}" ]]; then
      cycle_type="${pending_cleanup_cycle_type}"
      [[ -n "${pending_cleanup_run}" ]] && cycle_run="${pending_cleanup_run}"
      cycle_request_bound="${pending_cleanup_request_bound:-false}"
    elif [[ "${pending_source_sequence}" =~ ^[1-9][0-9]*$ && -n "${pending_source_cycle_type}" ]]; then
      cycle_type="${pending_source_cycle_type}"
      [[ -n "${pending_source_run}" ]] && cycle_run="${pending_source_run}"
      cycle_request_bound="${pending_source_request_bound:-false}"
    elif [[ "${pending_resource_sequence}" =~ ^[1-9][0-9]*$ && -n "${pending_resource_cycle_type}" ]]; then
      cycle_type="${pending_resource_cycle_type}"
      [[ -n "${pending_resource_run}" ]] && cycle_run="${pending_resource_run}"
      cycle_request_bound="${pending_resource_request_bound:-false}"
    elif [[ "${cycle_request_state}" == "PENDING" && "${cycle_request_mode}" == "FULL_RESEED" ]]; then
      cycle_type="full-reseed"
      [[ -n "${cycle_request_owner}" ]] && cycle_run="${cycle_request_owner}"
      cycle_request_bound="true"
    else
      cycle_type="$(ftctl_dr_scheduler_cycle_type "${next_sequence}" "${source_provider}" "${state_path}" "${target_provider}" "${plan}")"
    fi
    local checkpoint_pending_path
    checkpoint_pending_path="$(ftctl_dr_checkpoint_pending_path "${plan}")"
    if ftctl_dr_checkpoint_enabled "${profile_file}" && [[ -s "${checkpoint_pending_path}" ]]; then
      local pending_export_generation current_export_generation
      pending_export_generation="$(jq -r '.exportGeneration // 0' "${checkpoint_pending_path}")"
      current_export_generation="$(jq -r '.transport.exports[0].exportGeneration // 0' "${profile_file}")"
      if [[ "${pending_export_generation}" != "${current_export_generation}" ]]; then
        # Authority changed while ACK was missing. Never relabel current backing
        # as that old candidate; preserve evidence and restart from a full seed.
        local abandoned_checkpoint_sequence
        abandoned_checkpoint_sequence="$(jq -r '.request.checkpointSequence' "${checkpoint_pending_path}")"
        if [[ "${abandoned_checkpoint_sequence}" =~ ^[0-9]+$ ]] && (( next_sequence <= abandoned_checkpoint_sequence )); then
          next_sequence=$((abandoned_checkpoint_sequence + 1))
        fi
        mv "${checkpoint_pending_path}" "${checkpoint_pending_path}.abandoned-$(date +%s%N)"
        cycle_type="full-reseed"
        pending_reseed_sequence="${next_sequence}"
        pending_reseed_reason="TARGET_EXPORT_GENERATION_CHANGED"
      fi
    fi
    if ftctl_dr_checkpoint_enabled "${profile_file}" && [[ -s "${checkpoint_pending_path}" ]]; then
      next_sequence="$(jq -r '.request.checkpointSequence' "${checkpoint_pending_path}")"
      cycle_run="$(jq -r '.request.producerRunUuid' "${checkpoint_pending_path}")"
      local pending_cycle_context
      if ! pending_cycle_context="$(ftctl_dr_checkpoint_resume_context "${checkpoint_pending_path}" \
        "${cycle_request_state}" "${cycle_request_mode}" "${cycle_request_owner}" \
        "$(ftctl_state_read_kv "${sequence_path}" requested_cycle_sequence 2>/dev/null || true)")"; then
        if [[ "${cycle_request_state}" == "PENDING" && "${cycle_request_mode}" == "FULL_RESEED" \
            && -n "${cycle_request_owner}" && "${cycle_request_owner}" != "${cycle_run}" ]]; then
          # Preserve rejected evidence. Only an explicit new recovery request may
          # supersede it; never relabel or approve another producer's candidate.
          ftctl_dr_checkpoint_abandon_invalid "${checkpoint_pending_path}" "${plan}" \
            "${cycle_request_owner}" || return 108
          continue
        fi
        ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
          "state=ERROR" "step=checkpoint-recovery-required" \
          "scheduler_state=RUNNING" "scheduler_health=RECOVERY_REQUIRED" \
          "scheduler_recovery_state=FAILED" "cycle_retry_mode=OPERATOR_REPAIR_REQUIRED" \
          "cycle_state=FAILED" "replication_activity=STOPPED" \
          "protection_state=DEGRADED" "retryable=false" \
          "error_code=DR_CHECKPOINT_CANDIDATE_INVALID" \
          "error_message=Checkpoint evidence does not match its producer; request full resynchronization" \
          "updated_at=$(ftctl_now_iso8601)" || true
        ftctl_dr_scheduler_sleep_or_stop "${plan}" 30 "${control_generation}" || true
        continue
      fi
      IFS=$'\t' read -r cycle_type cycle_request_bound <<< "${pending_cycle_context}"
    fi
    checkpoint_ref="ftctl:${plan}:${cycle_run}:${next_sequence}"
    transfer_progress_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${cycle_run}" progress)"
    cycle_started_epoch="$(date +%s)"
    now="$(ftctl_now_iso8601)"
    if ! ftctl_dr_scheduler_lock_acquire "${plan}" "cycle" 202 0 "${run}:${sequence}"; then
      sleep 1
      continue
    fi
    if ! ftctl_dr_scheduler_slot_acquire "${plan}" "${profile_file}" "${cycle_type}" 203; then
      ftctl_dr_scheduler_lock_release "${plan}" "cycle" 202
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=$([[ "${sequence}" -gt 0 ]] && printf READY || printf SYNCING)" \
        "step=waiting-resource-slot" \
        "scheduler_state=RUNNING" \
        "scheduler_health=WAITING_RESOURCE" \
        "cycle_state=WAITING_RESOURCE" \
        "replication_activity=WAITING_RESOURCE" \
        "resource_slot_class=${FTCTL_DR_WAITING_SLOT_CLASS:-unknown}" \
        "resource_slot_limit=${FTCTL_DR_WAITING_SLOT_LIMIT:-0}" \
        "retryable=true" \
        "retry_after_sec=${resource_retry_sec}" \
        "error_code=DR_RESOURCE_BUSY" \
        "error_message=Replication capacity is temporarily unavailable" \
        "updated_at=$(ftctl_now_iso8601)" || true
      ftctl_log_event "dr-runtime" "dr.scheduler.admission" "skip" "" "97" \
        "plan=${plan} cycle_type=${cycle_type} reason=resource_slots_exhausted retry_after=${resource_retry_sec}"
      ftctl_dr_scheduler_sleep_or_stop "${plan}" "${resource_retry_sec}" "${control_generation}" || true
      continue
    fi
    sequence="${next_sequence}"
    if [[ "${pending_resource_sequence}" == "${sequence}" || "${pending_source_sequence}" == "${sequence}" \
        || "${pending_cleanup_sequence}" == "${sequence}" || "${pending_reseed_sequence}" == "${sequence}" ]]; then
      authority_sequence="$(ftctl_dr_scheduler_next_authority_sequence "${plan}")"
    else
      authority_sequence="$(ftctl_dr_scheduler_record_plan_sequence "${plan}" "${sequence}")"
    fi
    if [[ "${cycle_request_bound}" == "true" ]]; then
      ftctl_state_set_path "${sequence_path}" \
        "requested_cycle_state=RUNNING" \
        "requested_cycle_sequence=${sequence}" \
        "requested_cycle_started_at=${now}" || true
    fi
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "state=$([[ "${sequence}" -gt 1 ]] && printf READY || printf SYNCING)" \
      "step=${cycle_type}-transfer" \
      "progress=40" \
      "scheduler_state=RUNNING" \
      "next_cycle_at=" \
      "next_cycle_wait_seconds=" \
      "control_generation=${control_generation}" \
      "control_ack_generation=${control_generation}" \
      "control_state=RUNNING" \
      "cycle_state=RUNNING" \
      "replication_activity=TRANSFERRING" \
      "protection_state=$([[ "${sequence}" -gt 1 ]] && printf READY || printf SYNCING)" \
      "checkpoint_sequence=${sequence}" \
      "checkpoint_cycle_type=${cycle_type}" \
      "checkpoint_ref=${checkpoint_ref}" \
      "current_checkpoint_sequence=${sequence}" \
      "current_checkpoint_cycle_type=${cycle_type}" \
      "current_checkpoint_requested_mode=$([[ "${cycle_type}" == "full-seed" ]] && printf FULL_SEED || { [[ "${cycle_type}" == "full-reseed" ]] && printf FULL_RESEED || printf CBT_INCREMENTAL; })" \
      "current_checkpoint_effective_mode=" \
      "current_checkpoint_mode_decision_code=" \
      "current_checkpoint_automatic_reseed=false" \
      "current_checkpoint_invalid_baseline_disk_count=0" \
      "current_checkpoint_ref=${checkpoint_ref}" \
      "current_checkpoint_state=TRANSFERRING" \
      "transfer_progress_path=${transfer_progress_path}" \
      "runtime_generation=${authority_sequence}" \
      "scheduler_session_uuid=${session}" \
      "scheduler_lease_epoch=${lease_epoch}" \
      "authority_sequence=${authority_sequence}" \
      "plan_cycle_sequence=${sequence}" \
      "scheduler_health=HEALTHY" \
      "owner_matched=true" \
      "baseline_state=$([[ "${cycle_type}" == "full-reseed" ]] && printf REBUILDING || printf COMMITTED)" \
      "reseed_reason=$([[ "${cycle_type}" == "full-reseed" ]] && printf MISSING_OR_INVALID_COMMITTED_BASELINE || printf '')" \
      "resource_slot_class=$(ftctl_dr_scheduler_slot_class "${cycle_type}")" \
      "retryable=false" \
      "retry_after_sec=" \
      "error_code=" \
      "error_message=" \
      "updated_at=${now}" || true
    if [[ "${cycle_request_bound}" == "true" ]]; then
      ftctl_dr_scheduler_project_requested_cycle_run "${plan}" "${cycle_run}" "${status_path}" \
        "SYNCING" "full-reseed-transfer" "40" "" "" || true
    fi

    rc=0
    if ftctl_dr_checkpoint_enabled "${profile_file}" && [[ -s "${checkpoint_pending_path}" ]]; then
      output="$(jq -r '.output' "${checkpoint_pending_path}")"
    else
    output="$(FTCTL_DR_TRANSFER_PROGRESS_PATH="${transfer_progress_path}" \
      FTCTL_DR_BANDWIDTH_LIMIT_MBPS="${bandwidth_limit_mbps}" \
      FTCTL_DR_AUTOMATIC_RESEED_REASON="$([[ "${pending_reseed_sequence}" == "${sequence}" ]] && printf '%s' "${pending_reseed_reason}")" \
      ftctl_dr_scheduler_run_cycle "${plan}" "${cycle_run}" "${profile_file}" "${sequence}" "${cycle_type}")" || rc=$?
    fi
    if [[ "${rc}" == "0" ]]; then
      ftctl_dr_checkpoint_barrier "${plan}" "${cycle_run}" "${sequence}" "${output}" "${profile_file}" "${cycle_type}" || rc=$?
    fi
    ftctl_dr_scheduler_slot_release 203
    ftctl_dr_scheduler_lock_release "${plan}" "cycle" 202
    if [[ "${rc}" == "107" ]]; then
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "step=waiting-checkpoint-publication" "cycle_state=WAITING_CHECKPOINT" \
        "scheduler_state=RUNNING" "scheduler_health=WAITING_TARGET" \
        "replication_activity=WAITING_CHECKPOINT" "retryable=true" \
        "updated_at=$(ftctl_now_iso8601)" || true
      sleep 2
      continue
    fi
    if [[ "${rc}" != "0" ]]; then
      if [[ "${rc}" == "97" || "${rc}" == "100" ]]; then
        now="$(ftctl_now_iso8601)"
        resource_error_code="DR_RESOURCE_BUSY"
        resource_error_message="An NBD resource is temporarily unavailable"
        resource_step="waiting-nbd-resource"
        resource_component="nbd-resource"
        if [[ "${rc}" == "100" ]]; then
          resource_error_code="DR_TARGET_EXPORT_UNAVAILABLE"
          resource_error_message="The target site export is temporarily unavailable and will be reconciled automatically"
          resource_step="waiting-target-export"
          resource_component="target-export"
        fi
        resource_retry_attempt=$((resource_retry_attempt + 1))
        resource_retry_delay="$(ftctl_dr_scheduler_resource_retry_delay "${resource_retry_attempt}")"
        ftctl_state_set_path "${sequence_path}" \
          "pending_resource_sequence=${sequence}" \
          "pending_resource_cycle_type=${cycle_type}" \
          "pending_resource_run=${cycle_run}" \
          "pending_resource_request_bound=${cycle_request_bound}" \
          "resource_retry_attempt=${resource_retry_attempt}" \
          "resource_retry_after_sec=${resource_retry_delay}" \
          "resource_retry_updated_at=${now}" || true
        if [[ "${cycle_request_bound}" == "true" ]]; then
          ftctl_state_set_path "${sequence_path}" \
            "requested_cycle_state=PENDING" \
            "requested_cycle_sequence=" \
            "requested_cycle_started_at=" || true
        fi
        ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
          "state=$([[ "${sequence}" -gt 1 ]] && printf READY || printf SYNCING)" \
          "step=${resource_step}" \
          "scheduler_state=RUNNING" \
          "scheduler_health=WAITING_RESOURCE" \
          "cycle_state=WAITING_RESOURCE" \
          "replication_activity=WAITING_RESOURCE" \
          "current_checkpoint_state=WAITING_RESOURCE" \
          "retryable=true" \
          "retry_after_sec=${resource_retry_delay}" \
          "error_code=${resource_error_code}" \
          "error_message=${resource_error_message}" \
          "failed_component=${resource_component}" \
          "updated_at=${now}" || true
        ftctl_log_event "dr-runtime" "dr.scheduler.resource" "skip" "" "${rc}" \
          "plan=${plan} run=${cycle_run} sequence=${sequence} component=${resource_component} retry_attempt=${resource_retry_attempt} retry_after=${resource_retry_delay}"
        ftctl_dr_scheduler_sleep_or_stop "${plan}" "${resource_retry_delay}" "${control_generation}" || true
        continue
      fi
      if [[ "${rc}" == "98" || "${rc}" == "110" ]]; then
        now="$(ftctl_now_iso8601)"
        source_outage_since="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "source_outage_since" 2>/dev/null || true)"
        [[ -n "${source_outage_since}" ]] || source_outage_since="${now}"
        source_retry_attempt=$((source_retry_attempt + 1))
        source_retry_delay="$(ftctl_dr_scheduler_source_retry_delay "${plan}" "${source_retry_attempt}")"
        ftctl_state_set_path "${sequence_path}" \
          "pending_source_sequence=${sequence}" \
          "pending_source_cycle_type=${cycle_type}" \
          "pending_source_run=${cycle_run}" \
          "pending_source_request_bound=${cycle_request_bound}" \
          "source_retry_attempt=${source_retry_attempt}" \
          "source_retry_after_sec=${source_retry_delay}" \
          "source_retry_updated_at=${now}" || true
        if [[ "${cycle_request_bound}" == "true" ]]; then
          ftctl_state_set_path "${sequence_path}" \
            "requested_cycle_state=PENDING" \
            "requested_cycle_sequence=${sequence}" \
            "requested_cycle_started_at=${now}" || true
        fi
        ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
          "state=WAITING_SOURCE" \
          "step=waiting-source-recovery" \
          "scheduler_state=RUNNING" \
          "scheduler_health=WAITING_SOURCE" \
          "scheduler_recovery_state=$([[ "${rc}" == "110" ]] && printf REQUIRED || printf PENDING)" \
          "cycle_state=WAITING_SOURCE" \
          "replication_activity=WAITING_SOURCE" \
          "protection_state=DEGRADED" \
          "current_checkpoint_state=WAITING_SOURCE" \
          "failure_class=SOURCE_TRANSPORT" \
          "retryable=true" \
          "retry_after_sec=${source_retry_delay}" \
          "next_retry_at=$(ftctl_dr_scheduler_iso_from_epoch $(( $(date +%s) + source_retry_delay )))" \
          "source_outage_since=${source_outage_since}" \
          "error_code=$([[ "${rc}" == "110" ]] && printf DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE || printf DR_SOURCE_SITE_UNAVAILABLE)" \
          "error_message=Source runtime is unavailable on this worker; preserve the durable baseline and resolve current placement" \
          "updated_at=${now}" || true
        ftctl_log_event "dr-runtime" "dr.scheduler.source" "wait" "" "98" \
          "plan=${plan} run=${cycle_run} sequence=${sequence} retry_attempt=${source_retry_attempt} retry_after=${source_retry_delay}"
        ftctl_dr_scheduler_sleep_or_stop "${plan}" "${source_retry_delay}" "${control_generation}" || true
        continue
      fi
      if [[ "${rc}" == "99" ]]; then
        now="$(ftctl_now_iso8601)"
        cleanup_retry_attempt=$((cleanup_retry_attempt + 1))
        cleanup_retry_delay="$(ftctl_dr_scheduler_source_retry_delay "${plan}" "${cleanup_retry_attempt}")"
        ftctl_state_set_path "${sequence_path}" \
          "pending_cleanup_sequence=${sequence}" \
          "pending_cleanup_cycle_type=${cycle_type}" \
          "pending_cleanup_run=${cycle_run}" \
          "pending_cleanup_request_bound=${cycle_request_bound}" \
          "cleanup_retry_attempt=${cleanup_retry_attempt}" \
          "cleanup_retry_after_sec=${cleanup_retry_delay}" \
          "cleanup_retry_updated_at=${now}" || true
        if [[ "${cycle_request_bound}" == "true" ]]; then
          ftctl_state_set_path "${sequence_path}" \
            "requested_cycle_state=PENDING" \
            "requested_cycle_sequence=${sequence}" \
            "requested_cycle_started_at=${now}" || true
        fi
        ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
          "state=$([[ "${sequence}" -gt 1 ]] && printf READY || printf SYNCING)" \
          "step=waiting-source-snapshot-cleanup" \
          "scheduler_state=RUNNING" \
          "scheduler_health=WAITING_CLEANUP" \
          "scheduler_recovery_state=PENDING" \
          "cycle_state=WAITING_CLEANUP" \
          "replication_activity=WAITING_CLEANUP" \
          "protection_state=DEGRADED" \
          "current_checkpoint_state=WAITING_CLEANUP" \
          "failure_class=SOURCE_SNAPSHOT_CLEANUP" \
          "retryable=true" \
          "retry_after_sec=${cleanup_retry_delay}" \
          "next_retry_at=$(ftctl_dr_scheduler_iso_from_epoch $(( $(date +%s) + cleanup_retry_delay )))" \
          "error_code=DR_VMWARE_SNAPSHOT_CLEANUP_PENDING" \
          "error_message=The previous durable VMware source snapshot is awaiting cleanup" \
          "updated_at=${now}" || true
        ftctl_log_event "dr-runtime" "dr.scheduler.snapshot-cleanup" "wait" "" "99" \
          "plan=${plan} run=${cycle_run} sequence=${sequence} retry_attempt=${cleanup_retry_attempt} retry_after=${cleanup_retry_delay}"
        ftctl_dr_scheduler_sleep_or_stop "${plan}" "${cleanup_retry_delay}" "${control_generation}" || true
        continue
      fi
      if [[ "${rc}" == "85" && "${cycle_type}" == "incremental" ]]; then
        now="$(ftctl_now_iso8601)"
        current_baseline_generation="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "latest_completed_baseline_generation" 2>/dev/null || true)"
        [[ "${current_baseline_generation}" =~ ^[0-9]+$ ]] || current_baseline_generation=0
        pending_reseed_attempt=$((pending_reseed_attempt + 1))
        if [[ -z "${automatic_reseed_guard_generation}" || "${automatic_reseed_guard_generation}" != "${current_baseline_generation}" ]]; then
          ftctl_state_set_path "${sequence_path}" \
            "pending_reseed_sequence=${sequence}" \
            "pending_reseed_cycle_type=full-reseed" \
            "pending_reseed_run=${cycle_run}" \
            "pending_reseed_request_bound=${cycle_request_bound}" \
            "pending_reseed_reason=SOURCE_CBT_EPOCH_RESET" \
            "pending_reseed_attempt=${pending_reseed_attempt}" \
            "automatic_reseed_guard_generation=${current_baseline_generation}" \
            "pending_source_sequence=" \
            "pending_source_cycle_type=" \
            "pending_source_run=" \
            "pending_source_request_bound=" \
            "source_retry_attempt=0" || true
          ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
            "state=RESEEDING" \
            "step=source-cbt-baseline-rebuild" \
            "scheduler_state=RUNNING" \
            "scheduler_health=RECOVERING_BASELINE" \
            "scheduler_recovery_state=RUNNING" \
            "cycle_state=WAITING_RESEED" \
            "replication_activity=RESEEDING" \
            "protection_state=DEGRADED" \
            "current_checkpoint_state=WAITING_RESEED" \
            "current_checkpoint_mode_decision_code=SOURCE_CBT_EPOCH_RESET" \
            "current_checkpoint_automatic_reseed=true" \
            "baseline_state=REBUILDING" \
            "reseed_reason=SOURCE_CBT_EPOCH_RESET" \
            "retryable=true" \
            "retry_after_sec=1" \
            "error_code=DR_CBT_RESEED_REQUIRED" \
            "error_message=The previous VMware CBT epoch is no longer valid; one controlled baseline rebuild is starting" \
            "updated_at=${now}" || true
          ftctl_log_event "dr-runtime" "dr.scheduler.baseline" "reseed" "" "85" \
            "plan=${plan} run=${cycle_run} sequence=${sequence} reason=SOURCE_CBT_EPOCH_RESET attempt=${pending_reseed_attempt}"
          ftctl_dr_scheduler_sleep_or_stop "${plan}" 1 "${control_generation}" || true
          continue
        fi
        ftctl_log_event "dr-runtime" "dr.scheduler.baseline" "reseed-blocked" "" "90" \
          "plan=${plan} run=${cycle_run} sequence=${sequence} reason=SOURCE_CBT_EPOCH_RESET baseline_generation=${current_baseline_generation}"
        rc=90
      fi
      case "${rc}" in
        65) error_code="DR_VMWARE_MOVER_UNAVAILABLE" ;;
        68) error_code="DR_VMWARE_MOVER_FAILED" ;;
        69) error_code="DR_VMWARE_NBDKIT_FAILED" ;;
        70) error_code="DR_VDDK_LIBDIR_UNRESOLVED" ;;
        71) error_code="DR_VDDK_LIBRARY_LOAD_FAILED" ;;
        72) error_code="DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID" ;;
        73) error_code="DR_VMWARE_VDDK_CONNECT_INVALID" ;;
        74) error_code="DR_VMWARE_VDDK_EXPORT_UNAVAILABLE" ;;
        75) error_code="DR_VMWARE_VDDK_SOURCE_LOCKED" ;;
        76) error_code="DR_VMWARE_VDDK_OPEN_DENIED" ;;
        77) error_code="DR_VMWARE_VDDK_THUMBPRINT_UNRESOLVED" ;;
        80) error_code="DR_VMWARE_CBT_DISK_ID_UNRESOLVED" ;;
        81) error_code="DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" ;;
        82) error_code="DR_CBT_QUERY_FAILED" ;;
        83) error_code="DR_CBT_BASELINE_INVALID" ;;
        84) error_code="DR_CBT_EXTENT_INVALID" ;;
        85) error_code="DR_CBT_RESEED_REQUIRED" ;;
        86) error_code="DR_CBT_PATCH_FAILED" ;;
        87) error_code="DR_CBT_METRICS_INVALID" ;;
        88) error_code="DR_CBT_LOCAL_COMMIT_FAILED" ;;
        89) error_code="DR_TARGET_NBD_SIZE_NOT_READY" ;;
        90) error_code="DR_CBT_RESEED_LOOP_DETECTED" ;;
        91) error_code="DR_CBT_BASELINE_NOT_DURABLE" ;;
        92) error_code="DR_NBD_TEARDOWN_TIMEOUT" ;;
        93) error_code="DR_NBD_DISCONNECT_FAILED" ;;
        94) error_code="DR_NBD_DEVICE_BUSY" ;;
        95) error_code="DR_NBD_DEVICE_QUARANTINED" ;;
        96) error_code="DR_NBD_TARGET_FLUSH_FAILED" ;;
        97) error_code="DR_RESOURCE_BUSY" ;;
        98) error_code="DR_SOURCE_SITE_UNAVAILABLE" ;;
        99) error_code="DR_VMWARE_SNAPSHOT_CLEANUP_PENDING" ;;
        100) error_code="DR_TARGET_EXPORT_UNAVAILABLE" ;;
        110) error_code="DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE" ;;
        111) error_code="DR_QCOW2_BACKUP_FAILED" ;;
        112) error_code="DR_QCOW2_OFFLINE_SOURCE_BUSY" ;;
        113) error_code="DR_QCOW2_OFFLINE_BASELINE_FAILED" ;;
        114) error_code="DR_ABLESTACK_INCREMENTAL_APPLY_FAILED" ;;
        115) error_code="DR_QCOW2_OFFLINE_TRANSFER_FAILED" ;;
        116) error_code="DR_QCOW2_BASELINE_NOT_DURABLE" ;;
        66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
        *) error_code="DR_REPLICATION_CYCLE_FAILED" ;;
      esac
      failed_component="vmware-mover"
      if [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "ABLESTACK" ]]; then
        failed_component="ablestack-replication-mover"
      elif [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "VMWARE" ]]; then
        failed_component="kvm-vddk-writer"
      fi
      case "${error_code}" in
        DR_CBT_METRICS_INVALID)
          error_message="Disk data was copied, but the cycle metrics could not be validated"
          data_commit_state="DATA_COPIED_METADATA_FAILED"
          cycle_retry_mode="RESEED_REQUIRED"
          ;;
        DR_CBT_LOCAL_COMMIT_FAILED)
          error_message="Disk data was copied, but the local cycle metadata commit failed"
          data_commit_state="LOCAL_COMMIT_FAILED"
          cycle_retry_mode="RESEED_REQUIRED"
          ;;
        DR_CBT_RESEED_LOOP_DETECTED|DR_CBT_BASELINE_NOT_DURABLE)
          error_message="Automatic reseed was blocked until the CBT baseline is repaired or explicitly reset"
          data_commit_state="BLOCKED"
          cycle_retry_mode="OPERATOR_REPAIR_REQUIRED"
          ;;
        DR_NBD_TEARDOWN_TIMEOUT|DR_NBD_DISCONNECT_FAILED|DR_NBD_DEVICE_BUSY|DR_NBD_DEVICE_QUARANTINED)
          error_message="Target data may be durable, but NBD cleanup did not complete"
          data_commit_state="TARGET_DURABLE_CLEANUP_PENDING"
          cycle_retry_mode="CLEANUP_ONLY"
          ;;
        DR_NBD_TARGET_FLUSH_FAILED)
          error_message="Target data flush failed before cycle commit"
          data_commit_state="FAILED"
          cycle_retry_mode="FULL_RETRY"
          ;;
        DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE)
          error_message="The qcow2 source is active on another host; Cloud will re-resolve the current VM placement"
          data_commit_state="NOT_STARTED"
          cycle_retry_mode="FULL_RETRY"
          ;;
        DR_QCOW2_OFFLINE_SOURCE_BUSY)
          error_message="The offline qcow2 source became writable before its baseline could be sealed"
          data_commit_state="NOT_STARTED"
          cycle_retry_mode="FULL_RETRY"
          ;;
        DR_QCOW2_OFFLINE_BASELINE_FAILED)
          error_message="The offline qcow2 source baseline could not be prepared"
          data_commit_state="NOT_STARTED"
          cycle_retry_mode="FULL_RETRY"
          ;;
        DR_QCOW2_OFFLINE_TRANSFER_FAILED)
          error_message="The offline qcow2 full seed did not reach the target export"
          data_commit_state="FAILED"
          cycle_retry_mode="FULL_RETRY"
          ;;
        DR_QCOW2_BACKUP_FAILED|DR_ABLESTACK_INCREMENTAL_APPLY_FAILED|DR_QCOW2_BASELINE_NOT_DURABLE)
          error_message="The ABLESTACK qcow2 replication operation failed"
          data_commit_state="FAILED"
          cycle_retry_mode="FULL_RETRY"
          ;;
        *)
          error_message="FTCTL DR replication cycle failed"
          data_commit_state="FAILED"
          cycle_retry_mode="FULL_RETRY"
          ;;
      esac
      now="$(ftctl_now_iso8601)"
      authority_sequence="$(ftctl_dr_scheduler_next_authority_sequence "${plan}")"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=ERROR" \
        "step=replication-cycle-failed" \
        "progress=100" \
        "accepted=false" \
        "scheduler_state=ERROR" \
        "scheduler_health=$([[ "${error_code}" == "DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE" || "${error_code}" == "DR_QCOW2_OFFLINE_SOURCE_BUSY" ]] && printf WAITING_SOURCE || { [[ "${cycle_retry_mode}" == "CLEANUP_ONLY" ]] && printf RECOVERY_REQUIRED || printf DEAD; })" \
        "cycle_state=FAILED" \
        "replication_activity=STOPPED" \
        "protection_state=DEGRADED" \
        "current_checkpoint_sequence=${sequence}" \
        "current_checkpoint_cycle_type=${cycle_type}" \
        "current_checkpoint_ref=${checkpoint_ref}" \
        "current_checkpoint_state=FAILED" \
        "current_checkpoint_mode_decision_code=${error_code}" \
        "runtime_generation=${authority_sequence}" \
        "scheduler_session_uuid=${session}" \
        "scheduler_lease_epoch=${lease_epoch}" \
        "authority_sequence=${authority_sequence}" \
        "plan_cycle_sequence=${sequence}" \
        "owner_matched=false" \
        "error_code=${error_code}" \
        "error_message=${error_message}" \
        "failed_component=${failed_component}" \
        "data_commit_state=${data_commit_state}" \
        "data_copied=$([[ "${data_commit_state}" == "DATA_COPIED_METADATA_FAILED" || "${data_commit_state}" == "LOCAL_COMMIT_FAILED" ]] && printf true || printf false)" \
        "metadata_committed=false" \
        "target_durable=false" \
        "cycle_retry_mode=${cycle_retry_mode}" \
        "retryable=$([[ "${error_code}" == "DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE" || "${error_code}" == "DR_QCOW2_OFFLINE_SOURCE_BUSY" ]] && printf true || printf false)" \
        "retry_after_sec=$([[ "${error_code}" == "DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE" || "${error_code}" == "DR_QCOW2_OFFLINE_SOURCE_BUSY" ]] && printf 30 || printf '')" \
        "nbd_teardown_state=$([[ "${cycle_retry_mode}" == "CLEANUP_ONLY" ]] && printf QUARANTINED || printf FAILED)" \
        "nbd_quarantined_device_count=$([[ "${cycle_retry_mode}" == "CLEANUP_ONLY" ]] && printf 1 || printf 0)" \
        "nbd_teardown_error_code=${error_code}" \
        "nbd_teardown_error_message=${error_message}" \
        "scheduler_recovery_state=$([[ "${cycle_retry_mode}" == "CLEANUP_ONLY" ]] && printf REQUIRED || printf FAILED)" \
        "updated_at=${now}" || true
      ftctl_log_event "dr-runtime" "dr.scheduler.cycle" "fail" "" "${rc}" \
        "plan=${plan} run=${cycle_run} sequence=${sequence} error=${error_code}"
      if [[ "${cycle_request_bound}" == "true" ]]; then
        ftctl_state_set_path "${sequence_path}" \
          "requested_cycle_state=FAILED" \
          "requested_cycle_error=${error_code}" \
          "requested_cycle_completed_at=${now}" || true
        ftctl_dr_scheduler_project_requested_cycle_run "${plan}" "${cycle_run}" "${status_path}" \
          "ERROR" "full-resync-failed" "100" "${error_code}" "${error_message}" || true
      fi
      ftctl_state_set_path "${sequence_path}" \
        "pending_resource_sequence=" \
        "pending_resource_cycle_type=" \
        "pending_resource_run=" \
        "pending_resource_request_bound=" \
        "resource_retry_attempt=0" \
        "resource_retry_after_sec=" \
        "resource_retry_updated_at=" \
        "pending_source_sequence=" \
        "pending_source_cycle_type=" \
        "pending_source_run=" \
        "pending_source_request_bound=" \
        "source_retry_attempt=0" \
        "source_retry_after_sec=" \
        "source_retry_updated_at=" \
        "pending_cleanup_sequence=" \
        "pending_cleanup_cycle_type=" \
        "pending_cleanup_run=" \
        "pending_cleanup_request_bound=" \
        "cleanup_retry_attempt=0" \
        "cleanup_retry_after_sec=" \
        "cleanup_retry_updated_at=" \
        "pending_reseed_sequence=" \
        "pending_reseed_cycle_type=" \
        "pending_reseed_run=" \
        "pending_reseed_request_bound=" \
        "pending_reseed_reason=" \
        "pending_reseed_attempt=0" || true
      rm -f "${pid_path}" 2>/dev/null || true
      ftctl_dr_scheduler_mark_lease_stopped "${plan}" "${session}" "${lease_epoch}" "${run}" "${worker_process_pid}" "${start_ticks}"
      flock -u 205 2>/dev/null || true
      exec 205>&-
      return "${rc}"
    fi

    manifest_path="$(awk -F '\t' 'NF >= 2 {print $1; exit}' <<< "${output}")"
    checkpoint_path="$(awk -F '\t' 'NF >= 2 {print $2; exit}' <<< "${output}")"
    source_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "sourceCheckpointAt" || true)"
    target_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetDurableAt" || true)"
    rpo="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetReadyRpoSeconds" || true)"
    effective_mode="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "effectiveMode" || true)"
    requested_mode="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "requestedMode" || true)"
    automatic_reseed="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "automaticReseed" boolean || true)"
    mode_decision_code="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "modeDecisionCode" || true)"
    reseed_reason="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "reseedReason" || true)"
    invalid_baseline_disk_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "invalidBaselineDiskCount" integer || true)"
    incremental_verified="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "incrementalVerified" boolean || true)"
    metrics_estimated="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "metricsEstimated" boolean || true)"
    virtual_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "virtualBytes" integer || true)"
    changed_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "changedBytes" integer || true)"
    source_read_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "sourceReadBytes" integer || true)"
    target_written_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetWrittenBytes" integer || true)"
    transfer_payload_bytes="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "transferPayloadBytes" integer || true)"
    changed_extent_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "changedExtentCount" integer || true)"
    duration_ms="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "durationMs" integer || true)"
    throughput_bps="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "throughputBps" integer || true)"
    baseline_generation="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "baselineGeneration" integer || true)"
    cycle_token="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "cycleToken" || true)"
    cycle_metrics_path="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "cycleMetricsPath" || true)"
    nbd_teardown_state="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownState" || true)"
    nbd_teardown_started_at_ms="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownStartedAtEpochMs" integer || true)"
    nbd_teardown_completed_at_ms="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownCompletedAtEpochMs" integer || true)"
    nbd_teardown_duration_ms="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownDurationMs" integer || true)"
    nbd_source_device_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdSourceDeviceCount" integer || true)"
    nbd_target_device_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTargetDeviceCount" integer || true)"
    nbd_quarantined_device_count="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdQuarantinedDeviceCount" integer || true)"
    nbd_teardown_error_code="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownErrorCode" || true)"
    nbd_teardown_error_message="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "nbdTeardownErrorMessage" || true)"
    cycle_completed_epoch="$(date +%s)"
    cycle_wall_duration_seconds=$((cycle_completed_epoch - cycle_started_epoch))
    (( cycle_wall_duration_seconds < 0 )) && cycle_wall_duration_seconds=0
    ftctl_dr_scheduler_append_restore_point "${restore_points_path}" "${plan}" "${cycle_run}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" "${cycle_wall_duration_seconds}" || return $?
    if ftctl_dr_checkpoint_enabled "${profile_file}"; then
      rm -f "${checkpoint_pending_path}"
    fi
    ftctl_dr_scheduler_mark_resume_checkpoint_completed "${plan}" "${sequence}" || true
    ftctl_state_set_path "${sequence_path}" \
      "pending_resource_sequence=" \
      "pending_resource_cycle_type=" \
      "pending_resource_run=" \
      "pending_resource_request_bound=" \
      "resource_retry_attempt=0" \
      "resource_retry_after_sec=" \
      "resource_retry_updated_at=" \
      "pending_source_sequence=" \
      "pending_source_cycle_type=" \
      "pending_source_run=" \
      "pending_source_request_bound=" \
      "source_retry_attempt=0" \
      "source_retry_after_sec=" \
      "source_retry_updated_at=" \
      "pending_cleanup_sequence=" \
      "pending_cleanup_cycle_type=" \
      "pending_cleanup_run=" \
      "pending_cleanup_request_bound=" \
      "cleanup_retry_attempt=0" \
      "cleanup_retry_after_sec=" \
      "cleanup_retry_updated_at=" \
      "pending_reseed_sequence=" \
      "pending_reseed_cycle_type=" \
      "pending_reseed_run=" \
      "pending_reseed_request_bound=" \
      "pending_reseed_reason=" \
      "pending_reseed_attempt=0" \
      "automatic_reseed_guard_generation=" || true
    now="$(ftctl_now_iso8601)"
    authority_sequence="$(ftctl_dr_scheduler_next_authority_sequence "${plan}")"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "state=READY" \
      "step=target-checkpoint-ready" \
      "progress=100" \
      "accepted=true" \
      "scheduler_state=RUNNING" \
      "scheduler_health=HEALTHY" \
      "scheduler_recovery_state=SUCCEEDED" \
      "cycle_state=IDLE" \
      "replication_activity=IDLE" \
      "protection_state=READY" \
      "failure_class=" \
      "retryable=false" \
      "retry_after_sec=" \
      "next_retry_at=" \
      "source_outage_since=" \
      "error_code=" \
      "error_message=" \
      "driver=${driver}" \
      "driver_state=CHECKPOINT_READY" \
      "checkpoint_sequence=${sequence}" \
      "checkpoint_cycle_type=${cycle_type}" \
      "checkpoint_ref=${checkpoint_ref}" \
      "current_checkpoint_sequence=${sequence}" \
      "current_checkpoint_cycle_type=${cycle_type}" \
      "current_checkpoint_requested_mode=${requested_mode}" \
      "current_checkpoint_effective_mode=${effective_mode}" \
      "current_checkpoint_mode_decision_code=${mode_decision_code}" \
      "current_checkpoint_automatic_reseed=${automatic_reseed:-false}" \
      "current_checkpoint_invalid_baseline_disk_count=${invalid_baseline_disk_count:-0}" \
      "current_checkpoint_ref=${checkpoint_ref}" \
      "current_checkpoint_state=COMPLETED" \
      "runtime_generation=${authority_sequence}" \
      "scheduler_session_uuid=${session}" \
      "scheduler_lease_epoch=${lease_epoch}" \
      "authority_sequence=${authority_sequence}" \
      "plan_cycle_sequence=${sequence}" \
      "active_worker_run_uuid=${run}" \
      "active_worker_pid=${worker_process_pid}" \
      "active_worker_start_ticks=${start_ticks}" \
      "worker_heartbeat_at=${now}" \
      "owner_matched=true" \
      "latest_completed_checkpoint_sequence=${sequence}" \
      "latest_completed_checkpoint_cycle_type=${cycle_type}" \
      "latest_completed_requested_mode=${requested_mode}" \
      "latest_completed_checkpoint_ref=${checkpoint_ref}" \
      "latest_completed_checkpoint_state=READY" \
      "latest_completed_producer_run_uuid=${cycle_run}" \
      "latest_completed_source_checkpoint_at=${source_at}" \
      "latest_completed_target_durable_at=${target_at}" \
      "latest_completed_target_ready_rpo_seconds=${rpo}" \
      "latest_completed_manifest_path=${manifest_path}" \
      "latest_completed_checkpoint_path=${checkpoint_path}" \
      "manifest_path=${manifest_path}" \
      "checkpoint_path=${checkpoint_path}" \
      "restore_points_path=${restore_points_path}" \
      "last_source_checkpoint_at=${source_at}" \
      "last_target_durable_at=${target_at}" \
      "target_ready_rpo_seconds=${rpo}" \
      "latest_completed_effective_mode=${effective_mode}" \
      "latest_completed_mode_decision_code=${mode_decision_code}" \
      "latest_completed_reseed_reason=${reseed_reason}" \
      "latest_completed_automatic_reseed=${automatic_reseed:-false}" \
      "latest_completed_invalid_baseline_disk_count=${invalid_baseline_disk_count:-0}" \
      "consecutive_automatic_reseed_count=$([[ "${automatic_reseed:-false}" == "true" ]] && printf 1 || printf 0)" \
      "latest_completed_incremental_verified=${incremental_verified}" \
      "latest_completed_metrics_estimated=${metrics_estimated}" \
      "latest_completed_virtual_bytes=${virtual_bytes}" \
      "latest_completed_changed_bytes=${changed_bytes}" \
      "latest_completed_source_read_bytes=${source_read_bytes}" \
      "latest_completed_target_written_bytes=${target_written_bytes}" \
      "latest_completed_transfer_payload_bytes=${transfer_payload_bytes}" \
      "latest_completed_changed_extent_count=${changed_extent_count}" \
      "latest_completed_duration_ms=${duration_ms}" \
      "latest_completed_cycle_wall_duration_seconds=${cycle_wall_duration_seconds}" \
      "latest_completed_throughput_bps=${throughput_bps}" \
      "latest_completed_baseline_generation=${baseline_generation}" \
      "latest_completed_cycle_token=${cycle_token}" \
      "latest_completed_cycle_metrics_path=${cycle_metrics_path}" \
      "latest_completed_nbd_teardown_state=${nbd_teardown_state}" \
      "latest_completed_nbd_teardown_started_at_ms=${nbd_teardown_started_at_ms}" \
      "latest_completed_nbd_teardown_completed_at_ms=${nbd_teardown_completed_at_ms}" \
      "latest_completed_nbd_teardown_duration_ms=${nbd_teardown_duration_ms}" \
      "latest_completed_nbd_source_device_count=${nbd_source_device_count}" \
      "latest_completed_nbd_target_device_count=${nbd_target_device_count}" \
      "latest_completed_nbd_quarantined_device_count=${nbd_quarantined_device_count:-0}" \
      "latest_completed_nbd_teardown_error_code=${nbd_teardown_error_code}" \
      "latest_completed_nbd_teardown_error_message=${nbd_teardown_error_message}" \
      "nbd_teardown_state=${nbd_teardown_state}" \
      "nbd_quarantined_device_count=${nbd_quarantined_device_count:-0}" \
      "nbd_teardown_error_code=${nbd_teardown_error_code}" \
      "nbd_teardown_error_message=${nbd_teardown_error_message}" \
      "scheduler_recovery_state=SUCCEEDED" \
      "scheduler_recovered_at=${now}" \
      "data_commit_state=LOCAL_DURABLE" \
      "data_copied=true" \
      "metadata_committed=true" \
      "target_durable=true" \
      "cycle_retry_mode=NONE" \
      "baseline_state=LOCAL_DURABLE" \
      "reseed_reason=${reseed_reason}" \
      "error_code=" \
      "error_message=" \
      "failed_component=" \
      "updated_at=${now}" || true
    if command -v ftctl_dr_runtime_complete_failback_resume_checkpoint >/dev/null 2>&1; then
      ftctl_dr_runtime_complete_failback_resume_checkpoint "${plan}" "${sequence}" || true
    fi
    ftctl_log_event "dr-runtime" "dr.scheduler.cycle" "ok" "" "" \
      "plan=${plan} run=${cycle_run} sequence=${sequence} type=${cycle_type} checkpoint=${checkpoint_path} rpo=${rpo}"
    if [[ "${cycle_request_bound}" != "true" && "${cycle_request_state}" == "FAILED" \
          && "${cycle_request_mode}" == "FULL_RESEED" && "${cycle_request_owner}" == "${cycle_run}" \
          && ( "${cycle_type}" == "full-seed" || "${cycle_type}" == "full-reseed" ) ]]; then
      # A transient first-cycle failure can restart the scheduler. The same
      # Cloud request still owns this newer durable Full Seed terminal.
      cycle_request_bound="true"
    fi
    if [[ "${cycle_request_bound}" == "true" ]]; then
      if ! ftctl_dr_scheduler_publish_requested_cycle_terminal "${plan}" "${cycle_run}" \
          "${status_path}" "${sequence_path}" "${sequence}"; then
        ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
          "state=READY" \
          "step=result-finalizing" \
          "progress=100" \
          "cycle_state=TERMINALIZING" \
          "replication_activity=IDLE" \
          "terminal_publication_pending=true" \
          "updated_at=$(ftctl_now_iso8601)" || true
        break
      fi
    fi

    if [[ "${max_cycles}" =~ ^[1-9][0-9]*$ && "${sequence}" -ge "${max_cycles}" ]]; then
      now="$(ftctl_now_iso8601)"
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "state=READY" \
        "step=scheduler-completed" \
        "progress=100" \
        "scheduler_state=COMPLETED" \
        "updated_at=${now}" || true
      break
    fi

    cycle_jitter="$(ftctl_dr_scheduler_initial_jitter "${plan}" "${profile_file}" "${interval}" "${sequence}")"
    [[ "${cycle_jitter}" =~ ^[0-9]+$ ]] || cycle_jitter=0
    execution_budget_seconds="$(ftctl_dr_scheduler_execution_budget_seconds "${restore_points_path}" "${interval}")"
    [[ "${execution_budget_seconds}" =~ ^[0-9]+$ ]] || execution_budget_seconds=$((interval / 5))
    max_jitter_seconds=$((interval - execution_budget_seconds - 1))
    (( max_jitter_seconds < 0 )) && max_jitter_seconds=0
    (( cycle_jitter > max_jitter_seconds )) && cycle_jitter="${max_jitter_seconds}"
    if ! next_cycle_epoch="$(ftctl_dr_scheduler_next_deadline_epoch "${target_at}" "${interval}" "${execution_budget_seconds}" "${cycle_jitter}")"; then
      ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
        "scheduler_health=ERROR" \
        "error_code=DR_RPO_DEADLINE_INVALID" \
        "error_message=Unable to calculate the next durable RPO deadline" \
        "updated_at=$(ftctl_now_iso8601)" || true
      return 65
    fi
    wait_seconds=$((next_cycle_epoch - $(date +%s)))
    (( wait_seconds < 0 )) && wait_seconds=0
    next_cycle_at="$(ftctl_dr_scheduler_iso_from_epoch "${next_cycle_epoch}" 2>/dev/null || true)"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "next_cycle_at=${next_cycle_at}" \
      "next_cycle_wait_seconds=${wait_seconds}" \
      "cycle_jitter_seconds=${cycle_jitter}" \
      "scheduler_execution_budget_seconds=${execution_budget_seconds}" \
      "scheduler_cycle_wall_duration_seconds=${cycle_wall_duration_seconds}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    ftctl_dr_scheduler_sleep_or_stop "${plan}" "${wait_seconds}" "${control_generation}" || true
  done

  ftctl_dr_scheduler_mark_lease_stopped "${plan}" "${session}" "${lease_epoch}" "${run}" "${worker_process_pid}" "${start_ticks}"
  rm -f "${pid_path}" "$(ftctl_dr_scheduler_active_pid_path "${plan}")" 2>/dev/null || true
  flock -u 205 2>/dev/null || true
  exec 205>&-
}

ftctl_dr_scheduler_start() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" state_path="${4-}" status_path="${5-}" wait_value="${6-}"
  local pid_path log_path pid driver_state now session lease_epoch authority_sequence start_ticks

  [[ "${FTCTL_DR_SCHEDULER_DISABLE}" == "1" ]] && return 0
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  ftctl_dr_scheduler_profile_has_data_plane "${profile_file}" || return 0
  driver_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver_state")"
  case "${driver_state}" in
    WAITING_*|MISSING_*) return 0 ;;
  esac

  ftctl_ensure_dir "$(ftctl_dr_scheduler_dir "${plan}")" "0755"
  session="$(ftctl_dr_scheduler_session_uuid "${plan}" "${profile_file}")"
  if ftctl_dr_scheduler_active_worker_valid "${plan}" "${session}"; then
    pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
    start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
    lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
    authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
    ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
      "scheduler_state=RUNNING" \
      "scheduler_health=HEALTHY" \
      "scheduler_pid_alive=true" \
      "scheduler_session_uuid=${session}" \
      "scheduler_lease_epoch=${lease_epoch}" \
      "authority_sequence=${authority_sequence}" \
      "active_worker_run_uuid=$(ftctl_dr_scheduler_active_value "${plan}" "worker_run_uuid")" \
      "active_worker_pid=${pid}" \
      "active_worker_start_ticks=${start_ticks}" \
      "owner_matched=true" \
      "updated_at=$(ftctl_now_iso8601)" || true
    return 0
  fi
  pid_path="$(ftctl_dr_scheduler_pid_path "${plan}" "${run}")"
  if ftctl_dr_scheduler_pid_alive "${pid_path}" "${plan}" "${run}"; then
    pid="$(tr -d '[:space:]' < "${pid_path}")"
    ftctl_dr_runtime_path_set "${state_path}" "scheduler_state=RUNNING" "worker_pid=${pid}" || true
    return 0
  fi

  if [[ "${FTCTL_DR_SCHEDULER_FOREGROUND:-0}" == "1" ]] \
      || { [[ "${wait_value}" != "false" ]] && [[ "${FTCTL_DR_RUNTIME_WORKER:-0}" != "1" ]]; }; then
    ftctl_dr_scheduler_worker "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}"
    return $?
  fi

  if ftctl_dr_scheduler_systemd_available "${plan}"; then
    ftctl_dr_scheduler_launch_via_systemd "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}" "SYNC_START"
    return $?
  fi

  log_path="$(ftctl_dr_scheduler_log_path "${plan}" "${run}")"
  (
    trap - EXIT
    unset FTCTL_HELD_LOCK_FILE
    ftctl_dr_scheduler_worker "${plan}" "${run}" "${profile_file}" "${state_path}" "${status_path}"
  ) >> "${log_path}" 2>&1 &
  pid="$!"
  printf '%s\n' "${pid}" > "${pid_path}"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_scheduler_update_state "${state_path}" "${status_path}" \
    "step=sync-worker-started" \
    "progress=10" \
    "scheduler_state=STARTED" \
    "worker_pid=${pid}" \
    "restore_points_path=$(ftctl_dr_scheduler_restore_points_path "${plan}")" \
    "updated_at=${now}" || true
}

ftctl_dr_scheduler_control_action() {
  local action="${1-}" plan="${2-}" run_path="${3-}" status_path="${4-}" profile_file="${5-}"
  local command expected_state now generation
  case "${action}" in
    dr-sync-pause) command="pause"; expected_state="PAUSED" ;;
    dr-sync-resume) command="run"; expected_state="RUNNING" ;;
    dr-release|dr-cancel) command="stop"; expected_state="STOPPED" ;;
    *) return 0 ;;
  esac
  if [[ "${action}" == "dr-sync-resume" ]]; then
    ftctl_dr_scheduler_ensure_running "${plan}" "$(ftctl_dr_runtime_state_get_from_path "${run_path}" run)" \
      "${profile_file}" "${run_path}" "${status_path}" || return $?
  fi
  if [[ "${action}" == "dr-cancel" ]]; then
    generation="$(ftctl_dr_scheduler_cancel_active_transfer "${plan}" \
      "$(ftctl_dr_runtime_state_get_from_path "${run_path}" run)" "${run_path}" "${status_path}")" || return $?
  else
    generation="$(ftctl_dr_scheduler_request_and_wait "${plan}" "${command}" "${expected_state}" "${action}" "$(ftctl_dr_runtime_state_get_from_path "${run_path}" run)" "false")" || return $?
  fi
  now="$(ftctl_now_iso8601)"
  case "${command}" in
    pause)
      ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
        "scheduler_state=PAUSED" \
        "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
        "control_generation=${generation}" \
        "control_ack_generation=${generation}" \
        "control_state=PAUSED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      ;;
    run)
      ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
        "scheduler_state=RUNNING" \
        "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
        "control_generation=${generation}" \
        "control_ack_generation=${generation}" \
        "control_state=RUNNING" \
        "updated_at=${now}" || true
      ;;
    stop)
      ftctl_dr_scheduler_update_state "${run_path}" "${status_path}" \
        "scheduler_state=STOPPED" \
        "control_protocol_version=${FTCTL_DR_CONTROL_PROTOCOL_VERSION}" \
        "control_generation=${generation}" \
        "control_ack_generation=${generation}" \
        "control_state=STOPPED" \
        "cycle_state=IDLE" \
        "updated_at=${now}" || true
      ;;
  esac
}
