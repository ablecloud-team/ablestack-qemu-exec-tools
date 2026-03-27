#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_verify_vm() {
  local vm="${1-}"
  ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
  ftctl_log_event "verify" "verify.vm" "ok" "${vm}" "" "reason=skeleton"
}
