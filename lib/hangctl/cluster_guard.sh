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

hangctl_cluster_guard__state_path() {
  local name="${1-}"
  local dir="${HANGCTL_STATE_DIR:-/run/ablestack-vm-hangctl/state}"
  echo -n "${dir}/${name}"
}

hangctl_cluster_guard__url() {
  local value="${1-}"
  value="${value//$'\n'/;}"
  value="${value//$'\r'/}"
  value="${value// /%20}"
  echo -n "${value}"
}

hangctl_cluster_guard__cluster_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-active --quiet pacemaker 2>/dev/null || \
    systemctl is-active --quiet corosync 2>/dev/null
}

hangctl_cluster_status_collect() {
  # usage: hangctl_cluster_status_collect <out_text_var> <out_rc_var>
  local -n _out="${1}"
  local -n _rc="${2}"
  _out=""
  _rc=1

  local timeout_sec="${HANGCTL_CLUSTER_GUARD_TIMEOUT_SEC:-5}"
  local cmd_out="" cmd_err="" cmd_rc=0

  if command -v crm_mon >/dev/null 2>&1; then
    if declare -F hangctl_cmd_run >/dev/null 2>&1; then
      hangctl_cmd_run "${timeout_sec}" cmd_out cmd_err cmd_rc -- crm_mon -1 -r -f || true
    elif command -v timeout >/dev/null 2>&1; then
      cmd_out="$(timeout "${timeout_sec}" crm_mon -1 -r -f 2>/dev/null)" || cmd_rc=$?
    else
      cmd_out="$(crm_mon -1 -r -f 2>/dev/null)" || cmd_rc=$?
    fi
    if [[ "${cmd_rc}" == "0" && -n "${cmd_out}" ]]; then
      _out="${cmd_out}"
      _rc=0
      return 0
    fi
  fi

  cmd_out=""; cmd_err=""; cmd_rc=0
  if command -v pcs >/dev/null 2>&1; then
    if declare -F hangctl_cmd_run >/dev/null 2>&1; then
      hangctl_cmd_run "${timeout_sec}" cmd_out cmd_err cmd_rc -- pcs status --full || true
    elif command -v timeout >/dev/null 2>&1; then
      cmd_out="$(timeout "${timeout_sec}" pcs status --full 2>/dev/null)" || cmd_rc=$?
    else
      cmd_out="$(pcs status --full 2>/dev/null)" || cmd_rc=$?
    fi
    if [[ "${cmd_rc}" == "0" && -n "${cmd_out}" ]]; then
      _out="${cmd_out}"
      _rc=0
      return 0
    fi
  fi

  _rc="${cmd_rc:-1}"
  return 1
}

hangctl_cluster_status__active_text() {
  # Drop historical failure sections. They are useful for operators but should
  # not by themselves keep libvirtd restart blocked forever.
  awk '
    /^Failed Resource Actions:/ { skip=1; next }
    /^Tickets:/ || /^PCSD Status:/ || /^Daemon Status:/ { skip=0 }
    skip == 0 { print }
  '
}

hangctl_cluster_status_is_busy() {
  # usage: hangctl_cluster_status_is_busy <status_text> <out_reason_var> <out_detail_var>
  local status_text="${1-}"
  local -n _reason="${2}"
  local -n _detail="${3}"
  _reason=""
  _detail=""

  local active_text lc resource_re
  active_text="$(printf "%s\n" "${status_text}" | hangctl_cluster_status__active_text)"
  lc="$(printf "%s" "${active_text}" | tr '[:upper:]' '[:lower:]')"
  resource_re="${HANGCTL_CLUSTER_GUARD_RESOURCE_REGEX:-cloudcenter_res}"

  if grep -Eqi 'fencing actions:|stonith|fence[_ -]|pending|unclean|\boffline\b' <<< "${active_text}"; then
    _reason="cluster_transition"
    _detail="pattern=fencing_or_node_state"
    return 0
  fi

  if grep -Eqi '\b(starting|stopping|migrating)\b' <<< "${active_text}"; then
    _reason="resource_action"
    _detail="pattern=resource_action"
    return 0
  fi

  if [[ -n "${resource_re}" ]] && grep -Eqi "${resource_re}" <<< "${active_text}" &&
     grep -Eqi 'Actions:|_migrate| migrate_|_start| start_|_stop| stop_' <<< "${active_text}"; then
    _reason="managed_resource_action"
    _detail="resource_regex=$(hangctl_cluster_guard__url "${resource_re}")"
    return 0
  fi

  if grep -Eqi 'partition WITHOUT quorum|no quorum' <<< "${active_text}"; then
    _reason="no_quorum"
    _detail="pattern=quorum"
    return 0
  fi

  return 1
}

