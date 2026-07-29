#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/v2k_cutover_integrity_smoke"

cleanup() {
  rm -rf "${WORK_DIR}"
}

for cmd in bash jq mount; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: ${cmd}" >&2
    exit 2
  }
done

trap cleanup EXIT
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/mnt"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/engine.sh"

v2k_event() {
  return 0
}
export V2K_JSON_OUT=1

captured_output=""
captured_rc=0
v2k_linux_bootstrap_run_event "test_failure" captured_output captured_rc -- \
  bash -c 'printf "xfs metadata error" >&2; exit 23'
[[ "${captured_rc}" -eq 23 ]] || {
  echo "[ERR] bootstrap command rc was masked: ${captured_rc}" >&2
  exit 1
}
[[ "${captured_output}" == *"xfs metadata error"* ]] || {
  echo "[ERR] bootstrap command stderr was lost: ${captured_output}" >&2
  exit 1
}

nbd_command_log="${WORK_DIR}/qemu-nbd.args"
mock_nbd_size=107374182400
# shellcheck disable=SC2317
qemu-nbd() {
  printf '%s\n' "$*" >> "${nbd_command_log}"
}
# shellcheck disable=SC2317
blockdev() {
  [[ "${1:-}" == "--getsize64" ]] || return 2
  printf '%s\n' "${mock_nbd_size}"
}

v2k_linux_bootstrap_connect_nbd "/dev/rbd3" "raw" "/dev/nbd8"
grep -Fx -- \
  "--connect=/dev/nbd8 --format=raw --cache=none /dev/rbd3" \
  "${nbd_command_log}" >/dev/null || {
    echo "[ERR] raw bootstrap did not pass the explicit qemu-nbd format" >&2
    cat "${nbd_command_log}" >&2
    exit 1
  }

v2k_linux_bootstrap_connect_nbd "${WORK_DIR}/root.qcow2" "qcow2" "/dev/nbd9"
grep -Fx -- \
  "--connect=/dev/nbd9 --format=qcow2 --cache=none ${WORK_DIR}/root.qcow2" \
  "${nbd_command_log}" >/dev/null || {
    echo "[ERR] qcow2 bootstrap did not pass the explicit qemu-nbd format" >&2
    cat "${nbd_command_log}" >&2
    exit 1
  }

if v2k_linux_bootstrap_connect_nbd "/dev/rbd3" "auto" "/dev/nbd10"; then
  echo "[ERR] unsupported bootstrap image format was accepted" >&2
  exit 1
fi

unset -f qemu-nbd blockdev

format_manifest="${WORK_DIR}/format-manifest.json"
cat > "${format_manifest}" <<'JSON'
{
  "target": {
    "format": "raw",
    "storage": {"type": "rbd"}
  }
}
JSON

bootstrap_call=""
v2k_require_linux_bootstrap_deps() {
  return 0
}
v2k_linux_bootstrap_prepare_root_input() {
  printf -v "$2" '%s' "/dev/rbd3"
  printf -v "$3" '%s' ""
}
v2k_linux_bootstrap_one() {
  bootstrap_call="$1|$2"
}

v2k_linux_bootstrap_initramfs "${format_manifest}"
[[ "${bootstrap_call}" == "/dev/rbd3|raw" ]] || {
  echo "[ERR] manifest target format was not propagated to Linux bootstrap: ${bootstrap_call}" >&2
  exit 1
}

unset -f \
  v2k_require_linux_bootstrap_deps \
  v2k_linux_bootstrap_prepare_root_input \
  v2k_linux_bootstrap_one

typed_mount_log="${WORK_DIR}/typed-mount.args"
# shellcheck disable=SC2317
findmnt() {
  return 1
}
# shellcheck disable=SC2317
mount() {
  printf '%s\n' "$*" >> "${typed_mount_log}"
}

