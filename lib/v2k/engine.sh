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

V2K_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/logging.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/manifest.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/vmware_govc.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/transfer_base.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/transfer_patch.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/target_libvirt.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/verify.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/nbd_utils.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/v2k_target_device.sh"

v2k_set_paths() {
  local workdir_in="${1:-}"
  local run_id_in="${2:-}"
  local manifest_in="${3:-}"
  local log_in="${4:-}"

  # ------------------------------------------------------------
  # Apply defaults as documented in ablestack_v2k usage:
  #   --manifest default: <workdir>/manifest.json
  #   --log      default: <workdir>/events.log
  #
  # Also support:
  #   If only --manifest is given, infer workdir = dirname(manifest)
  #
  # IMPORTANT:
  #   Do NOT auto-generate workdir when empty here.
  #   init command already generates workdir/run-id/manifest/log.
  # ------------------------------------------------------------

  # Normalize empty/"null"
  if [[ "${workdir_in}" == "null" ]]; then workdir_in=""; fi
  if [[ "${manifest_in}" == "null" ]]; then manifest_in=""; fi
  if [[ "${log_in}" == "null" ]]; then log_in=""; fi

  # If manifest is provided but workdir is not, infer workdir.
  if [[ -z "${workdir_in}" && -n "${manifest_in}" ]]; then
    workdir_in="$(dirname "${manifest_in}")"
  fi

  # If workdir is provided, default manifest/log under it.
  if [[ -n "${workdir_in}" ]]; then
    # trim trailing slashes
    workdir_in="${workdir_in%/}"
    if [[ -z "${manifest_in}" ]]; then
      manifest_in="${workdir_in}/manifest.json"
    fi
    if [[ -z "${log_in}" ]]; then
      log_in="${workdir_in}/events.log"
    fi
  fi

  export V2K_WORKDIR="${workdir_in}"
  export V2K_RUN_ID="${run_id_in}"
  export V2K_MANIFEST="${manifest_in}"
  export V2K_EVENTS_LOG="${log_in}"

}

# ------------------------------------------------------------
# ABLESTACK Host defaults (fixed paths)
# - VirtIO ISO is already installed on ABLESTACK hosts.
# - WinPE ISO is shipped/installed with ablestack_v2k package.
#   (Both can be overridden by CLI options or env.)
# ------------------------------------------------------------

v2k_resolve_virtio_iso() {
  # Echo resolved path or empty.
  local p="${1-}"
  if [[ -n "${p}" ]]; then
    [[ -f "${p}" ]] && { echo "${p}"; return 0; }
    return 1
  fi

  if [[ -n "${V2K_VIRTIO_ISO-}" ]]; then
    [[ -f "${V2K_VIRTIO_ISO}" ]] && { echo "${V2K_VIRTIO_ISO}"; return 0; }
  fi

  local candidates=(
    "/usr/share/virtio-win/virtio-win.iso"
    "/usr/share/virtio-win/virtio-win-*.iso"
    "/usr/share/virtio-win/*.iso"
    "/usr/share/virtio-win.iso"
  )
  local c
  for c in "${candidates[@]}"; do
    # shellcheck disable=SC2086
    for f in ${c}; do
      [[ -f "${f}" ]] || continue
      echo "${f}"
      return 0
    done
  done
  return 1
}

v2k_resolve_winpe_iso() {
  # Echo resolved path or empty.
  local p="${1-}"
  if [[ -n "${p}" ]]; then
    [[ -f "${p}" ]] && { echo "${p}"; return 0; }
    return 1
  fi

  if [[ -n "${V2K_WINPE_ISO-}" ]]; then
    [[ -f "${V2K_WINPE_ISO}" ]] && { echo "${V2K_WINPE_ISO}"; return 0; }
  fi

  local candidates=(
    "/usr/share/ablestack-v2k/winpe-ablestack-v2k-amd64.iso"
    "/usr/share/ablestack-v2k/winpe-ablestack-v2k-*.iso"
    "/usr/share/ablestack-v2k/*.iso"
  )
  local c
  for c in "${candidates[@]}"; do
    # shellcheck disable=SC2086
    for f in ${c}; do
      [[ -f "${f}" ]] || continue
      echo "${f}"
      return 0
    done
  done
  return 1
}

