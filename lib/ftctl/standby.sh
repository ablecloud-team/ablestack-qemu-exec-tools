#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
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
