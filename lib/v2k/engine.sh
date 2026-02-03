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
#
# (patched) linux_bootstrap cleanup + step extra json safety
# ---------------------------------------------------------------------

set -euo pipefail

V2K_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
V2K_NBD_LOCK_ROOT="/var/lock/ablestack-v2k/reservations"

# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/logging.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/manifest.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/vmware_govc.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/transfer_base.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/transfer_patch.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/target_libvirt.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/verify.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/nbd_utils.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/v2k_target_device.sh"

# [Global Variable for LVM Lock FD]
# We use a global variable to hold the file descriptor for the LVM lock
# so that it persists across function calls until cleanup.
V2K_LVM_LOCK_FD=""

v2k_nbd_has_children_types() {
  # Return 0 if dev has suspicious children types (lvm/crypt/raid), meaning "not clean".
  # We intentionally avoid allocating/using such nbd for bootstrap to prevent LVM auto-activation ghosts.
  local dev="$1"
  command -v lsblk >/dev/null 2>&1 || return 1
  # Example output rows: nbd0 disk, nbd0p3 part, rl-root lvm
  # If any child type is lvm/crypt/md/raid, treat as dirty.
  lsblk -rn -o NAME,TYPE "${dev}" 2>/dev/null \
    | awk '
      $2=="lvm" || $2=="crypt" || $2=="raid" || $2=="md" {found=1}
      END{exit(found?0:1)}
    '
}

v2k_nbd_has_any_mountpoints() {
  local dev="$1"
  command -v lsblk >/dev/null 2>&1 || return 1
  lsblk -rn -o MOUNTPOINT "${dev}" 2>/dev/null | grep -q .
}

v2k_nbd_is_connected() {
  # Return 0(true) if /dev/nbdX is currently connected (in-use).
  # Kernel exposes pid when the device is connected.
  local dev="$1"
  local bn sys_pid
  bn="$(basename "${dev}")"
  sys_pid="/sys/block/${bn}/pid"
  [[ -r "${sys_pid}" ]] || return 1
  # pid file contains a number when connected; empty/0 when disconnected (depends on kernel)
  local pid
  pid="$(cat "${sys_pid}" 2>/dev/null || true)"
  [[ -n "${pid}" && "${pid}" != "0" ]]
}

v2k_linux_bootstrap_pick_nbd() {
  mkdir -p "${V2K_NBD_LOCK_ROOT}"
  local range="${V2K_LINUX_BOOTSTRAP_NBD_RANGE:-8-15}"
  local start end
  start="${range%-*}"; end="${range#*-}"
  [[ "${start}" =~ ^[0-9]+$ && "${end}" =~ ^[0-9]+$ ]] || { start=8; end=15; }

  local i dev lock_dir pid_file owner_pid

  for ((i=start; i<=end; i++)); do
    dev="/dev/nbd${i}"
    [[ -b "${dev}" ]] || continue
    
    lock_dir="${V2K_NBD_LOCK_ROOT}/nbd${i}.lock.d"
    pid_file="${lock_dir}/pid"

    # 1. 원자적 예약 시도 (nbd_utils.sh와 동일 메커니즘)
    if mkdir "${lock_dir}" 2>/dev/null; then
      echo "$$" > "${pid_file}"
      
      # 2. 커널 상태 체크 (기존 함수들 활용)
      if v2k_nbd_is_connected "${dev}" || \
         v2k_nbd_has_any_mountpoints "${dev}" || \
         v2k_nbd_has_children_types "${dev}"; then
         
         rm -rf "${lock_dir}"
         continue
      fi
      
      # 추가: pid 파일 체크
      local kpid
      kpid="$(v2k_nbd_sys_pid "${dev}" 2>/dev/null || true)"
      if [[ -n "${kpid}" && "${kpid}" != "0" ]]; then
         rm -rf "${lock_dir}"
         continue
      fi

      # 성공! [장치명] [락 디렉토리] 반환 (cleanup을 위해)
      # 락 디렉토리 경로를 호출자가 알면 나중에 지울 수 있음
      echo "${dev}"
      return 0
    else
      # 예약 실패 시 좀비 락 체크 (선택 사항이나 권장)
      if [[ -f "${pid_file}" ]]; then
        owner_pid="$(cat "${pid_file}" 2>/dev/null || true)"
        if [[ -n "${owner_pid}" ]] && ! kill -0 "${owner_pid}" 2>/dev/null; then
           # 주인이 죽었고 장치가 free하다면 락 제거
           if ! v2k_nbd_is_connected "${dev}"; then
             rm -rf "${lock_dir}"
           fi
        fi
      fi
    fi
  done
  return 1
}
 
v2k_mountpoint_is_mounted() {
  # Return 0(true) if path is a mountpoint (robust).
  local p="${1:-}"
  [[ -n "${p}" ]] || return 1
  command -v findmnt >/dev/null 2>&1 || { mountpoint -q "${p}" 2>/dev/null; return $?; }
  findmnt -rn "${p}" >/dev/null 2>&1
}

v2k_linux_bootstrap_umount_robust() {
  # Robust unmount with retries and fallbacks.
  #
  # Usage:
  #   v2k_linux_bootstrap_umount_robust <path> [--recursive]
  #
  # Policy:
  # - try umount
  # - if fails and --recursive => umount -R
  # - retry a few times (udev settle + sleep)
  # - last resort: umount -l (lazy)
  #
  # Never hard-fail caller; return rc for observability.
  local p="${1:-}"
  local recursive=0
  shift || true
  if [[ "${1:-}" == "--recursive" ]]; then
    recursive=1
  fi
  [[ -n "${p}" ]] || return 0

  # fast-path: not mounted
  if ! v2k_mountpoint_is_mounted "${p}"; then
    return 0
  fi

  local out rc
  local i
  for i in 1 2 3; do
    if [[ "${recursive}" -eq 1 ]]; then
      v2k_linux_bootstrap_run_event "cmd_umount_r_try" out rc -- umount -R "${p}"
    else
      v2k_linux_bootstrap_run_event "cmd_umount_try" out rc -- umount "${p}"
    fi
    if [[ "${rc}" -eq 0 ]]; then
      v2k_event INFO "linux_bootstrap" "" "umount_ok" \
        "$(v2k_linux_bootstrap_json --arg path "${p}" --argjson recursive "${recursive}" --argjson attempt "${i}" '{path:$path,recursive:$recursive,attempt:$attempt}')"
      return 0
    fi
    udevadm settle >/dev/null 2>&1 || true
    sleep 0.2
    # if already unmounted between retries
    if ! v2k_mountpoint_is_mounted "${p}"; then
      return 0
    fi
  done

  # last resort: lazy umount (best-effort)
  if [[ "${recursive}" -eq 1 ]]; then
    v2k_linux_bootstrap_run_event "cmd_umount_r_lazy" out rc -- umount -R -l "${p}"
  else
    v2k_linux_bootstrap_run_event "cmd_umount_lazy" out rc -- umount -l "${p}"
  fi
  v2k_event WARN "linux_bootstrap" "" "umount_lazy_attempted" \
    "$(v2k_linux_bootstrap_json --arg path "${p}" --argjson recursive "${recursive}" --argjson rc "${rc}" '{path:$path,recursive:$recursive,rc:$rc}')"
  return "${rc}"
}

v2k_linux_bootstrap_mount_robust() {
  # Robust mount wrapper with observability and idempotency.
  #
  # Usage:
  #   v2k_linux_bootstrap_mount_robust <src> <dst> <opts>
  # Example:
  #   v2k_linux_bootstrap_mount_robust "${dev}" "${mnt}" "ro"
  #
  # Returns mount rc (caller may decide).
  local src="${1:-}" dst="${2:-}" opts="${3:-}"
  [[ -n "${src}" && -n "${dst}" ]] || return 2
  mkdir -p "${dst}" >/dev/null 2>&1 || true

  # already mounted -> verify SOURCE matches expected src; otherwise remount
  if v2k_mountpoint_is_mounted "${dst}"; then
    local cur_src
    cur_src="$(findmnt -rn -o SOURCE --target "${dst}" 2>/dev/null || true)"
    if [[ -n "${cur_src}" && "${cur_src}" == "${src}" ]]; then
      v2k_event INFO "linux_bootstrap" "" "mount_skip_already_mounted" \
        "$(v2k_linux_bootstrap_json --arg src "${src}" --arg dst "${dst}" --arg opts "${opts}" --arg cur_src "${cur_src}" '{src:$src,dst:$dst,opts:$opts,cur_src:$cur_src}')"
      return 0
    fi
    v2k_event WARN "linux_bootstrap" "" "mount_dst_busy_remount" \
      "$(v2k_linux_bootstrap_json --arg src "${src}" --arg dst "${dst}" --arg cur_src "${cur_src}" '{src:$src,dst:$dst,cur_src:$cur_src}')"
    v2k_linux_bootstrap_umount_robust "${dst}" --recursive >/dev/null 2>&1 || true
  fi

  local out rc
  if [[ -n "${opts}" ]]; then
    v2k_linux_bootstrap_run_event "cmd_mount" out rc -- mount -o "${opts}" "${src}" "${dst}"
  else
    v2k_linux_bootstrap_run_event "cmd_mount" out rc -- mount "${src}" "${dst}"
  fi
  return "${rc}"
}

v2k_is_linux_guest() {
  # Return 0(true) if the guest looks like Linux.
  #
  # NOTE:
  # VMware Tools 미동작/제한 환경에서는 guestFamily가 빈 값으로 내려오는 케이스가 있음
  # (예: rockylinux_64Guest 인데 guestFamily == "").
  #
  # Policy:
  # 1) guestFamily가 linuxGuest면 Linux
  # 2) 아니면 guestId/guestFullName/osFullName 휴리스틱으로 Linux 판별
  local gf gid gfull osfull probe
  gf="$(jq -r '.source.vm.guestFamily // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"
  if [[ "${gf}" == "linuxGuest" ]]; then
    return 0
  fi

  gid="$(jq -r '.source.vm.guestId // .source.vm.guest_id // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"
  gfull="$(jq -r '.source.vm.guestFullName // .source.vm.guest_full_name // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"
  osfull="$(jq -r '.source.vm.osFullName // .source.vm.os_full_name // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"

  probe="$(printf '%s %s %s' "${gid}" "${gfull}" "${osfull}" | tr '[:upper:]' '[:lower:]')"
  [[ "${probe}" =~ (linux|rocky|rockylinux|rhel|redhat|centos|alma|ubuntu|debian|suse|opensuse|fedora|oraclelinux) ]]
}

v2k_is_safe_mode() {
  [[ "${V2K_SAFE_MODE:-0}" -eq 1 ]]
}

v2k_should_skip_incr_phase() {
  # Policy:
  # - safe-mode => skip incr regardless of OS
  # - (Modified) Linux guest also performs incr sync (same as Windows)
  if v2k_is_safe_mode; then
    return 0
  fi
  if v2k_is_linux_guest; then
    return 1
  fi
  return 1
}

v2k_require_linux_bootstrap_deps() {
  command -v qemu-nbd >/dev/null 2>&1 || return 1
  command -v lsblk >/dev/null 2>&1 || return 1
  command -v mount >/dev/null 2>&1 || return 1
  command -v umount >/dev/null 2>&1 || return 1
  command -v chroot >/dev/null 2>&1 || return 1
  return 0
}

v2k_has_lvm_tools() {
  command -v lvm >/dev/null 2>&1 || return 1
  command -v vgscan >/dev/null 2>&1 || return 1
  command -v vgchange >/dev/null 2>&1 || return 1
  command -v lvs >/dev/null 2>&1 || return 1
  return 0
}

v2k_linux_bootstrap_try_mount_partitions() {
  # Try to find root by mounting partitions directly and checking /etc/os-release
  local nbd_dev="$1" mnt="$2"
  local part root_part=""
  for part in "${nbd_dev}"p[0-9]*; do
    [[ -b "${part}" ]] || continue
    # guard: clear any leftover mount on mnt (prevents false rc=0 from mount_robust)
    v2k_linux_bootstrap_umount_robust "${mnt}" --recursive >/dev/null 2>&1 || true
    # Skip LVM PV partitions early (they won't contain /etc/os-release)
    if lsblk -rn -o FSTYPE "${part}" 2>/dev/null | grep -qx "LVM2_member"; then
      continue
    fi
    # Observability: log each mount attempt and its result.
    local mout mrc
    v2k_linux_bootstrap_wait_blockdev "${part}" 5 || true
    v2k_linux_bootstrap_run_event "mount_try_partition" mout mrc -- \
      v2k_linux_bootstrap_mount_robust "${part}" "${mnt}" "ro"

    if [[ "${mrc}" -ne 0 ]]; then
      v2k_event INFO "linux_bootstrap" "" "mount_try_partition_failed" \
        "$(v2k_linux_bootstrap_json \
          --arg part "${part}" \
          --argjson rc "${mrc}" \
          --arg note "mount failed" \
          '{part:$part,rc:$rc,note:$note}')"
      continue
    fi

    local has_os=0
    [[ -f "${mnt}/etc/os-release" ]] && has_os=1
    v2k_event INFO "linux_bootstrap" "" "mount_try_partition_probe" \
      "$(v2k_linux_bootstrap_json \
        --arg part "${part}" \
        --argjson has_os_release "${has_os}" \
        '{part:$part,has_os_release:$has_os_release}')"

    if [[ "${has_os}" -eq 1 ]]; then
      root_part="${part}"
      v2k_linux_bootstrap_umount_robust "${mnt}" >/dev/null 2>&1 || true
      echo "${root_part}"
      return 0
    fi
    v2k_linux_bootstrap_umount_robust "${mnt}" >/dev/null 2>&1 || true
  done
  return 1
}

