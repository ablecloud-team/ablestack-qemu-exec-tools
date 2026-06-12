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

v2k_cloud_target_disk_offering_name() {
  local storage_type="$1"
  case "${storage_type}" in
    local)
      printf '%s' "${V2K_CLOUD_LOCAL_DISK_OFFERING_NAME:-V2K Migration Writeback Local}"
      ;;
    *)
      printf '%s' "${V2K_CLOUD_SHARED_DISK_OFFERING_NAME:-V2K Migration Writeback}"
      ;;
  esac
}

v2k_cloud_target_config_json() {
  local endpoint="${1:-}" zone_id="${2:-}" service_offering_id="${3:-}" network_ids_csv="${4:-}"
  local storage_id="${5:-}" disk_offering_id="${6:-}" host_id="${7:-}" account="${8:-}" domain_id="${9:-}"
  local project_id="${10:-}" name="${11:-}" display_name="${12:-}" cpu_speed="${13:-}"
  local network_ids_json
  network_ids_json="$(v2k_cloud_json_array_from_csv "${network_ids_csv}")"

  jq -nc \
    --arg endpoint "${endpoint}" \
    --arg zone_id "${zone_id}" \
    --arg service_offering_id "${service_offering_id}" \
    --arg storage_id "${storage_id}" \
    --arg disk_offering_id "${disk_offering_id}" \
    --arg host_id "${host_id}" \
    --arg account "${account}" \
    --arg domain_id "${domain_id}" \
    --arg project_id "${project_id}" \
    --arg name "${name}" \
    --arg display_name "${display_name}" \
    --arg cpu_speed "${cpu_speed}" \
    --argjson network_ids "${network_ids_json}" \
    '
      {
        endpoint: $endpoint,
        zone_id: $zone_id,
        service_offering_id: $service_offering_id,
        network_ids: $network_ids,
        storage_id: $storage_id,
        disk_offering_id: $disk_offering_id,
        host_id: $host_id,
        account: $account,
        domain_id: $domain_id,
        project_id: $project_id,
        name: $name,
        display_name: $display_name,
        cpu_speed: $cpu_speed
      }
      | with_entries(select(
          (.value != null)
          and (
            ((.value | type) == "array" and (.value | length) > 0)
            or ((.value | type) != "array" and (.value | tostring | length) > 0)
          )
        ))
    '
}