v2k_linux_bootstrap_mount_typed_robust \
  "tmpfs" "tmpfs" "${WORK_DIR}/mnt/dev" "mode=0755,nosuid,noexec"
v2k_linux_bootstrap_mount_typed_robust \
  "proc" "proc" "${WORK_DIR}/mnt/proc" ""
v2k_linux_bootstrap_mount_typed_robust \
  "sysfs" "sysfs" "${WORK_DIR}/mnt/sys" ""

grep -Fx -- \
  "-t tmpfs -o mode=0755,nosuid,noexec tmpfs ${WORK_DIR}/mnt/dev" \
  "${typed_mount_log}" >/dev/null || {
    echo "[ERR] chroot /dev was not mounted as tmpfs" >&2
    cat "${typed_mount_log}" >&2
    exit 1
  }
grep -Fx -- \
  "-t proc proc ${WORK_DIR}/mnt/proc" \
  "${typed_mount_log}" >/dev/null || {
    echo "[ERR] chroot /proc was not mounted as proc" >&2
    cat "${typed_mount_log}" >&2
    exit 1
  }
grep -Fx -- \
  "-t sysfs sysfs ${WORK_DIR}/mnt/sys" \
  "${typed_mount_log}" >/dev/null || {
    echo "[ERR] chroot /sys was not mounted as sysfs" >&2
    cat "${typed_mount_log}" >&2
    exit 1
  }
if grep -F -- " /proc ${WORK_DIR}/mnt/proc" "${typed_mount_log}" >/dev/null; then
  echo "[ERR] chroot /proc used the host path as a block-device source" >&2
  cat "${typed_mount_log}" >&2
  exit 1
fi

bootstrap_root="${WORK_DIR}/bootstrap-root"
bootstrap_kver="5.14.0-v2k-test"
mkdir -p \
  "${bootstrap_root}/lib/modules/${bootstrap_kver}" \
  "${bootstrap_root}/etc" \
  "${bootstrap_root}/boot"
printf '%s\n' "kernel" > "${bootstrap_root}/boot/vmlinuz-${bootstrap_kver}"
printf '%s\n' "existing initramfs" > "${bootstrap_root}/boot/initramfs-${bootstrap_kver}.img"
: > "${typed_mount_log}"
chroot_command_log="${WORK_DIR}/chroot-command.log"
mock_chroot_mode="existing_valid"
mock_chroot_kver="${bootstrap_kver}"
# shellcheck disable=SC2317
cp() {
  return 0
}
# shellcheck disable=SC2317
chroot() {
  local mock_root="$1"
  local mock_command="$*"
  local mock_image=""
  printf '%s\n' "${mock_command}" >> "${chroot_command_log}"
  case "${mock_command}" in
    *"grubby --default-kernel"*)
      if [[ "${mock_chroot_mode}" != "no_default" ]]; then
        printf '/boot/vmlinuz-%s\n' "${mock_chroot_kver}"
      fi
      ;;
    *"lsinitrd"*)
      if [[ "${mock_command}" == *".v2k-"* ]]; then
        printf '%s\n' "virtio_pci virtio_scsi virtio_blk scsi_mod"
        if [[ "${mock_chroot_mode}" != "lvm_verify_fail" ]]; then
          printf '%s\n' \
            "lvm" \
            "kernel/drivers/md/dm-mod.ko.xz"
        fi
        if [[ "${mock_chroot_mode}" == "lvm_embedded_devices" ]]; then
          printf '%s\n' "etc/lvm/devices/system.devices"
        fi
      elif [[ "${mock_chroot_mode}" == "existing_valid" ]]; then
        printf '%s\n' "virtio_pci virtio_scsi virtio_blk scsi_mod"
      else
        printf '%s\n' "virtio_pci"
      fi
      ;;
    *"depmod -a"*)
      printf '%s\n' "kernel/drivers/virtio/virtio_pci.ko.xz:" \
        > "${mock_root}/lib/modules/${mock_chroot_kver}/modules.dep"
      ;;
    *"dracut -f"*)
      mock_image="${mock_command##* }"
      mock_image="${mock_image%\'}"
      mock_image="${mock_image#\'}"
      printf '%s\n' "staged initramfs" > "${mock_root}${mock_image}"
      ;;
  esac
  return 0
}

