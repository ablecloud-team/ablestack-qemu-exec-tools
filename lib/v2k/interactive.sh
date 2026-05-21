#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# Licensed under the Apache License, Version 2.0
# ---------------------------------------------------------------------

set -euo pipefail

v2k_interactive_has_tty() { [[ -t 0 && ( -t 2 || -t 1 ) ]]; }

v2k_interactive_prompt_text() {
  local label="$1" default_value="${2:-}" required="${3:-0}" example="${4:-}" answer
  while true; do
    [[ -z "${example}" ]] || printf '  Example: %s\n' "${example}" >&2
    if [[ -n "${default_value}" ]]; then printf '%s [%s]: ' "${label}" "${default_value}" >&2; else printf '%s: ' "${label}" >&2; fi
    IFS= read -r answer || answer=""
    [[ -n "${answer}" ]] || answer="${default_value}"
    if [[ -n "${answer}" || "${required}" != "1" ]]; then printf '%s' "${answer}"; return 0; fi
    printf 'A value is required.\n' >&2
  done
}

v2k_interactive_prompt_secret() {
  local label="$1" hint="${2:-Input is hidden.}" answer
  while true; do
    [[ -z "${hint}" ]] || printf '  %s\n' "${hint}" >&2
    printf '%s: ' "${label}" >&2
    IFS= read -rs answer || answer=""
    printf '\n' >&2
    if [[ -n "${answer}" ]]; then printf '%s' "${answer}"; return 0; fi
    printf 'A value is required.\n' >&2
  done
}

v2k_interactive_prompt_confirm() {
  local label="$1" default_value="${2:-no}" answer suffix
  case "${default_value}" in yes) suffix="Y/n" ;; *) suffix="y/N" ;; esac
  printf '%s [%s]: ' "${label}" "${suffix}" >&2
  IFS= read -r answer || answer=""
  [[ -n "${answer}" ]] || answer="${default_value}"
  case "${answer}" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

v2k_interactive_select_tsv() {
  local label="$1" choices="$2" current="${3:-}" yes="${4:-0}" default_index="${5:-1}"
  local id name meta choice count=0 idx=0
  local -a ids=() names=() metas=()
  if [[ -n "${current}" ]]; then printf '%s' "${current}"; return 0; fi
  while IFS=$'\t' read -r id name meta; do
    [[ -n "${id}" ]] || continue
    ids+=("${id}"); names+=("${name:-${id}}"); metas+=("${meta:-}")
  done <<< "${choices}"
  count="${#ids[@]}"
  [[ "${count}" -gt 0 ]] || { echo "No selectable item found for ${label}" >&2; return 2; }
  if [[ "${count}" -eq 1 ]]; then printf 'Auto-selected %s: %s (%s)\n' "${label}" "${names[0]}" "${ids[0]}" >&2; printf '%s' "${ids[0]}"; return 0; fi
  [[ "${yes}" -eq 0 ]] || { echo "${label} has multiple candidates; provide an explicit option" >&2; return 2; }
  v2k_interactive_has_tty || { echo "${label} selection requires a TTY" >&2; return 2; }
  printf '\n%s:\n' "${label}" >&2
  for ((idx=0; idx<count; idx++)); do
    if [[ -n "${metas[idx]}" ]]; then printf '  %d. %s (%s) - %s\n' "$((idx+1))" "${names[idx]}" "${ids[idx]}" "${metas[idx]}" >&2; else printf '  %d. %s (%s)\n' "$((idx+1))" "${names[idx]}" "${ids[idx]}" >&2; fi
  done
  while true; do
    choice="$(v2k_interactive_prompt_text "Select ${label}" "${default_index}" 1 "1")"
    if [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le "${count}" ]]; then printf '%s' "${ids[choice-1]}"; return 0; fi
    for ((idx=0; idx<count; idx++)); do
      if [[ "${choice}" == "${ids[idx]}" || "${choice}" == "${names[idx]}" ]]; then printf '%s' "${ids[idx]}"; return 0; fi
    done
    printf 'Invalid selection.\n' >&2
  done
}

