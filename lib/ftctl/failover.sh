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

ftctl_failover_request() {
  local vm="${1-}"
  local reason="${2-manual}"
  local count
  local fence_rc
  local mode
  count="$(ftctl_state_increment "${vm}" "failover_count")"
  mode="$(ftctl_state_get "${vm}" "mode" 2>/dev/null || echo "")"
  ftctl_state_set "${vm}" \
    "protection_state=failing_over" \
    "last_error=skeleton_failover_pending"
  fence_rc=0
  ftctl_fencing_execute "${vm}" "${reason}" || fence_rc=$?
  case "${fence_rc}" in
    0)
      if [[ "${mode}" == "ft" ]]; then
        if ! ftctl_xcolo_failover "${vm}"; then
          ftctl_state_set "${vm}" \
            "protection_state=error" \
            "last_error=xcolo_failover_failed"
          ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
            "reason=${reason} failover_count=${count} xcolo=failover_failed"
          return 1
        fi
        ftctl_state_set "${vm}" "last_error="
        ftctl_log_event "failover" "failover.request" "ok" "${vm}" "" \
          "reason=${reason} failover_count=${count} fencing=complete xcolo=running"
        return 0
      fi

      if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
        ftctl_blockcopy_stop_remote_nbd_exports "${vm}" || true
        sleep 2
      fi

      if ! ftctl_standby_activate "${vm}"; then
        ftctl_state_set "${vm}" \
          "protection_state=error" \
          "last_error=standby_activate_failed"
        ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
          "reason=${reason} failover_count=${count} standby=activate_failed"
        return 1
      fi
      if ! ftctl_verify_standby_boot "${vm}"; then
        ftctl_state_set "${vm}" \
          "protection_state=error" \
          "last_error=standby_verify_failed"
        ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
          "reason=${reason} failover_count=${count} standby=verify_failed"
        return 1
      fi
      ftctl_state_set "${vm}" \
        "protection_state=failed_over" \
        "transport_state=failed_over" \
        "last_error="
      ftctl_log_event "failover" "failover.request" "ok" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=complete standby=running"
      ;;
    3)
      ftctl_state_set "${vm}" "last_error=manual_fencing_required"
      ftctl_log_event "failover" "failover.request" "warn" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=manual_required"
      ;;
    4)
      ftctl_state_set "${vm}" "last_error=dry_run_fencing"
      ftctl_log_event "failover" "failover.request" "skip" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=dry_run"
      ;;
    *)
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "last_error=fencing_failed"
      ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=failed"
      return 1
      ;;
  esac
}

ftctl_failback_request() {
  local vm="${1-}"
  local reason="${2-manual}"
  if ! ftctl_verify_failback_ready "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=failback_precheck_failed"
    return 1
  fi
  ftctl_state_set "${vm}" \
    "protection_state=failing_back" \
    "last_error=reverse_sync_pending"
  if ! ftctl_blockcopy_start_reverse_sync "${vm}"; then
    ftctl_log_event "failback" "failback.request" "fail" "${vm}" "" \
      "reason=${reason} reverse_sync=failed"
    return 1
  fi
  ftctl_log_event "failback" "failback.request" "ok" "${vm}" "" \
    "reason=${reason} reverse_sync=started"
}
