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

n2k_interactive_has_tty() {
  [[ -t 0 && ( -t 2 || -t 1 ) ]]
}

n2k_interactive_prompt_text() {
  local label="$1" default_value="${2:-}" required="${3:-0}" example="${4:-}" answer
  while true; do
    if [[ -n "${example}" ]]; then
      printf '  Example: %s\n' "${example}" >&2
    fi
    if [[ -n "${default_value}" ]]; then
      printf '%s [%s]: ' "${label}" "${default_value}" >&2
    else
      printf '%s: ' "${label}" >&2
    fi
    IFS= read -r answer || answer=""
    [[ -n "${answer}" ]] || answer="${default_value}"
    if [[ -n "${answer}" || "${required}" != "1" ]]; then
      printf '%s' "${answer}"
      return 0
    fi
    printf 'A value is required.\n' >&2
  done
}

n2k_interactive_prompt_secret() {
  local label="$1" hint="${2:-Input is hidden.}" answer
  while true; do
    if [[ -n "${hint}" ]]; then
      printf '  %s\n' "${hint}" >&2
    fi
    printf '%s: ' "${label}" >&2
    IFS= read -rs answer || answer=""
    printf '\n' >&2
    if [[ -n "${answer}" ]]; then
      printf '%s' "${answer}"
      return 0
    fi
    printf 'A value is required.\n' >&2
  done
}

n2k_interactive_prompt_confirm() {
  local label="$1" default_value="${2:-no}" answer suffix
  case "${default_value}" in
    yes) suffix="Y/n" ;;
    *) suffix="y/N" ;;
  esac
  printf '%s [%s]: ' "${label}" "${suffix}" >&2
  IFS= read -r answer || answer=""
  [[ -n "${answer}" ]] || answer="${default_value}"
  case "${answer}" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

n2k_interactive_choice_by_id_or_label() {
  local choices="$1" wanted="$2"
  printf '%s\n' "${choices}" | awk -F '\t' -v wanted="${wanted}" '
    wanted != "" && ($1 == wanted || $2 == wanted) { print $1; found=1; exit }
    END { if (!found) exit 1 }
  '
}

n2k_interactive_select_tsv() {
  local label="$1" choices="$2" current="${3:-}" yes="${4:-0}" default_index="${5:-1}"
  local count=0 idx=0 line id name meta choice selected
  local -a ids=() names=() metas=()

  if [[ -n "${current}" ]]; then
    if selected="$(n2k_interactive_choice_by_id_or_label "${choices}" "${current}" 2>/dev/null)"; then
      printf '%s' "${selected}"
    else
      printf '%s' "${current}"
    fi
    return 0
  fi

  while IFS=$'\t' read -r id name meta; do
    [[ -n "${id}" ]] || continue
    ids+=("${id}")
    names+=("${name:-${id}}")
    metas+=("${meta:-}")
  done <<< "${choices}"
  count="${#ids[@]}"

  [[ "${count}" -gt 0 ]] || n2k_die "No selectable item found for ${label}"
  if [[ "${count}" -eq 1 ]]; then
    printf '%s\n' "Auto-selected ${label}: ${names[0]} (${ids[0]})" >&2
    printf '%s' "${ids[0]}"
    return 0
  fi

  if [[ "${yes}" -eq 1 ]]; then
    n2k_die "${label} has multiple candidates; run without --yes to select from the list, or provide an explicit option"
  fi
  n2k_interactive_has_tty || n2k_die "${label} selection requires a TTY"

  printf '\n%s:\n' "${label}" >&2
  for ((idx=0; idx<count; idx++)); do
    if [[ -n "${metas[idx]}" ]]; then
      printf '  %d. %s (%s) - %s\n' "$((idx + 1))" "${names[idx]}" "${ids[idx]}" "${metas[idx]}" >&2
    else
      printf '  %d. %s (%s)\n' "$((idx + 1))" "${names[idx]}" "${ids[idx]}" >&2
    fi
  done
  printf '  Choose by number, ID, or exact name. Press Enter for %s.\n' "${default_index}" >&2
  while true; do
    choice="$(n2k_interactive_prompt_text "Select ${label}" "${default_index}" 1 "1")"
    if [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le "${count}" ]]; then
      printf '%s' "${ids[choice - 1]}"
      return 0
    fi
    if selected="$(n2k_interactive_choice_by_id_or_label "${choices}" "${choice}" 2>/dev/null)"; then
      printf '%s' "${selected}"
      return 0
    fi
    printf 'Invalid selection. Enter a number from 1 to %s, an ID, or an exact name.\n' "${count}" >&2
  done
}

n2k_interactive_nutanix_vm_choices() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local list_json http_code api_error

  n2k_nutanix_api_request_capture GET "${pc}" "/api/vmm/v4.0/ahv/config/vms?\$limit=100" "${username}" "${password}" "${insecure}" "" list_json http_code api_error || true
  if n2k_nutanix_http_success "${http_code}"; then
    printf '%s' "${list_json}" | n2k_interactive_normalize_vm_choices
    return 0
  fi

  n2k_nutanix_api_request_capture POST "${pc}" "/api/nutanix/v3/vms/list" "${username}" "${password}" "${insecure}" '{"kind":"vm","length":100}' list_json http_code api_error || true
  if n2k_nutanix_http_success "${http_code}"; then
    printf '%s' "${list_json}" | n2k_interactive_normalize_vm_choices
    return 0
  fi

  n2k_nutanix_api_request_capture GET "${pc}" "/PrismGateway/services/rest/v2.0/vms" "${username}" "${password}" "${insecure}" "" list_json http_code api_error || true
  if n2k_nutanix_http_success "${http_code}"; then
    printf '%s' "${list_json}" | n2k_interactive_normalize_vm_choices
    return 0
  fi

  echo "Unable to list Nutanix VMs: HTTP ${http_code:-000} ${api_error:-}" >&2
  return 2
}

