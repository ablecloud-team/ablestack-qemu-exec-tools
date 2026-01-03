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

V2K_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/v2k/logging.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/v2k/manifest.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/v2k/vmware_govc.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/v2k/transfer_base.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/v2k/transfer_patch.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/v2k/target_libvirt.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/v2k/verify.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/v2k/nbd_utils.sh"


v2k_set_paths() {
  local workdir_in="${1:-}"
  local run_id_in="${2:-}"
  local manifest_in="${3:-}"
  local log_in="${4:-}"

  export V2K_WORKDIR="${workdir_in}"
  export V2K_RUN_ID="${run_id_in}"
  export V2K_MANIFEST="${manifest_in}"
  export V2K_EVENTS_LOG="${log_in}"
}

v2k_require_manifest() {
  if [[ -z "${V2K_MANIFEST:-}" ]]; then
    echo "Manifest path not set" >&2
    exit 2
  fi
  if [[ ! -f "${V2K_MANIFEST}" ]]; then
    echo "Manifest not found: ${V2K_MANIFEST}" >&2
    exit 2
  fi
}

v2k_cmd_init() {
  local vm="" vcenter="" dst="" mode="govc" cred_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vm) vm="${2:-}"; shift 2;;
      --vcenter) vcenter="${2:-}"; shift 2;;
      --dst) dst="${2:-}"; shift 2;;
      --mode) mode="${2:-}"; shift 2;;
      --cred-file) cred_file="${2:-}"; shift 2;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  [[ -n "${vm}" && -n "${vcenter}" && -n "${dst}" ]] || { echo "init requires --vm --vcenter --dst" >&2; exit 2; }
  [[ "${mode}" == "govc" ]] || { echo "Only --mode govc is supported in v1" >&2; exit 2; }

  if [[ -n "${cred_file}" ]]; then
    v2k_vmware_load_cred_file "${cred_file}"
  fi

  if [[ -z "${V2K_RUN_ID:-}" ]]; then
    V2K_RUN_ID="$(date +%Y%m%d-%H%M%S)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    export V2K_RUN_ID
  fi

  if [[ -z "${V2K_WORKDIR:-}" ]]; then
    # Workdir default: /var/lib/ablestack-v2k/<vm>/<run_id>
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

  v2k_event INFO "init" "" "phase_start" "{\"vm\":\"${vm}\",\"vcenter\":\"${vcenter}\",\"dst\":\"${dst}\",\"mode\":\"${mode}\"}"

  local inv_json
  inv_json="$(v2k_vmware_inventory_json "${vm}" "${vcenter}")"

  v2k_manifest_init "${V2K_MANIFEST}" "${V2K_RUN_ID}" "${V2K_WORKDIR}" "${vm}" "${vcenter}" "${mode}" "${dst}" "${inv_json}"

  v2k_event INFO "init" "" "phase_done" "{\"manifest\":\"${V2K_MANIFEST}\",\"workdir\":\"${V2K_WORKDIR}\"}"

  v2k_json_or_text_ok "init" "{\"run_id\":\"${V2K_RUN_ID}\",\"workdir\":\"${V2K_WORKDIR}\",\"manifest\":\"${V2K_MANIFEST}\"}" \
    "Initialized. run_id=${V2K_RUN_ID} workdir=${V2K_WORKDIR}"
}

v2k_cmd_cbt() {
  v2k_require_manifest
  local action="${1:-}"
  case "${action}" in
    enable)
      v2k_event INFO "cbt_enable" "" "phase_start" "{}"
      v2k_vmware_cbt_enable_all "${V2K_MANIFEST}"
      v2k_manifest_phase_done "${V2K_MANIFEST}" "cbt_enable"
      v2k_event INFO "cbt_enable" "" "phase_done" "{}"
      v2k_json_or_text_ok "cbt.enable" "{}" "CBT enabled (requested) and verified."
      ;;
    status)
      local s
      s="$(v2k_vmware_cbt_status_all "${V2K_MANIFEST}")"
      v2k_json_or_text_ok "cbt.status" "${s}" "${s}"
      ;;
    *)
      echo "Usage: cbt enable|status" >&2
      exit 2
      ;;
  esac
}

v2k_cmd_snapshot() {
  v2k_require_manifest
  local which="${1:-}" name=""
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="${2:-}"; shift 2;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  case "${which}" in
    base|incr|final)
      if [[ -z "${name}" ]]; then
        name="migr-${which}-$(date +%Y%m%d-%H%M%S)"
      fi
      v2k_event INFO "snapshot.${which}" "" "phase_start" "{\"name\":\"${name}\"}"
      v2k_vmware_snapshot_create "${V2K_MANIFEST}" "${which}" "${name}"
      v2k_manifest_snapshot_set "${V2K_MANIFEST}" "${which}" "${name}"
      v2k_event INFO "snapshot.${which}" "" "phase_done" "{\"name\":\"${name}\"}"
      v2k_json_or_text_ok "snapshot.${which}" "{\"name\":\"${name}\"}" "Snapshot created: ${name}"
      ;;
    *)
      echo "Usage: snapshot base|incr|final [--name X]" >&2
      exit 2
      ;;
  esac
}

