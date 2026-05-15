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

n2k_storage_rbd_image_name() {
  local target_path="$1"
  [[ "${target_path}" == rbd:* ]] || {
    echo "RBD target path must start with rbd: ${target_path}" >&2
    return 2
  }
  printf '%s' "${target_path#rbd:}"
}

n2k_storage_rbd_pool_image() {
  local target_path="$1" image_name pool image
  image_name="$(n2k_storage_rbd_image_name "${target_path}")"
  pool="${image_name%%/*}"
  image="${image_name#*/}"
  [[ -n "${pool}" && -n "${image}" && "${pool}" != "${image_name}" ]] || {
    echo "RBD target path must be rbd:<pool>/<image>: ${target_path}" >&2
    return 2
  }
  printf '%s\t%s\n' "${pool}" "${image}"
}

n2k_storage_rbd_krbd_device_path() {
  local target_path="$1" pool image
  IFS=$'\t' read -r pool image < <(n2k_storage_rbd_pool_image "${target_path}")
  printf '/dev/rbd/%s/%s' "${pool}" "${image}"
}

n2k_storage_file_size_bytes() {
  local path="$1"
  if stat -c '%s' "${path}" >/dev/null 2>&1; then
    stat -c '%s' "${path}"
  else
    stat -f '%z' "${path}"
  fi
}

n2k_storage_require_command() {
  local command_name="$1" purpose="$2"
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "${command_name} is required for ${purpose}." >&2
    return 2
  }
}

n2k_storage_copy_base() {
  local source_path="$1" target_path="$2" target_storage="$3" target_format="$4"

  case "${target_storage}" in
    file)
      mkdir -p "$(dirname "${target_path}")"
      case "${target_format}" in
        raw)
          if [[ -b "${source_path}" ]]; then
            dd if="${source_path}" of="${target_path}" bs=16M status=none conv=sparse
          else
            cp --sparse=always -f "${source_path}" "${target_path}"
          fi
          ;;
        qcow2)
          n2k_storage_require_command qemu-img "qcow2 base sync"
          qemu-img convert -p -O qcow2 "${source_path}" "${target_path}"
          ;;
        *)
          echo "Unsupported file target format: ${target_format}" >&2
          return 2
          ;;
      esac
      ;;
    block)
      [[ -b "${target_path}" ]] || {
        echo "Block target is not a block device: ${target_path}" >&2
        return 2
      }
      dd if="${source_path}" of="${target_path}" bs=16M status=none conv=fsync
      ;;
    rbd)
      n2k_storage_require_command qemu-img "RBD base sync"
      [[ "${target_path}" == rbd:* ]] || {
        echo "RBD target path must start with rbd: ${target_path}" >&2
        return 2
      }
      qemu-img convert -p -O raw "${source_path}" "${target_path}"
      ;;
    *)
      echo "Unsupported target storage: ${target_storage}" >&2
      return 2
      ;;
  esac
}

n2k_storage_validate_patch_target() {
  local target_path="$1" target_storage="$2" target_format="$3"

  case "${target_storage}" in
    file)
      case "${target_format}" in
        raw)
          [[ -f "${target_path}" ]] || {
            echo "Target raw file not found: ${target_path}" >&2
            return 2
          }
          ;;
        qcow2)
          [[ -f "${target_path}" ]] || {
            echo "Target qcow2 file not found: ${target_path}" >&2
            return 2
          }
          n2k_storage_require_command qemu-nbd "qcow2 incremental patch"
          ;;
        *)
          echo "Unsupported file patch format: ${target_format}" >&2
          return 2
          ;;
      esac
      ;;
    block)
      [[ -b "${target_path}" ]] || {
        echo "Block target is not a block device: ${target_path}" >&2
        return 2
      }
      ;;
    rbd)
      [[ "${target_path}" == rbd:* ]] || {
        echo "RBD target path must start with rbd: ${target_path}" >&2
        return 2
      }
      if ! command -v rbd-nbd >/dev/null 2>&1 && ! command -v rbd >/dev/null 2>&1; then
        echo "rbd-nbd or rbd is required for RBD incremental patch." >&2
        return 2
      fi
      ;;
    *)
      echo "Incremental patch does not support target storage: ${target_storage}" >&2
      return 2
      ;;
  esac
}