n2k_interactive_normalize_vm_choices() {
  jq -r '
    def items:
      if (.data | type) == "array" then .data
      elif (.entities | type) == "array" then .entities
      elif (.metadata.entities | type) == "array" then .metadata.entities
      else [] end;
    def first_nonempty($xs):
      reduce $xs[] as $x (""; if (. | length) > 0 then . elif (($x // "") | tostring | length) > 0 then ($x | tostring) else . end);
    items[]
    | first_nonempty([.extId, .ext_id, .metadata.uuid, .uuid, .vm_id]) as $id
    | first_nonempty([.name, .spec.name, .status.name]) as $name
    | first_nonempty([.powerState, .power_state, .status.powerState, .status.resources.power_state]) as $state
    | select(($id | length) > 0 or ($name | length) > 0)
    | [
        if ($name | length) > 0 then $name else $id end,
        if ($name | length) > 0 then $name else $id end,
        ((if ($id | length) > 0 then ("uuid=" + $id) else "" end) + (if ($state | length) > 0 then (" " + $state) else "" end))
      ]
    | @tsv
  '
}

n2k_interactive_cloud_choices() {
  local endpoint="$1" api_key="$2" secret_key="$3" kind="$4"
  local response
  case "${kind}" in
    zones)
      response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listZones" '{"available":true}')"
      printf '%s' "${response}" | jq -r '(.listzonesresponse.zone // [])[] | [.id, (.name // .id), (.allocationstate // "")] | @tsv'
      ;;
    service-offerings)
      response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listServiceOfferings" '{"issystem":false}')"
      printf '%s' "${response}" | jq -r '(.listserviceofferingsresponse.serviceoffering // [])[] | [.id, (.name // .displaytext // .id), (((.cpunumber // "") | tostring) + " cpu, " + ((.memory // "") | tostring) + " MB")] | @tsv'
      ;;
    networks)
      response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listNetworks" '{"listall":true}')"
      printf '%s' "${response}" | jq -r '(.listnetworksresponse.network // [])[] | [.id, (.name // .displaytext // .id), (((.type // "") | tostring) + " " + ((.broadcasturi // "") | tostring))] | @tsv'
      ;;
    storage-pools)
      response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listStoragePools" '{"listall":true}')"
      printf '%s' "${response}" | jq -r '(.liststoragepoolsresponse.storagepool // [])[] | [.id, (.name // .path // .id), (((.type // "") | tostring) + " " + ((.path // "") | tostring) + " " + ((.clustername // "") | tostring))] | @tsv'
      ;;
    hosts)
      response="$(n2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" "listHosts" '{"type":"Routing","state":"Up","listall":true}')"
      printf '%s' "${response}" | jq -r '(.listhostsresponse.host // [])[] | [.id, (.name // .id), (((.state // "") | tostring) + " " + ((.clustername // "") | tostring))] | @tsv'
      ;;
    *)
      n2k_die "Unsupported Cloud choice kind: ${kind}"
      ;;
  esac
}

n2k_interactive_target_profile_choices() {
  cat <<'EOF'
cloud-rbd	ABLESTACK Cloud / RBD	default
cloud-filesystem	ABLESTACK Cloud / FileSystem qcow2	local file primary storage
libvirt-rbd	libvirt / RBD	existing host libvirt path
libvirt-qcow2	libvirt / qcow2	existing host libvirt path
EOF
}

n2k_interactive_split_choices() {
  cat <<'EOF'
phase1	Phase1 incremental sync	no cutover yet
phase2	Phase2 final sync and cutover	requires existing manifest/workdir
full	Full run and cutover	one command validation path
EOF
}

