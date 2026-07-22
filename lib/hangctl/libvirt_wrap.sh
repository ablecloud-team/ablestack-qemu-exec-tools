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

# Commit 04 scope:
# - Global lock (flock) to prevent overlapping timer runs
# - Command runner with consistent timeout handling
# - virsh wrapper entry points (minimal)

hangctl_lock_acquire_or_exit() {
  # Acquire a global lock; if already locked, exit gracefully.
  # Requires: HANGCTL_LOCK_FILE (config.sh)
  local lock_file="${HANGCTL_LOCK_FILE-}"
  if [[ -z "${lock_file}" ]]; then
    lock_file="/run/ablestack-vm-hangctl/lock"
  fi

  local lock_dir
  lock_dir="$(dirname "${lock_file}")"
  if [[ ! -d "${lock_dir}" ]]; then
    mkdir -p "${lock_dir}" 2>/dev/null || true
  fi

  # FD 200 reserved for lock
  exec 200>"${lock_file}"
  if ! flock -n 200; then
    # Already running; do not treat as error (timer overlap)
    hangctl_log_event "scan" "scan.skip" "skip" "" "" "" "reason=locked lock_file=${lock_file}"
    exit 0
  fi
}

hangctl__result_from_rc() {
  local rc="${1-}"
  if [[ "${rc}" == "0" ]]; then
    echo "ok"
  elif [[ "${rc}" == "124" || "${rc}" == "137" || "${rc}" == "143" ]]; then
    echo "timeout"
  else
    echo "fail"
  fi
}

hangctl_cmd_run() {
  # Run a command with timeout and capture stdout/stderr into variables.
  #
  # usage:
  #   hangctl_cmd_run <timeout_sec> <out_var> <err_var> <rc_var> -- <cmd...>
  #
  # rc mapping:
  #   0      success
  #   124    timeout (from GNU timeout)
  #   other  command rc
  local timeout_sec="${1-}"
  local -n _cmd_out="${2}"
  local -n _cmd_err="${3}"
  local -n _cmd_rc="${4}"
  shift 4
  if [[ "${1-}" != "--" ]]; then
    _cmd_out=""
    _cmd_err="invalid_args"
    _cmd_rc=2
    return 2
  fi
  shift

  _cmd_out=""
  _cmd_err=""

  local tmp_out tmp_err
  tmp_out="$(mktemp -t hangctl.out.XXXXXX)"
  tmp_err="$(mktemp -t hangctl.err.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_out}' '${tmp_err}' 2>/dev/null || true" RETURN

  if [[ -z "${timeout_sec}" ]]; then
    timeout_sec="3"
  fi

  # Use timeout if available; otherwise run without timeout (best effort)
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status "${timeout_sec}" "$@" >"${tmp_out}" 2>"${tmp_err}"
    _rc=$?
  else
    "$@" >"${tmp_out}" 2>"${tmp_err}"
    _rc=$?
  fi

  _cmd_out="$(cat "${tmp_out}" 2>/dev/null || true)"
  _cmd_err="$(cat "${tmp_err}" 2>/dev/null || true)"
  _cmd_rc="${_rc}"
  return "${_rc}"
}

hangctl_virsh() {
  # Minimal virsh wrapper with timeout.
  #
  # usage:
  #   hangctl_virsh <timeout_sec> <out_var> <err_var> <rc_var> -- <virsh args...>
  local timeout_sec="${1-}"
  local out_var="${2-}"
  local err_var="${3-}"
  local rc_var="${4-}"
  shift 4
  # Backward-compat:
  # Some callers previously passed a literal "--" sentinel.
  # virsh interprets "virsh -- -c ..." as "-c is a command", so strip it.
  if [[ "${1-}" == "--" ]]; then
    shift
  fi
  # pass variable names (strings) to hangctl_cmd_run (it uses nameref internally)
  hangctl_cmd_run "${timeout_sec}" "${out_var}" "${err_var}" "${rc_var}" -- virsh "$@"
}

