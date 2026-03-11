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
#
# Target device preparation for VMware->KVM pipeline
# - file-qcow2 : qemu-nbd attach -> /dev/nbdX
# - file-raw   : qemu-nbd attach -> /dev/nbdX (engine unification)
# - rbd-raw    : host-side rbd map -> /dev/rbd/<pool>/<image>
# - block-dev  : direct device (/dev/sdf etc), strict safety checks
#

set -euo pipefail

# ---------- logging ----------
v2k_log() { echo "[$(date '+%F %T')] $*" >&2; }
v2k_die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- cleanup registry (defensive; prevents qemu-nbd leak even if caller forgets) ----------
_v2k_cleanup_cmds=()
_v2k_cleanup_trap_installed=0

v2k_register_cleanup_cmd() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || return 0
  _v2k_cleanup_cmds+=("${cmd}")

  # install once
  if [[ "${_v2k_cleanup_trap_installed}" -eq 0 ]]; then
    _v2k_cleanup_trap_installed=1
    trap v2k_run_registered_cleanups EXIT
  fi
}

v2k_run_registered_cleanups() {
  local i
  # reverse order (LIFO)
  for ((i=${#_v2k_cleanup_cmds[@]}-1; i>=0; i--)); do
    eval "${_v2k_cleanup_cmds[$i]}" >/dev/null 2>&1 || true
  done
  _v2k_cleanup_cmds=()
}

# ---------- global lock (avoid concurrent nbd attach collisions) ----------
_v2k_lock_fd=""
v2k_lock_nbd() {
  local lockfile="${1:-/var/lock/ablestack_v2k_nbd.lock}"
  mkdir -p "$(dirname "$lockfile")"
  exec {_v2k_lock_fd}>"$lockfile"
  flock -x "$_v2k_lock_fd"
}

v2k_unlock_nbd() {
  if [[ -n "${_v2k_lock_fd}" ]]; then
    flock -u "$_v2k_lock_fd" >/dev/null 2>&1 || true
    # close FD (important: avoid keeping lockfile open forever)
    eval "exec ${_v2k_lock_fd}>&-" >/dev/null 2>&1 || true
    _v2k_lock_fd=""
  fi
}

# ---------- nbd helpers ----------
v2k_modprobe_nbd() {
  modprobe nbd max_part=16 >/dev/null 2>&1 || true
}

v2k_find_free_nbd() {
  local i dev pid
  for i in $(seq 0 127); do
    dev="/dev/nbd${i}"
    [[ -b "$dev" ]] || continue
    pid="$(cat "/sys/block/nbd${i}/pid" 2>/dev/null || true)"
    if [[ -z "$pid" || "$pid" == "0" ]]; then
      echo "$dev"
      return 0
    fi
  done
  return 1
}

v2k_qemu_nbd_disconnect() {
  local dev="$1"
  [[ -b "$dev" ]] || return 0
  qemu-nbd --disconnect "$dev" >/dev/null 2>&1 || true
}

v2k_qemu_nbd_connect() {
  local format="$1"  # qcow2|raw
  local uri="$2"     # /path/file OR rbd:pool/image
  local dev="$3"

  local err
  err="$(mktemp -t v2k-qemu-nbd-err.XXXXXX)"

  if ! qemu-nbd --connect="$dev" --format="$format" --cache=none "$uri" >/dev/null 2>"$err"; then
    local msg
    msg="$(tail -n 50 "$err" 2>/dev/null || true)"
    rm -f "$err" || true
    v2k_qemu_nbd_disconnect "$dev"
    v2k_die "qemu-nbd attach failed: dev=$dev format=$format uri=$uri :: ${msg}"
  fi

  rm -f "$err" || true
  udevadm settle >/dev/null 2>&1 || true

  blockdev --getsize64 "$dev" >/dev/null 2>&1 || {
    v2k_qemu_nbd_disconnect "$dev"
    v2k_die "qemu-nbd attach succeeded but blockdev size read failed: $dev (uri=$uri)"
  }
}

# ---------- safety checks for direct block device ----------
v2k_assert_block_device_safe() {
  local dev="$1"

  [[ -b "$dev" ]] || v2k_die "target block device not found: $dev"

  # 0) Require a whole-disk target only; reject partitions, dm, and loop devices.
  local dtype
  dtype="$(lsblk -dn -o TYPE "$dev" 2>/dev/null || true)"
  if [[ "$dtype" != "disk" ]]; then
    v2k_die "target must be a whole disk device (TYPE=disk). got TYPE=${dtype} dev=${dev}"
  fi

  # 1) Refuse a target device that is currently mounted.
  if findmnt -rn -S "$dev" >/dev/null 2>&1; then
    v2k_die "target device is mounted: $dev"
  fi

  # 2) Inspect child partitions and mountpoints via lsblk.
  local out
  out="$(lsblk -nr -o NAME,TYPE,MOUNTPOINT "$dev" 2>/dev/null || true)"

  # If any mountpoint exists on the device tree, fail.
  if echo "$out" | awk '$3 != "" { exit 0 } END { exit 1 }'; then
    v2k_die "target device or its partitions are mounted: $dev"
  fi

  # 3) Reject devices that already contain partitions for safety.
  if lsblk -nr -o NAME "$dev" | tail -n +2 | grep -q .; then
    v2k_die "target device has partitions; refuse for safety: $dev (wipe/replace disk required)"
  fi

  # 4) Reject devices with holders such as dm, mdraid, or similar stacks.
  local base
  base="$(basename "$dev")"
  if [[ -d "/sys/class/block/${base}/holders" ]] && find "/sys/class/block/${base}/holders" -mindepth 1 -maxdepth 1 | read -r _; then
    v2k_die "target device has holders (in use by dm/raid/etc): $dev"
  fi

  # 5) Reject devices currently used as swap.
  if command -v swapon >/dev/null 2>&1; then
    if swapon --noheadings --raw --output=NAME 2>/dev/null | awk '{print $1}' | grep -qx "$dev"; then
      v2k_die "target device is used as swap: $dev"
    fi
  fi

  # 6) Reject devices that look like mdraid members.
  if command -v mdadm >/dev/null 2>&1; then
    if mdadm --examine "$dev" >/dev/null 2>&1; then
      v2k_die "target device looks like mdraid member: $dev"
    fi
  fi

  # 7) Reject devices already registered as LVM physical volumes.
  if command -v pvs >/dev/null 2>&1; then
    if pvs --noheadings -o pv_name 2>/dev/null \
      | awk '{gsub(/^[ \t]+|[ \t]+$/,""); print}' \
      | grep -qx "$dev"; then
      v2k_die "target device is an LVM physical volume: $dev"
    fi
  fi

  # 8) Reject existing blkid signatures such as FS, RAID, or LUKS by default.
  #    Only the blkid signature check can be bypassed with V2K_FORCE_BLOCK_DEVICE=1.
  local force="${V2K_FORCE_BLOCK_DEVICE:-0}"

  if command -v blkid >/dev/null 2>&1; then
    if blkid "$dev" >/dev/null 2>&1; then
      if [[ "$force" == "1" ]]; then
        v2k_log "WARN: --force-block-device enabled; bypassing blkid signature check for $dev"
      else
        v2k_die "target device has existing signatures (blkid detects). refuse: $dev (use --force-block-device to bypass ONLY this check)"
      fi
    fi
  fi

  # 9) Reject devices opened by other processes.
  if command -v fuser >/dev/null 2>&1; then
    if fuser "$dev" >/dev/null 2>&1; then
      v2k_die "target device is opened by some process (fuser): $dev"
    fi
  fi

  if command -v lsof >/dev/null 2>&1; then
    if lsof "$dev" >/dev/null 2>&1; then
      v2k_die "target device is opened by some process (lsof): $dev"
    fi
  fi

  # 10) Confirm the target size can be read before use.
  blockdev --getsize64 "$dev" >/dev/null 2>&1 || v2k_die "cannot read size of $dev"
}


v2k_rbd_dev_path() {
  local rbd_uri="$1"
  local spec="${rbd_uri#rbd:}"
  printf '/dev/rbd/%s\n' "${spec}"
}

v2k_rbd_map() {
  local rbd_uri="$1"
  local spec="${rbd_uri#rbd:}"
  local dev_path map_out

  command -v rbd >/dev/null 2>&1 || v2k_die "rbd CLI not found; cannot map ${rbd_uri}"

  dev_path="$(v2k_rbd_dev_path "${rbd_uri}")"
  if [[ -b "${dev_path}" ]]; then
    echo "${dev_path}"
    return 0
  fi

  if ! map_out="$(rbd map "${spec}" 2>&1)"; then
    v2k_die "rbd map failed: ${spec} :: ${map_out}"
  fi
  udevadm settle >/dev/null 2>&1 || true

  [[ -b "${dev_path}" ]] || v2k_die "rbd map completed but device path is missing: ${dev_path} :: ${map_out}"
  echo "${dev_path}"
}

v2k_rbd_unmap() {
  local dev_path="$1"
  [[ -n "${dev_path}" ]] || return 0
  [[ -b "${dev_path}" ]] || return 0
  rbd unmap "${dev_path}" >/dev/null 2>&1 || true
}

v2k_rbd_precheck() {
  local rbd_uri="$1"   # rbd:pool/image
  local spec="${rbd_uri#rbd:}"  # pool/image

  # If the rbd CLI is available, verify the image can be queried.
  if command -v rbd >/dev/null 2>&1; then
    # Validate existence, permissions, and cluster connectivity.
    if ! rbd info "$spec" >/dev/null 2>&1; then
      v2k_die "RBD precheck failed: rbd info ${spec} (check ceph.conf/keyring/permissions or image existence)"
    fi
  fi
}


# Ensure RBD image exists and is at least size_bytes.
# Requires: rbd CLI available and ceph access configured on host.
v2k_rbd_ensure_image() {
  local rbd_uri="$1" size_bytes="$2"
  local spec="${rbd_uri#rbd:}"  # pool/image
  local size_mib cur

  [[ -n "${size_bytes}" && "${size_bytes}" != "0" ]] || {
    v2k_die "RBD ensure requires --size-bytes (got empty/0) for ${rbd_uri}"
  }

  command -v rbd >/dev/null 2>&1 || return 0

  size_mib="$(( (size_bytes + 1024*1024 - 1) / (1024*1024) ))"
  [[ "${size_mib}" -gt 0 ]] || size_mib=1

  # If not exists -> create
  if ! rbd info "${spec}" >/dev/null 2>&1; then
    v2k_log "INFO: creating RBD image ${spec} size_bytes=${size_bytes} size_mib=${size_mib}"
    rbd create "${spec}" --size "${size_mib}" >/dev/null \
      || v2k_die "rbd create failed: ${spec} size_mib=${size_mib}"
    return 0
  fi

  # Exists -> ensure size >= requested
  cur="$(rbd info "${spec}" 2>/dev/null | awk -F': ' '/^size /{print $2}' | awk '{print $1}' || true)"
  if [[ -n "${cur}" && "${cur}" =~ ^[0-9]+$ ]]; then
    if [[ "${cur}" -lt "${size_bytes}" ]]; then
      v2k_log "INFO: resizing RBD image ${spec} from ${cur} to ${size_bytes} bytes size_mib=${size_mib}"
      rbd resize "${spec}" --size "${size_mib}" >/dev/null \
        || v2k_die "rbd resize failed: ${spec} size_mib=${size_mib}"
    fi
  fi
}

# ---------- Public API ----------
# prepare_target_device --kind <file-qcow2|file-raw|rbd|block-device> --path <...> [--rbd-uri rbd:pool/image] [--nbd-dev /dev/nbdX]
#
# stdout: target_blockdev
# exports:
#   V2K_TARGET_BLOCKDEV
#   V2K_TARGET_CLEANUP_CMD (eval-able)
prepare_target_device() {
  local kind="" path="" rbd_uri="" format="" nbd_dev="" size_bytes="" register_cleanup=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) kind="$2"; shift 2 ;;
      --path) path="$2"; shift 2 ;;
      --rbd-uri) rbd_uri="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;; # optional override
      --nbd-dev) nbd_dev="$2"; shift 2 ;;
      --size-bytes) size_bytes="$2"; shift 2 ;; # for rbd create/resize
      --no-register-cleanup) register_cleanup=0; shift 1 ;;
      *) v2k_die "prepare_target_device: unknown arg: $1" ;;
    esac
  done

  [[ -n "$kind" ]] || v2k_die "prepare_target_device: --kind is required"
  [[ -n "$path" ]] || v2k_die "prepare_target_device: --path is required"

  V2K_TARGET_BLOCKDEV=""
  V2K_TARGET_CLEANUP_CMD=""

  case "$kind" in
    file-qcow2)
      [[ -f "$path" ]] || v2k_die "qcow2 not found: $path"
      format="${format:-qcow2}"
      [[ "$format" == "qcow2" ]] || v2k_die "file-qcow2 requires format=qcow2"

      v2k_modprobe_nbd
      local dev
      if [[ -n "${nbd_dev}" ]]; then
        dev="${nbd_dev}"
      else
        v2k_lock_nbd
        dev="$(v2k_nbd_alloc)" || { v2k_unlock_nbd; v2k_die "no free /dev/nbdX"; }
      fi

      v2k_qemu_nbd_disconnect "$dev"
      v2k_qemu_nbd_connect "qcow2" "$path" "$dev"
      [[ -z "${nbd_dev}" ]] && v2k_unlock_nbd

      V2K_TARGET_BLOCKDEV="$dev"
      V2K_TARGET_CLEANUP_CMD="v2k_qemu_nbd_disconnect '$dev'"
      if [[ "${register_cleanup}" -eq 1 ]]; then
        v2k_register_cleanup_cmd "${V2K_TARGET_CLEANUP_CMD}"
      fi
      ;;

    file-raw)
      [[ -f "$path" ]] || v2k_die "raw file not found: $path"
      format="${format:-raw}"
      [[ "$format" == "raw" ]] || v2k_die "file-raw requires format=raw"

      v2k_modprobe_nbd
      local dev
      if [[ -n "${nbd_dev}" ]]; then
        dev="${nbd_dev}"
      else
        v2k_lock_nbd
        dev="$(v2k_nbd_alloc)" || { v2k_unlock_nbd; v2k_die "no free /dev/nbdX"; }
      fi
      v2k_qemu_nbd_disconnect "$dev"
      v2k_qemu_nbd_connect "raw" "$path" "$dev"
      [[ -z "${nbd_dev}" ]] && v2k_unlock_nbd

      V2K_TARGET_BLOCKDEV="$dev"
      V2K_TARGET_CLEANUP_CMD="v2k_qemu_nbd_disconnect '$dev'"
      if [[ "${register_cleanup}" -eq 1 ]]; then
        v2k_register_cleanup_cmd "${V2K_TARGET_CLEANUP_CMD}"
      fi
      ;;

    rbd)
      # path: rbd:pool/image (recommended). --rbd-uri can override the full URI.
      format="${format:-raw}"
      [[ "$format" == "raw" ]] || v2k_die "rbd requires format=raw"
      if [[ -n "${rbd_uri}" ]]; then
        :
      elif [[ "${path}" == rbd:* ]]; then
        rbd_uri="${path}"
      else
        rbd_uri="rbd:${path}"
      fi

      command -v rbd >/dev/null 2>&1 || v2k_die "rbd CLI not found; cannot prepare ${rbd_uri}"

      # RBD targets are mapped on the host and then treated as block devices.
      v2k_rbd_ensure_image "$rbd_uri" "${size_bytes}"
      V2K_TARGET_BLOCKDEV="$(v2k_rbd_map "$rbd_uri")"
      blockdev --getsize64 "${V2K_TARGET_BLOCKDEV}" >/dev/null 2>&1 || \
        v2k_die "cannot read mapped rbd device size: ${V2K_TARGET_BLOCKDEV}"

      V2K_TARGET_CLEANUP_CMD="v2k_rbd_unmap '${V2K_TARGET_BLOCKDEV}'"
      if [[ "${register_cleanup}" -eq 1 ]]; then
        v2k_register_cleanup_cmd "${V2K_TARGET_CLEANUP_CMD}"
      fi
      ;;
    block-device)
      # direct device like /dev/sdf
      v2k_assert_block_device_safe "$path"
      V2K_TARGET_BLOCKDEV="$path"
      V2K_TARGET_CLEANUP_CMD=": # no-op"
      ;;

    *)
      v2k_die "unsupported target kind: $kind"
      ;;
  esac

  echo "$V2K_TARGET_BLOCKDEV"
}