v2k_cloud_target_apply_manifest_config() {
  local manifest="$1" provider="$2" cloud_json="${3:-}"
  local cloud_compact tmp
  [[ -n "${cloud_json}" ]] || cloud_json="{}"
  cloud_compact="$(printf '%s' "${cloud_json}" | jq -c .)"
  tmp="$(mktemp)"
  jq \
    --arg provider "${provider}" \
    --argjson cloud "${cloud_compact}" \
    '
      def nonempty:
        with_entries(select(
          (.value != null)
          and (
            ((.value | type) == "array" and (.value | length) > 0)
            or ((.value | type) != "array" and (.value | tostring | length) > 0)
          )
        ));
      .target.provider = (if ($provider | length) > 0 then $provider else (.target.provider // "libvirt") end)
      | .target.cloud = ((.target.cloud // {}) + ($cloud | nonempty))
    ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

v2k_cloud_target_resolve_runtime_json() {
  local manifest="$1" endpoint_arg="$2" api_key_arg="$3" secret_key_arg="$4" cred_file="${5:-}"
  local endpoint api_key secret_key manifest_endpoint=""

  if [[ -n "${cred_file}" ]]; then
    v2k_cloud_load_cred_file "${cred_file}"
  fi
  if [[ -f "${manifest}" ]]; then
    manifest_endpoint="$(jq -r '.target.cloud.endpoint // empty' "${manifest}")"
  fi
  endpoint="${endpoint_arg:-${manifest_endpoint}}"
  endpoint="${endpoint:-${V2K_CLOUD_ENDPOINT:-${ABLESTACK_CLOUD_ENDPOINT:-${CLOUDSTACK_ENDPOINT:-}}}}"
  api_key="$(v2k_cloud_resolve_api_key "${api_key_arg}")"
  secret_key="$(v2k_cloud_resolve_secret_key "${secret_key_arg}")"

  jq -nc \
    --arg endpoint "${endpoint}" \
    --arg api_key "${api_key}" \
    --arg secret_key "${secret_key}" \
    '{endpoint:$endpoint, api_key:$api_key, secret_key:$secret_key}'
}

v2k_cloud_target_required_config_json() {
  local manifest="$1"
  jq -c '
    {
      zone_id: (.target.cloud.zone_id // ""),
      service_offering_id: (.target.cloud.service_offering_id // ""),
      network_ids: (.target.cloud.network_ids // []),
      storage_id: (.target.cloud.storage_id // ""),
      disk_offering_id: (.target.cloud.disk_offering_id // ""),
      host_id: (.target.cloud.host_id // ""),
      account: (.target.cloud.account // ""),
      domain_id: (.target.cloud.domain_id // ""),
      project_id: (.target.cloud.project_id // ""),
      name: (.target.cloud.name // .target.libvirt.name // .source.vm.name // ""),
      display_name: (.target.cloud.display_name // .target.cloud.name // .target.libvirt.name // .source.vm.name // ""),
      cpu_speed: ((.target.cloud.cpu_speed // "1000") | tostring)
    }
  ' "${manifest}"
}

v2k_cloud_target_validate_config() {
  local manifest="$1" runtime_json="$2"
  local cfg endpoint api_key secret_key network_count
  cfg="$(v2k_cloud_target_required_config_json "${manifest}")"
  endpoint="$(jq -r '.endpoint // ""' <<<"${runtime_json}")"
  api_key="$(jq -r '.api_key // ""' <<<"${runtime_json}")"
  secret_key="$(jq -r '.secret_key // ""' <<<"${runtime_json}")"
  network_count="$(jq -r '(.network_ids // []) | length' <<<"${cfg}")"

  v2k_cloud_require_credentials "${endpoint}" "${api_key}" "${secret_key}"
  jq -e '
    (.zone_id | length) > 0
    and (.service_offering_id | length) > 0
    and ((.network_ids // []) | length) > 0
    and (.storage_id | length) > 0
    and ((.cpu_speed // "1000") | tostring | test("^[0-9]+$"))
    and (((.cpu_speed // "1000") | tonumber) > 0)
  ' <<<"${cfg}" >/dev/null || {
    echo "Cloud target requires zone_id, service_offering_id, network_ids, storage_id, and a positive numeric cpu_speed." >&2
    return 2
  }
  [[ "${network_count}" -gt 0 ]] || {
    echo "Cloud target requires at least one network id." >&2
    return 2
  }
}

v2k_cloud_target_import_path() {
  local storage="$1" target_path="$2"
  local image
  case "${storage}" in
    rbd)
      image="${target_path#rbd:}"
      image="${image#/}"
      if [[ "${image}" == */* ]]; then
        image="${image#*/}"
      fi
      printf '%s' "${image}"
      ;;
    file)
      printf '%s' "${target_path}"
      ;;
    block)
      echo "ABLESTACK Cloud target import does not support block/LVM target paths." >&2
      return 2
      ;;
    *)
      echo "Unsupported target storage for Cloud import: ${storage}" >&2
      return 2
      ;;
  esac
}

v2k_cloud_target_optional_owner_params() {
  local cfg="$1"
  printf '%s' "${cfg}" | jq -c '
    {}
    + (if (.account | length) > 0 then {account:.account} else {} end)
    + (if (.domain_id | length) > 0 then {domainid:.domain_id} else {} end)
    + (if (.project_id | length) > 0 then {projectid:.project_id} else {} end)
  '
}

v2k_cloud_target_source_deploy_params_json() {
  local manifest="$1"
  jq -c '
    def controller($raw):
      ($raw // "" | tostring | ascii_downcase) as $s
      | if ($s | test("virtio")) then "virtio"
        elif ($s | test("sata")) then "sata"
        elif ($s | test("ide")) then "ide"
        elif ($s | test("scsi|lsilogic|pvscsi|buslogic")) then "scsi"
        else "" end;

    (.source.vm // {}) as $vm
    | (($vm.cpu // 0) | tonumber? // 0) as $cpu
    | (($vm.memory_mb // 0) | tonumber? // 0) as $memory_mb
    | (((.disks[0].size_bytes // 0) | tonumber? // 0)) as $root_size_bytes
    | (if $root_size_bytes > 0 then ((($root_size_bytes + 1073741823) / 1073741824) | floor) else 0 end) as $root_size_gib
    | ((.target.cloud.cpu_speed // "1000") | tostring) as $cpu_speed
    | (($vm.firmware // "") | tostring | ascii_downcase) as $firmware
    | (($vm.secure_boot // false) == true) as $secure_boot
    | ((.runtime.bootstrap_fallback.bus // "") | tostring | ascii_downcase) as $fallback_bus
    | ((.disks // []) | length) as $disk_count
    | (if $fallback_bus == "sata" then "sata" else controller(.disks[0].controller.type // "") end) as $root_controller
    | (if $fallback_bus == "sata" and $disk_count > 1 then "sata" else controller((.disks[1:] // [] | map(.controller.type // "") | map(select((. | tostring | length) > 0)) | first) // "") end) as $data_controller
    | {}
      + (if $cpu > 0 then {"details[0].cpuNumber": ($cpu | floor | tostring)} else {} end)
      + {"details[0].cpuSpeed": $cpu_speed}
      + {"details[0].io.policy": "io_uring"}
      + {"details[0].iothreads": "true"}
      + (if $memory_mb > 0 then {"details[0].memory": ($memory_mb | floor | tostring)} else {} end)
      + (if $root_size_gib > 0 then {"details[0].rootdisksize": ($root_size_gib | tostring)} else {} end)
      + (if ($root_controller | length) > 0 then {"details[0].rootDiskController": $root_controller} else {} end)
      + (if ($data_controller | length) > 0 then {"details[0].dataDiskController": $data_controller} else {} end)
      + (
          if (($firmware | test("efi|uefi")) or $secure_boot) then
            {boottype:"UEFI", bootmode:(if $secure_boot then "SECURE" else "LEGACY" end)}
          elif ($firmware | test("bios|legacy")) then
            {boottype:"BIOS", bootmode:"LEGACY"}
          else
            {}
          end
        )
  ' "${manifest}"
}

v2k_cloud_target_validate_import_visible() {
  local endpoint="$1" api_key="$2" secret_key="$3" storage_id="$4" import_path="$5"
  local response
  if ! response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listVolumesForImport" \
    "$(jq -nc --arg storageid "${storage_id}" --arg path "${import_path}" '{storageid:$storageid,path:$path}')")"; then
    return 1
  fi
  printf '%s' "${response}" | jq -e '
    to_entries[0].value as $body
    | (
        (($body.count // 0 | tonumber) > 0)
        or (($body.volume // $body.volumes // $body.volumeforimport // []) | length > 0)
      )
  ' >/dev/null
}

v2k_cloud_target_storage_pool_json() {
  local endpoint="$1" api_key="$2" secret_key="$3" storage_id="$4"
  local response
  [[ -n "${storage_id}" ]] || {
    echo "Cloud storage id is required to resolve storage path." >&2
    return 2
  }
  if ! response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listStoragePools" \
    "$(jq -nc --arg id "${storage_id}" '{id:$id,listall:true}')")"; then
    return 1
  fi
  printf '%s' "${response}" | jq -c --arg id "${storage_id}" '
    (.liststoragepoolsresponse.storagepool // [])
    | map(select((.id // "") == $id))
    | .[0] // empty
  '
}

v2k_cloud_target_storage_pool_config_json() {
  local pool_json="$1"
  printf '%s' "${pool_json}" | jq -c '
    {
      id: (.id // ""),
      name: (.name // ""),
      type: ((.type // .storagetype // "") | tostring),
      scope: ((.scope // "") | tostring),
      path: (.path // ""),
      cluster_id: (.clusterid // ""),
      cluster_name: (.clustername // ""),
      zone_id: (.zoneid // "")
    }
    | with_entries(select((.value | tostring | length) > 0))
  '
}

v2k_cloud_target_record_storage_pool() {
  local manifest="$1" pool_json="$2"
  local pool_compact tmp
  pool_compact="$(v2k_cloud_target_storage_pool_config_json "${pool_json}")"
  tmp="$(mktemp)"
  jq --argjson pool "${pool_compact}" '
    .target.cloud.storage_pool = $pool
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

v2k_cloud_target_file_storage_path_from_pool() {
  local pool_json="$1"
  local pool_type path
  pool_type="$(jq -r '(.type // .storagetype // "") | tostring' <<<"${pool_json}")"
  path="$(jq -r '.path // ""' <<<"${pool_json}")"
  case "${pool_type}" in
    Filesystem|NetworkFilesystem|SharedMountPoint) ;;
    *)
      echo "Cloud file/qcow2 target requires a file-backed storage pool, got type=${pool_type:-unknown}." >&2
      return 2
      ;;
  esac
  [[ -n "${path}" ]] || {
    echo "Cloud storage pool path is empty for type=${pool_type}." >&2
    return 2
  }
  printf '%s' "${path%/}"
}

v2k_cloud_target_validate_file_paths_for_pool() {
  local manifest="$1" pool_path="$2"
  local bad_paths
  pool_path="${pool_path%/}"
  bad_paths="$(jq -r --arg pool_path "${pool_path}" '
    .disks[]
    | (.transfer.target_path // "") as $path
    | select(
        ($path | startswith($pool_path + "/") | not)
        or (($path | sub("^.*/"; "")) | length == 0)
        or (($path | sub("/[^/]*$"; "")) != $pool_path)
      )
    | $path
  ' "${manifest}")"
  [[ -z "${bad_paths}" ]] || {
    echo "Cloud file/qcow2 target paths must be root-level files under the selected Cloud storage path: ${pool_path}" >&2
    printf '%s\n' "${bad_paths}" >&2
    return 2
  }
}

v2k_cloud_target_resolve_file_storage_for_manifest() {
  local manifest="$1" endpoint_arg="${2:-}" api_key_arg="${3:-}" secret_key_arg="${4:-}" cred_file="${5:-}"
  local runtime cfg endpoint api_key secret_key storage_id pool_json pool_path
  runtime="$(v2k_cloud_target_resolve_runtime_json "${manifest}" "${endpoint_arg}" "${api_key_arg}" "${secret_key_arg}" "${cred_file}")"
  endpoint="$(jq -r '.endpoint // ""' <<<"${runtime}")"
  api_key="$(jq -r '.api_key // ""' <<<"${runtime}")"
  secret_key="$(jq -r '.secret_key // ""' <<<"${runtime}")"
  cfg="$(v2k_cloud_target_required_config_json "${manifest}")"
  storage_id="$(jq -r '.storage_id // ""' <<<"${cfg}")"
  v2k_cloud_require_credentials "${endpoint}" "${api_key}" "${secret_key}" || return $?
  pool_json="$(v2k_cloud_target_storage_pool_json "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}")" || return $?
  [[ -n "${pool_json}" ]] || {
    echo "Cloud storage pool was not found: ${storage_id}" >&2
    return 2
  }
  pool_path="$(v2k_cloud_target_file_storage_path_from_pool "${pool_json}")" || return $?
  v2k_cloud_target_record_storage_pool "${manifest}" "${pool_json}"
  v2k_cloud_target_validate_file_paths_for_pool "${manifest}" "${pool_path}" || return $?
  printf '%s' "${pool_path}"
}

v2k_cloud_target_disk_offering_storage_type_from_pool() {
  local pool_json="$1"
  printf '%s' "${pool_json}" | jq -r '
    ((.scope // "") | tostring | ascii_downcase) as $scope
    | ((.local // .islocal // .isLocal // .uselocalstorage // false) | tostring | ascii_downcase) as $local
    | if $scope == "host" or $local == "true" then "local" else "shared" end
  '
}

v2k_cloud_target_disk_offerings_by_name_json() {
  local endpoint="$1" api_key="$2" secret_key="$3" name="$4" storage_type="$5"
  local response
  if ! response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listDiskOfferings" \
    "$(jq -nc --arg name "${name}" --arg storagetype "${storage_type}" '{name:$name,storagetype:$storagetype,listall:true}')")"; then
    return 1
  fi
  printf '%s' "${response}" | jq -c '(.listdiskofferingsresponse.diskoffering // [])'
}

v2k_cloud_target_usable_disk_offering_json() {
  local offerings_json="$1" name="$2" storage_type="$3"
  printf '%s' "${offerings_json}" | jq -c \
    --arg name "${name}" \
    --arg storage_type "${storage_type}" \
    '
      def st: ((.storagetype // "") | tostring | ascii_downcase);
      def cache: ((.cachemode // "") | tostring | ascii_downcase);
      def state: ((.state // "Active") | tostring | ascii_downcase);
      def customized: ((.iscustomized // .customized // false) == true);
      def untagged: (((.tags // "") | tostring | length) == 0);
      map(select(
        (.name // "") == $name
        and st == $storage_type
        and cache == "writeback"
        and state == "active"
        and customized
        and untagged
      ))
      | .[0] // empty
    '
}

v2k_cloud_target_disk_offering_conflict_count() {
  local offerings_json="$1" name="$2" storage_type="$3"
  printf '%s' "${offerings_json}" | jq -r \
    --arg name "${name}" \
    --arg storage_type "${storage_type}" \
    '
      [
        .[]
        | select(
            (.name // "") == $name
            and (((.storagetype // "") | tostring | ascii_downcase) == $storage_type)
          )
      ]
      | length
    '
}

v2k_cloud_target_disk_offering_summary_json() {
  local offering_json="$1" created="$2"
  jq -nc \
    --argjson offering "${offering_json}" \
    --argjson created "${created}" \
    '
      {
        id: ($offering.id // ""),
        name: ($offering.name // ""),
        storage_type: (($offering.storagetype // "") | tostring | ascii_downcase),
        cache_mode: (($offering.cachemode // "") | tostring | ascii_downcase),
        customized: (($offering.iscustomized // $offering.customized // false) == true),
        created: $created
      }
    '
}

v2k_cloud_target_create_v2k_disk_offering() {
  local endpoint="$1" api_key="$2" secret_key="$3" name="$4" storage_type="$5"
  local display_text response
  display_text="${V2K_CLOUD_DISK_OFFERING_DISPLAY_TEXT:-ABLESTACK V2K migration disk offering with writeback cache}"
  if ! response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "createDiskOffering" \
    "$(jq -nc \
      --arg name "${name}" \
      --arg displaytext "${display_text}" \
      --arg storagetype "${storage_type}" \
      '{
        name:$name,
        displaytext:$displaytext,
        customized:true,
        provisioningtype:"thin",
        storagetype:$storagetype,
        cachemode:"writeback",
        displayoffering:true
      }')")"; then
    return 1
  fi
  printf '%s\n' "Created Cloud V2K disk offering: ${name} (${storage_type}, writeback)" >&2
  printf '%s' "${response}" >/dev/null
}

v2k_cloud_target_resolve_disk_offering() {
  local endpoint="$1" api_key="$2" secret_key="$3" pool_json="$4"
  local storage_type name offerings offering conflict_count
  storage_type="$(v2k_cloud_target_disk_offering_storage_type_from_pool "${pool_json}")"
  name="$(v2k_cloud_target_disk_offering_name "${storage_type}")"

  offerings="$(v2k_cloud_target_disk_offerings_by_name_json "${endpoint}" "${api_key}" "${secret_key}" "${name}" "${storage_type}")" || return $?
  offering="$(v2k_cloud_target_usable_disk_offering_json "${offerings}" "${name}" "${storage_type}")"
  if [[ -n "${offering}" ]]; then
    v2k_cloud_target_disk_offering_summary_json "${offering}" false
    return 0
  fi

  conflict_count="$(v2k_cloud_target_disk_offering_conflict_count "${offerings}" "${name}" "${storage_type}")"
  if [[ "${conflict_count}" -gt 0 ]]; then
    echo "Cloud V2K disk offering exists but is not compatible: name=${name} storage_type=${storage_type} required_cache=writeback customized=true tags=empty" >&2
    printf '%s\n' "${offerings}" >&2
    return 2
  fi

  v2k_cloud_target_create_v2k_disk_offering "${endpoint}" "${api_key}" "${secret_key}" "${name}" "${storage_type}" || return $?
  offerings="$(v2k_cloud_target_disk_offerings_by_name_json "${endpoint}" "${api_key}" "${secret_key}" "${name}" "${storage_type}")" || return $?
  offering="$(v2k_cloud_target_usable_disk_offering_json "${offerings}" "${name}" "${storage_type}")"
  [[ -n "${offering}" ]] || {
    echo "Cloud V2K disk offering was created but could not be verified: name=${name} storage_type=${storage_type}" >&2
    printf '%s\n' "${offerings}" >&2
    return 1
  }
  v2k_cloud_target_disk_offering_summary_json "${offering}" true
}

v2k_cloud_target_record_disk_offering() {
  local manifest="$1" offering_json="$2"
  local offering_compact tmp
  offering_compact="$(printf '%s' "${offering_json}" | jq -c .)"
  tmp="$(mktemp)"
  jq --argjson offering "${offering_compact}" '
    .target.cloud.resolved_disk_offering = $offering
    | .target.cloud.disk_offering_id = ($offering.id // .target.cloud.disk_offering_id // "")
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

v2k_cloud_target_disk_name() {
  local manifest="$1" idx="$2"
  local vm disk_id
  vm="$(jq -r '.target.cloud.name // .target.libvirt.name // .source.vm.name // "vm"' "${manifest}")"
  disk_id="$(jq -r ".disks[${idx}].disk_id // \"disk${idx}\"" "${manifest}")"
  printf '%s-%s' "${vm}" "${disk_id}"
}

v2k_cloud_target_import_volume() {
  local endpoint="$1" api_key="$2" secret_key="$3" storage_id="$4" disk_offering_id="$5"
  local import_path="$6" name="$7" owner_params="$8"
  local params response job_id job volume_id
  params="$(jq -nc \
    --arg path "${import_path}" \
    --arg storageid "${storage_id}" \
    --arg name "${name}" \
    --arg diskofferingid "${disk_offering_id}" \
    --argjson owner "${owner_params}" \
    '{path:$path,storageid:$storageid,name:$name} + $owner
     + (if ($diskofferingid | length) > 0 then {diskofferingid:$diskofferingid} else {} end)')"
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "importVolume" "${params}")" || return $?
  job_id="$(printf '%s' "${response}" | v2k_cloud_response_job_id)"
  [[ -n "${job_id}" ]] || {
    echo "Cloud importVolume did not return an async job id." >&2
    printf '%s\n' "${response}" >&2
    return 1
  }
  job="$(v2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")" || return $?
  volume_id="$(printf '%s' "${job}" | jq -r '.jobresult.volume.id // .jobresult.id // empty')"
  [[ -n "${volume_id}" ]] || {
    echo "Cloud importVolume job completed but volume id was not returned." >&2
    printf '%s\n' "${job}" >&2
    return 1
  }
  jq -nc --arg id "${volume_id}" --arg job_id "${job_id}" --argjson job "${job}" '{id:$id,job_id:$job_id,job:$job}'
}

v2k_cloud_target_deploy_vm_for_volume() {
  local endpoint="$1" api_key="$2" secret_key="$3" cfg="$4" root_volume_id="$5" start_vm="$6" source_params="${7:-}"
  local owner_params params response job_id job vm_id
  [[ -n "${source_params}" ]] || source_params="{}"
  owner_params="$(v2k_cloud_target_optional_owner_params "${cfg}")"
  params="$(jq -nc \
    --arg volumeid "${root_volume_id}" \
    --argjson cfg "${cfg}" \
    --argjson owner "${owner_params}" \
    --argjson source_params "${source_params}" \
    --arg startvm "${start_vm}" \
    '
      {
        zoneid: $cfg.zone_id,
        serviceofferingid: $cfg.service_offering_id,
        volumeid: $volumeid,
        networkids: (($cfg.network_ids // []) | join(",")),
        name: $cfg.name,
        displayname: $cfg.display_name,
        startvm: $startvm,
        hypervisor: "KVM"
      }
      + $owner
      + $source_params
      + (if (($cfg.host_id // "") | length) > 0 then {hostid:$cfg.host_id} else {} end)
    ')"
  [[ -n "${root_volume_id}" ]] || {
    echo "Cloud deployVirtualMachineForVolume requires a root volume id." >&2
    return 2
  }
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "deployVirtualMachineForVolume" "${params}")" || return $?
  job_id="$(printf '%s' "${response}" | v2k_cloud_response_job_id)"
  [[ -n "${job_id}" ]] || {
    echo "Cloud deployVirtualMachineForVolume did not return an async job id." >&2
    printf '%s\n' "${response}" >&2
    return 1
  }
  job="$(v2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")" || return $?
  vm_id="$(printf '%s' "${job}" | jq -r '.jobresult.virtualmachine.id // .jobresult.uservm.id // .jobresult.id // empty')"
  [[ -n "${vm_id}" ]] || {
    echo "Cloud deployVirtualMachineForVolume job completed but VM id was not returned." >&2
    printf '%s\n' "${job}" >&2
    return 1
  }
  jq -nc --arg id "${vm_id}" --arg job_id "${job_id}" --argjson job "${job}" '{id:$id,job_id:$job_id,job:$job}'
}

v2k_cloud_target_volume_json() {
  local endpoint="$1" api_key="$2" secret_key="$3" volume_id="$4"
  local response
  [[ -n "${volume_id}" ]] || {
    echo "Cloud listVolumes requires a volume id." >&2
    return 2
  }
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listVolumes" \
    "$(jq -nc --arg id "${volume_id}" '{id:$id}')")" || return $?
  printf '%s' "${response}" | jq -c '(.listvolumesresponse.volume // [])[0] // {}'
}

v2k_cloud_target_update_volume_type() {
  local endpoint="$1" api_key="$2" secret_key="$3" volume_id="$4" volume_type="$5" volume_path="${6:-}"
  local response job_id job params
  params="$(jq -nc \
    --arg id "${volume_id}" \
    --arg type "${volume_type}" \
    --arg path "${volume_path}" \
    '{id:$id,type:$type} + (if ($path | length) > 0 then {path:$path} else {} end)')"
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "updateVolume" "${params}")" || return $?
  job_id="$(printf '%s' "${response}" | v2k_cloud_response_job_id)"
  if [[ -n "${job_id}" ]]; then
    job="$(v2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")" || return $?
    jq -nc --arg job_id "${job_id}" --argjson job "${job}" '{job_id:$job_id,job:$job}'
  else
    jq -nc --argjson response "${response}" '{response:$response}'
  fi
}

v2k_cloud_target_ensure_root_volume() {
  local endpoint="$1" api_key="$2" secret_key="$3" volume_id="$4" vm_id="$5" volume_path_hint="${6:-}"
  local volume volume_type volume_vm_id volume_path update_result converted=false
  volume="$(v2k_cloud_target_volume_json "${endpoint}" "${api_key}" "${secret_key}" "${volume_id}")" || return $?
  volume_type="$(jq -r '.type // empty' <<<"${volume}")"
  volume_vm_id="$(jq -r '.virtualmachineid // empty' <<<"${volume}")"
  volume_path="$(jq -r '.path // empty' <<<"${volume}")"
  [[ -n "${volume_path}" || -z "${volume_path_hint}" ]] || volume_path="${volume_path_hint}"
  [[ -z "${vm_id}" || "${volume_vm_id}" == "${vm_id}" ]] || {
    echo "Cloud root volume is not attached to the deployed VM: ${volume_id} vm=${volume_vm_id:-none} expected=${vm_id}" >&2
    printf '%s\n' "${volume}" >&2
    return 1
  }
  if [[ "${volume_type}" != "ROOT" ]]; then
    update_result="$(v2k_cloud_target_update_volume_type "${endpoint}" "${api_key}" "${secret_key}" "${volume_id}" "ROOT" "${volume_path}")" || return $?
    converted=true
    volume="$(v2k_cloud_target_volume_json "${endpoint}" "${api_key}" "${secret_key}" "${volume_id}")" || return $?
    volume_type="$(jq -r '.type // empty' <<<"${volume}")"
    volume_path="$(jq -r '.path // empty' <<<"${volume}")"
  else
    update_result="{}"
  fi
  [[ "${volume_type}" == "ROOT" ]] || {
    echo "Cloud root volume was not converted to ROOT: ${volume_id} type=${volume_type:-unknown}" >&2
    printf '%s\n' "${volume}" >&2
    return 1
  }
  [[ -z "${volume_path_hint}" || -n "${volume_path}" ]] || {
    echo "Cloud root volume path is empty after ROOT conversion: ${volume_id} expected_path=${volume_path_hint}" >&2
    printf '%s\n' "${volume}" >&2
    return 1
  }
  jq -nc \
    --argjson volume "${volume}" \
    --argjson converted "${converted}" \
    --argjson update "${update_result}" \
    '{volume:$volume,converted:$converted} + (if ($update | length) > 0 then {update:$update} else {} end)'
}

v2k_cloud_target_attach_volume() {
  local endpoint="$1" api_key="$2" secret_key="$3" vm_id="$4" volume_id="$5" device_id="$6"
  local response job_id job
  [[ -n "${vm_id}" && -n "${volume_id}" ]] || {
    echo "Cloud attachVolume requires VM id and volume id." >&2
    return 2
  }
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "attachVolume" \
    "$(jq -nc --arg id "${volume_id}" --arg virtualmachineid "${vm_id}" --arg deviceid "${device_id}" '{id:$id,virtualmachineid:$virtualmachineid,deviceid:$deviceid}')")" || return $?
  job_id="$(printf '%s' "${response}" | v2k_cloud_response_job_id)"
  [[ -n "${job_id}" ]] || {
    echo "Cloud attachVolume did not return an async job id." >&2
    printf '%s\n' "${response}" >&2
    return 1
  }
  job="$(v2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")" || return $?
  jq -nc --arg job_id "${job_id}" --argjson job "${job}" '{job_id:$job_id,job:$job}'
}

v2k_cloud_target_start_vm() {
  local endpoint="$1" api_key="$2" secret_key="$3" vm_id="$4"
  local response job_id job
  [[ -n "${vm_id}" ]] || {
    echo "Cloud startVirtualMachine requires a VM id." >&2
    return 2
  }
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "startVirtualMachine" \
    "$(jq -nc --arg id "${vm_id}" '{id:$id}')")" || return $?
  job_id="$(printf '%s' "${response}" | v2k_cloud_response_job_id)"
  [[ -n "${job_id}" ]] || {
    echo "Cloud startVirtualMachine did not return an async job id." >&2
    printf '%s\n' "${response}" >&2
    return 1
  }
  job="$(v2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")" || return $?
  jq -nc --arg job_id "${job_id}" --argjson job "${job}" '{job_id:$job_id,job:$job}'
}

v2k_cloud_target_record_result() {
  local manifest="$1" result_json="$2"
  local result_compact tmp
  result_compact="$(printf '%s' "${result_json}" | jq -c .)"
  tmp="$(mktemp)"
  jq --argjson result "${result_compact}" '
    .runtime.cloud = ((.runtime.cloud // {}) + $result)
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

v2k_cloud_target_preflight_json() {
  local endpoint="$1" api_key="$2" secret_key="$3"
  local api command response available_json="{}" ok=true
  v2k_cloud_require_credentials "${endpoint}" "${api_key}" "${secret_key}"
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listApis")"
  for api in listStoragePools listDiskOfferings createDiskOffering listVolumesForImport importVolume deployVirtualMachineForVolume updateVolume attachVolume startVirtualMachine queryAsyncJobResult; do
    if printf '%s' "${response}" | jq -e --arg api "${api}" '(.listapisresponse.api // []) | map(.name) | index($api) != null' >/dev/null; then
      command=true
    else
      command=false
      ok=false
    fi
    available_json="$(jq -c --arg api "${api}" --argjson available "${command}" '. + {($api):$available}' <<<"${available_json}")"
  done
  jq -nc --argjson ok "${ok}" --argjson apis "${available_json}" '{available:$ok,apis:$apis}'
}

v2k_cloud_target_cutover() {
  local manifest="$1" define_only="$2" apply_define="$3" start_vm="$4"
  local endpoint_arg="${5:-}" api_key_arg="${6:-}" secret_key_arg="${7:-}" cred_file="${8:-}"
  local runtime cfg endpoint api_key secret_key storage disk_count idx target_path import_path storage_id
  local disk_offering_id owner_params root_import root_volume_id deploy vm_id data_volumes_json jobs_json
  local import_result attach_result start_result result_json disk_name source_deploy_params root_volume_result root_volume_json root_volume_update_job root_volume_converted
  local pool_json pool_path import_volume_id disk_offering_json

  runtime="$(v2k_cloud_target_resolve_runtime_json "${manifest}" "${endpoint_arg}" "${api_key_arg}" "${secret_key_arg}" "${cred_file}")"
  endpoint="$(jq -r '.endpoint // ""' <<<"${runtime}")"
  api_key="$(jq -r '.api_key // ""' <<<"${runtime}")"
  secret_key="$(jq -r '.secret_key // ""' <<<"${runtime}")"
  cfg="$(v2k_cloud_target_required_config_json "${manifest}")"
  v2k_cloud_target_validate_config "${manifest}" "${runtime}" || return $?

  storage="$(jq -r '.target.storage.type // "file"' "${manifest}")"
  storage_id="$(jq -r '.storage_id // ""' <<<"${cfg}")"
  disk_offering_id="$(jq -r '.disk_offering_id // ""' <<<"${cfg}")"
  owner_params="$(v2k_cloud_target_optional_owner_params "${cfg}")"
  source_deploy_params="$(v2k_cloud_target_source_deploy_params_json "${manifest}")"
  disk_count="$(jq -r '.disks | length' "${manifest}")"
  [[ "${disk_count}" -gt 0 ]] || {
    echo "Cloud target cutover requires at least one migrated disk." >&2
    return 2
  }

  if [[ "${storage}" == "file" ]]; then
    pool_json="$(v2k_cloud_target_storage_pool_json "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}")" || return $?
    [[ -n "${pool_json}" ]] || {
      echo "Cloud storage pool was not found: ${storage_id}" >&2
      return 2
    }
    pool_path="$(v2k_cloud_target_file_storage_path_from_pool "${pool_json}")" || return $?
    v2k_cloud_target_record_storage_pool "${manifest}" "${pool_json}"
    v2k_cloud_target_validate_file_paths_for_pool "${manifest}" "${pool_path}" || return $?
  fi

  for ((idx=0; idx<disk_count; idx++)); do
    target_path="$(jq -r ".disks[${idx}].transfer.target_path // \"\"" "${manifest}")"
    [[ -n "${target_path}" ]] || {
      echo "Disk ${idx} has no target path." >&2
      return 2
    }
    import_path="$(v2k_cloud_target_import_path "${storage}" "${target_path}")" || return $?
    v2k_cloud_target_validate_import_visible "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}" "${import_path}" || {
      echo "Cloud import source is not visible: ${import_path}" >&2
      if [[ "${storage}" == "file" && -n "${pool_path:-}" ]]; then
        echo "Selected Cloud storage path: ${pool_path}" >&2
      fi
      return 2
    }
  done

  if [[ "${apply_define}" -eq 0 && "${start_vm}" -eq 0 ]]; then
    result_json="$(jq -nc \
      --arg provider "ablestack-cloud" \
      --arg endpoint "${endpoint}" \
      --argjson deployment_properties "${source_deploy_params}" \
      --argjson define_only "$(if [[ "${define_only}" -eq 1 ]]; then printf true; else printf false; fi)" \
      '{provider:$provider,endpoint:$endpoint,validated:true,applied:false,started:false,define_only:$define_only,deployment_properties:$deployment_properties}')"
    v2k_cloud_target_record_result "${manifest}" "${result_json}"
    printf '%s' "${result_json}"
    return 0
  fi

  if [[ "${V2K_DRY_RUN:-0}" -eq 1 ]]; then
    result_json="$(jq -nc --arg provider "ablestack-cloud" --argjson deployment_properties "${source_deploy_params}" '{provider:$provider,validated:true,applied:false,started:false,dry_run:true,deployment_properties:$deployment_properties}')"
    v2k_cloud_target_record_result "${manifest}" "${result_json}"
    printf '%s' "${result_json}"
    return 0
  fi

  if [[ -z "${disk_offering_id}" ]]; then
    if [[ -z "${pool_json:-}" ]]; then
      pool_json="$(v2k_cloud_target_storage_pool_json "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}")" || return $?
      [[ -n "${pool_json}" ]] || {
        echo "Cloud storage pool was not found: ${storage_id}" >&2
        return 2
      }
      v2k_cloud_target_record_storage_pool "${manifest}" "${pool_json}"
    fi
    disk_offering_json="$(v2k_cloud_target_resolve_disk_offering "${endpoint}" "${api_key}" "${secret_key}" "${pool_json}")" || return $?
    disk_offering_id="$(jq -r '.id // empty' <<<"${disk_offering_json}")"
    [[ -n "${disk_offering_id}" ]] || {
      echo "Cloud V2K disk offering resolution did not return an id." >&2
      printf '%s\n' "${disk_offering_json}" >&2
      return 1
    }
    v2k_cloud_target_record_disk_offering "${manifest}" "${disk_offering_json}"
  else
    disk_offering_json="$(jq -nc --arg id "${disk_offering_id}" '{id:$id,source:"explicit"}')"
  fi

  target_path="$(jq -r '.disks[0].transfer.target_path' "${manifest}")"
  import_path="$(v2k_cloud_target_import_path "${storage}" "${target_path}")"
  disk_name="$(v2k_cloud_target_disk_name "${manifest}" 0)"
  root_import="$(v2k_cloud_target_import_volume "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}" "${disk_offering_id}" "${import_path}" "${disk_name}" "${owner_params}")" || return $?
  root_volume_id="$(jq -r '.id' <<<"${root_import}")"
  [[ -n "${root_volume_id}" ]] || {
    echo "Cloud root import did not return a volume id." >&2
    return 1
  }
  deploy="$(v2k_cloud_target_deploy_vm_for_volume "${endpoint}" "${api_key}" "${secret_key}" "${cfg}" "${root_volume_id}" "false" "${source_deploy_params}")" || return $?
  vm_id="$(jq -r '.id' <<<"${deploy}")"
  [[ -n "${vm_id}" ]] || {
    echo "Cloud deployVirtualMachineForVolume did not return a VM id." >&2
    return 1
  }
  root_volume_result="$(v2k_cloud_target_ensure_root_volume "${endpoint}" "${api_key}" "${secret_key}" "${root_volume_id}" "${vm_id}" "${import_path}")" || return $?
  root_volume_json="$(jq -c '.volume' <<<"${root_volume_result}")"
  root_volume_update_job="$(jq -r '.update.job_id // empty' <<<"${root_volume_result}")"
  root_volume_converted="$(jq -r '.converted // false' <<<"${root_volume_result}")"

  data_volumes_json="[]"
  jobs_json="$(jq -nc --arg root_import_job "$(jq -r '.job_id' <<<"${root_import}")" --arg deploy_job "$(jq -r '.job_id' <<<"${deploy}")" '[{kind:"import-root",job_id:$root_import_job},{kind:"deploy-vm",job_id:$deploy_job}]')"
  if [[ -n "${root_volume_update_job}" ]]; then
    jobs_json="$(jq -c \
      --argjson jobs "${jobs_json}" \
      --arg update_job "${root_volume_update_job}" \
      '$jobs + [{kind:"update-root-volume",job_id:$update_job}]' <<<"{}")"
  fi
  for ((idx=1; idx<disk_count; idx++)); do
    target_path="$(jq -r ".disks[${idx}].transfer.target_path" "${manifest}")"
    import_path="$(v2k_cloud_target_import_path "${storage}" "${target_path}")"
    disk_name="$(v2k_cloud_target_disk_name "${manifest}" "${idx}")"
    import_result="$(v2k_cloud_target_import_volume "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}" "${disk_offering_id}" "${import_path}" "${disk_name}" "${owner_params}")" || return $?
    import_volume_id="$(jq -r '.id // empty' <<<"${import_result}")"
    [[ -n "${import_volume_id}" ]] || {
      echo "Cloud data disk import did not return a volume id for disk ${idx}." >&2
      return 1
    }
    attach_result="$(v2k_cloud_target_attach_volume "${endpoint}" "${api_key}" "${secret_key}" "${vm_id}" "${import_volume_id}" "${idx}")" || return $?
    data_volumes_json="$(jq -c \
      --argjson volumes "${data_volumes_json}" \
      --argjson imported "${import_result}" \
      --argjson attached "${attach_result}" \
      --argjson device_id "${idx}" \
      '$volumes + [{id:$imported.id,device_id:$device_id,import_job_id:$imported.job_id,attach_job_id:$attached.job_id}]' <<<"{}")"
    jobs_json="$(jq -c \
      --argjson jobs "${jobs_json}" \
      --arg import_job "$(jq -r '.job_id' <<<"${import_result}")" \
      --arg attach_job "$(jq -r '.job_id' <<<"${attach_result}")" \
      '$jobs + [{kind:"import-data",job_id:$import_job},{kind:"attach-data",job_id:$attach_job}]' <<<"{}")"
  done

  if [[ "${start_vm}" -eq 1 ]]; then
    start_result="$(v2k_cloud_target_start_vm "${endpoint}" "${api_key}" "${secret_key}" "${vm_id}")" || return $?
    jobs_json="$(jq -c --argjson jobs "${jobs_json}" --arg start_job "$(jq -r '.job_id' <<<"${start_result}")" '$jobs + [{kind:"start-vm",job_id:$start_job}]' <<<"{}")"
  fi

  result_json="$(jq -nc \
    --arg provider "ablestack-cloud" \
    --arg endpoint "${endpoint}" \
    --arg vm_id "${vm_id}" \
    --arg root_volume_id "${root_volume_id}" \
    --argjson root_volume "${root_volume_json}" \
    --argjson root_volume_converted "${root_volume_converted}" \
    --arg root_volume_update_job_id "${root_volume_update_job}" \
    --argjson data_volumes "${data_volumes_json}" \
    --argjson jobs "${jobs_json}" \
    --argjson deployment_properties "${source_deploy_params}" \
    --argjson disk_offering "${disk_offering_json}" \
    --argjson started "$(if [[ "${start_vm}" -eq 1 ]]; then printf true; else printf false; fi)" \
    '{provider:$provider,endpoint:$endpoint,validated:true,applied:true,started:$started,vm_id:$vm_id,root_volume_id:$root_volume_id,root_volume:$root_volume,root_volume_converted:$root_volume_converted,data_volumes:$data_volumes,jobs:$jobs,deployment_properties:$deployment_properties}
     + (if ($disk_offering | length) > 0 then {disk_offering:$disk_offering} else {} end)
     + (if ($root_volume_update_job_id | length) > 0 then {root_volume_update_job_id:$root_volume_update_job_id} else {} end)')"
  v2k_cloud_target_record_result "${manifest}" "${result_json}"
  printf '%s' "${result_json}"
}
