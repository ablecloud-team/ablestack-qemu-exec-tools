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
# ablestack_v2k - target device preparation helpers
#
# 목적:
#  - file-qcow2 / file-raw / rbd-raw 는 qemu-nbd로 /dev/nbdX에 attach
#  - block-device 는 /dev/sdX 같은 디바이스를 그대로 사용(엄격 검증)
#
# 의존:
#  - qemu-nbd, lsblk, blockdev, findmnt, flock(권장), modprobe

set -euo pipefail

# ----------------------------
# logging helpers (선택)
# ----------------------------
log()  { echo "[$(date '+%F %T')] $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ----------------------------
# lock helpers (동시 attach 방지)
# ----------------------------
_v2k_lock_fd=""
v2k_lock_global() {
  local lockfile="${1:-/var/lock/ablestack_v2k_nbd.lock}"
  mkdir -p "$(dirname "$lockfile")"
  exec { _v2k_lock_fd }>"$lockfile"
  flock -x "$_v2k_lock_fd"
}
v2k_unlock_global() {
  if [[ -n "${_v2k_lock_fd}" ]]; then
    flock -u "$_v2k_lock_fd" || true
  fi
}

# ----------------------------
# nbd helpers
# ----------------------------
v2k_modprobe_nbd() {
  # 최대 파티션 수는 환경에 맞춰 조정 가능(기본 0도 OK)
  modprobe nbd max_part=16 >/dev/null 2>&1 || true
}

v2k_find_free_nbd() {
  # /dev/nbd0..127 중 비어있는 것 찾기
  local i dev pid
  for i in $(seq 0 127); do
    dev="/dev/nbd${i}"
    [[ -b "$dev" ]] || continue
    # sysfs pid 존재하면 사용중
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
  if [[ -b "$dev" ]]; then
    qemu-nbd --disconnect "$dev" >/dev/null 2>&1 || true
  fi
}

v2k_qemu_nbd_connect() {
  local format="$1"   # qcow2|raw
  local uri="$2"      # /path/file or rbd:pool/image
  local dev="$3"      # /dev/nbdX

  # 연결
  # --cache=none: 일관성 우선(운영 정책에 따라 writeback 가능)
  # --discard=unmap: 환경에 따라(선택)
  qemu-nbd --connect="$dev" --format="$format" --cache=none "$uri" >/dev/null

  # 커널이 블록 디바이스 인식할 시간 약간 필요할 수 있음
  udevadm settle >/dev/null 2>&1 || true

  # 최소 검증: size 조회 가능해야 함
  blockdev --getsize64 "$dev" >/dev/null 2>&1 || {
    v2k_qemu_nbd_disconnect "$dev"
    die "qemu-nbd attach failed: dev=$dev format=$format uri=$uri"
  }
}

# ----------------------------
# block-device 안전 검증
# ----------------------------
v2k_assert_block_device_safe() {
  local dev="$1"

  [[ -b "$dev" ]] || die "target block device not found: $dev"

  # 1) 마운트 여부 체크(디바이스 자체 또는 자식 파티션)
  # findmnt는 직접 마운트된 대상 찾기에 좋음
  if findmnt -rn -S "$dev" >/dev/null 2>&1; then
    die "target device is mounted: $dev"
  fi

  # 2) lsblk로 자식 파티션/마운트포인트 확인
  # -n: no headings, -r: raw, -o: columns
  local lsblk_out
  lsblk_out="$(lsblk -nr -o NAME,TYPE,MOUNTPOINT "$dev" 2>/dev/null || true)"

  # mountpoint가 하나라도 있으면 실패
  if echo "$lsblk_out" | awk '$3 != "" { exit 0 } END { exit 1 }'; then
    die "target device or its partitions are mounted: $dev"
  fi

  # 3) “파티션이 존재”하면 운영 정책상 막는 것을 권장
  # (원하시면 옵션으로 완화 가능)
  if lsblk -nr -o TYPE "$dev" | grep -q '^disk$'; then
    # 자식이 있는지 확인
    if lsblk -nr -o NAME "$dev" | tail -n +2 | grep -q .; then
      die "target device has partitions; refuse for safety: $dev"
    fi
  fi

  # 4) 최소 크기 체크는 호출자가 소스 size와 비교할 것
  blockdev --getsize64 "$dev" >/dev/null 2>&1 || die "cannot read size of $dev"
}

# ----------------------------
# Public API
# ----------------------------
# prepare_target_device \
#   --kind file-qcow2|file-raw|block-device|rbd \
#   --path <file path or /dev/sdf or pool/image> \
#   [--rbd-uri rbd:pool/image] (선택; 기본 pool/image에서 생성) \
#   [--format qcow2|raw] (기본 kind에 따라 자동)
#
# 출력:
#   stdout: target_blockdev (/dev/nbdX or /dev/sdf)
#   exports:
#     V2K_TARGET_BLOCKDEV
#     V2K_TARGET_CLEANUP_CMD  (문자열; eval로 실행)
prepare_target_device() {
  local kind="" path="" format="" rbd_uri=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind)   kind="$2"; shift 2 ;;
      --path)   path="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      --rbd-uri) rbd_uri="$2"; shift 2 ;;
      *) die "prepare_target_device: unknown arg: $1" ;;
    esac
  done

  [[ -n "$kind" ]] || die "prepare_target_device: --kind is required"
  [[ -n "$path" ]] || die "prepare_target_device: --path is required"

  V2K_TARGET_BLOCKDEV=""
  V2K_TARGET_CLEANUP_CMD=""

  case "$kind" in
    file-qcow2)
      format="${format:-qcow2}"
      [[ "$format" == "qcow2" ]] || die "file-qcow2 requires format=qcow2"
      [[ -f "$path" ]] || die "qcow2 file not found: $path"

      v2k_lock_global
      v2k_modprobe_nbd
      local dev
      dev="$(v2k_find_free_nbd)" || { v2k_unlock_global; die "no free /dev/nbdX found"; }

      # 혹시 남아있을지 모르는 연결 정리
      v2k_qemu_nbd_disconnect "$dev"
      v2k_qemu_nbd_connect "qcow2" "$path" "$dev"
      v2k_unlock_global

      V2K_TARGET_BLOCKDEV="$dev"
      V2K_TARGET_CLEANUP_CMD="v2k_qemu_nbd_disconnect '$dev'"
      ;;

    file-raw)
      format="${format:-raw}"
      [[ "$format" == "raw" ]] || die "file-raw requires format=raw"
      [[ -f "$path" ]] || die "raw file not found: $path"

      v2k_lock_global
      v2k_modprobe_nbd
      local dev
      dev="$(v2k_find_free_nbd)" || { v2k_unlock_global; die "no free /dev/nbdX found"; }

      v2k_qemu_nbd_disconnect "$dev"
      v2k_qemu_nbd_connect "raw" "$path" "$dev"
      v2k_unlock_global

      V2K_TARGET_BLOCKDEV="$dev"
      V2K_TARGET_CLEANUP_CMD="v2k_qemu_nbd_disconnect '$dev'"
      ;;

    block-device)
      # 디바이스 직접 사용 (/dev/sdf)
      local dev="$path"
      v2k_assert_block_device_safe "$dev"
      V2K_TARGET_BLOCKDEV="$dev"
      V2K_TARGET_CLEANUP_CMD=": # no-op"
      ;;

    rbd)
      # path는 보통 pool/image
      format="${format:-raw}"
      [[ "$format" == "raw" ]] || die "rbd requires format=raw"

      if [[ -n "$rbd_uri" ]]; then
        :
      else
        rbd_uri="rbd:${path}"
      fi

      v2k_lock_global
      v2k_modprobe_nbd
      local dev
      dev="$(v2k_find_free_nbd)" || { v2k_unlock_global; die "no free /dev/nbdX found"; }

      v2k_qemu_nbd_disconnect "$dev"
      v2k_qemu_nbd_connect "raw" "$rbd_uri" "$dev"
      v2k_unlock_global

      V2K_TARGET_BLOCKDEV="$dev"
      V2K_TARGET_CLEANUP_CMD="v2k_qemu_nbd_disconnect '$dev'"
      ;;

    *)
      die "unsupported target kind: $kind"
      ;;
  esac

  echo "$V2K_TARGET_BLOCKDEV"
}