v2k_linux_bootstrap_dbg_cmd() {
  # Run a command and return compact single-line output for event logging.
  # Never fail the caller.
  local out
  out="$("$@" 2>&1 | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | head -c 2000 || true)"
  printf '%s' "${out}"
}

v2k_linux_bootstrap_run_capture() {
  # Run command safely under set -e, capturing stdout/stderr + rc.
  # IMPORTANT: Do NOT call this via command substitution $(...) if you need rc/out vars.
  #
  # Usage:
  #   local out rc
  #   v2k_linux_bootstrap_run_capture out rc -- <cmd> <args...>
  #   echo "$rc" ; echo "$out"
  local __out_var="$1"; shift
  local __rc_var="$1"; shift
  [[ "$1" == "--" ]] && shift

  # NOTE: set -u safety: always initialize locals.
  local _out="" _rc=0
  local _errexit=0
  shopt -qo errexit && _errexit=1
  set +e
  if [[ $# -gt 0 ]]; then
    _out="$("$@" 2>&1)"
    _rc=$?
  else
    _out="(no command)"
    _rc=127
  fi
  (( _errexit )) && set -e || set +e

  # single-line compact for event log
  _out="$(printf '%s' "${_out}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"

  printf -v "${__out_var}" '%s' "${_out}"
  printf -v "${__rc_var}"  '%s' "${_rc}"
}

v2k_linux_bootstrap_cmd_str() {
  # Build a readable shell-ish command string for logging.
  # NOTE: This is for observability only (not for re-execution).
  local s="" a
  for a in "$@"; do
    if [[ -z "${s}" ]]; then
      s="${a}"
      continue
    fi
    # naive quoting: quote if contains whitespace or quotes
    if [[ "${a}" =~ [[:space:]\"] ]]; then
      a="${a//\\/\\\\}"
      a="${a//\"/\\\"}"
      s+=" \"${a}\""
    else
      s+=" ${a}"
    fi
  done
  printf '%s' "${s}"
}

v2k_linux_bootstrap_run_event() {
  # Run a command with rc/out capture and emit an event with the exact cmdline.
  # Usage:
  #   local out rc
  #   v2k_linux_bootstrap_run_event "event_name" out rc -- <cmd> <args...>
  local ev="$1"; shift
  local __out_var="$1"; shift
  local __rc_var="$1"; shift
  [[ "$1" == "--" ]] && shift
  local cmdline
  cmdline="$(v2k_linux_bootstrap_cmd_str "$@")"

  # NOTE: set -u safety: always initialize locals.
  local _out="" _rc=0
  v2k_linux_bootstrap_run_capture _out _rc -- "$@"
  printf -v "${__out_var}" '%s' "${_out}"
  printf -v "${__rc_var}"  '%s' "${_rc}"

  # Truncate output for event payload safety
  local out_short=""
  out_short="$(printf '%s' "${_out}" | head -c 1500)"

  v2k_event INFO "linux_bootstrap" "" "${ev}" \
    "$(v2k_linux_bootstrap_json \
      --arg cmd "${cmdline}" \
      --argjson rc "${_rc}" \
      --arg out "${out_short}" \
      '{cmd:$cmd,rc:$rc,out:$out}')"
}

v2k_linux_bootstrap_wait_blockdev() {
  # Wait briefly for a block device node to become ready (race guard).
  # Returns 0 if device is a block node within timeout, non-zero otherwise.
  local dev="$1"
  local timeout_sec="${2:-5}"
  local start_ts now_ts
  start_ts="$(date +%s 2>/dev/null || echo 0)"
  while true; do
    [[ -b "${dev}" ]] && return 0
    udevadm settle >/dev/null 2>&1 || true
    now_ts="$(date +%s 2>/dev/null || echo 0)"
    if [[ $((now_ts - start_ts)) -ge "${timeout_sec}" ]]; then
      return 1
    fi
    sleep 0.2
  done
}

v2k_linux_bootstrap_json() {
  # Build valid JSON safely.
  # Example: v2k_linux_bootstrap_json --arg k v --argjson n 1 '{k:$k,n:$n}'
  jq -nc "$@"
}

v2k_linux_bootstrap_lvm_pv_candidates() {
  # Echo PV partition paths on this nbd device (e.g. /dev/nbd8p3)
  local nbd_dev="$1"
  local bn
  bn="$(basename "${nbd_dev}")"
  # Prefer partitions only; raw disk PV is uncommon but keep as fallback.
  # Only partitions that are LVM PVs (FSTYPE=LVM2_member)
  lsblk -rn -o NAME,FSTYPE "/dev/${bn}" 2>/dev/null \
    | awk '$2=="LVM2_member"{print "/dev/"$1}'
}

v2k_linux_bootstrap_lvm_try_activate_by_pv() {
  # Deterministic activation: activate only VGs that live on the given PV.
  # This is much more stable than scanning everything when duplicate PVID warnings exist.
  local nbd_dev="$1" pv="$2"
  v2k_has_lvm_tools || return 1
  [[ -b "${pv}" ]] || return 1

  local bn cfg
  bn="$(basename "${nbd_dev}")"
  cfg="devices { filter=[ \"a|^/dev/${bn}p[0-9]+$|\", \"a|^/dev/${bn}$|\", \"r|.*|\" ] }"

  udevadm settle >/dev/null 2>&1 || true

  # Activate only this PV's VG(s)
  local act_out act_rc
  # NOTE: avoid "|| true" because it destroys rc observability.
  # Also keep options after command for compatibility with some lvm wrappers.
  v2k_linux_bootstrap_run_event "cmd_pvscan_activate" act_out act_rc -- \
    lvm pvscan --config "${cfg}" --cache --activate ay "${pv}"

  v2k_event INFO "linux_bootstrap" "" "lvm_pvscan_activate" \
    "$(v2k_linux_bootstrap_json \
      --arg pv "${pv}" \
      --argjson rc "${act_rc}" \
      --arg out "$(printf '%s' "${act_out}" | head -c 1500)" \
      '{pv:$pv,rc:$rc,out:$out}')"

  udevadm settle >/dev/null 2>&1 || true

  # pvscan rc==0이면 "활성화 후보 성공"으로 간주한다.
  # 실제 LV active 판정은 vgchange -ay 이후 단계에서 수행.
  [[ "${act_rc}" -eq 0 ]] && return 0
  return 2
}

v2k_linux_bootstrap_lvm_try_activate_vg_name() {
  # Fallback: if VG name can be discovered, activate that VG explicitly.
  local nbd_dev="$1" vg="$2"
  v2k_has_lvm_tools || return 1
  [[ -n "${vg}" ]] || return 1

  local bn cfg
  bn="$(basename "${nbd_dev}")"
  cfg="devices { filter=[ \"a|^/dev/${bn}p[0-9]+$|\", \"a|^/dev/${bn}$|\", \"r|.*|\" ] }"

  local out rc
  v2k_linux_bootstrap_run_event "cmd_vgchange_activate" out rc -- \
    lvm vgchange --config "${cfg}" -ay "${vg}"
  v2k_event INFO "linux_bootstrap" "" "lvm_vgchange_activate" \
    "$(v2k_linux_bootstrap_json \
      --arg vg "${vg}" \
      --argjson rc "${rc}" \
      --arg out "$(printf '%s' "${out}" | head -c 1500)" \
      '{vg:$vg,rc:$rc,out:$out}')"
  udevadm settle >/dev/null 2>&1 || true

  if lvm lvs --config "${cfg}" --noheadings -o lv_attr "${vg}" 2>/dev/null \
      | awk '{$1=$1}; $1 ~ /a/ {found=1} END{exit(found?0:1)}'; then
    return 0
  fi
  return 2
}

v2k_linux_bootstrap_lvm_find_vgs_on_nbd() {
  # Echo VG names discovered on nbd partitions (deduped).
  # We intentionally scope all LVM operations to the given nbd device via --config filter.
  local nbd_dev="$1"
  v2k_has_lvm_tools || return 1

  local bn cfg
  bn="$(basename "${nbd_dev}")"
  cfg="devices { filter=[ \"a|^/dev/${bn}p[0-9]+$|\", \"a|^/dev/${bn}$|\", \"r|.*|\" ] }"

  # PV -> VG mapping from this device only
  # pvs output example: /dev/nbd8p3 rl
  lvm pvs --config "${cfg}" --noheadings -o vg_name 2>/dev/null \
    | awk '{$1=$1}; $1!="" {print $1}' \
    | sort -u
}

v2k_linux_bootstrap_lvm_activate_vg() {
  local nbd_dev="$1" vg="$2"
  v2k_has_lvm_tools || return 1
  [[ -n "${vg}" ]] || return 1

  local bn cfg
  bn="$(basename "${nbd_dev}")"
  cfg="devices { filter=[ \"a|^/dev/${bn}p[0-9]+$|\", \"a|^/dev/${bn}$|\", \"r|.*|\" ] }"

  # [CRITICAL ADDITION] VG Name Collision Locking
  # If multiple VMs have the same VG name (e.g. "rl"), we MUST serialize activation.
  # Otherwise, kernel device mapper will reject duplicate /dev/mapper/rl-root names.
  local lock_file="/var/lock/ablestack-v2k/lvm_name_${vg}.lock"
  mkdir -p "$(dirname "${lock_file}")"
  
  # Open lock file on a new file descriptor
  local lock_fd
  eval "exec {lock_fd}>${lock_file}"
  
  v2k_event INFO "linux_bootstrap" "" "lvm_lock_acquire_wait" "{\"vg\":\"${vg}\"}"
  
  # Wait for exclusive lock (timeout 300s to prevent indefinite hang)
  if ! flock -x -w 300 "${lock_fd}"; then
      v2k_event ERROR "linux_bootstrap" "" "lvm_lock_timeout" "{\"vg\":\"${vg}\"}"
      eval "exec ${lock_fd}>&-"
      return 5
  fi
  
  # Lock acquired! Store FD globally so cleanup() can release it later.
  # We DO NOT close it here; holding it keeps the VG exclusively ours.
  V2K_LVM_LOCK_FD="${lock_fd}"
  v2k_event INFO "linux_bootstrap" "" "lvm_lock_acquired" "{\"vg\":\"${vg}\"}"

  # [CRITICAL ADDITION] VG Name Collision Locking
  # If multiple VMs have the same VG name (e.g. "rl"), we MUST serialize activation.
  # Otherwise, kernel device mapper will reject duplicate /dev/mapper/rl-root names.
  local lock_file="/var/lock/ablestack-v2k/lvm_name_${vg}.lock"
  mkdir -p "$(dirname "${lock_file}")"
  local lock_fd
  eval "exec {lock_fd}>${lock_file}"
  
  v2k_event INFO "linux_bootstrap" "" "lvm_lock_acquire_wait" "{\"vg\":\"${vg}\"}"
  if ! flock -x -w 300 "${lock_fd}"; then
      v2k_event ERROR "linux_bootstrap" "" "lvm_lock_timeout" "{\"vg\":\"${vg}\"}"
      eval "exec ${lock_fd}>&-"
      return 5
  fi
  # Lock acquired! Store FD globally so cleanup() can release it later.
  V2K_LVM_LOCK_FD="${lock_fd}"
  v2k_event INFO "linux_bootstrap" "" "lvm_lock_acquired" "{\"vg\":\"${vg}\"}"

  udevadm settle >/dev/null 2>&1 || true

  # Activate
  if ! lvm vgchange --config "${cfg}" -ay "${vg}" >/dev/null 2>&1; then
    # If activation fails, we should release lock immediately to be polite,
    # though cleanup() will catch it too.
    return 2
  fi

  udevadm settle >/dev/null 2>&1 || true
  if lvm lvs --config "${cfg}" --noheadings -o lv_attr "${vg}" 2>/dev/null \
      | awk '{$1=$1}; $1 ~ /a/ {found=1} END{exit(found?0:1)}'; then
    return 0
  fi
  return 3
}

v2k_linux_bootstrap_try_mount_lvm() {
  local nbd_dev="$1" mnt="$2"
  v2k_has_lvm_tools || return 1

  local bn cfg
  bn="$(basename "${nbd_dev}")"
  # [Isolation] global_filter ensures no PVID collisions during this serialized session
  cfg="devices { global_filter=[ \"a|^/dev/${bn}|\", \"r|.*|\" ] filter=[ \"a|^/dev/${bn}|\", \"r|.*|\" ] }"

  v2k_event INFO "linux_bootstrap" "" "lvm_debug_pre" \
    "$(v2k_linux_bootstrap_json \
      --arg nbd "${nbd_dev}" \
      --arg note "pre-activation snapshot" \
      --arg lsblk "$(v2k_linux_bootstrap_dbg_cmd lsblk -rn -o NAME,TYPE,SIZE,FSTYPE,UUID,MOUNTPOINT "${nbd_dev}")" \
      --arg blkid "$(v2k_linux_bootstrap_dbg_cmd blkid "${nbd_dev}")" \
      '{nbd:$nbd,note:$note,lsblk:$lsblk,blkid:$blkid}')"

  udevadm settle >/dev/null 2>&1 || true
  sleep 1

  # [Step 1] Force Cache Update
  local scan_out scan_rc
  v2k_linux_bootstrap_run_event "cmd_pvscan_force" scan_out scan_rc -- \
     lvm pvscan --config "${cfg}" --cache

  # [Step 2] Discover VGs
  local vgs_out vgs_rc
  v2k_linux_bootstrap_run_event "cmd_vgs_discover" vgs_out vgs_rc -- \
     lvm vgs --config "${cfg}" --noheadings -o vg_name
  
  local vgs
  vgs="$(echo "${vgs_out}" | awk '{$1=$1}; $1!=""{print $1}' | sort -u)"

  local activated=0
  if [[ -n "${vgs}" ]]; then
      v2k_event INFO "linux_bootstrap" "" "lvm_vgs_found" "{\"vgs\":\"${vgs}\"}"
      
      # [Step 3] Activate (Safe due to global serialization)
      for vg in ${vgs}; do
          [[ -n "${vg}" ]] || continue
          
          if lvm vgchange --config "${cfg}" -ay "${vg}"; then
              activated=1
          fi
      done
  else
      v2k_event WARN "linux_bootstrap" "" "lvm_no_vgs_found" \
        "{\"note\":\"vgscan found nothing on ${nbd_dev}\", \"scan_rc\":${scan_rc}}"
  fi

  v2k_event INFO "linux_bootstrap" "" "lvm_debug_post" \
    "$(v2k_linux_bootstrap_json \
      --argjson activated "${activated}" \
      --arg pvs "$(v2k_linux_bootstrap_dbg_cmd lvm pvs --config "${cfg}" --noheadings -o pv_name,pv_uuid,vg_name)" \
      --arg vgs "$(v2k_linux_bootstrap_dbg_cmd lvm vgs --config "${cfg}" --noheadings -o vg_name,vg_uuid,vg_attr)" \
      --arg lvs "$(v2k_linux_bootstrap_dbg_cmd lvm lvs --config "${cfg}" --noheadings -o lv_name,vg_name,lv_attr,lv_path)" \
      '{activated:$activated,pvs:$pvs,vgs:$vgs,lvs:$lvs}')"

  # [Step 4] Mount Logic
  local lvlist_raw
  lvlist_raw="$(lvm lvs --config "${cfg}" --noheadings -o vg_name,lv_name 2>/dev/null || true)"

  while read -r vg lvname; do
    vg="$(printf '%s' "${vg}" | awk '{$1=$1};1')"
    lvname="$(printf '%s' "${lvname}" | awk '{$1=$1};1')"
    [[ -n "${vg}" && -n "${lvname}" ]] || continue

    local lv="/dev/${vg}/${lvname}"
    
    if ! v2k_linux_bootstrap_wait_blockdev "${lv}" 10; then
      continue
    fi
    udevadm settle >/dev/null 2>&1 || true

    v2k_linux_bootstrap_umount_robust "${mnt}" --recursive >/dev/null 2>&1 || true

    local mout mrc
    v2k_linux_bootstrap_run_event "mount_try_lv" mout mrc -- \
      v2k_linux_bootstrap_mount_robust "${lv}" "${mnt}" "ro"

    if [[ "${mrc}" -ne 0 ]]; then
      continue
    fi

    local has_os=0
    [[ -f "${mnt}/etc/os-release" ]] && has_os=1
    
    if [[ "${has_os}" -eq 1 ]]; then
      v2k_linux_bootstrap_umount_robust "${mnt}" >/dev/null 2>&1 || true
      echo "${lv}"
      return 0
    fi
    v2k_linux_bootstrap_umount_robust "${mnt}" >/dev/null 2>&1 || true
  done < <(printf '%s\n' "${lvlist_raw}" | awk '{$1=$1}; NF>=2 {print $1, $2}')

  return 1
}

v2k_linux_bootstrap_lvm_deactivate() {
  # Deactivate any VGs activated from this nbd device only.
  local nbd_dev="$1"
  v2k_has_lvm_tools || return 0
  local bn cfg
  bn="$(basename "${nbd_dev}")"
  cfg="devices { filter=[ \"a|^/dev/${bn}p[0-9]+$|\", \"a|^/dev/${bn}$|\", \"r|.*|\" ] }"
  lvm vgchange --config "${cfg}" -an >/dev/null 2>&1 || true
}

v2k_linux_bootstrap_enabled_default() {
  # Default policy:
  # - linuxGuest => enabled (unless explicitly disabled)
  # - others     => disabled
  if v2k_is_linux_guest; then
    return 0
  fi
  return 1
}

v2k_linux_bootstrap_initramfs() {
  local manifest="$1"

  # Best-effort toggle (default: fail cutover on bootstrap failure)
  : "${V2K_LINUX_BOOTSTRAP_BEST_EFFORT:=0}"

  if ! v2k_require_linux_bootstrap_deps; then
    v2k_event WARN "linux_bootstrap" "" "deps_missing" \
      "{\"note\":\"qemu-nbd/lsblk/mount/chroot required\",\"best_effort\":${V2K_LINUX_BOOTSTRAP_BEST_EFFORT}}"
    [[ "${V2K_LINUX_BOOTSTRAP_BEST_EFFORT}" == "1" ]] && return 0
    return 75
  fi

  local st fmt
  st="$(jq -r '.target.storage.type // "file"' "${manifest}" 2>/dev/null || echo "file")"
  fmt="$(jq -r '.target.format // "qcow2"' "${manifest}" 2>/dev/null || echo "qcow2")"

  # For file qcow2/raw: mount via qemu-nbd
  # For block/rbd: current implementation is conservative (follow-up patch can add direct mount)
  if [[ "${st}" != "file" ]]; then
    v2k_event WARN "linux_bootstrap" "" "unsupported_storage_type" \
      "{\"storage_type\":\"${st}\",\"note\":\"current bootstrap supports file targets only\"}"
    [[ "${V2K_LINUX_BOOTSTRAP_BEST_EFFORT}" == "1" ]] && return 0
    return 76
  fi

  # We assume disk0 contains root FS in most Linux VMs.
  local root_img
  root_img="$(jq -r '.disks[0].transfer.target_path // empty' "${manifest}" 2>/dev/null || true)"
  if [[ -z "${root_img}" || "${root_img}" == "null" || ! -f "${root_img}" ]]; then
    v2k_event ERROR "linux_bootstrap" "" "root_image_missing" \
      "{\"path\":\"${root_img}\"}"
    [[ "${V2K_LINUX_BOOTSTRAP_BEST_EFFORT}" == "1" ]] && return 0
    return 77
  fi

  v2k_event INFO "linux_bootstrap" "" "phase_start" \
    "{\"disk0\":\"${root_img}\",\"format\":\"${fmt}\",\"storage\":\"${st}\"}"

  v2k_linux_bootstrap_one "${root_img}"
  local rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    v2k_event INFO "linux_bootstrap" "" "phase_done" "{}"
    return 0
  fi

  v2k_event ERROR "linux_bootstrap" "" "phase_failed" "{\"code\":${rc}}"
  [[ "${V2K_LINUX_BOOTSTRAP_BEST_EFFORT}" == "1" ]] && return 0
  return "${rc}"
}

v2k_linux_bootstrap_one() {
  local img="$1"

  # [NEW] Ensure NBD module is loaded (Auto-recovery after reboot)
  if ! lsmod | grep -q "^nbd"; then
      v2k_event INFO "linux_bootstrap" "" "loading_nbd_module" "{}"
      modprobe nbd max_part=16
      udevadm settle
  fi

  local nbd_dev=""
  local mnt=""
  local bootmnt=""
  local lvm_sysdir=""
  local old_lvm_system_dir=""
  local had_old_lvm_system_dir=0
  mnt="$(mktemp -d /tmp/v2k_root.XXXXXX)"
  bootmnt="$(mktemp -d /tmp/v2k_boot.XXXXXX)"

  # [Global Lock Variable]
  V2K_BOOTSTRAP_LOCK_FD=""

  cleanup() {
    set +e
    v2k_event INFO "linux_bootstrap" "" "cleanup_start" \
      "$(v2k_linux_bootstrap_json \
        --arg nbd "${nbd_dev:-}" \
        --arg mnt "${mnt:-}" \
        --arg bootmnt "${bootmnt:-}" \
        '{nbd:$nbd,mnt:$mnt,bootmnt:$bootmnt}')"

    # [STEP 1] Unmount Filesystems
    if [[ -n "${mnt:-}" ]]; then
      v2k_linux_bootstrap_umount_robust "${mnt}/dev"  --recursive >/dev/null 2>&1 || true
      v2k_linux_bootstrap_umount_robust "${mnt}/proc" --recursive >/dev/null 2>&1 || true
      v2k_linux_bootstrap_umount_robust "${mnt}/sys"  --recursive >/dev/null 2>&1 || true
      v2k_linux_bootstrap_umount_robust "${mnt}/boot" --recursive >/dev/null 2>&1 || true
      v2k_linux_bootstrap_umount_robust "${mnt}"      --recursive >/dev/null 2>&1 || true
    fi
    if [[ -n "${bootmnt:-}" ]]; then
      v2k_linux_bootstrap_umount_robust "${bootmnt}"  --recursive >/dev/null 2>&1 || true
    fi

    # [STEP 2] Deactivate LVM & Targeted DM Cleanup
    if [[ -n "${nbd_dev:-}" ]]; then
      local bn cfg lvm_out lvm_rc
      bn="$(basename "${nbd_dev}")"
      # Target ONLY this NBD for deactivation
      cfg="devices { global_filter=[ \"a|^/dev/${bn}|\", \"r|.*|\" ] filter=[ \"a|^/dev/${bn}|\", \"r|.*|\" ] }"

      v2k_linux_bootstrap_run_event "cmd_lvm_vgchange_deactivate" lvm_out lvm_rc -- \
        lvm vgchange --config "${cfg}" -an

      # [SAFE FIX] Remove DM devices ONLY if they are holders of THIS nbd device
      for holder in /sys/block/${bn}/holders/*; do
          if [[ -e "${holder}" ]]; then
              local dm_name
              dm_name="$(basename "${holder}")"
              dmsetup remove --force "${dm_name}" >/dev/null 2>&1 || true
          fi
      done
    fi

    # [STEP 3] Remove Reservation Lock
    if [[ -n "${nbd_dev:-}" ]]; then
        local base lock_dir
        base="$(basename "${nbd_dev}")"
        lock_dir="/var/lock/ablestack-v2k/reservations/${base}.lock.d"
        rm -rf "${lock_dir}" >/dev/null 2>&1 || true
    fi

    # [STEP 4] Disconnect NBD & WAIT for Removal
    if [[ -n "${nbd_dev:-}" ]]; then
      local bn pid sys_pid attempt=0 max_attempts=5
      bn="$(basename "${nbd_dev}")"
      sys_pid="/sys/block/${bn}/pid"

      while [[ "${attempt}" -lt "${max_attempts}" ]]; do
        attempt=$((attempt+1))
        qemu-nbd -d "${nbd_dev}" >/dev/null 2>&1 || true
        udevadm settle >/dev/null 2>&1 || true
        sleep 0.5
        pid="$(cat "${sys_pid}" 2>/dev/null || echo "")"
        if [[ -z "${pid}" || "${pid}" == "0" ]]; then break; fi
        kill -TERM "${pid}" >/dev/null 2>&1 || true
        sleep 0.5
        kill -KILL "${pid}" >/dev/null 2>&1 || true
      done
      
      # Wait for nodes to disappear
      local wait_attempt=0
      while ls "${nbd_dev}"p* >/dev/null 2>&1; do
          wait_attempt=$((wait_attempt+1))
          if [[ "${wait_attempt}" -gt 20 ]]; then
              udevadm trigger --action=remove "${nbd_dev}" >/dev/null 2>&1 || true
              break
          fi
          sleep 0.5
      done
      udevadm settle >/dev/null 2>&1 || true
      
      # --------------------------------------------------------
      # [CRITICAL FIX] Post-Disconnect Cache Wipe
      # Now that the NBD device is GONE, we must tell LVM to scan
      # and realize it's gone. This removes the "Ghost" entry.
      # We use a filter that accepts NBDs so LVM *looks* for them,
      # finds nothing, and updates the cache to "missing".
      # --------------------------------------------------------
      local refresh_cfg="devices { filter=[ \"a|^/dev/nbd|\", \"r|.*|\" ] }"
      lvm pvscan --config "${refresh_cfg}" --cache >/dev/null 2>&1 || true
      # --------------------------------------------------------
    fi

    if [[ -n "${lvm_sysdir:-}" ]]; then
      rm -rf "${lvm_sysdir}" >/dev/null 2>&1 || true
    fi
    if [[ "${had_old_lvm_system_dir:-0}" -eq 1 ]]; then
      export LVM_SYSTEM_DIR="${old_lvm_system_dir:-}"
    else
      unset LVM_SYSTEM_DIR >/dev/null 2>&1 || true
    fi
    rm -rf "${mnt:-}" "${bootmnt:-}" >/dev/null 2>&1 || true

    # [STEP 5] Release Global Lock
    if [[ -n "${V2K_BOOTSTRAP_LOCK_FD}" ]]; then
        v2k_event INFO "linux_bootstrap" "" "global_lock_release" "{}"
        flock -u "${V2K_BOOTSTRAP_LOCK_FD}" 2>/dev/null || true
        eval "exec ${V2K_BOOTSTRAP_LOCK_FD}>&-" || true
        V2K_BOOTSTRAP_LOCK_FD=""
    fi

    v2k_event INFO "linux_bootstrap" "" "cleanup_done" \
      "$(v2k_linux_bootstrap_json \
        --arg nbd "${nbd_dev:-}" \
        --arg mnt "${mnt:-}" \
        --arg bootmnt "${bootmnt:-}" \
        '{nbd:$nbd,mnt:$mnt,bootmnt:$bootmnt}')"
  }
  trap cleanup EXIT INT TERM

  finish() {
    local _rc="${1:-0}"
    cleanup
    trap - EXIT INT TERM
    return "${_rc}"
  }

  # ------------------------------------------------------------
  # [GLOBAL SERIALIZATION START]
  local lock_file="/var/lock/ablestack-v2k/linux_bootstrap_global.lock"
  mkdir -p "$(dirname "${lock_file}")"
  local lock_fd
  eval "exec {lock_fd}>${lock_file}"
  
  v2k_event INFO "linux_bootstrap" "" "global_lock_wait" "{}"
  if ! flock -x -w 1200 "${lock_fd}"; then
      v2k_event ERROR "linux_bootstrap" "" "global_lock_timeout" "{}"
      eval "exec ${lock_fd}>&-"
      finish 89
      return $?
  fi
  V2K_BOOTSTRAP_LOCK_FD="${lock_fd}"
  v2k_event INFO "linux_bootstrap" "" "global_lock_acquired" "{}"
  
  # ------------------------------------------------------------
  # [SAFE PRE-FLIGHT CLEANUP]
  # Remove zombies and their DM holders.
  # ------------------------------------------------------------
  v2k_event INFO "linux_bootstrap" "" "preflight_safe_cleanup" "{}"
  
  for z_nbd_path in /sys/class/block/nbd*; do
      # e.g., /sys/class/block/nbd0
      local z_bn="$(basename "${z_nbd_path}")"
      local z_dev="/dev/${z_bn}"
      local z_pid_file="${z_nbd_path}/pid"
      
      # 1. Check if active process exists
      if [[ -f "${z_pid_file}" ]]; then
          local z_pid
          z_pid="$(cat "${z_pid_file}" 2>/dev/null || echo "")"
          if [[ -n "${z_pid}" && "${z_pid}" != "0" ]]; then
              if kill -0 "${z_pid}" 2>/dev/null; then
                  continue # Process is alive, skip
              fi
          fi
      fi

      # 2. Process is dead. Remove DM holders first.
      if [[ -d "${z_nbd_path}/holders" ]]; then
          for holder in "${z_nbd_path}/holders/"*; do
              if [[ -e "${holder}" ]]; then
                  local dm_name
                  dm_name="$(basename "${holder}")"
                  v2k_event WARN "linux_bootstrap" "" "removing_stale_dm" "{\"nbd\":\"${z_bn}\",\"dm\":\"${dm_name}\"}"
                  dmsetup remove --force "${dm_name}" >/dev/null 2>&1 || true
              fi
          done
      fi

      # 3. Clean up the zombie NBD itself
      if ls "${z_dev}"p* >/dev/null 2>&1; then
          local wipe_cfg="devices { global_filter=[ \"a|^/dev/${z_bn}|\", \"r|.*|\" ] filter=[ \"a|^/dev/${z_bn}|\", \"r|.*|\" ] }"
          lvm vgchange --config "${wipe_cfg}" -an >/dev/null 2>&1 || true
          qemu-nbd -d "${z_dev}" >/dev/null 2>&1 || true
      fi
  done
  
  # 4. Global Cache Refresh (Pre-flight)
  # Ensure we start with a clean slate regarding NBDs.
  local pre_refresh_cfg="devices { filter=[ \"a|^/dev/nbd|\", \"r|.*|\" ] }"
  lvm pvscan --config "${pre_refresh_cfg}" --cache >/dev/null 2>&1 || true
  
  udevadm settle >/dev/null 2>&1 || true
  sleep 0.5
  # ------------------------------------------------------------
 
  nbd_dev="$(v2k_linux_bootstrap_pick_nbd || true)"
  if [[ -z "${nbd_dev}" ]]; then
    v2k_event ERROR "linux_bootstrap" "" "no_free_nbd" "{}"
    finish 78
    return $?
  fi

  local qout qrc
  v2k_linux_bootstrap_run_event "cmd_qemu_nbd_connect" qout qrc -- \
    qemu-nbd --connect "${nbd_dev}" "${img}"
  if [[ "${qrc}" -ne 0 ]]; then
    v2k_event ERROR "linux_bootstrap" "" "qemu_nbd_connect_failed" \
      "{\"nbd\":\"${nbd_dev}\",\"img\":\"${img}\",\"rc\":${qrc}}"
    finish 79
    return $?
  fi
  udevadm settle >/dev/null 2>&1 || true
  local pout prc
  v2k_linux_bootstrap_run_event "cmd_partprobe" pout prc -- partprobe "${nbd_dev}"
  
  # [Partition Wait Loop]
  local pt_attempt=0
  while [[ "${pt_attempt}" -lt 20 ]]; do
      udevadm settle >/dev/null 2>&1 || true
      if ls "${nbd_dev}"p* >/dev/null 2>&1; then
          break
      fi
      if lsblk -rn "${nbd_dev}" 2>/dev/null | grep -q "part"; then
          sleep 0.5
      else
          break
      fi
      pt_attempt=$((pt_attempt+1))
  done

  if v2k_has_lvm_tools; then
    if [[ -n "${LVM_SYSTEM_DIR-}" ]]; then
      had_old_lvm_system_dir=1
      old_lvm_system_dir="${LVM_SYSTEM_DIR}"
    else
      had_old_lvm_system_dir=0
      old_lvm_system_dir=""
    fi
    lvm_sysdir="$(mktemp -d /tmp/v2k_lvm.XXXXXX)"
    chmod 700 "${lvm_sysdir}" >/dev/null 2>&1 || true
    export LVM_SYSTEM_DIR="${lvm_sysdir}"
  fi

  local root_dev=""
  root_dev="$(v2k_linux_bootstrap_try_mount_partitions "${nbd_dev}" "${mnt}" || true)"
  if [[ -z "${root_dev}" ]]; then
    root_dev="$(v2k_linux_bootstrap_try_mount_lvm "${nbd_dev}" "${mnt}" || true)"
  fi
  if [[ -z "${root_dev}" ]]; then
    v2k_event ERROR "linux_bootstrap" "" "root_partition_not_found" "{\"nbd\":\"${nbd_dev}\",\"note\":\"no /etc/os-release found on partitions or LVM LVs\"}"
    finish 80
    return $?
  fi

  local rout rrc
  v2k_linux_bootstrap_wait_blockdev "${root_dev}" 5 || true
  v2k_linux_bootstrap_run_event "mount_root_rw" rout rrc -- \
    v2k_linux_bootstrap_mount_robust "${root_dev}" "${mnt}" "rw"
  if [[ "${rrc}" -ne 0 ]]; then
    v2k_event ERROR "linux_bootstrap" "" "mount_root_failed" \
      "{\"dev\":\"${root_dev}\",\"rc\":${rrc}}"
    finish 81
    return $?
  fi

  if [[ -f "${mnt}/etc/fstab" ]]; then
    local boot_src
    boot_src="$(awk '$2=="/boot"{print $1}' "${mnt}/etc/fstab" 2>/dev/null | head -n1 || true)"
    if [[ -n "${boot_src}" ]]; then
      mkdir -p "${mnt}/boot"
      if [[ "${boot_src}" =~ ^UUID= ]]; then
        local uuid="${boot_src#UUID=}"
        boot_src=""
        local p
        for p in "${nbd_dev}"p*; do
           [[ -b "$p" ]] || continue
           local puuid
           puuid="$(blkid -o value -s UUID "$p" 2>/dev/null || true)"
           if [[ "${puuid}" == "${uuid}" ]]; then
              boot_src="$p"
              break
           fi
        done
      fi
      if [[ -b "${boot_src}" ]]; then
        local bout brc
        v2k_linux_bootstrap_wait_blockdev "${boot_src}" 5 || true
        v2k_linux_bootstrap_run_event "mount_boot_rw" bout brc -- \
          v2k_linux_bootstrap_mount_robust "${boot_src}" "${mnt}/boot" "rw"
      else
        v2k_event WARN "linux_bootstrap" "" "boot_partition_not_found_on_nbd" "{}"
      fi
    fi
  fi

  v2k_event INFO "linux_bootstrap" "" "root_mounted" "{\"root_part\":\"${root_dev}\"}"

  v2k_linux_bootstrap_rebuild_initramfs "${mnt}" "${nbd_dev}"
  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    finish "${rc}"
    return $?
  fi

  sync
  
  finish 0
  return $?
}

v2k_linux_bootstrap_rebuild_initramfs() {
  local rootmnt="$1"
  local nbd_dev="$2"

  # ------------------------------------------------------------
  # [Modified] bind mounts for chroot with ISOLATION
  # Instead of binding host /dev, we populate a tmpfs with
  # only the necessary nodes + this VM's NBD devices.
  # ------------------------------------------------------------
  mkdir -p "${rootmnt}/dev" "${rootmnt}/proc" "${rootmnt}/sys"
  
  # 1. Mount tmpfs on chroot /dev
  mount -t tmpfs tmpfs "${rootmnt}/dev" -o mode=0755,nosuid,noexec || return 85

  # 2. Copy essentials from host /dev
  local node
  for node in null zero full random urandom tty console ptmx; do
    if [[ -e "/dev/${node}" ]]; then
      cp -a "/dev/${node}" "${rootmnt}/dev/"
    fi
  done

  # 3. Copy specific NBD device nodes (Current VM's disk only)
  if [[ -n "${nbd_dev}" ]]; then
    cp -a "${nbd_dev}"* "${rootmnt}/dev/" 2>/dev/null || true
  fi

  v2k_linux_bootstrap_mount_robust "/proc" "${rootmnt}/proc" "" || return 85
  v2k_linux_bootstrap_mount_robust "/sys"  "${rootmnt}/sys"  "" || return 85

  # Harden propagation (best-effort)
  mount --make-rslave "${rootmnt}/dev"  >/dev/null 2>&1 || true
  mount --make-rslave "${rootmnt}/proc" >/dev/null 2>&1 || true
  mount --make-rslave "${rootmnt}/sys"  >/dev/null 2>&1 || true

  # Detect distro family
  local os_id os_like
  os_id="$(. "${rootmnt}/etc/os-release" >/dev/null 2>&1; echo "${ID:-}")"
  os_like="$(. "${rootmnt}/etc/os-release" >/dev/null 2>&1; echo "${ID_LIKE:-}")"

  # Persist virtio module load hints (harmless if already present)
  mkdir -p "${rootmnt}/etc/modules-load.d" "${rootmnt}/etc/dracut.conf.d"
  cat > "${rootmnt}/etc/modules-load.d/ablestack-v2k-virtio.conf" <<'EOF'
virtio_pci
virtio_scsi
virtio_blk
scsi_mod
EOF

  # For dracut-based distros, force include drivers in initramfs
  cat > "${rootmnt}/etc/dracut.conf.d/99-ablestack-v2k-virtio.conf" <<'EOF'
add_drivers+=" virtio_pci virtio_scsi virtio_blk scsi_mod "
EOF

  v2k_event INFO "linux_bootstrap" "" "initramfs_rebuild_start" \
    "{\"id\":\"${os_id}\",\"like\":\"${os_like}\"}"

  # ------------------------------------------------------------------
  # Determine target kernel version (kver) deterministically
  # Policy:
  # - Use the kernel version(s) present under /lib/modules
  # - If multiple exist, select the lexicographically last one
  # ------------------------------------------------------------------
  local kver
  kver="$(chroot "${rootmnt}" /bin/bash -lc 'ls -1 /lib/modules 2>/dev/null | sort | tail -n1' || true)"
  if [[ -z "${kver}" ]]; then
    v2k_event ERROR "linux_bootstrap" "" "kernel_version_not_found" \
      "{\"note\":\"/lib/modules empty or missing\"}"
    return 82
  fi

  # Function for final sync barrier
  flush_buffers() {
      v2k_event INFO "linux_bootstrap" "" "syncing_disks" "{}"
      sync
      if [[ -n "${nbd_dev}" && -b "${nbd_dev}" ]]; then
          blockdev --flushbufs "${nbd_dev}" >/dev/null 2>&1 || true
      fi
  }

  # Choose rebuild tool
  if chroot "${rootmnt}" /bin/bash -lc 'command -v dracut >/dev/null 2>&1'; then
    # RHEL/Rocky/Alma etc.
    local dout drc
    v2k_linux_bootstrap_run_event "cmd_dracut" dout drc -- \
      chroot "${rootmnt}" /bin/bash -lc "dracut -f -v --kver ${kver} /boot/initramfs-${kver}.img"
    if [[ "${drc}" -ne 0 ]]; then
      v2k_event ERROR "linux_bootstrap" "" "dracut_failed" "{}"
      return 82
    fi

    # [Added] Sync Barrier
    flush_buffers

    # ------------------------------------------------------------------
    # Verify that initramfs was actually updated and virtio drivers exist
    # ------------------------------------------------------------------
    local vout vrc
    v2k_linux_bootstrap_run_event "verify_initramfs_virtio" vout vrc -- \
      chroot "${rootmnt}" /bin/bash -lc \
        "lsinitrd /boot/initramfs-${kver}.img | grep -E 'virtio_(pci|blk|scsi)|scsi_mod'"
    if [[ "${vrc}" -ne 0 ]]; then
      v2k_event ERROR "linux_bootstrap" "" "initramfs_verify_failed" \
        "{\"kver\":\"${kver}\",\"note\":\"virtio drivers not found in initramfs\"}"
      return 82
    fi

    v2k_event INFO "linux_bootstrap" "" "dracut_ok" "{}"
    return 0
  fi

  if chroot "${rootmnt}" /bin/bash -lc 'command -v update-initramfs >/dev/null 2>&1'; then
    # Debian/Ubuntu
    local uout urc
    v2k_linux_bootstrap_run_event "cmd_update_initramfs" uout urc -- \
      chroot "${rootmnt}" /bin/bash -lc 'update-initramfs -u -k all'
    if [[ "${urc}" -ne 0 ]]; then
      v2k_event ERROR "linux_bootstrap" "" "update_initramfs_failed" "{}"
      return 83
    fi
    
    # [Added] Sync Barrier
    flush_buffers

    v2k_event INFO "linux_bootstrap" "" "update_initramfs_ok" "{}"
    return 0
  fi

  v2k_event ERROR "linux_bootstrap" "" "no_initramfs_tool" \
    "{\"note\":\"dracut or update-initramfs not found in guest\"}"
  return 84
}

v2k_set_paths() {
  local workdir_in="${1:-}"
  local run_id_in="${2:-}"
  local manifest_in="${3:-}"
  local log_in="${4:-}"

  # ------------------------------------------------------------
  # Apply defaults as documented in ablestack_v2k usage:
  #   --manifest default: <workdir>/manifest.json
  #   --log      default: <workdir>/events.log
  #
  # Also support:
  #   If only --manifest is given, infer workdir = dirname(manifest)
  #
  # IMPORTANT:
  #   Do NOT auto-generate workdir when empty here.
  #   init command already generates workdir/run-id/manifest/log.
  # ------------------------------------------------------------

  # Normalize empty/"null"
  if [[ "${workdir_in}" == "null" ]]; then workdir_in=""; fi
  if [[ "${manifest_in}" == "null" ]]; then manifest_in=""; fi
  if [[ "${log_in}" == "null" ]]; then log_in=""; fi

  # If manifest is provided but workdir is not, infer workdir.
  if [[ -z "${workdir_in}" && -n "${manifest_in}" ]]; then
    workdir_in="$(dirname "${manifest_in}")"
  fi

  # If workdir is provided, default manifest/log under it.
  if [[ -n "${workdir_in}" ]]; then
    # trim trailing slashes
    workdir_in="${workdir_in%/}"
    if [[ -z "${manifest_in}" ]]; then
      manifest_in="${workdir_in}/manifest.json"
    fi
    if [[ -z "${log_in}" ]]; then
      log_in="${workdir_in}/events.log"
    fi
  fi

  export V2K_WORKDIR="${workdir_in}"
  export V2K_RUN_ID="${run_id_in}"
  export V2K_MANIFEST="${manifest_in}"
  export V2K_EVENTS_LOG="${log_in}"

}

# ------------------------------------------------------------
# ABLESTACK Host defaults (fixed paths)
# - VirtIO ISO is already installed on ABLESTACK hosts.
# - WinPE ISO is shipped/installed with ablestack_v2k package.
#   (Both can be overridden by CLI options or env.)
# ------------------------------------------------------------

v2k_resolve_virtio_iso() {
  # Echo resolved path or empty.
  local p="${1-}"
  if [[ -n "${p}" ]]; then
    [[ -f "${p}" ]] && { echo "${p}"; return 0; }
    return 1
  fi

  if [[ -n "${V2K_VIRTIO_ISO-}" ]]; then
    [[ -f "${V2K_VIRTIO_ISO}" ]] && { echo "${V2K_VIRTIO_ISO}"; return 0; }
  fi

  local candidates=(
    "/usr/share/virtio-win/virtio-win.iso"
    "/usr/share/virtio-win/virtio-win-*.iso"
    "/usr/share/virtio-win/*.iso"
    "/usr/share/virtio-win.iso"
  )
  local c
  for c in "${candidates[@]}"; do
    # shellcheck disable=SC2086
    for f in ${c}; do
      [[ -f "${f}" ]] || continue
      echo "${f}"
      return 0
    done
  done
  return 1
}

v2k_resolve_winpe_iso() {
  # Echo resolved path or empty.
  local p="${1-}"
  if [[ -n "${p}" ]]; then
    [[ -f "${p}" ]] && { echo "${p}"; return 0; }
    return 1
  fi

  if [[ -n "${V2K_WINPE_ISO-}" ]]; then
    [[ -f "${V2K_WINPE_ISO}" ]] && { echo "${V2K_WINPE_ISO}"; return 0; }
  fi

  local candidates=(
    "/usr/share/ablestack/v2k/winpe/winpe-ablestack-v2k-amd64.iso"
    "/usr/share/ablestack/v2k/winpe/winpe-ablestack-v2k-*.iso"
    "/usr/share/ablestack/v2k/*.iso"
  )
  local c
  for c in "${candidates[@]}"; do
    # shellcheck disable=SC2086
    for f in ${c}; do
      [[ -f "${f}" ]] || continue
      echo "${f}"
      return 0
    done
  done
  return 1
}

# vCenter(또는 지정 server)의 SSL SHA1 thumbprint 계산
v2k_get_ssl_thumbprint_sha1() {
  local host="$1"
  [[ -n "${host}" ]] || return 1
  echo | openssl s_client -connect "${host}:443" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr '[:lower:]' '[:upper:]'
}

v2k_require_manifest() {
  if [[ -z "${V2K_MANIFEST:-}" ]]; then
    echo "Manifest path not set" >&2
    exit 2
  fi
  if [[ ! -f "${V2K_MANIFEST}" ]]; then
    echo "Manifest not found: ${V2K_MANIFEST}" >&2
    exit 2
  fi
}

v2k_manifest_append_sync_issue() {
  # Append a runtime sync-issue record into manifest for status observability.
  # This is intentionally engine-owned so status can surface "incr aborted but cutover continued".
  #
  # Usage: v2k_manifest_append_sync_issue <which> <code:int> <reason> <details_json>
  local which="${1:-}"
  local code="${2:-0}"
  local reason="${3:-}"
  local details_json="${4:-{}}"

  v2k_require_manifest

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # ensure details_json is valid json object; if not, fallback {}
  if ! printf '%s' "${details_json}" | jq -e '.' >/dev/null 2>&1; then
    details_json="{}"
  fi

  local tmp
  tmp="$(mktemp "${V2K_WORKDIR:-/tmp}/manifest.json.XXXXXX" 2>/dev/null || mktemp "/tmp/manifest.json.XXXXXX")"
  chmod 600 "${tmp}" 2>/dev/null || true

  # Append to .runtime.sync_issues (create array if missing)
  if ! jq --arg which "${which}" \
        --arg ts "${ts}" \
        --argjson code "${code}" \
        --arg reason "${reason}" \
        --argjson details "${details_json}" \
        '
        .runtime = (.runtime // {}) |
        .runtime.sync_issues = (.runtime.sync_issues // []) |
        .runtime.sync_issues += [{
          "which": $which,
          "code": $code,
          "reason": $reason,
          "ts": $ts,
          "details": $details
        }]
        ' "${V2K_MANIFEST}" > "${tmp}"; then
    rm -f "${tmp}" 2>/dev/null || true
    return 1
  fi
  mv -f "${tmp}" "${V2K_MANIFEST}"
}

v2k_now_ms() {
  # returns epoch milliseconds if possible, else seconds*1000
  local ms=""
  ms="$(date +%s%3N 2>/dev/null || true)"
  if [[ -n "${ms}" && "${ms}" =~ ^[0-9]+$ ]]; then
    echo "${ms}"
    return 0
  fi
  local s
  s="$(date +%s 2>/dev/null || echo 0)"
  echo $((s * 1000))
}

v2k_json_ensure_object() {
  # Normalize possibly-empty / invalid JSON into a valid JSON object string.
  # - empty/null -> {}
  # - valid json but not object -> {}
  # - invalid json -> {}
  local s="${1:-}"
  if [[ -z "${s}" || "${s}" == "null" ]]; then
    printf '%s' "{}"
    return 0
  fi
  if printf '%s' "${s}" | jq -e 'type=="object"' >/dev/null 2>&1; then
    printf '%s' "${s}"
    return 0
  fi
  printf '%s' "{}"
}

v2k_step_start() {
  # Usage: v2k_step_start <phase> <step> <json>
  local phase="$1" step="$2" payload="${3:-{}}"
  v2k_event INFO "${phase}" "" "${step}_start" "${payload}"
}

v2k_step_done() {
  # Usage: v2k_step_done <phase> <step> <start_ms> <rc> <json_extra>
  local phase="$1" step="$2" start_ms="$3" rc="$4" extra="${5:-{}}"
  extra="$(v2k_json_ensure_object "${extra}")"
  local end_ms dur
  end_ms="$(v2k_now_ms)"
  if [[ -n "${start_ms}" && "${start_ms}" =~ ^[0-9]+$ && -n "${end_ms}" && "${end_ms}" =~ ^[0-9]+$ ]]; then
    dur=$((end_ms - start_ms))
  else
    dur=-1
  fi
  # merge payload: {rc, elapsed_ms} + extra
  v2k_event INFO "${phase}" "" "${step}_done" \
    "$(jq -nc --argjson rc "${rc}" --argjson elapsed_ms "${dur}" --argjson extra "${extra}" \
      '$extra + {rc:$rc,elapsed_ms:$elapsed_ms}')"
}

v2k_step_fail() {
  # Usage: v2k_step_fail <phase> <step> <start_ms> <rc> <json_extra>
  local phase="$1" step="$2" start_ms="$3" rc="$4" extra="${5:-{}}"
  extra="$(v2k_json_ensure_object "${extra}")"
  local end_ms dur
  end_ms="$(v2k_now_ms)"
  if [[ -n "${start_ms}" && "${start_ms}" =~ ^[0-9]+$ && -n "${end_ms}" && "${end_ms}" =~ ^[0-9]+$ ]]; then
    dur=$((end_ms - start_ms))
  else
    dur=-1
  fi
  v2k_event ERROR "${phase}" "" "${step}_failed" \
    "$(jq -nc --argjson rc "${rc}" --argjson elapsed_ms "${dur}" --argjson extra "${extra}" \
      '$extra + {rc:$rc,elapsed_ms:$elapsed_ms}')"
}

v2k_load_runtime_flags_from_manifest() {
  # manifest가 존재한다는 전제(v2k_require_manifest 이후 호출)
  local force
  force="$(jq -r '.target.storage.force_block_device // false' "${V2K_MANIFEST}" 2>/dev/null || echo "false")"

  if [[ "${force}" == "true" ]]; then
    export V2K_FORCE_BLOCK_DEVICE="1"
  else
    export V2K_FORCE_BLOCK_DEVICE="0"
  fi

  # Observability: force-block-device 상태를 event에 기록
  # - command 별로 호출되므로, 해당 커맨드의 phase_start 전에 남겨도 문제 없음
  v2k_event INFO "runtime" "" "force_block_device" \
    "{\"enabled\":${force},\"source\":\"manifest\",\"manifest\":\"${V2K_MANIFEST}\"}"
}

v2k_cmd_init() {
  local vm="" vcenter="" dst="" mode="govc" cred_file=""

  # New: VDDK(ESXi) auth (separated from GOVC/vCenter)
  local vddk_cred_file=""

  # New: target override options (CLI -> env)
  local target_format="" target_storage="" target_map_json=""
  local force_block_device=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vm) vm="${2:-}"; shift 2;;
      --vcenter) vcenter="${2:-}"; shift 2;;
      --dst) dst="${2:-}"; shift 2;;
      --mode) mode="${2:-}"; shift 2;;
      --cred-file) cred_file="${2:-}"; shift 2;;
      --vddk-cred-file) vddk_cred_file="${2:-}"; shift 2;;

      # --- new options ---
      --target-format) target_format="${2:-}"; shift 2;;
      --target-storage) target_storage="${2:-}"; shift 2;;
      --target-map-json) target_map_json="${2:-}"; shift 2;;

      --force-block-device) force_block_device=1; shift 1;;

      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  [[ -n "${vm}" && -n "${vcenter}" && -n "${dst}" ]] || { echo "init requires --vm --vcenter --dst" >&2; exit 2; }
  [[ "${mode}" == "govc" ]] || { echo "Only --mode govc is supported in v1" >&2; exit 2; }

  if [[ -n "${cred_file}" ]]; then
    v2k_vmware_load_cred_file "${cred_file}"
  fi

  # (FIX) VDDK cred 파일은 workdir 확정/생성 이후에 저장해야 함.
  # - 기존 코드: V2K_WORKDIR 설정 전에 install 수행 -> 빈 경로/오동작 가능
  # - 정책: password는 manifest에 저장하지 않고, workdir 내 vddk.cred로만 보관

  # Validate & apply target overrides (CLI wins for this run)
  if [[ -n "${target_format}" ]]; then
    case "${target_format}" in
      qcow2|raw) export V2K_TARGET_FORMAT="${target_format}" ;;
      *) echo "Invalid --target-format: ${target_format} (allowed: qcow2|raw)" >&2; exit 2;;
    esac
  fi

  if [[ -n "${target_storage}" ]]; then
    case "${target_storage}" in
      file|block|rbd) export V2K_TARGET_STORAGE_TYPE="${target_storage}" ;;
      *) echo "Invalid --target-storage: ${target_storage} (allowed: file|block|rbd)" >&2; exit 2;;
    esac
  fi

  if [[ -n "${target_map_json}" ]]; then
    # Validate + normalize JSON early (requires jq)
    local map_compact
    if ! map_compact="$(printf '%s' "${target_map_json}" | jq -c '.' 2>/dev/null)"; then
      echo "Invalid --target-map-json (must be valid JSON object): ${target_map_json}" >&2
      exit 2
    fi
    export V2K_TARGET_STORAGE_MAP_JSON="${map_compact}"
  fi

  # Safety: block/rbd storage requires map json
  if [[ "${V2K_TARGET_STORAGE_TYPE:-file}" == "block" || "${V2K_TARGET_STORAGE_TYPE:-file}" == "rbd" ]]; then
    if [[ -z "${V2K_TARGET_STORAGE_MAP_JSON:-}" || "${V2K_TARGET_STORAGE_MAP_JSON}" == "{}" ]]; then
      echo "--target-storage block|rbd requires --target-map-json '{\"scsi0:0\":\"/dev/sdb\",\"scsi0:1\":\"rbd:pool/image\",...}'" >&2
      exit 2
    fi
  fi

  export V2K_FORCE_BLOCK_DEVICE="${force_block_device}"

  if [[ -z "${V2K_RUN_ID:-}" ]]; then
    V2K_RUN_ID="$(date +%Y%m%d-%H%M%S)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    export V2K_RUN_ID
  fi

  if [[ -z "${V2K_WORKDIR:-}" ]]; then
    # Workdir default: /var/lib/ablestack-v2k/<vm>/<run_id>
    V2K_WORKDIR="/var/lib/ablestack-v2k/${vm}/${V2K_RUN_ID}"
    export V2K_WORKDIR
  fi

  mkdir -p "${V2K_WORKDIR}"
  if [[ -z "${V2K_MANIFEST:-}" ]]; then
    V2K_MANIFEST="${V2K_WORKDIR}/manifest.json"
    export V2K_MANIFEST
  fi
  if [[ -z "${V2K_EVENTS_LOG:-}" ]]; then
    V2K_EVENTS_LOG="${V2K_WORKDIR}/events.log"
    export V2K_EVENTS_LOG
  fi

  # (FIX) Persist VDDK cred file into workdir (productization) AFTER workdir exists
  if [[ -n "${vddk_cred_file}" ]]; then
    local vddk_saved="${V2K_WORKDIR}/vddk.cred"
    # If src and dst are the same file, skip (idempotent).
    local src_real dst_real
    src_real="$(readlink -f "${vddk_cred_file}" 2>/dev/null || echo "${vddk_cred_file}")"
    dst_real="$(readlink -f "${vddk_saved}"     2>/dev/null || echo "${vddk_saved}")"
    if [[ "${src_real}" != "${dst_real}" ]]; then
      install -m 600 "${vddk_cred_file}" "${vddk_saved}"
    fi
    export V2K_VDDK_CRED_FILE="${vddk_saved}"
  else
    export V2K_VDDK_CRED_FILE=""
  fi

  # ---- VDDK(vCenter) thumbprint 제품화 자동화 ----
  # 1) cred_file 내부에 VDDK_THUMBPRINT가 있으면 우선 사용
  # 2) 없으면 V2K_VDDK_SERVER(또는 vCenter host)로 openssl 계산
  if [[ -n "${V2K_VDDK_CRED_FILE-}" && -f "${V2K_VDDK_CRED_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${V2K_VDDK_CRED_FILE}"
    # cred 파일에 user/pass/server/thumbprint가 있다면 env로 승격
    [[ -n "${VDDK_USER-}" ]] && export V2K_VDDK_USER="${VDDK_USER}"
    [[ -n "${VDDK_SERVER-}" ]] && export V2K_VDDK_SERVER="${VDDK_SERVER}"
    [[ -n "${VDDK_THUMBPRINT-}" ]] && export V2K_VDDK_THUMBPRINT="${VDDK_THUMBPRINT}"
  fi

  # thumbprint가 여전히 비어있으면 server 대상으로 자동 계산
  if [[ -z "${V2K_VDDK_THUMBPRINT-}" ]]; then
    local server host_from_vcenter
    server="${V2K_VDDK_SERVER-}"
    if [[ -z "${server}" ]]; then
      # GOVC_URL == https://x.x.x.x/sdk 형태에서 host만 추출
      host_from_vcenter="$(printf '%s' "${GOVC_URL-}" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#^.*@##; s#:[0-9]+$##')"
      server="${host_from_vcenter}"
      [[ -n "${server}" ]] && export V2K_VDDK_SERVER="${server}"
    fi
    if [[ -n "${server}" ]]; then
      V2K_VDDK_THUMBPRINT="$(v2k_get_ssl_thumbprint_sha1 "${server}" || true)"
      export V2K_VDDK_THUMBPRINT
    fi
  fi

  # Log init start with target overrides for observability
  v2k_event INFO "init" "" "phase_start" \
    "{\"vm\":\"${vm}\",\"vcenter\":\"${vcenter}\",\"dst\":\"${dst}\",\"mode\":\"${mode}\",\"target_format\":\"${V2K_TARGET_FORMAT:-qcow2}\",\"target_storage\":\"${V2K_TARGET_STORAGE_TYPE:-file}\"}"

  local inv_json
  inv_json="$(v2k_vmware_inventory_json "${vm}" "${vcenter}")"

  # Build manifest using inventory json + target settings (from env)
  v2k_manifest_init "${V2K_MANIFEST}" "${V2K_RUN_ID}" "${V2K_WORKDIR}" "${vm}" "${vcenter}" "${mode}" "${dst}" "${inv_json}"

  v2k_event INFO "init" "" "phase_done" "{\"manifest\":\"${V2K_MANIFEST}\",\"workdir\":\"${V2K_WORKDIR}\"}"

  v2k_json_or_text_ok "init" \
    "{\"run_id\":\"${V2K_RUN_ID}\",\"workdir\":\"${V2K_WORKDIR}\",\"manifest\":\"${V2K_MANIFEST}\"}" \
    "Initialized. run_id=${V2K_RUN_ID} workdir=${V2K_WORKDIR}"
}

v2k_cmd_cbt() {
  v2k_require_manifest
  v2k_load_runtime_flags_from_manifest
  local action="${1:-}"
  case "${action}" in
    enable)
      v2k_event INFO "cbt_enable" "" "phase_start" "{}"
      v2k_vmware_cbt_enable_all "${V2K_MANIFEST}"
      v2k_manifest_phase_done "${V2K_MANIFEST}" "cbt_enable"
      v2k_event INFO "cbt_enable" "" "phase_done" "{}"
      v2k_json_or_text_ok "cbt.enable" "{}" "CBT enabled (requested) and verified."
      ;;
    status)
      local s
      s="$(v2k_vmware_cbt_status_all "${V2K_MANIFEST}")"
      v2k_json_or_text_ok "cbt.status" "${s}" "${s}"
      ;;
    *)
      echo "Usage: cbt enable|status" >&2
      exit 2
      ;;
  esac
}

v2k_cmd_snapshot() {
  v2k_require_manifest
  v2k_load_runtime_flags_from_manifest
  local which="${1:-}" name=""
  local safe_mode=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="${2:-}"; shift 2;;
      --safe-mode) safe_mode=1; shift 1;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  export V2K_SAFE_MODE="${safe_mode}"

  case "${which}" in
    base|incr|final)
      if [[ "${which}" == "incr" ]] && v2k_should_skip_incr_phase; then
        v2k_event INFO "snapshot.incr" "" "phase_skipped_by_policy" \
          "{\"safe_mode\":${V2K_SAFE_MODE:-0},\"guestFamily\":\"$(jq -r '.source.vm.guestFamily // empty' "${V2K_MANIFEST}" 2>/dev/null || true)\"}"
        v2k_json_or_text_ok "snapshot.incr" "{}" "Snapshot incr skipped by policy."
        return 0
      fi
      if [[ -z "${name}" ]]; then
        name="migr-${which}-$(date +%Y%m%d-%H%M%S)"
      fi
      v2k_event INFO "snapshot.${which}" "" "phase_start" "{\"name\":\"${name}\"}"
      v2k_vmware_snapshot_create "${V2K_MANIFEST}" "${which}" "${name}"
      v2k_manifest_snapshot_set "${V2K_MANIFEST}" "${which}" "${name}"
      v2k_event INFO "snapshot.${which}" "" "phase_done" "{\"name\":\"${name}\"}"
      v2k_json_or_text_ok "snapshot.${which}" "{\"name\":\"${name}\"}" "Snapshot created: ${name}"
      ;;
    *)
      echo "Usage: snapshot base|incr|final [--name X]" >&2
      exit 2
      ;;
  esac
}

v2k_prepare_cbt_change_ids_for_sync() {
  local manifest="$1" which="$2"
  # For incr/final we must ensure changeId fields exist for CBT-enabled disks.
  # This prevents "empty changeId" runs and stabilizes incremental logic.
  #
  # NOTE: actual 'changeId advancement' is expected to be performed by the
  # patch pipeline (vmware_changed_areas.py + transfer_patch.sh) and persisted
  # into manifest. Here we only ensure initialization.
  if [[ "${which}" == "incr" || "${which}" == "final" ]]; then
    v2k_manifest_ensure_cbt_change_ids "${manifest}"
  fi
}

v2k_prepare_cbt_change_ids_after_base() {
  local manifest="$1"
  # After base sync completes, initialize base/last changeId for CBT-enabled disks.
  # This makes the next incr sync deterministic even if the patch pipeline expects
  # non-empty last_change_id.
  v2k_manifest_ensure_cbt_change_ids "${manifest}"
}

v2k_maybe_force_cleanup() {
  # force cleanup ONLY this run namespace
  if [[ "${V2K_FORCE_CLEANUP:-0}" -eq 1 ]]; then
    v2k_event WARN "runtime" "" "force_cleanup" "{\"run_id\":\"${V2K_RUN_ID:-}\"}"
    v2k_force_cleanup_run "${V2K_RUN_ID:-}" || true
  fi
}

v2k_force_cleanup_run() {
  # Idempotent cleanup for a given run-id namespace.
  # - Never hard-fail the caller.
  # - Best-effort: stop processes, detach devices, remove temp artifacts.
  local run_id="${1:-}"
  local workdir=""
  local manifest=""

  # If current env is set, prefer it. Otherwise try to locate by run-id.
  if [[ -n "${V2K_WORKDIR:-}" && -d "${V2K_WORKDIR}" ]]; then
    workdir="${V2K_WORKDIR}"
  elif [[ -n "${run_id}" ]]; then
    # Best-effort discovery (do not scan entire FS aggressively)
    # Default root used by init: /var/lib/ablestack-v2k/<vm>/<run_id>
    workdir="$(find /var/lib/ablestack-v2k -maxdepth 3 -type d -name "${run_id}" 2>/dev/null | head -n1 || true)"
  fi

  if [[ -n "${workdir}" && -f "${workdir}/manifest.json" ]]; then
    manifest="${workdir}/manifest.json"
  else
    manifest="${V2K_MANIFEST:-}"
  fi

  # Observability
  v2k_event WARN "cleanup" "" "force_cleanup_run_start" \
    "{\"run_id\":\"${run_id}\",\"workdir\":\"${workdir}\",\"manifest\":\"${manifest}\"}"

  set +e

  # 1) Stop nbdkit processes referenced by pidfiles in workdir (preferred)
  if [[ -n "${workdir}" ]]; then
    local pidf pid
    for pidf in "${workdir}"/nbdkit*.pid "${workdir}"/qemu-nbd*.pid "${workdir}"/*.pid; do
      [[ -f "${pidf}" ]] || continue
      pid="$(cat "${pidf}" 2>/dev/null || true)"
      if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]]; then
        kill -TERM "${pid}" >/dev/null 2>&1 || true
        sleep 0.2
        kill -KILL "${pid}" >/dev/null 2>&1 || true
        v2k_event INFO "cleanup" "" "force_cleanup_kill_pidfile" \
          "{\"pidfile\":\"${pidf}\",\"pid\":\"${pid}\"}"
      fi
    done
  fi

  # ==============================================================================
  # [삭제됨] 2) Defensive process kill (RunID/Workdir)
  # 원인: RunID는 유니크하므로 좀비가 존재할 수 없으며, 오히려 부모 프로세스(sudo 등)를 죽여
  #       스크립트가 중단되거나 세션이 종료되는 원인이 됨.
  # ==============================================================================
  # [FIX] Do not kill myself (current PID $$) via pkill -f pattern match
  #if [[ -n "${run_id}" ]]; then
    # 자기 자신($$)을 제외한 나머지 프로세스만 종료
  #  pgrep -f "ablestack_v2k.*${run_id}" | grep -v "^$$\$" | xargs -r kill -TERM >/dev/null 2>&1 || true
  #fi
  # [FIX 2] workdir 기반 종료 시 자기 자신($$) 제외 (지적해주신 부분)
  #if [[ -n "${workdir}" ]]; then
  #  pgrep -f "${workdir}" | grep -v "^$$\$" | xargs -r kill -TERM >/dev/null 2>&1 || true
  #fi

  # 3) Detach loop devices bound to files under workdir (best-effort)
  if command -v losetup >/dev/null 2>&1 && [[ -n "${workdir}" ]]; then
    local loop
    while read -r loop; do
      [[ -n "${loop}" ]] || continue
      losetup -d "${loop}" >/dev/null 2>&1 || true
      v2k_event INFO "cleanup" "" "force_cleanup_loop_detach" "{\"loop\":\"${loop}\"}"
    done < <(losetup -a 2>/dev/null | awk -v wd="${workdir}" '$0 ~ wd {sub(/:.*/,"",$1); print $1}')
  fi

  # [DISABLED] Concurrent Safety Fix: Do not sweep global /tmp mounts.
  # This kills other running VMs' bootstrap processes. rely on per-process trap cleanup.  
  # 4) Unmount any mountpoints under /tmp/v2k_* that might be left behind
  #if command -v findmnt >/dev/null 2>&1; then
  #  local mp
  #  while read -r mp; do
  #    [[ -n "${mp}" ]] || continue
  #    umount -R -l "${mp}" >/dev/null 2>&1 || umount -l "${mp}" >/dev/null 2>&1 || true
  #    v2k_event INFO "cleanup" "" "force_cleanup_umount" "{\"path\":\"${mp}\"}"
  #  done < <(findmnt -rn -o TARGET 2>/dev/null | grep -E '^/tmp/v2k_(root|boot|lvm)\.' || true)
  #fi

  # 5) Clean workdir-local temp artifacts (do NOT remove workdir itself here)
  if [[ -n "${workdir}" ]]; then
    rm -f "${workdir}"/nbdkit*.sock "${workdir}"/nbdkit*.uri "${workdir}"/*.lock \
          "${workdir}"/*.tmp "${workdir}"/*.json.tmp >/dev/null 2>&1 || true
  fi

  set -e 2>/dev/null || true
  v2k_event WARN "cleanup" "" "force_cleanup_run_done" \
    "{\"run_id\":\"${run_id}\",\"workdir\":\"${workdir}\"}"
  return 0
}

v2k_cmd_sync() {
  local manifest="${V2K_MANIFEST}"
  local force_cleanup=0
  local safe_mode=0
  : "${V2K_BASE_METHOD:=nbdcopy}"

  v2k_require_manifest
  v2k_load_runtime_flags_from_manifest
  local which="${1:-}" jobs=1 coalesce_gap=$((1024*1024)) chunk=$((4*1024*1024))
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs) jobs="${2:-}"; shift 2;;
      --coalesce-gap) coalesce_gap="${2:-}"; shift 2;;
      --chunk) chunk="${2:-}"; shift 2;;
      --force-cleanup) force_cleanup=1; shift 1;;
      --safe-mode) safe_mode=1; shift 1;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  export V2K_SAFE_MODE="${safe_mode}"

  export V2K_FORCE_CLEANUP="${force_cleanup}"
  v2k_maybe_force_cleanup

  v2k_event INFO "sync.${which}" "" "policy_evaluation" \
    "{\"safe_mode\":${V2K_SAFE_MODE:-0},"\
    "\"guestFamily\":\"$(jq -r '.source.vm.guestFamily // empty' "${V2K_MANIFEST}")\"}"

  # Policy: skip incr sync for linuxGuest or safe-mode
  if [[ "${which}" == "incr" ]] && v2k_should_skip_incr_phase; then
    v2k_event INFO "sync.incr" "" "phase_skipped_by_policy" \
      "{\"safe_mode\":${V2K_SAFE_MODE:-0},\"guestFamily\":\"$(jq -r '.source.vm.guestFamily // empty' "${V2K_MANIFEST}" 2>/dev/null || true)\"}"
    v2k_json_or_text_ok "sync.incr" "{}" "Incr sync skipped by policy."
    return 0
  fi

  v2k_prepare_cbt_change_ids_for_sync "${V2K_MANIFEST}" "${which}"

  # --------------------------------------------------
  # Pre-check for incr/final (CBT safety guard)
  # --------------------------------------------------
  if [[ "${which}" == "incr" || "${which}" == "final" ]]; then
    if ! v2k_should_skip_incr_phase; then
      if ! jq -e '
        .disks[]
        | select(.cbt.enabled == true)
        | .cbt.last_change_id
        | length > 0
      ' "${V2K_MANIFEST}" >/dev/null 2>&1; then
        echo "CBT changeId missing for ${which} sync. Refusing to run to avoid full-disk copy." >&2
        # Observability: emit explicit event + persist into manifest runtime for status reporting.
        v2k_event WARN "sync.${which}" "" "cbt_change_id_missing" \
          "{\"which\":\"${which}\",\"code\":44,\"action\":\"refuse_to_run\"}"
        v2k_manifest_append_sync_issue "${which}" 44 "cbt_change_id_missing" \
          "{\"action\":\"refuse_to_run\",\"note\":\"caller may continue to cutover\"}" \
          || true
        return 44
      fi
    fi
  fi

  case "${which}" in
    base)
      v2k_event INFO "sync.base" "" "phase_start" "{\"jobs\":${jobs}}"
      v2k_transfer_base_all "${V2K_MANIFEST}" "${jobs}"

      # [Fix] Base Sync 직후, 현재 Change ID를 조회하여 기준점 확보 (데이터 누락 방지)
      local py_script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vmware_changed_areas.py"
      v2k_manifest_fetch_and_save_base_change_ids "${V2K_MANIFEST}" "${py_script_path}"

      v2k_prepare_cbt_change_ids_after_base "${V2K_MANIFEST}"
      v2k_manifest_phase_done "${V2K_MANIFEST}" "base_sync"
      v2k_event INFO "sync.base" "" "phase_done" "{}"
      v2k_json_or_text_ok "sync.base" "{}" "Base sync done."
      ;;
    incr|final)
      v2k_event INFO "sync.${which}" "" "phase_start" \
        "{\"jobs\":${jobs},\"coalesce_gap\":${coalesce_gap},\"chunk\":${chunk}}"
      v2k_transfer_patch_all "${V2K_MANIFEST}" "${which}" "${jobs}" "${coalesce_gap}" "${chunk}"
      v2k_manifest_phase_done "${V2K_MANIFEST}" "${which}_sync"
      v2k_event INFO "sync.${which}" "" "phase_done" "{}"
      v2k_json_or_text_ok "sync.${which}" "{}" "${which} sync done."
      ;;
    *)
      echo "Usage: sync base|incr|final [--jobs N] [--coalesce-gap BYTES] [--chunk BYTES]" >&2
      exit 2
      ;;
  esac
}

v2k_cmd_verify() {
  v2k_require_manifest
  v2k_load_runtime_flags_from_manifest
  local mode="quick" samples=64
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) mode="${2:-}"; shift 2;;
      --samples) samples="${2:-}"; shift 2;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  v2k_event INFO "verify" "" "phase_start" "{\"mode\":\"${mode}\",\"samples\":${samples}}"
  local out
  out="$(v2k_verify "${V2K_MANIFEST}" "${mode}" "${samples}")"
  v2k_event INFO "verify" "" "phase_done" "{}"
  v2k_json_or_text_ok "verify" "${out}" "${out}"
}

v2k_cmd_cutover() {
  v2k_require_manifest
  v2k_load_runtime_flags_from_manifest
  local shutdown="guest" define_only=0 start_vm=0
  local safe_mode=0
  local winpe_bootstrap=1
  local winpe_cli_set=0 start_cli_set=0
  local winpe_iso="/usr/share/ablestack/v2k/winpe.iso"
  local virtio_iso="/usr/share/virtio-win/virtio-win.iso"
  local winpe_timeout=600
  local shutdown_force=1 shutdown_timeout=300
  local vcpu=2 memory=2048
  local vcpu_set=0 memory_set=0
  local network="default" bridge="" vlan=""
  local force_cleanup=0

  #Linux bootstrap (host-chroot initramfs rebuild)
  local linux_bootstrap=-1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shutdown) shutdown="${2:-}"; shift 2;;
      --shutdown-force) shutdown_force=1; shift 1;;
      --shutdown-timeout) shutdown_timeout="${2:-}"; shift 2;;
      --define-only) define_only=1; shift 1;;
      --start) start_vm=1; start_cli_set=1; shift 1;;
      --vcpu) vcpu="${2:-}"; vcpu_set=1; shift 2;;
      --memory) memory="${2:-}"; memory_set=1; shift 2;;
      --network) network="${2:-}"; shift 2;;
      --bridge) bridge="${2:-}"; shift 2;;
      --vlan) vlan="${2:-}"; shift 2;;
      --winpe-bootstrap)
        winpe_bootstrap=1
        winpe_cli_set=1
        shift 1
        ;;
      --no-winpe-bootstrap)
        winpe_bootstrap=0
        winpe_cli_set=1
        shift 1
        ;;
      --winpe-iso) winpe_iso="${2:-}"; shift 2;;
      --virtio-iso) virtio_iso="${2:-}"; shift 2;;
      --winpe-timeout) winpe_timeout="${2:-}"; shift 2;;
      --safe-mode) safe_mode=1; shift 1;;
      --linux-bootstrap)
        linux_bootstrap=1
        shift 1
        ;;
      --no-linux-bootstrap)
        linux_bootstrap=0
        shift 1
        ;;

      --force-cleanup) force_cleanup=1; shift 1;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  export V2K_SAFE_MODE="${safe_mode}"

  # -------------------------------------------------------------------
  # Auto WinPE policy:
  # - If source VM is NOT Windows, skip WinPE unless explicitly forced by CLI.
  # - If WinPE is skipped and caller did not explicitly set --start,
  #   auto-start the VM (unless --define-only).
  # -------------------------------------------------------------------
  local is_windows=0
  local guest_family guest_id guest_full
  guest_family="$(jq -r '.source.vm.guestFamily // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"
  guest_id="$(jq -r '.source.vm.guestId // .source.vm.guest_id // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"
  guest_full="$(jq -r '.source.vm.guestFullName // .source.vm.guest_full_name // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"

  # windows heuristics (govc 기준)
  if [[ "${guest_family}" == "windowsGuest" ]]; then
    is_windows=1
  elif [[ "${guest_id}" =~ [Ww]in ]]; then
    is_windows=1
  elif [[ "${guest_full}" =~ [Ww]indows ]]; then
    is_windows=1
  fi

  if [[ "${winpe_cli_set}" -eq 0 && "${is_windows}" -eq 0 ]]; then
    # non-Windows: default skip
    winpe_bootstrap=0
    v2k_event INFO "cutover" "" "winpe_auto_skip_non_windows" \
      "{\"guestFamily\":\"${guest_family}\",\"guestId\":\"${guest_id}\"}"
  fi

  # If WinPE is skipped, auto-start unless define-only or caller explicitly controlled start.
  if [[ "${winpe_bootstrap}" -eq 0 && "${define_only}" -eq 0 && "${start_cli_set}" -eq 0 ]]; then
    start_vm=1
    v2k_event INFO "cutover" "" "auto_start_enabled" "{}"
  fi

  # safety validation
  case "${winpe_bootstrap}" in
    0|1) ;;
    *) echo "Invalid winpe_bootstrap value: ${winpe_bootstrap}" >&2; exit 2;;
  esac

  export V2K_FORCE_CLEANUP="${force_cleanup}"
  v2k_maybe_force_cleanup

  # Default: carry over vCPU/Memory from VMware (manifest), unless explicitly overridden by CLI.
  if [[ "${vcpu_set}" -eq 0 ]]; then
    local mv_cpu
    mv_cpu="$(jq -r '.source.vm.cpu // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"
    if [[ -n "${mv_cpu}" && "${mv_cpu}" != "null" && "${mv_cpu}" =~ ^[0-9]+$ && "${mv_cpu}" -gt 0 ]]; then
      vcpu="${mv_cpu}"
    fi
  fi
  if [[ "${memory_set}" -eq 0 ]]; then
    local mv_mem
    mv_mem="$(jq -r '.source.vm.memory_mb // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"
    if [[ -n "${mv_mem}" && "${mv_mem}" != "null" && "${mv_mem}" =~ ^[0-9]+$ && "${mv_mem}" -gt 0 ]]; then
      memory="${mv_mem}"
    fi
  fi

  # As approved: default flow is shutdown -> final snapshot -> final sync
  v2k_event INFO "cutover" "" "phase_start" "{\"shutdown\":\"${shutdown}\"}"

  local _ts _rc
  case "${shutdown}" in
    manual)
      echo "Cutover requires VM to be shutdown on VMware side. Confirm shutdown before proceeding." >&2
      ;;
    guest)
      # Best-effort guest shutdown; fallback to hard poweroff if not supported/failed.
      _ts="$(v2k_now_ms)"
      v2k_step_start "cutover" "shutdown_guest" "{}"
      if v2k_vmware_vm_shutdown_guest_best_effort "${V2K_MANIFEST}"; then
        if ! v2k_vmware_vm_wait_poweroff "${V2K_MANIFEST}" "${shutdown_timeout}"; then
          v2k_event WARN "cutover" "" "shutdown_guest_timeout_fallback_poweroff" "{\"timeout\":${shutdown_timeout}}"
          v2k_vmware_vm_poweroff "${V2K_MANIFEST}" "${shutdown_force}" "${shutdown_timeout}" \
            || { echo "Failed to power off VM via govc (guest+fallback)." >&2; exit 50; }
        fi
      else
        v2k_event WARN "cutover" "" "shutdown_guest_unsupported_fallback_poweroff" "{}"
        v2k_vmware_vm_poweroff "${V2K_MANIFEST}" "${shutdown_force}" "${shutdown_timeout}" \
          || { echo "Failed to power off VM via govc." >&2; exit 50; }
      fi
      v2k_step_done "cutover" "shutdown_guest" "${_ts}" 0 "{}"
      ;;
    poweroff)
      _ts="$(v2k_now_ms)"
      v2k_step_start "cutover" "shutdown_poweroff" "{\"force\":${shutdown_force},\"timeout\":${shutdown_timeout}}"
      v2k_vmware_vm_poweroff "${V2K_MANIFEST}" "${shutdown_force}" "${shutdown_timeout}" \
        || { echo "Failed to power off VM via govc." >&2; exit 50; }
      v2k_step_done "cutover" "shutdown_poweroff" "${_ts}" 0 "{}"
      ;;
    *)
      echo "Invalid --shutdown value: ${shutdown} (allowed: manual|guest|poweroff)" >&2
      exit 2
      ;;
  esac

  # ---------------------------
  # final snapshot (observable)
  # ---------------------------
  local name="migr-final-$(date +%Y%m%d-%H%M%S)"
  _ts="$(v2k_now_ms)"
  v2k_step_start "cutover" "final_snapshot" "{\"name\":\"${name}\"}"
  if v2k_vmware_snapshot_create "${V2K_MANIFEST}" "final" "${name}"; then
    v2k_manifest_snapshot_set "${V2K_MANIFEST}" "final" "${name}"
    # status visibility: record snapshot completion under cutover flow
    v2k_manifest_phase_done "${V2K_MANIFEST}" "final_snapshot" || true
    v2k_step_done "cutover" "final_snapshot" "${_ts}" 0 "{\"name\":\"${name}\"}"
  else
    v2k_step_fail "cutover" "final_snapshot" "${_ts}" 60 "{\"name\":\"${name}\"}"
    echo "Final snapshot failed." >&2
    exit 60
  fi

  # ---------------------------
  # final sync (observable)
  # ---------------------------
  _ts="$(v2k_now_ms)"
  v2k_step_start "cutover" "final_sync" "{\"jobs\":1,\"coalesce_gap\":$((1024*1024)),\"chunk\":$((4*1024*1024))}"
  if v2k_transfer_patch_all "${V2K_MANIFEST}" "final" 1 $((1024*1024)) $((4*1024*1024)); then
    v2k_manifest_phase_done "${V2K_MANIFEST}" "final_sync" || true
    v2k_step_done "cutover" "final_sync" "${_ts}" 0 "{}"
  else
    _rc=$?
    v2k_step_fail "cutover" "final_sync" "${_ts}" "${_rc}" "{}"
    # persist to manifest for status visibility
    v2k_manifest_append_sync_issue "final" "${_rc}" "final_sync_failed" \
      "{\"action\":\"abort_cutover\",\"note\":\"final patch transfer failed\"}" \
      || true
    echo "Final sync failed. rc=${_rc}" >&2
    exit "${_rc}"
  fi

  # ------------------------------------------------------------
  # Linux virtio/initramfs bootstrap (Method B)
  # - Host mounts target disk0 and rebuilds initramfs in chroot.
  # - Runs after final sync and before libvirt define/start.
  # ------------------------------------------------------------
  if v2k_is_linux_guest; then
    local do_linux_bootstrap=0
    if [[ "${linux_bootstrap}" -eq 1 ]]; then
      do_linux_bootstrap=1
    elif [[ "${linux_bootstrap}" -eq 0 ]]; then
      do_linux_bootstrap=0
    else
      # auto
      if v2k_linux_bootstrap_enabled_default; then
        do_linux_bootstrap=1
      fi
    fi

    if [[ "${do_linux_bootstrap}" -eq 1 ]]; then
      v2k_event INFO "cutover" "" "linux_bootstrap_requested" "{}"
      if [[ "${V2K_JSON_OUT:-0}" -ne 1 ]]; then
        echo "[v2k] Linux bootstrap(initramfs) requested (guestFamily=linuxGuest)"
      fi
      v2k_linux_bootstrap_initramfs "${V2K_MANIFEST}"
      local rc=$?
      if [[ "${rc}" -ne 0 ]]; then
        v2k_event ERROR "cutover" "" "linux_bootstrap_failed" "{\"code\":${rc}}"
        if [[ "${V2K_JSON_OUT:-0}" -ne 1 ]]; then
          echo "[v2k] Linux bootstrap(initramfs) failed (guestFamily=linuxGuest)"
        fi
        echo "Linux bootstrap (initramfs rebuild) failed. code=${rc}" >&2
        exit 74
      fi
      v2k_event INFO "cutover" "" "linux_bootstrap_done" "{}"
      if [[ "${V2K_JSON_OUT:-0}" -ne 1 ]]; then
        echo "[v2k] Linux bootstrap(initramfs) done (guestFamily=linuxGuest)"
      fi
    else
      v2k_event INFO "cutover" "" "linux_bootstrap_skipped" "{\"reason\":\"cli_or_policy\"}"
      if [[ "${V2K_JSON_OUT:-0}" -ne 1 ]]; then
        echo "[v2k] Linux bootstrap(initramfs) skipped (guestFamily=linuxGuest)"
      fi
    fi
  else
    v2k_event INFO "cutover" "" "linux_bootstrap_bypassed_non_linux" "{}"
  fi

  # libvirt define
  if [[ "${define_only}" -eq 1 || "${start_vm}" -eq 1 || "${winpe_bootstrap}" -eq 1 ]]; then
    _ts="$(v2k_now_ms)"
    v2k_step_start "cutover" "libvirt_define" "{\"define_only\":${define_only},\"start\":${start_vm},\"winpe\":${winpe_bootstrap}}"
    local xml_path
    if [[ -n "${bridge}" ]]; then
      xml_path="$(v2k_target_generate_libvirt_xml "${V2K_MANIFEST}" \
        --vcpu "${vcpu}" --memory "${memory}" \
        --bridge "${bridge}" $( [[ -n "${vlan}" ]] && echo --vlan "${vlan}" ) \
      )"
    else
      xml_path="$(v2k_target_generate_libvirt_xml "${V2K_MANIFEST}" \
        --vcpu "${vcpu}" --memory "${memory}" \
        --network "${network}" \
      )"
    fi

    if v2k_target_define_libvirt "${xml_path}"; then
      v2k_step_done "cutover" "libvirt_define" "${_ts}" 0 "{\"xml_path\":\"${xml_path}\"}"
    else
      _rc=$?
      v2k_step_fail "cutover" "libvirt_define" "${_ts}" "${_rc}" "{\"xml_path\":\"${xml_path}\"}"
      echo "libvirt define failed. rc=${_rc}" >&2
      exit 65
    fi
  fi

  # Hard guard: non-Windows guests must never enter WinPE path
  if [[ "${winpe_bootstrap}" -eq 0 ]]; then
    v2k_event INFO "cutover" "" "winpe_path_bypassed" \
      "{\"reason\":\"non_windows_or_cli\"}"
  fi

  # Optional: WinPE bootstrap phase (driver injection) before first Windows boot
  if [[ "${winpe_bootstrap}" -eq 1 ]]; then
    local vm winpe_iso_resolved virtio_iso_resolved cdrom0 cdrom1
    vm="$(jq -r '.target.libvirt.name' "${V2K_MANIFEST}")"

    winpe_iso_resolved="$(v2k_resolve_winpe_iso "${winpe_iso}" || true)"
    virtio_iso_resolved="$(v2k_resolve_virtio_iso "${virtio_iso}" || true)"

    if [[ -z "${winpe_iso_resolved}" || ! -f "${winpe_iso_resolved}" ]]; then
      echo "WinPE ISO not found. Expected ${winpe_iso}. Set --winpe-iso or install WinPE ISO under /usr/share/ablestack/v2k/." >&2
      exit 71
    fi

    if [[ -z "${virtio_iso_resolved}" || ! -f "${virtio_iso_resolved}" ]]; then
      echo "VirtIO ISO not found. Expected ${virtio_iso}. Set --virtio-iso or install it under /usr/share/virtio-win/." >&2
      exit 72
    fi

    v2k_event INFO "winpe" "" "phase_start" \
      "{\"winpe_iso\":\"${winpe_iso_resolved}\",\"virtio_iso\":\"${virtio_iso_resolved}\",\"timeout\":${winpe_timeout}}"

    # --- SecureBoot handling for WinPE bootstrap ---
    # Policy: If source VM is EFI + SecureBoot, temporarily disable SecureBoot for WinPE boot,
    # then restore after bootstrap. (WinPE ISO is typically not SecureBoot-signed.)
    local fw sb
    fw="$(jq -r '.source.vm.firmware // empty' "${V2K_MANIFEST}" 2>/dev/null || true)"
    sb="$(jq -r '.source.vm.secure_boot // false' "${V2K_MANIFEST}" 2>/dev/null || true)"
    case "${sb}" in true|1|yes|on) sb=1 ;; *) sb=0 ;; esac

    if [[ "${fw}" == "efi" && "${sb}" -eq 1 ]]; then
      v2k_event INFO "winpe" "" "secureboot_temp_disable" "{}"
      v2k_target_set_uefi_secureboot "${vm}" 0
    fi

    # boot order: cdrom only (hd is not listed)
    v2k_target_set_boot_cdrom_only "${vm}"

    cdrom0="$(v2k_target_attach_cdrom "${vm}" "${winpe_iso_resolved}")"
    cdrom1="$(v2k_target_attach_cdrom "${vm}" "${virtio_iso_resolved}")"

    # Start VM (WinPE)
    virsh start "${vm}" >/dev/null 2>&1 || true

    # Press-any-key handling: send SPACE 1/sec for 15 sec
    v2k_target_send_key_space "${vm}" 15

    if v2k_target_wait_shutdown "${vm}" "${winpe_timeout}"; then
      v2k_event INFO "winpe" "" "phase_done" "{}"
    else
      v2k_event ERROR "winpe" "" "phase_timeout" "{\"timeout\":${winpe_timeout}}"
      # best-effort cleanup
      v2k_target_detach_disk "${vm}" "${cdrom1}" || true
      v2k_target_detach_disk "${vm}" "${cdrom0}" || true
      v2k_target_set_boot_hd "${vm}" || true

      # Best-effort restore SecureBoot as well
      if [[ "${fw}" == "efi" && "${sb}" -eq 1 ]]; then
        v2k_target_set_uefi_secureboot "${vm}" 1 || true
      fi

      exit 63
    fi

    # Detach ISOs and restore normal boot
    v2k_target_detach_disk "${vm}" "${cdrom1}" || true
    v2k_target_detach_disk "${vm}" "${cdrom0}" || true
    v2k_target_set_boot_hd "${vm}"

    # Restore SecureBoot if it was enabled on source
    if [[ "${fw}" == "efi" && "${sb}" -eq 1 ]]; then
      v2k_event INFO "winpe" "" "secureboot_restore" "{}"
      v2k_target_set_uefi_secureboot "${vm}" 1
    fi
  fi

  # Start VM after WinPE bootstrap (or immediately if WinPE skipped)
  if [[ "${start_vm}" -eq 1 ]]; then
    v2k_target_start_vm "${V2K_MANIFEST}"
  fi

  v2k_manifest_phase_done "${V2K_MANIFEST}" "cutover"
  v2k_event INFO "cutover" "" "phase_done" "{}"
  v2k_json_or_text_ok "cutover" "{}" "Cutover done (final snapshot + final sync)."

  # Cleanup 진입 전 vCenter 상태 안정화 대기
  sleep 3
}

# cleanup policy (engine-level contract):
# - stop run-scoped helper processes (nbdkit/qemu-nbd) best-effort
# - detach loop devices that reference workdir files
# - unmount leftover /tmp/v2k_* mountpoints (lazy, best-effort)
# - purge workdir-local temp artifacts (*.pid/*.sock/*.lock/*.tmp)
# - then call transfer-layer cleanup (v2k_transfer_cleanup)
# - optionally remove VMware migr-* snapshots
# - optionally remove workdir
v2k_cmd_cleanup() {
  v2k_require_manifest
  v2k_load_runtime_flags_from_manifest
  local keep_snapshots=0 keep_workdir=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-snapshots) keep_snapshots=1; shift 1;;
      --keep-workdir) keep_workdir=1; shift 1;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done
  v2k_event INFO "cleanup" "" "phase_start" "{\"keep_snapshots\":${keep_snapshots},\"keep_workdir\":${keep_workdir}}"

  # Engine-level idempotent cleanup first (processes/devices/tmp). Never fail.
  v2k_force_cleanup_run "${V2K_RUN_ID:-}" || true

  # Then delegate to transfer layer cleanup (idempotent expected). Never fail hard.
  v2k_transfer_cleanup || true
  if [[ "${keep_snapshots}" -eq 0 ]]; then
    # After final cutover: remove ONLY migration snapshots (name contains "migr-").
    # Default: enabled. To disable: export V2K_PURGE_MIGR_SNAPSHOTS=0
    : "${V2K_PURGE_MIGR_SNAPSHOTS:=1}"
    if [[ "${V2K_PURGE_MIGR_SNAPSHOTS}" == "1" ]]; then
      v2k_event INFO "cleanup" "" "vmware_snapshot_remove_migr_start" "{\"pattern\":\"migr-\"}"
      if v2k_vmware_snapshot_remove_migr "${V2K_MANIFEST}" "migr-"; then
        v2k_event INFO "cleanup" "" "vmware_snapshot_remove_migr_done" "{\"pattern\":\"migr-\"}"
      else
        v2k_event WARN "cleanup" "" "vmware_snapshot_remove_migr_failed" "{\"pattern\":\"migr-\"}"
      fi
    fi
    v2k_vmware_snapshot_cleanup "${V2K_MANIFEST}"
  fi
  if [[ "${keep_workdir}" -eq 0 ]]; then
    rm -rf "${V2K_WORKDIR}"
  fi
  v2k_event INFO "cleanup" "" "phase_done" "{}"
  v2k_json_or_text_ok "cleanup" "{}" "Cleanup done."
}

v2k_cmd_status() {
  v2k_require_manifest
  v2k_load_runtime_flags_from_manifest
  local summary
  summary="$(v2k_manifest_status_summary "${V2K_MANIFEST}" "${V2K_EVENTS_LOG:-}")"
  v2k_json_or_text_ok "status" "${summary}" "${summary}"
}

v2k_json_or_text_ok() {
  local phase="$1"
  local json_payload="$2"
  local text="$3"
  if [[ "${V2K_JSON_OUT:-0}" -eq 1 ]]; then
    printf '{"ok":true,"phase":"%s","run_id":"%s","workdir":"%s","manifest":"%s","summary":%s}\n' \
      "${phase}" "${V2K_RUN_ID:-}" "${V2K_WORKDIR:-}" "${V2K_MANIFEST:-}" "${json_payload}"
  else
    echo "${text}"
  fi
}
