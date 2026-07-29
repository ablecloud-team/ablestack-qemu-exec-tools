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

n2k_storage_rbd_sparse_enabled() {
  case "${N2K_RBD_SPARSE:-1}" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
    *) return 0 ;;
  esac
}

n2k_storage_rbd_sparse_size() {
  printf '%s' "${N2K_RBD_SPARSE_SIZE:-4M}"
}

n2k_storage_source_virtual_size_bytes() {
  local path="$1" size
  if [[ -b "${path}" ]]; then
    blockdev --getsize64 "${path}"
    return
  fi
  if command -v qemu-img >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    size="$(qemu-img info --output=json "${path}" 2>/dev/null | jq -r '."virtual-size" // .virtual_size // empty' 2>/dev/null || true)"
    if [[ "${size}" =~ ^[0-9]+$ && "${size}" -gt 0 ]]; then
      printf '%s' "${size}"
      return
    fi
  fi
  n2k_storage_file_size_bytes "${path}"
}

n2k_storage_rbd_current_size_bytes() {
  local target_path="$1" spec size
  spec="$(n2k_storage_rbd_image_name "${target_path}")"
  command -v rbd >/dev/null 2>&1 || return 1
  if ! rbd info "${spec}" >/dev/null 2>&1; then
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    size="$(rbd info --format json "${spec}" 2>/dev/null | jq -r '.size // .size_bytes // empty' 2>/dev/null || true)"
    if [[ "${size}" =~ ^[0-9]+$ && "${size}" -gt 0 ]]; then
      printf '%s' "${size}"
      return 0
    fi
  fi
  rbd info "${spec}" 2>/dev/null | awk '/^ *size / {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}'
}

n2k_storage_rbd_exists() {
  local target_path="$1" spec
  spec="$(n2k_storage_rbd_image_name "${target_path}")"
  command -v rbd >/dev/null 2>&1 || return 1
  rbd info "${spec}" >/dev/null 2>&1
}

n2k_storage_rbd_ensure_image() {
  local target_path="$1" size_bytes="$2" spec cur size_mb
  spec="$(n2k_storage_rbd_image_name "${target_path}")"
  [[ "${size_bytes}" =~ ^[0-9]+$ && "${size_bytes}" -gt 0 ]] || {
    echo "RBD ensure requires a positive size for ${target_path}: ${size_bytes}" >&2
    return 2
  }
  command -v rbd >/dev/null 2>&1 || return 1

  size_mb="$(( (size_bytes + 1024*1024 - 1) / (1024*1024) ))"
  [[ "${size_mb}" -gt 0 ]] || size_mb=1

  if ! rbd info "${spec}" >/dev/null 2>&1; then
    rbd create "${spec}" --size "${size_mb}"
    return
  fi

  cur="$(n2k_storage_rbd_current_size_bytes "${target_path}" || true)"
  if [[ "${cur}" =~ ^[0-9]+$ && "${cur}" -lt "${size_bytes}" ]]; then
    rbd resize "${spec}" --size "${size_mb}"
  fi
}

