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

FTCTL_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FTCTL_AUTOMATION_ENV_DEFAULT="${FTCTL_TEST_ROOT}/automation.env"

ftctl_test_info() {
  printf '[FTCTL-TEST] %s\n' "$*"
}

ftctl_test_warn() {
  printf '[FTCTL-TEST][WARN] %s\n' "$*" >&2
}

ftctl_test_die() {
  printf '[FTCTL-TEST][FAIL] %s\n' "$*" >&2
  exit 1
}

ftctl_test_require_cmds() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      ftctl_test_warn "missing command: ${cmd}"
      missing=1
    fi
  done
  (( missing == 0 )) || ftctl_test_die "required commands are missing"
}

ftctl_test_load_envs() {
  local automation_env="${1-${FTCTL_AUTOMATION_ENV_DEFAULT}}"
  local case_env="${2-}"

  [[ -f "${automation_env}" ]] || ftctl_test_die "automation env not found: ${automation_env}"
  [[ -f "${case_env}" ]] || ftctl_test_die "case env not found: ${case_env}"

  set -a
  # shellcheck source=/dev/null
  source "${automation_env}"
  # shellcheck source=/dev/null
  source "${case_env}"
  set +a

  [[ -n "${TEST_ID:-}" ]] || ftctl_test_die "TEST_ID is required"
  [[ -n "${VM_NAME:-}" ]] || ftctl_test_die "VM_NAME is required"
  [[ -n "${PRIMARY_LIBVIRT_URI:-}" ]] || ftctl_test_die "PRIMARY_LIBVIRT_URI is required"
  [[ -n "${SECONDARY_LIBVIRT_URI:-}" ]] || ftctl_test_die "SECONDARY_LIBVIRT_URI is required"
  [[ -n "${TEST_LOG_ROOT:-}" ]] || ftctl_test_die "TEST_LOG_ROOT is required"
}

ftctl_test_case_log_dir() {
  printf '%s/%s\n' "${TEST_LOG_ROOT}" "${TEST_ID}"
}

ftctl_test_prepare_log_dir() {
  local dir
  dir="$(ftctl_test_case_log_dir)"
  mkdir -p "${dir}"
}

ftctl_test_log_path() {
  local name="${1-}"
  printf '%s/%s\n' "$(ftctl_test_case_log_dir)" "${name}"
}

ftctl_test_run_and_log() {
  local log_name="${1-}"
  shift
  local log_path
  log_path="$(ftctl_test_log_path "${log_name}")"
  "$@" 2>&1 | tee "${log_path}"
}

ftctl_test_remote_run_and_log() {
  local log_name="${1-}"
  shift
  local host="${1-}"
  shift
  local log_path
  log_path="$(ftctl_test_log_path "${log_name}")"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SECONDARY_SSH_USER}@${host}" "$@" 2>&1 | tee "${log_path}"
}

ftctl_test_disk_get() {
  local idx="${1-}"
  local field="${2-}"
  local var="DISK_${idx}_${field}"
  printf '%s' "${!var-}"
}

ftctl_test_disk_source_image_get() {
  local idx="${1-}"
  local var="DISK_${idx}_SOURCE_IMAGE"
  printf '%s' "${!var-}"
}

ftctl_test_protected_disk_indices() {
  local i=1
  while (( i <= PROTECTED_DISK_COUNT )); do
    printf '%s\n' "${i}"
    i=$((i + 1))
  done
}

ftctl_test_write_cluster_config() {
  ftctl_test_run_and_log "${TEST_ID}.cluster.json" \
    ablestack_vm_ftctl config init-cluster \
    --cluster-name "${PRIMARY_HOST}-cluster" \
    --local-host-id host-01 >/dev/null

  ablestack_vm_ftctl config host-upsert \
    --host-id host-01 \
    --role primary \
    --management-ip "${PRIMARY_MGMT_IP}" \
    --libvirt-uri "${PRIMARY_LIBVIRT_URI}" \
    --blockcopy-ip "${PRIMARY_BLOCKCOPY_IP}" \
    --xcolo-control-ip "${PRIMARY_BLOCKCOPY_IP}" \
    --xcolo-data-ip "${PRIMARY_BLOCKCOPY_IP}" >/dev/null

  ablestack_vm_ftctl config host-upsert \
    --host-id host-02 \
    --role secondary \
    --management-ip "${SECONDARY_MGMT_IP}" \
    --libvirt-uri "${SECONDARY_LIBVIRT_URI}" \
    --blockcopy-ip "${SECONDARY_BLOCKCOPY_IP}" \
    --xcolo-control-ip "${SECONDARY_BLOCKCOPY_IP}" \
    --xcolo-data-ip "${SECONDARY_BLOCKCOPY_IP}" >/dev/null

  ablestack_vm_ftctl config show --json | tee "$(ftctl_test_log_path "${TEST_ID}.cluster.json")" >/dev/null
}

