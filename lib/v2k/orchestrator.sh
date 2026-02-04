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

v2k_run_defaults() {
  V2K_RUN_DEFAULT_SHUTDOWN="${V2K_RUN_DEFAULT_SHUTDOWN:-manual}"
  V2K_RUN_DEFAULT_KVM_POLICY="${V2K_RUN_DEFAULT_KVM_POLICY:-none}"
  V2K_RUN_DEFAULT_INCR_INTERVAL="${V2K_RUN_DEFAULT_INCR_INTERVAL:-10}"
  V2K_RUN_DEFAULT_MAX_INCR="${V2K_RUN_DEFAULT_MAX_INCR:-6}"
  V2K_RUN_DEFAULT_CONVERGE_THRESHOLD_SEC="${V2K_RUN_DEFAULT_CONVERGE_THRESHOLD_SEC:-120}"
  V2K_RUN_DEFAULT_INSECURE="${V2K_RUN_DEFAULT_INSECURE:-1}"
  V2K_RUN_WINPE_BOOTSTRAP_AUTO="${V2K_RUN_WINPE_BOOTSTRAP_AUTO:-1}"

  # Split-run defaults
  : "${V2K_RUN_DEFAULT_SPLIT:=full}"             # full|phase1|phase2
  : "${V2K_RUN_DEFAULT_DEADLINE_SEC:=120}"      # phase2 deadline window for incrN->cutover
  : "${V2K_RUN_DEFAULT_MAX_INCR_PHASE2:=20}"    # safety cap for phase2 incr loops
}

v2k_die() { echo "ERROR: $*" >&2; exit 2; }

# ---------------------------------------------------------------------
# Compatibility wrappers
# - Keep orchestrator's phase code readable while delegating to engine.sh
# - DO NOT change core migration logic (engine/transfer scripts stay intact)
# ---------------------------------------------------------------------
if ! declare -F v2k_cmd_incr_sync >/dev/null 2>&1; then
  v2k_cmd_incr_sync() { v2k_cmd_sync incr "$@"; }
fi

if ! declare -F v2k_cmd_final_sync >/dev/null 2>&1; then
  v2k_cmd_final_sync() { v2k_cmd_sync final "$@"; }
fi

if ! declare -F v2k_cmd_base_sync >/dev/null 2>&1; then
  v2k_cmd_base_sync() { v2k_cmd_sync base "$@"; }
fi

if ! declare -F v2k_cmd_incr_snapshot >/dev/null 2>&1; then
  v2k_cmd_incr_snapshot() { v2k_cmd_snapshot incr "$@"; }
fi

if ! declare -F v2k_cmd_final_snapshot >/dev/null 2>&1; then
  v2k_cmd_final_snapshot() { v2k_cmd_snapshot final "$@"; }
fi

if ! declare -F v2k_cmd_base_snapshot >/dev/null 2>&1; then
  v2k_cmd_base_snapshot() { v2k_cmd_snapshot base "$@"; }
fi

v2k_parse_arg_string() {
  local s="${1-}"
  local -n _out_arr="${2}"
  _out_arr=()
  [[ -z "${s}" ]] && return 0
  # shellcheck disable=SC2162
  read -r -a _out_arr <<<"${s}"
}

v2k_mktemp_file() {
  local prefix="${1:-v2k}"
  mktemp "/tmp/${prefix}.XXXXXX"
}

v2k_trap_append() {
  local sig="$1"; shift
  local cmd="$*"
  local prev
  prev="$(trap -p "${sig}" 2>/dev/null | sed -E "s/^trap -- '(.*)' ${sig}$/\1/")"
  if [[ -n "${prev}" && "${prev}" != "''" ]]; then
    trap "${prev}; ${cmd}" "${sig}"
  else
    trap "${cmd}" "${sig}"
  fi
}

v2k_write_kv_file() {
  local path="$1"; shift
  local -a kv=( "$@" )
  : > "${path}"
  local line
  for line in "${kv[@]}"; do
    [[ -n "${line}" ]] && echo "${line}" >> "${path}"
  done
  chmod 600 "${path}" 2>/dev/null || true
}
 