hangctl_virsh_event() {
  # Run virsh and emit a single event capturing result.
  #
  # usage:
  #   hangctl_virsh_event <stage> <event> <timeout_sec> -- <virsh args...>
  local stage="${1-}"
  local event="${2-}"
  local timeout_sec="${3-}"
  shift 3
  if [[ "${1-}" != "--" ]]; then
    hangctl_log_event "${stage}" "${event}" "fail" "" "" "2" "reason=invalid_args"
    return 2
  fi
  shift

  local out err rc
  hangctl_virsh "${timeout_sec}" out err rc "$@"
  local result
  result="$(hangctl__result_from_rc "${rc}")"

  # Truncate err to avoid huge logs (keep first 200 chars)
  local err_short="${err:0:200}"
  local err_url="${err_short// /%20}"
  if [[ -n "${err_short}" ]]; then
    hangctl_log_event "${stage}" "${event}" "${result}" "" "" "${rc}" "timeout_sec=${timeout_sec} err_url=${err_url}"
  else
    hangctl_log_event "${stage}" "${event}" "${result}" "" "" "${rc}" "timeout_sec=${timeout_sec}"
  fi
  return "${rc}"
}

# ---------------------------------------------------------------------
# Commit 10: libvirtd health gate + safe restart (cooldown + threshold)
# ---------------------------------------------------------------------

hangctl__state_get_int() {
  local path="${1-}"
  local def="${2-0}"
  if [[ -z "${path}" || ! -f "${path}" ]]; then
    echo "${def}"
    return 0
  fi
  local v
  v="$(cat "${path}" 2>/dev/null || true)"
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    echo "${v}"
  else
    echo "${def}"
  fi
}

hangctl__state_set_int() {
  local path="${1-}"
  local val="${2-0}"
  [[ -z "${path}" ]] && return 0
  mkdir -p "$(dirname "${path}")" 2>/dev/null || true
  printf "%s\n" "${val}" > "${path}" 2>/dev/null || true
}

hangctl_libvirtd_failcount_path() {
  echo "${HANGCTL_STATE_DIR}/libvirtd.failcount"
}

hangctl_libvirtd_last_restart_path() {
  echo "${HANGCTL_STATE_DIR}/libvirtd.last_restart_ts"
}

hangctl_libvirtd_backoff_until_path() {
  echo "${HANGCTL_STATE_DIR}/libvirtd.restart_backoff_until"
}

hangctl_libvirtd_restart_history_path() {
  echo "${HANGCTL_STATE_DIR}/libvirtd.restart_history"
}

hangctl_libvirtd_failcount_get() {
  hangctl__state_get_int "$(hangctl_libvirtd_failcount_path)" "0"
}

hangctl_libvirtd_failcount_set() {
  hangctl__state_set_int "$(hangctl_libvirtd_failcount_path)" "${1-0}"
}

hangctl_libvirtd_failcount_inc() {
  local cur
  cur="$(hangctl_libvirtd_failcount_get)"
  cur=$((cur + 1))
  hangctl_libvirtd_failcount_set "${cur}"
  echo "${cur}"
}

hangctl_libvirtd_last_restart_get() {
  hangctl__state_get_int "$(hangctl_libvirtd_last_restart_path)" "0"
}

hangctl_libvirtd_last_restart_set_now() {
  local now
  now="$(date +%s)"
  hangctl__state_set_int "$(hangctl_libvirtd_last_restart_path)" "${now}"
}

hangctl_libvirtd_backoff_set() {
  local sec="${1-0}"
  [[ "${sec}" =~ ^[0-9]+$ ]] || sec=0
  (( sec > 0 )) || return 0
  local now
  now="$(date +%s)"
  hangctl__state_set_int "$(hangctl_libvirtd_backoff_until_path)" "$((now + sec))"
}