ftctl_test_build_profile() {
  local profile_path="${1-}"
  local persistence="${2-}"
  local backend="${3-}"
  local target_scope="${4-}"
  local secondary_vm="${5-}"
  local disk_map="${6-}"
  local target_dir="${7-}"
  local export_addr="${8-}"
  local export_port="${9-}"
  local export_name="${10-}"

  cat > "${profile_path}" <<EOF
FTCTL_PROFILE_NAME="${TEST_ID,,}"
FTCTL_PROFILE_MODE="ha"
FTCTL_PROFILE_PRIMARY_URI="${PRIMARY_LIBVIRT_URI}"
FTCTL_PROFILE_SECONDARY_URI="${SECONDARY_LIBVIRT_URI}"
FTCTL_PROFILE_BACKEND_MODE="${backend}"
FTCTL_PROFILE_TARGET_STORAGE_SCOPE="${target_scope}"
FTCTL_PROFILE_SECONDARY_VM_NAME="${secondary_vm}"
FTCTL_PROFILE_DISK_MAP="${disk_map}"
FTCTL_PROFILE_FAILBACK_DISK_MAP="source"
FTCTL_PROFILE_NETWORK_MAP="inherit"
FTCTL_PROFILE_FENCING_POLICY="${FENCING_POLICY}"
FTCTL_PROFILE_FENCING_SSH_USER="${SECONDARY_SSH_USER}"
FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="3"
FTCTL_PROFILE_AUTO_REARM="1"
FTCTL_PROFILE_RECOVERY_PRIORITY="100"
FTCTL_PROFILE_QGA_POLICY="optional"
FTCTL_PROFILE_DOMAIN_PERSISTENCE="${persistence}"
FTCTL_PROFILE_SECONDARY_TARGET_DIR="${target_dir}"
FTCTL_PROFILE_REMOTE_NBD_EXPORT_ADDR="${export_addr}"
FTCTL_PROFILE_REMOTE_NBD_EXPORT_PORT="${export_port}"
FTCTL_PROFILE_REMOTE_NBD_EXPORT_NAME="${export_name}"
EOF
}

ftctl_test_shared_target_get() {
  local idx="${1-}"
  local var
  if [[ "${idx}" == "1" ]]; then
    var="SHARED_TARGET_PATH"
  else
    var="SHARED_TARGET_PATH_${idx}"
  fi
  printf '%s' "${!var-}"
}

ftctl_test_build_disk_map() {
  local backend="${1-}"
  local parts=()
  local idx target shared_target

  case "${backend}" in
    remote-nbd)
      printf '%s' "auto"
      return 0
      ;;
    shared-blockcopy)
      for idx in $(ftctl_test_protected_disk_indices); do
        target="$(ftctl_test_disk_get "${idx}" TARGET)"
        shared_target="$(ftctl_test_shared_target_get "${idx}")"
        [[ -n "${target}" && -n "${shared_target}" ]] || ftctl_test_die "shared-blockcopy requires SHARED_TARGET_PATH values for each protected disk"
        parts+=("${target}=${shared_target}")
      done
      local IFS=';'
      printf '%s' "${parts[*]}"
      return 0
      ;;
    *)
      ftctl_test_die "unsupported backend for disk map: ${backend}"
      ;;
  esac
}

