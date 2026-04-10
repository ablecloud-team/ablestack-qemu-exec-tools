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

ftctl_test_destroy_vm_if_present() {
  local vm="${1-}"
  virsh destroy "${vm}" >/dev/null 2>&1 || true
  virsh undefine "${vm}" >/dev/null 2>&1 || true
}

ftctl_test_prepare_root_disk() {
  local format="${1-}"
  local dst="${2-}"

  mkdir -p "$(dirname "${dst}")"
  rm -f "${dst}"

  case "${format}" in
    qcow2)
      qemu-img create -f qcow2 -F qcow2 -b "${BASE_IMAGE_QCOW2}" "${dst}" >/dev/null
      ;;
    raw)
      cp --sparse=always "${BASE_IMAGE_RAW}" "${dst}"
      ;;
    *)
      ftctl_test_die "unsupported root disk format: ${format}"
      ;;
  esac
}

ftctl_test_prepare_extra_disk() {
  local format="${1-}"
  local dst="${2-}"
  local size_bytes="${3-}"

  mkdir -p "$(dirname "${dst}")"
  rm -f "${dst}"
  qemu-img create -f "${format}" "${dst}" "${size_bytes}" >/dev/null
}

ftctl_test_template_source_xml() {
  local vm="${1-}"
  if [[ "${VM_CREATE_MODE}" == "virsh" ]]; then
    env LC_ALL=C LANG=C virsh -c "${PRIMARY_LIBVIRT_URI}" dumpxml "${vm}"
  else
    ftctl_test_die "unsupported VM_CREATE_MODE: ${VM_CREATE_MODE}"
  fi
}

ftctl_test_render_vm_xml() {
  local vm="${1-}"
  local out_path="${2-}"
  local xml_text
  xml_text="$(ftctl_test_template_source_xml "${vm}")"

  XML_TEXT="${xml_text}" \
  VM_NAME="${vm}" \
  VM_MEMORY_MB="${VM_DEFAULT_MEMORY_MB}" \
  VM_VCPU="${VM_DEFAULT_VCPU}" \
  DEFAULT_BRIDGE="${DEFAULT_BRIDGE}" \
  PROTECTED_DISK_COUNT="${PROTECTED_DISK_COUNT}" \
  DISK_1_TARGET="${DISK_1_TARGET:-}" DISK_1_PATH="${DISK_1_PATH:-}" DISK_1_FORMAT="${DISK_1_FORMAT:-}" \
  DISK_2_TARGET="${DISK_2_TARGET:-}" DISK_2_PATH="${DISK_2_PATH:-}" DISK_2_FORMAT="${DISK_2_FORMAT:-}" DISK_2_SIZE_BYTES="${DISK_2_SIZE_BYTES:-}" \
  DISK_3_TARGET="${DISK_3_TARGET:-}" DISK_3_PATH="${DISK_3_PATH:-}" DISK_3_FORMAT="${DISK_3_FORMAT:-}" DISK_3_SIZE_BYTES="${DISK_3_SIZE_BYTES:-}" \
  python3 - <<'PY' > "${out_path}"
import os
import xml.etree.ElementTree as ET

root = ET.fromstring(os.environ["XML_TEXT"])
vm_name = os.environ["VM_NAME"]
memory_mb = int(os.environ["VM_MEMORY_MB"])
vcpu = int(os.environ["VM_VCPU"])
default_bridge = os.environ["DEFAULT_BRIDGE"]

for child in list(root):
    if child.tag in {"uuid", "id"}:
        root.remove(child)

name = root.find("name")
if name is None:
    name = ET.SubElement(root, "name")
name.text = vm_name

memory = root.find("memory")
if memory is None:
    memory = ET.SubElement(root, "memory", {"unit": "KiB"})
memory.set("unit", "KiB")
memory.text = str(memory_mb * 1024)

current = root.find("currentMemory")
if current is None:
    current = ET.SubElement(root, "currentMemory", {"unit": "KiB"})
current.set("unit", "KiB")
current.text = str(memory_mb * 1024)

vcpu_node = root.find("vcpu")
if vcpu_node is None:
    vcpu_node = ET.SubElement(root, "vcpu")
vcpu_node.text = str(vcpu)

devices = root.find("devices")
if devices is None:
    raise SystemExit("missing devices section in source XML")

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
    driver = disk.find("driver")
    if driver is None:
        driver = ET.SubElement(disk, "driver")
    driver.set("name", "qemu")
    driver.set("type", fmt or "qcow2")

iface = devices.find("interface")
if iface is not None and iface.get("type") == "bridge":
    source = iface.find("source")
    if source is None:
        source = ET.SubElement(iface, "source")
    source.attrib.clear()
    source.set("bridge", default_bridge)

print(ET.tostring(root, encoding="unicode"))
PY
}

ftctl_test_prepare_vm_disks() {
  local disk1_format="${DISK_1_FORMAT:-qcow2}"
  ftctl_test_prepare_root_disk "${disk1_format}" "${DISK_1_PATH}"

  if (( PROTECTED_DISK_COUNT >= 2 )) && [[ -n "${DISK_2_PATH:-}" ]]; then
    ftctl_test_prepare_extra_disk "${DISK_2_FORMAT}" "${DISK_2_PATH}" "${DISK_2_SIZE_BYTES:-21474836480}"
  fi
  if (( PROTECTED_DISK_COUNT >= 3 )) && [[ -n "${DISK_3_PATH:-}" ]]; then
    ftctl_test_prepare_extra_disk "${DISK_3_FORMAT}" "${DISK_3_PATH}" "${DISK_3_SIZE_BYTES:-21474836480}"
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
