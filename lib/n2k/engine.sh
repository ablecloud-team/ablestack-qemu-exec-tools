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
  local target_format="qcow2" target_storage="file" target_map_json="{}"

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
      *) n2k_die "Unknown option for init: $1" ;;
    esac
  done

  [[ -n "${vm}" ]] || n2k_die "init requires --vm"
  [[ -n "${pc}" ]] || n2k_die "init requires --pc"
  [[ -n "${dst}" ]] || dst="/var/lib/libvirt/images/$(n2k_safe_name "${vm}")"
  n2k_valid_mode "${mode}" || n2k_die "Invalid --mode: ${mode}"
  n2k_valid_target_format "${target_format}" || n2k_die "Invalid --target-format: ${target_format}"
  n2k_valid_target_storage "${target_storage}" || n2k_die "Invalid --target-storage: ${target_storage}"
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

  n2k_manifest_init "${N2K_MANIFEST}" "${N2K_RUN_ID}" "${N2K_WORKDIR}" "${vm}" "${pc}" "${mode}" "${dst}" "${target_format}" "${target_storage}" "${target_map_json}" "${inventory_json}"
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
  local v4_vmm="auto" v4_dp="auto" legacy="auto" legacy_verified="auto" cold="auto" manual="auto"
  local parsed_bool=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pc) pc="${2:-}"; shift 2 ;;
      --vm) vm="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --cred-file)
        [[ -f "${2:-}" ]] || n2k_die "Credential file not found: ${2:-}"
        shift 2
        ;;
      --username|--password|--insecure)
        shift 2
        ;;
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
      --allow-experimental) allow_experimental=true; shift 1 ;;
      *) n2k_die "Unknown capability option: $1" ;;
    esac
  done

  [[ -n "${pc}" ]] || n2k_die "preflight requires --pc"
  if [[ "${require_vm}" == "1" ]]; then
    [[ -n "${vm}" ]] || n2k_die "plan requires --vm"
  fi
  n2k_valid_mode "${mode}" || n2k_die "Invalid --mode: ${mode}"

  local capability_json deps_json
  capability_json="$(n2k_load_json_arg "${capability_json_arg}")"
  deps_json="$(n2k_detect_host_dependencies)"

  n2k_preflight_result_json "${pc}" "${vm}" "${mode}" "${allow_experimental}" \
    "${capability_json}" "${deps_json}" \
    "${v4_vmm}" "${v4_dp}" "${legacy}" "${legacy_verified}" "${cold}" "${manual}"
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

  n2k_not_implemented "run"
}
n2k_cmd_snapshot() { n2k_not_implemented "snapshot"; }
n2k_cmd_sync() {
  local which="${1:-}"
  [[ -n "${which}" ]] || n2k_die "sync requires base|incr|final"
  shift || true

  local source_map_json_arg="" changed_regions_json_arg="" recovery_point_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-map-json) source_map_json_arg="${2:-}"; shift 2 ;;
      --source-map-file) source_map_json_arg="${2:-}"; shift 2 ;;
      --changed-regions-json) changed_regions_json_arg="${2:-}"; shift 2 ;;
      --changed-regions-file) changed_regions_json_arg="${2:-}"; shift 2 ;;
      --recovery-point-id) recovery_point_id="${2:-}"; shift 2 ;;
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

  case "${which}" in
    base)
      local source_map
      source_map="$(n2k_load_source_map_json "${source_map_json_arg}")"
      n2k_transfer_cold_base_all "${N2K_MANIFEST}" "${source_map}"
      n2k_json_or_text_ok "sync.base" "{}" "Base sync done."
      ;;
    incr|final)
      local source_map changed_regions
      source_map="$(n2k_load_source_map_json "${source_map_json_arg}")"
      changed_regions="$(n2k_load_changed_regions_json "${changed_regions_json_arg}")"
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

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --define-only) define_only=1; shift 1 ;;
      --apply) apply_define=1; shift 1 ;;
      --start) start_vm=1; shift 1 ;;
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

  local xml_path vm
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