v2k_linux_bootstrap_rebuild_initramfs \
  "${bootstrap_root}" "/dev/v2k-nbd-does-not-exist"

grep -Fx -- \
  "-t proc proc ${bootstrap_root}/proc" \
  "${typed_mount_log}" >/dev/null || {
    echo "[ERR] initramfs rebuild path did not mount proc explicitly" >&2
    cat "${typed_mount_log}" >&2
    exit 1
  }
grep -Fx -- \
  "-t sysfs sysfs ${bootstrap_root}/sys" \
  "${typed_mount_log}" >/dev/null || {
    echo "[ERR] initramfs rebuild path did not mount sysfs explicitly" >&2
    cat "${typed_mount_log}" >&2
    exit 1
  }

if grep -F -- "dracut -f" "${chroot_command_log}" >/dev/null; then
  echo "[ERR] already usable initramfs was rebuilt unnecessarily" >&2
  cat "${chroot_command_log}" >&2
  exit 1
fi

version_root="${WORK_DIR}/version-root"
mkdir -p \
  "${version_root}/lib/modules/5.14.0-9.el9.x86_64" \
  "${version_root}/lib/modules/5.14.0-10.el9.x86_64" \
  "${version_root}/boot"
printf '%s\n' "kernel" > "${version_root}/boot/vmlinuz-5.14.0-9.el9.x86_64"
printf '%s\n' "kernel" > "${version_root}/boot/vmlinuz-5.14.0-10.el9.x86_64"
mock_chroot_mode="no_default"
version_selection="$(v2k_linux_bootstrap_select_kernel "${version_root}")"
[[ "${version_selection}" == $'5.14.0-10.el9.x86_64\thighest_version' ]] || {
  echo "[ERR] kernel fallback did not use version ordering: ${version_selection}" >&2
  exit 1
}

escaped_root="${WORK_DIR}/escaped-root"
mkdir -p "${escaped_root}/boot"
ln -s /usr/lib "${escaped_root}/lib"
if v2k_linux_bootstrap_module_root "${escaped_root}" >/dev/null 2>&1; then
  echo "[ERR] guest module lookup escaped through an absolute /lib symlink" >&2
  exit 1
fi

builtin_root="${WORK_DIR}/builtin-root"
builtin_kver="5.14.0-builtins.el9.x86_64"
mkdir -p "${builtin_root}/lib/modules/${builtin_kver}" "${builtin_root}/boot"
printf '%s\n' \
  "kernel/drivers/scsi/virtio_scsi.ko" \
  "kernel/drivers/block/virtio_blk.ko" \
  "kernel/drivers/scsi/scsi_mod.ko" \
  > "${builtin_root}/lib/modules/${builtin_kver}/modules.builtin"
printf '%s\n' "existing initramfs" > "${builtin_root}/boot/initramfs-${builtin_kver}.img"
mock_chroot_mode="existing_builtins"
mock_chroot_kver="${builtin_kver}"
if ! v2k_linux_bootstrap_verify_initramfs_virtio \
    "${builtin_root}" "${builtin_kver}" \
    "/boot/initramfs-${builtin_kver}.img" "verify_builtin_initramfs"; then
  echo "[ERR] built-in virtio drivers were treated as missing from initramfs" >&2
  exit 1
fi

jq_bin="$(command -v jq)"
# shellcheck disable=SC2317
jq() {
  if [[ "$*" == *'reduce $modules'* ]]; then
    return 1
  fi
  "${jq_bin}" "$@"
}
if v2k_linux_bootstrap_verify_initramfs_virtio \
    "${builtin_root}" "${builtin_kver}" \
    "/boot/initramfs-${builtin_kver}.img" "verify_summary_failure"; then
  echo "[ERR] initramfs module summary failure was accepted as success" >&2
  exit 1
