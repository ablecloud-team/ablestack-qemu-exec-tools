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

n2k_cloud_target_config_json() {
  local endpoint="${1:-}" zone_id="${2:-}" service_offering_id="${3:-}" network_ids_csv="${4:-}"
  local storage_id="${5:-}" disk_offering_id="${6:-}" host_id="${7:-}" account="${8:-}" domain_id="${9:-}"
  local project_id="${10:-}" name="${11:-}" display_name="${12:-}"
  local network_ids_json
  network_ids_json="$(n2k_cloud_json_array_from_csv "${network_ids_csv}")"

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
        display_name: $display_name
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

n2k_cloud_target_apply_manifest_config() {
  local manifest="$1" provider="$2" cloud_json="${3:-}"
  local cloud_compact tmp
  if [[ -z "${cloud_json}" ]]; then
    cloud_json="{}"
  fi
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

n2k_cloud_target_resolve_runtime_json() {
  local manifest="$1" endpoint_arg="$2" api_key_arg="$3" secret_key_arg="$4" cred_file="${5:-}"
  local endpoint api_key secret_key manifest_endpoint=""

  if [[ -n "${cred_file}" ]]; then
    n2k_cloud_load_cred_file "${cred_file}"
  fi
  if [[ -f "${manifest}" ]]; then
    manifest_endpoint="$(jq -r '.target.cloud.endpoint // empty' "${manifest}")"
  fi
  endpoint="${endpoint_arg:-${manifest_endpoint}}"
  endpoint="${endpoint:-${N2K_CLOUD_ENDPOINT:-${ABLESTACK_CLOUD_ENDPOINT:-${CLOUDSTACK_ENDPOINT:-}}}}"
  api_key="$(n2k_cloud_resolve_api_key "${api_key_arg}")"
  secret_key="$(n2k_cloud_resolve_secret_key "${secret_key_arg}")"

  jq -nc \
    --arg endpoint "${endpoint}" \
    --arg api_key "${api_key}" \
    --arg secret_key "${secret_key}" \
    '{endpoint:$endpoint, api_key:$api_key, secret_key:$secret_key}'
}

n2k_cloud_target_required_config_json() {
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
      display_name: (.target.cloud.display_name // .target.cloud.name // .target.libvirt.name // .source.vm.name // "")
    }
  ' "${manifest}"
}

n2k_cloud_target_validate_config() {
  local manifest="$1" runtime_json="$2"
  local cfg endpoint api_key secret_key network_count
  cfg="$(n2k_cloud_target_required_config_json "${manifest}")"
  endpoint="$(jq -r '.endpoint // ""' <<<"${runtime_json}")"
  api_key="$(jq -r '.api_key // ""' <<<"${runtime_json}")"
  secret_key="$(jq -r '.secret_key // ""' <<<"${runtime_json}")"
  network_count="$(jq -r '(.network_ids // []) | length' <<<"${cfg}")"

  n2k_cloud_require_credentials "${endpoint}" "${api_key}" "${secret_key}"
  jq -e '
    (.zone_id | length) > 0
    and (.service_offering_id | length) > 0
    and ((.network_ids // []) | length) > 0
    and (.storage_id | length) > 0
  ' <<<"${cfg}" >/dev/null || {
    echo "Cloud target requires zone_id, service_offering_id, network_ids, and storage_id." >&2
    return 2
  }
  [[ "${network_count}" -gt 0 ]] || {
    echo "Cloud target requires at least one network id." >&2
    return 2
  }
}

n2k_cloud_target_import_path() {
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

n2k_cloud_target_disk_name() {
  local manifest="$1" idx="$2"
  local vm disk_id
  vm="$(jq -r '.target.cloud.name // .target.libvirt.name // .source.vm.name // "vm"' "${manifest}")"
  disk_id="$(jq -r ".disks[${idx}].disk_id // \"disk${idx}\"" "${manifest}")"
  printf '%s-%s' "${vm}" "${disk_id}"
}

n2k_cloud_target_optional_owner_params() {
  local cfg="$1"
  printf '%s' "${cfg}" | jq -c '
    {}
    + (if (.account | length) > 0 then {account:.account} else {} end)
    + (if (.domain_id | length) > 0 then {domainid:.domain_id} else {} end)
    + (if (.project_id | length) > 0 then {projectid:.project_id} else {} end)
  '
}

n2k_cloud_target_validate_import_visible() {
  local endpoint="$1" api_key="$2" secret_key="$3" storage_id="$4" import_path="$5"
  local response
  response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listVolumesForImport" \
    "$(jq -nc --arg storageid "${storage_id}" --arg path "${import_path}" '{storageid:$storageid,path:$path}')")"
  printf '%s' "${response}" | jq -e '
    to_entries[0].value as $body
    | (
        (($body.count // 0 | tonumber) > 0)
        or (($body.volume // $body.volumes // $body.volumeforimport // []) | length > 0)
      )
  ' >/dev/null
}

n2k_cloud_target_import_volume() {
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
  response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "importVolume" "${params}")"
  job_id="$(printf '%s' "${response}" | n2k_cloud_response_job_id)"
  job="$(n2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")"
  volume_id="$(printf '%s' "${job}" | jq -r '.jobresult.volume.id // .jobresult.id // empty')"
  [[ -n "${volume_id}" ]] || {
    echo "Cloud importVolume job completed but volume id was not returned." >&2
    printf '%s\n' "${job}" >&2
    return 1
  }
  jq -nc --arg id "${volume_id}" --arg job_id "${job_id}" --argjson job "${job}" '{id:$id,job_id:$job_id,job:$job}'
}

n2k_cloud_target_deploy_vm_for_volume() {
  local endpoint="$1" api_key="$2" secret_key="$3" cfg="$4" root_volume_id="$5" start_vm="$6"
  local owner_params params response job_id job vm_id
  owner_params="$(n2k_cloud_target_optional_owner_params "${cfg}")"
  params="$(jq -nc \
    --arg volumeid "${root_volume_id}" \
    --argjson cfg "${cfg}" \
    --argjson owner "${owner_params}" \
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
      + (if (($cfg.host_id // "") | length) > 0 then {hostid:$cfg.host_id} else {} end)
    ')"
  response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "deployVirtualMachineForVolume" "${params}")"
  job_id="$(printf '%s' "${response}" | n2k_cloud_response_job_id)"
  job="$(n2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")"
  vm_id="$(printf '%s' "${job}" | jq -r '.jobresult.virtualmachine.id // .jobresult.uservm.id // .jobresult.id // empty')"
  [[ -n "${vm_id}" ]] || {
    echo "Cloud deployVirtualMachineForVolume job completed but VM id was not returned." >&2
    printf '%s\n' "${job}" >&2
    return 1
  }
  jq -nc --arg id "${vm_id}" --arg job_id "${job_id}" --argjson job "${job}" '{id:$id,job_id:$job_id,job:$job}'
}

n2k_cloud_target_attach_volume() {
  local endpoint="$1" api_key="$2" secret_key="$3" vm_id="$4" volume_id="$5" device_id="$6"
  local response job_id job
  response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "attachVolume" \
    "$(jq -nc --arg id "${volume_id}" --arg virtualmachineid "${vm_id}" --arg deviceid "${device_id}" '{id:$id,virtualmachineid:$virtualmachineid,deviceid:$deviceid}')")"
  job_id="$(printf '%s' "${response}" | n2k_cloud_response_job_id)"
  job="$(n2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")"
  jq -nc --arg job_id "${job_id}" --argjson job "${job}" '{job_id:$job_id,job:$job}'
}

n2k_cloud_target_start_vm() {
  local endpoint="$1" api_key="$2" secret_key="$3" vm_id="$4"
  local response job_id job
  response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "startVirtualMachine" \
    "$(jq -nc --arg id "${vm_id}" '{id:$id}')")"
  job_id="$(printf '%s' "${response}" | n2k_cloud_response_job_id)"
  job="$(n2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")"
  jq -nc --arg job_id "${job_id}" --argjson job "${job}" '{job_id:$job_id,job:$job}'
}

n2k_cloud_target_record_result() {
  local manifest="$1" result_json="$2"
  local result_compact tmp
  result_compact="$(printf '%s' "${result_json}" | jq -c .)"
  tmp="$(mktemp)"
  jq --argjson result "${result_compact}" '
    .runtime.cloud = ((.runtime.cloud // {}) + $result)
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

n2k_cloud_target_preflight_json() {
  local endpoint="$1" api_key="$2" secret_key="$3"
  local api command response available_json="{}" ok=true
  n2k_cloud_require_credentials "${endpoint}" "${api_key}" "${secret_key}"
  response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listApis")"
  for api in listVolumesForImport importVolume deployVirtualMachineForVolume attachVolume startVirtualMachine queryAsyncJobResult; do
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

n2k_cloud_target_cutover() {
  local manifest="$1" define_only="$2" apply_define="$3" start_vm="$4"
  local endpoint_arg="${5:-}" api_key_arg="${6:-}" secret_key_arg="${7:-}" cred_file="${8:-}"
  local runtime cfg endpoint api_key secret_key storage disk_count idx target_path import_path storage_id
  local disk_offering_id owner_params root_import root_volume_id deploy vm_id data_volumes_json jobs_json
  local import_result attach_result start_result result_json disk_name

  runtime="$(n2k_cloud_target_resolve_runtime_json "${manifest}" "${endpoint_arg}" "${api_key_arg}" "${secret_key_arg}" "${cred_file}")"
  endpoint="$(jq -r '.endpoint // ""' <<<"${runtime}")"
  api_key="$(jq -r '.api_key // ""' <<<"${runtime}")"
  secret_key="$(jq -r '.secret_key // ""' <<<"${runtime}")"
  cfg="$(n2k_cloud_target_required_config_json "${manifest}")"
  n2k_cloud_target_validate_config "${manifest}" "${runtime}"

  storage="$(jq -r '.target.storage.type // "file"' "${manifest}")"
  storage_id="$(jq -r '.storage_id // ""' <<<"${cfg}")"
  disk_offering_id="$(jq -r '.disk_offering_id // ""' <<<"${cfg}")"
  owner_params="$(n2k_cloud_target_optional_owner_params "${cfg}")"
  disk_count="$(jq -r '.disks | length' "${manifest}")"
  [[ "${disk_count}" -gt 0 ]] || {
    echo "Cloud target cutover requires at least one migrated disk." >&2
    return 2
  }

  for ((idx=0; idx<disk_count; idx++)); do
    target_path="$(jq -r ".disks[${idx}].transfer.target_path // \"\"" "${manifest}")"
    [[ -n "${target_path}" ]] || {
      echo "Disk ${idx} has no target path." >&2
      return 2
    }
    import_path="$(n2k_cloud_target_import_path "${storage}" "${target_path}")"
    n2k_cloud_target_validate_import_visible "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}" "${import_path}" || {
      echo "Cloud import source is not visible: ${import_path}" >&2
      return 2
    }
  done

  if [[ "${apply_define}" -eq 0 && "${start_vm}" -eq 0 ]]; then
    result_json="$(jq -nc \
      --arg provider "ablestack-cloud" \
      --arg endpoint "${endpoint}" \
      --argjson define_only "$(if [[ "${define_only}" -eq 1 ]]; then printf true; else printf false; fi)" \
      '{provider:$provider,endpoint:$endpoint,validated:true,applied:false,started:false,define_only:$define_only}')"
    n2k_cloud_target_record_result "${manifest}" "${result_json}"
    printf '%s' "${result_json}"
    return 0
  fi

  if [[ "${N2K_DRY_RUN:-0}" -eq 1 ]]; then
    result_json="$(jq -nc --arg provider "ablestack-cloud" '{provider:$provider,validated:true,applied:false,started:false,dry_run:true}')"
    n2k_cloud_target_record_result "${manifest}" "${result_json}"
    printf '%s' "${result_json}"
    return 0
  fi

  target_path="$(jq -r '.disks[0].transfer.target_path' "${manifest}")"
  import_path="$(n2k_cloud_target_import_path "${storage}" "${target_path}")"
  disk_name="$(n2k_cloud_target_disk_name "${manifest}" 0)"
  root_import="$(n2k_cloud_target_import_volume "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}" "${disk_offering_id}" "${import_path}" "${disk_name}" "${owner_params}")"
  root_volume_id="$(jq -r '.id' <<<"${root_import}")"
  deploy="$(n2k_cloud_target_deploy_vm_for_volume "${endpoint}" "${api_key}" "${secret_key}" "${cfg}" "${root_volume_id}" "false")"
  vm_id="$(jq -r '.id' <<<"${deploy}")"

  data_volumes_json="[]"
  jobs_json="$(jq -nc --arg root_import_job "$(jq -r '.job_id' <<<"${root_import}")" --arg deploy_job "$(jq -r '.job_id' <<<"${deploy}")" '[{kind:"import-root",job_id:$root_import_job},{kind:"deploy-vm",job_id:$deploy_job}]')"
  for ((idx=1; idx<disk_count; idx++)); do
    target_path="$(jq -r ".disks[${idx}].transfer.target_path" "${manifest}")"
    import_path="$(n2k_cloud_target_import_path "${storage}" "${target_path}")"
    disk_name="$(n2k_cloud_target_disk_name "${manifest}" "${idx}")"
    import_result="$(n2k_cloud_target_import_volume "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}" "${disk_offering_id}" "${import_path}" "${disk_name}" "${owner_params}")"
    attach_result="$(n2k_cloud_target_attach_volume "${endpoint}" "${api_key}" "${secret_key}" "${vm_id}" "$(jq -r '.id' <<<"${import_result}")" "${idx}")"
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
    start_result="$(n2k_cloud_target_start_vm "${endpoint}" "${api_key}" "${secret_key}" "${vm_id}")"
    jobs_json="$(jq -c --argjson jobs "${jobs_json}" --arg start_job "$(jq -r '.job_id' <<<"${start_result}")" '$jobs + [{kind:"start-vm",job_id:$start_job}]' <<<"{}")"
  fi

  result_json="$(jq -nc \
    --arg provider "ablestack-cloud" \
    --arg endpoint "${endpoint}" \
    --arg vm_id "${vm_id}" \
    --arg root_volume_id "${root_volume_id}" \
    --argjson data_volumes "${data_volumes_json}" \
    --argjson jobs "${jobs_json}" \
    --argjson started "$(if [[ "${start_vm}" -eq 1 ]]; then printf true; else printf false; fi)" \
    '{provider:$provider,endpoint:$endpoint,validated:true,applied:true,started:$started,vm_id:$vm_id,root_volume_id:$root_volume_id,data_volumes:$data_volumes,jobs:$jobs}')"
  n2k_cloud_target_record_result "${manifest}" "${result_json}"
  printf '%s' "${result_json}"
}
