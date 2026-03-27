#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_xcolo_plan_protect() {
  local vm="${1-}"
  ftctl_state_set "${vm}" \
    "protection_state=colo_preparing" \
    "transport_state=planned" \
    "last_error=skeleton_xcolo_bootstrap_pending"
  ftctl_log_event "colo" "xcolo.protect" "skip" "${vm}" "" \
    "reason=skeleton qmp_timeout=${FTCTL_XCOLO_QMP_TIMEOUT_SEC}"
}

ftctl_xcolo_rearm() {
  local vm="${1-}"
  local count
  count="$(ftctl_state_increment "${vm}" "rearm_count")"
  ftctl_state_set "${vm}" \
    "protection_state=colo_rearming" \
    "transport_state=rearm_pending" \
    "last_rearm_ts=$(ftctl_now_iso8601)" \
    "last_error=skeleton_xcolo_rearm_pending"
  ftctl_log_event "rearm" "xcolo.rearm" "skip" "${vm}" "" \
    "reason=skeleton rearm_count=${count}"
}
