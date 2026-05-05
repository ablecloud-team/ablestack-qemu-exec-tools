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

n2k_file_size_bytes() {
  local path="$1"
  if stat -c '%s' "${path}" >/dev/null 2>&1; then
    stat -c '%s' "${path}"
  else
    stat -f '%z' "${path}"
  fi
}

n2k_load_source_map_json() {
  local value="${1:-}"
  [[ -n "${value}" ]] || {
    echo "sync requires --source-map-json or --source-map-file." >&2
    return 2
  }
  if [[ -f "${value}" ]]; then
    jq -c . "${value}"
  else
    printf '%s' "${value}" | jq -c .
  fi
}

n2k_source_for_disk() {
  local source_map="$1" manifest="$2" idx="$3"
  local disk_id label device_key
  disk_id="$(jq -r ".disks[${idx}].disk_id // empty" "${manifest}")"
  label="$(jq -r ".disks[${idx}].label // empty" "${manifest}")"
  device_key="$(jq -r ".disks[${idx}].device_key // empty" "${manifest}")"

  jq -r \
    --arg disk_id "${disk_id}" \
    --arg label "${label}" \
    --arg device_key "${device_key}" \
    --arg idx "${idx}" \
    '.[$disk_id] // .[$device_key] // .[$label] // .[$idx] // empty' \
    <<<"${source_map}"
}

n2k_copy_to_file_target() {
  local source_path="$1" target_path="$2" target_format="$3"
  mkdir -p "$(dirname "${target_path}")"

  case "${target_format}" in
    raw)
      if [[ -b "${source_path}" ]]; then
        dd if="${source_path}" of="${target_path}" bs=16M status=none conv=sparse
      else
        cp -f "${source_path}" "${target_path}"
      fi
      ;;
    qcow2)
      command -v qemu-img >/dev/null 2>&1 || {
        echo "qemu-img is required for qcow2 cold-export target." >&2
        return 2
      }
      qemu-img convert -p -O qcow2 "${source_path}" "${target_path}"
      ;;
    *)
      echo "Unsupported target format: ${target_format}" >&2
      return 2
      ;;
  esac
}

n2k_copy_to_block_target() {
  local source_path="$1" target_path="$2"
  [[ -b "${target_path}" ]] || {
    echo "Block target is not a block device: ${target_path}" >&2
    return 2
  }
  dd if="${source_path}" of="${target_path}" bs=16M status=none conv=fsync
}

n2k_copy_to_rbd_target() {
  local source_path="$1" target_path="$2"
  command -v qemu-img >/dev/null 2>&1 || {
    echo "qemu-img is required for rbd cold-export target." >&2
    return 2
  }
  qemu-img convert -p -O raw "${source_path}" "${target_path}"
}

n2k_transfer_cold_base_all() {
  local manifest="$1" source_map_json="$2"
  local count idx
  count="$(jq -r '.disks | length' "${manifest}")"
  [[ "${count}" -gt 0 ]] || {
    echo "Manifest has no disks. Run init with inventory first." >&2
    return 2
  }

  for ((idx=0; idx<count; idx++)); do
    n2k_transfer_cold_base_one "${manifest}" "${source_map_json}" "${idx}"
  done

  if [[ "${N2K_DRY_RUN:-0}" -ne 1 ]]; then
    n2k_manifest_phase_done "${manifest}" "base_sync"
  fi
}

n2k_transfer_cold_base_one() {
  local manifest="$1" source_map_json="$2" idx="$3"
  local disk_id source_path target_path target_format target_storage bytes_written

  disk_id="$(jq -r ".disks[${idx}].disk_id" "${manifest}")"
  source_path="$(n2k_source_for_disk "${source_map_json}" "${manifest}" "${idx}")"
  target_path="$(jq -r ".disks[${idx}].transfer.target_path" "${manifest}")"
  target_format="$(jq -r '.target.format // "qcow2"' "${manifest}")"
  target_storage="$(jq -r '.target.storage.type // "file"' "${manifest}")"

  [[ -n "${source_path}" ]] || {
    echo "Missing cold-export source path for disk: ${disk_id}" >&2
    return 2
  }
  [[ -e "${source_path}" ]] || {
    echo "Cold-export source path not found: ${source_path}" >&2
    return 2
  }
  [[ -n "${target_path}" ]] || {
    echo "Missing target path for disk: ${disk_id}" >&2
    return 2
  }

  n2k_event INFO "sync.base" "${disk_id}" "cold_export_disk_start" \
    "$(jq -nc --arg source "${source_path}" --arg target "${target_path}" '{source:$source,target:$target}')"

  if [[ "${N2K_DRY_RUN:-0}" -eq 1 ]]; then
    n2k_event INFO "sync.base" "${disk_id}" "dry_run" "{}"
    return 0
  fi

  case "${target_storage}" in
    file)
      n2k_copy_to_file_target "${source_path}" "${target_path}" "${target_format}"
      ;;
    block)
      n2k_copy_to_block_target "${source_path}" "${target_path}"
      ;;
    rbd)
      n2k_copy_to_rbd_target "${source_path}" "${target_path}"
      ;;
    *)
      echo "Unsupported target storage: ${target_storage}" >&2
      return 2
      ;;
  esac

  bytes_written="$(n2k_file_size_bytes "${source_path}")"
  n2k_manifest_set_cold_source "${manifest}" "${idx}" "${source_path}"
  n2k_manifest_mark_base_done "${manifest}" "${idx}" "${bytes_written}"
  n2k_event INFO "sync.base" "${disk_id}" "cold_export_disk_done" \
    "$(jq -nc --argjson bytes "${bytes_written}" '{bytes_written:$bytes}')"
}
