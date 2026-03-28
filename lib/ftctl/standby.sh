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
    source = disk.find("source")
    if source is None:
        source = ET.Element("source")
        disk.insert(0, source)
    source.attrib.clear()
    source.set(source_attr, dest_path)

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
  local seed out_path
  local records=()
  local record target source dest format job_state ready attr

  seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  [[ -n "${seed}" && -f "${seed}" ]] || {
    echo "ERROR: standby_xml_seed not found for ${vm}" >&2
    return 2
  }
  out_path="$(ftctl_standby_generated_xml_path "${vm}")"
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"
  cp -f "${seed}" "${out_path}"

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
    ready="${record##*|}"
    : "${source}${format}${job_state}${ready}"

    attr="$(ftctl_standby__source_attr_for_dest "${dest}")"
    ftctl_standby__rewrite_xml "${out_path}" "${target}" "${dest}" "${attr}"
  done

  if [[ "${FTCTL_PROFILE_MODE}" == "ft" && -n "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY}" ]]; then
    ftctl_xml_apply_qemu_commandline "${out_path}" "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY}"
  fi

  ftctl_state_set "${vm}" \
    "standby_xml_generated=${out_path}" \
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
  local persistence generated_xml out err rc

  generated_xml="$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)"
  [[ -n "${generated_xml}" ]] || {
    echo "ERROR: standby_xml_generated not found for ${vm}" >&2
    return 2
  }
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" \
      "standby_state=start-dry-run" \
      "active_side=secondary"
    ftctl_log_event "standby" "standby.activate" "skip" "${vm}" "" \
      "reason=dry_run path=${generated_xml}"
    return 0
  fi

  out=""
  err=""
  rc=0
  if [[ "${persistence}" == "yes" ]]; then
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" start "${vm}" || true
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