fi
unset -f jq

repair_root="${WORK_DIR}/repair-root"
repair_kver="5.14.0-427.el9.x86_64"
mkdir -p \
  "${repair_root}/lib/modules/${repair_kver}/kernel/drivers/virtio" \
  "${repair_root}/etc" \
  "${repair_root}/boot"
printf '%s\n' "kernel module" \
  > "${repair_root}/lib/modules/${repair_kver}/kernel/drivers/virtio/virtio_pci.ko.xz"
printf '%s\n' "kernel" > "${repair_root}/boot/vmlinuz-${repair_kver}"
printf '%s\n' "original initramfs" > "${repair_root}/boot/initramfs-${repair_kver}.img"
: > "${chroot_command_log}"
mock_chroot_mode="repair"
mock_chroot_kver="${repair_kver}"

v2k_linux_bootstrap_rebuild_initramfs \
  "${repair_root}" "/dev/v2k-nbd-does-not-exist"

[[ -s "${repair_root}/lib/modules/${repair_kver}/modules.dep" ]] || {
  echo "[ERR] missing modules.dep was not repaired before dracut" >&2
  exit 1
}
grep -Fx -- "staged initramfs" "${repair_root}/boot/initramfs-${repair_kver}.img" >/dev/null || {
  echo "[ERR] validated staged initramfs was not installed" >&2
  exit 1
}
grep -F -- "depmod -a '${repair_kver}'" "${chroot_command_log}" >/dev/null || {
  echo "[ERR] depmod repair command was not executed" >&2
  cat "${chroot_command_log}" >&2
  exit 1
}
grep -F -- \
  "/usr/bin/env -u LVM_SYSTEM_DIR /bin/bash -lc dracut -f -v --no-hostonly --fstab" \
  "${chroot_command_log}" >/dev/null || {
    echo "[ERR] dracut did not clear host LVM state and disable host-only mode" >&2
    cat "${chroot_command_log}" >&2
    exit 1
  }
grep -F -- "--add 'lvm' --add-drivers 'virtio_pci virtio_scsi virtio_blk scsi_mod dm_mod'" \
  "${chroot_command_log}" >/dev/null || {
    echo "[ERR] dracut did not explicitly include the target storage stack" >&2
    cat "${chroot_command_log}" >&2
    exit 1
  }
grep -F -- "--kver '${repair_kver}' '/boot/.initramfs-" \
  "${chroot_command_log}" >/dev/null || {
    echo "[ERR] dracut did not build into a staged initramfs path" >&2
    cat "${chroot_command_log}" >&2
    exit 1
  }
if grep -F -- \
    "--kver '${repair_kver}' '/boot/initramfs-${repair_kver}.img'" \
    "${chroot_command_log}" >/dev/null; then
  echo "[ERR] dracut overwrote the live initramfs directly" >&2
  cat "${chroot_command_log}" >&2
  exit 1
fi

lvm_root="${WORK_DIR}/lvm-root"
lvm_kver="5.14.0-427.28.1.el9_4.x86_64"
mkdir -p \
  "${lvm_root}/lib/modules/${lvm_kver}/kernel/drivers/virtio" \
  "${lvm_root}/etc/lvm/devices" \
  "${lvm_root}/boot"
printf '%s\n' "kernel module" \
  > "${lvm_root}/lib/modules/${lvm_kver}/kernel/drivers/virtio/virtio_pci.ko.xz"
printf '%s\n' "kernel/drivers/virtio/virtio_pci.ko.xz:" \
  > "${lvm_root}/lib/modules/${lvm_kver}/modules.dep"
