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

ftctl_verify_domain_state_on_uri() {
  local uri="${1-}"
  local vm="${2-}"
  local state_var="${3}"
  local out err rc resolved_state

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_STANDBY_VERIFY_TIMEOUT_SEC}" out err rc -- -c "${uri}" domstate "${vm}" || true
  : "${out}${err}"
  if [[ "${rc}" == "0" ]]; then
    resolved_state="$(head -n 1 <<< "${out}" | tr '[:upper:]' '[:lower:]' | xargs)"
    printf -v "${state_var}" '%s' "${resolved_state}"
    return 0
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_STANDBY_VERIFY_TIMEOUT_SEC}" out err rc -- -c "${uri}" dominfo "${vm}" || true
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    printf -v "${state_var}" '%s' "unknown"
    return "${rc}"
  fi

  resolved_state="$(awk -F: 'tolower($1) ~ /^state$/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print tolower($2); exit}' <<< "${out}")"
  [[ -n "${resolved_state}" ]] || resolved_state="unknown"
  printf -v "${state_var}" '%s' "${resolved_state}"
  [[ "${resolved_state}" != "unknown" ]]
}

ftctl_verify_domain_network_on_uri() {
  local uri="${1-}"
  local vm="${2-}"
  local result_var="${3}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_STANDBY_VERIFY_TIMEOUT_SEC}" out err rc -- -c "${uri}" domifaddr "${vm}" || true
  : "${out}${err}"
  if [[ "${rc}" == "0" && "${out}" == *"/"* ]]; then
    printf -v "${result_var}" '%s' "ok"
    return 0
  fi
  printf -v "${result_var}" '%s' "unknown"
  return 1
}

ftctl_verify_standby_boot() {
  local vm="${1-}"
  local state net result i standby_vm

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" "standby_verify_state=dry-run"
    ftctl_log_event "verify" "verify.standby" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  standby_vm="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || ftctl_profile_secondary_vm_name_resolved "${vm}")"
  result="fail"
  for ((i=0; i<FTCTL_STANDBY_VERIFY_TIMEOUT_SEC; i++)); do
    state="unknown"
    if ftctl_verify_domain_state_on_uri "${FTCTL_PROFILE_SECONDARY_URI}" "${standby_vm}" state; then
      case "${state}" in
        running|running\ \(*) result="ok"; break ;;
      esac
    fi
    sleep 1
  done

  if [[ "${result}" != "ok" ]]; then
    for ((i=0; i<10; i++)); do
      state="unknown"
      if ftctl_verify_domain_state_on_uri "${FTCTL_PROFILE_SECONDARY_URI}" "${standby_vm}" state; then
        case "${state}" in
          running|running\ \(*) result="ok"; break ;;
        esac
      fi
      sleep 1
    done
  fi

  if [[ "${result}" != "ok" ]]; then
    ftctl_state_set "${vm}" "standby_verify_state=failed"
    ftctl_log_event "verify" "verify.standby" "fail" "${vm}" "" \
      "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} state=${state}"
    return 1
  fi

  net="unknown"
  ftctl_verify_domain_network_on_uri "${FTCTL_PROFILE_SECONDARY_URI}" "${standby_vm}" net || true
  case "${net}" in
    ok) ftctl_state_set "${vm}" "standby_verify_state=running-network-ok" ;;
    *)  ftctl_state_set "${vm}" "standby_verify_state=running-network-unknown" ;;
  esac
  ftctl_log_event "verify" "verify.standby" "ok" "${vm}" "" \
    "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} network=${net}"
}

ftctl_verify_failback_ready() {
  local vm="${1-}"
  local active_side standby_state
  active_side="$(ftctl_state_get "${vm}" "active_side" 2>/dev/null || echo "primary")"
  standby_state="$(ftctl_state_get "${vm}" "standby_state" 2>/dev/null || echo "unknown")"
  if [[ "${active_side}" != "secondary" ]]; then
    echo "ERROR: failback requires active_side=secondary" >&2
    return 1
  fi
  case "${standby_state}" in
    running|start-dry-run|running-network-ok|running-network-unknown) return 0 ;;
    *)
      echo "ERROR: failback requires standby_state to be active-ready, got ${standby_state}" >&2
      return 1
      ;;
  esac
}

ftctl_verify_vm() {
  local vm="${1-}"
  ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
  ftctl_log_event "verify" "verify.vm" "ok" "${vm}" "" "reason=skeleton"
}