n2k_interactive_build_target_map_json() {
  local inventory_json="$1" target_storage="$2" target_format="$3" rbd_pool="$4" file_root="$5" target_name="$6"
  jq -c \
    --arg storage "${target_storage}" \
    --arg format "${target_format}" \
    --arg pool "${rbd_pool}" \
    --arg file_root "${file_root%/}" \
    --arg target_name "${target_name}" \
    '
      def safe_name($s):
        ($s | tostring)
        | gsub("[/\\\\]"; "_")
        | gsub("[[:cntrl:]]"; "_")
        | gsub("[[:space:]]+"; "_")
        | gsub("^[.]+$"; "_")
        | gsub("^[.]"; "_")
        | gsub("_+"; "_");
      reduce ((.disks // []) | to_entries[]) as $entry ({};
        ($entry.value.disk_id // ("disk" + ($entry.key | tostring))) as $disk_id
        | . + {
            ($disk_id): (
              if $storage == "rbd" then
                ("rbd:" + $pool + "/" + safe_name($target_name) + "-disk" + ($entry.key | tostring))
              elif $storage == "file" then
                ($file_root + "/" + safe_name($target_name) + "-disk" + ($entry.key | tostring) + "." + $format)
              else
                ""
              end
            )
          }
      )
      | with_entries(select(.value != ""))
    ' <<< "${inventory_json}"
}

n2k_interactive_default_workdir() {
  local vm="$1"
  if [[ -z "${N2K_RUN_ID:-}" ]]; then
    N2K_RUN_ID="$(n2k_generate_run_id)"
    export N2K_RUN_ID
  fi
  printf '/var/lib/ablestack-n2k/%s/%s' "$(n2k_safe_name "${vm}")" "${N2K_RUN_ID}"
}

n2k_interactive_set_workdir() {
  local workdir="$1"
  [[ -n "${workdir}" ]] || n2k_die "workdir is required"
  N2K_WORKDIR="${workdir}"
  export N2K_WORKDIR
  if [[ -z "${N2K_MANIFEST:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR%/}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -z "${N2K_EVENTS_LOG:-}" ]]; then
    N2K_EVENTS_LOG="${N2K_WORKDIR%/}/events.log"
    export N2K_EVENTS_LOG
  fi
}

n2k_interactive_prepare_manifest_path() {
  if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR%/}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -z "${N2K_EVENTS_LOG:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_EVENTS_LOG="${N2K_WORKDIR%/}/events.log"
    export N2K_EVENTS_LOG
  fi
}

n2k_interactive_manifest_value() {
  local path="$1" query="$2"
  [[ -f "${path}" ]] || return 1
  jq -r "${query} // empty" "${path}" 2>/dev/null
}

n2k_interactive_manifest_json_value() {
  local path="$1" query="$2"
  [[ -f "${path}" ]] || return 1
  jq -c "${query} // empty" "${path}" 2>/dev/null
}

n2k_interactive_manifest_network_ids() {
  local path="$1"
  [[ -f "${path}" ]] || return 1
  jq -r '(.target.cloud.network_ids // []) | join(",")' "${path}" 2>/dev/null
}

n2k_interactive_profile_from_manifest() {
  local path="$1" provider storage format
  provider="$(n2k_interactive_manifest_value "${path}" '.target.provider')"
  storage="$(n2k_interactive_manifest_value "${path}" '.target.storage.type')"
  format="$(n2k_interactive_manifest_value "${path}" '.target.format')"
  case "${provider}:${storage}:${format}" in
    ablestack-cloud:rbd:*) printf 'cloud-rbd' ;;
    ablestack-cloud:file:*) printf 'cloud-filesystem' ;;
    libvirt:rbd:*) printf 'libvirt-rbd' ;;
    libvirt:file:qcow2) printf 'libvirt-qcow2' ;;
    *) return 1 ;;
  esac
}

n2k_interactive_default_split_from_manifest() {
  local path="$1" phase1_done phase2_done
  [[ -f "${path}" ]] || return 1
  phase1_done="$(jq -r '.runtime.split.phase1.done // false' "${path}" 2>/dev/null || printf false)"
  phase2_done="$(jq -r '.runtime.split.phase2.done // false' "${path}" 2>/dev/null || printf false)"
  if [[ "${phase1_done}" == "true" && "${phase2_done}" != "true" ]]; then
    printf 'phase2'
  else
    printf 'phase1'
  fi
}

n2k_interactive_apply_manifest_defaults() {
  local path="$1"
  [[ -f "${path}" ]] || return 0

  vm="${vm:-$(n2k_interactive_manifest_value "${path}" '.source.vm.name')}"
  pc="${pc:-$(n2k_interactive_manifest_value "${path}" '.source.pc')}"
  target_provider="${target_provider:-$(n2k_interactive_manifest_value "${path}" '.target.provider')}"
  target_storage="${target_storage:-$(n2k_interactive_manifest_value "${path}" '.target.storage.type')}"
  target_format="${target_format:-$(n2k_interactive_manifest_value "${path}" '.target.format')}"
  dst="${dst:-$(n2k_interactive_manifest_value "${path}" '.target.dst_root')}"
  target_map_json="${target_map_json:-$(n2k_interactive_manifest_json_value "${path}" '.target.storage.map')}"
  rbd_access_mode="${rbd_access_mode:-$(n2k_interactive_manifest_value "${path}" '.target.storage.rbd_access_mode')}"
  cloud_endpoint="${cloud_endpoint:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.endpoint')}"
  cloud_zone_id="${cloud_zone_id:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.zone_id')}"
  cloud_service_offering_id="${cloud_service_offering_id:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.service_offering_id')}"
  cloud_network_ids="${cloud_network_ids:-$(n2k_interactive_manifest_network_ids "${path}")}"
  cloud_storage_id="${cloud_storage_id:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.storage_id')}"
  cloud_disk_offering_id="${cloud_disk_offering_id:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.disk_offering_id')}"
  cloud_host_id="${cloud_host_id:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.host_id')}"
  cloud_account="${cloud_account:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.account')}"
  cloud_domain_id="${cloud_domain_id:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.domain_id')}"
  cloud_project_id="${cloud_project_id:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.project_id')}"
  cloud_name="${cloud_name:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.name')}"
  cloud_display_name="${cloud_display_name:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.display_name')}"
  cloud_cpu_speed="${cloud_cpu_speed:-$(n2k_interactive_manifest_value "${path}" '.target.cloud.cpu_speed')}"
  if [[ -z "${target_profile}" ]]; then
    target_profile="$(n2k_interactive_profile_from_manifest "${path}" 2>/dev/null || true)"
  fi
  if [[ -z "${split}" ]]; then
    split="$(n2k_interactive_default_split_from_manifest "${path}" 2>/dev/null || true)"
  fi
}

