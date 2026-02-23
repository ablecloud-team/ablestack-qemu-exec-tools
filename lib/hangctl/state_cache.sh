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

# Commit 06 scope:
# - Track per-VM domstate and last change timestamp in /run cache
# - Calculate stuck_sec = now - last_change_ts

# Commit 08 scope:
# - Track migration progress by recording cumulative bytes in a separate file, and calculating incremental progress for
hangctl_state__vm_key() {
  # Safe key for filename
  local vm="${1-}"
  vm="${vm//\//_}"
  vm="${vm// /_}"
  echo -n "${vm}"
}

# Generate path for VM-specific state file in the runtime directory, e.g., /run/ablestack-vm-hangctl/state/<vm>.state
hangctl_state__path() {
  local vm="${1-}"
  local key
  key="$(hangctl_state__vm_key "${vm}")"
  local dir="${HANGCTL_STATE_DIR-}"
  if [[ -z "${dir}" ]]; then
    dir="/run/ablestack-vm-hangctl/state"
  fi
  echo -n "${dir}/${key}.state"
}

# Simple key=value 파일에서 특정 키의 값을 읽는 유틸리티 함수
hangctl_state__read_kv() {
  # usage: hangctl_state__read_kv <path> <key>
  local path="${1-}"
  local key="${2-}"
  [[ -f "${path}" ]] || return 1
  grep -E "^${key}=" "${path}" 2>/dev/null | head -n 1 | cut -d= -f2-
}

# VM별 상태 기록 파일에 domstate와 마지막 변경 시점(timestamp)을 기록하여, hang 상태 지속 시간을 계산하는 데 활용
hangctl_state__write_file() {
  # usage: hangctl_state__write_file <path> <domstate> <last_change_ts>
  local path="${1-}"
  local domstate="${2-}"
  local last_change_ts="${3-}"

  local dir
  dir="$(dirname "${path}")"
  [[ -d "${dir}" ]] || mkdir -p "${dir}" 2>/dev/null || true

  cat > "${path}.tmp" <<EOF
domstate=${domstate}
last_change_ts=${last_change_ts}
EOF
  mv -f "${path}.tmp" "${path}" 2>/dev/null || {
    # best effort
    rm -f "${path}.tmp" 2>/dev/null || true
    return 1
  }
  return 0
}

# VM의 현재 domstate를 기록하고, 상태 변경 시점을 업데이트하여 stuck_sec 계산에 활용
hangctl_state_update_domstate() {
  # usage: hangctl_state_update_domstate <vm> <domstate>
  local vm="${1-}"
  local domstate="${2-}"
  local path
  path="$(hangctl_state__path "${vm}")"

  local now
  now="$(date +%s)"

  local prev_state prev_change
  prev_state="$(hangctl_state__read_kv "${path}" "domstate" || true)"
  prev_change="$(hangctl_state__read_kv "${path}" "last_change_ts" || true)"

  local change_ts="${prev_change}"
  if [[ -z "${prev_state}" ]]; then
    # 처음 발견된 VM은 현재 상태를 기준으로 기록을 시작하여 stuck_sec을 0으로 유지
    prev_state="${domstate}"
    change_ts="${now}"
  elif [[ "${prev_state}" != "${domstate}" ]]; then
    change_ts="${now}"
  elif [[ -z "${change_ts}" ]]; then
    change_ts="${now}"
  fi

  hangctl_state__write_file "${path}" "${domstate}" "${change_ts}" || true
}

# VM이 hang 상태에서 벗어난 후에도 일정 시간 동안 기록을 유지하여, 스캔 간격이 길어도 stuck_sec 계산이 계속 유효하도록 함
hangctl_state_get_duration_sec() {
  # usage: hangctl_state_get_duration_sec <vm>
  local vm="${1-}"
  local path
  path="$(hangctl_state__path "${vm}")"
  local now
  now="$(date +%s)"
  local change_ts
  change_ts="$(hangctl_state__read_kv "${path}" "last_change_ts" || true)"
  if [[ -z "${change_ts}" ]]; then
    echo -n "0"
    return 0
  fi
  local duration=$(( now - change_ts ))
  if [[ "${duration}" -lt 0 ]]; then
    duration=0
  fi
  echo -n "${duration}"
}

# Migration 진행 상황 추적을 위해 별도 파일에 누적된 바이트 수 기록
hangctl_state_get_migration_progress() {
  # usage: hangctl_state_get_migration_progress <vm> <current_bytes>
  local vm="${1-}"
  local current="${2-0}"
  local path
  path="$(hangctl_state__path "${vm}").migrate"

  local prev
  prev="$(cat "${path}" 2>/dev/null || echo "0")"
  
  # 현재 수치를 파일에 저장
  echo "${current}" > "${path}"
  
  # 이전 수치와 비교하여 증분 반환
  echo $(( current - prev ))
}

# VM이 종료되어 상태 초기화가 필요한 경우, 캐시 파일을 삭제하여 다음 스캔에서 새롭게 기록 시작
hangctl_state_reset_vm() {
  local vm="${1-}"
  local path
  path="$(hangctl_state__path "${vm}")"
  local migrate_path="${path}.migrate"

  rm -f "${path}" "${migrate_path}" 2>/dev/null || true
  hangctl_log_event "state" "state.reset" "ok" "${vm}" "" "" "reason=vm_not_running"
}

# QMP 응답이 성공하면 이 함수를 호출하여 마지막 성공 시점을 현재로 갱신
hangctl_state_touch_heartbeat() {
  local vm="${1-}"
  local path
  path="$(hangctl_state__path "${vm}")"
  local now
  now="$(date +%s)"
  
  # 상태와 관계없이 마지막 응답 시점을 현재로 업데이트 (시간 초기화 효과)
  hangctl_state__write_file "${path}" "alive" "${now}" || true
}
