#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ---------------------------------------------------------------------

ftctl_orchestrator_mark_transport_loss() {
  local vm="${1-}"
  local reason="${2-unknown}"
  local current
  current="$(ftctl_state_get "${vm}" "transport_loss_since" 2>/dev/null || true)"
  if [[ -z "${current}" ]]; then
    ftctl_state_set "${vm}" "transport_loss_since=$(ftctl_now_iso8601)"
  fi
  ftctl_state_set "${vm}" \
    "protection_state=degraded" \
    "last_error=${reason}"
}

ftctl_orchestrator_clear_transport_loss() {
  local vm="${1-}"
  ftctl_state_set "${vm}" \
    "transport_loss_since=" \
    "last_error=" \
    "last_reconcile_ts=$(ftctl_now_iso8601)"
}

ftctl_orchestrator_rearm_allowed() {
  local vm="${1-}"
  local elapsed_since_loss elapsed_since_rearm rearm_count
  elapsed_since_loss="$(ftctl_state_get_elapsed_key_sec "${vm}" "transport_loss_since" 2>/dev/null || echo "0")"
  rearm_count="$(ftctl_state_get "${vm}" "rearm_count" 2>/dev/null || echo "0")"
  [[ "${rearm_count}" =~ ^[0-9]+$ ]] || rearm_count="0"

  if (( elapsed_since_loss < FTCTL_TRANSIENT_NET_GRACE_SEC )); then
    return 1
  fi
  if (( rearm_count >= FTCTL_MAX_REARM_ATTEMPTS )); then
    return 2
  fi

  elapsed_since_rearm="$(ftctl_state_get_elapsed_key_sec "${vm}" "last_rearm_ts" 2>/dev/null || echo "${FTCTL_REARM_BACKOFF_SEC}")"
  if (( elapsed_since_rearm < FTCTL_REARM_BACKOFF_SEC )); then
    return 3
  fi
  return 0
}

ftctl_orchestrator_probe_peer() {
  local host_id_var="${1}"
  local mgmt_ip_var="${2}"
  local reach_var="${3}"
  local record host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data rc

  printf -v "${host_id_var}" '%s' ""
  printf -v "${mgmt_ip_var}" '%s' ""
  printf -v "${reach_var}" '%s' "unknown"

  if ! ftctl_cluster_find_peer_record_for_vm record; then
    return 1
  fi

  ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
  : "${role}${libvirt_uri}${blockcopy_ip}${xcolo_ctrl}${xcolo_data}"
  printf -v "${host_id_var}" '%s' "${host_id}"
  printf -v "${mgmt_ip_var}" '%s' "${mgmt_ip}"

  rc=0
  ftctl_cluster_probe_management_reachability "${mgmt_ip}" "1" || rc=$?
  case "${rc}" in
    0) printf -v "${reach_var}" '%s' "reachable" ;;
    1|124) printf -v "${reach_var}" '%s' "unreachable" ;;
    *) printf -v "${reach_var}" '%s' "unknown" ;;
  esac
}

