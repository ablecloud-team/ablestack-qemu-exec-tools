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

# migration zombie check
hangctl_probe_migration_zombie_check() {
  # usage: hangctl_probe_migration_zombie_check <vm>
  local vm="${1-}"
  local out err rc=0
  
  # 1. 마이그레이션 작업 정보 조회
  hangctl_virsh "${HANGCTL_VIRSH_TIMEOUT_SEC}" out err rc -- -c qemu:///system domjobinfo "${vm}" || true
  
  # 'Data processed' 또는 'Memory remaining' 수치 추출 (대상 호스트 기준)
  local current_data
  current_data="$(echo "${out}" | grep -iE "Data processed|Memory processed" | awk '{print $3}' | tr -d ',' || echo "0")"
  
  # 2. 진척도 비교 (이전 스캔 대비 데이터 유입량)
  local diff
  diff="$(hangctl_state_get_migration_progress "${vm}" "${current_data}")"
  
  # 데이터 변화가 0이고, 이미 설정된 마이그레이션 임계치를 넘었다면 좀비로 판단
  if [[ "${diff}" -eq 0 ]]; then
    return 0 # 진척 없음 (위험)
  fi
  return 1 # 진행 중 (정상)
}

# detect.sh 에 추가

# QMP를 통해 모든 가상 디스크의 I/O 통계를 수집하는 함수
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

  # QMP query-blockstats 실행 (모든 드라이브의 통계를 합산하여 전체 I/O 흐름 파악)
  local cmd='{"execute":"query-blockstats"}'
  hangctl_virsh "${HANGCTL_QMP_TIMEOUT_SEC}" out err rc -- -c qemu:///system qemu-monitor-command "${vm}" --cmd "${cmd}" || true

  local result
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    return "${rc}"
  fi

  # jq를 사용하여 모든 드라이브의 rd_operations와 wr_operations 합계 추출
  if command -v jq >/dev/null 2>&1; then
    _rd_ops=$(echo "${out}" | jq '[.return[].stats.rd_operations] | add' 2>/dev/null || echo "0")
    _wr_ops=$(echo "${out}" | jq '[.return[].stats.wr_operations] | add' 2>/dev/null || echo "0")
  else
    # jq가 없는 경우 첫 번째 장치의 수치만 sed로 추출 (fallback)
    _rd_ops=$(echo "${out}" | sed -nE 's/.*"rd_operations"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1 || echo "0")
    _wr_ops=$(echo "${out}" | sed -nE 's/.*"wr_operations"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n 1 || echo "0")
  fi

  [[ -z "${_rd_ops}" ]] && _rd_ops=0
  [[ -z "${_wr_ops}" ]] && _wr_ops=0

  return 0
}

# 블록 I/O Stall 여부를 판단하는 함수
hangctl_detect_block_stall() {
  # usage: hangctl_detect_block_stall <vm> <curr_rd> <curr_wr>
  # return: 0 (Stall 의심), 1 (정상 또는 판단 불가)
  local vm="${1-}"
  local curr_rd="${2-0}"
  local curr_wr="${3-0}"

  local prev_rd=0
  local prev_wr=0
  # 1단계에서 만든 함수로 이전 값 로드
  hangctl_state_get_prev_blockstats "${vm}" prev_rd prev_wr

  # 현재 수치를 다음 스캔을 위해 저장
  hangctl_state_update_blockstats "${vm}" "${curr_rd}" "${curr_wr}"

  # 이전 기록이 없으면(첫 스캔) 정상으로 간주
  if [[ "${prev_rd}" -eq 0 && "${prev_wr}" -eq 0 ]]; then
    return 1
  fi

  # 판단 로직: I/O 요청 횟수가 이전과 정확히 일치한다면?
  # 1. 아예 I/O가 없는 한가한 상태이거나
  # 2. I/O가 꽉 막혀서 처리가 안 되고 있는 상태임
  if [[ "${curr_rd}" -eq "${prev_rd}" && "${curr_wr}" -eq "${prev_wr}" ]]; then
    # 이 시점에서는 의심(suspect) 단계로 보고 duration을 누적하게 됨
    return 0
  fi

  return 1
}