printf '%s\n' "kernel" > "${lvm_root}/boot/vmlinuz-${lvm_kver}"
printf '%s\n' "original LVM initramfs" > "${lvm_root}/boot/initramfs-${lvm_kver}.img"
printf '%s\n' "IDTYPE=sys_wwid IDNAME=vmware-root" \
  > "${lvm_root}/etc/lvm/devices/system.devices"
: > "${chroot_command_log}"
mock_chroot_mode="lvm_repair"
mock_chroot_kver="${lvm_kver}"

v2k_linux_bootstrap_rebuild_initramfs \
  "${lvm_root}" "/dev/v2k-nbd-does-not-exist" 1

[[ ! -e "${lvm_root}/etc/lvm/devices/system.devices" ]] || {
  echo "[ERR] migrated Rocky LVM devices file was left active" >&2
  exit 1
}
lvm_devices_backup="$(find "${lvm_root}/etc/lvm/devices" -maxdepth 1 \
  -type f -name 'system.devices.v2k-backup*' -print -quit)"
[[ -n "${lvm_devices_backup}" ]] || {
  echo "[ERR] original LVM devices file was not preserved" >&2
  exit 1
}
grep -F -- "IDTYPE=sys_wwid IDNAME=vmware-root" "${lvm_devices_backup}" >/dev/null || {
  echo "[ERR] LVM devices file backup content changed" >&2
  exit 1
}
grep -Fx -- "staged initramfs" "${lvm_root}/boot/initramfs-${lvm_kver}.img" >/dev/null || {
  echo "[ERR] validated LVM initramfs was not installed" >&2
  exit 1
}
grep -Fx -- 'hostonly="no"' \
  "${lvm_root}/etc/dracut.conf.d/99-ablestack-v2k-virtio.conf" >/dev/null || {
    echo "[ERR] portable dracut configuration was not persisted" >&2
    exit 1
  }
grep -F -- \
  "lsinitrd '/boot/.initramfs-${lvm_kver}.v2k-" \
  "${chroot_command_log}" >/dev/null || {
  echo "[ERR] staged initramfs LVM stack was not verified" >&2
  cat "${chroot_command_log}" >&2
  exit 1
}

mock_chroot_mode="lvm_embedded_devices"
if v2k_linux_bootstrap_verify_initramfs_lvm \
    "${lvm_root}" "${lvm_kver}" \
    "/boot/.initramfs-${lvm_kver}.v2k-embedded.img" \
    "verify_embedded_lvm_devices"; then
  echo "[ERR] initramfs containing stale system.devices was accepted" >&2
  exit 1
fi

lvm_fail_root="${WORK_DIR}/lvm-fail-root"
lvm_fail_kver="5.14.0-500.1.el9.x86_64"
mkdir -p \
  "${lvm_fail_root}/lib/modules/${lvm_fail_kver}/kernel/drivers/virtio" \
  "${lvm_fail_root}/etc/lvm/devices" \
  "${lvm_fail_root}/boot"
printf '%s\n' "kernel module" \
  > "${lvm_fail_root}/lib/modules/${lvm_fail_kver}/kernel/drivers/virtio/virtio_pci.ko.xz"
printf '%s\n' "kernel/drivers/virtio/virtio_pci.ko.xz:" \
  > "${lvm_fail_root}/lib/modules/${lvm_fail_kver}/modules.dep"
printf '%s\n' "kernel" > "${lvm_fail_root}/boot/vmlinuz-${lvm_fail_kver}"
printf '%s\n' "must remain unchanged" \
  > "${lvm_fail_root}/boot/initramfs-${lvm_fail_kver}.img"
printf '%s\n' "IDTYPE=sys_wwid IDNAME=vmware-root" \
  > "${lvm_fail_root}/etc/lvm/devices/system.devices"
: > "${chroot_command_log}"
mock_chroot_mode="lvm_verify_fail"
mock_chroot_kver="${lvm_fail_kver}"

set +e
v2k_linux_bootstrap_rebuild_initramfs \
  "${lvm_fail_root}" "/dev/v2k-nbd-does-not-exist" 1
