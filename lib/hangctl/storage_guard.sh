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

hangctl_storage__detail_safe() {
  echo "${1-}" | tr '[:space:]' '_' | tr -cd '[:alnum:]_:/,.+-'
}

hangctl_storage__realpath() {
  local path="${1-}"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f -- "${path}" 2>/dev/null || echo "${path}"
    return 0
  fi
  echo "${path}"
}

hangctl_storage__wwid_from_uuid() {
  local uuid="${1-}"
  if [[ "${uuid}" == mpath-* ]]; then
    echo "${uuid#mpath-}"
    return 0
  fi
  echo ""
}

hangctl_storage__reason_matches() {
  local reason="${1-}"
  case "${reason}" in
    libvirt_reported_disk_error|continuous_io_stall_detected|stuck_in_paused_state|qmp_status_paused_stuck)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

hangctl_storage_collect_vm_block_sources() {
  # usage: hangctl_storage_collect_vm_block_sources <vm> <out_array_name>
  # output record: <type>|<target>|<source>
  local vm="${1-}"
  local -n _sources="${2}"
  _sources=()

  local out err rc result
  out=""
  err=""
  rc=0

  hangctl_virsh "${HANGCTL_STORAGE_GUARD_TIMEOUT_SEC}" out err rc -- -c qemu:///system domblklist "${vm}" --details || true
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    local err_short
    err_short="$(hangctl_storage__detail_safe "${err:0:160}")"
    hangctl_log_event "storage" "storage.inventory" "${result}" "${vm}" "" "${rc}" \
      "reason=domblklist_failed timeout_sec=${HANGCTL_STORAGE_GUARD_TIMEOUT_SEC} err=${err_short}"
    return 1
  fi

  local line type device target source
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^Type[[:space:]]+Device[[:space:]]+Target[[:space:]]+Source ]] && continue
    [[ "${line}" =~ ^-+$ ]] && continue

    type=""
    device=""
    target=""
    source=""
    read -r type device target source <<<"${line}"

    [[ "${device}" != "disk" ]] && continue
    [[ "${type}" != "block" && "${type}" != "file" ]] && continue
    [[ -z "${source}" || "${source}" == "-" ]] && continue

    _sources+=("${type}|${target}|${source}")
  done <<<"${out}"

  hangctl_log_event "storage" "storage.inventory" "ok" "${vm}" "" "" \
    "block_sources=${#_sources[@]}"
  return 0
}

hangctl_storage_resolve_mount_info() {
  # usage: hangctl_storage_resolve_mount_info <path> <out_target> <out_source> <out_fstype>
  local path="${1-}"
  local -n _target="${2}"
  local -n _source="${3}"
  local -n _fstype="${4}"
  _target=""
  _source=""
  _fstype=""

  command -v findmnt >/dev/null 2>&1 || return 1

  local out err rc result line
  out=""
  err=""
  rc=0
  hangctl_cmd_run "${HANGCTL_NFS_GUARD_TIMEOUT_SEC}" out err rc -- \
    findmnt -rn -T "${path}" -o TARGET,SOURCE,FSTYPE || true
  result="$(hangctl__result_from_rc "${rc}")"
  [[ "${result}" == "ok" ]] || return 1

  line="$(echo "${out}" | head -n 1 | tr -d '\r')"
  [[ -n "${line}" ]] || return 1
  read -r _target _source _fstype <<<"${line}"
  [[ -n "${_target}" && -n "${_source}" && -n "${_fstype}" ]] || return 1
  return 0
}

hangctl_storage_collect_host_nfs_mounts() {
  # usage: hangctl_storage_collect_host_nfs_mounts <out_array_name>
  # output record: <mountpoint>|<mount_source>|<fstype>
  local -n _mounts="${1}"
  _mounts=()

  command -v findmnt >/dev/null 2>&1 || return 1

  local out err rc result line mountpoint mount_source fstype
  out=""
  err=""
  rc=0
  hangctl_cmd_run "${HANGCTL_NFS_GUARD_TIMEOUT_SEC}" out err rc -- \
    findmnt -rn -t nfs,nfs4 -o TARGET,SOURCE,FSTYPE || true
  result="$(hangctl__result_from_rc "${rc}")"
  [[ "${result}" == "ok" ]] || return 1

  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    mountpoint=""
    mount_source=""
    fstype=""
    read -r mountpoint mount_source fstype <<<"${line}"
    [[ -n "${mountpoint}" && -n "${mount_source}" && -n "${fstype}" ]] || continue
    _mounts+=("${mountpoint}|${mount_source}|${fstype}")
  done <<<"${out}"

  return 0
}

