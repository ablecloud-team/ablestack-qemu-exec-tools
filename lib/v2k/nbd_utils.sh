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
set -euo pipefail

# [전역 설정] 모든 VM이 공유하는 예약 디렉토리
V2K_NBD_LOCK_ROOT="/var/lock/ablestack-v2k/reservations"

# ---------------------------
# NBD allocator utilities (productized)
# - robust lock (atomic mkdir)
# - in-use detection via /sys/block/nbdX/pid
# - disconnect waits until kernel releases nbd
# ---------------------------
 
v2k_nbd_has_dm_children() {
  # Return 0 if dev has device-mapper children (e.g., LVM LVs) visible to lsblk.
  # This is used to avoid allocating an nbd dev that is "pid-free" but still has dm remnants.
  local dev="$1"
  command -v lsblk >/dev/null 2>&1 || return 1
  # if any child exists under this dev, it's not safe to reuse immediately
  lsblk -rn -o NAME,TYPE "${dev}" 2>/dev/null | awk '$2=="lvm" || $2=="crypt"{found=1} END{exit(found?0:1)}'
}

v2k_nbd_lvm_deactivate_best_effort() {
  # Best-effort: deactivate any LVs/VGs that appear on this nbd device.
  # This prevents cases where LVM auto-activation causes "ghost" rl-root on stale nbd.
  local dev="$1"
  command -v pvs >/dev/null 2>&1 || return 0
  command -v vgchange >/dev/null 2>&1 || return 0

  # Collect VGs that have PVs on this dev or its partitions.
  # Example pvs output "vgname /dev/nbd0p3"
  local vgs vg
  vgs="$(pvs --noheadings -o vg_name,pv_name 2>/dev/null \
    | awk -v d="${dev}" '$2 ~ ("^"d"p") || $2==d {print $1}' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | sort -u \
    || true)"

  for vg in ${vgs}; do
    [[ -n "${vg}" ]] || continue
    vgchange -an "${vg}" >/dev/null 2>&1 || true
  done
}

v2k_nbd_sys_pid() {
  local dev="$1" base pidf
  base="$(basename "${dev}")"
  pidf="/sys/block/${base}/pid"
  if [[ -r "${pidf}" ]]; then
    cat "${pidf}" 2>/dev/null || true
  else
    echo ""
  fi
}

