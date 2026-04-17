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

FTCTL_CLUSTER_NAME=""
FTCTL_LOCAL_HOST_ID=""
FTCTL_CLUSTER_HOST_RECORDS=()

ftctl_cluster_reset() {
  FTCTL_CLUSTER_NAME=""
  FTCTL_LOCAL_HOST_ID=""
  FTCTL_CLUSTER_HOST_RECORDS=()
}

ftctl_cluster__global_path() {
  echo "${FTCTL_CLUSTER_CONFIG}"
}

ftctl_cluster__host_path() {
  local host_id="${1-}"
  echo "${FTCTL_CLUSTER_HOSTS_DIR}/${host_id}.conf"
}

ftctl_cluster__validate_id() {
  local field="${1-}"
  local value="${2-}"
  [[ "${value}" =~ ^[A-Za-z0-9_.-]+$ ]] && return 0
  echo "ERROR: ${field} has invalid value: ${value}" >&2
  return 2
}

ftctl_cluster__validate_role() {
  local role="${1-}"
  case "${role}" in
    primary|secondary|observer|generic) return 0 ;;
    *)
      echo "ERROR: FTCTL_HOST_ROLE has invalid value: ${role}" >&2
      return 2
      ;;
  esac
}

ftctl_cluster__validate_addr() {
  local field="${1-}"
  local value="${2-}"
  [[ -n "${value}" ]] || {
    echo "ERROR: ${field} is required" >&2
    return 2
  }
  if [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 0
  fi
  if [[ "${value}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    return 0
  fi
  echo "ERROR: ${field} has invalid address value: ${value}" >&2
  return 2
}

ftctl_cluster__validate_libvirt_uri() {
  local value="${1-}"
  [[ -n "${value}" ]] || {
    echo "ERROR: FTCTL_HOST_LIBVIRT_URI is required" >&2
    return 2
  }
  [[ "${value}" =~ ^qemu(\+ssh)?:// ]] && return 0
  echo "ERROR: FTCTL_HOST_LIBVIRT_URI must start with qemu:// or qemu+ssh://" >&2
  return 2
}

ftctl_cluster_load() {
  local file host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
  ftctl_cluster_reset

  if [[ -f "$(ftctl_cluster__global_path)" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$(ftctl_cluster__global_path)"
    set +a
  fi

  FTCTL_CLUSTER_NAME="${FTCTL_CLUSTER_NAME:-}"
  FTCTL_LOCAL_HOST_ID="${FTCTL_LOCAL_HOST_ID:-}"

  shopt -s nullglob
  for file in "${FTCTL_CLUSTER_HOSTS_DIR}"/*.conf; do
    host_id=""
    role=""
    mgmt_ip=""
    libvirt_uri=""
    blockcopy_ip=""
    xcolo_ctrl=""
    xcolo_data=""
    unset FTCTL_HOST_ID FTCTL_HOST_ROLE FTCTL_HOST_MANAGEMENT_IP FTCTL_HOST_LIBVIRT_URI \
      FTCTL_HOST_BLOCKCOPY_REPLICATION_IP FTCTL_HOST_XCOLO_CONTROL_IP FTCTL_HOST_XCOLO_DATA_IP
    set -a
    # shellcheck source=/dev/null
    source "${file}"
    set +a
    host_id="${FTCTL_HOST_ID:-}"
    role="${FTCTL_HOST_ROLE:-generic}"
    mgmt_ip="${FTCTL_HOST_MANAGEMENT_IP:-}"
    libvirt_uri="${FTCTL_HOST_LIBVIRT_URI:-}"
    blockcopy_ip="${FTCTL_HOST_BLOCKCOPY_REPLICATION_IP:-}"
    xcolo_ctrl="${FTCTL_HOST_XCOLO_CONTROL_IP:-}"
    xcolo_data="${FTCTL_HOST_XCOLO_DATA_IP:-}"
    [[ -n "${host_id}" ]] || continue
    FTCTL_CLUSTER_HOST_RECORDS+=("${host_id}|${role}|${mgmt_ip}|${libvirt_uri}|${blockcopy_ip}|${xcolo_ctrl}|${xcolo_data}")
  done
  shopt -u nullglob
}

ftctl_cluster_validate_global() {
  [[ -n "${FTCTL_CLUSTER_NAME}" ]] || {
    echo "ERROR: FTCTL_CLUSTER_NAME is required" >&2
    return 2
  }
  ftctl_cluster__validate_id "FTCTL_CLUSTER_NAME" "${FTCTL_CLUSTER_NAME}" || return 2
  [[ -n "${FTCTL_LOCAL_HOST_ID}" ]] || {
    echo "ERROR: FTCTL_LOCAL_HOST_ID is required" >&2
    return 2
  }
  ftctl_cluster__validate_id "FTCTL_LOCAL_HOST_ID" "${FTCTL_LOCAL_HOST_ID}" || return 2
}

ftctl_cluster_validate_host_fields() {
  local host_id="${1-}"
  local role="${2-}"
  local mgmt_ip="${3-}"
  local libvirt_uri="${4-}"
  local blockcopy_ip="${5-}"
  local xcolo_ctrl="${6-}"
  local xcolo_data="${7-}"

  ftctl_cluster__validate_id "FTCTL_HOST_ID" "${host_id}" || return 2
  ftctl_cluster__validate_role "${role}" || return 2
  ftctl_cluster__validate_addr "FTCTL_HOST_MANAGEMENT_IP" "${mgmt_ip}" || return 2
  ftctl_cluster__validate_libvirt_uri "${libvirt_uri}" || return 2
  ftctl_cluster__validate_addr "FTCTL_HOST_BLOCKCOPY_REPLICATION_IP" "${blockcopy_ip}" || return 2
  ftctl_cluster__validate_addr "FTCTL_HOST_XCOLO_CONTROL_IP" "${xcolo_ctrl}" || return 2
  ftctl_cluster__validate_addr "FTCTL_HOST_XCOLO_DATA_IP" "${xcolo_data}" || return 2
}

ftctl_cluster_write_global() {
  local cluster_name="${1-}"
  local local_host_id="${2-}"
  local path tmp

  ftctl_cluster__validate_id "FTCTL_CLUSTER_NAME" "${cluster_name}" || return 2
  ftctl_cluster__validate_id "FTCTL_LOCAL_HOST_ID" "${local_host_id}" || return 2

  path="$(ftctl_cluster__global_path)"
  ftctl_ensure_dir "$(dirname "${path}")" "0755"
  tmp="$(mktemp -t ftctl.cluster.XXXXXX)"
  cat > "${tmp}" <<EOF
FTCTL_CLUSTER_NAME="${cluster_name}"
FTCTL_LOCAL_HOST_ID="${local_host_id}"
EOF
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true

  FTCTL_CLUSTER_NAME="${cluster_name}"
  FTCTL_LOCAL_HOST_ID="${local_host_id}"
  ftctl_log_event "config" "cluster.global.write" "ok" "" "" \
    "cluster=${cluster_name} local_host=${local_host_id}"
}

ftctl_cluster_upsert_host() {
  local host_id="${1-}"
  local role="${2-}"
  local mgmt_ip="${3-}"
  local libvirt_uri="${4-}"
  local blockcopy_ip="${5-}"
  local xcolo_ctrl="${6-}"
  local xcolo_data="${7-}"
  local path tmp

  ftctl_cluster_validate_host_fields "${host_id}" "${role}" "${mgmt_ip}" "${libvirt_uri}" "${blockcopy_ip}" "${xcolo_ctrl}" "${xcolo_data}" || return 2

  path="$(ftctl_cluster__host_path "${host_id}")"
  ftctl_ensure_dir "$(dirname "${path}")" "0755"
  tmp="$(mktemp -t ftctl.cluster.host.XXXXXX)"
  cat > "${tmp}" <<EOF
FTCTL_HOST_ID="${host_id}"
FTCTL_HOST_ROLE="${role}"
FTCTL_HOST_MANAGEMENT_IP="${mgmt_ip}"
FTCTL_HOST_LIBVIRT_URI="${libvirt_uri}"
FTCTL_HOST_BLOCKCOPY_REPLICATION_IP="${blockcopy_ip}"
FTCTL_HOST_XCOLO_CONTROL_IP="${xcolo_ctrl}"
FTCTL_HOST_XCOLO_DATA_IP="${xcolo_data}"
EOF
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
  ftctl_log_event "config" "cluster.host.upsert" "ok" "" "" \
    "host_id=${host_id} role=${role} management_ip=${mgmt_ip}"
}

ftctl_cluster_remove_host() {
  local host_id="${1-}"
  local path

  ftctl_cluster__validate_id "FTCTL_HOST_ID" "${host_id}" || return 2
  path="$(ftctl_cluster__host_path "${host_id}")"
  if [[ -f "${path}" ]]; then
    rm -f "${path}"
    ftctl_log_event "config" "cluster.host.remove" "ok" "" "" "host_id=${host_id}"
  else
    ftctl_log_event "config" "cluster.host.remove" "skip" "" "" "host_id=${host_id}"
  fi
}

ftctl_cluster_host_list_text() {
  local record host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
  ftctl_cluster_load
  for record in "${FTCTL_CLUSTER_HOST_RECORDS[@]}"; do
    host_id="${record%%|*}"
    record="${record#*|}"
    role="${record%%|*}"
    record="${record#*|}"
    mgmt_ip="${record%%|*}"
    record="${record#*|}"
    libvirt_uri="${record%%|*}"
    record="${record#*|}"
    blockcopy_ip="${record%%|*}"
    record="${record#*|}"
    xcolo_ctrl="${record%%|*}"
    xcolo_data="${record##*|}"
    printf '%s role=%s management_ip=%s libvirt_uri=%s blockcopy_ip=%s xcolo_control_ip=%s xcolo_data_ip=%s\n' \
      "${host_id}" "${role}" "${mgmt_ip}" "${libvirt_uri}" "${blockcopy_ip}" "${xcolo_ctrl}" "${xcolo_data}"
  done
}

ftctl_cluster_host_list_json() {
  local first="1"
  local record host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
  ftctl_cluster_load
  printf '['
  for record in "${FTCTL_CLUSTER_HOST_RECORDS[@]}"; do
    host_id="${record%%|*}"
    record="${record#*|}"
    role="${record%%|*}"
    record="${record#*|}"
    mgmt_ip="${record%%|*}"
    record="${record#*|}"
    libvirt_uri="${record%%|*}"
    record="${record#*|}"
    blockcopy_ip="${record%%|*}"
    record="${record#*|}"
    xcolo_ctrl="${record%%|*}"
    xcolo_data="${record##*|}"
    if [[ "${first}" == "1" ]]; then
      first="0"
    else
      printf ','
    fi
    printf '{"host_id":"%s","role":"%s","management_ip":"%s","libvirt_uri":"%s","blockcopy_replication_ip":"%s","xcolo_control_ip":"%s","xcolo_data_ip":"%s"}' \
      "${host_id}" "${role}" "${mgmt_ip}" "${libvirt_uri}" "${blockcopy_ip}" "${xcolo_ctrl}" "${xcolo_data}"
  done
  printf ']\n'
}

ftctl_cluster_find_record_by_libvirt_uri() {
  local uri="${1-}"
  local out_var="${2}"
  local item
  ftctl_cluster_load
  for item in "${FTCTL_CLUSTER_HOST_RECORDS[@]}"; do
    if [[ "${item}" == *"|${uri}|"* ]]; then
      printf -v "${out_var}" '%s' "${item}"
      return 0
    fi
  done
  return 1
}

ftctl_cluster_find_record_by_host_id() {
  local host_id="${1-}"
  local out_var="${2}"
  local item
  ftctl_cluster_load
  for item in "${FTCTL_CLUSTER_HOST_RECORDS[@]}"; do
    if [[ "${item%%|*}" == "${host_id}" ]]; then
      printf -v "${out_var}" '%s' "${item}"
      return 0
    fi
  done
  return 1
}

ftctl_cluster_parse_record() {
  local record="${1-}"
  local host_id_var="${2}"
  local role_var="${3}"
  local mgmt_ip_var="${4}"
  local libvirt_uri_var="${5}"
  local blockcopy_ip_var="${6}"
  local xcolo_ctrl_var="${7}"
  local xcolo_data_var="${8}"
  local rec_host_id rec_role rec_mgmt_ip rec_libvirt_uri rec_blockcopy_ip rec_xcolo_ctrl rec_xcolo_data

  rec_host_id="${record%%|*}"
  record="${record#*|}"
  rec_role="${record%%|*}"
  record="${record#*|}"
  rec_mgmt_ip="${record%%|*}"
  record="${record#*|}"
  rec_libvirt_uri="${record%%|*}"
  record="${record#*|}"
  rec_blockcopy_ip="${record%%|*}"
  record="${record#*|}"
  rec_xcolo_ctrl="${record%%|*}"
  rec_xcolo_data="${record##*|}"

  printf -v "${host_id_var}" '%s' "${rec_host_id}"
  printf -v "${role_var}" '%s' "${rec_role}"
  printf -v "${mgmt_ip_var}" '%s' "${rec_mgmt_ip}"
  printf -v "${libvirt_uri_var}" '%s' "${rec_libvirt_uri}"
  printf -v "${blockcopy_ip_var}" '%s' "${rec_blockcopy_ip}"
  printf -v "${xcolo_ctrl_var}" '%s' "${rec_xcolo_ctrl}"
  printf -v "${xcolo_data_var}" '%s' "${rec_xcolo_data}"
}

ftctl_cluster_find_peer_record_for_vm() {
  local out_var="${1}"
  local record out_record

  if ftctl_cluster_find_record_by_libvirt_uri "${FTCTL_PROFILE_SECONDARY_URI}" out_record; then
    printf -v "${out_var}" '%s' "${out_record}"
    return 0
  fi

  ftctl_cluster_load
  for record in "${FTCTL_CLUSTER_HOST_RECORDS[@]}"; do
    if [[ "${record%%|*}" != "${FTCTL_LOCAL_HOST_ID}" ]]; then
      printf -v "${out_var}" '%s' "${record}"
      return 0
    fi
  done
  return 1
}

ftctl_cluster_probe_management_reachability() {
  local mgmt_ip="${1-}"
  local timeout_sec="${2-1}"
  local out err rc
  [[ -n "${mgmt_ip}" ]] || return 2
  out=""
  err=""
  rc=0
  if command -v ping >/dev/null 2>&1; then
    ftctl_cmd_run "${timeout_sec}" out err rc -- ping -c 1 -W "${timeout_sec}" "${mgmt_ip}" || true
    : "${out}${err}"
    return "${rc}"
  fi
  return 2
}

ftctl_cluster_show() {
  local json="${1-0}"
  ftctl_cluster_load
  if [[ "${json}" == "1" ]]; then
    printf '{"cluster_name":"%s","local_host_id":"%s","hosts":' "${FTCTL_CLUSTER_NAME}" "${FTCTL_LOCAL_HOST_ID}"
    ftctl_cluster_host_list_json
    printf '}\n'
  else
    printf 'cluster=%s local_host=%s hosts_dir=%s\n' \
      "${FTCTL_CLUSTER_NAME}" "${FTCTL_LOCAL_HOST_ID}" "${FTCTL_CLUSTER_HOSTS_DIR}"
    ftctl_cluster_host_list_text
  fi
}