hangctl_libvirtd_backoff_remaining() {
  local until now
  until="$(hangctl__state_get_int "$(hangctl_libvirtd_backoff_until_path)" "0")"
  now="$(date +%s)"
  if (( until > now )); then
    echo $((until - now))
  else
    echo 0
  fi
}

hangctl_libvirtd_restart_history_record() {
  local now path tmp cutoff
  now="$(date +%s)"
  cutoff=$((now - 3600))
  path="$(hangctl_libvirtd_restart_history_path)"
  mkdir -p "$(dirname "${path}")" 2>/dev/null || true
  tmp="${path}.tmp"
  if [[ -f "${path}" ]]; then
    awk -v cutoff="${cutoff}" '$1 ~ /^[0-9]+$/ && $1 >= cutoff { print $1 }' "${path}" > "${tmp}" 2>/dev/null || true
  else
    : > "${tmp}"
  fi
  printf "%s\n" "${now}" >> "${tmp}"
  mv -f "${tmp}" "${path}" 2>/dev/null || true
}

hangctl_libvirtd_restart_history_count() {
  local now cutoff path
  now="$(date +%s)"
  cutoff=$((now - 3600))
  path="$(hangctl_libvirtd_restart_history_path)"
  [[ -f "${path}" ]] || { echo 0; return 0; }
  awk -v cutoff="${cutoff}" '$1 ~ /^[0-9]+$/ && $1 >= cutoff { c++ } END { print c+0 }' "${path}" 2>/dev/null || echo 0
}

hangctl_libvirtd_health_check_raw() {
  # usage: hangctl_libvirtd_health_check_raw <timeout_sec> <out_var> <err_var> <rc_var>
  local timeout_sec="${1-3}"
  local -n _out="${2}"
  local -n _err="${3}"
  local -n _rc="${4}"
  _out=""
  _err=""
  _rc=0

  # Minimal API check (fast, low-cost)
  hangctl_virsh "${timeout_sec}" _out _err _rc -- -c qemu:///system list --name || true
  return 0
}

hangctl_libvirtd__socket_exists() {
  local sockets="${HANGCTL_LIBVIRTD_EXPECTED_SOCKET-}"
  local sock
  for sock in ${sockets}; do
    [[ -S "${sock}" ]] && return 0
  done
  return 1
}

hangctl_libvirtd_health_check_classified() {
  # usage: hangctl_libvirtd_health_check_classified <timeout_sec> <result_var> <class_var> <detail_var> <rc_var>
  local timeout_sec="${1-3}"
  local -n _result="${2}"
  local -n _class="${3}"
  local -n _detail="${4}"
  local -n _rc="${5}"
  _result="fail"
  _class="unknown"
  _detail=""
  _rc=1

  local svc="${HANGCTL_LIBVIRTD_SERVICE:-libvirtd.service}"
  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet "${svc}" 2>/dev/null; then
      _result="fail"
      _class="service_inactive"
      _detail="service=${svc}"
      _rc=3
      return 0
    fi
  fi

  if [[ -n "${HANGCTL_LIBVIRTD_EXPECTED_SOCKET-}" ]] && ! hangctl_libvirtd__socket_exists; then
    _result="fail"
    _class="socket_missing"
    _detail="socket=missing"
    _rc=2
    return 0
  fi

  local out err raw_rc
  out=""; err=""; raw_rc=0
  hangctl_libvirtd_health_check_raw "${timeout_sec}" out err raw_rc
  _result="$(hangctl__result_from_rc "${raw_rc}")"
  _rc="${raw_rc}"
  if [[ "${_result}" == "ok" ]]; then
    _class="ok"
    _detail="service=${svc}"
    return 0
  fi

  local err_short="${err:0:200}"
  err_short="${err_short// /%20}"
  if [[ "${_result}" == "timeout" ]]; then
    _class="api_timeout"
  else
    _class="command_fail"
  fi
  _detail="service=${svc}"
  [[ -n "${err_short}" ]] && _detail+=" err_url=${err_short}"
  return 0
}