# vCenter(또는 지정 server)의 SSL SHA1 thumbprint 계산
v2k_get_ssl_thumbprint_sha1() {
  local host="$1"
  [[ -n "${host}" ]] || return 1
  echo | openssl s_client -connect "${host}:443" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr '[:lower:]' '[:upper:]'
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

v2k_load_runtime_flags_from_manifest() {
  # manifest가 존재한다는 전제(v2k_require_manifest 이후 호출)
  local force
  force="$(jq -r '.target.storage.force_block_device // false' "${V2K_MANIFEST}" 2>/dev/null || echo "false")"

  if [[ "${force}" == "true" ]]; then
    export V2K_FORCE_BLOCK_DEVICE="1"
  else
    export V2K_FORCE_BLOCK_DEVICE="0"
  fi

  # Observability: force-block-device 상태를 event에 기록
  # - command 별로 호출되므로, 해당 커맨드의 phase_start 전에 남겨도 문제 없음
  v2k_event INFO "runtime" "" "force_block_device" \
    "{\"enabled\":${force},\"source\":\"manifest\",\"manifest\":\"${V2K_MANIFEST}\"}"
}

v2k_cmd_init() {
  local vm="" vcenter="" dst="" mode="govc" cred_file=""

  # New: VDDK(ESXi) auth (separated from GOVC/vCenter)
  local vddk_cred_file=""

  # New: target override options (CLI -> env)
  local target_format="" target_storage="" target_map_json=""
  local force_block_device=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vm) vm="${2:-}"; shift 2;;
      --vcenter) vcenter="${2:-}"; shift 2;;
      --dst) dst="${2:-}"; shift 2;;
      --mode) mode="${2:-}"; shift 2;;
      --cred-file) cred_file="${2:-}"; shift 2;;
      --vddk-cred-file) vddk_cred_file="${2:-}"; shift 2;;

      # --- new options ---
      --target-format) target_format="${2:-}"; shift 2;;
      --target-storage) target_storage="${2:-}"; shift 2;;
      --target-map-json) target_map_json="${2:-}"; shift 2;;

      --force-block-device) force_block_device=1; shift 1;;

      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  [[ -n "${vm}" && -n "${vcenter}" && -n "${dst}" ]] || { echo "init requires --vm --vcenter --dst" >&2; exit 2; }
  [[ "${mode}" == "govc" ]] || { echo "Only --mode govc is supported in v1" >&2; exit 2; }

  if [[ -n "${cred_file}" ]]; then
    v2k_vmware_load_cred_file "${cred_file}"
  fi

  # Persist VDDK cred file into workdir (productization)
  # - Do NOT store password in manifest
  # - Keep a secure on-disk cred file referenced by manifest
  if [[ -n "${vddk_cred_file}" ]]; then
    local vddk_saved="${V2K_WORKDIR}/vddk.cred"
    install -m 600 "${vddk_cred_file}" "${vddk_saved}"
    export V2K_VDDK_CRED_FILE="${vddk_saved}"
  else
    export V2K_VDDK_CRED_FILE=""
  fi

  # ---- VDDK(vCenter) thumbprint 제품화 자동화 ----
  # 1) cred_file 내부에 VDDK_THUMBPRINT가 있으면 우선 사용
  # 2) 없으면 V2K_VDDK_SERVER(또는 vCenter host)로 openssl 계산
  if [[ -n "${V2K_VDDK_CRED_FILE-}" && -f "${V2K_VDDK_CRED_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${V2K_VDDK_CRED_FILE}"
    # cred 파일에 user/pass/server/thumbprint가 있다면 env로 승격
    [[ -n "${VDDK_USER-}" ]] && export V2K_VDDK_USER="${VDDK_USER}"
    [[ -n "${VDDK_SERVER-}" ]] && export V2K_VDDK_SERVER="${VDDK_SERVER}"
    [[ -n "${VDDK_THUMBPRINT-}" ]] && export V2K_VDDK_THUMBPRINT="${VDDK_THUMBPRINT}"
  fi

  # thumbprint가 여전히 비어있으면 server 대상으로 자동 계산
  if [[ -z "${V2K_VDDK_THUMBPRINT-}" ]]; then
    local server host_from_vcenter
    server="${V2K_VDDK_SERVER-}"
    if [[ -z "${server}" ]]; then
      # GOVC_URL == https://x.x.x.x/sdk 형태에서 host만 추출
      host_from_vcenter="$(printf '%s' "${GOVC_URL-}" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#^.*@##; s#:[0-9]+$##')"
      server="${host_from_vcenter}"
      [[ -n "${server}" ]] && export V2K_VDDK_SERVER="${server}"
    fi
    if [[ -n "${server}" ]]; then
      V2K_VDDK_THUMBPRINT="$(v2k_get_ssl_thumbprint_sha1 "${server}" || true)"
      export V2K_VDDK_THUMBPRINT
    fi
  fi

  # Validate & apply target overrides (CLI wins for this run)
  if [[ -n "${target_format}" ]]; then
    case "${target_format}" in
      qcow2|raw) export V2K_TARGET_FORMAT="${target_format}" ;;
      *) echo "Invalid --target-format: ${target_format} (allowed: qcow2|raw)" >&2; exit 2;;
    esac
  fi

  if [[ -n "${target_storage}" ]]; then
    case "${target_storage}" in
      file|block|rbd) export V2K_TARGET_STORAGE_TYPE="${target_storage}" ;;
      *) echo "Invalid --target-storage: ${target_storage} (allowed: file|block|rbd)" >&2; exit 2;;
    esac
  fi

  if [[ -n "${target_map_json}" ]]; then
    # Validate + normalize JSON early (requires jq)
    local map_compact
    if ! map_compact="$(printf '%s' "${target_map_json}" | jq -c '.' 2>/dev/null)"; then
      echo "Invalid --target-map-json (must be valid JSON object): ${target_map_json}" >&2
      exit 2
    fi
    export V2K_TARGET_STORAGE_MAP_JSON="${map_compact}"
  fi

  # Safety: block/rbd storage requires map json
  if [[ "${V2K_TARGET_STORAGE_TYPE:-file}" == "block" || "${V2K_TARGET_STORAGE_TYPE:-file}" == "rbd" ]]; then
    if [[ -z "${V2K_TARGET_STORAGE_MAP_JSON:-}" || "${V2K_TARGET_STORAGE_MAP_JSON}" == "{}" ]]; then
      echo "--target-storage block|rbd requires --target-map-json '{\"scsi0:0\":\"/dev/sdb\",\"scsi0:1\":\"rbd:pool/image\",...}'" >&2
      exit 2
    fi
  fi

  export V2K_FORCE_BLOCK_DEVICE="${force_block_device}"

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

  # Log init start with target overrides for observability
  v2k_event INFO "init" "" "phase_start" \
    "{\"vm\":\"${vm}\",\"vcenter\":\"${vcenter}\",\"dst\":\"${dst}\",\"mode\":\"${mode}\",\"target_format\":\"${V2K_TARGET_FORMAT:-qcow2}\",\"target_storage\":\"${V2K_TARGET_STORAGE_TYPE:-file}\"}"

  local inv_json
  inv_json="$(v2k_vmware_inventory_json "${vm}" "${vcenter}")"

  # Build manifest using inventory json + target settings (from env)
  v2k_manifest_init "${V2K_MANIFEST}" "${V2K_RUN_ID}" "${V2K_WORKDIR}" "${vm}" "${vcenter}" "${mode}" "${dst}" "${inv_json}"

  v2k_event INFO "init" "" "phase_done" "{\"manifest\":\"${V2K_MANIFEST}\",\"workdir\":\"${V2K_WORKDIR}\"}"

  v2k_json_or_text_ok "init" \
    "{\"run_id\":\"${V2K_RUN_ID}\",\"workdir\":\"${V2K_WORKDIR}\",\"manifest\":\"${V2K_MANIFEST}\"}" \
    "Initialized. run_id=${V2K_RUN_ID} workdir=${V2K_WORKDIR}"
}