ftctl_test_cleanup_remote_nbd() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  rm -f /run/ablestack-vm-ftctl/state/"${vm}".state*
  rm -rf /run/ablestack-vm-ftctl/debug/blockcopy/"${vm}"
  rm -f /run/ablestack-vm-ftctl/xml/"${vm}"-*-remote-nbd.xml
  for idx in $(ftctl_test_protected_disk_indices); do
    local target
    target="$(ftctl_test_disk_get "${idx}" TARGET)"
    virsh blockjob --domain "${vm}" --path "${target}" --abort >/dev/null 2>&1 || true
  done
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SECONDARY_SSH_USER}@${SECONDARY_MGMT_IP}" "
    pkill -f 'qemu-nbd.*${vm}.*' >/dev/null 2>&1 || true
    rm -f /run/ablestack-vm-ftctl/nbd-${vm}-*.pid
    rm -rf ${REMOTE_NBD_TARGET_ROOT}/${vm}
    mkdir -p ${REMOTE_NBD_TARGET_ROOT}/${vm}
  "
  virsh -c "${SECONDARY_LIBVIRT_URI}" destroy "${secondary_vm}" >/dev/null 2>&1 || true
  virsh -c "${SECONDARY_LIBVIRT_URI}" undefine "${secondary_vm}" >/dev/null 2>&1 || true
}

ftctl_test_cleanup_shared_blockcopy() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  local idx target_path

  rm -f /run/ablestack-vm-ftctl/state/"${vm}".state*
  rm -rf /run/ablestack-vm-ftctl/debug/blockcopy/"${vm}"

  for idx in $(ftctl_test_protected_disk_indices); do
    target_path="$(ftctl_test_shared_target_get "${idx}")"
    [[ -n "${target_path}" ]] || continue
    rm -f "${target_path}" >/dev/null 2>&1 || true
  done

  virsh -c "${SECONDARY_LIBVIRT_URI}" destroy "${secondary_vm}" >/dev/null 2>&1 || true
  virsh -c "${SECONDARY_LIBVIRT_URI}" undefine "${secondary_vm}" >/dev/null 2>&1 || true
}

ftctl_test_cleanup_case() {
  local vm="${1-}"
  local secondary_vm="${2-}"
  case "${FTCTL_PROFILE_BACKEND_MODE}" in
    remote-nbd)
      ftctl_test_cleanup_remote_nbd "${vm}" "${secondary_vm}"
      ;;
    shared-blockcopy)
      ftctl_test_cleanup_shared_blockcopy "${vm}" "${secondary_vm}"
      ;;
    *)
      ftctl_test_die "unsupported backend for cleanup: ${FTCTL_PROFILE_BACKEND_MODE}"
      ;;
  esac
}

ftctl_test_destroy_vm_if_present() {
  local vm="${1-}"
  virsh destroy "${vm}" >/dev/null 2>&1 || true
  virsh undefine "${vm}" >/dev/null 2>&1 || true
}

ftctl_test_prepare_root_disk() {
  local format="${1-}"
  local src="${2-}"
  local dst="${3-}"

  mkdir -p "$(dirname "${dst}")"
  rm -f "${dst}"
  [[ -n "${src}" && -f "${src}" ]] || ftctl_test_die "missing root disk source image: ${src}"

  case "${format}" in
    qcow2|raw)
      cp --reflink=auto --sparse=always "${src}" "${dst}"
      ;;
    *)
      ftctl_test_die "unsupported root disk format: ${format}"
      ;;
  esac
}

ftctl_test_prepare_extra_disk() {
  local format="${1-}"
  local src="${2-}"
  local dst="${3-}"
  local size_bytes="${4-}"

  mkdir -p "$(dirname "${dst}")"
  rm -f "${dst}"
  if [[ -n "${src}" && -f "${src}" ]]; then
    cp --reflink=auto --sparse=always "${src}" "${dst}"
  else
    qemu-img create -f "${format}" "${dst}" "${size_bytes}" >/dev/null
  fi
}

