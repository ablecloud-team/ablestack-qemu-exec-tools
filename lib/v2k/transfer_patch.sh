#!/usr/bin/env bash
# ---------------------------------------------------------------------
# TODO: Copy the exact author/license header from bin/vm_exec.sh here.
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

V2K_PY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

v2k_require_patch_deps() {
  : "${VDDK_LIBDIR:?missing VDDK_LIBDIR}"
  command -v nbdkit >/dev/null
  command -v nbd-client >/dev/null
  command -v qemu-nbd >/dev/null
  command -v python3 >/dev/null
  command -v govc >/dev/null
}

v2k_transfer_patch_all() {
  local manifest="$1" which="$2" jobs="$3" coalesce_gap="$4" chunk="$5"
  local count
  count="$(jq -r '.disks|length' "${manifest}")"

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

  local snap_name
  snap_name="$(jq -r ".disks[0].snapshots.${which}.name" "${manifest}")"
  [[ -n "${snap_name}" && "${snap_name}" != "null" ]] || {
    echo "Snapshot name missing for ${which}. Run: snapshot ${which}" >&2
    exit 30
  }

  local snap_moref
  snap_moref="$(v2k_vmware_snapshot_moref_by_name "${manifest}" "${snap_name}")"
  [[ -n "${snap_moref}" && "${snap_moref}" != "null" ]] || {
    echo "Failed to resolve snapshot moref for name=${snap_name}" >&2
    exit 30
  }

  v2k_require_patch_deps

  local i
  for ((i=0;i<count;i++)); do
    v2k_transfer_patch_one "${manifest}" "${which}" "${i}" "${esxi}" "${thumbprint}" "${vm_moref}" "${snap_name}" "${snap_moref}" "${coalesce_gap}" "${chunk}"
  done
}

v2k_transfer_patch_one() {
  local manifest="$1" which="$2" idx="$3" esxi="$4" thumbprint="$5" vm_moref="$6" snap_name="$7" snap_moref="$8" coalesce_gap="$9" chunk="${10}"

  local disk_id vmdk_path target_path
  disk_id="$(jq -r ".disks[$idx].disk_id" "${manifest}")"
  vmdk_path="$(jq -r ".disks[$idx].vmdk.path" "${manifest}")"
  target_path="$(jq -r ".disks[$idx].transfer.target_path" "${manifest}")"

  v2k_event INFO "sync.${which}" "${disk_id}" "disk_start" "{\"snapshot\":\"${snap_name}\",\"vmdk\":\"${vmdk_path}\",\"target\":\"${target_path}\"}"

  if [[ "${V2K_DRY_RUN:-0}" -eq 1 ]]; then
    v2k_event INFO "sync.${which}" "${disk_id}" "dry_run" "{}"
    v2k_manifest_inc_incr_seq "${manifest}" "${idx}"
    return 0
  fi

  # Allocate NBD devices
  local src_dev dst_dev
  src_dev="$(v2k_nbd_alloc)"
  dst_dev="$(v2k_nbd_alloc)"
  # Prepare unique socket/pidfile
  local sock pidfile
  sock="/tmp/v2k_src_${V2K_RUN_ID:-run}_${idx}.sock"
  pidfile="/tmp/v2k_nbdkit_${V2K_RUN_ID:-run}_${idx}.pid"
  rm -f "${sock}" "${pidfile}" || true

  local logdir="${V2K_WORKDIR}/logs"; mkdir -p "${logdir}"
  local nbdlog="${logdir}/nbdkit_${which}_${idx}.log"
  v2k_event INFO "sync.${which}" "${disk_id}" "nbdkit_log" "{"path":"${nbdlog}"}"

  # Start nbdkit (read-only) for snapshot view
  LD_LIBRARY_PATH="${VDDK_LIBDIR}" \
  nbdkit -r -U "${sock}" -P "${pidfile}" vddk \
    libdir="${VDDK_LIBDIR}" \
    server="${esxi}" \
    user="${GOVC_USERNAME:?missing GOVC_USERNAME}" \
    password=+/tmp/vmware_pass \
    thumbprint="${thumbprint}" \
    vm="moref=${vm_moref}" \
    snapshot="${snap_moref}" \
    transports=nbd:nbdssl \
    file="${vmdk_path}" >"$nbdlog" 2>&1 || true

  if ! v2k_wait_unix_socket "${sock}" 20 1; then
    v2k_kill_pidfile "${pidfile}"
    v2k_nbd_free "${src_dev}"
    v2k_nbd_free "${dst_dev}"
    echo "nbdkit socket not ready: ${sock}" >&2
    exit 40
  fi

  # Connect source socket to src_dev
  nbd-client -u -N default "${sock}" "${src_dev}" >/dev/null

  # Map target qcow2 to dst_dev
  qemu-nbd -f qcow2 --cache=none -c "${dst_dev}" "${target_path}" >/dev/null
  udevadm settle >/dev/null 2>&1 || true
  sleep 1

  # Query changed areas via pyvmomi helper
  export VCENTER_HOST="${GOVC_URL:?missing GOVC_URL}"
  export VCENTER_USER="${GOVC_USERNAME:?missing GOVC_USERNAME}"
  export VCENTER_PASS="${GOVC_PASSWORD:?missing GOVC_PASSWORD}"
  export VCENTER_INSECURE="${GOVC_INSECURE:-1}"

  local areas_json
  areas_json="$(python3 "${V2K_PY_DIR}/vmware_changed_areas.py" \
      --vm "$(jq -r '.source.vm.name' "${manifest}")" \
      --snapshot "${snap_name}" \
      --disk-id "${disk_id}")"

  local areas_count bytes_total
  areas_count="$(echo "${areas_json}" | jq -r '.areas|length')"
  bytes_total="$(echo "${areas_json}" | jq -r '[.areas[].length] | add // 0')"
  v2k_event INFO "sync.${which}" "${disk_id}" "changed_areas_fetched" "{\"areas\":${areas_count},\"bytes\":${bytes_total}}"

  if [[ "${areas_count}" -gt 0 ]]; then
    # Apply patch: /dev/nbdX -> /dev/nbdY
    python3 "${V2K_PY_DIR}/patch_apply.py" \
      --source "${src_dev}" \
      --target "${dst_dev}" \
      --areas-json "${areas_json}" \
      --coalesce-gap "${coalesce_gap}" \
      --chunk "${chunk}"
  fi

  sync || true

  # Cleanup
  v2k_nbd_disconnect "${dst_dev}"
  v2k_nbd_disconnect "${src_dev}"
  v2k_kill_pidfile "${pidfile}"
  rm -f "${sock}" >/dev/null 2>&1 || true
  v2k_nbd_free "${src_dev}"
  v2k_nbd_free "${dst_dev}"

  v2k_manifest_set_disk_metric_incr "${manifest}" "${idx}" "${bytes_total}" "${areas_count}"
  v2k_manifest_inc_incr_seq "${manifest}" "${idx}"

  v2k_event INFO "sync.${which}" "${disk_id}" "disk_done" "{\"bytes_written\":${bytes_total},\"areas\":${areas_count}}"
}
