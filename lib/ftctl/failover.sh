#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_failover_request() {
  local vm="${1-}"
  local reason="${2-manual}"
  local count
  count="$(ftctl_state_increment "${vm}" "failover_count")"
  ftctl_state_set "${vm}" \
    "protection_state=failing_over" \
    "last_error=skeleton_failover_pending"
  ftctl_fencing_mark_required "${vm}"
  ftctl_log_event "failover" "failover.request" "skip" "${vm}" "" \
    "reason=${reason} failover_count=${count}"
}

ftctl_failback_request() {
  local vm="${1-}"
  local reason="${2-manual}"
  ftctl_state_set "${vm}" \
    "protection_state=failing_back" \
    "last_error=skeleton_failback_pending"
  ftctl_log_event "failback" "failback.request" "skip" "${vm}" "" \
    "reason=${reason}"
}
