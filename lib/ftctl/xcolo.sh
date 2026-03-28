#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_xcolo_state_path() {
  local vm="${1-}"
  echo "$(ftctl_state_path "${vm}").xcolo"
}

ftctl_xcolo_state_write() {
  local vm="${1-}"
  shift
  local path tmp line
  path="$(ftctl_xcolo_state_path "${vm}")"
  tmp="$(mktemp -t ftctl.xcolo.XXXXXX)"
  for line in "$@"; do
    printf "%s\n" "${line}" >> "${tmp}"
  done
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
}

ftctl_xcolo_parse_tcp_endpoint() {
  local endpoint="${1-}"
  local host_var="${2}"
  local port_var="${3}"
  local rest host port
  [[ "${endpoint}" == tcp:* ]] || {
    echo "ERROR: x-colo endpoint must start with tcp:" >&2
    return 2
  }
  rest="${endpoint#tcp:}"
  host="${rest%:*}"
  port="${rest##*:}"
  [[ -n "${host}" && -n "${port}" ]] || {
    echo "ERROR: invalid x-colo endpoint: ${endpoint}" >&2
    return 2
  }
  printf -v "${host_var}" '%s' "${host}"
  printf -v "${port_var}" '%s' "${port}"
}

ftctl_xcolo_qmp() {
  local uri="${1-}"
  local vm="${2-}"
  local payload="${3-}"
  local out_var="${4}"
  local rc_var="${5}"
  local out err rc

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_XCOLO_QMP_TIMEOUT_SEC}" out err rc -- \
    virsh -c "${uri}" qemu-monitor-command "${vm}" --pretty "${payload}" || true
  : "${err}"
  printf -v "${out_var}" '%s' "${out}"
  printf -v "${rc_var}" '%s' "${rc}"
  return 0
}

ftctl_xcolo_qmp_require_ok() {
  local uri="${1-}"
  local vm="${2-}"
  local payload="${3-}"
  local stage="${4-}"
  local event="${5-}"
  local out rc

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "${stage}" "${event}" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  out=""
  rc=0
  ftctl_xcolo_qmp "${uri}" "${vm}" "${payload}" out rc
  if [[ "${rc}" != "0" ]]; then
    ftctl_log_event "${stage}" "${event}" "fail" "${vm}" "${rc}" "uri=${uri}"
    return "${rc}"
  fi
  ftctl_log_event "${stage}" "${event}" "ok" "${vm}" "" "uri=${uri}"
}

ftctl_xcolo_plan_protect() {
  local vm="${1-}"
  local nbd_host nbd_port

  ftctl_xcolo_parse_tcp_endpoint "${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" nbd_host nbd_port
  ftctl_standby_materialize_primary_xml "${vm}" || true
  ftctl_standby_materialize_xml "${vm}" || true

  ftctl_state_set "${vm}" \
    "protection_state=colo_preparing" \
    "transport_state=planned" \
    "last_error="

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "secondary.qmp_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}}' \
    "colo" "secondary.migrate_set_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"nbd-server-start\",\"arguments\":{\"addr\":{\"type\":\"inet\",\"data\":{\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"}}}}" \
    "colo" "secondary.nbd_server_start" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    "{\"execute\":\"nbd-server-add\",\"arguments\":{\"device\":\"${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}\",\"writable\":true}}" \
    "colo" "secondary.nbd_server_add" || return 1

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"qmp_capabilities"}' "colo" "primary.qmp_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"nbd\",\"node-name\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\",\"server\":{\"type\":\"inet\",\"host\":\"${nbd_host}\",\"port\":\"${nbd_port}\"},\"export\":\"${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}\",\"detect-zeroes\":\"on\"}}" \
    "colo" "primary.blockdev_add" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"x-blockdev-change\",\"arguments\":{\"parent\":\"${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE}\",\"node\":\"${FTCTL_PROFILE_XCOLO_NBD_NODE}\"}}" \
    "colo" "primary.x_blockdev_change" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    '{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"return-path","state":true},{"capability":"x-colo","state":true}]}}' \
    "colo" "primary.migrate_set_capabilities" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate-set-parameters\",\"arguments\":{\"x-checkpoint-delay\":${FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY}}}" \
    "colo" "primary.migrate_set_parameters" || return 1
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_PRIMARY_URI}" "${vm}" \
    "{\"execute\":\"migrate\",\"arguments\":{\"uri\":\"${FTCTL_PROFILE_XCOLO_MIGRATE_URI}\"}}" \
    "colo" "primary.migrate" || return 1

  ftctl_xcolo_state_write "${vm}" \
    "proxy_endpoint=${FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT}" \
    "nbd_endpoint=${FTCTL_PROFILE_XCOLO_NBD_ENDPOINT}" \
    "migrate_uri=${FTCTL_PROFILE_XCOLO_MIGRATE_URI}" \
    "primary_disk_node=${FTCTL_PROFILE_XCOLO_PRIMARY_DISK_NODE}" \
    "parent_block_node=${FTCTL_PROFILE_XCOLO_PARENT_BLOCK_NODE}" \
    "nbd_node=${FTCTL_PROFILE_XCOLO_NBD_NODE}"

  ftctl_state_set "${vm}" \
    "protection_state=colo_running" \
    "transport_state=mirroring" \
    "last_sync_ts=$(ftctl_now_iso8601)" \
    "last_error="
  ftctl_log_event "colo" "xcolo.protect" "ok" "${vm}" "" \
    "qmp_timeout=${FTCTL_XCOLO_QMP_TIMEOUT_SEC}"
}

ftctl_xcolo_rearm() {
  local vm="${1-}"
  local count
  count="$(ftctl_state_increment "${vm}" "rearm_count")"
  ftctl_state_set "${vm}" \
    "protection_state=colo_rearming" \
    "transport_state=rearm_pending" \
    "last_rearm_ts=$(ftctl_now_iso8601)" \
    "last_error="

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"nbd-server-stop"}' "rearm" "secondary.nbd_server_stop" || true
  ftctl_xcolo_plan_protect "${vm}" || {
    ftctl_state_set "${vm}" \
      "protection_state=error" \
      "transport_state=rearm_failed" \
      "last_error=xcolo_rearm_failed"
    return 1
  }
  ftctl_log_event "rearm" "xcolo.rearm" "ok" "${vm}" "" \
    "rearm_count=${count}"
}

ftctl_xcolo_failover() {
  local vm="${1-}"

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" \
      "protection_state=failed_over" \
      "active_side=secondary" \
      "transport_state=colo_failover_dry_run"
    ftctl_log_event "failover" "xcolo.failover" "skip" "${vm}" "" "reason=dry_run"
    return 0
  fi

  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"nbd-server-stop"}' "failover" "secondary.nbd_server_stop" || true
  ftctl_xcolo_qmp_require_ok "${FTCTL_PROFILE_SECONDARY_URI}" "${vm}" \
    '{"execute":"x-colo-lost-heartbeat"}' "failover" "secondary.x_colo_lost_heartbeat" || return 1

  ftctl_state_set "${vm}" \
    "protection_state=failed_over" \
    "active_side=secondary" \
    "transport_state=colo_failover"
  ftctl_log_event "failover" "xcolo.failover" "ok" "${vm}" "" "active_side=secondary"
}
