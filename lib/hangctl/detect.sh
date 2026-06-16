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

# migration job and progress helpers
hangctl__domjob_field() {
  # usage: hangctl__domjob_field <domjobinfo_text> <field_name>
  local text="${1-}"
  local field="${2-}"
  awk -F: -v key="${field}" '
    BEGIN { key_l=tolower(key) }
    {
      name=tolower($1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == key_l) {
        $1=""
        sub(/^:[[:space:]]*/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        print $0
        exit
      }
    }
  ' <<< "${text}"
}

hangctl_classify_domjobinfo() {
  # usage: hangctl_classify_domjobinfo <domstate_full> <domjobinfo_text> <job_type_var> <operation_var> <is_migration_var> <is_backup_var>
  local domstate_full="${1-}"
  local job_out="${2-}"
  local -n _job_type="${3}"
  local -n _operation="${4}"
  local -n _is_migration="${5}"
  local -n _is_backup="${6}"

  _job_type="$(hangctl__domjob_field "${job_out}" "Job type" | awk '{print $1}' | head -n 1)"
  _operation="$(hangctl__domjob_field "${job_out}" "Operation" | head -n 1)"
  [[ -z "${_job_type}" ]] && _job_type="None"

  local dom_lc op_lc job_lc
  dom_lc="$(printf '%s' "${domstate_full}" | tr '[:upper:]' '[:lower:]')"
  op_lc="$(printf '%s' "${_operation}" | tr '[:upper:]' '[:lower:]')"
  job_lc="$(printf '%s' "${job_out}" | tr '[:upper:]' '[:lower:]')"

  _is_migration=0
  if [[ "${dom_lc}" == *"migration"* || "${op_lc}" == *"migration"* ]]; then
    _is_migration=1
  elif [[ "${job_lc}" == *"memory processed"* || "${job_lc}" == *"memory remaining"* || "${job_lc}" == *"memory total"* ]]; then
    _is_migration=1
  fi

  local job_type_lc
  job_type_lc="$(printf '%s' "${_job_type}" | tr '[:upper:]' '[:lower:]')"
  _is_backup=0
  if [[ "${_is_migration}" -eq 0 && -n "${_job_type}" && "${job_type_lc}" != "none" && "${job_type_lc}" != "completed" ]]; then
    _is_backup=1
  fi
}

hangctl_parse_size_to_bytes() {
  # usage: hangctl_parse_size_to_bytes <value> <unit>
  local value="${1-}"
  local unit="${2-}"

  awk -v value="${value}" -v unit="${unit}" '
    BEGIN {
      gsub(/,/, "", value)
      if (value !~ /^[0-9]+([.][0-9]+)?$/) exit 1
      u=tolower(unit)
      gsub(/[^a-z0-9]/, "", u)
      mult=1
      if (u == "" || u == "b" || u == "byte" || u == "bytes") mult=1
      else if (u == "k" || u == "kb" || u == "kib") mult=1024
      else if (u == "m" || u == "mb" || u == "mib") mult=1024*1024
      else if (u == "g" || u == "gb" || u == "gib") mult=1024*1024*1024
      else if (u == "t" || u == "tb" || u == "tib") mult=1024*1024*1024*1024
      else exit 1
      printf "%.0f", value * mult
    }
  '
}

hangctl__domjob_size_bytes() {
  # usage: hangctl__domjob_size_bytes <domjobinfo_text> <field_name>
  local text="${1-}"
  local field="${2-}"
  local raw value unit bytes
  raw="$(hangctl__domjob_field "${text}" "${field}" | head -n 1)"
  [[ -n "${raw}" ]] || return 1
  value="$(awk '{print $1}' <<< "${raw}")"
  unit="$(awk '{print $2}' <<< "${raw}")"
  bytes="$(hangctl_parse_size_to_bytes "${value}" "${unit}" 2>/dev/null)" || return 1
  [[ "${bytes}" =~ ^[0-9]+$ ]] || return 1
  echo -n "${bytes}"
}

hangctl_extract_migration_progress_metric() {
  # usage: hangctl_extract_migration_progress_metric <domjobinfo_text> <kind_var> <bytes_var> <direction_var>
  local job_out="${1-}"
  local -n _kind="${2}"
  local -n _bytes="${3}"
  local -n _direction="${4}"

  _kind=""
  _bytes=""
  _direction="increase"

  if _bytes="$(hangctl__domjob_size_bytes "${job_out}" "Data processed" 2>/dev/null)"; then
    _kind="data_processed"
    _direction="increase"
    return 0
  fi
  if _bytes="$(hangctl__domjob_size_bytes "${job_out}" "Memory processed" 2>/dev/null)"; then
    _kind="memory_processed"
    _direction="increase"
    return 0
  fi
  if _bytes="$(hangctl__domjob_size_bytes "${job_out}" "Memory remaining" 2>/dev/null)"; then
    _kind="memory_remaining"
    _direction="change"
    return 0
  fi

  return 1
}

hangctl_probe_migration_progress_evaluate() {
  # usage: hangctl_probe_migration_progress_evaluate <vm> <domjobinfo_text> <duration_sec> <out_status_var> <out_detail_var>
  local vm="${1-}"
  local job_out="${2-}"
  local duration_sec="${3-0}"
  local -n _status="${4}"
  local -n _detail="${5}"

  _status="not_migration"
  _detail="status=not_migration"

  local kind bytes direction
  if ! hangctl_extract_migration_progress_metric "${job_out}" kind bytes direction; then
    local now_unknown
    now_unknown="$(date +%s)"
    hangctl_state_set_migration_kv_all "${vm}" \
      "migration_last_seen_ts=${now_unknown}" \
      "migration_metric_kind=unknown" || true
    _status="protect_unknown_progress"
    _detail="status=protect_unknown_progress reason=metric_parse_failed note=protecting_active_migration"
    return 0
  fi

  local now prev_bytes prev_kind last_progress_ts progress_window confirm_window
  now="$(date +%s)"
  prev_bytes="$(hangctl_state_get_migration_kv "${vm}" "migration_metric_bytes" 2>/dev/null || true)"
  prev_kind="$(hangctl_state_get_migration_kv "${vm}" "migration_metric_kind" 2>/dev/null || true)"
  last_progress_ts="$(hangctl_state_get_migration_kv "${vm}" "migration_last_progress_ts" 2>/dev/null || true)"
  progress_window="${HANGCTL_MIGRATION_PROGRESS_CHECK_SEC:-300}"
  confirm_window="${HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC:-3600}"

  [[ "${duration_sec}" =~ ^[0-9]+$ ]] || duration_sec=0
  [[ "${progress_window}" =~ ^[0-9]+$ ]] || progress_window=300
  [[ "${confirm_window}" =~ ^[0-9]+$ ]] || confirm_window=3600
  [[ "${prev_bytes}" =~ ^[0-9]+$ ]] || prev_bytes=""
  [[ "${last_progress_ts}" =~ ^[0-9]+$ ]] || last_progress_ts=""

  local progressed=0 delta=0 reason=""
  if [[ -z "${prev_bytes}" || -z "${prev_kind}" || "${prev_kind}" != "${kind}" ]]; then
    progressed=1
    reason="first_observation"
  elif [[ "${direction}" == "increase" ]]; then
    if (( bytes > prev_bytes )); then
      progressed=1
      delta=$(( bytes - prev_bytes ))
    elif (( bytes < prev_bytes )); then
      progressed=1
      reason="metric_reset"
    fi
  else
    if (( bytes != prev_bytes )); then
      progressed=1
      if (( bytes > prev_bytes )); then
        delta=$(( bytes - prev_bytes ))
      else
        delta=$(( prev_bytes - bytes ))
      fi
    fi
  fi

  if [[ "${progressed}" -eq 1 ]]; then
    hangctl_state_set_migration_kv_all "${vm}" \
      "migration_metric_bytes=${bytes}" \
      "migration_metric_kind=${kind}" \
      "migration_last_progress_ts=${now}" \
      "migration_last_seen_ts=${now}" || true
    _status="progressing"
    _detail="status=progressing metric_kind=${kind} metric_bytes=${bytes} delta_bytes=${delta} last_progress_age_sec=0 note=protecting_active_migration"
    [[ -n "${reason}" ]] && _detail="${_detail} reason=${reason}"
    return 0
  fi

  if [[ -z "${last_progress_ts}" ]]; then
    last_progress_ts="${now}"
    hangctl_state_set_migration_kv_all "${vm}" "migration_last_progress_ts=${now}" || true
  fi

  local age=$(( now - last_progress_ts ))
  (( age < 0 )) && age=0
  hangctl_state_set_migration_kv_all "${vm}" \
    "migration_metric_bytes=${bytes}" \
    "migration_metric_kind=${kind}" \
    "migration_last_seen_ts=${now}" || true

  if (( age >= progress_window && duration_sec >= confirm_window )); then
    _status="zombie_no_progress"
    _detail="status=zombie_no_progress metric_kind=${kind} metric_bytes=${bytes} last_progress_age_sec=${age} progress_window_sec=${progress_window} confirm_window_sec=${confirm_window}"
    return 0
  fi

  _status="no_progress_within_grace"
  _detail="status=no_progress_within_grace metric_kind=${kind} metric_bytes=${bytes} last_progress_age_sec=${age} progress_window_sec=${progress_window} confirm_window_sec=${confirm_window} note=protecting_active_migration"
  return 0
}

# migration zombie check
hangctl_probe_migration_zombie_check() {
  # usage: hangctl_probe_migration_zombie_check <vm>
  # Backward-compatible wrapper. Return 0 only when a migration zombie is confirmed.
  local vm="${1-}"
  local out err rc=0
  local status detail

  hangctl_virsh "${HANGCTL_VIRSH_TIMEOUT_SEC}" out err rc -- -c qemu:///system domjobinfo "${vm}" || true
  hangctl_probe_migration_progress_evaluate "${vm}" "${out}" "${HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC:-3600}" status detail || true
  [[ "${status}" == "zombie_no_progress" ]]
}

# detect.sh ??Ï∂îÍ?

# QMPÎ•??µÌï¥ Î™®Îì† Í∞Ä???îÏä§?¨Ïùò I/O ?µÍ≥ÑÎ•??òÏßë?òÎäî ?®Ïàò
hangctl_probe_blockstats() {
  # usage: hangctl_probe_blockstats <vm> <out_rd_ops_var> <out_wr_ops_var>
  local vm="${1-}"
  local -n _rd_ops="${2}"
  local -n _wr_ops="${3}"

  _rd_ops=0
  _wr_ops=0

  local out err rc
  out=""
  err=""
  rc=0

  # QMP query-blockstats ?§Ìñâ (Î™®Îì† ?úÎùº?¥Î∏å???µÍ≥ÑÎ•??©ÏÇ∞?òÏó¨ ?ÑÏ≤¥ I/O ?êÎ¶Ñ ?åÏïÖ)
  local cmd='{"execute":"query-blockstats"}'
  hangctl_virsh "${HANGCTL_QMP_TIMEOUT_SEC}" out err rc -- -c qemu:///system qemu-monitor-command "${vm}" --cmd "${cmd}" || true

  local result
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    return "${rc}"
  fi

  # jqÎ•??¨Ïö©?òÏó¨ Î™®Îì† ?úÎùº?¥Î∏å??rd_operations?Ä wr_operations ?©Í≥Ñ Ï∂îÏ∂ú
  if command -v jq >/dev/null 2>&1; then
    _rd_ops=$(echo "${out}" | jq '[.return[].stats.rd_operations] | add' 2>/dev/null || echo "0")
    _wr_ops=$(echo "${out}" | jq '[.return[].stats.wr_operations] | add' 2>/dev/null || echo "0")
  else
    # jqÍ∞Ä ?ÜÎäî Í≤ΩÏö∞ Ï≤?Î≤àÏß∏ ?•Ïπò???òÏπòÎß?sedÎ°?Ï∂îÏ∂ú (fallback)
    _rd_ops=$(echo "${out}" | sed -nE 's/.*"rd_operations"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1 || echo "0")
    _wr_ops=$(echo "${out}" | sed -nE 's/.*"wr_operations"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1 || echo "0")
  fi

  [[ -z "${_rd_ops}" ]] && _rd_ops=0
  [[ -z "${_wr_ops}" ]] && _wr_ops=0

  return 0
}

# Î∏îÎ°ù I/O Stall ?¨Î?Î•??êÎã®?òÎäî ?®Ïàò
hangctl_detect_block_stall() {
  # usage: hangctl_detect_block_stall <vm> <curr_rd> <curr_wr>
  # return: 0 (Stall ?òÏã¨), 1 (?ïÏÉÅ ?êÎäî ?êÎã® Î∂àÍ?)
  local vm="${1-}"
  local curr_rd="${2-0}"
  local curr_wr="${3-0}"

  local prev_rd=0
  local prev_wr=0
  # 1?®Í≥Ñ?êÏÑú ÎßåÎì† ?®ÏàòÎ°??¥Ï†Ñ Í∞?Î°úÎìú
  hangctl_state_get_prev_blockstats "${vm}" prev_rd prev_wr

  # ?ÑÏû¨ ?òÏπòÎ•??§Ïùå ?§Ï∫î???ÑÌï¥ ?Ä??
  hangctl_state_update_blockstats "${vm}" "${curr_rd}" "${curr_wr}"

  # ?¥Ï†Ñ Í∏∞Î°ù???ÜÏúºÎ©?Ï≤??§Ï∫î) ?ïÏÉÅ?ºÎ°ú Í∞ÑÏ£º
  if [[ "${prev_rd}" -eq 0 && "${prev_wr}" -eq 0 ]]; then
    return 1
  fi

  # ?êÎã® Î°úÏßÅ: I/O ?îÏ≤≠ ?üÏàòÍ∞Ä ?¥Ï†ÑÍ≥??ïÌôï???ºÏπò?úÎã§Î©?
  # 1. ?ÑÏòà I/OÍ∞Ä ?ÜÎäî ?úÍ????ÅÌÉú?¥Í±∞??
  # 2. I/OÍ∞Ä ÍΩ?ÎßâÌ???Ï≤òÎ¶¨Í∞Ä ???òÍ≥† ?àÎäî ?ÅÌÉú??
  if [[ "${curr_rd}" -eq "${prev_rd}" && "${curr_wr}" -eq "${prev_wr}" ]]; then
    # ???úÏ†ê?êÏÑú???òÏã¨(suspect) ?®Í≥ÑÎ°?Î≥¥Í≥† duration???ÑÏ†Å?òÍ≤å ??
    return 0
  fi

  return 1
}
