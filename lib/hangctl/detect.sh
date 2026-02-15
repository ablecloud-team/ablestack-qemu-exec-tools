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

# Commit 07 scope:
# - QMP probe (query-status) as a strong signal for hang confirmation
# - QGA probe optional (guest-ping); failure marks has_qga=no but does not confirm hang

hangctl__trim_one_line() {
  # usage: hangctl__trim_one_line "text"
  echo "${1-}" | head -n 1 | tr -d '\r' | xargs
}

hangctl__extract_qmp_status() {
  # Extract "status" from QMP query-status JSON output (best-effort).
  # Examples:
  # {"return":{"status":"running","singlestep":false,"running":true}}
  # {"return":{"status":"paused"}}
  local s="${1-}"
  # Try jq first if available
  if command -v jq >/dev/null 2>&1; then
    local st
    st="$(echo "${s}" | jq -r 'try .return.status catch empty' 2>/dev/null || true)"
    if [[ -n "${st}" && "${st}" != "null" ]]; then
      echo -n "${st}"
      return 0
    fi
  fi
  # Fallback: regex/sed
  echo "${s}" | sed -nE 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1
}

hangctl_probe_qmp_query_status() {
  # usage: hangctl_probe_qmp_query_status <vm> <out_status_var> <out_rc_var>
  local vm="${1-}"
  local -n _status="${2}"
  local -n _rc="${3}"

  _status=""
  _rc=0

  local out err rc
  out=""
  err=""
  rc=0

  # QMP via virsh qemu-monitor-command
  local cmd='{"execute":"query-status"}'
  hangctl_virsh "${HANGCTL_QMP_TIMEOUT_SEC}" out err rc -- -c qemu:///system qemu-monitor-command "${vm}" --cmd "${cmd}" || true
  _rc="${rc}"

  local result
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    local err_short="${err:0:200}"
    hangctl_log_event "detect" "probe.qmp" "${result}" "${vm}" "" "${rc}" \
      "timeout_sec=${HANGCTL_QMP_TIMEOUT_SEC} err_url=${err_short// /%20}"
    return "${rc}"
  fi

  local st
  st="$(hangctl__extract_qmp_status "${out}")"
  st="$(hangctl__trim_one_line "${st}")"
  [[ -z "${st}" ]] && st="unknown"
  _status="${st}"

  hangctl_log_event "detect" "probe.qmp" "ok" "${vm}" "" "" \
    "timeout_sec=${HANGCTL_QMP_TIMEOUT_SEC} status=${st}"
  return 0
}

hangctl_probe_qga_ping_optional() {
  # usage: hangctl_probe_qga_ping_optional <vm> <out_has_qga_var> <out_rc_var>
  # has_qga values:
  #   yes: guest agent responded
  #   no : guest agent not available / command failed / timeout
  #   unknown: not attempted (reserved)
  local vm="${1-}"
  local -n _has_qga="${2}"
  local -n _rc="${3}"

  _has_qga="unknown"
  _rc=0

  local out err rc
  out=""
  err=""
  rc=0

  # QGA ping (optional)
  # guest-ping is supported by QGA; if QGA not installed/running, virsh will fail.
  local cmd='{"execute":"guest-ping"}'
  hangctl_virsh "${HANGCTL_QGA_TIMEOUT_SEC}" out err rc -- -c qemu:///system qemu-agent-command "${vm}" "${cmd}" || true
  _rc="${rc}"

  local result
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    _has_qga="no"
    local err_short="${err:0:200}"
    hangctl_log_event "detect" "probe.qga" "${result}" "${vm}" "" "${rc}" \
      "timeout_sec=${HANGCTL_QGA_TIMEOUT_SEC} has_qga=no err_url=${err_short// /%20}"
    return "${rc}"
  fi

  _has_qga="yes"
  hangctl_log_event "detect" "probe.qga" "ok" "${vm}" "" "" \
    "timeout_sec=${HANGCTL_QGA_TIMEOUT_SEC} has_qga=yes"
  return 0
}
