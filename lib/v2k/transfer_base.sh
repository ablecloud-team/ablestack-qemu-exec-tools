#!/usr/bin/env bash
# ---------------------------------------------------------------------
# TODO: Copy the exact author/license header from bin/vm_exec.sh here.
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
source "${V2K_ROOT_DIR}/lib/v2k/nbd_utils.sh"

v2k_require_vddk_env() {
  : "${VDDK_LIBDIR:?missing VDDK_LIBDIR (e.g. /opt/vmware-vix-disklib-distrib/lib64)}"
  command -v nbdkit >/dev/null
  command -v qemu-img >/dev/null
  command -v govc >/dev/null
}

v2k_transfer_base_all() {
  local manifest="$1" jobs="$2"
  local count
  count="$(jq -r '.disks|length' "${manifest}")"

  mkdir -p /tmp
  echo -n "${GOVC_PASSWORD:?missing GOVC_PASSWORD}" > /tmp/vmware_pass
  chmod 600 /tmp/vmware_pass

  local esxi
  esxi="$(v2k_vmware_require_esxi_host "${manifest}")"

  local thumbprint="${THUMBPRINT:-}"
  if [[ -z "${thumbprint}" ]]; then
    thumbprint="$(v2k_vmware_get_thumbprint "${esxi}")"
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
    v2k_transfer_base_one "${manifest}" "${i}" "${esxi}" "${thumbprint}" "${vm_moref}" "${snap_moref}"
  done
}

v2k_transfer_base_one() {
  local manifest="$1" idx="$2" esxi="$3" thumbprint="$4" vm_moref="$5" snap_moref="$6"

  local disk_id vmdk_path target_path
  disk_id="$(jq -r ".disks[$idx].disk_id" "${manifest}")"
  vmdk_path="$(jq -r ".disks[$idx].vmdk.path" "${manifest}")"
  target_path="$(jq -r ".disks[$idx].transfer.target_path" "${manifest}")"

  mkdir -p "$(dirname "${target_path}")"

  v2k_event INFO "sync.base" "${disk_id}" "disk_start" \
    "{\"esxi\":\"${esxi}\",\"snapshot_moref\":\"${snap_moref}\",\"vmdk\":\"${vmdk_path}\",\"target\":\"${target_path}\"}"

  if [[ "${V2K_DRY_RUN:-0}" -eq 1 ]]; then
    v2k_event INFO "sync.base" "${disk_id}" "dry_run" "{}"
    v2k_manifest_mark_base_done "${manifest}" "${idx}"
    return 0
  fi

  local logdir="${V2K_WORKDIR}/logs"; mkdir -p "${logdir}"
  local nbdlog="${logdir}/nbdkit_base_${idx}.log"
  v2k_event INFO "sync.base" "${disk_id}" "nbdkit_log" "{"path":"${nbdlog}"}"  

  # Validated pattern:
  # nbdkit -r -U - vddk libdir=... server=... user=... password=+file thumbprint=... vm="moref=..." snapshot="..." transports=nbd:nbdssl file="..." \
  #   --run 'qemu-img convert -p -f raw -O qcow2 $nbd target.qcow2'
  LD_LIBRARY_PATH="${VDDK_LIBDIR}" \
  nbdkit -r -U - vddk \
    libdir="${VDDK_LIBDIR}" \
    server="${esxi}" \
    user="${GOVC_USERNAME:?missing GOVC_USERNAME}" \
    password=+/tmp/vmware_pass \
    thumbprint="${thumbprint}" \
    vm="moref=${vm_moref}" \
    snapshot="${snap_moref}" \
    transports=nbd:nbdssl \
    file="${vmdk_path}" \
    --run "qemu-img convert -p -f raw -O qcow2 \$nbd \"${target_path}\"" >"${nbdlog}" 2>&1

  v2k_manifest_mark_base_done "${manifest}" "${idx}"
  v2k_event INFO "sync.base" "${disk_id}" "disk_done" "{\"target\":\"${target_path}\"}"
}

v2k_transfer_cleanup() {
  # base is run-mode; no persistent nbd devices. Keep placeholder.
  true
}
