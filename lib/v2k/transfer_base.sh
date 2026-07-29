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

V2K_ROOT_DIR="${V2K_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
V2K_LIB_DIR="${V2K_LIB_DIR:-${V2K_ROOT_DIR}/lib/v2k}"
if [[ ! -f "${V2K_LIB_DIR}/logging.sh" ]]; then
  V2K_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  V2K_LIB_DIR="${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k"
fi
# shellcheck source=/dev/null
source "${V2K_LIB_DIR}/logging.sh"
# shellcheck source=/dev/null
source "${V2K_LIB_DIR}/compat.sh"
# shellcheck source=/dev/null
source "${V2K_LIB_DIR}/manifest.sh"
# shellcheck source=/dev/null
source "${V2K_LIB_DIR}/vmware_govc.sh"
# shellcheck source=/dev/null
source "${V2K_LIB_DIR}/nbd_utils.sh"
# shellcheck source=/dev/null
source "${V2K_LIB_DIR}/v2k_target_device.sh"

v2k_require_vddk_env() {
  : "${VDDK_LIBDIR:?missing VDDK_LIBDIR (e.g. /opt/vmware-vix-disklib-distrib/lib64)}"
  local nbdkit_bin
  nbdkit_bin="$(v2k_compat_nbdkit_bin)"
  [[ -x "${nbdkit_bin}" ]]
  command -v qemu-img >/dev/null
  v2k_has_govc_bin
}

v2k_load_vddk_cred_from_manifest() {
  local manifest="$1"
  local cred
  cred="$(jq -r '.source.vddk.cred_file // empty' "${manifest}" 2>/dev/null || true)"
  [[ -n "${cred}" && -f "${cred}" ]] || {
    echo "Missing .source.vddk.cred_file in manifest (or file not found). Provide it via init --vddk-cred-file." >&2
    exit 32
  }
  # shellcheck disable=SC1090
  source "${cred}"
  : "${VDDK_USER:?missing VDDK_USER in vddk cred file}"
  : "${VDDK_PASSWORD:?missing VDDK_PASSWORD in vddk cred file}"
}

v2k_transfer_base_retryable_nfc_log() {
  local log_file="$1"
  [[ -s "${log_file}" ]] || return 1
  grep -Eiq \
    'NFC_NETWORK_ERROR|NfcNetTcp(SetError|Read|Write)|Connection reset by peer|server refused connection|Broken pipe|Connection timed out|timed out|Memory allocation failed|Out of memory|Failed to allocate the requested' \
    "${log_file}"
}