hangctl_storage_extract_nfs_server() {
  local mount_source="${1-}"
  local server=""
  if [[ "${mount_source}" =~ ^\[([0-9a-fA-F:]+)\]:(.*)$ ]]; then
    server="${BASH_REMATCH[1]}"
  else
    server="${mount_source%%:*}"
  fi
  echo "${server}"
}

hangctl_storage_probe_nfs_server() {
  # usage: hangctl_storage_probe_nfs_server <server> <out_detail>
  local server="${1-}"
  local -n _detail="${2}"
  _detail=""

  [[ -n "${server}" ]] || return 1

  local out err rc result
  out=""
  err=""
  rc=0
  hangctl_cmd_run "${HANGCTL_NFS_GUARD_TIMEOUT_SEC}" out err rc -- \
    bash -lc 'host="$1"; port="$2"; host="${host#[}"; host="${host%]}"; : >"/dev/tcp/${host}/${port}"' _ "${server}" "${HANGCTL_NFS_GUARD_PORT}" || true
  result="$(hangctl__result_from_rc "${rc}")"

  if [[ "${result}" == "ok" ]]; then
    _detail="tcp_${HANGCTL_NFS_GUARD_PORT}_reachable"
    return 0
  fi

  _detail="$(hangctl_storage__detail_safe "${result}")"
  [[ -n "${err}" ]] && _detail="${_detail}_$(hangctl_storage__detail_safe "${err:0:120}")"
  return 1
}

hangctl_storage_force_unmount_nfs() {
  # usage: hangctl_storage_force_unmount_nfs <vm> <incident_id> <target> <disk_source> <mountpoint> <mount_source> <server> <probe_detail>
  local vm="${1-}"
  local incident_id="${2-}"
  local target="${3-}"
  local disk_source="${4-}"
  local mountpoint="${5-}"
  local mount_source="${6-}"
  local server="${7-}"
  local probe_detail="${8-}"

  if [[ "${HANGCTL_DRY_RUN}" == "1" ]]; then
    hangctl_log_event "storage" "storage.nfs.force_unmount" "skip" "${vm}" "${incident_id}" "" \
      "reason=dry_run target=${target} source=$(hangctl_storage__detail_safe "${disk_source}") mountpoint=$(hangctl_storage__detail_safe "${mountpoint}") mount_source=$(hangctl_storage__detail_safe "${mount_source}") server=$(hangctl_storage__detail_safe "${server}") probe=${probe_detail}"
    return 0
  fi

  local out err rc result err_short
  out=""
  err=""
  rc=0
  hangctl_cmd_run "${HANGCTL_NFS_GUARD_TIMEOUT_SEC}" out err rc -- umount -R -f -l "${mountpoint}" || true
  result="$(hangctl__result_from_rc "${rc}")"
  err_short="$(hangctl_storage__detail_safe "${err:0:160}")"
  if [[ "${result}" != "ok" ]]; then
    out=""
    err=""
    rc=0
    hangctl_cmd_run "${HANGCTL_NFS_GUARD_TIMEOUT_SEC}" out err rc -- umount -f -l "${mountpoint}" || true
    result="$(hangctl__result_from_rc "${rc}")"
    err_short="$(hangctl_storage__detail_safe "${err:0:160}")"
  fi

  if [[ "${result}" == "ok" ]]; then
    hangctl_log_event "storage" "storage.nfs.force_unmount" "ok" "${vm}" "${incident_id}" "" \
      "target=${target} source=$(hangctl_storage__detail_safe "${disk_source}") mountpoint=$(hangctl_storage__detail_safe "${mountpoint}") mount_source=$(hangctl_storage__detail_safe "${mount_source}") server=$(hangctl_storage__detail_safe "${server}") probe=${probe_detail}"
    return 0
  fi

  hangctl_log_event "storage" "storage.nfs.force_unmount" "${result}" "${vm}" "${incident_id}" "${rc}" \
    "target=${target} source=$(hangctl_storage__detail_safe "${disk_source}") mountpoint=$(hangctl_storage__detail_safe "${mountpoint}") mount_source=$(hangctl_storage__detail_safe "${mount_source}") server=$(hangctl_storage__detail_safe "${server}") probe=${probe_detail} err=${err_short}"
  return 1
}