hangctl_cluster_status_hash_settle_check() {
  # usage: hangctl_cluster_status_hash_settle_check <status_text> <out_reason_var> <out_detail_var>
  local status_text="${1-}"
  local -n _reason="${2}"
  local -n _detail="${3}"
  _reason=""
  _detail=""

  local settle_sec="${HANGCTL_CLUSTER_GUARD_SETTLE_SEC:-600}"
  [[ "${settle_sec}" =~ ^[0-9]+$ ]] || settle_sec=600
  (( settle_sec > 0 )) || return 1

  local hash_path ts_path now hash prev_hash prev_ts age
  hash_path="$(hangctl_cluster_guard__state_path "cluster.status.hash")"
  ts_path="$(hangctl_cluster_guard__state_path "cluster.status.last_change_ts")"
  mkdir -p "$(dirname "${hash_path}")" 2>/dev/null || true

  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf "%s" "${status_text}" | sha256sum | awk '{print $1}')"
  else
    hash="$(printf "%s" "${status_text}" | cksum | awk '{print $1 "-" $2}')"
  fi
  prev_hash="$(cat "${hash_path}" 2>/dev/null || true)"
  prev_ts="$(cat "${ts_path}" 2>/dev/null || true)"
  now="$(date +%s)"

  if [[ -z "${prev_hash}" ]]; then
    printf "%s\n" "${hash}" > "${hash_path}" 2>/dev/null || true
    printf "0\n" > "${ts_path}" 2>/dev/null || true
    return 1
  fi

  if [[ "${prev_hash}" != "${hash}" ]]; then
    printf "%s\n" "${hash}" > "${hash_path}" 2>/dev/null || true
    printf "%s\n" "${now}" > "${ts_path}" 2>/dev/null || true
    _reason="status_changed"
    _detail="settle_sec=${settle_sec} age=0"
    return 0
  fi

  if [[ "${prev_ts}" =~ ^[0-9]+$ && "${prev_ts}" -gt 0 ]]; then
    age=$((now - prev_ts))
    if (( age < settle_sec )); then
      _reason="recent_status_change"
      _detail="settle_sec=${settle_sec} age=${age}"
      return 0
    fi
  fi

  return 1
}

hangctl_cluster_guard_probe() {
  # usage: hangctl_cluster_guard_probe <stage> <out_decision_var> <out_reason_var> <out_detail_var>
  local stage="${1-scan}"
  local -n _decision="${2}"
  local -n _reason="${3}"
  local -n _detail="${4}"
  _decision="idle"
  _reason="ok"
  _detail=""

  if [[ "${HANGCTL_CLUSTER_GUARD_ENABLE:-1}" != "1" ]]; then
    _decision="disabled"
    _reason="disabled"
    return 0
  fi

  if ! hangctl_cluster_guard__cluster_active; then
    _decision="idle"
    _reason="cluster_inactive"
    return 0
  fi

  local status_text status_rc reason detail
  status_text=""; status_rc=0
  if ! hangctl_cluster_status_collect status_text status_rc; then
    _decision="unknown"
    _reason="status_unavailable"
    _detail="rc=${status_rc}"
    return 0
  fi

  reason=""; detail=""
  if hangctl_cluster_status_is_busy "${status_text}" reason detail; then
    _decision="busy"
    _reason="${reason}"
    _detail="${detail}"
    return 0
  fi

  reason=""; detail=""
  if hangctl_cluster_status_hash_settle_check "${status_text}" reason detail; then
    _decision="settle"
    _reason="${reason}"
    _detail="${detail}"
    return 0
  fi

  _decision="idle"
  _reason="ok"
  _detail=""
  return 0
}