ftctl_test_render_vm_xml() {
  local vm="${1-}"
  local out_path="${2-}"
  VM_NAME="${vm}" \
  VM_NAME="${vm}" \
  VM_MEMORY_MB="${VM_DEFAULT_MEMORY_MB}" \
  VM_VCPU="${VM_DEFAULT_VCPU}" \
  VM_MACHINE="${VM_DEFAULT_MACHINE:-q35}" \
  VM_ARCH="${VM_DEFAULT_ARCH:-x86_64}" \
  VM_BRIDGE="${DEFAULT_BRIDGE:-bridge0}" \
  VM_EMULATOR="${DEFAULT_EMULATOR:-/usr/libexec/qemu-kvm}" \
  VM_FIRMWARE="${DEFAULT_FIRMWARE:-bios}" \
  VM_UEFI_CODE_PATH="${DEFAULT_UEFI_CODE_PATH:-}" \
  VM_UEFI_VARS_TEMPLATE="${DEFAULT_UEFI_VARS_TEMPLATE:-}" \
  VM_NVRAM_PATH="${VM_NVRAM_ROOT:-/var/lib/libvirt/qemu/nvram}/${vm}_VARS.fd" \
  PROTECTED_DISK_COUNT="${PROTECTED_DISK_COUNT}" \
  DISK_1_TARGET="${DISK_1_TARGET:-}" DISK_1_PATH="${DISK_1_PATH:-}" DISK_1_FORMAT="${DISK_1_FORMAT:-}" \
  DISK_2_TARGET="${DISK_2_TARGET:-}" DISK_2_PATH="${DISK_2_PATH:-}" DISK_2_FORMAT="${DISK_2_FORMAT:-}" DISK_2_SIZE_BYTES="${DISK_2_SIZE_BYTES:-}" \
  DISK_3_TARGET="${DISK_3_TARGET:-}" DISK_3_PATH="${DISK_3_PATH:-}" DISK_3_FORMAT="${DISK_3_FORMAT:-}" DISK_3_SIZE_BYTES="${DISK_3_SIZE_BYTES:-}" \
  python3 - <<'PY' > "${out_path}"
import os
import xml.etree.ElementTree as ET

vm_name = os.environ["VM_NAME"]
memory_mb = int(os.environ["VM_MEMORY_MB"])
vcpu = int(os.environ["VM_VCPU"])
machine = os.environ["VM_MACHINE"]
arch = os.environ["VM_ARCH"]
bridge = os.environ["VM_BRIDGE"]
emulator = os.environ["VM_EMULATOR"]
firmware = os.environ["VM_FIRMWARE"]
uefi_code = os.environ["VM_UEFI_CODE_PATH"]
uefi_vars_template = os.environ["VM_UEFI_VARS_TEMPLATE"]
nvram_path = os.environ["VM_NVRAM_PATH"]

root = ET.Element("domain", {"type": "kvm"})
ET.SubElement(root, "name").text = vm_name
ET.SubElement(root, "memory", {"unit": "KiB"}).text = str(memory_mb * 1024)
ET.SubElement(root, "currentMemory", {"unit": "KiB"}).text = str(memory_mb * 1024)
ET.SubElement(root, "vcpu", {"placement": "static"}).text = str(vcpu)

os_node = ET.SubElement(root, "os")
if firmware == "uefi" and uefi_code and uefi_vars_template:
    os_node.set("firmware", "efi")
ET.SubElement(os_node, "type", {"arch": arch, "machine": machine}).text = "hvm"
ET.SubElement(os_node, "boot", {"dev": "hd"})
if firmware == "uefi" and uefi_code and uefi_vars_template:
    ET.SubElement(os_node, "loader", {"readonly": "yes", "type": "pflash"}).text = uefi_code
    ET.SubElement(os_node, "nvram", {"template": uefi_vars_template}).text = nvram_path

features = ET.SubElement(root, "features")
ET.SubElement(features, "acpi")
ET.SubElement(features, "apic")
ET.SubElement(root, "cpu", {"mode": "host-passthrough", "check": "none", "migratable": "on"})

clock = ET.SubElement(root, "clock", {"offset": "utc"})
ET.SubElement(clock, "timer", {"name": "rtc", "tickpolicy": "catchup"})
ET.SubElement(clock, "timer", {"name": "pit", "tickpolicy": "delay"})
ET.SubElement(clock, "timer", {"name": "hpet", "present": "no"})

ET.SubElement(root, "on_poweroff").text = "destroy"
ET.SubElement(root, "on_reboot").text = "restart"
ET.SubElement(root, "on_crash").text = "destroy"

devices = ET.SubElement(root, "devices")
ET.SubElement(devices, "emulator").text = emulator

disks = {}
for idx in range(1, 4):
    target = os.environ.get(f"DISK_{idx}_TARGET", "")
    path = os.environ.get(f"DISK_{idx}_PATH", "")
    fmt = os.environ.get(f"DISK_{idx}_FORMAT", "")
    if target and path:
      disks[target] = (path, fmt)

for disk in devices.findall("disk"):
    target = disk.find("target")
    if target is None:
        continue
    dev = target.get("dev")
    if dev not in disks:
        continue
    src_path, fmt = disks[dev]
    source = disk.find("source")
    if source is None:
        source = ET.SubElement(disk, "source")
    source.attrib.clear()
    source.set("file", src_path)
for dev, (src_path, fmt) in disks.items():
    disk = ET.SubElement(devices, "disk", {"type": "file", "device": "disk"})
    ET.SubElement(disk, "driver", {"name": "qemu", "type": fmt or "qcow2", "discard": "unmap"})
    ET.SubElement(disk, "source", {"file": src_path})
    ET.SubElement(disk, "target", {"dev": dev, "bus": "virtio"})

cdrom = ET.SubElement(devices, "disk", {"type": "file", "device": "cdrom"})
ET.SubElement(cdrom, "driver", {"name": "qemu"})
ET.SubElement(cdrom, "target", {"dev": "sda", "bus": "sata"})
ET.SubElement(cdrom, "readonly")

ET.SubElement(devices, "controller", {"type": "usb", "index": "0", "model": "qemu-xhci", "ports": "15"})
ET.SubElement(devices, "controller", {"type": "pci", "index": "0", "model": "pcie-root"})
ET.SubElement(devices, "controller", {"type": "sata", "index": "0"})
ET.SubElement(devices, "controller", {"type": "virtio-serial", "index": "0"})

iface = ET.SubElement(devices, "interface", {"type": "bridge"})
ET.SubElement(iface, "source", {"bridge": bridge})
ET.SubElement(iface, "model", {"type": "virtio"})

serial = ET.SubElement(devices, "serial", {"type": "pty"})
ET.SubElement(serial, "target", {"type": "isa-serial", "port": "0"})
console = ET.SubElement(devices, "console", {"type": "pty"})
ET.SubElement(console, "target", {"type": "serial", "port": "0"})

channel = ET.SubElement(devices, "channel", {"type": "unix"})
ET.SubElement(channel, "target", {"type": "virtio", "name": "org.qemu.guest_agent.0"})

ET.SubElement(devices, "input", {"type": "tablet", "bus": "usb"})
ET.SubElement(devices, "input", {"type": "mouse", "bus": "ps2"})
ET.SubElement(devices, "input", {"type": "keyboard", "bus": "ps2"})

graphics = ET.SubElement(devices, "graphics", {"type": "vnc", "autoport": "yes", "listen": "0.0.0.0"})
ET.SubElement(graphics, "listen", {"type": "address", "address": "0.0.0.0"})
ET.SubElement(devices, "audio", {"id": "1", "type": "none"})
video = ET.SubElement(devices, "video")
ET.SubElement(video, "model", {"type": "virtio", "heads": "1", "primary": "yes"})
ET.SubElement(devices, "watchdog", {"model": "itco", "action": "reset"})
ET.SubElement(devices, "memballoon", {"model": "virtio"})
rng = ET.SubElement(devices, "rng", {"model": "virtio"})
ET.SubElement(rng, "backend", {"model": "random"}).text = "/dev/urandom"

print(ET.tostring(root, encoding="unicode"))
PY
}

