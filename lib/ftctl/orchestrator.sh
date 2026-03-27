#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# ---------------------------------------------------------------------

ftctl_orchestrator_protect() {
  local vm="${1-}"
  ftctl_state_init_vm "${vm}"
  if [[ "${FTCTL_PROFILE_MODE}" == "ft" ]]; then
    ftctl_xcolo_plan_protect "${vm}"
  else
    ftctl_blockcopy_plan_protect "${vm}"
  fi
  ftctl_verify_vm "${vm}"
  ftctl_state_print_one "${vm}" "0"
}

ftctl_orchestrator_check_vm() {
  local vm="${1-}"
  local json="${2-0}"
  local probe local_rc peer_rc result
  probe="$(ftctl_inventory_check_vm "${vm}")"
  local_rc="${probe%% *}"
  probe="${probe#* }"
  peer_rc="${probe%% *}"
  result="${probe##* }"

  if [[ "${json}" == "1" ]]; then
    printf '{"vm":"%s","primary_rc":"%s","peer_rc":"%s","result":"%s"}\n' \
      "${vm}" "${local_rc}" "${peer_rc}" "${result}"
  else
    printf '%s inventory=%s primary_rc=%s peer_rc=%s\n' "${vm}" "${result}" "${local_rc}" "${peer_rc}"
  fi
}

ftctl_orchestrator_reconcile_one() {
  local vm="${1-}"
  local admin mode transport
  admin="$(ftctl_state_get "${vm}" "admin_state" 2>/dev/null || echo "active")"
  [[ "${admin}" == "paused" ]] && {
    ftctl_log_event "rearm" "reconcile.skip" "skip" "${vm}" "" "reason=admin_paused"
    return 0
  }

  mode="$(ftctl_state_get "${vm}" "mode" 2>/dev/null || echo "")"
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "unknown")"

  ftctl_profile_load_vm "${vm}"
  ftctl_profile_apply_cli "${vm}" "${mode}" "" ""

  case "${transport}" in
    broken|lost|disconnected|rearm-requested)
      if ftctl_fencing_is_explicit "${vm}"; then
        ftctl_log_event "rearm" "reconcile.skip" "skip" "${vm}" "" "reason=source_fenced"
      elif [[ "${mode}" == "ft" ]]; then
        ftctl_xcolo_rearm "${vm}"
      else
        ftctl_blockcopy_rearm "${vm}"
      fi
      ;;
    *)
      ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
      ftctl_log_event "health" "reconcile.tick" "ok" "${vm}" "" "mode=${mode} transport=${transport}"
      ;;
  esac
}

ftctl_orchestrator_reconcile() {
  local vm="${1-}"
  local json="${2-0}"
  local f name
  if [[ -n "${vm}" ]]; then
    ftctl_orchestrator_reconcile_one "${vm}"
    ftctl_state_print_one "${vm}" "${json}"
    return 0
  fi

  shopt -s nullglob
  for f in "${FTCTL_STATE_DIR}"/*.state; do
    name="$(basename "${f}" .state)"
    ftctl_orchestrator_reconcile_one "${name}"
    if [[ "${json}" == "1" ]]; then
      ftctl_state_emit_json "${name}"
    else
      ftctl_state_print_one "${name}" "0"
    fi
  done
  shopt -u nullglob
}
