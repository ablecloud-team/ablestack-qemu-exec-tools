#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/v2k_ubuntu_initramfs_smoke"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/engine.sh"

v2k_event() {
  return 0
}
export V2K_JSON_OUT=1

mount_log="${WORK_DIR}/mount.log"
chroot_log="${WORK_DIR}/chroot.log"
mock_mode="success"
mock_kver=""

# shellcheck disable=SC2317
findmnt() {
  return 1
}

# shellcheck disable=SC2317
mount() {
  printf '%s\n' "$*" >> "${mount_log}"
  return 0
}

# shellcheck disable=SC2317
cp() {
  if [[ "$*" == *"/boot/"* ]]; then
    command cp "$@"
  fi
  return 0
}

# shellcheck disable=SC2317
chroot() {
  local mock_root="$1"
  local mock_command="$*"
  local mock_image=""
  printf '%s\n' "${mock_command}" >> "${chroot_log}"

  case "${mock_command}" in
    *"command -v dracut"*)
      return 0
      ;;
    *"command -v update-initramfs"*)
      return 0
      ;;
    *"command -v mkinitramfs"*)
      return 0
      ;;
    *"grubby --default-kernel"*)
      return 0
      ;;
    *"lsinitramfs"*)
      if [[ "${mock_command}" == *".v2k-"* ]]; then
        if [[ "${mock_mode}" == "verify_fail" ]]; then
          printf '%s\n' \
            "usr/lib/modules/${mock_kver}/virtio_pci.ko" \
            "usr/lib/modules/${mock_kver}/virtio_scsi.ko" \
            "usr/lib/modules/${mock_kver}/virtio_blk.ko" \
            "usr/lib/modules/${mock_kver}/scsi_mod.ko" \
            "usr/lib/modules/${mock_kver}/dm-mod.ko"
        else
          printf '%s\n' \
            "usr/lib/modules/${mock_kver}/virtio_pci.ko" \
            "usr/lib/modules/${mock_kver}/virtio_scsi.ko" \
            "usr/lib/modules/${mock_kver}/virtio_blk.ko" \
            "usr/lib/modules/${mock_kver}/scsi_mod.ko" \
            "usr/lib/modules/${mock_kver}/dm-mod.ko" \
            "usr/sbin/lvm"
        fi
      elif [[ "${mock_mode}" == "existing_valid" ]]; then
        printf '%s\n' \
          "usr/lib/modules/${mock_kver}/virtio_pci.ko" \
          "usr/lib/modules/${mock_kver}/virtio_scsi.ko" \
          "usr/lib/modules/${mock_kver}/virtio_blk.ko" \
          "usr/lib/modules/${mock_kver}/scsi_mod.ko"
      else
        printf '%s\n' "usr/lib/modules/${mock_kver}/vmw_pvscsi.ko"
      fi
      return 0
      ;;
    *"mkinitramfs -o "*)
      mock_image="${mock_command#*mkinitramfs -o \'}"
      mock_image="${mock_image%%\'*}"
      printf '%s\n' "staged Ubuntu initramfs" > "${mock_root}${mock_image}"
      return 0
      ;;
  esac
  return 0
}

prepare_ubuntu_root() {
  local root="$1"
  local kver="$2"
  mkdir -p \
    "${root}/lib/modules/${kver}/kernel/drivers/virtio" \
    "${root}/etc/initramfs-tools" \
    "${root}/boot"
  printf '%s\n' \
    'ID=ubuntu' \
    'ID_LIKE=debian' \
    'PRETTY_NAME="Ubuntu smoke guest"' \
    > "${root}/etc/os-release"
  printf '%s\n' "kernel module" \
    > "${root}/lib/modules/${kver}/kernel/drivers/virtio/virtio_pci.ko"
  printf '%s\n' "kernel/drivers/virtio/virtio_pci.ko:" \
    > "${root}/lib/modules/${kver}/modules.dep"
  printf '%s\n' "kernel" > "${root}/boot/vmlinuz-${kver}"
  ln -s "boot/vmlinuz-${kver}" "${root}/vmlinuz"
}

ubuntu_root="${WORK_DIR}/ubuntu-root"
ubuntu_kver="5.15.0-139-generic"
prepare_ubuntu_root "${ubuntu_root}" "${ubuntu_kver}"
printf '%s\n' "original Ubuntu initramfs" \
  > "${ubuntu_root}/boot/initrd.img-${ubuntu_kver}"
: > "${mount_log}"
: > "${chroot_log}"
mock_mode="success"
mock_kver="${ubuntu_kver}"

v2k_linux_bootstrap_rebuild_initramfs \
  "${ubuntu_root}" "/dev/v2k-nbd-does-not-exist" 1

grep -Fx -- "staged Ubuntu initramfs" \
  "${ubuntu_root}/boot/initrd.img-${ubuntu_kver}" >/dev/null || {
    echo "[ERR] validated Ubuntu initramfs was not installed" >&2
    exit 1
  }
