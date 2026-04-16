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

ftctl_failback_reprotect_from_primary() {
  local vm="${1-}"
  local mode="${2-}"
  local host="" user="" out="" err="" rc=0 remote_cmd="" remote_blockcopy=""

  if [[ "${FTCTL_PROFILE_PRIMARY_URI}" == "qemu:///system" ]]; then
    ftctl_blockcopy_plan_protect "${vm}" || return 1
    ftctl_blockcopy_wait_forward_sync_ready "${vm}" "120" || return 1
    return 0
  fi

  ftctl_blockcopy_primary_target_host_user host user || return 1
  remote_cmd="$(cat <<EOF
set -euo pipefail
ablestack_vm_ftctl protect --vm ${vm@Q} --mode ${mode@Q}
for _i in \$(seq 1 60); do
  ablestack_vm_ftctl reconcile --vm ${vm@Q} >/dev/null 2>&1 || true
  status_json="\$(ablestack_vm_ftctl status --vm ${vm@Q} --json 2>/dev/null || true)"
  if [[ "\${status_json}" == *'"protection_state":"protected"'* && "\${status_json}" == *'"transport_state":"mirroring"'* && "\${status_json}" == *'"active_side":"primary"'* ]]; then
    exit 0
  fi
  sleep 2
done
echo "primary_reprotect_timeout:${vm}" >&2
exit 99
EOF
)"
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}${err}"
  [[ "${rc}" == "0" ]] || {
    [[ -n "${err}" ]] && echo "ERROR: primary reprotect failed: ${err}" >&2
    return 1
  }

  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "cat /run/ablestack-vm-ftctl/state/$(ftctl_state_vm_key "${vm}").state.blockcopy" || true
  : "${out}${err}"
  [[ "${rc}" == "0" && -n "${out}" ]] || {
    [[ -n "${err}" ]] && echo "ERROR: failed to fetch primary blockcopy state: ${err}" >&2
    return 1
  }
  remote_blockcopy="$(ftctl_blockcopy_state_path "${vm}")"
  printf '%s\n' "${out}" > "${remote_blockcopy}"
  chmod 0644 "${remote_blockcopy}" 2>/dev/null || true

  ftctl_state_set "${vm}" \
    "active_side=primary" \
    "protection_state=protected" \
    "transport_state=mirroring" \
    "fencing_state=clear" \
    "standby_state=prepared-transient" \
    "last_sync_ts=$(ftctl_now_iso8601)" \
    "last_error="
}

ftctl_failback_request() {
  local vm="${1-}"
  local reason="${2-manual}"
  local mode="${FTCTL_PROFILE_MODE:-ha}"
  if [[ "${mode}" == "ft" ]]; then
    if ! ftctl_xcolo_failback "${vm}"; then
      ftctl_log_event "failback" "failback.request" "fail" "${vm}" "" \
        "reason=${reason} xcolo=failback_failed"
      return 1
    fi
    return 0
  fi
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
  if ! ftctl_blockcopy_wait_reverse_sync_ready "${vm}" "120"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=reverse_sync_failed" \
      "last_error=reverse_sync_timeout"
    ftctl_log_event "failback" "failback.request" "fail" "${vm}" "" \
      "reason=${reason} reverse_sync=timeout"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "protection_state=failing_back" \
    "transport_state=cutback_switching" \
    "last_error="

  if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
    ftctl_blockcopy_stop_primary_reverse_nbd_exports "${vm}" || true
    sleep 2
  fi

  if ! ftctl_standby_deactivate "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=cutback_secondary_stop_failed"
    ftctl_log_event "failback" "failback.cutback" "fail" "${vm}" "" \
      "reason=${reason} secondary=stop_failed"
    return 1
  fi
  if ! ftctl_primary_activate_from_backup "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=cutback_primary_activate_failed"
    ftctl_log_event "failback" "failback.cutback" "fail" "${vm}" "" \
      "reason=${reason} primary=activate_failed"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "active_side=primary" \
    "fencing_state=clear" \
    "protection_state=pairing" \
    "transport_state=initializing" \
    "standby_state="

  if ! ftctl_failback_reprotect_from_primary "${vm}" "${mode}"; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "last_error=cutback_reprotect_failed"
    ftctl_log_event "failback" "failback.cutback" "fail" "${vm}" "" \
      "reason=${reason} reprotect=failed"
    return 1
  fi

  ftctl_log_event "failback" "failback.request" "ok" "${vm}" "" \
    "reason=${reason} reverse_sync=completed cutback=done"
}