lvm_fail_rc=$?
set -e
[[ "${lvm_fail_rc}" -eq 82 ]] || {
  echo "[ERR] incomplete staged LVM initramfs returned rc=${lvm_fail_rc}" >&2
  exit 1
}
grep -Fx -- "must remain unchanged" \
  "${lvm_fail_root}/boot/initramfs-${lvm_fail_kver}.img" >/dev/null || {
    echo "[ERR] failed LVM validation damaged the existing initramfs" >&2
    exit 1
  }
grep -F -- "IDTYPE=sys_wwid IDNAME=vmware-root" \
  "${lvm_fail_root}/etc/lvm/devices/system.devices" >/dev/null || {
    echo "[ERR] failed LVM validation did not restore system.devices" >&2
    exit 1
  }

invalid_root="${WORK_DIR}/invalid-root"
invalid_kver="5.14.0-500.el9.x86_64"
mkdir -p \
  "${invalid_root}/lib/modules/${invalid_kver}" \
  "${invalid_root}/etc" \
  "${invalid_root}/boot"
printf '%s\n' "kernel" > "${invalid_root}/boot/vmlinuz-${invalid_kver}"
printf '%s\n' "must remain unchanged" > "${invalid_root}/boot/initramfs-${invalid_kver}.img"
: > "${chroot_command_log}"
mock_chroot_mode="missing_payload"
mock_chroot_kver="${invalid_kver}"

set +e
v2k_linux_bootstrap_rebuild_initramfs \
  "${invalid_root}" "/dev/v2k-nbd-does-not-exist"
invalid_rc=$?
set -e
[[ "${invalid_rc}" -eq 82 ]] || {
  echo "[ERR] incomplete module payload returned unexpected rc=${invalid_rc}" >&2
  exit 1
}
grep -Fx -- "must remain unchanged" "${invalid_root}/boot/initramfs-${invalid_kver}.img" >/dev/null || {
  echo "[ERR] invalid module tree damaged the existing initramfs" >&2
  exit 1
}
if grep -F -- "dracut -f" "${chroot_command_log}" >/dev/null; then
  echo "[ERR] dracut ran despite an incomplete kernel module payload" >&2
  cat "${chroot_command_log}" >&2
  exit 1
fi

unset -f findmnt mount cp chroot

# Consumed dynamically by the sourced engine.
# shellcheck disable=SC2034
V2K_BOOTSTRAP_LOCK_FD=10
lock_probe_output=""
lock_probe_rc=0
eval "exec 10>${WORK_DIR}/bootstrap.lock"
v2k_linux_bootstrap_run_capture lock_probe_output lock_probe_rc -- \
  bash -c 'if [[ -e /proc/self/fd/10 ]]; then echo leaked; exit 1; fi; echo clean'
[[ "${lock_probe_rc}" -eq 0 && "${lock_probe_output}" == "clean" ]] || {
  echo "[ERR] bootstrap lock FD leaked into a child command: rc=${lock_probe_rc} out=${lock_probe_output}" >&2
  exit 1
}
[[ -e /proc/$$/fd/10 ]] || {
  echo "[ERR] bootstrap lock FD was closed in the parent shell" >&2
  exit 1
}
eval "exec 10>&-"
# shellcheck disable=SC2034
V2K_BOOTSTRAP_LOCK_FD=""

lvm_report='{
  "report": [
    {
      "vg": [
        {"vg_name": " rl "},
        {"vg_name": "data"},
        {"vg_name": "rl"}
      ]
    }
  ]
}'
lvm_vgs="$(printf '%s' "${lvm_report}" | v2k_linux_bootstrap_lvm_vg_names_from_report)"
[[ "${lvm_vgs}" == $'data\nrl' ]] || {
  echo "[ERR] structured LVM VG report was not normalized: ${lvm_vgs}" >&2
  exit 1
}
if printf '%s' "File descriptor 10 leaked ${lvm_report}" \
    | v2k_linux_bootstrap_lvm_vg_names_from_report >/dev/null 2>&1; then
  echo "[ERR] contaminated LVM output was accepted as a structured report" >&2
  exit 1