n2k_storage_apply_patch_region_to_device() {
  local source_path="$1" target_path="$2" offset="$3" length="$4" region_type="${5:-regular}"
  local bs=1 skip="${offset}" seek="${offset}" count="${length}" unit

  for unit in 1048576 65536 4096 1024 512; do
    if (( offset % unit == 0 && length % unit == 0 )); then
      bs="${unit}"
      skip=$((offset / unit))
      seek=$((offset / unit))
      count=$((length / unit))
      break
    fi
  done

  case "${region_type}" in
    zero|zeros|zeroed|hole)
      dd if=/dev/zero of="${target_path}" bs="${bs}" seek="${seek}" count="${count}" conv=notrunc status=none
      ;;
    regular|"")
      dd if="${source_path}" of="${target_path}" bs="${bs}" skip="${skip}" seek="${seek}" count="${count}" conv=notrunc iflag=fullblock status=none
      ;;
    *)
      echo "Unsupported changed-region type: ${region_type}" >&2
      return 2
      ;;
  esac
}

n2k_storage_nbd_is_free() {
  local dev="$1" base pid size
  [[ -b "${dev}" ]] || return 1
  base="${dev##*/}"
  pid="$(cat "/sys/block/${base}/pid" 2>/dev/null || true)"
  [[ -z "${pid}" || "${pid}" == "0" ]] || return 1
  size="$(blockdev --getsize64 "${dev}" 2>/dev/null || echo 0)"
  [[ "${size}" == "0" ]]
}

n2k_storage_find_free_nbd() {
  local i dev
  if command -v modprobe >/dev/null 2>&1; then
    modprobe nbd max_part=8 >/dev/null 2>&1 || true
  fi
  for i in $(seq 0 127); do
    dev="/dev/nbd${i}"
    n2k_storage_nbd_is_free "${dev}" || continue
    printf '%s' "${dev}"
    return 0
  done
  echo "No free /dev/nbd device found." >&2
  return 2
}

n2k_storage_nbd_dm_dependency_patterns() {
  local dev="$1" mm major minor
  lsblk -rn -o MAJ:MIN "${dev}" 2>/dev/null | while IFS= read -r mm; do
    [[ -n "${mm}" ]] || continue
    major="${mm%%:*}"
    minor="${mm##*:}"
    [[ -n "${major}" && -n "${minor}" ]] || continue
    printf '(%s, %s)\n' "${major}" "${minor}"
  done
}

n2k_storage_remove_dm_deps_for_device() {
  local dev="$1" name deps open_count pattern depends
  local -a patterns=()

  command -v dmsetup >/dev/null 2>&1 || return 0
  mapfile -t patterns < <(n2k_storage_nbd_dm_dependency_patterns "${dev}")
  [[ "${#patterns[@]}" -gt 0 ]] || return 0

  while IFS=$' \t' read -r name _; do
    [[ -n "${name}" ]] || continue
    deps="$(dmsetup deps "${name}" 2>/dev/null || true)"
    depends=0
    for pattern in "${patterns[@]}"; do
      if printf '%s' "${deps}" | grep -Fq "${pattern}"; then
        depends=1
        break
      fi
    done
    [[ "${depends}" -eq 1 ]] || continue

    open_count="$(dmsetup info -c --noheadings -o open "${name}" 2>/dev/null | tr -dc '0-9')"
    if [[ -n "${open_count}" && "${open_count}" != "0" ]]; then
      echo "Cannot remove device-mapper node ${name}; open_count=${open_count}" >&2
      continue
    fi
    dmsetup remove "${name}" >/dev/null 2>&1 || dmsetup remove -f "${name}" >/dev/null 2>&1 || true
  done < <(dmsetup ls --noheadings 2>/dev/null || true)
}