v2k_keep_file_in_workdir() {
  local src="$1" dst_basename="$2"
  [[ -n "${V2K_WORKDIR:-}" && -d "${V2K_WORKDIR}" ]] || return 0
  [[ -f "${src}" ]] || return 0
  local dst="${V2K_WORKDIR}/${dst_basename}"
  if [[ ! -e "${dst}" ]]; then
    install -m 600 "${src}" "${dst}" 2>/dev/null || true
  fi
  printf '%s' "${dst}"
}

v2k_validate_vcenter_host() {
  local v="${1-}"
  [[ -n "${v}" ]] || return 1
  if [[ "${v}" =~ :// ]] || [[ "${v}" == */* ]] || [[ "${v}" =~ [[:space:]] ]]; then
    return 1
  fi
  return 0
}

v2k_build_govc_url_from_vcenter_host() {
  local host="${1-}"
  echo "https://${host}/sdk"
}

v2k_generate_run_id() {
  # engine.sh init과 동일한 형식(호환성 유지)
  # YYYYMMDD-HHMMSS-<4bytes hex>
  printf '%s-%s\n' \
    "$(date +%Y%m%d-%H%M%S)" \
    "$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

v2k_output_run_id() {
  local run_id="$1"
  if [[ "${V2K_JSON_OUT:-0}" -eq 1 ]]; then
    printf '{"ok":true,"phase":"run","run_id":"%s","workdir":"%s","manifest":"%s"}\n' \
      "${run_id}" "${V2K_WORKDIR:-}" "${V2K_MANIFEST:-}"
  else
    echo "${run_id}"
  fi
}

v2k_keep_govc_env_in_workdir() {
  local govc_env_path="$1"
  if [[ -n "${V2K_WORKDIR:-}" && -d "${V2K_WORKDIR}" && -f "${govc_env_path}" ]]; then
    local dst="${V2K_WORKDIR}/govc.env"
    if [[ ! -e "${dst}" ]]; then
      install -m 600 "${govc_env_path}" "${dst}" 2>/dev/null || true
    fi
  fi
}
 
v2k_keep_vddk_cred_in_workdir() {
  local cred_path="$1"
  local kept
  kept="$(v2k_keep_file_in_workdir "${cred_path}" "vddk.cred")"
  if [[ -n "${kept}" ]]; then
    export V2K_VDDK_CRED_FILE="${kept}"
  fi
}

v2k_source_kv_env() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  # key=value 파일을 현재 쉘에 로드 + export
  set -a
  # shellcheck disable=SC1090
  source "${path}"
  set +a
}
 
v2k_shell_quote_args() {
  # Join args into a shell-escaped single string (preserve spaces/special chars)
  # Usage: v2k_shell_quote_args out_var_name "${args[@]}"
  local -n _out="${1}"
  shift || true
  local a
  local -a q=()
  for a in "$@"; do
    # %q: shell-escape
    q+=( "$(printf '%q' "${a}")" )
  done
  # space-joined
  _out="${q[*]-}"
}

# -----------------------------------------------------------------------------
# Foreground worker (기존 파이프라인)
# -----------------------------------------------------------------------------
v2k_cmd_run_foreground() {
  v2k_run_defaults

  local shutdown="${V2K_RUN_DEFAULT_SHUTDOWN}"
  local kvm_vm_policy="${V2K_RUN_DEFAULT_KVM_POLICY}"
  local incr_interval="${V2K_RUN_DEFAULT_INCR_INTERVAL}"
  local max_incr="${V2K_RUN_DEFAULT_MAX_INCR}"
  local converge_threshold_sec="${V2K_RUN_DEFAULT_CONVERGE_THRESHOLD_SEC}"
  local insecure="${V2K_RUN_DEFAULT_INSECURE}"
  local no_incr="0"

  local split="${V2K_RUN_DEFAULT_SPLIT}"
  local deadline_sec="${V2K_RUN_DEFAULT_DEADLINE_SEC}"
  local max_incr_phase2="${V2K_RUN_DEFAULT_MAX_INCR_PHASE2}"

  local do_cleanup="1" keep_snapshots="0" keep_workdir="1"
  local default_jobs="" default_chunk="" default_coalesce_gap=""
  local base_args_str="" incr_args_str="" cutover_args_str=""

  local vm="" vcenter_host="" username="" password="" dst=""
  local cred_file_in="" vddk_cred_file_in=""

  local init_mode="govc"
  local init_target_format="" init_target_storage="" init_target_map_json=""
  local init_force_block_device="0"

  # ---------------------------------------------------------------------------
  # 1. Parse Arguments
  # ---------------------------------------------------------------------------
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --foreground) shift 1;;
      --vm) vm="${2:-}"; shift 2;;
      --vcenter) vcenter_host="${2:-}"; shift 2;;
      --username) username="${2:-}"; shift 2;;
      --password) password="${2:-}"; shift 2;;
      --dst) dst="${2:-}"; shift 2;;
      --insecure) insecure="${2:-}"; shift 2;;
      --cred-file) cred_file_in="${2:-}"; shift 2;;
      --vddk-cred-file) vddk_cred_file_in="${2:-}"; shift 2;;
      --shutdown) shutdown="${2:-}"; shift 2;;
      --kvm-vm-policy) kvm_vm_policy="${2:-}"; shift 2;;
      --incr-interval) incr_interval="${2:-}"; shift 2;;
      --max-incr) max_incr="${2:-}"; shift 2;;
      --converge-threshold-sec) converge_threshold_sec="${2:-}"; shift 2;;
      --no-incr) no_incr="1"; shift 1;;
      --split) split="${2-}"; shift 2;;
      --deadline-sec) deadline_sec="${2-}"; shift 2;;
      --max-incr-phase2) max_incr_phase2="${2-}"; shift 2;;
      --no-cleanup) do_cleanup="0"; shift 1;;
      --keep-snapshots) keep_snapshots="1"; shift 1;;
      --keep-workdir) keep_workdir="1"; shift 1;;
      --jobs) default_jobs="${2:-}"; shift 2;;
      --chunk) default_chunk="${2:-}"; shift 2;;
      --coalesce-gap) default_coalesce_gap="${2:-}"; shift 2;;
      --base-args) base_args_str="${2:-}"; shift 2;;
      --incr-args) incr_args_str="${2:-}"; shift 2;;
      --cutover-args) cutover_args_str="${2:-}"; shift 2;;
      --mode) init_mode="${2:-}"; shift 2;;
      --target-format) init_target_format="${2:-}"; shift 2;;
      --target-storage) init_target_storage="${2:-}"; shift 2;;
      --target-map-json) init_target_map_json="${2:-}"; shift 2;;
      --force-block-device) init_force_block_device="1"; shift 1;;
      *) v2k_die "Unknown option for run: $1" ;;
    esac
  done

  # ---------------------------------------------------------------------------
  # 2. Logic Check & Defaults
  # ---------------------------------------------------------------------------
  case "${shutdown}" in manual|guest|poweroff) ;; *) v2k_die "invalid --shutdown: ${shutdown}";; esac
  case "${kvm_vm_policy}" in none|define-only|define-and-start) ;; *) v2k_die "invalid --kvm-vm-policy: ${kvm_vm_policy}";; esac
  [[ "${incr_interval}" =~ ^[0-9]+$ ]] || v2k_die "--incr-interval must be integer seconds"
  [[ "${max_incr}" =~ ^[0-9]+$ ]] || v2k_die "--max-incr must be integer"
  [[ "${converge_threshold_sec}" =~ ^[0-9]+$ ]] || v2k_die "--converge-threshold-sec must be integer seconds"
  [[ "${insecure}" =~ ^[01]$ ]] || v2k_die "--insecure must be 0 or 1"

  case "${split}" in
    full|phase1|phase2) ;;
    *) v2k_die "Invalid --split: ${split}" ;;
  esac
  
  if [[ "${split}" == "phase1" && "${do_cleanup}" == "1" ]]; then
    do_cleanup=0
  fi

  if [[ "${no_incr}" == "0" && "${max_incr}" == "0" ]]; then
    [[ "${V2K_FORCE:-0}" == "1" ]] || v2k_die "--max-incr 0 requires --force"
  fi

  [[ -n "${vm}" ]] || v2k_die "missing --vm"

  # ---------------------------------------------------------------------------
  # 3. Workdir Initialization (Moved BEFORE Validation for Phase 2 Discovery)
  # ---------------------------------------------------------------------------
  if [[ -z "${V2K_RUN_ID:-}" ]]; then
      export V2K_RUN_ID="$(date +%Y%m%d-%H%M%S)"
  fi
  
  if [[ -z "${V2K_WORKDIR:-}" ]]; then
      export V2K_WORKDIR="/var/lib/ablestack-v2k/${vm}/${V2K_RUN_ID}"
  fi
  
  if [[ -z "${V2K_MANIFEST:-}" ]]; then
      export V2K_MANIFEST="${V2K_WORKDIR}/manifest.json"
  fi

  # Create workdir if not exists (important for full run, harmless for phase2)
  mkdir -p "${V2K_WORKDIR}"

  # ---------------------------------------------------------------------------
  # 4. Phase 2 Credential Auto-Discovery
  # ---------------------------------------------------------------------------
  # If we are in phase2, and no creds were passed, look inside the workdir.
  if [[ "${split}" == "phase2" ]]; then
      if [[ -z "${cred_file_in}" && -f "${V2K_WORKDIR}/govc.env" ]]; then
          cred_file_in="${V2K_WORKDIR}/govc.env"
      fi
      if [[ -z "${vddk_cred_file_in}" && -f "${V2K_WORKDIR}/vddk.cred" ]]; then
          vddk_cred_file_in="${V2K_WORKDIR}/vddk.cred"
      fi
  fi

  # ---------------------------------------------------------------------------
  # 5. Validation (Check if creds exist)
  # ---------------------------------------------------------------------------
  if [[ -z "${cred_file_in}" ]]; then
      [[ -n "${vcenter_host}" ]] || v2k_die "missing --vcenter (or --cred-file)"
      [[ -n "${username}" ]] || v2k_die "missing --username (or --cred-file)"
      [[ -n "${password}" ]] || v2k_die "missing --password (or --cred-file)"
  fi
  
  if [[ -z "${dst}" ]]; then dst="/var/lib/libvirt/images/${vm}"; fi

  # init args setup
  local -a init_args=( --vm "${vm}" --vcenter "${vcenter_host}" --dst "${dst}" --mode "${init_mode}" )
  [[ -n "${init_target_format}" ]] && init_args+=( --target-format "${init_target_format}" )
  [[ -n "${init_target_storage}" ]] && init_args+=( --target-storage "${init_target_storage}" )
  [[ -n "${init_target_map_json}" ]] && init_args+=( --target-map-json "${init_target_map_json}" )
  [[ "${init_force_block_device}" == "1" ]] && init_args+=( --force-block-device )

  # -----------------------------------------------------------------------------
  # 6. Credential Setup (Load or Generate)
  # -----------------------------------------------------------------------------
  local tmp_govc_env=""
  local tmp_vddk_cred=""
  local persisted_govc_env="${V2K_WORKDIR}/govc.env"
  local persisted_vddk_cred="${V2K_WORKDIR}/vddk.cred"
  
  local -a cleanup_tmp=()

  # A. GOVC Credential
  if [[ -n "${cred_file_in}" ]]; then
      # User provided or Auto-discovered
      tmp_govc_env="${cred_file_in}"
  else
      # Generate from args
      local govc_url
      govc_url="$(v2k_build_govc_url_from_vcenter_host "${vcenter_host}")"
      tmp_govc_env="$(v2k_mktemp_file "govc.env")"
      v2k_write_kv_file "${tmp_govc_env}" \
        "GOVC_URL=${govc_url}" \
        "GOVC_USERNAME=${username}" \
        "GOVC_PASSWORD=${password}" \
        "GOVC_INSECURE=${insecure}"
      cleanup_tmp+=("${tmp_govc_env}")
  fi

  # B. VDDK Credential
  if [[ -n "${vddk_cred_file_in}" ]]; then
      # User provided or Auto-discovered
      tmp_vddk_cred="${vddk_cred_file_in}"
  else
      # Generate from args if username is present
      if [[ -n "${username}" ]]; then
          tmp_vddk_cred="$(v2k_mktemp_file "vddk.cred")"
          v2k_write_kv_file "${tmp_vddk_cred}" \
            "VDDK_USER=${username}" \
            "VDDK_PASSWORD=${password}" \
            "VDDK_SERVER=${vcenter_host}"
          cleanup_tmp+=("${tmp_vddk_cred}")
      fi
  fi

  # C. Persist to Workdir (Idempotent: cp even if same file, to ensure permission/existence)
  # Only persist if it's NOT already the persisted file to avoid "cp: same file" warning
  if [[ "${tmp_govc_env}" != "${persisted_govc_env}" ]]; then
      install -m 600 "${tmp_govc_env}" "${persisted_govc_env}"
  fi
  
  if [[ -n "${tmp_vddk_cred}" ]]; then
      if [[ "${tmp_vddk_cred}" != "${persisted_vddk_cred}" ]]; then
          install -m 600 "${tmp_vddk_cred}" "${persisted_vddk_cred}"
      fi
      export V2K_VDDK_CRED_FILE="${persisted_vddk_cred}"
      # If auto-discovered, V2K_VDDK_SERVER needs to be loaded or assumed. 
      # Usually loaded from govc.env but let's ensure exported if passed by arg.
      [[ -n "${vcenter_host}" ]] && export V2K_VDDK_SERVER="${vcenter_host}"
      
      init_args+=( --vddk-cred-file "${persisted_vddk_cred}" )
  fi

  # Load Env
  v2k_source_kv_env "${persisted_govc_env}"
  
  # For init, we point to the persisted file
  init_args+=( --cred-file "${persisted_govc_env}" )

  # Cleanup temps
  if (( ${#cleanup_tmp[@]} > 0 )); then
      # shellcheck disable=SC2064
      v2k_trap_append EXIT "rm -f ${cleanup_tmp[*]} 2>/dev/null || true"
  fi

  # -----------------------------------------------------------------------------
  # Failure handling setup
  # -----------------------------------------------------------------------------
  local __v2k_cleanup_done=0
  local __v2k_failed=0
  v2k_trap_append ERR '
    __v2k_failed=1
    if declare -F v2k_event >/dev/null 2>&1; then
      v2k_event ERROR "orchestrator" "" "run_failed" "{\"where\":\"v2k_cmd_run_foreground\",\"line\":${LINENO}}"
    fi
    if declare -F v2k_event_storage_snapshot >/dev/null 2>&1; then
      v2k_event_storage_snapshot "on_error_pre_cleanup" || true
    fi
    if [[ "${do_cleanup}" == "1" && "${__v2k_cleanup_done}" -eq 0 ]]; then
      __v2k_cleanup_done=1
      local -a __cleanup_args=()
      [[ "${keep_snapshots}" == "1" ]] && __cleanup_args+=(--keep-snapshots)
      [[ "${keep_workdir}" == "1" ]] && __cleanup_args+=(--keep-workdir)
      v2k_cmd_cleanup "${__cleanup_args[@]}" || true
      if declare -F v2k_event_storage_snapshot >/dev/null 2>&1; then
        v2k_event_storage_snapshot "on_error_post_cleanup" || true
      fi
    fi
  '

  local -a sync_defaults=()
  [[ -n "${default_jobs}" ]] && sync_defaults+=(--jobs "${default_jobs}")
  [[ -n "${default_chunk}" ]] && sync_defaults+=(--chunk "${default_chunk}")
  [[ -n "${default_coalesce_gap}" ]] && sync_defaults+=(--coalesce-gap "${default_coalesce_gap}")

  local -a base_extra=() incr_extra=() cutover_extra=()
  v2k_parse_arg_string "${base_args_str}" base_extra
  v2k_parse_arg_string "${incr_args_str}" incr_extra
  v2k_parse_arg_string "${cutover_args_str}" cutover_extra

  local winpe_bootstrap_auto="${V2K_RUN_WINPE_BOOTSTRAP_AUTO:-1}"

  # Pipeline start
  local skip_init=0
  local skip_cbt=0
  local skip_base=0
  local have_manifest=0
  [[ -f "${V2K_MANIFEST}" ]] && have_manifest=1

  if [[ "${split}" == "phase2" ]]; then
    if [[ "${have_manifest}" -ne 1 ]]; then
      v2k_die "split=phase2 requires existing manifest at ${V2K_MANIFEST}"
    fi
    if ! v2k_manifest_split_is_done "${V2K_MANIFEST}" "phase1"; then
      v2k_die "split=phase2 requires split=phase1 completion marker in manifest"
    fi
    
    # Reload environment in Phase 2
    if [[ -f "${persisted_govc_env}" ]]; then
        v2k_source_kv_env "${persisted_govc_env}"
    fi
    if [[ -f "${persisted_vddk_cred}" ]]; then
        export V2K_VDDK_CRED_FILE="${persisted_vddk_cred}"
        # VDDK Server might be needed from govc.env if not set
        if [[ -z "${V2K_VDDK_SERVER:-}" ]]; then
             export V2K_VDDK_SERVER="${GOVC_URL_HOST:-${GOVC_URL:-}}"
             # Remove https:// prefix if exists for VDDK_SERVER just in case, though usually govc handles it
             V2K_VDDK_SERVER="${V2K_VDDK_SERVER#*://}"
             V2K_VDDK_SERVER="${V2K_VDDK_SERVER%%/*}"
        fi
    fi

    skip_init=1
    skip_cbt=1
    skip_base=1
    v2k_event INFO run "" skip_base_phase2 "{\"manifest\":\"${V2K_MANIFEST}\"}"
  fi

  if [[ "${skip_init}" -eq 0 ]]; then
    v2k_cmd_init "${init_args[@]}"
  fi

  if [[ "${skip_cbt}" -eq 0 ]]; then
    v2k_cmd_cbt enable
  fi

  if [[ "${skip_base}" -eq 0 ]]; then
    v2k_cmd_snapshot base
    v2k_cmd_sync base "${sync_defaults[@]}" "${base_extra[@]}" 
    v2k_manifest_phase_done "${V2K_MANIFEST}" "base"
  fi

  # Phase1 boundary
  if [[ "${split}" == "phase1" ]]; then
    v2k_event INFO "run" "" "phase" "{\"which\":\"phase1\",\"action\":\"enter\"}"
    v2k_emit_progress_event "run" "phase1:incr1_snapshot"
    v2k_cmd_snapshot "incr"
    v2k_emit_progress_event "run" "phase1:incr1_sync"
    v2k_cmd_incr_sync
    v2k_manifest_phase_done "${V2K_MANIFEST}" "incr_sync"
    
    v2k_manifest_runtime_set "${V2K_MANIFEST}" ".runtime.split.phase1.done" "true"
    if declare -F v2k_manifest_mark_split_done >/dev/null; then
       v2k_manifest_mark_split_done "${V2K_MANIFEST}" "phase1" 2>/dev/null || true
    fi
    
    v2k_manifest_runtime_set "${V2K_MANIFEST}" ".runtime.progress" "{\"percent\":$(v2k_progress_percent_from_manifest "${V2K_MANIFEST}"),\"last_step\":\"phase1_done\"}"
    v2k_emit_progress_event "run" "phase1:done"
    v2k_event INFO "run" "" "phase" "{\"which\":\"phase1\",\"action\":\"exit\"}"
    echo "[run] split=phase1 completed (run_id=${V2K_RUN_ID}). Re-run with --split=phase2 to continue."
    return 0
  fi

  # Incr loop
  if [[ "${no_incr}" == "0" ]]; then
    local iter=0 converged=0
    local incr_failed=0
    while :; do
      iter=$((iter + 1))
      if [[ "${max_incr}" != "0" ]] && (( iter > max_incr )); then break; fi

      local t0 t1 elapsed
      t0="$(date +%s)"
      v2k_cmd_snapshot incr

      if ! v2k_cmd_sync incr "${sync_defaults[@]}" "${incr_extra[@]}"; then
        incr_failed=1
        if declare -F v2k_event >/dev/null 2>&1; then
          v2k_event WARN "orchestrator" "" "incr_failed_continue_to_cutover" \
            "{\"iter\":${iter}}"
        fi
        break
      fi

      t1="$(date +%s)"
      elapsed=$((t1 - t0))

      if [[ "${split}" == "phase2" ]]; then
        if [[ "${elapsed}" -le "${deadline_sec}" ]]; then
          v2k_manifest_runtime_set "${V2K_MANIFEST}" ".runtime.sync_within_deadline" "true"
          converged=1
          break
        else
          v2k_manifest_runtime_set "${V2K_MANIFEST}" ".runtime.sync_within_deadline" "false"
        fi

        if [[ "${iter}" -ge "${max_incr_phase2}" ]]; then
          v2k_event WARN "run" "" "deadline" "{\"reason\":\"max_incr_phase2_reached\",\"iter\":${iter},\"deadline_sec\":${deadline_sec}}"
          break
        fi
      else
        if [[ "${converge_threshold_sec}" != "0" ]] && (( elapsed <= converge_threshold_sec )); then
          converged=1
          if declare -F v2k_event >/dev/null 2>&1; then
            v2k_event INFO "orchestrator" "" "incr_converged_stop" \
              "{\"iter\":${iter},\"elapsed_sec\":${elapsed},\"threshold_sec\":${converge_threshold_sec}}"
          fi
          break
        fi
      fi

      if [[ "${max_incr}" != "0" ]] && (( iter >= max_incr )); then break; fi
      sleep "${incr_interval}"
    done
 
    if [[ "${incr_failed}" -eq 1 ]]; then
      if declare -F v2k_event >/dev/null 2>&1; then
        v2k_event INFO "orchestrator" "" "incr_aborted_proceed_cutover" \
          "{\"iter\":${iter}}"
      fi
    fi

    if declare -F v2k_event >/dev/null 2>&1; then
      if [[ "${converged}" -eq 0 ]]; then
        v2k_event INFO "orchestrator" "" "incr_loop_end" "{\"iter\":${iter}}"
      fi
    fi
  fi

  if [[ "${split}" == "phase2" ]]; then
    local within_deadline
    within_deadline="$(jq -r '.runtime.sync_within_deadline // false' "${V2K_MANIFEST}" 2>/dev/null || echo false)"
    if [[ "${within_deadline}" != "true" ]]; then
      v2k_event WARN "run" "" "cutover_gate" "{\"reason\":\"deadline_not_met\"}"
      echo "[run] split=phase2 stopped without cutover (deadline not met). Re-run phase2."
      return 3
    fi
  fi

  local is_windows=0
  if v2k_manifest_is_windows "${V2K_MANIFEST}"; then
    is_windows=1
  fi

  local -a cutover_args=(--shutdown "${shutdown}")

  if [[ "${is_windows}" -eq 1 && "${V2K_RUN_WINPE_BOOTSTRAP_AUTO}" == "1" ]]; then
    if [[ "${kvm_vm_policy}" == "none" ]]; then
      kvm_vm_policy="define-and-start"
    fi
    cutover_args+=(--winpe-bootstrap)
  fi

  case "${kvm_vm_policy}" in
    none) ;;
    define-only) cutover_args+=(--define-only) ;;
    define-and-start) cutover_args+=(--start) ;;
  esac

  if [[ "${winpe_bootstrap_auto}" == "1" ]]; then
    if declare -F v2k_manifest_is_windows >/dev/null 2>&1 && v2k_manifest_is_windows "${V2K_MANIFEST}"; then
      local winpe_explicit=0
      local a
      for a in "${cutover_extra[@]}"; do
        case "${a}" in
          --winpe-bootstrap|--winpe-iso|--virtio-iso|--winpe-timeout)
            winpe_explicit=1
            ;;
        esac
      done
      if [[ "${winpe_explicit}" -eq 0 ]]; then
        cutover_args+=(--winpe-bootstrap)
      fi
    fi
  fi

  cutover_args+=("${cutover_extra[@]}")

  v2k_cmd_cutover "${cutover_args[@]}"

  # Cleanup
  if [[ "${do_cleanup}" == "1" ]]; then
    local -a cleanup_args=()
    [[ "${keep_snapshots}" == "1" ]] && cleanup_args+=(--keep-snapshots)
    [[ "${keep_workdir}" == "1" ]] && cleanup_args+=(--keep-workdir)
    if declare -F v2k_event_storage_snapshot >/dev/null 2>&1; then
      v2k_event_storage_snapshot "pre_cleanup" || true
    fi
    __v2k_cleanup_done=1
    v2k_cmd_cleanup "${cleanup_args[@]}"
    if declare -F v2k_event_storage_snapshot >/dev/null 2>&1; then
      v2k_event_storage_snapshot "post_cleanup" || true
    fi
  fi

  if [[ "${split}" == "phase2" ]]; then
    v2k_manifest_runtime_set "${V2K_MANIFEST}" ".runtime.split.phase2.done" "true"
  fi
}

