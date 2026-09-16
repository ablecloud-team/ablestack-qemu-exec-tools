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

# Commit 08 scope:
# - Action for confirmed VM:
#   - virsh destroy (default)
#   - on destroy fail/timeout -> kill escalation (TERM -> KILL)
# - Post verify: domstate should NOT be running/paused/inmigrate
# - JSONL events with incident_id

hangctl_new_incident_id() {
  # Example: 20260213-205012-acde12
  local ts rid
  ts="$(date +"%Y%m%d-%H%M%S")"
  rid="$(hangctl_rand_id)"
  echo "${ts}-${rid}"
}

hangctl__is_active_domstate() {
  # Returns 0 if domstate indicates still active (running/paused/inmigrate)
  local st="${1-}"
  st="$(echo "${st}" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "${st}" in
    running|paused|inmigrate) return 0 ;;
    *) return 1 ;;
  esac
}

# Read libvirt's PID file, then bind it to the domain UUID and process start
# time. Never select kill targets with an unanchored pgrep name expression.
hangctl_qemu_identity() {
  local vm="${1}" uuid_out='' uuid_err='' uuid_rc=0 pid proc_stat exe i
  [[ "${vm}" =~ ^[a-zA-Z0-9_.:-]+$ ]] || return 1
  LC_ALL=C hangctl_virsh "${HANGCTL_VIRSH_TIMEOUT_SEC}" uuid_out uuid_err uuid_rc -- \
    -c qemu:///system domuuid "${vm}" || true
  [[ "${uuid_rc}" == 0 && "${uuid_out}" =~ ^[a-fA-F0-9-]{36}$ ]] || return 1
  read -r pid < "/run/libvirt/qemu/${vm}.pid" || return 1
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  exe="$(readlink "/proc/${pid}/exe")" || return 1
  [[ "${exe##*/}" == qemu* ]] || return 1
  local -a argv=() fields=()
  mapfile -d '' -t argv < "/proc/${pid}/cmdline" || return 1
  local matched=0
  for ((i=0; i+1<${#argv[@]}; i++)); do
    if [[ "${argv[i]}" == -uuid && "${argv[i+1],,}" == "${uuid_out,,}" ]]; then
      matched=1; break
    fi
  done
  [[ "${matched}" == 1 ]] || return 1
  proc_stat="$(cat "/proc/${pid}/stat")" || return 1
  # Strip pid and (comm); starttime is field 22, index 19 after those fields.
  read -r -a fields <<< "${proc_stat##*) }"
  [[ "${fields[19]-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s:%s:%s' "${uuid_out,,}" "${pid}" "${fields[19]}"
}

hangctl_action_gate() {
  local vm="${1}" incident="${2}" phase="${3}" expected="${4}"
  local observed detail domain actual guard_reason='' guard_detail='' verdict=ALLOW
  hangctl_probe_operation "${vm}" observed detail domain
  if [[ "${observed}" != NONE ]]; then
    verdict="DEFER_${observed}"
    hangctl_state_observe_operation "${vm}" "${observed}" || true
  elif [[ -z "${expected}" ]] || ! actual="$(hangctl_qemu_identity "${vm}")" || [[ "${actual}" != "${expected}" ]]; then
    verdict=STALE_IDENTITY
  elif hangctl_ftctl_guard_should_skip_action "${vm}" action_gate guard_reason guard_detail; then
    verdict=DEFER_FTCTL
  elif [[ "${domain%% *}" != paused ]]; then
    local fresh_status='' fresh_rc=0
    hangctl_probe_qmp_query_status "${vm}" fresh_status fresh_rc || true
    if [[ "${fresh_rc}" == 0 && "${fresh_status}" == running ]]; then
      verdict=RECOVERED
      hangctl_state_touch_heartbeat "${vm}"
    fi
  fi
  hangctl_log_event action action.gate "$([[ "${verdict}" == ALLOW ]] && echo ok || echo skip)" \
    "${vm}" "${incident}" '' "phase=${phase} verdict=${verdict} identity=${expected} ${detail} ftctl_reason=${guard_reason}"
  [[ "${verdict}" == ALLOW ]]
}

hangctl_kill_escalation() {
  local vm="${1}" incident_id="${2}" expected="${3-}" pid
  [[ "${HANGCTL_DRY_RUN:-0}" != 1 && -n "${expected}" ]] || return 1
  pid="${expected#*:}"; pid="${pid%%:*}"
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  hangctl_action_gate "${vm}" "${incident_id}" term "${expected}" || return 1
  hangctl_log_event action action.kill.term ok "${vm}" "${incident_id}" '' "pids=${pid}"
  kill -TERM "${pid}" 2>/dev/null || return 1
  sleep "${HANGCTL_KILL_GRACE_SEC}"
  if kill -0 "${pid}" 2>/dev/null; then
    hangctl_action_gate "${vm}" "${incident_id}" kill "${expected}" || return 1
    hangctl_log_event action action.kill.k9 ok "${vm}" "${incident_id}" '' "pids=${pid}"
    kill -KILL "${pid}" 2>/dev/null || return 1
  fi
}

hangctl_verify_vm_stopped() {
  # usage: hangctl_verify_vm_stopped <vm> <incident_id>
  local vm="${1-}"
  local incident_id="${2-}"

  local out err rc
  out=""; err=""; rc=0
  hangctl_virsh "${HANGCTL_VERIFY_TIMEOUT_SEC}" out err rc -- -c qemu:///system domstate "${vm}" || true
  local result
  result="$(hangctl__result_from_rc "${rc}")"

  if [[ "${result}" != "ok" ]]; then
    # Failure to observe the domain is not proof of a successful stop.
    hangctl_log_event "verify" "verify.domstate" "fail" "${vm}" "${incident_id}" "${rc}" \
      "note=domstate_unknown"
    return 1
  fi

  local st
  st="$(echo "${out}" | head -n 1 | tr -d '\r' | xargs)"
  [[ -z "${st}" ]] && st="unknown"

  if hangctl__is_active_domstate "${st}"; then
    hangctl_log_event "verify" "verify.domstate" "fail" "${vm}" "${incident_id}" "" \
      "domstate=${st}"
    return 1
  fi

  hangctl_log_event "verify" "verify.domstate" "ok" "${vm}" "${incident_id}" "" \
    "domstate=${st}"
  return 0
}

hangctl_action_handle_confirmed_vm() {
  local vm="${1}" reason="${2}" domstate="${3}" stuck_sec="${4}" qmp_status="${5}"
  local incident_id expected='' guard_reason='' guard_detail=''
  incident_id="$(hangctl_new_incident_id)"
  if hangctl_ftctl_guard_should_skip_action "${vm}" "${reason}" guard_reason guard_detail; then
    hangctl_log_event action action.skip ok "${vm}" "${incident_id}" '' "reason=${guard_reason} ${guard_detail}"
    return 0
  fi
  # A dry run must not dump memory (including crash-mode dumps) or remediate
  # storage. The detector has already recorded the decision.
  if [[ "${HANGCTL_DRY_RUN}" == 1 ]]; then
    hangctl_log_event action incident.end ok "${vm}" "${incident_id}" '' 'result=dry_run'
    return 0
  fi
  expected="$(hangctl_qemu_identity "${vm}")" || true
  hangctl_action_gate "${vm}" "${incident_id}" pre_action "${expected}" || return 0
  hangctl_log_event action incident.start ok "${vm}" "${incident_id}" '' \
    "reason=${reason} domstate=${domstate} stuck_sec=${stuck_sec} qmp_status=${qmp_status} identity=${expected}"
  hangctl_storage_guard_vm_volumes "${vm}" "${incident_id}" "${reason}" || true
  hangctl_collect_evidence_pre_action "${vm}" "${incident_id}" "${reason}" "${domstate}" "${stuck_sec}" "${qmp_status}" || true
  if ! hangctl_action_gate "${vm}" "${incident_id}" dump "${expected}"; then
    hangctl_log_event action incident.end ok "${vm}" "${incident_id}" '' 'result=deferred phase=dump'
    return 0
  fi
  local dump_path='' dump_sha='' dump_bytes=0
  hangctl_collect_dump_pre_action "${vm}" "${incident_id}" dump_path dump_sha dump_bytes || true
  if ! hangctl_action_gate "${vm}" "${incident_id}" destroy "${expected}"; then
    hangctl_log_event action incident.end ok "${vm}" "${incident_id}" '' 'result=deferred phase=destroy'
    return 0
  fi
  local destroy_out='' destroy_err='' destroy_rc=0 destroy_result
  hangctl_virsh "${HANGCTL_VIRSH_TIMEOUT_SEC}" destroy_out destroy_err destroy_rc -- \
    -c qemu:///system destroy "${vm}" || true
  destroy_result="$(hangctl__result_from_rc "${destroy_rc}")"
  hangctl_log_event action action.destroy "${destroy_result}" "${vm}" "${incident_id}" "${destroy_rc}" \
    "timeout_sec=${HANGCTL_VIRSH_TIMEOUT_SEC} identity=${expected}"
  if [[ "${destroy_result}" == timeout ]]; then
    # A timed-out destroy may still be queued behind a snapshot. Never turn
    # monitor contention into permission to bypass libvirt with a signal.
    hangctl_log_event action incident.end warn "${vm}" "${incident_id}" '' 'result=deferred reason=destroy_timeout'
    return 0
  elif [[ "${destroy_result}" != ok ]]; then
    if ! hangctl_kill_escalation "${vm}" "${incident_id}" "${expected}"; then
      hangctl_log_event action incident.end warn "${vm}" "${incident_id}" '' 'result=deferred phase=signal'
      return 0
    fi
  fi
  if hangctl_verify_vm_stopped "${vm}" "${incident_id}"; then
    hangctl_log_event action incident.end ok "${vm}" "${incident_id}" '' 'result=stopped'
  else
    hangctl_log_event action incident.end fail "${vm}" "${incident_id}" '' 'result=stop_unconfirmed'
    return 1
  fi
}
