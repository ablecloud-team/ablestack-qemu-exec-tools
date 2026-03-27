#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_fencing_is_explicit() {
  local vm="${1-}"
  local state
  state="$(ftctl_state_get "${vm}" "fencing_state" 2>/dev/null || echo "clear")"
  [[ "${state}" == "fenced" || "${state}" == "manual-fenced" ]]
}

ftctl_fencing_mark_required() {
  local vm="${1-}"
  ftctl_state_set "${vm}" "fencing_state=required"
  ftctl_log_event "fencing" "fencing.required" "warn" "${vm}" "" "policy=${FTCTL_PROFILE_FENCING_POLICY}"
}
