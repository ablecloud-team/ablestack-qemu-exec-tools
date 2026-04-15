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

ftctl_standby_generated_xml_path() {
  local vm="${1-}"
  local seed
  seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  if [[ -n "${seed}" ]]; then
    printf '%s\n' "$(dirname "${seed}")/standby.generated.xml"
    return 0
  fi
  printf '%s\n' "${FTCTL_XML_BACKUP_DIR}/$(ftctl_state_vm_key "${vm}")/standby.generated.xml"
}

ftctl_primary_generated_xml_path() {
  local vm="${1-}"
  local primary
  primary="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  if [[ -n "${primary}" ]]; then
    printf '%s\n' "$(dirname "${primary}")/primary.generated.xml"
    return 0
  fi
  printf '%s\n' "${FTCTL_XML_BACKUP_DIR}/$(ftctl_state_vm_key "${vm}")/primary.generated.xml"
}

ftctl_standby_blockcopy_records() {
  local vm="${1-}"
  local out_array_name="${2}"
  local path line
  local -n _out_array="${out_array_name}"

  _out_array=()
  path="$(ftctl_blockcopy_state_path "${vm}")"
  [[ -f "${path}" ]] || return 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    _out_array+=("${line}")
  done < "${path}"
  ((${#_out_array[@]} > 0))
}

ftctl_standby__source_attr_for_dest() {
  local dest="${1-}"
  if [[ "${dest}" == rbd:* ]]; then
    printf '%s\n' "rbd"
    return 0
  fi
  if [[ "${dest}" == /dev/* ]]; then
    printf '%s\n' "dev"
  else
    printf '%s\n' "file"
  fi
}

ftctl_standby__rewrite_xml() {
  local xml_path="${1-}"
  local target="${2-}"
  local dest="${3-}"
  local attr="${4-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for standby XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" TARGET_DEV="${target}" DEST_PATH="${dest}" SOURCE_ATTR="${attr}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
target_dev = os.environ["TARGET_DEV"]
dest_path = os.environ["DEST_PATH"]
source_attr = os.environ["SOURCE_ATTR"]

tree = ET.parse(xml_path)
root = tree.getroot()

for child in list(root):
    if child.tag in {"uuid", "id"}:
        root.remove(child)

devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in standby xml")

for disk in devices.findall("disk"):
    target = disk.find("target")
    if target is None or target.get("dev") != target_dev:
        continue
    if source_attr == "rbd":
        if not dest_path.startswith("rbd:"):
            raise SystemExit(f"invalid rbd dest: {dest_path}")
        body = dest_path[4:]
        pool, image = body.split("/", 1)
        disk.set("type", "network")
        source = disk.find("source")
        if source is None:
            source = ET.Element("source")
            disk.insert(0, source)
        hosts = [child for child in list(source) if child.tag == "host"]
        source.attrib.clear()
        source.set("protocol", "rbd")
        source.set("name", f"{pool}/{image}")
        for child in list(source):
            source.remove(child)
        for host in hosts:
            source.append(host)
    else:
        if source_attr == "dev":
            disk.set("type", "block")
        elif source_attr == "file":
            disk.set("type", "file")
        source = disk.find("source")
        if source is None:
            source = ET.Element("source")
            disk.insert(0, source)
        source.attrib.clear()
        source.set(source_attr, dest_path)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_standby__rewrite_domain_name() {
  local xml_path="${1-}"
  local domain_name="${2-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for standby XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" DOMAIN_NAME="${domain_name}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
domain_name = os.environ["DOMAIN_NAME"]

tree = ET.parse(xml_path)
root = tree.getroot()

name = root.find("name")
if name is None:
    name = ET.Element("name")
    root.insert(0, name)
name.text = domain_name

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_apply_qemu_commandline() {
  local xml_path="${1-}"
  local args_string="${2-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for qemu:commandline XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" QEMU_ARGS="${args_string}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
args_raw = os.environ.get("QEMU_ARGS", "")
args = [a for a in args_raw.split(";") if a]

if not args:
    raise SystemExit(0)

qemu_ns = "http://libvirt.org/schemas/domain/qemu/1.0"
ET.register_namespace("qemu", qemu_ns)

tree = ET.parse(xml_path)
root = tree.getroot()

qcmd = root.find(f"{{{qemu_ns}}}commandline")
if qcmd is not None:
    root.remove(qcmd)

qcmd = ET.Element(f"{{{qemu_ns}}}commandline")
for arg in args:
    node = ET.SubElement(qcmd, f"{{{qemu_ns}}}arg")
    node.set("value", arg)
root.append(qcmd)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_remove_qemu_commandline() {
  local xml_path="${1-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for qemu:commandline XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
qemu_ns = "http://libvirt.org/schemas/domain/qemu/1.0"
tree = ET.parse(xml_path)
root = tree.getroot()
qcmd = root.find(f"{{{qemu_ns}}}commandline")
if qcmd is not None:
    root.remove(qcmd)
tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_rewrite_first_disk_block_runtime() {
  local xml_path="${1-}"
  local dest_path="${2-}"
  local disk_format="${3-qcow2}"
  local disk_mode="${4-rw}"
  local boot_order="${5-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for block-backed runtime XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" DEST_PATH="${dest_path}" DISK_FORMAT="${disk_format}" DISK_MODE="${disk_mode}" BOOT_ORDER="${boot_order}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
dest_path = os.environ["DEST_PATH"]
disk_format = os.environ["DISK_FORMAT"] or "qcow2"
disk_mode = os.environ["DISK_MODE"] or "rw"
boot_order = os.environ.get("BOOT_ORDER", "")

tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in xml")
os_node = root.find("os")
if os_node is not None and boot_order:
    for child in list(os_node):
        if child.tag == "boot":
            os_node.remove(child)

disk = None
for candidate in devices.findall("disk"):
    if candidate.get("device") == "disk":
        disk = candidate
        break

if disk is None:
    raise SystemExit("missing first disk device in xml")

disk.set("type", "block")
driver = disk.find("driver")
if driver is None:
    driver = ET.Element("driver")
    disk.insert(0, driver)
driver.set("name", "qemu")
driver.set("type", disk_format)
driver.set("discard", "unmap")

source = disk.find("source")
if source is None:
    source = ET.Element("source")
    disk.insert(1, source)
source.attrib.clear()
source.set("dev", dest_path)

target = disk.find("target")
if target is None:
    target = ET.Element("target")
    disk.append(target)
target.set("dev", "sdb")
target.set("bus", "scsi")

for child in list(disk):
    if child.tag in {"readonly", "shareable", "boot", "alias", "address"}:
        disk.remove(child)

if disk_mode in {"ro", "ro-shareable"}:
    disk.append(ET.Element("readonly"))
if disk_mode in {"shareable", "ro-shareable"}:
    disk.append(ET.Element("shareable"))
if boot_order:
    boot = ET.Element("boot")
    boot.set("order", boot_order)
    disk.append(boot)

has_scsi = False
for controller in devices.findall("controller"):
    if controller.get("type") == "scsi":
        controller.set("model", "virtio-scsi")
        has_scsi = True
        break
if not has_scsi:
    controller = ET.Element("controller")
    controller.set("type", "scsi")
    controller.set("index", "0")
    controller.set("model", "virtio-scsi")
    devices.insert(1, controller)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_standby_materialize_primary_xml() {
  local vm="${1-}"
  local primary_xml generated

  primary_xml="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  [[ -n "${primary_xml}" && -f "${primary_xml}" ]] || return 1

  generated="$(ftctl_primary_generated_xml_path "${vm}")"
  ftctl_ensure_dir "$(dirname "${generated}")" "0755"
  cp -f "${primary_xml}" "${generated}"
  if [[ "${FTCTL_PROFILE_MODE}" == "ft" && -n "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY}" ]]; then
    ftctl_xml_apply_qemu_commandline "${generated}" "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY}"
  fi
  ftctl_state_set "${vm}" "primary_xml_generated=${generated}"
}

ftctl_standby_materialize_xml() {
  local vm="${1-}"
  local seed out_path standby_vm_name
  local records=()
  local record target source dest format job_state ready secondary_dest attr

  seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  [[ -n "${seed}" && -f "${seed}" ]] || {
    echo "ERROR: standby_xml_seed not found for ${vm}" >&2
    return 2
  }
  out_path="$(ftctl_standby_generated_xml_path "${vm}")"
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"
  cp -f "${seed}" "${out_path}"
  standby_vm_name="$(ftctl_profile_secondary_vm_name_resolved "${vm}")"
  ftctl_standby__rewrite_domain_name "${out_path}" "${standby_vm_name}"

  ftctl_standby_blockcopy_records "${vm}" records || {
    echo "ERROR: blockcopy state records not found for ${vm}" >&2
    return 2
  }

  for record in "${records[@]}"; do
    target="${record%%|*}"
    record="${record#*|}"
    source="${record%%|*}"
    record="${record#*|}"
    dest="${record%%|*}"
    record="${record#*|}"
    format="${record%%|*}"
    record="${record#*|}"
    job_state="${record%%|*}"
    record="${record#*|}"
    if [[ "${record}" == *"|"* ]]; then
      ready="${record%%|*}"
      secondary_dest="${record##*|}"
    else
      ready="${record}"
      secondary_dest=""
    fi
    : "${source}${format}${job_state}${ready}"

    if [[ -n "${secondary_dest}" ]]; then
      dest="${secondary_dest}"
    fi

    attr="$(ftctl_standby__source_attr_for_dest "${dest}")"
    ftctl_standby__rewrite_xml "${out_path}" "${target}" "${dest}" "${attr}"
  done

  if [[ "${FTCTL_PROFILE_MODE}" == "ft" && -n "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY}" ]]; then
    ftctl_xml_apply_qemu_commandline "${out_path}" "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY}"
  fi

  ftctl_state_set "${vm}" \
    "standby_xml_generated=${out_path}" \
    "secondary_vm_name=${standby_vm_name}" \
    "standby_last_prepare_ts=$(ftctl_now_iso8601)"
  ftctl_log_event "standby" "standby.materialize" "ok" "${vm}" "" \
    "path=${out_path}"
}

ftctl_standby_prepare() {
  local vm="${1-}"
  local out err rc generated_xml persistence

  ftctl_standby_materialize_xml "${vm}"
  generated_xml="$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)"
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"
  if [[ "${persistence}" == "unknown" && ( "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "yes" || "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "no" ) ]]; then
    persistence="${FTCTL_PROFILE_DOMAIN_PERSISTENCE}"
    ftctl_state_set "${vm}" "primary_persistence=${persistence}"
  fi

  if [[ "${persistence}" != "yes" ]]; then
    ftctl_state_set "${vm}" "standby_state=prepared-transient"
    ftctl_log_event "standby" "standby.prepare" "ok" "${vm}" "" \
      "mode=transient path=${generated_xml}"
    return 0
  fi

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" "standby_state=define-dry-run"
    ftctl_log_event "standby" "standby.prepare" "skip" "${vm}" "" \
      "reason=dry_run path=${generated_xml}"
    return 0
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" define "${generated_xml}" || true
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "standby_state=define-failed" \
      "last_error=standby_define_failed"
    ftctl_log_event "standby" "standby.prepare" "fail" "${vm}" "${rc}" \
      "path=${generated_xml} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
    return "${rc}"
  fi

  ftctl_state_set "${vm}" "standby_state=defined"
  ftctl_log_event "standby" "standby.prepare" "ok" "${vm}" "" \
    "mode=persistent path=${generated_xml} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
}

ftctl_standby_activate() {
  local vm="${1-}"
  local persistence generated_xml out err rc secondary_vm_name

  generated_xml="$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)"
  [[ -n "${generated_xml}" ]] || {
    echo "ERROR: standby_xml_generated not found for ${vm}" >&2
    return 2
  }
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"
  secondary_vm_name="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || ftctl_profile_secondary_vm_name_resolved "${vm}")"
  if [[ "${persistence}" == "unknown" && ( "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "yes" || "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "no" ) ]]; then
    persistence="${FTCTL_PROFILE_DOMAIN_PERSISTENCE}"
    ftctl_state_set "${vm}" "primary_persistence=${persistence}"
  fi

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" \
      "standby_state=start-dry-run" \
      "active_side=secondary"
    ftctl_log_event "standby" "standby.activate" "skip" "${vm}" "" \
      "reason=dry_run path=${generated_xml}"
    return 0
  fi

  if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
    ftctl_blockcopy_stop_remote_nbd_exports "${vm}" || true
    ftctl_blockcopy_wait_remote_nbd_release "${vm}" || {
      ftctl_state_set "${vm}" \
        "standby_state=release-timeout" \
        "last_error=remote_nbd_release_timeout"
      return 1
    }
  fi

  out=""
  err=""
  rc=0
  if [[ "${persistence}" == "yes" ]]; then
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" start "${secondary_vm_name}" || true
  else
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" create "${generated_xml}" || true
  fi
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "standby_state=activate-failed" \
      "last_error=standby_activate_failed"
    ftctl_log_event "standby" "standby.activate" "fail" "${vm}" "${rc}" \
      "path=${generated_xml} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
    return "${rc}"
  fi

  ftctl_state_set "${vm}" \
    "standby_state=running" \
    "active_side=secondary"
  ftctl_log_event "standby" "standby.activate" "ok" "${vm}" "" \
    "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
}