ftctl_orchestrator_handle_transport_issue() {
  local vm="${1-}"
  local mode="${2-}"
  local reason="${3-transport_lost}"
  local peer_host_id="${4-}"
  local peer_reach="${5-unknown}"
  local rearm_rc=0

  if ftctl_fencing_is_explicit "${vm}"; then
    ftctl_state_set "${vm}" \
      "protection_state=failing_over" \
      "transport_state=source_fenced" \
      "last_error=source_fenced"
    ftctl_log_event "failover" "failover.pending" "warn" "${vm}" "" \
      "reason=source_fenced peer_host=${peer_host_id}"
    return 0
  fi

  ftctl_orchestrator_mark_transport_loss "${vm}" "${reason}"

  if [[ "${peer_reach}" == "unreachable" ]]; then
    ftctl_state_set "${vm}" "transport_state=peer_unreachable"
    ftctl_log_event "health" "peer.reachability" "warn" "${vm}" "" \
      "peer_host=${peer_host_id} reachability=${peer_reach}"
    return 0
  fi

  ftctl_orchestrator_rearm_allowed "${vm}" || rearm_rc=$?
  case "${rearm_rc}" in
    0)
      if [[ "${mode}" == "ft" ]]; then
        ftctl_xcolo_rearm "${vm}"
      else
        ftctl_blockcopy_rearm "${vm}"
      fi
      ;;
    1)
      ftctl_state_set "${vm}" "transport_state=transient_loss"
      ftctl_log_event "rearm" "rearm.defer" "warn" "${vm}" "" \
        "reason=grace_window peer_host=${peer_host_id}"
      ;;
    2)
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=rearm_exhausted" \
        "last_error=rearm_attempts_exhausted"
      ftctl_log_event "rearm" "rearm.exhausted" "fail" "${vm}" "" \
        "peer_host=${peer_host_id} max_attempts=${FTCTL_MAX_REARM_ATTEMPTS}"
      ;;
    3)
      ftctl_state_set "${vm}" "transport_state=rearm_backoff"
      ftctl_log_event "rearm" "rearm.defer" "warn" "${vm}" "" \
        "reason=backoff peer_host=${peer_host_id}"
      ;;
    *)
      ftctl_state_set "${vm}" \
        "protection_state=error" \
        "transport_state=unknown" \
        "last_error=rearm_decision_failed"
      ;;
  esac
}

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
  local admin mode transport refresh_rc peer_host_id peer_mgmt_ip peer_reach
  admin="$(ftctl_state_get "${vm}" "admin_state" 2>/dev/null || echo "active")"
  [[ "${admin}" == "paused" ]] && {
    ftctl_log_event "rearm" "reconcile.skip" "skip" "${vm}" "" "reason=admin_paused"
    return 0
  }

  mode="$(ftctl_state_get "${vm}" "mode" 2>/dev/null || echo "")"
  transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "unknown")"

  ftctl_profile_load_vm "${vm}"
  ftctl_profile_apply_cli "${vm}" "${mode}" "" ""
  ftctl_profile_validate "${vm}"
  ftctl_cluster_load || true
  ftctl_orchestrator_probe_peer peer_host_id peer_mgmt_ip peer_reach || true
  : "${peer_mgmt_ip}"
  ftctl_state_set "${vm}" "last_reconcile_ts=$(ftctl_now_iso8601)"

  refresh_rc=0
  if [[ "${mode}" != "ft" ]]; then
    ftctl_blockcopy_refresh_and_classify "${vm}" || refresh_rc=$?
    transport="$(ftctl_state_get "${vm}" "transport_state" 2>/dev/null || echo "${transport}")"
  fi

  if [[ "${mode}" != "ft" ]]; then
    case "${refresh_rc}" in
      0|11)
        ftctl_orchestrator_clear_transport_loss "${vm}"
        ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
        ftctl_log_event "health" "reconcile.tick" "ok" "${vm}" "" \
          "mode=${mode} transport=${transport} peer_host=${peer_host_id} peer_reach=${peer_reach}"
        ;;
      *)
        ftctl_orchestrator_handle_transport_issue "${vm}" "${mode}" "blockcopy_transport_lost" "${peer_host_id}" "${peer_reach}"
        ;;
    esac
    return 0
  fi

  case "${transport}" in
    broken|lost|disconnected|rearm-requested|colo_rearming)
      ftctl_orchestrator_handle_transport_issue "${vm}" "${mode}" "xcolo_transport_lost" "${peer_host_id}" "${peer_reach}"
      ;;
    *)
      ftctl_orchestrator_clear_transport_loss "${vm}"
      ftctl_state_set "${vm}" "last_healthy_ts=$(ftctl_now_iso8601)"
      ftctl_log_event "health" "reconcile.tick" "ok" "${vm}" "" \
        "mode=${mode} transport=${transport} peer_host=${peer_host_id} peer_reach=${peer_reach}"
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
