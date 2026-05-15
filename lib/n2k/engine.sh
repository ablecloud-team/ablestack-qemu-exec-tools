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
source "${N2K_LIB_DIR}/transfer_cold.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/transfer_patch.sh"
# shellcheck source=/dev/null
source "${N2K_LIB_DIR}/target_libvirt.sh"

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
    auto|v4-incremental|legacy-cbt|cold-export|manual-disk) return 0 ;;
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
    jq -nc --arg phase "${phase}" --argjson payload "${json_payload}" '{ok:true,phase:$phase,payload:$payload}'
  else
    echo "${text}"
  fi
}

n2k_cmd_init() {
  local vm="" pc="" dst="" mode="auto" cred_file=""
  local username="" password="" insecure="1"
  local inventory_json_arg="" inventory_source="none"
  local target_format="qcow2" target_storage="file" target_map_json="{}" rbd_access_mode="librbd"

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
      --inventory-json) inventory_json_arg="${2:-}"; inventory_source="fixture"; shift 2 ;;
      --inventory-file) inventory_json_arg="${2:-}"; inventory_source="fixture"; shift 2 ;;
      --inventory-source) inventory_source="${2:-}"; shift 2 ;;
      --target-format) target_format="${2:-}"; shift 2 ;;
      --target-storage) target_storage="${2:-}"; shift 2 ;;
      --target-map-json) target_map_json="${2:-}"; shift 2 ;;
      --rbd-access-mode) rbd_access_mode="${2:-}"; shift 2 ;;
      *) n2k_die "Unknown option for init: $1" ;;
    esac
  done

  [[ -n "${vm}" ]] || n2k_die "init requires --vm"
  [[ -n "${pc}" ]] || n2k_die "init requires --pc"
  [[ -n "${dst}" ]] || dst="/var/lib/libvirt/images/$(n2k_safe_name "${vm}")"
  n2k_valid_mode "${mode}" || n2k_die "Invalid --mode: ${mode}"
  if [[ "${target_storage}" == "qcow2" ]]; then
    target_storage="file"
    target_format="qcow2"
  fi
  n2k_valid_target_format "${target_format}" || n2k_die "Invalid --target-format: ${target_format}"
  n2k_valid_target_storage "${target_storage}" || n2k_die "Invalid --target-storage: ${target_storage}"
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

  n2k_manifest_init "${N2K_MANIFEST}" "${N2K_RUN_ID}" "${N2K_WORKDIR}" "${vm}" "${pc}" "${mode}" "${dst}" "${target_format}" "${target_storage}" "${target_map_json}" "${inventory_json}" "${rbd_access_mode}"
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
  local parsed_bool=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pc) pc="${2:-}"; shift 2 ;;
      --vm) vm="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --target-storage) target_storage="${2:-}"; shift 2 ;;
      --target-format) target_format="${2:-}"; shift 2 ;;
      --rbd-access-mode) rbd_access_mode="${2:-}"; shift 2 ;;
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
  n2k_valid_rbd_access_mode "${rbd_access_mode}" || n2k_die "Invalid --rbd-access-mode: ${rbd_access_mode}"

  local capability_json deps_json probed_json
  capability_json="$(n2k_load_json_arg "${capability_json_arg}")"
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
  deps_json="$(n2k_detect_host_dependencies)"

  n2k_preflight_result_json "${pc}" "${vm}" "${mode}" "${allow_experimental}" \
    "${capability_json}" "${deps_json}" \
    "${v4_vmm}" "${v4_dp}" "${v4_data_plane}" "${legacy}" "${legacy_verified}" "${cold}" "${manual}" \
    "${target_storage}" "${target_format}"
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

