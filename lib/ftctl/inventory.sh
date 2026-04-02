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

ftctl_inventory_probe_uri_vm() {
  local uri="${1-}"
  local vm="${2-}"
  local out err rc
  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_HEALTH_INTERVAL_SEC}" out err rc -- -c "${uri}" dominfo "${vm}" || true
  : "${out}${err}"
  return "${rc}"
}

ftctl_inventory_check_vm() {
  local vm="${1-}"
  local local_rc peer_rc result
  local_rc=0
  peer_rc=0

  ftctl_inventory_probe_uri_vm "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" || local_rc=$?
  ftctl_inventory_probe_uri_vm "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" || peer_rc=$?

  if [[ "${local_rc}" == "0" && "${peer_rc}" == "0" ]]; then
    result="ok"
  elif [[ "${local_rc}" == "0" ]]; then
    result="warn"
  else
    result="fail"
  fi

  ftctl_log_event "inventory" "inventory.check" "${result}" "${vm}" "" \
    "primary_rc=${local_rc} peer_rc=${peer_rc} peer_uri=${FTCTL_PROFILE_SECONDARY_URI}"

  printf '%s %s %s\n' "${local_rc}" "${peer_rc}" "${result}"
}

ftctl_inventory_detect_disk_format() {
  local source_path="${1-}"
  local _out_var="${2}"
  local fmt=""
  local out err rc

  if command -v qemu-img >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    out=""
    err=""
    rc=0
    ftctl_cmd_run "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- qemu-img info --output=json "${source_path}" || true
    if [[ "${rc}" == "0" ]]; then
      fmt="$(printf '%s' "${out}" | jq -r '.format // empty' 2>/dev/null || true)"
    fi
  fi

  if [[ -z "${fmt}" ]]; then
    case "${source_path}" in
      *.qcow2|*.qcow2.*) fmt="qcow2" ;;
      *.raw) fmt="raw" ;;
      *) fmt="" ;;
    esac
  fi

  printf -v "${_out_var}" '%s' "${fmt}"
}

ftctl_inventory_collect_vm_disks() {
  local vm="${1-}"
  local out_array_name="${2}"
  local out err rc
  local -n _out_array="${out_array_name}"
  local line device target source format

  _out_array=()
  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" domblklist "${vm}" --details || true
  if [[ "${rc}" != "0" ]]; then
    ftctl_log_event "inventory" "inventory.disks" "fail" "${vm}" "${rc}" \
      "primary_uri=${FTCTL_PROFILE_PRIMARY_URI}"
    return "${rc}"
  fi

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    case "${line}" in
      Type*|----*) continue ;;
    esac

    device="$(awk '{print $2}' <<< "${line}")"
    target="$(awk '{print $3}' <<< "${line}")"
    source="$(awk '{print $4}' <<< "${line}")"

    [[ "${device}" == "disk" ]] || continue
    [[ -n "${target}" && -n "${source}" && "${source}" != "-" ]] || continue

    format=""
    ftctl_inventory_detect_disk_format "${source}" format
    _out_array+=("${target}|${source}|${format}")
  done <<< "${out}"

  if ((${#_out_array[@]} == 0)); then
    ftctl_log_event "inventory" "inventory.disks" "warn" "${vm}" "" "count=0"
    return 3
  fi

  ftctl_log_event "inventory" "inventory.disks" "ok" "${vm}" "" "count=${#_out_array[@]}"
}

ftctl_inventory_xml_backup_path() {
  local vm="${1-}"
  local key
  key="$(ftctl_state_vm_key "${vm}")"
  echo "${FTCTL_XML_BACKUP_DIR}/${key}"
}

ftctl_inventory_detect_domain_persistence() {
  local vm="${1-}"
  local out_var="${2}"
  local out err rc value

  if [[ "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "yes" || "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "no" ]]; then
    printf -v "${out_var}" '%s' "${FTCTL_PROFILE_DOMAIN_PERSISTENCE}"
    return 0
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dumpxml --inactive "${vm}" >/dev/null 2>&1 || true
  if [[ "${rc}" == "0" ]]; then
    printf -v "${out_var}" '%s' "yes"
    return 0
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dominfo "${vm}" || true
  if [[ "${rc}" != "0" ]]; then
    printf -v "${out_var}" '%s' "unknown"
    return "${rc}"
  fi

  value="$(awk -F: 'tolower($1) ~ /persistent/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<< "${out}")"
  if [[ -z "${value}" || "${value}" == "unknown" ]]; then
    out=""
    err=""
    rc=0
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" domuuid "${vm}" || true
    if [[ "${rc}" == "0" ]]; then
      value="no"
    fi
  fi
  [[ -n "${value}" ]] || value="unknown"
  printf -v "${out_var}" '%s' "${value}"
}

ftctl_inventory_backup_domain_xml() {
  local vm="${1-}"
  local bundle_dir_var="${2}"
  local primary_xml_var="${3}"
  local standby_xml_var="${4}"
  local persistence_var="${5}"
  local out err rc bundle_dir primary_xml standby_xml meta_file persistence checksum

  bundle_dir="$(ftctl_inventory_xml_backup_path "${vm}")"
  ftctl_ensure_dir "${bundle_dir}" "0755"
  primary_xml="${bundle_dir}/primary.xml"
  standby_xml="${bundle_dir}/standby.xml"
  meta_file="${bundle_dir}/meta"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" dumpxml --security-info "${vm}" || true
  : "${err}"
  if [[ "${rc}" != "0" ]]; then
    ftctl_log_event "inventory" "inventory.dumpxml" "fail" "${vm}" "${rc}" \
      "primary_uri=${FTCTL_PROFILE_PRIMARY_URI}"
    return "${rc}"
  fi

  printf '%s\n' "${out}" > "${primary_xml}"
  printf '%s\n' "${out}" > "${standby_xml}"
  chmod 0644 "${primary_xml}" "${standby_xml}" 2>/dev/null || true

  persistence="unknown"
  ftctl_inventory_detect_domain_persistence "${vm}" persistence || true
  checksum=""
  if command -v sha256sum >/dev/null 2>&1; then
    checksum="$(sha256sum "${primary_xml}" | awk '{print $1}')"
  fi

  cat > "${meta_file}" <<EOF
vm=${vm}
primary_uri=${FTCTL_PROFILE_PRIMARY_URI}
secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}
primary_xml=${primary_xml}
standby_xml=${standby_xml}
persistent=${persistence}
xml_sha256=${checksum}
EOF
  chmod 0644 "${meta_file}" 2>/dev/null || true

  printf -v "${bundle_dir_var}" '%s' "${bundle_dir}"
  printf -v "${primary_xml_var}" '%s' "${primary_xml}"
  printf -v "${standby_xml_var}" '%s' "${standby_xml}"
  printf -v "${persistence_var}" '%s' "${persistence}"
  ftctl_log_event "inventory" "inventory.dumpxml" "ok" "${vm}" "" \
    "bundle_dir=${bundle_dir} persistent=${persistence}"
}
