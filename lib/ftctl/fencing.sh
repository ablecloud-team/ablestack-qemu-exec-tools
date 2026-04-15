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

ftctl_fencing_mark_failed() {
  local vm="${1-}"
  local reason="${2-fencing_failed}"
  ftctl_state_set "${vm}" "fencing_state=failed" "last_error=${reason}"
  ftctl_log_event "fencing" "fencing.failed" "fail" "${vm}" "" "reason=${reason}"
}

ftctl_fencing_clear() {
  local vm="${1-}"
  ftctl_state_set "${vm}" "fencing_state=clear"
  ftctl_log_event "fencing" "fencing.clear" "ok" "${vm}" "" "done=1"
}

ftctl_fencing_manual_confirm() {
  local vm="${1-}"
  ftctl_state_set "${vm}" "fencing_state=manual-fenced"
  ftctl_log_event "fencing" "fencing.manual_confirm" "ok" "${vm}" "" "done=1"
}

ftctl_fencing_source_uri() {
  local vm="${1-}"
  local active_side
  active_side="$(ftctl_state_get "${vm}" "active_side" 2>/dev/null || echo "primary")"
  if [[ "${active_side}" == "secondary" ]]; then
    printf '%s\n' "${FTCTL_PROFILE_SECONDARY_URI}"
  else
    printf '%s\n' "${FTCTL_PROFILE_PRIMARY_URI}"
  fi
}

ftctl_fencing_provider_manual_block() {
  local vm="${1-}"
  local reason="${2-manual}"
  ftctl_fencing_mark_required "${vm}"
  ftctl_log_event "fencing" "provider.manual_block" "warn" "${vm}" "" "reason=${reason}"
  return 3
}

ftctl_fencing_provider_ssh() {
  local vm="${1-}"
  local reason="${2-manual}"
  local source_uri record host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
  local out err rc ssh_target

  source_uri="$(ftctl_fencing_source_uri "${vm}")"
  if ! ftctl_cluster_find_record_by_libvirt_uri "${source_uri}" record; then
    ftctl_fencing_mark_failed "${vm}" "ssh_target_host_not_found"
    return 1
  fi

  ftctl_cluster_parse_record "${record}" host_id role mgmt_ip libvirt_uri blockcopy_ip xcolo_ctrl xcolo_data
  : "${host_id}${role}${libvirt_uri}${blockcopy_ip}${xcolo_ctrl}${xcolo_data}"
  ssh_target="${FTCTL_PROFILE_FENCING_SSH_USER}@${mgmt_ip}"

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" "fencing_state=dry-run"
    ftctl_log_event "fencing" "provider.ssh" "skip" "${vm}" "" \
      "reason=dry_run target=${ssh_target} source_uri=${source_uri}"
    return 4
  fi

  out=""
  err=""
  rc=0
  ftctl_cmd_run "${FTCTL_FENCING_TIMEOUT_SEC}" out err rc -- \
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout="${FTCTL_FENCING_TIMEOUT_SEC}" \
    "${ssh_target}" "sudo systemctl poweroff || sudo poweroff || /sbin/poweroff" || true
  : "${out}${err}"
  if [[ "${rc}" == "0" ]]; then
    ftctl_state_set "${vm}" "fencing_state=fenced"
    ftctl_log_event "fencing" "provider.ssh" "ok" "${vm}" "" \
      "reason=${reason} target=${ssh_target} source_uri=${source_uri}"
    return 0
  fi

  ftctl_fencing_mark_failed "${vm}" "ssh_provider_failed"
  return 1
}

ftctl_fencing_provider_peer_virsh_destroy() {
  local vm="${1-}"
  local reason="${2-manual}"
  local source_uri out err rc

  source_uri="$(ftctl_fencing_source_uri "${vm}")"

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" "fencing_state=dry-run"
    ftctl_log_event "fencing" "provider.peer_virsh_destroy" "skip" "${vm}" "" \
      "reason=dry_run source_uri=${source_uri}"
    return 4
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_FENCING_TIMEOUT_SEC}" out err rc -- -c "${source_uri}" destroy "${vm}" || true
  : "${out}${err}"
  if [[ "${rc}" == "0" ]]; then
    ftctl_state_set "${vm}" "fencing_state=fenced"
    ftctl_log_event "fencing" "provider.peer_virsh_destroy" "ok" "${vm}" "" \
      "reason=${reason} source_uri=${source_uri}"
    return 0
  fi

  case "${err}" in
    *"failed to get domain"*|*"domain is not running"*|*"Domain not found"*)
      ftctl_state_set "${vm}" "fencing_state=fenced"
      ftctl_log_event "fencing" "provider.peer_virsh_destroy" "ok" "${vm}" "" \
        "reason=${reason} source_uri=${source_uri} already_absent=1"
      return 0
      ;;
  esac

  ftctl_fencing_mark_failed "${vm}" "peer_virsh_destroy_failed"
  return 1
}

ftctl_fencing_execute() {
  local vm="${1-}"
  local reason="${2-manual}"
  case "${FTCTL_PROFILE_FENCING_POLICY}" in
    manual-block)
      ftctl_fencing_provider_manual_block "${vm}" "${reason}"
      ;;
    ssh)
      ftctl_fencing_provider_ssh "${vm}" "${reason}"
      ;;
    peer-virsh-destroy)
      ftctl_fencing_provider_peer_virsh_destroy "${vm}" "${reason}"
      ;;
    ipmi|redfish)
      ftctl_fencing_mark_failed "${vm}" "${FTCTL_PROFILE_FENCING_POLICY}_not_implemented"
      return 5
      ;;
    *)
      ftctl_fencing_mark_failed "${vm}" "unknown_fencing_policy"
      return 2
      ;;
  esac
}