v2k_interactive_target_profile_choices() { cat <<'EOF'
cloud-rbd	ABLESTACK Cloud / RBD	default Cloud target
cloud-filesystem	ABLESTACK Cloud / FileSystem qcow2	file primary storage
libvirt-rbd	libvirt / RBD	existing host libvirt path
libvirt-qcow2	libvirt / qcow2	existing host libvirt path
EOF
}

v2k_interactive_cloud_choices() {
  local endpoint="$1" api_key="$2" secret_key="$3" kind="$4" response
  case "${kind}" in
    zones) response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" listZones '{"available":true}')"; printf '%s' "${response}" | jq -r '(.listzonesresponse.zone // [])[] | [.id, (.name // .id), (.allocationstate // "")] | @tsv' ;;
    service-offerings) response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" listServiceOfferings '{"issystem":false}')"; printf '%s' "${response}" | jq -r '(.listserviceofferingsresponse.serviceoffering // [])[] | [.id, (.name // .displaytext // .id), (((.cpunumber // "") | tostring) + " cpu, " + ((.memory // "") | tostring) + " MB")] | @tsv' ;;
    networks) response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" listNetworks '{"listall":true}')"; printf '%s' "${response}" | jq -r '(.listnetworksresponse.network // [])[] | [.id, (.name // .displaytext // .id), (((.type // "") | tostring) + " " + ((.broadcasturi // "") | tostring))] | @tsv' ;;
    storage-pools) response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" listStoragePools '{"listall":true}')"; printf '%s' "${response}" | jq -r '(.liststoragepoolsresponse.storagepool // [])[] | [.id, (.name // .path // .id), (((.type // "") | tostring) + " " + ((.path // "") | tostring) + " " + ((.clustername // "") | tostring))] | @tsv' ;;
    hosts) response="$(v2k_cloud_api_get "${endpoint}" "${api_key}" "${secret_key}" listHosts '{"type":"Routing","state":"Up","listall":true}')"; printf '%s' "${response}" | jq -r '(.listhostsresponse.host // [])[] | [.id, (.name // .id), (((.state // "") | tostring) + " " + ((.clustername // "") | tostring))] | @tsv' ;;
    *) echo "Unsupported Cloud choice kind: ${kind}" >&2; return 2 ;;
  esac
}

v2k_interactive_vm_choices() { v2k_require_govc_env; v2k_govc find / -type m 2>/dev/null | awk -F/ 'NF{n=$NF; print n "\t" n "\t" $0}'; }
v2k_interactive_safe_name() { printf '%s' "$1" | sed -E 's#[/\\]#_#g; s#[[:space:]]+#_#g; s#[^A-Za-z0-9_.-]#_#g; s#_+#_#g; s#^\.+#_#'; }
v2k_interactive_default_workdir() { printf '/var/lib/ablestack-v2k/%s/%s' "$(v2k_interactive_safe_name "$1")" "${V2K_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"; }

v2k_interactive_build_target_map_json() {
  local inventory_json="$1" target_storage="$2" target_format="$3" rbd_pool="$4" file_root="$5" target_name="$6"
  jq -c --arg storage "${target_storage}" --arg format "${target_format}" --arg pool "${rbd_pool}" --arg file_root "${file_root%/}" --arg target_name "${target_name}" '
    def safe_name($s): ($s|tostring)|gsub("[/\\\\]";"_")|gsub("[[:space:]]+";"_")|gsub("[^A-Za-z0-9_.-]";"_")|gsub("_+";"_");
    reduce ((.disks // []) | to_entries[]) as $entry ({};
      ($entry.value.disk_id // ("disk" + ($entry.key|tostring))) as $disk_id
      | . + {($disk_id): (if $storage == "rbd" then ("rbd:" + $pool + "/" + safe_name($target_name) + "-disk" + ($entry.key|tostring)) else ($file_root + "/" + safe_name($target_name) + "-disk" + ($entry.key|tostring) + "." + $format) end)}
    )' <<<"${inventory_json}"
}

v2k_interactive_print_command() {
  local rendered="ablestack_v2k" redact_next=0 arg
  for arg in "$@"; do
    if [[ "${redact_next}" -eq 1 ]]; then rendered+=" REDACTED"; redact_next=0; continue; fi
    case "${arg}" in --password|--cloud-api-key|--cloud-secret-key) rendered+=" $(printf '%q' "${arg}")"; redact_next=1 ;; *) rendered+=" $(printf '%q' "${arg}")" ;; esac
  done
  printf '%s\n' "${rendered}"
}