v2k_cmd_sync() {
  v2k_require_manifest
  local which="${1:-}" jobs=1 coalesce_gap=$((1024*1024)) chunk=$((4*1024*1024))
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs) jobs="${2:-}"; shift 2;;
      --coalesce-gap) coalesce_gap="${2:-}"; shift 2;;
      --chunk) chunk="${2:-}"; shift 2;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  case "${which}" in
    base)
      v2k_event INFO "sync.base" "" "phase_start" "{\"jobs\":${jobs}}"
      v2k_transfer_base_all "${V2K_MANIFEST}" "${jobs}"
      v2k_manifest_phase_done "${V2K_MANIFEST}" "base_sync"
      v2k_event INFO "sync.base" "" "phase_done" "{}"
      v2k_json_or_text_ok "sync.base" "{}" "Base sync done."
      ;;
    incr|final)
      v2k_event INFO "sync.${which}" "" "phase_start" "{\"jobs\":${jobs},\"coalesce_gap\":${coalesce_gap},\"chunk\":${chunk}}"
      v2k_transfer_patch_all "${V2K_MANIFEST}" "${which}" "${jobs}" "${coalesce_gap}" "${chunk}"
      v2k_manifest_phase_done "${V2K_MANIFEST}" "${which}_sync"
      v2k_event INFO "sync.${which}" "" "phase_done" "{}"
      v2k_json_or_text_ok "sync.${which}" "{}" "${which} sync done."
      ;;
    *)
      echo "Usage: sync base|incr|final [--jobs N] [--coalesce-gap BYTES] [--chunk BYTES]" >&2
      exit 2
      ;;
  esac
}

v2k_cmd_verify() {
  v2k_require_manifest
  local mode="quick" samples=64
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) mode="${2:-}"; shift 2;;
      --samples) samples="${2:-}"; shift 2;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  v2k_event INFO "verify" "" "phase_start" "{\"mode\":\"${mode}\",\"samples\":${samples}}"
  local out
  out="$(v2k_verify "${V2K_MANIFEST}" "${mode}" "${samples}")"
  v2k_event INFO "verify" "" "phase_done" "{}"
  v2k_json_or_text_ok "verify" "${out}" "${out}"
}

v2k_cmd_cutover() {
  v2k_require_manifest
  local shutdown="manual" define_only=0 start_vm=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shutdown) shutdown="${2:-}"; shift 2;;
      --define-only) define_only=1; shift 1;;
      --start) start_vm=1; shift 1;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  # As approved: default flow is shutdown -> final snapshot -> final sync
  v2k_event INFO "cutover" "" "phase_start" "{\"shutdown\":\"${shutdown}\"}"

  if [[ "${shutdown}" == "guest" ]]; then
    # Placeholder hook: in v1 we do not force guest shutdown automatically.
    v2k_event INFO "cutover" "" "shutdown_hook" "{\"note\":\"guest shutdown hook not implemented in v1; do manual shutdown or extend.\"}"
  fi

  echo "Cutover requires VM to be shutdown on VMware side. Confirm shutdown before proceeding." >&2

  # Always create final snapshot as default
  local name="migr-final-$(date +%Y%m%d-%H%M%S)"
  v2k_vmware_snapshot_create "${V2K_MANIFEST}" "final" "${name}"
  v2k_manifest_snapshot_set "${V2K_MANIFEST}" "final" "${name}"

  # final sync
  v2k_transfer_patch_all "${V2K_MANIFEST}" "final" 1 $((1024*1024)) $((4*1024*1024))

  # libvirt define
  if [[ "${define_only}" -eq 1 || "${start_vm}" -eq 1 ]]; then
    local xml_path
    xml_path="$(v2k_target_generate_libvirt_xml "${V2K_MANIFEST}")"
    v2k_target_define_libvirt "${xml_path}"
    if [[ "${start_vm}" -eq 1 ]]; then
      v2k_target_start_vm "${V2K_MANIFEST}"
    fi
  fi

  v2k_manifest_phase_done "${V2K_MANIFEST}" "cutover"
  v2k_event INFO "cutover" "" "phase_done" "{}"
  v2k_json_or_text_ok "cutover" "{}" "Cutover done (final snapshot + final sync)."
}

v2k_cmd_cleanup() {
  v2k_require_manifest
  local keep_snapshots=0 keep_workdir=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-snapshots) keep_snapshots=1; shift 1;;
      --keep-workdir) keep_workdir=1; shift 1;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done
  v2k_event INFO "cleanup" "" "phase_start" "{\"keep_snapshots\":${keep_snapshots},\"keep_workdir\":${keep_workdir}}"
  v2k_transfer_cleanup
  if [[ "${keep_snapshots}" -eq 0 ]]; then
    v2k_vmware_snapshot_cleanup "${V2K_MANIFEST}"
  fi
  if [[ "${keep_workdir}" -eq 0 ]]; then
    rm -rf "${V2K_WORKDIR}"
  fi
  v2k_event INFO "cleanup" "" "phase_done" "{}"
  v2k_json_or_text_ok "cleanup" "{}" "Cleanup done."
}

v2k_cmd_status() {
  v2k_require_manifest
  local summary
  summary="$(v2k_manifest_status_summary "${V2K_MANIFEST}" "${V2K_EVENTS_LOG:-}")"
  v2k_json_or_text_ok "status" "${summary}" "${summary}"
}

v2k_json_or_text_ok() {
  local phase="$1"
  local json_payload="$2"
  local text="$3"
  if [[ "${V2K_JSON_OUT:-0}" -eq 1 ]]; then
    printf '{"ok":true,"phase":"%s","run_id":"%s","workdir":"%s","manifest":"%s","summary":%s}\n' \
      "${phase}" "${V2K_RUN_ID:-}" "${V2K_WORKDIR:-}" "${V2K_MANIFEST:-}" "${json_payload}"
  else
    echo "${text}"
  fi
}
