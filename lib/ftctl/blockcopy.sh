#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_blockcopy_plan_protect() {
  local vm="${1-}"
  ftctl_state_set "${vm}" \
    "protection_state=syncing" \
    "transport_state=planned" \
    "last_error=skeleton_blockcopy_bootstrap_pending"
  ftctl_log_event "mirror" "blockcopy.protect" "skip" "${vm}" "" \
    "reason=skeleton mode=${FTCTL_PROFILE_MODE} sync_writes=${FTCTL_BLOCKCOPY_SYNC_WRITES}"
}

ftctl_blockcopy_rearm() {
  local vm="${1-}"
  local count
  count="$(ftctl_state_increment "${vm}" "rearm_count")"
  ftctl_state_set "${vm}" \
    "protection_state=rearming" \
    "transport_state=rearm_pending" \
    "last_rearm_ts=$(ftctl_now_iso8601)" \
    "last_error=skeleton_blockcopy_rearm_pending"
  ftctl_log_event "rearm" "blockcopy.rearm" "skip" "${vm}" "" \
    "reason=skeleton rearm_count=${count}"
}