v2k_nbd_is_in_use() {
  local dev="$1" pid
  pid="$(v2k_nbd_sys_pid "${dev}")"
  # kernel exports "0" or empty when free
  if [[ -n "${pid}" && "${pid}" != "0" ]]; then
    return 0
  fi
  # fallback (older stacks / transient): nbd-client query
  if command -v nbd-client >/dev/null 2>&1; then
    if nbd-client -c "${dev}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

v2k_nbd_lock_try() {
  # atomic lockdir per device. stores pid for stale cleanup.
  local lock_dir="$1" dev="$2" base lock
  base="$(basename "${dev}")"
  lock="${lock_dir}/${base}.lock.d"

  if mkdir "${lock}" >/dev/null 2>&1; then
    echo "$$" > "${lock}/pid" 2>/dev/null || true
    date +%s > "${lock}/ts" 2>/dev/null || true
    return 0
  fi

  # stale lock handling: if owner pid is gone AND device is free -> remove lock and retry once
  local owner
  owner="$(cat "${lock}/pid" 2>/dev/null || true)"
  if [[ -n "${owner}" ]] && ! kill -0 "${owner}" >/dev/null 2>&1; then
    if ! v2k_nbd_is_in_use "${dev}"; then
      rm -rf "${lock}" >/dev/null 2>&1 || true
      if mkdir "${lock}" >/dev/null 2>&1; then
        echo "$$" > "${lock}/pid" 2>/dev/null || true
        date +%s > "${lock}/ts" 2>/dev/null || true
        return 0
      fi
    fi
  fi
  return 1
}

v2k_nbd_lock_release() {
  local lock_dir="$1" dev="$2" base lock
  base="$(basename "${dev}")"
  lock="${lock_dir}/${base}.lock.d"
  rm -rf "${lock}" >/dev/null 2>&1 || true
}

# Find a free /dev/nbdX and lock it.
v2k_nbd_alloc() {
  mkdir -p "${V2K_NBD_LOCK_ROOT}"
  modprobe nbd max_part=16 >/dev/null 2>&1 || true

  local i dev lock_dir pid_file owner_pid

  for i in $(seq 0 63); do
    dev="/dev/nbd${i}"
    [[ -b "${dev}" ]] || continue

    lock_dir="${V2K_NBD_LOCK_ROOT}/nbd${i}.lock.d"
    pid_file="${lock_dir}/pid"

    # 1. 원자적(Atomic) 예약 시도: mkdir
    if mkdir "${lock_dir}" 2>/dev/null; then
      # 예약 성공! 내 PID 기록
      echo "$$" > "${pid_file}"
      
      # 2. 커널 상태 이중 체크 (이미 사용 중인지)
      if v2k_nbd_is_in_use "${dev}" || v2k_nbd_has_dm_children "${dev}"; then
        # 사용 중이면 예약 취소하고 다음으로
        rm -rf "${lock_dir}"
        continue
      fi
      
      # 최종 할당 성공
      echo "${dev}"
      return 0
    else
      # 예약 실패 (이미 락이 존재함). 좀비 락인지 확인
      if [[ -f "${pid_file}" ]]; then
        owner_pid="$(cat "${pid_file}" 2>/dev/null || true)"
        # 프로세스가 죽었고($owner_pid 없음) + 커널에서도 사용 안 함 -> 좀비 락
        if [[ -n "${owner_pid}" ]] && ! kill -0 "${owner_pid}" 2>/dev/null; then
           if ! v2k_nbd_is_in_use "${dev}"; then
             # 좀비 락 청소 후 재시도
             rm -rf "${lock_dir}"
             # 이번 루프(i)를 다시 시도하기 위해 i를 하나 줄이거나, 그냥 다음으로 넘어감.
             # 안전하게 다음 디바이스 탐색 (다음 실행 시엔 청소되어 있을 것임)
           fi
        fi
      fi
    fi
  done

  echo "No free /dev/nbdX found" >&2
  return 1
}

v2k_nbd_free() {
  local dev="$1"
  local base lock_dir
  [[ -z "${dev}" ]] && return 0
  
  # 연결 해제 (기존 로직 수행)
  v2k_nbd_disconnect "${dev}"

  # 전역 예약 해제
  base="$(basename "${dev}")"
  lock_dir="${V2K_NBD_LOCK_ROOT}/${base}.lock.d"
  if [[ -d "${lock_dir}" ]]; then
     # 내 락인지 확인하고 지우는 것이 가장 안전하지만, 
     # 보통 free를 호출하는 건 주인이므로 강제 삭제
     rm -rf "${lock_dir}"
  fi
}

v2k_nbd_disconnect() {
  local dev="$1"
  # Best-effort:
  # 1) deactivate any LVM remnants on this dev (prevents auto-activation ghosts)
  # 2) detach (nbd-client, then qemu-nbd)
  # 3) wait for kernel release (/sys/block/nbdX/pid == 0)
  v2k_nbd_lvm_deactivate_best_effort "${dev}" >/dev/null 2>&1 || true

  command -v nbd-client >/dev/null 2>&1 && nbd-client -d "${dev}" >/dev/null 2>&1 || true
  command -v qemu-nbd   >/dev/null 2>&1 && qemu-nbd -d "${dev}"   >/dev/null 2>&1 || true

  # Wait until /sys/block/nbdX/pid becomes 0 (avoid reattach races)
  local i pid
  for i in $(seq 1 50); do
    pid="$(v2k_nbd_sys_pid "${dev}")"
    if [[ -z "${pid}" || "${pid}" == "0" ]]; then
      return 0
    fi
    sleep 0.1
  done
  # last resort: still return success (caller trap will prevent leak chaining)
  return 0
}

v2k_wait_unix_socket() {
  local sock="$1" tries="${2:-20}" delay="${3:-1}"
  local i
  for i in $(seq 1 "${tries}"); do
    [[ -S "${sock}" ]] && return 0
    sleep "${delay}"
  done
  return 1
}

v2k_kill_pidfile_safe() {
  local pidfile="$1"
  local match="${2:-}"   # optional token (e.g. unix socket path) to ensure we only kill our own process

  [[ -f "${pidfile}" ]] || return 0
  local pid
  pid="$(cat "${pidfile}" 2>/dev/null || true)"
  [[ -n "${pid}" ]] || { rm -f "${pidfile}" || true; return 0; }
  [[ "${pid}" =~ ^[0-9]+$ ]] || { rm -f "${pidfile}" || true; return 0; }
  [[ -d "/proc/${pid}" ]] || { rm -f "${pidfile}" || true; return 0; }

  # Safety: ensure the pid is an nbdkit process, and (if match provided) it contains the token
  local cmdline
  cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
  if [[ -z "${cmdline}" ]]; then
    rm -f "${pidfile}" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ "${cmdline}" != *"nbdkit"* ]]; then
    rm -f "${pidfile}" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ -n "${match}" && "${cmdline}" != *"${match}"* ]]; then
    rm -f "${pidfile}" >/dev/null 2>&1 || true
    return 0
  fi

  kill "${pid}" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 50); do
    kill -0 "${pid}" >/dev/null 2>&1 || break
    sleep 0.1
  done
  kill -9 "${pid}" >/dev/null 2>&1 || true
  rm -f "${pidfile}" >/dev/null 2>&1 || true
}

