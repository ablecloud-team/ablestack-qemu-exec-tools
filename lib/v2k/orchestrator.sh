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

v2k_die() { echo "ERROR: $*" >&2; exit 2; }

v2k_parse_arg_string() {
  local s="${1-}"
  local -n _out_arr="${2}"
  _out_arr=()
  [[ -z "${s}" ]] && return 0
  # shellcheck disable=SC2162
  read -r -a _out_arr <<<"${s}"
}

v2k_run_defaults() {
  V2K_RUN_DEFAULT_SHUTDOWN="${V2K_RUN_DEFAULT_SHUTDOWN:-manual}"
  V2K_RUN_DEFAULT_KVM_POLICY="${V2K_RUN_DEFAULT_KVM_POLICY:-none}"
  V2K_RUN_DEFAULT_INCR_INTERVAL="${V2K_RUN_DEFAULT_INCR_INTERVAL:-10}"
  V2K_RUN_DEFAULT_MAX_INCR="${V2K_RUN_DEFAULT_MAX_INCR:-6}"
  V2K_RUN_DEFAULT_CONVERGE_THRESHOLD_SEC="${V2K_RUN_DEFAULT_CONVERGE_THRESHOLD_SEC:-120}"
  V2K_RUN_DEFAULT_INSECURE="${V2K_RUN_DEFAULT_INSECURE:-1}"
}