ftctl_test_prepare_vm_disks() {
  local disk1_format="${DISK_1_FORMAT:-qcow2}"
  local disk1_source
  disk1_source="$(ftctl_test_disk_source_image_get 1)"
  if [[ -z "${disk1_source}" ]]; then
    case "${disk1_format}" in
      qcow2) disk1_source="${BASE_IMAGE_QCOW2}" ;;
      raw)   disk1_source="${BASE_IMAGE_RAW}" ;;
    esac
  fi
  ftctl_test_prepare_root_disk "${disk1_format}" "${disk1_source}" "${DISK_1_PATH}"

  if (( PROTECTED_DISK_COUNT >= 2 )) && [[ -n "${DISK_2_PATH:-}" ]]; then
    ftctl_test_prepare_extra_disk "${DISK_2_FORMAT}" "$(ftctl_test_disk_source_image_get 2)" "${DISK_2_PATH}" "${DISK_2_SIZE_BYTES:-21474836480}"
  fi
  if (( PROTECTED_DISK_COUNT >= 3 )) && [[ -n "${DISK_3_PATH:-}" ]]; then
    ftctl_test_prepare_extra_disk "${DISK_3_FORMAT}" "$(ftctl_test_disk_source_image_get 3)" "${DISK_3_PATH}" "${DISK_3_SIZE_BYTES:-21474836480}"
  fi
}

