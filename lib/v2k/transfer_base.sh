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
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/nbd_utils.sh"
# shellcheck source=/dev/null
source "${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k/v2k_target_device.sh"

v2k_require_vddk_env() {
  : "${VDDK_LIBDIR:?missing VDDK_LIBDIR (e.g. /opt/vmware-vix-disklib-distrib/lib64)}"
  command -v nbdkit >/dev/null
  command -v qemu-img >/dev/null
  command -v govc >/dev/null
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

v2k_transfer_base_all() {
  local manifest="$1" jobs="$2"
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
    thumbprint="$(v2k_vmware_get_thumbprint "${esxi}")"
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
      # qcow2는 먼저 만들어둬야 qemu-nbd attach 가능
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
      # target_path는 /dev/sdX 등 “디바이스 자체”
    elif [[ "${st}" == "rbd" ]]; then
      kind="rbd"
      # target_path는 rbd:pool/image (manifest에서 강제)
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
    # - block/rbd      : prepare_target_device -> blockdev, write -O raw
    # ------------------------------------------------------------
    local out_target out_fmt cleanup_cmd target_blockdev
    out_target=""
    out_fmt=""
    cleanup_cmd=": # no-op"
    target_blockdev=""

    if [[ "${st}" == "file" ]]; then
      # Direct file output: ensure format is honored (qcow2/raw)
      out_target="${target_path}"
      out_fmt="${fmt}"
    else
      # block/rbd -> blockdev and raw stream
      target_blockdev="$(prepare_target_device --kind "${kind}" --path "${target_path}" --size-bytes "${size_bytes}")"
      cleanup_cmd="${V2K_TARGET_CLEANUP_CMD:-:}"
      out_target="${target_blockdev}"
      out_fmt="raw"
    fi

    cleanup() {
      if [[ -n "${target_blockdev}" && -b "${target_blockdev}" ]]; then
        blockdev --flushbufs "${target_blockdev}" >/dev/null 2>&1 || true
      fi
      eval "${cleanup_cmd}" >/dev/null 2>&1 || true
    }
    # IMPORTANT: per-disk cleanup (avoid qemu-nbd leak across disks)
    trap cleanup RETURN

    # Validated pattern:
    # nbdkit -r -U - vddk libdir=... server=... user=... password=+file thumbprint=... vm="moref=..." snapshot="..." transports=nbd:nbdssl file="..." \
    #   --run 'qemu-img convert -p -f raw -O <raw|qcow2> $nbd <target>'
    LD_LIBRARY_PATH="${VDDK_LIBDIR}" \
    nbdkit -r -U - vddk \
      libdir="${VDDK_LIBDIR}" \
      server="${server}" \
      user="${VDDK_USER}" \
      password=+"${passfile}" \
      thumbprint="${thumbprint}" \
      vm="moref=${vm_moref}" \
      snapshot="${snap_moref}" \
      transports=nbd:nbdssl \
      file="${vmdk_path}" \
      --run "qemu-img convert -p -f raw -O \"${out_fmt}\" \$nbd \"${out_target}\"" >"${nbdlog}" 2>&1

    v2k_manifest_mark_base_done "${manifest}" "${idx}"
    v2k_event INFO "sync.base" "${disk_id}" "disk_done" "{\"target\":\"${target_path}\"}"

  )
}

v2k_transfer_cleanup() {
  # base is run-mode; no persistent nbd devices. Keep placeholder.
  true
}