v2k_mktemp_file() {
  local prefix="${1:-v2k}"
  mktemp "/tmp/${prefix}.XXXXXX"
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
  date +%Y%m%d-%H%M%S
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

v2k_source_kv_env() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  # key=value 파일을 현재 쉘에 로드 + export
  set -a
  # shellcheck disable=SC1090
  source "${path}"
  set +a
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

  local do_cleanup="1" keep_snapshots="0" keep_workdir="0"
  local default_jobs="" default_chunk="" default_coalesce_gap=""
  local base_args_str="" incr_args_str="" cutover_args_str=""

  local vm="" vcenter_host="" username="" password="" dst=""

  local init_mode="govc"
  local init_target_format="" init_target_storage="" init_target_map_json=""
  local init_force_block_device="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      # control
      --foreground) shift 1;; # already in foreground

      # minimal inputs
      --vm) vm="${2:-}"; shift 2;;
      --vcenter) vcenter_host="${2:-}"; shift 2;;
      --username) username="${2:-}"; shift 2;;
      --password) password="${2:-}"; shift 2;;
      --dst) dst="${2:-}"; shift 2;;
      --insecure) insecure="${2:-}"; shift 2;;

      # orchestrator options
      --shutdown) shutdown="${2:-}"; shift 2;;
      --kvm-vm-policy) kvm_vm_policy="${2:-}"; shift 2;;
      --incr-interval) incr_interval="${2:-}"; shift 2;;
      --max-incr) max_incr="${2:-}"; shift 2;;
      --converge-threshold-sec) converge_threshold_sec="${2:-}"; shift 2;;
      --no-incr) no_incr="1"; shift 1;;

      # cleanup controls
      --no-cleanup) do_cleanup="0"; shift 1;;
      --keep-snapshots) keep_snapshots="1"; shift 1;;
      --keep-workdir) keep_workdir="1"; shift 1;;

      # sync defaults
      --jobs) default_jobs="${2:-}"; shift 2;;
      --chunk) default_chunk="${2:-}"; shift 2;;
      --coalesce-gap) default_coalesce_gap="${2:-}"; shift 2;;

      # extras
      --base-args) base_args_str="${2:-}"; shift 2;;
      --incr-args) incr_args_str="${2:-}"; shift 2;;
      --cutover-args) cutover_args_str="${2:-}"; shift 2;;

      # init knobs supported by engine.sh init
      --mode) init_mode="${2:-}"; shift 2;;
      --target-format) init_target_format="${2:-}"; shift 2;;
      --target-storage) init_target_storage="${2:-}"; shift 2;;
      --target-map-json) init_target_map_json="${2:-}"; shift 2;;
      --force-block-device) init_force_block_device="1"; shift 1;;

      *)
        v2k_die "Unknown option for run: $1"
        ;;
    esac
  done

  case "${shutdown}" in manual|guest|poweroff) ;; *) v2k_die "invalid --shutdown: ${shutdown}";; esac
  case "${kvm_vm_policy}" in none|define-only|define-and-start) ;; *) v2k_die "invalid --kvm-vm-policy: ${kvm_vm_policy}";; esac
  [[ "${incr_interval}" =~ ^[0-9]+$ ]] || v2k_die "--incr-interval must be integer seconds"
  [[ "${max_incr}" =~ ^[0-9]+$ ]] || v2k_die "--max-incr must be integer (0 means unlimited)"
  [[ "${converge_threshold_sec}" =~ ^[0-9]+$ ]] || v2k_die "--converge-threshold-sec must be integer seconds"
  [[ "${insecure}" =~ ^[01]$ ]] || v2k_die "--insecure must be 0 or 1"

  if [[ "${no_incr}" == "0" && "${max_incr}" == "0" ]]; then
    [[ "${V2K_FORCE:-0}" == "1" ]] || v2k_die "--max-incr 0 requires --force"
  fi

  [[ -n "${vm}" ]] || v2k_die "missing --vm"
  [[ -n "${vcenter_host}" ]] || v2k_die "missing --vcenter"
  v2k_validate_vcenter_host "${vcenter_host}" || v2k_die "--vcenter must be host/ip only (no scheme/path)"
  [[ -n "${username}" ]] || v2k_die "missing --username"
  [[ -n "${password}" ]] || v2k_die "missing --password"
  if [[ -z "${dst}" ]]; then dst="/var/lib/libvirt/images/${vm}"; fi

  # init args for engine.sh v2k_cmd_init
  local -a init_args=( --vm "${vm}" --vcenter "${vcenter_host}" --dst "${dst}" --mode "${init_mode}" )
  [[ -n "${init_target_format}" ]] && init_args+=( --target-format "${init_target_format}" )
  [[ -n "${init_target_storage}" ]] && init_args+=( --target-storage "${init_target_storage}" )
  [[ -n "${init_target_map_json}" ]] && init_args+=( --target-map-json "${init_target_map_json}" )
  [[ "${init_force_block_device}" == "1" ]] && init_args+=( --force-block-device )

  # Create govc.env + vddk.cred
  local govc_url tmp_govc_env tmp_vddk_cred
  govc_url="$(v2k_build_govc_url_from_vcenter_host "${vcenter_host}")"
  tmp_govc_env="$(v2k_mktemp_file "govc.env")"
  tmp_vddk_cred="$(v2k_mktemp_file "vddk.cred")"
  local -a cleanup_tmp=( "${tmp_govc_env}" "${tmp_vddk_cred}" )
  trap 'for f in "${cleanup_tmp[@]:-}"; do [[ -n "${f}" && -f "${f}" ]] && rm -f "${f}" || true; done' EXIT

  v2k_write_kv_file "${tmp_govc_env}" \
    "GOVC_URL=${govc_url}" \
    "GOVC_USERNAME=${username}" \
    "GOVC_PASSWORD=${password}" \
    "GOVC_INSECURE=${insecure}"

  v2k_write_kv_file "${tmp_vddk_cred}" \
    "VDDK_USER=${username}" \
    "VDDK_PASSWORD=${password}" \
    "VDDK_SERVER=${vcenter_host}"

    # ✅ 중요: govc 단계들이 env 기반으로 동작할 수 있으므로 즉시 환경에 반영
    v2k_source_kv_env "${tmp_govc_env}"

    # ✅ manifest에 vddk cred 경로를 남기고, 후속 단계에서 참조 가능하도록 env에도 설정
    export V2K_VDDK_SERVER="${vcenter_host}"
    export V2K_VDDK_CRED_FILE="${tmp_vddk_cred}"

  init_args+=( --cred-file "${tmp_govc_env}" --vddk-cred-file "${tmp_vddk_cred}" )

  # sync defaults + extras
  local -a sync_defaults=()
  [[ -n "${default_jobs}" ]] && sync_defaults+=(--jobs "${default_jobs}")
  [[ -n "${default_chunk}" ]] && sync_defaults+=(--chunk "${default_chunk}")
  [[ -n "${default_coalesce_gap}" ]] && sync_defaults+=(--coalesce-gap "${default_coalesce_gap}")

  local -a base_extra=() incr_extra=() cutover_extra=()
  v2k_parse_arg_string "${base_args_str}" base_extra
  v2k_parse_arg_string "${incr_args_str}" incr_extra
  v2k_parse_arg_string "${cutover_args_str}" cutover_extra

  # Pipeline
  v2k_cmd_init "${init_args[@]}"
  v2k_keep_govc_env_in_workdir "${tmp_govc_env}" || true

  v2k_cmd_cbt enable

  v2k_cmd_snapshot base
  v2k_cmd_sync base "${sync_defaults[@]}" "${base_extra[@]}"

  if [[ "${no_incr}" == "0" ]]; then
    local iter=0 converged=0
    while :; do
      iter=$((iter + 1))
      if [[ "${max_incr}" != "0" ]] && (( iter > max_incr )); then break; fi

      local t0 t1 elapsed
      t0="$(date +%s)"
      v2k_cmd_snapshot incr
      v2k_cmd_sync incr "${sync_defaults[@]}" "${incr_extra[@]}"
      t1="$(date +%s)"
      elapsed=$((t1 - t0))

      if [[ "${converge_threshold_sec}" != "0" ]] && (( elapsed <= converge_threshold_sec )); then
        converged=1
        if declare -F v2k_event >/dev/null 2>&1; then
          v2k_event INFO "orchestrator" "" "incr_converged_stop" \
            "{\"iter\":${iter},\"elapsed_sec\":${elapsed},\"threshold_sec\":${converge_threshold_sec}}"
        fi
        break
      fi

      if [[ "${max_incr}" != "0" ]] && (( iter >= max_incr )); then break; fi
      sleep "${incr_interval}"
    done

    if declare -F v2k_event >/dev/null 2>&1; then
      if [[ "${converged}" -eq 0 ]]; then
        v2k_event INFO "orchestrator" "" "incr_loop_end" "{\"iter\":${iter}}"
      fi
    fi
  fi

  local -a cutover_args=(--shutdown "${shutdown}")
  case "${kvm_vm_policy}" in
    none) ;;
    define-only) cutover_args+=(--define-only) ;;
    define-and-start) cutover_args+=(--start) ;;
  esac
  cutover_args+=("${cutover_extra[@]}")

  v2k_cmd_cutover "${cutover_args[@]}"

  # Cleanup (after successful cutover)
  if [[ "${do_cleanup}" == "1" ]]; then
    local -a cleanup_args=()
    [[ "${keep_snapshots}" == "1" ]] && cleanup_args+=(--keep-snapshots)
    [[ "${keep_workdir}" == "1" ]] && cleanup_args+=(--keep-workdir)
    v2k_cmd_cleanup "${cleanup_args[@]}"
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

exec "\$(command -v ablestack_v2k)" --workdir "${V2K_WORKDIR}" --run-id "${V2K_RUN_ID}" --manifest "${V2K_MANIFEST}" --log "${V2K_EVENTS_LOG}" run --foreground ${args[*]}
EOF
  chmod 700 "${worker}"

  # Detach (nohup + background)
  # - stdout/stderr to run.out
  # - parent returns immediately
  nohup bash "${worker}" >> "${outlog}" 2>&1 < /dev/null & disown || true

  v2k_output_run_id "${V2K_RUN_ID}"
}
