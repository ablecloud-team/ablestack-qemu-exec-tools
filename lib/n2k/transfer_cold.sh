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
  n2k_storage_file_size_bytes "${path}"
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
  local disk_id disk_label device_key
  disk_id="$(jq -r ".disks[${idx}].disk_id // empty" "${manifest}")"
  disk_label="$(jq -r ".disks[${idx}].label // empty" "${manifest}")"
  device_key="$(jq -r ".disks[${idx}].device_key // empty" "${manifest}")"

  jq -r \
    --arg disk_id "${disk_id}" \
    --arg disk_label "${disk_label}" \
    --arg device_key "${device_key}" \
    --arg idx "${idx}" \
    '.[$disk_id] // .[$device_key] // .[$disk_label] // .[$idx] // empty' \
    <<<"${source_map}"
}

n2k_source_is_nutanix_nfs_uri() {
  [[ "${1:-}" == nutanix-nfs://* ]]
}

n2k_source_nfs_host_from_endpoint() {
  local host="$1"
  host="${host#http://}"
  host="${host#https://}"
  host="${host%%/*}"
  if [[ "${host}" == \[*\]* ]]; then
    host="${host#\[}"
    host="${host%%\]*}"
  elif [[ "${host}" == *:* ]]; then
    host="${host%%:*}"
  fi
  printf '%s' "${host}"
}

n2k_source_nfs_uri_from_path() {
  local host="$1" snapshot_path="$2"
  host="$(n2k_source_nfs_host_from_endpoint "${host}")"
  [[ -n "${host}" ]] || {
    echo "NFS host is required for Nutanix NFS source paths." >&2
    return 2
  }
  [[ "${snapshot_path}" == /* ]] || {
    echo "Nutanix NFS source path must start with /: ${snapshot_path}" >&2
    return 2
  }
  printf 'nutanix-nfs://%s%s' "${host}" "${snapshot_path}"
}

n2k_source_nfs_uri_parts() {
  local uri="$1" rest host path container rel
  n2k_source_is_nutanix_nfs_uri "${uri}" || {
    echo "Invalid Nutanix NFS source URI: ${uri}" >&2
    return 2
  }

  rest="${uri#nutanix-nfs://}"
  host="${rest%%/*}"
  path="/${rest#*/}"
  container="${path#/}"
  container="${container%%/*}"
  rel="${path#/"${container}"/}"
  [[ -n "${host}" && -n "${container}" && "${rel}" != "${path}" ]] || {
    echo "Nutanix NFS URI must be nutanix-nfs://<host>/<container>/<path>" >&2
    return 2
  }

  jq -nc \
    --arg host "${host}" \
    --arg path "${path}" \
    --arg container "${container}" \
    --arg rel "${rel}" \
    '{host:$host,path:$path,container:$container,rel:$rel}'
}

n2k_source_nfs_safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

n2k_source_nfs_mounts_file() {
  printf '%s' "${N2K_SOURCE_NFS_MOUNTS_FILE:-${N2K_WORKDIR:-/tmp}/n2k-nfs-mounts.list}"
}

n2k_source_nfs_mount_uri() {
  local uri="$1" parts host container rel mount_root mount_point mounts_file mounted_here=0
  local route_source="" mount_output="" mount_status=0
  parts="$(n2k_source_nfs_uri_parts "${uri}")"
  host="$(jq -r '.host' <<<"${parts}")"
  container="$(jq -r '.container' <<<"${parts}")"
  rel="$(jq -r '.rel' <<<"${parts}")"
  mount_root="${N2K_NUTANIX_NFS_MOUNT_ROOT:-/mnt/ablestack-n2k-nfs}"
  mount_point="${mount_root}/$(n2k_source_nfs_safe_name "${host}")/$(n2k_source_nfs_safe_name "${container}")"
  mounts_file="$(n2k_source_nfs_mounts_file)"

  n2k_storage_require_command mount "Nutanix NFS source mount"
  n2k_storage_require_command mountpoint "Nutanix NFS source mount check"

  mkdir -p "${mount_point}" "$(dirname "${mounts_file}")"
  if ! mountpoint -q "${mount_point}"; then
    route_source="$(ip route get "${host}" 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' | head -1 || true)"
    mount_output="$(mount -t nfs -o "${N2K_NUTANIX_NFS_OPTIONS:-ro,vers=3,nolock,proto=tcp}" "${host}:/${container}" "${mount_point}" 2>&1)" || mount_status=$?
    if [[ "${mount_status}" -ne 0 ]]; then
      cat >&2 <<EOF
Nutanix NFS export mount failed.
Source endpoint: ${host}
Client source IP: ${route_source:-unknown}
Container: /${container}
Mount point: ${mount_point}
NFS options: ${N2K_NUTANIX_NFS_OPTIONS:-ro,vers=3,nolock,proto=tcp}
Error: ${mount_output:-mount exited with status ${mount_status}}
Action: add the client source IP or its subnet to the Nutanix storage container filesystem allowlist/whitelist, and confirm the export can be mounted from the conversion host.
EOF
      return "${mount_status}"
    fi
    mounted_here=1
  fi
  if [[ "${mounted_here}" -eq 1 ]]; then
    printf '%s\n' "${mount_point}" >>"${mounts_file}"
  fi
  printf '%s/%s' "${mount_point}" "${rel}"
}

n2k_source_cleanup_nfs_mounts() {
  local mounts_file mount_point
  mounts_file="$(n2k_source_nfs_mounts_file)"
  [[ -f "${mounts_file}" ]] || return 0
  tac "${mounts_file}" 2>/dev/null | awk '!seen[$0]++' | while IFS= read -r mount_point; do
    [[ -n "${mount_point}" ]] || continue
    if mountpoint -q "${mount_point}"; then
      umount "${mount_point}" >/dev/null 2>&1 || true
    fi
  done
  rm -f "${mounts_file}"
}

n2k_source_prepare_file_path() {
  local source_path="$1"
  if n2k_source_is_nutanix_nfs_uri "${source_path}"; then
    n2k_source_nfs_mount_uri "${source_path}"
  else
    printf '%s' "${source_path}"
  fi
}

n2k_source_map_from_v3_nfs_changed_regions() {
  local changed_regions_json="$1" nfs_host="$2"
  nfs_host="$(n2k_source_nfs_host_from_endpoint "${nfs_host}")"
  [[ -n "${nfs_host}" ]] || {
    echo "NFS host is required to build source-map from v3 changed-region metadata." >&2
    return 2
  }
  jq -c --arg host "${nfs_host}" '
    (.disk_mappings // {}) as $m
    | reduce ($m | keys[]) as $disk_id ({};
        ($m[$disk_id].snapshot_file_path // "") as $path
        | if ($path | startswith("/")) then
            . + {($disk_id):("nutanix-nfs://" + $host + $path)}
          else
            .
          end
      )
  ' <<<"${changed_regions_json}"
}

n2k_source_map_from_v3_nfs_path_index() {
  local manifest="$1" path_index_json="$2" nfs_host="$3"
  local entries count idx item vdisk_uuid snapshot_file_path uri local_path file_size disk_id source_map="{}"
  local mapped_count=0 mount_errors="[]" missing_files="[]"
  [[ -n "${nfs_host}" ]] || {
    echo "NFS host is required to build source-map from v3 path index." >&2
    return 2
  }
  nfs_host="$(n2k_source_nfs_host_from_endpoint "${nfs_host}")"
  [[ -n "${nfs_host}" ]] || {
    echo "NFS host is required to build source-map from v3 path index." >&2
    return 2
  }
  entries="$(jq -c '.disks // {} | to_entries' <<<"${path_index_json}")"
  count="$(jq -r 'length' <<<"${entries}")"
  for ((idx=0; idx<count; idx++)); do
    item="$(jq -c --argjson idx "${idx}" '.[$idx]' <<<"${entries}")"
    vdisk_uuid="$(jq -r '.key' <<<"${item}")"
    snapshot_file_path="$(jq -r '.value.snapshot_file_path // empty' <<<"${item}")"
    [[ -n "${snapshot_file_path}" ]] || continue
    uri="$(n2k_source_nfs_uri_from_path "${nfs_host}" "${snapshot_file_path}")"
    local err_file
    err_file="$(mktemp)"
    if ! local_path="$(n2k_source_nfs_mount_uri "${uri}" 2>"${err_file}")"; then
      mount_errors="$(jq -c \
        --arg uri "${uri}" \
        --arg error "$(cat "${err_file}")" \
        '. + [{uri:$uri,error:$error}]' <<<"${mount_errors}")"
      rm -f "${err_file}"
      continue
    fi
    rm -f "${err_file}"
    if [[ ! -e "${local_path}" ]]; then
      missing_files="$(jq -c \
        --arg uri "${uri}" \
        --arg local_path "${local_path}" \
        '. + [{uri:$uri,local_path:$local_path}]' <<<"${missing_files}")"
      continue
    fi
    file_size="$(n2k_storage_file_size_bytes "${local_path}")"
    disk_id="$(n2k_source_manifest_disk_id_for_snapshot_file "${manifest}" "${vdisk_uuid}" "${file_size}" "${idx}")"
    [[ -n "${disk_id}" ]] || continue
    source_map="$(jq -c --arg disk_id "${disk_id}" --arg uri "${uri}" '. + {($disk_id):$uri}' <<<"${source_map}")"
    mapped_count=$((mapped_count + 1))
  done
  if [[ "${mapped_count}" -eq 0 ]]; then
    jq -nc \
      --arg host "${nfs_host}" \
      --argjson snapshot_disk_count "${count}" \
      --argjson mount_errors "${mount_errors}" \
      --argjson missing_files "${missing_files}" \
      '{message:"Unable to build Nutanix NFS source map from v3 snapshot paths",source_endpoint:$host,snapshot_disk_count:$snapshot_disk_count,mount_errors:$mount_errors,missing_files:$missing_files}' >&2
    return 2
  fi
  printf '%s' "${source_map}"
}

n2k_transfer_cold_base_all() {
  local manifest="$1" source_map_json="$2"
  local count idx
  count="$(jq -r '.disks | length' "${manifest}")"
  [[ "${count}" -gt 0 ]] || {
    echo "Manifest has no disks. Run init with inventory first." >&2
    return 2
  }

  trap 'n2k_source_cleanup_nfs_mounts' RETURN
  for ((idx=0; idx<count; idx++)); do
    n2k_transfer_cold_base_one "${manifest}" "${source_map_json}" "${idx}"
  done

  if [[ "${N2K_DRY_RUN:-0}" -ne 1 ]]; then
    n2k_manifest_phase_done "${manifest}" "base_sync"
  fi
  n2k_source_cleanup_nfs_mounts
  trap - RETURN
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
  if [[ "${N2K_DRY_RUN:-0}" -ne 1 ]]; then
    source_path="$(n2k_source_prepare_file_path "${source_path}")"
  fi
  [[ "${N2K_DRY_RUN:-0}" -eq 1 || -e "${source_path}" ]] || {
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

  n2k_storage_copy_base "${source_path}" "${target_path}" "${target_storage}" "${target_format}"

  bytes_written="$(n2k_file_size_bytes "${source_path}")"
  n2k_manifest_set_cold_source "${manifest}" "${idx}" "${source_path}"
  n2k_manifest_mark_base_done "${manifest}" "${idx}" "${bytes_written}"
  n2k_event INFO "sync.base" "${disk_id}" "cold_export_disk_done" \
    "$(jq -nc --argjson bytes "${bytes_written}" '{bytes_written:$bytes}')"
}
