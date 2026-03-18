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
  elif [[ "${rc}" == "124" ]]; then
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

  local out err rc
  out=""; err=""; rc=0
  hangctl_libvirtd_health_check_raw "${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC}" out err rc
  local result
  result="$(hangctl__result_from_rc "${rc}")"

  if [[ "${result}" == "ok" ]]; then
    hangctl_libvirtd_failcount_set 0
    hangctl_log_event "${stage}" "libvirtd.health" "ok" "" "" 0 \
      "timeout_sec=${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC} fail_count=0"
    return 0
  fi

  local fc
  fc="$(hangctl_libvirtd_failcount_inc)"
  local err_short="${err:0:200}"
  hangctl_log_event "${stage}" "libvirtd.health" "${result}" "" "" "${rc}" \
    "timeout_sec=${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC} fail_count=${fc} err_url=${err_short// /%20}"

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

  local now last cd
  now="$(date +%s)"
  last="$(hangctl_libvirtd_last_restart_get)"
  cd="${HANGCTL_LIBVIRTD_RESTART_COOLDOWN_SEC}"
  if (( last > 0 && (now - last) < cd )); then
    hangctl_log_event "${stage}" "libvirtd.restart.skip" "ok" "" "" "" \
      "reason=cooldown remain=$((cd - (now - last)))"
    return 2
  fi

  hangctl_libvirtd_restart_safe "${stage}" || true

  # After restart attempt, re-check quickly:
  out=""; err=""; rc=0
  hangctl_libvirtd_health_check_raw "${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC}" out err rc
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" == "ok" ]]; then
    hangctl_libvirtd_failcount_set 0
    hangctl_log_event "${stage}" "libvirtd.health" "ok" "" "" 0 \
      "timeout_sec=${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC} fail_count=0 recovered=restart"
    return 0
  fi

  return 3
}