v2k_transfer_base_rbd_staging_uri() {
  local target_uri="$1"
  local run_id="$2"
  local idx="$3"
  local attempt="$4"
  local prefix image safe_run

  [[ "${target_uri}" == rbd:*/* ]] || return 1
  prefix="${target_uri%/*}"
  image="${target_uri##*/}"
  safe_run="$(printf '%s' "${run_id}" | tr -c 'A-Za-z0-9_.-' '_')"
  [[ -n "${safe_run}" ]] || safe_run="unknown"
  printf '%s/%s.v2k-stage-%s-d%s-p%s-a%s\n' \
    "${prefix}" "${image}" "${safe_run}" "${idx}" "$$" "${attempt}"
}

v2k_transfer_base_rbd_remove_staging() {
  local staging_uri="$1"
  local spec="${staging_uri#rbd:}"

  [[ "${staging_uri}" == rbd:*/*.v2k-stage-* ]] || return 1
  command -v rbd >/dev/null 2>&1 || return 1
  if rbd info "${spec}" >/dev/null 2>&1; then
    rbd rm "${spec}" >/dev/null
  fi
}

v2k_transfer_base_rbd_publish() {
  local staging_uri="$1"
  local target_uri="$2"
  local staging_spec="${staging_uri#rbd:}"
  local target_spec="${target_uri#rbd:}"

  [[ "${staging_uri}" == rbd:*/*.v2k-stage-* ]] || return 1
  [[ "${target_uri}" == rbd:*/* ]] || return 1
  command -v rbd >/dev/null 2>&1 || return 1
  rbd info "${staging_spec}" >/dev/null 2>&1 || return 1
  if rbd info "${target_spec}" >/dev/null 2>&1; then
    return 2
  fi
  rbd mv "${staging_spec}" "${target_spec}" >/dev/null
}

v2k_transfer_base_run_vddk() {
  local attempt_log="$1"
  local run_str="$2"
  local nbdkit_bin="$3"
  local nbdkit_plugin="$4"
  local vddk_ld_library_path="$5"
  local vddk_config="$6"
  local server="$7"
  local passfile="$8"
  local thumbprint="$9"
  local vm_moref="${10}"
  local snap_moref="${11}"
  local vmdk_path="${12}"

  LD_LIBRARY_PATH="${vddk_ld_library_path}" \
  "${nbdkit_bin}" -r -U - "${nbdkit_plugin}" \
    libdir="${VDDK_LIBDIR}" \
    config="${vddk_config}" \
    server="${server}" \
    user="${VDDK_USER}" \
    password=+"${passfile}" \
    thumbprint="${thumbprint}" \
    vm="moref=${vm_moref}" \
    snapshot="${snap_moref}" \
    transports=nbd:nbdssl \
    file="${vmdk_path}" \
    --run "${run_str}" >>"${attempt_log}" 2>&1
}

v2k_transfer_base_record_failure() {
  local manifest="$1"
  local idx="$2"
  local disk_id="$3"
  local code="$4"
  local reason="$5"
  local details_json="${6:-{}}"

  v2k_manifest_record_sync_failure \
    "${manifest}" "base" "${idx}" "${code}" "${reason}" "${details_json}" || true
  v2k_event ERROR "sync.base" "${disk_id}" "disk_failed" \
    "$(jq -nc \
      --argjson code "${code}" \
      --arg reason "${reason}" \
      --argjson details "${details_json}" \
      '{code:$code,reason:$reason,details:$details}' 2>/dev/null \
      || printf '{"code":%s,"reason":"%s"}' "${code}" "${reason}")"
}

v2k_transfer_base_all() {
  local manifest="$1" jobs="$2"
  : "${jobs:?}"
  local count
  count="$(jq -r '.disks|length' "${manifest}")"

  mkdir -p /tmp
  v2k_load_vddk_cred_from_manifest "${manifest}"

  local passfile
  passfile="$(mktemp /tmp/v2k_vddk_pass.XXXXXX)"
  echo -n "${VDDK_PASSWORD}" > "${passfile}"
  chmod 600 "${passfile}"
  trap 'rm -f "${passfile-}" >/dev/null 2>&1 || true' EXIT

  local server
  # vCenter 중심: vddk.server -> vcenter(host) -> esxi_host
  server="$(jq -r '.source.vddk.server // empty' "${manifest}" 2>/dev/null || true)"
  if [[ -z "${server}" || "${server}" == "null" ]]; then
    server="$(jq -r '.source.vcenter // empty' "${manifest}" 2>/dev/null \
      | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#^.*@##; s#:[0-9]+$##' || true)"
  fi
  if [[ -z "${server}" || "${server}" == "null" ]]; then
    server="$(jq -r '.source.esxi_host // empty' "${manifest}" 2>/dev/null || true)"
  fi
  [[ -n "${server}" && "${server}" != "null" ]] || {
    echo "Missing VDDK server (source.vddk.server/source.vcenter/source.esxi_host)" >&2
    exit 32
  }

  local thumbprint="${THUMBPRINT:-}"
  if [[ -z "${thumbprint}" ]]; then
    thumbprint="$(jq -r '.source.vddk.thumbprint // empty' "${manifest}" 2>/dev/null || true)"
  fi
  if [[ -z "${thumbprint}" ]]; then
    thumbprint="$(v2k_vmware_get_thumbprint "${server}")"
  fi

  local vm_moref
  vm_moref="$(v2k_vmware_get_vm_moref "${manifest}")"

  local base_snap_name
  base_snap_name="$(jq -r ".disks[0].snapshots.base.name" "${manifest}")"
  [[ -n "${base_snap_name}" && "${base_snap_name}" != "null" ]] || {
    echo "Base snapshot name missing. Run: snapshot base" >&2
    exit 30
  }

  local snap_moref
  snap_moref="$(v2k_vmware_snapshot_moref_by_name "${manifest}" "${base_snap_name}")"
  [[ -n "${snap_moref}" && "${snap_moref}" != "null" ]] || {
    echo "Failed to resolve base snapshot moref for name=${base_snap_name}" >&2
    exit 30
  }

  v2k_require_vddk_env

  local i
  for ((i=0;i<count;i++)); do
    v2k_transfer_base_one "${manifest}" "${i}" "${server}" "${thumbprint}" "${vm_moref}" "${snap_moref}" "${passfile}"
  done
}

v2k_transfer_base_one() {
  local manifest="$1" idx="$2" server="$3" thumbprint="$4" vm_moref="$5" snap_moref="$6" passfile="$7"
  (

    local disk_id vmdk_path target_path
    disk_id="$(jq -r ".disks[$idx].disk_id" "${manifest}")"
    vmdk_path="$(jq -r ".disks[$idx].vmdk.path" "${manifest}")"
    target_path="$(jq -r ".disks[$idx].transfer.target_path" "${manifest}")"
    local size_bytes
    size_bytes="$(jq -r ".disks[$idx].size_bytes // 0" "${manifest}")"

    local fmt st kind
    fmt="$(jq -r '.target.format // "qcow2"' "${manifest}")"
    st="$(jq -r '.target.storage.type // "file"' "${manifest}")"

    if [[ "${st}" == "file" && "${fmt}" == "qcow2" ]]; then
      kind="file-qcow2"
      mkdir -p "$(dirname "${target_path}")"
      # qcow2??먼�? 만들?�둬??qemu-nbd attach 가??      
      if [[ ! -f "${target_path}" ]]; then
        qemu-img create -f qcow2 "${target_path}" "${size_bytes}" >/dev/null
      fi
    elif [[ "${st}" == "file" && "${fmt}" == "raw" ]]; then
      kind="file-raw"
      mkdir -p "$(dirname "${target_path}")"
      if [[ ! -f "${target_path}" ]]; then
        truncate -s "${size_bytes}" "${target_path}"
      fi
    elif [[ "${st}" == "block" ]]; then
      kind="block-device"
      # target_path는 /dev/sdX 같은 디바이스 자체    
    elif [[ "${st}" == "rbd" ]]; then
      kind="rbd"
      # target_path??rbd:pool/image (manifest?�서 강제)
    else
      echo "Unsupported target: storage=${st} format=${fmt}" >&2
      exit 31
    fi

    v2k_event INFO "sync.base" "${disk_id}" "disk_start" \
      "{\"server\":\"${server}\",\"snapshot_moref\":\"${snap_moref}\",\"vmdk\":\"${vmdk_path}\",\"target\":\"${target_path}\"}"

    if [[ "${V2K_DRY_RUN:-0}" -eq 1 ]]; then
      v2k_event INFO "sync.base" "${disk_id}" "dry_run" "{}"
      v2k_manifest_mark_base_done "${manifest}" "${idx}"
      return 0
    fi

    local logdir="${V2K_WORKDIR}/logs"; mkdir -p "${logdir}"
    local nbdlog="${logdir}/nbdkit_base_${idx}.log"
    v2k_event INFO "sync.base" "${disk_id}" "nbdkit_log" "{\"path\":\"${nbdlog}\"}"

    # ------------------------------------------------------------
    # Target selection:
    # - file(qcow2/raw): write directly to file with correct -O format
    # - block          : prepare_target_device -> blockdev, write -O raw
    # - rbd            : write to a per-attempt staging image and publish only
    #                    after the full VDDK copy succeeds.
    # ------------------------------------------------------------
    local out_target out_fmt cleanup_cmd target_blockdev active_staging
    out_target=""
    out_fmt=""
    cleanup_cmd=": # no-op"
    target_blockdev=""
    active_staging=""

    if [[ "${st}" == "file" ]]; then
      # Direct file output: ensure format is honored (qcow2/raw)
      out_target="${target_path}"
      out_fmt="${fmt}"
    elif [[ "${st}" == "rbd" ]]; then
      command -v rbd >/dev/null 2>&1 || {
        local details_json
        details_json="$(jq -nc --arg target "${target_path}" \
          '{target:$target,note:"rbd CLI is required for staging and atomic publish"}')"
        v2k_transfer_base_record_failure \
          "${manifest}" "${idx}" "${disk_id}" 72 "rbd_staging_unavailable" "${details_json}"
        return 72
      }
      if v2k_rbd_exists "${target_path}"; then
        local details_json
        details_json="$(jq -nc --arg target "${target_path}" \
          '{target:$target,note:"canonical target already exists; refusing to overwrite possible partial or completed data"}')"
        v2k_transfer_base_record_failure \
          "${manifest}" "${idx}" "${disk_id}" 73 "rbd_target_already_exists" "${details_json}"
        return 73
      fi
      out_fmt="raw"
    else
      # block -> blockdev and raw stream
      target_blockdev="$(prepare_target_device --kind "${kind}" --path "${target_path}" --size-bytes "${size_bytes}")"
      cleanup_cmd="${V2K_TARGET_CLEANUP_CMD:-:}"
      out_target="${target_blockdev}"
      out_fmt="raw"
    fi

    cleanup() {
      if [[ -n "${target_blockdev}" && -b "${target_blockdev}" ]]; then
        blockdev --flushbufs "${target_blockdev}" >/dev/null 2>&1 || true
      fi
      if [[ -n "${active_staging}" ]]; then
        v2k_transfer_base_rbd_remove_staging "${active_staging}" >/dev/null 2>&1 || true
        active_staging=""
      fi
      eval "${cleanup_cmd}" >/dev/null 2>&1 || true
    }
    # IMPORTANT: per-disk cleanup, including a failed/stale staging RBD.
    trap cleanup EXIT

    # - V2K_BASE_METHOD=convert : qemu-img convert
    # - V2K_BASE_METHOD=nbdcopy : nbdcopy
    local base_method="${V2K_BASE_METHOD:-nbdcopy}"
    if [[ "${st}" == "rbd" ]]; then
      base_method="qemu-img"
    fi

    # normalize: trim + lowercase (whitespace/newline 방�?)
    base_method="$(echo -n "${base_method}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"

    # resolve absolute paths to avoid PATH issues (systemd/sudo/nbdkit --run)
    local qemu_img_path nbdcopy_path
    qemu_img_path="$(command -v qemu-img)"
    nbdcopy_path="$(command -v nbdcopy 2>/dev/null || true)"
    local child_env_prefix
    child_env_prefix="$(v2k_compat_vddk_child_env_prefix)"

    local nbdkit_bin nbdkit_plugin vddk_ld_library_path vddk_config
    nbdkit_bin="$(v2k_compat_nbdkit_bin)"
    nbdkit_plugin="$(v2k_compat_nbdkit_vddk_plugin)"
    vddk_ld_library_path="$(v2k_compat_vddk_ld_library_path)"
    vddk_config="$(v2k_compat_vddk_config_file)"

    local retry_limit="${V2K_BASE_NFC_RETRIES:-2}"
    local retry_delay_base="${V2K_BASE_RETRY_DELAY_SECONDS:-10}"
    [[ "${retry_limit}" =~ ^[0-9]+$ ]] || retry_limit=2
    [[ "${retry_delay_base}" =~ ^[0-9]+$ ]] || retry_delay_base=10
    if [[ "${st}" != "rbd" ]]; then
      # Non-staged destinations are not automatically retried because safely
      # discarding or replacing a partial block/file target is target-specific.
      retry_limit=0
    fi

    local max_attempts=$((retry_limit + 1))
    local attempt=1 transfer_rc=0 retryable=0 retry_delay=0
    local attempt_log="" run_str="" convert_sparse_args=""
    local run_id="${V2K_RUN_ID:-unknown}"

    : > "${nbdlog}"
    while [[ "${attempt}" -le "${max_attempts}" ]]; do
      attempt_log="${logdir}/nbdkit_base_${idx}_attempt_${attempt}.log"
      : > "${attempt_log}"
      convert_sparse_args=""

      if [[ "${st}" == "rbd" ]]; then
        active_staging="$(
          v2k_transfer_base_rbd_staging_uri \
            "${target_path}" "${run_id}" "${idx}" "${attempt}"
        )"
        v2k_transfer_base_rbd_remove_staging "${active_staging}" >/dev/null 2>&1 || true
        local staging_prepare_rc=0
        (v2k_rbd_ensure_image "${active_staging}" "${size_bytes}") \
          || staging_prepare_rc=$?
        if [[ "${staging_prepare_rc}" -ne 0 ]]; then
          local details_json
          details_json="$(jq -nc \
            --arg target "${target_path}" \
            --arg staging "${active_staging}" \
            --argjson attempt "${attempt}" \
            --argjson prepare_rc "${staging_prepare_rc}" \
            '{target:$target,staging:$staging,attempt:$attempt,prepare_rc:$prepare_rc}')"
          v2k_transfer_base_rbd_remove_staging "${active_staging}" >/dev/null 2>&1 || true
          active_staging=""
          v2k_transfer_base_record_failure \
            "${manifest}" "${idx}" "${disk_id}" 75 "rbd_staging_prepare_failed" "${details_json}"
          return 75
        fi
        out_target="${active_staging}"
        convert_sparse_args="-n -S \"$(v2k_rbd_sparse_size)\""
        v2k_event INFO "sync.base" "${disk_id}" "rbd_staging_ready" \
          "$(jq -nc \
            --arg target "${target_path}" \
            --arg staging "${active_staging}" \
            --argjson attempt "${attempt}" \
            --argjson max_attempts "${max_attempts}" \
            --arg sparse_size "$(v2k_rbd_sparse_size)" \
            '{target:$target,staging:$staging,attempt:$attempt,max_attempts:$max_attempts,sparse_size:$sparse_size}')"
      fi

      case "${base_method}" in
        convert|qemu-img)
          run_str="${child_env_prefix} ${qemu_img_path} convert -p -t none -T none ${convert_sparse_args} -O \"${out_fmt}\" \"\$uri\" \"${out_target}\""
          ;;
        nbdcopy)
          if [[ "${st}" == "file" && "${fmt}" == "qcow2" ]]; then
            run_str="${child_env_prefix} ${nbdcopy_path} --progress \"\$uri\" -- \"[\" qemu-nbd -f qcow2 \"${out_target}\" \"]\""
          else
            run_str="${child_env_prefix} ${nbdcopy_path} --progress \"\$uri\" \"${out_target}\""
          fi
          ;;
        *)
          run_str="${child_env_prefix} ${qemu_img_path} convert -p -t none -T none ${convert_sparse_args} -O \"${out_fmt}\" \"\$uri\" \"${out_target}\""
          ;;
      esac

      {
        printf '[INFO] Attempt: %s/%s\n' "${attempt}" "${max_attempts}"
        printf '[INFO] Base transfer method: %s\n' "${base_method}"
        printf '[INFO] Run string: %s\n' "${run_str}"
        printf '[INFO] nbdkit binary: %s\n' "${nbdkit_bin}"
        printf '[INFO] VDDK libdir: %s\n' "${VDDK_LIBDIR}"
        printf '[INFO] VDDK config: %s\n' "${vddk_config}"
      } >> "${attempt_log}"
      v2k_event INFO "sync.base" "${disk_id}" "transfer_attempt_start" \
        "$(jq -nc \
          --argjson attempt "${attempt}" \
          --argjson max_attempts "${max_attempts}" \
          --arg log "${attempt_log}" \
          --arg target "${out_target}" \
          '{attempt:$attempt,max_attempts:$max_attempts,log:$log,target:$target}')"

      transfer_rc=0
      v2k_transfer_base_run_vddk \
        "${attempt_log}" "${run_str}" "${nbdkit_bin}" "${nbdkit_plugin}" \
        "${vddk_ld_library_path}" "${vddk_config}" "${server}" "${passfile}" \
        "${thumbprint}" "${vm_moref}" "${snap_moref}" "${vmdk_path}" \
        || transfer_rc=$?

      {
        printf '\n===== attempt %s/%s =====\n' "${attempt}" "${max_attempts}"
        cat "${attempt_log}"
      } >> "${nbdlog}"

      if [[ "${transfer_rc}" -eq 0 ]]; then
        v2k_event INFO "sync.base" "${disk_id}" "transfer_attempt_done" \
          "$(jq -nc \
            --argjson attempt "${attempt}" \
            --arg target "${out_target}" \
            '{attempt:$attempt,target:$target}')"
        break
      fi

      retryable=0
      v2k_transfer_base_retryable_nfc_log "${attempt_log}" && retryable=1
      v2k_event WARN "sync.base" "${disk_id}" "transfer_attempt_failed" \
        "$(jq -nc \
          --argjson attempt "${attempt}" \
          --argjson max_attempts "${max_attempts}" \
          --argjson code "${transfer_rc}" \
          --argjson retryable "${retryable}" \
          --arg log "${attempt_log}" \
          --arg staging "${active_staging}" \
          '{attempt:$attempt,max_attempts:$max_attempts,code:$code,retryable:($retryable==1),log:$log,staging:$staging}')"

      if [[ -n "${active_staging}" ]]; then
        v2k_transfer_base_rbd_remove_staging "${active_staging}" >/dev/null 2>&1 || true
        active_staging=""
      fi
      if [[ "${retryable}" -eq 1 && "${attempt}" -lt "${max_attempts}" ]]; then
        retry_delay=$((retry_delay_base * attempt))
        v2k_event WARN "sync.base" "${disk_id}" "transfer_retry_scheduled" \
          "$(jq -nc \
            --argjson attempt "${attempt}" \
            --argjson next_attempt "$((attempt + 1))" \
            --argjson delay_seconds "${retry_delay}" \
            --arg reason "nfc_transient" \
            '{attempt:$attempt,next_attempt:$next_attempt,delay_seconds:$delay_seconds,reason:$reason}')"
        sleep "${retry_delay}"
        attempt=$((attempt + 1))
        continue
      fi
      break
    done

    if [[ "${transfer_rc}" -ne 0 ]]; then
      local failure_reason="base_transfer_failed"
      [[ "${retryable}" -eq 1 ]] && failure_reason="nfc_transfer_retries_exhausted"
      local details_json
      details_json="$(jq -nc \
        --arg target "${target_path}" \
        --arg log "${nbdlog}" \
        --argjson attempts "${attempt}" \
        --argjson max_attempts "${max_attempts}" \
        --argjson retryable "${retryable}" \
        '{target:$target,log:$log,attempts:$attempts,max_attempts:$max_attempts,retryable:($retryable==1)}')"
      v2k_transfer_base_record_failure \
        "${manifest}" "${idx}" "${disk_id}" "${transfer_rc}" "${failure_reason}" "${details_json}"
      return "${transfer_rc}"
    fi

    if [[ "${st}" == "rbd" ]]; then
      local publish_rc=0
      v2k_transfer_base_rbd_publish "${active_staging}" "${target_path}" || publish_rc=$?
      if [[ "${publish_rc}" -ne 0 ]]; then
        local details_json
        details_json="$(jq -nc \
          --arg target "${target_path}" \
          --arg staging "${active_staging}" \
          --argjson publish_rc "${publish_rc}" \
          '{target:$target,staging:$staging,publish_rc:$publish_rc,note:"validated staging image was not published; canonical target was not overwritten"}')"
        # Keep the fully transferred staging image for explicit operator recovery.
        active_staging=""
        v2k_transfer_base_record_failure \
          "${manifest}" "${idx}" "${disk_id}" 74 "rbd_staging_publish_failed" "${details_json}"
        return 74
      fi
      active_staging=""
      v2k_event INFO "sync.base" "${disk_id}" "rbd_staging_published" \
        "$(jq -nc --arg target "${target_path}" '{target:$target,atomic:true}')"
      if v2k_rbd_sparse_enabled; then
        v2k_rbd_sparsify "${target_path}"
      fi
    fi

    v2k_manifest_mark_base_done "${manifest}" "${idx}"
    v2k_event INFO "sync.base" "${disk_id}" "disk_done" \
      "$(jq -nc \
        --arg target "${target_path}" \
        --argjson attempts "${attempt}" \
        '{target:$target,attempts:$attempts}')"

  )
}

v2k_transfer_cleanup() {
  # base is run-mode; no persistent nbd devices. Keep placeholder.
  true
}
