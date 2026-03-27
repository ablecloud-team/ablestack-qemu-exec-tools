#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_blockcopy_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").blockcopy"
}

ftctl_blockcopy_reverse_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").blockcopy.reverse"
}

ftctl_blockcopy_state_write() {
  local vm="${1-}"
  shift
  local path tmp line
  path="$(ftctl_blockcopy_state_path "${vm}")"
  tmp="$(mktemp -t ftctl.blockcopy.XXXXXX)"
  for line in "$@"; do
    printf "%s\n" "${line}" >> "${tmp}"
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_blockcopy_resolve_dest() {
  local vm="${1-}"
  local target="${2-}"
  local source="${3-}"
  local format="${4-}"
  local explicit dest source_base

  explicit="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_DISK_MAP}" "${target}" 2>/dev/null || true)"
  if [[ -n "${explicit}" ]]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  if [[ "${FTCTL_PROFILE_DISK_MAP}" == "auto" ]]; then
    source_base="$(basename "${source}")"
    dest="${FTCTL_BLOCKCOPY_TARGET_BASE_DIR}/${vm}/${target}-${source_base}"
    if [[ -n "${format}" ]]; then
      case "${dest}" in
        *.qcow2|*.raw) ;;
        *)
          dest="${dest}.${format}"
          ;;
      esac
    fi
    printf '%s\n' "${dest}"
    return 0
  fi

  echo "ERROR: no destination mapping for disk target ${target}" >&2
  return 2
}

ftctl_blockcopy_resolve_reverse_dest() {
  local target="${1-}"
  local source="${2-}"
  local explicit

  if [[ "${FTCTL_PROFILE_FAILBACK_DISK_MAP}" == "source" ]]; then
    printf '%s\n' "${source}"
    return 0
  fi

  explicit="$(ftctl_profile_lookup_map_value "${FTCTL_PROFILE_FAILBACK_DISK_MAP}" "${target}" 2>/dev/null || true)"
  if [[ -n "${explicit}" ]]; then
    printf '%s\n' "${explicit}"
    return 0
  fi

  echo "ERROR: no reverse destination mapping for disk target ${target}" >&2
  return 2
}

ftctl_blockcopy_start_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local dest="${4-}"
  local format="${5-}"
  local force_reuse="${6-0}"
  local out err rc
  local args=()

  args=(-c "${uri}" blockcopy "${vm}" "${target}" "${dest}")
  if [[ -n "${format}" ]]; then
    args+=("${format}")
  fi
  args+=(--wait --verbose)
  if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
    args+=(--synchronous-writes)
  fi
  if [[ "${force_reuse}" == "1" ]]; then
    args+=(--reuse-external)
  fi
  if [[ "${FTCTL_BLOCKCOPY_BANDWIDTH_MIB}" =~ ^[1-9][0-9]*$ ]]; then
    args+=("${FTCTL_BLOCKCOPY_BANDWIDTH_MIB}")
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- "${args[@]}" || true
  : "${out}${err}"
  return "${rc}"
}

ftctl_blockcopy_abort_job() {
  local uri="${1-}"
  local vm="${2-}"
  local target="${3-}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" blockjob "${vm}" "${target}" --abort || true
  : "${out}${err}"
  return 0
}