hangctl_libvirtd_health_class_restart_eligible() {
  local class="${1-}"
  case "${class}" in
    service_inactive|socket_missing)
      return 0
      ;;
    api_timeout)
      [[ "${HANGCTL_LIBVIRTD_RESTART_ON_API_TIMEOUT:-0}" == "1" ]]
      return $?
      ;;
    *)
      return 1
      ;;
  esac
}

hangctl_libvirtd_restart_safe() {
  # usage: hangctl_libvirtd_restart_safe <stage>
  local stage="${1-scan}"
  local svc="${HANGCTL_LIBVIRTD_SERVICE}"

  local out err rc
  out=""; err=""; rc=0

  hangctl_log_event "${stage}" "libvirtd.restart.start" "ok" "" "" "" \
    "service=${svc} timeout_sec=${HANGCTL_LIBVIRTD_RESTART_TIMEOUT_SEC}"

  hangctl_cmd_run "${HANGCTL_LIBVIRTD_RESTART_TIMEOUT_SEC}" out err rc -- systemctl restart "${svc}" || true
  local result
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    local err_short="${err:0:200}"
    hangctl_log_event "${stage}" "libvirtd.restart.end" "fail" "" "" "${rc}" \
      "service=${svc} err_url=${err_short// /%20}"
    return 1
  fi

  hangctl_libvirtd_last_restart_set_now
  hangctl_libvirtd_restart_history_record

  # Post-restart verify loop
  local i ok="0"
  for ((i=0; i<${HANGCTL_LIBVIRTD_POST_RESTART_WAIT_SEC}; i++)); do
    local hout herr hrc
    hout=""; herr=""; hrc=0
    hangctl_libvirtd_health_check_raw "${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC}" hout herr hrc
    local hres
    hres="$(hangctl__result_from_rc "${hrc}")"
    if [[ "${hres}" == "ok" ]]; then
      ok="1"
      break
    fi
    sleep 1
  done

  if [[ "${ok}" == "1" ]]; then
    hangctl_log_event "${stage}" "libvirtd.restart.verify" "ok" "" "" "" \
      "wait_sec=${HANGCTL_LIBVIRTD_POST_RESTART_WAIT_SEC}"
    hangctl_log_event "${stage}" "libvirtd.restart.end" "ok" "" "" 0 \
      "service=${svc}"
    return 0
  fi

  hangctl_log_event "${stage}" "libvirtd.restart.verify" "fail" "" "" "" \
    "wait_sec=${HANGCTL_LIBVIRTD_POST_RESTART_WAIT_SEC}"
  hangctl_log_event "${stage}" "libvirtd.restart.end" "warn" "" "" 0 \
    "service=${svc} reason=verify_timeout"
  return 2
}

