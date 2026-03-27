#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
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