ftctl_blockcopy_state_write_reverse() {
  local vm="${1-}"
  shift
  local path tmp line
  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  tmp="$(mktemp -t ftctl.blockcopy.reverse.XXXXXX)"
  for line in "$@"; do
    printf "%s\n" "${line}" >> "${tmp}"
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_blockcopy_job_query() {
  local vm="${1-}"
  local target="${2-}"
  local state_var="${3}"
  local ready_var="${4}"
  local out err rc state ready

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" blockjob "${vm}" "${target}" --info || true
  if [[ "${rc}" != "0" ]]; then
    printf -v "${state_var}" '%s' "unknown"
    printf -v "${ready_var}" '%s' "unknown"
    return "${rc}"
  fi

  state="$(awk -F: 'tolower($1) ~ /state/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<< "${out}")"
  ready="$(awk -F: 'tolower($1) ~ /ready/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}' <<< "${out}")"
  [[ -n "${state}" ]] || state="unknown"
  [[ -n "${ready}" ]] || ready="unknown"
  printf -v "${state_var}" '%s' "${state}"
  printf -v "${ready_var}" '%s' "${ready}"
}

ftctl_blockcopy_refresh_vm_jobs() {
  local vm="${1-}"
  local disks=()
  local line target source format dest job_state ready
  local records=()
  local all_ready="1"
  local rc_any=0

  ftctl_inventory_collect_vm_disks "${vm}" disks || return $?

  for line in "${disks[@]}"; do
    target="${line%%|*}"
    source="${line#*|}"
    source="${source%%|*}"
    format="${line##*|}"
    dest="$(ftctl_blockcopy_resolve_dest "${vm}" "${target}" "${source}" "${format}")"
    job_state="unknown"
    ready="unknown"
    if ! ftctl_blockcopy_job_query "${vm}" "${target}" job_state ready; then
      rc_any=1
    fi
    [[ "${ready}" == "yes" ]] || all_ready="0"
    records+=("${target}|${source}|${dest}|${format}|${job_state}|${ready}")
  done

  ftctl_blockcopy_state_write "${vm}" "${records[@]}"

  if [[ "${all_ready}" == "1" && "${rc_any}" == "0" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=protected" \
      "transport_state=mirroring" \
      "last_sync_ts=$(ftctl_now_iso8601)" \
      "last_error="
  else
    ftctl_state_set "${vm}" \
      "protection_state=syncing" \
      "transport_state=copying" \
      "last_sync_ts=$(ftctl_now_iso8601)"
  fi
}

ftctl_blockcopy_plan_protect() {
  local vm="${1-}"
  local disks=()
  local line target source format dest
  local xml_bundle_dir primary_xml_backup standby_xml_seed persistence
  local out err rc
  local args=()
  local records=()
  local sync_flag="0"

  xml_bundle_dir=""
  primary_xml_backup=""
  standby_xml_seed=""
  persistence="unknown"
  ftctl_inventory_backup_domain_xml "${vm}" xml_bundle_dir primary_xml_backup standby_xml_seed persistence
  ftctl_state_set "${vm}" \
    "xml_bundle_dir=${xml_bundle_dir}" \
    "primary_xml_backup=${primary_xml_backup}" \
    "standby_xml_seed=${standby_xml_seed}" \
    "primary_persistence=${persistence}"

  ftctl_inventory_collect_vm_disks "${vm}" disks

  for line in "${disks[@]}"; do
    target="${line%%|*}"
    source="${line#*|}"
    source="${source%%|*}"
    format="${line##*|}"
    dest="$(ftctl_blockcopy_resolve_dest "${vm}" "${target}" "${source}" "${format}")"
    ftctl_ensure_dir "$(dirname "${dest}")" "0755"

    args=(-c "${FTCTL_PROFILE_PRIMARY_URI}" blockcopy "${vm}" "${target}" "${dest}")
    if [[ -n "${format}" ]]; then
      args+=("${format}")
    fi
    args+=(--wait --verbose)
    if [[ "${FTCTL_BLOCKCOPY_SYNC_WRITES}" == "1" ]]; then
      args+=(--synchronous-writes)
      sync_flag="1"
    fi
    if ftctl_profile_lookup_map_value "${FTCTL_PROFILE_DISK_MAP}" "${target}" >/dev/null 2>&1; then
      args+=(--reuse-external)
    fi
    if [[ "${FTCTL_BLOCKCOPY_BANDWIDTH_MIB}" =~ ^[1-9][0-9]*$ ]]; then
      args+=("${FTCTL_BLOCKCOPY_BANDWIDTH_MIB}")
    fi

    rc=0
    ftctl_blockcopy_start_job "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${target}" "${dest}" "${format}" "0" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=failed" \
        "last_error=blockcopy_start_failed_${target}"
      ftctl_log_event "mirror" "blockcopy.protect" "fail" "${vm}" "${rc}" \
        "target=${target} dest=${dest}"
      return "${rc}"
    fi

    records+=("${target}|${source}|${dest}|${format}|started|unknown")
    ftctl_log_event "mirror" "blockcopy.start" "ok" "${vm}" "" \
      "target=${target} dest=${dest} format=${format} sync_writes=${sync_flag}"
  done

  ftctl_blockcopy_state_write "${vm}" "${records[@]}"
  ftctl_blockcopy_refresh_vm_jobs "${vm}"
  ftctl_standby_prepare "${vm}"
}

ftctl_blockcopy_rearm() {
  local vm="${1-}"
  local count
  local records=()
  local record target source dest format rc_any=0
  count="$(ftctl_state_increment "${vm}" "rearm_count")"
  ftctl_state_set "${vm}" \
    "protection_state=rearming" \
    "transport_state=rearm_pending" \
    "last_rearm_ts=$(ftctl_now_iso8601)" \
    "last_error="

  ftctl_standby_blockcopy_records "${vm}" records || {
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=rearm_failed" \
      "last_error=blockcopy_rearm_missing_state"
    return 1
  }

  for record in "${records[@]}"; do
    target="${record%%|*}"
    record="${record#*|}"
    source="${record%%|*}"
    record="${record#*|}"
    dest="${record%%|*}"
    record="${record#*|}"
    format="${record%%|*}"
    : "${source}"
    ftctl_blockcopy_abort_job "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${target}"
    if ! ftctl_blockcopy_start_job "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" "${target}" "${dest}" "${format}" "1"; then
      rc_any=1
      ftctl_log_event "rearm" "blockcopy.rearm.start" "fail" "${vm}" "" \
        "target=${target} dest=${dest}"
    else
      ftctl_log_event "rearm" "blockcopy.rearm.start" "ok" "${vm}" "" \
        "target=${target} dest=${dest} rearm_count=${count}"
    fi
  done

  if [[ "${rc_any}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=rearm_failed" \
      "last_error=blockcopy_rearm_start_failed"
    return 1
  fi

  ftctl_blockcopy_refresh_vm_jobs "${vm}"
  ftctl_standby_prepare "${vm}"
}

ftctl_blockcopy_prepare_reverse_sync_plan() {
  local vm="${1-}"
  local records=()
  local reverse_records=()
  local record target source dest format reverse_dest

  ftctl_standby_blockcopy_records "${vm}" records || return 1

  for record in "${records[@]}"; do
    target="${record%%|*}"
    record="${record#*|}"
    source="${record%%|*}"
    record="${record#*|}"
    dest="${record%%|*}"
    record="${record#*|}"
    format="${record%%|*}"

    reverse_dest="$(ftctl_blockcopy_resolve_reverse_dest "${target}" "${source}")"
    reverse_records+=("${target}|${dest}|${reverse_dest}|${format}")
  done

  ftctl_blockcopy_state_write_reverse "${vm}" "${reverse_records[@]}"
}

ftctl_blockcopy_start_reverse_sync() {
  local vm="${1-}"
  local path line target source dest format rc_any=0

  ftctl_blockcopy_prepare_reverse_sync_plan "${vm}" || {
    ftctl_state_set "${vm}" "last_error=reverse_sync_plan_failed"
    return 1
  }

  path="$(ftctl_blockcopy_reverse_state_path "${vm}")"
  [[ -f "${path}" ]] || return 1

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    target="${line%%|*}"
    line="${line#*|}"
    source="${line%%|*}"
    line="${line#*|}"
    dest="${line%%|*}"
    format="${line##*|}"
    : "${source}"
    if ! ftctl_blockcopy_start_job "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" "${target}" "${dest}" "${format}" "1"; then
      rc_any=1
      ftctl_log_event "failback" "reverse_sync.start" "fail" "${vm}" "" \
        "target=${target} dest=${dest}"
    else
      ftctl_log_event "failback" "reverse_sync.start" "ok" "${vm}" "" \
        "target=${target} dest=${dest}"
    fi
  done < "${path}"

  if [[ "${rc_any}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=reverse_sync_failed" \
      "last_error=reverse_sync_start_failed"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "transport_state=reverse_syncing" \
    "last_sync_ts=$(ftctl_now_iso8601)"
}

ftctl_blockcopy_refresh_and_classify() {
  local vm="${1-}"
  local rc=0
  ftctl_blockcopy_refresh_vm_jobs "${vm}" || rc=$?
  case "${rc}" in
    0)
      if [[ "$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || true)" == "mirroring" ]]; then
        return 0
      fi
      return 11
      ;;
    *)
      ftctl_state_set "${vm}" \
        "protection_state=degraded" \
        "transport_state=lost" \
        "last_error=blockcopy_refresh_failed"
      return 12
      ;;
  esac
}