n2k_storage_unmap_qcow2_nbd() {
  local dev="$1" tries size
  [[ -n "${dev}" ]] || return 0

  qemu-nbd --disconnect "${dev}" >/dev/null 2>&1 || true
  for tries in $(seq 1 20); do
    if n2k_storage_nbd_is_free "${dev}"; then
      return 0
    fi
    if [[ "${tries}" -eq 3 || "${tries}" -eq 8 ]]; then
      n2k_storage_remove_dm_deps_for_device "${dev}" || true
      if command -v partx >/dev/null 2>&1; then
        partx -d "${dev}" >/dev/null 2>&1 || true
      fi
      blockdev --rereadpt "${dev}" >/dev/null 2>&1 || true
      qemu-nbd --disconnect "${dev}" >/dev/null 2>&1 || true
    fi
    if command -v udevadm >/dev/null 2>&1; then
      udevadm settle >/dev/null 2>&1 || true
    fi
    sleep 0.2
  done

  size="$(blockdev --getsize64 "${dev}" 2>/dev/null || echo unknown)"
  echo "Failed to disconnect qemu-nbd device: ${dev} size=${size}" >&2
  return 4
}

n2k_storage_connect_qcow2_nbd() {
  local target_path="$1"
  local i dev err msg size tries last_error

  if command -v modprobe >/dev/null 2>&1; then
    modprobe nbd max_part=8 >/dev/null 2>&1 || true
  fi

  for i in $(seq 0 127); do
    dev="/dev/nbd${i}"
    n2k_storage_nbd_is_free "${dev}" || continue

    err="$(mktemp -t n2k-qemu-nbd-err.XXXXXX)"
    if qemu-nbd --connect="${dev}" --format=qcow2 --cache=none "${target_path}" >/dev/null 2>"${err}"; then
      rm -f "${err}" || true
      if command -v udevadm >/dev/null 2>&1; then
        udevadm settle >/dev/null 2>&1 || true
      fi
      tries=0
      while [[ "${tries}" -lt 30 ]]; do
        size="$(blockdev --getsize64 "${dev}" 2>/dev/null || echo 0)"
        if [[ "${size}" =~ ^[0-9]+$ && "${size}" -gt 0 ]]; then
          printf '%s' "${dev}"
          return 0
        fi
        tries=$((tries + 1))
        if command -v udevadm >/dev/null 2>&1; then
          udevadm settle >/dev/null 2>&1 || true
        fi
        sleep 0.2
      done
      n2k_storage_unmap_qcow2_nbd "${dev}" >/dev/null 2>&1 || true
      last_error="qemu-nbd attached ${dev}, but the block device size stayed zero"
      continue
    fi

    msg="$(tail -n 20 "${err}" 2>/dev/null || true)"
    rm -f "${err}" || true
    n2k_storage_unmap_qcow2_nbd "${dev}" >/dev/null 2>&1 || true
    last_error="dev=${dev}: ${msg}"
  done

  echo "Unable to attach qcow2 target through qemu-nbd: ${target_path}" >&2
  [[ -n "${last_error:-}" ]] && echo "${last_error}" >&2
  return 2
}

n2k_storage_patch_qcow2() {
  local source_path="$1" target_path="$2" regions="$3"
  local nbd_device offset length region_type

  n2k_storage_require_command qemu-nbd "qcow2 incremental patch"
  nbd_device="$(n2k_storage_connect_qcow2_nbd "${target_path}")"
  trap 'n2k_storage_unmap_qcow2_nbd "'"${nbd_device}"'" >/dev/null 2>&1 || true' RETURN

  while IFS=$'\t' read -r offset length region_type; do
    [[ -n "${offset}" && -n "${length}" ]] || continue
    n2k_storage_apply_patch_region_to_device "${source_path}" "${nbd_device}" "${offset}" "${length}" "${region_type:-regular}"
  done < <(jq -r '.[] | [(.offset | tostring), (.length | tostring), (.type // "regular")] | @tsv' <<<"${regions}")

  n2k_storage_unmap_qcow2_nbd "${nbd_device}"
  trap - RETURN
}

n2k_storage_map_rbd() {
  local target_path="$1" mode="${2:-${N2K_RBD_PATCH_MAP_MODE:-auto}}" image_name mapped
  image_name="$(n2k_storage_rbd_image_name "${target_path}")"
  [[ "${mode}" == "librbd" ]] && mode="auto"

  if [[ "${mode}" == "krbd" ]]; then
    n2k_storage_map_rbd_krbd "${target_path}"
    return
  fi

  if [[ "${mode}" == "auto" ]] && command -v rbd-nbd >/dev/null 2>&1; then
    mapped="$(rbd-nbd map "${image_name}")"
    printf '%s' "${mapped}"
    return 0
  fi
  if [[ "${mode}" == "auto" || "${mode}" == "krbd" ]]; then
    n2k_storage_map_rbd_krbd "${target_path}"
    return
  fi

  echo "Unsupported RBD patch map mode: ${mode}" >&2
  return 2
}

