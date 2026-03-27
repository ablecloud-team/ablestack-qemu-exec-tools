#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_failover_request() {
  local vm="${1-}"
  local reason="${2-manual}"
  local count
  local fence_rc
  count="$(ftctl_state_increment "${vm}" "failover_count")"
  ftctl_state_set "${vm}" \
    "protection_state=failing_over" \
    "last_error=skeleton_failover_pending"
  fence_rc=0
  ftctl_fencing_execute "${vm}" "${reason}" || fence_rc=$?
  case "${fence_rc}" in
    0)
      ftctl_state_set "${vm}" "last_error=fencing_complete_start_pending"
      ftctl_log_event "failover" "failover.request" "ok" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=complete"
      ;;
    3)
      ftctl_state_set "${vm}" "last_error=manual_fencing_required"
      ftctl_log_event "failover" "failover.request" "warn" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=manual_required"
      ;;
    4)
      ftctl_state_set "${vm}" "last_error=dry_run_fencing"
      ftctl_log_event "failover" "failover.request" "skip" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=dry_run"
      ;;
    *)
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "last_error=fencing_failed"
      ftctl_log_event "failover" "failover.request" "fail" "${vm}" "" \
        "reason=${reason} failover_count=${count} fencing=failed"
      return 1
      ;;
  esac
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