n2k_interactive_select_or_prepare_resume_workdir() {
  if [[ "${split:-}" != "phase2" ]]; then
    return 0
  fi

  n2k_interactive_prepare_manifest_path
  if [[ -n "${N2K_MANIFEST:-}" && -f "${N2K_MANIFEST}" ]]; then
    n2k_interactive_apply_manifest_defaults "${N2K_MANIFEST}"
    return 0
  fi

  if [[ -z "${N2K_WORKDIR:-}" ]]; then
    [[ "${yes}" -eq 0 ]] || n2k_die "--workdir or --manifest is required for wizard --split phase2 when using --yes"
    n2k_interactive_has_tty || n2k_die "Existing workdir is required for wizard --split phase2 without a TTY"
    n2k_interactive_set_workdir "$(n2k_interactive_prompt_text "Existing migration work directory" "" 1 "/var/lib/ablestack-n2k/win10/20260519-120000-abcd1234")"
  else
    n2k_interactive_prepare_manifest_path
  fi

  [[ -n "${N2K_MANIFEST:-}" && -f "${N2K_MANIFEST}" ]] || \
    n2k_die "wizard --split phase2 requires an existing manifest in the selected workdir"
  n2k_interactive_apply_manifest_defaults "${N2K_MANIFEST}"
}

n2k_interactive_prepare_new_workdir() {
  local vm="$1" split="$2" default_workdir workdir
  if [[ "${split}" == "phase2" ]]; then
    return 0
  fi
  if [[ -n "${N2K_WORKDIR:-}" ]]; then
    n2k_interactive_prepare_manifest_path
    return 0
  fi
  default_workdir="$(n2k_interactive_default_workdir "${vm}")"
  if [[ "${yes}" -eq 1 ]]; then
    workdir="${default_workdir}"
    printf 'Auto-selected migration work directory: %s\n' "${workdir}" >&2
  else
    n2k_interactive_has_tty || n2k_die "Migration work directory requires a TTY or --workdir"
    workdir="$(n2k_interactive_prompt_text "Migration work directory" "${default_workdir}" 1 "Press Enter to accept the generated path, or type another absolute path.")"
  fi
  n2k_interactive_set_workdir "${workdir}"
}

n2k_interactive_print_command() {
  local redact_next=0 arg rendered=""
  local -a printable=(ablestack_n2k)
  [[ -n "${N2K_WORKDIR:-}" ]] && printable+=(--workdir "${N2K_WORKDIR}")
  [[ -n "${N2K_RUN_ID:-}" ]] && printable+=(--run-id "${N2K_RUN_ID}")
  [[ -n "${N2K_MANIFEST:-}" ]] && printable+=(--manifest "${N2K_MANIFEST}")
  [[ -n "${N2K_EVENTS_LOG:-}" ]] && printable+=(--log "${N2K_EVENTS_LOG}")
  [[ "${N2K_DRY_RUN:-0}" -eq 1 ]] && printable+=(--dry-run)
  printable+=(run "$@")

  for arg in "${printable[@]}"; do
    if [[ "${redact_next}" -eq 1 ]]; then
      printf -v arg '%s' 'REDACTED'
      redact_next=0
    else
      case "${arg}" in
        --password|--cloud-api-key|--cloud-secret-key)
          redact_next=1
          ;;
      esac
    fi
    printf -v rendered '%s%q ' "${rendered}" "${arg}"
  done
  printf '%s\n' "${rendered% }"
}

n2k_interactive_summary() {
  local vm="$1" pc="$2" target_profile="$3" target_provider="$4" target_storage="$5" target_format="$6"
  local split="$7" shutdown="$8" cutover_policy="$9" dst="${10}" cloud_endpoint="${11}" cloud_zone_id="${12}"
  local cloud_service_offering_id="${13}" cloud_network_ids="${14}" cloud_storage_id="${15}" cloud_host_id="${16}"
  local cloud_name="${17}" target_map_json="${18}"

  cat >&2 <<EOF

Interactive migration summary
  Source VM:        ${vm}
  Prism endpoint:   ${pc}
  Target profile:   ${target_profile}
  Target provider:  ${target_provider}
  Target storage:   ${target_storage} (${target_format})
  Destination root: ${dst}
  Split:            ${split}
  Shutdown:         ${shutdown}
  Cutover action:   ${cutover_policy}
EOF
  if [[ "${target_provider}" == "ablestack-cloud" ]]; then
    cat >&2 <<EOF
  Cloud endpoint:   ${cloud_endpoint}
  Cloud VM name:    ${cloud_name}
  Cloud zone:       ${cloud_zone_id}
  Cloud offering:   ${cloud_service_offering_id}
  Cloud networks:   ${cloud_network_ids}
  Cloud storage:    ${cloud_storage_id}
  Cloud host:       ${cloud_host_id:-auto}
EOF
  fi
  if [[ -n "${target_map_json}" && "${target_map_json}" != "{}" ]]; then
    printf '  Target map:      generated for %s disk(s)\n' "$(jq -r 'length' <<< "${target_map_json}")" >&2
  fi
  printf '\n' >&2
}

