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

ftctl_lock_acquire_or_exit() {
  local lock_file="${FTCTL_LOCK_FILE}"
  ftctl_ensure_dir "$(dirname "${lock_file}")" "0755"
  exec 201>"${lock_file}"
  if ! flock -n 201; then
    ftctl_log_event "scan" "scan.skip" "skip" "" "" "reason=locked"
    exit 0
  fi
}

ftctl_cmd_run() {
  local timeout_sec="${1-3}"
  local -n _out="${2}"
  local -n _err="${3}"
  local -n _rc="${4}"
  shift 4
  [[ "${1-}" == "--" ]] || {
    _out=""
    _err="invalid_args"
    _rc=2
    return 2
  }
  shift

  local tmp_out tmp_err
  tmp_out="$(mktemp -t ftctl.out.XXXXXX)"
  tmp_err="$(mktemp -t ftctl.err.XXXXXX)"
  trap 'rm -f "${tmp_out}" "${tmp_err}" 2>/dev/null || true' RETURN

  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status "${timeout_sec}" "$@" >"${tmp_out}" 2>"${tmp_err}" || _rc=$?
    : "${_rc:=0}"
  else
    "$@" >"${tmp_out}" 2>"${tmp_err}" || _rc=$?
    : "${_rc:=0}"
  fi

  _out="$(cat "${tmp_out}" 2>/dev/null || true)"
  _err="$(cat "${tmp_err}" 2>/dev/null || true)"
  return "${_rc}"
}

ftctl_result_from_rc() {
  local rc="${1-}"
  if [[ "${rc}" == "0" ]]; then
    echo "ok"
  elif [[ "${rc}" == "124" ]]; then
    echo "timeout"
  else
    echo "fail"
  fi
}

ftctl_virsh() {
  local timeout_sec="${1-3}"
  local out_var="${2}"
  local err_var="${3}"
  local rc_var="${4}"
  shift 4
  [[ "${1-}" == "--" ]] && shift
  ftctl_cmd_run "${timeout_sec}" "${out_var}" "${err_var}" "${rc_var}" -- virsh "$@" || return $?
}

ftctl_local_health() {
  local json="${1-0}"
  local out err rc result
  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_HEALTH_INTERVAL_SEC}" out err rc -- -c "${FTCTL_DEFAULT_PRIMARY_URI}" list --name || true
  : "${out}${err}"
  result="$(ftctl_result_from_rc "${rc}")"
  ftctl_log_event "health" "libvirt.local" "${result}" "" "${rc}" "uri=${FTCTL_DEFAULT_PRIMARY_URI}"
  if [[ "${json}" == "1" ]]; then
    printf '{"result":"%s","uri":"%s","rc":%s}\n' "${result}" "${FTCTL_DEFAULT_PRIMARY_URI}" "${rc}"
  else
    printf 'libvirt.local: %s (%s)\n' "${result}" "${FTCTL_DEFAULT_PRIMARY_URI}"
  fi
  [[ "${rc}" == "0" ]]
}