hangctl_libvirtd_health_gate() {
  # Circuit breaker gate:
  # - Update consecutive failcount
  # - If failcount >= threshold (default 2), attempt restart (cooldown guarded)
  # - Return 0 when healthy (or recovered), non-zero when unhealthy
  #
  # usage: hangctl_libvirtd_health_gate <stage>
  local stage="${1-scan}"

  local result class detail rc
  result=""; class=""; detail=""; rc=0
  hangctl_libvirtd_health_check_classified "${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC}" result class detail rc

  if [[ "${result}" == "ok" ]]; then
    hangctl_libvirtd_failcount_set 0
    hangctl_log_event "${stage}" "libvirtd.health" "ok" "" "" 0 \
      "timeout_sec=${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC} fail_count=0 class=${class}"
    return 0
  fi

  local fc
  fc="$(hangctl_libvirtd_failcount_inc)"
  hangctl_log_event "${stage}" "libvirtd.health" "${result}" "" "" "${rc}" \
    "timeout_sec=${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC} fail_count=${fc} class=${class} ${detail}"

  local th="${HANGCTL_LIBVIRTD_FAIL_THRESHOLD}"
  if [[ "${fc}" -lt "${th}" ]]; then
    return 1
  fi

  # threshold reached -> restart path (cooldown guarded)
  if [[ "${HANGCTL_LIBVIRTD_RESTART_ENABLED}" != "1" ]]; then
    hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" "reason=disabled"
    return 2
  fi

  if [[ "${HANGCTL_DRY_RUN}" == "1" ]]; then
    hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" "reason=dry_run"
    return 2
  fi

  local remain
  remain="$(hangctl_libvirtd_backoff_remaining)"
  if [[ "${remain}" =~ ^[0-9]+$ && "${remain}" -gt 0 ]]; then
    hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" \
      "reason=backoff remain=${remain}"
    return 2
  fi

  if ! hangctl_libvirtd_health_class_restart_eligible "${class}"; then
    hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" \
      "reason=health_class class=${class}"
    return 2
  fi

  local now last cd
  now="$(date +%s)"
  last="$(hangctl_libvirtd_last_restart_get)"
  cd="${HANGCTL_LIBVIRTD_RESTART_COOLDOWN_SEC}"
  if (( last > 0 && (now - last) < cd )); then
    hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" \
      "reason=cooldown remain=$((cd - (now - last)))"
    return 2
  fi

  local max_per_hour hist_count
  max_per_hour="${HANGCTL_LIBVIRTD_RESTART_MAX_PER_HOUR:-1}"
  [[ "${max_per_hour}" =~ ^[0-9]+$ ]] || max_per_hour=1
  hist_count="$(hangctl_libvirtd_restart_history_count)"
  if (( max_per_hour > 0 && hist_count >= max_per_hour )); then
    hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" \
      "reason=max_per_hour count=${hist_count} limit=${max_per_hour}"
    return 2
  fi

  if declare -F hangctl_cluster_guard_probe >/dev/null 2>&1; then
    local guard guard_reason guard_detail
    guard=""; guard_reason=""; guard_detail=""
    hangctl_cluster_guard_probe "${stage}" guard guard_reason guard_detail || true
    case "${guard}" in
      idle|disabled)
        ;;
      busy)
        hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" \
          "reason=cluster_busy guard_reason=${guard_reason} ${guard_detail}"
        return 2
        ;;
      settle)
        hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" \
          "reason=cluster_settle guard_reason=${guard_reason} ${guard_detail}"
        return 2
        ;;
      *)
        if [[ "${HANGCTL_CLUSTER_GUARD_FAIL_CLOSED:-1}" == "1" ]]; then
          hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" \
            "reason=cluster_unknown guard_reason=${guard_reason} ${guard_detail}"
          return 2
        fi
        ;;
    esac
  elif [[ "${HANGCTL_CLUSTER_GUARD_ENABLE:-1}" == "1" && "${HANGCTL_CLUSTER_GUARD_FAIL_CLOSED:-1}" == "1" ]]; then
    hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" \
      "reason=cluster_unknown guard_reason=guard_unavailable"
    return 2
  fi

  local restart_rc=0
  hangctl_libvirtd_restart_safe "${stage}" || restart_rc=$?
  if [[ "${restart_rc}" != "0" ]]; then
    hangctl_libvirtd_backoff_set "${HANGCTL_LIBVIRTD_RESTART_BACKOFF_SEC:-3600}"
  fi

  # After restart attempt, re-check quickly:
  result=""; class=""; detail=""; rc=0
  hangctl_libvirtd_health_check_classified "${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC}" result class detail rc
  if [[ "${result}" == "ok" ]]; then
    hangctl_libvirtd_failcount_set 0
    hangctl_log_event "${stage}" "libvirtd.health" "ok" "" "" 0 \
      "timeout_sec=${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC} fail_count=0 recovered=restart class=${class}"
    return 0
  fi

  hangctl_libvirtd_backoff_set "${HANGCTL_LIBVIRTD_RESTART_BACKOFF_SEC:-3600}"
  return 3
}