ubuntu_backup="$(find "${ubuntu_root}/boot" -maxdepth 1 \
  -type f -name "initrd.img-${ubuntu_kver}.v2k-backup*" -print -quit)"
[[ -n "${ubuntu_backup}" ]] || {
  echo "[ERR] original Ubuntu initramfs backup was not retained" >&2
  exit 1
}
grep -Fx -- "original Ubuntu initramfs" "${ubuntu_backup}" >/dev/null || {
  echo "[ERR] original Ubuntu initramfs backup content changed" >&2
  exit 1
}
for required_module in virtio_pci virtio_scsi virtio_blk scsi_mod dm_mod; do
  [[ "$(grep -Ec "^[[:space:]]*${required_module}([[:space:]]|$)" \
      "${ubuntu_root}/etc/initramfs-tools/modules")" -eq 1 ]] || {
    echo "[ERR] initramfs-tools module list missing or duplicated: ${required_module}" >&2
    exit 1
  }
done
grep -Fx -- "MODULES=most" \
  "${ubuntu_root}/etc/initramfs-tools/conf.d/zz-ablestack-v2k" >/dev/null || {
    echo "[ERR] portable initramfs-tools configuration was not persisted" >&2
    exit 1
  }
grep -F -- \
  "mkinitramfs -o '/boot/.initrd.img-${ubuntu_kver}.v2k-" \
  "${chroot_log}" >/dev/null || {
    echo "[ERR] selected Ubuntu kernel was not built into a staged image" >&2
    cat "${chroot_log}" >&2
    exit 1
  }
if grep -F -- "update-initramfs -u -k all" "${chroot_log}" >/dev/null; then
  echo "[ERR] Ubuntu path overwrote all active initramfs images directly" >&2
  exit 1
fi
if grep -F -- "command -v dracut" "${chroot_log}" >/dev/null; then
  echo "[ERR] Ubuntu guest selected dracut despite initramfs-tools distro routing" >&2
  exit 1
fi
grep -Fx -- "-t proc proc ${ubuntu_root}/proc" "${mount_log}" >/dev/null || {
  echo "[ERR] Ubuntu chroot /proc did not use an explicit proc mount" >&2
  exit 1
}
grep -Fx -- "-t sysfs sysfs ${ubuntu_root}/sys" "${mount_log}" >/dev/null || {
  echo "[ERR] Ubuntu chroot /sys did not use an explicit sysfs mount" >&2
  exit 1
}
grep -Fx -- \
  "-t tmpfs -o mode=0755,nosuid,nodev tmpfs ${ubuntu_root}/run" \
  "${mount_log}" >/dev/null || {
    echo "[ERR] Ubuntu chroot /run was not isolated with tmpfs" >&2
    exit 1
  }

existing_root="${WORK_DIR}/existing-root"
existing_kver="6.8.0-60-generic"
prepare_ubuntu_root "${existing_root}" "${existing_kver}"
printf '%s\n' "already portable initramfs" \
  > "${existing_root}/boot/initrd.img-${existing_kver}"
: > "${chroot_log}"
mock_mode="existing_valid"
mock_kver="${existing_kver}"

v2k_linux_bootstrap_rebuild_initramfs \
  "${existing_root}" "/dev/v2k-nbd-does-not-exist" 0

grep -Fx -- "already portable initramfs" \
  "${existing_root}/boot/initrd.img-${existing_kver}" >/dev/null || {
    echo "[ERR] already portable Ubuntu initramfs was replaced" >&2
    exit 1
  }
if grep -F -- "mkinitramfs -o" "${chroot_log}" >/dev/null; then
  echo "[ERR] already portable Ubuntu initramfs was rebuilt unnecessarily" >&2
  exit 1
fi

failure_root="${WORK_DIR}/failure-root"
failure_kver="5.4.0-216-generic"
prepare_ubuntu_root "${failure_root}" "${failure_kver}"
printf '%s\n' "must remain unchanged" \
  > "${failure_root}/boot/initrd.img-${failure_kver}"
: > "${chroot_log}"
mock_mode="verify_fail"
mock_kver="${failure_kver}"

set +e
v2k_linux_bootstrap_rebuild_initramfs \
  "${failure_root}" "/dev/v2k-nbd-does-not-exist" 1
failure_rc=$?
set -e
[[ "${failure_rc}" -eq 83 ]] || {
  echo "[ERR] Ubuntu LVM initramfs without lvm returned rc=${failure_rc}" >&2
  exit 1
}
grep -Fx -- "must remain unchanged" \
  "${failure_root}/boot/initrd.img-${failure_kver}" >/dev/null || {
    echo "[ERR] failed Ubuntu initramfs validation damaged the active image" >&2
    exit 1
  }
if find "${failure_root}/boot" -maxdepth 1 \
    -type f -name '.initrd.img-*.v2k-*' -print -quit | grep -q .; then
  echo "[ERR] failed Ubuntu initramfs validation left a staged image" >&2
  exit 1
fi

unset -f findmnt mount cp chroot

echo "[OK] v2k Ubuntu staged initramfs build, verification, backup, and rollback"