hangctl_storage_resolve_multipath_map() {
  # usage: hangctl_storage_resolve_multipath_map <source_dev> <out_map_name> <out_dm_name> <out_mode> <out_wwid>
  local source_dev="${1-}"
  local -n _map_name="${2}"
  local -n _dm_name="${3}"
  local -n _mode="${4}"
  local -n _wwid="${5}"
  _map_name=""
  _dm_name=""
  _mode="unknown"
  _wwid=""

  local real_dev out err rc result info_line map_name map_uuid dm_name table
  real_dev="$(hangctl_storage__realpath "${source_dev}")"
  out=""
  err=""
  rc=0

  hangctl_cmd_run "${HANGCTL_STORAGE_GUARD_TIMEOUT_SEC}" out err rc -- \
    dmsetup info -C --noheadings --separator '|' -o name,uuid,blkdevname "${real_dev}" || true
  result="$(hangctl__result_from_rc "${rc}")"
  if [[ "${result}" != "ok" ]]; then
    return 1
  fi

  info_line="$(echo "${out}" | head -n 1 | tr -d '\r')"
  map_name="$(echo "${info_line}" | cut -d'|' -f1 | xargs)"
  map_uuid="$(echo "${info_line}" | cut -d'|' -f2 | xargs)"
  dm_name="$(echo "${info_line}" | cut -d'|' -f3 | xargs)"
  [[ -z "${dm_name}" && "${real_dev}" == /dev/dm-* ]] && dm_name="${real_dev##*/}"
  [[ -z "${map_name}" || -z "${dm_name}" ]] && return 1
  if [[ -z "${map_uuid}" && -r "/sys/block/${dm_name}/dm/uuid" ]]; then
    map_uuid="$(cat "/sys/block/${dm_name}/dm/uuid" 2>/dev/null || true)"
    map_uuid="$(echo "${map_uuid}" | tr -d '\r' | xargs)"
  fi

  out=""
  err=""
  rc=0
  hangctl_cmd_run "${HANGCTL_STORAGE_GUARD_TIMEOUT_SEC}" out err rc -- dmsetup table "${map_name}" || true
  result="$(hangctl__result_from_rc "${rc}")"
  [[ "${result}" != "ok" ]] && return 1
  table="$(echo "${out}" | tr -d '\r')"

  if [[ "${map_uuid}" != mpath-* && "${table}" != *" multipath "* ]]; then
    return 1
  fi

  if [[ "${table}" == *"queue_if_no_path"* ]]; then
    _mode="queue_if_no_path"
  else
    _mode="fail_immediately_or_other"
  fi

  _map_name="${map_name}"
  _dm_name="${dm_name}"
  _wwid="$(hangctl_storage__wwid_from_uuid "${map_uuid}")"
  return 0
}

