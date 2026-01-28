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

V2K_PY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

v2k_require_patch_deps() {
  : "${VDDK_LIBDIR:?missing VDDK_LIBDIR}"
  command -v nbdkit >/dev/null
  command -v nbd-client >/dev/null
  command -v qemu-nbd >/dev/null
  command -v python3 >/dev/null
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

v2k_transfer_patch_all() {
  local manifest="$1" which="$2" jobs="$3" coalesce_gap="$4" chunk="$5"
  local count
  count="$(jq -r '.disks|length' "${manifest}")"

  mkdir -p /tmp
  v2k_load_vddk_cred_from_manifest "${manifest}"

  local passfile
  passfile="$(mktemp /tmp/vmware_pass.XXXXXX)"
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
    server="$(v2k_vmware_require_esxi_host "${manifest}")"
  fi

  local thumbprint="${THUMBPRINT:-}"
  if [[ -z "${thumbprint}" ]]; then
    thumbprint="$(jq -r '.source.vddk.thumbprint // empty' "${manifest}" 2>/dev/null || true)"
  fi
  if [[ -z "${thumbprint}" ]]; then
    thumbprint="$(v2k_vmware_get_thumbprint "${server}")"
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

  # Optional: aggressively cleanup leftover processes from the same run-id
  if [[ "${V2K_FORCE_CLEANUP:-0}" == "1" ]]; then
    v2k_force_cleanup_run "${V2K_RUN_ID:-}" || true
  fi

  local i
  for ((i=0;i<count;i++)); do
    v2k_transfer_patch_one "${manifest}" "${which}" "${i}" "${server}" "${thumbprint}" "${vm_moref}" "${snap_name}" "${snap_moref}" "${coalesce_gap}" "${chunk}" "${passfile}"
  done
}

v2k_transfer_patch_one() {
  local manifest="$1" which="$2" idx="$3" server="$4" thumbprint="$5" vm_moref="$6" snap_name="$7" snap_moref="$8" coalesce_gap="$9" chunk="${10}" passfile="${11}"
  (
    set -euo pipefail

    local disk_id vmdk_path target_path
    disk_id="$(jq -r ".disks[$idx].disk_id" "${manifest}")"
    vmdk_path="$(jq -r ".disks[$idx].vmdk.path" "${manifest}")"  # fallback/reference only
    target_path="$(jq -r ".disks[$idx].transfer.target_path" "${manifest}")"

    local size_bytes
    size_bytes="$(jq -r ".disks[$idx].size_bytes // 0" "${manifest}")"    

    local fmt st kind
    fmt="$(jq -r '.target.format // "qcow2"' "${manifest}")"
    st="$(jq -r '.target.storage.type // "file"' "${manifest}")"
    if [[ "${st}" == "file" && "${fmt}" == "qcow2" ]]; then kind="file-qcow2"
    elif [[ "${st}" == "file" && "${fmt}" == "raw" ]]; then kind="file-raw"
    elif [[ "${st}" == "block" ]]; then kind="block-device"
    elif [[ "${st}" == "rbd" ]]; then kind="rbd"
    else echo "Unsupported target: storage=${st} format=${fmt}" >&2; exit 31; fi

    v2k_event INFO "sync.${which}" "${disk_id}" "disk_start" "{\"snapshot\":\"${snap_name}\",\"vmdk\":\"${vmdk_path}\",\"target\":\"${target_path}\"}"

    if [[ "${V2K_DRY_RUN:-0}" -eq 1 ]]; then
      v2k_event INFO "sync.${which}" "${disk_id}" "dry_run" "{}"
      v2k_manifest_inc_incr_seq "${manifest}" "${idx}"
      return 0
    fi

    # ---- resources we must cleanup even on failure ----
    local src_dev="" dst_dev="" sock="" pidfile="" nbdlog=""

    cleanup() {
      set +e

      # Detach target first (flush writes)
      if [[ -n "${dst_dev}" ]]; then
        if [[ "${kind}" != "block-device" ]]; then
          v2k_nbd_disconnect "${dst_dev}" >/dev/null 2>&1 || true
        else
          [[ -b "${dst_dev}" ]] && blockdev --flushbufs "${dst_dev}" >/dev/null 2>&1 || true
        fi
      fi

      # Detach source
      # NOTE:
      #   src_dev is connected by nbd-client (unix socket export).
      #   If v2k_nbd_disconnect is implemented with qemu-nbd -d only,
      #   src_dev will leak and remain connected (e.g., /dev/nbd0).
      if [[ -n "${src_dev}" ]]; then
        # try nbd-client detach first (safe even if not connected)
        nbd-client -d "${src_dev}" >/dev/null 2>&1 || true
        # then try qemu-nbd detach as fallback (safe even if not connected)
        qemu-nbd -d "${src_dev}" >/dev/null 2>&1 || true
        # keep legacy helper as well (in case it has extra logic)
        v2k_nbd_disconnect "${src_dev}" >/dev/null 2>&1 || true
      fi

      # Stop nbdkit safely (PID ONLY; verify cmdline contains sock token)
      v2k_nbdkit_stop "${pidfile}" "${sock}" >/dev/null 2>&1 || true

      [[ -n "${sock}" ]] && rm -f "${sock}" >/dev/null 2>&1 || true
      [[ -n "${pidfile}" ]] && rm -f "${pidfile}" >/dev/null 2>&1 || true

      [[ -n "${src_dev}" ]] && v2k_nbd_free "${src_dev}" >/dev/null 2>&1 || true
      if [[ -n "${dst_dev}" && "${kind}" != "block-device" ]]; then
        v2k_nbd_free "${dst_dev}" >/dev/null 2>&1 || true
      fi
    }
    # NOTE: keep trap as safety net, but ensure cleanup routines never kill our own shell.
    trap cleanup EXIT INT TERM

    # Allocate NBD devices
    src_dev="$(v2k_nbd_alloc)"
    if [[ "${kind}" == "block-device" ]]; then
      dst_dev="${target_path}"
    else
      dst_dev="$(v2k_nbd_alloc)"
    fi

    # Prepare unique socket/pidfile (avoid collisions across parallel runs)
    sock="$(mktemp -u /tmp/v2k_src.XXXXXX.sock)"
    pidfile="$(mktemp /tmp/v2k_nbdkit.XXXXXX.pid)"
    rm -f "${sock}" >/dev/null 2>&1 || true

    # Explicit cleanup (do not rely on trap). Safe to call multiple times.
    local cleaned=0
    cleanup_patch() {
      [[ "${cleaned}" -eq 1 ]] && return 0
      cleaned=1

      # Detach/destroy in reverse order
      nbd-client -d "${src_dev}" >/dev/null 2>&1 || true
      if [[ "${kind}" != "block-device" ]]; then
        v2k_nbd_disconnect "${dst_dev}" >/dev/null 2>&1 || true
      fi
      v2k_nbd_disconnect "${src_dev}" >/dev/null 2>&1 || true

      v2k_nbdkit_stop "${pidfile}" "${sock}" >/dev/null 2>&1 || true
      rm -f "${sock}" >/dev/null 2>&1 || true

      v2k_nbd_free "${src_dev}" >/dev/null 2>&1 || true
      if [[ "${kind}" != "block-device" ]]; then
        v2k_nbd_free "${dst_dev}" >/dev/null 2>&1 || true
      fi
    }

    local logdir="${V2K_WORKDIR}/logs"; mkdir -p "${logdir}"
    nbdlog="${logdir}/nbdkit_${which}_${idx}.log"
    v2k_event INFO "sync.${which}" "${disk_id}" "nbdkit_log" "{\"path\":\"${nbdlog}\"}"

    # Query changed areas via pyvmomi helper
    export VCENTER_HOST="${GOVC_URL:?missing GOVC_URL}"
    export VCENTER_USER="${GOVC_USERNAME:?missing GOVC_USERNAME}"
    export VCENTER_PASS="${GOVC_PASSWORD:?missing GOVC_PASSWORD}"
    export VCENTER_INSECURE="${GOVC_INSECURE:-1}"

    local last_change_id
    last_change_id="$(jq -r ".disks[$idx].cbt.last_change_id // empty" "${manifest}" 2>/dev/null || true)"

    local areas_json

    areas_json="$(python3 "${V2K_PY_DIR}/vmware_changed_areas.py" \
        --vm "$(jq -r '.source.vm.name' "${manifest}")" \
        --snapshot "${snap_name}" \
        --disk-id "${disk_id}" \
        --change-id "${last_change_id}")"

    # IMPORTANT: snapshot view must read from snapshot disk backing (delta chain top).
    local snap_vmdk_path
    snap_vmdk_path="$(printf '%s' "${areas_json}" | jq -r '.vmdk_path // empty')"
    if [[ -z "${snap_vmdk_path}" ]]; then
      echo "Failed to resolve snapshot vmdk_path for disk=${disk_id} snapshot=${snap_name}. Cannot patch without snapshot disk chain." >&2
      exit 41
    fi

    local areas_count bytes_total new_change_id
    areas_count="$(echo "${areas_json}" | jq -r '.areas|length')"
    bytes_total="$(echo "${areas_json}" | jq -r '[.areas[].length] | add // 0')"
    new_change_id="$(echo "${areas_json}" | jq -r '.new_change_id // empty')"

    # No changed areas is a valid no-op incremental/final sync.
    if [[ "${areas_count}" -eq 0 ]]; then
      v2k_event INFO "sync.${which}" "${disk_id}" "no_changes" "{}"
      if [[ -n "${new_change_id}" && "${new_change_id}" != "null" ]]; then
        v2k_manifest_advance_cbt_change_ids "${manifest}" "${idx}" "${last_change_id}" "${new_change_id}"
      fi
      v2k_manifest_inc_incr_seq "${manifest}" "${idx}"
      v2k_event INFO "sync.${which}" "${disk_id}" "disk_done" "{\"bytes_written\":0,\"areas\":0}"
      cleanup_patch
      return 0
    fi

    v2k_event INFO "sync.${which}" "${disk_id}" "changed_areas_fetched" "{\"areas\":${areas_count},\"bytes\":${bytes_total}}"

    # Start nbdkit (read-only) for snapshot view (do NOT swallow failures)
    # IMPORTANT: run in background and wait for pidfile/socket readiness.
    LD_LIBRARY_PATH="${VDDK_LIBDIR}" \
    nbdkit -r -U "${sock}" -P "${pidfile}" vddk \
      libdir="${VDDK_LIBDIR}" \
      server="${server}" \
      user="${VDDK_USER}" \
      password=+"${passfile}" \
      thumbprint="${thumbprint}" \
      vm="moref=${vm_moref}" \
      snapshot="${snap_moref}" \
      transports=nbd:nbdssl \
      file="${snap_vmdk_path}" >>"$nbdlog" 2>&1 &
    nbdkit_bg_pid=$!

    # Wait for pidfile creation (race-safe) and ensure process is alive
    for _ in {1..50}; do
      [[ -s "${pidfile}" ]] && break
      kill -0 "${nbdkit_bg_pid}" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if [[ ! -s "${pidfile}" ]]; then
      echo "nbdkit did not create pidfile: ${pidfile}" >&2
      tail -n 80 "${nbdlog}" >&2 || true
      cleanup_patch
      exit 42
    fi
    local nbdkit_pid
    nbdkit_pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -z "${nbdkit_pid}" || ! -d "/proc/${nbdkit_pid}" ]]; then
      echo "nbdkit process not running (pid=${nbdkit_pid})" >&2
      tail -n 80 "${nbdlog}" >&2 || true
      cleanup_patch
      exit 43
    fi

    if ! v2k_wait_unix_socket "${sock}" 30 1; then
      cleanup_patch
      v2k_event ERROR "sync.${which}" "${disk_id}" "nbdkit_socket_not_ready" "{\"sock\":\"${sock}\"}"
      exit 40
    fi

    # Connect source socket to src_dev
    nbd-client -u -N default "${sock}" "${src_dev}" >/dev/null

    # Map target to dst_dev
    if [[ "${kind}" != "block-device" ]]; then
      prepare_target_device --kind "${kind}" --path "${target_path}" --nbd-dev "${dst_dev}" --size-bytes "${size_bytes}" >/dev/null
      udevadm settle >/dev/null 2>&1 || true
      sleep 1
    fi

    if [[ "${areas_count}" -gt 0 ]]; then
      python3 "${V2K_PY_DIR}/patch_apply.py" \
        --source "${src_dev}" \
        --target "${dst_dev}" \
        --areas-json "${areas_json}" \
        --coalesce-gap "${coalesce_gap}" \
        --chunk "${chunk}" \
        || { cleanup_patch; exit 41; }
    fi

    sync || true
    if [[ "${kind}" != "block-device" ]]; then
      [[ -b "${dst_dev}" ]] && blockdev --flushbufs "${dst_dev}" >/dev/null 2>&1 || true
    fi

    # Advance CBT changeIds ONLY after successful apply/flush.
    # - base_change_id will be fixed to the previous last_change_id on the first successful patch.
    # - last_change_id advances to new_change_id.
    if [[ -n "${new_change_id}" && "${new_change_id}" != "null" ]]; then
      v2k_manifest_advance_cbt_change_ids "${manifest}" "${idx}" "${last_change_id}" "${new_change_id}"
    fi

    # NOTE(v1): we only report new_change_id (manifest persistence can be added when manifest.sh exposes setter)

    v2k_manifest_set_disk_metric_incr "${manifest}" "${idx}" "${bytes_total}" "${areas_count}"
    v2k_manifest_inc_incr_seq "${manifest}" "${idx}"

    v2k_event INFO "sync.${which}" "${disk_id}" "disk_done" "{\"bytes_written\":${bytes_total},\"areas\":${areas_count}}"

    cleanup_patch
  )
}