n2k_storage_rbd_staging_path() {
  local target_path="$1" run_id="$2" idx="$3" attempt="$4"
  local prefix image safe_run

  [[ "${target_path}" == rbd:*/* ]] || return 2
  prefix="${target_path%/*}"
  image="${target_path##*/}"
  safe_run="$(printf '%s' "${run_id}" | tr -c 'A-Za-z0-9_.-' '_')"
  [[ -n "${safe_run}" ]] || safe_run="unknown"
  printf '%s/%s.n2k-stage-%s-d%s-p%s-a%s' \
    "${prefix}" "${image}" "${safe_run}" "${idx}" "$$" "${attempt}"
}

n2k_storage_rbd_remove_staging() {
  local staging_path="$1" spec
  [[ "${staging_path}" == rbd:*/*.n2k-stage-* ]] || return 2
  spec="$(n2k_storage_rbd_image_name "${staging_path}")"
  command -v rbd >/dev/null 2>&1 || return 1
  if rbd info "${spec}" >/dev/null 2>&1; then
    rbd rm "${spec}" >/dev/null
  fi
}

n2k_storage_rbd_publish_staging() {
  local staging_path="$1" target_path="$2" staging_spec target_spec
  [[ "${staging_path}" == rbd:*/*.n2k-stage-* ]] || return 2
  [[ "${target_path}" == rbd:*/* ]] || return 2
  staging_spec="$(n2k_storage_rbd_image_name "${staging_path}")"
  target_spec="$(n2k_storage_rbd_image_name "${target_path}")"
  command -v rbd >/dev/null 2>&1 || return 1
  rbd info "${staging_spec}" >/dev/null 2>&1 || return 1
  if rbd info "${target_spec}" >/dev/null 2>&1; then
    return 3
  fi
  rbd mv "${staging_spec}" "${target_spec}" >/dev/null
}

n2k_storage_rbd_sparsify() {
  local target_path="$1" needed="${2:-0}" mode="${N2K_RBD_SPARSIFY_AFTER:-auto}" spec
  case "${mode}" in
    0|false|FALSE|no|NO|off|OFF) return 0 ;;
    auto|AUTO) [[ "${needed}" == "1" ]] || return 0 ;;
  esac
  command -v rbd >/dev/null 2>&1 || return 0
  spec="$(n2k_storage_rbd_image_name "${target_path}")"
  rbd sparsify "${spec}" --sparse-size "$(n2k_storage_rbd_sparse_size)" >/dev/null 2>&1 || true
}

n2k_storage_detect_image_format() {
  local path="$1" fmt
  if [[ -b "${path}" ]]; then
    printf 'raw'
    return 0
  fi

  n2k_storage_require_command qemu-img "image format detection"
  fmt="$(qemu-img info --output=json "${path}" 2>/dev/null | jq -r '.format // empty' 2>/dev/null || true)"
  [[ -n "${fmt}" ]] || fmt="raw"
  printf '%s' "${fmt}"
}

n2k_storage_target_size_bytes() {
  local target_path="$1" target_storage="$2" target_format="$3" size

  case "${target_storage}" in
    file)
      [[ -f "${target_path}" ]] || return 1
      if [[ "${target_format}" == "qcow2" ]]; then
        n2k_storage_require_command qemu-img "qcow2 target size validation"
        size="$(qemu-img info --output=json "${target_path}" 2>/dev/null \
          | jq -r '."virtual-size" // .virtual_size // empty' 2>/dev/null || true)"
        [[ "${size}" =~ ^[0-9]+$ && "${size}" -gt 0 ]] || return 1
        printf '%s' "${size}"
      else
        n2k_storage_file_size_bytes "${target_path}"
      fi
      ;;
    block)
      [[ -b "${target_path}" ]] || return 1
      blockdev --getsize64 "${target_path}"
      ;;
    rbd)
      n2k_storage_rbd_current_size_bytes "${target_path}"
      ;;
    *)
      return 2
      ;;
  esac
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
      local convert_rc=0
      n2k_storage_require_command qemu-img "RBD base sync"
      [[ "${target_path}" == rbd:* ]] || {
        echo "RBD target path must start with rbd: ${target_path}" >&2
        return 2
      }
      if n2k_storage_rbd_sparse_enabled; then
        local source_size sparse_size rbd_preexisting=0
        source_size="$(n2k_storage_source_virtual_size_bytes "${source_path}")"
        sparse_size="$(n2k_storage_rbd_sparse_size)"
        if command -v rbd >/dev/null 2>&1; then
          n2k_storage_rbd_exists "${target_path}" && rbd_preexisting=1
        fi
        if command -v rbd >/dev/null 2>&1 && n2k_storage_rbd_ensure_image "${target_path}" "${source_size}"; then
          if [[ "${rbd_preexisting}" -eq 0 ]]; then
            qemu-img convert -p -n -S "${sparse_size}" -O raw "${source_path}" "${target_path}" || convert_rc=$?
          else
            qemu-img convert -p -S "${sparse_size}" -O raw "${source_path}" "${target_path}" || convert_rc=$?
          fi
        else
          qemu-img convert -p -S "${sparse_size}" -O raw "${source_path}" "${target_path}" || convert_rc=$?
        fi
        [[ "${convert_rc}" -eq 0 ]] || return "${convert_rc}"
        n2k_storage_rbd_sparsify "${target_path}" 0
      else
        qemu-img convert -p -O raw "${source_path}" "${target_path}" || convert_rc=$?
        [[ "${convert_rc}" -eq 0 ]] || return "${convert_rc}"
      fi
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
          n2k_storage_require_command qemu-io "qcow2 incremental patch"
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

n2k_storage_connect_readonly_nbd() {
  local source_path="$1" image_format="${2:-}"
  local i dev err msg size tries last_error

  n2k_storage_require_command qemu-nbd "read-only image source mapping"
  [[ -n "${image_format}" ]] || image_format="$(n2k_storage_detect_image_format "${source_path}")"

  if command -v modprobe >/dev/null 2>&1; then
    modprobe nbd max_part=8 >/dev/null 2>&1 || true
  fi

  for i in $(seq 0 127); do
    dev="/dev/nbd${i}"
    n2k_storage_nbd_is_free "${dev}" || continue

    err="$(mktemp -t n2k-src-qemu-nbd-err.XXXXXX)"
    if qemu-nbd --read-only --connect="${dev}" --format="${image_format}" --cache=none "${source_path}" >/dev/null 2>"${err}"; then
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

  echo "Unable to attach read-only image source through qemu-nbd: ${source_path}" >&2
  [[ -n "${last_error:-}" ]] && echo "${last_error}" >&2
  return 2
}

n2k_storage_copy_region_to_file() {
  local source_path="$1" output_file="$2" offset="$3" length="$4"
  local bs=1 skip="${offset}" count="${length}" unit

  for unit in 1048576 65536 4096 1024 512; do
    if (( offset % unit == 0 && length % unit == 0 )); then
      bs="${unit}"
      skip=$((offset / unit))
      count=$((length / unit))
      break
    fi
  done

  dd if="${source_path}" of="${output_file}" bs="${bs}" skip="${skip}" count="${count}" conv=notrunc iflag=fullblock status=none
}

n2k_storage_patch_qcow2() {
  local source_path="$1" target_path="$2" regions="$3"
  local offset length region_type chunk_file

  n2k_storage_require_command qemu-io "qcow2 incremental patch"

  while IFS=$'\t' read -r offset length region_type; do
    [[ -n "${offset}" && -n "${length}" ]] || continue
    case "${region_type:-regular}" in
      zero|zeros|zeroed|hole)
        qemu-io -f qcow2 -c "write -q -z ${offset} ${length}" "${target_path}" >/dev/null
        ;;
      regular|"")
        chunk_file="$(mktemp -t n2k-qcow2-patch-region.XXXXXX)"
        if ! n2k_storage_copy_region_to_file "${source_path}" "${chunk_file}" "${offset}" "${length}"; then
          rm -f "${chunk_file}"
          return 2
        fi
        if ! qemu-io -f qcow2 -c "write -q -s ${chunk_file} ${offset} ${length}" "${target_path}" >/dev/null; then
          rm -f "${chunk_file}"
          return 2
        fi
        rm -f "${chunk_file}"
        ;;
      *)
        echo "Unsupported changed-region type: ${region_type}" >&2
        return 2
        ;;
    esac
  done < <(jq -r '.[] | [(.offset | tostring), (.length | tostring), (.type // "regular")] | @tsv' <<<"${regions}")
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

n2k_storage_discard_rbd_region() {
  local target_path="$1" mapped_device="$2" offset="$3" length="$4"
  n2k_storage_rbd_sparse_enabled || return 1

  if command -v qemu-io >/dev/null 2>&1; then
    if qemu-io -f raw -c "discard ${offset} ${length}" "${target_path}" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if [[ -b "${mapped_device}" ]] && command -v blkdiscard >/dev/null 2>&1; then
    if blkdiscard -o "${offset}" -l "${length}" "${mapped_device}" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

n2k_storage_patch_rbd() {
  local source_path="$1" target_path="$2" regions="$3"
  local mapped_device offset length region_type map_mode discard_fallbacks=0 discards=0

  map_mode="${N2K_RBD_PATCH_MAP_MODE:-auto}"
  mapped_device="$(n2k_storage_map_rbd "${target_path}" "${map_mode}")"
  trap 'n2k_storage_unmap_rbd "'"${mapped_device}"'"' RETURN

  while IFS=$'\t' read -r offset length region_type; do
    [[ -n "${offset}" && -n "${length}" ]] || continue
    case "${region_type:-regular}" in
      zero|zeros|zeroed|hole)
        if n2k_storage_discard_rbd_region "${target_path}" "${mapped_device}" "${offset}" "${length}"; then
          discards=$((discards + 1))
          continue
        fi
        discard_fallbacks=$((discard_fallbacks + 1))
        ;;
    esac
    n2k_storage_apply_patch_region_to_device "${source_path}" "${mapped_device}" "${offset}" "${length}" "${region_type:-regular}"
  done < <(jq -r '.[] | [(.offset | tostring), (.length | tostring), (.type // "regular")] | @tsv' <<<"${regions}")

  if [[ "${discards}" -gt 0 || "${discard_fallbacks}" -gt 0 ]]; then
    echo "RBD sparse patch summary: discards=${discards} zero_write_fallbacks=${discard_fallbacks}" >&2
  fi

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
