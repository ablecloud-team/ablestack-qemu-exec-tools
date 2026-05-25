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

N2K_ROOT_DIR="${N2K_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
N2K_LIB_DIR="${N2K_LIB_DIR:-${N2K_ROOT_DIR}/lib/n2k}"

# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/logging.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/manifest.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/preflight.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/nutanix_api.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/source_adapter.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/target_storage.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/cloudstack_api.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/target_cloud.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/transfer_cold.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/transfer_patch.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/target_libvirt.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/interactive.sh"

n2k_die() {
  echo "ERROR: $*" >&2
  exit 2
}

n2k_not_implemented() {
  local cmd="$1"
  if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
    jq -nc --arg command "${cmd}" '{ok:false,command:$command,error:"not_implemented"}'
  else
    echo "Command '${cmd}' is not implemented yet. See docs/n2k/ablestack_n2k_development_plan.md." >&2
  fi
  exit 3
}

n2k_valid_mode() {
  case "${1:-}" in
    auto|v4-incremental|v3-incremental|legacy-cbt|cold-export|manual-disk) return 0 ;;
    *) return 1 ;;
  esac
}

n2k_valid_target_format() {
  case "${1:-}" in
    qcow2|raw) return 0 ;;
    *) return 1 ;;
  esac
}

n2k_valid_target_storage() {
  case "${1:-}" in
    file|block|rbd) return 0 ;;
    *) return 1 ;;
  esac
}

n2k_valid_target_provider() {
  case "${1:-}" in
    libvirt|ablestack-cloud) return 0 ;;
    *) return 1 ;;
  esac
}

n2k_valid_rbd_access_mode() {
  case "${1:-}" in
    librbd|krbd) return 0 ;;
    *) return 1 ;;
  esac
}

n2k_safe_name() {
  local raw="${1:-vm}"
  raw="${raw//\//_}"
  raw="${raw//\\/_}"
  raw="${raw// /_}"
  raw="${raw//	/_}"
  raw="${raw//:/_}"
  [[ -n "${raw}" ]] || raw="vm"
  printf '%s' "${raw}"
}

n2k_generate_run_id() {
  printf '%s-%s\n' "$(date +%Y%m%d-%H%M%S)" "$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

n2k_set_default_paths() {
  local vm="${1:-vm}"
  local safe_vm
  safe_vm="$(n2k_safe_name "${vm}")"

  if [[ -z "${N2K_RUN_ID:-}" ]]; then
    N2K_RUN_ID="$(n2k_generate_run_id)"
    export N2K_RUN_ID
  fi
  if [[ -z "${N2K_WORKDIR:-}" ]]; then
    N2K_WORKDIR="/var/lib/ablestack-n2k/${safe_vm}/${N2K_RUN_ID}"
    export N2K_WORKDIR
  fi
  if [[ -z "${N2K_MANIFEST:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -z "${N2K_EVENTS_LOG:-}" ]]; then
    N2K_EVENTS_LOG="${N2K_WORKDIR}/events.log"
    export N2K_EVENTS_LOG
  fi
}

n2k_require_manifest() {
  [[ -n "${N2K_MANIFEST:-}" && -f "${N2K_MANIFEST}" ]] || {
    echo "Manifest not found. Use --manifest or --workdir, or run init first." >&2
    exit 2
  }
}

n2k_json_or_text_ok() {
  local phase="$1" json_payload="$2" text="$3"
  if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
    jq -nc --arg phase "${phase}" --slurpfile payload_json <(printf '%s' "${json_payload}") '{ok:true,phase:$phase,payload:$payload_json[0]}'
  else
    echo "${text}"
  fi
}

n2k_cmd_init() {
  local vm="" pc="" dst="" mode="auto" cred_file=""
  local username="" password="" insecure="1"
  local inventory_json_arg="" inventory_source="none"
  local target_format="qcow2" target_storage="file" target_map_json="{}" rbd_access_mode="librbd"
  local target_provider="libvirt"
  local cloud_endpoint="" cloud_api_key="" cloud_secret_key="" cloud_cred_file=""
  local cloud_zone_id="" cloud_service_offering_id="" cloud_network_ids=""
  local cloud_storage_id="" cloud_disk_offering_id="" cloud_host_id="" cloud_account="" cloud_domain_id=""
  local cloud_project_id="" cloud_name="" cloud_display_name="" cloud_cpu_speed=""
  local force_v3=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vm) vm="${2:-}"; shift 2 ;;
      --pc) pc="${2:-}"; shift 2 ;;
      --dst) dst="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --force-v3|--force-v3-incremental) force_v3=true; shift 1 ;;
      --cred-file) cred_file="${2:-}"; shift 2 ;;
      --username) username="${2:-}"; shift 2 ;;
      --password) password="${2:-}"; shift 2 ;;
      --insecure) insecure="${2:-}"; shift 2 ;;
      --inventory-json) inventory_json_arg="${2:-}"; inventory_source="fixture"; shift 2 ;;
      --inventory-file) inventory_json_arg="${2:-}"; inventory_source="fixture"; shift 2 ;;
      --inventory-source) inventory_source="${2:-}"; shift 2 ;;
      --target-format) target_format="${2:-}"; shift 2 ;;
      --target-storage) target_storage="${2:-}"; shift 2 ;;
      --target-map-json) target_map_json="${2:-}"; shift 2 ;;
      --rbd-access-mode) rbd_access_mode="${2:-}"; shift 2 ;;
      --target-provider) target_provider="${2:-}"; shift 2 ;;
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
      *) n2k_die "Unknown option for init: $1" ;;
    esac
  done

  [[ -n "${vm}" ]] || n2k_die "init requires --vm"
  [[ -n "${pc}" ]] || n2k_die "init requires --pc"
  n2k_valid_mode "${mode}" || n2k_die "Invalid --mode: ${mode}"
  if [[ "${force_v3}" == "true" ]]; then
    [[ "${mode}" == "auto" || "${mode}" == "v3-incremental" ]] || \
      n2k_die "--force-v3 conflicts with --mode ${mode}"
    mode="v3-incremental"
  fi
  if [[ "${target_storage}" == "qcow2" ]]; then
    target_storage="file"
    target_format="qcow2"
  fi
  n2k_valid_target_format "${target_format}" || n2k_die "Invalid --target-format: ${target_format}"
  n2k_valid_target_storage "${target_storage}" || n2k_die "Invalid --target-storage: ${target_storage}"
  n2k_valid_target_provider "${target_provider}" || n2k_die "Invalid --target-provider: ${target_provider}"
  n2k_valid_rbd_access_mode "${rbd_access_mode}" || n2k_die "Invalid --rbd-access-mode: ${rbd_access_mode}"
  case "${inventory_source}" in
    none|fixture|api) ;;
    *) n2k_die "Invalid --inventory-source: ${inventory_source}" ;;
  esac
  case "${insecure}" in
    0|1) ;;
    *) n2k_die "Invalid --insecure: ${insecure}" ;;
  esac

  if [[ -n "${cred_file}" ]]; then
    n2k_nutanix_load_cred_file "${cred_file}"
    username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
    password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"
  fi

  local cloud_config_json storage_pool_json storage_path storage_pool_config
  if [[ "${target_provider}" == "ablestack-cloud" && "${target_storage}" == "file" ]]; then
    [[ -n "${cloud_storage_id}" ]] || n2k_die "Cloud file/qcow2 target requires --cloud-storage-id"
    local cloud_runtime cloud_runtime_endpoint cloud_runtime_api_key cloud_runtime_secret_key
    cloud_runtime="$(n2k_cloud_target_resolve_runtime_json "" "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" "${cloud_cred_file}")"
    cloud_runtime_endpoint="$(jq -r '.endpoint // ""' <<<"${cloud_runtime}")"
    cloud_runtime_api_key="$(jq -r '.api_key // ""' <<<"${cloud_runtime}")"
    cloud_runtime_secret_key="$(jq -r '.secret_key // ""' <<<"${cloud_runtime}")"
    n2k_cloud_require_credentials "${cloud_runtime_endpoint}" "${cloud_runtime_api_key}" "${cloud_runtime_secret_key}" || return $?
    storage_pool_json="$(n2k_cloud_target_storage_pool_json "${cloud_runtime_endpoint}" "${cloud_runtime_api_key}" "${cloud_runtime_secret_key}" "${cloud_storage_id}")" || return $?
    [[ -n "${storage_pool_json}" ]] || n2k_die "Cloud storage pool was not found: ${cloud_storage_id}"
    storage_path="$(n2k_cloud_target_file_storage_path_from_pool "${storage_pool_json}")" || return $?
    if [[ -n "${dst}" && "${dst%/}" != "${storage_path}" ]]; then
      n2k_die "Cloud file/qcow2 target root must match selected Cloud storage path: ${storage_path} (got ${dst%/})"
    fi
    dst="${storage_path}"
    if [[ -n "${target_map_json}" && "${target_map_json}" != "{}" ]]; then
      local bad_map_paths
      bad_map_paths="$(jq -r --arg pool_path "${storage_path}" '
        to_entries[]
        | (.value | tostring) as $path
        | select(
            ($path | startswith($pool_path + "/") | not)
            or (($path | sub("/[^/]*$"; "")) != $pool_path)
          )
        | $path
      ' <<<"${target_map_json}")"
      [[ -z "${bad_map_paths}" ]] || {
        echo "Cloud file/qcow2 target map must use root-level files under selected Cloud storage path: ${storage_path}" >&2
        printf '%s\n' "${bad_map_paths}" >&2
        return 2
      }
    fi
  else
    [[ -n "${dst}" ]] || dst="/var/lib/libvirt/images/$(n2k_safe_name "${vm}")"
  fi

  n2k_set_default_paths "${vm}"
  mkdir -p "${N2K_WORKDIR}"

  local inventory_raw="" inventory_json=""
  if [[ "${inventory_source}" == "fixture" ]]; then
    inventory_raw="$(n2k_nutanix_load_inventory_json_arg "${inventory_json_arg}")"
    inventory_json="$(n2k_nutanix_inventory_from_raw "${inventory_raw}" "${vm}")"
  elif [[ "${inventory_source}" == "api" ]]; then
    [[ -n "${username}" ]] || n2k_die "API inventory source requires --username or credential file"
    [[ -n "${password}" ]] || n2k_die "API inventory source requires --password or credential file"
    inventory_raw="$(n2k_nutanix_fetch_vm_inventory "${pc}" "${vm}" "${username}" "${password}" "${insecure}")"
    inventory_json="$(n2k_nutanix_inventory_from_raw "${inventory_raw}" "${vm}")"
  fi

  cloud_config_json="$(n2k_cloud_target_config_json "${cloud_endpoint}" "${cloud_zone_id}" "${cloud_service_offering_id}" "${cloud_network_ids}" "${cloud_storage_id}" "${cloud_disk_offering_id}" "${cloud_host_id}" "${cloud_account}" "${cloud_domain_id}" "${cloud_project_id}" "${cloud_name}" "${cloud_display_name}" "${cloud_cpu_speed}")"
  if [[ -n "${storage_pool_json:-}" ]]; then
    storage_pool_config="$(n2k_cloud_target_storage_pool_config_json "${storage_pool_json}")"
    cloud_config_json="$(jq -c --argjson pool "${storage_pool_config}" '. + {storage_pool:$pool}' <<<"${cloud_config_json}")"
  fi
  n2k_manifest_init "${N2K_MANIFEST}" "${N2K_RUN_ID}" "${N2K_WORKDIR}" "${vm}" "${pc}" "${mode}" "${dst}" "${target_format}" "${target_storage}" "${target_map_json}" "${inventory_json}" "${rbd_access_mode}" "${target_provider}" "${cloud_config_json}"
  n2k_event INFO "init" "" "manifest_created" "{\"manifest\":\"${N2K_MANIFEST}\"}"
  if [[ -n "${inventory_json}" ]]; then
    n2k_event INFO "init" "" "inventory_loaded" "${inventory_json}"
  fi
  n2k_json_or_text_ok "init" "{\"manifest\":\"${N2K_MANIFEST}\",\"workdir\":\"${N2K_WORKDIR}\",\"run_id\":\"${N2K_RUN_ID}\"}" "Init done. Manifest: ${N2K_MANIFEST}"
}