v2k_cmd_cbt() {
  v2k_require_manifest
  v2k_load_runtime_flags_from_manifest
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
  v2k_load_runtime_flags_from_manifest
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

v2k_prepare_cbt_change_ids_for_sync() {
  local manifest="$1" which="$2"
  # For incr/final we must ensure changeId fields exist for CBT-enabled disks.
  # This prevents "empty changeId" runs and stabilizes incremental logic.
  #
  # NOTE: actual 'changeId advancement' is expected to be performed by the
  # patch pipeline (vmware_changed_areas.py + transfer_patch.sh) and persisted
  # into manifest. Here we only ensure initialization.
  if [[ "${which}" == "incr" || "${which}" == "final" ]]; then
    v2k_manifest_ensure_cbt_change_ids "${manifest}"
  fi
}

v2k_prepare_cbt_change_ids_after_base() {
  local manifest="$1"
  # After base sync completes, initialize base/last changeId for CBT-enabled disks.
  # This makes the next incr sync deterministic even if the patch pipeline expects
  # non-empty last_change_id.
  v2k_manifest_ensure_cbt_change_ids "${manifest}"
}

v2k_maybe_force_cleanup() {
  # force cleanup ONLY this run namespace
  if [[ "${V2K_FORCE_CLEANUP:-0}" -eq 1 ]]; then
    v2k_event WARN "runtime" "" "force_cleanup" "{\"run_id\":\"${V2K_RUN_ID:-}\"}"
    v2k_force_cleanup_run "${V2K_RUN_ID:-}" || true
  fi
}

v2k_cmd_sync() {
  local manifest="${V2K_MANIFEST}"
  local force_cleanup=0
  : "${V2K_BASE_METHOD:=nbdcopy}"

  v2k_require_manifest
  v2k_load_runtime_flags_from_manifest
  local which="${1:-}" jobs=1 coalesce_gap=$((1024*1024)) chunk=$((4*1024*1024))
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs) jobs="${2:-}"; shift 2;;
      --coalesce-gap) coalesce_gap="${2:-}"; shift 2;;
      --chunk) chunk="${2:-}"; shift 2;;
      --force-cleanup) force_cleanup=1; shift 1;;
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  export V2K_FORCE_CLEANUP="${force_cleanup}"
  v2k_maybe_force_cleanup

  v2k_prepare_cbt_change_ids_for_sync "${V2K_MANIFEST}" "${which}"

  case "${which}" in
    base)
      v2k_event INFO "sync.base" "" "phase_start" "{\"jobs\":${jobs}}"
      v2k_transfer_base_all "${V2K_MANIFEST}" "${jobs}"
      v2k_prepare_cbt_change_ids_after_base "${V2K_MANIFEST}"
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
  v2k_load_runtime_flags_from_manifest
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
  v2k_load_runtime_flags_from_manifest
  local shutdown="manual" define_only=0 start_vm=0
  local winpe_bootstrap=0
  local winpe_iso="" virtio_iso="" winpe_timeout=600
  local shutdown_force=1 shutdown_timeout=300
  local vcpu=2 memory=2048
  local network="default" bridge="" vlan=""
  local force_cleanup=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shutdown) shutdown="${2:-}"; shift 2;;
      --shutdown-force) shutdown_force=1; shift 1;;
      --shutdown-timeout) shutdown_timeout="${2:-}"; shift 2;;
      --define-only) define_only=1; shift 1;;
      --start) start_vm=1; shift 1;;
      --vcpu) vcpu="${2:-}"; shift 2;;
      --memory) memory="${2:-}"; shift 2;;
      --network) network="${2:-}"; shift 2;;
      --bridge) bridge="${2:-}"; shift 2;;
      --vlan) vlan="${2:-}"; shift 2;;
      --winpe-bootstrap) winpe_bootstrap=1; shift 1;;
      --winpe-iso) winpe_iso="${2:-}"; shift 2;;
      --virtio-iso) virtio_iso="${2:-}"; shift 2;;
      --winpe-timeout) winpe_timeout="${2:-}"; shift 2;;

      --force-cleanup) force_cleanup=1; shift 1;; 
      *) echo "Unknown option: $1" >&2; exit 2;;
    esac
  done

  export V2K_FORCE_CLEANUP="${force_cleanup}"
  v2k_maybe_force_cleanup

  # As approved: default flow is shutdown -> final snapshot -> final sync
  v2k_event INFO "cutover" "" "phase_start" "{\"shutdown\":\"${shutdown}\"}"

  case "${shutdown}" in
    manual)
      echo "Cutover requires VM to be shutdown on VMware side. Confirm shutdown before proceeding." >&2
      ;;
    guest)
      # Best-effort guest shutdown; fallback to hard poweroff if not supported/failed.
      v2k_event INFO "cutover" "" "shutdown_guest_attempt" "{}"
      if v2k_vmware_vm_shutdown_guest_best_effort "${V2K_MANIFEST}"; then
        if ! v2k_vmware_vm_wait_poweroff "${V2K_MANIFEST}" "${shutdown_timeout}"; then
          v2k_event WARN "cutover" "" "shutdown_guest_timeout_fallback_poweroff" "{\"timeout\":${shutdown_timeout}}"
          v2k_vmware_vm_poweroff "${V2K_MANIFEST}" "${shutdown_force}" "${shutdown_timeout}" \
            || { echo "Failed to power off VM via govc (guest+fallback)." >&2; exit 50; }
        fi
      else
        v2k_event WARN "cutover" "" "shutdown_guest_unsupported_fallback_poweroff" "{}"
        v2k_vmware_vm_poweroff "${V2K_MANIFEST}" "${shutdown_force}" "${shutdown_timeout}" \
          || { echo "Failed to power off VM via govc." >&2; exit 50; }
      fi
      ;;
    poweroff)
      v2k_event INFO "cutover" "" "shutdown_poweroff" "{\"force\":${shutdown_force},\"timeout\":${shutdown_timeout}}"
      v2k_vmware_vm_poweroff "${V2K_MANIFEST}" "${shutdown_force}" "${shutdown_timeout}" \
        || { echo "Failed to power off VM via govc." >&2; exit 50; }
      ;;
    *)
      echo "Invalid --shutdown value: ${shutdown} (allowed: manual|guest|poweroff)" >&2
      exit 2
      ;;
  esac

  # Always create final snapshot as default
  local name="migr-final-$(date +%Y%m%d-%H%M%S)"
  v2k_vmware_snapshot_create "${V2K_MANIFEST}" "final" "${name}"
  v2k_manifest_snapshot_set "${V2K_MANIFEST}" "final" "${name}"

  # final sync
  v2k_transfer_patch_all "${V2K_MANIFEST}" "final" 1 $((1024*1024)) $((4*1024*1024))

  # libvirt define
  if [[ "${define_only}" -eq 1 || "${start_vm}" -eq 1 || "${winpe_bootstrap}" -eq 1 ]]; then
    local xml_path
    if [[ -n "${bridge}" ]]; then
      xml_path="$(v2k_target_generate_libvirt_xml "${V2K_MANIFEST}" \
        --vcpu "${vcpu}" --memory "${memory}" \
        --bridge "${bridge}" $( [[ -n "${vlan}" ]] && echo --vlan "${vlan}" ) \
      )"
    else
      xml_path="$(v2k_target_generate_libvirt_xml "${V2K_MANIFEST}" \
        --vcpu "${vcpu}" --memory "${memory}" \
        --network "${network}" \
      )"
    fi
    v2k_target_define_libvirt "${xml_path}"
    # Optional: WinPE bootstrap phase (driver injection) before first Windows boot
    if [[ "${winpe_bootstrap}" -eq 1 ]]; then
      local vm winpe_iso_resolved virtio_iso_resolved cdrom0 cdrom1
      vm="$(jq -r '.target.libvirt.name' "${V2K_MANIFEST}")"

      winpe_iso_resolved="$(v2k_resolve_winpe_iso "${winpe_iso}" || true)"
      virtio_iso_resolved="$(v2k_resolve_virtio_iso "${virtio_iso}" || true)"

      if [[ -z "${winpe_iso_resolved}" || ! -f "${winpe_iso_resolved}" ]]; then
        echo "WinPE ISO not found (resolved). Set --winpe-iso or install it under /usr/share/ablestack-v2k/." >&2
        exit 61
      fi
      if [[ -z "${virtio_iso_resolved}" || ! -f "${virtio_iso_resolved}" ]]; then
        echo "VirtIO ISO not found (resolved). Set --virtio-iso or install it under /usr/share/virtio-win/." >&2
        exit 62
      fi

      v2k_event INFO "winpe" "" "phase_start" \
        "{\"winpe_iso\":\"${winpe_iso_resolved}\",\"virtio_iso\":\"${virtio_iso_resolved}\",\"timeout\":${winpe_timeout}}"

      # boot order: cdrom only (hd is not listed)
      v2k_target_set_boot_cdrom_only "${vm}"

      cdrom0="$(v2k_target_attach_cdrom "${vm}" "${winpe_iso_resolved}")"

      # Start VM (WinPE)
      virsh start "${vm}" >/dev/null 2>&1 || true

      # Press-any-key handling: send SPACE 1/sec for 15 sec
      v2k_target_send_key_space "${vm}" 15

      # Delay 15 sec then attach VirtIO ISO
      sleep 15
      cdrom1="$(v2k_target_attach_cdrom "${vm}" "${virtio_iso_resolved}")"

      if v2k_target_wait_shutdown "${vm}" "${winpe_timeout}"; then
        v2k_event INFO "winpe" "" "phase_done" "{}"
      else
        v2k_event ERROR "winpe" "" "phase_timeout" "{\"timeout\":${winpe_timeout}}"
        # best-effort cleanup
        v2k_target_detach_disk "${vm}" "${cdrom1}" || true
        v2k_target_detach_disk "${vm}" "${cdrom0}" || true
        v2k_target_set_boot_hd "${vm}" || true
        exit 63
      fi

      # Detach ISOs and restore normal boot
      v2k_target_detach_disk "${vm}" "${cdrom1}" || true
      v2k_target_detach_disk "${vm}" "${cdrom0}" || true
      v2k_target_set_boot_hd "${vm}"
    fi

    # Start Windows VM only after WinPE bootstrap (if requested)
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
  v2k_load_runtime_flags_from_manifest
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
    # After final cutover: remove ONLY migration snapshots (name contains "migr-").
    # Default: enabled. To disable: export V2K_PURGE_MIGR_SNAPSHOTS=0
    : "${V2K_PURGE_MIGR_SNAPSHOTS:=1}"
    if [[ "${V2K_PURGE_MIGR_SNAPSHOTS}" == "1" ]]; then
      v2k_event INFO "cleanup" "" "vmware_snapshot_remove_migr_start" "{\"pattern\":\"migr-\"}"
      if v2k_vmware_snapshot_remove_migr "${V2K_MANIFEST}" "migr-"; then
        v2k_event INFO "cleanup" "" "vmware_snapshot_remove_migr_done" "{\"pattern\":\"migr-\"}"
      else
        v2k_event WARN "cleanup" "" "vmware_snapshot_remove_migr_failed" "{\"pattern\":\"migr-\"}"
      fi
    fi
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
  v2k_load_runtime_flags_from_manifest
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