# -----------------------------------------------------------------------------
# Background launcher (default): run_id 반환 후 워커를 nohup로 분리 실행
# -----------------------------------------------------------------------------
v2k_cmd_run() {
  # If user explicitly wants foreground
  local foreground=0
  local -a args=( "$@" )
  local i
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--foreground" ]]; then
      foreground=1
      break
    fi
  done
  if [[ "${foreground}" -eq 1 ]]; then
    v2k_cmd_run_foreground "$@"
    return 0
  fi

  # We need vm name early to build default workdir.
  local vm=""
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--vm" ]]; then
      vm="${args[$((i+1))]:-}"
      break
    fi
  done
  [[ -n "${vm}" ]] || v2k_die "run(background) requires --vm to allocate workdir/run_id"

  # Pre-generate run_id/workdir so we can return immediately and keep logs isolated
  if [[ -z "${V2K_RUN_ID:-}" ]]; then
    V2K_RUN_ID="$(v2k_generate_run_id)"
    export V2K_RUN_ID
  fi
  if [[ -z "${V2K_WORKDIR:-}" ]]; then
    V2K_WORKDIR="/var/lib/ablestack-v2k/${vm}/${V2K_RUN_ID}"
    export V2K_WORKDIR
  fi
  mkdir -p "${V2K_WORKDIR}"

  if [[ -z "${V2K_MANIFEST:-}" ]]; then
    V2K_MANIFEST="${V2K_WORKDIR}/manifest.json"
    export V2K_MANIFEST
  fi
  if [[ -z "${V2K_EVENTS_LOG:-}" ]]; then
    V2K_EVENTS_LOG="${V2K_WORKDIR}/events.log"
    export V2K_EVENTS_LOG
  fi

  # Worker script
  local worker="${V2K_WORKDIR}/run.worker.sh"
  local outlog="${V2K_WORKDIR}/run.out"
 
  # Preserve original args safely (avoid word-splitting/globbing in worker heredoc)
  local args_quoted=""
  v2k_shell_quote_args args_quoted "${args[@]}"

  cat > "${worker}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# preserve runtime flags from parent (global flags)
export V2K_JSON_OUT="${V2K_JSON_OUT:-0}"
export V2K_DRY_RUN="${V2K_DRY_RUN:-0}"
export V2K_RESUME="${V2K_RESUME:-0}"
export V2K_FORCE="${V2K_FORCE:-0}"

# preserve paths
export V2K_RUN_ID="${V2K_RUN_ID}"
export V2K_WORKDIR="${V2K_WORKDIR}"
export V2K_MANIFEST="${V2K_MANIFEST}"
export V2K_EVENTS_LOG="${V2K_EVENTS_LOG}"

# NOTE: This worker runs in a fresh shell, so engine+orchestrator must already be loaded by main CLI.
# We invoke ablestack_v2k itself in foreground mode.

exec "\$(command -v ablestack_v2k)" --workdir "${V2K_WORKDIR}" --run-id "${V2K_RUN_ID}" --manifest "${V2K_MANIFEST}" --log "${V2K_EVENTS_LOG}" run --foreground ${args_quoted}
EOF
  chmod 700 "${worker}"

  # Detach (nohup + background)
  # - stdout/stderr to run.out
  # - parent returns immediately
  nohup bash "${worker}" >> "${outlog}" 2>&1 < /dev/null & disown || true

  v2k_output_run_id "${V2K_RUN_ID}"
}