#
# Stop an nbdkit process started by V2K patch/base sync helpers.
# - transfer_patch.sh calls: v2k_nbdkit_stop <pidfile> <sock>
# - This function was referenced but missing, which caused cleanup to no-op.
#
v2k_nbdkit_stop() {
  local pidfile="${1-}"
  local sock="${2-}"

  # If pidfile is missing, best-effort cleanup only
  if [[ -n "${pidfile}" && -f "${pidfile}" ]]; then
    local pid
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ && -d "/proc/${pid}" ]]; then
      # Safety check: ensure it's really nbdkit and (if provided) matches our sock path.
      local cmdline
      cmdline="$(tr '\0' ' ' </proc/${pid}/cmdline 2>/dev/null || true)"

      if [[ "${cmdline}" == *"nbdkit"* ]]; then
        if [[ -n "${sock}" ]]; then
          # Only kill if cmdline contains the sock path we expect.
          if [[ "${cmdline}" == *"${sock}"* ]]; then
            kill -TERM "${pid}" 2>/dev/null || true
          fi
        else
          kill -TERM "${pid}" 2>/dev/null || true
        fi

        # Wait a short time for graceful exit
        local i
        for i in 1 2 3 4 5; do
          [[ -d "/proc/${pid}" ]] || break
          sleep 0.2
        done

        # Force kill if still alive
        if [[ -d "/proc/${pid}" ]]; then
          if [[ -n "${sock}" ]]; then
            [[ "${cmdline}" == *"${sock}"* ]] && kill -KILL "${pid}" 2>/dev/null || true
          else
            kill -KILL "${pid}" 2>/dev/null || true
          fi
        fi
      fi
    fi

    rm -f "${pidfile}" 2>/dev/null || true
  fi

  # Remove stale unix socket file if present
  if [[ -n "${sock}" && -S "${sock}" ]]; then
    rm -f "${sock}" 2>/dev/null || true
  fi
}

v2k_nbdkit_kill_by_token() {
  # Kill ONLY our nbdkit process(es) identified by unix socket token.
  # Why: nbdkit may reexec and PID in pidfile can be stale.
  #
  # Args:
  #   $1: pidfile (optional)
  #   $2: sock token (required for safe kill)
  local pidfile="${1:-}"
  local sock="${2:-}"

  [[ -n "${sock}" ]] || return 0

  # 1) Try pidfile first (fast path)
  if [[ -n "${pidfile}" && -f "${pidfile}" ]]; then
    v2k_kill_pidfile_safe "${pidfile}" "${sock}" >/dev/null 2>&1 || true
  fi

  # 2) Fallback: find by cmdline token (ONLY our socket path)
  # NOTE: do not kill if sock is empty -> avoid collateral.
  local pids=""
  if command -v pgrep >/dev/null 2>&1; then
    # match both "nbdkit" and "-U <sock>"
    pids="$(pgrep -f "nbdkit .* -U ${sock}" 2>/dev/null || true)"
  else
    # fallback without pgrep: scan /proc
    local pid cmdline
    for pid in /proc/[0-9]*; do
      pid="${pid##*/}"
      cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
      [[ -n "${cmdline}" ]] || continue
      [[ "${cmdline}" == *"nbdkit"* && "${cmdline}" == *" -U ${sock}"* ]] || continue
      pids+="${pid}"$'\n'
    done
  fi

  local p
  for p in ${pids}; do
    [[ "${p}" =~ ^[0-9]+$ ]] || continue
    kill "${p}" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 50); do
      kill -0 "${p}" >/dev/null 2>&1 || break
      sleep 0.1
    done
    kill -9 "${p}" >/dev/null 2>&1 || true
  done
}

v2k_force_cleanup_run() {
  # Force cleanup ONLY resources belonging to current run-id namespace.
  # It does NOT touch other runs because it only matches /tmp paths with this run-id.
  local run_id="${1:-${V2K_RUN_ID:-}}"
  [[ -n "${run_id}" ]] || return 0

  local pidfile sock
  # pidfile naming in transfer_*: /tmp/v2k_nbdkit_${V2K_RUN_ID}_${idx}.pid
  for pidfile in "/tmp/v2k_nbdkit_${run_id}_"*.pid; do
    [[ -e "${pidfile}" ]] || continue
    # derive sock path: /tmp/v2k_src_${run_id}_${idx}.sock
    sock="${pidfile/v2k_nbdkit_/v2k_src_}"
    sock="${sock%.pid}.sock"
    v2k_nbdkit_kill_by_token "${pidfile}" "${sock}" >/dev/null 2>&1 || true
    rm -f "${pidfile}" >/dev/null 2>&1 || true
    rm -f "${sock}" >/dev/null 2>&1 || true
  done
}

v2k_kill_pidfile() {
  local pidfile="$1"
  v2k_kill_pidfile_safe "${pidfile}" ""
}

## NOTE:
## v2k_force_cleanup_run() and nbdkit stop helpers are already implemented above.
## Do not redefine them here (bash will override earlier definitions).