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

hangctl_find_qemu_pids() {
  # usage: hangctl_find_qemu_pids <vm>
  # Best-effort: libvirt qemu argv includes "-name guest=<VM>,..."
  local vm="${1-}"
  local pat1="-name guest=${vm},"
  local pat2="-name guest=${vm}"

  if command -v pgrep >/dev/null 2>&1; then
    # pgrep -f matches full command line
    pgrep -f "qemu.*${pat1}" 2>/dev/null || pgrep -f "qemu.*${pat2}" 2>/dev/null || true
    return 0
  fi

  # Fallback: ps+grep
  ps -eo pid,args | grep -E "qemu.*(${pat1}|${pat2})" | grep -v grep | awk '{print $1}' || true
}

hangctl_kill_escalation() {
  # usage: hangctl_kill_escalation <vm> <incident_id>
  local vm="${1-}"
  local incident_id="${2-}"

  local pids
  pids="$(hangctl_find_qemu_pids "${vm}")"
  pids="$(echo "${pids}" | xargs)"

  if [[ -z "${pids}" ]]; then
    hangctl_log_event "action" "action.kill" "skip" "${vm}" "${incident_id}" "" "reason=no_pid"
    return 0
  fi

  # TERM
  hangctl_log_event "action" "action.kill.term" "ok" "${vm}" "${incident_id}" "" "pids=${pids}"
  kill -TERM ${pids} 2>/dev/null || true
  sleep "${HANGCTL_KILL_GRACE_SEC}"

  # KILL any remaining
  local still=""
  local pid
  for pid in ${pids}; do
    if kill -0 "${pid}" 2>/dev/null; then
      still+="${pid} "
    fi
  done
  still="$(echo "${still}" | xargs)"
  if [[ -n "${still}" ]]; then
    hangctl_log_event "action" "action.kill.k9" "ok" "${vm}" "${incident_id}" "" "pids=${still}"
    kill -KILL ${still} 2>/dev/null || true
  fi
  return 0
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
    # If domstate itself fails (e.g., domain vanished), treat as stopped.
    hangctl_log_event "verify" "verify.domstate" "ok" "${vm}" "${incident_id}" "${rc}" \
      "note=domstate_failed_treat_stopped"
    return 0
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
  # usage:
  #   hangctl_action_handle_confirmed_vm <vm> <reason> <domstate> <stuck_sec> <qmp_status>
  local vm="${1-}"
  local reason="${2-}"
  local domstate="${3-}"
  local stuck_sec="${4-}"
  local qmp_status="${5-}"

  local incident_id
  incident_id="$(hangctl_new_incident_id)"

  hangctl_log_event "action" "incident.start" "ok" "${vm}" "${incident_id}" "" \
    "reason=${reason} domstate=${domstate} stuck_sec=${stuck_sec} qmp_status=${qmp_status} policy=${HANGCTL_POLICY} dry_run=${HANGCTL_DRY_RUN}"

  # Commit 09: pre-action evidence + memory dump + analysis (soft-gated)
  hangctl_collect_evidence_pre_action "${vm}" "${incident_id}" "${reason}" "${domstate}" "${stuck_sec}" "${qmp_status}" || true

  local dump_path dump_sha dump_bytes
  dump_path=""; dump_sha=""; dump_bytes="0"
  hangctl_collect_dump_pre_action "${vm}" "${incident_id}" dump_path dump_sha dump_bytes || true

  # If dump_path is unexpectedly empty, recover it from evidence pointer (observed in field logs)
  if [[ -z "${dump_path}" ]]; then
    local edir pointer
    edir="$(hangctl_evidence_dir "${vm}" "${incident_id}")"
    pointer="${edir}/dump.pointer"
    if [[ -r "${pointer}" ]]; then
      dump_path="$(awk -F= '/^dump_path=/{print $2}' "${pointer}" | head -n 1)"
      if [[ -n "${dump_path}" ]]; then
        # analysis removed: handled by external process
        hangctl_log_event "analysis" "analysis.start" "skip" "${vm}" "${HANGCTL_INCIDENT_ID-}" "" \
            "reason=disabled"
      fi
    fi
  fi
 
  if [[ "${HANGCTL_DRY_RUN}" == "1" ]]; then
    hangctl_log_event "action" "action.destroy" "skip" "${vm}" "${incident_id}" "" "reason=dry_run"
    hangctl_log_event "verify" "verify.domstate" "skip" "${vm}" "${incident_id}" "" "reason=dry_run"
    hangctl_log_event "action" "incident.end" "ok" "${vm}" "${incident_id}" "" "result=dry_run"
    return 0
  fi

  # Default action: destroy
  local rc=0
  hangctl_virsh_event "action" "action.destroy" "${HANGCTL_VIRSH_TIMEOUT_SEC}" -- -c qemu:///system destroy "${vm}" || rc=$?
  local destroy_result
  destroy_result="$(hangctl__result_from_rc "${rc}")"

  if [[ "${destroy_result}" != "ok" ]]; then
    # Escalate to kill
    hangctl_kill_escalation "${vm}" "${incident_id}" || true
  fi

  # Verify
  if hangctl_verify_vm_stopped "${vm}" "${incident_id}"; then
    hangctl_log_event "action" "incident.end" "ok" "${vm}" "${incident_id}" "" "result=stopped"
    return 0
  fi

  hangctl_log_event "action" "incident.end" "fail" "${vm}" "${incident_id}" "" "result=still_active"
  return 1
}