n2k_cmd_run() {
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
  local split="${N2K_RUN_DEFAULT_SPLIT:-full}" source_api="v3"
  local nfs_host="" nfs_mount_root="" source_map_from_v3_nfs=true
  local deadline_sec="${N2K_RUN_DEFAULT_DEADLINE_SEC:-120}"
  local max_incr_phase2="${N2K_RUN_DEFAULT_MAX_INCR_PHASE2:-20}"
  local max_final_bytes="${N2K_RUN_DEFAULT_MAX_FINAL_BYTES:--1}"
  local wait_seconds="180" retention_seconds="3600" snapshot_type="CRASH_CONSISTENT"
  local shutdown="manual" cutover_policy="define-only" cutover_args_str=""
  local shutdown_timeout_sec="${N2K_RUN_DEFAULT_SHUTDOWN_TIMEOUT_SEC:-300}"
  local shutdown_poll_sec="${N2K_RUN_DEFAULT_SHUTDOWN_POLL_SEC:-5}"
  local skip_plan=0 allow_experimental=false probe_legacy=false

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
      --split) split="${2:-}"; shift 2 ;;
      --source-api) source_api="${2:-}"; shift 2 ;;
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
  [[ "${deadline_sec}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --deadline-sec: ${deadline_sec}"
  [[ "${max_incr_phase2}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --max-incr-phase2: ${max_incr_phase2}"
  [[ "${max_final_bytes}" =~ ^-?[0-9]+$ ]] || n2k_die "Invalid --max-final-bytes: ${max_final_bytes}"
  [[ "${wait_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --wait-seconds: ${wait_seconds}"
  [[ "${retention_seconds}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --retention-seconds: ${retention_seconds}"
  [[ "${shutdown_timeout_sec}" =~ ^[0-9]+$ ]] || n2k_die "Invalid --shutdown-timeout-sec: ${shutdown_timeout_sec}"
  [[ "${shutdown_poll_sec}" =~ ^[0-9]+$ && "${shutdown_poll_sec}" -gt 0 ]] || n2k_die "Invalid --shutdown-poll-sec: ${shutdown_poll_sec}"
  n2k_valid_mode "${mode}" || n2k_die "Invalid --mode: ${mode}"
  if [[ "${target_storage}" == "qcow2" ]]; then
    target_storage="file"
    target_format="qcow2"
  fi
  n2k_valid_target_format "${target_format}" || n2k_die "Invalid --target-format: ${target_format}"
  n2k_valid_target_storage "${target_storage}" || n2k_die "Invalid --target-storage: ${target_storage}"
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

  if [[ "${split}" == "phase2" ]]; then
    n2k_require_manifest
    n2k_manifest_split_is_done "${N2K_MANIFEST}" "phase1" || \
      n2k_die "run --split phase2 requires a completed phase1 marker in the manifest"
  elif [[ -z "${N2K_MANIFEST:-}" || ! -f "${N2K_MANIFEST}" ]]; then
    [[ -n "${vm}" ]] || n2k_die "run --split ${split} requires --vm when no manifest exists"
    [[ -n "${pc}" ]] || n2k_die "run --split ${split} requires --pc when no manifest exists"
    local -a init_args=(--vm "${vm}" --pc "${pc}" --mode "${mode}" --inventory-source "${inventory_source}" --target-format "${target_format}" --target-storage "${target_storage}" --rbd-access-mode "${rbd_access_mode}")
    [[ -n "${dst}" ]] && init_args+=(--dst "${dst}")
    [[ -n "${target_map_json}" ]] && init_args+=(--target-map-json "${target_map_json}")
    init_args+=("${credential_args[@]}")
    n2k_cmd_init "${init_args[@]}"
  else
    n2k_require_manifest
  fi

  vm="${vm:-$(n2k_run_manifest_value "${N2K_MANIFEST}" '.source.vm.name // empty')}"
  pc="${pc:-$(n2k_run_manifest_value "${N2K_MANIFEST}" '.source.pc // empty')}"
  [[ -n "${vm}" ]] || n2k_die "run could not resolve VM name from args or manifest"
  [[ -n "${pc}" ]] || n2k_die "run could not resolve Prism endpoint from args or manifest"
  if [[ -z "${nfs_host}" ]]; then
    nfs_host="${pc}"
  fi

  if [[ -n "${nfs_mount_root}" ]]; then
    export N2K_NUTANIX_NFS_MOUNT_ROOT="${nfs_mount_root}"
  fi

  if [[ "${split}" != "phase2" && "${skip_plan}" -eq 0 ]] && ! n2k_run_manifest_phase_done "${N2K_MANIFEST}" "plan"; then
    local -a plan_args=(--vm "${vm}" --pc "${pc}" --mode "${mode}" --target-format "${target_format}" --target-storage "${target_storage}" --rbd-access-mode "${rbd_access_mode}")
    plan_args+=("${credential_args[@]}")
    [[ "${allow_experimental}" == "true" ]] && plan_args+=(--allow-experimental)
    [[ "${probe_legacy}" == "true" ]] && plan_args+=(--probe-legacy-cbt)
    n2k_cmd_plan "${plan_args[@]}"
  fi

  local -a snapshot_common=(--source-api "${source_api}" --create-vm-snapshot --pc "${pc}" --vm "${vm}" --wait-seconds "${wait_seconds}" --retention-seconds "${retention_seconds}" --snapshot-type "${snapshot_type}")
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
          "$(jq -nc --arg policy "${shutdown}" --argjson timeout_sec "${shutdown_timeout_sec}" '{policy:$policy,timeout_sec:$timeout_sec}')"
        shutdown_result="$(n2k_source_vm_shutdown "${pc}" "${vm}" "${username}" "${password}" "${insecure}" "${shutdown}" "${shutdown_timeout_sec}" "${shutdown_poll_sec}")" || shutdown_rc=$?
        shutdown_payload="$(n2k_source_compact_json_value "${shutdown_result:-{}}")"
        if [[ "${shutdown_rc}" -eq 0 ]]; then
          shutdown_payload="$(n2k_run_reconstruct_empty_shutdown_payload "${shutdown_payload}" "${pc}" "${vm}" "${username}" "${password}" "${insecure}" "${shutdown}")"
          if ! n2k_run_shutdown_payload_ok "${shutdown_payload}"; then
            shutdown_rc=4
          fi
        fi
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
  cutover_args+=(--shutdown "${shutdown}")

  if ! n2k_run_manifest_phase_done "${N2K_MANIFEST}" "cutover"; then
    n2k_event INFO "run" "" "step" '{"step":"cutover"}'
    n2k_cmd_cutover "${cutover_args[@]}"
  fi

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
  local create_pd=false protect_vm=false create_oob_snapshot=false create_vm_snapshot=false
  local verify_changed_regions=false collect_changed_regions=false reference_kind=""
  local wait_seconds="180" retention_seconds="3600" app_consistent=false snapshot_type="CRASH_CONSISTENT"
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
      --verify-changed-regions) verify_changed_regions=true; shift 1 ;;
      --collect-changed-regions) collect_changed_regions=true; shift 1 ;;
      --reference-kind) reference_kind="${2:-}"; shift 2 ;;
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
        --argjson create_response "${create_response}" \
        --argjson snapshot "${snapshot_json}" \
        --argjson paths "${path_index}" \
        --argjson validation "${validation_json}" \
        --argjson changed_regions "${changed_regions_json}" \
        '{v3:{create_response:$create_response,snapshot:$snapshot,path_index:$paths,changed_regions_validation:$validation,changed_regions:$changed_regions}}')"
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
        --argjson oob "${oob_response}" \
        --argjson snapshot "${latest_snapshot}" \
        --argjson paths "${path_index}" \
        --argjson validation "${validation_json}" \
        '{legacy:{oob_schedule:$oob,snapshot:$snapshot,path_index:$paths,changed_regions_validation:$validation}}')"
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
  n2k_event INFO "snapshot.${which}" "" "recovery_point_recorded" \
    "$(jq -nc --arg kind "${which}" --arg id "${recovery_point_id}" --arg name "${name}" --arg source_api "${source_api}" --argjson metadata "${metadata_json}" '{kind:$kind,id:$id,name:$name,source_api:$source_api,metadata:$metadata}')"
  n2k_json_or_text_ok "snapshot.${which}" \
    "$(jq -nc --arg id "${recovery_point_id}" --arg name "${name}" --arg source_api "${source_api}" --argjson metadata "${metadata_json}" '{recovery_point_id:$id,name:$name,source_api:$source_api,metadata:$metadata}')" \
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
    nfs_host="${pc}"
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
      local source_map changed_regions
      if [[ -n "${changed_regions_json_arg}" ]]; then
        changed_regions="$(n2k_load_changed_regions_json "${changed_regions_json_arg}")"
      else
        changed_regions="$(jq -c --arg kind "${which}" '.runtime.recovery_points[$kind].metadata.v3.changed_regions // .runtime.recovery_points[$kind].metadata.legacy.changed_regions // empty' "${N2K_MANIFEST}")"
        [[ -n "${changed_regions}" && "${changed_regions}" != "null" ]] || {
          echo "sync ${which} requires --changed-regions-json/--changed-regions-file or a collected changed_regions entry in the manifest." >&2
          return 2
        }
      fi
      if [[ -n "${source_map_json_arg}" ]]; then
        source_map="$(n2k_load_source_map_json "${source_map_json_arg}")"
      elif [[ "${source_map_from_v3_nfs}" == "true" ]]; then
        source_map="$(n2k_source_map_from_v3_nfs_changed_regions "${changed_regions}" "${nfs_host}")"
      else
        source_map="$(n2k_load_source_map_json "${source_map_json_arg}")"
      fi
      if [[ -z "${recovery_point_id}" ]]; then
        recovery_point_id="$(jq -r --arg kind "${which}" '.runtime.recovery_points[$kind].id // empty' "${N2K_MANIFEST}")"
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

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --define-only) define_only=1; shift 1 ;;
      --apply) apply_define=1; shift 1 ;;
      --start) start_vm=1; shift 1 ;;
      --rbd-access-mode) rbd_access_mode="${2:-}"; shift 2 ;;
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

  if [[ -n "${rbd_access_mode}" ]]; then
    n2k_valid_rbd_access_mode "${rbd_access_mode}" || n2k_die "Invalid --rbd-access-mode: ${rbd_access_mode}"
    export N2K_RBD_ACCESS_MODE="${rbd_access_mode}"
  fi

  local xml_path vm
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
  local manifest="$1" keep_source_points="$2" keep_workdir="$3"
  local workdir
  workdir="$(jq -r '.run.workdir // ""' "${manifest}")"
  jq -c \
    --arg workdir "${workdir}" \
    --argjson keep_source_points "${keep_source_points}" \
    --argjson keep_workdir "${keep_workdir}" \
    '
      def in_workdir($p):
        ($workdir | length) > 0 and (($p + "/") | startswith($workdir + "/"));

      (.runtime.cleanup.items // []) as $items
      | {
          keep_source_points: $keep_source_points,
          keep_workdir: $keep_workdir,
          items: (
            $items
            | map(select((.removed // false) | not))
            | map(. + {
                action: (
                  if (.source_resource // false) and $keep_source_points then "keep"
                  elif ((.cleanup_allowed // false) | not) then "keep"
                  elif (.path // "" | in_workdir(.)) then "remove"
                  else "keep"
                  end
                ),
                reason: (
                  if (.source_resource // false) and $keep_source_points then "source resource is kept"
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
  local path kind action

  while IFS=$'\t' read -r action path kind; do
    [[ "${action}" == "remove" ]] || continue
    [[ -n "${path}" ]] || continue
    if [[ -f "${path}" ]]; then
      rm -f -- "${path}"
      n2k_manifest_mark_cleanup_item_removed "${manifest}" "${path}"
      n2k_event INFO "cleanup" "" "artifact_removed" \
        "$(jq -nc --arg path "${path}" --arg kind "${kind}" '{path:$path,kind:$kind}')"
    elif [[ -d "${path}" ]]; then
      rmdir -- "${path}" 2>/dev/null || true
      if [[ ! -d "${path}" ]]; then
        n2k_manifest_mark_cleanup_item_removed "${manifest}" "${path}"
      fi
    else
      n2k_manifest_mark_cleanup_item_removed "${manifest}" "${path}"
    fi
  done < <(printf '%s\n' "${plan}" | jq -r '.items[] | [.action, .path, .kind] | @tsv')
}

n2k_cmd_cleanup() {
  local keep_source_points=true keep_workdir=true apply_cleanup=0

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
  plan="$(n2k_cleanup_plan_json "${N2K_MANIFEST}" "${keep_source_points}" "${keep_workdir}")"
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