n2k_cmd_wizard() {
  local vm="" pc="" username="" password="" cred_file="" insecure="1"
  local target_profile="" target_provider="" target_storage="" target_format="" dst="" target_map_json=""
  local rbd_pool="${N2K_WIZARD_RBD_POOL:-rbd}" file_root="${N2K_WIZARD_FILE_ROOT:-/var/lib/libvirt/images}"
  local rbd_access_mode=""
  local cloud_endpoint="" cloud_api_key="" cloud_secret_key="" cloud_cred_file=""
  local cloud_zone_id="" cloud_service_offering_id="" cloud_network_ids="" cloud_storage_id="" cloud_disk_offering_id=""
  local cloud_host_id="" cloud_account="" cloud_domain_id="" cloud_project_id="" cloud_name="" cloud_display_name="" cloud_cpu_speed=""
  local cloud_storage_json="" cloud_storage_path="" cloud_storage_scope=""
  local split="" source_api="v3" force_v3=true
  local nfs_host="" nfs_mount_root=""
  local shutdown="guest" cutover_policy="start"
  local libvirt_network_mode="" libvirt_bridge="" libvirt_network=""
  local yes=0 print_command=0
  local target_name inventory_raw="" inventory_json="" vm_choices cloud_choices

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vm) vm="${2:-}"; shift 2 ;;
      --pc) pc="${2:-}"; shift 2 ;;
      --username) username="${2:-}"; shift 2 ;;
      --password) password="${2:-}"; shift 2 ;;
      --cred-file) cred_file="${2:-}"; shift 2 ;;
      --insecure) insecure="${2:-}"; shift 2 ;;
      --target-profile|--profile) target_profile="${2:-}"; shift 2 ;;
      --target-provider) target_provider="${2:-}"; shift 2 ;;
      --target-storage) target_storage="${2:-}"; shift 2 ;;
      --target-format) target_format="${2:-}"; shift 2 ;;
      --dst) dst="${2:-}"; shift 2 ;;
      --target-map-json) target_map_json="${2:-}"; shift 2 ;;
      --rbd-pool) rbd_pool="${2:-}"; shift 2 ;;
      --file-root) file_root="${2:-}"; shift 2 ;;
      --rbd-access-mode) rbd_access_mode="${2:-}"; shift 2 ;;
      --cloud-endpoint) cloud_endpoint="${2:-}"; shift 2 ;;
      --cloud-api-key) cloud_api_key="${2:-}"; shift 2 ;;
      --cloud-secret-key) cloud_secret_key="${2:-}"; shift 2 ;;
      --cloud-cred-file) cloud_cred_file="${2:-}"; shift 2 ;;
      --cloud-zone-id) cloud_zone_id="${2:-}"; shift 2 ;;
      --cloud-service-offering-id) cloud_service_offering_id="${2:-}"; shift 2 ;;
      --cloud-network-id)
        cloud_network_ids="${cloud_network_ids:+${cloud_network_ids},}${2:-}"
        shift 2
        ;;
      --cloud-network-ids) cloud_network_ids="${2:-}"; shift 2 ;;
      --cloud-storage-id) cloud_storage_id="${2:-}"; shift 2 ;;
      --cloud-disk-offering-id) cloud_disk_offering_id="${2:-}"; shift 2 ;;
      --cloud-host-id) cloud_host_id="${2:-}"; shift 2 ;;
      --cloud-account) cloud_account="${2:-}"; shift 2 ;;
      --cloud-domain-id) cloud_domain_id="${2:-}"; shift 2 ;;
      --cloud-project-id) cloud_project_id="${2:-}"; shift 2 ;;
      --cloud-name) cloud_name="${2:-}"; shift 2 ;;
      --cloud-display-name) cloud_display_name="${2:-}"; shift 2 ;;
      --cloud-cpu-speed) cloud_cpu_speed="${2:-}"; shift 2 ;;
      --split) split="${2:-}"; shift 2 ;;
      --source-api) source_api="${2:-}"; shift 2 ;;
      --force-v3|--force-v3-incremental) force_v3=true; shift 1 ;;
      --nfs-host) nfs_host="${2:-}"; shift 2 ;;
      --nfs-mount-root) nfs_mount_root="${2:-}"; shift 2 ;;
      --shutdown) shutdown="${2:-}"; shift 2 ;;
      --define-only) cutover_policy="define-only"; shift 1 ;;
      --apply) cutover_policy="apply"; shift 1 ;;
      --start) cutover_policy="start"; shift 1 ;;
      --network-mode|--libvirt-network-mode) libvirt_network_mode="${2:-}"; shift 2 ;;
      --bridge|--libvirt-bridge) libvirt_bridge="${2:-}"; shift 2 ;;
      --network|--libvirt-network) libvirt_network="${2:-}"; shift 2 ;;
      --yes|-y) yes=1; shift 1 ;;
      --print-command) print_command=1; shift 1 ;;
      *) n2k_die "Unknown option for wizard: $1" ;;
    esac
  done

  n2k_interactive_prepare_manifest_path
  if [[ -n "${N2K_MANIFEST:-}" && -f "${N2K_MANIFEST}" ]]; then
    n2k_interactive_apply_manifest_defaults "${N2K_MANIFEST}"
  elif [[ -z "${split}" && "${yes}" -eq 0 ]]; then
    n2k_interactive_has_tty || n2k_die "--split is required without a TTY"
    split="$(n2k_interactive_select_tsv "migration split" "$(n2k_interactive_split_choices)" "" 0 1)"
    n2k_interactive_select_or_prepare_resume_workdir
  elif [[ "${split:-}" == "phase2" ]]; then
    n2k_interactive_select_or_prepare_resume_workdir
  fi

  [[ "${source_api}" == "v3" ]] || n2k_die "wizard currently supports --source-api v3 only"
  case "${insecure}" in 0|1) ;; *) n2k_die "Invalid --insecure: ${insecure}" ;; esac
  case "${shutdown}" in none|manual|guest|poweroff) ;; *) n2k_die "Invalid --shutdown: ${shutdown}" ;; esac

  if [[ -n "${cred_file}" ]]; then
    n2k_nutanix_load_cred_file "${cred_file}"
    username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
    password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"
  fi
  pc="${pc:-${N2K_PC:-${N2K_PC_ENDPOINT:-${NUTANIX_PC:-}}}}"
  username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
  password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"

  if [[ -z "${pc}" ]]; then
    [[ "${yes}" -eq 0 ]] || n2k_die "--pc is required when using --yes"
    n2k_interactive_has_tty || n2k_die "--pc is required without a TTY"
    pc="$(n2k_interactive_prompt_text "Prism endpoint" "" 1 "https://10.10.132.100:9440")"
  fi
  if [[ -z "${username}" ]]; then
    [[ "${yes}" -eq 0 ]] || n2k_die "--username is required when using --yes"
    n2k_interactive_has_tty || n2k_die "--username is required without a TTY"
    username="$(n2k_interactive_prompt_text "Prism username" "admin" 1 "admin")"
  fi
  if [[ -z "${password}" ]]; then
    [[ "${yes}" -eq 0 ]] || n2k_die "--password, environment password, or --cred-file is required when using --yes"
    n2k_interactive_has_tty || n2k_die "Prism password is required without a TTY"
    password="$(n2k_interactive_prompt_secret "Prism password" "Paste the Prism admin password. Input is hidden.")"
  fi

  if [[ -z "${vm}" ]]; then
    vm_choices="$(n2k_interactive_nutanix_vm_choices "${pc}" "${username}" "${password}" "${insecure}")"
    vm="$(n2k_interactive_select_tsv "source VM" "${vm_choices}" "" "${yes}" 1)"
  fi

  target_profile="${target_profile:-${N2K_WIZARD_TARGET_PROFILE:-}}"
  if [[ -z "${target_profile}" ]]; then
    if [[ "${yes}" -eq 1 ]]; then
      target_profile="cloud-rbd"
    else
      target_profile="$(n2k_interactive_select_tsv "target profile" "$(n2k_interactive_target_profile_choices)" "" 0 1)"
    fi
  fi

  case "${target_profile}" in
    cloud-rbd)
      target_provider="${target_provider:-ablestack-cloud}"
      target_storage="${target_storage:-rbd}"
      target_format="${target_format:-raw}"
      ;;
    cloud-filesystem|cloud-qcow2)
      target_profile="cloud-filesystem"
      target_provider="${target_provider:-ablestack-cloud}"
      target_storage="${target_storage:-file}"
      target_format="${target_format:-qcow2}"
      ;;
    libvirt-rbd)
      target_provider="${target_provider:-libvirt}"
      target_storage="${target_storage:-rbd}"
      target_format="${target_format:-raw}"
      ;;
    libvirt-qcow2)
      target_provider="${target_provider:-libvirt}"
      target_storage="${target_storage:-file}"
      target_format="${target_format:-qcow2}"
      ;;
    *)
      n2k_die "Invalid --target-profile: ${target_profile}"
      ;;
  esac
  n2k_valid_target_provider "${target_provider}" || n2k_die "Invalid --target-provider: ${target_provider}"
  n2k_valid_target_storage "${target_storage}" || n2k_die "Invalid --target-storage: ${target_storage}"
  n2k_valid_target_format "${target_format}" || n2k_die "Invalid --target-format: ${target_format}"
  rbd_access_mode="${rbd_access_mode:-librbd}"
  n2k_valid_rbd_access_mode "${rbd_access_mode}" || n2k_die "Invalid --rbd-access-mode: ${rbd_access_mode}"
  if [[ -n "${target_map_json}" ]]; then
    target_map_json="$(printf '%s' "${target_map_json}" | jq -c . 2>/dev/null)" || \
      n2k_die "Invalid --target-map-json"
  fi

  split="${split:-${N2K_WIZARD_DEFAULT_SPLIT:-}}"
  if [[ -z "${split}" ]]; then
    if [[ "${yes}" -eq 1 ]]; then
      split="phase1"
    else
      split="$(n2k_interactive_select_tsv "migration split" "$(n2k_interactive_split_choices)" "" 0 1)"
    fi
  fi
  case "${split}" in phase1|phase2|full) ;; *) n2k_die "Invalid --split: ${split}" ;; esac

  target_name="${cloud_name:-${N2K_WIZARD_TARGET_NAME:-}}"
  if [[ -z "${target_name}" ]]; then
    target_name="n2k-$(n2k_safe_name "${vm}")-$(date +%Y%m%d%H%M%S)"
  fi
  cloud_name="${cloud_name:-${target_name}}"
  cloud_display_name="${cloud_display_name:-${cloud_name}}"

  n2k_interactive_prepare_new_workdir "${vm}" "${split}"

  if [[ "${target_provider}" == "ablestack-cloud" ]]; then
    if [[ -n "${cloud_cred_file}" ]]; then
      n2k_cloud_load_cred_file "${cloud_cred_file}"
    fi
    cloud_endpoint="${cloud_endpoint:-${N2K_CLOUD_ENDPOINT:-${ABLESTACK_CLOUD_ENDPOINT:-${CLOUDSTACK_ENDPOINT:-}}}}"
    cloud_api_key="$(n2k_cloud_resolve_api_key "${cloud_api_key}")"
    cloud_secret_key="$(n2k_cloud_resolve_secret_key "${cloud_secret_key}")"
    cloud_cpu_speed="${cloud_cpu_speed:-1000}"

    if [[ -z "${cloud_endpoint}" ]]; then
      [[ "${yes}" -eq 0 ]] || n2k_die "--cloud-endpoint is required when using --yes"
      n2k_interactive_has_tty || n2k_die "--cloud-endpoint is required without a TTY"
      cloud_endpoint="$(n2k_interactive_prompt_text "Cloud API endpoint" "" 1 "http://10.10.22.10:8080/client/api")"
    fi
    if [[ -z "${cloud_api_key}" ]]; then
      [[ "${yes}" -eq 0 ]] || n2k_die "--cloud-api-key, environment key, or --cloud-cred-file is required when using --yes"
      n2k_interactive_has_tty || n2k_die "Cloud API key is required without a TTY"
      cloud_api_key="$(n2k_interactive_prompt_secret "Cloud API key" "Paste the ABLESTACK Cloud API key. Input is hidden.")"
    fi
    if [[ -z "${cloud_secret_key}" ]]; then
      [[ "${yes}" -eq 0 ]] || n2k_die "--cloud-secret-key, environment key, or --cloud-cred-file is required when using --yes"
      n2k_interactive_has_tty || n2k_die "Cloud secret key is required without a TTY"
      cloud_secret_key="$(n2k_interactive_prompt_secret "Cloud secret key" "Paste the ABLESTACK Cloud secret key. Input is hidden.")"
    fi

    [[ -n "${cloud_zone_id}" ]] || {
      cloud_choices="$(n2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" zones)"
      cloud_zone_id="$(n2k_interactive_select_tsv "Cloud zone" "${cloud_choices}" "" "${yes}" 1)"
    }
    [[ -n "${cloud_service_offering_id}" ]] || {
      cloud_choices="$(n2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" service-offerings)"
      cloud_service_offering_id="$(n2k_interactive_select_tsv "Cloud service offering" "${cloud_choices}" "" "${yes}" 1)"
    }
    [[ -n "${cloud_network_ids}" ]] || {
      cloud_choices="$(n2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" networks)"
      cloud_network_ids="$(n2k_interactive_select_tsv "Cloud network" "${cloud_choices}" "" "${yes}" 1)"
    }
    [[ -n "${cloud_storage_id}" ]] || {
      cloud_choices="$(n2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" storage-pools)"
      cloud_storage_id="$(n2k_interactive_select_tsv "Cloud storage pool" "${cloud_choices}" "" "${yes}" 1)"
    }
    if [[ "${target_storage}" == "file" ]]; then
      cloud_storage_json="$(n2k_cloud_target_storage_pool_json "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" "${cloud_storage_id}")" || return $?
      [[ -n "${cloud_storage_json}" ]] || n2k_die "Cloud storage pool was not found: ${cloud_storage_id}"
      cloud_storage_path="$(n2k_cloud_target_file_storage_path_from_pool "${cloud_storage_json}")" || return $?
      cloud_storage_scope="$(jq -r '(.scope // "") | tostring' <<<"${cloud_storage_json}")"
      file_root="${cloud_storage_path}"
      if [[ "${cloud_storage_scope}" == "HOST" && -z "${cloud_host_id}" ]]; then
        cloud_choices="$(n2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" hosts)"
        cloud_host_id="$(n2k_interactive_select_tsv "Cloud host for local FileSystem storage" "${cloud_choices}" "" "${yes}" 1)"
      fi
    fi
  fi

  if [[ -z "${dst}" ]]; then
    case "${target_storage}" in
      rbd) dst="rbd:${rbd_pool}/${target_name}" ;;
      file)
        if [[ "${target_provider}" == "ablestack-cloud" ]]; then
          dst="${file_root%/}"
        else
          dst="${file_root%/}/${target_name}"
        fi
        ;;
    esac
  elif [[ "${target_provider}" == "ablestack-cloud" && "${target_storage}" == "file" && "${dst%/}" != "${file_root%/}" ]]; then
    n2k_die "Cloud file/qcow2 target root must match selected Cloud storage path: ${file_root%/} (got ${dst%/})"
  fi

  if [[ -z "${target_map_json}" && ( "${target_storage}" == "rbd" || "${target_provider}" == "ablestack-cloud" ) ]]; then
    if inventory_raw="$(n2k_nutanix_fetch_vm_inventory "${pc}" "${vm}" "${username}" "${password}" "${insecure}" 2>/dev/null)"; then
      inventory_json="$(n2k_nutanix_inventory_from_raw "${inventory_raw}" "${vm}")"
      target_map_json="$(n2k_interactive_build_target_map_json "${inventory_json}" "${target_storage}" "${target_format}" "${rbd_pool}" "${file_root}" "${target_name}")"
    elif [[ "${target_storage}" == "file" && "${target_provider}" == "ablestack-cloud" ]]; then
      n2k_die "Cloud FileSystem profile requires source inventory to generate root-level qcow2 target paths"
    fi
  fi

  if [[ "${target_provider}" == "libvirt" ]]; then
    libvirt_network_mode="${libvirt_network_mode:-bridge}"
    libvirt_bridge="${libvirt_bridge:-bridge0}"
  fi

  n2k_interactive_summary "${vm}" "${pc}" "${target_profile}" "${target_provider}" "${target_storage}" "${target_format}" \
    "${split}" "${shutdown}" "${cutover_policy}" "${dst}" "${cloud_endpoint}" "${cloud_zone_id}" \
    "${cloud_service_offering_id}" "${cloud_network_ids}" "${cloud_storage_id}" "${cloud_host_id}" \
    "${cloud_name}" "${target_map_json:-}"

  local -a run_args=(--vm "${vm}" --pc "${pc}" --username "${username}" --password "${password}" --insecure "${insecure}")
  run_args+=(--inventory-source api --source-api "${source_api}" --split "${split}" --shutdown "${shutdown}")
  [[ "${force_v3}" == "true" ]] && run_args+=(--force-v3)
  run_args+=(--target-provider "${target_provider}" --target-storage "${target_storage}" --target-format "${target_format}" --dst "${dst}")
  run_args+=(--rbd-access-mode "${rbd_access_mode}")
  [[ -n "${cred_file}" ]] && run_args+=(--cred-file "${cred_file}")
  [[ -n "${target_map_json}" && "${target_map_json}" != "{}" ]] && run_args+=(--target-map-json "${target_map_json}")
  [[ -n "${nfs_host}" ]] && run_args+=(--nfs-host "${nfs_host}")
  [[ -n "${nfs_mount_root}" ]] && run_args+=(--nfs-mount-root "${nfs_mount_root}")

  case "${cutover_policy}" in
    define-only) run_args+=(--define-only) ;;
    apply) run_args+=(--apply) ;;
    start) run_args+=(--apply --start) ;;
  esac

  if [[ "${target_provider}" == "ablestack-cloud" ]]; then
    run_args+=(--cloud-endpoint "${cloud_endpoint}" --cloud-api-key "${cloud_api_key}" --cloud-secret-key "${cloud_secret_key}")
    run_args+=(--cloud-zone-id "${cloud_zone_id}" --cloud-service-offering-id "${cloud_service_offering_id}" --cloud-network-ids "${cloud_network_ids}" --cloud-storage-id "${cloud_storage_id}")
    [[ -n "${cloud_cred_file}" ]] && run_args+=(--cloud-cred-file "${cloud_cred_file}")
    [[ -n "${cloud_disk_offering_id}" ]] && run_args+=(--cloud-disk-offering-id "${cloud_disk_offering_id}")
    [[ -n "${cloud_host_id}" ]] && run_args+=(--cloud-host-id "${cloud_host_id}")
    [[ -n "${cloud_account}" ]] && run_args+=(--cloud-account "${cloud_account}")
    [[ -n "${cloud_domain_id}" ]] && run_args+=(--cloud-domain-id "${cloud_domain_id}")
    [[ -n "${cloud_project_id}" ]] && run_args+=(--cloud-project-id "${cloud_project_id}")
    [[ -n "${cloud_name}" ]] && run_args+=(--cloud-name "${cloud_name}")
    [[ -n "${cloud_display_name}" ]] && run_args+=(--cloud-display-name "${cloud_display_name}")
    [[ -n "${cloud_cpu_speed}" ]] && run_args+=(--cloud-cpu-speed "${cloud_cpu_speed}")
  else
    [[ -n "${libvirt_network_mode}" ]] && run_args+=(--network-mode "${libvirt_network_mode}")
    [[ -n "${libvirt_bridge}" ]] && run_args+=(--bridge "${libvirt_bridge}")
    [[ -n "${libvirt_network}" ]] && run_args+=(--network "${libvirt_network}")
  fi

  if [[ "${print_command}" -eq 1 ]]; then
    n2k_interactive_print_command "${run_args[@]}"
    return 0
  fi

  if [[ "${yes}" -eq 0 ]]; then
    n2k_interactive_has_tty || n2k_die "Final confirmation requires a TTY; pass --yes to execute with supplied values"
    printf 'Review the summary above. Type yes to start the migration, or no to cancel.\n' >&2
    n2k_interactive_prompt_confirm "Execute this migration run" "no" || {
      printf 'Migration run cancelled.\n' >&2
      return 0
    }
  fi

  n2k_cmd_run "${run_args[@]}"
}