ftctl_test_create_vm() {
  local vm="${1-}"
  local xml_path="${2-}"

  ftctl_test_destroy_vm_if_present "${vm}"
  ftctl_test_prepare_vm_disks
  ftctl_test_render_vm_xml "${vm}" "${xml_path}"

  case "${DOMAIN_MODE}" in
    persistent)
      virsh define "${xml_path}" >/dev/null
      virsh start "${vm}" >/dev/null
      ;;
    transient)
      virsh create "${xml_path}" >/dev/null
      ;;
    *)
      ftctl_test_die "unsupported DOMAIN_MODE: ${DOMAIN_MODE}"
      ;;
  esac
}

ftctl_test_collect_bundle() {
  local vm="${1-}"
  local out_dir
  out_dir="$(ftctl_test_case_log_dir)"

  find /run/ablestack-vm-ftctl/debug/blockcopy/"${vm}" -maxdepth 3 -type f -print 2>/dev/null \
    | tee "${out_dir}/${TEST_ID}.debug-files.txt" >/dev/null || true

  for f in /run/ablestack-vm-ftctl/debug/blockcopy/"${vm}"/v*/{remote-nbd-repro.sh,remote-nbd-dest.xml,primary-blockcopy-command.txt,primary-blockcopy-stdout.txt,primary-blockcopy-stderr.txt,primary-blockcopy-rc.txt,primary-dumpxml.stdout.xml,primary-blockjob.stdout.txt,secondary-prepare-context.txt,secondary-prepare-command.txt}; do
    [[ -f "${f}" ]] && { echo "===== ${f} ====="; cat "${f}"; }
  done > "${out_dir}/${TEST_ID}.debug-bundle.txt" || true
}

ftctl_test_collect_backend_target_log() {
  local log_name="${1-}"
  local cmd=""

  case "${FTCTL_PROFILE_BACKEND_MODE}" in
    remote-nbd)
      cmd="ls -lh ${FTCTL_PROFILE_SECONDARY_TARGET_DIR}/${VM_NAME}/ ; ps -ef | grep qemu-nbd | grep ${VM_NAME} || true ; ss -lntp | grep ${FTCTL_REMOTE_NBD_PORT_BASE} || true"
      ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${SECONDARY_SSH_USER}@${SECONDARY_MGMT_IP}" "${cmd}" 2>&1 | tee "$(ftctl_test_log_path "${log_name}")"
      ;;
    shared-blockcopy)
      {
        for idx in $(ftctl_test_protected_disk_indices); do
          local path
          path="$(ftctl_test_shared_target_get "${idx}")"
          [[ -n "${path}" ]] || continue
          echo "===== ${path} ====="
          ls -lh "${path}" 2>/dev/null || true
        done
      } | tee "$(ftctl_test_log_path "${log_name}")"
      ;;
    *)
      ftctl_test_die "unsupported backend for target collection: ${FTCTL_PROFILE_BACKEND_MODE}"
      ;;
  esac
}

ftctl_test_mark_summary() {
  local vm="${1-}"
  local status_json="${2-}"
  python3 - <<'PY' "${status_json}" "${TEST_ID}" "${VM_NAME}" > "$(ftctl_test_log_path "${TEST_ID}.summary.txt")"
import json, sys
path, test_id, vm = sys.argv[1], sys.argv[2], sys.argv[3]
obj = json.load(open(path, encoding='utf-8'))
state = obj.get("protection_state", "")
transport = obj.get("transport_state", "")
result = "PASS" if state == "protected" and transport == "mirroring" else "FAIL"
print(f"TEST_ID={test_id}")
print(f"VM_NAME={vm}")
print(f"RESULT={result}")
print(f"PROTECTION_STATE={state}")
print(f"TRANSPORT_STATE={transport}")
PY
}