n2k_cmd_status() {
  local vm="" watch=0 resume_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vm) vm="${2:-}"; shift 2 ;;
      --watch) watch=1; shift 1 ;;
      --resume-plan) resume_only=1; shift 1 ;;
      *) n2k_die "Unknown option for status: $1" ;;
    esac
  done

  if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -z "${N2K_EVENTS_LOG:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_EVENTS_LOG="${N2K_WORKDIR}/events.log"
    export N2K_EVENTS_LOG
  fi

  [[ "${watch}" -eq 0 ]] || n2k_die "status --watch is not implemented yet"
  [[ -z "${vm}" ]] || n2k_die "fleet status by --vm is not implemented yet"

  local runner_state_file="${N2K_WORKDIR:+${N2K_WORKDIR%/}/runner.json}"
  if [[ ( -z "${N2K_MANIFEST:-}" || ! -f "${N2K_MANIFEST}" ) && -n "${runner_state_file}" && -f "${runner_state_file}" ]]; then
    local runner_summary
    runner_summary="$(jq -c --arg workdir "${N2K_WORKDIR:-}" --slurpfile runner "${runner_state_file}" '
      ($runner[0] // {}) as $r
      | {
          run_id: "",
          source: {vm: "", mode: ""},
          target: {storage: "", format: ""},
          disks_count: 0,
          workdir: $workdir,
          phases: {},
          runtime: {runner: $r, progress: {last_step: ($r.state // "starting")}},
          resume: {
            completed: false,
            can_resume: false,
            next_step: ($r.state // "starting"),
            last_step: ($r.state // "starting"),
            percent: 0,
            reason: "background runner has started; manifest is not initialized yet"
          },
          display_step: "Init",
          sync_progress: {mode: "Starting", done_bytes: 0, total_bytes: 0, percent: 0},
          sync_total: {done_bytes: 0, known_total_bytes: 0, percent: 0}
        }
    ')"
    if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
      if [[ "${resume_only}" -eq 1 ]]; then
        printf '%s\n' "${runner_summary}" | jq -c '.resume'
      else
        printf '%s\n' "${runner_summary}"
      fi
    else
      printf 'Workdir: %s\nLast step: %s\nProgress: 0%%\n' "${N2K_WORKDIR:-}" "$(printf '%s\n' "${runner_summary}" | jq -r '.resume.last_step // "starting"')"
    fi
    return 0
  fi

  n2k_require_manifest
  local summary
  summary="$(n2k_manifest_status_summary "${N2K_MANIFEST}" "${N2K_EVENTS_LOG:-}")"
  if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
    if [[ "${resume_only}" -eq 1 ]]; then
      printf '%s\n' "${summary}" | jq -c '.resume'
    else
      printf '%s\n' "${summary}"
    fi
  else
    if [[ "${resume_only}" -eq 1 ]]; then
      printf '%s\n' "${summary}" | jq -r '
        "Next step: " + (.resume.next_step // "") + "\n" +
        "Next command: " + (.resume.next_command // "") + "\n" +
        "Can resume: " + ((.resume.can_resume // false) | tostring) + "\n" +
        "Reason: " + (.resume.reason // "")
      '
    else
      printf '%s\n' "${summary}" | jq -r '
        "Run ID: " + (.run_id // "") + "\n" +
        "VM: " + (.source.vm // "") + "\n" +
        "Mode: " + (.source.mode // "") + "\n" +
        "Target: " + (.target.storage // "") + "/" + (.target.format // "") + "\n" +
        "Disks: " + ((.disks_count // 0) | tostring) + "\n" +
        "Workdir: " + (.workdir // "") + "\n" +
        "Last step: " + (.runtime.progress.last_step // "") + "\n" +
        "Progress: " + ((.resume.percent // 0) | tostring) + "%\n" +
        "Next step: " + (.resume.next_step // "") + "\n" +
        "Next command: " + (.resume.next_command // "") + "\n" +
        "Cleanup pending: " + ((.cleanup.items_pending // 0) | tostring)
      '
    fi
  fi
}

n2k_build_preflight_result_from_args() {
  local require_vm="$1"
  shift || true

  local pc="" vm="" mode="auto" allow_experimental=false capability_json_arg=""
  local cred_file="" username="" password="" insecure="1" probe_legacy=false
  local v4_vmm="auto" v4_dp="auto" v4_data_plane="auto" legacy="auto" legacy_verified="auto" cold="auto" manual="auto"
  local target_storage="auto" target_format="qcow2" rbd_access_mode="librbd"
  local target_provider="libvirt" target_provider_arg_set=0
  local cloud_endpoint="" cloud_api_key="" cloud_secret_key="" cloud_cred_file=""
  local cloud_zone_id="" cloud_service_offering_id="" cloud_network_ids="" cloud_storage_id=""
  local cloud_disk_offering_id="" cloud_host_id="" cloud_account="" cloud_domain_id="" cloud_project_id=""
  local cloud_name="" cloud_display_name="" cloud_cpu_speed=""
  local source_api_policy="auto" force_v3=false
  local parsed_bool=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pc) pc="${2:-}"; shift 2 ;;
      --vm) vm="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --target-storage) target_storage="${2:-}"; shift 2 ;;
      --target-format) target_format="${2:-}"; shift 2 ;;
      --rbd-access-mode) rbd_access_mode="${2:-}"; shift 2 ;;
      --target-provider) target_provider="${2:-}"; target_provider_arg_set=1; shift 2 ;;
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
      --source-api)
        source_api_policy="${2:-}"
        case "${source_api_policy}" in
          auto) ;;
          v3) force_v3=true ;;
          *) n2k_die "preflight/plan --source-api currently supports auto|v3" ;;
        esac
        shift 2
        ;;
      --force-v3|--force-v3-incremental) force_v3=true; source_api_policy="v3"; shift 1 ;;
      --cred-file)
        cred_file="${2:-}"
        [[ -f "${cred_file}" ]] || n2k_die "Credential file not found: ${cred_file}"
        shift 2
        ;;
      --username) username="${2:-}"; shift 2 ;;
      --password) password="${2:-}"; shift 2 ;;
      --insecure) insecure="${2:-}"; shift 2 ;;
      --capability-json) capability_json_arg="${2:-}"; shift 2 ;;
      --v4-vmm)
        parsed_bool="$(n2k_bool_arg "${2:-}" || true)"
        [[ -n "${parsed_bool}" ]] || n2k_die "Invalid --v4-vmm value"
        v4_vmm="${parsed_bool}"
        shift 2
        ;;
      --v4-dataprotection)
        parsed_bool="$(n2k_bool_arg "${2:-}" || true)"
        [[ -n "${parsed_bool}" ]] || n2k_die "Invalid --v4-dataprotection value"
        v4_dp="${parsed_bool}"
        shift 2
        ;;
      --v4-data-plane)
        parsed_bool="$(n2k_bool_arg "${2:-}" || true)"
        [[ -n "${parsed_bool}" ]] || n2k_die "Invalid --v4-data-plane value"
        v4_data_plane="${parsed_bool}"
        shift 2
        ;;
      --legacy-changed-regions)
        parsed_bool="$(n2k_bool_arg "${2:-}" || true)"
        [[ -n "${parsed_bool}" ]] || n2k_die "Invalid --legacy-changed-regions value"
        legacy="${parsed_bool}"
        shift 2
        ;;
      --legacy-endpoint-verified)
        parsed_bool="$(n2k_bool_arg "${2:-}" || true)"
        [[ -n "${parsed_bool}" ]] || n2k_die "Invalid --legacy-endpoint-verified value"
        legacy_verified="${parsed_bool}"
        shift 2
        ;;
      --cold-export-available)
        parsed_bool="$(n2k_bool_arg "${2:-}" || true)"
        [[ -n "${parsed_bool}" ]] || n2k_die "Invalid --cold-export-available value"
        cold="${parsed_bool}"
        shift 2
        ;;
      --manual-disk-available)
        parsed_bool="$(n2k_bool_arg "${2:-}" || true)"
        [[ -n "${parsed_bool}" ]] || n2k_die "Invalid --manual-disk-available value"
        manual="${parsed_bool}"
        shift 2
        ;;
      --probe-legacy-cbt) probe_legacy=true; shift 1 ;;
      --allow-experimental) allow_experimental=true; shift 1 ;;
      *) n2k_die "Unknown capability option: $1" ;;
    esac
  done

  [[ -n "${pc}" ]] || n2k_die "preflight requires --pc"
  if [[ "${require_vm}" == "1" ]]; then
    [[ -n "${vm}" ]] || n2k_die "plan requires --vm"
  fi
  n2k_valid_mode "${mode}" || n2k_die "Invalid --mode: ${mode}"
  if [[ "${force_v3}" == "true" ]]; then
    [[ "${mode}" == "auto" || "${mode}" == "v3-incremental" ]] || \
      n2k_die "--force-v3/--source-api v3 conflicts with --mode ${mode}"
    source_api_policy="v3"
  fi
  case "${insecure}" in
    0|1) ;;
    *) n2k_die "Invalid --insecure: ${insecure}" ;;
  esac
  case "${target_storage}" in
    auto|file|block|rbd) ;;
    qcow2)
      target_storage="file"
      target_format="qcow2"
      ;;
    *) n2k_die "Invalid --target-storage: ${target_storage}" ;;
  esac
  n2k_valid_target_format "${target_format}" || n2k_die "Invalid --target-format: ${target_format}"
  n2k_valid_target_provider "${target_provider}" || n2k_die "Invalid --target-provider: ${target_provider}"
  n2k_valid_rbd_access_mode "${rbd_access_mode}" || n2k_die "Invalid --rbd-access-mode: ${rbd_access_mode}"

  local capability_json deps_json probed_json cloud_config_json cloud_probe_json cloud_runtime_json cloud_endpoint_runtime cloud_api_runtime cloud_secret_runtime
  capability_json="$(n2k_load_json_arg "${capability_json_arg}")"
  cloud_config_json="$(n2k_cloud_target_config_json "${cloud_endpoint}" "${cloud_zone_id}" "${cloud_service_offering_id}" "${cloud_network_ids}" "${cloud_storage_id}" "${cloud_disk_offering_id}" "${cloud_host_id}" "${cloud_account}" "${cloud_domain_id}" "${cloud_project_id}" "${cloud_name}" "${cloud_display_name}" "${cloud_cpu_speed}")"
  if [[ "${probe_legacy}" == "true" || "${capability_json}" == "{}" && ( -n "${cred_file}" || -n "${username}" || -n "${password}" ) ]]; then
    if [[ -n "${cred_file}" ]]; then
      n2k_nutanix_load_cred_file "${cred_file}"
      username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
      password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"
    fi
    if [[ -n "${username}" && -n "${password}" ]]; then
      probed_json="$(n2k_source_probe_capabilities "${pc}" "${vm}" "${username}" "${password}" "${insecure}" "${probe_legacy}")"
      capability_json="$(jq -cs '.[0] * .[1]' <(printf '%s\n' "${probed_json}") <(printf '%s\n' "${capability_json}"))"
    elif [[ "${probe_legacy}" == "true" ]]; then
      n2k_die "--probe-legacy-cbt requires --username/--password or --cred-file"
    fi
  fi
  if [[ "${target_provider_arg_set}" -eq 1 || "$(jq -r 'length' <<<"${cloud_config_json}")" -gt 0 ]]; then
    capability_json="$(jq -cs --arg provider "${target_provider}" --argjson cloud_config "${cloud_config_json}" '.[0] * {target:{provider:$provider,cloud:{config:$cloud_config}}}' <(printf '%s\n' "${capability_json}"))"
  fi
  if [[ "${target_provider}" == "ablestack-cloud" || -n "${cloud_endpoint}" || -n "${cloud_api_key}" || -n "${cloud_secret_key}" || -n "${cloud_cred_file}" ]]; then
    cloud_runtime_json="$(n2k_cloud_target_resolve_runtime_json /dev/null "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" "${cloud_cred_file}" 2>/dev/null || true)"
    [[ -n "${cloud_runtime_json}" ]] || cloud_runtime_json="{}"
    cloud_endpoint_runtime="$(jq -r '.endpoint // ""' <<<"${cloud_runtime_json}")"
    cloud_api_runtime="$(jq -r '.api_key // ""' <<<"${cloud_runtime_json}")"
    cloud_secret_runtime="$(jq -r '.secret_key // ""' <<<"${cloud_runtime_json}")"
    if [[ -n "${cloud_endpoint_runtime}" && -n "${cloud_api_runtime}" && -n "${cloud_secret_runtime}" ]]; then
      cloud_probe_json="$(n2k_cloud_target_preflight_json "${cloud_endpoint_runtime}" "${cloud_api_runtime}" "${cloud_secret_runtime}")" || \
        cloud_probe_json="$(jq -nc '{available:false,error:"probe_failed"}')"
      capability_json="$(jq -cs --argjson cloud_probe "${cloud_probe_json}" '.[0] * {target:{cloud:$cloud_probe}}' <(printf '%s\n' "${capability_json}"))"
    fi
  fi
  deps_json="$(n2k_detect_host_dependencies)"

  n2k_preflight_result_json "${pc}" "${vm}" "${mode}" "${allow_experimental}" \
    "${capability_json}" "${deps_json}" \
    "${v4_vmm}" "${v4_dp}" "${v4_data_plane}" "${legacy}" "${legacy_verified}" "${cold}" "${manual}" \
    "${target_storage}" "${target_format}" "${source_api_policy}" "${target_provider}"
}

n2k_maybe_record_phase_done() {
  local phase="$1"
  if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -n "${N2K_MANIFEST:-}" && -f "${N2K_MANIFEST}" ]]; then
    n2k_manifest_phase_done "${N2K_MANIFEST}" "${phase}" || true
  fi
}

n2k_maybe_record_preflight_result() {
  local result="$1"
  if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -n "${N2K_MANIFEST:-}" && -f "${N2K_MANIFEST}" ]]; then
    n2k_manifest_record_preflight_result "${N2K_MANIFEST}" "${result}" || true
  fi
}

n2k_run_set_manifest_paths_from_workdir() {
  if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -z "${N2K_EVENTS_LOG:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_EVENTS_LOG="${N2K_WORKDIR}/events.log"
    export N2K_EVENTS_LOG
  fi
}

n2k_run_manifest_phase_done() {
  local manifest="$1" phase="$2"
  jq -e --arg phase "${phase}" '.phases[$phase].done // false' "${manifest}" >/dev/null 2>&1
}

n2k_run_manifest_has_recovery_point() {
  local manifest="$1" kind="$2"
  jq -e --arg kind "${kind}" '((.runtime.recovery_points[$kind].id // "") | length) > 0' "${manifest}" >/dev/null 2>&1
}

n2k_run_manifest_value() {
  local manifest="$1" filter="$2"
  jq -r "${filter}" "${manifest}"
}

n2k_run_text_or_json() {
  local split="$1" state="$2" message="$3"
  if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
    jq -nc --arg split "${split}" --arg state "${state}" --arg message "${message}" \
      '{ok:true,phase:"run",split:$split,state:$state,message:$message}'
  else
    printf '%s\n' "${message}"
  fi
}

n2k_run_shutdown_payload_is_empty() {
  local payload="${1:-}"
  [[ "$(printf '%s' "${payload}" | jq -r 'type == "object" and length == 0' 2>/dev/null || printf false)" == "true" ]]
}

n2k_run_reconstruct_empty_shutdown_payload() {
  local payload="$1" pc="$2" vm="$3" username="$4" password="$5" insecure="$6" policy="$7"
  local inventory_raw vm_uuid after_state normalized transition ok_json=false

  if ! n2k_run_shutdown_payload_is_empty "${payload}"; then
    printf '%s' "${payload}"
    return 0
  fi

  transition="$(n2k_source_vm_power_transition_for_policy "${policy}" 2>/dev/null || true)"
  if inventory_raw="$(n2k_nutanix_fetch_vm_inventory "${pc}" "${vm}" "${username}" "${password}" "${insecure}" 2>/dev/null)"; then
    vm_uuid="$(n2k_source_vm_uuid_from_inventory_raw "${inventory_raw}")"
    after_state="$(n2k_source_vm_power_state_from_inventory_raw "${inventory_raw}")"
    normalized="$(n2k_source_power_state_normalize "${after_state}")"
    if n2k_source_power_state_is_off "${after_state}"; then
      ok_json=true
    fi
    jq -nc \
      --arg policy "${policy}" \
      --arg transition "${transition}" \
      --arg vm_uuid "${vm_uuid}" \
      --arg after_state "${after_state}" \
      --arg normalized_after_state "${normalized}" \
      --argjson ok "${ok_json}" \
      '{ok:$ok,payload_reconstructed:true,reconstruct_reason:"shutdown_result_empty",policy:$policy,transition:$transition,vm_uuid:$vm_uuid,before_state:"",after_state:$after_state,normalized_after_state:$normalized_after_state,response:{}}'
    return 0
  fi

  jq -nc \
    --arg policy "${policy}" \
    --arg transition "${transition}" \
    '{ok:false,payload_reconstructed:true,reconstruct_reason:"shutdown_result_empty_inventory_fetch_failed",policy:$policy,transition:$transition,vm_uuid:"",before_state:"",after_state:"",normalized_after_state:"unknown",response:{}}'
}

n2k_run_shutdown_payload_ok() {
  local payload="${1:-}"
  [[ "$(printf '%s' "${payload}" | jq -r '.ok // false' 2>/dev/null || printf false)" == "true" ]]
}

