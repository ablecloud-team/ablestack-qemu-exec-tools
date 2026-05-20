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
  local disk_id disk_label device_key
  disk_id="$(jq -r ".disks[${idx}].disk_id // empty" "${manifest}")"
  disk_label="$(jq -r ".disks[${idx}].label // empty" "${manifest}")"
  device_key="$(jq -r ".disks[${idx}].device_key // empty" "${manifest}")"

  jq -c \
    --arg disk_id "${disk_id}" \
    --arg disk_label "${disk_label}" \
    --arg device_key "${device_key}" \
    --arg idx "${idx}" \
    '
      def normalize_region:
        {
          offset: (.offset // .start // .start_offset),
          length: (.length // .len // .size),
          type: ((.type // .region_type // "regular") | ascii_downcase)
        };

      def normalize_list($list):
        (($list // []) | map(normalize_region));

      if (.disks? | type) == "object" then
        normalize_list(.disks[$disk_id] // .disks[$device_key] // .disks[$disk_label] // .disks[$idx])
      elif ((.disk_id? // .device_key? // .label? // "") as $one_id
        | (($one_id == $disk_id) or ($one_id == $device_key) or ($one_id == $disk_label) or ($one_id == $idx))) then
        normalize_list(.regions // .changed_regions)
      elif (.region_list? | type) == "array" then
        normalize_list(.region_list)
      else
        normalize_list(.[$disk_id] // .[$device_key] // .[$disk_label] // .[$idx])
      end
    ' <<<"${changed_regions}"
}

n2k_validate_region_array() {
  local regions="$1"
  jq -e '
    type == "array" and
    all(.[]; ((.offset | type) == "number") and ((.length | type) == "number") and (.offset >= 0) and (.length > 0) and ((.offset | floor) == .offset) and ((.length | floor) == .length) and (((.type // "regular") | IN("regular","zero","zeros","zeroed","hole"))))
  ' <<<"${regions}" >/dev/null
}

n2k_patch_source_is_nutanix_v3_data_uri() {
  [[ "${1:-}" == nutanix-v3-data://* ]]
}

n2k_patch_source_nutanix_v3_data_uri_parts() {
  local uri="$1" rest vm_uuid disk_uuid extra
  n2k_patch_source_is_nutanix_v3_data_uri "${uri}" || {
    echo "Invalid Nutanix v3 data URI: ${uri}" >&2
    return 2
  }

  rest="${uri#nutanix-v3-data://}"
  rest="${rest%%\?*}"
  IFS='/' read -r vm_uuid disk_uuid extra <<<"${rest}"
  [[ -n "${vm_uuid}" && -n "${disk_uuid}" && -z "${extra:-}" ]] || {
    echo "Nutanix v3 data URI must be nutanix-v3-data://<vm_uuid>/<disk_uuid>" >&2
    return 2
  }

  jq -nc --arg vm_uuid "${vm_uuid}" --arg disk_uuid "${disk_uuid}" \
    '{vm_uuid:$vm_uuid,disk_uuid:$disk_uuid}'
}

n2k_patch_source_safe_name() {
  local raw="$1"
  printf '%s' "${raw}" | tr -c 'A-Za-z0-9_.-' '_'
}

n2k_patch_source_require_nutanix_v3_data_env() {
  [[ -n "${N2K_NUTANIX_PC:-}" ]] || {
    echo "Nutanix v3 data source requires --pc or manifest source pc." >&2
    return 2
  }
  [[ -n "${N2K_NUTANIX_USERNAME:-}" ]] || {
    echo "Nutanix v3 data source requires --username or --cred-file." >&2
    return 2
  }
  [[ -n "${N2K_NUTANIX_PASSWORD:-}" ]] || {
    echo "Nutanix v3 data source requires --password or --cred-file." >&2
    return 2
  }
  n2k_storage_require_command base64 "Nutanix v3 data source decode"
}

n2k_patch_source_download_nutanix_v3_data_chunk() {
  local vm_uuid="$1" vm_disk_uuid="$2" offset="$3" length="$4" output_file="$5"
  local encoded_file http_code api_error rc decoded_size offset_max length_max
  encoded_file="$(mktemp)"
  offset_max="${N2K_NUTANIX_DATA_OFFSET_MAX:-16777216}"
  length_max="${N2K_NUTANIX_DATA_LENGTH_MAX:-16777216}"

  if [[ "${offset}" -gt "${offset_max}" ]]; then
    echo "Nutanix v3 disk data API offset ${offset} exceeds observed limit ${offset_max}; use a snapshot clone/proxy source for full-disk reads." >&2
    rm -f "${encoded_file}"
    return 2
  fi
  if [[ "${length}" -gt "${length_max}" ]]; then
    echo "Nutanix v3 disk data API length ${length} exceeds observed limit ${length_max}." >&2
    rm -f "${encoded_file}"
    return 2
  fi

  rc=0
  n2k_nutanix_api_get_to_file \
    "${N2K_NUTANIX_PC}" \
    "/api/nutanix/v3/vms/${vm_uuid}/vm_disk/${vm_disk_uuid}/data?offset=${offset}&length=${length}" \
    "${N2K_NUTANIX_USERNAME}" \
    "${N2K_NUTANIX_PASSWORD}" \
    "${N2K_NUTANIX_INSECURE:-1}" \
    "${encoded_file}" \
    http_code \
    api_error || rc=$?

  if [[ "${rc}" -ne 0 || ! "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
    echo "Failed to read Nutanix v3 disk data (http=${http_code:-000}, rc=${rc}): ${api_error}" >&2
    rm -f "${encoded_file}"
    return 2
  fi

  if ! base64 --decode "${encoded_file}" >"${output_file}" 2>/dev/null; then
    echo "Failed to decode Nutanix v3 disk data response." >&2
    rm -f "${encoded_file}" "${output_file}"
    return 2
  fi
  rm -f "${encoded_file}"

  decoded_size="$(n2k_storage_file_size_bytes "${output_file}")"
  if [[ "${decoded_size}" -ne "${length}" ]]; then
    echo "Nutanix v3 disk data returned ${decoded_size} bytes; expected ${length}." >&2
    rm -f "${output_file}"
    return 2
  fi
}

n2k_patch_source_materialize_nutanix_v3_data() {
  local source_uri="$1" regions="$2" disk_id="$3" phase="$4"
  local uri_json vm_uuid vm_disk_uuid cache_dir safe_disk out_file max_end chunk_max
  local offset length region_type cursor remaining chunk_len chunk_file

  n2k_patch_source_require_nutanix_v3_data_env
  uri_json="$(n2k_patch_source_nutanix_v3_data_uri_parts "${source_uri}")"
  vm_uuid="$(jq -r '.vm_uuid' <<<"${uri_json}")"
  vm_disk_uuid="$(jq -r '.disk_uuid' <<<"${uri_json}")"
  cache_dir="${N2K_WORKDIR:-$(pwd)}/source-cache"
  safe_disk="$(n2k_patch_source_safe_name "${disk_id}")"
  out_file="${cache_dir}/${phase}-${safe_disk}.raw"
  max_end="$(jq -r 'map(.offset + .length) | max // 0' <<<"${regions}")"
  chunk_max="${N2K_NUTANIX_DATA_CHUNK_MAX:-16777216}"

  mkdir -p "${cache_dir}"
  rm -f "${out_file}"
  truncate -s "${max_end}" "${out_file}"

  while IFS=$'\t' read -r offset length region_type; do
    [[ -n "${offset}" && -n "${length}" ]] || continue
    case "${region_type:-regular}" in
      regular|"") ;;
      zero|zeros|zeroed|hole) continue ;;
      *)
        echo "Unsupported changed-region type: ${region_type}" >&2
        return 2
        ;;
    esac

    cursor="${offset}"
    remaining="${length}"
    while [[ "${remaining}" -gt 0 ]]; do
      chunk_len="${remaining}"
      if [[ "${chunk_len}" -gt "${chunk_max}" ]]; then
        chunk_len="${chunk_max}"
      fi
      chunk_file="$(mktemp)"
      n2k_patch_source_download_nutanix_v3_data_chunk "${vm_uuid}" "${vm_disk_uuid}" "${cursor}" "${chunk_len}" "${chunk_file}"
      dd if="${chunk_file}" of="${out_file}" bs=1 seek="${cursor}" conv=notrunc 2>/dev/null
      rm -f "${chunk_file}"
      cursor=$((cursor + chunk_len))
      remaining=$((remaining - chunk_len))
    done
  done < <(jq -r '.[] | [(.offset | tostring), (.length | tostring), (.type // "regular")] | @tsv' <<<"${regions}")

  printf '%s' "${out_file}"
}

n2k_patch_source_materialize_image_regions() {
  local source_path="$1" regions="$2" disk_id="$3" phase="$4"
  local cache_dir safe_disk out_file max_end image_format source_device
  local offset length region_type rc=0

  n2k_storage_require_command qemu-nbd "image patch source materialization"
  cache_dir="${N2K_WORKDIR:-$(pwd)}/source-cache"
  safe_disk="$(n2k_patch_source_safe_name "${disk_id}")"
  out_file="${cache_dir}/${phase}-${safe_disk}.raw"
  max_end="$(jq -r 'map(.offset + .length) | max // 0' <<<"${regions}")"

  mkdir -p "${cache_dir}"
  rm -f "${out_file}"
  truncate -s "${max_end}" "${out_file}"

  image_format="$(n2k_storage_detect_image_format "${source_path}")"
  source_device="$(n2k_storage_connect_readonly_nbd "${source_path}" "${image_format}")"

  while IFS=$'\t' read -r offset length region_type; do
    [[ -n "${offset}" && -n "${length}" ]] || continue
    case "${region_type:-regular}" in
      regular|"")
        if ! n2k_storage_apply_patch_region_to_device "${source_device}" "${out_file}" "${offset}" "${length}" "${region_type:-regular}"; then
          rc=2
          break
        fi
        ;;
      zero|zeros|zeroed|hole)
        ;;
      *)
        echo "Unsupported changed-region type: ${region_type}" >&2
        rc=2
        break
        ;;
    esac
  done < <(jq -r '.[] | [(.offset | tostring), (.length | tostring), (.type // "regular")] | @tsv' <<<"${regions}")

  n2k_storage_unmap_qcow2_nbd "${source_device}"
  [[ "${rc}" -eq 0 ]] || return "${rc}"
  printf '%s' "${out_file}"
}

n2k_patch_source_prepare() {
  local source_path="$1" regions="$2" disk_id="$3" phase="$4"
  if n2k_patch_source_is_nutanix_v3_data_uri "${source_path}"; then
    n2k_patch_source_materialize_nutanix_v3_data "${source_path}" "${regions}" "${disk_id}" "${phase}"
  elif n2k_source_is_nutanix_nfs_uri "${source_path}"; then
    source_path="$(n2k_source_prepare_file_path "${source_path}")"
    n2k_patch_source_materialize_image_regions "${source_path}" "${regions}" "${disk_id}" "${phase}"
  else
    [[ -e "${source_path}" ]] || {
      echo "Patch source path not found: ${source_path}" >&2
      return 2
    }
    printf '%s' "${source_path}"
  fi
}

n2k_transfer_patch_all() {
  local manifest="$1" phase="$2" source_map_json="$3" changed_regions_json="$4" recovery_point_id="${5:-}"
  local count idx phase_key regions region_count bytes_written total_regions=0 total_bytes=0

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

  trap 'n2k_source_cleanup_nfs_mounts' RETURN
  for ((idx=0; idx<count; idx++)); do
    regions="$(n2k_changed_regions_for_disk "${changed_regions_json}" "${manifest}" "${idx}")"
    n2k_validate_region_array "${regions}" || {
      echo "Invalid changed regions for disk index: ${idx}" >&2
      return 2
    }
    region_count="$(jq -r 'length' <<<"${regions}")"
    bytes_written="$(jq -r 'map(.length) | add // 0' <<<"${regions}")"
    total_regions=$((total_regions + region_count))
    total_bytes=$((total_bytes + bytes_written))
    n2k_transfer_patch_one "${manifest}" "${phase}" "${source_map_json}" "${changed_regions_json}" "${idx}" "${recovery_point_id}"
  done

  if [[ "${N2K_DRY_RUN:-0}" -ne 1 ]]; then
    n2k_manifest_record_sync_summary "${manifest}" "${phase_key}" "${total_bytes}" "${total_regions}" "${recovery_point_id}"
    n2k_manifest_phase_done "${manifest}" "${phase_key}"
  fi
  n2k_source_cleanup_nfs_mounts
  trap - RETURN
}

n2k_transfer_patch_one() {
  local manifest="$1" phase="$2" source_map_json="$3" changed_regions_json="$4" idx="$5" recovery_point_id="${6:-}"
  local disk_id source_path patch_source_path target_path target_format target_storage rbd_access_mode regions region_count bytes_written phase_key

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
  rbd_access_mode="$(jq -r '.target.storage.rbd_access_mode // "librbd"' "${manifest}")"
  regions="$(n2k_changed_regions_for_disk "${changed_regions_json}" "${manifest}" "${idx}")"

  [[ -n "${source_path}" ]] || {
    echo "Missing patch source path for disk: ${disk_id}" >&2
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

  region_count="$(jq -r 'length' <<<"${regions}")"
  bytes_written="$(jq -r 'map(.length) | add // 0' <<<"${regions}")"

  n2k_event INFO "sync.${phase}" "${disk_id}" "patch_disk_start" \
    "$(jq -nc --arg source "${source_path}" --arg target "${target_path}" --argjson regions "${region_count}" '{source:$source,target:$target,regions:$regions}')"

  if [[ "${N2K_DRY_RUN:-0}" -eq 1 ]]; then
    n2k_event INFO "sync.${phase}" "${disk_id}" "dry_run" "{}"
    return 0
  fi

  patch_source_path="$(n2k_patch_source_prepare "${source_path}" "${regions}" "${disk_id}" "${phase}")"
  if [[ "${target_storage}" == "rbd" && "${rbd_access_mode}" == "krbd" ]]; then
    N2K_RBD_PATCH_MAP_MODE="krbd" n2k_storage_patch_target "${patch_source_path}" "${target_path}" "${target_storage}" "${target_format}" "${regions}"
  else
    n2k_storage_patch_target "${patch_source_path}" "${target_path}" "${target_storage}" "${target_format}" "${regions}"
  fi

  n2k_manifest_mark_patch_done "${manifest}" "${idx}" "${phase_key}" "${bytes_written}" "${region_count}" "${recovery_point_id}"
  n2k_event INFO "sync.${phase}" "${disk_id}" "patch_disk_done" \
    "$(jq -nc --argjson bytes "${bytes_written}" --argjson regions "${region_count}" '{bytes_written:$bytes,regions:$regions}')"
}
