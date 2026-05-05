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

n2k_load_changed_regions_json() {
  local value="${1:-}"
  [[ -n "${value}" ]] || {
    echo "sync incr/final requires --changed-regions-json or --changed-regions-file." >&2
    return 2
  }
  if [[ -f "${value}" ]]; then
    jq -c . "${value}"
  else
    printf '%s' "${value}" | jq -c .
  fi
}

n2k_changed_regions_for_disk() {
  local changed_regions="$1" manifest="$2" idx="$3"
  local disk_id label device_key
  disk_id="$(jq -r ".disks[${idx}].disk_id // empty" "${manifest}")"
  label="$(jq -r ".disks[${idx}].label // empty" "${manifest}")"
  device_key="$(jq -r ".disks[${idx}].device_key // empty" "${manifest}")"

  jq -c \
    --arg disk_id "${disk_id}" \
    --arg label "${label}" \
    --arg device_key "${device_key}" \
    --arg idx "${idx}" \
    '
      def normalize_region:
        {
          offset: (.offset // .start // .start_offset),
          length: (.length // .len // .size)
        };

      def normalize_list($list):
        (($list // []) | map(normalize_region));

      if (.disks? | type) == "object" then
        normalize_list(.disks[$disk_id] // .disks[$device_key] // .disks[$label] // .disks[$idx])
      elif ((.disk_id? // .device_key? // .label? // "") as $one_id
        | (($one_id == $disk_id) or ($one_id == $device_key) or ($one_id == $label) or ($one_id == $idx))) then
        normalize_list(.regions // .changed_regions)
      else
        normalize_list(.[$disk_id] // .[$device_key] // .[$label] // .[$idx])
      end
    ' <<<"${changed_regions}"
}

n2k_validate_region_array() {
  local regions="$1"
  jq -e '
    type == "array" and
    all(.[]; ((.offset | type) == "number") and ((.length | type) == "number") and (.offset >= 0) and (.length > 0) and ((.offset | floor) == .offset) and ((.length | floor) == .length))
  ' <<<"${regions}" >/dev/null
}

n2k_patch_target_supported() {
  local target_storage="$1" target_format="$2" target_path="$3"
  case "${target_storage}" in
    file)
      [[ "${target_format}" == "raw" ]] || {
        echo "Incremental patch currently supports raw file targets only." >&2
        return 2
      }
      [[ -f "${target_path}" ]] || {
        echo "Target file not found: ${target_path}" >&2
        return 2
      }
      ;;
    block)
      [[ -b "${target_path}" ]] || {
        echo "Block target is not a block device: ${target_path}" >&2
        return 2
      }
      ;;
    *)
      echo "Incremental patch does not support target storage: ${target_storage}" >&2
      return 2
      ;;
  esac
}

n2k_apply_patch_region() {
  local source_path="$1" target_path="$2" offset="$3" length="$4"
  dd if="${source_path}" of="${target_path}" bs=1 skip="${offset}" seek="${offset}" count="${length}" conv=notrunc 2>/dev/null
}

n2k_transfer_patch_all() {
  local manifest="$1" phase="$2" source_map_json="$3" changed_regions_json="$4" recovery_point_id="${5:-}"
  local count idx phase_key

  case "${phase}" in
    incr) phase_key="incr_sync" ;;
    final) phase_key="final_sync" ;;
    *)
      echo "Invalid patch phase: ${phase}" >&2
      return 2
      ;;
  esac

  count="$(jq -r '.disks | length' "${manifest}")"
  [[ "${count}" -gt 0 ]] || {
    echo "Manifest has no disks. Run init with inventory first." >&2
    return 2
  }

  for ((idx=0; idx<count; idx++)); do
    n2k_transfer_patch_one "${manifest}" "${phase}" "${source_map_json}" "${changed_regions_json}" "${idx}" "${recovery_point_id}"
  done

  if [[ "${N2K_DRY_RUN:-0}" -ne 1 ]]; then
    n2k_manifest_phase_done "${manifest}" "${phase_key}"
  fi
}

n2k_transfer_patch_one() {
  local manifest="$1" phase="$2" source_map_json="$3" changed_regions_json="$4" idx="$5" recovery_point_id="${6:-}"
  local disk_id source_path target_path target_format target_storage regions region_count bytes_written phase_key
  local offset length

  case "${phase}" in
    incr) phase_key="incr_sync" ;;
    final) phase_key="final_sync" ;;
    *)
      echo "Invalid patch phase: ${phase}" >&2
      return 2
      ;;
  esac

  disk_id="$(jq -r ".disks[${idx}].disk_id" "${manifest}")"
  source_path="$(n2k_source_for_disk "${source_map_json}" "${manifest}" "${idx}")"
  target_path="$(jq -r ".disks[${idx}].transfer.target_path" "${manifest}")"
  target_format="$(jq -r '.target.format // "qcow2"' "${manifest}")"
  target_storage="$(jq -r '.target.storage.type // "file"' "${manifest}")"
  regions="$(n2k_changed_regions_for_disk "${changed_regions_json}" "${manifest}" "${idx}")"

  [[ -n "${source_path}" ]] || {
    echo "Missing patch source path for disk: ${disk_id}" >&2
    return 2
  }
  [[ -e "${source_path}" ]] || {
    echo "Patch source path not found: ${source_path}" >&2
    return 2
  }
  [[ -n "${target_path}" ]] || {
    echo "Missing target path for disk: ${disk_id}" >&2
    return 2
  }
  n2k_validate_region_array "${regions}" || {
    echo "Invalid changed regions for disk: ${disk_id}" >&2
    return 2
  }
  n2k_patch_target_supported "${target_storage}" "${target_format}" "${target_path}"

  region_count="$(jq -r 'length' <<<"${regions}")"
  bytes_written="$(jq -r 'map(.length) | add // 0' <<<"${regions}")"

  n2k_event INFO "sync.${phase}" "${disk_id}" "patch_disk_start" \
    "$(jq -nc --arg source "${source_path}" --arg target "${target_path}" --argjson regions "${region_count}" '{source:$source,target:$target,regions:$regions}')"

  if [[ "${N2K_DRY_RUN:-0}" -eq 1 ]]; then
    n2k_event INFO "sync.${phase}" "${disk_id}" "dry_run" "{}"
    return 0
  fi

  while IFS=$'\t' read -r offset length; do
    [[ -n "${offset}" && -n "${length}" ]] || continue
    n2k_apply_patch_region "${source_path}" "${target_path}" "${offset}" "${length}"
  done < <(jq -r '.[] | [(.offset | tostring), (.length | tostring)] | @tsv' <<<"${regions}")

  n2k_manifest_mark_patch_done "${manifest}" "${idx}" "${phase_key}" "${bytes_written}" "${region_count}" "${recovery_point_id}"
  n2k_event INFO "sync.${phase}" "${disk_id}" "patch_disk_done" \
    "$(jq -nc --argjson bytes "${bytes_written}" --argjson regions "${region_count}" '{bytes_written:$bytes,regions:$regions}')"
}
