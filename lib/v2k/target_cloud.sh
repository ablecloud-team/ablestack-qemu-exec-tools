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
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/guest_configuration.sh"

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/cloud_allocation.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/cloud_retention.sh"
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/controller_policy.sh"

v2k_cloud_target_disk_offering_name() {
  local storage_type="$1" mode="${2:-none}" base="V2K Migration None"
  [[ "$mode" != writeback ]] || base="V2K Migration Writeback"
  case "$storage_type" in
    local) printf '%s' "${V2K_CLOUD_LOCAL_DISK_OFFERING_NAME:-$base Local}";;
    *) printf '%s' "${V2K_CLOUD_SHARED_DISK_OFFERING_NAME:-$base}";;
  esac
}

v2k_cloud_target_build_nic_mappings_json() {
  local source_nics_json="${1:-[]}" network_ids_json="${2:-[]}"

  jq -nc \
    --argjson nics "${source_nics_json}" \
    --argjson networks "${network_ids_json}" \
    '
      def normalized_mac:
        (. // "" | tostring | ascii_downcase);
      def valid_unicast_mac:
        test("^[0-9a-f][02468ace](:[0-9a-f]{2}){5}$");
      def source_network:
        (.network // .backing.device_name // .backing.network_name //
         .backing.opaque_network_id // "");

      if ($nics | type) != "array" then
        error("source.vm.nics must be an array")
      elif ($networks | type) != "array" then
        error("target.cloud.network_ids must be an array")
      elif ($nics | length) == 0 then
        error("Cloud target requires at least one source NIC")
      elif ($nics | length) != ($networks | length) then
        error("source NIC count must match Cloud network count")
      elif ($networks | any((. // "" | tostring | length) == 0)) then
        error("Cloud network IDs must not be empty")
      elif (($networks | map(tostring) | unique | length) != ($networks | length)) then
        error("Cloud network IDs must be unique per VM")
      else
        [
          $nics
          | to_entries[]
          | . as $entry
          | ($entry.value.mac // $entry.value.macAddress //
             $entry.value.mac_address // "" | normalized_mac) as $mac
          | if ($mac | valid_unicast_mac | not) then
              error("source NIC has an invalid or non-unicast MAC address")
            else
              {
                source_index: $entry.key,
                source_key: (
                  $entry.value.key //
                  ("nic-" + ($entry.key | tostring))
                  | tostring
                ),
                source_label: (
                  $entry.value.label //
                  $entry.value.type //
                  ("Network adapter " + (($entry.key + 1) | tostring))
                  | tostring
                ),
                source_network: ($entry.value | source_network | tostring),
                mac: $mac,
                network_id: ($networks[$entry.key] | tostring),
                default: ($entry.key == 0)
              }
            end
        ]
        | if ((map(.mac) | unique | length) != length) then
            error("source NIC MAC addresses must be unique")
          else
            .
          end
      end
    '
}

v2k_cloud_target_ensure_manifest_nic_mappings() {
  local manifest="$1"
  local source_nics_json network_ids_json mappings tmp

  source_nics_json="$(jq -c '.source.vm.nics // []' "${manifest}")"
  network_ids_json="$(jq -c '.target.cloud.network_ids // []' "${manifest}")"
  if ! mappings="$(v2k_cloud_target_build_nic_mappings_json \
      "${source_nics_json}" "${network_ids_json}")"; then
    if ! jq -e 'type == "array" and length > 0
        and all(.[]; (tostring | length) > 0)
        and ((map(tostring) | unique | length) == length)' \
        <<<"${network_ids_json}" >/dev/null 2>&1; then
      echo "Unable to map source NICs and no usable Cloud network ID was provided." >&2
      return 2
    fi
    mappings="$(jq -c '[to_entries[] | {
      source_index:.key,source_key:("unmapped-nic-" + (.key | tostring)),
      source_label:("Unmapped NIC " + ((.key + 1) | tostring)),source_network:"",
      mac:"",network_id:(.value | tostring),default:(.key == 0)
    }]' <<<"${network_ids_json}")"
    tmp="$(mktemp)"
    jq --argjson mappings "${mappings}" '
      .target.cloud = (.target.cloud // {})
      | .target.cloud.nic_mappings = $mappings
      | .target.cloud.network_fallback = {enabled:true,reason:"source_nic_mapping_unavailable"}
      | .runtime = (.runtime // {})
      | .runtime.cloud = (.runtime.cloud // {})
      | .runtime.cloud.readiness = ((.runtime.cloud.readiness // {}) * {
          status:"degraded",inspection_required:true,
          components:((.runtime.cloud.readiness.components // {}) * {
            network:{status:"degraded",fallback:"cloud-assigned-mac",reason:"source_nic_mapping_unavailable"}
          })
        })
    ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
    return
  fi

  tmp="$(mktemp)"
  jq --argjson mappings "${mappings}" '
    .target.cloud = (.target.cloud // {})
    | .target.cloud.nic_mappings = $mappings
    | del(.target.cloud.network_fallback)
    | del(.runtime.cloud.readiness.components.network)
    | if ([.runtime.cloud.readiness.components[]? | select((.status // "") == "degraded")] | length) == 0 then
        .runtime.cloud.readiness.status = "ready"
        | .runtime.cloud.readiness.inspection_required = false
      else . end
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
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
  if [[ "$(jq -r '.target.provider // "libvirt"' "${manifest}")" == "ablestack-cloud" ]] &&
      (( $(jq -r '(.target.cloud.network_ids // []) | length' "${manifest}") > 0 )); then
    v2k_cloud_target_ensure_manifest_nic_mappings "${manifest}"
  fi
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
      nic_mappings: (.target.cloud.nic_mappings // []),
      network_fallback: (.target.cloud.network_fallback // {}),
      storage_id: (.target.cloud.storage_id // ""),
      disk_offering_id: (.target.cloud.disk_offering_id // ""),
      host_id: (.target.cloud.host_id // ""),
      account: (.target.cloud.account // ""),
      domain_id: (.target.cloud.domain_id // ""),
      project_id: (.target.cloud.project_id // ""),
      name: (.target.cloud.name // .target.libvirt.name // .source.vm.name // ""),
      display_name: (.target.cloud.display_name // .target.cloud.name // .target.libvirt.name // .source.vm.name // ""),
      cpu_speed: ((.target.cloud.cpu_speed // "") | tostring)
    }
  ' "${manifest}"
}

v2k_cloud_target_validate_config() {
  local manifest="$1" runtime_json="$2"
  local cfg endpoint api_key secret_key network_count mapping_count
  cfg="$(v2k_cloud_target_required_config_json "${manifest}")"
  endpoint="$(jq -r '.endpoint // ""' <<<"${runtime_json}")"
  api_key="$(jq -r '.api_key // ""' <<<"${runtime_json}")"
  secret_key="$(jq -r '.secret_key // ""' <<<"${runtime_json}")"
  network_count="$(jq -r '(.network_ids // []) | length' <<<"${cfg}")"
  mapping_count="$(jq -r '(.nic_mappings // []) | length' <<<"${cfg}")"

  v2k_cloud_require_credentials "${endpoint}" "${api_key}" "${secret_key}"
  jq -e '
    (.zone_id | length) > 0
    and (.service_offering_id | length) > 0
    and ((.network_ids // []) | length) > 0
    and (
      (.network_fallback.enabled // false) == true
      or (
        ((.nic_mappings // []) | length) == ((.network_ids // []) | length)
        and all((.nic_mappings // [])[];
          ((.source_key // "") | tostring | length) > 0
          and ((.network_id // "") | tostring | length) > 0
          and ((.mac // "") | tostring | ascii_downcase |
            test("^[0-9a-f][02468ace](:[0-9a-f]{2}){5}$"))
        )
      )
    )
    and (.storage_id | length) > 0
    and (
      ((.cpu_speed // "") | tostring | length) == 0
      or (
        ((.cpu_speed // "") | tostring | test("^[0-9]+$"))
        and (((.cpu_speed // "0") | tonumber) > 0)
      )
    )
  ' <<<"${cfg}" >/dev/null || {
    echo "Cloud target requires zone_id, service_offering_id, network_ids, storage_id, and an optional positive numeric cpu_speed." >&2
    return 2
  }
  [[ "${network_count}" -gt 0 ]] || {
    echo "Cloud target requires at least one network id." >&2
    return 2
  }
  [[ "$(jq -r '.network_fallback.enabled // false' <<<"${cfg}")" == "true" \
      || "${mapping_count}" -eq "${network_count}" ]] || {
    echo "Cloud target requires one source NIC mapping per network id." >&2
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

v2k_cloud_target_service_offering_json() {
  local endpoint="$1" api_key="$2" secret_key="$3" service_offering_id="$4"
  local params response offering

  [[ -n "${service_offering_id}" ]] || return 2
  params="$(jq -nc --arg id "${service_offering_id}" '{id:$id,issystem:false}')"
  response="$(v2k_cloud_api_get \
    "${endpoint}" "${api_key}" "${secret_key}" \
    "listServiceOfferings" "${params}")" || return $?
  offering="$(jq -c --arg id "${service_offering_id}" '
    ((.listserviceofferingsresponse.serviceoffering // [])
      | map(select((.id // "") == $id))
      | first) // empty
  ' <<<"${response}")"
  [[ -n "${offering}" ]] || {
    echo "Cloud service offering was not found: ${service_offering_id}" >&2
    return 2
  }
  printf '%s' "${offering}"
}

v2k_cloud_target_prepare_disk_controller_plan() {
  local manifest="$1"
  local ts tmp status
  if jq -e ' .target.disk_controller_plan.version == 1' "$manifest" >/dev/null; then v2k_controller_validate "$manifest"; return $?; fi

  [[ -f "${manifest}" ]] || return 2
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp "${manifest}.tmp.XXXXXX")"
  chmod 600 "${tmp}" 2>/dev/null || true

  if ! jq \
      --arg ts "${ts}" '
      def supported($kind):
        ((["ide","scsi","sata"] | index($kind)) != null);

      (.disks // []) as $disks
      | ([ $disks[] | select((.role // "") == "root") ]) as $roots
      | ([ $disks[] | select((.role // "") == "data") ]) as $data_disks
      | (($roots[0].controller.kind // "") | tostring | ascii_downcase) as $root_kind
      | ([ $data_disks[].controller.kind // "" ]
          | map(tostring | ascii_downcase)
          | map(select(length > 0))
          | unique) as $data_kinds
      | (
          if ($roots | length) != 1 then "cloud_root_disk_ambiguous"
          elif (supported($root_kind) | not) then "cloud_root_controller_unsupported"
          elif ([ $data_kinds[] | select(supported(.) | not) ] | length) > 0
            then "cloud_data_controller_unsupported"
          elif ($data_kinds | length) > 1
            then "cloud_mixed_data_controller_unsupported"
          else ""
          end
        ) as $reason
      | (($data_kinds[0] // "") | tostring) as $data_kind
      | .target.cloud = (.target.cloud // {})
      | .target.cloud.disk_controller_plan = {
          status:(if ($reason | length) == 0 then "passed" else "failed" end),
          planned_at:$ts,
          source:{root:$root_kind,data:$data_kind,data_kinds:$data_kinds},
          effective:{
            root:(if ($reason | length) == 0 then $root_kind else "" end),
            data:(if ($reason | length) == 0 then $data_kind else "" end)
          },
          override_reason:"",
          failure_reason:$reason
        }
      | if ($reason | length) > 0 then
          .runtime = (.runtime // {})
          | .runtime.last_error = {
              code:44,
              reason:$reason,
              ts:$ts,
              details:{
                root_controller:$root_kind,
                data_controllers:$data_kinds
              }
            }
        else
          .
        end
    ' "${manifest}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 2
  fi
  mv -f "${tmp}" "${manifest}"

  status="$(jq -r '.target.cloud.disk_controller_plan.status // "failed"' "${manifest}" 2>/dev/null || echo failed)"
  [[ "${status}" == "passed" ]] && return 0
  return 44
}

v2k_cloud_target_disk_controller_plan_is_valid() {
  local manifest="$1"
  if jq -e '.target.disk_controller_plan.version == 1' "$manifest" >/dev/null; then v2k_controller_validate "$manifest"; return $?; fi
  jq -e '
    def supported($kind):
      ((["ide","scsi","sata"] | index($kind)) != null);
    (.target.cloud.disk_controller_plan // {}) as $plan
    | $plan.status == "passed"
      and supported($plan.effective.root // "")
      and (
        (($plan.effective.data // "") | length) == 0
        or supported($plan.effective.data)
      )
  ' "${manifest}" >/dev/null 2>&1
}

v2k_cloud_target_apply_disk_controller_override() {
  local manifest="$1"
  local bus="$2"
  local reason="$3"
  local phase="${4:-bootstrap}" code="${5:-0}" detail="${6:-${reason}}"
  local ts tmp

  case "${bus}" in
    ide|scsi|sata) ;;
    *) return 44 ;;
  esac
  [[ -f "${manifest}" ]] || return 2
  jq -e '
    (.target.provider // "libvirt") == "ablestack-cloud"
    and ((.disks // []) | length) > 0
    and (([.disks[] | select((.role // "") == "root")] | length) == 1)
    and (.runtime.source_validation.status // "") == "passed"
  ' "${manifest}" >/dev/null 2>&1 || return 44

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp "${manifest}.tmp.XXXXXX")"
  chmod 600 "${tmp}" 2>/dev/null || true
  if ! jq \
      --arg bus "${bus}" \
      --arg reason "${reason}" \
      --arg phase "${phase}" \
      --arg detail "${detail}" \
      --argjson code "${code}" \
      --arg ts "${ts}" '
      .runtime = (.runtime // {})
      | .runtime.bootstrap_fallback = {
          enabled:true,
          bus:$bus,
          scope:"all-disks",
          phase:$phase,
          code:$code,
          reason:$detail
        }
      | .runtime.cloud = (.runtime.cloud // {})
      | .runtime.cloud.readiness = ((.runtime.cloud.readiness // {}) * {
          status:"degraded",
          inspection_required:true,
          components:((.runtime.cloud.readiness.components // {}) * {
            boot:{status:"degraded",phase:$phase,code:$code,reason:$detail},
            controller:{
              status:"degraded",
              fallback:"sata",
              scope:"all-disks",
              reason:$reason
            }
          })
        })
      | .target.cloud = (.target.cloud // {})
      | .target.cloud.disk_controller_plan = (
          (.target.cloud.disk_controller_plan // {})
          * {
              status:"passed",
              effective:{root:$bus,data:(if ((.disks // []) | length) > 1 then $bus else "" end)},
              override_reason:$reason,
              override_at:$ts,
              failure_reason:""
            }
        )
      | .target.cloud.disk_controller_plan.effective.root = $bus
      | .target.cloud.disk_controller_plan.effective.data = (
          if ((.disks // []) | length) > 1 then $bus else "" end
        )
    ' "${manifest}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 2
  fi
  mv -f "${tmp}" "${manifest}"
}

v2k_cloud_target_source_deploy_params_legacy_json() {
  local manifest="$1" offering_json="${2:-}"
  [[ -n "${offering_json}" ]] || offering_json='{}'
  offering_json="$(jq -c 'if type == "object" then . else {} end' <<<"${offering_json}")" || return 2
  if jq -e '.runtime.source_validation.status == "passed"' "${manifest}" >/dev/null 2>&1 \
    && ! v2k_cloud_target_disk_controller_plan_is_valid "${manifest}"; then
    echo "Cloud deployment requires a validated disk-controller plan." >&2
    return 44
  fi
  jq -c --argjson offering "${offering_json}" '
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
    | ((.target.cloud.cpu_speed // "") | tostring) as $cpu_speed
    | ((($offering.cpuspeed // 0) | tonumber?) // 0) as $offering_cpu_speed
    | (($vm.firmware // "") | tostring | ascii_downcase) as $firmware
    | (($vm.secure_boot // false) == true) as $secure_boot
    | ((.runtime.bootstrap_fallback.bus // "") | tostring | ascii_downcase) as $fallback_bus
    | ((.disks // []) | length) as $disk_count
    | (.target.cloud.disk_controller_plan // {}) as $controller_plan
    | (
        if $controller_plan.status == "passed"
          then (($controller_plan.effective.root // "") | tostring | ascii_downcase)
        elif $fallback_bus == "sata" then "sata"
        else controller(.disks[0].controller.kind // .disks[0].controller.type // "")
        end
      ) as $root_controller
    | (
        if $controller_plan.status == "passed"
          then (($controller_plan.effective.data // "") | tostring | ascii_downcase)
        elif $fallback_bus == "sata" and $disk_count > 1 then "sata"
        else controller((.disks[1:] // []
          | map(.controller.kind // .controller.type // "")
          | map(select((. | tostring | length) > 0))
          | first) // "")
        end
      ) as $data_controller
    | {}
      + (if $cpu > 0 then {"details[0].cpuNumber": ($cpu | floor | tostring)} else {} end)
      + (if $offering_cpu_speed <= 0 and ($cpu_speed | length) > 0 then {"details[0].cpuSpeed": $cpu_speed} else {} end)
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

v2k_cloud_target_nic_request_params_json() {
  local cfg="$1"
  jq -c '
    reduce ((.nic_mappings // []) | to_entries[]) as $entry ({};
      . + {
        ("iptonetworklist[" + ($entry.key | tostring) + "].networkid"):
          ($entry.value.network_id | tostring)
      }
      + (if (($entry.value.mac // "") | tostring | length) > 0 then {
          ("iptonetworklist[" + ($entry.key | tostring) + "].mac"):
            ($entry.value.mac | tostring | ascii_downcase)
        } else {} end)
    )
  ' <<<"${cfg}"
}

v2k_cloud_target_deploy_params_json() {
  local cfg="$1" root_volume_id="$2" start_vm="$3" source_params="${4:-}"
  local owner_params nic_params

  [[ -n "${source_params}" ]] || source_params="{}"
  owner_params="$(v2k_cloud_target_optional_owner_params "${cfg}")"
  nic_params="$(v2k_cloud_target_nic_request_params_json "${cfg}")"
  jq -nc \
    --arg volumeid "${root_volume_id}" \
    --argjson cfg "${cfg}" \
    --argjson owner "${owner_params}" \
    --argjson source_params "${source_params}" \
    --argjson nic_params "${nic_params}" \
    --arg startvm "${start_vm}" \
    '
      {
        zoneid: $cfg.zone_id,
        serviceofferingid: $cfg.service_offering_id,
        volumeid: $volumeid,
        name: $cfg.name,
        displayname: $cfg.display_name,
        startvm: $startvm,
        hypervisor: "KVM"
      }
      + (
          if ($nic_params | length) > 0 then
            $nic_params
          else
            {networkids: (($cfg.network_ids // []) | join(","))}
          end
        )
      + $owner
      + (
          if ($nic_params | length) > 0 then
            ($source_params | del(.macaddress))
          else
            $source_params
          end
        )
      + (if (($cfg.host_id // "") | length) > 0 then {hostid:$cfg.host_id} else {} end)
    '
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
  local offerings_json="$1" name="$2" storage_type="$3" expected_mode="${4:-}" expected_format="${5:-}" expected_cache="${6:-none}"
  printf '%s' "${offerings_json}" | jq -c \
    --arg name "${name}" \
    --arg storage_type "${storage_type}" \
    --arg policy "${expected_mode}" --arg format "${expected_format}" --arg cache_mode "${expected_cache}" \
    '
      def st: ((.storagetype // "") | tostring | ascii_downcase);
      def cache: ((.cachemode // "") | tostring | ascii_downcase);
      def state: ((.state // "Active") | tostring | ascii_downcase);
      def customized: ((.iscustomized // .customized // false) == true);
      def untagged: (((.tags // "") | tostring | length) == 0);
      map(select(
        (.name // "") == $name
        and st == $storage_type
        and cache == $cache_mode
        and state == "active"
        and customized
        and untagged
        and ($policy == "" or (.allocation.requestedpolicy == $policy and .allocation.requestedformat == $format
          and (.allocation.contractversion | tostring) == "1" and .allocation.policyorigin == "explicit"))
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
  local manifest="${6:-}"
  local display_text response cache_mode
  cache_mode="$(migration_disk_cache_value v2k "$manifest")" || return $?
  display_text="${V2K_CLOUD_DISK_OFFERING_DISPLAY_TEXT:-ABLESTACK V2K migration disk offering with $cache_mode cache}"
  if ! response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "createDiskOffering" \
    "$(jq -nc \
      --arg name "${name}" \
      --arg displaytext "${display_text}" \
      --arg storagetype "${storage_type}" --arg cache_mode "${cache_mode}" \
      '{
        name:$name,
        displaytext:$displaytext,
        customized:true,
        provisioningtype:"thin",
        storagetype:$storagetype,
        cachemode:$cache_mode,
        displayoffering:true
      }' | migration_cloud_allocation_offering_params "${manifest}" "$(cat)")")"; then
    return 1
  fi
  printf '%s\n' "Created Cloud V2K disk offering: ${name} (${storage_type}, ${cache_mode})" >&2
  printf '%s' "${response}" >/dev/null
}

v2k_cloud_target_resolve_disk_offering() {
  local endpoint="$1" api_key="$2" secret_key="$3" pool_json="$4"
  local manifest="${5:-}" expected_mode="" expected_format=""
  local storage_type name offerings offering conflict_count cache_mode
  cache_mode="$(migration_disk_cache_value v2k "$manifest")" || return $?
  storage_type="$(v2k_cloud_target_disk_offering_storage_type_from_pool "${pool_json}")"
  name="$(v2k_cloud_target_disk_offering_name "${storage_type}" "${cache_mode}")"
  migration_cloud_allocation_intent "${manifest}" || return $?
  if [[ "${CLOUD_ALLOCATION_ACTIVE}" == 1 ]]; then
    expected_mode="${CLOUD_ALLOCATION_MODE}"; expected_format="${CLOUD_ALLOCATION_FORMAT}"
    name+=" ${expected_format} ${expected_mode}"
  fi

  offerings="$(v2k_cloud_target_disk_offerings_by_name_json "${endpoint}" "${api_key}" "${secret_key}" "${name}" "${storage_type}")" || return $?
  offering="$(v2k_cloud_target_usable_disk_offering_json "${offerings}" "${name}" "${storage_type}" "${expected_mode}" "${expected_format}" "${cache_mode}")"
  if [[ -n "${offering}" ]]; then
    v2k_cloud_target_disk_offering_summary_json "${offering}" false
    return 0
  fi

  conflict_count="$(v2k_cloud_target_disk_offering_conflict_count "${offerings}" "${name}" "${storage_type}")"
  if [[ "${conflict_count}" -gt 0 ]]; then
    echo "Cloud V2K disk offering exists but is not compatible: name=${name} storage_type=${storage_type} required_cache=${cache_mode} customized=true tags=empty" >&2
    printf '%s\n' "${offerings}" >&2
    return 2
  fi

  v2k_cloud_target_create_v2k_disk_offering "${endpoint}" "${api_key}" "${secret_key}" "${name}" "${storage_type}" "${manifest}" || return $?
  offerings="$(v2k_cloud_target_disk_offerings_by_name_json "${endpoint}" "${api_key}" "${secret_key}" "${name}" "${storage_type}")" || return $?
  offering="$(v2k_cloud_target_usable_disk_offering_json "${offerings}" "${name}" "${storage_type}" "${expected_mode}" "${expected_format}" "${cache_mode}")"
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
  local manifest="${9:-}" disk_index="${10:-0}"
  local params response job_id job volume_id checkpoint_patch checkpoint_stage
  params="$(jq -nc \
    --arg path "${import_path}" \
    --arg storageid "${storage_id}" \
    --arg name "${name}" \
    --arg diskofferingid "${disk_offering_id}" \
    --argjson owner "${owner_params}" \
    '{path:$path,storageid:$storageid,name:$name} + $owner
     + (if ($diskofferingid | length) > 0 then {diskofferingid:$diskofferingid} else {} end)')"
  params="$(migration_cloud_allocation_import_params "${manifest}" "${disk_index}" "${params}")" || return $?
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "importVolume" "${params}")" || return $?
  job_id="$(printf '%s' "${response}" | v2k_cloud_response_job_id)"
  [[ -n "${job_id}" ]] || {
    echo "Cloud importVolume did not return an async job id." >&2
    printf '%s\n' "${response}" >&2
    return 1
  }
  if [[ -n "${manifest}" ]]; then
    if [[ "${disk_index}" -eq 0 ]]; then
      checkpoint_stage="root-import-submitted"
      checkpoint_patch="$(jq -nc \
        --arg job_id "${job_id}" --arg path "${import_path}" \
        '{complete:false,root_import_job_id:$job_id,root_import_path:$path,data_volumes:{}}')"
    else
      checkpoint_stage="data-import-submitted"
      checkpoint_patch="$(jq -nc \
        --arg idx "${disk_index}" --arg job_id "${job_id}" --arg path "${import_path}" \
        '.data_volumes = {($idx):{import_job_id:$job_id,import_path:$path,attached:false}}')"
    fi
    v2k_cloud_target_record_checkpoint \
      "${manifest}" "${checkpoint_stage}" "${checkpoint_patch}" || return 78
  fi
  job="$(v2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")" || return $?
  volume_id="$(printf '%s' "${job}" | jq -r '.jobresult.volume.id // .jobresult.id // empty')"
  [[ -n "${volume_id}" ]] || {
    echo "Cloud importVolume job completed but volume id was not returned." >&2
    printf '%s\n' "${job}" >&2
    return 1
  }
  jq -nc --arg id "${volume_id}" --arg job_id "${job_id}" --argjson job "${job}" '{id:$id,job_id:$job_id,job:$job}'
}

v2k_cloud_target_import_volume_from_job() {
  local endpoint="$1" api_key="$2" secret_key="$3" job_id="$4"
  local job volume_id
  job="$(v2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")" || return $?
  volume_id="$(jq -r '.jobresult.volume.id // .jobresult.id // empty' <<<"${job}")"
  [[ -n "${volume_id}" ]] || return 1
  jq -nc --arg id "${volume_id}" --arg job_id "${job_id}" --argjson job "${job}" \
    '{id:$id,job_id:$job_id,job:$job,reused_submitted_job:true}'
}

v2k_cloud_target_cpu_speed_override_rejected() {
  local error_text="${1:-}"
  grep -Eiq \
    'cpu[[:space:]]*speed.*not customi[sz]able|cpuSpeed.*static service offering|cpuNumber or cpuSpeed or memory should not be specified for static service offering' \
    <<<"${error_text}"
}

v2k_cloud_target_deploy_vm_for_volume() {
  local endpoint="$1" api_key="$2" secret_key="$3" cfg="$4" root_volume_id="$5" start_vm="$6" source_params="${7:-}"
  local manifest="${8:-}"
  local params response job_id job vm_id error_file first_error retry_params
  params="$(v2k_cloud_target_deploy_params_json \
    "${cfg}" "${root_volume_id}" "${start_vm}" "${source_params}")"
  [[ -n "${root_volume_id}" ]] || {
    echo "Cloud deployVirtualMachineForVolume requires a root volume id." >&2
    return 2
  }
  error_file="$(mktemp "${TMPDIR:-/tmp}/v2k-cloud-deploy.XXXXXX")"
  if response="$(v2k_cloud_api_get \
      "${endpoint}" "${api_key}" "${secret_key}" \
      "deployVirtualMachineForVolume" "${params}" 2>"${error_file}")"; then
    rm -f "${error_file}"
  else
    first_error="$(cat "${error_file}")"
    if jq -e 'has("details[0].cpuSpeed")' <<<"${params}" >/dev/null 2>&1 \
        && v2k_cloud_target_cpu_speed_override_rejected "${first_error}"; then
      echo "Cloud service offering rejected the optional CPU-speed override; retrying without details[0].cpuSpeed." >&2
      retry_params="$(jq -c 'del(."details[0].cpuSpeed")' <<<"${params}")"
      if response="$(v2k_cloud_api_get \
          "${endpoint}" "${api_key}" "${secret_key}" \
          "deployVirtualMachineForVolume" "${retry_params}" 2>"${error_file}")"; then
        params="${retry_params}"
        rm -f "${error_file}"
      else
        [[ -n "${first_error}" ]] && printf '%s\n' "${first_error}" >&2
        cat "${error_file}" >&2
        rm -f "${error_file}"
        return 1
      fi
    else
      [[ -n "${first_error}" ]] && printf '%s\n' "${first_error}" >&2
      rm -f "${error_file}"
      return 1
    fi
  fi
  job_id="$(printf '%s' "${response}" | v2k_cloud_response_job_id)"
  [[ -n "${job_id}" ]] || {
    echo "Cloud deployVirtualMachineForVolume did not return an async job id." >&2
    printf '%s\n' "${response}" >&2
    return 1
  }
  if [[ -n "${manifest}" ]]; then
    v2k_cloud_target_record_checkpoint "${manifest}" "vm-deploy-submitted" \
      "$(jq -nc --arg job_id "${job_id}" --arg root_volume_id "${root_volume_id}" \
        '{deploy_job_id:$job_id,root_volume_id:$root_volume_id}')" || return 78
  fi
  job="$(v2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")" || return $?
  vm_id="$(printf '%s' "${job}" | jq -r '.jobresult.virtualmachine.id // .jobresult.uservm.id // .jobresult.id // empty')"
  [[ -n "${vm_id}" ]] || {
    echo "Cloud deployVirtualMachineForVolume job completed but VM id was not returned." >&2
    printf '%s\n' "${job}" >&2
    return 1
  }
  jq -nc --arg id "${vm_id}" --arg job_id "${job_id}" --argjson job "${job}" '{id:$id,job_id:$job_id,job:$job}'
}

v2k_cloud_target_deploy_vm_from_job() {
  local endpoint="$1" api_key="$2" secret_key="$3" job_id="$4"
  local job vm_id
  job="$(v2k_cloud_wait_job "${endpoint}" "${api_key}" "${secret_key}" "${job_id}")" || return $?
  vm_id="$(jq -r '.jobresult.virtualmachine.id // .jobresult.uservm.id // .jobresult.id // empty' <<<"${job}")"
  [[ -n "${vm_id}" ]] || return 1
  jq -nc --arg id "${vm_id}" --arg job_id "${job_id}" --argjson job "${job}" \
    '{id:$id,job_id:$job_id,job:$job,reused_submitted_job:true}'
}

v2k_cloud_target_vm_json() {
  local endpoint="$1" api_key="$2" secret_key="$3" vm_id="$4"
  local response

  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" \
    "listVirtualMachines" \
    "$(jq -nc --arg id "${vm_id}" '{id:$id,listall:true}')")" || return $?
  printf '%s' "${response}" |
    jq -c '(.listvirtualmachinesresponse.virtualmachine // [])[0] // {}'
}

v2k_cloud_target_verify_vm_nics_json() {
  local cfg="$1" vm_json="$2"
  jq -nc \
    --argjson expected "$(jq -c '.nic_mappings // []' <<<"${cfg}")" \
    --argjson vm "${vm_json}" \
    '
      ($vm.nic // []) as $actual
      | [
          $expected[] as $wanted
          | {
              source_key: $wanted.source_key,
              network_id: $wanted.network_id,
              expected_mac: ($wanted.mac | ascii_downcase),
              actual: (
                [
                  $actual[]
                  | select(
                      ((.networkid // "") | tostring) ==
                        (($wanted.network_id // "") | tostring)
                    )
                ][0] // null
              )
            }
          | . + {
              matched: (
                .actual != null
                and ((.actual.macaddress // "") | tostring | ascii_downcase) ==
                  .expected_mac
                and (
                  ($wanted.default // false) != true
                  or ((.actual.isdefault // false) | tostring | ascii_downcase) ==
                    "true"
                )
              )
            }
        ] as $checks
      | {
          matched: (($checks | length) > 0 and all($checks[]; .matched)),
          checks: $checks,
          actual_nics: $actual
        }
    '
}

v2k_cloud_target_wait_for_vm_nic_match() {
  local endpoint="$1" api_key="$2" secret_key="$3" cfg="$4" vm_id="$5"
  local attempts="${V2K_CLOUD_NIC_VERIFY_ATTEMPTS:-5}"
  local interval="${V2K_CLOUD_NIC_VERIFY_INTERVAL:-2}"
  local attempt vm_json verification="{}"

  [[ "${attempts}" =~ ^[0-9]+$ && "${attempts}" -gt 0 ]] || attempts=5
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval=2
  for ((attempt=1; attempt<=attempts; attempt++)); do
    vm_json="$(v2k_cloud_target_vm_json \
      "${endpoint}" "${api_key}" "${secret_key}" "${vm_id}")" || return $?
    verification="$(v2k_cloud_target_verify_vm_nics_json "${cfg}" "${vm_json}")"
    if jq -e '.matched == true' <<<"${verification}" >/dev/null; then
      printf '%s' "${verification}"
      return 0
    fi
    if [[ "${attempt}" -lt "${attempts}" && "${interval}" -gt 0 ]]; then
      sleep "${interval}"
    fi
  done

  echo "Cloud VM NIC network/MAC verification failed; VM ${vm_id} remains stopped." >&2
  printf '%s\n' "${verification}" >&2
  printf '%s' "${verification}"
  return 1
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

v2k_cloud_target_record_checkpoint() {
  local manifest="$1" stage="$2" patch_json="${3:-}"
  local patch_compact ts tmp

  [[ -n "${patch_json}" ]] || patch_json='{}'
  if ! patch_compact="$(printf '%s' "${patch_json}" | jq -c 'if type == "object" then . else error("checkpoint patch must be an object") end')"; then
    return 2
  fi
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp "${manifest}.tmp.XXXXXX")"
  chmod 600 "${tmp}" 2>/dev/null || true
  if ! jq \
      --arg stage "${stage}" \
      --arg ts "${ts}" \
      --argjson patch "${patch_compact}" '
        .runtime = (.runtime // {})
        | .runtime.cloud = (.runtime.cloud // {})
        | .runtime.cloud.checkpoint = (
            (.runtime.cloud.checkpoint // {})
            * $patch
            * {stage:$stage,updated_at:$ts}
          )
      ' "${manifest}" > "${tmp}"; then
    rm -f "${tmp}" >/dev/null 2>&1 || true
    return 1
  fi
  mv -f "${tmp}" "${manifest}"
}

v2k_cloud_target_existing_checkpoint_json() {
  local manifest="$1"
  jq -c '.runtime.cloud.checkpoint // {}' "${manifest}"
}

v2k_cloud_target_checkpoint_reentry_state() {
  local checkpoint="$1"
  jq -r '
    if (type != "object") or (length == 0) then "none"
    elif (.complete // false) == true then "complete"
    else "incomplete"
    end
  ' <<<"${checkpoint}"
}

v2k_cloud_target_preflight_json() {
  local endpoint="$1" api_key="$2" secret_key="$3"
  local api command response available_json="{}" ok=true
  v2k_cloud_require_credentials "${endpoint}" "${api_key}" "${secret_key}"
  response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listApis")"
  for api in listStoragePools listDiskOfferings createDiskOffering listVolumesForImport importVolume deployVirtualMachineForVolume listVirtualMachines updateVolume attachVolume startVirtualMachine queryAsyncJobResult; do
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

v2k_cloud_target_cutover_impl() {
  local manifest="$1" define_only="$2" apply_define="$3" start_vm="$4"
  v2k_guest_config_frozen_options "$1" || return $?
  local endpoint_arg="${5:-}" api_key_arg="${6:-}" secret_key_arg="${7:-}" cred_file="${8:-}"
  local runtime cfg endpoint api_key secret_key storage disk_count idx target_path import_path storage_id
  local disk_offering_id owner_params root_import root_volume_id deploy vm_id data_volumes_json jobs_json
  local import_result attach_result start_result result_json disk_name source_deploy_params root_volume_result root_volume_json root_volume_update_job root_volume_converted
  local nic_verification checkpoint checkpoint_state
  local service_offering_json="{}" offering_cpu_speed=""
  local issues_json="[]" inspection_required=false started=false
  local pool_json pool_path import_volume_id disk_offering_json

  runtime="$(v2k_cloud_target_resolve_runtime_json "${manifest}" "${endpoint_arg}" "${api_key_arg}" "${secret_key_arg}" "${cred_file}")"
  endpoint="$(jq -r '.endpoint // ""' <<<"${runtime}")"
  api_key="$(jq -r '.api_key // ""' <<<"${runtime}")"
  secret_key="$(jq -r '.secret_key // ""' <<<"${runtime}")"
  v2k_controller_resume_check "$manifest" || return $?
  v2k_controller_check_target "$manifest" "$endpoint" "$api_key" "$secret_key" || return $?
  v2k_cloud_target_ensure_manifest_nic_mappings "${manifest}" || return $?
  cfg="$(v2k_cloud_target_required_config_json "${manifest}")"
  v2k_cloud_target_validate_config "${manifest}" "${runtime}" || return $?

  storage="$(jq -r '.target.storage.type // "file"' "${manifest}")"
  storage_id="$(jq -r '.storage_id // ""' <<<"${cfg}")"
  disk_offering_id="$(jq -r '.disk_offering_id // ""' <<<"${cfg}")"
  owner_params="$(v2k_cloud_target_optional_owner_params "${cfg}")"
  if jq -e '(.target.guest_configuration_plan.version==1 or .target.guest_configuration_plan.version==2) and (.runtime.cloud.checkpoint.vm_id // "")!=""' "$manifest" >/dev/null; then
    local guest_existing_id guest_existing_vm
    guest_existing_id="$(jq -r '.runtime.cloud.checkpoint.vm_id' "$manifest")"
    guest_existing_vm="$(v2k_cloud_target_vm_json "$endpoint" "$api_key" "$secret_key" "$guest_existing_id")" || return $?
    if jq -e '.state=="Running"' <<<"$guest_existing_vm" >/dev/null; then
      migration_disk_cache_verify_cloud v2k "$manifest" "$endpoint" "$api_key" "$secret_key" || return $?
      migration_cloud_allocation_verify_final v2k "$manifest" "$endpoint" "$api_key" "$secret_key" || return $?
      v2k_controller_cloud_verify "$manifest" "$endpoint" "$api_key" "$secret_key" running || return $?
      v2k_guest_config_reconcile "$manifest" "$endpoint" "$api_key" "$secret_key" verify || return $?
      v2k_cloud_target_record_checkpoint "$manifest" complete '{"complete":true,"started":true,"inspection_required":false}' || return $?
      jq -nc --arg id "$guest_existing_id" '{provider:"ablestack-cloud",vm_id:$id,started:true,validated:true,status:"completed",guest_configuration_verified:true}'
      return 0
    fi
  fi
  if service_offering_json="$(v2k_cloud_target_service_offering_json \
      "${endpoint}" "${api_key}" "${secret_key}" \
      "$(jq -r '.service_offering_id // ""' <<<"${cfg}")")"; then
    offering_cpu_speed="$(jq -r '((.cpuspeed // 0) | tonumber?) // 0' <<<"${service_offering_json}")"
    if [[ "${offering_cpu_speed}" =~ ^[0-9]+$ && "${offering_cpu_speed}" -gt 0 ]]; then
      echo "Cloud service offering defines CPU speed ${offering_cpu_speed} MHz; using the offering value without an override." >&2
    fi
  else
    echo "Cloud service offering metadata is unavailable; continuing without making CPU speed a hard dependency." >&2
    service_offering_json='{}'
  fi
  migration_cloud_allocation_check_manifest v2k "${manifest}" "${endpoint}" "${api_key}" "${secret_key}" || return $?
  source_deploy_params="$(v2k_cloud_target_source_deploy_params_json \
    "${manifest}" "${service_offering_json}")" || return $?
  disk_count="$(jq -r '.disks | length' "${manifest}")"
  [[ "${disk_count}" -gt 0 ]] || {
    echo "Cloud target cutover requires at least one migrated disk." >&2
    return 2
  }
  if jq -e '.runtime.cloud.readiness.inspection_required == true' "${manifest}" >/dev/null 2>&1; then
    inspection_required=true
    issues_json="$(jq -c '[
      (.runtime.cloud.readiness.components // {} | to_entries[])
      | select((.value.status // "") == "degraded")
      | {
          component:.key,
          stage:(.value.stage // .value.phase // "readiness"),
          reason:(.value.reason // "cloud_readiness_degraded"),
          action:(if (.value.fallback // "") == "sata" then "force_all_disks_sata" else "engineer_inspection" end)
        }
    ]' "${manifest}")"
  fi

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
    # Managed/committed imports are reconciled by UUID, never re-probed as unmanaged images.
    # In particular, a completed Running VM must not trigger offline source qemu inspection.
    if [[ "${CLOUD_ALLOCATION_ACTIVE}" == 1 ]] && jq -e --argjson idx "${idx}" '
        .runtime.cloud.checkpoint as $c
        | (if $idx == 0 then ($c.root_volume_id // $c.root_import_job_id // "")
           else ($c.data_volumes[($idx | tostring)].id // $c.data_volumes[($idx | tostring)].import_job_id // "") end)
        | length > 0' "${manifest}" >/dev/null; then
      continue
    fi
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
      --argjson nic_mappings "$(jq -c '.nic_mappings // []' <<<"${cfg}")" \
      --argjson define_only "$(if [[ "${define_only}" -eq 1 ]]; then printf true; else printf false; fi)" \
      '{provider:$provider,endpoint:$endpoint,validated:true,applied:false,started:false,define_only:$define_only,deployment_properties:$deployment_properties,nic_mappings:$nic_mappings}')"
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

  checkpoint="$(v2k_cloud_target_existing_checkpoint_json "${manifest}")"
  checkpoint_state="$(v2k_cloud_target_checkpoint_reentry_state "${checkpoint}")"
  case "${checkpoint_state}" in
    complete)
      migration_cloud_allocation_intent "${manifest}" || return $?
      if [[ "${CLOUD_ALLOCATION_ACTIVE}" == 1 ]] &&
          { jq -e '.inspection_required == true' <<<"${checkpoint}" >/dev/null ||
             { [[ "${start_vm}" -eq 1 ]] && ! jq -e '.started == true' <<<"${checkpoint}" >/dev/null; }; }; then
        # An earlier warning/define-only result is not a completed requested first start.
        v2k_cloud_target_record_checkpoint "${manifest}" deployment-incomplete '{"complete":false}' || return 78
        checkpoint="$(v2k_cloud_target_existing_checkpoint_json "${manifest}")"
      else
        v2k_controller_cloud_verify "$manifest" "$endpoint" "$api_key" "$secret_key" running || return $?
    v2k_guest_config_reconcile "$manifest" "$endpoint" "$api_key" "$secret_key" verify || return $?
        migration_disk_cache_verify_cloud v2k "$manifest" "$endpoint" "$api_key" "$secret_key" || return $?
        migration_cloud_allocation_verify_final v2k "${manifest}" "${endpoint}" "${api_key}" "${secret_key}" || return $?
        result_json="$(jq -c '.runtime.cloud + {idempotent:true,reused_checkpoint:true}' "${manifest}")"
        printf '%s' "${result_json}"
        return 0
      fi
      ;;
    incomplete)
      echo "Cloud cutover is resuming from an incomplete mutation checkpoint." >&2
      jq -c '{stage,root_volume_id,vm_id,data_volumes,updated_at}' <<<"${checkpoint}" >&2
      ;;
  esac

  if [[ -z "${disk_offering_id}" ]]; then
    if [[ -z "${pool_json:-}" ]]; then
      pool_json="$(v2k_cloud_target_storage_pool_json "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}")" || return $?
      [[ -n "${pool_json}" ]] || {
        echo "Cloud storage pool was not found: ${storage_id}" >&2
        return 2
      }
      v2k_cloud_target_record_storage_pool "${manifest}" "${pool_json}"
    fi
    disk_offering_json="$(v2k_cloud_target_resolve_disk_offering "${endpoint}" "${api_key}" "${secret_key}" "${pool_json}" "${manifest}")" || return $?
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

  migration_cloud_allocation_intent "${manifest}" || return $?
  if [[ -n "${disk_offering_id}" ]]; then
    if [[ -z "${pool_json:-}" ]]; then
      pool_json="$(v2k_cloud_target_storage_pool_json "$endpoint" "$api_key" "$secret_key" "$storage_id")" || return $?
      [[ -n "$pool_json" ]] || return 2
    fi
    migration_cloud_allocation_validate_offering v2k "${manifest}" "${endpoint}" "${api_key}" "${secret_key}" "${disk_offering_id}" \
      "$(v2k_cloud_target_disk_offering_storage_type_from_pool "${pool_json}")" || return $?
  fi

  target_path="$(jq -r '.disks[0].transfer.target_path' "${manifest}")"
  import_path="$(v2k_cloud_target_import_path "${storage}" "${target_path}")"
  disk_name="$(v2k_cloud_target_disk_name "${manifest}" 0)"
  root_volume_id="$(jq -r '.root_volume_id // empty' <<<"${checkpoint}")"
  if [[ -n "${root_volume_id}" ]]; then
    root_import="$(jq -nc \
      --arg id "${root_volume_id}" \
      --arg job_id "$(jq -r '.root_import_job_id // empty' <<<"${checkpoint}")" \
      '{id:$id,job_id:$job_id,reused_checkpoint:true}')"
  elif [[ -n "$(jq -r '.root_import_job_id // empty' <<<"${checkpoint}")" ]]; then
    root_import="$(v2k_cloud_target_import_volume_from_job \
      "${endpoint}" "${api_key}" "${secret_key}" \
      "$(jq -r '.root_import_job_id' <<<"${checkpoint}")")" || return $?
    root_volume_id="$(jq -r '.id' <<<"${root_import}")"
  else
    root_import="$(v2k_cloud_target_import_volume "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}" "${disk_offering_id}" "${import_path}" "${disk_name}" "${owner_params}" "${manifest}" 0)" || return $?
    root_volume_id="$(jq -r '.id' <<<"${root_import}")"
    [[ -n "${root_volume_id}" ]] || {
      echo "Cloud root import did not return a volume id." >&2
      return 1
    }
    v2k_cloud_target_record_checkpoint "${manifest}" "root-imported" \
      "$(jq -nc \
        --arg root_volume_id "${root_volume_id}" \
        --arg root_import_job_id "$(jq -r '.job_id // empty' <<<"${root_import}")" \
        --arg root_import_path "${import_path}" \
        --arg storage_id "${storage_id}" \
        --arg disk_offering_id "${disk_offering_id}" \
        '{complete:false,root_volume_id:$root_volume_id,root_import_job_id:$root_import_job_id,root_import_path:$root_import_path,storage_id:$storage_id,disk_offering_id:$disk_offering_id,data_volumes:{}}')" || return 78
    checkpoint="$(v2k_cloud_target_existing_checkpoint_json "${manifest}")"
  fi
  if [[ "$(jq -r '.root_volume_id // empty' <<<"${checkpoint}")" != "${root_volume_id}" ]]; then
    v2k_cloud_target_record_checkpoint "${manifest}" "root-imported" \
      "$(jq -nc --arg id "${root_volume_id}" --arg job_id "$(jq -r '.job_id // empty' <<<"${root_import}")" \
        '{root_volume_id:$id,root_import_job_id:$job_id}')" || return 78
    checkpoint="$(v2k_cloud_target_existing_checkpoint_json "${manifest}")"
  fi

  vm_id="$(jq -r '.vm_id // empty' <<<"${checkpoint}")"
  if [[ -n "${vm_id}" ]]; then
    deploy="$(jq -nc \
      --arg id "${vm_id}" \
      --arg job_id "$(jq -r '.deploy_job_id // empty' <<<"${checkpoint}")" \
      '{id:$id,job_id:$job_id,reused_checkpoint:true}')"
  elif [[ -n "$(jq -r '.deploy_job_id // empty' <<<"${checkpoint}")" ]]; then
    deploy="$(v2k_cloud_target_deploy_vm_from_job \
      "${endpoint}" "${api_key}" "${secret_key}" \
      "$(jq -r '.deploy_job_id' <<<"${checkpoint}")")" || return $?
    vm_id="$(jq -r '.id' <<<"${deploy}")"
  else
    deploy="$(v2k_cloud_target_deploy_vm_for_volume "${endpoint}" "${api_key}" "${secret_key}" "${cfg}" "${root_volume_id}" "false" "${source_deploy_params}" "${manifest}")" || return $?
    vm_id="$(jq -r '.id' <<<"${deploy}")"
    [[ -n "${vm_id}" ]] || {
      echo "Cloud deployVirtualMachineForVolume did not return a VM id." >&2
      return 1
    }
    v2k_cloud_target_record_checkpoint "${manifest}" "vm-deployed" \
      "$(jq -nc \
        --arg vm_id "${vm_id}" \
        --arg deploy_job_id "$(jq -r '.job_id // empty' <<<"${deploy}")" \
        '{vm_id:$vm_id,deploy_job_id:$deploy_job_id}')" || return 78
    checkpoint="$(v2k_cloud_target_existing_checkpoint_json "${manifest}")"
  fi
  if [[ "$(jq -r '.vm_id // empty' <<<"${checkpoint}")" != "${vm_id}" ]]; then
    v2k_cloud_target_record_checkpoint "${manifest}" "vm-deployed" \
      "$(jq -nc --arg id "${vm_id}" --arg job_id "$(jq -r '.job_id // empty' <<<"${deploy}")" \
        '{vm_id:$id,deploy_job_id:$job_id}')" || return 78
    checkpoint="$(v2k_cloud_target_existing_checkpoint_json "${manifest}")"
  fi
  if ! nic_verification="$(v2k_cloud_target_wait_for_vm_nic_match \
      "${endpoint}" "${api_key}" "${secret_key}" "${cfg}" "${vm_id}")"; then
    [[ -n "${nic_verification}" ]] || nic_verification='{}'
    inspection_required=true
    issues_json="$(jq -c \
      --argjson issues "${issues_json}" \
      --argjson details "${nic_verification}" \
      '$issues + [{component:"network",stage:"nic-verification",reason:"cloud_nic_verification_failed",details:$details}]' <<<"{}")"
    v2k_cloud_target_record_checkpoint "${manifest}" "nic-degraded" \
      "$(jq -nc --argjson nic_verification "${nic_verification}" \
        '{nic_verification:$nic_verification,inspection_required:true}')" || return 78
  else
    v2k_cloud_target_record_checkpoint "${manifest}" "nic-verified" \
      "$(jq -nc --argjson nic_verification "${nic_verification}" '{nic_verification:$nic_verification}')" || return 78
  fi

  root_volume_json='{}'
  root_volume_update_job=""
  root_volume_converted=false
  if root_volume_result="$(v2k_cloud_target_ensure_root_volume "${endpoint}" "${api_key}" "${secret_key}" "${root_volume_id}" "${vm_id}" "${import_path}")"; then
    root_volume_json="$(jq -c '.volume' <<<"${root_volume_result}")"
    root_volume_update_job="$(jq -r '.update.job_id // empty' <<<"${root_volume_result}")"
    root_volume_converted="$(jq -r '.converted // false' <<<"${root_volume_result}")"
    v2k_cloud_target_record_checkpoint "${manifest}" "root-ready" \
      "$(jq -nc \
        --argjson root_volume "${root_volume_json}" \
        --argjson root_volume_converted "${root_volume_converted}" \
        --arg root_volume_update_job_id "${root_volume_update_job}" \
        '{root_volume:$root_volume,root_volume_converted:$root_volume_converted,root_volume_update_job_id:$root_volume_update_job_id}')" || return 78
  else
    inspection_required=true
    issues_json="$(jq -c --argjson issues "${issues_json}" \
      '$issues + [{component:"storage",stage:"root-ready",reason:"cloud_root_volume_validation_failed"}]' <<<"{}")"
    v2k_cloud_target_record_checkpoint "${manifest}" "root-degraded" \
      '{"inspection_required":true}' || return 78
  fi

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
    checkpoint="$(v2k_cloud_target_existing_checkpoint_json "${manifest}")"
    import_volume_id="$(jq -r --arg idx "${idx}" '.data_volumes[$idx].id // empty' <<<"${checkpoint}")"
    if [[ -n "${import_volume_id}" ]]; then
      import_result="$(jq -nc \
        --arg id "${import_volume_id}" \
        --arg job_id "$(jq -r --arg idx "${idx}" '.data_volumes[$idx].import_job_id // empty' <<<"${checkpoint}")" \
        '{id:$id,job_id:$job_id,reused_checkpoint:true}')"
    elif [[ -n "$(jq -r --arg idx "${idx}" '.data_volumes[$idx].import_job_id // empty' <<<"${checkpoint}")" ]]; then
      import_result="$(v2k_cloud_target_import_volume_from_job \
        "${endpoint}" "${api_key}" "${secret_key}" \
        "$(jq -r --arg idx "${idx}" '.data_volumes[$idx].import_job_id' <<<"${checkpoint}")")" || {
        inspection_required=true
        issues_json="$(jq -c --argjson issues "${issues_json}" --argjson idx "${idx}" \
          '$issues + [{component:"storage",stage:"data-import",disk_index:$idx,reason:"cloud_data_volume_job_failed"}]' <<<"{}")"
        continue
      }
      import_volume_id="$(jq -r '.id // empty' <<<"${import_result}")"
    elif import_result="$(v2k_cloud_target_import_volume "${endpoint}" "${api_key}" "${secret_key}" "${storage_id}" "${disk_offering_id}" "${import_path}" "${disk_name}" "${owner_params}" "${manifest}" "${idx}")"; then
      import_volume_id="$(jq -r '.id // empty' <<<"${import_result}")"
      if [[ -z "${import_volume_id}" ]]; then
        inspection_required=true
        issues_json="$(jq -c --argjson issues "${issues_json}" --argjson idx "${idx}" \
          '$issues + [{component:"storage",stage:"data-import",disk_index:$idx,reason:"cloud_data_volume_id_missing"}]' <<<"{}")"
        continue
      fi
      v2k_cloud_target_record_checkpoint "${manifest}" "data-imported" \
        "$(jq -nc \
          --arg idx "${idx}" \
          --arg id "${import_volume_id}" \
          --arg import_job_id "$(jq -r '.job_id // empty' <<<"${import_result}")" \
          '.data_volumes = {($idx):{id:$id,import_job_id:$import_job_id,attached:false}}')" || return 78
    else
      inspection_required=true
      issues_json="$(jq -c --argjson issues "${issues_json}" --argjson idx "${idx}" \
        '$issues + [{component:"storage",stage:"data-import",disk_index:$idx,reason:"cloud_data_volume_import_failed"}]' <<<"{}")"
      continue
    fi

    if [[ -n "${import_volume_id}" ]] && \
       [[ "$(jq -r --arg idx "${idx}" '.data_volumes[$idx].id // empty' <<<"${checkpoint}")" != "${import_volume_id}" ]]; then
      v2k_cloud_target_record_checkpoint "${manifest}" "data-imported" \
        "$(jq -nc \
          --arg idx "${idx}" \
          --arg id "${import_volume_id}" \
          --arg import_job_id "$(jq -r '.job_id // empty' <<<"${import_result}")" \
          '.data_volumes = {($idx):{id:$id,import_job_id:$import_job_id,attached:false}}')" || return 78
    fi

    checkpoint="$(v2k_cloud_target_existing_checkpoint_json "${manifest}")"
    if jq -e --arg idx "${idx}" '.data_volumes[$idx].attached == true' <<<"${checkpoint}" >/dev/null 2>&1; then
      attach_result="$(jq -nc \
        --arg job_id "$(jq -r --arg idx "${idx}" '.data_volumes[$idx].attach_job_id // empty' <<<"${checkpoint}")" \
        '{job_id:$job_id,reused_checkpoint:true}')"
    elif attach_result="$(v2k_cloud_target_attach_volume "${endpoint}" "${api_key}" "${secret_key}" "${vm_id}" "${import_volume_id}" "${idx}")"; then
      v2k_cloud_target_record_checkpoint "${manifest}" "data-attached" \
        "$(jq -nc \
          --arg idx "${idx}" \
          --arg attach_job_id "$(jq -r '.job_id // empty' <<<"${attach_result}")" \
          '.data_volumes = {($idx):{attach_job_id:$attach_job_id,attached:true}}')" || return 78
    else
      inspection_required=true
      issues_json="$(jq -c --argjson issues "${issues_json}" --argjson idx "${idx}" --arg id "${import_volume_id}" \
        '$issues + [{component:"storage",stage:"data-attach",disk_index:$idx,volume_id:$id,reason:"cloud_data_volume_attach_failed"}]' <<<"{}")"
      v2k_cloud_target_record_checkpoint "${manifest}" "data-attach-degraded" \
        "$(jq -nc --arg idx "${idx}" '.data_volumes = {($idx):{attached:false}} | .inspection_required=true')" || return 78
      continue
    fi
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

  v2k_controller_cloud_verify "$manifest" "$endpoint" "$api_key" "$secret_key" prestart || return $?
  migration_disk_cache_verify_cloud v2k "$manifest" "$endpoint" "$api_key" "$secret_key" || return $?
  if ! migration_cloud_allocation_verify_final v2k "${manifest}" "${endpoint}" "${api_key}" "${secret_key}"; then
    v2k_cloud_target_record_checkpoint "${manifest}" allocation-unverified '{"complete":false,"inspection_required":true,"allocation_verified":false}' || return 78
    v2k_cloud_target_record_result "${manifest}" '{"status":"blocked","applied":true,"started":false,"validated":false,"inspection_required":true,"reason":"ALLOCATION_EVIDENCE_REQUIRED"}' || return 78
    return 2
  fi

  v2k_guest_config_reconcile "$manifest" "$endpoint" "$api_key" "$secret_key" bind || return $?
  if [[ "${start_vm}" -eq 1 && "${inspection_required}" == "false" ]]; then
    if start_result="$(v2k_cloud_target_start_vm "${endpoint}" "${api_key}" "${secret_key}" "${vm_id}")"; then
      v2k_controller_cloud_verify "$manifest" "$endpoint" "$api_key" "$secret_key" running || return $?
      started=true
      v2k_cloud_target_record_checkpoint "${manifest}" "vm-started" \
        "$(jq -nc --arg start_job_id "$(jq -r '.job_id // empty' <<<"${start_result}")" '{start_job_id:$start_job_id,started:true}')" || return 78
      jobs_json="$(jq -c --argjson jobs "${jobs_json}" --arg start_job "$(jq -r '.job_id' <<<"${start_result}")" '$jobs + [{kind:"start-vm",job_id:$start_job}]' <<<"{}")"
    else
      inspection_required=true
      issues_json="$(jq -c --argjson issues "${issues_json}" \
        '$issues + [{component:"boot",stage:"start-vm",reason:"cloud_vm_start_failed"}]' <<<"{}")"
    fi
  elif [[ "${start_vm}" -eq 1 ]]; then
    issues_json="$(jq -c --argjson issues "${issues_json}" \
      '$issues + [{component:"assembly",stage:"start-vm",reason:"start_skipped_due_to_degraded_target"}]' <<<"{}")"
  fi

  migration_cloud_allocation_intent "${manifest}" || return $?
  if [[ "${CLOUD_ALLOCATION_ACTIVE}" == 1 ]]; then
    if [[ "${start_vm}" -eq 1 && "${started}" == true ]]; then
      local observed_vm
      if ! observed_vm="$(v2k_cloud_target_vm_json "${endpoint}" "${api_key}" "${secret_key}" "${vm_id}")" ||
          ! jq -e '.state == "Running"' <<<"${observed_vm}" >/dev/null; then
        inspection_required=true; started=false
        issues_json="$(jq -c '. + [{component:"boot",stage:"start-vm",reason:"cloud_vm_not_running"}]' <<<"${issues_json}")"
      fi
    fi
    if [[ "${inspection_required}" == true ]]; then
      v2k_cloud_target_record_result "${manifest}" \
        "$(jq -nc --argjson issues "${issues_json}" '{status:"blocked",applied:true,started:false,validated:false,inspection_required:true,reason:"CLOUD_CUTOVER_INCOMPLETE",issues:$issues}')" || return 78
      v2k_cloud_target_record_checkpoint "${manifest}" deployment-incomplete \
        "$(jq -nc --argjson issues "${issues_json}" '{complete:false,started:false,inspection_required:true,issues:$issues}')" || return 78
      return 2
    fi
  fi

  if [[ "$started" == true ]] && ! v2k_guest_config_reconcile "$manifest" "$endpoint" "$api_key" "$secret_key" verify; then
    v2k_cloud_target_record_checkpoint "$manifest" guest-config-pending '{"complete":false,"started":true,"inspection_required":true}' || return $?
    return 78
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
    --argjson nic_verification "${nic_verification}" \
    --argjson disk_offering "${disk_offering_json}" \
    --argjson issues "${issues_json}" \
    --argjson inspection_required "${inspection_required}" \
    --argjson started "${started}" \
    '{provider:$provider,endpoint:$endpoint,
      status:(if $inspection_required then "completed_with_warning" else "completed" end),
      validated:($inspection_required | not),applied:true,started:$started,
      inspection_required:$inspection_required,issues:$issues,
      vm_id:$vm_id,root_volume_id:$root_volume_id,root_volume:$root_volume,root_volume_converted:$root_volume_converted,data_volumes:$data_volumes,jobs:$jobs,deployment_properties:$deployment_properties,nic_verification:$nic_verification}
     + (if ($disk_offering | length) > 0 then {disk_offering:$disk_offering} else {} end)
     + (if ($root_volume_update_job_id | length) > 0 then {root_volume_update_job_id:$root_volume_update_job_id} else {} end)')"
  local guest_state guest_verified target_complete=true
  guest_state="$(jq -r '.runtime.guest_configuration.status // "LEGACY_UNVERIFIED"' "$manifest")"
  guest_verified="$(jq -r '.runtime.guest_configuration.verified // false' "$manifest")"
  if [[ "$guest_state" == SKIPPED || "$guest_state" == BOUND || "$guest_state" == STAGED ]]; then target_complete=false; fi
  result_json="$(jq --arg status "$guest_state" --argjson verified "$guest_verified" --argjson complete "$target_complete" '. + {complete:$complete,guest_configuration_status:$status,guest_configuration_verified:$verified} | if $complete then . else .validated=false | .status=(if $status=="SKIPPED" then "guest_config_skipped" else "bound" end) end' <<<"$result_json")"
  v2k_cloud_target_record_result "${manifest}" "${result_json}" || return 78
  v2k_cloud_target_record_checkpoint "${manifest}" \
    "$(if [[ "$target_complete" == false ]]; then printf guest-config-unverified; elif [[ "${inspection_required}" == "true" ]]; then printf inspection-required; else printf complete; fi)" \
    "$(jq -nc \
      --arg vm_id "${vm_id}" \
      --arg root_volume_id "${root_volume_id}" \
      --argjson issues "${issues_json}" \
      --argjson inspection_required "${inspection_required}" \
      --argjson started "${started}" \
      --argjson complete "$target_complete" \
      '{complete:$complete,vm_id:$vm_id,root_volume_id:$root_volume_id,started:$started,inspection_required:$inspection_required,issues:$issues}')" || return 78
  printf '%s' "${result_json}"
}


v2k_cloud_target_source_deploy_params_json() {
  local base plan
  base="$(v2k_cloud_target_source_deploy_params_legacy_json "$@")" || return $?
  if jq -e '.target.disk_controller_plan.version == 1' "$1" >/dev/null; then
    plan="$(v2k_controller_python params --manifest "$1")" || return $?
    if jq -e ' (.target.guest_configuration_plan.version==1 or .target.guest_configuration_plan.version==2)' "$1" >/dev/null; then
      local guest_params
      guest_params="$(v2k_guest_config_python guest_configuration.py params --manifest "$1")" || return $?
      plan="$(jq -nc --argjson p "$plan" --argjson g "$guest_params" '$p+$g')"
    fi
    jq -nc --argjson base "$base" --argjson plan "$plan" '$base + $plan'
  else printf '%s' "$base"; fi
}

v2k_cloud_target_cutover() {
  migration_cloud_retention_cutover v2k "$@"
}