v2k_cmd_wizard() {
  local vm="" vcenter_host="" username="" password="" cred_file="" vddk_cred_file="" insecure="1" compat_profile="${V2K_COMPAT_PROFILE:-auto}"
  local target_profile="" target_provider="" target_storage="" target_format="" dst="" target_map_json="" rbd_pool="${V2K_WIZARD_RBD_POOL:-rbd}" file_root="${V2K_WIZARD_FILE_ROOT:-/var/lib/libvirt/images}"
  local cloud_endpoint="" cloud_api_key="" cloud_secret_key="" cloud_cred_file="" cloud_zone_id="" cloud_service_offering_id="" cloud_network_ids="" cloud_storage_id="" cloud_disk_offering_id="" cloud_host_id="" cloud_account="" cloud_domain_id="" cloud_project_id="" cloud_name="" cloud_display_name="" cloud_cpu_speed=""
  local split="${V2K_WIZARD_DEFAULT_SPLIT:-phase1}" shutdown="guest" cutover_policy="start" yes=0 print_command=0 target_name inventory_json cloud_choices cloud_storage_json cloud_storage_path cloud_storage_scope
  while [[ $# -gt 0 ]]; do case "$1" in
    --vm) vm="${2:-}"; shift 2;; --vcenter) vcenter_host="${2:-}"; shift 2;; --username) username="${2:-}"; shift 2;; --password) password="${2:-}"; shift 2;; --cred-file) cred_file="${2:-}"; shift 2;; --vddk-cred-file) vddk_cred_file="${2:-}"; shift 2;; --compat-profile) compat_profile="${2:-}"; shift 2;; --insecure) insecure="${2:-}"; shift 2;;
    --target-profile|--profile) target_profile="${2:-}"; shift 2;; --target-provider) target_provider="${2:-}"; shift 2;; --target-storage) target_storage="${2:-}"; shift 2;; --target-format) target_format="${2:-}"; shift 2;; --dst) dst="${2:-}"; shift 2;; --target-map-json) target_map_json="${2:-}"; shift 2;; --rbd-pool) rbd_pool="${2:-}"; shift 2;; --file-root) file_root="${2:-}"; shift 2;;
    --cloud-endpoint) cloud_endpoint="${2:-}"; shift 2;; --cloud-api-key) cloud_api_key="${2:-}"; shift 2;; --cloud-secret-key) cloud_secret_key="${2:-}"; shift 2;; --cloud-cred-file) cloud_cred_file="${2:-}"; shift 2;; --cloud-zone-id) cloud_zone_id="${2:-}"; shift 2;; --cloud-service-offering-id) cloud_service_offering_id="${2:-}"; shift 2;; --cloud-network-id) cloud_network_ids="${cloud_network_ids:+${cloud_network_ids},}${2:-}"; shift 2;; --cloud-network-ids) cloud_network_ids="${2:-}"; shift 2;; --cloud-storage-id) cloud_storage_id="${2:-}"; shift 2;; --cloud-disk-offering-id) cloud_disk_offering_id="${2:-}"; shift 2;; --cloud-host-id) cloud_host_id="${2:-}"; shift 2;; --cloud-account) cloud_account="${2:-}"; shift 2;; --cloud-domain-id) cloud_domain_id="${2:-}"; shift 2;; --cloud-project-id) cloud_project_id="${2:-}"; shift 2;; --cloud-name) cloud_name="${2:-}"; shift 2;; --cloud-display-name) cloud_display_name="${2:-}"; shift 2;; --cloud-cpu-speed) cloud_cpu_speed="${2:-}"; shift 2;;
    --split) split="${2:-}"; shift 2;; --shutdown) shutdown="${2:-}"; shift 2;; --define-only) cutover_policy="define-only"; shift;; --apply) cutover_policy="apply"; shift;; --start) cutover_policy="start"; shift;; --yes|-y) yes=1; shift;; --print-command) print_command=1; shift;; *) echo "Unknown option for wizard: $1" >&2; return 2;; esac; done
  case "${split}" in phase1|phase2|full) ;; *) echo "Invalid --split: ${split}" >&2; return 2;; esac

  [[ -z "${cred_file}" ]] || { v2k_vmware_load_cred_file "${cred_file}"; vcenter_host="${vcenter_host:-$(printf '%s' "${GOVC_URL:-}" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#^.*@##; s#:[0-9]+$##')}"; }
  if [[ -z "${vcenter_host}" ]]; then [[ "${yes}" -eq 0 ]] || { echo "--vcenter is required with --yes" >&2; return 2; }; v2k_interactive_has_tty || { echo "--vcenter is required without a TTY" >&2; return 2; }; vcenter_host="$(v2k_interactive_prompt_text "vCenter host" "" 1 "10.10.10.10")"; fi
  if [[ -z "${cred_file}" ]]; then
    if [[ -z "${username}" ]]; then [[ "${yes}" -eq 0 ]] || { echo "--username or --cred-file is required with --yes" >&2; return 2; }; v2k_interactive_has_tty || return 2; username="$(v2k_interactive_prompt_text "vCenter username" "administrator@vsphere.local" 1 "administrator@vsphere.local")"; fi
    if [[ -z "${password}" ]]; then [[ "${yes}" -eq 0 ]] || { echo "--password or --cred-file is required with --yes" >&2; return 2; }; v2k_interactive_has_tty || return 2; password="$(v2k_interactive_prompt_secret "vCenter password")"; fi
    export GOVC_URL="https://${vcenter_host}/sdk" GOVC_USERNAME="${username}" GOVC_PASSWORD="${password}" GOVC_INSECURE="${insecure}"
  fi
  if [[ -z "${vm}" ]]; then
    if choices="$(v2k_interactive_vm_choices 2>/dev/null)" && [[ -n "${choices}" ]]; then vm="$(v2k_interactive_select_tsv "source VM" "${choices}" "" "${yes}" 1)"; else [[ "${yes}" -eq 0 ]] || { echo "--vm is required with --yes" >&2; return 2; }; v2k_interactive_has_tty || return 2; vm="$(v2k_interactive_prompt_text "Source VM" "" 1 "my-vm")"; fi
  fi
  if [[ -z "${target_profile}" ]]; then if [[ "${yes}" -eq 1 ]]; then target_profile="cloud-rbd"; else target_profile="$(v2k_interactive_select_tsv "target profile" "$(v2k_interactive_target_profile_choices)" "" 0 1)"; fi; fi
  case "${target_profile}" in cloud-rbd) target_provider="${target_provider:-ablestack-cloud}"; target_storage="${target_storage:-rbd}"; target_format="${target_format:-raw}";; cloud-filesystem|cloud-qcow2) target_profile="cloud-filesystem"; target_provider="${target_provider:-ablestack-cloud}"; target_storage="${target_storage:-file}"; target_format="${target_format:-qcow2}";; libvirt-rbd) target_provider="${target_provider:-libvirt}"; target_storage="${target_storage:-rbd}"; target_format="${target_format:-raw}";; libvirt-qcow2) target_provider="${target_provider:-libvirt}"; target_storage="${target_storage:-file}"; target_format="${target_format:-qcow2}";; *) echo "Invalid --target-profile: ${target_profile}" >&2; return 2;; esac
  target_name="${cloud_name:-v2k-$(v2k_interactive_safe_name "${vm}")-$(date +%Y%m%d%H%M%S)}"; cloud_name="${cloud_name:-${target_name}}"; cloud_display_name="${cloud_display_name:-${cloud_name}}"
  if [[ -z "${V2K_WORKDIR:-}" && "${split}" != "phase2" ]]; then V2K_WORKDIR="$(v2k_interactive_default_workdir "${vm}")"; export V2K_WORKDIR; V2K_MANIFEST="${V2K_WORKDIR}/manifest.json"; export V2K_MANIFEST; fi

  if [[ "${target_provider}" == "ablestack-cloud" ]]; then
    [[ -z "${cloud_cred_file}" ]] || v2k_cloud_load_cred_file "${cloud_cred_file}"
    cloud_endpoint="${cloud_endpoint:-${V2K_CLOUD_ENDPOINT:-${ABLESTACK_CLOUD_ENDPOINT:-${CLOUDSTACK_ENDPOINT:-}}}}"; cloud_api_key="$(v2k_cloud_resolve_api_key "${cloud_api_key}")"; cloud_secret_key="$(v2k_cloud_resolve_secret_key "${cloud_secret_key}")"; cloud_cpu_speed="${cloud_cpu_speed:-1000}"
    [[ -n "${cloud_endpoint}" ]] || { echo "--cloud-endpoint is required" >&2; return 2; }; [[ -n "${cloud_api_key}" ]] || { echo "--cloud-api-key/env/cred-file is required" >&2; return 2; }; [[ -n "${cloud_secret_key}" ]] || { echo "--cloud-secret-key/env/cred-file is required" >&2; return 2; }
    [[ -n "${cloud_zone_id}" ]] || { cloud_choices="$(v2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" zones)"; cloud_zone_id="$(v2k_interactive_select_tsv "Cloud zone" "${cloud_choices}" "" "${yes}" 1)"; }
    [[ -n "${cloud_service_offering_id}" ]] || { cloud_choices="$(v2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" service-offerings)"; cloud_service_offering_id="$(v2k_interactive_select_tsv "Cloud service offering" "${cloud_choices}" "" "${yes}" 1)"; }
    [[ -n "${cloud_network_ids}" ]] || { cloud_choices="$(v2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" networks)"; cloud_network_ids="$(v2k_interactive_select_tsv "Cloud network" "${cloud_choices}" "" "${yes}" 1)"; }
    [[ -n "${cloud_storage_id}" ]] || { cloud_choices="$(v2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" storage-pools)"; cloud_storage_id="$(v2k_interactive_select_tsv "Cloud storage pool" "${cloud_choices}" "" "${yes}" 1)"; }
    if [[ "${target_storage}" == "file" ]]; then cloud_storage_json="$(v2k_cloud_target_storage_pool_json "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" "${cloud_storage_id}")"; cloud_storage_path="$(v2k_cloud_target_file_storage_path_from_pool "${cloud_storage_json}")"; file_root="${cloud_storage_path}"; cloud_storage_scope="$(jq -r '(.scope // "") | tostring' <<<"${cloud_storage_json}")"; if [[ "${cloud_storage_scope}" == "HOST" && -z "${cloud_host_id}" ]]; then cloud_choices="$(v2k_interactive_cloud_choices "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" hosts)"; cloud_host_id="$(v2k_interactive_select_tsv "Cloud host" "${cloud_choices}" "" "${yes}" 1)"; fi; fi
  fi
  if [[ -z "${dst}" ]]; then case "${target_storage}" in rbd) dst="rbd:${rbd_pool}/${target_name}";; file) if [[ "${target_provider}" == "ablestack-cloud" ]]; then dst="${file_root%/}"; else dst="${file_root%/}/${target_name}"; fi;; esac; fi
  if [[ -z "${target_map_json}" && ( "${target_storage}" == "rbd" || "${target_provider}" == "ablestack-cloud" ) ]]; then inventory_json="$(v2k_vmware_inventory_json "${vm}" "${vcenter_host}")" || { echo "source inventory is required to generate target disk paths" >&2; return 2; }; target_map_json="$(v2k_interactive_build_target_map_json "${inventory_json}" "${target_storage}" "${target_format}" "${rbd_pool}" "${file_root}" "${target_name}")"; fi

  printf '\nMigration summary:\n  Source VM: %s\n  vCenter: %s\n  Target profile: %s\n  Target provider: %s\n  Target storage: %s/%s\n  Split: %s\n  Workdir: %s\n  Destination: %s\n' "${vm}" "${vcenter_host}" "${target_profile}" "${target_provider}" "${target_storage}" "${target_format}" "${split}" "${V2K_WORKDIR:-}" "${dst}" >&2
  local -a run_args=(run --foreground --vm "${vm}" --vcenter "${vcenter_host}" --split "${split}" --shutdown "${shutdown}" --compat-profile "${compat_profile}" --target-provider "${target_provider}" --target-storage "${target_storage}" --target-format "${target_format}" --dst "${dst}")
  [[ -n "${cred_file}" ]] && run_args+=(--cred-file "${cred_file}"); [[ -n "${vddk_cred_file}" ]] && run_args+=(--vddk-cred-file "${vddk_cred_file}"); [[ -z "${cred_file}" ]] && run_args+=(--username "${username}" --password "${password}" --insecure "${insecure}"); [[ -n "${target_map_json}" && "${target_map_json}" != "{}" ]] && run_args+=(--target-map-json "${target_map_json}")
  case "${cutover_policy}" in define-only) run_args+=(--kvm-vm-policy define-only);; apply) run_args+=(--cutover-args "--apply");; start) run_args+=(--kvm-vm-policy define-and-start);; esac
  if [[ "${target_provider}" == "ablestack-cloud" ]]; then run_args+=(--cloud-endpoint "${cloud_endpoint}" --cloud-api-key "${cloud_api_key}" --cloud-secret-key "${cloud_secret_key}" --cloud-zone-id "${cloud_zone_id}" --cloud-service-offering-id "${cloud_service_offering_id}" --cloud-network-ids "${cloud_network_ids}" --cloud-storage-id "${cloud_storage_id}"); [[ -n "${cloud_cred_file}" ]] && run_args+=(--cloud-cred-file "${cloud_cred_file}"); [[ -n "${cloud_disk_offering_id}" ]] && run_args+=(--cloud-disk-offering-id "${cloud_disk_offering_id}"); [[ -n "${cloud_host_id}" ]] && run_args+=(--cloud-host-id "${cloud_host_id}"); [[ -n "${cloud_account}" ]] && run_args+=(--cloud-account "${cloud_account}"); [[ -n "${cloud_domain_id}" ]] && run_args+=(--cloud-domain-id "${cloud_domain_id}"); [[ -n "${cloud_project_id}" ]] && run_args+=(--cloud-project-id "${cloud_project_id}"); [[ -n "${cloud_name}" ]] && run_args+=(--cloud-name "${cloud_name}"); [[ -n "${cloud_display_name}" ]] && run_args+=(--cloud-display-name "${cloud_display_name}"); [[ -n "${cloud_cpu_speed}" ]] && run_args+=(--cloud-cpu-speed "${cloud_cpu_speed}"); fi
  if [[ "${print_command}" -eq 1 ]]; then v2k_interactive_print_command "${run_args[@]}"; return 0; fi
  if [[ "${yes}" -eq 0 ]]; then v2k_interactive_has_tty || { echo "Final confirmation requires a TTY; pass --yes" >&2; return 2; }; v2k_interactive_prompt_confirm "Execute this migration run" "no" || { echo "Migration run cancelled." >&2; return 0; }; fi
  v2k_cmd_run "${run_args[@]:1}"
}