fi

set +e
v2k_linux_bootstrap_mount_robust \
  "/dev/v2k-device-does-not-exist" "${WORK_DIR}/mnt" "ro"
mount_rc=$?
set -e
[[ "${mount_rc}" -ne 0 ]] || {
  echo "[ERR] failed mount was reported as success" >&2
  exit 1
}

manifest="${WORK_DIR}/manifest.json"
cat > "${manifest}" <<'JSON'
{
  "source": {
    "vm": {
      "cpu": 4,
      "memory_mb": 8192,
      "firmware": "bios",
      "secure_boot": false
    }
  },
  "target": {
    "cloud": {
      "cpu_speed": "1000"
    }
  },
  "runtime": {},
  "disks": [
    {
      "size_bytes": 107374182400,
      "controller": {"type": "VirtualLsiLogicController"},
      "cbt": {
        "enabled": true,
        "base_change_id": "*",
        "last_change_id": "change-1"
      }
    }
  ]
}
JSON

v2k_select_bootstrap_fallback \
  "${manifest}" "linux_bootstrap" 80 "test bootstrap failure" "sata"

jq -e '
  .runtime.bootstrap_fallback.enabled == true
  and .runtime.bootstrap_fallback.bus == "sata"
  and (.bootstrap_fallback | not)
' "${manifest}" >/dev/null || {
  echo "[ERR] SATA fallback was not persisted at the canonical runtime path" >&2
  cat "${manifest}" >&2
  exit 1
}

deploy_params="$(v2k_cloud_target_source_deploy_params_json "${manifest}")"
jq -e '."details[0].rootDiskController" == "sata"' <<<"${deploy_params}" >/dev/null || {
  echo "[ERR] Cloud deploy properties did not consume SATA fallback" >&2
  printf '%s\n' "${deploy_params}" >&2
  exit 1
}

complete_coverage='{
  "coverage": {
    "mode": "delta",
    "complete": true,
    "start_offset": 0,
    "end_offset": 107374182400,
    "disk_capacity": 107374182400,
    "pages": 2
  },
  "areas": []
}'
incomplete_coverage='{
  "coverage": {
    "mode": "delta",
    "complete": false,
    "start_offset": 0,
    "end_offset": 53687091200,
    "disk_capacity": 107374182400,
    "pages": 1
  },
  "areas": []
}'

v2k_validate_cbt_coverage "${complete_coverage}" 107374182400 || {
  echo "[ERR] complete CBT coverage was rejected" >&2
  exit 1
}
if v2k_validate_cbt_coverage "${incomplete_coverage}" 107374182400; then
  echo "[ERR] incomplete CBT coverage was accepted" >&2
  exit 1
fi

coverage_record='{
  "mode": "delta",
  "complete": true,
  "start_offset": 0,
  "end_offset": 107374182400,
  "disk_capacity": 107374182400,
  "pages": 2,
  "phase": "final",
  "new_change_id": "change-2"
}'
v2k_manifest_advance_cbt_change_ids \
  "${manifest}" 0 "change-1" "change-2" "${coverage_record}"

jq -e '
  .disks[0].cbt.base_change_id == "change-1"
  and .disks[0].cbt.last_change_id == "change-2"
  and .disks[0].cbt.last_coverage.complete == true
  and .disks[0].cbt.last_coverage.new_change_id == .disks[0].cbt.last_change_id
' "${manifest}" >/dev/null || {
  echo "[ERR] changeId and coverage were not committed together" >&2
  cat "${manifest}" >&2
  exit 1
}

echo "[OK] v2k cutover error propagation, CBT gate, and SATA fallback integrity"