n2k_storage_map_rbd_krbd() {
  local target_path="$1" image_name expected mapped username
  n2k_storage_require_command rbd "RBD krbd map"
  image_name="$(n2k_storage_rbd_image_name "${target_path}")"
  expected="$(n2k_storage_rbd_krbd_device_path "${target_path}")"
  username="${N2K_RBD_USERNAME:-admin}"

  if [[ -b "${expected}" ]]; then
    printf '%s' "${expected}"
    return 0
  fi

  if [[ -n "${username}" ]]; then
    mapped="$(rbd --id "${username}" map "${image_name}")"
  else
    mapped="$(rbd map "${image_name}")"
  fi

  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle >/dev/null 2>&1 || true
  fi
  if [[ -b "${expected}" ]]; then
    printf '%s' "${expected}"
  else
    [[ -b "${mapped}" ]] || {
      echo "RBD krbd map did not create a block device for ${target_path}: ${mapped}" >&2
      return 2
    }
    printf '%s' "${mapped}"
  fi
}

n2k_storage_unmap_rbd() {
  local mapped_device="$1"
  if command -v rbd-nbd >/dev/null 2>&1 && [[ "${mapped_device}" == /dev/nbd* ]]; then
    rbd-nbd unmap "${mapped_device}" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v rbd >/dev/null 2>&1; then
    rbd unmap "${mapped_device}" >/dev/null 2>&1 || true
  fi
}

n2k_storage_patch_rbd() {
  local source_path="$1" target_path="$2" regions="$3"
  local mapped_device offset length region_type map_mode

  map_mode="${N2K_RBD_PATCH_MAP_MODE:-auto}"
  mapped_device="$(n2k_storage_map_rbd "${target_path}" "${map_mode}")"
  trap 'n2k_storage_unmap_rbd "'"${mapped_device}"'"' RETURN

  while IFS=$'\t' read -r offset length region_type; do
    [[ -n "${offset}" && -n "${length}" ]] || continue
    n2k_storage_apply_patch_region_to_device "${source_path}" "${mapped_device}" "${offset}" "${length}" "${region_type:-regular}"
  done < <(jq -r '.[] | [(.offset | tostring), (.length | tostring), (.type // "regular")] | @tsv' <<<"${regions}")

  n2k_storage_unmap_rbd "${mapped_device}"
  trap - RETURN
}

n2k_storage_patch_target() {
  local source_path="$1" target_path="$2" target_storage="$3" target_format="$4" regions="$5"
  local offset length region_type

  n2k_storage_validate_patch_target "${target_path}" "${target_storage}" "${target_format}"

  case "${target_storage}" in
    file)
      if [[ "${target_format}" == "qcow2" ]]; then
        n2k_storage_patch_qcow2 "${source_path}" "${target_path}" "${regions}"
      else
        while IFS=$'\t' read -r offset length region_type; do
          [[ -n "${offset}" && -n "${length}" ]] || continue
          n2k_storage_apply_patch_region_to_device "${source_path}" "${target_path}" "${offset}" "${length}" "${region_type:-regular}"
        done < <(jq -r '.[] | [(.offset | tostring), (.length | tostring), (.type // "regular")] | @tsv' <<<"${regions}")
      fi
      ;;
    block)
      while IFS=$'\t' read -r offset length region_type; do
        [[ -n "${offset}" && -n "${length}" ]] || continue
        n2k_storage_apply_patch_region_to_device "${source_path}" "${target_path}" "${offset}" "${length}" "${region_type:-regular}"
      done < <(jq -r '.[] | [(.offset | tostring), (.length | tostring), (.type // "regular")] | @tsv' <<<"${regions}")
      ;;
    rbd)
      n2k_storage_patch_rbd "${source_path}" "${target_path}" "${regions}"
      ;;
    *)
      echo "Unsupported target storage: ${target_storage}" >&2
      return 2
      ;;
  esac
}