hangctl_storage_read_multipath_path_state() {
  # usage: hangctl_storage_read_multipath_path_state <dm_name> <out_total> <out_running> <out_states>
  local dm_name="${1-}"
  local -n _total="${2}"
  local -n _running="${3}"
  local -n _states="${4}"
  _total=0
  _running=0
  _states=""

  local slaves_dir="/sys/block/${dm_name}/slaves"
  [[ -d "${slaves_dir}" ]] || return 1

  local slave_path slave_name state state_lc
  for slave_path in "${slaves_dir}"/*; do
    [[ -e "${slave_path}" ]] || continue
    slave_name="$(basename "${slave_path}")"
    state="$(cat "/sys/block/${slave_name}/device/state" 2>/dev/null || echo "unknown")"
    state_lc="$(echo "${state}" | tr '[:upper:]' '[:lower:]' | xargs)"
    _total=$((_total + 1))
    if [[ "${state_lc}" == "running" || "${state_lc}" == "live" ]]; then
      _running=$((_running + 1))
    fi
    if [[ -n "${_states}" ]]; then
      _states+=","
    fi
    _states+="${slave_name}:$(hangctl_storage__detail_safe "${state_lc}")"
  done

  return 0
}

hangctl_storage_force_fail_if_no_path() {
  # usage: hangctl_storage_force_fail_if_no_path <vm> <incident_id> <target> <source> <map_name> <dm_name> <queue_mode> <wwid> <path_total> <path_running> <path_states>
  local vm="${1-}"
  local incident_id="${2-}"
  local target="${3-}"
  local source="${4-}"
  local map_name="${5-}"
  local dm_name="${6-}"
  local queue_mode="${7-}"
  local wwid="${8-}"
  local path_total="${9-0}"
  local path_running="${10-0}"
  local path_states="${11-}"

  if [[ "${HANGCTL_DRY_RUN}" == "1" ]]; then
    hangctl_log_event "storage" "storage.multipath.fail_if_no_path" "skip" "${vm}" "${incident_id}" "" \
      "reason=dry_run target=${target} source=$(hangctl_storage__detail_safe "${source}") map=${map_name} dm=${dm_name} wwid=${wwid} queue_mode=${queue_mode} paths_total=${path_total} paths_running=${path_running} path_states=${path_states}"
    return 0
  fi

  local out err rc result err_short
  out=""
  err=""
  rc=0
  hangctl_cmd_run "${HANGCTL_STORAGE_GUARD_TIMEOUT_SEC}" out err rc -- dmsetup message "${map_name}" 0 "fail_if_no_path" || true
  result="$(hangctl__result_from_rc "${rc}")"
  err_short="$(hangctl_storage__detail_safe "${err:0:160}")"

  if [[ "${result}" == "ok" ]]; then
    hangctl_log_event "storage" "storage.multipath.fail_if_no_path" "ok" "${vm}" "${incident_id}" "" \
      "target=${target} source=$(hangctl_storage__detail_safe "${source}") map=${map_name} dm=${dm_name} wwid=${wwid} queue_mode=${queue_mode} paths_total=${path_total} paths_running=${path_running} path_states=${path_states}"
    return 0
  fi

  hangctl_log_event "storage" "storage.multipath.fail_if_no_path" "${result}" "${vm}" "${incident_id}" "${rc}" \
    "target=${target} source=$(hangctl_storage__detail_safe "${source}") map=${map_name} dm=${dm_name} wwid=${wwid} queue_mode=${queue_mode} paths_total=${path_total} paths_running=${path_running} path_states=${path_states} err=${err_short}"
  return 1
}

hangctl_storage_guard_vm_volumes() {
  # usage: hangctl_storage_guard_vm_volumes <vm> <incident_id> <reason>
  local vm="${1-}"
  local incident_id="${2-}"
  local reason="${3-}"

  if [[ "${HANGCTL_STORAGE_GUARD_ENABLE-1}" != "1" ]]; then
    hangctl_log_event "storage" "storage.guard" "skip" "${vm}" "${incident_id}" "" \
      "reason=disabled"
    return 0
  fi

  if ! hangctl_storage__reason_matches "${reason}"; then
    hangctl_log_event "storage" "storage.guard" "skip" "${vm}" "${incident_id}" "" \
      "reason=not_storage_related confirm_reason=${reason}"
    return 0
  fi

  if ! command -v dmsetup >/dev/null 2>&1; then
    hangctl_log_event "storage" "storage.guard" "skip" "${vm}" "${incident_id}" "" \
      "reason=dmsetup_missing"
    return 0
  fi

  local -a block_sources
  block_sources=()
  hangctl_storage_collect_vm_block_sources "${vm}" block_sources || return 0

  local touched=0 inspected=0 unhealthy=0
  local nfs_mounts=0 nfs_remediated=0 nfs_unreachable=0
  local entry disk_type target source map_name dm_name queue_mode wwid path_total path_running path_states
  for entry in "${block_sources[@]}"; do
    disk_type="${entry%%|*}"
    target="${entry#*|}"
    target="${target%%|*}"
    source="${entry#*|*|}"

    [[ "${disk_type}" == "block" ]] || continue
    inspected=$((inspected + 1))

    if [[ "${disk_type}" == "block" ]]; then
      if ! hangctl_storage_resolve_multipath_map "${source}" map_name dm_name queue_mode wwid; then
        hangctl_log_event "storage" "storage.volume" "skip" "${vm}" "${incident_id}" "" \
          "target=${target} source=$(hangctl_storage__detail_safe "${source}") reason=not_multipath"
        continue
      fi

      path_total=0
      path_running=0
      path_states=""
      if ! hangctl_storage_read_multipath_path_state "${dm_name}" path_total path_running path_states; then
        path_total=0
        path_running=0
        path_states="sysfs_unavailable"
      fi

      local unhealthy_flag="0"
      if [[ "${path_total}" -eq 0 || "${path_running}" -eq 0 ]]; then
        unhealthy_flag="1"
        unhealthy=$((unhealthy + 1))
      fi

      hangctl_log_event "storage" "storage.multipath.inspect" "ok" "${vm}" "${incident_id}" "" \
        "target=${target} source=$(hangctl_storage__detail_safe "${source}") map=${map_name} dm=${dm_name} wwid=${wwid} queue_mode=${queue_mode} paths_total=${path_total} paths_running=${path_running} path_states=${path_states} unhealthy=${unhealthy_flag}"

      [[ "${unhealthy_flag}" == "1" ]] || continue

      if hangctl_storage_force_fail_if_no_path "${vm}" "${incident_id}" "${target}" "${source}" "${map_name}" "${dm_name}" "${queue_mode}" "${wwid}" "${path_total}" "${path_running}" "${path_states}"; then
        touched=$((touched + 1))
      fi
      continue
    fi
  done

  if [[ "${HANGCTL_NFS_GUARD_ENABLE-1}" == "1" ]]; then
    local -a nfs_mount_records
    local mount_record mountpoint mount_source fstype server probe_detail
    nfs_mount_records=()
    if hangctl_storage_collect_host_nfs_mounts nfs_mount_records; then
      nfs_mounts="${#nfs_mount_records[@]}"
      for mount_record in "${nfs_mount_records[@]}"; do
        mountpoint="${mount_record%%|*}"
        mount_source="${mount_record#*|}"
        fstype="${mount_source##*|}"
        mount_source="${mount_source%%|*}"
        server="$(hangctl_storage_extract_nfs_server "${mount_source}")"
        probe_detail=""

        if hangctl_storage_probe_nfs_server "${server}" probe_detail; then
          hangctl_log_event "storage" "storage.nfs.inspect" "ok" "${vm}" "${incident_id}" "" \
            "mountpoint=$(hangctl_storage__detail_safe "${mountpoint}") mount_source=$(hangctl_storage__detail_safe "${mount_source}") fstype=${fstype} server=$(hangctl_storage__detail_safe "${server}") probe=${probe_detail} unhealthy=0"
          continue
        fi

        nfs_unreachable=$((nfs_unreachable + 1))
        hangctl_log_event "storage" "storage.nfs.inspect" "warn" "${vm}" "${incident_id}" "" \
          "mountpoint=$(hangctl_storage__detail_safe "${mountpoint}") mount_source=$(hangctl_storage__detail_safe "${mount_source}") fstype=${fstype} server=$(hangctl_storage__detail_safe "${server}") probe=${probe_detail} unhealthy=1"

        if hangctl_storage_force_unmount_nfs "${vm}" "${incident_id}" "host_nfs" "${mountpoint}" "${mountpoint}" "${mount_source}" "${server}" "${probe_detail}"; then
          nfs_remediated=$((nfs_remediated + 1))
        fi
      done
    else
      hangctl_log_event "storage" "storage.nfs.inventory" "skip" "${vm}" "${incident_id}" "" \
        "reason=inventory_unavailable"
    fi
  else
    hangctl_log_event "storage" "storage.nfs.inventory" "skip" "${vm}" "${incident_id}" "" \
      "reason=disabled"
  fi

  hangctl_log_event "storage" "storage.guard" "ok" "${vm}" "${incident_id}" "" \
    "confirm_reason=${reason} inspected=${inspected} multipath_unhealthy=${unhealthy} multipath_remediated=${touched} nfs_mounts=${nfs_mounts} nfs_unreachable=${nfs_unreachable} nfs_remediated=${nfs_remediated}"
  return 0
}