n2k_run_cleanup_source_recovery_points() {
  local manifest="$1" pc="$2" username="$3" password="$4" insecure="$5"
  local points point_count cleanup_rc=0
  local kind recovery_point_id name response payload rc

  points="$(jq -r '
    [
      (.runtime.recovery_point_history // []),
      ((.runtime.recovery_points // {}) | to_entries | map(.value + {kind:.key}))
    ]
    | add
    | map(select(
        ((.id // "") | length) > 0
        and (.source_api // "") == "v3"
        and (((.cleanup.ok // false) | not))
      ))
    | unique_by(.id)
    | sort_by(if .kind == "final" then 0 elif .kind == "incr" then 1 elif .kind == "base" then 2 else 9 end)
    | .[]
    | [.kind, .id, (.name // "")] | @tsv
  ' "${manifest}")"
  point_count="$(printf '%s\n' "${points}" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

  if [[ "${point_count}" -eq 0 ]]; then
    n2k_event INFO "run" "" "source_points_cleanup_skipped" '{"reason":"no pending v3 source recovery points"}'
    return 0
  fi

  [[ -n "${username}" && -n "${password}" ]] || {
    n2k_event ERROR "run" "" "source_points_cleanup_failed" \
      "$(jq -nc --argjson count "${point_count}" '{reason:"credentials are required to cleanup source recovery points",count:$count}')"
    return 2
  }

  n2k_event INFO "run" "" "source_points_cleanup_start" \
    "$(jq -nc --argjson count "${point_count}" --arg source_endpoint "${pc}" '{count:$count,source_endpoint:$source_endpoint}')"

  while IFS=$'\t' read -r kind recovery_point_id name; do
    [[ -n "${recovery_point_id}" ]] || continue
    rc=0
    response="$(n2k_source_v3_delete_vm_snapshot "${pc}" "${username}" "${password}" "${insecure}" "${recovery_point_id}")" || rc=$?
    payload="$(n2k_source_compact_json_value "${response:-{}}")"
    if [[ "${rc}" -ne 0 ]]; then
      n2k_manifest_record_recovery_point_cleanup "${manifest}" "${kind}" "${recovery_point_id}" "delete-v3-vm-snapshot" false "${payload}" || true
      n2k_event ERROR "run" "" "source_point_cleanup_failed" \
        "$(jq -nc --arg kind "${kind}" --arg id "${recovery_point_id}" --arg name "${name}" --argjson response "${payload}" '{kind:$kind,id:$id,name:$name,response:$response}')"
      cleanup_rc="${rc}"
      continue
    fi
    n2k_manifest_record_recovery_point_cleanup "${manifest}" "${kind}" "${recovery_point_id}" "delete-v3-vm-snapshot" true "${payload}"
    n2k_event INFO "run" "" "source_point_cleaned" \
      "$(jq -nc --arg kind "${kind}" --arg id "${recovery_point_id}" --arg name "${name}" --argjson response "${payload}" '{kind:$kind,id:$id,name:$name,response:$response}')"
  done <<< "${points}"

  if [[ "${cleanup_rc}" -ne 0 ]]; then
    return "${cleanup_rc}"
  fi
  n2k_event INFO "run" "" "source_points_cleanup_done" \
    "$(jq -nc --argjson count "${point_count}" '{count:$count}')"
}

n2k_cmd_preflight() {
  local result
  result="$(n2k_build_preflight_result_from_args 0 "$@")"
  n2k_event INFO "preflight" "" "capability_evaluated" "${result}"
  n2k_maybe_record_preflight_result "${result}"
  n2k_maybe_record_phase_done "preflight"

  if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
    printf '%s\n' "${result}"
  else
    printf '%s\n' "${result}" | n2k_preflight_text_summary
  fi
}

n2k_cmd_plan() {
  local preflight plan
  preflight="$(n2k_build_preflight_result_from_args 1 "$@")"
  plan="$(n2k_plan_result_json "${preflight}")"
  n2k_event INFO "plan" "" "plan_created" "${plan}"
  n2k_maybe_record_preflight_result "${preflight}"
  n2k_maybe_record_phase_done "plan"

  if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
    printf '%s\n' "${plan}"
  else
    printf '%s\n' "${plan}" | n2k_plan_text_summary
  fi
}

n2k_run_resolved_v3_source_endpoint_from_manifest() {
  local manifest="$1" fallback="${2:-}"

  if [[ -z "${manifest}" || ! -f "${manifest}" ]]; then
    printf '%s\n' "${fallback}"
    return 0
  fi

  jq -r --arg fallback "${fallback}" '
    [
      .source.api.namespaces.v3.source_endpoint?,
      .runtime.preflight.api.v3.source_endpoint?,
      .runtime.preflight.modes["v3-incremental"].source_endpoint?,
      .runtime.preflight.modes.v3.source_endpoint?
    ]
    | map(select(type == "string" and length > 0))
    | .[0] // $fallback
  ' "${manifest}"
}

n2k_default_retention_seconds() {
  printf '%s\n' "${N2K_DEFAULT_RETENTION_SECONDS:-1209600}"
}

n2k_run_warn_recovery_point_expiration() {
  local manifest="$1" kind="$2" context="${3:-run}" warn_before_seconds="${4:-${N2K_RECOVERY_POINT_EXPIRY_WARN_SECONDS:-3600}}"
  local expiry_msecs expiry_seconds now_seconds seconds_left point_id point_name
  [[ -f "${manifest}" ]] || return 0
  expiry_msecs="$(jq -r --arg kind "${kind}" '
    .runtime.recovery_points[$kind].metadata.v3.snapshot.status.expiration_time_msecs //
    .runtime.recovery_points[$kind].metadata.v3.snapshot.spec.expiration_time_msecs //
    .runtime.recovery_points[$kind].metadata.v4.recovery_point.expirationTime //
    empty
  ' "${manifest}")"
  [[ -n "${expiry_msecs}" && "${expiry_msecs}" != "null" ]] || return 0
  point_id="$(jq -r --arg kind "${kind}" '.runtime.recovery_points[$kind].id // ""' "${manifest}")"
  point_name="$(jq -r --arg kind "${kind}" '.runtime.recovery_points[$kind].name // ""' "${manifest}")"
  now_seconds="$(date +%s)"
  if [[ "${expiry_msecs}" =~ ^[0-9]+$ ]]; then
    expiry_seconds=$((expiry_msecs / 1000))
  else
    expiry_seconds="$(date -d "${expiry_msecs}" +%s 2>/dev/null || printf 0)"
  fi
  [[ "${expiry_seconds}" -gt 0 ]] || return 0
  seconds_left=$((expiry_seconds - now_seconds))
  if [[ "${seconds_left}" -le 0 ]]; then
    n2k_event WARN "${context}" "" "reference_recovery_point_expired" \
      "$(jq -nc --arg kind "${kind}" --arg id "${point_id}" --arg name "${point_name}" --argjson expired_by_seconds "$((-seconds_left))" --arg expires_at "$(date -d "@${expiry_seconds}" -Iseconds)" '{kind:$kind,id:$id,name:$name,expires_at:$expires_at,expired_by_seconds:$expired_by_seconds}')"
  elif [[ "${seconds_left}" -le "${warn_before_seconds}" ]]; then
    n2k_event WARN "${context}" "" "reference_recovery_point_expiring_soon" \
      "$(jq -nc --arg kind "${kind}" --arg id "${point_id}" --arg name "${point_name}" --argjson seconds_left "${seconds_left}" --arg expires_at "$(date -d "@${expiry_seconds}" -Iseconds)" '{kind:$kind,id:$id,name:$name,expires_at:$expires_at,seconds_left:$seconds_left}')"
  fi
}

n2k_run_self_executable() {
  local self="${N2K_SELF:-}"
  if [[ -z "${self}" ]]; then
    self="$(command -v ablestack_n2k 2>/dev/null || true)"
  fi
  if [[ -z "${self}" && -x "${N2K_ROOT_DIR:-}/bin/ablestack_n2k.sh" ]]; then
    self="${N2K_ROOT_DIR}/bin/ablestack_n2k.sh"
  fi
  [[ -n "${self}" ]] || n2k_die "Unable to resolve ablestack_n2k executable for background run"
  printf '%s\n' "${self}"
}

n2k_run_runner_state_file() {
  [[ -n "${N2K_WORKDIR:-}" ]] || n2k_die "background run requires a resolved workdir"
  printf '%s\n' "${N2K_WORKDIR%/}/runner.json"
}

n2k_run_write_runner_state() {
  local state="$1" pid="${2:-}" split="${3:-}" log_file="${4:-}" exit_code="${5:-}"
  local state_file
  state_file="$(n2k_run_runner_state_file)"
  mkdir -p "$(dirname "${state_file}")"
  jq -nc \
    --arg state "${state}" \
    --arg pid "${pid}" \
    --arg split "${split}" \
    --arg workdir "${N2K_WORKDIR:-}" \
    --arg manifest "${N2K_MANIFEST:-}" \
    --arg events_log "${N2K_EVENTS_LOG:-}" \
    --arg log_file "${log_file}" \
    --arg exit_code "${exit_code}" \
    --arg updated_at "$(date -Iseconds)" \
    '{
      state: $state,
      pid: (if $pid == "" then null else ($pid | tonumber) end),
      split: $split,
      workdir: $workdir,
      manifest: $manifest,
      events_log: $events_log,
      log_file: $log_file,
      exit_code: (if $exit_code == "" then null else ($exit_code | tonumber) end),
      updated_at: $updated_at
    }' > "${state_file}"
}

n2k_run_start_background() {
  local split="$1"
  shift
  [[ "${split}" == "phase1" || "${split}" == "phase2" ]] || n2k_die "--background supports --split phase1 or phase2"
  [[ -n "${N2K_WORKDIR:-}" ]] || n2k_die "--background requires a workdir"

  mkdir -p "${N2K_WORKDIR}"
  [[ -n "${N2K_MANIFEST:-}" ]] || N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
  [[ -n "${N2K_EVENTS_LOG:-}" ]] || N2K_EVENTS_LOG="${N2K_WORKDIR}/events.log"
  export N2K_MANIFEST N2K_EVENTS_LOG

  local self log_file
  self="$(n2k_run_self_executable)"
  log_file="${N2K_WORKDIR%/}/run-${split}.log"
  n2k_run_write_runner_state "starting" "" "${split}" "${log_file}" ""

  local -a worker_cmd=("${self}")
  [[ -n "${N2K_WORKDIR:-}" ]] && worker_cmd+=(--workdir "${N2K_WORKDIR}")
  [[ -n "${N2K_RUN_ID:-}" ]] && worker_cmd+=(--run-id "${N2K_RUN_ID}")
  [[ -n "${N2K_MANIFEST:-}" ]] && worker_cmd+=(--manifest "${N2K_MANIFEST}")
  [[ -n "${N2K_EVENTS_LOG:-}" ]] && worker_cmd+=(--log "${N2K_EVENTS_LOG}")
  [[ "${N2K_DRY_RUN:-0}" -eq 1 ]] && worker_cmd+=(--dry-run)
  [[ "${N2K_FORCE:-0}" -eq 1 ]] && worker_cmd+=(--force)
  worker_cmd+=(run --foreground "$@")

  (
    n2k_run_write_runner_state "running" "${BASHPID}" "${split}" "${log_file}" ""
    set +e
    "${worker_cmd[@]}"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      n2k_run_write_runner_state "done" "${BASHPID}" "${split}" "${log_file}" "${rc}"
    else
      n2k_run_write_runner_state "failed" "${BASHPID}" "${split}" "${log_file}" "${rc}"
    fi
    exit "${rc}"
  ) >> "${log_file}" 2>&1 < /dev/null &
  local pid=$!
  disown "${pid}" 2>/dev/null || true
  n2k_run_write_runner_state "running" "${pid}" "${split}" "${log_file}" ""
  sleep 0.2
  if ! kill -0 "${pid}" 2>/dev/null; then
    n2k_run_write_runner_state "failed" "${pid}" "${split}" "${log_file}" "1"
    n2k_die "background n2k worker failed to start; see ${log_file}"
  fi

  local payload
  payload="$(jq -nc --arg workdir "${N2K_WORKDIR}" --arg manifest "${N2K_MANIFEST}" --arg events_log "${N2K_EVENTS_LOG}" --arg log_file "${log_file}" --argjson pid "${pid}" --arg split "${split}" '{workdir:$workdir,manifest:$manifest,events_log:$events_log,log_file:$log_file,pid:$pid,split:$split}')"
  if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
    jq -nc --arg phase "run.background" --argjson payload "${payload}" '{ok:true,phase:$phase,payload:$payload}'
  else
    printf 'n2k background run started. PID: %s Workdir: %s Log: %s\n' "${pid}" "${N2K_WORKDIR}" "${log_file}"
  fi
}

n2k_cmd_run() {
  local -a foreground_run_args=()
  local arg
  for arg in "$@"; do
    [[ "${arg}" == "--background" ]] && continue
    foreground_run_args+=("${arg}")
  done

  if [[ "${N2K_RESUME:-0}" -eq 1 ]]; then
    if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
      N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
      export N2K_MANIFEST
    fi
    n2k_require_manifest
    local resume
    resume="$(n2k_manifest_resume_summary "${N2K_MANIFEST}")"
    n2k_event INFO "run" "" "resume_plan_created" "${resume}"
    if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
      jq -nc --arg phase "run.resume" --argjson payload "${resume}" '{ok:true,phase:$phase,payload:$payload}'
    else
      printf '%s\n' "${resume}" | jq -r '
        "Resume plan:\n" +
        "Next step: " + (.next_step // "") + "\n" +
        "Next command: " + (.next_command // "") + "\n" +
        "Can resume: " + ((.can_resume // false) | tostring) + "\n" +
        "Reason: " + (.reason // "")
      '
    fi
    return 0
  fi

  local vm="" pc="" dst="" mode="auto" cred_file=""
  local username="" password="" insecure="1" inventory_source="api"
  local target_format="qcow2" target_storage="file" target_map_json="" rbd_access_mode="librbd"
  local rbd_access_mode_arg_set=0
  local target_provider="libvirt" target_provider_arg_set=0
  local cloud_endpoint="" cloud_api_key="" cloud_secret_key="" cloud_cred_file=""
  local cloud_zone_id="" cloud_service_offering_id="" cloud_network_ids="" cloud_storage_id=""
  local cloud_disk_offering_id="" cloud_host_id="" cloud_account="" cloud_domain_id="" cloud_project_id=""
  local cloud_name="" cloud_display_name="" cloud_cpu_speed="" cloud_config_arg_set=0
  local split="${N2K_RUN_DEFAULT_SPLIT:-full}" source_api="v3"
  local nfs_host="" nfs_mount_root="" source_map_from_v3_nfs=true source_endpoint=""
  local source_api_arg_set=0 force_v3=false
  local deadline_sec="${N2K_RUN_DEFAULT_DEADLINE_SEC:-120}"
  local max_incr_phase2="${N2K_RUN_DEFAULT_MAX_INCR_PHASE2:-20}"
  local max_final_bytes="${N2K_RUN_DEFAULT_MAX_FINAL_BYTES:--1}"
  local wait_seconds="180" retention_seconds
  retention_seconds="$(n2k_default_retention_seconds)"
  local snapshot_type="CRASH_CONSISTENT"
  local shutdown="manual" cutover_policy="define-only" cutover_args_str=""
  local shutdown_timeout_sec="${N2K_RUN_DEFAULT_SHUTDOWN_TIMEOUT_SEC:-300}"
  local shutdown_poll_sec="${N2K_RUN_DEFAULT_SHUTDOWN_POLL_SEC:-5}"
  local skip_plan=0 allow_experimental=false probe_legacy=false
  local libvirt_network_mode="" libvirt_bridge="" libvirt_network=""
  local cleanup_source_points=true
  local execution_mode="foreground"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vm) vm="${2:-}"; shift 2 ;;
      --pc) pc="${2:-}"; shift 2 ;;
      --dst) dst="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --cred-file) cred_file="${2:-}"; shift 2 ;;
      --username) username="${2:-}"; shift 2 ;;
      --password) password="${2:-}"; shift 2 ;;
      --insecure) insecure="${2:-}"; shift 2 ;;
      --inventory-source) inventory_source="${2:-}"; shift 2 ;;
      --target-format) target_format="${2:-}"; shift 2 ;;
      --target-storage) target_storage="${2:-}"; shift 2 ;;
      --target-map-json) target_map_json="${2:-}"; shift 2 ;;
      --rbd-access-mode) rbd_access_mode="${2:-}"; rbd_access_mode_arg_set=1; shift 2 ;;
      --target-provider) target_provider="${2:-}"; target_provider_arg_set=1; shift 2 ;;
      --cloud-endpoint) cloud_endpoint="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-api-key) cloud_api_key="${2:-}"; shift 2 ;;
      --cloud-secret-key) cloud_secret_key="${2:-}"; shift 2 ;;
      --cloud-cred-file) cloud_cred_file="${2:-}"; shift 2 ;;
      --cloud-zone-id) cloud_zone_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-service-offering-id) cloud_service_offering_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-network-id)
        cloud_network_ids="${cloud_network_ids:+${cloud_network_ids},}${2:-}"
        cloud_config_arg_set=1
        shift 2
        ;;
      --cloud-network-ids) cloud_network_ids="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-storage-id) cloud_storage_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-disk-offering-id) cloud_disk_offering_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-host-id) cloud_host_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-account) cloud_account="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-domain-id) cloud_domain_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-project-id) cloud_project_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-name) cloud_name="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-display-name) cloud_display_name="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-cpu-speed) cloud_cpu_speed="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --split) split="${2:-}"; shift 2 ;;
      --source-api) source_api="${2:-}"; source_api_arg_set=1; shift 2 ;;
      --force-v3|--force-v3-incremental) force_v3=true; shift 1 ;;
      --source-map-from-v3-nfs) source_map_from_v3_nfs=true; shift 1 ;;
      --no-source-map-from-v3-nfs) source_map_from_v3_nfs=false; shift 1 ;;
      --nfs-host) nfs_host="${2:-}"; shift 2 ;;
      --nfs-mount-root) nfs_mount_root="${2:-}"; shift 2 ;;
      --deadline-sec) deadline_sec="${2:-}"; shift 2 ;;
      --max-incr-phase2) max_incr_phase2="${2:-}"; shift 2 ;;
      --max-final-bytes) max_final_bytes="${2:-}"; shift 2 ;;
      --wait-seconds) wait_seconds="${2:-}"; shift 2 ;;
      --retention-seconds) retention_seconds="${2:-}"; shift 2 ;;
      --snapshot-type) snapshot_type="${2:-}"; shift 2 ;;
      --shutdown) shutdown="${2:-}"; shift 2 ;;
      --shutdown-timeout-sec) shutdown_timeout_sec="${2:-}"; shift 2 ;;
      --shutdown-poll-sec) shutdown_poll_sec="${2:-}"; shift 2 ;;
      --cutover-args) cutover_args_str="${2:-}"; shift 2 ;;
      --network-mode|--libvirt-network-mode) libvirt_network_mode="${2:-}"; shift 2 ;;
      --bridge|--libvirt-bridge) libvirt_bridge="${2:-}"; shift 2 ;;
      --network|--libvirt-network) libvirt_network="${2:-}"; shift 2 ;;
      --cleanup-source-points) cleanup_source_points=true; shift 1 ;;
      --keep-source-points) cleanup_source_points=false; shift 1 ;;
      --foreground) execution_mode="foreground"; shift 1 ;;
      --background) execution_mode="background"; shift 1 ;;
      --define-only) cutover_policy="define-only"; shift 1 ;;
      --apply) cutover_policy="apply"; shift 1 ;;
      --start) cutover_policy="start"; shift 1 ;;
      --skip-plan) skip_plan=1; shift 1 ;;
      --allow-experimental) allow_experimental=true; shift 1 ;;
      --probe-legacy-cbt) probe_legacy=true; shift 1 ;;
      *) n2k_die "Unknown option for run: $1" ;;
    esac
  done

  case "${split}" in
    full|phase1|phase2) ;;
    *) n2k_die "Invalid --split: ${split}" ;;
  esac
  case "${source_api}" in
    v3) ;;
    *) n2k_die "run orchestration currently supports --source-api v3 only" ;;
  esac
  if [[ "${source_api_arg_set}" -eq 1 && "${source_api}" == "v3" ]]; then
    force_v3=true
  fi
  case "${inventory_source}" in
    none|fixture|api) ;;
    *) n2k_die "Invalid --inventory-source: ${inventory_source}" ;;
  esac
  case "${insecure}" in
    0|1) ;;
    *) n2k_die "Invalid --insecure: ${insecure}" ;;
  esac
  case "${shutdown}" in
    none|manual|guest|poweroff) ;;
    *) n2k_die "Invalid --shutdown: ${shutdown}" ;;
  esac
  if [[ -n "${libvirt_network_mode}" ]]; then
    case "${libvirt_network_mode}" in
      bridge|network) ;;
      *) n2k_die "Invalid --network-mode: ${libvirt_network_mode}" ;;
    esac
  fi
  [[ "${deadline_sec}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --deadline-sec: ${deadline_sec}"
  [[ "${max_incr_phase2}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --max-incr-phase2: ${max_incr_phase2}"
  [[ "${max_final_bytes}" =~ ^-?[0-9]+$ ]] || n2k_die "Invalid --max-final-bytes: ${max_final_bytes}"
  [[ "${wait_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --wait-seconds: ${wait_seconds}"
  [[ "${retention_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --retention-seconds: ${retention_seconds}"
  [[ "${shutdown_timeout_sec}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --shutdown-timeout-sec: ${shutdown_timeout_sec}"
  [[ "${shutdown_poll_sec}" =~ ^[0-9]+$ && "${shutdown_poll_sec}" -gt 0 ]] || n2k_die "Invalid --shutdown-poll-sec: ${shutdown_poll_sec}"
  n2k_valid_mode "${mode}" || n2k_die "Invalid --mode: ${mode}"
  if [[ "${force_v3}" == "true" ]]; then
    [[ "${mode}" == "auto" || "${mode}" == "v3-incremental" ]] || \
      n2k_die "--force-v3/--source-api v3 conflicts with --mode ${mode}"
    mode="v3-incremental"
  fi
  if [[ "${target_storage}" == "qcow2" ]]; then
    target_storage="file"
    target_format="qcow2"
  fi
  n2k_valid_target_format "${target_format}" || n2k_die "Invalid --target-format: ${target_format}"
  n2k_valid_target_storage "${target_storage}" || n2k_die "Invalid --target-storage: ${target_storage}"
  n2k_valid_target_provider "${target_provider}" || n2k_die "Invalid --target-provider: ${target_provider}"
  n2k_valid_rbd_access_mode "${rbd_access_mode}" || n2k_die "Invalid --rbd-access-mode: ${rbd_access_mode}"
  [[ "${source_map_from_v3_nfs}" == "true" ]] || n2k_die "run --source-api v3 requires --source-map-from-v3-nfs"

  if [[ -n "${cred_file}" ]]; then
    n2k_nutanix_load_cred_file "${cred_file}"
    username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
    password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"
  fi
  username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
  password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"

  local -a credential_args=(--insecure "${insecure}")
  [[ -n "${cred_file}" ]] && credential_args+=(--cred-file "${cred_file}")
  [[ -n "${username}" ]] && credential_args+=(--username "${username}")
  [[ -n "${password}" ]] && credential_args+=(--password "${password}")

  n2k_run_set_manifest_paths_from_workdir

  if [[ "${execution_mode}" == "background" ]]; then
    if [[ "${split}" == "phase2" ]]; then
      n2k_require_manifest
      n2k_manifest_split_is_done "${N2K_MANIFEST}" "phase1" || \
        n2k_die "run --split phase2 requires a completed phase1 marker in the manifest"
    else
      [[ -n "${vm}" ]] || n2k_die "run --background --split ${split} requires --vm"
      [[ -n "${pc}" ]] || n2k_die "run --background --split ${split} requires --pc"
    fi
    n2k_run_start_background "${split}" "${foreground_run_args[@]}"
    return 0
  fi

  if [[ "${split}" == "phase2" ]]; then
    n2k_require_manifest
    n2k_manifest_split_is_done "${N2K_MANIFEST}" "phase1" || \
      n2k_die "run --split phase2 requires a completed phase1 marker in the manifest"
  elif [[ -z "${N2K_MANIFEST:-}" || ! -f "${N2K_MANIFEST}" ]]; then
    [[ -n "${vm}" ]] || n2k_die "run --split ${split} requires --vm when no manifest exists"
    [[ -n "${pc}" ]] || n2k_die "run --split ${split} requires --pc when no manifest exists"
    local -a init_args=(--vm "${vm}" --pc "${pc}" --mode "${mode}" --inventory-source "${inventory_source}" --target-format "${target_format}" --target-storage "${target_storage}" --rbd-access-mode "${rbd_access_mode}")
    [[ "${target_provider_arg_set}" -eq 1 ]] && init_args+=(--target-provider "${target_provider}")
    [[ -n "${dst}" ]] && init_args+=(--dst "${dst}")
    [[ -n "${target_map_json}" ]] && init_args+=(--target-map-json "${target_map_json}")
    [[ -n "${cloud_endpoint}" ]] && init_args+=(--cloud-endpoint "${cloud_endpoint}")
    [[ -n "${cloud_api_key}" ]] && init_args+=(--cloud-api-key "${cloud_api_key}")
    [[ -n "${cloud_secret_key}" ]] && init_args+=(--cloud-secret-key "${cloud_secret_key}")
    [[ -n "${cloud_cred_file}" ]] && init_args+=(--cloud-cred-file "${cloud_cred_file}")
    [[ -n "${cloud_zone_id}" ]] && init_args+=(--cloud-zone-id "${cloud_zone_id}")
    [[ -n "${cloud_service_offering_id}" ]] && init_args+=(--cloud-service-offering-id "${cloud_service_offering_id}")
    [[ -n "${cloud_network_ids}" ]] && init_args+=(--cloud-network-ids "${cloud_network_ids}")
    [[ -n "${cloud_storage_id}" ]] && init_args+=(--cloud-storage-id "${cloud_storage_id}")
    [[ -n "${cloud_disk_offering_id}" ]] && init_args+=(--cloud-disk-offering-id "${cloud_disk_offering_id}")
    [[ -n "${cloud_host_id}" ]] && init_args+=(--cloud-host-id "${cloud_host_id}")
    [[ -n "${cloud_account}" ]] && init_args+=(--cloud-account "${cloud_account}")
    [[ -n "${cloud_domain_id}" ]] && init_args+=(--cloud-domain-id "${cloud_domain_id}")
    [[ -n "${cloud_project_id}" ]] && init_args+=(--cloud-project-id "${cloud_project_id}")
    [[ -n "${cloud_name}" ]] && init_args+=(--cloud-name "${cloud_name}")
    [[ -n "${cloud_display_name}" ]] && init_args+=(--cloud-display-name "${cloud_display_name}")
    [[ -n "${cloud_cpu_speed}" ]] && init_args+=(--cloud-cpu-speed "${cloud_cpu_speed}")
    init_args+=("${credential_args[@]}")
    n2k_cmd_init "${init_args[@]}"
  else
    n2k_require_manifest
  fi

  if [[ "${target_provider_arg_set}" -eq 1 || "${cloud_config_arg_set}" -eq 1 ]]; then
    local cloud_config_json
    cloud_config_json="$(n2k_cloud_target_config_json "${cloud_endpoint}" "${cloud_zone_id}" "${cloud_service_offering_id}" "${cloud_network_ids}" "${cloud_storage_id}" "${cloud_disk_offering_id}" "${cloud_host_id}" "${cloud_account}" "${cloud_domain_id}" "${cloud_project_id}" "${cloud_name}" "${cloud_display_name}" "${cloud_cpu_speed}")"
    n2k_cloud_target_apply_manifest_config "${N2K_MANIFEST}" "$(if [[ "${target_provider_arg_set}" -eq 1 ]]; then printf '%s' "${target_provider}"; else printf ''; fi)" "${cloud_config_json}"
  fi
  target_provider="$(jq -r '.target.provider // "libvirt"' "${N2K_MANIFEST}")"
  if [[ "${target_provider}" == "ablestack-cloud" && "$(jq -r '.target.storage.type // ""' "${N2K_MANIFEST}")" == "file" ]]; then
    n2k_cloud_target_resolve_file_storage_for_manifest "${N2K_MANIFEST}" "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" "${cloud_cred_file}" >/dev/null
  fi

  vm="${vm:-$(n2k_run_manifest_value "${N2K_MANIFEST}" '.source.vm.name // empty')}"
  pc="${pc:-$(n2k_run_manifest_value "${N2K_MANIFEST}" '.source.pc // empty')}"
  [[ -n "${vm}" ]] || n2k_die "run could not resolve VM name from args or manifest"
  [[ -n "${pc}" ]] || n2k_die "run could not resolve Prism endpoint from args or manifest"
  source_endpoint="${pc}"
  if [[ "${source_api}" == "v3" ]]; then
    source_endpoint="$(n2k_run_resolved_v3_source_endpoint_from_manifest "${N2K_MANIFEST}" "${pc}")"
  fi
  if [[ "${source_api}" == "v3" && -n "${username}" && -n "${password}" ]]; then
    local v3_source_probe v3_source_endpoint
    v3_source_probe="$(n2k_source_probe_v3_source_endpoint "${pc}" "${username}" "${password}" "${insecure}" "${vm}")"
    v3_source_endpoint="$(jq -r 'if (.vm_snapshots // false) and (.changed_regions // false) then (.source_endpoint // "") else "" end' <<<"${v3_source_probe}")"
    if [[ -n "${v3_source_endpoint}" ]]; then
      source_endpoint="${v3_source_endpoint}"
      n2k_event INFO "run" "" "v3_source_endpoint_selected" \
        "$(jq -nc --arg pc "${pc}" --arg source_endpoint "${source_endpoint}" --argjson probe "${v3_source_probe}" '{pc:$pc,source_endpoint:$source_endpoint,probe:$probe}')"
    fi
  fi
  if [[ -z "${nfs_host}" ]]; then
    nfs_host="${source_endpoint}"
  fi

  if [[ -n "${nfs_mount_root}" ]]; then
    export N2K_NUTANIX_NFS_MOUNT_ROOT="${nfs_mount_root}"
  fi

  if [[ "${split}" != "phase2" && "${skip_plan}" -eq 0 ]] && ! n2k_run_manifest_phase_done "${N2K_MANIFEST}" "plan"; then
    local -a plan_args=(--vm "${vm}" --pc "${pc}" --mode "${mode}" --target-format "${target_format}" --target-storage "${target_storage}" --rbd-access-mode "${rbd_access_mode}")
    plan_args+=("${credential_args[@]}")
    plan_args+=(--target-provider "${target_provider}")
    [[ -n "${cloud_endpoint}" ]] && plan_args+=(--cloud-endpoint "${cloud_endpoint}")
    [[ -n "${cloud_api_key}" ]] && plan_args+=(--cloud-api-key "${cloud_api_key}")
    [[ -n "${cloud_secret_key}" ]] && plan_args+=(--cloud-secret-key "${cloud_secret_key}")
    [[ -n "${cloud_cred_file}" ]] && plan_args+=(--cloud-cred-file "${cloud_cred_file}")
    [[ -n "${cloud_zone_id}" ]] && plan_args+=(--cloud-zone-id "${cloud_zone_id}")
    [[ -n "${cloud_service_offering_id}" ]] && plan_args+=(--cloud-service-offering-id "${cloud_service_offering_id}")
    [[ -n "${cloud_network_ids}" ]] && plan_args+=(--cloud-network-ids "${cloud_network_ids}")
    [[ -n "${cloud_storage_id}" ]] && plan_args+=(--cloud-storage-id "${cloud_storage_id}")
    [[ -n "${cloud_disk_offering_id}" ]] && plan_args+=(--cloud-disk-offering-id "${cloud_disk_offering_id}")
    [[ -n "${cloud_host_id}" ]] && plan_args+=(--cloud-host-id "${cloud_host_id}")
    [[ -n "${cloud_account}" ]] && plan_args+=(--cloud-account "${cloud_account}")
    [[ -n "${cloud_domain_id}" ]] && plan_args+=(--cloud-domain-id "${cloud_domain_id}")
    [[ -n "${cloud_project_id}" ]] && plan_args+=(--cloud-project-id "${cloud_project_id}")
    [[ -n "${cloud_name}" ]] && plan_args+=(--cloud-name "${cloud_name}")
    [[ -n "${cloud_display_name}" ]] && plan_args+=(--cloud-display-name "${cloud_display_name}")
    [[ -n "${cloud_cpu_speed}" ]] && plan_args+=(--cloud-cpu-speed "${cloud_cpu_speed}")
    [[ "${force_v3}" == "true" ]] && plan_args+=(--force-v3)
    [[ "${allow_experimental}" == "true" ]] && plan_args+=(--allow-experimental)
    [[ "${probe_legacy}" == "true" ]] && plan_args+=(--probe-legacy-cbt)
    n2k_cmd_plan "${plan_args[@]}"
  fi

  local -a snapshot_common=(--source-api "${source_api}" --create-vm-snapshot --pc "${source_endpoint}" --vm "${vm}" --wait-seconds "${wait_seconds}" --retention-seconds "${retention_seconds}" --snapshot-type "${snapshot_type}")
  snapshot_common+=("${credential_args[@]}")
  local -a sync_common=(--source-map-from-v3-nfs --nfs-host "${nfs_host}")
  [[ -n "${nfs_mount_root}" ]] && sync_common+=(--nfs-mount-root "${nfs_mount_root}")
  sync_common+=("${credential_args[@]}")

  if [[ "${split}" == "phase1" || "${split}" == "full" ]]; then
    if ! n2k_run_manifest_has_recovery_point "${N2K_MANIFEST}" "base"; then
      n2k_event INFO "run" "" "step" '{"step":"snapshot-base"}'
      n2k_cmd_snapshot base "${snapshot_common[@]}"
    fi
    if ! n2k_run_manifest_phase_done "${N2K_MANIFEST}" "base_sync"; then
      n2k_event INFO "run" "" "step" '{"step":"sync-base"}'
      n2k_cmd_sync base "${sync_common[@]}"
    fi
    if ! n2k_run_manifest_has_recovery_point "${N2K_MANIFEST}" "incr"; then
      n2k_event INFO "run" "" "step" '{"step":"snapshot-incr-phase1"}'
      n2k_cmd_snapshot incr "${snapshot_common[@]}" --collect-changed-regions --reference-kind base
    fi
    if ! n2k_run_manifest_phase_done "${N2K_MANIFEST}" "incr_sync"; then
      n2k_event INFO "run" "" "step" '{"step":"sync-incr-phase1"}'
      n2k_cmd_sync incr "${sync_common[@]}"
    fi
    if [[ "${split}" == "phase1" ]]; then
      n2k_manifest_record_split_iteration "${N2K_MANIFEST}" "phase1" 1 0 \
        "$(jq -r '.runtime.sync.last_changed_bytes // 0' "${N2K_MANIFEST}")" \
        "$(jq -r '.runtime.sync.last_region_count // 0' "${N2K_MANIFEST}")" true
      n2k_manifest_mark_split_done "${N2K_MANIFEST}" "phase1"
      n2k_event INFO "run" "" "phase" '{"which":"phase1","action":"exit"}'
      n2k_run_text_or_json "${split}" "phase1_done" "n2k split phase1 completed. Re-run with --split phase2 to continue."
      return 0
    fi
  fi

  if [[ "${split}" == "phase2" ]]; then
    n2k_run_manifest_has_recovery_point "${N2K_MANIFEST}" "incr" || \
      n2k_die "run --split phase2 requires an incremental recovery point from phase1"
    n2k_run_warn_recovery_point_expiration "${N2K_MANIFEST}" "incr" "run.phase2"
  fi

  local ready=1 iter=0 elapsed_sec=0 changed_bytes=0 changed_regions=0 start_ts end_ts
  if [[ "${split}" == "phase2" ]] && ! n2k_run_manifest_phase_done "${N2K_MANIFEST}" "final_sync"; then
    ready=0
    while [[ "${iter}" -lt "${max_incr_phase2}" ]]; do
      iter=$((iter + 1))
      start_ts="$(date +%s)"
      n2k_event INFO "run" "" "phase2_incremental_start" \
        "$(jq -nc --argjson iter "${iter}" '{iter:$iter}')"
      n2k_cmd_snapshot incr "${snapshot_common[@]}" --collect-changed-regions --reference-kind incr
      n2k_cmd_sync incr "${sync_common[@]}"
      end_ts="$(date +%s)"
      elapsed_sec=$((end_ts - start_ts))
      changed_bytes="$(jq -r '.runtime.sync.last_changed_bytes // 0' "${N2K_MANIFEST}")"
      changed_regions="$(jq -r '.runtime.sync.last_region_count // 0' "${N2K_MANIFEST}")"
      ready=0
      if [[ "${elapsed_sec}" -le "${deadline_sec}" ]]; then
        ready=1
      fi
      if [[ "${max_final_bytes}" -ge 0 && "${changed_bytes}" -gt "${max_final_bytes}" ]]; then
        ready=0
      fi
      n2k_manifest_record_split_iteration "${N2K_MANIFEST}" "phase2" "${iter}" "${elapsed_sec}" "${changed_bytes}" "${changed_regions}" "${ready}"
      n2k_event INFO "run" "" "phase2_incremental_done" \
        "$(jq -nc --argjson iter "${iter}" --argjson elapsed_sec "${elapsed_sec}" --argjson changed_bytes "${changed_bytes}" --argjson changed_regions "${changed_regions}" --argjson ready "${ready}" '{iter:$iter,elapsed_sec:$elapsed_sec,changed_bytes:$changed_bytes,changed_regions:$changed_regions,ready_for_cutover:$ready}')"
      [[ "${ready}" -eq 1 ]] && break
    done

    if [[ "${ready}" -ne 1 ]]; then
      n2k_event WARN "run" "" "phase2_deadline_not_met" \
        "$(jq -nc --argjson max_incr_phase2 "${max_incr_phase2}" --argjson deadline_sec "${deadline_sec}" '{max_incr_phase2:$max_incr_phase2,deadline_sec:$deadline_sec}')"
      n2k_run_text_or_json "${split}" "deadline_not_met" "n2k split phase2 stopped before cutover because the deadline was not met. Re-run phase2 after the next incremental window."
      return 0
    fi
  fi

  if ! n2k_run_manifest_phase_done "${N2K_MANIFEST}" "final_sync"; then
    case "${shutdown}" in
      none)
        n2k_event WARN "run" "" "shutdown_skipped" '{"policy":"none"}'
        ;;
      manual)
        n2k_event INFO "run" "" "shutdown_boundary" '{"policy":"manual","note":"operator must stop or quiesce the source VM before final sync"}'
        ;;
      guest|poweroff)
        local shutdown_result shutdown_payload shutdown_rc shutdown_transition shutdown_before shutdown_after
        shutdown_rc=0
        n2k_event INFO "run" "" "shutdown_source_start" \
          "$(jq -nc --arg policy "${shutdown}" --arg pc "${pc}" --arg source_endpoint "${source_endpoint}" --argjson timeout_sec "${shutdown_timeout_sec}" '{policy:$policy,pc:$pc,source_endpoint:$source_endpoint,timeout_sec:$timeout_sec}')"
        if [[ "${source_api}" == "v3" ]]; then
          shutdown_result="$(N2K_NUTANIX_INVENTORY_SKIP_V4=1 n2k_source_vm_shutdown "${source_endpoint}" "${vm}" "${username}" "${password}" "${insecure}" "${shutdown}" "${shutdown_timeout_sec}" "${shutdown_poll_sec}")" || shutdown_rc=$?
        else
          shutdown_result="$(n2k_source_vm_shutdown "${source_endpoint}" "${vm}" "${username}" "${password}" "${insecure}" "${shutdown}" "${shutdown_timeout_sec}" "${shutdown_poll_sec}")" || shutdown_rc=$?
        fi
        shutdown_payload="$(n2k_source_compact_json_value "${shutdown_result:-{}}")"
        if [[ "${shutdown_rc}" -eq 0 ]]; then
          shutdown_payload="$(n2k_run_reconstruct_empty_shutdown_payload "${shutdown_payload}" "${source_endpoint}" "${vm}" "${username}" "${password}" "${insecure}" "${shutdown}")"
          if ! n2k_run_shutdown_payload_ok "${shutdown_payload}"; then
            shutdown_rc=4
          fi
        fi
        shutdown_payload="$(printf '%s' "${shutdown_payload}" | jq -c --arg pc "${pc}" --arg source_endpoint "${source_endpoint}" '. + {pc:$pc,source_endpoint:$source_endpoint,source_endpoint_selected:($pc != $source_endpoint)}')"
        shutdown_transition="$(printf '%s' "${shutdown_payload}" | jq -r '.transition // ""' 2>/dev/null || true)"
        shutdown_before="$(printf '%s' "${shutdown_payload}" | jq -r '.before_state // ""' 2>/dev/null || true)"
        shutdown_after="$(printf '%s' "${shutdown_payload}" | jq -r '.after_state // ""' 2>/dev/null || true)"
        if [[ "${shutdown_rc}" -ne 0 ]]; then
          n2k_manifest_record_source_shutdown "${N2K_MANIFEST}" "${shutdown}" "${shutdown_transition}" "${shutdown_before}" "${shutdown_after}" false "${shutdown_payload}" || true
          n2k_event ERROR "run" "" "shutdown_source_failed" "${shutdown_payload}"
          n2k_die "source VM shutdown failed before final snapshot; policy=${shutdown}"
        fi
        n2k_manifest_record_source_shutdown "${N2K_MANIFEST}" "${shutdown}" "${shutdown_transition}" "${shutdown_before}" "${shutdown_after}" true "${shutdown_payload}" || true
        n2k_event INFO "run" "" "shutdown_source_done" "${shutdown_payload}"
        ;;
    esac
    n2k_event INFO "run" "" "step" '{"step":"snapshot-final"}'
    n2k_cmd_snapshot final "${snapshot_common[@]}" --collect-changed-regions --reference-kind incr
    n2k_event INFO "run" "" "step" '{"step":"sync-final"}'
    n2k_cmd_sync final "${sync_common[@]}"
  fi

  local -a cutover_args=()
  if [[ -n "${cutover_args_str}" ]]; then
    read -r -a cutover_args <<< "${cutover_args_str}"
  else
    case "${cutover_policy}" in
      define-only) cutover_args=(--define-only) ;;
      apply) cutover_args=(--apply) ;;
      start) cutover_args=(--apply --start) ;;
      *) n2k_die "Invalid cutover policy: ${cutover_policy}" ;;
    esac
  fi
  if [[ "${rbd_access_mode_arg_set}" -eq 1 ]]; then
    cutover_args+=(--rbd-access-mode "${rbd_access_mode}")
  fi
  [[ -n "${libvirt_network_mode}" ]] && cutover_args+=(--network-mode "${libvirt_network_mode}")
  [[ -n "${libvirt_bridge}" ]] && cutover_args+=(--bridge "${libvirt_bridge}")
  [[ -n "${libvirt_network}" ]] && cutover_args+=(--network "${libvirt_network}")
  cutover_args+=(--target-provider "${target_provider}")
  [[ -n "${cloud_endpoint}" ]] && cutover_args+=(--cloud-endpoint "${cloud_endpoint}")
  [[ -n "${cloud_api_key}" ]] && cutover_args+=(--cloud-api-key "${cloud_api_key}")
  [[ -n "${cloud_secret_key}" ]] && cutover_args+=(--cloud-secret-key "${cloud_secret_key}")
  [[ -n "${cloud_cred_file}" ]] && cutover_args+=(--cloud-cred-file "${cloud_cred_file}")
  [[ -n "${cloud_zone_id}" ]] && cutover_args+=(--cloud-zone-id "${cloud_zone_id}")
  [[ -n "${cloud_service_offering_id}" ]] && cutover_args+=(--cloud-service-offering-id "${cloud_service_offering_id}")
  [[ -n "${cloud_network_ids}" ]] && cutover_args+=(--cloud-network-ids "${cloud_network_ids}")
  [[ -n "${cloud_storage_id}" ]] && cutover_args+=(--cloud-storage-id "${cloud_storage_id}")
  [[ -n "${cloud_disk_offering_id}" ]] && cutover_args+=(--cloud-disk-offering-id "${cloud_disk_offering_id}")
  [[ -n "${cloud_host_id}" ]] && cutover_args+=(--cloud-host-id "${cloud_host_id}")
  [[ -n "${cloud_account}" ]] && cutover_args+=(--cloud-account "${cloud_account}")
  [[ -n "${cloud_domain_id}" ]] && cutover_args+=(--cloud-domain-id "${cloud_domain_id}")
  [[ -n "${cloud_project_id}" ]] && cutover_args+=(--cloud-project-id "${cloud_project_id}")
  [[ -n "${cloud_name}" ]] && cutover_args+=(--cloud-name "${cloud_name}")
  [[ -n "${cloud_display_name}" ]] && cutover_args+=(--cloud-display-name "${cloud_display_name}")
  [[ -n "${cloud_cpu_speed}" ]] && cutover_args+=(--cloud-cpu-speed "${cloud_cpu_speed}")
  cutover_args+=(--shutdown "${shutdown}")

  if ! n2k_run_manifest_phase_done "${N2K_MANIFEST}" "cutover"; then
    n2k_event INFO "run" "" "step" '{"step":"cutover"}'
    n2k_cmd_cutover "${cutover_args[@]}"
  fi
  if [[ "${cleanup_source_points}" == "true" && "${N2K_DRY_RUN:-0}" -ne 1 ]]; then
    n2k_run_cleanup_source_recovery_points "${N2K_MANIFEST}" "${source_endpoint}" "${username}" "${password}" "${insecure}"
  else
    n2k_event INFO "run" "" "source_points_cleanup_skipped" '{"reason":"operator requested source recovery point retention"}'
  fi

  local completion_cleanup_plan
  completion_cleanup_plan="$(n2k_cleanup_plan_json "${N2K_MANIFEST}" true true)"
  n2k_event INFO "run" "" "cleanup_plan_created" "${completion_cleanup_plan}"
  n2k_manifest_phase_done "${N2K_MANIFEST}" "cleanup"

  if [[ "${split}" == "phase2" ]]; then
    n2k_manifest_mark_split_done "${N2K_MANIFEST}" "phase2"
  fi
  n2k_run_text_or_json "${split}" "done" "n2k run ${split} completed."
}
n2k_cmd_snapshot() {
  local which="${1:-}"
  [[ -n "${which}" ]] || n2k_die "snapshot requires base|incr|final"
  shift || true

  local name="" recovery_point_id="" source_api="manual"
  local pc="" vm="" cred_file="" username="" password="" insecure="1" pd_name=""
  local create_pd=false protect_vm=false create_oob_snapshot=false create_vm_snapshot=false create_recovery_point=false
  local verify_changed_regions=false collect_changed_regions=false reference_kind=""
  local restore_to_temp_vm=false temp_vm_name="" restore_cluster_id="" restore_strict_mode=false
  local wait_seconds="180" retention_seconds app_consistent=false snapshot_type="CRASH_CONSISTENT"
  retention_seconds="$(n2k_default_retention_seconds)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="${2:-}"; shift 2 ;;
      --recovery-point-id) recovery_point_id="${2:-}"; shift 2 ;;
      --source-api) source_api="${2:-}"; shift 2 ;;
      --pc) pc="${2:-}"; shift 2 ;;
      --vm) vm="${2:-}"; shift 2 ;;
      --cred-file) cred_file="${2:-}"; shift 2 ;;
      --username) username="${2:-}"; shift 2 ;;
      --password) password="${2:-}"; shift 2 ;;
      --insecure) insecure="${2:-}"; shift 2 ;;
      --pd-name) pd_name="${2:-}"; shift 2 ;;
      --create-pd) create_pd=true; shift 1 ;;
      --protect-vm) protect_vm=true; shift 1 ;;
      --create-oob-snapshot) create_oob_snapshot=true; shift 1 ;;
      --create-vm-snapshot) create_vm_snapshot=true; shift 1 ;;
      --create-recovery-point) create_recovery_point=true; shift 1 ;;
      --verify-changed-regions) verify_changed_regions=true; shift 1 ;;
      --collect-changed-regions) collect_changed_regions=true; shift 1 ;;
      --reference-kind) reference_kind="${2:-}"; shift 2 ;;
      --restore-to-temp-vm) restore_to_temp_vm=true; shift 1 ;;
      --temp-vm-name) temp_vm_name="${2:-}"; shift 2 ;;
      --restore-cluster-id) restore_cluster_id="${2:-}"; shift 2 ;;
      --restore-strict-mode) restore_strict_mode="$(n2k_parse_bool "${2:-}")"; [[ -n "${restore_strict_mode}" ]] || n2k_die "Invalid --restore-strict-mode value"; shift 2 ;;
      --wait-seconds) wait_seconds="${2:-}"; shift 2 ;;
      --retention-seconds) retention_seconds="${2:-}"; shift 2 ;;
      --snapshot-type) snapshot_type="${2:-}"; shift 2 ;;
      --app-consistent) app_consistent=true; shift 1 ;;
      *) n2k_die "Unknown option for snapshot: $1" ;;
    esac
  done

  case "${which}" in
    base|incr|final) ;;
    *) n2k_die "Invalid snapshot phase: ${which}" ;;
  esac
  case "${source_api}" in
    manual|v4|v3|legacy) ;;
    *) n2k_die "Invalid --source-api: ${source_api}" ;;
  esac
  if [[ "${restore_to_temp_vm}" == "true" ]]; then
    [[ "${source_api}" == "v4" ]] || n2k_die "--restore-to-temp-vm is only valid with --source-api v4"
    [[ "${create_recovery_point}" == "true" || "${create_vm_snapshot}" == "true" ]] || n2k_die "--restore-to-temp-vm requires --create-recovery-point"
  fi

  if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -z "${N2K_EVENTS_LOG:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_EVENTS_LOG="${N2K_WORKDIR}/events.log"
    export N2K_EVENTS_LOG
  fi
  n2k_require_manifest

  local metadata_json="{}"
  if [[ "${source_api}" == "v3" && "${create_vm_snapshot}" == "true" ]]; then
    case "${insecure}" in
      0|1) ;;
      *) n2k_die "Invalid --insecure: ${insecure}" ;;
    esac
    [[ "${wait_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --wait-seconds: ${wait_seconds}"
    [[ "${retention_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --retention-seconds: ${retention_seconds}"

    if [[ -z "${pc}" ]]; then
      pc="$(jq -r '.source.pc // empty' "${N2K_MANIFEST}")"
    fi
    if [[ -z "${vm}" ]]; then
      vm="$(jq -r '.source.vm.name // empty' "${N2K_MANIFEST}")"
    fi
    [[ -n "${pc}" ]] || n2k_die "v3 VM snapshot creation requires --pc or manifest source pc"
    [[ -n "${vm}" ]] || n2k_die "v3 VM snapshot creation requires --vm or manifest source vm"

    if [[ -n "${cred_file}" ]]; then
      n2k_nutanix_load_cred_file "${cred_file}"
      username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
      password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"
    fi
    [[ -n "${username}" ]] || n2k_die "v3 VM snapshot creation requires --username or --cred-file"
    [[ -n "${password}" ]] || n2k_die "v3 VM snapshot creation requires --password or --cred-file"

    if [[ "${N2K_DRY_RUN:-0}" -eq 1 ]]; then
      metadata_json="$(jq -nc \
        --arg pc "${pc}" \
        --arg vm "${vm}" \
        --arg snapshot_type "${snapshot_type}" \
        --argjson verify_changed_regions "${verify_changed_regions}" \
        --argjson collect_changed_regions "${collect_changed_regions}" \
        '{dry_run:true,source:{pc:$pc,vm:$vm},v3:{create_vm_snapshot:true,snapshot_type:$snapshot_type,verify_changed_regions:$verify_changed_regions,collect_changed_regions:$collect_changed_regions}}')"
    else
      local vm_raw vm_uuid snapshot_name create_response snapshot_uuid snapshot_json path_index validation_json changed_regions_json ref_index resolved_reference_kind
      vm_raw="$(n2k_nutanix_fetch_vm_inventory "${pc}" "${vm}" "${username}" "${password}" "${insecure}")"
      vm_uuid="$(printf '%s' "${vm_raw}" | jq -r '.metadata.uuid // .uuid // .vm_id // empty')"
      [[ -n "${vm_uuid}" ]] || n2k_die "v3 VM snapshot creation could not resolve VM UUID: ${vm}"

      snapshot_name="${name:-n2k-${which}-${N2K_RUN_ID:-$(date +%Y%m%d-%H%M%S)}}"
      create_response="$(n2k_source_v3_create_vm_snapshot \
        "${pc}" "${username}" "${password}" "${insecure}" \
        "${vm_uuid}" "${snapshot_name}" "${retention_seconds}" "${snapshot_type}")"
      snapshot_uuid="$(printf '%s' "${create_response}" | jq -r '.metadata.uuid // empty')"
      [[ -n "${snapshot_uuid}" ]] || n2k_die "v3 VM snapshot create response did not include a snapshot UUID"
      snapshot_json="$(n2k_source_v3_wait_vm_snapshot "${pc}" "${username}" "${password}" "${insecure}" "${snapshot_uuid}" "${wait_seconds}")"
      path_index="$(n2k_source_v3_vm_snapshot_paths_from_json "${snapshot_json}")"
      validation_json="$(jq -nc '{verified:false,skipped:true,reason:"changed-region path verification was not requested"}')"
      changed_regions_json="$(jq -nc '{ok:false,skipped:true,reason:"changed-region collection was not requested",disks:{}}')"

      if [[ "${verify_changed_regions}" == "true" || "${collect_changed_regions}" == "true" ]]; then
        resolved_reference_kind="${reference_kind}"
        if [[ -z "${resolved_reference_kind}" ]]; then
          case "${which}" in
            incr) resolved_reference_kind="base" ;;
            final) resolved_reference_kind="incr" ;;
            *) resolved_reference_kind="" ;;
          esac
        fi
        if [[ -z "${resolved_reference_kind}" ]]; then
          validation_json="$(jq -nc '{verified:false,skipped:true,reason:"no reference recovery point kind is available for this snapshot phase"}')"
        else
          case "${resolved_reference_kind}" in
            base|incr|final) ;;
            *) n2k_die "Invalid --reference-kind: ${resolved_reference_kind}" ;;
          esac
          ref_index="$(jq -c --arg kind "${resolved_reference_kind}" '.runtime.recovery_points[$kind].metadata.v3.path_index // .runtime.recovery_points[$kind].metadata.legacy.path_index // empty' "${N2K_MANIFEST}")"
          if [[ -z "${ref_index}" || "${ref_index}" == "null" ]]; then
            validation_json="$(jq -nc --arg kind "${resolved_reference_kind}" '{verified:false,skipped:true,reason:"reference recovery point has no v3 or legacy path index",reference_kind:$kind}')"
            if [[ "${collect_changed_regions}" == "true" ]]; then
              changed_regions_json="$(jq -nc --arg kind "${resolved_reference_kind}" '{ok:false,skipped:true,reason:"reference recovery point has no v3 or legacy path index",reference_kind:$kind,disks:{}}')"
            fi
          else
            if [[ "${verify_changed_regions}" == "true" ]]; then
              validation_json="$(n2k_source_legacy_verify_changed_region_paths \
                "${pc}" "${username}" "${password}" "${insecure}" \
                "${path_index}" "${ref_index}" 40)"
              validation_json="$(jq -c --arg kind "${resolved_reference_kind}" '. + {reference_kind:$kind}' <<<"${validation_json}")"
            fi
            if [[ "${collect_changed_regions}" == "true" ]]; then
              changed_regions_json="$(n2k_source_v3_collect_changed_regions_from_indexes \
                "${pc}" "${username}" "${password}" "${insecure}" \
                "${path_index}" "${ref_index}" "${N2K_MANIFEST}" \
                "${snapshot_uuid}" "$(jq -r --arg kind "${resolved_reference_kind}" '.runtime.recovery_points[$kind].id // empty' "${N2K_MANIFEST}")" 256)"
              changed_regions_json="$(jq -c --arg kind "${resolved_reference_kind}" '. + {reference_kind:$kind}' <<<"${changed_regions_json}")"
            fi
          fi
        fi
      fi

      if [[ -z "${recovery_point_id}" ]]; then
        recovery_point_id="${snapshot_uuid}"
      fi
      if [[ -z "${name}" ]]; then
        name="$(printf '%s' "${snapshot_json}" | jq -r '.status.name // .spec.name // empty')"
        [[ -n "${name}" ]] || name="${snapshot_name}"
      fi
      metadata_json="$(jq -nc \
        --slurpfile create_response_json <(printf '%s' "${create_response}") \
        --slurpfile snapshot_json_file <(printf '%s' "${snapshot_json}") \
        --slurpfile paths_json <(printf '%s' "${path_index}") \
        --slurpfile validation_json_file <(printf '%s' "${validation_json}") \
        --slurpfile changed_regions_json_file <(printf '%s' "${changed_regions_json}") \
        '{v3:{create_response:$create_response_json[0],snapshot:$snapshot_json_file[0],path_index:$paths_json[0],changed_regions_validation:$validation_json_file[0],changed_regions:$changed_regions_json_file[0]}}')"
    fi
  elif [[ "${source_api}" == "v4" && ( "${create_recovery_point}" == "true" || "${create_vm_snapshot}" == "true" ) ]]; then
    case "${insecure}" in
      0|1) ;;
      *) n2k_die "Invalid --insecure: ${insecure}" ;;
    esac
    [[ "${wait_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --wait-seconds: ${wait_seconds}"
    [[ "${retention_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --retention-seconds: ${retention_seconds}"

    if [[ -z "${pc}" ]]; then
      pc="$(jq -r '.source.pc // empty' "${N2K_MANIFEST}")"
    fi
    if [[ -z "${vm}" ]]; then
      vm="$(jq -r '.source.vm.name // empty' "${N2K_MANIFEST}")"
    fi
    [[ -n "${pc}" ]] || n2k_die "v4 recovery point creation requires --pc or manifest source pc"
    [[ -n "${vm}" ]] || n2k_die "v4 recovery point creation requires --vm or manifest source vm"

    if [[ -n "${cred_file}" ]]; then
      n2k_nutanix_load_cred_file "${cred_file}"
      username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
      password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"
    fi
    [[ -n "${username}" ]] || n2k_die "v4 recovery point creation requires --username or --cred-file"
    [[ -n "${password}" ]] || n2k_die "v4 recovery point creation requires --password or --cred-file"
    if [[ "${restore_to_temp_vm}" == "true" ]]; then
      [[ -n "${temp_vm_name}" ]] || temp_vm_name="n2k-restore-${which}-${N2K_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
      if [[ "${N2K_DRY_RUN:-0}" -ne 1 && "${N2K_FORCE:-0}" -ne 1 ]]; then
        n2k_die "snapshot --restore-to-temp-vm creates a Nutanix VM and requires global --force"
      fi
    fi

    if [[ "${N2K_DRY_RUN:-0}" -eq 1 ]]; then
      metadata_json="$(jq -nc \
        --arg pc "${pc}" \
        --arg vm "${vm}" \
        --argjson collect_changed_regions "${collect_changed_regions}" \
        --argjson restore_to_temp_vm "${restore_to_temp_vm}" \
        --arg temp_vm_name "${temp_vm_name}" \
        --arg restore_cluster_id "${restore_cluster_id}" \
        --argjson restore_strict_mode "${restore_strict_mode}" \
        '{dry_run:true,source:{pc:$pc,vm:$vm},v4:{create_recovery_point:true,collect_changed_regions:$collect_changed_regions,restore_to_temp_vm:{requested:$restore_to_temp_vm,temp_vm_name:$temp_vm_name,cluster_ext_id:$restore_cluster_id,strict_mode:$restore_strict_mode}}}')"
    else
      local vm_raw vm_ext_id revision rp_name create_response task_ext_id task_json rp_projection rp_ext_id rp_json vmrp_ext_id vmrp_json path_index changed_regions_json
      local ref_index resolved_reference_kind reference_recovery_point_id restore_to_temp_vm_json
      local restore_response restore_task_ext_id restore_task_json temp_vm_raw temp_vm_ext_id
      vm_raw="$(n2k_nutanix_fetch_vm_inventory "${pc}" "${vm}" "${username}" "${password}" "${insecure}")"
      vm_ext_id="$(n2k_source_vm_uuid_from_inventory_raw "${vm_raw}")"
      [[ -n "${vm_ext_id}" ]] || n2k_die "v4 recovery point creation could not resolve VM extId: ${vm}"

      revision="$(n2k_nutanix_v4_select_revision dataprotection "${pc}" "${username}" "${password}" "${insecure}")"
      rp_name="${name:-n2k-${which}-${N2K_RUN_ID:-$(date +%Y%m%d-%H%M%S)}}"
      create_response="$(n2k_source_v4_create_recovery_point \
        "${pc}" "${username}" "${password}" "${insecure}" \
        "${vm_ext_id}" "${rp_name}" "${retention_seconds}" "${revision}")"
      task_ext_id="$(printf '%s' "${create_response}" | jq -r '.data.extId // empty')"
      [[ -n "${task_ext_id}" ]] || n2k_die "v4 recovery point create response did not include a task extId"
      task_json="$(n2k_source_v4_wait_task "${pc}" "${username}" "${password}" "${insecure}" "${task_ext_id}" "${wait_seconds}")"
      rp_ext_id="$(printf '%s' "${task_json}" | jq -r '.data.completionDetails[]? | select((.name // "") == "recoveryPointExtId") | .value // empty' | head -n1)"
      if [[ -z "${rp_ext_id}" ]]; then
        rp_projection="$(n2k_source_v4_find_recovery_point_by_name "${pc}" "${username}" "${password}" "${insecure}" "${rp_name}" "${vm_ext_id}" "${revision}")"
        rp_ext_id="$(printf '%s' "${rp_projection}" | jq -r '.extId // empty')"
      fi
      [[ -n "${rp_ext_id}" ]] || n2k_die "v4 recovery point task succeeded but the recovery point could not be found by name: ${rp_name}"
      rp_json="$(n2k_source_v4_get_recovery_point "${pc}" "${username}" "${password}" "${insecure}" "${rp_ext_id}" "${revision}")"
      vmrp_ext_id="$(printf '%s' "${rp_json}" | jq -r --arg vm_ext_id "${vm_ext_id}" '.data.vmRecoveryPoints[]? | select((.vmExtId // "") == $vm_ext_id) | .extId // empty' | head -n1)"
      if [[ -n "${vmrp_ext_id}" ]]; then
        vmrp_json="$(n2k_source_v4_get_vm_recovery_point "${pc}" "${username}" "${password}" "${insecure}" "${rp_ext_id}" "${vmrp_ext_id}" "${revision}")"
      else
        vmrp_json="$(jq -nc '{data:{}}')"
      fi
      path_index="$(n2k_source_v4_recovery_point_index_from_json "${rp_json}" "${vmrp_json}")"
      changed_regions_json="$(jq -nc '{ok:false,skipped:true,reason:"v4 changed-region collection was not requested",disks:{}}')"
      restore_to_temp_vm_json="$(jq -nc '{requested:false,performed:false}')"

      if [[ "${restore_to_temp_vm}" == "true" ]]; then
        [[ -n "${vmrp_ext_id}" ]] || n2k_die "v4 restore-to-temp-vm requires a VM recovery point extId"
        restore_response="$(n2k_source_v4_restore_recovery_point \
          "${pc}" "${username}" "${password}" "${insecure}" \
          "${rp_ext_id}" "${vmrp_ext_id}" "${temp_vm_name}" "${restore_cluster_id}" "${restore_strict_mode}" "${revision}")"
        restore_task_ext_id="$(printf '%s' "${restore_response}" | jq -r '.data.extId // empty')"
        [[ -n "${restore_task_ext_id}" ]] || n2k_die "v4 recovery point restore response did not include a task extId"
        restore_task_json="$(n2k_source_v4_wait_task_terminal "${pc}" "${username}" "${password}" "${insecure}" "${restore_task_ext_id}" "${wait_seconds}")"
        temp_vm_raw="$(n2k_nutanix_fetch_vm_inventory "${pc}" "${temp_vm_name}" "${username}" "${password}" "${insecure}" 2>/dev/null || true)"
        temp_vm_ext_id=""
        if [[ -n "${temp_vm_raw}" ]]; then
          temp_vm_ext_id="$(n2k_source_vm_uuid_from_inventory_raw "${temp_vm_raw}")"
        fi
        restore_to_temp_vm_json="$(jq -nc \
          --arg temp_vm_name "${temp_vm_name}" \
          --arg temp_vm_ext_id "${temp_vm_ext_id}" \
          --arg cluster_ext_id "${restore_cluster_id}" \
          --argjson strict_mode "${restore_strict_mode}" \
          --argjson response "${restore_response}" \
          --argjson task "${restore_task_json}" \
          --argjson temp_vm "$(if [[ -n "${temp_vm_raw}" ]]; then printf '%s' "${temp_vm_raw}"; else printf '{}'; fi)" \
          '{requested:true,performed:true,temp_vm_name:$temp_vm_name,temp_vm_ext_id:$temp_vm_ext_id,cluster_ext_id:$cluster_ext_id,strict_mode:$strict_mode,response:$response,task:$task,temp_vm:$temp_vm,found:($temp_vm_ext_id != "")}')"
      fi

      if [[ "${collect_changed_regions}" == "true" ]]; then
        ref_index="null"
        reference_recovery_point_id=""
        if [[ "${which}" != "base" || -n "${reference_kind}" ]]; then
          resolved_reference_kind="${reference_kind:-base}"
          ref_index="$(jq -c --arg kind "${resolved_reference_kind}" '.runtime.recovery_points[$kind].metadata.v4.path_index // empty' "${N2K_MANIFEST}")"
          reference_recovery_point_id="$(jq -r --arg kind "${resolved_reference_kind}" '.runtime.recovery_points[$kind].id // empty' "${N2K_MANIFEST}")"
          if [[ -z "${ref_index}" || "${ref_index}" == "null" ]]; then
            changed_regions_json="$(jq -nc --arg kind "${resolved_reference_kind}" '{ok:false,skipped:true,reason:"reference recovery point has no v4 path index",reference_kind:$kind,disks:{}}')"
          else
            changed_regions_json="$(n2k_source_v4_collect_changed_regions_from_indexes \
              "${pc}" "${username}" "${password}" "${insecure}" \
              "${path_index}" "${ref_index}" "${N2K_MANIFEST}" \
              "${rp_ext_id}" "${reference_recovery_point_id}" "${revision}" 256)"
            changed_regions_json="$(jq -c --arg kind "${resolved_reference_kind}" '. + {reference_kind:$kind}' <<<"${changed_regions_json}")"
          fi
        else
          changed_regions_json="$(n2k_source_v4_collect_changed_regions_from_indexes \
            "${pc}" "${username}" "${password}" "${insecure}" \
            "${path_index}" "null" "${N2K_MANIFEST}" \
            "${rp_ext_id}" "" "${revision}" 256)"
        fi
      fi
      if [[ -z "${recovery_point_id}" ]]; then
        recovery_point_id="${rp_ext_id}"
      fi
      if [[ -z "${name}" ]]; then
        name="${rp_name}"
      fi
      metadata_json="$(jq -nc \
        --arg revision "${revision}" \
        --slurpfile create_response_json <(printf '%s' "${create_response}") \
        --slurpfile task_json_file <(printf '%s' "${task_json}") \
        --slurpfile recovery_point_json <(printf '%s' "${rp_json}") \
        --slurpfile vm_recovery_point_json <(printf '%s' "${vmrp_json}") \
        --slurpfile paths_json <(printf '%s' "${path_index}") \
        --slurpfile changed_regions_json_file <(printf '%s' "${changed_regions_json}") \
        --slurpfile restore_to_temp_vm_json_file <(printf '%s' "${restore_to_temp_vm_json}") \
        '{v4:{revision:$revision,create_response:$create_response_json[0],task:$task_json_file[0],recovery_point:$recovery_point_json[0],path_index:$paths_json[0],vm_recovery_point:$vm_recovery_point_json[0],changed_regions:$changed_regions_json_file[0],restore_to_temp_vm:$restore_to_temp_vm_json_file[0]}}')"
    fi
  elif [[ "${source_api}" == "legacy" && "${create_oob_snapshot}" == "true" ]]; then
    case "${insecure}" in
      0|1) ;;
      *) n2k_die "Invalid --insecure: ${insecure}" ;;
    esac
    [[ "${wait_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --wait-seconds: ${wait_seconds}"
    [[ "${retention_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --retention-seconds: ${retention_seconds}"

    if [[ -z "${pc}" ]]; then
      pc="$(jq -r '.source.pc // empty' "${N2K_MANIFEST}")"
    fi
    if [[ -z "${vm}" ]]; then
      vm="$(jq -r '.source.vm.name // empty' "${N2K_MANIFEST}")"
    fi
    [[ -n "${pc}" ]] || n2k_die "legacy snapshot creation requires --pc or manifest source pc"
    [[ -n "${vm}" ]] || n2k_die "legacy snapshot creation requires --vm or manifest source vm"
    [[ -n "${pd_name}" ]] || n2k_die "legacy snapshot creation requires --pd-name"

    if [[ -n "${cred_file}" ]]; then
      n2k_nutanix_load_cred_file "${cred_file}"
      username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
      password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"
    fi
    [[ -n "${username}" ]] || n2k_die "legacy snapshot creation requires --username or --cred-file"
    [[ -n "${password}" ]] || n2k_die "legacy snapshot creation requires --password or --cred-file"

    if [[ "${N2K_DRY_RUN:-0}" -eq 1 ]]; then
      metadata_json="$(jq -nc \
        --arg pc "${pc}" \
        --arg vm "${vm}" \
        --arg pd_name "${pd_name}" \
        --argjson verify_changed_regions "${verify_changed_regions}" \
        '{dry_run:true,source:{pc:$pc,vm:$vm},legacy:{protection_domain_name:$pd_name,create_oob_snapshot:true,verify_changed_regions:$verify_changed_regions}}')"
    else
      local snapshots_before before_count oob_response snapshots_after latest_snapshot path_index validation_json ref_index resolved_reference_kind
      if [[ "${create_pd}" == "true" ]]; then
        if ! n2k_source_legacy_get_protection_domain "${pc}" "${username}" "${password}" "${insecure}" "${pd_name}" >/dev/null 2>&1; then
          n2k_source_legacy_create_protection_domain "${pc}" "${username}" "${password}" "${insecure}" "${pd_name}" >/dev/null
          n2k_event INFO "snapshot.${which}" "" "legacy_protection_domain_created" \
            "$(jq -nc --arg pd_name "${pd_name}" '{protection_domain_name:$pd_name}')"
        fi
      fi
      if [[ "${protect_vm}" == "true" ]]; then
        n2k_source_legacy_protect_vm "${pc}" "${username}" "${password}" "${insecure}" "${pd_name}" "${vm}" >/dev/null
        n2k_event INFO "snapshot.${which}" "" "legacy_vm_protected" \
          "$(jq -nc --arg pd_name "${pd_name}" --arg vm "${vm}" '{protection_domain_name:$pd_name,vm:$vm}')"
      fi

      snapshots_before="$(n2k_source_legacy_list_pd_snapshots "${pc}" "${username}" "${password}" "${insecure}" "${pd_name}" 20)"
      before_count="$(printf '%s' "${snapshots_before}" | jq -r '(.entities // []) | length')"
      oob_response="$(n2k_source_legacy_create_oob_snapshot "${pc}" "${username}" "${password}" "${insecure}" "${pd_name}" "${retention_seconds}" "${app_consistent}")"
      snapshots_after="$(n2k_source_legacy_wait_pd_snapshot_count "${pc}" "${username}" "${password}" "${insecure}" "${pd_name}" "$((before_count + 1))" "${wait_seconds}")"
      latest_snapshot="$(n2k_source_legacy_latest_pd_snapshot "${snapshots_after}")"
      [[ -n "${latest_snapshot}" ]] || n2k_die "legacy OOB snapshot did not return a snapshot record"
      path_index="$(n2k_source_legacy_pd_snapshot_paths_from_json "${latest_snapshot}")"
      validation_json="$(jq -nc '{verified:false,skipped:true,reason:"changed-region path verification was not requested"}')"

      if [[ "${verify_changed_regions}" == "true" ]]; then
        resolved_reference_kind="${reference_kind}"
        if [[ -z "${resolved_reference_kind}" ]]; then
          case "${which}" in
            incr) resolved_reference_kind="base" ;;
            final) resolved_reference_kind="incr" ;;
            *) resolved_reference_kind="" ;;
          esac
        fi
        if [[ -z "${resolved_reference_kind}" ]]; then
          validation_json="$(jq -nc '{verified:false,skipped:true,reason:"no reference recovery point kind is available for this snapshot phase"}')"
        else
          case "${resolved_reference_kind}" in
            base|incr|final) ;;
            *) n2k_die "Invalid --reference-kind: ${resolved_reference_kind}" ;;
          esac
          ref_index="$(jq -c --arg kind "${resolved_reference_kind}" '.runtime.recovery_points[$kind].metadata.legacy.path_index // empty' "${N2K_MANIFEST}")"
          if [[ -z "${ref_index}" || "${ref_index}" == "null" ]]; then
            validation_json="$(jq -nc --arg kind "${resolved_reference_kind}" '{verified:false,skipped:true,reason:"reference recovery point has no legacy path index",reference_kind:$kind}')"
          else
            validation_json="$(n2k_source_legacy_verify_changed_region_paths \
              "${pc}" "${username}" "${password}" "${insecure}" \
              "${path_index}" "${ref_index}" 40)"
            validation_json="$(jq -c --arg kind "${resolved_reference_kind}" '. + {reference_kind:$kind}' <<<"${validation_json}")"
          fi
        fi
      fi

      if [[ -z "${recovery_point_id}" ]]; then
        recovery_point_id="$(printf '%s' "${latest_snapshot}" | jq -r '.snapshot_id // .snapshot_uuid // empty')"
      fi
      if [[ -z "${name}" ]]; then
        name="${pd_name}:${recovery_point_id}"
      fi
      metadata_json="$(jq -nc \
        --slurpfile oob_json <(printf '%s' "${oob_response}") \
        --slurpfile snapshot_json_file <(printf '%s' "${latest_snapshot}") \
        --slurpfile paths_json <(printf '%s' "${path_index}") \
        --slurpfile validation_json_file <(printf '%s' "${validation_json}") \
        '{legacy:{oob_schedule:$oob_json[0],snapshot:$snapshot_json_file[0],path_index:$paths_json[0],changed_regions_validation:$validation_json_file[0]}}')"
    fi
  fi

  if [[ -z "${recovery_point_id}" ]]; then
    recovery_point_id="manual-${which}-$(date +%Y%m%d-%H%M%S)"
  fi
  if [[ -z "${name}" ]]; then
    name="${recovery_point_id}"
  fi

  if [[ "${N2K_DRY_RUN:-0}" -ne 1 ]]; then
    n2k_manifest_record_recovery_point "${N2K_MANIFEST}" "${which}" "${recovery_point_id}" "${name}" "${source_api}" "${metadata_json}"
  fi
  local recovery_point_payload
  recovery_point_payload="$(jq -nc --arg kind "${which}" --arg id "${recovery_point_id}" --arg name "${name}" --arg source_api "${source_api}" --slurpfile metadata_json_file <(printf '%s' "${metadata_json}") '{kind:$kind,id:$id,name:$name,source_api:$source_api,metadata:$metadata_json_file[0]}')"
  n2k_event INFO "snapshot.${which}" "" "recovery_point_recorded" \
    "${recovery_point_payload}"
  n2k_json_or_text_ok "snapshot.${which}" \
    "$(jq -nc --arg id "${recovery_point_id}" --arg name "${name}" --arg source_api "${source_api}" --slurpfile metadata_json_file <(printf '%s' "${metadata_json}") '{recovery_point_id:$id,name:$name,source_api:$source_api,metadata:$metadata_json_file[0]}')" \
    "Snapshot reference recorded: ${recovery_point_id}"
}
n2k_cmd_sync() {
  local which="${1:-}"
  [[ -n "${which}" ]] || n2k_die "sync requires base|incr|final"
  shift || true

  local source_map_json_arg="" changed_regions_json_arg="" recovery_point_id=""
  local pc="" cred_file="" username="" password="" insecure="1"
  local source_map_from_v3_nfs=false nfs_host="" nfs_mount_root=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-map-json) source_map_json_arg="${2:-}"; shift 2 ;;
      --source-map-file) source_map_json_arg="${2:-}"; shift 2 ;;
      --changed-regions-json) changed_regions_json_arg="${2:-}"; shift 2 ;;
      --changed-regions-file) changed_regions_json_arg="${2:-}"; shift 2 ;;
      --recovery-point-id) recovery_point_id="${2:-}"; shift 2 ;;
      --pc) pc="${2:-}"; shift 2 ;;
      --cred-file) cred_file="${2:-}"; shift 2 ;;
      --username) username="${2:-}"; shift 2 ;;
      --password) password="${2:-}"; shift 2 ;;
      --insecure) insecure="${2:-}"; shift 2 ;;
	      --source-map-from-v3-nfs) source_map_from_v3_nfs=true; shift 1 ;;
	      --nfs-host) nfs_host="${2:-}"; shift 2 ;;
	      --nfs-mount-root) nfs_mount_root="${2:-}"; shift 2 ;;
	      --keep-source-cache) export N2K_KEEP_SOURCE_CACHE=1; shift 1 ;;
	      --jobs|--chunk|--coalesce-gap)
	        shift 2
	        ;;
      *) n2k_die "Unknown option for sync: $1" ;;
    esac
  done

  if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -z "${N2K_EVENTS_LOG:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_EVENTS_LOG="${N2K_WORKDIR}/events.log"
    export N2K_EVENTS_LOG
  fi
  n2k_require_manifest

  case "${insecure}" in
    0|1) ;;
    *) n2k_die "Invalid --insecure: ${insecure}" ;;
  esac

  if [[ -z "${pc}" ]]; then
    pc="$(jq -r '.source.pc // empty' "${N2K_MANIFEST}")"
  fi
  if [[ -n "${cred_file}" ]]; then
    n2k_nutanix_load_cred_file "${cred_file}"
    username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
    password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"
  fi
  username="${username:-${NUTANIX_USERNAME:-${N2K_PC_USERNAME:-}}}"
  password="${password:-${NUTANIX_PASSWORD:-${N2K_PC_PASSWORD:-}}}"
  export N2K_NUTANIX_PC="${pc}"
  export N2K_NUTANIX_USERNAME="${username}"
  export N2K_NUTANIX_PASSWORD="${password}"
  export N2K_NUTANIX_INSECURE="${insecure}"
  if [[ -z "${nfs_host}" ]]; then
    if [[ "${source_map_from_v3_nfs}" == "true" ]]; then
      nfs_host="$(n2k_run_resolved_v3_source_endpoint_from_manifest "${N2K_MANIFEST}" "${pc}")"
    else
      nfs_host="${pc}"
    fi
  fi
  if [[ "${source_map_from_v3_nfs}" == "true" && -n "${nfs_host}" && "${nfs_host}" != "${pc}" ]]; then
    n2k_event INFO "sync" "" "v3_source_nfs_endpoint_selected" \
      "$(jq -nc --arg pc "${pc}" --arg nfs_host "${nfs_host}" '{pc:$pc,nfs_host:$nfs_host}')"
  fi
  if [[ -n "${nfs_mount_root}" ]]; then
    export N2K_NUTANIX_NFS_MOUNT_ROOT="${nfs_mount_root}"
  fi

  case "${which}" in
    base)
      local source_map
      if [[ -n "${source_map_json_arg}" ]]; then
        source_map="$(n2k_load_source_map_json "${source_map_json_arg}")"
      elif [[ "${source_map_from_v3_nfs}" == "true" ]]; then
        local path_index
        path_index="$(jq -c '.runtime.recovery_points.base.metadata.v3.path_index // empty' "${N2K_MANIFEST}")"
        [[ -n "${path_index}" && "${path_index}" != "null" ]] || {
          echo "sync base --source-map-from-v3-nfs requires a v3 base recovery point path_index in the manifest." >&2
          return 2
        }
        source_map="$(n2k_source_map_from_v3_nfs_path_index "${N2K_MANIFEST}" "${path_index}" "${nfs_host}")"
      else
        source_map="$(n2k_load_source_map_json "${source_map_json_arg}")"
      fi
      n2k_transfer_cold_base_all "${N2K_MANIFEST}" "${source_map}"
      n2k_json_or_text_ok "sync.base" "{}" "Base sync done."
      ;;
	    incr|final)
	      local source_map changed_regions changed_regions_ok
	      if [[ -n "${changed_regions_json_arg}" ]]; then
	        changed_regions="$(n2k_load_changed_regions_json "${changed_regions_json_arg}")"
	      else
	        changed_regions="$(jq -c --arg kind "${which}" '.runtime.recovery_points[$kind].metadata.v3.changed_regions // .runtime.recovery_points[$kind].metadata.legacy.changed_regions // empty' "${N2K_MANIFEST}")"
	        [[ -n "${changed_regions}" && "${changed_regions}" != "null" ]] || {
	          echo "sync ${which} requires --changed-regions-json/--changed-regions-file or a collected changed_regions entry in the manifest." >&2
	          return 2
	        }
	      fi
	      if [[ -z "${recovery_point_id}" ]]; then
	        recovery_point_id="$(jq -r --arg kind "${which}" '.runtime.recovery_points[$kind].id // empty' "${N2K_MANIFEST}")"
	      fi
	      if [[ -n "${source_map_json_arg}" ]]; then
	        source_map="$(n2k_load_source_map_json "${source_map_json_arg}")"
	      elif [[ "${source_map_from_v3_nfs}" == "true" ]]; then
	        changed_regions_ok="$(jq -r '(.ok // false) | tostring' <<<"${changed_regions}")"
	        if [[ "${changed_regions_ok}" == "true" ]]; then
	          source_map="$(n2k_source_map_from_v3_nfs_changed_regions "${changed_regions}" "${nfs_host}")"
	        else
	          local path_index fallback_reason reference_recovery_point_id
	          path_index="$(jq -c --arg kind "${which}" '.runtime.recovery_points[$kind].metadata.v3.path_index // empty' "${N2K_MANIFEST}")"
	          [[ -n "${path_index}" && "${path_index}" != "null" ]] || {
	            echo "sync ${which} could not use changed-region metadata and has no v3 path_index for full-copy fallback." >&2
	            return 2
	          }
	          fallback_reason="$(jq -r '.reason // (if ((.errors // []) | length) > 0 then "changed-region API returned errors" else "changed-region metadata is unavailable" end)' <<<"${changed_regions}")"
	          reference_recovery_point_id="$(jq -r '.reference_recovery_point_id // .base_recovery_point_id // empty' <<<"${changed_regions}")"
	          n2k_event WARN "sync.${which}" "" "changed_regions_full_copy_fallback" \
	            "$(jq -nc --arg reason "${fallback_reason}" --arg recovery_point_id "${recovery_point_id}" --arg reference_recovery_point_id "${reference_recovery_point_id}" --slurpfile changed_regions_json_file <(printf '%s' "${changed_regions}") '{reason:$reason,recovery_point_id:$recovery_point_id,reference_recovery_point_id:$reference_recovery_point_id,changed_regions:$changed_regions_json_file[0]}')"
	          source_map="$(n2k_source_map_from_v3_nfs_path_index "${N2K_MANIFEST}" "${path_index}" "${nfs_host}")"
	          changed_regions="$(n2k_changed_regions_full_copy_from_source_map "${source_map}" "${N2K_MANIFEST}" "${recovery_point_id}" "${reference_recovery_point_id}" "${fallback_reason}")"
	        fi
	      else
	        source_map="$(n2k_load_source_map_json "${source_map_json_arg}")"
	      fi
	      n2k_transfer_patch_all "${N2K_MANIFEST}" "${which}" "${source_map}" "${changed_regions}" "${recovery_point_id}"
	      n2k_json_or_text_ok "sync.${which}" "{}" "$(printf '%s' "${which}" | tr '[:lower:]' '[:upper:]') sync done."
	      ;;
    *)
      n2k_die "Invalid sync phase: ${which}"
      ;;
  esac
}
n2k_cmd_verify() { n2k_not_implemented "verify"; }
n2k_cmd_cutover() {
  local define_only=0 apply_define=0 start_vm=0
  local rbd_access_mode=""
  local libvirt_network_mode="" libvirt_bridge="" libvirt_network=""
  local target_provider="" target_provider_arg_set=0
  local cloud_endpoint="" cloud_api_key="" cloud_secret_key="" cloud_cred_file=""
  local cloud_zone_id="" cloud_service_offering_id="" cloud_network_ids="" cloud_storage_id=""
  local cloud_disk_offering_id="" cloud_host_id="" cloud_account="" cloud_domain_id="" cloud_project_id=""
  local cloud_name="" cloud_display_name="" cloud_cpu_speed="" cloud_config_arg_set=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --define-only) define_only=1; shift 1 ;;
      --apply) apply_define=1; shift 1 ;;
      --start) start_vm=1; shift 1 ;;
      --rbd-access-mode) rbd_access_mode="${2:-}"; shift 2 ;;
      --network-mode|--libvirt-network-mode) libvirt_network_mode="${2:-}"; shift 2 ;;
      --bridge|--libvirt-bridge) libvirt_bridge="${2:-}"; shift 2 ;;
      --network|--libvirt-network) libvirt_network="${2:-}"; shift 2 ;;
      --target-provider) target_provider="${2:-}"; target_provider_arg_set=1; shift 2 ;;
      --cloud-endpoint) cloud_endpoint="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-api-key) cloud_api_key="${2:-}"; shift 2 ;;
      --cloud-secret-key) cloud_secret_key="${2:-}"; shift 2 ;;
      --cloud-cred-file) cloud_cred_file="${2:-}"; shift 2 ;;
      --cloud-zone-id) cloud_zone_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-service-offering-id) cloud_service_offering_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-network-id)
        cloud_network_ids="${cloud_network_ids:+${cloud_network_ids},}${2:-}"
        cloud_config_arg_set=1
        shift 2
        ;;
      --cloud-network-ids) cloud_network_ids="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-storage-id) cloud_storage_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-disk-offering-id) cloud_disk_offering_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-host-id) cloud_host_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-account) cloud_account="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-domain-id) cloud_domain_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-project-id) cloud_project_id="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-name) cloud_name="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-display-name) cloud_display_name="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --cloud-cpu-speed) cloud_cpu_speed="${2:-}"; cloud_config_arg_set=1; shift 2 ;;
      --shutdown)
        shift 2
        ;;
      *) n2k_die "Unknown option for cutover: $1" ;;
    esac
  done

  if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -z "${N2K_EVENTS_LOG:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_EVENTS_LOG="${N2K_WORKDIR}/events.log"
    export N2K_EVENTS_LOG
  fi
  n2k_require_manifest
  [[ "${start_vm}" -eq 0 || "${apply_define}" -eq 1 ]] || n2k_die "--start requires --apply"

  if [[ -n "${rbd_access_mode}" ]]; then
    n2k_valid_rbd_access_mode "${rbd_access_mode}" || n2k_die "Invalid --rbd-access-mode: ${rbd_access_mode}"
    export N2K_RBD_ACCESS_MODE="${rbd_access_mode}"
  fi
  if [[ "${target_provider_arg_set}" -eq 1 ]]; then
    n2k_valid_target_provider "${target_provider}" || n2k_die "Invalid --target-provider: ${target_provider}"
  fi
  if [[ -n "${libvirt_network_mode}" ]]; then
    case "${libvirt_network_mode}" in
      bridge|network) ;;
      *) n2k_die "Invalid --network-mode: ${libvirt_network_mode}" ;;
    esac
    export N2K_LIBVIRT_NETWORK_MODE="${libvirt_network_mode}"
  fi
  [[ -n "${libvirt_bridge}" ]] && export N2K_LIBVIRT_BRIDGE="${libvirt_bridge}"
  [[ -n "${libvirt_network}" ]] && export N2K_LIBVIRT_NETWORK="${libvirt_network}"

  if [[ "${target_provider_arg_set}" -eq 1 || "${cloud_config_arg_set}" -eq 1 ]]; then
    local cloud_config_json
    cloud_config_json="$(n2k_cloud_target_config_json "${cloud_endpoint}" "${cloud_zone_id}" "${cloud_service_offering_id}" "${cloud_network_ids}" "${cloud_storage_id}" "${cloud_disk_offering_id}" "${cloud_host_id}" "${cloud_account}" "${cloud_domain_id}" "${cloud_project_id}" "${cloud_name}" "${cloud_display_name}" "${cloud_cpu_speed}")"
    n2k_cloud_target_apply_manifest_config "${N2K_MANIFEST}" "$(if [[ "${target_provider_arg_set}" -eq 1 ]]; then printf '%s' "${target_provider}"; else printf ''; fi)" "${cloud_config_json}"
  fi
  target_provider="$(jq -r '.target.provider // "libvirt"' "${N2K_MANIFEST}")"

  local xml_path vm cloud_result
  if [[ "${target_provider}" == "ablestack-cloud" ]]; then
    local cloud_error_file cloud_rc cloud_error_text cloud_error_json
    cloud_error_file="$(mktemp)"
    if cloud_result="$(n2k_cloud_target_cutover "${N2K_MANIFEST}" "${define_only}" "${apply_define}" "${start_vm}" "${cloud_endpoint}" "${cloud_api_key}" "${cloud_secret_key}" "${cloud_cred_file}" 2>"${cloud_error_file}")"; then
      rm -f "${cloud_error_file}"
    else
      cloud_rc=$?
      cloud_error_text="$(cat "${cloud_error_file}")"
      [[ -n "${cloud_error_text}" ]] && printf '%s\n' "${cloud_error_text}" >&2
      cloud_error_json="$(jq -nc --arg error "${cloud_error_text}" '{error:$error}')"
      n2k_event ERROR "cutover" "" "cloud_target_cutover_failed" "${cloud_error_json}"
      rm -f "${cloud_error_file}"
      return "${cloud_rc}"
    fi
    n2k_event INFO "cutover" "" "cloud_target_cutover" "${cloud_result}"
    if [[ "${define_only}" -eq 1 || "${apply_define}" -eq 1 || "${start_vm}" -eq 1 ]]; then
      n2k_manifest_phase_done "${N2K_MANIFEST}" "cutover"
    fi
    n2k_json_or_text_ok "cutover" "${cloud_result}" "Cloud cutover completed: $(jq -r '.vm_id // .provider' <<<"${cloud_result}")"
    return 0
  fi

  if [[ "${apply_define}" -eq 1 || "${start_vm}" -eq 1 ]]; then
    n2k_target_prepare_libvirt_storage "${N2K_MANIFEST}"
  fi

  xml_path="$(n2k_target_generate_libvirt_xml "${N2K_MANIFEST}")"
  n2k_manifest_record_artifact "${N2K_MANIFEST}" "${xml_path}" "libvirt_xml"
  n2k_event INFO "cutover" "" "libvirt_xml_generated" \
    "$(jq -nc --arg xml_path "${xml_path}" '{xml_path:$xml_path}')"

  if [[ "${apply_define}" -eq 1 ]]; then
    n2k_target_define_libvirt "${xml_path}"
    n2k_event INFO "cutover" "" "libvirt_defined" \
      "$(jq -nc --arg xml_path "${xml_path}" '{xml_path:$xml_path}')"
  fi

  if [[ "${start_vm}" -eq 1 ]]; then
    [[ "${apply_define}" -eq 1 ]] || n2k_die "--start requires --apply"
    vm="$(jq -r '.target.libvirt.name // .source.vm.name' "${N2K_MANIFEST}")"
    virsh start "${vm}" >/dev/null
    n2k_event INFO "cutover" "" "target_started" \
      "$(jq -nc --arg vm "${vm}" '{vm:$vm}')"
  fi

  if [[ "${define_only}" -eq 1 || "${apply_define}" -eq 1 || "${start_vm}" -eq 1 ]]; then
    n2k_manifest_phase_done "${N2K_MANIFEST}" "cutover"
  fi

  n2k_json_or_text_ok "cutover" "$(jq -nc --arg xml_path "${xml_path}" '{xml_path:$xml_path}')" "Cutover artifact generated: ${xml_path}"
}
n2k_cleanup_plan_json() {
  local manifest="$1" keep_source_points="$2" keep_workdir="$3" remove_source_cache="${4:-false}"
  local workdir
  workdir="$(jq -r '.run.workdir // ""' "${manifest}")"
  jq -c \
    --arg workdir "${workdir}" \
    --argjson keep_source_points "${keep_source_points}" \
    --argjson keep_workdir "${keep_workdir}" \
    --argjson remove_source_cache "${remove_source_cache}" \
    '
      def in_workdir($p):
        ($workdir | length) > 0 and (($p + "/") | startswith($workdir + "/"));

      (.runtime.cleanup.items // []) as $items
      | {
          keep_source_points: $keep_source_points,
          keep_workdir: $keep_workdir,
          items: (
            (
              $items
              + (if $remove_source_cache and (($workdir | length) > 0) then [{
                  kind:"source-cache",
                  path:($workdir + "/source-cache"),
                  cleanup_allowed:true,
                  removed:false
                }] else [] end)
            )
            | map(select((.removed // false) | not))
            | unique_by(.kind + ":" + (.path // ""))
            | map(. + {
                action: (
                  if (.kind // "") == "source-cache" and $remove_source_cache then "remove"
                  elif (.source_resource // false) and $keep_source_points then "keep"
                  elif ((.cleanup_allowed // false) | not) then "keep"
                  elif (.path // "" | in_workdir(.)) then "remove"
                  else "keep"
                  end
                ),
                reason: (
                  if (.kind // "") == "source-cache" and $remove_source_cache then "source-cache garbage"
                  elif (.source_resource // false) and $keep_source_points then "source resource is kept"
                  elif ((.cleanup_allowed // false) | not) then "cleanup is not allowed"
                  elif (.path // "" | in_workdir(.)) then "recorded workdir artifact"
                  else "path is outside workdir"
                  end
                )
              })
          )
        }
    ' "${manifest}"
}

n2k_cleanup_apply_plan() {
  local manifest="$1" plan="$2"
  local path kind action workdir
  workdir="$(jq -r '.run.workdir // ""' "${manifest}")"

  while IFS=$'\t' read -r action path kind; do
    [[ "${action}" == "remove" ]] || continue
    [[ -n "${path}" ]] || continue
    if [[ -f "${path}" ]]; then
      rm -f -- "${path}"
      n2k_manifest_mark_cleanup_item_removed "${manifest}" "${path}"
      n2k_event INFO "cleanup" "" "artifact_removed" \
        "$(jq -nc --arg path "${path}" --arg kind "${kind}" '{path:$path,kind:$kind}')"
    elif [[ -d "${path}" ]]; then
      if [[ "${kind}" == "source-cache" && -n "${workdir}" && "${path}" == "${workdir}/source-cache" ]]; then
        rm -rf -- "${path}"
      else
        rmdir -- "${path}" 2>/dev/null || true
      fi
      if [[ ! -d "${path}" ]]; then
        n2k_manifest_mark_cleanup_item_removed "${manifest}" "${path}"
        n2k_event INFO "cleanup" "" "artifact_removed" \
          "$(jq -nc --arg path "${path}" --arg kind "${kind}" '{path:$path,kind:$kind}')"
      fi
    else
      n2k_manifest_mark_cleanup_item_removed "${manifest}" "${path}"
    fi
  done < <(printf '%s\n' "${plan}" | jq -r '.items[] | [.action, .path, .kind] | @tsv')
}

n2k_cmd_cleanup() {
  local keep_source_points=true keep_workdir=true remove_source_cache=false apply_cleanup=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-source-points) keep_source_points=true; shift 1 ;;
      --remove-source-points)
        [[ "${N2K_FORCE:-0}" -eq 1 ]] || n2k_die "--remove-source-points requires --force"
        keep_source_points=false
        shift 1
        ;;
	      --keep-workdir) keep_workdir=true; shift 1 ;;
	      --remove-workdir)
	        [[ "${N2K_FORCE:-0}" -eq 1 ]] || n2k_die "--remove-workdir requires --force"
	        keep_workdir=false
	        shift 1
	        ;;
	      --remove-source-cache|--gc-source-cache) remove_source_cache=true; shift 1 ;;
	      --apply) apply_cleanup=1; shift 1 ;;
	      *) n2k_die "Unknown option for cleanup: $1" ;;
	    esac
  done

  if [[ -z "${N2K_MANIFEST:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_MANIFEST="${N2K_WORKDIR}/manifest.json"
    export N2K_MANIFEST
  fi
  if [[ -z "${N2K_EVENTS_LOG:-}" && -n "${N2K_WORKDIR:-}" ]]; then
    N2K_EVENTS_LOG="${N2K_WORKDIR}/events.log"
    export N2K_EVENTS_LOG
  fi
  n2k_require_manifest

  local plan
  plan="$(n2k_cleanup_plan_json "${N2K_MANIFEST}" "${keep_source_points}" "${keep_workdir}" "${remove_source_cache}")"
  n2k_event INFO "cleanup" "" "cleanup_plan_created" "${plan}"

  if [[ "${apply_cleanup}" -eq 1 && "${N2K_DRY_RUN:-0}" -ne 1 ]]; then
    n2k_cleanup_apply_plan "${N2K_MANIFEST}" "${plan}"
    n2k_manifest_phase_done "${N2K_MANIFEST}" "cleanup"
    n2k_json_or_text_ok "cleanup" "${plan}" "Cleanup applied."
  else
    if [[ "${N2K_JSON_OUT:-0}" -eq 1 ]]; then
      jq -nc --arg phase "cleanup" --argjson payload "${plan}" '{ok:true,phase:$phase,dry_run:true,payload:$payload}'
    else
      printf '%s\n' "${plan}" | jq -r '
        "Cleanup plan only. Use --apply to remove recorded local artifacts.\n" +
        "Items: " + ((.items | length) | tostring) + "\n" +
        ((.items // []) | map("- " + (.action // "") + " " + (.path // "") + " (" + (.reason // "") + ")") | join("\n"))
      '
    fi
  fi
}
