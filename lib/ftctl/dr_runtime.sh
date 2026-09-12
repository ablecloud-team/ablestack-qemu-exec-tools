#!/usr/bin/env bash
# ---------------------------------------------------------------------

FTCTL_DR_REPROTECT_AUTHORITY_CONTRACT_VERSIONS="${FTCTL_DR_REPROTECT_AUTHORITY_CONTRACT_VERSIONS:-2026-07-23,2026-08-26}"
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

ftctl_dr_runtime_key() {
  local value="${1-}"
  ftctl_state_vm_key "${value}"
}

ftctl_dr_runtime_root() {
  printf '%s/dr-runtime\n' "${FTCTL_RUN_DIR}"
}

ftctl_dr_runtime_plan_dir() {
  local plan="${1-}"
  printf '%s/plans/%s\n' "$(ftctl_dr_runtime_root)" "$(ftctl_dr_runtime_key "${plan}")"
}

ftctl_dr_runtime_profile_path() {
  local plan="${1-}"
  printf '%s/profile.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_artifact_spec_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/test-sessions/%s.artifact-spec.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_authority_spec_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.authority.json\n' "$(ftctl_dr_runtime_run_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_credential_path() {
  local plan="${1-}"
  printf '%s/credentials.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_status_path() {
  local plan="${1-}"
  printf '%s/status.state\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_release_tombstone_path() {
  local plan="${1-}"
  printf '%s/release.json\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_run_dir() {
  local plan="${1-}"
  printf '%s/runs\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_run_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.state\n' "$(ftctl_dr_runtime_run_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_run_journal_dir() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.journals\n' "$(ftctl_dr_runtime_run_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_run_journal_path() {
  local plan="${1-}" run="${2-}" role="${3-}"
  printf '%s/%s.state\n' "$(ftctl_dr_runtime_run_journal_dir "${plan}" "${run}")" "$(ftctl_dr_runtime_key "${role}")"
}

ftctl_dr_runtime_journal_write() {
  local path="${1-}" dir tmp item
  shift
  [[ -n "${path}" ]] || return 1
  dir="$(dirname "${path}")"
  ftctl_ensure_dir "${dir}" "0755"
  tmp="$(mktemp "${dir}/.$(basename "${path}").tmp.XXXXXX")" || return 1
  for item in "$@"; do
    printf '%s\n' "${item}" >> "${tmp}"
  done
  chmod 0644 "${tmp}" 2>/dev/null || true
  sync -f "${tmp}" 2>/dev/null || true
  mv -f -- "${tmp}" "${path}" || { rm -f -- "${tmp}"; return 1; }
  sync -f "${dir}" 2>/dev/null || true
}

ftctl_dr_runtime_journal_value() {
  local path="${1-}" key="${2-}"
  [[ -f "${path}" ]] || return 0
  ftctl_dr_runtime_state_get_from_path "${path}" "${key}"
}

ftctl_dr_runtime_launch_nonce() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '[:space:]' < /proc/sys/kernel/random/uuid
  else
    printf '%s-%s-%s\n' "$(date +%s%N)" "$$" "${RANDOM}"
  fi
}

ftctl_dr_runtime_worker_journal_write() {
  local plan="${1-}" run="${2-}" nonce="${3-}" generation="${4-}" pid="${5-}" start_ticks="${6-}" state="${7-}" now="${8-}"
  local path
  path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" worker)"
  ftctl_dr_runtime_journal_write "${path}" \
    "version=1" "writer_role=worker" "plan=${plan}" "run=${run}" \
    "launch_nonce=${nonce}" "generation=${generation}" "worker_pid=${pid}" \
    "worker_start_ticks=${start_ticks}" "worker_state=${state}" \
    "worker_heartbeat_at=${now}" "written_at=${now}"
}

ftctl_dr_runtime_terminal_journal_write() {
  local plan="${1-}" run="${2-}" nonce="${3-}" generation="${4-}" state="${5-}" exit_code="${6-}" error_code="${7-}" now="${8-}"
  local path
  path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" terminal)"
  ftctl_dr_runtime_journal_write "${path}" \
    "version=1" "writer_role=engine-terminal" "plan=${plan}" "run=${run}" \
    "launch_nonce=${nonce}" "generation=${generation}" "terminal_state=${state}" \
    "terminal_exit_code=${exit_code}" "terminal_error_code=${error_code}" \
    "terminal_source=ENGINE_TERMINAL" "terminal_version=1" \
    "terminal_authoritative=true" "runtime_endpoints_drained=true" "written_at=${now}"
}

ftctl_dr_runtime_failback_worker_live() {
  local plan="${1-}" run="${2-}" worker_path pid ticks actual
  worker_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" worker)"
  [[ -f "${worker_path}" ]] || return 1
  pid="$(ftctl_dr_runtime_journal_value "${worker_path}" worker_pid)"
  ticks="$(ftctl_dr_runtime_journal_value "${worker_path}" worker_start_ticks)"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" >/dev/null 2>&1 || return 1
  actual="$(ftctl_dr_scheduler_process_start_ticks "${pid}" 2>/dev/null || true)"
  [[ -z "${ticks}" || "${actual}" == "${ticks}" ]]
}

ftctl_dr_runtime_other_failback_worker_live() {
  local plan="${1-}" run="${2-}" worker_path worker_run pid ticks actual terminal_path
  shopt -s nullglob
  for worker_path in "$(ftctl_dr_runtime_run_dir "${plan}")"/*.journals/worker.state; do
    worker_run="$(ftctl_dr_runtime_journal_value "${worker_path}" run)"
    [[ -n "${worker_run}" && "${worker_run}" != "${run}" ]] || continue
    terminal_path="$(dirname "${worker_path}")/terminal.state"
    [[ ! -f "${terminal_path}" ]] || continue
    pid="$(ftctl_dr_runtime_journal_value "${worker_path}" worker_pid)"
    ticks="$(ftctl_dr_runtime_journal_value "${worker_path}" worker_start_ticks)"
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    kill -0 "${pid}" >/dev/null 2>&1 || continue
    actual="$(ftctl_dr_scheduler_process_start_ticks "${pid}" 2>/dev/null || true)"
    if [[ -z "${ticks}" || "${actual}" == "${ticks}" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

ftctl_dr_runtime_test_dir() {
  local plan="${1-}"
  printf '%s/test-sessions\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_test_session_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' "$(ftctl_dr_runtime_test_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_active_test_session_path() {
  local plan="${1-}"
  printf '%s/active.json\n' "$(ftctl_dr_runtime_test_dir "${plan}")"
}

ftctl_dr_runtime_test_artifacts_dir() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s-artifacts\n' "$(ftctl_dr_runtime_test_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_failover_dir() {
  local plan="${1-}"
  printf '%s/failovers\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_failover_session_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' "$(ftctl_dr_runtime_failover_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_active_failover_session_path() {
  local plan="${1-}"
  printf '%s/active.json\n' "$(ftctl_dr_runtime_failover_dir "${plan}")"
}

ftctl_dr_runtime_cutover_commit_dir() {
  local plan="${1-}"
  printf '%s/cutover-commits\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_cutover_commit_state_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.commit.state\n' \
    "$(ftctl_dr_runtime_cutover_commit_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_abort_failover_session() {
  local plan="${1-}" run="${2-}" session_id="${3-}" now="${4-}"
  local session_path active_path

  session_path="$(ftctl_dr_runtime_failover_session_path "${plan}" "${run}")"
  active_path="$(ftctl_dr_runtime_active_failover_session_path "${plan}")"
  python3 - "${session_path}" "${active_path}" "${plan}" "${run}" "${session_id}" "${now}" <<'PY'
import json
import os
import sys
import tempfile

session_path, active_path, plan, run, session_id, now = sys.argv[1:7]

def read_session(path):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

def matches(session):
    if not isinstance(session, dict):
        return False
    if str(session.get("planUuid") or "") != plan:
        return False
    if str(session.get("runUuid") or "") != run:
        return False
    return not session_id or str(session.get("sessionId") or "") == session_id

def atomic_write(path, value):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(value, fh, sort_keys=True, separators=(",", ":"))
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(temp_path, path)
        try:
            dir_fd = os.open(directory, os.O_RDONLY)
        except OSError:
            dir_fd = None
        if dir_fd is not None:
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)

session = read_session(session_path)
if session is not None:
    if not matches(session):
        sys.stderr.write("ERROR: failover session identity mismatch\n")
        sys.exit(79)
    session["state"] = "ABORTED"
    session["activeSide"] = "SOURCE"
    session["completedAt"] = now
    session["engineAckState"] = "ABORTED"
    promotion = session.setdefault("targetPromotion", {})
    promotion["state"] = "STANDBY"
    promotion["powerState"] = "POWERED_OFF"
    atomic_write(session_path, session)

active = read_session(active_path)
if active is None:
    sys.exit(0)
if not matches(active):
    # A newer failover session owns the active pointer. Never remove it.
    sys.exit(0)
os.unlink(active_path)
try:
    dir_fd = os.open(os.path.dirname(active_path), os.O_RDONLY)
except OSError:
    dir_fd = None
if dir_fd is not None:
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
PY
}

ftctl_dr_runtime_capture_authority_context() {
  local plan="${1-}" run_path="${2-}" prior_status_path="${3-}" authority_spec_path="${4-}"
  local active_path snapshot_path active_side authority_state checkpoint_sequence
  local target_power_state target_promotion_state session_id authority_generation authority_sequence_floor authority_source key value
  local effective_authority_floor prior_authority_generation prior_authority_floor
  local projected_authority_generation projected_authority_floor
  local -a projection_updates=()

  active_path="$(ftctl_dr_runtime_active_failover_session_path "${plan}")"
  snapshot_path="$(mktemp -t ftctl.dr.authority.XXXXXX)"
  if [[ -f "${active_path}" ]]; then
    python3 - "${active_path}" "${snapshot_path}" <<'PY' || true
import json
import sys

source, target = sys.argv[1:3]
try:
    with open(source, "r", encoding="utf-8") as fh:
        session = json.load(fh)
except (OSError, json.JSONDecodeError):
    session = {}

promotion = session.get("targetPromotion")
if not isinstance(promotion, dict):
    promotion = {}
restore_point = session.get("restorePoint")
if not isinstance(restore_point, dict):
    restore_point = {}

values = {
    "active_side": session.get("activeSide"),
    "authority_state": session.get("state"),
    "checkpoint_sequence": restore_point.get("checkpointSequence"),
    "target_power_state": promotion.get("powerState"),
    "target_promotion_state": promotion.get("state"),
    "cloud_cutover_session_id": session.get("sessionId"),
    "cloud_authority_generation": session.get("cloudAuthorityGeneration"),
}
with open(target, "w", encoding="utf-8") as fh:
    for key, value in values.items():
        fh.write(f"{key}={'' if value is None else value}\n")
PY
  fi

  active_side="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "active_side")"
  authority_state="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "authority_state")"
  checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "checkpoint_sequence")"
  target_power_state="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "target_power_state")"
  target_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "target_promotion_state")"
  session_id="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "cloud_cutover_session_id")"
  authority_generation="$(ftctl_dr_runtime_state_get_from_path "${snapshot_path}" "cloud_authority_generation")"
  authority_source=""

  if [[ "${active_side}" == "TARGET" && "${authority_state}" == "FAILED_OVER" ]]; then
    authority_source="failover-session"
  else
    active_side="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "active_side")"
    authority_state="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "state")"
    checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "checkpoint_sequence")"
    target_power_state="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "target_power_state")"
    target_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "target_promotion_state")"
    session_id="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "cloud_cutover_session_id")"
    authority_generation="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "cloud_authority_generation")"
    if [[ "${active_side}" == "TARGET" && "${authority_state}" == "FAILED_OVER" ]]; then
      authority_source="status-compat"
    fi
  fi
  authority_sequence_floor="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "cloud_authority_sequence_floor")"
  [[ -n "${authority_sequence_floor}" ]] || \
    authority_sequence_floor="$(ftctl_dr_runtime_state_get_from_path "${prior_status_path}" "cloud_authority_sequence_floor")"

  if [[ -n "${authority_spec_path}" && -f "${authority_spec_path}" ]]; then
    local expected_side spec_generation spec_sequence_floor spec_checkpoint spec_power spec_promotion spec_session
    expected_side="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "expectedActiveSide" 2>/dev/null || true)"
    spec_generation="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "authorityGeneration" 2>/dev/null || true)"
    spec_sequence_floor="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "authoritySequenceFloor" 2>/dev/null || true)"
    spec_checkpoint="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "checkpointSequence" 2>/dev/null || true)"
    spec_power="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "targetPowerState" 2>/dev/null || true)"
    spec_promotion="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "targetPromotionState" 2>/dev/null || true)"
    spec_session="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "cutoverSessionId" 2>/dev/null || true)"
    if [[ -n "${active_side}" && "${active_side}" != "${expected_side}" ]]; then
      rm -f "${snapshot_path}" 2>/dev/null || true
      return 79
    fi
    if [[ -n "${authority_generation}" && -n "${spec_generation}" && "${authority_generation}" != "${spec_generation}" ]]; then
      rm -f "${snapshot_path}" 2>/dev/null || true
      return 79
    fi
    if [[ -n "${checkpoint_sequence}" && -n "${spec_checkpoint}" ]]; then
      if [[ "${checkpoint_sequence}" =~ ^[0-9]+$ && "${spec_checkpoint}" =~ ^[0-9]+$ ]]; then
        if (( checkpoint_sequence < spec_checkpoint )); then
          rm -f "${snapshot_path}" 2>/dev/null || true
          return 79
        fi
      elif [[ "${checkpoint_sequence}" != "${spec_checkpoint}" ]]; then
        rm -f "${snapshot_path}" 2>/dev/null || true
        return 79
      fi
    fi
    [[ -n "${active_side}" ]] || active_side="${expected_side}"
    # Operation status can be ERROR after a failed Reprotect while TARGET
    # authority remains committed. Once Cloud's immutable authority contract
    # matches the active side and generation, normalize the authority state
    # independently from that earlier operation result.
    if [[ "${expected_side}" == "TARGET" ]]; then
      authority_state="FAILED_OVER"
    else
      [[ -n "${authority_state}" ]] || authority_state="FAILED_OVER"
    fi
    [[ -n "${authority_generation}" ]] || authority_generation="${spec_generation}"
    [[ -n "${authority_sequence_floor}" ]] || authority_sequence_floor="${spec_sequence_floor}"
    [[ -n "${checkpoint_sequence}" ]] || checkpoint_sequence="${spec_checkpoint}"
    [[ -n "${target_power_state}" ]] || target_power_state="${spec_power}"
    [[ -n "${target_promotion_state}" ]] || target_promotion_state="${spec_promotion}"
    [[ -n "${session_id}" ]] || session_id="${spec_session}"
    [[ -n "${authority_source}" ]] || authority_source="cloud-command"
  fi
  rm -f "${snapshot_path}" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "authority_source=${authority_source}" \
    "authority_state=${authority_state}" \
    "active_side=${active_side}" \
    "checkpoint_sequence=${checkpoint_sequence}" \
    "target_power_state=${target_power_state}" \
    "target_promotion_state=${target_promotion_state}" \
    "cloud_cutover_session_id=${session_id}" \
    "cloud_authority_generation=${authority_generation}" \
    "cloud_authority_sequence_floor=${authority_sequence_floor}" || return $?

  effective_authority_floor="${authority_generation}"
  if [[ "${authority_sequence_floor}" =~ ^[0-9]+$ ]] && \
      { [[ ! "${effective_authority_floor}" =~ ^[0-9]+$ ]] || (( authority_sequence_floor > effective_authority_floor )); }; then
    effective_authority_floor="${authority_sequence_floor}"
  fi
  if [[ "${effective_authority_floor}" =~ ^[0-9]+$ ]]; then
    ftctl_dr_scheduler_floor_authority_sequence "${plan}" "${effective_authority_floor}" >/dev/null || return $?
  fi

  # Authority accepted for an operation is also Plan-owned capability evidence.
  # Keep it monotonic in status.state so plan-scoped preflight and dr-status do
  # not fall back to a stale scheduler sequence after the operation Run exits.
  if [[ -n "${prior_status_path}" ]]; then
    prior_authority_generation="$(ftctl_dr_runtime_state_get_from_path \
      "${prior_status_path}" "cloud_authority_generation")"
    prior_authority_floor="$(ftctl_dr_runtime_state_get_from_path \
      "${prior_status_path}" "cloud_authority_sequence_floor")"
    projected_authority_generation="${authority_generation}"
    projected_authority_floor="${authority_sequence_floor}"
    if [[ "${prior_authority_generation}" =~ ^[0-9]+$ ]] && \
        { [[ ! "${projected_authority_generation}" =~ ^[0-9]+$ ]] || \
          (( prior_authority_generation > projected_authority_generation )); }; then
      projected_authority_generation="${prior_authority_generation}"
    fi
    if [[ "${prior_authority_floor}" =~ ^[0-9]+$ ]] && \
        { [[ ! "${projected_authority_floor}" =~ ^[0-9]+$ ]] || \
          (( prior_authority_floor > projected_authority_floor )); }; then
      projected_authority_floor="${prior_authority_floor}"
    fi
    ftctl_dr_runtime_path_set "${prior_status_path}" \
      "cloud_authority_generation=${projected_authority_generation}" \
      "cloud_authority_sequence_floor=${projected_authority_floor}" || return $?
  fi

  # Preserve the last completed replication cycle as one Plan-owned
  # projection when an operation Run is initialized from a fresh state file.
  # Otherwise failback/reprotect can replace status.state with a Run that has
  # authority fields but has silently dropped the durable checkpoint metrics.
  for key in \
    restore_points_path \
    latest_completed_checkpoint_sequence \
    latest_completed_checkpoint_cycle_type \
    latest_completed_checkpoint_ref \
    latest_completed_checkpoint_state \
    latest_completed_producer_run_uuid \
    latest_completed_source_checkpoint_at \
    latest_completed_target_durable_at \
    latest_completed_target_ready_rpo_seconds \
    latest_completed_manifest_path \
    latest_completed_checkpoint_path \
    latest_completed_requested_mode \
    latest_completed_effective_mode \
    latest_completed_mode_decision_code \
    latest_completed_reseed_reason \
    latest_completed_automatic_reseed \
    latest_completed_invalid_baseline_disk_count \
    latest_completed_incremental_verified \
    latest_completed_metrics_estimated \
    latest_completed_virtual_bytes \
    latest_completed_changed_bytes \
    latest_completed_source_read_bytes \
    latest_completed_target_written_bytes \
    latest_completed_transfer_payload_bytes \
    latest_completed_changed_extent_count \
    latest_completed_duration_ms \
    latest_completed_throughput_bps \
    latest_completed_baseline_generation \
    latest_completed_cycle_token \
    latest_completed_cycle_metrics_path \
    latest_completed_nbd_teardown_state \
    latest_completed_nbd_teardown_started_at_ms \
    latest_completed_nbd_teardown_completed_at_ms \
    latest_completed_nbd_teardown_duration_ms \
    latest_completed_nbd_source_device_count \
    latest_completed_nbd_target_device_count \
    latest_completed_nbd_quarantined_device_count \
    latest_completed_nbd_teardown_error_code \
    latest_completed_nbd_teardown_error_message \
    target_vm_id \
    target_external_ref \
    target_vm_present \
    target_storage_present \
    target_network_present \
    restore_point_present \
    target_materialized
  do
    value="$(ftctl_state_read_kv "${prior_status_path}" "${key}" 2>/dev/null || true)"
    [[ -n "${value}" ]] && projection_updates+=("${key}=${value}")
  done
  (( ${#projection_updates[@]} == 0 )) || \
    ftctl_dr_runtime_path_set "${run_path}" "${projection_updates[@]}"
}

ftctl_dr_runtime_failback_dir() {
  local plan="${1-}"
  printf '%s/failbacks\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_failback_session_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' "$(ftctl_dr_runtime_failback_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_active_failback_session_path() {
  local plan="${1-}"
  printf '%s/active.json\n' "$(ftctl_dr_runtime_failback_dir "${plan}")"
}

ftctl_dr_runtime_failback_commit_state_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.commit.state\n' "$(ftctl_dr_runtime_failback_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_reprotect_dir() {
  local plan="${1-}"
  printf '%s/reprotects\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_reprotect_session_path() {
  local plan="${1-}" run="${2-}"
  printf '%s/%s.json\n' "$(ftctl_dr_runtime_reprotect_dir "${plan}")" "$(ftctl_dr_runtime_key "${run}")"
}

ftctl_dr_runtime_active_reprotect_session_path() {
  local plan="${1-}"
  printf '%s/active.json\n' "$(ftctl_dr_runtime_reprotect_dir "${plan}")"
}

ftctl_dr_runtime_reverse_profile_dir() {
  local plan="${1-}"
  printf '%s/reverse-profiles\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_reverse_profile_path() {
  local plan="${1-}" run="${2-}" phase="${3-reverse}"
  printf '%s/%s-%s.json\n' \
    "$(ftctl_dr_runtime_reverse_profile_dir "${plan}")" \
    "$(ftctl_dr_runtime_key "${run}")" \
    "$(ftctl_dr_runtime_key "${phase}")"
}

ftctl_dr_runtime_reverse_restore_points_path() {
  local plan="${1-}"
  printf '%s/reverse-restore-points.jsonl\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_ensure_plan_dirs() {
  local plan="${1-}"
  ftctl_ensure_dir "$(ftctl_dr_runtime_plan_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_run_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_test_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_failover_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_failback_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_reprotect_dir "${plan}")" "0755"
  ftctl_ensure_dir "$(ftctl_dr_runtime_reverse_profile_dir "${plan}")" "0755"
}

ftctl_dr_runtime_plan_events_path() {
  local plan="${1-}" key
  key="$(ftctl_dr_runtime_key "${plan}")"
  printf '%s/dr-runtime/plans/%s/events.jsonl\n' "${FTCTL_RUN_DIR}" "${key}"
}

ftctl_dr_runtime_events_offset() {
  local plan="${1-}" events_path
  events_path="$(ftctl_dr_runtime_plan_events_path "${plan}")"
  if [[ -f "${events_path}" ]]; then
    wc -l < "${events_path}" | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

ftctl_dr_runtime_validate_profile_file() {
  local profile_file="${1-}"
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 2
  python3 - "${profile_file}" <<'PY' >/dev/null 2>&1
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

if not isinstance(data, dict):
    sys.exit(3)
sys.exit(0)
PY
}

ftctl_dr_runtime_profile_value() {
  local profile_file="${1-}" field="${2-}"
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 1
  python3 - "${profile_file}" "${field}" <<'PY' 2>/dev/null
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

value = data
for part in field.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        sys.exit(1)

if value is None:
    sys.exit(1)
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(str(value))
PY
}

ftctl_dr_runtime_json_text_value() {
  local json_text="${1-}" field="${2-}"
  JSON_TEXT="${json_text}" python3 - "${field}" <<'PY' 2>/dev/null
import json
import os
import sys

field = sys.argv[1]
try:
    data = json.loads(os.environ.get("JSON_TEXT", "{}"))
except json.JSONDecodeError:
    sys.exit(1)
value = data
for part in field.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print("")
        sys.exit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

ftctl_dr_runtime_redacted_profile_json() {
  local profile_file="${1-}"
  python3 - "${profile_file}" <<'PY'
import json
import sys

SECRET_PARTS = ("password", "secret", "token", "apikey", "api_key", "credential")

def redact(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            lower = str(key).lower()
            if lower not in ("checkpointcycletoken", "cycletoken", "latest_completed_cycle_token") and any(part in lower for part in SECRET_PARTS):
                out[key] = "REDACTED"
            else:
                out[key] = redact(item)
        return out
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

print(json.dumps(redact(data), separators=(",", ":"), sort_keys=True))
PY
}

ftctl_dr_runtime_save_credentials() {
  local plan="${1-}" profile_file="${2-}"
  local out_path tmp_path rc=0

  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 0
  out_path="$(ftctl_dr_runtime_credential_path "${plan}")"
  tmp_path="${out_path}.tmp.$$"
  python3 - "${profile_file}" "${tmp_path}" <<'PY' || rc=$?
import json
import os
import sys

profile_path, out_path = sys.argv[1], sys.argv[2]
with open(profile_path, "r", encoding="utf-8") as fh:
    profile = json.load(fh)
credentials = profile.get("credentials")
if not isinstance(credentials, dict) or not credentials:
    sys.exit(3)
payload = {
    "version": 1,
    "credentials": credentials,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
PY
  if [[ "${rc}" == "3" ]]; then
    rm -f "${tmp_path}" 2>/dev/null || true
    return 0
  fi
  [[ "${rc}" == "0" ]] || {
    rm -f "${tmp_path}" 2>/dev/null || true
    return "${rc}"
  }
  chmod 0600 "${tmp_path}" 2>/dev/null || true
  mv -f "${tmp_path}" "${out_path}"
  chmod 0600 "${out_path}" 2>/dev/null || true
}

ftctl_dr_runtime_save_profile() {
  local plan="${1-}" profile_file="${2-}"
  local redacted

  [[ -n "${profile_file}" ]] || return 0
  ftctl_dr_runtime_validate_profile_file "${profile_file}" || return $?
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  ftctl_dr_runtime_save_credentials "${plan}" "${profile_file}" || return $?
  redacted="$(ftctl_dr_runtime_redacted_profile_json "${profile_file}")" || return $?
  ftctl_state_write_json_file "$(ftctl_dr_runtime_profile_path "${plan}")" "${redacted}"
}

ftctl_dr_runtime_save_artifact_spec() {
  local plan="${1-}" run="${2-}" spec_file="${3-}" out_path

  [[ -n "${spec_file}" && -f "${spec_file}" ]] || return 2
  out_path="$(ftctl_dr_runtime_artifact_spec_path "${plan}" "${run}")"
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  python3 - "${spec_file}" "${plan}" "${run}" <<'PY' || return $?
import json
import sys

path, plan, run = sys.argv[1:4]
try:
    with open(path, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write(f"ERROR: invalid artifact spec JSON: {exc}\n")
    sys.exit(53)
if str(spec.get("contractVersion") or "") != "3":
    sys.stderr.write("ERROR: artifact contractVersion 3 is required\n")
    sys.exit(53)
if spec.get("planUuid") != plan or spec.get("runUuid") != run:
    sys.stderr.write("ERROR: artifact spec plan/run correlation mismatch\n")
    sys.exit(53)
disks = spec.get("disks")
if not isinstance(disks, list) or not disks:
    sys.stderr.write("ERROR: artifact spec requires at least one disk\n")
    sys.exit(53)
for index, disk in enumerate(disks):
    if not isinstance(disk, dict):
        sys.stderr.write(f"ERROR: artifact spec disk {index} is invalid\n")
        sys.exit(53)
    provider = str(disk.get("provider") or "").upper()
    locator = str(disk.get("canonicalLocator") or "")
    if provider == "RBD":
        if not locator.startswith("rbd:") or "/" not in locator[4:]:
            sys.stderr.write(f"ERROR: disk {index} requires rbd:pool/image\n")
            sys.exit(53)
    elif provider == "FILE":
        if not locator.startswith("file:/"):
            sys.stderr.write(f"ERROR: disk {index} requires file:/absolute/path\n")
            sys.exit(53)
    else:
        sys.stderr.write(f"ERROR: disk {index} provider {provider} is unsupported\n")
        sys.exit(54)
PY
  ftctl_state_write_json_file "${out_path}" "$(cat "${spec_file}")" || return $?
  chmod 0600 "${out_path}" 2>/dev/null || true
}

ftctl_dr_runtime_save_authority_spec() {
  local plan="${1-}" run="${2-}" spec_file="${3-}" out_path

  [[ -n "${spec_file}" && -f "${spec_file}" ]] || return 2
  out_path="$(ftctl_dr_runtime_authority_spec_path "${plan}" "${run}")"
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  python3 - "${spec_file}" "${plan}" "${run}" \
    "${FTCTL_DR_REPROTECT_AUTHORITY_CONTRACT_VERSIONS}" <<'PY' || return $?
import json
import sys

path, plan, run, supported_csv = sys.argv[1:5]
try:
    with open(path, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write(f"ERROR: invalid authority spec JSON: {exc}\n")
    sys.exit(79)
contract_version = str(spec.get("contractVersion") or "")
supported_contract_versions = {
    item.strip() for item in supported_csv.split(",") if item.strip()
}
if contract_version not in supported_contract_versions:
    sys.stderr.write(
        "ERROR: authority contractVersion must be one of "
        + ", ".join(sorted(supported_contract_versions))
        + "\n"
    )
    sys.exit(79)
if spec.get("planUuid") != plan or spec.get("runUuid") != run:
    sys.stderr.write("ERROR: authority spec plan/run correlation mismatch\n")
    sys.exit(79)
if str(spec.get("expectedActiveSide") or "").upper() != "TARGET":
    sys.stderr.write("ERROR: authority spec requires TARGET active side\n")
    sys.exit(79)
for key in ("authorityGeneration", "checkpointSequence", "targetVmId"):
    try:
        if int(spec.get(key)) <= 0:
            raise ValueError
    except (TypeError, ValueError):
        sys.stderr.write(f"ERROR: authority spec requires positive {key}\n")
        sys.exit(79)
if not str(spec.get("cutoverSessionId") or "").strip():
    sys.stderr.write("ERROR: authority spec requires cutoverSessionId\n")
    sys.exit(79)
PY
  ftctl_state_write_json_file "${out_path}" "$(cat "${spec_file}")" || return $?
  chmod 0600 "${out_path}" 2>/dev/null || true
}

ftctl_dr_runtime_state_get_from_path() {
  local path="${1-}" key="${2-}"
  if [[ -n "${FTCTL_DR_RUNTIME_STATE_SNAPSHOT_PATH:-}" && "${path}" == "${FTCTL_DR_RUNTIME_STATE_SNAPSHOT_PATH}" ]]; then
    if [[ -n "${FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES[${key}]+x}" ]]; then
      printf '%s\n' "${FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES[${key}]}"
    fi
    return 0
  fi
  ftctl_state_read_kv "${path}" "${key}" 2>/dev/null || true
}

ftctl_dr_runtime_state_snapshot_begin() {
  local path="${1-}" key value
  FTCTL_DR_RUNTIME_STATE_SNAPSHOT_PATH="${path}"
  declare -gA FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES=()
  [[ -n "${path}" && -f "${path}" ]] || return 0
  while IFS='=' read -r key value; do
    [[ -n "${key}" ]] || continue
    FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES["${key}"]="${value}"
  done < "${path}"
}

ftctl_dr_runtime_state_snapshot_end() {
  FTCTL_DR_RUNTIME_STATE_SNAPSHOT_PATH=""
  unset FTCTL_DR_RUNTIME_STATE_SNAPSHOT_VALUES
}

ftctl_dr_runtime_atomic_copy() {
  local source="${1-}" target="${2-}" mode="${3-0644}" dir tmp
  [[ -n "${source}" && -f "${source}" && -n "${target}" ]] || return 1
  dir="$(dirname "${target}")"
  ftctl_ensure_dir "${dir}" "0755"
  tmp="$(mktemp "${dir}/.$(basename "${target}").tmp.XXXXXX")" || return 1
  if ! cp -f -- "${source}" "${tmp}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  chmod "${mode}" "${tmp}" 2>/dev/null || true
  sync -f "${tmp}" 2>/dev/null || true
  if ! mv -f -- "${tmp}" "${target}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  sync -f "${dir}" 2>/dev/null || true
}

ftctl_dr_runtime_path_set() {
  local path="${1-}"
  local dir tmp key value
  shift
  [[ -n "${path}" && -f "${path}" ]] || return 1
  dir="$(dirname "${path}")"
  tmp="$(mktemp "${dir}/.$(basename "${path}").set.XXXXXX")" || return 1
  cp -f "${path}" "${tmp}"
  while (($#)); do
    key="${1%%=*}"
    value="${1#*=}"
    if grep -q "^${key}=" "${tmp}"; then
      sed -i "s#^${key}=.*#${key}=${value}#" "${tmp}"
    else
      printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
    fi
    shift
  done
  chmod 0644 "${tmp}" 2>/dev/null || true
  sync -f "${tmp}" 2>/dev/null || true
  mv -f "${tmp}" "${path}"
  chmod 0644 "${path}" 2>/dev/null || true
  sync -f "${dir}" 2>/dev/null || true
}

ftctl_dr_runtime_publish_status() {
  local run_path="${1-}" status_path="${2-}"
  local publishing_run current_owner plan_dir owner_path owner_state owner_worker_state owner_rollback_state owner_active
  [[ -n "${run_path}" && -f "${run_path}" && -n "${status_path}" ]] || return 1
  publishing_run="$(ftctl_state_read_kv "${run_path}" "control_request_run_uuid" 2>/dev/null || true)"
  [[ -n "${publishing_run}" ]] || publishing_run="$(ftctl_state_read_kv "${run_path}" "run_uuid" 2>/dev/null || true)"
  [[ -n "${publishing_run}" ]] || publishing_run="$(basename "${run_path}" .state)"
  if [[ -f "${status_path}" ]]; then
    current_owner="$(ftctl_state_read_kv "${status_path}" "control_request_run_uuid" 2>/dev/null || true)"
    [[ -n "${current_owner}" ]] || current_owner="$(ftctl_state_read_kv "${status_path}" "run_uuid" 2>/dev/null || true)"
    if [[ -n "${current_owner}" && -n "${publishing_run}" && "${current_owner}" != "${publishing_run}" ]]; then
      plan_dir="$(dirname "${status_path}")"
      owner_path="${plan_dir}/runs/${current_owner}.state"
      if [[ -f "${owner_path}" ]]; then
        owner_state="$(ftctl_state_read_kv "${owner_path}" "state" 2>/dev/null || true)"
        owner_worker_state="$(ftctl_state_read_kv "${owner_path}" "worker_state" 2>/dev/null || true)"
        owner_rollback_state="$(ftctl_state_read_kv "${owner_path}" "rollback_state" 2>/dev/null || true)"
        owner_active="false"
        case "${owner_state}" in
          ACCEPTED|RUNNING|SYNCING|RESEEDING|WAITING_RESOURCE|FAILBACK_DATA_READY|COMMIT_VERIFYING|PROTECTION_RESUMING|FAILING_OVER|TESTING|CLEANING_UP)
            owner_active="true"
            ;;
        esac
        case "${owner_worker_state}" in
          PENDING|STARTING|RUNNING) owner_active="true" ;;
        esac
        if [[ "${owner_rollback_state}" != "COMPLETED" && "${owner_active}" == "true" ]]; then
          ftctl_log_event "dr-runtime" "dr.status.publish.skipped_stale_owner" "ok" "" "" \
            "current_owner=${current_owner} publishing_run=${publishing_run} state=${owner_state} worker_state=${owner_worker_state}"
          return 0
        fi
      fi
    fi
  fi
  ftctl_dr_runtime_atomic_copy "${run_path}" "${status_path}" "0644" || return $?
  ftctl_dr_runtime_overlay_failback_plan_authority "${run_path}" "${status_path}"
}

ftctl_dr_runtime_overlay_failback_plan_authority() {
  local run_path="${1-}" status_path="${2-}" plan_dir active_path
  local action current_active_side active_state active_side session_id
  local source_power target_power engine_ack engine_ack_at commit_outcome completed_at post_sequence evidence_run
  local cloud_lifecycle_state
  local -a updates=()
  [[ -f "${run_path}" && -f "${status_path}" ]] || return 1

  action="$(ftctl_state_read_kv "${run_path}" action 2>/dev/null || true)"
  current_active_side="$(ftctl_state_read_kv "${run_path}" active_side 2>/dev/null || true)"
  case "${action}" in
    dr-failover*|dr-reprotect*) return 0 ;;
  esac
  [[ "${current_active_side}" != "TARGET" ]] || return 0

  plan_dir="$(dirname "${status_path}")"
  active_path="${plan_dir}/failbacks/active.json"
  [[ -s "${active_path}" ]] || return 0
  active_state="$(jq -r '.state // empty' "${active_path}" 2>/dev/null || true)"
  [[ "${active_state}" == "PROTECTION_RESUMING" || "${active_state}" == "COMPLETED" ]] || return 0
  active_side="$(jq -r '.activeSide // empty' "${active_path}" 2>/dev/null || true)"
  [[ "${active_side}" == "SOURCE" ]] || return 0

  session_id="$(jq -r '.sessionId // empty' "${active_path}" 2>/dev/null || true)"
  source_power="$(jq -r '.sourcePowerState // empty' "${active_path}" 2>/dev/null || true)"
  target_power="$(jq -r '.targetPowerState // empty' "${active_path}" 2>/dev/null || true)"
  engine_ack="$(jq -r '.engineAckState // empty' "${active_path}" 2>/dev/null || true)"
  engine_ack_at="$(jq -r '.engineAckAt // empty' "${active_path}" 2>/dev/null || true)"
  commit_outcome="$(jq -r '.commitOutcome // empty' "${active_path}" 2>/dev/null || true)"
  completed_at="$(jq -r '.completedAt // empty' "${active_path}" 2>/dev/null || true)"
  post_sequence="$(jq -r '.postFailbackCheckpointSequence // empty' "${active_path}" 2>/dev/null || true)"
  evidence_run="$(jq -r '.runUuid // empty' "${active_path}" 2>/dev/null || true)"
  [[ "${active_state}" == "COMPLETED" ]] && cloud_lifecycle_state="COMPLETED" || cloud_lifecycle_state="COMMITTED"

  updates+=("active_side=SOURCE" "failback_phase=${active_state}" "cloud_lifecycle_state=${cloud_lifecycle_state}")
  [[ -n "${session_id}" ]] && updates+=("failback_session_id=${session_id}")
  [[ -n "${source_power}" ]] && updates+=("source_power_state=${source_power}")
  [[ -n "${target_power}" ]] && updates+=("target_power_state=${target_power}")
  [[ -n "${engine_ack}" ]] && updates+=("engine_ack_state=${engine_ack}")
  [[ -n "${engine_ack_at}" ]] && updates+=("engine_ack_at=${engine_ack_at}")
  [[ -n "${commit_outcome}" ]] && updates+=("failback_commit_outcome=${commit_outcome}")
  [[ -n "${completed_at}" ]] && updates+=("failback_completed_at=${completed_at}")
  [[ -n "${evidence_run}" ]] && updates+=("reverse_evidence_run_uuid=${evidence_run}")
  if [[ "${post_sequence}" =~ ^[1-9][0-9]*$ ]]; then
    updates+=("post_failback_checkpoint_sequence=${post_sequence}")
    updates+=("resume_checkpoint_completed_sequence=${post_sequence}")
  fi
  ftctl_dr_runtime_path_set "${status_path}" "${updates[@]}"
}

# Repair a plan status that still projects an older TARGET-side failover after a
# newer, durably acknowledged failback completed. This is intentionally stricter
# than the read-side overlay because it is allowed to reopen the SOURCE scheduler.
ftctl_dr_runtime_converge_completed_failback_authority() {
  local plan="${1-}" state_path="${2-}" status_path="${3-}"
  local plan_dir active_path failover_path commit_path run_uuid
  local state active_side engine_ack commit_outcome source_power target_power
  local failback_generation failover_generation failback_completed_at failover_completed_at
  local commit_plan commit_run commit_phase commit_state commit_source_power commit_target_power
  local commit_generation commit_checkpoint post_sequence current_state current_side now
  local authority_order

  [[ -n "${plan}" && -f "${state_path}" && -f "${status_path}" ]] || return 1
  plan_dir="$(dirname "${status_path}")"
  active_path="${plan_dir}/failbacks/active.json"
  [[ -s "${active_path}" ]] || return 1

  state="$(jq -r '.state // empty' "${active_path}" 2>/dev/null || true)"
  active_side="$(jq -r '.activeSide // empty' "${active_path}" 2>/dev/null || true)"
  engine_ack="$(jq -r '.engineAckState // empty' "${active_path}" 2>/dev/null || true)"
  commit_outcome="$(jq -r '.commitOutcome // empty' "${active_path}" 2>/dev/null || true)"
  source_power="$(jq -r '.sourcePowerState // empty' "${active_path}" 2>/dev/null || true)"
  target_power="$(jq -r '.targetPowerState // empty' "${active_path}" 2>/dev/null || true)"
  run_uuid="$(jq -r '.runUuid // empty' "${active_path}" 2>/dev/null || true)"
  failback_generation="$(jq -r '.cloudAuthorityGeneration // empty' "${active_path}" 2>/dev/null || true)"
  failback_completed_at="$(jq -r '.completedAt // empty' "${active_path}" 2>/dev/null || true)"
  post_sequence="$(jq -r '.postFailbackCheckpointSequence // empty' "${active_path}" 2>/dev/null || true)"
  [[ "${state}" == "COMPLETED" && "${active_side}" == "SOURCE" \
        && "${engine_ack}" == "ACKNOWLEDGED" && "${commit_outcome}" == "ACKNOWLEDGED" \
        && "${source_power}" == "POWERED_ON" && "${target_power}" == "POWERED_OFF" \
        && -n "${run_uuid}" && "${failback_generation}" =~ ^[1-9][0-9]*$ \
        && "${post_sequence}" =~ ^[1-9][0-9]*$ && -n "${failback_completed_at}" ]] || return 1

  commit_path="$(ftctl_dr_runtime_failback_commit_state_path "${plan}" "${run_uuid}")"
  [[ -f "${commit_path}" ]] || return 1
  commit_plan="$(ftctl_state_read_kv "${commit_path}" plan 2>/dev/null || true)"
  commit_run="$(ftctl_state_read_kv "${commit_path}" run 2>/dev/null || true)"
  commit_phase="$(ftctl_state_read_kv "${commit_path}" phase 2>/dev/null || true)"
  commit_state="$(ftctl_state_read_kv "${commit_path}" outcome 2>/dev/null || true)"
  commit_source_power="$(ftctl_state_read_kv "${commit_path}" source_power_state 2>/dev/null || true)"
  commit_target_power="$(ftctl_state_read_kv "${commit_path}" target_power_state 2>/dev/null || true)"
  commit_generation="$(ftctl_state_read_kv "${commit_path}" authority_generation 2>/dev/null || true)"
  commit_checkpoint="$(ftctl_state_read_kv "${commit_path}" checkpoint_sequence 2>/dev/null || true)"
  [[ "${commit_plan}" == "${plan}" && "${commit_run}" == "${run_uuid}" \
        && "${commit_phase}" == "COMPLETED" && "${commit_state}" == "ACKNOWLEDGED" \
        && "${commit_source_power}" == "POWERED_ON" && "${commit_target_power}" == "POWERED_OFF" \
        && "${commit_generation}" == "${failback_generation}" \
        && "${commit_checkpoint}" =~ ^[1-9][0-9]*$ \
        && "${post_sequence}" -ge "${commit_checkpoint}" ]] || return 1

  # A later TARGET authority must always win. Equal generations are ordered by
  # the durable completion timestamps because failover and failback may share
  # one Cloud authority generation during a round trip.
  failover_path="${plan_dir}/failovers/active.json"
  if [[ -s "${failover_path}" \
        && "$(jq -r '.state // empty' "${failover_path}" 2>/dev/null || true)" == "FAILED_OVER" \
        && "$(jq -r '.activeSide // empty' "${failover_path}" 2>/dev/null || true)" == "TARGET" ]]; then
    failover_generation="$(jq -r '.cloudAuthorityGeneration // empty' "${failover_path}" 2>/dev/null || true)"
    failover_completed_at="$(jq -r '.completedAt // empty' "${failover_path}" 2>/dev/null || true)"
    authority_order="$(python3 - "${failback_generation}" "${failback_completed_at}" \
      "${failover_generation}" "${failover_completed_at}" <<'PY'
import datetime
import sys

fb_generation, fb_at, fo_generation, fo_at = sys.argv[1:5]

def generation(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0

def timestamp(value):
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return 0.0

fb_key = (generation(fb_generation), timestamp(fb_at))
fo_key = (generation(fo_generation), timestamp(fo_at))
print("SOURCE" if fb_key > fo_key else "TARGET")
PY
)"
    [[ "${authority_order}" == "SOURCE" ]] || return 2
  fi

  current_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" state)"
  current_side="$(ftctl_dr_runtime_state_get_from_path "${status_path}" active_side)"
  [[ "${current_state}" == "FAILED_OVER" || "${current_side}" == "TARGET" ]] || return 0
  now="$(ftctl_now_iso8601)"
  local -a updates=(
    "state=READY" "step=target-checkpoint-ready" "progress=100"
    "active_side=SOURCE" "source_power_state=POWERED_ON" "source_promotion_state=PROMOTED"
    "target_power_state=POWERED_OFF" "target_promotion_state=STANDBY"
    "failback_phase=COMPLETED" "cloud_lifecycle_state=COMPLETED"
    "engine_ack_state=ACKNOWLEDGED" "failback_commit_outcome=ACKNOWLEDGED"
    "post_failback_checkpoint_sequence=${post_sequence}"
    "resume_checkpoint_completed_sequence=${post_sequence}"
    "terminal_authoritative=true" "retryable=false" "error_code=" "error_message="
    "updated_at=${now}"
  )
  ftctl_dr_runtime_path_set "${state_path}" "${updates[@]}" || return 1
  ftctl_dr_runtime_path_set "${status_path}" "${updates[@]}" || return 1
  ftctl_log_event "dr-runtime" "dr.failback.authority.converged" "ok" "" "" \
    "plan=${plan} run=${run_uuid} generation=${failback_generation} checkpoint=${post_sequence}"
}

ftctl_dr_runtime_apply_target_authority_terminal_state() {
  local state_path="${1-}" now="${2-$(ftctl_now_iso8601)}"
  [[ -n "${state_path}" && -f "${state_path}" ]] || return 1
  ftctl_dr_runtime_path_set "${state_path}" \
    "scheduler_state=STOPPED" \
    "scheduler_desired_state=STOPPED" \
    "scheduler_health=SUPPRESSED" \
    "scheduler_recovery_state=SUPPRESSED" \
    "replication_activity=STOPPED" \
    "scheduler_pid_alive=false" \
    "owner_matched=false" \
    "active_worker_run_uuid=" \
    "active_worker_pid=" \
    "active_worker_start_ticks=" \
    "worker_heartbeat_at=" \
    "control_state=STOPPED" \
    "updated_at=${now}"
}

ftctl_dr_runtime_record_lock_conflict() {
  local lock_file="${1-}" command_name="${2-}" holder_pid="${3-}" holder_command="${4-}" holder_age="${5-}" exit_code="${6-20}"
  local plan="${CLI_PLAN:-}" run="${CLI_RUN:-}" run_path status_path now

  [[ "${command_name}" == dr-* && -n "${plan}" && -n "${run}" ]] || return 0
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  [[ -f "${run_path}" ]] || return 0
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=RETRYING" \
    "worker_pid=$$" \
    "worker_exit_code=${exit_code}" \
    "worker_updated_at=${now}" \
    "retryable=true" \
    "retry_after_sec=2" \
    "lock_file=${lock_file}" \
    "holder_pid=${holder_pid}" \
    "holder_command=${holder_command}" \
    "holder_age_sec=${holder_age}" \
    "error_code=DR_ENGINE_BUSY_RETRYABLE" \
    "updated_at=${now}" || true
  ftctl_dr_runtime_publish_status "${run_path}" "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_json_string_field() {
  local key="${1-}" value="${2-}"
  printf ',"%s":"%s"' "${key}" "$(ftctl__json_escape "${value}")"
}

ftctl_dr_runtime_json_number_field() {
  local key="${1-}" value="${2-}"
  if [[ -n "${value}" && "${value}" =~ ^[0-9]+$ ]]; then
    printf ',"%s":%s' "${key}" "${value}"
  else
    printf ',"%s":null' "${key}"
  fi
}

ftctl_dr_runtime_json_boolean_field() {
  local key="${1-}" value="${2-}"
  case "${value,,}" in
    true|1|yes)
      printf ',"%s":true' "${key}"
      ;;
    false|0|no)
      printf ',"%s":false' "${key}"
      ;;
    "")
      return 0
      ;;
    *)
      return 65
      ;;
  esac
}

ftctl_dr_runtime_json_file_field_redacted() {
  local key="${1-}" path="${2-}"
  [[ -n "${key}" && -n "${path}" && -f "${path}" ]] || return 0
  python3 - "${key}" "${path}" <<'PY' || true
import json
import sys

SECRET_PARTS = ("password", "secret", "token", "apikey", "api_key", "credential")

def redact(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            lower = str(key).lower()
            if lower not in ("checkpointcycletoken", "cycletoken", "latest_completed_cycle_token") and any(part in lower for part in SECRET_PARTS):
                out[key] = "REDACTED"
            else:
                out[key] = redact(item)
        return out
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value

field, path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
print("," + json.dumps(field, separators=(",", ":")) + ":" + json.dumps(redact(data), sort_keys=True, separators=(",", ":")), end="")
PY
}

ftctl_dr_runtime_rpo_from_target_at() {
  local target_at="${1-}"
  local target_epoch now_epoch
  [[ -n "${target_at}" ]] || return 1
  target_epoch="$(ftctl_iso_to_epoch "${target_at}" 2>/dev/null || true)"
  now_epoch="$(date +%s)"
  [[ "${target_epoch}" =~ ^[0-9]+$ && "${now_epoch}" =~ ^[0-9]+$ && "${now_epoch}" -ge "${target_epoch}" ]] || return 1
  printf '%s\n' "$((now_epoch - target_epoch))"
}

ftctl_dr_runtime_default_restore_points_path() {
  local plan="${1-}" status_path="${2-}" restore_points_path
  restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "restore_points_path")"
  if [[ -z "${restore_points_path}" ]] && command -v ftctl_dr_scheduler_restore_points_path >/dev/null 2>&1; then
    restore_points_path="$(ftctl_dr_scheduler_restore_points_path "${plan}")"
  fi
  if [[ -z "${restore_points_path}" ]]; then
    restore_points_path="$(ftctl_dr_runtime_plan_dir "${plan}")/restore-points.jsonl"
  fi
  printf '%s\n' "${restore_points_path}"
}

ftctl_dr_runtime_remote_source_transition() {
  local profile_file="${1-}"
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 1
  # Cross-Mold target profiles intentionally do not carry a source host UUID.
  # The Cloud-issued site transition scope is the authority boundary; worker
  # placement remains a transient runtime concern resolved by the source Mold.
  jq -e '
    ((.direction // "") | ascii_upcase) == "KVM_TO_KVM"
    and ((.request.schedulerTransitionScope // "") | ascii_upcase) == "REMOTE_SOURCE"
  ' "${profile_file}" >/dev/null 2>&1
}

ftctl_dr_runtime_target_disaster_transition() {
  local profile_file="${1-}"
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 1
  jq -e '
    ((.direction // "") | ascii_upcase) == "KVM_TO_KVM"
    and ((.request.schedulerTransitionScope // "") | ascii_upcase) == "TARGET_DISASTER"
    and ((.request.mode // "") | ascii_downcase) == "disaster"
    and ((.request.finalSync // false) == false)
    and ((.workers.target // "") | length) > 0
  ' "${profile_file}" >/dev/null 2>&1
}

ftctl_dr_runtime_cloud_target_transition() {
  local profile_file="${1-}"
  ftctl_dr_runtime_remote_source_transition "${profile_file}" \
    || ftctl_dr_runtime_target_disaster_transition "${profile_file}"
}

ftctl_dr_runtime_cloud_target_profile_path() {
  local plan="${1-}" candidate
  [[ -n "${plan}" ]] || return 1

  candidate="$(ftctl_dr_runtime_profile_path "${plan}")"
  if ftctl_dr_runtime_cloud_target_transition "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  if command -v ftctl_dr_ablestack_export_persist_profile_path >/dev/null 2>&1; then
    candidate="$(ftctl_dr_ablestack_export_persist_profile_path "${plan}")"
    if ftctl_dr_runtime_cloud_target_transition "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi
  return 1
}

ftctl_dr_runtime_worker_role_path() {
  local plan="${1-}"
  printf '%s/worker-role.state\n' "$(ftctl_dr_runtime_plan_dir "${plan}")"
}

ftctl_dr_runtime_record_worker_role() {
  local plan="${1-}" role="${2-}" path now
  [[ -n "${plan}" && -n "${role}" ]] || return 0
  role="$(printf '%s' "${role}" | tr '[:upper:]' '[:lower:]')"
  case "${role}" in
    source|target|coordinator) ;;
    *) return 2 ;;
  esac
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  path="$(ftctl_dr_runtime_worker_role_path "${plan}")"
  now="$(ftctl_now_iso8601)"
  ftctl_state_write_kv_all "${path}" \
    "plan=${plan}" "worker_role=${role}" "updated_at=${now}"
}

ftctl_dr_runtime_record_export_worker_role() {
  local plan="${1-}" role="${2-}"
  [[ -n "${plan}" && -n "${role}" ]] || return 0
  role="$(printf '%s' "${role}" | tr '[:upper:]' '[:lower:]')"
  case "${role}" in
    reverse-target)
      # This is an action-scoped Failback role, not scheduler authority.
      return 0
      ;;
    source|target|coordinator)
      ftctl_dr_runtime_record_worker_role "${plan}" "${role}"
      ;;
    *)
      return 2
      ;;
  esac
}

ftctl_dr_runtime_local_worker_role() {
  local plan="${1-}" path role
  path="$(ftctl_dr_runtime_worker_role_path "${plan}")"
  role="$(ftctl_state_read_kv "${path}" worker_role 2>/dev/null || true)"
  printf '%s\n' "${role,,}"
}

ftctl_dr_runtime_profile_bool_default() {
  local profile_file="${1-}" field="${2-}" default_value="${3-}"
  local value
  value="$(ftctl_dr_runtime_profile_value "${profile_file}" "${field}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  if [[ -z "${value}" ]]; then
    [[ "${default_value}" == "true" || "${default_value}" == "1" || "${default_value}" == "yes" ]]
    return
  fi
  [[ "${value}" == "true" || "${value}" == "1" || "${value}" == "yes" ]]
}

ftctl_dr_runtime_failover_mode() {
  local mode="${1-}" profile_file="${2-}"
  local request_mode disaster
  request_mode="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.mode" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  disaster="$(ftctl_dr_runtime_profile_value "${profile_file}" "request.disaster" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  mode="$(tr '[:upper:]' '[:lower:]' <<< "${mode:-}")"
  if [[ "${mode}" == "disaster" || "${request_mode}" == "disaster" || "${disaster}" == "true" || "${disaster}" == "1" ]]; then
    printf 'disaster\n'
  else
    printf 'planned\n'
  fi
}

ftctl_dr_runtime_failover_next_sequence() {
  local status_path="${1-}" restore_points_path="${2-}" current
  current="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "checkpoint_sequence")"
  if [[ ! "${current}" =~ ^[0-9]+$ && -n "${restore_points_path}" && -f "${restore_points_path}" ]]; then
    current="$(python3 - "${restore_points_path}" <<'PY' 2>/dev/null || true
import json
import sys

latest = 0
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            value = json.loads(line).get("checkpointSequence")
        except Exception:
            continue
        try:
            latest = max(latest, int(value))
        except Exception:
            pass
print(latest)
PY
)"
  fi
  [[ "${current}" =~ ^[0-9]+$ ]] || current="0"
  printf '%s\n' "$((current + 1))"
}

ftctl_dr_runtime_checkpoint_value() {
  local checkpoint_path="${1-}" key="${2-}" kind="${3-string}"
  if command -v ftctl_dr_scheduler_checkpoint_value >/dev/null 2>&1; then
    ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "${key}" "${kind}"
    return $?
  fi
  python3 - "${checkpoint_path}" "${key}" "${kind}" <<'PY'
import json
import sys

path, key, kind = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    value = json.load(fh).get(key)
if value is None:
    raise SystemExit(1)
if kind == "boolean":
    if not isinstance(value, bool):
        raise SystemExit(1)
    print("true" if value else "false")
elif kind == "integer":
    if isinstance(value, bool) or not isinstance(value, int):
        raise SystemExit(1)
    print(value)
elif isinstance(value, (str, int, float)) and not isinstance(value, bool):
    print(value)
else:
    raise SystemExit(1)
PY
}

# A control Run owns an intent, not a new replication baseline. Preserve only
# validated completed-cycle evidence; never copy another Run's terminal state.
ftctl_dr_runtime_inherit_resume_checkpoint() {
  local plan="${1-}" run_path="${2-}" status_path="${3-}"
  local checkpoint sequence ref baseline key value
  local -a updates=()
  [[ -f "${status_path}" && "${run_path}" != "${status_path}" ]] || return 0
  checkpoint="$(ftctl_dr_runtime_state_get_from_path "${status_path}" latest_completed_checkpoint_path)"
  sequence="$(ftctl_dr_runtime_state_get_from_path "${status_path}" latest_completed_checkpoint_sequence)"
  ref="$(ftctl_dr_runtime_state_get_from_path "${status_path}" latest_completed_checkpoint_ref)"
  baseline="$(ftctl_dr_runtime_state_get_from_path "${status_path}" baseline_state)"
  [[ "${baseline}" != INVALID && "${baseline}" != MISSING ]] || return 0
  [[ "${sequence}" =~ ^[1-9][0-9]*$ && -f "${checkpoint}" && -n "${ref}" ]] || return 0
  jq -e --arg plan "${plan}" --argjson seq "${sequence}" '
    .planUuid == $plan and (.state == "READY" or .state == "TARGET_READY")
    and ((.cycleMetrics.sequence // .sequence // .baselineGeneration) == $seq)
    and ((.targetDurableAt // "") | length > 0)
  ' "${checkpoint}" >/dev/null 2>&1 || return 0
  while IFS='=' read -r key value; do
    case "${key}" in
      latest_completed_*|restore_points_path|source_disk_map_path)
        updates+=("${key}=${value}") ;;
    esac
  done < "${status_path}"
  updates+=("last_target_durable_at=$(jq -r '.targetDurableAt' "${checkpoint}")")
  updates+=("last_source_checkpoint_at=$(jq -r '.sourceCheckpointAt // empty' "${checkpoint}")")
  ftctl_dr_runtime_path_set "${run_path}" "${updates[@]}"
}

ftctl_dr_runtime_publish_latest_completed_checkpoint() {
  local plan="${1-}" run="${2-}" sequence="${3-}" cycle_type="${4-}"
  local manifest_path="${5-}" checkpoint_path="${6-}" run_path="${7-}" status_path="${8-}"
  local checkpoint_ref source_at target_at rpo requested_mode effective_mode mode_decision_code
  local reseed_reason automatic_reseed invalid_baseline_disk_count incremental_verified metrics_estimated
  local virtual_bytes changed_bytes source_read_bytes target_written_bytes transfer_payload_bytes
  local changed_extent_count duration_ms throughput_bps baseline_generation cycle_token cycle_metrics_path
  local nbd_teardown_state nbd_teardown_started_at_ms nbd_teardown_completed_at_ms nbd_teardown_duration_ms
  local nbd_source_device_count nbd_target_device_count nbd_quarantined_device_count
  local nbd_teardown_error_code nbd_teardown_error_message

  [[ "${sequence}" =~ ^[1-9][0-9]*$ && -s "${manifest_path}" && -s "${checkpoint_path}" ]] || return 1
  checkpoint_ref="ftctl:${plan}:${run}:${sequence}"
  source_at="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "sourceCheckpointAt" || true)"
  target_at="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "targetDurableAt" || true)"
  rpo="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "targetReadyRpoSeconds" integer || true)"
  requested_mode="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "requestedMode" || true)"
  effective_mode="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "effectiveMode" || true)"
  mode_decision_code="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "modeDecisionCode" || true)"
  reseed_reason="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "reseedReason" || true)"
  automatic_reseed="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "automaticReseed" boolean || true)"
  invalid_baseline_disk_count="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "invalidBaselineDiskCount" integer || true)"
  incremental_verified="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "incrementalVerified" boolean || true)"
  metrics_estimated="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "metricsEstimated" boolean || true)"
  virtual_bytes="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "virtualBytes" integer || true)"
  changed_bytes="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "changedBytes" integer || true)"
  source_read_bytes="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "sourceReadBytes" integer || true)"
  target_written_bytes="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "targetWrittenBytes" integer || true)"
  transfer_payload_bytes="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "transferPayloadBytes" integer || true)"
  changed_extent_count="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "changedExtentCount" integer || true)"
  duration_ms="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "durationMs" integer || true)"
  throughput_bps="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "throughputBps" integer || true)"
  baseline_generation="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "baselineGeneration" integer || true)"
  cycle_token="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "cycleToken" || true)"
  cycle_metrics_path="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "cycleMetricsPath" || true)"
  nbd_teardown_state="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "nbdTeardownState" || true)"
  nbd_teardown_started_at_ms="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "nbdTeardownStartedAtEpochMs" integer || true)"
  nbd_teardown_completed_at_ms="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "nbdTeardownCompletedAtEpochMs" integer || true)"
  nbd_teardown_duration_ms="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "nbdTeardownDurationMs" integer || true)"
  nbd_source_device_count="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "nbdSourceDeviceCount" integer || true)"
  nbd_target_device_count="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "nbdTargetDeviceCount" integer || true)"
  nbd_quarantined_device_count="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "nbdQuarantinedDeviceCount" integer || true)"
  nbd_teardown_error_code="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "nbdTeardownErrorCode" || true)"
  nbd_teardown_error_message="$(ftctl_dr_runtime_checkpoint_value "${checkpoint_path}" "nbdTeardownErrorMessage" || true)"

  ftctl_dr_runtime_path_set "${run_path}" \
    "latest_completed_checkpoint_sequence=${sequence}" \
    "latest_completed_checkpoint_cycle_type=${cycle_type}" \
    "latest_completed_checkpoint_ref=${checkpoint_ref}" \
    "latest_completed_checkpoint_state=READY" \
    "latest_completed_producer_run_uuid=${run}" \
    "latest_completed_source_checkpoint_at=${source_at}" \
    "latest_completed_target_durable_at=${target_at}" \
    "latest_completed_target_ready_rpo_seconds=${rpo}" \
    "latest_completed_manifest_path=${manifest_path}" \
    "latest_completed_checkpoint_path=${checkpoint_path}" \
    "latest_completed_requested_mode=${requested_mode}" \
    "latest_completed_effective_mode=${effective_mode}" \
    "latest_completed_mode_decision_code=${mode_decision_code}" \
    "latest_completed_reseed_reason=${reseed_reason}" \
    "latest_completed_automatic_reseed=${automatic_reseed:-false}" \
    "latest_completed_invalid_baseline_disk_count=${invalid_baseline_disk_count:-0}" \
    "latest_completed_incremental_verified=${incremental_verified}" \
    "latest_completed_metrics_estimated=${metrics_estimated}" \
    "latest_completed_virtual_bytes=${virtual_bytes}" \
    "latest_completed_changed_bytes=${changed_bytes}" \
    "latest_completed_source_read_bytes=${source_read_bytes}" \
    "latest_completed_target_written_bytes=${target_written_bytes}" \
    "latest_completed_transfer_payload_bytes=${transfer_payload_bytes}" \
    "latest_completed_changed_extent_count=${changed_extent_count}" \
    "latest_completed_duration_ms=${duration_ms}" \
    "latest_completed_throughput_bps=${throughput_bps}" \
    "latest_completed_baseline_generation=${baseline_generation}" \
    "latest_completed_cycle_token=${cycle_token}" \
    "latest_completed_cycle_metrics_path=${cycle_metrics_path}" \
    "latest_completed_nbd_teardown_state=${nbd_teardown_state}" \
    "latest_completed_nbd_teardown_started_at_ms=${nbd_teardown_started_at_ms}" \
    "latest_completed_nbd_teardown_completed_at_ms=${nbd_teardown_completed_at_ms}" \
    "latest_completed_nbd_teardown_duration_ms=${nbd_teardown_duration_ms}" \
    "latest_completed_nbd_source_device_count=${nbd_source_device_count}" \
    "latest_completed_nbd_target_device_count=${nbd_target_device_count}" \
    "latest_completed_nbd_quarantined_device_count=${nbd_quarantined_device_count:-0}" \
    "latest_completed_nbd_teardown_error_code=${nbd_teardown_error_code}" \
    "latest_completed_nbd_teardown_error_message=${nbd_teardown_error_message}" \
    "data_commit_state=LOCAL_DURABLE" \
    "target_durable=true" || return 1
  cp -f "${run_path}" "${status_path}" 2>/dev/null || return 1
}

ftctl_dr_runtime_repair_final_checkpoint_selection() {
  local plan="${1-}" run="${2-}" checkpoint_sequence="${3-}" run_path="${4-}"
  local status_path="${5-}" session_path="${6-}" active_path="${7-}"
  local restore_points_path evidence
  local -a fields=()

  [[ "${checkpoint_sequence}" =~ ^[1-9][0-9]*$ ]] || return 1
  restore_points_path="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  [[ -n "${restore_points_path}" && -s "${restore_points_path}" ]] || return 1

  evidence="$(python3 - "${restore_points_path}" "${plan}" "${run}" "${checkpoint_sequence}" \
    "${session_path}" "${active_path}" <<'PY'
import json
import os
import sys
import tempfile

restore_points_path, plan, run, sequence_text, session_path, active_path = sys.argv[1:7]
sequence = int(sequence_text)
record = None
with open(restore_points_path, "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            candidate = json.loads(line)
        except (TypeError, ValueError):
            continue
        if (str(candidate.get("planUuid") or "") == plan
                and str(candidate.get("runUuid") or "") == run
                and candidate.get("checkpointSequence") == sequence
                and str(candidate.get("cycleType") or "").lower() == "failover-final"
                and str(candidate.get("state") or "").upper() == "TARGET_READY"):
            record = candidate

if record is None:
    raise SystemExit(1)
checkpoint_path = str(record.get("checkpoint") or "")
manifest_path = str(record.get("manifest") or "")
if not checkpoint_path or not manifest_path or not os.path.isfile(checkpoint_path) or not os.path.isfile(manifest_path):
    raise SystemExit(1)
with open(checkpoint_path, "r", encoding="utf-8") as fh:
    checkpoint = json.load(fh)
if (str(checkpoint.get("planUuid") or "") != plan
        or str(checkpoint.get("runUuid") or "") != run
        or checkpoint.get("sequence") != sequence
        or str(checkpoint.get("state") or "").upper() != "TARGET_READY"
        or str(checkpoint.get("cycleCommitState") or "").upper() != "LOCAL_DURABLE"
        or checkpoint.get("targetWritten") is not True
        or checkpoint.get("writeVerified") is not True
        or str(checkpoint.get("nbdTeardownState") or "").upper() != "DRAINED"):
    raise SystemExit(1)

restore_ref = str(record.get("checkpointRef") or f"ftctl:{plan}:{run}:{sequence}")
restore_point = {
    "ref": restore_ref,
    "checkpointSequence": sequence,
    "manifest": manifest_path,
    "checkpoint": checkpoint_path,
    "sourceCheckpointAt": record.get("sourceCheckpointAt") or checkpoint.get("sourceCheckpointAt"),
    "targetDurableAt": record.get("targetDurableAt") or checkpoint.get("targetDurableAt"),
    "targetReadyRpoSeconds": record.get("targetReadyRpoSeconds") or checkpoint.get("targetReadyRpoSeconds"),
}

def update_session(path):
    if not path or not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        session = json.load(fh)
    if str(session.get("planUuid") or "") != plan or str(session.get("runUuid") or "") != run:
        raise SystemExit(1)
    session["restorePoint"] = restore_point
    directory = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(prefix=".failover-final.", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(session, fh, sort_keys=True, separators=(",", ":"))
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)

update_session(session_path)
update_session(active_path)
for value in (
    restore_ref,
    manifest_path,
    checkpoint_path,
    str(restore_point.get("sourceCheckpointAt") or ""),
    str(restore_point.get("targetDurableAt") or ""),
    "" if restore_point.get("targetReadyRpoSeconds") is None else str(restore_point.get("targetReadyRpoSeconds")),
):
    print(value)
print("__FTCTL_FINAL_CHECKPOINT_EVIDENCE_END__")
PY
)" || return 1
  mapfile -t fields <<< "${evidence}"
  [[ "${#fields[@]}" -ge 7 && -n "${fields[0]}" \
      && "${fields[6]}" == "__FTCTL_FINAL_CHECKPOINT_EVIDENCE_END__" ]] || return 1

  ftctl_dr_runtime_path_set "${run_path}" \
    "failover_restore_point_ref=${fields[0]}" \
    "failover_restore_point_sequence=${checkpoint_sequence}" \
    "failover_manifest_path=${fields[1]}" \
    "failover_checkpoint_path=${fields[2]}" \
    "failover_final_checkpoint_sequence=${checkpoint_sequence}" \
    "failover_final_restore_point_ref=${fields[0]}" \
    "last_source_checkpoint_at=${fields[3]}" \
    "last_target_durable_at=${fields[4]}" \
    "target_ready_rpo_seconds=${fields[5]}" \
    "updated_at=$(ftctl_now_iso8601)" || return 1
  ftctl_dr_runtime_publish_latest_completed_checkpoint "${plan}" "${run}" "${checkpoint_sequence}" \
    "failover-final" "${fields[1]}" "${fields[2]}" "${run_path}" "${status_path}"
}

ftctl_dr_runtime_build_reverse_profile() {
  local plan="${1-}" run="${2-}" source_profile="${3-}" out_profile="${4-}" operation="${5-reverse}"

  [[ -n "${source_profile}" && -f "${source_profile}" && -n "${out_profile}" ]] || return 2
  ftctl_ensure_dir "$(dirname "${out_profile}")" "0755"
  python3 - "${plan}" "${run}" "${source_profile}" "${out_profile}" "${operation}" <<'PY'
import copy
import json
import os
import sys

plan, run, source_profile, out_profile, operation = sys.argv[1:6]

with open(source_profile, "r", encoding="utf-8") as fh:
    profile = json.load(fh)

def obj(value):
    return value if isinstance(value, dict) else {}

def arr(value):
    return value if isinstance(value, list) else []

def first_str(*values):
    for value in values:
        if value is None or isinstance(value, (dict, list)):
            continue
        text = str(value).strip()
        if text:
            return text
    return ""

def value_at(data, *keys):
    if not isinstance(data, dict):
        return None
    for key in keys:
        if key in data:
            return data.get(key)
    return None

def reverse_direction(direction):
    normalized = str(direction or "").upper()
    return {
        "KVM_TO_KVM": "KVM_TO_KVM",
        "ABLESTACK_TO_ABLESTACK": "ABLESTACK_TO_ABLESTACK",
        "KVM_TO_VMWARE": "VMWARE_TO_KVM",
        "ABLESTACK_TO_VMWARE": "VMWARE_TO_ABLESTACK",
        "VMWARE_TO_KVM": "KVM_TO_VMWARE",
        "VMWARE_TO_ABLESTACK": "ABLESTACK_TO_VMWARE",
        "VMWARE_TO_VMWARE": "VMWARE_TO_VMWARE",
    }.get(normalized, normalized)

def endpoint_ref(item, endpoint, path_keys, disk_keys, vmdk_keys):
    endpoint_obj = obj(item.get(endpoint))
    return first_str(
        *(value_at(item, key) for key in path_keys),
        *(value_at(endpoint_obj, key) for key in ("path", "diskRef", "disk", "ref", "vmdkPath")),
        *(value_at(item, key) for key in disk_keys),
        *(value_at(item, key) for key in vmdk_keys),
    )

def rbd_pool(value):
    text = str(value or "").strip()
    for prefix in ("rbd:", "rbd/", "/dev/rbd/"):
        if text.startswith(prefix):
            text = text[len(prefix):]
            break
    text = text.strip("/")
    return text.split("/", 1)[0] if text else ""

def canonical_rbd_ref(value, endpoint, item, prefix):
    text = str(value or "").strip()
    if not text or text.startswith(("rbd:", "rbd/", "/dev/rbd/")):
        return text
    storage_type = first_str(
        value_at(endpoint, "storagePoolType", "poolType", "storageType"),
        value_at(item, f"{prefix}StorageType"),
    ).upper()
    storage_path = first_str(
        value_at(endpoint, "storagePath", "pathPrefix", "krbdPath"),
        value_at(item, f"{prefix}StoragePath", f"{prefix}StorageKrbdPath"),
    )
    if "RBD" not in storage_type and not str(storage_path).startswith(("rbd", "/dev/rbd/")):
        return text
    pool = rbd_pool(storage_path)
    if not pool:
        return text
    return f"rbd:{pool}/{os.path.basename(text.rstrip('/'))}"

def reverse_disk(item, index):
    item = obj(item)
    source = obj(item.get("source"))
    target = obj(item.get("target"))
    old_source_ref = endpoint_ref(
        item, "source",
        ("sourcePath", "sourceDisk", "sourceRef"),
        ("sourceDiskRef",),
        ("sourceVmdkPath",),
    )
    old_target_ref = endpoint_ref(
        item, "target",
        ("targetPath", "targetDisk", "destination", "dest", "targetRef"),
        ("targetDiskRef",),
        ("targetVmdkPath",),
    )
    old_source_ref = canonical_rbd_ref(old_source_ref, source, item, "source")
    old_target_ref = canonical_rbd_ref(old_target_ref, target, item, "target")
    reversed_item = copy.deepcopy(item)
    reversed_item["device"] = first_str(
        value_at(item, "device", "targetDevice", "diskTarget", "unitNumber", "key"),
        value_at(source, "device", "targetDevice", "unitNumber", "key"),
        value_at(target, "device", "targetDevice", "unitNumber", "key"),
        f"disk{index}",
    )
    reversed_item["source"] = copy.deepcopy(target)
    reversed_item["target"] = copy.deepcopy(source)
    reversed_item["sourcePath"] = old_target_ref
    reversed_item["targetPath"] = old_source_ref
    reversed_item["sourceDiskRef"] = first_str(value_at(item, "targetDiskRef"), old_target_ref)
    reversed_item["targetDiskRef"] = first_str(value_at(item, "sourceDiskRef"), old_source_ref)
    reversed_item["sourceVmdkPath"] = first_str(value_at(item, "targetVmdkPath"), old_target_ref)
    reversed_item["targetVmdkPath"] = first_str(value_at(item, "sourceVmdkPath"), old_source_ref)
    reversed_item["sourceFormat"] = first_str(value_at(item, "targetFormat"), value_at(target, "format"), value_at(item, "format"))
    reversed_item["targetFormat"] = first_str(value_at(item, "sourceFormat"), value_at(source, "format"), value_at(item, "format"))
    if "targetType" in item:
        reversed_item["sourceType"] = item.get("targetType")
    if "sourceType" in item:
        reversed_item["targetType"] = item.get("sourceType")
    if "changeId" in reversed_item:
        reversed_item.pop("changeId", None)
    if "snapshotRef" in reversed_item:
        reversed_item.pop("snapshotRef", None)
    return reversed_item

def disk_items_from(profile):
    mapping = obj(profile.get("mapping"))
    for key in ("disks", "diskMappings", "volumes", "volumeMappings"):
        values = arr(mapping.get(key))
        if values:
            return key, values
    for key in ("disks", "diskMappings", "volumes"):
        values = arr(profile.get(key))
        if values:
            return key, values
    return "disks", []

source = obj(profile.get("source"))
target = obj(profile.get("target"))
mapping = copy.deepcopy(obj(profile.get("mapping")))
disk_key, disk_items = disk_items_from(profile)
reversed_disks = [reverse_disk(item, index) for index, item in enumerate(disk_items)]

reverse = copy.deepcopy(profile)
reverse["planUuid"] = plan or profile.get("planUuid", "")
reverse["runUuid"] = run or profile.get("runUuid", "")
reverse["direction"] = reverse_direction(profile.get("direction"))
reverse["source"] = copy.deepcopy(target)
reverse["target"] = copy.deepcopy(source)
workers = copy.deepcopy(obj(profile.get("workers")))
workers["source"], workers["target"] = workers.get("target", ""), workers.get("source", "")
reverse["workers"] = workers
reverse["originalDirection"] = profile.get("direction", "")
reverse["reverseDirection"] = reverse["direction"]
reverse_source_provider = first_str(reverse.get("source", {}).get("provider")).upper()
reverse_target_provider = first_str(reverse.get("target", {}).get("provider")).upper()
reverse["replicationDirection"] = reverse["direction"]
reverse["providerPair"] = f"{reverse_source_provider}_TO_{reverse_target_provider}"
reverse["routeContractVersion"] = 2
reverse["reverseOf"] = {
    "planUuid": profile.get("planUuid", ""),
    "runUuid": profile.get("runUuid", ""),
    "operation": operation,
}
request = copy.deepcopy(obj(profile.get("request")))
request["operation"] = operation
request["reverse"] = True
reverse["request"] = request
mapping[disk_key] = reversed_disks
reverse["mapping"] = mapping
original_source_provider = first_str(source.get("provider")).upper()
original_target_provider = first_str(target.get("provider")).upper()
if original_source_provider == "VMWARE" and original_target_provider == "ABLESTACK":
    guest_compatibility_state = "ORIGINAL_VMWARE_COMPATIBILITY_PRESERVED"
elif original_source_provider == "ABLESTACK" and original_target_provider == "ABLESTACK":
    guest_compatibility_state = "NATIVE_COMPATIBILITY_PRESERVED"
else:
    guest_compatibility_state = "VALIDATION_REQUIRED"
reverse["guestCompatibility"] = {
    "state": guest_compatibility_state,
    "sourceLineage": original_source_provider,
    "targetProvider": first_str(reverse.get("target", {}).get("provider")).upper(),
    "bootValidationRequired": True,
}

tmp = out_profile + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(reverse, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, out_profile)
PY
}

ftctl_dr_runtime_reverse_checkpoint() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}" cycle_type="${6-reverse-sync}" phase="${7-reverse}"
  local restore_points_path sequence output rc=0 manifest_path checkpoint_path transfer_progress_path
  local source_at target_at rpo source_provider target_provider replication_direction provider_pair driver now
  local baseline_generation baseline_state="" tracker_state writer_state target_written write_verified guest_compatibility_state
  local operation_intent="REPROTECT" requested_mode="AUTO" effective_mode="" mode_decision_code="" initial_seed_required=false decision

  command -v ftctl_dr_scheduler_run_cycle >/dev/null 2>&1 || return 0
  restore_points_path="$(ftctl_dr_runtime_reverse_restore_points_path "${plan}")"
  sequence="$(ftctl_dr_runtime_failover_next_sequence "${status_path}" "${restore_points_path}")"
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  replication_direction="$(ftctl_dr_runtime_profile_value "${profile_file}" "direction" 2>/dev/null || true)"
  provider_pair="${source_provider}_TO_${target_provider}"
  if [[ "${source_provider}" == "ABLESTACK" && "${target_provider}" == "VMWARE" ]]; then
    [[ "${phase}" == "failback" ]] && operation_intent="FAILBACK_FINAL"
    decision="$(ftctl_dr_kvm_vmware_mode_decision "${plan}" "${operation_intent}" "${requested_mode}")" || return $?
    IFS=$'\t' read -r baseline_state effective_mode mode_decision_code initial_seed_required <<< "${decision}"
    cycle_type="${effective_mode}"
  fi
  now="$(ftctl_now_iso8601)"
  transfer_progress_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" progress)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=${phase}-transfer" \
    "progress=55" \
    "checkpoint_sequence=${sequence}" \
    "reverse_restore_points_path=${restore_points_path}" \
    "operation_intent=${operation_intent}" \
    "requested_mode=${requested_mode}" \
    "effective_mode=${effective_mode}" \
    "mode_decision_code=${mode_decision_code}" \
    "initial_seed_required=${initial_seed_required}" \
    "baseline_file_state=${baseline_state}" \
    "transfer_progress_path=${transfer_progress_path}" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  output="$(FTCTL_DR_PROGRESS_RUN_UUID="${run}" FTCTL_DR_TRANSFER_PROGRESS_PATH="${transfer_progress_path}" \
    ftctl_dr_scheduler_run_cycle "${plan}" "${run}-${phase}" "${profile_file}" "${sequence}" "${cycle_type}")" || rc=$?
  [[ "${rc}" == "0" ]] || return "${rc}"
  manifest_path="$(awk -F '\t' 'NF >= 2 {print $1; exit}' <<< "${output}")"
  checkpoint_path="$(awk -F '\t' 'NF >= 2 {print $2; exit}' <<< "${output}")"
  source_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "sourceCheckpointAt" || true)"
  target_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetDurableAt" || true)"
  rpo="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetReadyRpoSeconds" || true)"
  driver="$(ftctl_dr_scheduler_driver_name "${source_provider}" "${target_provider}")"
  baseline_generation="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "baselineGeneration" "integer" || true)"
  baseline_state="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "baselineState" || true)"
  tracker_state="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "trackerState" || true)"
  writer_state="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "writerState" || true)"
  target_written="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetWritten" "boolean" || true)"
  write_verified="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "writeVerified" "boolean" || true)"
  guest_compatibility_state="$(jq -r '.guestCompatibility.state // ""' "${profile_file}" 2>/dev/null || true)"
  ftctl_dr_scheduler_append_restore_point "${restore_points_path}" "${plan}" "${run}-${phase}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" || return $?
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=${phase}-target-ready" \
    "progress=80" \
    "scheduler_state=REVERSE_CHECKPOINT" \
    "driver=${driver}" \
    "driver_state=CHECKPOINT_READY" \
    "checkpoint_sequence=${sequence}" \
    "manifest_path=${manifest_path}" \
    "checkpoint_path=${checkpoint_path}" \
    "reverse_restore_points_path=${restore_points_path}" \
    "last_source_checkpoint_at=${source_at}" \
    "last_target_durable_at=${target_at}" \
    "target_ready_rpo_seconds=${rpo}" \
    "route_contract_version=2" \
    "replication_direction=${replication_direction}" \
    "reverse_direction=${provider_pair}" \
    "provider_pair=${provider_pair}" \
    "baseline_generation=${baseline_generation}" \
    "baseline_state=${baseline_state}" \
    "tracker_state=${tracker_state}" \
    "writer_state=${writer_state}" \
    "target_written=${target_written}" \
    "write_verified=${write_verified}" \
    "reverse_guest_compatibility_state=${guest_compatibility_state}" \
    "reverse_evidence_run_uuid=${run}" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_failover_final_checkpoint() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}"
  local restore_points_path sequence cycle_type output rc=0 manifest_path checkpoint_path
  local source_at target_at rpo source_provider target_provider driver now final_restore_point_ref

  command -v ftctl_dr_scheduler_run_cycle >/dev/null 2>&1 || return 0
  restore_points_path="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  [[ -n "${restore_points_path}" ]] || return 0
  sequence="$(ftctl_dr_runtime_failover_next_sequence "${status_path}" "${restore_points_path}")"
  cycle_type="failover-final"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=final-delta-capture" \
    "progress=45" \
    "checkpoint_sequence=${sequence}" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  output="$(ftctl_dr_scheduler_run_cycle "${plan}" "${run}-final" "${profile_file}" "${sequence}" "${cycle_type}")" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    case "${rc}" in
      65) return 65 ;;
      66) return 66 ;;
      *) return 67 ;;
    esac
  fi

  manifest_path="$(awk -F '\t' 'NF >= 2 {print $1; exit}' <<< "${output}")"
  checkpoint_path="$(awk -F '\t' 'NF >= 2 {print $2; exit}' <<< "${output}")"
  source_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "sourceCheckpointAt" || true)"
  target_at="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetDurableAt" || true)"
  rpo="$(ftctl_dr_scheduler_checkpoint_value "${checkpoint_path}" "targetReadyRpoSeconds" || true)"
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  driver="$(ftctl_dr_scheduler_driver_name "${source_provider}" "${target_provider}")"
  ftctl_dr_scheduler_append_restore_point "${restore_points_path}" "${plan}" "${run}" "${sequence}" "${cycle_type}" "${driver}" "${manifest_path}" "${checkpoint_path}" || return $?
  final_restore_point_ref="ftctl:${plan}:${run}:${sequence}"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=final-delta-apply" \
    "progress=70" \
    "driver=${driver}" \
    "driver_state=CHECKPOINT_READY" \
    "checkpoint_sequence=${sequence}" \
    "manifest_path=${manifest_path}" \
    "checkpoint_path=${checkpoint_path}" \
    "failover_final_checkpoint_sequence=${sequence}" \
    "failover_final_restore_point_ref=${final_restore_point_ref}" \
    "restore_points_path=${restore_points_path}" \
    "last_source_checkpoint_at=${source_at}" \
    "last_target_durable_at=${target_at}" \
    "target_ready_rpo_seconds=${rpo}" \
    "updated_at=${now}" || true
  ftctl_dr_runtime_publish_latest_completed_checkpoint "${plan}" "${run}" "${sequence}" \
    "${cycle_type}" "${manifest_path}" "${checkpoint_path}" "${run_path}" "${status_path}" || return $?
}

ftctl_dr_runtime_prepare_test_session() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" restore_point="${4-}" run_path="${5-}" status_path="${6-}" artifact_spec_path="${7-}"
  local session_path active_path selection_path restore_points_path profile_path
  local test_session_id test_lease_owner_run test_restore_point_ref test_restore_point_sequence test_manifest_path test_checkpoint_path
  local last_source last_target target_rpo now rc=0

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  session_path="$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")"
  active_path="$(ftctl_dr_runtime_active_test_session_path "${plan}")"
  selection_path="$(mktemp -t ftctl.dr.test.selection.XXXXXX)"
  restore_points_path="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  profile_path="${profile_file}"
  [[ -n "${profile_path}" && -f "${profile_path}" ]] || profile_path="$(ftctl_dr_runtime_profile_path "${plan}")"
  now="$(ftctl_now_iso8601)"

  python3 - "${plan}" "${run}" "${profile_path}" "${restore_point}" "${status_path}" \
    "${restore_points_path}" "${session_path}" "${active_path}" "${selection_path}" "${now}" "${artifact_spec_path}" <<'PY' || rc=$?
import json
import os
import shutil
import sys

plan, run, profile_path, restore_selector, status_path, restore_points_path, session_path, active_path, selection_path, now, artifact_spec_path = sys.argv[1:12]

def read_state(path):
    values = {}
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    key, value = line.split("=", 1)
                    values[key] = value
    return values

def read_json(path):
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    return {}

def read_restore_points(path):
    records = []
    if not path or not os.path.exists(path):
        return records
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict):
                records.append(data)
    return records

def record_ref(record):
    explicit = record.get("checkpointRef") or record.get("sourceSnapshotRef") or record.get("restorePointRef")
    if explicit:
        return str(explicit)
    sequence = record.get("checkpointSequence")
    if sequence is not None:
        return f"ftctl:{plan}:{record.get('runUuid') or run}:{sequence}"
    checkpoint = record.get("checkpoint")
    if checkpoint:
        return str(checkpoint)
    return f"ftctl:{plan}:latest"

def record_sequence(record):
    sequence = record.get("checkpointSequence")
    if sequence is None:
        return None
    try:
        return int(sequence)
    except (TypeError, ValueError):
        return sequence

def matches(record, selector):
    if not selector:
        return False
    candidates = {
        record_ref(record),
        f"ftctl:{plan}:{record.get('checkpointSequence', '')}",
        str(record.get("checkpointSequence", "")),
        str(record.get("checkpoint", "")),
        str(record.get("manifest", "")),
        str(record.get("sourceSnapshotRef", "")),
        str(record.get("restorePointRef", "")),
        str(record.get("checkpointRef", "")),
    }
    return str(selector) in candidates

def controller_checkpoint(profile, request, selector, artifact_spec):
    if str(profile.get("direction") or "").upper() != "KVM_TO_KVM":
        return None
    try:
        contract_version = int(request.get("checkpointContractVersion"))
        sequence = int(request.get("checkpointSequence"))
    except (TypeError, ValueError):
        return None
    checkpoint_ref = str(request.get("checkpointRef") or request.get("restorePointRef") or "")
    if contract_version != 1 or sequence <= 0 or not checkpoint_ref:
        return None
    if str(request.get("checkpointPlanUuid") or "") != plan:
        return None
    if str(request.get("checkpointState") or "").upper() != "READY":
        return None
    if str(selector or "") != checkpoint_ref:
        return None
    if not isinstance(artifact_spec, dict):
        return None
    try:
        artifact_sequence = int(artifact_spec.get("checkpointSequence"))
    except (TypeError, ValueError):
        return None
    if (str(artifact_spec.get("contractVersion") or "") != "3"
            or str(artifact_spec.get("planUuid") or "") != plan
            or str(artifact_spec.get("runUuid") or "") != run
            or str(artifact_spec.get("checkpointRef") or "") != checkpoint_ref
            or artifact_sequence != sequence):
        return None
    return {
        "planUuid": plan,
        "runUuid": run,
        "checkpointSequence": sequence,
        "checkpointRef": checkpoint_ref,
        "cycleType": request.get("checkpointCycleType"),
        "cycleToken": request.get("checkpointCycleToken"),
        "effectiveMode": request.get("checkpointEffectiveMode"),
        "sourceCheckpointAt": request.get("checkpointSourceCreatedAt"),
        "targetDurableAt": request.get("checkpointTargetReadyAt"),
        "targetReadyRpoSeconds": request.get("checkpointTargetReadyRpoSeconds"),
        "state": "READY",
        "controllerProjected": True,
        "recordedAt": now,
    }

state = read_state(status_path)
profile = read_json(profile_path)
request = profile.get("request") if isinstance(profile.get("request"), dict) else {}
selector = restore_selector or request.get("restorePointRef") or request.get("restorePointId") or ""
records = read_restore_points(restore_points_path)
selected = None
if selector:
    selected = next((record for record in records if matches(record, str(selector))), None)
    if selected is None:
        selected = controller_checkpoint(profile, request, str(selector), read_json(artifact_spec_path))
        if selected is None:
            sys.stderr.write(f"ERROR: restore point {selector} was not found\n")
            sys.exit(44)
elif records:
    selected = records[-1]

if selected is None:
    sequence = state.get("checkpoint_sequence")
    checkpoint_path = state.get("checkpoint_path")
    manifest_path = state.get("manifest_path")
    last_target = state.get("last_target_durable_at")
    if not (sequence or checkpoint_path or manifest_path or last_target):
        sys.stderr.write("ERROR: no target-ready restore point is available\n")
        sys.exit(45)
    selected = {
        "planUuid": plan,
        "runUuid": state.get("run"),
        "checkpointSequence": int(sequence) if str(sequence).isdigit() else sequence,
        "manifest": manifest_path,
        "checkpoint": checkpoint_path,
        "sourceCheckpointAt": state.get("last_source_checkpoint_at"),
        "targetDurableAt": last_target,
        "targetReadyRpoSeconds": state.get("target_ready_rpo_seconds"),
        "state": state.get("state"),
        "recordedAt": state.get("updated_at"),
    }

checkpoint = read_json(selected.get("checkpoint"))
source_at = selected.get("sourceCheckpointAt") or checkpoint.get("sourceCheckpointAt") or state.get("last_source_checkpoint_at")
target_at = selected.get("targetDurableAt") or checkpoint.get("targetDurableAt") or state.get("last_target_durable_at")
target_rpo = selected.get("targetReadyRpoSeconds") or checkpoint.get("targetReadyRpoSeconds") or state.get("target_ready_rpo_seconds")
manifest_path = selected.get("manifest") or state.get("manifest_path")
checkpoint_path = selected.get("checkpoint") or state.get("checkpoint_path")
session_id = f"{plan}:{run}"
restore_ref = record_ref(selected)
session = {
    "version": 1,
    "planUuid": plan,
    "runUuid": run,
    "sessionId": session_id,
    "state": "READY",
    "mode": "test-failover",
    "networkMode": request.get("networkMode", "isolated"),
    "startedAt": now,
    "restorePoint": {
        "ref": restore_ref,
        "checkpointSequence": record_sequence(selected),
        "manifest": manifest_path,
        "checkpoint": checkpoint_path,
        "sourceCheckpointAt": source_at,
        "targetDurableAt": target_at,
        "targetReadyRpoSeconds": target_rpo,
    },
    "profile": {
        "direction": profile.get("direction"),
        "source": profile.get("source"),
        "target": profile.get("target"),
        "mapping": profile.get("mapping"),
        "policy": profile.get("policy"),
    },
    "request": request,
    "checkpoint": checkpoint,
}
os.makedirs(os.path.dirname(session_path), exist_ok=True)
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
shutil.copyfile(session_path, active_path)
with open(selection_path, "w", encoding="utf-8") as fh:
    fh.write(f"test_session_id={session_id}\n")
    fh.write(f"test_lease_owner_run={session.get('runUuid', '') or ''}\n")
    fh.write("test_session_state=READY\n")
    fh.write(f"test_restore_point_ref={restore_ref}\n")
    sequence = record_sequence(selected)
    fh.write(f"test_restore_point_sequence={'' if sequence is None else sequence}\n")
    fh.write(f"test_manifest_path={manifest_path or ''}\n")
    fh.write(f"test_checkpoint_path={checkpoint_path or ''}\n")
    fh.write(f"last_source_checkpoint_at={source_at or ''}\n")
    fh.write(f"last_target_durable_at={target_at or ''}\n")
    fh.write(f"target_ready_rpo_seconds={target_rpo or ''}\n")
    fh.write(f"restore_points_path={restore_points_path or ''}\n")
PY
  if [[ "${rc}" != "0" ]]; then
    rm -f "${selection_path}" 2>/dev/null || true
    return "${rc}"
  fi

  test_session_id="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_session_id")"
  test_lease_owner_run="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_lease_owner_run")"
  test_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_restore_point_ref")"
  test_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_restore_point_sequence")"
  test_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_manifest_path")"
  test_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_checkpoint_path")"
  last_source="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_source_checkpoint_at")"
  last_target="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_target_durable_at")"
  target_rpo="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_ready_rpo_seconds")"
  restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "restore_points_path")"
  rm -f "${selection_path}" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "state=TESTING" \
    "step=test-session-ready" \
    "progress=100" \
    "test_session_id=${test_session_id}" \
    "test_lease_owner_run=${test_lease_owner_run}" \
    "test_session_path=${session_path}" \
    "test_session_state=READY" \
    "test_restore_point_ref=${test_restore_point_ref}" \
    "test_restore_point_sequence=${test_restore_point_sequence}" \
    "test_manifest_path=${test_manifest_path}" \
    "test_checkpoint_path=${test_checkpoint_path}" \
    "last_source_checkpoint_at=${last_source}" \
    "last_target_durable_at=${last_target}" \
    "target_ready_rpo_seconds=${target_rpo}" \
    "restore_points_path=${restore_points_path}" \
    "updated_at=${now}"
}

ftctl_dr_runtime_cleanup_test_session() {
  local plan="${1-}" run="${2-}" run_path="${3-}" status_path="${4-}"
  local active_path session_path selection_path now rc=0
  local test_session_id test_lease_owner_run test_restore_point_ref test_restore_point_sequence test_manifest_path test_checkpoint_path
  local last_source last_target target_rpo restore_points_path test_artifacts_state test_artifacts_path test_artifact_count

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  active_path="$(ftctl_dr_runtime_active_test_session_path "${plan}")"
  session_path="$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")"
  selection_path="$(mktemp -t ftctl.dr.test.cleanup.XXXXXX)"
  now="$(ftctl_now_iso8601)"
  python3 - "${plan}" "${run}" "${active_path}" "${session_path}" "${selection_path}" "${now}" <<'PY' || rc=$?
import json
import os
import shutil
import subprocess
import sys

plan, run, active_path, session_path, selection_path, now = sys.argv[1:7]
session = {}
# Failed preparation has a run session before active.json is published.
selected_path = session_path if os.path.exists(session_path) else active_path
if os.path.exists(selected_path):
    with open(selected_path, "r", encoding="utf-8") as fh:
        session = json.load(fh)
    # active.json can precede materialization; follow its owned run record.
    if selected_path == active_path:
        owner = str(session.get("runUuid") or "")
        if owner and owner not in (".", "..") and all(ch.isalnum() or ch in "-_." for ch in owner):
            original_path = os.path.join(os.path.dirname(active_path), owner + ".json")
            if os.path.exists(original_path):
                with open(original_path, "r", encoding="utf-8") as fh:
                    original = json.load(fh)
                if original.get("runUuid") != owner or original.get("planUuid") != plan:
                    raise RuntimeError("DR_TEST_CLEANUP_OWNER_MISMATCH: original session identity differs")
                session = original
    if session.get("planUuid") not in (None, "", plan):
        raise RuntimeError("DR_TEST_CLEANUP_OWNER_MISMATCH: session belongs to another plan")
    if selected_path == session_path and session.get("runUuid") not in (None, "", run):
        # A cleanup run may already contain the original test session after a retry.
        if session.get("cleanupRunUuid") != run:
            raise RuntimeError("DR_TEST_CLEANUP_OWNER_MISMATCH: session belongs to another run")
restore = session.get("restorePoint") if isinstance(session.get("restorePoint"), dict) else {}
artifacts = session.get("testArtifacts") if isinstance(session.get("testArtifacts"), dict) else {}
artifact_path = artifacts.get("path") if isinstance(artifacts, dict) else ""
test_domain = session.get("testDomain") if isinstance(session.get("testDomain"), dict) else {}
domain_name = test_domain.get("name") if isinstance(test_domain, dict) else ""
if domain_name:
    subprocess.run(["virsh", "destroy", str(domain_name)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["virsh", "undefine", str(domain_name), "--nvram"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["virsh", "undefine", str(domain_name)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for record in artifacts.get("records", []) if isinstance(artifacts, dict) else []:
    if isinstance(record, dict) and record.get("type") in ("qcow2-overlay", "qcow2-copy", "qcow2-checkpoint-overlay"):
        path = os.path.abspath(str(record.get("path") or ""))
        storage_root = os.path.abspath(str(record.get("storageRoot") or ""))
        owned = record.get("ownedByFtctl") is True
        if (owned and path and storage_root and os.path.dirname(path) == storage_root
                and os.path.basename(path).startswith("ftctl-dr-test-") and os.path.isfile(path)):
            os.unlink(path)
    if not isinstance(record, dict) or record.get("type") != "rbd-clone":
        continue
    mapped = record.get("mappedDevice")
    clone = str(record.get("clone") or "")
    backing = str(record.get("backing") or "")
    snapshot = str(record.get("snapshot") or "")
    if mapped:
        subprocess.run(["rbd", "unmap", str(mapped)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    manifest_path = session.get("guestPreparation", {}).get("manifest") if isinstance(session.get("guestPreparation"), dict) else None
    if manifest_path and os.path.exists(manifest_path):
        try:
            manifest = json.load(open(manifest_path, "r", encoding="utf-8"))
            runtime = manifest.get("runtime") if isinstance(manifest.get("runtime"), dict) else {}
            rbd_runtime = runtime.get("rbd") if isinstance(runtime.get("rbd"), dict) else {}
            for device in rbd_runtime.get("mapped", []) if isinstance(rbd_runtime.get("mapped"), list) else []:
                if device:
                    subprocess.run(["rbd", "unmap", str(device)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, ValueError, TypeError):
            pass
    if clone.startswith("rbd:"):
        owner = "".join(ch if ch.isalnum() else "-" for ch in str(session.get("runUuid") or "")).strip("-")[:36]
        if not owner or clone != backing + "-ftctl-test-" + owner:
            raise RuntimeError("DR_TEST_CLEANUP_OWNER_MISMATCH: unowned RBD clone")
        removed = subprocess.run(["rbd", "rm", clone[4:]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if removed.returncode != 0:
            probe = subprocess.run(["rbd", "info", clone[4:]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if probe.returncode != 2 or "No such file or directory" not in probe.stderr:
                raise RuntimeError("DR_TEST_ARTIFACT_CLEANUP_FAILED: RBD clone removal failed: " + clone)
    if backing.startswith("rbd:") and snapshot and not record.get("retainedCheckpoint"):
        snap_ref = backing[4:] + "@" + snapshot
        subprocess.run(["rbd", "snap", "unprotect", snap_ref], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["rbd", "snap", "rm", snap_ref], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
session_id = session.get("sessionId") or f"{plan}:{run}"
session["state"] = "CLEANED"
session["cleanupRunUuid"] = run
session["completedAt"] = now
if artifact_path:
    artifact_abs = os.path.abspath(artifact_path)
    session_root = os.path.abspath(os.path.dirname(active_path))
    if artifact_abs.startswith(session_root + os.sep) and os.path.isdir(artifact_abs):
        shutil.rmtree(artifact_abs)
artifacts["state"] = "CLEANED"
artifacts["cleanedAt"] = now
session["testArtifacts"] = artifacts
os.makedirs(os.path.dirname(session_path), exist_ok=True)
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
if os.path.exists(active_path):
    with open(active_path, "r", encoding="utf-8") as fh:
        active = json.load(fh)
    if active.get("sessionId") and active.get("sessionId") == session.get("sessionId"):
        os.unlink(active_path)
with open(selection_path, "w", encoding="utf-8") as fh:
    fh.write(f"test_session_id={session_id}\n")
    fh.write(f"test_lease_owner_run={session.get('runUuid', '') or ''}\n")
    fh.write("test_session_state=CLEANED\n")
    fh.write(f"test_restore_point_ref={restore.get('ref', '')}\n")
    sequence = restore.get("checkpointSequence")
    fh.write(f"test_restore_point_sequence={'' if sequence is None else sequence}\n")
    fh.write(f"test_manifest_path={restore.get('manifest', '') or ''}\n")
    fh.write(f"test_checkpoint_path={restore.get('checkpoint', '') or ''}\n")
    fh.write(f"last_source_checkpoint_at={restore.get('sourceCheckpointAt', '') or ''}\n")
    fh.write(f"last_target_durable_at={restore.get('targetDurableAt', '') or ''}\n")
    fh.write(f"target_ready_rpo_seconds={restore.get('targetReadyRpoSeconds', '') or ''}\n")
    fh.write(f"test_artifacts_state={artifacts.get('state', '') if isinstance(artifacts, dict) else ''}\n")
    fh.write(f"test_artifacts_path={artifact_path or ''}\n")
    fh.write(f"test_artifact_count={artifacts.get('count', '') if isinstance(artifacts, dict) else ''}\n")
PY
  [[ "${rc}" == "0" ]] || {
    rm -f "${selection_path}" 2>/dev/null || true
    return "${rc}"
  }

  test_session_id="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_session_id")"
  test_lease_owner_run="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_lease_owner_run")"
  test_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_restore_point_ref")"
  test_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_restore_point_sequence")"
  test_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_manifest_path")"
  test_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_checkpoint_path")"
  last_source="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_source_checkpoint_at")"
  last_target="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_target_durable_at")"
  target_rpo="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_ready_rpo_seconds")"
  test_artifacts_state="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_artifacts_state")"
  test_artifacts_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_artifacts_path")"
  test_artifact_count="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "test_artifact_count")"
  restore_points_path="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  rm -f "${selection_path}" 2>/dev/null || true
  rm -f "$(ftctl_dr_runtime_artifact_spec_path "${plan}" "${run}")" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "state=READY" \
    "step=test-cleanup-completed" \
    "progress=100" \
    "test_session_id=${test_session_id}" \
    "test_lease_owner_run=${test_lease_owner_run}" \
    "test_session_state=CLEANED" \
    "test_restore_point_ref=${test_restore_point_ref}" \
    "test_restore_point_sequence=${test_restore_point_sequence}" \
    "test_manifest_path=${test_manifest_path}" \
    "test_checkpoint_path=${test_checkpoint_path}" \
    "last_source_checkpoint_at=${last_source}" \
    "last_target_durable_at=${last_target}" \
    "target_ready_rpo_seconds=${target_rpo}" \
    "restore_points_path=${restore_points_path}" \
    "test_artifacts_state=${test_artifacts_state}" \
    "test_artifacts_path=${test_artifacts_path}" \
    "test_artifact_count=${test_artifact_count}" \
    "test_cleanup_state=CLEANED" \
    "cleanup_required=false" \
    "updated_at=${now}"
}

# A Cloud cleanup profile may intentionally omit source credentials. Only the
# durable Cloud recovery worker can restore that profile and the operator intent.
ftctl_dr_runtime_cloud_managed_test_restore() {
  local profile
  profile="$(ftctl_dr_runtime_profile_path "${1-}")"
  [[ -s "${profile}" ]] && jq -e '.request.sourceSchedulerRestoreManagedByCloud == true' "${profile}" >/dev/null 2>&1
}

ftctl_dr_runtime_finalize_failed_test() {
  local plan="${1-}" run="${2-}" run_path="${3-}" status_path="${4-}"
  local failure_rc="${5-1}" error_code="${6-DR_TEST_FAILOVER_FAILED}" failed_step="${7-test-failed}"
  local error_message="${8-}"
  local cleanup_rc=0 resume_rc=0 lease_rc=0 sequence lease_owner_run cleanup_state cleanup_required=true
  local transition_scope

  ftctl_dr_runtime_cleanup_test_session "${plan}" "${run}" "${run_path}" "${status_path}" || cleanup_rc=$?
  # Keep failed resources reachable by the operator's later cleanup command.
  if [[ "${cleanup_rc}" != "0" && ! -e "$(ftctl_dr_runtime_active_test_session_path "${plan}")"       && -f "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" ]]; then
    cp -f "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")"       "$(ftctl_dr_runtime_active_test_session_path "${plan}")"
  fi
  sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_sequence")"
  lease_owner_run="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_lease_owner_run")"
  [[ -n "${lease_owner_run}" ]] || lease_owner_run="${run}"
  if [[ -n "${sequence}" ]]; then
    ftctl_dr_scheduler_checkpoint_lease_release_owned "${plan}" "${sequence}" "${lease_owner_run}" || lease_rc=$?
  fi
  if [[ "${lease_rc}" == "0" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "checkpoint_lease_state=RELEASED" \
      "checkpoint_lease_path=" || true
  fi
  transition_scope="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "scheduler_transition_scope")"
  if [[ "${transition_scope}" != "REMOTE_SOURCE" ]] && ! ftctl_dr_runtime_cloud_managed_test_restore "${plan}" && command -v ftctl_dr_scheduler_resume_after_transition >/dev/null 2>&1; then
    ftctl_dr_scheduler_resume_after_transition "${plan}" "${run}" "test-failover-rollback" \
      "${run_path}" "${status_path}" || resume_rc=$?
  fi
  if [[ "${transition_scope}" != "REMOTE_SOURCE" ]] && command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1; then
    ftctl_dr_scheduler_transition_end "${plan}"
  fi

  cleanup_state="FAILED"
  if [[ "${cleanup_rc}" == "0" && "${lease_rc}" == "0" ]]; then
    cleanup_state="CLEANED"
    cleanup_required=false
  fi
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=ERROR" \
    "step=${failed_step}" \
    "progress=100" \
    "accepted=false" \
    "worker_state=FAILED" \
    "worker_pid=$$" \
    "worker_exit_code=${failure_rc}" \
    "test_cleanup_state=${cleanup_state}" \
    "cleanup_required=${cleanup_required}" \
    "scheduler_recovery_state=$([[ "${resume_rc}" == "0" ]] && printf RUNNING || printf RECOVERY_FAILED)" \
    "error_code=${error_code}" \
    "error_message=${error_message}" \
    "updated_at=$(ftctl_now_iso8601)" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.test.failure-finalized" \
    "$([[ "${cleanup_required}" == "false" && "${resume_rc}" == "0" ]] && printf ok || printf fail)" "" "${error_code}" \
    "plan=${plan} run=${run} failure_rc=${failure_rc} cleanup_rc=${cleanup_rc} lease_rc=${lease_rc} resume_rc=${resume_rc}"
  return 0
}

ftctl_dr_runtime_materialize_test_artifacts() {
  local plan="${1-}" run="${2-}" session_path="${3-}" run_path="${4-}" artifact_spec_path="${5-}"
  local artifacts_dir artifacts_state_path rc=0
  local test_artifacts_state test_artifacts_path test_artifact_count artifact_error_code artifact_error_message
  local test_checkpoint_seal_state test_checkpoint_integrity_state test_checkpoint_sequence test_checkpoint_path

  artifacts_dir="$(ftctl_dr_runtime_test_artifacts_dir "${plan}" "${run}")"
  artifacts_state_path="$(mktemp -t ftctl.dr.test.artifacts.XXXXXX)"
  python3 - "${session_path}" "${artifacts_dir}" "${artifacts_state_path}" "$(ftctl_now_iso8601)" "${artifact_spec_path}" \
    "${FTCTL_LIB_BASE}/ftctl/qcow2_checkpoint.py" <<'PY' || rc=$?
import json
import os
import shutil
import subprocess
import sys

session_path, artifacts_dir, state_path, now, artifact_spec_path, checkpoint_tool = sys.argv[1:7]
with open(session_path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
try:
    with open(artifact_spec_path, "r", encoding="utf-8") as fh:
        artifact_spec = json.load(fh)
except (OSError, ValueError) as exc:
    sys.stderr.write(f"ERROR: unable to read artifact locator contract: {exc}\n")
    sys.exit(53)
if str(artifact_spec.get("contractVersion") or "") != "3":
    sys.stderr.write("ERROR: artifact contractVersion 3 is required\n")
    sys.exit(53)

profile = session.get("profile") if isinstance(session.get("profile"), dict) else {}
target = profile.get("target") if isinstance(profile.get("target"), dict) else {}
disks = artifact_spec.get("disks") if isinstance(artifact_spec.get("disks"), list) else []
target_provider = str(target.get("provider") or "").upper()
records = []
state = "NO_DISKS"
os.makedirs(artifacts_dir, exist_ok=True)

def rbd_spec(value):
    text = str(value or "")
    if text.startswith("rbd:"):
        return text[4:]
    if text.startswith("/dev/rbd/"):
        return text[len("/dev/rbd/"):]
    return ""

def safe_key(value):
    return "".join(ch if ch.isalnum() else "-" for ch in str(value)).strip("-")[:36]

def cleanup_records():
    for record in reversed(records):
        if not isinstance(record, dict):
            continue
        if record.get("type") == "rbd-clone":
            clone = str(record.get("clone") or "")
            backing = str(record.get("backing") or "")
            snapshot = str(record.get("snapshot") or "")
            if clone.startswith("rbd:"):
                subprocess.run(["rbd", "rm", clone[4:]], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if backing.startswith("rbd:") and snapshot and not record.get("retainedCheckpoint"):
                snap_ref = backing[4:] + "@" + snapshot
                subprocess.run(["rbd", "snap", "unprotect", snap_ref], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["rbd", "snap", "rm", snap_ref], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        path = str(record.get("path") or "")
        if record.get("type") in ("qcow2-overlay", "qcow2-copy", "qcow2-checkpoint-overlay") and path and os.path.isfile(path):
            os.unlink(path)

def fail(code, message):
    cleanup_records()
    structured_code = ""
    if str(message).startswith("DR_") and ":" in str(message):
        structured_code, message = str(message).split(":", 1)
        message = message.strip()
    message = " ".join(str(message or "").split())
    if len(message) > 4096:
        message = message[:4072].rstrip() + " ... [detail truncated]"
    session["testArtifacts"] = {
        "state": "FAILED",
        "path": artifacts_dir,
        "count": 0,
        "records": records,
        "errorCode": structured_code or ("DR_TEST_ARTIFACT_LOCATOR_INVALID" if code == 53 else "DR_TEST_ARTIFACT_PROVIDER_UNSUPPORTED" if code == 54 else "DR_TEST_MATERIALIZATION_FAILED"),
        "errorMessage": message,
        "updatedAt": now,
    }
    with open(session_path, "w", encoding="utf-8") as fh:
        json.dump(session, fh, sort_keys=True, separators=(",", ":"))
        fh.write("\n")
    with open(state_path, "w", encoding="utf-8") as fh:
        fh.write("test_artifacts_state=FAILED\n")
        fh.write("test_artifacts_path=\n")
        fh.write("test_artifact_count=0\n")
        fh.write(f"artifact_error_code={session['testArtifacts']['errorCode']}\n")
        fh.write(f"artifact_error_message={message.replace(chr(10), ' ')}\n")
    sys.stderr.write(f"ERROR: {message}\n")
    sys.exit(code)

if target_provider == "VMWARE":
    state = "METADATA_ONLY"
else:
    qemu_img = shutil.which("qemu-img")
    all_file_disks = bool(disks) and all(
        isinstance(disk, dict) and str(disk.get("provider") or "").upper() == "FILE"
        for disk in disks
    )
    if all_file_disks:
        request = session.get("request") if isinstance(session.get("request"), dict) else {}
        if artifact_spec.get("checkpointImmutableRequired") is not True:
            fail(53, "DR_TEST_CHECKPOINT_CONTRACT_INVALID: immutable FILE checkpoint contract is required")
        if str(request.get("checkpointWriterState") or "").upper() != "DRAINED":
            fail(46, "DR_TEST_CHECKPOINT_WRITER_NOT_DRAINED: target checkpoint writer is not drained")
        if not qemu_img:
            fail(46, "qemu-img is required to create ABLESTACK test copies")
        restore_point = session.get("restorePoint") if isinstance(session.get("restorePoint"), dict) else {}
        sequence = restore_point.get("checkpointSequence")
        artifact_sequence = artifact_spec.get("checkpointSequence")
        checkpoint_ref = str(restore_point.get("ref") or "")
        try:
            sequence = int(sequence)
            artifact_sequence = int(artifact_sequence)
        except (TypeError, ValueError):
            fail(53, "file-backed test artifact requires a positive checkpoint sequence")
        if sequence <= 0 or sequence != artifact_sequence:
            fail(53, f"checkpoint sequence mismatch: session={sequence} artifact={artifact_sequence}")
        if not checkpoint_ref or checkpoint_ref != str(artifact_spec.get("checkpointRef") or ""):
            fail(53, "checkpoint reference mismatch between session and artifact contract")

        set_disks = []
        for index, disk in enumerate(disks):
            locator = str(disk.get("canonicalLocator") or "")
            device = str(disk.get("device") or f"disk{index}").replace("/", "_").replace(" ", "_")
            if not locator.startswith("file:/"):
                fail(53, f"invalid file locator {locator}; expected file:/absolute/path")
            target_path = locator[5:]
            if not os.path.isabs(target_path) or not os.path.isfile(target_path):
                fail(53, f"file-backed target does not exist: {target_path}")
            storage_root = str(target.get("storagePath") or "").strip()
            if not storage_root:
                storage_root = os.path.dirname(os.path.abspath(target_path))
            storage_root = os.path.abspath(storage_root)
            target_abs = os.path.abspath(target_path)
            if not os.path.isdir(storage_root):
                fail(53, f"file-backed target storage root does not exist: {storage_root}")
            try:
                target_in_storage = os.path.commonpath([target_abs, storage_root]) == storage_root
            except ValueError:
                target_in_storage = False
            if not target_in_storage:
                fail(53, f"file-backed target escapes storage root: {target_path}")
            run_key = safe_key(session.get("runUuid") or now) or "run"
            device_key = safe_key(device) or f"disk{index}"
            set_disks.append({
                "device": disk.get("device") or f"disk{index}",
                "source": target_path,
                "storageRoot": storage_root,
                "output": os.path.join(storage_root, f"ftctl-dr-test-{run_key}-{device_key}.qcow2"),
                "sizeBytes": disk.get("sizeBytes") or disk.get("capacityBytes") or 0,
            })
        set_request = {
            "existingOnly": request.get("checkpointExistingSealRequired") is True,
            "plan": str(session.get("planUuid") or ""),
            "sequence": sequence,
            "checkpointRef": checkpoint_ref,
            "evidencePath": os.path.join(artifacts_dir, "checkpoint-inspection-evidence.json"),
            "disks": set_disks,
        }
        try:
            result = subprocess.run(
                [sys.executable, checkpoint_tool, "--set-request", "-"],
                input=json.dumps(set_request), check=False, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True,
            )
            if result.returncode != 0:
                error = json.loads((result.stderr or "").strip().splitlines()[-1])
                fail(46, f"{error.get('errorCode')}: {error.get('errorMessage')}")
            set_result = json.loads(result.stdout)
            records.extend(set_result.get("records") or [])
        except (OSError, ValueError, IndexError) as exc:
            fail(46, f"immutable checkpoint set materialization failed: {exc}")
        disks = []
    for index, disk in enumerate(disks):
        if not isinstance(disk, dict):
            fail(53, f"artifact disk {index} is not an object")
        provider = str(disk.get("provider") or "").upper()
        locator = str(disk.get("canonicalLocator") or "")
        device = str(disk.get("device") or f"disk{index}").replace("/", "_").replace(" ", "_")
        target_format = str(disk.get("targetFormat") or disk.get("format") or "qcow2")
        if provider == "RBD":
            source_rbd = rbd_spec(locator)
            if shutil.which("rbd") is None:
                fail(46, "rbd is required to create ABLESTACK test clones")
            if "/" not in source_rbd:
                fail(53, f"invalid RBD locator {locator}; expected rbd:pool/image")
            pool, image = source_rbd.split("/", 1)
            suffix = safe_key(session.get("runUuid") or now)
            import hashlib
            request = session.get("request") or {}
            checkpoint_ref = str((session.get("restorePoint") or {}).get("ref") or "")
            seal_key = hashlib.sha256((str(session.get("planUuid")) + ":" + checkpoint_ref + ":" + str(disk.get("device"))).encode()).hexdigest()[:32]
            snapshot = f"ftctl-dr-seal-{seal_key}"
            existing_only = request.get("checkpointExistingSealRequired") is True
            clone_image = f"{image}-ftctl-test-{suffix}"
            clone_spec = f"{pool}/{clone_image}"
            snap_spec = f"{source_rbd}@{snapshot}"
            try:
                sys.path.insert(0, os.path.dirname(checkpoint_tool))
                from dr_checkpoint_store import storage_lock
                with storage_lock({"planUuid": str(session.get("planUuid")), "disks": [{"provider": "RBD", "canonicalLocator": locator}]}):
                    subprocess.run(["rbd", "info", source_rbd], check=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                    proof_result = subprocess.run(["rbd", "image-meta", "get", source_rbd, snapshot], check=False,
                                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    reused_seal = proof_result.returncode == 0
                    if existing_only or reused_seal:
                        proof = proof_result.stdout.strip()
                        if proof != checkpoint_ref:
                            fail(53, "DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH: RBD checkpoint seal does not match request")
                        subprocess.run(["rbd", "info", snap_spec], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    else:
                        subprocess.run(["rbd", "snap", "create", snap_spec], check=True)
                    records.append({
                        "device": disk.get("device") or f"disk{index}",
                        "state": "CREATING",
                        "type": "rbd-clone",
                        "backing": f"rbd:{source_rbd}",
                        "snapshot": snapshot,
                        "retainedCheckpoint": existing_only or reused_seal,
                        "checkpointRef": checkpoint_ref,
                        "clone": f"rbd:{clone_spec}",
                        "path": f"rbd:{clone_spec}",
                        "sizeBytes": disk.get("sizeBytes") or disk.get("capacityBytes") or 0,
                    })
                    if not existing_only and not reused_seal:
                        subprocess.run(["rbd", "snap", "protect", snap_spec], check=True)
                    subprocess.run(["rbd", "clone", snap_spec, clone_spec], check=True)
                    records[-1]["state"] = "CREATED"
            except subprocess.CalledProcessError as exc:
                stderr = (exc.stderr or "").strip() if isinstance(exc.stderr, str) else ""
                fail(46, f"{'DR_TEST_SEALED_CHECKPOINT_MISSING' if existing_only else 'DR_TEST_MATERIALIZATION_FAILED'}: RBD test clone failed for {source_rbd}: {stderr or exc}")
            continue
        if provider == "FILE":
            request = session.get("request") if isinstance(session.get("request"), dict) else {}
            if artifact_spec.get("checkpointImmutableRequired") is not True:
                fail(53, "DR_TEST_CHECKPOINT_CONTRACT_INVALID: immutable FILE checkpoint contract is required")
            if str(request.get("checkpointWriterState") or "").upper() != "DRAINED":
                fail(46, "DR_TEST_CHECKPOINT_WRITER_NOT_DRAINED: target checkpoint writer is not drained")
            if not locator.startswith("file:/"):
                fail(53, f"invalid file locator {locator}; expected file:/absolute/path")
            target_path = locator[5:]
            if not os.path.isabs(target_path) or not os.path.isfile(target_path):
                fail(53, f"file-backed target does not exist: {target_path}")
            if not qemu_img:
                fail(46, "qemu-img is required to create ABLESTACK test copies")
            storage_root = str(target.get("storagePath") or "").strip()
            if not storage_root:
                storage_root = os.path.dirname(os.path.abspath(target_path))
            storage_root = os.path.abspath(storage_root)
            target_abs = os.path.abspath(target_path)
            if not os.path.isdir(storage_root):
                fail(53, f"file-backed target storage root does not exist: {storage_root}")
            try:
                target_in_storage = os.path.commonpath([target_abs, storage_root]) == storage_root
            except ValueError:
                target_in_storage = False
            if not target_in_storage:
                fail(53, f"file-backed target escapes storage root: {target_path}")
            run_key = safe_key(session.get("runUuid") or now) or "run"
            device_key = safe_key(device) or f"disk{index}"
            copy_name = f"ftctl-dr-test-{run_key}-{device_key}.qcow2"
            copy_path = os.path.join(storage_root, copy_name)
            restore_point = session.get("restorePoint") if isinstance(session.get("restorePoint"), dict) else {}
            sequence = restore_point.get("checkpointSequence")
            checkpoint_ref = str(restore_point.get("ref") or "")
            artifact_sequence = artifact_spec.get("checkpointSequence")
            try:
                sequence = int(sequence)
                artifact_sequence = int(artifact_sequence)
            except (TypeError, ValueError):
                fail(53, "file-backed test artifact requires a positive checkpoint sequence")
            if sequence <= 0 or sequence != artifact_sequence:
                fail(53, f"checkpoint sequence mismatch: session={sequence} artifact={artifact_sequence}")
            if not checkpoint_ref or checkpoint_ref != str(artifact_spec.get("checkpointRef") or ""):
                fail(53, "checkpoint reference mismatch between session and artifact contract")
            command = [
                sys.executable, checkpoint_tool,
                "--plan", str(session.get("planUuid") or ""),
                "--sequence", str(sequence),
                "--checkpoint-ref", checkpoint_ref,
                "--device", str(disk.get("device") or f"disk{index}"),
                "--source", target_path,
                "--storage-root", storage_root,
                "--output", copy_path,
            ]
            if request.get("checkpointExistingSealRequired") is True:
                command.append("--existing-only")
            try:
                result = subprocess.run(command, check=False, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
                if result.returncode != 0:
                    error = json.loads((result.stderr or "").strip().splitlines()[-1])
                    fail(46, f"{error.get('errorCode')}: {error.get('errorMessage')}")
                record = json.loads(result.stdout)
            except (OSError, ValueError, IndexError) as exc:
                fail(46, f"immutable checkpoint materialization failed for {target_path}: {exc}")
            record.update({
                "device": disk.get("device") or f"disk{index}",
                "source": target_path,
                "sizeBytes": disk.get("sizeBytes") or disk.get("capacityBytes") or 0,
                "command": command,
            })
            records.append(record)
            continue
        fail(54, f"unsupported test artifact provider {provider} for disk {index}")
    state = "CREATED" if any(record.get("state") == "CREATED" for record in records) else "NO_MATERIALIZED_DISKS"

# Publish seals only after the complete disk set has materialized successfully.
for record in records:
    if record.get("type") == "rbd-clone" and not record.get("retainedCheckpoint"):
        try:
            subprocess.run(["rbd", "image-meta", "set", record["backing"][4:], record["snapshot"], record["checkpointRef"]], check=True)
        except subprocess.CalledProcessError as exc:
            fail(46, "DR_TEST_CHECKPOINT_SEAL_FAILED: RBD checkpoint publication failed")
for record in records:
    if record.get("type") == "rbd-clone":
        record["retainedCheckpoint"] = True

session["testArtifacts"] = {
    "state": state,
    "path": artifacts_dir,
    "count": len([record for record in records if record.get("state") == "CREATED"]),
    "records": records,
    "updatedAt": now,
}
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
with open(state_path, "w", encoding="utf-8") as fh:
    fh.write(f"test_artifacts_state={state}\n")
    fh.write(f"test_artifacts_path={artifacts_dir}\n")
    fh.write(f"test_artifact_count={session['testArtifacts']['count']}\n")
    sealed = [record for record in records if record.get("checkpointSealState") == "SEALED"]
    passed = [record for record in records if record.get("checkpointIntegrityState") == "PASSED"]
    if sealed:
        fh.write("test_checkpoint_seal_state=SEALED\n")
        fh.write(f"test_checkpoint_sequence={sealed[0].get('checkpointSequence', '')}\n")
        fh.write(f"test_checkpoint_path={sealed[0].get('checkpointPath', '')}\n")
    if passed and len(passed) == len(sealed):
        fh.write("test_checkpoint_integrity_state=PASSED\n")
PY
  [[ "${rc}" == "0" ]] || {
    artifact_error_code="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "artifact_error_code")"
    artifact_error_message="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "artifact_error_message")"
    ftctl_dr_runtime_path_set "${run_path}" \
      "test_artifacts_state=FAILED" \
      "error_code=${artifact_error_code}" \
      "error_message=${artifact_error_message}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    rm -f "${artifacts_state_path}" 2>/dev/null || true
    return "${rc}"
  }

  test_artifacts_state="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_artifacts_state")"
  test_artifacts_path="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_artifacts_path")"
  test_artifact_count="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_artifact_count")"
  test_checkpoint_seal_state="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_checkpoint_seal_state")"
  test_checkpoint_integrity_state="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_checkpoint_integrity_state")"
  test_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_checkpoint_sequence")"
  test_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${artifacts_state_path}" "test_checkpoint_path")"
  rm -f "${artifacts_state_path}" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "test_artifacts_state=${test_artifacts_state}" \
    "test_artifacts_path=${test_artifacts_path}" \
    "test_artifact_count=${test_artifact_count}" \
    "test_checkpoint_seal_state=${test_checkpoint_seal_state}" \
    "test_checkpoint_integrity_state=${test_checkpoint_integrity_state}" \
    "test_checkpoint_sequence=${test_checkpoint_sequence}" \
    "test_checkpoint_path=${test_checkpoint_path}"
}

# Resolve with the same durable local artifact selector used by guest preparation.
# Never derive cutover provenance from a copied Run's checkpoint_sequence.
ftctl_dr_runtime_select_cutover_checkpoint() {
  local plan="${1-}" run="${2-}" profile="${3-}" selector="${4-}" status="${5-}" output="${6-}"
  local records libdir
  records="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status}")"
  libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 - "${libdir}" "${plan}" "${run}" "${profile}" "${selector}" "${records}" "${status}" "${output}" <<'PY'
import hashlib
import json
import os
import sys
sys.path.insert(0, sys.argv[1])
from guestprep_manifest import select_checkpoint, ManifestError
_, plan, run, profile_path, selector, records, status, output = sys.argv[1:]
with open(profile_path, encoding="utf-8") as handle:
    profile = json.load(handle)
request = profile.get("request") or {}
try:
    selected = select_checkpoint(plan, run, records,
        selector or request.get("restorePointRef") or request.get("restorePointId") or "", status)
except ManifestError as exc:
    print(exc.code + ": " + exc.message, file=sys.stderr)
    raise SystemExit(exc.exit_code)
sequence = selected.get("sequence")
if not isinstance(sequence, int) or sequence <= 0:
    raise SystemExit(44)
proof = {"checkpointSequence": sequence, "checkpointRef": selected["ref"],
         "planUuid": plan, "cutoverRunUuid": run}
for key in ("path", "manifest"):
    path = selected.get(key)
    if path and os.path.isfile(path):
        with open(path, "rb") as handle:
            proof[key + "Sha256"] = hashlib.sha256(handle.read()).hexdigest()
with open(output + ".tmp", "w", encoding="utf-8") as handle:
    json.dump(proof, handle, sort_keys=True)
    handle.flush()
    os.fsync(handle.fileno())
os.replace(output + ".tmp", output)
print(str(sequence) + "\t" + selected["ref"])
PY
}

ftctl_dr_runtime_finalize_failover() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" restore_point="${4-}" mode="${5-}" run_path="${6-}" status_path="${7-}"
  local session_path active_path selection_path restore_points_path profile_path now rc=0
  local failover_session_id failover_restore_point_ref failover_restore_point_sequence
  local failover_manifest_path failover_checkpoint_path failover_requested_at restore_point_locked_at
  local target_promote_started_at target_power_on_at failover_completed_at rto_actual_seconds
  local last_source last_target target_rpo target_power_state target_promotion_state failover_runtime_state active_side
  local manifest_sha256 target_vm_id target_external_ref

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  session_path="$(ftctl_dr_runtime_failover_session_path "${plan}" "${run}")"
  active_path="$(ftctl_dr_runtime_active_failover_session_path "${plan}")"
  selection_path="$(mktemp -t ftctl.dr.failover.selection.XXXXXX)"
  restore_points_path="$(ftctl_dr_runtime_default_restore_points_path "${plan}" "${status_path}")"
  profile_path="${profile_file}"
  [[ -n "${profile_path}" && -f "${profile_path}" ]] || profile_path="$(ftctl_dr_runtime_profile_path "${plan}")"
  now="$(ftctl_now_iso8601)"

  python3 - "${plan}" "${run}" "${profile_path}" "${restore_point}" "${mode}" "${status_path}" \
    "${restore_points_path}" "${session_path}" "${active_path}" "${selection_path}" "${now}" <<'PY' || rc=$?
import hashlib
import json
import os
import shutil
import sys
from datetime import datetime, timezone

plan, run, profile_path, restore_selector, mode, status_path, restore_points_path, session_path, active_path, selection_path, now = sys.argv[1:12]

def read_state(path):
    values = {}
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    key, value = line.split("=", 1)
                    values[key] = value
    return values

def read_json(path):
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    return {}

def read_restore_points(path):
    records = []
    if not path or not os.path.exists(path):
        return records
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict):
                records.append(data)
    return records

def record_ref(record):
    explicit = record.get("checkpointRef") or record.get("sourceSnapshotRef") or record.get("restorePointRef")
    if explicit:
        return str(explicit)
    sequence = record.get("checkpointSequence")
    if sequence is not None:
        return f"ftctl:{plan}:{record.get('runUuid') or run}:{sequence}"
    checkpoint = record.get("checkpoint")
    if checkpoint:
        return str(checkpoint)
    return f"ftctl:{plan}:latest"

def record_sequence(record):
    sequence = record.get("checkpointSequence")
    if sequence is None:
        return None
    try:
        return int(sequence)
    except (TypeError, ValueError):
        return sequence

def matches(record, selector):
    if not selector:
        return False
    candidates = {
        record_ref(record),
        f"ftctl:{plan}:{record.get('checkpointSequence', '')}",
        str(record.get("checkpointSequence", "")),
        str(record.get("checkpoint", "")),
        str(record.get("manifest", "")),
        str(record.get("sourceSnapshotRef", "")),
        str(record.get("restorePointRef", "")),
        str(record.get("checkpointRef", "")),
    }
    return str(selector) in candidates

def controller_checkpoint(profile, request, selector):
    if str(profile.get("direction") or "").upper() != "KVM_TO_KVM":
        return None
    try:
        contract_version = int(request.get("checkpointContractVersion"))
        sequence = int(request.get("checkpointSequence"))
    except (TypeError, ValueError):
        return None
    checkpoint_ref = str(request.get("checkpointRef") or request.get("restorePointRef") or "")
    if (contract_version != 1 or sequence <= 0 or not checkpoint_ref
            or str(request.get("checkpointPlanUuid") or "") != plan
            or str(request.get("checkpointState") or "").upper() != "READY"
            or str(selector or "") != checkpoint_ref):
        return None
    return {
        "planUuid": plan,
        "runUuid": run,
        "checkpointSequence": sequence,
        "checkpointRef": checkpoint_ref,
        "cycleType": request.get("checkpointCycleType"),
        "cycleToken": request.get("checkpointCycleToken"),
        "effectiveMode": request.get("checkpointEffectiveMode"),
        "sourceCheckpointAt": request.get("checkpointSourceCreatedAt"),
        "targetDurableAt": request.get("checkpointTargetReadyAt"),
        "targetReadyRpoSeconds": request.get("checkpointTargetReadyRpoSeconds"),
        "state": "READY",
        "controllerProjected": True,
        "recordedAt": now,
    }

def seconds_between(start, end):
    def parse(value):
        if not value:
            return None
        text = value.replace("Z", "+00:00")
        try:
            return datetime.fromisoformat(text)
        except ValueError:
            return None
    s = parse(start)
    e = parse(end)
    if s is None or e is None:
        return 0
    if s.tzinfo is None:
        s = s.replace(tzinfo=timezone.utc)
    if e.tzinfo is None:
        e = e.replace(tzinfo=timezone.utc)
    return max(0, int((e - s).total_seconds()))

state = read_state(status_path)
profile = read_json(profile_path)
request = profile.get("request") if isinstance(profile.get("request"), dict) else {}
selector = restore_selector or request.get("restorePointRef") or request.get("restorePointId") or ""
records = read_restore_points(restore_points_path)
selected = None
if selector:
    selected = next((record for record in records if matches(record, str(selector))), None)
    if selected is None:
        selected = controller_checkpoint(profile, request, str(selector))
        if selected is None:
            sys.stderr.write(f"ERROR: restore point {selector} was not found\n")
            sys.exit(44)
elif records:
    selected = records[-1]

if selected is None:
    sequence = state.get("checkpoint_sequence")
    checkpoint_path = state.get("checkpoint_path")
    manifest_path = state.get("manifest_path")
    last_target = state.get("last_target_durable_at")
    if not (sequence or checkpoint_path or manifest_path or last_target):
        sys.stderr.write("ERROR: no target-ready restore point is available\n")
        sys.exit(45)
    selected = {
        "planUuid": plan,
        "runUuid": state.get("run"),
        "checkpointSequence": int(sequence) if str(sequence).isdigit() else sequence,
        "manifest": manifest_path,
        "checkpoint": checkpoint_path,
        "sourceCheckpointAt": state.get("last_source_checkpoint_at"),
        "targetDurableAt": last_target,
        "targetReadyRpoSeconds": state.get("target_ready_rpo_seconds"),
        "state": state.get("state"),
        "recordedAt": state.get("updated_at"),
    }

checkpoint = read_json(selected.get("checkpoint"))
source_at = selected.get("sourceCheckpointAt") or checkpoint.get("sourceCheckpointAt") or state.get("last_source_checkpoint_at")
target_at = selected.get("targetDurableAt") or checkpoint.get("targetDurableAt") or state.get("last_target_durable_at")
target_rpo = selected.get("targetReadyRpoSeconds") or checkpoint.get("targetReadyRpoSeconds") or state.get("target_ready_rpo_seconds")
manifest_path = selected.get("manifest") or state.get("manifest_path")
checkpoint_path = selected.get("checkpoint") or state.get("checkpoint_path")
requested_at = state.get("failover_requested_at") or now
session_id = f"{plan}:{run}"
restore_ref = record_ref(selected)
direction = str(profile.get("direction") or "").upper()
remote_source_transition = (
    direction == "KVM_TO_KVM"
    and str(request.get("schedulerTransitionScope") or "").upper() == "REMOTE_SOURCE"
)
target_disaster_transition = (
    direction == "KVM_TO_KVM"
    and str(request.get("schedulerTransitionScope") or "").upper() == "TARGET_DISASTER"
    and str(request.get("mode") or "").lower() == "disaster"
    and request.get("finalSync") is False
)
cutover_ready = direction == "VMWARE_TO_KVM" or remote_source_transition or target_disaster_transition
runtime_state = "CUTOVER_READY" if cutover_ready else "FAILED_OVER"
active_side = "SOURCE" if cutover_ready else "TARGET"
target_power_state = "POWERED_OFF" if cutover_ready else "POWER_ON_DELEGATED"
target_promotion_state = "CUTOVER_READY" if cutover_ready else "PROMOTED"
target = profile.get("target") if isinstance(profile.get("target"), dict) else {}
target_vm_id = target.get("vmId")
target_external_ref = target.get("externalRef") or target.get("uuid") or ""
manifest_sha256 = str(state.get("manifest_sha256") or "")
if remote_source_transition or target_disaster_transition:
    manifest_payload = {
        "contractVersion": 1,
        "planUuid": plan,
        "direction": direction,
        "checkpointRef": restore_ref,
        "checkpointSequence": record_sequence(selected),
        "targetVmId": target_vm_id,
        "targetExternalRef": target_external_ref,
        "mapping": profile.get("mapping") if isinstance(profile.get("mapping"), dict) else {},
    }
    encoded = json.dumps(manifest_payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    manifest_sha256 = hashlib.sha256(encoded).hexdigest()
session = {
    "version": 1,
    "planUuid": plan,
    "runUuid": run,
    "sessionId": session_id,
    "state": runtime_state,
    "mode": mode or "planned",
    "activeSide": active_side,
    "startedAt": requested_at,
    "restorePointLockedAt": now,
    "targetPromoteStartedAt": now,
    "targetPowerOnAt": None if cutover_ready else now,
    "completedAt": None if cutover_ready else now,
    "rtoActualSeconds": seconds_between(requested_at, now),
    "restorePoint": {
        "ref": restore_ref,
        "checkpointSequence": record_sequence(selected),
        "manifest": manifest_path,
        "checkpoint": checkpoint_path,
        "sourceCheckpointAt": source_at,
        "targetDurableAt": target_at,
        "targetReadyRpoSeconds": target_rpo,
    },
    "targetPromotion": {
        "state": target_promotion_state,
        "powerState": target_power_state,
        "lifecycleOwner": "Cloud",
    },
    "manifestSha256": manifest_sha256 or None,
    "targetVmId": target_vm_id,
    "targetExternalRef": target_external_ref or None,
    "profile": {
        "direction": profile.get("direction"),
        "source": profile.get("source"),
        "target": profile.get("target"),
        "mapping": profile.get("mapping"),
    },
    "checkpoint": checkpoint,
}
os.makedirs(os.path.dirname(session_path), exist_ok=True)
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
shutil.copyfile(session_path, active_path)
with open(selection_path, "w", encoding="utf-8") as fh:
    fh.write(f"failover_session_id={session_id}\n")
    fh.write(f"failover_mode={mode or 'planned'}\n")
    fh.write(f"failover_restore_point_ref={restore_ref}\n")
    sequence = record_sequence(selected)
    fh.write(f"failover_restore_point_sequence={'' if sequence is None else sequence}\n")
    fh.write(f"failover_manifest_path={manifest_path or ''}\n")
    fh.write(f"failover_checkpoint_path={checkpoint_path or ''}\n")
    fh.write(f"failover_requested_at={requested_at}\n")
    fh.write(f"restore_point_locked_at={now}\n")
    fh.write(f"target_promote_started_at={now}\n")
    fh.write(f"target_power_on_at={'' if cutover_ready else now}\n")
    fh.write(f"failover_completed_at={'' if cutover_ready else now}\n")
    fh.write(f"rto_actual_seconds={seconds_between(requested_at, now)}\n")
    fh.write(f"failover_runtime_state={runtime_state}\n")
    fh.write(f"active_side={active_side}\n")
    fh.write(f"target_power_state={target_power_state}\n")
    fh.write(f"target_promotion_state={target_promotion_state}\n")
    fh.write(f"manifest_sha256={manifest_sha256}\n")
    fh.write(f"target_vm_id={'' if target_vm_id is None else target_vm_id}\n")
    fh.write(f"target_external_ref={target_external_ref}\n")
    fh.write(f"last_source_checkpoint_at={source_at or ''}\n")
    fh.write(f"last_target_durable_at={target_at or ''}\n")
    fh.write(f"target_ready_rpo_seconds={target_rpo or ''}\n")
    fh.write(f"restore_points_path={restore_points_path or ''}\n")
PY
  [[ "${rc}" == "0" ]] || {
    rm -f "${selection_path}" 2>/dev/null || true
    return "${rc}"
  }

  failover_session_id="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_session_id")"
  failover_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_restore_point_ref")"
  failover_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_restore_point_sequence")"
  failover_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_manifest_path")"
  failover_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_checkpoint_path")"
  failover_requested_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_requested_at")"
  restore_point_locked_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "restore_point_locked_at")"
  target_promote_started_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_promote_started_at")"
  target_power_on_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_power_on_at")"
  failover_completed_at="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_completed_at")"
  rto_actual_seconds="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "rto_actual_seconds")"
  last_source="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_source_checkpoint_at")"
  last_target="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "last_target_durable_at")"
  target_rpo="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_ready_rpo_seconds")"
  restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "restore_points_path")"
  target_power_state="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_power_state")"
  target_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_promotion_state")"
  failover_runtime_state="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "failover_runtime_state")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "active_side")"
  manifest_sha256="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "manifest_sha256")"
  target_vm_id="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_vm_id")"
  target_external_ref="$(ftctl_dr_runtime_state_get_from_path "${selection_path}" "target_external_ref")"
  [[ -n "${failover_runtime_state}" ]] || failover_runtime_state="FAILED_OVER"
  [[ -n "${active_side}" ]] || active_side="TARGET"
  rm -f "${selection_path}" 2>/dev/null || true

  ftctl_dr_runtime_path_set "${run_path}" \
    "state=${failover_runtime_state}" \
    "step=$( [[ "${failover_runtime_state}" == "CUTOVER_READY" ]] && printf 'cutover-ready' || printf 'active-side-switch' )" \
    "progress=100" \
    "scheduler_state=STOPPED" \
    "failover_session_id=${failover_session_id}" \
    "failover_mode=${mode}" \
    "failover_restore_point_ref=${failover_restore_point_ref}" \
    "failover_restore_point_sequence=${failover_restore_point_sequence}" \
    "failover_manifest_path=${failover_manifest_path}" \
    "failover_checkpoint_path=${failover_checkpoint_path}" \
    "failover_requested_at=${failover_requested_at}" \
    "restore_point_locked_at=${restore_point_locked_at}" \
    "target_promote_started_at=${target_promote_started_at}" \
    "target_power_on_at=${target_power_on_at}" \
    "failover_completed_at=${failover_completed_at}" \
    "rto_actual_seconds=${rto_actual_seconds}" \
    "active_side=${active_side}" \
    "target_power_state=${target_power_state}" \
    "target_promotion_state=${target_promotion_state}" \
    "manifest_sha256=${manifest_sha256}" \
    "target_vm_id=${target_vm_id}" \
    "target_external_ref=${target_external_ref}" \
    "last_source_checkpoint_at=${last_source}" \
    "last_target_durable_at=${last_target}" \
    "target_ready_rpo_seconds=${target_rpo}" \
    "restore_points_path=${restore_points_path}" \
    "error_code=" \
    "updated_at=${failover_completed_at}"
  ftctl_dr_runtime_apply_target_authority_terminal_state "${run_path}" "${failover_completed_at}" || return 2
  ftctl_dr_runtime_publish_status "${run_path}" "${status_path}" || return 2
}

ftctl_dr_runtime_failover_worker() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" restore_point="${4-}" mode="${5-}" run_path="${6-}" status_path="${7-}"
  local final_sync final_restore_point_ref rc=0 error_code now source_isolation_ack source_isolation_reason source_fence_state
  local source_runtime_quiesce_required=false source_runtime_quiesce_held=false

  now="$(ftctl_now_iso8601)"
  source_isolation_ack="$(jq -r '.request.sourceIsolationAcknowledged // false' "${profile_file}" 2>/dev/null || echo false)"
  source_isolation_reason="$(jq -r '.request.sourceIsolationReason // empty' "${profile_file}" 2>/dev/null || true)"
  source_fence_state="REQUESTED"
  if [[ "${mode}" == "disaster" ]]; then
    if [[ "${source_isolation_ack}" != "true" || -z "${source_isolation_reason}" ]]; then
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=source-isolation-unconfirmed" \
        "progress=100" \
        "worker_state=FAILED" \
        "worker_pid=$$" \
        "worker_exit_code=78" \
        "source_fence_state=UNCONFIRMED" \
        "error_code=DR_SOURCE_ISOLATION_UNCONFIRMED" \
        "error_message=Disaster failover requires source isolation acknowledgement and a reason" \
        "updated_at=${now}" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      return 78
    fi
    source_fence_state="ACKNOWLEDGED"
  fi
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=pre-failover-check" \
    "progress=25" \
    "worker_state=RUNNING" \
    "worker_pid=$$" \
    "failover_requested_at=${now}" \
    "failover_mode=${mode}" \
    "source_fence_state=${source_fence_state}" \
    "source_power_state=UNKNOWN" \
    "scheduler_recovery_state=STOPPED_PENDING_CUTOVER" \
    "updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  if command -v ftctl_dr_scheduler_control_set >/dev/null 2>&1; then
    ftctl_dr_scheduler_control_set "${plan}" "stop" || true
  fi

  final_sync="false"
  if [[ "${mode}" == "planned" ]] && ftctl_dr_runtime_profile_bool_default "${profile_file}" "request.finalSync" "true"; then
    final_sync="true"
  fi
  if [[ "${final_sync}" == "true" ]]; then
    if command -v ftctl_dr_ablestack_cutover_quiesce_required >/dev/null 2>&1 \
        && ftctl_dr_ablestack_cutover_quiesce_required "${profile_file}"; then
      source_runtime_quiesce_required=true
      ftctl_dr_runtime_path_set "${run_path}" \
        "step=source-runtime-quiesce" "progress=40" \
        "source_runtime_quiesce_state=QUIESCING" \
        "source_runtime_quiesce_mode=QMP_STOP" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      ftctl_dr_ablestack_cutover_quiesce_begin "${plan}" "${run}" "${profile_file}" \
        "${run_path}" "${status_path}" || rc=$?
      [[ "${rc}" == "0" ]] && source_runtime_quiesce_held=true
    fi
    if [[ "${rc}" == "0" ]]; then
      ftctl_dr_runtime_failover_final_checkpoint "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}" || rc=$?
    fi
    if [[ "${rc}" != "0" ]]; then
      case "${rc}" in
        65) error_code="DR_VMWARE_MOVER_UNAVAILABLE" ;;
        68) error_code="DR_VMWARE_MOVER_FAILED" ;;
        69) error_code="DR_VMWARE_NBDKIT_FAILED" ;;
        70) error_code="DR_VDDK_LIBDIR_UNRESOLVED" ;;
        71) error_code="DR_VDDK_LIBRARY_LOAD_FAILED" ;;
        72) error_code="DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID" ;;
        73) error_code="DR_VMWARE_VDDK_CONNECT_INVALID" ;;
        74) error_code="DR_VMWARE_VDDK_EXPORT_UNAVAILABLE" ;;
        75) error_code="DR_VMWARE_VDDK_SOURCE_LOCKED" ;;
        76) error_code="DR_VMWARE_VDDK_OPEN_DENIED" ;;
        77) error_code="DR_VMWARE_VDDK_THUMBPRINT_UNRESOLVED" ;;
        81) error_code="DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" ;;
        66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
        79|90|101|102|103|104|105|106|107) error_code="DR_SOURCE_RUNTIME_QUIESCE_FAILED" ;;
        *) error_code="DR_FINAL_CHECKPOINT_FAILED" ;;
      esac
      if [[ "${source_runtime_quiesce_required}" == "true" ]] \
          && command -v ftctl_dr_ablestack_cutover_quiesce_release >/dev/null 2>&1; then
        ftctl_dr_ablestack_cutover_quiesce_release "${plan}" "${run}" "${run_path}" "${status_path}" || true
      fi
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=final-delta-failed" \
        "progress=100" \
        "accepted=false" \
        "worker_state=FAILED" \
        "worker_pid=$$" \
        "worker_exit_code=${rc}" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      ftctl_log_event "dr-runtime" "dr.failover" "fail" "" "${error_code}" \
        "plan=${plan} run=${run} mode=${mode} rc=${rc}"
      return "${rc}"
    fi
    final_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_final_restore_point_ref")"
    if [[ -z "${final_restore_point_ref}" ]]; then
      if [[ "${source_runtime_quiesce_held}" == "true" ]] \
          && command -v ftctl_dr_ablestack_cutover_quiesce_release >/dev/null 2>&1; then
        ftctl_dr_ablestack_cutover_quiesce_release "${plan}" "${run}" "${run_path}" "${status_path}" || true
      fi
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=final-checkpoint-reference-missing" \
        "progress=100" \
        "accepted=false" \
        "worker_state=FAILED" \
        "worker_pid=$$" \
        "worker_exit_code=67" \
        "error_code=DR_FINAL_CHECKPOINT_REFERENCE_MISSING" \
        "error_message=The durable final checkpoint reference was not published" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      return 67
    fi
    restore_point="${final_restore_point_ref}"
  fi

  local cutover_workdir direction cutover_checkpoint_sequence=""
  direction="$(jq -r '.direction // ""' "${profile_file}" 2>/dev/null || true)"
  if [[ "${direction}" == "VMWARE_TO_KVM" ]]; then
    local cutover_selection cutover_provenance
    cutover_provenance="$(ftctl_dr_runtime_plan_dir "${plan}")/cutover-provenance-$(ftctl_dr_runtime_key "${run}").json"
    cutover_selection="$(ftctl_dr_runtime_select_cutover_checkpoint "${plan}" "${run}" "${profile_file}" \
      "${restore_point}" "${status_path}" "${cutover_provenance}")" || rc=$?
    if [[ "${rc}" == "0" ]]; then
      IFS=$'\t' read -r cutover_checkpoint_sequence restore_point <<< "${cutover_selection}"
    fi
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=RUNNING" \
      "step=reverse-baseline-seed" \
      "progress=75" \
      "reverse_baseline_state=PREPARING" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    if [[ "${rc}" == "0" ]]; then
      ftctl_dr_kvm_vmware_seed_cutover_baseline "${plan}" "${run}" "${profile_file}" \
        "${cutover_checkpoint_sequence}" || rc=$?
    fi
    if [[ "${rc}" == "0" ]]; then
      local cutover_baseline
      cutover_baseline="$(ftctl_dr_kvm_vmware_baseline_path "${plan}")"
      jq --slurpfile proof "${cutover_provenance}" '. + {createdFromRestorePoint:$proof[0]}' \
        "${cutover_baseline}" > "${cutover_baseline}.provenance.tmp" \
        && mv -f "${cutover_baseline}.provenance.tmp" "${cutover_baseline}" || rc=67
    fi
    if [[ "${rc}" != "0" ]]; then
      if [[ "${source_runtime_quiesce_held}" == "true" ]] \
          && command -v ftctl_dr_ablestack_cutover_quiesce_release >/dev/null 2>&1; then
        ftctl_dr_ablestack_cutover_quiesce_release "${plan}" "${run}" "${run_path}" "${status_path}" || true
      fi
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" "step=reverse-baseline-seed-failed" "progress=100" \
        "accepted=false" "worker_state=FAILED" "worker_pid=$$" "worker_exit_code=${rc}" \
        "reverse_baseline_state=FAILED" "error_code=DR_REVERSE_BASELINE_SEED_FAILED" \
        "error_message=Unable to establish the KVM cutover baseline before target activation" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      ftctl_log_event "dr-runtime" "dr.failover.reverse-baseline" "fail" "" \
        "DR_REVERSE_BASELINE_SEED_FAILED" "plan=${plan} run=${run} checkpoint=${cutover_checkpoint_sequence} rc=${rc}"
      return "${rc}"
    fi
    ftctl_dr_runtime_path_set "${run_path}" \
      "reverse_baseline_state=LOCAL_DURABLE" \
      "reverse_baseline_generation=${cutover_checkpoint_sequence}" \
      "reverse_baseline_origin=FAILOVER_CUTOVER" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cutover_workdir="$(ftctl_dr_runtime_failover_dir "${plan}")/$(ftctl_dr_runtime_key "${run}")-guestprep"
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=RUNNING" \
      "step=guest-preparation" \
      "progress=80" \
      "guest_prep_state=RUNNING" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_guestprep_prepare_cutover_target "${profile_file}" "${run_path}" "${cutover_workdir}" \
      "${status_path}" "${restore_point}" || rc=$?
  else
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=CUTOVER_READY" \
      "step=guest-preparation-not-required" \
      "progress=90" \
      "guest_prep_state=NOT_REQUIRED" \
      "updated_at=$(ftctl_now_iso8601)" || true
  fi
  if [[ "${rc}" != "0" ]]; then
    if [[ "${source_runtime_quiesce_held}" == "true" ]] \
        && command -v ftctl_dr_ablestack_cutover_quiesce_release >/dev/null 2>&1; then
      ftctl_dr_ablestack_cutover_quiesce_release "${plan}" "${run}" "${run_path}" "${status_path}" || true
    fi
    case "${rc}" in
      44) error_code="DR_RESTORE_POINT_NOT_FOUND" ;;
      60) error_code="DR_CUTOVER_MANIFEST_INVALID" ;;
      61) error_code="DR_GUEST_OS_UNRESOLVED" ;;
      62) error_code="DR_TARGET_DISK_MAP_MISSING" ;;
      63) error_code="DR_TARGET_DISK_LOCATOR_INVALID" ;;
      64) error_code="DR_TARGET_DISK_NOT_DURABLE" ;;
      47|65) error_code="DR_GUEST_PREP_RUNTIME_UNAVAILABLE" ;;
      48) error_code="DR_GUEST_OS_UNRESOLVED" ;;
      *) error_code="DR_GUEST_PREPARATION_FAILED" ;;
    esac
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=guest-preparation-failed" \
      "progress=100" \
      "accepted=false" \
      "worker_state=FAILED" \
      "worker_pid=$$" \
      "worker_exit_code=${rc}" \
      "guest_prep_state=FAILED" \
      "scheduler_recovery_state=REQUIRES_AUTHORIZED_RECOVERY" \
      "error_code=${error_code}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_log_event "dr-runtime" "dr.failover.guestprep" "fail" "" "${error_code}" \
      "plan=${plan} run=${run} mode=${mode} rc=${rc}"
    return "${rc}"
  fi
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true

  ftctl_dr_runtime_finalize_failover "${plan}" "${run}" "${profile_file}" "${restore_point}" "${mode}" "${run_path}" "${status_path}" || rc=$?
  if [[ "${rc}" != "0" ]]; then
    if [[ "${source_runtime_quiesce_held}" == "true" ]] \
        && command -v ftctl_dr_ablestack_cutover_quiesce_release >/dev/null 2>&1; then
      ftctl_dr_ablestack_cutover_quiesce_release "${plan}" "${run}" "${run_path}" "${status_path}" || true
    fi
    error_code="DR_RESTORE_POINT_NOT_FOUND"
    [[ "${rc}" == "45" ]] && error_code="DR_TARGET_NOT_READY"
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=target-promote-failed" \
      "progress=100" \
      "accepted=false" \
      "worker_state=FAILED" \
      "worker_pid=$$" \
      "worker_exit_code=${rc}" \
      "error_code=${error_code}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_log_event "dr-runtime" "dr.failover" "fail" "" "${error_code}" \
      "plan=${plan} run=${run} mode=${mode} restore_point=${restore_point:-} rc=${rc}"
    return "${rc}"
  fi

  ftctl_log_event "dr-runtime" "dr.failover" "ok" "" "" \
    "plan=${plan} run=${run} mode=${mode} restore_point=$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_restore_point_ref")"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=SUCCEEDED" \
    "worker_pid=$$" \
    "worker_exit_code=0" \
    "worker_updated_at=$(ftctl_now_iso8601)" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_start_failover() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" restore_point="${4-}" mode="${5-}" run_path="${6-}" status_path="${7-}" wait_value="${8-}"
  local worker_profile pid log_path now

  worker_profile="${profile_file}"
  [[ -n "${worker_profile}" && -f "${worker_profile}" ]] || worker_profile="$(ftctl_dr_runtime_profile_path "${plan}")"
  mode="$(ftctl_dr_runtime_failover_mode "${mode}" "${worker_profile}")"

  if [[ "${wait_value}" != "false" || "${FTCTL_DR_FAILOVER_FOREGROUND:-0}" == "1" ]]; then
    ftctl_dr_runtime_failover_worker "${plan}" "${run}" "${worker_profile}" "${restore_point}" "${mode}" "${run_path}" "${status_path}"
    return $?
  fi

  log_path="${FTCTL_LOG_DIR}/dr-failover-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}").log"
  (
    trap - EXIT
    unset FTCTL_HELD_LOCK_FILE
    ftctl_dr_runtime_failover_worker "${plan}" "${run}" "${worker_profile}" "${restore_point}" "${mode}" "${run_path}" "${status_path}"
  ) >> "${log_path}" 2>&1 &
  pid="$!"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=failover-worker-started" \
    "progress=15" \
    "failover_mode=${mode}" \
    "failover_worker_pid=${pid}" \
    "updated_at=${now}" || true
}

ftctl_dr_runtime_write_operation_session() {
  local session_path="${1-}" active_path="${2-}" plan="${3-}" run="${4-}" operation="${5-}" state="${6-}" active_side="${7-}"
  local profile_file="${8-}" reverse_profile="${9-}" run_path="${10-}" requested_at="${11-}" completed_at="${12-}"

  ftctl_ensure_dir "$(dirname "${session_path}")" "0755"
  python3 - "${session_path}" "${active_path}" "${plan}" "${run}" "${operation}" "${state}" "${active_side}" \
    "${profile_file}" "${reverse_profile}" "${run_path}" "${requested_at}" "${completed_at}" <<'PY'
import json
import os
import shutil
import sys
from datetime import datetime, timezone

session_path, active_path, plan, run, operation, state, active_side, profile_file, reverse_profile, run_path, requested_at, completed_at = sys.argv[1:13]

def read_json(path):
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    return {}

def read_state(path):
    values = {}
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    key, value = line.split("=", 1)
                    values[key] = value
    return values

def seconds_between(start, end):
    def parse(value):
        if not value:
            return None
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    s = parse(start)
    e = parse(end)
    if s is None or e is None:
        return 0
    if s.tzinfo is None:
        s = s.replace(tzinfo=timezone.utc)
    if e.tzinfo is None:
        e = e.replace(tzinfo=timezone.utc)
    return max(0, int((e - s).total_seconds()))

runtime = read_state(run_path)
profile = read_json(profile_file)
reverse = read_json(reverse_profile)
sequence = runtime.get("checkpoint_sequence") or ""
restore_ref = runtime.get("checkpoint_ref") or (f"ftctl:{plan}:{run}:{sequence}" if sequence else f"ftctl:{plan}:latest")
session = {
    "version": 1,
    "planUuid": plan,
    "runUuid": run,
    "sessionId": f"{plan}:{run}",
    "operation": operation,
    "state": state,
    "activeSide": active_side,
    "startedAt": requested_at,
    "completedAt": completed_at,
    "rtoActualSeconds": seconds_between(requested_at, completed_at),
    "reverseDirection": reverse.get("direction"),
    "reverseProfilePath": reverse_profile,
    "restorePoint": {
        "ref": restore_ref,
        "checkpointSequence": int(sequence) if str(sequence).isdigit() else sequence,
        "manifest": runtime.get("manifest_path"),
        "checkpoint": runtime.get("checkpoint_path"),
        "sourceCheckpointAt": runtime.get("last_source_checkpoint_at"),
        "targetDurableAt": runtime.get("last_target_durable_at"),
        "targetReadyRpoSeconds": runtime.get("target_ready_rpo_seconds"),
    },
    "profile": {
        "originalDirection": profile.get("direction"),
        "reverseDirection": reverse.get("direction"),
        "source": reverse.get("source"),
        "target": reverse.get("target"),
        "mapping": reverse.get("mapping"),
    },
    "failure": {
        "phase": runtime.get("failure_phase"),
        "component": runtime.get("failed_component"),
        "workerExitCode": int(runtime["worker_exit_code"]) if str(runtime.get("worker_exit_code", "")).lstrip("-").isdigit() else None,
        "driverExitCode": int(runtime["driver_exit_code"]) if str(runtime.get("driver_exit_code", "")).lstrip("-").isdigit() else None,
        "errorCode": runtime.get("error_code"),
        "errorMessage": runtime.get("error_message"),
    },
    "preflight": {
        "baselineFileState": runtime.get("baseline_file_state"),
        "sourceDiskProbeState": runtime.get("source_disk_probe_state"),
        "targetWriterProbeState": runtime.get("target_writer_probe_state"),
    },
}
with open(session_path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
shutil.copyfile(session_path, active_path)
PY
}

ftctl_dr_runtime_failback_worker() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}"
  local launch_nonce="${6-}" worker_generation="${7-}" worker_profile reverse_profile worker_start_ticks now requested_at completed_at rc=0 error_code error_message failure_phase
  local worker_pid heartbeat_pid=""
  local reverse_preflight_json="" reverse_source_provider="" reverse_target_provider=""
  local sequence manifest_path checkpoint_path reverse_restore_points_path reverse_direction replication_direction provider_pair rto_actual_seconds
  local active_side current_state previous_checkpoint_sequence failed_component="kvm-vmware-mover"

  worker_profile="${profile_file}"
  [[ -n "${worker_profile}" && -f "${worker_profile}" ]] || worker_profile="$(ftctl_dr_runtime_profile_path "${plan}")"
  [[ -n "${launch_nonce}" ]] || launch_nonce="$(ftctl_dr_runtime_launch_nonce)"
  [[ "${worker_generation}" =~ ^[0-9]+$ ]] || worker_generation="$(date +%s%N)"
  worker_pid="${BASHPID:-$$}"
  worker_start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${worker_pid}" 2>/dev/null || true)"
  requested_at="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_worker_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
    "${worker_pid}" "${worker_start_ticks}" "STARTING" "${requested_at}" || return 70
  active_side="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "active_side")"
  current_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "authority_state")"
  previous_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_sequence")"
  if [[ "${active_side}" != "TARGET" && "${current_state}" != "FAILED_OVER" ]]; then
    ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
      "FAILED" "47" "DR_FAILBACK_REQUIRES_TARGET_ACTIVE" "$(ftctl_now_iso8601)" || true
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=failback-not-eligible" \
      "progress=100" \
      "accepted=false" \
      "error_code=DR_FAILBACK_REQUIRES_TARGET_ACTIVE" \
      "error_message=Committed target authority was not available for failback" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    return 47
  fi

  reverse_profile="$(ftctl_dr_runtime_reverse_profile_path "${plan}" "${run}" "failback")"
  failure_phase="REVERSE_PREFLIGHT"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=reverse-preflight" \
    "progress=20" \
    "failback_requested_at=${requested_at}" \
    "failback_phase=REQUESTED" \
    "worker_state=RUNNING" \
    "worker_launch_nonce=${launch_nonce}" \
    "worker_generation=${worker_generation}" \
    "worker_started_at=${requested_at}" \
    "worker_updated_at=${requested_at}" \
    "accepted=true" \
    "active_side=TARGET" \
    "checkpoint_sequence=${previous_checkpoint_sequence}" \
    "updated_at=${requested_at}" || true
  ftctl_dr_runtime_worker_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
    "${worker_pid}" "${worker_start_ticks}" "RUNNING" "${requested_at}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  ftctl_dr_runtime_write_operation_session \
    "$(ftctl_dr_runtime_failback_session_path "${plan}" "${run}")" \
    "$(ftctl_dr_runtime_active_failback_session_path "${plan}")" \
    "${plan}" "${run}" "failback" "REQUESTED" "TARGET" \
    "${worker_profile}" "" "${run_path}" "${requested_at}" "" || true

  if command -v ftctl_dr_scheduler_control_set >/dev/null 2>&1; then
    ftctl_dr_scheduler_control_set "${plan}" "stop" || true
  fi
  ftctl_dr_runtime_build_reverse_profile "${plan}" "${run}" "${worker_profile}" "${reverse_profile}" "failback" || rc=$?
  if [[ "${rc}" == "0" ]]; then
    reverse_source_provider="$(ftctl_dr_scheduler_profile_provider "${reverse_profile}" source)"
    reverse_target_provider="$(ftctl_dr_scheduler_profile_provider "${reverse_profile}" target)"
    if [[ "${reverse_source_provider}" == "ABLESTACK" && "${reverse_target_provider}" == "VMWARE" ]]; then
      reverse_preflight_json="$(ftctl_dr_kvm_vmware_reverse_preflight "${plan}" "${reverse_profile}" "FAILBACK_FINAL" "AUTO" 1 "$(ftctl_dr_runtime_credential_path "${plan}")")" || rc=$?
    fi
  fi
  if [[ -n "${reverse_preflight_json}" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "operation_intent=$(jq -r '.operation_intent // "FAILBACK_FINAL"' <<< "${reverse_preflight_json}")" \
      "requested_mode=$(jq -r '.requested_mode // "AUTO"' <<< "${reverse_preflight_json}")" \
      "effective_mode=$(jq -r '.effective_mode // ""' <<< "${reverse_preflight_json}")" \
      "mode_decision_code=$(jq -r '.mode_decision_code // ""' <<< "${reverse_preflight_json}")" \
      "initial_seed_required=$(jq -r '.initial_seed_required // false' <<< "${reverse_preflight_json}")" \
      "baseline_file_state=$(jq -r '.baseline_file_state // ""' <<< "${reverse_preflight_json}")" \
      "source_disk_probe_state=$(jq -r '.source_disk_probe_state // ""' <<< "${reverse_preflight_json}")" \
      "source_disk_count=$(jq -r '.source_disk_count // 0' <<< "${reverse_preflight_json}")" \
      "target_writer_probe_state=$(jq -r '.target_writer_probe_state // ""' <<< "${reverse_preflight_json}")" \
      "estimated_virtual_bytes=$(jq -r '.estimated_virtual_bytes // 0' <<< "${reverse_preflight_json}")" \
      "worker_updated_at=$(ftctl_now_iso8601)" || true
  fi
  if [[ "${rc}" == "0" ]]; then
    failure_phase="REVERSE_TRANSFER"
    replication_direction="$(ftctl_dr_runtime_profile_value "${reverse_profile}" "direction" 2>/dev/null || true)"
    provider_pair="$(ftctl_dr_runtime_profile_value "${reverse_profile}" "providerPair" 2>/dev/null || true)"
    [[ -n "${provider_pair}" ]] || provider_pair="${replication_direction}"
    if [[ "${provider_pair}" == "ABLESTACK_TO_ABLESTACK" ]]; then
      failed_component="ablestack-rbd-mover"
    fi
    reverse_direction="${provider_pair}"
    ftctl_dr_runtime_path_set "${run_path}" \
      "reverse_profile_path=${reverse_profile}" \
      "route_contract_version=2" \
      "replication_direction=${replication_direction}" \
      "reverse_direction=${reverse_direction}" \
      "provider_pair=${provider_pair}" || true
    ftctl_dr_runtime_path_set "${run_path}" \
      "operation_intent=FAILBACK_FINAL" \
      "requested_mode=AUTO" || true
    (
      while kill -0 "${worker_pid}" >/dev/null 2>&1; do
        ftctl_dr_runtime_worker_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
          "${worker_pid}" "${worker_start_ticks}" "RUNNING" "$(ftctl_now_iso8601)" || true
        sleep 2
      done
    ) &
    heartbeat_pid="$!"
    ftctl_dr_runtime_reverse_checkpoint "${plan}" "${run}" "${reverse_profile}" "${run_path}" "${status_path}" "failback-final" "failback" || rc=$?
    kill "${heartbeat_pid}" >/dev/null 2>&1 || true
    wait "${heartbeat_pid}" 2>/dev/null || true
    heartbeat_pid=""
  fi
  if [[ "${rc}" != "0" ]]; then
    case "${rc}" in
      65) error_code="DR_VMWARE_MOVER_UNAVAILABLE" ;;
      68) error_code="DR_VMWARE_MOVER_FAILED" ;;
      69) error_code="DR_VMWARE_NBDKIT_FAILED" ;;
      70) error_code="DR_VDDK_LIBDIR_UNRESOLVED" ;;
      71) error_code="DR_VDDK_LIBRARY_LOAD_FAILED" ;;
      72) error_code="DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID" ;;
      73) error_code="DR_VMWARE_VDDK_CONNECT_INVALID" ;;
      74) error_code="DR_VMWARE_VDDK_EXPORT_UNAVAILABLE" ;;
      75) error_code="DR_VMWARE_VDDK_SOURCE_LOCKED" ;;
      76) error_code="DR_REVERSE_TARGET_VM_NOT_STOPPED" ;;
      77) error_code="DR_VMWARE_VDDK_THUMBPRINT_UNRESOLVED" ;;
      81) error_code="DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" ;;
      82) error_code="DR_REVERSE_SOURCE_STORAGE_MISSING" ;;
      83) error_code="DR_REVERSE_BASELINE_REQUIRED" ;;
      84) error_code="DR_REVERSE_BASELINE_INVALID" ;;
      86) error_code="DR_REVERSE_SNAPSHOT_OPEN_FAILED" ;;
      87) error_code="DR_REVERSE_WRITER_FAILED" ;;
      88) error_code="DR_REVERSE_DURABILITY_VERIFY_FAILED" ;;
      90) error_code="DR_REVERSE_TARGET_BACKING_UNRESOLVED" ;;
      66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
      47) error_code="DR_FAILBACK_REQUIRES_TARGET_ACTIVE" ;;
      *) error_code="DR_FAILBACK_REVERSE_SYNC_FAILED" ;;
    esac
    error_message="Failback ${failure_phase} failed in ${failed_component} (exit ${rc})"
    ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
      "FAILED" "${rc}" "${error_code}" "$(ftctl_now_iso8601)" || true
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=failback-reverse-sync-failed" \
      "progress=100" \
      "accepted=true" \
      "failback_phase=FAILED" \
      "worker_state=FAILED" \
      "terminal_source=ENGINE_TERMINAL" \
      "terminal_version=1" \
      "terminal_publication_pending=false" \
      "terminal_publication_pending_since=" \
      "worker_pid=" \
      "worker_pid_alive=false" \
      "worker_exit_code=${rc}" \
      "driver_exit_code=${rc}" \
      "worker_updated_at=$(ftctl_now_iso8601)" \
      "failure_phase=${failure_phase}" \
      "failed_component=${failed_component}" \
      "target_writer_probe_state=$([[ "${failure_phase}" == "REVERSE_TRANSFER" ]] && printf FAILED || printf NOT_STARTED)" \
      "error_code=${error_code}" \
      "error_message=${error_message}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_dr_runtime_write_operation_session \
      "$(ftctl_dr_runtime_failback_session_path "${plan}" "${run}")" \
      "$(ftctl_dr_runtime_active_failback_session_path "${plan}")" \
      "${plan}" "${run}" "failback" "FAILED" "TARGET" \
      "${worker_profile}" "${reverse_profile}" "${run_path}" "${requested_at}" "$(ftctl_now_iso8601)" || true
    ftctl_log_event "dr-runtime" "dr.failback" "fail" "" "${error_code}" \
      "plan=${plan} run=${run} rc=${rc}"
    ftctl_dr_runtime_worker_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
      "${worker_pid}" "${worker_start_ticks}" "TERMINAL_PUBLISHED" "$(ftctl_now_iso8601)" || true
    return "${rc}"
  fi

  completed_at="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
    "FAILBACK_DATA_READY" "0" "" "${completed_at}" || true
  ftctl_dr_runtime_write_operation_session \
    "$(ftctl_dr_runtime_failback_session_path "${plan}" "${run}")" \
    "$(ftctl_dr_runtime_active_failback_session_path "${plan}")" \
    "${plan}" "${run}" "failback" "DATA_READY" "TARGET" \
    "${worker_profile}" "${reverse_profile}" "${run_path}" "${requested_at}" "${completed_at}"
  sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_sequence")"
  manifest_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "manifest_path")"
  checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_path")"
  reverse_restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_restore_points_path")"
  reverse_direction="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_direction")"
  replication_direction="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "replication_direction")"
  provider_pair="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "provider_pair")"
  rto_actual_seconds="$(python3 - "${requested_at}" "${completed_at}" <<'PY'
import sys
from datetime import datetime, timezone
def parse(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
s = parse(sys.argv[1])
e = parse(sys.argv[2])
if s is None or e is None:
    print(0)
else:
    if s.tzinfo is None:
        s = s.replace(tzinfo=timezone.utc)
    if e.tzinfo is None:
        e = e.replace(tzinfo=timezone.utc)
    print(max(0, int((e - s).total_seconds())))
PY
)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=FAILBACK_DATA_READY" \
    "step=cloud-lifecycle-pending" \
    "progress=70" \
    "scheduler_state=STOPPED" \
    "failback_phase=DATA_READY" \
    "cloud_lifecycle_state=PENDING" \
    "failback_session_id=${plan}:${run}" \
    "failback_mode=planned" \
    "failback_restore_point_ref=ftctl:${plan}:${sequence}" \
    "failback_restore_point_sequence=${sequence}" \
    "failback_manifest_path=${manifest_path}" \
    "failback_checkpoint_path=${checkpoint_path}" \
    "failback_requested_at=${requested_at}" \
    "reverse_sync_started_at=${requested_at}" \
    "reverse_target_ready_at=${completed_at}" \
    "source_promote_started_at=" \
    "source_power_on_at=" \
    "failback_completed_at=" \
    "failback_rto_actual_seconds=${rto_actual_seconds}" \
    "rto_actual_seconds=${rto_actual_seconds}" \
    "active_side=TARGET" \
    "source_power_state=POWERED_OFF" \
    "source_promotion_state=STANDBY" \
    "target_power_state=POWERED_ON" \
    "engine_ack_state=PENDING" \
    "route_contract_version=2" \
    "replication_direction=${replication_direction}" \
    "reverse_direction=${reverse_direction}" \
    "provider_pair=${provider_pair}" \
    "reverse_profile_path=${reverse_profile}" \
    "reverse_restore_points_path=${reverse_restore_points_path}" \
    "worker_state=SUCCEEDED" \
    "terminal_source=ENGINE_TERMINAL" \
    "terminal_version=1" \
    "terminal_publication_pending=false" \
    "terminal_publication_pending_since=" \
    "worker_pid=" \
    "worker_pid_alive=false" \
    "worker_exit_code=0" \
    "driver_exit_code=0" \
    "worker_updated_at=${completed_at}" \
    "baseline_file_state=LOCAL_DURABLE" \
    "source_disk_probe_state=READY" \
    "target_writer_probe_state=READY" \
    "failure_phase=" \
    "failed_component=" \
    "error_code=" \
    "error_message=" \
    "updated_at=${completed_at}"
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.failback" "ok" "" "" \
    "plan=${plan} run=${run} restore_point=ftctl:${plan}:${sequence} phase=DATA_READY active_side=TARGET"
  ftctl_dr_runtime_worker_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
    "${worker_pid}" "${worker_start_ticks}" "TERMINAL_PUBLISHED" "${completed_at}" || true
}

ftctl_dr_runtime_start_failback() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}" wait_value="${6-}"
  local pid log_path now launch_nonce worker_generation launch_path worker_path ack_nonce ack_generation ack_pid attempt

  if ftctl_dr_runtime_other_failback_worker_live "${plan}" "${run}"; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=RUNNING" "step=failback-existing-worker-reconciliation" "progress=15" \
      "accepted=false" "retryable=true" "retry_after_sec=2" \
      "reconciliation_required=true" "worker_liveness_state=ALIVE" \
      "error_code=DR_ENGINE_BUSY_RETRYABLE" \
      "error_message=Another Failback worker is still active for this Plan" \
      "updated_at=$(ftctl_now_iso8601)" || true
    return 20
  fi

  launch_nonce="$(ftctl_dr_runtime_launch_nonce)"
  worker_generation="$(date +%s%N)"
  launch_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" launch)"
  worker_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" worker)"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_journal_write "${launch_path}" \
    "version=1" "writer_role=launcher" "plan=${plan}" "run=${run}" \
    "launch_nonce=${launch_nonce}" "generation=${worker_generation}" \
    "launch_state=ACCEPTED" "written_at=${now}" || return 70

  if [[ "${wait_value}" != "false" || "${FTCTL_DR_FAILBACK_FOREGROUND:-0}" == "1" ]]; then
    ftctl_dr_runtime_failback_worker "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}" \
      "${launch_nonce}" "${worker_generation}"
    return $?
  fi

  log_path="${FTCTL_LOG_DIR}/dr-failback-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}").log"
  (
    trap - EXIT
    unset FTCTL_HELD_LOCK_FILE
    ftctl_dr_runtime_failback_worker "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}" \
      "${launch_nonce}" "${worker_generation}"
  ) >> "${log_path}" 2>&1 &
  pid="$!"
  now="$(ftctl_now_iso8601)"
  ack_pid=""
  for attempt in $(seq 1 100); do
    ack_nonce="$(ftctl_dr_runtime_journal_value "${worker_path}" launch_nonce)"
    ack_generation="$(ftctl_dr_runtime_journal_value "${worker_path}" generation)"
    ack_pid="$(ftctl_dr_runtime_journal_value "${worker_path}" worker_pid)"
    if [[ "${ack_nonce}" == "${launch_nonce}" && "${ack_generation}" == "${worker_generation}" && "${ack_pid}" =~ ^[0-9]+$ ]]; then
      break
    fi
    kill -0 "${pid}" >/dev/null 2>&1 || break
    sleep 0.05
  done
  ftctl_dr_runtime_journal_write "${launch_path}" \
    "version=1" "writer_role=launcher" "plan=${plan}" "run=${run}" \
    "launch_nonce=${launch_nonce}" "generation=${worker_generation}" \
    "expected_pid=${pid}" \
    "launch_state=$([[ "${ack_pid}" =~ ^[0-9]+$ ]] && printf ACKNOWLEDGED || printf ACK_PENDING)" \
    "written_at=${now}" || true
}

ftctl_dr_runtime_adopt_existing_reprotect() {
  local plan="${1-}" profile_file="${2-}" run_path="${3-}" status_path="${4-}"
  local active_session ack_path sequence_path provider_pair direction authority_side profile_plan
  local source_provider target_provider
  local session_plan session_state session_side reverse_profile session_sequence latest_sequence
  local manifest_path checkpoint_path source_checkpoint_at target_durable_at
  local ack_state ack_owner ack_worker ack_owner_matched active_worker baseline_sequence

  [[ -n "${plan}" && -f "${profile_file}" && -f "${status_path}" ]] || return 1
  provider_pair="$(ftctl_dr_runtime_profile_value "${profile_file}" "providerPair" 2>/dev/null || true)"
  if [[ -z "${provider_pair}" ]]; then
    source_provider="$(ftctl_dr_runtime_profile_value "${profile_file}" "source.provider" 2>/dev/null || true)"
    target_provider="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.provider" 2>/dev/null || true)"
    if [[ -n "${source_provider}" && -n "${target_provider}" ]]; then
      provider_pair="${source_provider^^}_TO_${target_provider^^}"
    fi
  fi
  direction="$(ftctl_dr_runtime_profile_value "${profile_file}" "direction" 2>/dev/null || true)"
  authority_side="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "active_side")"
  profile_plan="$(ftctl_dr_runtime_profile_value "${profile_file}" "planUuid" 2>/dev/null || true)"
  [[ "${provider_pair}" == "ABLESTACK_TO_ABLESTACK" && "${direction}" == "KVM_TO_KVM" \
        && "${authority_side}" == "TARGET" && "${profile_plan}" == "${plan}" ]] || return 1

  active_session="$(ftctl_dr_runtime_active_reprotect_session_path "${plan}")"
  [[ -f "${active_session}" ]] || return 1
  session_plan="$(jq -r '.planUuid // empty' "${active_session}" 2>/dev/null || true)"
  session_state="$(jq -r '.state // empty' "${active_session}" 2>/dev/null || true)"
  session_side="$(jq -r '.activeSide // empty' "${active_session}" 2>/dev/null || true)"
  reverse_profile="$(jq -r '.reverseProfilePath // empty' "${active_session}" 2>/dev/null || true)"
  session_sequence="$(jq -r '.restorePoint.checkpointSequence // empty' "${active_session}" 2>/dev/null || true)"
  [[ "${session_plan}" == "${plan}" && "${session_state}" == "READY" \
        && "${session_side}" == "TARGET" && -f "${reverse_profile}" \
        && "${session_sequence}" =~ ^[0-9]+$ ]] || return 1

  ftctl_dr_scheduler_active_worker_valid "${plan}" "" || return 1
  active_worker="$(ftctl_dr_scheduler_active_value "${plan}" "worker_run_uuid")"
  ack_path="$(ftctl_dr_scheduler_control_ack_path "${plan}")"
  ack_state="$(ftctl_state_read_kv "${ack_path}" "state" 2>/dev/null || true)"
  ack_owner="$(ftctl_state_read_kv "${ack_path}" "request_run_uuid" 2>/dev/null || true)"
  ack_worker="$(ftctl_state_read_kv "${ack_path}" "active_worker_run_uuid" 2>/dev/null || true)"
  ack_owner_matched="$(ftctl_state_read_kv "${ack_path}" "owner_matched" 2>/dev/null || true)"
  [[ "${ack_state}" == "RUNNING" && "${ack_owner_matched}" == "true" \
        && -n "${active_worker}" && "${ack_owner}" == "${active_worker}" \
        && "${ack_worker}" == "${active_worker}" ]] || return 1

  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  baseline_sequence="$(ftctl_state_read_kv "${sequence_path}" "reprotect_baseline_sequence" 2>/dev/null || true)"
  latest_sequence="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "latest_completed_checkpoint_sequence")"
  [[ "${baseline_sequence}" =~ ^[0-9]+$ && "${latest_sequence}" =~ ^[0-9]+$ \
        && "${latest_sequence}" -ge "${baseline_sequence}" \
        && "${latest_sequence}" -ge "${session_sequence}" ]] || return 1

  manifest_path="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "latest_completed_manifest_path")"
  checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "latest_completed_checkpoint_path")"
  source_checkpoint_at="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "latest_completed_source_checkpoint_at")"
  target_durable_at="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "latest_completed_target_durable_at")"
  [[ -f "${manifest_path}" && -f "${checkpoint_path}" && -n "${target_durable_at}" ]] || return 1

  ftctl_dr_runtime_path_set "${run_path}" \
    "checkpoint_sequence=${latest_sequence}" \
    "manifest_path=${manifest_path}" \
    "checkpoint_path=${checkpoint_path}" \
    "last_source_checkpoint_at=${source_checkpoint_at}" \
    "last_target_durable_at=${target_durable_at}" \
    "reverse_profile_path=${reverse_profile}" \
    "reverse_restore_points_path=$(ftctl_dr_runtime_reverse_restore_points_path "${plan}")" \
    "replication_direction=${direction}" \
    "reverse_direction=${direction}" \
    "provider_pair=${provider_pair}" \
    "reprotect_idempotent_adopted=true" \
    "reprotect_adopted_scheduler_run_uuid=${active_worker}" \
    "reprotect_adopted_at=$(ftctl_now_iso8601)" || return $?
  return 0
}

ftctl_dr_runtime_reprotect_worker() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}"
  local worker_profile reverse_profile now requested_at completed_at rc=0 error_code
  local launch_nonce worker_generation worker_pid worker_start_ticks
  local sequence manifest_path checkpoint_path reverse_restore_points_path reverse_direction replication_direction provider_pair rto_actual_seconds
  local scheduler_run=""
  local active_side current_state previous_checkpoint_sequence

  worker_profile="${profile_file}"
  [[ -n "${worker_profile}" && -f "${worker_profile}" ]] || worker_profile="$(ftctl_dr_runtime_profile_path "${plan}")"
  launch_nonce="$(ftctl_dr_runtime_launch_nonce)"
  worker_generation="$(date +%s%N)"
  worker_pid="${BASHPID:-$$}"
  worker_start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${worker_pid}" 2>/dev/null || true)"
  requested_at="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_worker_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
    "${worker_pid}" "${worker_start_ticks}" "RUNNING" "${requested_at}" || return 70
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=RUNNING" \
    "worker_pid=${worker_pid}" \
    "worker_pid_alive=true" \
    "worker_launch_nonce=${launch_nonce}" \
    "worker_generation=${worker_generation}" \
    "worker_started_at=${requested_at}" \
    "worker_updated_at=${requested_at}" \
    "terminal_publication_pending=false" \
    "terminal_publication_pending_since=" || true
  active_side="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "active_side")"
  current_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "authority_state")"
  previous_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_sequence")"
  if [[ "${active_side}" != "TARGET" && "${current_state}" != "FAILED_OVER" ]]; then
    completed_at="$(ftctl_now_iso8601)"
    ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
      "FAILED" "47" "DR_REPROTECT_REQUIRES_TARGET_ACTIVE" "${completed_at}" || true
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=reprotect-not-eligible" \
      "progress=100" \
      "accepted=false" \
      "worker_state=TERMINAL_PUBLISHED" \
      "worker_pid_alive=false" \
      "worker_exit_code=47" \
      "terminal_source=ENGINE_TERMINAL" \
      "terminal_version=1" \
      "terminal_authoritative=true" \
      "runtime_endpoints_drained=true" \
      "error_code=DR_REPROTECT_REQUIRES_TARGET_ACTIVE" \
      "error_message=Committed target authority was not available for reprotect" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    return 47
  fi

  reverse_profile="$(ftctl_dr_runtime_reverse_profile_path "${plan}" "${run}" "reprotect")"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=reprotect-preflight" \
    "progress=20" \
    "reprotect_requested_at=${requested_at}" \
    "active_side=TARGET" \
    "checkpoint_sequence=${previous_checkpoint_sequence}" \
    "updated_at=${requested_at}" || true
  if ftctl_dr_runtime_adopt_existing_reprotect "${plan}" "${worker_profile}" "${run_path}" "${status_path}"; then
    reverse_profile="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_profile_path")"
    replication_direction="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "replication_direction")"
    reverse_direction="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_direction")"
    provider_pair="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "provider_pair")"
    ftctl_dr_runtime_path_set "${run_path}" \
      "step=reprotect-existing-protection-adopted" \
      "progress=90" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  else
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_dr_runtime_build_reverse_profile "${plan}" "${run}" "${worker_profile}" "${reverse_profile}" "reprotect" || rc=$?
  fi
  if [[ "${rc}" == "0" && "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reprotect_idempotent_adopted")" != "true" ]]; then
    replication_direction="$(ftctl_dr_runtime_profile_value "${reverse_profile}" "direction" 2>/dev/null || true)"
    provider_pair="$(ftctl_dr_runtime_profile_value "${reverse_profile}" "providerPair" 2>/dev/null || true)"
    [[ -n "${provider_pair}" ]] || provider_pair="${replication_direction}"
    reverse_direction="${provider_pair}"
    ftctl_dr_runtime_path_set "${run_path}" \
      "reverse_profile_path=${reverse_profile}" \
      "route_contract_version=2" \
      "replication_direction=${replication_direction}" \
      "reverse_direction=${reverse_direction}" \
      "provider_pair=${provider_pair}" || true
    ftctl_dr_runtime_reverse_checkpoint "${plan}" "${run}" "${reverse_profile}" "${run_path}" "${status_path}" "reprotect-seed" "reprotect" || rc=$?
  fi
  if [[ "${rc}" != "0" ]]; then
    case "${rc}" in
      65) error_code="DR_VMWARE_MOVER_UNAVAILABLE" ;;
      68) error_code="DR_VMWARE_MOVER_FAILED" ;;
      69) error_code="DR_VMWARE_NBDKIT_FAILED" ;;
      70) error_code="DR_VDDK_LIBDIR_UNRESOLVED" ;;
      71) error_code="DR_VDDK_LIBRARY_LOAD_FAILED" ;;
      72) error_code="DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID" ;;
      73) error_code="DR_VMWARE_VDDK_CONNECT_INVALID" ;;
      74) error_code="DR_VMWARE_VDDK_EXPORT_UNAVAILABLE" ;;
      75) error_code="DR_VMWARE_VDDK_SOURCE_LOCKED" ;;
      76) error_code="DR_VMWARE_VDDK_OPEN_DENIED" ;;
      77) error_code="DR_VMWARE_VDDK_THUMBPRINT_UNRESOLVED" ;;
      81) error_code="DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" ;;
      94) error_code="DR_SITE_AGENT_EXPORT_CONTRACT_MISSING" ;;
      66) error_code="DR_UNSUPPORTED_DIRECTION" ;;
      47) error_code="DR_REPROTECT_REQUIRES_TARGET_ACTIVE" ;;
      *) error_code="DR_REPROTECT_REVERSE_SYNC_FAILED" ;;
    esac
    completed_at="$(ftctl_now_iso8601)"
    ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
      "FAILED" "${rc}" "${error_code}" "${completed_at}" || true
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=reprotect-reverse-sync-failed" \
      "progress=100" \
      "accepted=false" \
      "worker_state=TERMINAL_PUBLISHED" \
      "worker_pid_alive=false" \
      "worker_exit_code=${rc}" \
      "terminal_source=ENGINE_TERMINAL" \
      "terminal_version=1" \
      "terminal_authoritative=true" \
      "runtime_endpoints_drained=true" \
      "error_code=${error_code}" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_log_event "dr-runtime" "dr.reprotect" "fail" "" "${error_code}" \
      "plan=${plan} run=${run} rc=${rc}"
    return "${rc}"
  fi

  completed_at="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_write_operation_session \
    "$(ftctl_dr_runtime_reprotect_session_path "${plan}" "${run}")" \
    "$(ftctl_dr_runtime_active_reprotect_session_path "${plan}")" \
    "${plan}" "${run}" "reprotect" "READY" "TARGET" \
    "${worker_profile}" "${reverse_profile}" "${run_path}" "${requested_at}" "${completed_at}"
  cp -f "${reverse_profile}" "$(ftctl_dr_runtime_profile_path "${plan}")" 2>/dev/null || true
  sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_sequence")"
  manifest_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "manifest_path")"
  checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_path")"
  reverse_restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_restore_points_path")"
  reverse_direction="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "reverse_direction")"
  replication_direction="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "replication_direction")"
  provider_pair="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "provider_pair")"
  rto_actual_seconds="$(python3 - "${requested_at}" "${completed_at}" <<'PY'
import sys
from datetime import datetime, timezone
def parse(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
s = parse(sys.argv[1])
e = parse(sys.argv[2])
if s is None or e is None:
    print(0)
else:
    if s.tzinfo is None:
        s = s.replace(tzinfo=timezone.utc)
    if e.tzinfo is None:
        e = e.replace(tzinfo=timezone.utc)
    print(max(0, int((e - s).total_seconds())))
PY
)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=reprotect-scheduler-starting" \
    "progress=95" \
    "scheduler_desired_state=RUNNING" \
    "scheduler_health=RECOVERING" \
    "updated_at=$(ftctl_now_iso8601)" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  rc=0
  FTCTL_DR_REPROTECT_SCHEDULER_RUN=""
  if command -v ftctl_dr_scheduler_activate_reprotected_profile >/dev/null 2>&1; then
    ftctl_dr_scheduler_activate_reprotected_profile "${plan}" "${run}" \
      "$(ftctl_dr_runtime_profile_path "${plan}")" "${run_path}" "${status_path}" || rc=$?
    scheduler_run="${FTCTL_DR_REPROTECT_SCHEDULER_RUN:-}"
  else
    rc=127
  fi
  if [[ "${rc}" != "0" || -z "${scheduler_run}" ]]; then
    completed_at="$(ftctl_now_iso8601)"
    ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
      "FAILED" "${rc}" "DR_REPROTECT_SCHEDULER_START_FAILED" "${completed_at}" || true
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" \
      "step=reprotect-scheduler-start-failed" \
      "progress=100" \
      "accepted=false" \
      "active_side=TARGET" \
      "protection_state=FAILED_OVER_UNPROTECTED" \
      "scheduler_state=ERROR" \
      "scheduler_health=ERROR" \
      "scheduler_desired_state=RUNNING" \
      "worker_state=TERMINAL_PUBLISHED" \
      "worker_pid_alive=false" \
      "worker_exit_code=${rc}" \
      "terminal_source=ENGINE_TERMINAL" \
      "terminal_version=1" \
      "terminal_authoritative=true" \
      "runtime_endpoints_drained=true" \
      "error_code=DR_REPROTECT_SCHEDULER_START_FAILED" \
      "error_message=Reverse protection scheduler did not reach an owned RUNNING state" \
      "updated_at=${completed_at}" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    ftctl_log_event "dr-runtime" "dr.reprotect.scheduler" "fail" "" \
      "DR_REPROTECT_SCHEDULER_START_FAILED" "plan=${plan} run=${run} rc=${rc}"
    return "${rc}"
  fi
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=READY" \
    "step=reprotect-ready" \
    "progress=100" \
    "protection_state=READY" \
    "scheduler_state=RUNNING" \
    "scheduler_health=HEALTHY" \
    "scheduler_desired_state=RUNNING" \
    "scheduler_owner_run_uuid=${scheduler_run}" \
    "reprotect_session_id=${plan}:${run}" \
    "reprotect_mode=reverse" \
    "reprotect_restore_point_ref=ftctl:${plan}:${sequence}" \
    "reprotect_restore_point_sequence=${sequence}" \
    "reprotect_manifest_path=${manifest_path}" \
    "reprotect_checkpoint_path=${checkpoint_path}" \
    "reprotect_requested_at=${requested_at}" \
    "reprotect_completed_at=${completed_at}" \
    "reprotect_rto_actual_seconds=${rto_actual_seconds}" \
    "rto_actual_seconds=${rto_actual_seconds}" \
    "active_side=TARGET" \
    "target_power_state=POWER_ON_DELEGATED" \
    "target_promotion_state=PROMOTED" \
    "route_contract_version=2" \
    "replication_direction=${replication_direction}" \
    "reverse_direction=${reverse_direction}" \
    "provider_pair=${provider_pair}" \
    "reverse_profile_path=${reverse_profile}" \
    "reverse_restore_points_path=${reverse_restore_points_path}" \
    "control_request_run_uuid=${run}" \
    "worker_state=SUCCEEDED" \
    "worker_pid_alive=false" \
    "worker_exit_code=0" \
    "transfer_activity_state=IDLE" \
    "error_code=" \
    "updated_at=${completed_at}"
  if ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
      "SUCCEEDED" "0" "" "${completed_at}"; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "worker_state=TERMINAL_PUBLISHED" \
      "terminal_source=ENGINE_TERMINAL" \
      "terminal_version=1" \
      "terminal_authoritative=true" \
      "runtime_endpoints_drained=true" \
      "terminal_publication_pending=false" \
      "terminal_publication_pending_since=" \
      "updated_at=${completed_at}" || true
    ftctl_dr_runtime_worker_journal_write "${plan}" "${run}" "${launch_nonce}" "${worker_generation}" \
      "${worker_pid}" "${worker_start_ticks}" "TERMINAL_PUBLISHED" "${completed_at}" || true
  else
    ftctl_dr_runtime_path_set "${run_path}" \
      "worker_state=TERMINAL_PENDING" \
      "terminal_authoritative=false" \
      "runtime_endpoints_drained=true" \
      "terminal_publication_pending=true" \
      "terminal_publication_pending_since=${completed_at}" \
      "updated_at=${completed_at}" || true
  fi
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.reprotect" "ok" "" "" \
    "plan=${plan} run=${run} restore_point=ftctl:${plan}:${sequence} active_side=TARGET"
}

ftctl_dr_runtime_repair_reprotect_terminal() {
  local plan="${1-}" run="${2-}" path="${3-}"
  local terminal_path action state step progress completed_at worker_state error_code
  local manifest_path checkpoint_path nonce generation now

  [[ -n "${plan}" && -n "${run}" && -f "${path}" ]] || return 0
  terminal_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" terminal)"
  [[ ! -f "${terminal_path}" ]] || return 0
  action="$(ftctl_dr_runtime_state_get_from_path "${path}" action)"
  state="$(ftctl_dr_runtime_state_get_from_path "${path}" state)"
  step="$(ftctl_dr_runtime_state_get_from_path "${path}" step)"
  progress="$(ftctl_dr_runtime_state_get_from_path "${path}" progress)"
  completed_at="$(ftctl_dr_runtime_state_get_from_path "${path}" reprotect_completed_at)"
  worker_state="$(ftctl_dr_runtime_state_get_from_path "${path}" worker_state)"
  error_code="$(ftctl_dr_runtime_state_get_from_path "${path}" error_code)"
  manifest_path="$(ftctl_dr_runtime_state_get_from_path "${path}" reprotect_manifest_path)"
  checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${path}" reprotect_checkpoint_path)"
  [[ "${action}" == "dr-reprotect" && "${state}" == "READY" && "${step}" == "reprotect-ready" \
        && "${progress}" == "100" && -n "${completed_at}" && -z "${error_code}" \
        && ( "${worker_state}" == "SUCCEEDED" || "${worker_state}" == "TERMINAL_PENDING" \
             || "${worker_state}" == "TERMINAL_PUBLISHED" ) \
        && -f "${manifest_path}" && -f "${checkpoint_path}" ]] || return 0

  nonce="$(ftctl_dr_runtime_state_get_from_path "${path}" worker_launch_nonce)"
  generation="$(ftctl_dr_runtime_state_get_from_path "${path}" worker_generation)"
  [[ -n "${nonce}" ]] || nonce="status-repair:${plan}:${run}"
  [[ "${generation}" =~ ^[0-9]+$ ]] || generation="0"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${nonce}" "${generation}" \
    "SUCCEEDED" "0" "" "${now}" || return $?
  ftctl_dr_runtime_path_set "${path}" \
    "protection_state=READY" \
    "control_request_run_uuid=${run}" \
    "worker_state=TERMINAL_PUBLISHED" \
    "worker_exit_code=0" \
    "worker_pid_alive=false" \
    "transfer_activity_state=IDLE" \
    "terminal_source=ENGINE_TERMINAL" \
    "terminal_version=1" \
    "terminal_authoritative=true" \
    "runtime_endpoints_drained=true" \
    "terminal_publication_pending=false" \
    "terminal_publication_pending_since=" \
    "terminal_repaired_at=${now}" \
    "updated_at=${now}"
  ftctl_log_event "dr-runtime" "dr.reprotect.terminal-repair" "ok" "" "" \
    "plan=${plan} run=${run}"
}

ftctl_dr_runtime_start_reprotect() {
  local plan="${1-}" run="${2-}" profile_file="${3-}" run_path="${4-}" status_path="${5-}" wait_value="${6-}"
  local pid log_path now

  if [[ "${wait_value}" != "false" || "${FTCTL_DR_REPROTECT_FOREGROUND:-0}" == "1" ]]; then
    ftctl_dr_runtime_reprotect_worker "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}"
    return $?
  fi

  log_path="${FTCTL_LOG_DIR}/dr-reprotect-$(ftctl_dr_runtime_key "${plan}")-$(ftctl_dr_runtime_key "${run}").log"
  (
    trap - EXIT
    unset FTCTL_HELD_LOCK_FILE
    ftctl_dr_runtime_reprotect_worker "${plan}" "${run}" "${profile_file}" "${run_path}" "${status_path}"
  ) >> "${log_path}" 2>&1 &
  pid="$!"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=RUNNING" \
    "step=reprotect-worker-started" \
    "progress=15" \
    "reprotect_worker_pid=${pid}" \
    "updated_at=${now}" || true
}

ftctl_dr_runtime_emit_events_since() {
  local plan="${1-}" offset="${2-0}" limit="${3-20}" events_path
  [[ "${offset}" =~ ^[0-9]+$ ]] || offset="0"
  [[ "${limit}" =~ ^[0-9]+$ ]] || limit="20"
  (( limit <= 100 )) || limit="100"
  events_path="$(ftctl_dr_runtime_plan_events_path "${plan}")"
  python3 - "${events_path}" "${offset}" "${limit}" <<'PY'
import json
import os
import sys

path, offset, limit = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
lines = []
if os.path.isfile(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
current = len(lines)
candidates = list(enumerate(lines, start=1))
candidates = [(seq, line) for seq, line in candidates if seq > offset]
truncated = limit == 0 and bool(candidates)
if limit == 0:
    candidates = []
elif len(candidates) > limit:
    candidates = candidates[-limit:]
    truncated = True
events = []
invalid = 0
for seq, line in candidates:
    try:
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError("event is not an object")
        events.append(value)
    except Exception:
        invalid += 1
payload = {
    "events_offset": current,
    "events_next_offset": current,
    "events_truncated": truncated,
    "events_invalid_count": invalid,
    "events": events,
}
encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"))
sys.stdout.write("," + encoded[1:-1])
PY
}

# Additive profile boot evidence; keep full observation fingerprint v2 unchanged.
ftctl_dr_runtime_boot_hardware() {
  local profile_path="${1-}"
  [[ -f "${profile_path}" ]] || { printf '{}'; return 0; }
  jq -c '
    (.mapping.source.hardware // {})
    | with_entries(select(.key == "sourceVmRef" or .key == "firmware" or .key == "UEFI"
        or .key == "secureBoot" or .key == "rootDiskController" or .key == "dataDiskController"
        or .key == "vmDetails"))
    | if (.vmDetails | type) == "object" then
        .vmDetails |= with_entries(select(.key | ascii_downcase |
          test("^(uefi|rootdiskcontroller|datadiskcontroller|bootorder|boot[.]order|tpmversion|tpmmodel|machinetype)$")))
      else del(.vmDetails) end
  ' "${profile_path}" 2>/dev/null || printf '{}'
}

ftctl_dr_runtime_stable_hardware_fingerprint() {
  local profile_path="${1-}" canonical="" digest=""
  [[ -f "${profile_path}" ]] || return 1
  canonical="$(jq -c '
    (.mapping.source.hardware // {}) as $h
    | {}
    | if $h.sourceVmRef != null then .sourceVmRef = $h.sourceVmRef else . end
    | if $h.firmware != null then .firmware = $h.firmware else . end
    | if $h.UEFI != null then .UEFI = $h.UEFI else . end
    | if $h.secureBoot != null then .secureBoot = $h.secureBoot else . end
    | if $h.guestId != null then .guestId = $h.guestId else . end
    | if $h.cpuCount != null then .cpuCount = $h.cpuCount else . end
    | if $h.memoryMiB != null then .memoryMiB = $h.memoryMiB else . end
    | if $h.rootDiskController != null then .rootDiskController = $h.rootDiskController else . end
    | if $h.dataDiskController != null then .dataDiskController = $h.dataDiskController else . end
    | if ($h.vmDetails | type) == "object" then
        .vmDetails = ($h.vmDetails
          | to_entries
          | map(select((.key | ascii_downcase) as $key
              | (["message.", "clone.", "ftctl.", "dr.", "ha.", "host.", "runtime.", "last."]
                | map($key | startswith(.)) | any) | not))
          | sort_by(.key)
          | from_entries)
      else . end
  ' "${profile_path}" 2>/dev/null)" || return 1
  [[ -n "${canonical}" ]] || return 1
  digest="$(printf '%s' "${canonical}" | sha256sum | awk '{print $1}')"
  [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'sha256:%s\n' "${digest}"
}

ftctl_dr_runtime_emit_state_json() {
  local command="${1-}" result="${2-ok}" plan="${3-}" run="${4-}" state_path="${5-}" events_offset="${6-}" events_limit="${7-20}"
  local action state step progress external_job_ref error_code error_message failed_component data_commit_state data_copied metadata_committed target_durable cycle_retry_mode driver_exit_code last_source last_target target_rpo updated accepted
  local runtime_exists profile_exists run_exists
  local driver driver_state disk_map_path source_disk_map_path target_disk_map_path disk_map_role
  local target_disk_count target_disk_invalid_count manifest_path checkpoint_path cbt_status_path source_open_status_path source_snapshot_status_path
  local scheduler_state worker_pid worker_start_ticks worker_pid_alive worker_state worker_started_at worker_updated_at worker_exit_code
  local terminal_source terminal_version terminal_publication_pending terminal_publication_pending_since terminal_pending_age
  local worker_identity_state worker_liveness_state worker_launch_nonce worker_generation worker_heartbeat_current
  local transfer_activity_state transfer_payload_bytes owned_process_count reconciliation_required terminal_authoritative runtime_endpoints_drained
  local transfer_progress_schema_version transfer_cycle_sequence transfer_sample_sequence transfer_phase transfer_mode
  local transfer_bytes_total transfer_bytes_processed transfer_source_read_bytes transfer_target_written_bytes transfer_verified_bytes
  local transfer_percent transfer_throughput_bps transfer_eta_seconds transfer_current_disk_index transfer_disk_count
  local transfer_progress_estimated transfer_progress_sample_epoch_ms transfer_progress_stale
  local worker_journal_path terminal_journal_path progress_journal_path actual_worker_start_ticks heartbeat_age progress_updated_epoch progress_age
  local runtime_generation scheduler_pid_alive baseline_state reseed_reason consecutive_automatic_reseed_count
  local control_protocol_version control_generation control_ack_generation control_state cycle_state
  local scheduler_session_uuid scheduler_lease_epoch authority_sequence plan_cycle_sequence scheduler_health effective_status_authority_floor
  local resume_baseline_checkpoint_sequence minimum_completed_checkpoint_sequence immediate_cycle_pending immediate_cycle_owner_run scheduler_immediate_cycle_owner_run
  local replication_activity protection_state resource_disposition active_worker_run_uuid active_worker_pid active_worker_start_ticks
  local worker_heartbeat_at control_request_run_uuid scheduler_control_request_run_uuid owner_matched
  local transfer_owner_run_uuid progress_plan_uuid progress_run_uuid progress_cycle_sequence
  local transfer_plan_uuid="" transfer_run_uuid="" transfer_direction="" transfer_expected_sequence=""
  local scheduler_desired_state scheduler_service_unit scheduler_unit_active_state scheduler_unit_sub_state
  local scheduler_unit_main_pid scheduler_cgroup scheduler_recovery_state scheduler_recovery_trigger scheduler_recovered_at
  local transition_state transition_action transition_quiesced_at checkpoint_lease_state checkpoint_lease_path
  local retryable retry_after_sec lock_file holder_pid holder_command holder_age_sec
  local checkpoint_sequence restore_points_path dynamic_rpo policy_target_rpo_seconds=""
  local scheduler_next_run_at scheduler_execution_budget_seconds scheduler_cycle_wall_duration_seconds
  local current_checkpoint_sequence current_checkpoint_cycle_type current_checkpoint_requested_mode current_checkpoint_effective_mode
  local current_checkpoint_mode_decision_code current_checkpoint_automatic_reseed current_checkpoint_invalid_baseline_disk_count
  local current_checkpoint_ref current_checkpoint_state
  local latest_completed_checkpoint_sequence latest_completed_checkpoint_cycle_type latest_completed_checkpoint_ref latest_completed_checkpoint_state
  local latest_completed_producer_run_uuid
  local latest_completed_source_checkpoint_at latest_completed_target_durable_at latest_completed_target_ready_rpo_seconds
  local latest_completed_manifest_path latest_completed_checkpoint_path
  local latest_completed_requested_mode latest_completed_effective_mode latest_completed_mode_decision_code latest_completed_reseed_reason
  local latest_completed_automatic_reseed latest_completed_invalid_baseline_disk_count
  local latest_completed_incremental_verified latest_completed_metrics_estimated latest_completed_virtual_bytes
  local latest_completed_changed_bytes latest_completed_source_read_bytes latest_completed_target_written_bytes
  local latest_completed_transfer_payload_bytes latest_completed_changed_extent_count latest_completed_duration_ms
  local latest_completed_throughput_bps latest_completed_baseline_generation latest_completed_cycle_token latest_completed_cycle_metrics_path
  local nbd_teardown_state nbd_quarantined_device_count nbd_teardown_error_code nbd_teardown_error_message
  local nbd_capacity_json="" nbd_capacity_configured="" nbd_capacity_ready="" nbd_capacity_error_code=""
  local latest_completed_nbd_teardown_state latest_completed_nbd_teardown_started_at_ms
  local latest_completed_nbd_teardown_completed_at_ms latest_completed_nbd_teardown_duration_ms
  local latest_completed_nbd_source_device_count latest_completed_nbd_target_device_count
  local latest_completed_nbd_quarantined_device_count latest_completed_nbd_teardown_error_code
  local latest_completed_nbd_teardown_error_message
  local -a completed_checkpoint_fields=()
  local test_session_id test_session_path test_session_state test_restore_point_ref test_restore_point_sequence
  local test_manifest_path test_checkpoint_path
  local test_artifacts_state test_artifacts_path test_artifact_count test_cleanup_state cleanup_required
  local failover_session_id failover_mode failover_restore_point_ref failover_restore_point_sequence
  local failover_manifest_path failover_checkpoint_path failover_requested_at restore_point_locked_at
  local target_promote_started_at target_power_on_at failover_completed_at rto_actual_seconds
  local active_side target_power_state target_promotion_state failover_worker_pid
  local boot_validation_state cloud_cutover_session_id cloud_authority_generation cloud_authority_sequence_floor engine_ack_state engine_ack_at
  local guest_preflight_state guest_preflight_error_code guest_preflight_error_message
  local guest_prep_state guest_family guestprep_manifest_path manifest_schema_version manifest_sha256
  local guestprep_checkpoint_sequence source_fence_state scheduler_recovery_state
  local source_runtime_quiesce_state source_runtime_quiesce_mode source_runtime_quiesce_owner_run
  local source_runtime_quiesced_at source_runtime_quiesce_released_at
  local cutover_source_disk_map_path cutover_source_disk_map_sha256
  local test_domain_name test_domain_state test_boot_validation_mode
  local failback_session_id failback_mode failback_phase="" cloud_lifecycle_state
  local failure_phase baseline_file_state source_disk_probe_state source_disk_count target_writer_probe_state
  local operation_intent requested_mode effective_mode mode_decision_code initial_seed_required estimated_virtual_bytes
  local failback_commit_outcome failback_commit_phase rollback_state rollback_generation
  local failback_commit_contract_version failback_commit_attempt_id failback_commit_envelope_sha256 failback_commit_dispatch_state
  local failback_restore_point_ref failback_restore_point_sequence
  local failback_manifest_path failback_checkpoint_path failback_requested_at reverse_sync_started_at
  local reverse_target_ready_at source_promote_started_at source_power_on_at failback_completed_at
  local failback_rto_actual_seconds source_power_state source_promotion_state failback_worker_pid post_failback_checkpoint_sequence
  local reprotect_session_id reprotect_mode reprotect_restore_point_ref reprotect_restore_point_sequence
  local reprotect_manifest_path reprotect_checkpoint_path reprotect_requested_at reprotect_completed_at
  local reprotect_rto_actual_seconds route_contract_version replication_direction reverse_direction provider_pair reverse_profile_path reverse_restore_points_path reprotect_worker_pid
  local target_vm_id target_external_ref target_materialized target_vm_present target_storage_present target_network_present restore_point_present
  local status_scope profile_path authority_state_path source_firmware="" source_secure_boot="" source_hardware_fingerprint="" source_hardware_fingerprint_version=""
  local target_boot_type="" target_boot_mode="" target_io_policy="" target_iothreads=""
  local reverse_evidence_contract_version="1" reverse_evidence_state="PENDING" reverse_evidence_run_uuid=""
  local reverse_evidence_state_path="" reverse_evidence_checkpoint_path="" reverse_evidence_checkpoint_plan=""
  local reverse_evidence_checkpoint_run="" reverse_evidence_checkpoint_sequence=""
  local baseline_generation="" tracker_state="" writer_state="" target_written="" write_verified=""
  local reverse_guest_compatibility_state="" reverse_evidence_field="" reverse_evidence_first="true"
  local -a reverse_evidence_missing_fields=()

  ftctl_dr_runtime_state_snapshot_begin "${state_path}"
  action="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "action")"
  state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "state")"
  step="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "step")"
  progress="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "progress")"
  external_job_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "external_job_ref")"
  error_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "error_code")"
  error_message="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "error_message")"
  failed_component="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failed_component")"
  if [[ -z "${error_code}" ]]; then
    failed_component=""
  elif [[ -z "${failed_component}" ]]; then
    failed_component="ftctl"
  fi
  data_commit_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "data_commit_state")"
  data_copied="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "data_copied")"
  metadata_committed="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "metadata_committed")"
  target_durable="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_durable")"
  cycle_retry_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cycle_retry_mode")"
  driver_exit_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver_exit_code")"
  last_source="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "last_source_checkpoint_at")"
  last_target="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "last_target_durable_at")"
  target_rpo="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_ready_rpo_seconds")"
  updated="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "updated_at")"
  accepted="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "accepted")"
  [[ -f "${state_path}" ]] && runtime_exists="true" || runtime_exists="false"
  profile_path="$(ftctl_dr_runtime_profile_path "${plan}")"
  [[ -f "${profile_path}" ]] && profile_exists="true" || profile_exists="false"
  [[ -n "${run}" && -f "$(ftctl_dr_runtime_run_path "${plan}" "${run}")" ]] && run_exists="true" || run_exists="false"
  if [[ "${profile_exists}" == "true" ]]; then
    source_firmware="$(jq -r '.mapping.source.hardware.firmware // empty' "${profile_path}" 2>/dev/null || true)"
    source_secure_boot="$(jq -r '.mapping.source.hardware.secureBoot // empty' "${profile_path}" 2>/dev/null || true)"
    source_hardware_fingerprint="$(jq -r '.mapping.source.hardware.fingerprint // empty' "${profile_path}" 2>/dev/null || true)"
    source_hardware_fingerprint_version="$(jq -r '.mapping.source.hardware.fingerprintVersion // empty' "${profile_path}" 2>/dev/null || true)"
    if [[ -z "${source_hardware_fingerprint_version}" ]]; then
      source_hardware_fingerprint="$(ftctl_dr_runtime_stable_hardware_fingerprint "${profile_path}" 2>/dev/null || true)"
      if [[ -n "${source_hardware_fingerprint}" ]]; then
        source_hardware_fingerprint_version="2"
      fi
    fi
    target_boot_type="$(jq -r '.mapping.target.hardware.bootType // empty' "${profile_path}" 2>/dev/null || true)"
    target_boot_mode="$(jq -r '.mapping.target.hardware.bootMode // empty' "${profile_path}" 2>/dev/null || true)"
    target_io_policy="$(jq -r '.mapping.target.hardware.ioPolicy // empty' "${profile_path}" 2>/dev/null || true)"
    target_iothreads="$(jq -r '.mapping.target.hardware.ioThreadsEnabled // empty' "${profile_path}" 2>/dev/null || true)"
    policy_target_rpo_seconds="$(jq -r '.policy.rpoSeconds // .schedule.intervalSeconds // empty' "${profile_path}" 2>/dev/null || true)"
  fi
  [[ "${policy_target_rpo_seconds}" =~ ^[1-9][0-9]*$ ]] || policy_target_rpo_seconds="${FTCTL_DR_SCHEDULER_INTERVAL_SEC:-300}"
  driver="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver")"
  driver_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "driver_state")"
  disk_map_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "disk_map_path")"
  source_disk_map_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_disk_map_path")"
  target_disk_map_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_disk_map_path")"
  disk_map_role="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "disk_map_role")"
  target_disk_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_disk_count")"
  target_disk_invalid_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_disk_invalid_count")"
  manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "manifest_path")"
  checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_path")"
  cbt_status_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cbt_status_path")"
  source_open_status_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_open_status_path")"
  source_snapshot_status_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_snapshot_status_path")"
  scheduler_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_state")"
  runtime_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "runtime_generation")"
  baseline_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "baseline_state")"
  reseed_reason="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reseed_reason")"
  consecutive_automatic_reseed_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "consecutive_automatic_reseed_count")"
  control_protocol_version="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_protocol_version")"
  control_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_generation")"
  control_ack_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_ack_generation")"
  control_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_state")"
  cycle_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cycle_state")"
  scheduler_session_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_session_uuid")"
  scheduler_lease_epoch="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_lease_epoch")"
  authority_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "authority_sequence")"
  plan_cycle_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "plan_cycle_sequence")"
  resume_baseline_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "resume_baseline_checkpoint_sequence")"
  minimum_completed_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "minimum_completed_checkpoint_sequence")"
  immediate_cycle_pending="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "immediate_cycle_pending")"
  immediate_cycle_owner_run="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "immediate_cycle_owner_run")"
  scheduler_health="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_health")"
  replication_activity="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "replication_activity")"
  protection_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "protection_state")"
  resource_disposition="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "resource_disposition")"
  active_worker_run_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "active_worker_run_uuid")"
  active_worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "active_worker_pid")"
  active_worker_start_ticks="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "active_worker_start_ticks")"
  worker_heartbeat_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_heartbeat_at")"
  control_request_run_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "control_request_run_uuid")"
  owner_matched="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "owner_matched")"
  scheduler_desired_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_desired_state")"
  scheduler_service_unit="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_service_unit")"
  scheduler_unit_active_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_unit_active_state")"
  scheduler_unit_sub_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_unit_sub_state")"
  scheduler_unit_main_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_unit_main_pid")"
  scheduler_cgroup="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_cgroup")"
  scheduler_recovery_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_recovery_state")"
  scheduler_recovery_trigger="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_recovery_trigger")"
  scheduler_recovered_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_recovered_at")"
  nbd_teardown_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "nbd_teardown_state")"
  nbd_quarantined_device_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "nbd_quarantined_device_count")"
  nbd_teardown_error_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "nbd_teardown_error_code")"
  nbd_teardown_error_message="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "nbd_teardown_error_message")"
  transition_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "transition_state")"
  transition_action="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "transition_action")"
  transition_quiesced_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "transition_quiesced_at")"
  checkpoint_lease_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_lease_state")"
  checkpoint_lease_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_lease_path")"
  worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_pid")"
  worker_start_ticks="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_start_ticks")"
  worker_pid_alive="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_pid_alive")"
  worker_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_state")"
  worker_started_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_started_at")"
  worker_updated_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_updated_at")"
  worker_exit_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "worker_exit_code")"
  terminal_source="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "terminal_source")"
  terminal_version="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "terminal_version")"
  terminal_publication_pending="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "terminal_publication_pending")"
  terminal_publication_pending_since="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "terminal_publication_pending_since")"
  worker_identity_state="UNPUBLISHED"
  worker_liveness_state="UNKNOWN"
  worker_launch_nonce=""
  worker_generation="0"
  transfer_activity_state="UNKNOWN"
  transfer_payload_bytes="0"
  transfer_progress_schema_version="0"
  transfer_cycle_sequence="0"
  transfer_sample_sequence="0"
  transfer_phase="UNKNOWN"
  transfer_mode="UNKNOWN"
  transfer_bytes_total="0"
  transfer_bytes_processed="0"
  transfer_source_read_bytes="0"
  transfer_target_written_bytes="0"
  transfer_verified_bytes="0"
  transfer_percent="0"
  transfer_throughput_bps="0"
  transfer_eta_seconds="0"
  transfer_current_disk_index="0"
  transfer_disk_count="0"
  transfer_progress_estimated="false"
  transfer_progress_sample_epoch_ms="0"
  transfer_progress_stale="false"
  owned_process_count="0"
  reconciliation_required="false"
  terminal_authoritative="false"
  runtime_endpoints_drained="false"
  if [[ "${terminal_source}" == "ENGINE_TERMINAL" ]]; then
    terminal_authoritative="true"
    runtime_endpoints_drained="true"
    worker_liveness_state="TERMINAL"
  fi
  if [[ -n "${run}" ]]; then
    worker_journal_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" worker)"
    terminal_journal_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" terminal)"
    progress_journal_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "transfer_progress_path")"
    [[ -n "${progress_journal_path}" ]] || progress_journal_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" progress)"
    if [[ -f "${worker_journal_path}" ]]; then
      worker_pid="$(ftctl_dr_runtime_journal_value "${worker_journal_path}" worker_pid)"
      worker_start_ticks="$(ftctl_dr_runtime_journal_value "${worker_journal_path}" worker_start_ticks)"
      worker_state="$(ftctl_dr_runtime_journal_value "${worker_journal_path}" worker_state)"
      worker_launch_nonce="$(ftctl_dr_runtime_journal_value "${worker_journal_path}" launch_nonce)"
      worker_generation="$(ftctl_dr_runtime_journal_value "${worker_journal_path}" generation)"
      worker_heartbeat_current="$(ftctl_dr_runtime_journal_value "${worker_journal_path}" worker_heartbeat_at)"
      if [[ -n "${worker_heartbeat_current}" ]]; then
        worker_updated_at="${worker_heartbeat_current}"
        worker_heartbeat_at="${worker_heartbeat_current}"
      fi
    fi
    if [[ "${action}" == dr-failback* ]]; then
      transfer_expected_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" checkpoint_sequence)"
    fi
    if [[ -f "${progress_journal_path}" ]] && jq -e --arg plan "${plan}" --arg run "${run}" \
        --arg sequence "${transfer_expected_sequence}" \
        '.planUuid == $plan and .runUuid == $run and
         ($sequence == "" or $sequence == "0" or (.cycleSequence | tostring) == $sequence)' \
        "${progress_journal_path}" >/dev/null 2>&1; then
      transfer_plan_uuid="${plan}"
      transfer_run_uuid="${run}"
      transfer_direction="$(jq -r '.direction // empty' "${progress_journal_path}")"
      transfer_activity_state="$(jq -r '.state // "UNKNOWN"' "${progress_journal_path}" 2>/dev/null || printf UNKNOWN)"
      transfer_payload_bytes="$(jq -r '.transferPayloadBytes // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_progress_schema_version="$(jq -r '.schemaVersion // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_cycle_sequence="$(jq -r '.cycleSequence // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_sample_sequence="$(jq -r '.sampleSequence // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_phase="$(jq -r '.phase // "UNKNOWN"' "${progress_journal_path}" 2>/dev/null || printf UNKNOWN)"
      transfer_mode="$(jq -r '.mode // "UNKNOWN"' "${progress_journal_path}" 2>/dev/null || printf UNKNOWN)"
      transfer_bytes_total="$(jq -r '.bytesTotal // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_bytes_processed="$(jq -r '.bytesProcessed // .transferPayloadBytes // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_source_read_bytes="$(jq -r '.sourceReadBytes // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_target_written_bytes="$(jq -r '.targetWrittenBytes // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_verified_bytes="$(jq -r '.verifiedBytes // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_percent="$(jq -r '(.percent // 0) | floor' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_throughput_bps="$(jq -r '.throughputBps // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_eta_seconds="$(jq -r '.etaSeconds // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_current_disk_index="$(jq -r '.diskIndex // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_disk_count="$(jq -r '.diskCount // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_progress_estimated="$(jq -r '.progressEstimated // false' "${progress_journal_path}" 2>/dev/null || printf false)"
      progress_updated_epoch="$(jq -r '.updatedAtEpochMs // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      transfer_progress_sample_epoch_ms="${progress_updated_epoch}"
      if [[ "${progress_updated_epoch}" =~ ^[0-9]+$ && "${progress_updated_epoch}" -gt 0 ]]; then
        progress_age=$(( $(date +%s) - (progress_updated_epoch / 1000) ))
      else
        progress_age=999999
      fi
      if [[ "${transfer_activity_state}" == "COPYING" || "${transfer_activity_state}" == "VERIFYING" ]]; then
        [[ "${progress_age}" -le "${FTCTL_DR_TRANSFER_PROGRESS_STALE_SECONDS:-15}" ]] || transfer_progress_stale="true"
      fi
    else
      progress_age=999999
    fi
    if [[ -f "${terminal_journal_path}" ]]; then
      terminal_source="$(ftctl_dr_runtime_journal_value "${terminal_journal_path}" terminal_source)"
      terminal_version="$(ftctl_dr_runtime_journal_value "${terminal_journal_path}" terminal_version)"
      terminal_authoritative="$(ftctl_dr_runtime_journal_value "${terminal_journal_path}" terminal_authoritative)"
      runtime_endpoints_drained="$(ftctl_dr_runtime_journal_value "${terminal_journal_path}" runtime_endpoints_drained)"
      worker_state="TERMINAL_PUBLISHED"
      worker_exit_code="$(ftctl_dr_runtime_journal_value "${terminal_journal_path}" terminal_exit_code)"
      worker_liveness_state="TERMINAL"
      terminal_publication_pending="false"
    fi
  fi
  if [[ "${terminal_authoritative}" != "true" && "${worker_state}" == "RUNNING" && "${worker_pid}" =~ ^[0-9]+$ ]]; then
    actual_worker_start_ticks="$(ftctl_dr_scheduler_process_start_ticks "${worker_pid}" 2>/dev/null || true)"
    if kill -0 "${worker_pid}" >/dev/null 2>&1; then
      worker_pid_alive="true"
      owned_process_count="1"
      if [[ -z "${worker_start_ticks}" || "${actual_worker_start_ticks}" == "${worker_start_ticks}" ]]; then
        worker_identity_state="MATCHED"
        worker_liveness_state="ALIVE"
      else
        worker_identity_state="CONFLICT"
        worker_liveness_state="SUSPECT"
        reconciliation_required="true"
      fi
    else
      worker_pid_alive="false"
      worker_identity_state="$([[ -n "${worker_start_ticks}" ]] && printf MATCHED || printf UNPUBLISHED)"
      if [[ "${action}" == "dr-failback" || -n "${failback_phase}" ]]; then
        heartbeat_age="$(ftctl_dr_runtime_rpo_from_target_at "${worker_updated_at}" 2>/dev/null || printf '999999')"
        [[ "${heartbeat_age}" =~ ^[0-9]+$ ]] || heartbeat_age=999999
        state="RUNNING"
        step="failback-runtime-reconciliation"
        worker_state="TERMINAL_PENDING"
        retryable="true"
        retry_after_sec="2"
        reconciliation_required="true"
        terminal_publication_pending="true"
        if [[ "${progress_age}" -lt "${FTCTL_DR_TERMINAL_PUBLICATION_GRACE_SECONDS:-10}" \
              || "${heartbeat_age}" -lt "${FTCTL_DR_TERMINAL_PUBLICATION_GRACE_SECONDS:-10}" ]]; then
          worker_liveness_state="SUSPECT"
        else
          worker_liveness_state="DEAD_CONFIRMED"
          runtime_endpoints_drained="false"
        fi
      fi
    fi
  fi
  if [[ "${terminal_authoritative}" != "true" \
        && "${progress_age:-999999}" -lt "${FTCTL_DR_TERMINAL_PUBLICATION_GRACE_SECONDS:-10}" \
        && ( "${transfer_activity_state}" == "COPYING" || "${transfer_activity_state}" == "VERIFYING" ) ]]; then
    worker_liveness_state="ALIVE"
    reconciliation_required="$([[ "${worker_identity_state}" == CONFLICT ]] && printf true || printf false)"
  fi
  scheduler_pid_alive="false"
  if ftctl_dr_scheduler_active_worker_valid "${plan}" ""; then
    scheduler_pid_alive="true"
    scheduler_state="RUNNING"
    scheduler_health="HEALTHY"
    owner_matched="true"
    scheduler_session_uuid="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
    scheduler_lease_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
    active_worker_run_uuid="$(ftctl_dr_scheduler_active_value "${plan}" "worker_run_uuid")"
    active_worker_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
    active_worker_start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"
    worker_heartbeat_at="$(ftctl_dr_scheduler_active_value "${plan}" "heartbeat_at")"
    scheduler_cgroup="$(ftctl_dr_scheduler_process_cgroup "${active_worker_pid}" 2>/dev/null || true)"
    if ftctl_dr_scheduler_systemd_available "${plan}"; then
      scheduler_service_unit="$(ftctl_dr_scheduler_unit_name "${plan}" 2>/dev/null || true)"
      scheduler_unit_active_state="$(systemctl show "${scheduler_service_unit}" -p ActiveState --value 2>/dev/null || true)"
      scheduler_unit_sub_state="$(systemctl show "${scheduler_service_unit}" -p SubState --value 2>/dev/null || true)"
      scheduler_unit_main_pid="$(systemctl show "${scheduler_service_unit}" -p MainPID --value 2>/dev/null || true)"
    fi
  elif [[ -f "$(ftctl_dr_scheduler_active_pid_path "${plan}")" ]]; then
    scheduler_pid_alive="false"
    scheduler_health="DEAD"
    owner_matched="false"
  elif [[ -z "${scheduler_health}" ]]; then
    scheduler_health="STOPPED"
    owner_matched="false"
  fi
  cloud_authority_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cloud_authority_generation")"
  cloud_authority_sequence_floor="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cloud_authority_sequence_floor")"
  effective_status_authority_floor="${cloud_authority_generation}"
  if [[ "${cloud_authority_sequence_floor}" =~ ^[0-9]+$ ]] && \
      { [[ ! "${effective_status_authority_floor}" =~ ^[0-9]+$ ]] || (( cloud_authority_sequence_floor > effective_status_authority_floor )); }; then
    effective_status_authority_floor="${cloud_authority_sequence_floor}"
  fi
  if [[ "${effective_status_authority_floor}" =~ ^[0-9]+$ ]]; then
    authority_sequence="$(ftctl_dr_scheduler_floor_authority_sequence \
      "${plan}" "${effective_status_authority_floor}")" || \
      authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  else
    authority_sequence="$(ftctl_dr_scheduler_current_authority_sequence "${plan}")"
  fi
  plan_cycle_sequence="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_sequence_path "${plan}")" "plan_cycle_sequence" 2>/dev/null || true)"
  resume_baseline_checkpoint_sequence="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_sequence_path "${plan}")" "resume_baseline_checkpoint_sequence" 2>/dev/null || true)"
  minimum_completed_checkpoint_sequence="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_sequence_path "${plan}")" "minimum_completed_checkpoint_sequence" 2>/dev/null || true)"
  immediate_cycle_pending="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_sequence_path "${plan}")" "immediate_cycle_pending" 2>/dev/null || true)"
  scheduler_immediate_cycle_owner_run="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_sequence_path "${plan}")" "immediate_cycle_owner_run" 2>/dev/null || true)"
  [[ -z "${scheduler_immediate_cycle_owner_run}" ]] || immediate_cycle_owner_run="${scheduler_immediate_cycle_owner_run}"
  scheduler_control_request_run_uuid="$(ftctl_dr_scheduler_control_value "${plan}" "owner_run")"
  if [[ -z "${run}" ]]; then
    [[ -z "${scheduler_control_request_run_uuid}" ]] || control_request_run_uuid="${scheduler_control_request_run_uuid}"
  else
    # An operation-scoped status keeps the immutable request owner even after
    # the plan scheduler accepts a later incremental cycle.
    [[ -n "${control_request_run_uuid}" ]] \
      || control_request_run_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" requested_cycle_owner_run)"
    [[ -n "${control_request_run_uuid}" ]] || control_request_run_uuid="${run}"
  fi
  if [[ -z "${run}" ]]; then
    transfer_owner_run_uuid="${control_request_run_uuid:-${immediate_cycle_owner_run:-${active_worker_run_uuid}}}"
    progress_journal_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "transfer_progress_path")"
    if [[ -n "${transfer_owner_run_uuid}" && -f "${progress_journal_path}" ]]; then
      progress_plan_uuid="$(jq -r '.planUuid // empty' "${progress_journal_path}" 2>/dev/null || true)"
      progress_run_uuid="$(jq -r '.runUuid // empty' "${progress_journal_path}" 2>/dev/null || true)"
      progress_cycle_sequence="$(jq -r '.cycleSequence // 0' "${progress_journal_path}" 2>/dev/null || printf 0)"
      if [[ "${progress_plan_uuid}" == "${plan}" \
            && "${progress_run_uuid}" == "${transfer_owner_run_uuid}" \
            && "${progress_cycle_sequence}" =~ ^[0-9]+$ \
            && ( ! "${plan_cycle_sequence}" =~ ^[0-9]+$ || "${plan_cycle_sequence}" == "0" \
                 || "${progress_cycle_sequence}" == "${plan_cycle_sequence}" ) \
            ]] && jq -e '(.schemaVersion // 0) >= 2 and (.bytesTotal // 0) > 0' \
                 "${progress_journal_path}" >/dev/null 2>&1; then
        transfer_plan_uuid="${plan}"
        transfer_run_uuid="${progress_run_uuid}"
        transfer_direction="$(jq -r '.direction // empty' "${progress_journal_path}")"
        transfer_activity_state="$(jq -r '.state // "UNKNOWN"' "${progress_journal_path}")"
        transfer_payload_bytes="$(jq -r '.transferPayloadBytes // 0' "${progress_journal_path}")"
        transfer_progress_schema_version="$(jq -r '.schemaVersion // 0' "${progress_journal_path}")"
        transfer_cycle_sequence="${progress_cycle_sequence}"
        transfer_sample_sequence="$(jq -r '.sampleSequence // 0' "${progress_journal_path}")"
        transfer_phase="$(jq -r '.phase // "UNKNOWN"' "${progress_journal_path}")"
        transfer_mode="$(jq -r '.mode // "UNKNOWN"' "${progress_journal_path}")"
        transfer_bytes_total="$(jq -r '.bytesTotal // 0' "${progress_journal_path}")"
        transfer_bytes_processed="$(jq -r '.bytesProcessed // .transferPayloadBytes // 0' "${progress_journal_path}")"
        transfer_source_read_bytes="$(jq -r '.sourceReadBytes // 0' "${progress_journal_path}")"
        transfer_target_written_bytes="$(jq -r '.targetWrittenBytes // 0' "${progress_journal_path}")"
        transfer_verified_bytes="$(jq -r '.verifiedBytes // 0' "${progress_journal_path}")"
        transfer_percent="$(jq -r '(.percent // 0) | floor' "${progress_journal_path}")"
        transfer_throughput_bps="$(jq -r '.throughputBps // 0' "${progress_journal_path}")"
        transfer_eta_seconds="$(jq -r '.etaSeconds // 0' "${progress_journal_path}")"
        transfer_current_disk_index="$(jq -r '.diskIndex // 0' "${progress_journal_path}")"
        transfer_disk_count="$(jq -r '.diskCount // 0' "${progress_journal_path}")"
        transfer_progress_estimated="$(jq -r '.progressEstimated // false' "${progress_journal_path}")"
        progress_updated_epoch="$(jq -r '.updatedAtEpochMs // 0' "${progress_journal_path}")"
        transfer_progress_sample_epoch_ms="${progress_updated_epoch}"
        if [[ "${progress_updated_epoch}" =~ ^[0-9]+$ && "${progress_updated_epoch}" -gt 0 ]]; then
          progress_age=$(( $(date +%s) - (progress_updated_epoch / 1000) ))
        else
          progress_age=999999
        fi
        transfer_progress_stale="false"
        if [[ "${transfer_activity_state}" == "COPYING" || "${transfer_activity_state}" == "VERIFYING" ]]; then
          [[ "${progress_age}" -le "${FTCTL_DR_TRANSFER_PROGRESS_STALE_SECONDS:-15}" ]] || transfer_progress_stale="true"
          if [[ "${transfer_progress_stale}" != "true" ]]; then
            worker_liveness_state="ALIVE"
          fi
        fi
      fi
    fi
  fi
  [[ -n "${replication_activity}" ]] || replication_activity="IDLE"
  [[ -n "${protection_state}" ]] || protection_state="${state}"
  retryable="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "retryable")"
  retry_after_sec="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "retry_after_sec")"
  lock_file="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "lock_file")"
  holder_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "holder_pid")"
  holder_command="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "holder_command")"
  holder_age_sec="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "holder_age_sec")"
  checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "checkpoint_sequence")"
  authority_state_path="$(ftctl_dr_runtime_status_path "${plan}")"
  if [[ "${authority_state_path}" != "${state_path}" && -f "${authority_state_path}" ]]; then
    ftctl_dr_runtime_state_snapshot_end
    ftctl_dr_runtime_state_snapshot_begin "${authority_state_path}"
  else
    authority_state_path="${state_path}"
  fi
  restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "restore_points_path")"
  [[ -n "${restore_points_path}" ]] || restore_points_path="$(ftctl_dr_runtime_plan_dir "${plan}")/restore-points.jsonl"
  current_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_sequence")"
  current_checkpoint_cycle_type="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_cycle_type")"
  current_checkpoint_requested_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_requested_mode")"
  current_checkpoint_effective_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_effective_mode")"
  current_checkpoint_mode_decision_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_mode_decision_code")"
  current_checkpoint_automatic_reseed="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_automatic_reseed")"
  current_checkpoint_invalid_baseline_disk_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_invalid_baseline_disk_count")"
  current_checkpoint_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_ref")"
  current_checkpoint_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "current_checkpoint_state")"
  latest_completed_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_checkpoint_sequence")"
  latest_completed_checkpoint_cycle_type="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_checkpoint_cycle_type")"
  latest_completed_checkpoint_ref="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_checkpoint_ref")"
  latest_completed_checkpoint_state="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_checkpoint_state")"
  latest_completed_producer_run_uuid="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_producer_run_uuid")"
  latest_completed_source_checkpoint_at="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_source_checkpoint_at")"
  latest_completed_target_durable_at="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_target_durable_at")"
  latest_completed_target_ready_rpo_seconds="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_target_ready_rpo_seconds")"
  scheduler_next_run_at="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "next_cycle_at")"
  scheduler_execution_budget_seconds="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "scheduler_execution_budget_seconds")"
  scheduler_cycle_wall_duration_seconds="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "scheduler_cycle_wall_duration_seconds")"
  latest_completed_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_manifest_path")"
  latest_completed_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_checkpoint_path")"
  latest_completed_requested_mode="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_requested_mode")"
  latest_completed_effective_mode="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_effective_mode")"
  latest_completed_mode_decision_code="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_mode_decision_code")"
  latest_completed_reseed_reason="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_reseed_reason")"
  latest_completed_automatic_reseed="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_automatic_reseed")"
  latest_completed_invalid_baseline_disk_count="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_invalid_baseline_disk_count")"
  latest_completed_incremental_verified="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_incremental_verified")"
  latest_completed_metrics_estimated="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_metrics_estimated")"
  latest_completed_virtual_bytes="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_virtual_bytes")"
  latest_completed_changed_bytes="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_changed_bytes")"
  latest_completed_source_read_bytes="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_source_read_bytes")"
  latest_completed_target_written_bytes="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_target_written_bytes")"
  latest_completed_transfer_payload_bytes="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_transfer_payload_bytes")"
  latest_completed_changed_extent_count="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_changed_extent_count")"
  latest_completed_duration_ms="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_duration_ms")"
  latest_completed_throughput_bps="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_throughput_bps")"
  latest_completed_baseline_generation="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_baseline_generation")"
  latest_completed_cycle_token="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_cycle_token")"
  latest_completed_cycle_metrics_path="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_cycle_metrics_path")"
  latest_completed_nbd_teardown_state="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_nbd_teardown_state")"
  latest_completed_nbd_teardown_started_at_ms="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_nbd_teardown_started_at_ms")"
  latest_completed_nbd_teardown_completed_at_ms="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_nbd_teardown_completed_at_ms")"
  latest_completed_nbd_teardown_duration_ms="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_nbd_teardown_duration_ms")"
  latest_completed_nbd_source_device_count="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_nbd_source_device_count")"
  latest_completed_nbd_target_device_count="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_nbd_target_device_count")"
  latest_completed_nbd_quarantined_device_count="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_nbd_quarantined_device_count")"
  latest_completed_nbd_teardown_error_code="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_nbd_teardown_error_code")"
  latest_completed_nbd_teardown_error_message="$(ftctl_dr_runtime_state_get_from_path "${authority_state_path}" "latest_completed_nbd_teardown_error_message")"
  if [[ -s "${restore_points_path}" ]]; then
    mapfile -t completed_checkpoint_fields < <(python3 - "${restore_points_path}" "${plan}" <<'PY' 2>/dev/null
import json
import sys

latest = None
expected_plan = sys.argv[2]
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            candidate = json.loads(line)
        except (TypeError, ValueError):
            continue
        if (candidate.get("checkpointSequence") is not None
                and candidate.get("planUuid") == expected_plan
                and candidate.get("state") in ("READY", "COMPLETED", "TARGET_READY")):
            latest = candidate
if latest:
    sequence = latest.get("checkpointSequence")
    expected_token = f"{expected_plan}:{sequence}"
    if latest.get("cycleToken") not in (None, "", expected_token):
        sys.exit(0)
    if latest.get("baselineGeneration") not in (None, "", sequence):
        sys.exit(0)
    for key in (
        "checkpointSequence", "cycleType", "checkpointRef", "state",
        "sourceCheckpointAt", "targetDurableAt", "targetReadyRpoSeconds",
        "manifest", "checkpoint", "producerRunUuid",
        "requestedMode", "effectiveMode", "modeDecisionCode", "reseedReason",
        "automaticReseed", "invalidBaselineDiskCount", "incrementalVerified",
        "metricsEstimated", "virtualBytes", "changedBytes", "sourceReadBytes",
        "targetWrittenBytes", "transferPayloadBytes", "changedExtentCount",
        "durationMs", "throughputBps", "baselineGeneration", "cycleToken",
        "nbdTeardownState", "nbdTeardownStartedAtEpochMs",
        "nbdTeardownCompletedAtEpochMs", "nbdTeardownDurationMs",
        "nbdSourceDeviceCount", "nbdTargetDeviceCount",
        "nbdQuarantinedDeviceCount", "nbdTeardownErrorCode",
        "nbdTeardownErrorMessage",
    ):
        value = latest.get(key)
        print("" if value is None else value)
PY
    )
    if (( ${#completed_checkpoint_fields[@]} >= 37 )) \
        && [[ ! "${latest_completed_checkpoint_sequence}" =~ ^[0-9]+$ \
          || "${completed_checkpoint_fields[0]}" -gt "${latest_completed_checkpoint_sequence}" ]]; then
      local completed_checkpoint_field_index
      for completed_checkpoint_field_index in "${!completed_checkpoint_fields[@]}"; do
        completed_checkpoint_fields[completed_checkpoint_field_index]="${completed_checkpoint_fields[completed_checkpoint_field_index]%$'\r'}"
      done
      latest_completed_checkpoint_sequence="${completed_checkpoint_fields[0]}"
      latest_completed_checkpoint_cycle_type="${completed_checkpoint_fields[1]}"
      latest_completed_checkpoint_ref="${completed_checkpoint_fields[2]}"
      latest_completed_checkpoint_state="${completed_checkpoint_fields[3]:-READY}"
      latest_completed_source_checkpoint_at="${completed_checkpoint_fields[4]}"
      latest_completed_target_durable_at="${completed_checkpoint_fields[5]}"
      latest_completed_target_ready_rpo_seconds="${completed_checkpoint_fields[6]}"
      latest_completed_manifest_path="${completed_checkpoint_fields[7]}"
      latest_completed_checkpoint_path="${completed_checkpoint_fields[8]}"
      latest_completed_producer_run_uuid="${completed_checkpoint_fields[9]}"
      latest_completed_requested_mode="${completed_checkpoint_fields[10]}"
      latest_completed_effective_mode="${completed_checkpoint_fields[11]}"
      latest_completed_mode_decision_code="${completed_checkpoint_fields[12]}"
      latest_completed_reseed_reason="${completed_checkpoint_fields[13]}"
      latest_completed_automatic_reseed="${completed_checkpoint_fields[14]}"
      latest_completed_invalid_baseline_disk_count="${completed_checkpoint_fields[15]}"
      latest_completed_incremental_verified="${completed_checkpoint_fields[16]}"
      latest_completed_metrics_estimated="${completed_checkpoint_fields[17]}"
      latest_completed_virtual_bytes="${completed_checkpoint_fields[18]}"
      latest_completed_changed_bytes="${completed_checkpoint_fields[19]}"
      latest_completed_source_read_bytes="${completed_checkpoint_fields[20]}"
      latest_completed_target_written_bytes="${completed_checkpoint_fields[21]}"
      latest_completed_transfer_payload_bytes="${completed_checkpoint_fields[22]}"
      latest_completed_changed_extent_count="${completed_checkpoint_fields[23]}"
      latest_completed_duration_ms="${completed_checkpoint_fields[24]}"
      latest_completed_throughput_bps="${completed_checkpoint_fields[25]}"
      latest_completed_baseline_generation="${completed_checkpoint_fields[26]}"
      latest_completed_cycle_token="${completed_checkpoint_fields[27]}"
      latest_completed_nbd_teardown_state="${completed_checkpoint_fields[28]}"
      latest_completed_nbd_teardown_started_at_ms="${completed_checkpoint_fields[29]}"
      latest_completed_nbd_teardown_completed_at_ms="${completed_checkpoint_fields[30]}"
      latest_completed_nbd_teardown_duration_ms="${completed_checkpoint_fields[31]}"
      latest_completed_nbd_source_device_count="${completed_checkpoint_fields[32]}"
      latest_completed_nbd_target_device_count="${completed_checkpoint_fields[33]}"
      latest_completed_nbd_quarantined_device_count="${completed_checkpoint_fields[34]}"
      latest_completed_nbd_teardown_error_code="${completed_checkpoint_fields[35]}"
      latest_completed_nbd_teardown_error_message="${completed_checkpoint_fields[36]}"
    fi
  fi
  if [[ -z "${latest_completed_producer_run_uuid}" && "${latest_completed_checkpoint_ref}" == ftctl:* ]]; then
    latest_completed_producer_run_uuid="$(awk -F: '{print $(NF-1)}' <<< "${latest_completed_checkpoint_ref}")"
  fi
  [[ -n "${latest_completed_producer_run_uuid}" ]] || latest_completed_producer_run_uuid="${active_worker_run_uuid}"
  [[ -n "${current_checkpoint_sequence}" ]] || current_checkpoint_sequence="${checkpoint_sequence}"
  if [[ "${authority_state_path}" != "${state_path}" ]]; then
    ftctl_dr_runtime_state_snapshot_end
    ftctl_dr_runtime_state_snapshot_begin "${state_path}"
  fi
  test_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_session_id")"
  test_session_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_session_path")"
  test_session_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_session_state")"
  test_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_restore_point_ref")"
  test_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_restore_point_sequence")"
  test_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_manifest_path")"
  test_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_checkpoint_path")"
  test_artifacts_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_artifacts_state")"
  test_artifacts_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_artifacts_path")"
  test_artifact_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_artifact_count")"
  test_cleanup_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_cleanup_state")"
  cleanup_required="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cleanup_required")"
  guest_preflight_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guest_preflight_state")"
  guest_preflight_error_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guest_preflight_error_code")"
  guest_preflight_error_message="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guest_preflight_error_message")"
  guest_prep_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guest_prep_state")"
  guest_family="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guest_family")"
  guestprep_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guestprep_manifest_path")"
  manifest_schema_version="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "manifest_schema_version")"
  manifest_sha256="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "manifest_sha256")"
  guestprep_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "guestprep_checkpoint_sequence")"
  source_fence_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_fence_state")"
  scheduler_recovery_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "scheduler_recovery_state")"
  source_runtime_quiesce_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_runtime_quiesce_state")"
  source_runtime_quiesce_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_runtime_quiesce_mode")"
  source_runtime_quiesce_owner_run="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_runtime_quiesce_owner_run")"
  source_runtime_quiesced_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_runtime_quiesced_at")"
  source_runtime_quiesce_released_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_runtime_quiesce_released_at")"
  cutover_source_disk_map_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cutover_source_disk_map_path")"
  cutover_source_disk_map_sha256="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cutover_source_disk_map_sha256")"
  test_domain_name="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_domain_name")"
  test_domain_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_domain_state")"
  test_boot_validation_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "test_boot_validation_mode")"
  failover_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_session_id")"
  failover_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_mode")"
  failover_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_restore_point_ref")"
  failover_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_restore_point_sequence")"
  failover_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_manifest_path")"
  failover_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_checkpoint_path")"
  failover_requested_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_requested_at")"
  restore_point_locked_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "restore_point_locked_at")"
  target_promote_started_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_promote_started_at")"
  target_power_on_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_power_on_at")"
  failover_completed_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_completed_at")"
  rto_actual_seconds="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "rto_actual_seconds")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "active_side")"
  target_power_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_power_state")"
  target_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_promotion_state")"
  boot_validation_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "boot_validation_state")"
  cloud_cutover_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cloud_cutover_session_id")"
  cloud_authority_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cloud_authority_generation")"
  cloud_authority_sequence_floor="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cloud_authority_sequence_floor")"
  engine_ack_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "engine_ack_state")"
  engine_ack_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "engine_ack_at")"
  failover_worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failover_worker_pid")"
  failback_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_session_id")"
  failback_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_mode")"
  failback_phase="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_phase")"
  failure_phase="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failure_phase")"
  baseline_file_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "baseline_file_state")"
  source_disk_probe_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_disk_probe_state")"
  source_disk_count="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_disk_count")"
  target_writer_probe_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_writer_probe_state")"
  operation_intent="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "operation_intent")"
  requested_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "requested_mode")"
  effective_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "effective_mode")"
  mode_decision_code="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "mode_decision_code")"
  initial_seed_required="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "initial_seed_required")"
  estimated_virtual_bytes="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "estimated_virtual_bytes")"
  cloud_lifecycle_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "cloud_lifecycle_state")"
  failback_commit_outcome="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_commit_outcome")"
  failback_commit_phase="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_commit_phase")"
  failback_commit_contract_version="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_commit_contract_version")"
  failback_commit_attempt_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_commit_attempt_id")"
  failback_commit_envelope_sha256="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_commit_envelope_sha256")"
  failback_commit_dispatch_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_commit_dispatch_state")"
  rollback_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "rollback_state")"
  rollback_generation="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "rollback_generation")"
  failback_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_restore_point_ref")"
  failback_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_restore_point_sequence")"
  failback_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_manifest_path")"
  failback_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_checkpoint_path")"
  failback_requested_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_requested_at")"
  reverse_sync_started_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_sync_started_at")"
  reverse_target_ready_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_target_ready_at")"
  source_promote_started_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_promote_started_at")"
  source_power_on_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_power_on_at")"
  failback_completed_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_completed_at")"
  failback_rto_actual_seconds="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_rto_actual_seconds")"
  source_power_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_power_state")"
  source_promotion_state="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "source_promotion_state")"
  failback_worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "failback_worker_pid")"
  post_failback_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "post_failback_checkpoint_sequence")"
  [[ -n "${post_failback_checkpoint_sequence}" ]] || post_failback_checkpoint_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "resume_checkpoint_completed_sequence")"
  if [[ "${failback_phase}" == "COMMIT_VERIFYING" || "${failback_phase}" == "PROTECTION_RESUMING" ]]; then
    terminal_authoritative="false"
    runtime_endpoints_drained="false"
    [[ "${terminal_source}" == "ENGINE_TERMINAL" ]] && terminal_source="DATA_TERMINAL"
  fi
  reprotect_session_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_session_id")"
  reprotect_mode="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_mode")"
  reprotect_restore_point_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_restore_point_ref")"
  reprotect_restore_point_sequence="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_restore_point_sequence")"
  reprotect_manifest_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_manifest_path")"
  reprotect_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_checkpoint_path")"
  reprotect_requested_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_requested_at")"
  reprotect_completed_at="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_completed_at")"
  reprotect_rto_actual_seconds="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_rto_actual_seconds")"
  route_contract_version="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "route_contract_version")"
  replication_direction="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "replication_direction")"
  reverse_direction="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_direction")"
  provider_pair="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "provider_pair")"
  if [[ -z "${provider_pair}" && "${profile_exists}" == "true" ]]; then
    provider_pair="$(ftctl_dr_scheduler_profile_provider "${profile_path}" source)_TO_$(ftctl_dr_scheduler_profile_provider "${profile_path}" target)"
  fi
  if [[ "${provider_pair}" == "VMWARE_TO_ABLESTACK" || "${provider_pair}" == "VMWARE_TO_KVM" ]]; then
    nbd_capacity_json="$(ftctl_dr_nbd_capacity_json)"
    nbd_capacity_configured="$(ftctl_dr_runtime_json_text_value "${nbd_capacity_json}" "configured")"
    nbd_capacity_ready="$(ftctl_dr_runtime_json_text_value "${nbd_capacity_json}" "ready")"
    nbd_capacity_error_code="$(ftctl_dr_runtime_json_text_value "${nbd_capacity_json}" "errorCode")"
  fi
  reverse_profile_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_profile_path")"
  reverse_restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_restore_points_path")"
  reprotect_worker_pid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reprotect_worker_pid")"
  reverse_evidence_run_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "reverse_evidence_run_uuid")"
  if [[ -z "${reverse_evidence_run_uuid}" && -n "${failback_session_id}" \
      && "${failback_session_id}" == "${plan}:"* ]]; then
    reverse_evidence_run_uuid="${failback_session_id#"${plan}:"}"
  fi
  [[ -n "${reverse_evidence_run_uuid}" ]] || reverse_evidence_run_uuid="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "run")"
  [[ -n "${reverse_evidence_run_uuid}" ]] || reverse_evidence_run_uuid="${run}"
  [[ -n "${reverse_evidence_run_uuid}" ]] || reverse_evidence_run_uuid="${external_job_ref}"
  [[ -n "${reverse_evidence_run_uuid}" ]] || reverse_evidence_run_uuid="${control_request_run_uuid}"
  reverse_evidence_state_path="${state_path}"
  if [[ -n "${reverse_evidence_run_uuid}" && -f "$(ftctl_dr_runtime_run_path "${plan}" "${reverse_evidence_run_uuid}")" ]]; then
    reverse_evidence_state_path="$(ftctl_dr_runtime_run_path "${plan}" "${reverse_evidence_run_uuid}")"
  fi
  baseline_generation="$(ftctl_dr_runtime_state_get_from_path "${reverse_evidence_state_path}" "baseline_generation")"
  baseline_state="$(ftctl_dr_runtime_state_get_from_path "${reverse_evidence_state_path}" "baseline_state")"
  tracker_state="$(ftctl_dr_runtime_state_get_from_path "${reverse_evidence_state_path}" "tracker_state")"
  writer_state="$(ftctl_dr_runtime_state_get_from_path "${reverse_evidence_state_path}" "writer_state")"
  target_written="$(ftctl_dr_runtime_state_get_from_path "${reverse_evidence_state_path}" "target_written")"
  write_verified="$(ftctl_dr_runtime_state_get_from_path "${reverse_evidence_state_path}" "write_verified")"
  reverse_guest_compatibility_state="$(ftctl_dr_runtime_state_get_from_path "${reverse_evidence_state_path}" "reverse_guest_compatibility_state")"
  reverse_evidence_checkpoint_path="$(ftctl_dr_runtime_state_get_from_path "${reverse_evidence_state_path}" "checkpoint_path")"
  [[ -n "${reverse_evidence_checkpoint_path}" ]] || reverse_evidence_checkpoint_path="${checkpoint_path}"
  if [[ -s "${reverse_evidence_checkpoint_path}" ]]; then
    [[ -n "${baseline_generation}" ]] || baseline_generation="$(jq -r '.baselineGeneration // empty' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    [[ -n "${baseline_state}" ]] || baseline_state="$(jq -r '.baselineState // empty' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    [[ -n "${tracker_state}" ]] || tracker_state="$(jq -r '.trackerState // empty' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    [[ -n "${writer_state}" ]] || writer_state="$(jq -r '.writerState // empty' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    [[ -n "${target_written}" ]] || target_written="$(jq -r 'if has("targetWritten") then .targetWritten else empty end' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    [[ -n "${write_verified}" ]] || write_verified="$(jq -r 'if has("writeVerified") then .writeVerified else empty end' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    reverse_evidence_checkpoint_plan="$(jq -r '.planUuid // empty' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    reverse_evidence_checkpoint_run="$(jq -r '.runUuid // empty' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    reverse_evidence_checkpoint_sequence="$(jq -r '.checkpointSequence // .baselineGeneration // empty' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
  fi
  for reverse_evidence_field in baseline_generation baseline_state tracker_state writer_state target_written write_verified reverse_guest_compatibility_state; do
    [[ -n "${!reverse_evidence_field}" ]] || reverse_evidence_missing_fields+=("${reverse_evidence_field}")
  done
  if [[ -n "${reverse_evidence_checkpoint_plan}" && "${reverse_evidence_checkpoint_plan}" != "${plan}" ]]; then
    reverse_evidence_state="INCONSISTENT"
  elif [[ -n "${reverse_evidence_checkpoint_run}" && "${reverse_evidence_checkpoint_run}" != "${reverse_evidence_run_uuid}" \
      && "${reverse_evidence_checkpoint_run}" != "${reverse_evidence_run_uuid}-failback" ]]; then
    reverse_evidence_state="INCONSISTENT"
  elif [[ -n "${reverse_evidence_checkpoint_sequence}" && -n "${baseline_generation}" \
      && "${reverse_evidence_checkpoint_sequence}" != "${baseline_generation}" ]]; then
    reverse_evidence_state="INCONSISTENT"
  elif (( ${#reverse_evidence_missing_fields[@]} > 0 )); then
    if [[ -s "${reverse_evidence_state_path}" || -s "${reverse_evidence_checkpoint_path}" ]]; then
      reverse_evidence_state="INCOMPLETE"
    else
      reverse_evidence_state="PENDING"
    fi
  elif [[ "${baseline_state}" != "LOCAL_DURABLE" || "${tracker_state}" != "LOCAL_DURABLE" \
      || "${writer_state}" != "DURABLE" || "${target_written}" != "true" || "${write_verified}" != "true" ]]; then
    reverse_evidence_state="NOT_DURABLE"
  else
    reverse_evidence_state="COMPLETE"
  fi
  target_vm_id="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_vm_id")"
  target_external_ref="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_external_ref")"
  dynamic_rpo="$(ftctl_dr_runtime_rpo_from_target_at "${last_target}" 2>/dev/null || true)"
  [[ -n "${dynamic_rpo}" ]] && target_rpo="${dynamic_rpo}"
  target_vm_present="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_vm_present")"
  [[ -n "${target_vm_present}" ]] || {
    if [[ -n "${target_vm_id}" || -n "${target_external_ref}" ]]; then
      target_vm_present="true"
    else
      target_vm_present="false"
    fi
  }
  target_storage_present="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_storage_present")"
  [[ -n "${target_storage_present}" ]] || {
    if [[ -n "${last_target}" || -n "${checkpoint_path}" || -n "${manifest_path}" \
        || -n "${latest_completed_target_durable_at}" || -n "${latest_completed_checkpoint_path}" \
        || -n "${latest_completed_manifest_path}" ]]; then
      target_storage_present="true"
    else
      target_storage_present="false"
    fi
  }
  restore_point_present="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "restore_point_present")"
  [[ -n "${restore_point_present}" ]] || {
    if [[ -n "${last_target}" || ( -n "${restore_points_path}" && -s "${restore_points_path}" ) ]]; then
      restore_point_present="true"
    else
      restore_point_present="false"
    fi
  }
  target_network_present="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_network_present")"
  [[ -n "${target_network_present}" ]] || target_network_present="${target_vm_present}"
  target_materialized="$(ftctl_dr_runtime_state_get_from_path "${state_path}" "target_materialized")"
  [[ -n "${target_materialized}" ]] || {
    if [[ "${target_vm_present}" == "true" && "${target_storage_present}" == "true" && "${target_network_present}" == "true" && "${restore_point_present}" == "true" ]]; then
      target_materialized="true"
    else
      target_materialized="false"
    fi
  }

  [[ -n "${run}" ]] && status_scope="OPERATION" || status_scope="PLAN_AUTHORITY"
  if [[ "${command}" == "dr-status" && "${status_scope}" == "OPERATION" && "${run_exists}" != "true" ]]; then
    printf '{"command":"%s","result":"run_not_found","plan_uuid":"%s","status_scope":"OPERATION","run_uuid":"%s","action":"dr-status","state":"QUEUED","step":"run-pending","progress":0,"external_job_ref":"%s","runtime_exists":%s,"profile_exists":%s,"run_exists":false,"accepted":false,"terminal_authoritative":false,"error_code":"not_found","error_message":"","events_offset":%s,"events":[],"exit_code":0}\n' \
      "$(ftctl__json_escape "${command}")" \
      "$(ftctl__json_escape "${plan}")" \
      "$(ftctl__json_escape "${run}")" \
      "$(ftctl__json_escape "${run}")" \
      "${runtime_exists}" "${profile_exists}" \
      "$(ftctl_dr_runtime_events_offset "${plan}")"
    return 0
  fi
  printf '{"command":"%s","result":"%s"' \
    "$(ftctl__json_escape "${command}")" \
    "$(ftctl__json_escape "${result}")"
  ftctl_dr_runtime_json_string_field "plan_uuid" "${plan}"
  ftctl_dr_runtime_json_string_field "status_scope" "${status_scope}"
  [[ -n "${run}" ]] && ftctl_dr_runtime_json_string_field "run_uuid" "${run}"
  ftctl_dr_runtime_json_string_field "action" "${action}"
  ftctl_dr_runtime_json_string_field "state" "${state:-PLANNED}"
  ftctl_dr_runtime_json_string_field "step" "${step:-planned}"
  ftctl_dr_runtime_json_number_field "progress" "${progress:-0}"
  ftctl_dr_runtime_json_string_field "external_job_ref" "${external_job_ref:-${run}}"
  printf ',"runtime_exists":%s,"profile_exists":%s,"run_exists":%s' "${runtime_exists}" "${profile_exists}" "${run_exists}"
  ftctl_dr_runtime_json_string_field "last_source_checkpoint_at" "${last_source}"
  ftctl_dr_runtime_json_string_field "last_target_durable_at" "${last_target}"
  ftctl_dr_runtime_json_number_field "target_ready_rpo_seconds" "${target_rpo}"
  ftctl_dr_runtime_json_number_field "target_rpo_seconds" "${policy_target_rpo_seconds}"
  ftctl_dr_runtime_json_string_field "scheduler_next_run_at" "${scheduler_next_run_at}"
  ftctl_dr_runtime_json_number_field "scheduler_execution_budget_seconds" "${scheduler_execution_budget_seconds}"
  ftctl_dr_runtime_json_number_field "scheduler_cycle_wall_duration_seconds" "${scheduler_cycle_wall_duration_seconds}"
  ftctl_dr_runtime_json_boolean_field "target_materialized" "${target_materialized}" || return $?
  ftctl_dr_runtime_json_boolean_field "target_vm_present" "${target_vm_present}" || return $?
  ftctl_dr_runtime_json_boolean_field "target_storage_present" "${target_storage_present}" || return $?
  ftctl_dr_runtime_json_boolean_field "target_network_present" "${target_network_present}" || return $?
  ftctl_dr_runtime_json_boolean_field "restore_point_present" "${restore_point_present}" || return $?
  ftctl_dr_runtime_json_string_field "target_vm_id" "${target_vm_id}"
  ftctl_dr_runtime_json_string_field "target_external_ref" "${target_external_ref}"
  ftctl_dr_runtime_json_string_field "source_firmware" "${source_firmware}"
  ftctl_dr_runtime_json_boolean_field "source_secure_boot" "${source_secure_boot}" || return $?
  ftctl_dr_runtime_json_number_field "source_boot_hardware_version" "1"
  printf ',"source_boot_hardware":%s' "$(ftctl_dr_runtime_boot_hardware "${profile_path:-}")"
  ftctl_dr_runtime_json_string_field "source_hardware_fingerprint" "${source_hardware_fingerprint}"
  ftctl_dr_runtime_json_string_field "source_hardware_fingerprint_version" "${source_hardware_fingerprint_version}"
  ftctl_dr_runtime_json_string_field "target_boot_type" "${target_boot_type}"
  ftctl_dr_runtime_json_string_field "target_boot_mode" "${target_boot_mode}"
  ftctl_dr_runtime_json_string_field "target_io_policy" "${target_io_policy}"
  ftctl_dr_runtime_json_boolean_field "target_iothreads" "${target_iothreads}" || return $?
  ftctl_dr_runtime_json_string_field "error_code" "${error_code}"
  ftctl_dr_runtime_json_string_field "error_message" "${error_message}"
  ftctl_dr_runtime_json_string_field "failed_component" "${failed_component}"
  ftctl_dr_runtime_json_string_field "data_commit_state" "${data_commit_state}"
  ftctl_dr_runtime_json_boolean_field "data_copied" "${data_copied}" || return $?
  ftctl_dr_runtime_json_boolean_field "metadata_committed" "${metadata_committed}" || return $?
  ftctl_dr_runtime_json_boolean_field "target_durable" "${target_durable}" || return $?
  ftctl_dr_runtime_json_string_field "cycle_retry_mode" "${cycle_retry_mode}"
  ftctl_dr_runtime_json_number_field "driver_exit_code" "${driver_exit_code}"
  ftctl_dr_runtime_json_string_field "updated_at" "${updated}"
  ftctl_dr_runtime_json_string_field "driver" "${driver}"
  ftctl_dr_runtime_json_string_field "driver_state" "${driver_state}"
  ftctl_dr_runtime_json_string_field "disk_map_path" "${disk_map_path}"
  ftctl_dr_runtime_json_string_field "source_disk_map_path" "${source_disk_map_path}"
  ftctl_dr_runtime_json_string_field "target_disk_map_path" "${target_disk_map_path}"
  ftctl_dr_runtime_json_string_field "disk_map_role" "${disk_map_role}"
  ftctl_dr_runtime_json_number_field "target_disk_count" "${target_disk_count}"
  ftctl_dr_runtime_json_number_field "target_disk_invalid_count" "${target_disk_invalid_count}"
  ftctl_dr_runtime_json_string_field "manifest_path" "${manifest_path}"
  ftctl_dr_runtime_json_string_field "checkpoint_path" "${checkpoint_path}"
  ftctl_dr_runtime_json_string_field "cbt_status_path" "${cbt_status_path}"
  ftctl_dr_runtime_json_file_field_redacted "cbt_status" "${cbt_status_path}"
  ftctl_dr_runtime_json_string_field "source_open_status_path" "${source_open_status_path}"
  ftctl_dr_runtime_json_file_field_redacted "source_open" "${source_open_status_path}"
  ftctl_dr_runtime_json_string_field "source_snapshot_status_path" "${source_snapshot_status_path}"
  ftctl_dr_runtime_json_file_field_redacted "source_snapshot" "${source_snapshot_status_path}"
  ftctl_dr_runtime_json_string_field "scheduler_state" "${scheduler_state}"
  ftctl_dr_runtime_json_number_field "runtime_generation" "${runtime_generation}"
  ftctl_dr_runtime_json_boolean_field "scheduler_pid_alive" "${scheduler_pid_alive}" || return $?
  ftctl_dr_runtime_json_string_field "scheduler_session_uuid" "${scheduler_session_uuid}"
  ftctl_dr_runtime_json_number_field "scheduler_lease_epoch" "${scheduler_lease_epoch}"
  ftctl_dr_runtime_json_number_field "authority_sequence" "${authority_sequence}"
  ftctl_dr_runtime_json_number_field "plan_cycle_sequence" "${plan_cycle_sequence}"
  ftctl_dr_runtime_json_number_field "resume_baseline_checkpoint_sequence" "${resume_baseline_checkpoint_sequence}"
  ftctl_dr_runtime_json_number_field "minimum_completed_checkpoint_sequence" "${minimum_completed_checkpoint_sequence}"
  ftctl_dr_runtime_json_boolean_field "immediate_cycle_pending" "${immediate_cycle_pending}" || return $?
  ftctl_dr_runtime_json_string_field "immediate_cycle_owner_run" "${immediate_cycle_owner_run}"
  ftctl_dr_runtime_json_string_field "scheduler_health" "${scheduler_health}"
  ftctl_dr_runtime_json_string_field "scheduler_desired_state" "${scheduler_desired_state}"
  ftctl_dr_runtime_json_string_field "scheduler_service_unit" "${scheduler_service_unit}"
  ftctl_dr_runtime_json_string_field "scheduler_unit_active_state" "${scheduler_unit_active_state}"
  ftctl_dr_runtime_json_string_field "scheduler_unit_sub_state" "${scheduler_unit_sub_state}"
  ftctl_dr_runtime_json_number_field "scheduler_unit_main_pid" "${scheduler_unit_main_pid}"
  ftctl_dr_runtime_json_string_field "scheduler_cgroup" "${scheduler_cgroup}"
  ftctl_dr_runtime_json_string_field "scheduler_recovery_state" "${scheduler_recovery_state}"
  ftctl_dr_runtime_json_string_field "scheduler_recovery_trigger" "${scheduler_recovery_trigger}"
  ftctl_dr_runtime_json_string_field "scheduler_recovered_at" "${scheduler_recovered_at}"
  ftctl_dr_runtime_json_string_field "nbd_teardown_state" "${nbd_teardown_state}"
  ftctl_dr_runtime_json_number_field "nbd_quarantined_device_count" "${nbd_quarantined_device_count}"
  ftctl_dr_runtime_json_string_field "nbd_teardown_error_code" "${nbd_teardown_error_code}"
  ftctl_dr_runtime_json_string_field "nbd_teardown_error_message" "${nbd_teardown_error_message}"
  if [[ -n "${nbd_capacity_json}" ]]; then
    printf ',"nbd_capacity":%s' "${nbd_capacity_json}"
    ftctl_dr_runtime_json_boolean_field "nbd_capacity_configured" "${nbd_capacity_configured}" || return $?
    ftctl_dr_runtime_json_boolean_field "nbd_capacity_ready" "${nbd_capacity_ready}" || return $?
    ftctl_dr_runtime_json_string_field "nbd_capacity_error_code" "${nbd_capacity_error_code}"
  fi
  ftctl_dr_runtime_json_string_field "replication_activity" "${replication_activity}"
  ftctl_dr_runtime_json_string_field "protection_state" "${protection_state}"
  ftctl_dr_runtime_json_string_field "resource_disposition" "${resource_disposition}"
  ftctl_dr_runtime_json_string_field "active_worker_run_uuid" "${active_worker_run_uuid}"
  ftctl_dr_runtime_json_number_field "active_worker_pid" "${active_worker_pid}"
  ftctl_dr_runtime_json_number_field "active_worker_start_ticks" "${active_worker_start_ticks}"
  ftctl_dr_runtime_json_string_field "worker_heartbeat_at" "${worker_heartbeat_at}"
  ftctl_dr_runtime_json_string_field "control_request_run_uuid" "${control_request_run_uuid}"
  ftctl_dr_runtime_json_boolean_field "owner_matched" "${owner_matched}" || return $?
  ftctl_dr_runtime_json_string_field "baseline_state" "${baseline_state}"
  ftctl_dr_runtime_json_number_field "reverse_evidence_contract_version" "${reverse_evidence_contract_version}"
  ftctl_dr_runtime_json_string_field "reverse_evidence_state" "${reverse_evidence_state}"
  ftctl_dr_runtime_json_string_field "reverse_evidence_run_uuid" "${reverse_evidence_run_uuid}"
  ftctl_dr_runtime_json_number_field "baseline_generation" "${baseline_generation}"
  ftctl_dr_runtime_json_string_field "tracker_state" "${tracker_state}"
  ftctl_dr_runtime_json_string_field "writer_state" "${writer_state}"
  ftctl_dr_runtime_json_boolean_field "target_written" "${target_written}" || return $?
  ftctl_dr_runtime_json_boolean_field "write_verified" "${write_verified}" || return $?
  # Readback claims require explicit evidence from this reverse checkpoint.
  local reverse_verification_method="" reverse_readback_verified="" reverse_readback_bytes=""
  if [[ -s "${reverse_evidence_checkpoint_path}" ]]; then
    reverse_verification_method="$(jq -r '.verificationMethod // .cycleMetrics.verificationMethod // empty' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    reverse_readback_verified="$(jq -r 'if .readbackVerified != null then .readbackVerified elif .cycleMetrics.readbackVerified != null then .cycleMetrics.readbackVerified else empty end' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
    reverse_readback_bytes="$(jq -r '.readbackVerifiedBytes // .cycleMetrics.readbackVerifiedBytes // empty' "${reverse_evidence_checkpoint_path}" 2>/dev/null || true)"
  fi
  local provenance_baseline="" provenance_sequence="" provenance_ref=""
  if command -v ftctl_dr_kvm_vmware_baseline_path >/dev/null 2>&1; then
    provenance_baseline="$(ftctl_dr_kvm_vmware_baseline_path "${plan}")"
    if [[ -s "${provenance_baseline}" ]]; then
      provenance_sequence="$(jq -r '.createdFromRestorePoint.checkpointSequence // empty' "${provenance_baseline}" 2>/dev/null || true)"
      provenance_ref="$(jq -r '.createdFromRestorePoint.checkpointRef // empty' "${provenance_baseline}" 2>/dev/null || true)"
    fi
  fi
  ftctl_dr_runtime_json_number_field "reverse_origin_checkpoint_sequence" "${provenance_sequence}"
  ftctl_dr_runtime_json_string_field "reverse_origin_checkpoint_ref" "${provenance_ref}"
  ftctl_dr_runtime_json_string_field "reverse_verification_method" "${reverse_verification_method}"
  ftctl_dr_runtime_json_boolean_field "reverse_readback_verified" "${reverse_readback_verified}" || return $?
  ftctl_dr_runtime_json_number_field "reverse_readback_verified_bytes" "${reverse_readback_bytes}"

  ftctl_dr_runtime_json_string_field "reverse_guest_compatibility_state" "${reverse_guest_compatibility_state}"
  printf ',"reverse_evidence_missing_fields":['
  reverse_evidence_first="true"
  for reverse_evidence_field in "${reverse_evidence_missing_fields[@]}"; do
    [[ "${reverse_evidence_first}" == "true" ]] || printf ','
    printf '"%s"' "$(ftctl__json_escape "${reverse_evidence_field}")"
    reverse_evidence_first="false"
  done
  printf ']'
  ftctl_dr_runtime_json_string_field "reseed_reason" "${reseed_reason}"
  ftctl_dr_runtime_json_number_field "consecutive_automatic_reseed_count" "${consecutive_automatic_reseed_count}"
  ftctl_dr_runtime_json_number_field "control_protocol_version" "${control_protocol_version}"
  ftctl_dr_runtime_json_number_field "control_generation" "${control_generation}"
  ftctl_dr_runtime_json_number_field "control_ack_generation" "${control_ack_generation}"
  ftctl_dr_runtime_json_string_field "control_state" "${control_state}"
  ftctl_dr_runtime_json_string_field "cycle_state" "${cycle_state}"
  ftctl_dr_runtime_json_string_field "transition_state" "${transition_state}"
  ftctl_dr_runtime_json_string_field "transition_action" "${transition_action}"
  ftctl_dr_runtime_json_string_field "transition_quiesced_at" "${transition_quiesced_at}"
  ftctl_dr_runtime_json_string_field "checkpoint_lease_state" "${checkpoint_lease_state}"
  ftctl_dr_runtime_json_string_field "checkpoint_lease_path" "${checkpoint_lease_path}"
  ftctl_dr_runtime_json_number_field "worker_pid" "${worker_pid}"
  ftctl_dr_runtime_json_number_field "worker_start_ticks" "${worker_start_ticks}"
  ftctl_dr_runtime_json_boolean_field "worker_pid_alive" "${worker_pid_alive}" || return $?
  ftctl_dr_runtime_json_string_field "worker_state" "${worker_state}"
  ftctl_dr_runtime_json_string_field "worker_started_at" "${worker_started_at}"
  ftctl_dr_runtime_json_string_field "worker_updated_at" "${worker_updated_at}"
  ftctl_dr_runtime_json_number_field "worker_exit_code" "${worker_exit_code}"
  ftctl_dr_runtime_json_string_field "worker_identity_state" "${worker_identity_state}"
  ftctl_dr_runtime_json_string_field "worker_liveness_state" "${worker_liveness_state}"
  ftctl_dr_runtime_json_string_field "worker_launch_nonce" "${worker_launch_nonce}"
  ftctl_dr_runtime_json_number_field "worker_generation" "${worker_generation}"
  ftctl_dr_runtime_json_string_field "transfer_activity_state" "${transfer_activity_state}"
  ftctl_dr_runtime_json_number_field "transfer_payload_bytes" "${transfer_payload_bytes}"
  ftctl_dr_runtime_json_number_field "transfer_progress_schema_version" "${transfer_progress_schema_version}"
  ftctl_dr_runtime_json_number_field "transfer_cycle_sequence" "${transfer_cycle_sequence}"
  ftctl_dr_runtime_json_number_field "transfer_sample_sequence" "${transfer_sample_sequence}"
  ftctl_dr_runtime_json_string_field "transfer_phase" "${transfer_phase}"
  ftctl_dr_runtime_json_string_field "transfer_plan_uuid" "${transfer_plan_uuid}"
  ftctl_dr_runtime_json_string_field "transfer_run_uuid" "${transfer_run_uuid}"
  ftctl_dr_runtime_json_string_field "transfer_direction" "${transfer_direction}"
  ftctl_dr_runtime_json_string_field "transfer_mode" "${transfer_mode}"
  ftctl_dr_runtime_json_number_field "transfer_bytes_total" "${transfer_bytes_total}"
  ftctl_dr_runtime_json_number_field "transfer_bytes_processed" "${transfer_bytes_processed}"
  ftctl_dr_runtime_json_number_field "transfer_source_read_bytes" "${transfer_source_read_bytes}"
  ftctl_dr_runtime_json_number_field "transfer_target_written_bytes" "${transfer_target_written_bytes}"
  ftctl_dr_runtime_json_number_field "transfer_verified_bytes" "${transfer_verified_bytes}"
  ftctl_dr_runtime_json_number_field "transfer_percent" "${transfer_percent}"
  ftctl_dr_runtime_json_number_field "transfer_throughput_bps" "${transfer_throughput_bps}"
  ftctl_dr_runtime_json_number_field "transfer_eta_seconds" "${transfer_eta_seconds}"
  ftctl_dr_runtime_json_number_field "transfer_current_disk_index" "${transfer_current_disk_index}"
  ftctl_dr_runtime_json_number_field "transfer_disk_count" "${transfer_disk_count}"
  ftctl_dr_runtime_json_boolean_field "transfer_progress_estimated" "${transfer_progress_estimated}" || return $?
  ftctl_dr_runtime_json_number_field "transfer_progress_sample_epoch_ms" "${transfer_progress_sample_epoch_ms}"
  ftctl_dr_runtime_json_boolean_field "transfer_progress_stale" "${transfer_progress_stale}" || return $?
  ftctl_dr_runtime_json_number_field "owned_process_count" "${owned_process_count}"
  ftctl_dr_runtime_json_boolean_field "reconciliation_required" "${reconciliation_required}" || return $?
  ftctl_dr_runtime_json_boolean_field "runtime_endpoints_drained" "${runtime_endpoints_drained}" || return $?
  ftctl_dr_runtime_json_string_field "terminal_source" "${terminal_source}"
  ftctl_dr_runtime_json_number_field "terminal_version" "${terminal_version}"
  ftctl_dr_runtime_json_boolean_field "terminal_authoritative" "${terminal_authoritative}" || return $?
  ftctl_dr_runtime_json_boolean_field "terminal_publication_pending" "${terminal_publication_pending}" || return $?
  ftctl_dr_runtime_json_string_field "terminal_publication_pending_since" "${terminal_publication_pending_since}"
  ftctl_dr_runtime_json_boolean_field "retryable" "${retryable}" || return $?
  ftctl_dr_runtime_json_number_field "retry_after_sec" "${retry_after_sec}"
  ftctl_dr_runtime_json_string_field "lock_file" "${lock_file}"
  ftctl_dr_runtime_json_number_field "holder_pid" "${holder_pid}"
  ftctl_dr_runtime_json_string_field "holder_command" "${holder_command}"
  ftctl_dr_runtime_json_number_field "holder_age_sec" "${holder_age_sec}"
  ftctl_dr_runtime_json_number_field "checkpoint_sequence" "${checkpoint_sequence}"
  ftctl_dr_runtime_json_number_field "current_checkpoint_sequence" "${current_checkpoint_sequence}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_cycle_type" "${current_checkpoint_cycle_type}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_requested_mode" "${current_checkpoint_requested_mode}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_effective_mode" "${current_checkpoint_effective_mode}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_mode_decision_code" "${current_checkpoint_mode_decision_code}"
  ftctl_dr_runtime_json_boolean_field "current_checkpoint_automatic_reseed" "${current_checkpoint_automatic_reseed:-false}" || return $?
  ftctl_dr_runtime_json_number_field "current_checkpoint_invalid_baseline_disk_count" "${current_checkpoint_invalid_baseline_disk_count}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_ref" "${current_checkpoint_ref}"
  ftctl_dr_runtime_json_string_field "current_checkpoint_state" "${current_checkpoint_state}"
  ftctl_dr_runtime_json_string_field "immutable_checkpoint_ref" "$(jq -r '.contract.checkpointRef // empty' "$(ftctl_dr_checkpoint_committed_path "${plan}")" 2>/dev/null || true)"
  ftctl_dr_runtime_json_string_field "immutable_checkpoint_manifest_sha256" "$(jq -r '.manifestSha256 // empty' "$(ftctl_dr_checkpoint_committed_path "${plan}")" 2>/dev/null || true)"
  ftctl_dr_runtime_json_string_field "checkpoint_publication_pending" "$(cat "$(ftctl_dr_checkpoint_pending_path "${plan}")" 2>/dev/null || true)"
  ftctl_dr_runtime_json_number_field "latest_completed_checkpoint_sequence" "${latest_completed_checkpoint_sequence}"
  ftctl_dr_runtime_json_number_field "latest_completed_cycle_sequence" "${latest_completed_checkpoint_sequence}"
  ftctl_dr_runtime_json_string_field "latest_completed_checkpoint_cycle_type" "${latest_completed_checkpoint_cycle_type}"
  ftctl_dr_runtime_json_string_field "latest_completed_checkpoint_ref" "${latest_completed_checkpoint_ref}"
  ftctl_dr_runtime_json_string_field "latest_completed_checkpoint_state" "${latest_completed_checkpoint_state}"
  ftctl_dr_runtime_json_string_field "latest_completed_producer_run_uuid" "${latest_completed_producer_run_uuid}"
  ftctl_dr_runtime_json_string_field "latest_completed_source_checkpoint_at" "${latest_completed_source_checkpoint_at}"
  ftctl_dr_runtime_json_string_field "latest_completed_target_durable_at" "${latest_completed_target_durable_at}"
  ftctl_dr_runtime_json_number_field "latest_completed_target_ready_rpo_seconds" "${latest_completed_target_ready_rpo_seconds}"
  ftctl_dr_runtime_json_string_field "latest_completed_manifest_path" "${latest_completed_manifest_path}"
  ftctl_dr_runtime_json_string_field "latest_completed_checkpoint_path" "${latest_completed_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "latest_completed_requested_mode" "${latest_completed_requested_mode}"
  ftctl_dr_runtime_json_string_field "latest_completed_effective_mode" "${latest_completed_effective_mode}"
  ftctl_dr_runtime_json_string_field "latest_completed_mode_decision_code" "${latest_completed_mode_decision_code}"
  ftctl_dr_runtime_json_string_field "latest_completed_reseed_reason" "${latest_completed_reseed_reason}"
  ftctl_dr_runtime_json_boolean_field "latest_completed_automatic_reseed" "${latest_completed_automatic_reseed:-false}" || return $?
  ftctl_dr_runtime_json_number_field "latest_completed_invalid_baseline_disk_count" "${latest_completed_invalid_baseline_disk_count}"
  ftctl_dr_runtime_json_boolean_field "latest_completed_incremental_verified" "${latest_completed_incremental_verified}" || return $?
  ftctl_dr_runtime_json_boolean_field "latest_completed_metrics_estimated" "${latest_completed_metrics_estimated}" || return $?
  ftctl_dr_runtime_json_number_field "latest_completed_virtual_bytes" "${latest_completed_virtual_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_changed_bytes" "${latest_completed_changed_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_source_read_bytes" "${latest_completed_source_read_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_target_written_bytes" "${latest_completed_target_written_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_transfer_payload_bytes" "${latest_completed_transfer_payload_bytes}"
  ftctl_dr_runtime_json_number_field "latest_completed_changed_extent_count" "${latest_completed_changed_extent_count}"
  ftctl_dr_runtime_json_number_field "latest_completed_duration_ms" "${latest_completed_duration_ms}"
  ftctl_dr_runtime_json_number_field "latest_completed_throughput_bps" "${latest_completed_throughput_bps}"
  ftctl_dr_runtime_json_number_field "latest_completed_baseline_generation" "${latest_completed_baseline_generation}"
  ftctl_dr_runtime_json_string_field "latest_completed_cycle_token" "${latest_completed_cycle_token}"
  ftctl_dr_runtime_json_string_field "latest_completed_cycle_metrics_path" "${latest_completed_cycle_metrics_path}"
  ftctl_dr_runtime_json_string_field "latest_completed_nbd_teardown_state" "${latest_completed_nbd_teardown_state}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_teardown_started_at_ms" "${latest_completed_nbd_teardown_started_at_ms}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_teardown_completed_at_ms" "${latest_completed_nbd_teardown_completed_at_ms}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_teardown_duration_ms" "${latest_completed_nbd_teardown_duration_ms}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_source_device_count" "${latest_completed_nbd_source_device_count}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_target_device_count" "${latest_completed_nbd_target_device_count}"
  ftctl_dr_runtime_json_number_field "latest_completed_nbd_quarantined_device_count" "${latest_completed_nbd_quarantined_device_count}"
  ftctl_dr_runtime_json_string_field "latest_completed_nbd_teardown_error_code" "${latest_completed_nbd_teardown_error_code}"
  ftctl_dr_runtime_json_string_field "latest_completed_nbd_teardown_error_message" "${latest_completed_nbd_teardown_error_message}"
  ftctl_dr_runtime_json_file_field_redacted "latest_completed_cycle_metrics" "${latest_completed_cycle_metrics_path}"
  ftctl_dr_runtime_json_string_field "restore_points_path" "${restore_points_path}"
  ftctl_dr_runtime_json_string_field "test_session_id" "${test_session_id}"
  ftctl_dr_runtime_json_string_field "test_session_path" "${test_session_path}"
  ftctl_dr_runtime_json_file_field_redacted "test_session" "${test_session_path}"
  ftctl_dr_runtime_json_string_field "test_session_state" "${test_session_state}"
  ftctl_dr_runtime_json_string_field "test_restore_point_ref" "${test_restore_point_ref}"
  ftctl_dr_runtime_json_number_field "test_restore_point_sequence" "${test_restore_point_sequence}"
  ftctl_dr_runtime_json_string_field "test_manifest_path" "${test_manifest_path}"
  ftctl_dr_runtime_json_string_field "test_checkpoint_path" "${test_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "test_artifacts_state" "${test_artifacts_state}"
  ftctl_dr_runtime_json_string_field "test_artifacts_path" "${test_artifacts_path}"
  ftctl_dr_runtime_json_number_field "test_artifact_count" "${test_artifact_count}"
  ftctl_dr_runtime_json_string_field "test_cleanup_state" "${test_cleanup_state}"
  ftctl_dr_runtime_json_boolean_field "cleanup_required" "${cleanup_required:-false}" || return $?
  ftctl_dr_runtime_json_string_field "guest_preflight_state" "${guest_preflight_state}"
  ftctl_dr_runtime_json_string_field "guest_preflight_error_code" "${guest_preflight_error_code}"
  ftctl_dr_runtime_json_string_field "guest_preflight_error_message" "${guest_preflight_error_message}"
  ftctl_dr_runtime_json_string_field "guest_prep_state" "${guest_prep_state}"
  ftctl_dr_runtime_json_string_field "guest_family" "${guest_family}"
  ftctl_dr_runtime_json_string_field "guestprep_manifest_path" "${guestprep_manifest_path}"
  ftctl_dr_runtime_json_string_field "manifest_schema_version" "${manifest_schema_version}"
  ftctl_dr_runtime_json_string_field "manifest_sha256" "${manifest_sha256}"
  ftctl_dr_runtime_json_number_field "guestprep_checkpoint_sequence" "${guestprep_checkpoint_sequence}"
  ftctl_dr_runtime_json_string_field "source_fence_state" "${source_fence_state}"
  ftctl_dr_runtime_json_string_field "scheduler_recovery_state" "${scheduler_recovery_state}"
  ftctl_dr_runtime_json_string_field "source_runtime_quiesce_state" "${source_runtime_quiesce_state}"
  ftctl_dr_runtime_json_string_field "source_runtime_quiesce_mode" "${source_runtime_quiesce_mode}"
  ftctl_dr_runtime_json_string_field "source_runtime_quiesce_owner_run" "${source_runtime_quiesce_owner_run}"
  ftctl_dr_runtime_json_string_field "source_runtime_quiesced_at" "${source_runtime_quiesced_at}"
  ftctl_dr_runtime_json_string_field "source_runtime_quiesce_released_at" "${source_runtime_quiesce_released_at}"
  ftctl_dr_runtime_json_string_field "cutover_source_disk_map_path" "${cutover_source_disk_map_path}"
  ftctl_dr_runtime_json_string_field "cutover_source_disk_map_sha256" "${cutover_source_disk_map_sha256}"
  ftctl_dr_runtime_json_string_field "test_domain_name" "${test_domain_name}"
  ftctl_dr_runtime_json_string_field "test_domain_state" "${test_domain_state}"
  ftctl_dr_runtime_json_string_field "test_boot_validation_mode" "${test_boot_validation_mode}"
  ftctl_dr_runtime_json_string_field "failover_session_id" "${failover_session_id}"
  ftctl_dr_runtime_json_string_field "failover_mode" "${failover_mode}"
  ftctl_dr_runtime_json_string_field "failover_restore_point_ref" "${failover_restore_point_ref}"
  ftctl_dr_runtime_json_number_field "failover_restore_point_sequence" "${failover_restore_point_sequence}"
  ftctl_dr_runtime_json_string_field "failover_manifest_path" "${failover_manifest_path}"
  ftctl_dr_runtime_json_string_field "failover_checkpoint_path" "${failover_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "failover_requested_at" "${failover_requested_at}"
  ftctl_dr_runtime_json_string_field "restore_point_locked_at" "${restore_point_locked_at}"
  ftctl_dr_runtime_json_string_field "target_promote_started_at" "${target_promote_started_at}"
  ftctl_dr_runtime_json_string_field "target_power_on_at" "${target_power_on_at}"
  ftctl_dr_runtime_json_string_field "failover_completed_at" "${failover_completed_at}"
  ftctl_dr_runtime_json_number_field "rto_actual_seconds" "${rto_actual_seconds}"
  ftctl_dr_runtime_json_string_field "active_side" "${active_side}"
  ftctl_dr_runtime_json_string_field "target_power_state" "${target_power_state}"
  ftctl_dr_runtime_json_string_field "target_promotion_state" "${target_promotion_state}"
  ftctl_dr_runtime_json_string_field "boot_validation_state" "${boot_validation_state}"
  ftctl_dr_runtime_json_string_field "cloud_cutover_session_id" "${cloud_cutover_session_id}"
  ftctl_dr_runtime_json_number_field "cloud_authority_generation" "${cloud_authority_generation}"
  ftctl_dr_runtime_json_number_field "cloud_authority_sequence_floor" "${cloud_authority_sequence_floor}"
  ftctl_dr_runtime_json_string_field "engine_ack_state" "${engine_ack_state}"
  ftctl_dr_runtime_json_string_field "engine_ack_at" "${engine_ack_at}"
  ftctl_dr_runtime_json_number_field "failover_worker_pid" "${failover_worker_pid}"
  ftctl_dr_runtime_json_string_field "failback_session_id" "${failback_session_id}"
  ftctl_dr_runtime_json_string_field "failback_mode" "${failback_mode}"
  ftctl_dr_runtime_json_string_field "failback_phase" "${failback_phase}"
  ftctl_dr_runtime_json_string_field "failure_phase" "${failure_phase}"
  ftctl_dr_runtime_json_string_field "baseline_file_state" "${baseline_file_state}"
  ftctl_dr_runtime_json_string_field "source_disk_probe_state" "${source_disk_probe_state}"
  ftctl_dr_runtime_json_number_field "source_disk_count" "${source_disk_count}"
  ftctl_dr_runtime_json_string_field "target_writer_probe_state" "${target_writer_probe_state}"
  ftctl_dr_runtime_json_string_field "operation_intent" "${operation_intent}"
  ftctl_dr_runtime_json_string_field "requested_mode" "${requested_mode}"
  ftctl_dr_runtime_json_string_field "effective_mode" "${effective_mode}"
  ftctl_dr_runtime_json_string_field "mode_decision_code" "${mode_decision_code}"
  ftctl_dr_runtime_json_boolean_field "initial_seed_required" "${initial_seed_required:-false}" || return $?
  ftctl_dr_runtime_json_number_field "estimated_virtual_bytes" "${estimated_virtual_bytes}"
  ftctl_dr_runtime_json_string_field "cloud_lifecycle_state" "${cloud_lifecycle_state}"
  ftctl_dr_runtime_json_string_field "failback_commit_outcome" "${failback_commit_outcome}"
  ftctl_dr_runtime_json_string_field "failback_commit_phase" "${failback_commit_phase}"
  ftctl_dr_runtime_json_string_field "failback_commit_contract_version" "${failback_commit_contract_version}"
  ftctl_dr_runtime_json_string_field "failback_commit_attempt_id" "${failback_commit_attempt_id}"
  ftctl_dr_runtime_json_string_field "failback_commit_envelope_sha256" "${failback_commit_envelope_sha256}"
  ftctl_dr_runtime_json_string_field "failback_commit_dispatch_state" "${failback_commit_dispatch_state}"
  ftctl_dr_runtime_json_string_field "rollback_state" "${rollback_state}"
  ftctl_dr_runtime_json_number_field "rollback_generation" "${rollback_generation}"
  ftctl_dr_runtime_json_string_field "failback_restore_point_ref" "${failback_restore_point_ref}"
  ftctl_dr_runtime_json_number_field "failback_restore_point_sequence" "${failback_restore_point_sequence}"
  ftctl_dr_runtime_json_string_field "failback_manifest_path" "${failback_manifest_path}"
  ftctl_dr_runtime_json_string_field "failback_checkpoint_path" "${failback_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "failback_requested_at" "${failback_requested_at}"
  ftctl_dr_runtime_json_string_field "reverse_sync_started_at" "${reverse_sync_started_at}"
  ftctl_dr_runtime_json_string_field "reverse_target_ready_at" "${reverse_target_ready_at}"
  ftctl_dr_runtime_json_string_field "source_promote_started_at" "${source_promote_started_at}"
  ftctl_dr_runtime_json_string_field "source_power_on_at" "${source_power_on_at}"
  ftctl_dr_runtime_json_string_field "failback_completed_at" "${failback_completed_at}"
  ftctl_dr_runtime_json_number_field "failback_rto_actual_seconds" "${failback_rto_actual_seconds}"
  ftctl_dr_runtime_json_number_field "post_failback_checkpoint_sequence" "${post_failback_checkpoint_sequence}"
  ftctl_dr_runtime_json_string_field "source_power_state" "${source_power_state}"
  ftctl_dr_runtime_json_string_field "source_promotion_state" "${source_promotion_state}"
  ftctl_dr_runtime_json_number_field "failback_worker_pid" "${failback_worker_pid}"
  ftctl_dr_runtime_json_string_field "reprotect_session_id" "${reprotect_session_id}"
  ftctl_dr_runtime_json_string_field "reprotect_mode" "${reprotect_mode}"
  ftctl_dr_runtime_json_string_field "reprotect_restore_point_ref" "${reprotect_restore_point_ref}"
  ftctl_dr_runtime_json_number_field "reprotect_restore_point_sequence" "${reprotect_restore_point_sequence}"
  ftctl_dr_runtime_json_string_field "reprotect_manifest_path" "${reprotect_manifest_path}"
  ftctl_dr_runtime_json_string_field "reprotect_checkpoint_path" "${reprotect_checkpoint_path}"
  ftctl_dr_runtime_json_string_field "reprotect_requested_at" "${reprotect_requested_at}"
  ftctl_dr_runtime_json_string_field "reprotect_completed_at" "${reprotect_completed_at}"
  ftctl_dr_runtime_json_number_field "reprotect_rto_actual_seconds" "${reprotect_rto_actual_seconds}"
  ftctl_dr_runtime_json_number_field "route_contract_version" "${route_contract_version}"
  ftctl_dr_runtime_json_string_field "replication_direction" "${replication_direction}"
  ftctl_dr_runtime_json_string_field "reverse_direction" "${reverse_direction}"
  ftctl_dr_runtime_json_string_field "provider_pair" "${provider_pair}"
  ftctl_dr_runtime_json_string_field "reverse_profile_path" "${reverse_profile_path}"
  ftctl_dr_runtime_json_string_field "reverse_restore_points_path" "${reverse_restore_points_path}"
  ftctl_dr_runtime_json_number_field "reprotect_worker_pid" "${reprotect_worker_pid}"
  if [[ "${accepted}" == "false" ]]; then
    printf ',"accepted":false'
  else
    printf ',"accepted":true'
  fi
  ftctl_dr_runtime_emit_events_since "${plan}" "${events_offset}" "${events_limit:-20}"
  printf ',"exit_code":0}\n'
  ftctl_dr_runtime_state_snapshot_end
}

ftctl_dr_runtime_emit_error_json() {
  local command="${1-}" plan="${2-}" run="${3-}" error_code="${4-}" message="${5-}" rc="${6-10}"
  printf '{"command":"%s","result":"error","plan_uuid":"%s"' \
    "$(ftctl__json_escape "${command}")" \
    "$(ftctl__json_escape "${plan}")"
  [[ -n "${run}" ]] && printf ',"run_uuid":"%s"' "$(ftctl__json_escape "${run}")"
  printf ',"accepted":false,"state":"ERROR","step":"error","progress":100,"error_code":"%s","message":"%s","exit_code":%s}\n' \
    "$(ftctl__json_escape "${error_code}")" \
    "$(ftctl__json_escape "${message}")" \
    "${rc}"
}

ftctl_dr_runtime_write_state() {
  local path="${1-}" plan="${2-}" run="${3-}" action="${4-}" state="${5-}" step="${6-}" progress="${7-}" external_ref="${8-}" error_code="${9-}"
  local now
  now="$(ftctl_now_iso8601)"
  ftctl_ensure_dir "$(dirname "${path}")" "0755"
  ftctl_state_write_kv_all "${path}" \
    "plan=${plan}" \
    "run=${run}" \
    "action=${action}" \
    "state=${state}" \
    "step=${step}" \
    "progress=${progress}" \
    "accepted=true" \
    "external_job_ref=${external_ref}" \
    "last_source_checkpoint_at=${now}" \
    "last_target_durable_at=" \
    "target_ready_rpo_seconds=" \
    "error_code=${error_code}" \
    "updated_at=${now}"
}

ftctl_dr_runtime_action_state() {
  local action="${1-}"
  case "${action}" in
    dr-sync-start) printf 'SYNCING|sync-start-accepted|1\n' ;;
    dr-sync-recover) printf 'SYNCING|scheduler-recovery-accepted|1\n' ;;
    dr-sync-pause) printf 'PAUSED|sync-paused|100\n' ;;
    dr-sync-resume) printf 'SYNCING|sync-resumed|1\n' ;;
    dr-test-failover) printf 'TESTING|test-failover-accepted|1\n' ;;
    dr-test-prepare) printf 'TESTING|test-artifact-prepare-accepted|1\n' ;;
    dr-test-cleanup|dr-test-artifact-cleanup) printf 'READY|test-cleanup-completed|100\n' ;;
    dr-failover) printf 'RUNNING|failover-accepted|1\n' ;;
    dr-failback) printf 'RUNNING|failback-accepted|1\n' ;;
    dr-reprotect) printf 'RUNNING|reprotect-accepted|1\n' ;;
    dr-release) printf 'RELEASED|release-completed|100\n' ;;
    *) printf 'RUNNING|accepted|1\n' ;;
  esac
}

ftctl_dr_runtime_require_plan() {
  local plan="${1-}"
  [[ -n "${plan}" ]] || {
    echo "ERROR: --plan is required" >&2
    return 2
  }
}

ftctl_dr_runtime_require_run() {
  local run="${1-}"
  [[ -n "${run}" ]] || {
    echo "ERROR: --run is required" >&2
    return 2
  }
}

ftctl_dr_runtime_plan_apply() {
  local plan="${1-}" profile_file="${2-}" role="${3-}" dry_run="${4-0}" json="${5-0}"
  local profile_plan direction now status_path capable error_code details_json vmware_capable
  local source_provider target_provider nbd_capacity_json="" nbd_capacity_configured=""

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_validate_profile_file "${profile_file}" || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-plan-apply" "${plan}" "" "profile_invalid" "profile JSON is missing or invalid" 2
    return 2
  }

  profile_plan="$(ftctl_dr_runtime_profile_value "${profile_file}" "planUuid" || true)"
  direction="$(ftctl_dr_runtime_profile_value "${profile_file}" "direction" || true)"
  if [[ -n "${profile_plan}" && "${profile_plan}" != "${plan}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-plan-apply" "${plan}" "" "plan_mismatch" "profile planUuid does not match --plan" 2
    return 2
  fi

  capable="true"
  error_code=""
  details_json=""
  if command -v ftctl_dr_vmware_preflight_json >/dev/null 2>&1 &&
      ftctl_dr_vmware_profile_involves_vmware "${profile_file}"; then
    details_json="$(ftctl_dr_vmware_preflight_json "${plan}" "${profile_file}" "${role}" "${dry_run}")"
    vmware_capable="$(ftctl_dr_runtime_json_text_value "${details_json}" "capable")"
    if [[ "${vmware_capable}" != "true" ]]; then
      capable="false"
      error_code="$(ftctl_dr_runtime_json_text_value "${details_json}" "error_code")"
      [[ -n "${error_code}" ]] || error_code="DR_VMWARE_PREFLIGHT_FAILED"
    fi
  fi
  source_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" source)"
  target_provider="$(ftctl_dr_scheduler_profile_provider "${profile_file}" target)"
  if [[ "${source_provider}" == "VMWARE" && ( "${target_provider}" == "ABLESTACK" || "${target_provider}" == "KVM" ) ]]; then
    nbd_capacity_json="$(ftctl_vmware_mover_nbd_capacity_json)"
    nbd_capacity_configured="$(ftctl_dr_runtime_json_text_value "${nbd_capacity_json}" "configured")"
    if [[ "${nbd_capacity_configured}" != "true" ]]; then
      capable="false"
      error_code="DR_NBD_CAPACITY_INVALID"
    fi
  fi

  if [[ "${dry_run}" != "1" && "${capable}" == "true" ]]; then
    ftctl_dr_runtime_save_profile "${plan}" "${profile_file}" || return $?
    ftctl_dr_runtime_record_worker_role "${plan}" "${role}" || return $?
    now="$(ftctl_now_iso8601)"
    status_path="$(ftctl_dr_runtime_status_path "${plan}")"
    ftctl_state_write_kv_all "${status_path}" \
      "plan=${plan}" \
      "run=" \
      "action=dr-plan-apply" \
      "state=PLANNED" \
      "step=profile-applied" \
      "progress=0" \
      "accepted=true" \
      "external_job_ref=" \
      "last_source_checkpoint_at=" \
      "last_target_durable_at=" \
      "target_ready_rpo_seconds=" \
      "error_code=" \
      "updated_at=${now}"
    ftctl_log_event "dr-runtime" "dr.plan.apply" "ok" "" "" \
      "plan=${plan} role=${role:-} direction=${direction:-} dry_run=0"
  elif [[ "${dry_run}" != "1" ]]; then
    ftctl_log_event "dr-runtime" "dr.plan.apply" "fail" "" "${error_code}" \
      "plan=${plan} role=${role:-} direction=${direction:-} dry_run=0 capable=false"
  else
    if [[ "${capable}" == "true" ]]; then
      ftctl_log_event "dr-runtime" "dr.plan.apply" "ok" "" "" \
        "plan=${plan} role=${role:-} direction=${direction:-} dry_run=1"
    else
      ftctl_log_event "dr-runtime" "dr.plan.apply" "fail" "" "${error_code}" \
        "plan=${plan} role=${role:-} direction=${direction:-} dry_run=1 capable=false"
    fi
  fi

  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-plan-apply","result":"ok","capable":%s,"plan_uuid":"%s","role":"%s","direction":"%s","dry_run":%s' \
      "${capable}" \
      "$(ftctl__json_escape "${plan}")" \
      "$(ftctl__json_escape "${role}")" \
      "$(ftctl__json_escape "${direction}")" \
      "$([[ "${dry_run}" == "1" ]] && printf true || printf false)"
    [[ -n "${error_code}" ]] && ftctl_dr_runtime_json_string_field "error_code" "${error_code}"
    [[ -n "${details_json}" ]] && printf ',"details":%s' "${details_json}"
    [[ -n "${nbd_capacity_json}" ]] && printf ',"nbd_capacity":%s' "${nbd_capacity_json}"
    printf ',"exit_code":0}\n'
  else
    if [[ -n "${error_code}" ]]; then
      printf 'dr-plan-apply: %s capable=%s direction=%s error=%s\n' "${plan}" "${capable}" "${direction:-unknown}" "${error_code}"
    else
      printf 'dr-plan-apply: %s capable=%s direction=%s\n' "${plan}" "${capable}" "${direction:-unknown}"
    fi
  fi
}

ftctl_dr_runtime_run_log_path() {
  local plan="${1-}" run="${2-}"
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  printf '%s/runs/%s.log' "$(ftctl_dr_runtime_plan_dir "${plan}")" "${run}"
}

ftctl_dr_runtime_should_delegate_action() {
  local action="${1-}" wait_value="${2-}" dry_run="${3-0}"
  local wait_lower

  [[ "${dry_run}" != "1" ]] || return 1
  [[ "${FTCTL_DR_RUNTIME_WORKER:-0}" != "1" ]] || return 1
  case "${action}" in
    dr-sync-start)
      [[ "${FTCTL_DR_SYNC_FOREGROUND:-0}" != "1" ]] || return 1
      [[ "${FTCTL_DR_SCHEDULER_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-test-failover|dr-test-prepare)
      [[ "${FTCTL_DR_TEST_FAILOVER_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-failover)
      [[ "${FTCTL_DR_FAILOVER_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-failback)
      [[ "${FTCTL_DR_FAILBACK_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-reprotect)
      [[ "${FTCTL_DR_REPROTECT_FOREGROUND:-0}" != "1" ]] || return 1
      ;;
    dr-sync-pause|dr-sync-resume|dr-test-cleanup|dr-test-artifact-cleanup|dr-release)
      ;;
  esac
  wait_lower="$(printf '%s' "${wait_value}" | tr '[:upper:]' '[:lower:]')"
  [[ "${wait_lower}" == "false" || "${wait_lower}" == "0" || "${wait_lower}" == "no" ]] || return 1

  case "${action}" in
    dr-sync-start|dr-sync-recover|dr-sync-pause|dr-sync-resume|dr-test-failover|dr-test-prepare|dr-test-cleanup|dr-test-artifact-cleanup|dr-failover|dr-failback|dr-reprotect|dr-release) return 0 ;;
    *) return 1 ;;
  esac
}

ftctl_dr_runtime_start_background_worker() {
  local action="${1-}" plan="${2-}" run="${3-}" role="${4-}" mode="${5-}" restore_point="${6-}" force="${7-0}" dry_run="${8-0}" artifact_spec_path="${9-}" authority_spec_path="${10-}" log_path ftctl_bin profile_path
  local run_path status_path now worker_pid
  local -a worker_cmd

  log_path="$(ftctl_dr_runtime_run_log_path "${plan}" "${run}")"
  profile_path="$(ftctl_dr_runtime_profile_path "${plan}")"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=STARTING" \
    "worker_pid=" \
    "worker_started_at=${now}" \
    "worker_updated_at=${now}" \
    "worker_exit_code=" \
    "retryable=false" \
    "retry_after_sec=" \
    "lock_file=" \
    "holder_pid=" \
    "holder_command=" \
    "holder_age_sec=" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_bin="${FTCTL_DR_RUNTIME_WORKER_COMMAND:-$(command -v ablestack_vm_ftctl 2>/dev/null || true)}"
  [[ -n "${ftctl_bin}" ]] || ftctl_bin="${0}"
  worker_cmd=("${ftctl_bin}" "${action}" "--plan" "${plan}" "--run" "${run}" "--profile-json" "${profile_path}" "--role" "${role:-coordinator}")
  [[ -n "${FTCTL_CONFIG_PATH:-}" ]] && worker_cmd+=("--config" "${FTCTL_CONFIG_PATH}")
  [[ -n "${mode}" ]] && worker_cmd+=("--mode" "${mode}")
  [[ -n "${restore_point}" ]] && worker_cmd+=("--restore-point" "${restore_point}")
  [[ -n "${artifact_spec_path}" && -f "${artifact_spec_path}" ]] && worker_cmd+=("--artifact-spec-json" "${artifact_spec_path}")
  [[ -n "${authority_spec_path}" && -f "${authority_spec_path}" ]] && worker_cmd+=("--authority-spec-json" "${authority_spec_path}")
  [[ "${force}" == "1" ]] && worker_cmd+=("--force")
  [[ "${dry_run}" == "1" ]] && worker_cmd+=("--dry-run")
  worker_cmd+=("--wait=true" "--json")

  (
    export FTCTL_DR_RUNTIME_WORKER=1
    exec nohup "${worker_cmd[@]}" >>"${log_path}" 2>&1
  ) >/dev/null 2>&1 &
  worker_pid="$!"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=STARTED" \
    "worker_pid=${worker_pid}" \
    "worker_updated_at=${now}" || true
  cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  chmod 0644 "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_mark_worker_terminal() {
  local run_path="${1-}" status_path="${2-}" state="${3-}" exit_code="${4-0}" error_code="${5-}" retryable="${6-false}" retry_after="${7-}"
  local now

  [[ "${FTCTL_DR_RUNTIME_WORKER:-0}" == "1" && -n "${run_path}" && -f "${run_path}" ]] || return 0
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "worker_state=${state}" \
    "worker_pid=$$" \
    "worker_exit_code=${exit_code}" \
    "worker_updated_at=${now}" \
    "retryable=${retryable}" \
    "retry_after_sec=${retry_after}" \
    "error_code=${error_code}" || true
  [[ -n "${status_path}" ]] && cp -f "${run_path}" "${status_path}" 2>/dev/null || true
  [[ -n "${status_path}" ]] && chmod 0644 "${status_path}" 2>/dev/null || true
}

ftctl_dr_runtime_action() {
  local action="${1-}" plan="${2-}" run="${3-}" profile_file="${4-}" role="${5-}" mode="${6-}" restore_point="${7-}" force="${8-0}" dry_run="${9-0}" wait_value="${10-}" json="${11-0}" artifact_spec_file="${12-}" authority_spec_file="${13-}"
  local force_immediate_cycle="${14-false}"
  local authority_sequence_floor="${15-}"
  local resume_baseline_checkpoint_sequence="${16-}"
  local minimum_completed_checkpoint_sequence="${17-}"
  local state_tuple state step progress run_path status_path external_ref rc error_code error_message
  local target_vm_id target_external_ref checkpoint_lease_path test_sequence persisted_artifact_spec="" persisted_authority_spec=""
  local release_authority_side="" release_authority_generation="" release_resource_disposition="RETAIN_OPERATIONAL_VM"
  local remote_source_transition=0

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  if [[ -n "${authority_sequence_floor}" && ! "${authority_sequence_floor}" =~ ^[0-9]+$ ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" \
      "authority_sequence_floor_invalid" "authority sequence floor must be a non-negative integer" 2
    return 2
  fi
  if [[ "${authority_sequence_floor}" =~ ^[0-9]+$ ]]; then
    ftctl_dr_scheduler_floor_authority_sequence "${plan}" "${authority_sequence_floor}" >/dev/null || return $?
  fi
  if [[ -n "${profile_file}" ]]; then
    ftctl_dr_runtime_save_profile "${plan}" "${profile_file}" || {
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" "profile_invalid" "profile JSON is missing or invalid" 2
      return 2
    }
    [[ "${dry_run}" == "1" ]] || ftctl_dr_runtime_record_worker_role "${plan}" "${role}" || return $?
    if [[ "${dry_run}" != "1" && ( "${action}" == "dr-sync-start" || "${action}" == "dr-sync-recover" ) && ( "${role}" == "source" || "${role}" == "coordinator" ) ]]; then
      ftctl_dr_scheduler_restore_source_role_control "${plan}" "${run}" || return $?
    fi
  fi
  if [[ "${action}" == "dr-test-prepare" ]]; then
    ftctl_dr_runtime_save_artifact_spec "${plan}" "${run}" "${artifact_spec_file}" || {
      rc=$?
      error_code="DR_TEST_ARTIFACT_LOCATOR_INVALID"
      [[ "${rc}" == "54" ]] && error_code="DR_TEST_ARTIFACT_PROVIDER_UNSUPPORTED"
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" "artifact_spec_invalid" "artifact locator contract is missing or invalid" "${rc}"
      return "${rc}"
    }
    persisted_artifact_spec="$(ftctl_dr_runtime_artifact_spec_path "${plan}" "${run}")"
  fi
  if [[ "${action}" == "dr-reprotect" && -n "${authority_spec_file}" ]]; then
    ftctl_dr_runtime_save_authority_spec "${plan}" "${run}" "${authority_spec_file}" || {
      rc=$?
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" \
        "DR_REPROTECT_AUTHORITY_INVALID" "committed authority contract is missing or invalid" "${rc}"
      return "${rc}"
    }
    persisted_authority_spec="$(ftctl_dr_runtime_authority_spec_path "${plan}" "${run}")"
  fi

  state_tuple="$(ftctl_dr_runtime_action_state "${action}")"
  IFS='|' read -r state step progress <<< "${state_tuple}"
  external_ref="${run}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  if ftctl_dr_runtime_remote_source_transition "$(ftctl_dr_runtime_profile_path "${plan}")"; then
    remote_source_transition=1
  fi
  if [[ "${action}" == "dr-release" && -f "${status_path}" ]]; then
    release_authority_side="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "active_side")"
    release_authority_generation="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "cloud_authority_generation")"
    if [[ -n "${profile_file}" && -f "${profile_file}" ]]; then
      release_resource_disposition="$(jq -r '.request.resourceDisposition // "RETAIN_OPERATIONAL_VM"' "${profile_file}" 2>/dev/null || printf 'RETAIN_OPERATIONAL_VM')"
    elif [[ -f "$(ftctl_dr_runtime_profile_path "${plan}")" ]]; then
      release_resource_disposition="$(jq -r '.request.resourceDisposition // "RETAIN_OPERATIONAL_VM"' "$(ftctl_dr_runtime_profile_path "${plan}")" 2>/dev/null || printf 'RETAIN_OPERATIONAL_VM')"
    fi
  fi
  ftctl_dr_runtime_write_state "${run_path}" "${plan}" "${run}" "${action}" "${state}" "${step}" "${progress}" "${external_ref}" ""
  case "${action}" in
    dr-sync-pause|dr-sync-resume)
      ftctl_dr_runtime_inherit_resume_checkpoint "${plan}" "${run_path}" "${status_path}" || return $? ;;
  esac
  if [[ "${authority_sequence_floor}" =~ ^[0-9]+$ ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "cloud_authority_sequence_floor=${authority_sequence_floor}" || return $?
  fi
  case "${action}" in
    dr-failover|dr-failback|dr-reprotect)
      ftctl_dr_runtime_capture_authority_context "${plan}" "${run_path}" "${status_path}" "${persisted_authority_spec}" || {
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "${action}" "${plan}" "${run}" \
          "DR_AUTHORITY_CONTEXT_CONFLICT" "committed authority state does not match FTCTL runtime" 79
        return 79
      }
      ;;
  esac
  if [[ -n "${profile_file}" && -f "${profile_file}" ]]; then
    target_vm_id="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.vmId" || true)"
    [[ -n "${target_vm_id}" ]] || target_vm_id="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.id" || true)"
    target_external_ref="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.externalRef" || true)"
    [[ -n "${target_external_ref}" ]] || target_external_ref="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.vmRef" || true)"
    [[ -n "${target_external_ref}" ]] || target_external_ref="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.uuid" || true)"
    ftctl_dr_runtime_path_set "${run_path}" \
      "target_vm_id=${target_vm_id}" \
      "target_external_ref=${target_external_ref}" \
      "target_vm_present=$([[ -n "${target_vm_id}${target_external_ref}" ]] && printf true || printf false)" \
      "target_network_present=$([[ -n "${target_vm_id}${target_external_ref}" ]] && printf true || printf false)" || true
  fi

  if [[ "${action}" == "dr-sync-recover" && "${dry_run}" != "1" ]]; then
    rc=0
    ftctl_dr_scheduler_seed_relocated_baseline "${plan}" "$(ftctl_dr_runtime_profile_path "${plan}")" \
      "${run_path}" "${status_path}" "${resume_baseline_checkpoint_sequence}" \
      "${minimum_completed_checkpoint_sequence}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      error_code="DR_RECOVERY_BASELINE_EVIDENCE_INVALID"
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=scheduler-recovery-baseline-invalid" \
        "progress=100" \
        "accepted=false" \
        "scheduler_recovery_state=FAILED" \
        "scheduler_recovery_rc=${rc}" \
        "error_code=${error_code}" \
        "error_message=Durable checkpoint evidence for scheduler relocation is incomplete" \
        "updated_at=$(ftctl_now_iso8601)" || true
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      return "${rc}"
    fi
    ftctl_dr_scheduler_recover "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" \
      "${run_path}" "${status_path}" "MANUAL" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      case "${rc}" in
        41) error_code="DR_RECOVERY_SUPPRESSED_TARGET" ;;
        42) error_code="DR_RECOVERY_SUPPRESSED_CONTROL_STATE" ;;
        43) error_code="DR_RECOVERY_TRANSITION_ACTIVE" ;;
        65) error_code="DR_NBD_RECOVERY_TOOL_UNAVAILABLE" ;;
        69) error_code="DR_RECOVERY_UNIT_START_FAILED" ;;
        92) error_code="DR_NBD_TEARDOWN_TIMEOUT" ;;
        93) error_code="DR_NBD_DISCONNECT_FAILED" ;;
        94) error_code="DR_NBD_DEVICE_BUSY" ;;
        95) error_code="DR_NBD_DEVICE_QUARANTINED" ;;
        96) error_code="DR_NBD_TARGET_FLUSH_FAILED" ;;
        *) error_code="DR_RECOVERY_FAILED" ;;
      esac
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=scheduler-recovery-failed" \
        "progress=100" \
        "accepted=false" \
        "scheduler_recovery_state=FAILED" \
        "scheduler_recovery_rc=${rc}" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      return "${rc}"
    fi
    ftctl_log_event "dr-runtime" "dr.scheduler.recovery" "ok" "" "" \
      "plan=${plan} run=${run} trigger=MANUAL"
    if [[ "${json}" == "1" ]]; then
      ftctl_dr_runtime_emit_state_json "${action}" "accepted" "${plan}" "${run}" "${run_path}" "0"
    else
      printf '%s: plan=%s run=%s accepted\n' "${action}" "${plan}" "${run}"
    fi
    return 0
  fi

  if ftctl_dr_runtime_should_delegate_action "${action}" "${wait_value}" "${dry_run}"; then
    cp -f "${run_path}" "${status_path}"
    chmod 0644 "${status_path}" 2>/dev/null || true
    command -v ftctl_lock_release >/dev/null 2>&1 && ftctl_lock_release || true
    ftctl_dr_runtime_start_background_worker "${action}" "${plan}" "${run}" "${role}" "${mode}" "${restore_point}" "${force}" "${dry_run}" "${persisted_artifact_spec}" "${persisted_authority_spec}"
    ftctl_log_event "dr-runtime" "dr.action.accepted" "ok" "" "" \
      "plan=${plan} run=${run} action=${action} role=${role:-} mode=${mode:-} restore_point=${restore_point:-} force=${force} dry_run=${dry_run} wait=${wait_value:-} delegated=1"
    if [[ "${json}" == "1" ]]; then
      ftctl_dr_runtime_emit_state_json "${action}" "accepted" "${plan}" "${run}" "${run_path}" "0"
    else
      printf '%s: plan=%s run=%s accepted state=%s step=%s delegated=1\n' "${action}" "${plan}" "${run}" "${state}" "${step}"
    fi
    return 0
  fi

  if [[ "${FTCTL_DR_RUNTIME_WORKER:-0}" == "1" && "${dry_run}" != "1" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "worker_state=RUNNING" \
      "worker_pid=$$" \
      "worker_started_at=$(ftctl_now_iso8601)" \
      "worker_updated_at=$(ftctl_now_iso8601)" \
      "worker_exit_code=" \
      "retryable=false" \
      "retry_after_sec=" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    chmod 0644 "${status_path}" 2>/dev/null || true
  fi

  case "${action}" in
    dr-sync-pause|dr-sync-resume|dr-release)
      if command -v ftctl_dr_scheduler_control_action >/dev/null 2>&1; then
        rc=0
        ftctl_dr_scheduler_control_action "${action}" "${plan}" "${run_path}" "${status_path}" \
          "$(ftctl_dr_runtime_profile_path "${plan}")" || rc=$?
        if [[ "${rc}" != "0" && "${action}" == "dr-sync-resume" ]]; then
          ftctl_dr_runtime_path_set "${run_path}" \
            "state=ERROR" \
            "step=scheduler-recovery-failed" \
            "progress=100" \
            "accepted=false" \
            "scheduler_state=ERROR" \
            "error_code=DR_SCHEDULER_NOT_RUNNING" \
            "error_message=Scheduler recovery did not establish a live worker" \
            "updated_at=$(ftctl_now_iso8601)" || true
          cp -f "${run_path}" "${status_path}" 2>/dev/null || true
          ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "DR_SCHEDULER_NOT_RUNNING" "true" "2"
          [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
          return "${rc}"
        fi
      fi
      if [[ "${action}" == "dr-release" && "${rc:-0}" == "0" ]]; then
        ftctl_dr_runtime_write_release_tombstone "${plan}" "${run}" "${run_path}" "${status_path}" \
          "${release_authority_side:-SOURCE}" "${release_authority_generation}" \
          "${release_resource_disposition}" || return $?
      fi
      ;;
    dr-test-failover|dr-test-prepare)
      rc=0
      ftctl_dr_runtime_path_set "${run_path}" \
        "scheduler_transition_scope=$([[ "${remote_source_transition}" == "1" ]] && printf REMOTE_SOURCE || printf LOCAL)" || true
      if [[ "${remote_source_transition}" != "1" ]] && command -v ftctl_dr_scheduler_transition_begin >/dev/null 2>&1; then
        ftctl_dr_scheduler_transition_begin "${plan}" "${run}" "${action}" "${run_path}" "${status_path}" || rc=$?
      fi
      if [[ "${rc}" != "0" ]]; then
        error_code="DR_SYNC_QUIESCE_TIMEOUT"
        [[ "${rc}" == "20" ]] && error_code="DR_TRANSITION_BUSY_RETRYABLE"
        ftctl_dr_runtime_path_set "${run_path}" \
          "state=ERROR" \
          "step=test-quiesce-failed" \
          "progress=100" \
          "accepted=false" \
          "retryable=$([[ "${rc}" == "20" ]] && printf true || printf false)" \
          "retry_after_sec=$([[ "${rc}" == "20" ]] && printf 2 || printf '')" \
          "error_code=${error_code}" \
          "updated_at=$(ftctl_now_iso8601)" || true
        cp -f "${run_path}" "${status_path}" 2>/dev/null || true
        ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "$([[ "${rc}" == "20" ]] && printf true || printf false)" "$([[ "${rc}" == "20" ]] && printf 2 || printf '')"
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        return "${rc}"
      fi
      ftctl_dr_runtime_prepare_test_session "${plan}" "${run}" "${profile_file}" "${restore_point}" "${run_path}" "${status_path}" \
        "$(ftctl_dr_runtime_artifact_spec_path "${plan}" "${run}")" || rc=$?
      if [[ "${rc}" == "0" ]]; then
        test_sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_sequence")"
        checkpoint_lease_path="$(ftctl_dr_scheduler_checkpoint_lease_acquire "${plan}" "${test_sequence}" "${run}" "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_ref")")" || rc=$?
      fi
      if [[ "${rc}" == "0" ]]; then
        ftctl_dr_runtime_path_set "${run_path}" \
          "checkpoint_lease_state=LEASED" \
          "checkpoint_lease_path=${checkpoint_lease_path}" \
          "test_checkpoint_sequence=${test_sequence}" \
          "updated_at=$(ftctl_now_iso8601)" || true
      fi
      if [[ "${rc}" == "0" ]]; then
        ftctl_guestprep_preflight_test_session "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "${run_path}" || rc=$?
      fi
      if [[ "${rc}" == "0" ]]; then
        ftctl_dr_runtime_materialize_test_artifacts "${plan}" "${run}" "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "${run_path}" \
          "$(ftctl_dr_runtime_artifact_spec_path "${plan}" "${run}")" || rc=$?
      fi
      if [[ "${rc}" == "0" ]]; then
        if [[ "${action}" == "dr-test-prepare" ]]; then
          ftctl_guestprep_prepare_artifacts "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "${run_path}" || rc=$?
        else
          ftctl_guestprep_prepare_and_start "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "${run_path}" || rc=$?
        fi
      fi
      if [[ "${rc}" == "0" ]]; then
        cp -f "$(ftctl_dr_runtime_test_session_path "${plan}" "${run}")" "$(ftctl_dr_runtime_active_test_session_path "${plan}")" 2>/dev/null || true
        ftctl_dr_runtime_path_set "${run_path}" \
          "test_cleanup_state=PENDING" \
          "cleanup_required=true" \
          "transition_state=TEST_ACTIVE" \
          "updated_at=$(ftctl_now_iso8601)" || true
      fi
      if [[ "${rc}" != "0" ]]; then
        error_code="DR_RESTORE_POINT_NOT_FOUND"
        error_message=""
        [[ "${rc}" == "45" ]] && error_code="DR_TARGET_NOT_READY"
        [[ "${rc}" == "46" ]] && error_code="DR_TEST_MATERIALIZATION_FAILED"
        [[ "${rc}" == "47" ]] && error_code="DR_GUEST_PREP_RUNTIME_UNAVAILABLE"
        [[ "${rc}" == "48" ]] && error_code="DR_GUEST_OS_UNRESOLVED"
        [[ "${rc}" == "49" ]] && error_code="DR_GUEST_PREPARATION_FAILED"
        [[ "${rc}" == "50" ]] && error_code="DR_TEST_DOMAIN_DEFINE_FAILED"
        [[ "${rc}" == "51" ]] && error_code="DR_TEST_BOOT_TIMEOUT"
        [[ "${rc}" == "52" ]] && error_code="DR_TEST_QGA_UNAVAILABLE"
        [[ "${rc}" == "53" ]] && error_code="DR_TEST_ARTIFACT_LOCATOR_INVALID"
        [[ "${rc}" == "54" ]] && error_code="DR_TEST_ARTIFACT_PROVIDER_UNSUPPORTED"
        if [[ "${rc}" == "46" ]]; then
          local artifact_runtime_error_code="" artifact_runtime_error_message=""
          artifact_runtime_error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
          artifact_runtime_error_message="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_message")"
          if [[ -n "${artifact_runtime_error_code}" ]]; then
            error_code="${artifact_runtime_error_code}"
            error_message="${artifact_runtime_error_message}"
          fi
        fi
        local manifest_error_code="" manifest_error_message=""
        manifest_error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "guest_manifest_error_code")"
        manifest_error_message="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "guest_manifest_error_message")"
        if [[ -n "${manifest_error_code}" ]]; then
          error_code="${manifest_error_code}"
          error_message="${manifest_error_message}"
        fi
        if [[ "${rc}" == "47" || "${rc}" == "48" ]]; then
          error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "guest_preflight_error_code")"
          error_message="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "guest_preflight_error_message")"
          [[ -n "${error_code}" ]] || error_code="$([[ "${rc}" == "47" ]] && printf DR_GUEST_PREP_RUNTIME_UNAVAILABLE || printf DR_GUEST_OS_UNRESOLVED)"
        fi
        if [[ "${rc}" == "49" ]]; then
          error_message="Guest preparation failed (exit $(ftctl_dr_runtime_state_get_from_path "${run_path}" guest_prep_exit_code)); diagnostic log: ${run_path}.guestprep.log"
        fi
        local failed_step="test-session-restore-point-missing"
        [[ "${rc}" == "46" ]] && failed_step="test-materialization-failed"
        [[ "${rc}" -ge 47 ]] && failed_step="test-guest-preparation-failed"
        ftctl_dr_runtime_finalize_failed_test "${plan}" "${run}" "${run_path}" "${status_path}" \
          "${rc}" "${error_code}" "${failed_step}" "${error_message}"
        ftctl_log_event "dr-runtime" "dr.test.failover" "fail" "" "${error_code}" \
          "plan=${plan} run=${run} restore_point=${restore_point:-} rc=${rc}"
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s restore point unavailable error=%s\n' "${action}" "${plan}" "${run}" "${error_code}" >&2
        fi
        return "${rc}"
      fi
      if [[ "${remote_source_transition}" != "1" ]] && command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1; then
        ftctl_dr_scheduler_transition_end "${plan}"
      fi
      ftctl_log_event "dr-runtime" "dr.test.failover" "ok" "" "" \
        "plan=${plan} run=${run} restore_point=$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_ref")"
      ;;
    dr-test-cleanup|dr-test-artifact-cleanup)
      rc=0
      ftctl_dr_runtime_path_set "${run_path}" \
        "scheduler_transition_scope=$([[ "${remote_source_transition}" == "1" ]] && printf REMOTE_SOURCE || printf LOCAL)" || true
      if [[ "${remote_source_transition}" != "1" ]] && command -v ftctl_dr_scheduler_transition_begin >/dev/null 2>&1; then
        ftctl_dr_scheduler_transition_begin "${plan}" "${run}" "${action}" "${run_path}" "${status_path}" || rc=$?
      fi
      if [[ "${rc}" != "0" ]]; then
        error_code="DR_SYNC_QUIESCE_TIMEOUT"
        [[ "${rc}" == "20" ]] && error_code="DR_TRANSITION_BUSY_RETRYABLE"
        ftctl_dr_runtime_path_set "${run_path}" \
          "state=ERROR" \
          "step=test-cleanup-quiesce-failed" \
          "progress=100" \
          "accepted=false" \
          "retryable=$([[ "${rc}" == "20" ]] && printf true || printf false)" \
          "retry_after_sec=$([[ "${rc}" == "20" ]] && printf 2 || printf '')" \
          "error_code=${error_code}" \
          "updated_at=$(ftctl_now_iso8601)" || true
        cp -f "${run_path}" "${status_path}" 2>/dev/null || true
        ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "$([[ "${rc}" == "20" ]] && printf true || printf false)" "$([[ "${rc}" == "20" ]] && printf 2 || printf '')"
        if [[ "${remote_source_transition}" != "1" ]] && command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1; then
          ftctl_dr_scheduler_transition_end "${plan}"
        fi
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        return "${rc}"
      fi
      ftctl_dr_runtime_cleanup_test_session "${plan}" "${run}" "${run_path}" "${status_path}" || rc=$?
      if [[ "${rc}" != "0" ]]; then
        ftctl_dr_runtime_path_set "${run_path}" \
          "state=ERROR" \
          "step=test-cleanup-failed" \
          "progress=100" \
          "accepted=false" \
          "error_code=DR_TEST_CLEANUP_FAILED" \
          "updated_at=$(ftctl_now_iso8601)" || true
        cp -f "${run_path}" "${status_path}" 2>/dev/null || true
        chmod 0644 "${status_path}" 2>/dev/null || true
        ftctl_log_event "dr-runtime" "dr.test.cleanup" "fail" "" "${rc}" \
          "plan=${plan} run=${run}"
        if [[ "${remote_source_transition}" != "1" ]] && command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1; then
          ftctl_dr_scheduler_transition_end "${plan}"
        fi
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s cleanup failed rc=%s\n' "${action}" "${plan}" "${run}" "${rc}" >&2
        fi
        return "${rc}"
      fi
      test_sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_restore_point_sequence")"
      local test_lease_owner_run
      test_lease_owner_run="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "test_lease_owner_run")"
      [[ -n "${test_lease_owner_run}" ]] || test_lease_owner_run="${run}"
      [[ -n "${test_sequence}" ]] && ftctl_dr_scheduler_checkpoint_lease_release_owned "${plan}" "${test_sequence}" "${test_lease_owner_run}"
      ftctl_dr_runtime_path_set "${run_path}" "checkpoint_lease_state=RELEASED" "checkpoint_lease_path=" || true
      if [[ "${remote_source_transition}" != "1" ]] && ! ftctl_dr_runtime_cloud_managed_test_restore "${plan}" && command -v ftctl_dr_scheduler_resume_after_transition >/dev/null 2>&1; then
        ftctl_dr_scheduler_resume_after_transition "${plan}" "${run}" "test-cleanup" "${run_path}" "${status_path}" || rc=$?
      fi
      if [[ "${remote_source_transition}" != "1" ]] && command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1; then
        ftctl_dr_scheduler_transition_end "${plan}"
      fi
      if [[ "${rc}" != "0" ]]; then
        ftctl_dr_runtime_path_set "${run_path}" \
          "state=ERROR" \
          "step=test-cleanup-resume-failed" \
          "accepted=false" \
          "error_code=DR_SYNC_RESUME_TIMEOUT" \
          "updated_at=$(ftctl_now_iso8601)" || true
        cp -f "${run_path}" "${status_path}" 2>/dev/null || true
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        return "${rc}"
      fi
      ftctl_log_event "dr-runtime" "dr.test.cleanup" "ok" "" "" \
        "plan=${plan} run=${run}"
      ;;
    dr-failover)
      rc=0
      ftctl_dr_runtime_start_failover "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" \
        "${restore_point}" "${mode}" "${run_path}" "${status_path}" "${wait_value}" || rc=$?
      if [[ "${rc}" != "0" ]]; then
        error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
        [[ -n "${error_code}" ]] || error_code="DR_FAILOVER_FAILED"
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s failover failed error=%s rc=%s\n' "${action}" "${plan}" "${run}" "${error_code}" "${rc}" >&2
        fi
        return "${rc}"
      fi
      ;;
    dr-failback)
      rc=0
      ftctl_dr_runtime_start_failback "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" \
        "${run_path}" "${status_path}" "${wait_value}" || rc=$?
      if [[ "${rc}" != "0" ]]; then
        error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
        [[ -n "${error_code}" ]] || error_code="DR_FAILBACK_FAILED"
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s failback failed error=%s rc=%s\n' "${action}" "${plan}" "${run}" "${error_code}" "${rc}" >&2
        fi
        return "${rc}"
      fi
      ;;
    dr-reprotect)
      rc=0
      ftctl_dr_runtime_start_reprotect "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" \
        "${run_path}" "${status_path}" "${wait_value}" || rc=$?
      if [[ "${rc}" != "0" ]]; then
        error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
        [[ -n "${error_code}" ]] || error_code="DR_REPROTECT_FAILED"
        if [[ "${json}" == "1" ]]; then
          ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
        else
          printf '%s: plan=%s run=%s reprotect failed error=%s rc=%s\n' "${action}" "${plan}" "${run}" "${error_code}" "${rc}" >&2
        fi
        return "${rc}"
      fi
      ;;
  esac

  if [[ "${action}" == "dr-sync-start" && "${dry_run}" != "1" ]] &&
      command -v ftctl_dr_vmware_sync_start >/dev/null 2>&1; then
    rc=0
    ftctl_dr_vmware_sync_start "${plan}" "${run}" "${profile_file}" "${run_path}" "${wait_value}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
      [[ -n "${error_code}" ]] || error_code="DR_VMWARE_DRIVER_FAILED"
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "accepted=false" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      chmod 0644 "${status_path}" 2>/dev/null || true
      ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "false" ""
      ftctl_log_event "dr-runtime" "dr.vmware.driver" "fail" "" "${rc}" \
        "plan=${plan} run=${run} action=${action} error=${error_code}"
      if [[ "${json}" == "1" ]]; then
        ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      else
        printf '%s: plan=%s run=%s vmware driver failed rc=%s error=%s\n' "${action}" "${plan}" "${run}" "${rc}" "${error_code}" >&2
      fi
      return "${rc}"
    fi
  fi

  if [[ "${action}" == "dr-sync-start" && "${dry_run}" != "1" ]] &&
      command -v ftctl_dr_ablestack_sync_start >/dev/null 2>&1; then
    rc=0
    ftctl_dr_ablestack_sync_start "${plan}" "${run}" "${profile_file}" "${run_path}" "${wait_value}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
      [[ -n "${error_code}" ]] || error_code="DR_ABLESTACK_DRIVER_FAILED"
      step="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "step")"
      [[ -n "${step}" ]] || step="ablestack-driver-failed"
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=${step}" \
        "progress=100" \
        "accepted=false" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      chmod 0644 "${status_path}" 2>/dev/null || true
      ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "false" ""
      ftctl_log_event "dr-runtime" "dr.ablestack.driver" "fail" "" "${rc}" \
        "plan=${plan} run=${run} action=${action} error=${error_code}"
      if [[ "${json}" == "1" ]]; then
        ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      else
        printf '%s: plan=%s run=%s ablestack driver failed rc=%s error=%s\n' "${action}" "${plan}" "${run}" "${rc}" "${error_code}" >&2
      fi
      return "${rc}"
    fi
  fi

  if [[ "${action}" == "dr-sync-start" && "${dry_run}" != "1" ]] &&
      command -v ftctl_dr_scheduler_start >/dev/null 2>&1; then
    rc=0
    if [[ "${mode^^}" == "FULL_RESEED" ]] &&
        command -v ftctl_dr_scheduler_request_cycle >/dev/null 2>&1; then
      ftctl_dr_scheduler_request_cycle "${plan}" "${run}" "FULL_RESEED" "${run_path}" "${status_path}" \
        "${force_immediate_cycle}" || rc=$?
    fi
    if [[ "${rc}" != "0" ]]; then
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=full-resync-request-failed" \
        "progress=100" \
        "accepted=false" \
        "error_code=DR_FULL_RESYNC_REQUEST_FAILED" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "DR_FULL_RESYNC_REQUEST_FAILED" "false" ""
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      return "${rc}"
    fi
    ftctl_dr_scheduler_start "${plan}" "${run}" "$(ftctl_dr_runtime_profile_path "${plan}")" "${run_path}" "${status_path}" "${wait_value}" || rc=$?
    if [[ "${rc}" != "0" ]]; then
      error_code="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "error_code")"
      [[ -n "${error_code}" ]] || error_code="DR_SCHEDULER_FAILED"
      ftctl_dr_runtime_path_set "${run_path}" \
        "state=ERROR" \
        "step=scheduler-failed" \
        "progress=100" \
        "accepted=false" \
        "scheduler_state=ERROR" \
        "error_code=${error_code}" \
        "updated_at=$(ftctl_now_iso8601)" || true
      cp -f "${run_path}" "${status_path}" 2>/dev/null || true
      chmod 0644 "${status_path}" 2>/dev/null || true
      ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "FAILED" "${rc}" "${error_code}" "false" ""
      ftctl_log_event "dr-runtime" "dr.scheduler" "fail" "" "${rc}" \
        "plan=${plan} run=${run} action=${action} error=${error_code}"
      if [[ "${json}" == "1" ]]; then
        ftctl_dr_runtime_emit_state_json "${action}" "error" "${plan}" "${run}" "${run_path}" "0"
      else
        printf '%s: plan=%s run=%s scheduler failed rc=%s error=%s\n' "${action}" "${plan}" "${run}" "${rc}" "${error_code}" >&2
      fi
      return "${rc}"
    fi

    # systemd now owns the live Plan projection. Keep the dispatch Run
    # terminal for Cloud accounting, but never copy its older snapshot back
    # over status.kv after the scheduler unit has been accepted.
    if [[ "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "scheduler_launch_mode")" == "systemd" ]]; then
      ftctl_dr_runtime_path_set "${run_path}" \
        "worker_state=SUCCEEDED" \
        "worker_pid=$$" \
        "worker_exit_code=0" \
        "worker_error_code=" \
        "worker_retryable=false" \
        "worker_retry_after_sec=" \
        "worker_updated_at=$(ftctl_now_iso8601)" || true
      ftctl_log_event "dr-runtime" "dr.action.accepted" "ok" "" "" \
        "plan=${plan} run=${run} action=${action} scheduler_owner=systemd"
      if [[ "${json}" == "1" ]]; then
        ftctl_dr_runtime_emit_state_json "${action}" "accepted" "${plan}" "${run}" "${run_path}" "0"
      else
        printf '%s: plan=%s run=%s accepted scheduler_owner=systemd\n' "${action}" "${plan}" "${run}"
      fi
      return 0
    fi
  fi

  ftctl_dr_runtime_mark_worker_terminal "${run_path}" "${status_path}" "SUCCEEDED" "0" "" "false" ""
  cp -f "${run_path}" "${status_path}"
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.action.accepted" "ok" "" "" \
    "plan=${plan} run=${run} action=${action} role=${role:-} mode=${mode:-} restore_point=${restore_point:-} force=${force} dry_run=${dry_run} wait=${wait_value:-}"

  if [[ "${json}" == "1" ]]; then
    ftctl_dr_runtime_emit_state_json "${action}" "accepted" "${plan}" "${run}" "${run_path}" "0"
  else
    printf '%s: plan=%s run=%s accepted state=%s step=%s\n' "${action}" "${plan}" "${run}" "${state}" "${step}"
  fi
}

ftctl_dr_runtime_write_release_tombstone() {
  local plan="${1-}" run="${2-}" run_path="${3-}" status_path="${4-}"
  local authority_side="${5-SOURCE}" authority_generation="${6-}"
  local resource_disposition="${7-RETAIN_OPERATIONAL_VM}"
  local tombstone_path now

  tombstone_path="$(ftctl_dr_runtime_release_tombstone_path "${plan}")"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "action=dr-release" "state=RELEASED" "step=release-completed" "progress=100" \
    "active_side=${authority_side^^}" "cloud_authority_generation=${authority_generation}" \
    "scheduler_state=STOPPED" "scheduler_desired_state=STOPPED" \
    "control_state=STOPPED" "cycle_state=IDLE" "worker_state=SUCCEEDED" \
    "protection_state=UNPROTECTED" "release_state=RELEASED" \
    "resource_disposition=${resource_disposition}" \
    "profile_removed=true" "runtime_removed=false" \
    "vm_mutated=false" "storage_mutated=false" "network_mutated=false" \
    "released_at=${now}" "accepted=true" "retryable=false" \
    "error_code=" "error_message=" "updated_at=${now}" || return 2
  cp -f "${run_path}" "${status_path}" || return 2
  chmod 0644 "${status_path}" 2>/dev/null || true
  python3 - "${tombstone_path}" "${plan}" "${run}" "${authority_side^^}" \
    "${authority_generation}" "${now}" "${resource_disposition}" <<'PY' || return 2
import json
import os
import sys

path, plan, run, active_side, generation, released_at, resource_disposition = sys.argv[1:8]
payload = {
    "schema_version": 1,
    "contract_version": "dr-release-tombstone-v1",
    "plan_uuid": plan,
    "run_uuid": run,
    "state": "RELEASED",
    "step": "release-completed",
    "protection_state": "UNPROTECTED",
    "active_side": active_side or "SOURCE",
    "resource_disposition": resource_disposition or "RETAIN_OPERATIONAL_VM",
    "authority_generation": int(generation) if generation.isdigit() else None,
    "scheduler_state": "STOPPED",
    "worker_state": "IDLE",
    "profile_removed": True,
    "runtime_removed": False,
    "vm_mutated": False,
    "storage_mutated": False,
    "network_mutated": False,
    "released_at": released_at,
}
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, path)
PY
  rm -f "$(ftctl_dr_runtime_profile_path "${plan}")"
  ftctl_log_event "dr-runtime" "dr.release.tombstone" "ok" "" "" \
    "plan=${plan} run=${run} active_side=${authority_side^^} generation=${authority_generation:-} resource_disposition=${resource_disposition}"
}

ftctl_dr_runtime_restore_release_status() {
  local plan="${1-}" tombstone_path status_path contract plan_uuid run state step protection_state
  local active_side authority_generation scheduler_state released_at resource_disposition

  tombstone_path="$(ftctl_dr_runtime_release_tombstone_path "${plan}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  [[ -f "${tombstone_path}" ]] || return 1

  contract="$(jq -r '.contract_version // empty' "${tombstone_path}" 2>/dev/null || true)"
  plan_uuid="$(jq -r '.plan_uuid // empty' "${tombstone_path}" 2>/dev/null || true)"
  run="$(jq -r '.run_uuid // empty' "${tombstone_path}" 2>/dev/null || true)"
  state="$(jq -r '.state // empty' "${tombstone_path}" 2>/dev/null || true)"
  step="$(jq -r '.step // empty' "${tombstone_path}" 2>/dev/null || true)"
  protection_state="$(jq -r '.protection_state // empty' "${tombstone_path}" 2>/dev/null || true)"
  [[ "${contract}" == "dr-release-tombstone-v1" && "${plan_uuid}" == "${plan}" \
        && "${state}" == "RELEASED" && "${step}" == "release-completed" \
        && "${protection_state}" == "UNPROTECTED" ]] || return 1

  active_side="$(jq -r '.active_side // "SOURCE"' "${tombstone_path}" 2>/dev/null || true)"
  authority_generation="$(jq -r '.authority_generation // empty' "${tombstone_path}" 2>/dev/null || true)"
  scheduler_state="$(jq -r '.scheduler_state // "STOPPED"' "${tombstone_path}" 2>/dev/null || true)"
  released_at="$(jq -r '.released_at // empty' "${tombstone_path}" 2>/dev/null || true)"
  resource_disposition="$(jq -r '.resource_disposition // "RETAIN_OPERATIONAL_VM"' "${tombstone_path}" 2>/dev/null || true)"

  ftctl_dr_runtime_write_state "${status_path}" "${plan}" "${run}" "dr-release" \
    "RELEASED" "release-completed" "100" "${run}" "" || return 1
  ftctl_dr_runtime_path_set "${status_path}" \
    "active_side=${active_side^^}" \
    "cloud_authority_generation=${authority_generation}" \
    "scheduler_state=${scheduler_state^^}" \
    "scheduler_desired_state=STOPPED" \
    "control_state=STOPPED" \
    "cycle_state=IDLE" \
    "worker_state=IDLE" \
    "protection_state=UNPROTECTED" \
    "resource_disposition=${resource_disposition}" \
    "release_state=RELEASED" \
    "profile_removed=true" \
    "runtime_removed=false" \
    "vm_mutated=false" \
    "storage_mutated=false" \
    "network_mutated=false" \
    "released_at=${released_at}" \
    "accepted=true" \
    "retryable=false" \
    "error_code=" \
    "error_message=" \
    "updated_at=${released_at:-$(ftctl_now_iso8601)}" || return 1
  ftctl_log_event "dr-runtime" "dr.release.status-restored" "ok" "" "" \
    "plan=${plan} run=${run} tombstone=${tombstone_path}"
}

ftctl_dr_runtime_target_materialized() {
  local plan="${1-}" run="${2-}" target_vm_id="${3-}" target_external_ref="${4-}" target_vm_name="${5-}" target_network_id="${6-}"
  local target_volume_map_json="${7-}" target_ready_rpo_seconds="${8-}" materialization_spec_json="${9-}"
  local materialization_spec_sha256="${10-}" json="${11-0}"
  local run_path status_path now updates validation generation observed_power_state disk_digest replica_id ownership_fingerprint
  local previous_generation previous_digest previous_ownership_fingerprint previous_replica_id previous_target_vm_id
  local previous_target_external_ref previous_disk_digest legacy_ownership_matches rc

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  if [[ -z "${target_vm_id}${target_external_ref}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-target-materialized" "${plan}" "${run}" "target_reference_required" "target VM id or external ref is required" 2
    [[ "${json}" == "1" ]] || printf 'dr-target-materialized: plan=%s run=%s target reference is required\n' "${plan}" "${run}" >&2
    return 2
  fi
  if [[ -z "${materialization_spec_json}" || -z "${materialization_spec_sha256}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-target-materialized" "${plan}" "${run}" \
      "DR_MATERIALIZATION_CONTRACT_REQUIRED" "materialization contract v2 and SHA-256 are required" 78
    return 78
  fi

  validation="$(python3 - "${materialization_spec_json}" "${materialization_spec_sha256}" "${plan}" "${run}" \
      "${target_vm_id}" "${target_external_ref}" "${target_volume_map_json}" <<'PY'
import hashlib
import json
import sys

raw, supplied_hash, plan, run, target_vm_id, target_external_ref, volume_map_raw = sys.argv[1:8]
actual_hash = hashlib.sha256(raw.encode("utf-8")).hexdigest()
if actual_hash.lower() != supplied_hash.lower():
    print("DR_MATERIALIZATION_DIGEST_MISMATCH")
    raise SystemExit(78)
try:
    spec = json.loads(raw)
    volume_map = json.loads(volume_map_raw)
except Exception:
    print("DR_MATERIALIZATION_SCHEMA_INVALID")
    raise SystemExit(78)
if spec.get("contractVersion") != 2 or spec.get("planUuid") != plan or spec.get("runUuid") != run:
    print("DR_MATERIALIZATION_OWNERSHIP_MISMATCH")
    raise SystemExit(78)
replica_id = spec.get("replicaId")
generation = spec.get("ownershipGeneration")
if not isinstance(replica_id, int) or replica_id <= 0 or not isinstance(generation, int) or generation <= 0:
    print("DR_MATERIALIZATION_SCHEMA_INVALID")
    raise SystemExit(78)
target = spec.get("targetVm") or {}
if str(target.get("vmId", "")) != str(target_vm_id) or str(target.get("externalRef", "")) != str(target_external_ref):
    print("DR_MATERIALIZATION_OWNERSHIP_MISMATCH")
    raise SystemExit(78)
power = target.get("observedPowerState")
if power not in ("POWERED_OFF", "POWERED_ON"):
    print("DR_MATERIALIZATION_POWER_STATE_MISMATCH")
    raise SystemExit(80)
spec_disks = (spec.get("targetVolumeMap") or {}).get("disks") or []
arg_disks = (volume_map or {}).get("disks") or []
if not spec_disks or spec_disks != arg_disks:
    print("DR_MATERIALIZATION_DISK_MAP_MISMATCH")
    raise SystemExit(81)
for disk in spec_disks:
    if not disk.get("targetVolumeId") or not disk.get("targetDiskRef"):
        print("DR_MATERIALIZATION_DISK_MAP_MISMATCH")
        raise SystemExit(81)
disk_digest = hashlib.sha256(json.dumps(spec_disks, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
ownership = {
    "contractVersion": spec.get("contractVersion"),
    "planUuid": spec.get("planUuid"),
    "replicaId": replica_id,
    "ownershipGeneration": generation,
    "targetVm": {
        "vmId": str(target.get("vmId", "")),
        "externalRef": str(target.get("externalRef", "")),
    },
    "targetVolumeMap": {"disks": spec_disks},
}
ownership_fingerprint = hashlib.sha256(
    json.dumps(ownership, sort_keys=True, separators=(",", ":")).encode("utf-8")
).hexdigest()
print(f"OK\t{generation}\t{supplied_hash.lower()}\t{power}\t{disk_digest}\t{replica_id}\t{ownership_fingerprint}")
PY
  )" || rc=$?
  rc="${rc:-0}"
  if [[ "${rc}" != "0" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-target-materialized" "${plan}" "${run}" \
      "${validation:-DR_MATERIALIZATION_CONTRACT_INVALID}" "materialization contract v2 validation failed" "${rc}"
    return "${rc}"
  fi
  IFS=$'\t' read -r _ generation materialization_spec_sha256 observed_power_state disk_digest replica_id ownership_fingerprint <<<"${validation}"

  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  previous_generation="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "materialization_ownership_generation" 2>/dev/null || true)"
  previous_digest="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "materialization_spec_sha256" 2>/dev/null || true)"
  previous_ownership_fingerprint="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "materialization_ownership_fingerprint_sha256" 2>/dev/null || true)"
  previous_replica_id="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "materialization_replica_id" 2>/dev/null || true)"
  previous_target_vm_id="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "target_vm_id" 2>/dev/null || true)"
  previous_target_external_ref="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "target_external_ref" 2>/dev/null || true)"
  previous_disk_digest="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "materialization_disk_map_sha256" 2>/dev/null || true)"
  if [[ "${previous_generation}" =~ ^[0-9]+$ ]] && (( generation < previous_generation )); then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-target-materialized" "${plan}" "${run}" \
      "DR_MATERIALIZATION_STALE_GENERATION" "materialization ownership generation is stale" 79
    return 79
  fi
  legacy_ownership_matches=false
  if [[ -z "${previous_ownership_fingerprint}" && -n "${previous_digest}" \
      && "${previous_replica_id}" == "${replica_id}" \
      && "${previous_target_vm_id}" == "${target_vm_id}" \
      && "${previous_target_external_ref}" == "${target_external_ref}" \
      && "${previous_disk_digest}" == "${disk_digest}" ]]; then
    legacy_ownership_matches=true
  fi
  if [[ "${previous_generation}" == "${generation}" \
      && -n "${previous_ownership_fingerprint}" \
      && "${previous_ownership_fingerprint}" != "${ownership_fingerprint}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-target-materialized" "${plan}" "${run}" \
      "DR_MATERIALIZATION_GENERATION_CONFLICT" "materialization ownership changed without generation advance" 79
    return 79
  fi
  if [[ "${previous_generation}" == "${generation}" && -n "${previous_digest}" \
      && -z "${previous_ownership_fingerprint}" \
      && "${legacy_ownership_matches}" != "true" \
      && "${previous_digest}" != "${materialization_spec_sha256}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-target-materialized" "${plan}" "${run}" \
      "DR_MATERIALIZATION_GENERATION_CONFLICT" "materialization ownership changed without generation advance" 79
    return 79
  fi
  if [[ ! -f "${run_path}" ]]; then
    if [[ -f "${status_path}" ]]; then
      cp -f "${status_path}" "${run_path}"
    else
      ftctl_dr_runtime_write_state "${run_path}" "${plan}" "${run}" "dr-target-materialized" "READY" "target-ready" "100" "${run}" ""
    fi
  fi

  now="$(ftctl_now_iso8601)"
  updates=(
    "action=dr-target-materialized"
    "state=READY"
    "step=target-ready"
    "progress=100"
    "accepted=true"
    "target_vm_id=${target_vm_id}"
    "target_external_ref=${target_external_ref}"
    "target_vm_name=${target_vm_name}"
    "target_network_id=${target_network_id}"
    "target_volume_map_json=${target_volume_map_json}"
    "target_vm_present=true"
    "target_storage_present=true"
    "target_network_present=true"
    "restore_point_present=true"
    "target_materialized=true"
    "materialization_contract_version=2"
    "materialization_replica_id=${replica_id}"
    "materialization_ownership_generation=${generation}"
    "materialization_spec_sha256=${materialization_spec_sha256}"
    "materialization_ownership_fingerprint_sha256=${ownership_fingerprint}"
    "materialization_disk_map_sha256=${disk_digest}"
    "materialization_observed_power_state=${observed_power_state}"
    "worker_state=SUCCEEDED"
    "worker_exit_code=0"
    "worker_updated_at=${now}"
    "retryable=false"
    "retry_after_sec="
    "error_code="
    "error_message="
    "updated_at=${now}"
  )
  [[ -n "${target_ready_rpo_seconds}" ]] && updates+=("target_ready_rpo_seconds=${target_ready_rpo_seconds}")
  ftctl_dr_runtime_path_set "${run_path}" "${updates[@]}" || return 2
  cp -f "${run_path}" "${status_path}"
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.target.materialized" "ok" "" "" \
    "plan=${plan} run=${run} target_vm_id=${target_vm_id:-} target_external_ref=${target_external_ref:-}"

  if [[ "${json}" == "1" ]]; then
    ftctl_dr_runtime_emit_state_json "dr-target-materialized" "ok" "${plan}" "${run}" "${run_path}" "0"
  else
    printf 'dr-target-materialized: plan=%s run=%s target=%s state=READY\n' "${plan}" "${run}" "${target_vm_id:-${target_external_ref}}"
  fi
}

ftctl_dr_runtime_cutover_commit_envelope_sha256() {
  python3 - "$@" <<'PY'
import hashlib
import json
import sys

(contract, plan, run, engine_session, cloud_session, checkpoint, manifest,
 authority, attempt, target_vm_id, target_external_ref, target_power,
 boot_state, source_fence, source_power) = sys.argv[1:]
payload = {
    "authorityGeneration": int(authority),
    "bootValidationState": boot_state,
    "checkpointSequence": int(checkpoint),
    "cloudCutoverSessionUuid": cloud_session,
    "commitAttemptId": attempt,
    "contractVersion": contract,
    "engineSessionId": engine_session,
    "manifestSha256": manifest,
    "planUuid": plan,
    "runUuid": run,
    "sourceFenceState": source_fence,
    "sourcePowerState": source_power,
    "targetExternalRef": target_external_ref,
    "targetPowerState": target_power,
    "targetVmId": int(target_vm_id),
}
canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
PY
}

ftctl_dr_runtime_cutover_commit_target_projection() {
  local plan="${1-}" run="${2-}" session_id="${3-}" checkpoint_sequence="${4-}"
  local authority_generation="${5-}" target_power_state="${6-}" boot_validation_state="${7-}" json="${8-0}"
  local contract_version="${9-}" cloud_session_id="${10-}" manifest_sha256="${11-}"
  local commit_attempt_id="${12-}" commit_envelope_sha256="${13-}" target_vm_id="${14-}"
  local target_external_ref="${15-}" source_fence_state="${16-}" source_power_state="${17-}"
  local profile_file="${18-}"
  local run_path status_path commit_path now profile_target_vm_id profile_target_external_ref
  local journal_attempt journal_sha journal_cloud_session reverse_baseline_state unit

  if [[ -z "${profile_file}" ]]; then
    profile_file="$(ftctl_dr_runtime_cloud_target_profile_path "${plan}" 2>/dev/null || true)"
  fi
  ftctl_dr_runtime_cloud_target_transition "${profile_file}" || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_TARGET_ROLE_INVALID" "target authority projection requires a Cloud-managed KVM cutover profile" 79
    return 79
  }
  profile_target_vm_id="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.vmId" 2>/dev/null || true)"
  profile_target_external_ref="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.externalRef" 2>/dev/null || true)"
  [[ -n "${profile_target_external_ref}" ]] || \
    profile_target_external_ref="$(ftctl_dr_runtime_profile_value "${profile_file}" "target.vmUuid" 2>/dev/null || true)"
  if [[ -n "${profile_target_vm_id}" && "${profile_target_vm_id}" != "${target_vm_id}" \
        || -n "${profile_target_external_ref}" && "${profile_target_external_ref}" != "${target_external_ref}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_TARGET_IDENTITY_MISMATCH" "Cloud target identity does not match the target FTCTL profile" 79
    return 79
  fi

  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${run_path}")" "0755"
  if [[ ! -f "${run_path}" ]]; then
    if [[ -f "${status_path}" ]]; then
      cp -f "${status_path}" "${run_path}" || return 2
    else
      ftctl_state_write_kv_all "${run_path}" "plan=${plan}" "run=${run}" || return 2
    fi
  fi
  commit_path="$(ftctl_dr_runtime_cutover_commit_state_path "${plan}" "${run}")"
  ftctl_ensure_dir "$(dirname "${commit_path}")" "0755" || return 2
  if [[ -f "${commit_path}" ]]; then
    journal_attempt="$(ftctl_state_read_kv "${commit_path}" "commit_attempt_id" 2>/dev/null || true)"
    journal_sha="$(ftctl_state_read_kv "${commit_path}" "commit_envelope_sha256" 2>/dev/null || true)"
    journal_cloud_session="$(ftctl_state_read_kv "${commit_path}" "cloud_session_id" 2>/dev/null || true)"
    if [[ "${journal_attempt}" != "${commit_attempt_id}" || "${journal_sha}" != "${commit_envelope_sha256}" \
          || "${journal_cloud_session}" != "${cloud_session_id}" ]]; then
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_CUTOVER_COMMIT_CONFLICT" "target cutover journal identity conflicts with this envelope" 79
      return 79
    fi
  fi

  reverse_baseline_state="FULL_SEED_REQUIRED"
  if command -v ftctl_dr_ablestack_reverse_baseline_status >/dev/null 2>&1; then
    reverse_baseline_state="$(ftctl_dr_ablestack_reverse_baseline_status "${plan}" "${run}" "${checkpoint_sequence}")"
  fi
  if command -v ftctl_dr_scheduler_control_set >/dev/null 2>&1; then
    ftctl_dr_scheduler_control_set "${plan}" "stop" "cutover-target-authority" "${run}" "false" >/dev/null || return $?
  fi
  if command -v ftctl_dr_scheduler_systemd_available >/dev/null 2>&1 \
      && ftctl_dr_scheduler_systemd_available "${plan}"; then
    unit="$(ftctl_dr_scheduler_unit_name "${plan}")"
    systemctl stop "${unit}" >/dev/null 2>&1 || true
  fi

  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "action=dr-cutover-commit" "role=target" "plan=${plan}" "run=${run}" \
    "state=FAILED_OVER" "step=cloud-promotion-committed" "progress=100" \
    "active_side=TARGET" "target_vm_id=${target_vm_id}" \
    "target_external_ref=${target_external_ref}" "target_power_state=POWERED_ON" \
    "target_promotion_state=PROMOTED" "boot_validation_state=${boot_validation_state}" \
    "source_fence_state=${source_fence_state}" "source_power_state=${source_power_state}" \
    "failover_session_id=${session_id}" "cloud_cutover_session_id=${cloud_session_id}" \
    "failover_restore_point_sequence=${checkpoint_sequence}" "checkpoint_sequence=${checkpoint_sequence}" \
    "manifest_sha256=${manifest_sha256}" "cloud_authority_generation=${authority_generation}" \
    "cutover_commit_contract_version=${contract_version}" \
    "cutover_commit_attempt_id=${commit_attempt_id}" \
    "cutover_commit_envelope_sha256=${commit_envelope_sha256}" \
    "cutover_commit_phase=ACKNOWLEDGED" "cutover_commit_outcome=ACKNOWLEDGED" \
    "engine_ack_state=ACKNOWLEDGED" "engine_ack_at=${now}" \
    "reverse_baseline_state=${reverse_baseline_state}" \
    "initial_reverse_seed_required=$([[ "${reverse_baseline_state}" == "READY" ]] && printf false || printf true)" \
    "worker_state=SUCCEEDED" "worker_exit_code=0" "accepted=true" \
    "terminal_authoritative=true" "retryable=false" "error_code=" "error_message=" \
    "failover_completed_at=${now}" "updated_at=${now}" || return 2
  ftctl_dr_runtime_apply_target_authority_terminal_state "${run_path}" "${now}" || return 2
  ftctl_dr_runtime_publish_status "${run_path}" "${status_path}" || return 2
  ftctl_state_write_kv_all "${commit_path}" \
    "version=2" "projection_role=TARGET" "contract_version=${contract_version}" \
    "plan=${plan}" "run=${run}" "engine_session_id=${session_id}" \
    "cloud_session_id=${cloud_session_id}" "checkpoint_sequence=${checkpoint_sequence}" \
    "manifest_sha256=${manifest_sha256}" "authority_generation=${authority_generation}" \
    "commit_attempt_id=${commit_attempt_id}" "commit_envelope_sha256=${commit_envelope_sha256}" \
    "target_vm_id=${target_vm_id}" "target_external_ref=${target_external_ref}" \
    "target_power_state=${target_power_state}" "boot_validation_state=${boot_validation_state}" \
    "source_fence_state=${source_fence_state}" "source_power_state=${source_power_state}" \
    "reverse_baseline_state=${reverse_baseline_state}" "phase=ACKNOWLEDGED" \
    "outcome=ACKNOWLEDGED" "acknowledged_at=${now}" "updated_at=${now}" || return 2
  ftctl_log_event "dr-runtime" "dr.cutover.target_authority" "ok" "" "" \
    "plan=${plan} run=${run} generation=${authority_generation} reverse_baseline=${reverse_baseline_state}"
  if [[ "${json}" == "1" ]]; then
    ftctl_dr_runtime_emit_state_json "dr-cutover-commit" "ok" "${plan}" "${run}" "${run_path}" "0"
  else
    printf 'dr-cutover-commit: plan=%s run=%s role=target state=FAILED_OVER active_side=TARGET\n' "${plan}" "${run}"
  fi
}

ftctl_dr_runtime_cutover_commit() {
  local plan="${1-}" run="${2-}" session_id="${3-}" checkpoint_sequence="${4-}"
  local authority_generation="${5-}" target_power_state="${6-}" boot_validation_state="${7-}" json="${8-0}"
  local contract_version="${9-}" cloud_session_id="${10-}" manifest_sha256="${11-}"
  local commit_attempt_id="${12-}" commit_envelope_sha256="${13-}" target_vm_id="${14-}"
  local target_external_ref="${15-}" source_fence_state="${16-}" source_power_state="${17-}" role="${18-}"
  local run_path status_path active_path session_path commit_path state current_session current_checkpoint current_generation now
  local current_manifest current_target_vm_id current_target_external_ref current_source_fence current_source_power
  local calculated_envelope_sha256 journal_attempt journal_sha journal_cloud_session journal_phase target_profile_file
  local v2="false"

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  if [[ -n "${contract_version}" ]]; then
    v2="true"
    if [[ "${contract_version}" != "DR_CUTOVER_COMMIT_V2" || -z "${session_id}" || -z "${cloud_session_id}" \
          || ! "${checkpoint_sequence}" =~ ^[0-9]+$ || ! "${authority_generation}" =~ ^[0-9]+$ \
          || ! "${manifest_sha256}" =~ ^[0-9a-f]{64}$ || -z "${commit_attempt_id}" \
          || ! "${commit_envelope_sha256}" =~ ^[0-9a-f]{64}$ || ! "${target_vm_id}" =~ ^[1-9][0-9]*$ \
          || -z "${target_external_ref}" ]]; then
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_CUTOVER_COMMIT_INVALID" "complete cutover commit envelope v2 is required" 2
      return 2
    fi
    case "${source_fence_state}" in ACKNOWLEDGED|VERIFIED) ;; *)
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_CUTOVER_POWER_STATE_INVALID" "source fence state is not safe for cutover" 78
      return 78
      ;;
    esac
    case "${source_power_state}" in POWERED_OFF|UNREACHABLE|UNKNOWN) ;; *)
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_CUTOVER_POWER_STATE_INVALID" "source power state is not safe for cutover" 78
      return 78
      ;;
    esac
    calculated_envelope_sha256="$(ftctl_dr_runtime_cutover_commit_envelope_sha256 \
      "${contract_version}" "${plan}" "${run}" "${session_id}" "${cloud_session_id}" \
      "${checkpoint_sequence}" "${manifest_sha256}" "${authority_generation}" "${commit_attempt_id}" \
      "${target_vm_id}" "${target_external_ref}" "${target_power_state}" "${boot_validation_state}" \
      "${source_fence_state}" "${source_power_state}")" || return 2
    if [[ "${calculated_envelope_sha256}" != "${commit_envelope_sha256}" ]]; then
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_CUTOVER_COMMIT_HASH_MISMATCH" "cutover commit envelope SHA-256 does not match" 79
      return 79
    fi
  fi
  if [[ -z "${session_id}" || ! "${checkpoint_sequence}" =~ ^[0-9]+$ || ! "${authority_generation}" =~ ^[0-9]+$ ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_COMMIT_INVALID" "session id, checkpoint sequence, and authority generation are required" 2
    [[ "${json}" == "1" ]] || printf 'dr-cutover-commit: invalid commit contract\n' >&2
    return 2
  fi
  if [[ "${target_power_state}" != "POWERED_ON" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_TARGET_NOT_RUNNING" "Cloud target power state must be POWERED_ON" 78
    return 78
  fi
  case "${boot_validation_state}" in
    POWER_STATE_VALIDATED|GUEST_HEARTBEAT_VALIDATED) ;;
    *)
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_BOOT_VALIDATION_INCOMPLETE" "Cloud target boot validation is incomplete" 78
      return 78
      ;;
  esac

  if [[ "${role,,}" == "target" ]]; then
    target_profile_file="$(ftctl_dr_runtime_cloud_target_profile_path "${plan}" 2>/dev/null || true)"
    if [[ -z "${target_profile_file}" ]]; then
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_CUTOVER_TARGET_ROLE_INVALID" "target authority projection requires a Plan-owned target profile" 79
      return 79
    fi
    ftctl_dr_runtime_cutover_commit_target_projection "${plan}" "${run}" "${session_id}" \
      "${checkpoint_sequence}" "${authority_generation}" "${target_power_state}" \
      "${boot_validation_state}" "${json}" "${contract_version}" "${cloud_session_id}" \
      "${manifest_sha256}" "${commit_attempt_id}" "${commit_envelope_sha256}" \
      "${target_vm_id}" "${target_external_ref}" "${source_fence_state}" "${source_power_state}" \
      "${target_profile_file}"
    return $?
  fi

  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  active_path="$(ftctl_dr_runtime_active_failover_session_path "${plan}")"
  session_path="$(ftctl_dr_runtime_failover_session_path "${plan}" "${run}")"
  commit_path="$(ftctl_dr_runtime_cutover_commit_state_path "${plan}" "${run}")"
  [[ -f "${run_path}" && -f "${status_path}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_SESSION_NOT_FOUND" "FTCTL cutover runtime was not found" 44
    return 44
  }

  state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "state")"
  current_session="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_session_id")"
  current_checkpoint="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_restore_point_sequence")"
  current_generation="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "cloud_authority_generation")"
  current_manifest="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "manifest_sha256")"
  current_target_vm_id="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "target_vm_id")"
  current_target_external_ref="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "target_external_ref")"
  current_source_fence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "source_fence_state")"
  current_source_power="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "source_power_state")"
  [[ "${current_session}" == "${session_id}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_SESSION_MISMATCH" "Cloud cutover session does not match FTCTL runtime" 79
    return 79
  }
  if [[ "${current_checkpoint}" != "${checkpoint_sequence}" \
        && "${state}" == "CUTOVER_READY" \
        && "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "checkpoint_sequence")" == "${checkpoint_sequence}" ]] \
      && ftctl_dr_runtime_remote_source_transition "$(ftctl_dr_runtime_profile_path "${plan}")" \
      && ftctl_dr_runtime_repair_final_checkpoint_selection "${plan}" "${run}" "${checkpoint_sequence}" \
        "${run_path}" "${status_path}" "${session_path}" "${active_path}"; then
    current_checkpoint="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_restore_point_sequence")"
  fi
  [[ "${current_checkpoint}" == "${checkpoint_sequence}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_CHECKPOINT_MISMATCH" "Cloud checkpoint does not match FTCTL cutover checkpoint" 79
    return 79
  }
  if [[ -n "${current_generation}" && "${authority_generation}" -lt "${current_generation}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_GENERATION_STALE" "Cloud authority generation is older than the committed generation" 79
    return 79
  fi
  if [[ "${state}" != "CUTOVER_READY" && "${state}" != "FAILED_OVER" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
      "DR_CUTOVER_STATE_INVALID" "FTCTL runtime is not ready for Cloud promotion commit" 79
    return 79
  fi

  if [[ "${v2}" == "true" ]]; then
    if [[ "${current_manifest}" != "${manifest_sha256}" ]]; then
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_CUTOVER_MANIFEST_MISMATCH" "Cloud manifest does not match FTCTL cutover manifest" 79
      return 79
    fi
    if [[ -n "${current_target_vm_id}" && "${current_target_vm_id}" != "${target_vm_id}" \
          || -n "${current_target_external_ref}" && "${current_target_external_ref}" != "${target_external_ref}" ]]; then
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
        "DR_CUTOVER_TARGET_IDENTITY_MISMATCH" "Cloud target identity does not match FTCTL materialization" 79
      return 79
    fi
    if [[ -n "${current_source_fence}" && "${current_source_fence}" != "${source_fence_state}" ]]; then
      if [[ "${current_source_fence}" != "REQUESTED" && "${current_source_fence}" != "UNKNOWN" \
            || "${source_fence_state}" != "ACKNOWLEDGED" && "${source_fence_state}" != "VERIFIED" ]]; then
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
          "DR_CUTOVER_POWER_STATE_INVALID" "Cloud source isolation evidence conflicts with FTCTL runtime" 79
        return 79
      fi
    fi
    if [[ -n "${current_source_power}" && "${current_source_power}" != "${source_power_state}" ]]; then
      if [[ "${current_source_power}" != "UNKNOWN" \
            || "${source_power_state}" != "POWERED_OFF" && "${source_power_state}" != "UNREACHABLE" ]]; then
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
          "DR_CUTOVER_POWER_STATE_INVALID" "Cloud source power evidence conflicts with FTCTL runtime" 79
        return 79
      fi
    fi
    if [[ -f "${commit_path}" ]]; then
      journal_attempt="$(ftctl_state_read_kv "${commit_path}" "commit_attempt_id" 2>/dev/null || true)"
      journal_sha="$(ftctl_state_read_kv "${commit_path}" "commit_envelope_sha256" 2>/dev/null || true)"
      journal_cloud_session="$(ftctl_state_read_kv "${commit_path}" "cloud_session_id" 2>/dev/null || true)"
      journal_phase="$(ftctl_state_read_kv "${commit_path}" "phase" 2>/dev/null || true)"
      if [[ "${journal_attempt}" != "${commit_attempt_id}" || "${journal_sha}" != "${commit_envelope_sha256}" \
            || "${journal_cloud_session}" != "${cloud_session_id}" ]]; then
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-cutover-commit" "${plan}" "${run}" \
          "DR_CUTOVER_COMMIT_CONFLICT" "cutover commit journal identity conflicts with this envelope" 79
        return 79
      fi
      if [[ "${journal_phase}" == "ACKNOWLEDGED" && "${state}" == "FAILED_OVER" ]]; then
        [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json \
          "dr-cutover-commit" "ok" "${plan}" "${run}" "${run_path}" "0"
        return 0
      fi
    else
      now="$(ftctl_now_iso8601)"
      ftctl_ensure_dir "$(dirname "${commit_path}")" "0755"
      ftctl_state_write_kv_all "${commit_path}" \
        "version=2" "contract_version=${contract_version}" "plan=${plan}" "run=${run}" \
        "engine_session_id=${session_id}" "cloud_session_id=${cloud_session_id}" \
        "checkpoint_sequence=${checkpoint_sequence}" "manifest_sha256=${manifest_sha256}" \
        "authority_generation=${authority_generation}" "commit_attempt_id=${commit_attempt_id}" \
        "commit_envelope_sha256=${commit_envelope_sha256}" "target_vm_id=${target_vm_id}" \
        "target_external_ref=${target_external_ref}" "target_power_state=${target_power_state}" \
        "boot_validation_state=${boot_validation_state}" "source_fence_state=${source_fence_state}" \
        "source_power_state=${source_power_state}" "phase=PREPARED" "outcome=PENDING" \
        "prepared_at=${now}" "updated_at=${now}" || return 2
    fi
  fi

  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "action=dr-cutover-commit" \
    "state=FAILED_OVER" \
    "step=cloud-promotion-committed" \
    "progress=100" \
    "active_side=TARGET" \
    "target_power_state=POWERED_ON" \
    "target_promotion_state=PROMOTED" \
    "boot_validation_state=${boot_validation_state}" \
    "source_fence_state=${source_fence_state}" \
    "source_power_state=${source_power_state}" \
    "cloud_cutover_session_id=${cloud_session_id:-${session_id}}" \
    "cloud_authority_generation=${authority_generation}" \
    "cutover_commit_contract_version=${contract_version}" \
    "cutover_commit_attempt_id=${commit_attempt_id}" \
    "cutover_commit_envelope_sha256=${commit_envelope_sha256}" \
    "cutover_commit_phase=$([[ "${v2}" == "true" ]] && printf AUTHORITY_APPLIED || printf ACKNOWLEDGED)" \
    "cutover_commit_outcome=$([[ "${v2}" == "true" ]] && printf PENDING || printf ACKNOWLEDGED)" \
    "engine_ack_state=ACKNOWLEDGED" \
    "engine_ack_at=${now}" \
    "failover_completed_at=${now}" \
    "worker_state=SUCCEEDED" \
    "worker_exit_code=0" \
    "accepted=true" \
    "retryable=false" \
    "error_code=" \
    "error_message=" \
    "updated_at=${now}" || return 2
  ftctl_dr_runtime_apply_target_authority_terminal_state "${run_path}" "${now}" || return 2
  ftctl_dr_runtime_publish_status "${run_path}" "${status_path}" || return 2

  if [[ "${v2}" == "true" ]]; then
    ftctl_state_write_kv_all "${commit_path}" \
      "version=2" "contract_version=${contract_version}" "plan=${plan}" "run=${run}" \
      "engine_session_id=${session_id}" "cloud_session_id=${cloud_session_id}" \
      "checkpoint_sequence=${checkpoint_sequence}" "manifest_sha256=${manifest_sha256}" \
      "authority_generation=${authority_generation}" "commit_attempt_id=${commit_attempt_id}" \
      "commit_envelope_sha256=${commit_envelope_sha256}" "target_vm_id=${target_vm_id}" \
      "target_external_ref=${target_external_ref}" "target_power_state=${target_power_state}" \
      "boot_validation_state=${boot_validation_state}" "source_fence_state=${source_fence_state}" \
      "source_power_state=${source_power_state}" "phase=AUTHORITY_APPLIED" "outcome=PENDING" \
      "authority_applied_at=${now}" "updated_at=${now}" || return 2
  fi

  if [[ -f "${session_path}" ]]; then
    python3 - "${session_path}" "${active_path}" "${authority_generation}" "${boot_validation_state}" "${now}" \
      "${cloud_session_id:-${session_id}}" <<'PY' || return 2
import json
import os
import shutil
import sys

path, active_path, generation, validation_state, now, cloud_session_id = sys.argv[1:7]
with open(path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["state"] = "FAILED_OVER"
session["activeSide"] = "TARGET"
session["completedAt"] = now
session["cloudAuthorityGeneration"] = int(generation)
session["cloudCutoverSessionId"] = cloud_session_id
session["bootValidationState"] = validation_state
promotion = session.setdefault("targetPromotion", {})
promotion["state"] = "PROMOTED"
promotion["powerState"] = "POWERED_ON"
promotion["committedAt"] = now
promotion["authorityOwner"] = "Cloud"
with open(path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.makedirs(os.path.dirname(active_path), exist_ok=True)
shutil.copyfile(path, active_path)
PY
  fi

  if [[ "${v2}" == "true" ]]; then
    now="$(ftctl_now_iso8601)"
    ftctl_state_write_kv_all "${commit_path}" \
      "version=2" "contract_version=${contract_version}" "plan=${plan}" "run=${run}" \
      "engine_session_id=${session_id}" "cloud_session_id=${cloud_session_id}" \
      "checkpoint_sequence=${checkpoint_sequence}" "manifest_sha256=${manifest_sha256}" \
      "authority_generation=${authority_generation}" "commit_attempt_id=${commit_attempt_id}" \
      "commit_envelope_sha256=${commit_envelope_sha256}" "target_vm_id=${target_vm_id}" \
      "target_external_ref=${target_external_ref}" "target_power_state=${target_power_state}" \
      "boot_validation_state=${boot_validation_state}" "source_fence_state=${source_fence_state}" \
      "source_power_state=${source_power_state}" "phase=ACKNOWLEDGED" "outcome=ACKNOWLEDGED" \
      "authority_applied_at=${now}" "acknowledged_at=${now}" "updated_at=${now}" || return 2
    ftctl_dr_runtime_path_set "${run_path}" \
      "cutover_commit_phase=ACKNOWLEDGED" "cutover_commit_outcome=ACKNOWLEDGED" \
      "engine_ack_state=ACKNOWLEDGED" "engine_ack_at=${now}" "updated_at=${now}" || return 2
    ftctl_dr_runtime_publish_status "${run_path}" "${status_path}" || return 2
  fi

  ftctl_log_event "dr-runtime" "dr.cutover.commit" "ok" "" "" \
    "plan=${plan} run=${run} session=${session_id} generation=${authority_generation}"
  if [[ "${json}" == "1" ]]; then
    ftctl_dr_runtime_emit_state_json "dr-cutover-commit" "ok" "${plan}" "${run}" "${run_path}" "0"
  else
    printf 'dr-cutover-commit: plan=%s run=%s state=FAILED_OVER active_side=TARGET\n' "${plan}" "${run}"
  fi
}

ftctl_dr_runtime_cutover_commit_status() {
  local plan="${1-}" run="${2-}" engine_session_id="${3-}" contract_version="${4-}"
  local commit_attempt_id="${5-}" commit_envelope_sha256="${6-}" json="${7-0}"
  local run_path commit_path journal_session journal_attempt journal_sha phase outcome state active_side
  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  if [[ "${contract_version}" != "DR_CUTOVER_COMMIT_V2" || -z "${engine_session_id}" \
        || -z "${commit_attempt_id}" || ! "${commit_envelope_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json \
      "dr-cutover-commit-status" "${plan}" "${run}" \
      "DR_CUTOVER_COMMIT_INVALID" "complete cutover commit status identity is required" 2
    return 2
  fi
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  commit_path="$(ftctl_dr_runtime_cutover_commit_state_path "${plan}" "${run}")"
  [[ -f "${run_path}" && -f "${commit_path}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json \
      "dr-cutover-commit-status" "${plan}" "${run}" \
      "DR_CUTOVER_COMMIT_NOT_SUBMITTED" "cutover commit was not submitted to FTCTL" 44
    return 44
  }
  journal_session="$(ftctl_state_read_kv "${commit_path}" "engine_session_id" 2>/dev/null || true)"
  journal_attempt="$(ftctl_state_read_kv "${commit_path}" "commit_attempt_id" 2>/dev/null || true)"
  journal_sha="$(ftctl_state_read_kv "${commit_path}" "commit_envelope_sha256" 2>/dev/null || true)"
  if [[ "${journal_session}" != "${engine_session_id}" || "${journal_attempt}" != "${commit_attempt_id}" \
        || "${journal_sha}" != "${commit_envelope_sha256}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json \
      "dr-cutover-commit-status" "${plan}" "${run}" \
      "DR_CUTOVER_COMMIT_IDENTITY_MISMATCH" "cutover commit identity does not match the durable journal" 79
    return 79
  fi
  phase="$(ftctl_state_read_kv "${commit_path}" "phase" 2>/dev/null || true)"
  outcome="$(ftctl_state_read_kv "${commit_path}" "outcome" 2>/dev/null || true)"
  state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "state")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "active_side")"
  if [[ "${phase}" =~ ^(PREPARED|AUTHORITY_APPLIED)$ && "${state}" == "FAILED_OVER" && "${active_side}" == "TARGET" ]]; then
    local now
    now="$(ftctl_now_iso8601)"
    ftctl_dr_runtime_path_set "${run_path}" \
      "cutover_commit_phase=ACKNOWLEDGED" "cutover_commit_outcome=ACKNOWLEDGED" \
      "engine_ack_state=ACKNOWLEDGED" "engine_ack_at=${now}" "updated_at=${now}" || return 2
    ftctl_state_write_kv_all "${commit_path}" \
      "version=2" "contract_version=${contract_version}" "plan=${plan}" "run=${run}" \
      "engine_session_id=${engine_session_id}" \
      "cloud_session_id=$(ftctl_state_read_kv "${commit_path}" "cloud_session_id" 2>/dev/null || true)" \
      "checkpoint_sequence=$(ftctl_state_read_kv "${commit_path}" "checkpoint_sequence" 2>/dev/null || true)" \
      "manifest_sha256=$(ftctl_state_read_kv "${commit_path}" "manifest_sha256" 2>/dev/null || true)" \
      "authority_generation=$(ftctl_state_read_kv "${commit_path}" "authority_generation" 2>/dev/null || true)" \
      "commit_attempt_id=${commit_attempt_id}" "commit_envelope_sha256=${commit_envelope_sha256}" \
      "target_vm_id=$(ftctl_state_read_kv "${commit_path}" "target_vm_id" 2>/dev/null || true)" \
      "target_external_ref=$(ftctl_state_read_kv "${commit_path}" "target_external_ref" 2>/dev/null || true)" \
      "target_power_state=$(ftctl_state_read_kv "${commit_path}" "target_power_state" 2>/dev/null || true)" \
      "boot_validation_state=$(ftctl_state_read_kv "${commit_path}" "boot_validation_state" 2>/dev/null || true)" \
      "source_fence_state=$(ftctl_state_read_kv "${commit_path}" "source_fence_state" 2>/dev/null || true)" \
      "source_power_state=$(ftctl_state_read_kv "${commit_path}" "source_power_state" 2>/dev/null || true)" \
      "phase=ACKNOWLEDGED" "outcome=ACKNOWLEDGED" "acknowledged_at=${now}" "updated_at=${now}" || return 2
    ftctl_dr_runtime_publish_status "${run_path}" "$(ftctl_dr_runtime_status_path "${plan}")" || return 2
    phase="ACKNOWLEDGED"
    outcome="ACKNOWLEDGED"
  fi
  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-cutover-commit-status","result":"ok","plan_uuid":"%s","run_uuid":"%s","commit_state":"%s","commit_outcome":"%s","state":"%s","active_side":"%s","retryable":%s}\n' \
      "$(ftctl__json_escape "${plan}")" "$(ftctl__json_escape "${run}")" \
      "$(ftctl__json_escape "${phase}")" "$(ftctl__json_escape "${outcome}")" \
      "$(ftctl__json_escape "${state}")" "$(ftctl__json_escape "${active_side}")" \
      "$([[ "${outcome}" == "ACKNOWLEDGED" ]] && printf false || printf true)"
  else
    printf 'dr-cutover-commit-status: plan=%s run=%s state=%s outcome=%s\n' \
      "${plan}" "${run}" "${phase}" "${outcome}"
  fi
}

ftctl_dr_runtime_update_failback_session_commit_ack() {
  local session_path="${1-}" active_path="${2-}" authority_generation="${3-}"
  local boot_validation_state="${4-}" now="${5-}" control_generation="${6-}"
  local control_ack_generation="${7-}"
  [[ -f "${session_path}" ]] || return 0
  python3 - "${session_path}" "${active_path}" "${authority_generation}" "${boot_validation_state}" "${now}" \
    "${control_generation}" "${control_ack_generation}" <<'PY'
import json
import os
import shutil
import sys

path, active_path, generation, validation_state, now, control_generation, ack_generation = sys.argv[1:8]
with open(path, "r", encoding="utf-8") as fh:
    session = json.load(fh)
session["state"] = "PROTECTION_RESUMING"
session["activeSide"] = "SOURCE"
session["cloudAuthorityGeneration"] = int(generation)
session["bootValidationState"] = validation_state
session["sourcePowerState"] = "POWERED_ON"
session["targetPowerState"] = "POWERED_OFF"
session["engineAckState"] = "ACKNOWLEDGED"
session["engineAckAt"] = now
session["commitOutcome"] = "ACKNOWLEDGED"
session["schedulerGeneration"] = int(control_generation)
session["schedulerAckGeneration"] = int(ack_generation)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(session, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.makedirs(os.path.dirname(active_path), exist_ok=True)
shutil.copyfile(path, active_path)
PY
}

ftctl_dr_runtime_reconcile_failback_commit() {
  local plan="${1-}" run="${2-}" session_id="${3-}"
  local run_path status_path commit_path session_path active_path control_path ack_path now
  local commit_plan commit_run commit_session commit_phase commit_outcome
  local source_power_state target_power_state authority_generation checkpoint_sequence
  local baseline_generation evidence_run contract_version commit_attempt_id commit_envelope_sha256
  local control_generation control_command control_owner
  local ack_generation ack_state ack_owner ack_request_run ack_session ack_epoch ack_pid ack_start_ticks ack_owner_matched
  local active_session active_epoch active_pid active_start_ticks

  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  commit_path="$(ftctl_dr_runtime_failback_commit_state_path "${plan}" "${run}")"
  session_path="$(ftctl_dr_runtime_failback_session_path "${plan}" "${run}")"
  active_path="$(ftctl_dr_runtime_active_failback_session_path "${plan}")"
  control_path="$(ftctl_dr_scheduler_control_path "${plan}")"
  ack_path="$(ftctl_dr_scheduler_control_ack_path "${plan}")"
  [[ -f "${run_path}" && -f "${commit_path}" ]] || return 1

  ftctl_dr_scheduler_lock_acquire "${plan}" "failback-commit" 206 \
    "${FTCTL_DR_TRANSITION_LOCK_TIMEOUT_SEC}" "reconcile:${run}" || return $?

  commit_plan="$(ftctl_state_read_kv "${commit_path}" "plan" 2>/dev/null || true)"
  commit_run="$(ftctl_state_read_kv "${commit_path}" "run" 2>/dev/null || true)"
  commit_session="$(ftctl_state_read_kv "${commit_path}" "session_id" 2>/dev/null || true)"
  commit_phase="$(ftctl_state_read_kv "${commit_path}" "phase" 2>/dev/null || true)"
  commit_outcome="$(ftctl_state_read_kv "${commit_path}" "outcome" 2>/dev/null || true)"
  authority_generation="$(ftctl_state_read_kv "${commit_path}" "authority_generation" 2>/dev/null || true)"
  checkpoint_sequence="$(ftctl_state_read_kv "${commit_path}" "checkpoint_sequence" 2>/dev/null || true)"
  source_power_state="$(ftctl_state_read_kv "${commit_path}" "source_power_state" 2>/dev/null || true)"
  target_power_state="$(ftctl_state_read_kv "${commit_path}" "target_power_state" 2>/dev/null || true)"
  baseline_generation="$(ftctl_state_read_kv "${commit_path}" "baseline_generation" 2>/dev/null || true)"
  evidence_run="$(ftctl_state_read_kv "${commit_path}" "evidence_run" 2>/dev/null || true)"
  contract_version="$(ftctl_state_read_kv "${commit_path}" "contract_version" 2>/dev/null || true)"
  commit_attempt_id="$(ftctl_state_read_kv "${commit_path}" "commit_attempt_id" 2>/dev/null || true)"
  commit_envelope_sha256="$(ftctl_state_read_kv "${commit_path}" "commit_envelope_sha256" 2>/dev/null || true)"

  if [[ "${commit_phase}" == "ACKNOWLEDGED" && "${commit_outcome}" == "ACKNOWLEDGED" ]]; then
    ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
    return 0
  fi
  if [[ "${commit_plan}" != "${plan}" || "${commit_run}" != "${run}" \
        || "${commit_session}" != "${session_id}" \
        || ! "${commit_phase}" =~ ^(AUTHORITY_COMMITTED|SCHEDULER_RESUMING)$ \
        || ! "${commit_outcome}" =~ ^(PENDING|UNKNOWN)$ \
        || "${source_power_state}" != "POWERED_ON" \
        || "${target_power_state}" != "POWERED_OFF" ]]; then
    ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
    return 79
  fi

  if ftctl_dr_runtime_ack_remote_source_failback_commit \
      "${plan}" "${run}" "${run_path}" "${status_path}" "${commit_path}" \
      "${session_id}" "${checkpoint_sequence}" "${authority_generation}" \
      "${baseline_generation}" "${evidence_run}" "${contract_version}" \
      "${commit_attempt_id}" "${commit_envelope_sha256}"; then
    ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
    return 0
  fi

  if [[ ! -f "${control_path}" || ! -f "${ack_path}" ]]; then
    ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
    return 1
  fi

  control_generation="$(ftctl_state_read_kv "${control_path}" "generation" 2>/dev/null || true)"
  control_command="$(ftctl_state_read_kv "${control_path}" "command" 2>/dev/null || true)"
  control_owner="$(ftctl_state_read_kv "${control_path}" "owner_run" 2>/dev/null || true)"
  ack_generation="$(ftctl_state_read_kv "${ack_path}" "generation" 2>/dev/null || true)"
  ack_state="$(ftctl_state_read_kv "${ack_path}" "state" 2>/dev/null || true)"
  ack_owner="$(ftctl_state_read_kv "${ack_path}" "owner_run" 2>/dev/null || true)"
  ack_request_run="$(ftctl_state_read_kv "${ack_path}" "request_run_uuid" 2>/dev/null || true)"
  ack_session="$(ftctl_state_read_kv "${ack_path}" "scheduler_session_uuid" 2>/dev/null || true)"
  ack_epoch="$(ftctl_state_read_kv "${ack_path}" "lease_epoch" 2>/dev/null || true)"
  ack_pid="$(ftctl_state_read_kv "${ack_path}" "worker_pid" 2>/dev/null || true)"
  ack_start_ticks="$(ftctl_state_read_kv "${ack_path}" "worker_start_ticks" 2>/dev/null || true)"
  ack_owner_matched="$(ftctl_state_read_kv "${ack_path}" "owner_matched" 2>/dev/null || true)"
  active_session="$(ftctl_dr_scheduler_active_value "${plan}" "scheduler_session_uuid")"
  active_epoch="$(ftctl_dr_scheduler_active_value "${plan}" "lease_epoch")"
  active_pid="$(ftctl_dr_scheduler_active_value "${plan}" "pid")"
  active_start_ticks="$(ftctl_dr_scheduler_active_value "${plan}" "start_ticks")"

  if [[ ! "${control_generation}" =~ ^[1-9][0-9]*$ \
        || "${control_command}" != "run" || "${control_owner}" != "${run}" \
        || "${ack_generation}" != "${control_generation}" \
        || "${ack_state}" != "RUNNING" \
        || "${ack_owner}" != "${run}" || "${ack_request_run}" != "${run}" \
        || "${ack_owner_matched}" != "true" \
        || -z "${ack_session}" || "${ack_session}" != "${active_session}" \
        || -z "${ack_epoch}" || "${ack_epoch}" != "${active_epoch}" \
        || -z "${ack_pid}" || "${ack_pid}" != "${active_pid}" \
        || -z "${ack_start_ticks}" || "${ack_start_ticks}" != "${active_start_ticks}" ]] \
        || ! ftctl_dr_scheduler_active_worker_valid "${plan}" "${ack_session}"; then
    ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
    return 1
  fi

  now="$(ftctl_now_iso8601)"
  ftctl_state_write_kv_all "${commit_path}" \
    "version=3" "plan=${plan}" "run=${run}" "session_id=${session_id}" \
    "checkpoint_sequence=${checkpoint_sequence}" "authority_generation=${authority_generation}" \
    "baseline_generation=${baseline_generation}" "evidence_run=${evidence_run}" \
    "contract_version=${contract_version}" "commit_attempt_id=${commit_attempt_id}" \
    "commit_envelope_sha256=${commit_envelope_sha256}" \
    "phase=ACKNOWLEDGED" "outcome=ACKNOWLEDGED" \
    "control_generation=${control_generation}" "control_ack_generation=${ack_generation}" \
    "ack_owner_run=${ack_owner}" "ack_scheduler_session_uuid=${ack_session}" \
    "ack_lease_epoch=${ack_epoch}" "ack_worker_pid=${ack_pid}" \
    "ack_worker_start_ticks=${ack_start_ticks}" \
    "source_power_state=${source_power_state}" "target_power_state=${target_power_state}" \
    "recovered_from_late_ack=true" "recovered_at=${now}" "updated_at=${now}" || {
      ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
      return 2
    }
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=SYNCING" "step=protection-resuming" \
    "failback_phase=PROTECTION_RESUMING" "cloud_lifecycle_state=COMMITTED" \
    "active_side=SOURCE" "source_power_state=POWERED_ON" "target_power_state=POWERED_OFF" \
    "engine_ack_state=ACKNOWLEDGED" "engine_ack_at=${now}" \
    "failback_commit_outcome=ACKNOWLEDGED" "failback_commit_phase=ACKNOWLEDGED" \
    "failback_commit_dispatch_state=ACKNOWLEDGED" \
    "control_generation=${control_generation}" "control_ack_generation=${ack_generation}" \
    "scheduler_state=RUNNING" "retryable=false" "error_code=" "error_message=" \
    "updated_at=${now}" || {
      ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
      return 2
    }
  ftctl_dr_runtime_path_set "${status_path}" \
    "state=SYNCING" "step=protection-resuming" \
    "failback_phase=PROTECTION_RESUMING" "cloud_lifecycle_state=COMMITTED" \
    "active_side=SOURCE" "source_power_state=POWERED_ON" "target_power_state=POWERED_OFF" \
    "engine_ack_state=ACKNOWLEDGED" "engine_ack_at=${now}" \
    "failback_commit_outcome=ACKNOWLEDGED" "failback_commit_phase=ACKNOWLEDGED" \
    "failback_commit_dispatch_state=ACKNOWLEDGED" \
    "control_generation=${control_generation}" "control_ack_generation=${ack_generation}" \
    "scheduler_state=RUNNING" "retryable=false" "error_code=" "error_message=" \
    "updated_at=${now}" || {
      ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
      return 2
    }
  ftctl_dr_runtime_update_failback_session_commit_ack "${session_path}" "${active_path}" \
    "${authority_generation}" "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "boot_validation_state")" \
    "${now}" "${control_generation}" "${ack_generation}" || {
      ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
      return 2
    }
  ftctl_log_event "dr-runtime" "dr.failback.commit.recovered" "ok" "" "" \
    "plan=${plan} run=${run} session=${session_id} generation=${control_generation}"
  ftctl_dr_scheduler_lock_release "${plan}" "failback-commit" 206
  return 0
}

ftctl_dr_runtime_complete_failback_resume_checkpoint() {
  local plan="${1-}" completed="${2-}" sequence_path owner_run minimum
  local run_path status_path commit_path session_path active_path now session_id
  [[ -n "${plan}" && "${completed}" =~ ^[1-9][0-9]*$ ]] || return 2
  sequence_path="$(ftctl_dr_scheduler_sequence_path "${plan}")"
  owner_run="$(ftctl_state_read_kv "${sequence_path}" "immediate_cycle_owner_run" 2>/dev/null || true)"
  minimum="$(ftctl_state_read_kv "${sequence_path}" "minimum_completed_checkpoint_sequence" 2>/dev/null || true)"
  [[ -n "${owner_run}" && "${minimum}" =~ ^[1-9][0-9]*$ && "${completed}" -ge "${minimum}" ]] || return 0
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${owner_run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  [[ -f "${run_path}" && -f "${status_path}" ]] || return 0
  [[ "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "active_side")" == "SOURCE" \
        && "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "engine_ack_state")" == "ACKNOWLEDGED" \
        && "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "source_power_state")" == "POWERED_ON" \
        && "$(ftctl_dr_runtime_state_get_from_path "${run_path}" "target_power_state")" == "POWERED_OFF" ]] || return 0

  now="$(ftctl_now_iso8601)"
  session_id="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failback_session_id")"
  commit_path="$(ftctl_dr_runtime_failback_commit_state_path "${plan}" "${owner_run}")"
  session_path="$(ftctl_dr_runtime_failback_session_path "${plan}" "${owner_run}")"
  active_path="$(ftctl_dr_runtime_active_failback_session_path "${plan}")"

  ftctl_dr_runtime_path_set "${run_path}" \
    "state=READY" "step=completed" "progress=100" \
    "failback_phase=COMPLETED" "cloud_lifecycle_state=COMPLETED" \
    "active_side=SOURCE" "scheduler_state=RUNNING" "scheduler_health=HEALTHY" \
    "immediate_cycle_pending=false" "resume_checkpoint_completed_sequence=${completed}" \
    "resume_checkpoint_completed_at=${now}" "failback_completed_at=${now}" \
    "reverse_evidence_run_uuid=${owner_run}" \
    "worker_state=TERMINAL_PUBLISHED" "worker_exit_code=0" \
    "transfer_activity_state=IDLE" "terminal_source=ENGINE_TERMINAL" \
    "terminal_version=1" "terminal_authoritative=true" \
    "retryable=false" "error_code=" "error_message=" "updated_at=${now}" || return 2
  ftctl_dr_runtime_path_set "${status_path}" \
    "state=READY" "step=target-checkpoint-ready" "progress=100" \
    "failback_phase=COMPLETED" "cloud_lifecycle_state=COMPLETED" \
    "active_side=SOURCE" "scheduler_state=RUNNING" "scheduler_health=HEALTHY" \
    "immediate_cycle_pending=false" "resume_checkpoint_completed_sequence=${completed}" \
    "resume_checkpoint_completed_at=${now}" "failback_completed_at=${now}" \
    "reverse_evidence_run_uuid=${owner_run}" \
    "transfer_activity_state=IDLE" "terminal_source=ENGINE_TERMINAL" \
    "terminal_version=1" "terminal_authoritative=true" \
    "retryable=false" "error_code=" "error_message=" "updated_at=${now}" || return 2
  if [[ -f "${commit_path}" ]]; then
    ftctl_state_set_path "${commit_path}" \
      "phase=COMPLETED" "outcome=ACKNOWLEDGED" \
      "resume_checkpoint_completed_sequence=${completed}" \
      "resume_checkpoint_completed_at=${now}" "updated_at=${now}" || return 2
  fi
  if [[ -f "${session_path}" ]]; then
    python3 - "${session_path}" "${active_path}" "${completed}" "${now}" <<'PY' || return 2
import json
import os
import shutil
import sys

path, active_path, completed, now = sys.argv[1:5]
with open(path, "r", encoding="utf-8") as handle:
    session = json.load(handle)
session["state"] = "COMPLETED"
session["activeSide"] = "SOURCE"
session["postFailbackCheckpointSequence"] = int(completed)
session["protectionResumeVerifiedAt"] = now
session["completedAt"] = now
session["engineAckState"] = "ACKNOWLEDGED"
session["commitOutcome"] = "ACKNOWLEDGED"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(session, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
os.makedirs(os.path.dirname(active_path), exist_ok=True)
shutil.copyfile(path, active_path)
PY
  fi
  ftctl_log_event "dr-runtime" "dr.failback.resume-checkpoint" "ok" "" "" \
    "plan=${plan} run=${owner_run} session=${session_id} checkpoint=${completed} state=COMPLETED"
}

ftctl_dr_runtime_failback_commit_envelope_sha256() {
  python3 - "$@" <<'PY'
import hashlib
import json
import sys

(contract, plan, run, session, checkpoint, authority, baseline, evidence_run,
 attempt, target_power, source_power, boot_state) = sys.argv[1:]
payload = {
    "authorityGeneration": int(authority),
    "baselineGeneration": int(baseline),
    "bootValidationState": boot_state,
    "checkpointSequence": int(checkpoint),
    "commitAttemptId": attempt,
    "contractVersion": contract,
    "evidenceRunUuid": evidence_run,
    "failbackSessionId": session,
    "planUuid": plan,
    "runUuid": run,
    "sourcePowerState": source_power,
    "targetPowerState": target_power,
}
canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
print(hashlib.sha256(canonical.encode("utf-8")).hexdigest())
PY
}

ftctl_dr_runtime_profile_is_windows_guest() {
  local profile_file="${1-}" field guest_id=""
  [[ -n "${profile_file}" && -f "${profile_file}" ]] || return 1
  for field in target.hardware.guestId target.vm.guestId source.hardware.guestId source.vm.guestId; do
    guest_id="$(ftctl_dr_runtime_profile_value "${profile_file}" "${field}" 2>/dev/null || true)"
    [[ -n "${guest_id}" ]] && break
  done
  [[ "$(tr '[:upper:]' '[:lower:]' <<< "${guest_id}")" == *windows* ]]
}

ftctl_dr_runtime_failback_requires_vcenter_guest_heartbeat() {
  local profile_file="${1-}" provider_pair=""
  ftctl_dr_runtime_profile_is_windows_guest "${profile_file}" || return 1
  provider_pair="$(ftctl_dr_runtime_profile_value "${profile_file}" "providerPair" 2>/dev/null || true)"
  [[ "${provider_pair}" == "ABLESTACK_TO_ABLESTACK" ]] && return 1
  [[ "${provider_pair}" == *_TO_VMWARE || -z "${provider_pair}" ]]
}

ftctl_dr_runtime_ack_remote_source_failback_commit() {
  local plan="${1-}" run="${2-}" run_path="${3-}" status_path="${4-}" commit_path="${5-}"
  local session_id="${6-}" checkpoint_sequence="${7-}" authority_generation="${8-}"
  local baseline_generation="${9-}" evidence_run="${10-}" contract_version="${11-}"
  local commit_attempt_id="${12-}" commit_envelope_sha256="${13-}" now profile_file worker_role
  local session_path active_path boot_validation_state

  profile_file="$(ftctl_dr_runtime_profile_path "${plan}")"
  ftctl_dr_runtime_remote_source_transition "${profile_file}" || return 1
  worker_role="$(ftctl_dr_runtime_local_worker_role "${plan}")"
  [[ "${worker_role}" == "target" ]] || return 1

  now="$(ftctl_now_iso8601)"
  ftctl_state_write_kv_all "${commit_path}" \
    "version=3" "plan=${plan}" "run=${run}" "session_id=${session_id}" \
    "checkpoint_sequence=${checkpoint_sequence}" "authority_generation=${authority_generation}" \
    "baseline_generation=${baseline_generation}" "evidence_run=${evidence_run}" \
    "contract_version=${contract_version}" "commit_attempt_id=${commit_attempt_id}" \
    "commit_envelope_sha256=${commit_envelope_sha256}" \
    "phase=ACKNOWLEDGED" "outcome=ACKNOWLEDGED" \
    "scheduler_transition_scope=REMOTE_SOURCE" \
    "updated_at=${now}" || return 2
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=READY" "step=remote-source-protection-resume-pending" "progress=90" \
    "failback_phase=PROTECTION_RESUMING" "cloud_lifecycle_state=PROTECTION_RESUMING" \
    "active_side=SOURCE" "source_power_state=POWERED_ON" "target_power_state=POWERED_OFF" \
    "engine_ack_state=ACKNOWLEDGED" "engine_ack_at=${now}" \
    "failback_commit_outcome=ACKNOWLEDGED" "failback_commit_phase=ACKNOWLEDGED" \
    "failback_commit_dispatch_state=ACKNOWLEDGED" \
    "scheduler_state=STOPPED" "scheduler_desired_state=STOPPED" \
    "scheduler_health=SUPPRESSED" "replication_activity=STOPPED" \
    "retryable=false" "retry_after_sec=" "error_code=" "error_message=" \
    "updated_at=${now}" || return 2
  cp -f "${run_path}" "${status_path}" || return 2
  chmod 0644 "${status_path}" 2>/dev/null || true
  session_path="$(ftctl_dr_runtime_failback_session_path "${plan}" "${run}")"
  active_path="$(ftctl_dr_runtime_active_failback_session_path "${plan}")"
  boot_validation_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "boot_validation_state")"
  ftctl_dr_runtime_update_failback_session_commit_ack "${session_path}" "${active_path}" \
    "${authority_generation}" "${boot_validation_state}" "${now}" "0" "0" || return 2
  ftctl_log_event "dr-runtime" "dr.failback.commit.remote-source" "ok" "" "" \
    "plan=${plan} run=${run} session=${session_id} checkpoint=${checkpoint_sequence} authority=${authority_generation}"
  return 0
}

ftctl_dr_runtime_failback_commit() {
  local plan="${1-}" run="${2-}" session_id="${3-}" checkpoint_sequence="${4-}"
  local authority_generation="${5-}" target_power_state="${6-}" source_power_state="${7-}"
  local boot_validation_state="${8-}" json="${9-0}"
  local resume_baseline_checkpoint_sequence="${10-${checkpoint_sequence}}"
  local minimum_completed_checkpoint_sequence="${11-}"
  local force_immediate_cycle="${12-true}"
  local contract_version="${13-}" baseline_generation="${14-}" evidence_run="${15-}"
  local commit_attempt_id="${16-}" commit_envelope_sha256="${17-}"
  local run_path status_path session_path active_path commit_path state current_session current_checkpoint now rc=0
  local commit_phase control_generation control_ack_generation calculated_envelope_sha256 reverse_profile_path

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  if [[ "${contract_version}" != "DR_FAILBACK_COMMIT_V1" || -z "${session_id}" || ! "${checkpoint_sequence}" =~ ^[0-9]+$ \
        || ! "${authority_generation}" =~ ^[0-9]+$ || ! "${baseline_generation}" =~ ^[0-9]+$ \
        || "${evidence_run}" != "${run}" || -z "${commit_attempt_id}" \
        || ! "${commit_envelope_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failback-commit" "${plan}" "${run}" \
      "DR_FAILBACK_COMMIT_INVALID" "complete failback commit envelope v1 is required" 2
    return 2
  fi
  calculated_envelope_sha256="$(ftctl_dr_runtime_failback_commit_envelope_sha256 \
    "${contract_version}" "${plan}" "${run}" "${session_id}" "${checkpoint_sequence}" \
    "${authority_generation}" "${baseline_generation}" "${evidence_run}" "${commit_attempt_id}" \
    "${target_power_state}" "${source_power_state}" "${boot_validation_state}")" || return 2
  if [[ "${calculated_envelope_sha256}" != "${commit_envelope_sha256}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failback-commit" "${plan}" "${run}" \
      "DR_FAILBACK_COMMIT_ENVELOPE_MISMATCH" "Failback commit envelope SHA-256 does not match" 79
    return 79
  fi
  [[ "${resume_baseline_checkpoint_sequence}" =~ ^[0-9]+$ ]] || resume_baseline_checkpoint_sequence="${checkpoint_sequence}"
  [[ "${minimum_completed_checkpoint_sequence}" =~ ^[0-9]+$ ]] \
    || minimum_completed_checkpoint_sequence=$((resume_baseline_checkpoint_sequence + 1))
  if (( minimum_completed_checkpoint_sequence <= resume_baseline_checkpoint_sequence )); then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failback-commit" "${plan}" "${run}" \
      "DR_FAILBACK_RESUME_SEQUENCE_INVALID" "minimum completed checkpoint must be greater than the resume baseline" 2
    return 2
  fi
  [[ "${target_power_state}" == "POWERED_OFF" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failback-commit" "${plan}" "${run}" \
      "DR_FAILBACK_TARGET_STILL_RUNNING" "Cloud target must be POWERED_OFF before source authority commit" 78
    return 78
  }
  [[ "${source_power_state}" == "POWERED_ON" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failback-commit" "${plan}" "${run}" \
      "DR_FAILBACK_SOURCE_NOT_RUNNING" "Cloud source must be POWERED_ON before source authority commit" 78
    return 78
  }
  reverse_profile_path="$(ftctl_dr_runtime_reverse_profile_path "${plan}" "${run}" "failback")"
  if ftctl_dr_runtime_failback_requires_vcenter_guest_heartbeat "${reverse_profile_path}" \
        && [[ "${boot_validation_state}" != "GUEST_HEARTBEAT_VALIDATED" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failback-commit" "${plan}" "${run}" \
      "DR_FAILBACK_WINDOWS_GUEST_HEARTBEAT_REQUIRED" \
      "Windows failback requires vCenter guest heartbeat validation" 78
    return 78
  fi
  case "${boot_validation_state}" in
    POWER_STATE_VALIDATED|GUEST_HEARTBEAT_VALIDATED) ;;
    *)
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failback-commit" "${plan}" "${run}" \
        "DR_FAILBACK_BOOT_VALIDATION_INCOMPLETE" "Cloud source boot validation is incomplete" 78
      return 78
      ;;
  esac

  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  session_path="$(ftctl_dr_runtime_failback_session_path "${plan}" "${run}")"
  active_path="$(ftctl_dr_runtime_active_failback_session_path "${plan}")"
  commit_path="$(ftctl_dr_runtime_failback_commit_state_path "${plan}" "${run}")"
  [[ -f "${run_path}" && -f "${status_path}" ]] || return 44
  state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "state")"
  current_session="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failback_session_id")"
  current_checkpoint="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failback_restore_point_sequence")"
  [[ "${current_session}" == "${session_id}" ]] || return 79
  [[ "${current_checkpoint}" == "${checkpoint_sequence}" ]] || return 79
  [[ "${state}" == "FAILBACK_DATA_READY" || "${state}" == "SYNCING" || "${state}" == "READY" ]] || return 79
  commit_phase="$(ftctl_state_read_kv "${commit_path}" "phase" 2>/dev/null || true)"
  if [[ "${commit_phase}" == "ACKNOWLEDGED" \
        && "$(ftctl_state_read_kv "${commit_path}" "session_id" 2>/dev/null || true)" == "${session_id}" \
        && "$(ftctl_state_read_kv "${commit_path}" "checkpoint_sequence" 2>/dev/null || true)" == "${checkpoint_sequence}" \
        && "$(ftctl_state_read_kv "${commit_path}" "authority_generation" 2>/dev/null || true)" == "${authority_generation}" ]]; then
    [[ "$(ftctl_state_read_kv "${commit_path}" "commit_attempt_id" 2>/dev/null || true)" == "${commit_attempt_id}" \
          && "$(ftctl_state_read_kv "${commit_path}" "commit_envelope_sha256" 2>/dev/null || true)" == "${commit_envelope_sha256}" ]] || return 79
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json \
      "dr-failback-commit" "ok" "${plan}" "${run}" "${run_path}" "0"
    return 0
  fi

  now="$(ftctl_now_iso8601)"
  ftctl_ensure_dir "$(dirname "${commit_path}")" "0755"
  ftctl_state_write_kv_all "${commit_path}" \
    "version=3" \
    "plan=${plan}" \
    "run=${run}" \
    "session_id=${session_id}" \
    "checkpoint_sequence=${checkpoint_sequence}" \
    "authority_generation=${authority_generation}" \
    "baseline_generation=${baseline_generation}" \
    "evidence_run=${evidence_run}" \
    "contract_version=${contract_version}" \
    "commit_attempt_id=${commit_attempt_id}" \
    "commit_envelope_sha256=${commit_envelope_sha256}" \
    "phase=PREPARED" \
    "outcome=PENDING" \
    "source_power_state=${source_power_state}" \
    "target_power_state=${target_power_state}" \
    "updated_at=${now}" || return 2
  ftctl_dr_runtime_path_set "${run_path}" \
    "action=dr-failback-commit" \
    "state=SYNCING" \
    "step=protection-resuming" \
    "progress=90" \
    "failback_phase=PROTECTION_RESUMING" \
    "cloud_lifecycle_state=COMMITTED" \
    "active_side=SOURCE" \
    "target_power_state=POWERED_OFF" \
    "target_promotion_state=STANDBY" \
    "source_power_state=POWERED_ON" \
    "source_promotion_state=PROMOTED" \
    "boot_validation_state=${boot_validation_state}" \
    "cloud_authority_generation=${authority_generation}" \
    "failback_commit_contract_version=${contract_version}" \
    "failback_commit_attempt_id=${commit_attempt_id}" \
    "failback_commit_envelope_sha256=${commit_envelope_sha256}" \
    "failback_commit_dispatch_state=JOURNALED" \
    "engine_ack_state=PENDING" \
    "engine_ack_at=" \
    "failback_commit_outcome=PENDING" \
    "failback_commit_phase=AUTHORITY_COMMITTED" \
    "resume_baseline_checkpoint_sequence=${resume_baseline_checkpoint_sequence}" \
    "minimum_completed_checkpoint_sequence=${minimum_completed_checkpoint_sequence}" \
    "immediate_cycle_pending=${force_immediate_cycle}" \
    "immediate_cycle_owner_run=${run}" \
    "rollback_state=NONE" \
    "source_promote_started_at=${now}" \
    "source_power_on_at=${now}" \
    "scheduler_state=STARTING" \
    "accepted=true" \
    "retryable=false" \
    "error_code=" \
    "error_message=" \
    "updated_at=${now}" || return 2
  ftctl_dr_runtime_path_set "${status_path}" \
    "state=SYNCING" "step=protection-resuming" "progress=90" \
    "failback_phase=PROTECTION_RESUMING" "cloud_lifecycle_state=COMMITTED" \
    "active_side=SOURCE" "target_power_state=POWERED_OFF" \
    "target_promotion_state=STANDBY" "source_power_state=POWERED_ON" \
    "source_promotion_state=PROMOTED" "boot_validation_state=${boot_validation_state}" \
    "cloud_authority_generation=${authority_generation}" "engine_ack_state=PENDING" \
    "failback_commit_contract_version=${contract_version}" \
    "failback_commit_attempt_id=${commit_attempt_id}" \
    "failback_commit_envelope_sha256=${commit_envelope_sha256}" \
    "failback_commit_dispatch_state=JOURNALED" \
    "engine_ack_at=" "failback_commit_outcome=PENDING" \
    "failback_commit_phase=AUTHORITY_COMMITTED" \
    "resume_baseline_checkpoint_sequence=${resume_baseline_checkpoint_sequence}" \
    "minimum_completed_checkpoint_sequence=${minimum_completed_checkpoint_sequence}" \
    "immediate_cycle_pending=${force_immediate_cycle}" \
    "immediate_cycle_owner_run=${run}" "scheduler_state=STARTING" \
    "retryable=false" "error_code=" "error_message=" "updated_at=${now}" || return 2
  ftctl_state_write_kv_all "${commit_path}" \
    "version=3" "plan=${plan}" "run=${run}" "session_id=${session_id}" \
    "checkpoint_sequence=${checkpoint_sequence}" "authority_generation=${authority_generation}" \
    "baseline_generation=${baseline_generation}" "evidence_run=${evidence_run}" \
    "contract_version=${contract_version}" "commit_attempt_id=${commit_attempt_id}" \
    "commit_envelope_sha256=${commit_envelope_sha256}" \
    "phase=AUTHORITY_COMMITTED" "outcome=PENDING" \
    "resume_baseline_checkpoint_sequence=${resume_baseline_checkpoint_sequence}" \
    "minimum_completed_checkpoint_sequence=${minimum_completed_checkpoint_sequence}" \
    "immediate_cycle_pending=${force_immediate_cycle}" \
    "source_power_state=${source_power_state}" "target_power_state=${target_power_state}" \
    "updated_at=$(ftctl_now_iso8601)" || return 2
  if ftctl_dr_runtime_ack_remote_source_failback_commit \
      "${plan}" "${run}" "${run_path}" "${status_path}" "${commit_path}" \
      "${session_id}" "${checkpoint_sequence}" "${authority_generation}" \
      "${baseline_generation}" "${evidence_run}" "${contract_version}" \
      "${commit_attempt_id}" "${commit_envelope_sha256}"; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json \
      "dr-failback-commit" "ok" "${plan}" "${run}" "${run_path}" "0"
    return 0
  fi
  if [[ "${force_immediate_cycle}" == "true" || "${force_immediate_cycle}" == "1" ]]; then
    ftctl_dr_scheduler_seed_resume_checkpoint "${plan}" \
      "${resume_baseline_checkpoint_sequence}" "${minimum_completed_checkpoint_sequence}" "${run}" || rc=$?
  fi
  if [[ "${rc}" == "0" ]] && command -v ftctl_dr_scheduler_resume_after_transition >/dev/null 2>&1; then
    ftctl_dr_scheduler_resume_after_transition "${plan}" "${run}" "failback-commit" "${run_path}" "${status_path}" || rc=$?
  fi
  now="$(ftctl_now_iso8601)"
  control_generation="$(ftctl_dr_scheduler_control_generation "${plan}")"
  control_ack_generation="$(ftctl_state_read_kv "$(ftctl_dr_scheduler_control_ack_path "${plan}")" "generation" 2>/dev/null || true)"
  [[ "${control_generation}" =~ ^[0-9]+$ ]] || control_generation=0
  [[ "${control_ack_generation}" =~ ^[0-9]+$ ]] || control_ack_generation=0
  ftctl_state_write_kv_all "${commit_path}" \
    "version=3" "plan=${plan}" "run=${run}" "session_id=${session_id}" \
    "checkpoint_sequence=${checkpoint_sequence}" "authority_generation=${authority_generation}" \
    "baseline_generation=${baseline_generation}" "evidence_run=${evidence_run}" \
    "contract_version=${contract_version}" "commit_attempt_id=${commit_attempt_id}" \
    "commit_envelope_sha256=${commit_envelope_sha256}" \
    "resume_baseline_checkpoint_sequence=${resume_baseline_checkpoint_sequence}" \
    "minimum_completed_checkpoint_sequence=${minimum_completed_checkpoint_sequence}" \
    "immediate_cycle_pending=${force_immediate_cycle}" \
    "phase=SCHEDULER_RESUMING" "outcome=$([[ "${rc}" == "0" ]] && printf PENDING || printf UNKNOWN)" \
    "control_generation=${control_generation}" "control_ack_generation=${control_ack_generation}" \
    "source_power_state=${source_power_state}" "target_power_state=${target_power_state}" \
    "updated_at=${now}" || true
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=SYNCING" "step=commit-verifying" "failback_phase=COMMIT_VERIFYING" \
    "cloud_lifecycle_state=COMMIT_VERIFYING" "engine_ack_state=UNKNOWN" \
    "failback_commit_outcome=UNKNOWN" "failback_commit_phase=SCHEDULER_RESUMING" \
    "control_generation=${control_generation}" \
    "control_ack_generation=${control_ack_generation}" \
    "error_code=DR_FAILBACK_COMMIT_ACK_PENDING" \
    "error_message=Failback commit acknowledgement is pending verification" \
    "retryable=true" "updated_at=${now}" || return 2
  ftctl_dr_runtime_path_set "${status_path}" \
    "state=SYNCING" "step=commit-verifying" "failback_phase=COMMIT_VERIFYING" \
    "cloud_lifecycle_state=COMMIT_VERIFYING" "engine_ack_state=UNKNOWN" \
    "failback_commit_outcome=UNKNOWN" "failback_commit_phase=SCHEDULER_RESUMING" \
    "control_generation=${control_generation}" \
    "control_ack_generation=${control_ack_generation}" \
    "error_code=DR_FAILBACK_COMMIT_ACK_PENDING" \
    "error_message=Failback commit acknowledgement is pending verification" \
    "retryable=true" "updated_at=${now}" || return 2
  if ftctl_dr_runtime_reconcile_failback_commit "${plan}" "${run}" "${session_id}"; then
    ftctl_log_event "dr-runtime" "dr.failback.commit" "ok" "" "" \
      "plan=${plan} run=${run} session=${session_id} generation=${authority_generation} control_generation=${control_generation}"
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json \
      "dr-failback-commit" "ok" "${plan}" "${run}" "${run_path}" "0"
    return 0
  fi
  [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json \
    "dr-failback-commit" "unknown" "${plan}" "${run}" "${run_path}" "0"
  [[ "${rc}" != "0" ]] && return "${rc}"
  return 21
}

ftctl_dr_runtime_failback_commit_status() {
  local plan="${1-}" run="${2-}" session_id="${3-}" contract_version="${4-}"
  local commit_attempt_id="${5-}" commit_envelope_sha256="${6-}" json="${7-0}"
  local run_path commit_path current_session journal_attempt journal_sha
  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  commit_path="$(ftctl_dr_runtime_failback_commit_state_path "${plan}" "${run}")"
  current_session="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failback_session_id")"
  [[ "${contract_version}" == "DR_FAILBACK_COMMIT_V1" && -n "${session_id}" && "${current_session}" == "${session_id}" \
        && -n "${commit_attempt_id}" && "${commit_envelope_sha256}" =~ ^[0-9a-f]{64}$ ]] || return 79
  [[ -f "${commit_path}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json \
      "dr-failback-commit-status" "${plan}" "${run}" \
      "DR_FAILBACK_COMMIT_NOT_SUBMITTED" "Failback commit was not submitted to FTCTL" 44
    return 44
  }
  journal_attempt="$(ftctl_state_read_kv "${commit_path}" "commit_attempt_id" 2>/dev/null || true)"
  journal_sha="$(ftctl_state_read_kv "${commit_path}" "commit_envelope_sha256" 2>/dev/null || true)"
  [[ "${journal_attempt}" == "${commit_attempt_id}" && "${journal_sha}" == "${commit_envelope_sha256}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json \
      "dr-failback-commit-status" "${plan}" "${run}" \
      "DR_FAILBACK_COMMIT_IDENTITY_MISMATCH" "Failback commit identity does not match the durable journal" 79
    return 79
  }
  ftctl_dr_runtime_reconcile_failback_commit "${plan}" "${run}" "${session_id}" || true
  [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json \
    "dr-failback-commit-status" "ok" "${plan}" "${run}" "${run_path}" "0"
}

ftctl_dr_runtime_failback_abort() {
  local plan="${1-}" run="${2-}" session_id="${3-}" phase="${4-commit}"
  local target_power_state="${5-POWERED_ON}" source_power_state="${6-POWERED_OFF}" json="${7-0}"
  local run_path status_path current_session current_rollback_state current_failback_phase now generation
  if [[ "${phase}" == "0" || "${phase}" == "1" ]]; then
    json="${phase}"
    phase="commit"
  fi
  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  current_session="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failback_session_id")"
  [[ -n "${session_id}" && "${current_session}" == "${session_id}" ]] || return 79
  current_rollback_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "rollback_state")"
  current_failback_phase="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failback_phase")"
  if [[ "${current_rollback_state}" == "COMPLETED" || "${current_failback_phase}" == "ABORTED" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json \
      "dr-failback-abort" "ok" "${plan}" "${run}" "${run_path}" "0"
    return 0
  fi
  now="$(ftctl_now_iso8601)"
  generation="$(ftctl_dr_scheduler_request_and_wait "${plan}" "stop" "STOPPED" \
    "failback-abort-${phase}" "${run}" "false")" || {
      ftctl_dr_runtime_path_set "${run_path}" \
        "failback_phase=COMMIT_UNCERTAIN" "cloud_lifecycle_state=COMMIT_UNCERTAIN" \
        "rollback_state=FENCE_FAILED" "failback_commit_outcome=UNKNOWN" \
        "error_code=DR_FAILBACK_ROLLBACK_FENCE_FAILED" \
        "error_message=Scheduler STOPPED acknowledgement was not received" \
        "retryable=false" "updated_at=$(ftctl_now_iso8601)" || true
      ftctl_dr_runtime_publish_status "${run_path}" "${status_path}" 2>/dev/null || true
      [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json \
        "dr-failback-abort" "error" "${plan}" "${run}" "${run_path}" "0"
      return 21
    }
  ftctl_dr_runtime_path_set "${run_path}" \
    "scheduler_state=STOPPED" "scheduler_desired_state=STOPPED" \
    "control_state=STOPPED" "control_generation=${generation}" \
    "control_ack_generation=${generation}" "rollback_generation=${generation}" \
    "rollback_state=FENCED" "failback_phase=ROLLBACK_FENCING" \
    "cloud_lifecycle_state=ROLLBACK_FENCING" "updated_at=$(ftctl_now_iso8601)" || return 2
  ftctl_dr_runtime_publish_status "${run_path}" "${status_path}" || return 2
  if [[ "${phase}" == "prepare" ]]; then
    ftctl_log_event "dr-runtime" "dr.failback.abort.prepare" "ok" "" "" \
      "plan=${plan} run=${run} session=${session_id} generation=${generation}"
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json \
      "dr-failback-abort" "ok" "${plan}" "${run}" "${run_path}" "0"
    return 0
  fi
  [[ "${phase}" == "commit" ]] || return 2
  [[ "${target_power_state}" == "POWERED_ON" && "${source_power_state}" == "POWERED_OFF" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json \
      "dr-failback-abort" "${plan}" "${run}" \
      "DR_FAILBACK_ROLLBACK_EVIDENCE_INVALID" \
      "Rollback commit requires SOURCE POWERED_OFF and TARGET POWERED_ON" 78
    return 78
  }
  ftctl_dr_runtime_path_set "${run_path}" \
    "action=dr-failback-abort" "state=FAILED_OVER" "step=failback-aborted" "progress=100" \
    "failback_phase=ABORTED" "cloud_lifecycle_state=ABORTED" "active_side=TARGET" \
    "source_power_state=${source_power_state}" "source_promotion_state=STANDBY" \
    "target_power_state=${target_power_state}" "target_promotion_state=PROMOTED" \
    "engine_ack_state=ABORTED" "failback_commit_outcome=ROLLED_BACK" \
    "failback_commit_phase=ROLLED_BACK" "rollback_state=COMPLETED" \
    "scheduler_state=STOPPED" "scheduler_desired_state=STOPPED" \
    "error_code=" "error_message=" "failed_component=" \
    "accepted=false" "retryable=false" "updated_at=${now}" || return 2
  ftctl_dr_runtime_apply_target_authority_terminal_state "${run_path}" "${now}" || return 2
  ftctl_dr_runtime_publish_status "${run_path}" "${status_path}" || return 2
  ftctl_log_event "dr-runtime" "dr.failback.abort" "warn" "" "" \
    "plan=${plan} run=${run} session=${session_id} generation=${generation}"
  [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "dr-failback-abort" "ok" "${plan}" "${run}" "${run_path}" "0"
}

ftctl_dr_runtime_failover_abort() {
  local plan="${1-}" run="${2-}" session_id="${3-}" json="${4-0}"
  local run_path status_path current_session current_state active_side target_power_state sequence now rc=0
  local profile_file remote_source_transition=0 scheduler_state="RUNNING" scheduler_recovery_state="RESUMED_AFTER_FAILOVER_ABORT"

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  profile_file="$(ftctl_dr_runtime_profile_path "${plan}")"
  if ftctl_dr_runtime_remote_source_transition "${profile_file}"; then
    remote_source_transition=1
  fi
  [[ -f "${run_path}" ]] || {
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failover-abort" "${plan}" "${run}" \
      "DR_CUTOVER_SESSION_NOT_FOUND" "FTCTL failover preparation runtime was not found" 44
    return 44
  }

  current_session="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_session_id")"
  current_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "state")"
  active_side="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "active_side")"
  target_power_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "target_power_state")"
  sequence="$(ftctl_dr_runtime_state_get_from_path "${run_path}" "failover_restore_point_sequence")"
  if [[ -n "${session_id}" && -n "${current_session}" && "${current_session}" != "${session_id}" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failover-abort" "${plan}" "${run}" \
      "DR_CUTOVER_SESSION_MISMATCH" "Cloud cutover session does not match FTCTL runtime" 79
    return 79
  fi
  if [[ "${current_state}" == "ABORTED" && "${active_side}" == "SOURCE" ]]; then
    now="$(ftctl_now_iso8601)"
    ftctl_dr_runtime_abort_failover_session "${plan}" "${run}" "${current_session:-${session_id}}" "${now}" || return $?
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "dr-failover-abort" "ok" "${plan}" "${run}" "${run_path}" "0"
    return 0
  fi
  if [[ "${active_side}" == "TARGET" || "${target_power_state}" == "POWERED_ON" ]]; then
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_error_json "dr-failover-abort" "${plan}" "${run}" \
      "DR_FAILOVER_ABORT_UNSAFE" "Target authority or power-on evidence prevents failover preparation abort" 78
    return 78
  fi

  now="$(ftctl_now_iso8601)"
  if command -v ftctl_dr_ablestack_cutover_quiesce_release >/dev/null 2>&1; then
    ftctl_dr_ablestack_cutover_quiesce_release "${plan}" "${run}" "${run_path}" "${status_path}" || rc=$?
  fi
  if [[ "${rc}" == "0" && "${remote_source_transition}" == "1" ]]; then
    scheduler_state="PAUSED"
    scheduler_recovery_state="SOURCE_POWER_ON_REQUIRED"
  elif [[ "${rc}" == "0" ]] && command -v ftctl_dr_scheduler_resume_after_transition >/dev/null 2>&1; then
    ftctl_dr_scheduler_resume_after_transition "${plan}" "${run}" "failover-abort" "${run_path}" "${status_path}" || rc=$?
  elif [[ "${rc}" == "0" ]]; then
    ftctl_dr_scheduler_control_action "dr-sync-resume" "${plan}" "${run_path}" "${status_path}" \
      "${profile_file}" || rc=$?
  fi
  if [[ "${rc}" != "0" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=ERROR" "step=failover-abort-resume-failed" \
      "scheduler_recovery_state=REQUIRES_AUTHORIZED_RECOVERY" \
      "error_code=DR_FAILOVER_ABORT_RESUME_FAILED" \
      "error_message=Scheduler resume acknowledgement was not received" \
      "retryable=true" "updated_at=${now}" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "dr-failover-abort" "error" "${plan}" "${run}" "${run_path}" "0"
    return "${rc}"
  fi

  if [[ -n "${sequence}" ]]; then
    ftctl_dr_scheduler_checkpoint_lease_release "${plan}" "${sequence}" || true
  fi
  ftctl_dr_runtime_abort_failover_session "${plan}" "${run}" "${current_session:-${session_id}}" "${now}" || return $?
  if command -v ftctl_dr_scheduler_transition_end >/dev/null 2>&1; then
    ftctl_dr_scheduler_transition_end "${plan}"
  fi
  ftctl_dr_runtime_path_set "${run_path}" \
    "action=dr-failover-abort" "state=ABORTED" "step=failover-preparation-aborted" "progress=100" \
    "active_side=SOURCE" "target_power_state=POWERED_OFF" "target_promotion_state=STANDBY" \
    "scheduler_state=${scheduler_state}" "scheduler_desired_state=$([[ "${remote_source_transition}" == "1" ]] && printf PAUSED || printf RUNNING)" \
    "scheduler_recovery_state=${scheduler_recovery_state}" \
    "checkpoint_lease_state=RELEASED" "engine_ack_state=ABORTED" \
    "accepted=false" "retryable=false" "error_code=" "error_message=" "updated_at=${now}" || return 2
  cp -f "${run_path}" "${status_path}" || return 2
  chmod 0644 "${status_path}" 2>/dev/null || true
  ftctl_log_event "dr-runtime" "dr.failover.abort" "warn" "" "" \
    "plan=${plan} run=${run} session=${current_session:-${session_id}} sequence=${sequence}"
  [[ "${json}" == "1" ]] && ftctl_dr_runtime_emit_state_json "dr-failover-abort" "ok" "${plan}" "${run}" "${run_path}" "0"
}

ftctl_dr_runtime_transition_preflight() {
  local plan="${1-}" operation="${2-}" expected_authority="${3-TARGET}"
  local expected_generation="${4-}" json="${5-0}"
  local status_path active_side="" authority_generation="" target_power_state=""
  local source_fence_state="" source_power_state=""
  local active_reprotect_path="" reprotect_plan="" reprotect_state="" reprotect_side=""
  local reprotect_run="" authority_spec_path="" spec_side="" spec_generation=""
  local scheduler_state="" scheduler_health="" owner_matched="" protection_state=""
  local ready="true" error_code="" message="" retryable="false" checked_at_epoch_ms

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  operation="${operation,,}"
  expected_authority="${expected_authority^^}"
  if [[ "${operation}" != "failback" && "${operation}" != "reprotect" ]]; then
    error_code="DR_TRANSITION_PREFLIGHT_OPERATION_INVALID"
    message="operation must be failback or reprotect"
  elif [[ "${expected_authority}" != "TARGET" ]]; then
    error_code="DR_TRANSITION_PREFLIGHT_AUTHORITY_INVALID"
    message="transition preflight requires TARGET authority"
  fi

  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  if [[ -z "${error_code}" && ! -f "${status_path}" ]]; then
    error_code="DR_TRANSITION_PREFLIGHT_STATE_MISSING"
    message="FTCTL plan authority state is missing"
  fi
  if [[ -z "${error_code}" ]]; then
    active_side="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "active_side")"
    authority_generation="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "cloud_authority_generation")"
    target_power_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "target_power_state")"
    source_fence_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "source_fence_state")"
    source_power_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "source_power_state")"
    if [[ "${active_side^^}" == "TARGET" \
          && ( -z "${authority_generation}" || -z "${target_power_state}" \
            || -z "${source_fence_state}" || -z "${source_power_state}" ) ]]; then
      active_reprotect_path="$(ftctl_dr_runtime_active_reprotect_session_path "${plan}")"
      scheduler_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "scheduler_state")"
      scheduler_health="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "scheduler_health")"
      owner_matched="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "owner_matched")"
      protection_state="$(ftctl_dr_runtime_state_get_from_path "${status_path}" "protection_state")"
      if [[ -s "${active_reprotect_path}" && "${scheduler_state}" == "RUNNING" \
            && "${scheduler_health}" == "HEALTHY" && "${owner_matched}" == "true" \
            && "${protection_state}" == "READY" ]]; then
        reprotect_plan="$(jq -r '.planUuid // empty' "${active_reprotect_path}" 2>/dev/null || true)"
        reprotect_state="$(jq -r '.state // empty' "${active_reprotect_path}" 2>/dev/null || true)"
        reprotect_side="$(jq -r '.activeSide // empty' "${active_reprotect_path}" 2>/dev/null || true)"
        reprotect_run="$(jq -r '.runUuid // empty' "${active_reprotect_path}" 2>/dev/null || true)"
        authority_spec_path="$(ftctl_dr_runtime_authority_spec_path "${plan}" "${reprotect_run}")"
        if [[ "${reprotect_plan}" == "${plan}" && "${reprotect_state}" == "READY" \
              && "${reprotect_side}" == "TARGET" && -s "${authority_spec_path}" ]]; then
          spec_side="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "expectedActiveSide" 2>/dev/null || true)"
          spec_generation="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "authorityGeneration" 2>/dev/null || true)"
          if [[ "${spec_side}" == "TARGET" && -n "${spec_generation}" \
                && ( -z "${expected_generation}" || "${spec_generation}" == "${expected_generation}" ) ]]; then
            [[ -n "${authority_generation}" ]] || authority_generation="${spec_generation}"
            [[ -n "${target_power_state}" ]] || target_power_state="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "targetPowerState" 2>/dev/null || true)"
            [[ -n "${source_fence_state}" ]] || source_fence_state="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "sourceFenceState" 2>/dev/null || true)"
            [[ -n "${source_power_state}" ]] || source_power_state="$(ftctl_dr_runtime_profile_value "${authority_spec_path}" "sourcePowerState" 2>/dev/null || true)"
          fi
        fi
      fi
    fi
    if [[ "${active_side^^}" != "${expected_authority}" ]]; then
      error_code="DR_TRANSITION_PREFLIGHT_AUTHORITY_MISMATCH"
      message="FTCTL authority does not match the Cloud transition authority"
    elif [[ -n "${expected_generation}" && "${authority_generation}" != "${expected_generation}" ]]; then
      error_code="DR_TRANSITION_PREFLIGHT_GENERATION_MISMATCH"
      message="FTCTL authority generation does not match the committed Cloud generation"
    elif [[ "${target_power_state^^}" != "POWERED_ON" \
        && "${target_power_state^^}" != "POWER_ON_DELEGATED" ]]; then
      error_code="DR_TRANSITION_PREFLIGHT_TARGET_NOT_SERVING"
      message="FTCTL target authority is not recorded as powered on"
    fi
  fi

  [[ -z "${error_code}" ]] || ready="false"
  checked_at_epoch_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-transition-preflight","schema_version":2,"contract_version":"dr-transition-preflight-v2","status_scope":"TRANSITION_PREFLIGHT","result":"%s","ready":%s,"retryable":%s,"plan_uuid":"%s","operation":"%s","expected_authority":"%s","active_side":"%s","expected_generation":%s,"authority_generation":%s,"target_power_state":"%s","target_power_semantics":"PROJECTION_ONLY","source_fence_state":"%s","source_power_state":"%s","source_power_semantics":"PROJECTION_ONLY","scheduler_state":"%s","active_operation":"%s","checked_at_epoch_ms":%s,"error_code":"%s","message":"%s","exit_code":%s}\n' "$( [[ "${ready}" == "true" ]] && printf ok || printf error )" "${ready}" "${retryable}" "$(ftctl__json_escape "${plan}")" "$(ftctl__json_escape "${operation}")" "$(ftctl__json_escape "${expected_authority}")" "$(ftctl__json_escape "${active_side}")" "${expected_generation:-null}" "${authority_generation:-null}" "$(ftctl__json_escape "${target_power_state}")" "$(ftctl__json_escape "${source_fence_state}")" "$(ftctl__json_escape "${source_power_state}")" "$(ftctl__json_escape "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "scheduler_state")")" "$(ftctl__json_escape "$(ftctl_dr_runtime_state_get_from_path "${status_path}" "action")")" "${checked_at_epoch_ms}" "$(ftctl__json_escape "${error_code}")" "$(ftctl__json_escape "${message}")" "$( [[ "${ready}" == "true" ]] && printf 0 || printf 79 )"
  elif [[ "${ready}" == "true" ]]; then
    printf 'DR transition preflight ready: plan=%s operation=%s authority=%s generation=%s\n' "${plan}" "${operation}" "${active_side}" "${authority_generation}"
  else
    printf 'ERROR: %s: %s\n' "${error_code}" "${message}" >&2
  fi
  if [[ "${ready}" == "true" ]]; then
    return 0
  fi
  return 79
}

ftctl_dr_runtime_capabilities() {
  local json="${1-0}" version="${PROG_VERSION:-unknown}"
  local schema="20260727" action_contract="2026-07-27"
  local authority_contracts_json
  local commands=(
    "dr-plan-apply"
    "dr-sync-start"
    "dr-sync-recover"
    "dr-sync-pause"
    "dr-sync-resume"
    "dr-test-failover"
    "dr-test-cleanup"
    "dr-test-prepare"
    "dr-test-artifact-cleanup"
    "dr-failover"
    "dr-failback"
    "dr-reprotect"
    "dr-target-materialized"
    "dr-target-export-start"
    "dr-target-export-stop"
    "dr-checkpoint-publish"
    "dr-checkpoint-ack"
    "dr-checkpoint-restore"
    "dr-target-export-reconcile-v1"
    "dr-cutover-commit"
    "dr-cutover-commit-status"
    "dr-failover-abort"
    "dr-failback-commit"
    "dr-failback-commit-status"
    "dr-failback-abort"
    "dr-release"
    "dr-status"
    "dr-transition-preflight"
    "dr-reconcile"
    "dr-cancel"
  )
  local first="1" command

  authority_contracts_json="$(python3 - "${FTCTL_DR_REPROTECT_AUTHORITY_CONTRACT_VERSIONS}" <<'PY'
import json
import sys

versions = [item.strip() for item in sys.argv[1].split(",") if item.strip()]
print(json.dumps(versions, separators=(",", ":")))
PY
)"

  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-capabilities","result":"ok","ftctl_version":"%s","runtime_schema_version":"%s","action_contract_version":"%s","materialization_contract_version":2,"reprotect_authority_contract_versions":%s,"supported_commands":[' \
      "$(ftctl__json_escape "${version}")" "$(ftctl__json_escape "${schema}")" "$(ftctl__json_escape "${action_contract}")" "${authority_contracts_json}"
    for command in "${commands[@]}"; do
      [[ "${first}" == "1" ]] || printf ','
      first="0"
      printf '"%s"' "$(ftctl__json_escape "${command}")"
    done
    printf '],"supported_features":["async-run","status-projection","status-scope-v2","target-materialized-notify","target-materialized-idempotent","target-materialization-manifest-v2","target-resource-ownership-generation-v1","hardware-contract-projection","control-protocol-v2","control-protocol-v3","control-protocol-v4","dr-site-agent-rbd-transport-v1","dr-target-disaster-promote-v1","dr-source-independent-test-v1","dr-cloud-test-recovery-v1","dr-reverse-site-agent-rbd-transport-v1","dr-remote-source-failback-commit-v1","dr-scheduler-singleton-v1","dr-scheduler-self-owner-repair-v1","dr-scheduler-systemd-unit-v1","dr-sync-recover-v1","dr-local-reconcile-fence-v1","dr-checkpoint-producer-v1","dr-nbd-deterministic-drain-v1","dr-nbd-cleanup-recovery-v1","dr-plan-authority-snapshot-v1","dr-failover-authority-snapshot-v1","dr-completed-cycle-evidence-v2","dr-failover-abort-v1","dr-failover-cutover-reverse-baseline-v1","dr-transition-preflight-v1","dr-transition-preflight-v2","dr-reverse-preflight-v2","dr-reverse-evidence-publication-v1","dr-reverse-rbd-snapshot-readonly-v1","dr-terminal-causality-v1","dr-requested-cycle-terminal-v1","dr-failback-resume-terminal-v1","dr-worker-journal-v1","dr-live-transfer-progress-v1","dr-runtime-reconciliation-v1","dr-release-tombstone-v1","plan-scoped-locks","cycle-scoped-lock","quiesce-before-test-failover","checkpoint-lease","file-checkpoint-invariance-v1","dr-file-planned-failover-qmp-quiesce-v1","dr-file-planned-failover-runtime-quiesce-v2","guest-preparation-v1","guest-preparation-v2","test-domain-lifecycle-v1","test-artifact-lifecycle-v2","cloud-managed-test-vm-v1","cutover-ready-v1","cutover-manifest-v2","cutover-preflight-v1","cloud-cutover-commit-v1","cloud-cutover-commit-envelope-v2","cloud-cutover-commit-journal-v2","cloud-cutover-commit-status-v1","cloud-failback-lifecycle-v1","dr-failback-commit-journal-v1","dr-failback-commit-journal-v2","dr-failback-commit-envelope-v1","dr-failback-commit-journal-v3","dr-failback-late-ack-reconcile-v1","dr-failback-rollback-fence-v1"]}\n'
    return 0
  fi

  printf 'FTCTL_DR capabilities (version=%s schema=%s reprotect-authority=%s)\n' \
    "${version}" "${schema}" "${FTCTL_DR_REPROTECT_AUTHORITY_CONTRACT_VERSIONS}"
  for command in "${commands[@]}"; do
    printf '  %s\n' "${command}"
  done
}

ftctl_dr_runtime_repair_requested_cycle_terminal() {
  local plan="${1-}" run="${2-}" path="${3-}"
  local state step progress owner requested_state mode commit_state durable sequence token expected_token
  local scheduler_path scheduler_owner scheduler_state scheduler_sequence scheduler_mode run_requested_sequence
  local terminal_path terminal_state nonce generation now restore_points_path recovered_json
  local recovered_sequence recovered_token recovered_manifest recovered_checkpoint recovered_source_at recovered_target_at

  [[ -n "${plan}" && -n "${run}" && -f "${path}" ]] || return 0
  terminal_path="$(ftctl_dr_runtime_run_journal_path "${plan}" "${run}" terminal)"
  terminal_state="$(ftctl_dr_runtime_journal_value "${terminal_path}" terminal_state)"
  if [[ -f "${terminal_path}" && "${terminal_state}" != "FAILED" ]]; then
    return 0
  fi
  state="$(ftctl_dr_runtime_state_get_from_path "${path}" state)"
  step="$(ftctl_dr_runtime_state_get_from_path "${path}" step)"
  progress="$(ftctl_dr_runtime_state_get_from_path "${path}" progress)"
  owner="$(ftctl_dr_runtime_state_get_from_path "${path}" control_request_run_uuid)"
  [[ -n "${owner}" ]] || owner="$(ftctl_dr_runtime_state_get_from_path "${path}" requested_cycle_owner_run)"
  requested_state="$(ftctl_dr_runtime_state_get_from_path "${path}" requested_cycle_state)"
  mode="$(ftctl_dr_runtime_state_get_from_path "${path}" latest_completed_effective_mode)"
  [[ -n "${mode}" ]] || mode="$(ftctl_dr_runtime_state_get_from_path "${path}" latest_completed_requested_mode)"
  commit_state="$(ftctl_dr_runtime_state_get_from_path "${path}" data_commit_state)"
  durable="$(ftctl_dr_runtime_state_get_from_path "${path}" target_durable)"
  sequence="$(ftctl_dr_runtime_state_get_from_path "${path}" latest_completed_checkpoint_sequence)"
  token="$(ftctl_dr_runtime_state_get_from_path "${path}" latest_completed_cycle_token)"
  run_requested_sequence="$(ftctl_dr_runtime_state_get_from_path "${path}" requested_cycle_sequence)"
  if [[ "${terminal_state}" == "FAILED" ]]; then
    restore_points_path="$(ftctl_dr_runtime_state_get_from_path "${path}" restore_points_path)"
    [[ -n "${restore_points_path}" ]] || restore_points_path="$(ftctl_dr_runtime_plan_dir "${plan}")/restore-points.jsonl"
    if [[ ! "${run_requested_sequence}" =~ ^[1-9][0-9]*$ ]]; then
      scheduler_path="$(ftctl_dr_runtime_plan_dir "${plan}")/scheduler/sequence.state"
      [[ -f "${scheduler_path}" ]] || return 0
      scheduler_owner="$(ftctl_dr_runtime_state_get_from_path "${scheduler_path}" requested_cycle_owner_run)"
      scheduler_sequence="$(ftctl_dr_runtime_state_get_from_path "${scheduler_path}" requested_cycle_sequence)"
      scheduler_mode="$(ftctl_dr_runtime_state_get_from_path "${scheduler_path}" requested_cycle_mode)"
      [[ "${scheduler_owner}" == "${run}" && "${scheduler_sequence}" =~ ^[1-9][0-9]*$ \
            && ( "${scheduler_mode}" == "FULL_RESEED" || "${scheduler_mode}" == "FULL_SEED" ) ]] || return 0
      run_requested_sequence="${scheduler_sequence}"
    fi
    [[ "${run_requested_sequence}" =~ ^[1-9][0-9]*$ && -s "${restore_points_path}" ]] || return 0
    recovered_json="$(python3 - "${restore_points_path}" "${plan}" "${run}" "${run_requested_sequence}" <<'PY'
import json
import os
import sys

path, plan, run, requested_sequence = sys.argv[1:5]
requested_sequence = int(requested_sequence)
candidate = None
with open(path, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            row = json.loads(line)
        except (TypeError, ValueError):
            continue
        sequence = row.get("checkpointSequence")
        mode = str(row.get("requestedMode") or "").upper()
        cycle_type = str(row.get("cycleType") or "").lower()
        commit = str(row.get("cycleCommitState") or "").upper()
        state = str(row.get("state") or "").upper()
        token = str(row.get("cycleToken") or "")
        owner = row.get("runUuid") or row.get("producerRunUuid")
        try:
            sequence = int(sequence)
        except (TypeError, ValueError):
            continue
        if row.get("planUuid") != plan or owner != run or sequence <= requested_sequence:
            continue
        if mode not in {"FULL_SEED", "FULL_RESEED"} and cycle_type not in {"full-seed", "full-reseed"}:
            continue
        if commit not in {"LOCAL_DURABLE", "COMMITTED", "DURABLE"}:
            continue
        if state not in {"READY", "COMPLETED", "TARGET_READY"} or token != f"{plan}:{sequence}":
            continue
        manifest = str(row.get("manifest") or "")
        checkpoint = str(row.get("checkpoint") or "")
        marker = f"{run}-cycle-{sequence}-"
        if marker not in manifest or marker not in checkpoint:
            continue
        if not os.path.isfile(manifest) or not os.path.isfile(checkpoint):
            continue
        if candidate is None or sequence > int(candidate["checkpointSequence"]):
            candidate = row
if candidate is not None:
    print(json.dumps(candidate, separators=(",", ":")))
PY
)"
    [[ -n "${recovered_json}" ]] || return 0
    recovered_sequence="$(jq -r '.checkpointSequence // empty' <<< "${recovered_json}")"
    recovered_token="$(jq -r '.cycleToken // empty' <<< "${recovered_json}")"
    recovered_manifest="$(jq -r '.manifest // empty' <<< "${recovered_json}")"
    recovered_checkpoint="$(jq -r '.checkpoint // empty' <<< "${recovered_json}")"
    recovered_source_at="$(jq -r '.sourceCheckpointAt // empty' <<< "${recovered_json}")"
    recovered_target_at="$(jq -r '.targetDurableAt // empty' <<< "${recovered_json}")"
    nonce="$(ftctl_dr_runtime_state_get_from_path "${path}" scheduler_session_uuid)"
    generation="$(ftctl_dr_runtime_state_get_from_path "${path}" scheduler_lease_epoch)"
    [[ -n "${nonce}" ]] || nonce="status-repair:${plan}"
    [[ "${generation}" =~ ^[0-9]+$ ]] || generation="0"
    now="$(ftctl_now_iso8601)"
    ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${nonce}" "${generation}" \
      "SUCCEEDED" "0" "" "${now}" || return $?
    ftctl_dr_runtime_path_set "${path}" \
      "state=READY" "step=full-resync-completed" "progress=100" \
      "control_request_run_uuid=${run}" "requested_cycle_owner_run=${run}" \
      "requested_cycle_sequence=${recovered_sequence}" "requested_cycle_state=COMPLETED" \
      "checkpoint_sequence=${recovered_sequence}" "checkpoint_path=${recovered_checkpoint}" \
      "manifest_path=${recovered_manifest}" "data_commit_state=LOCAL_DURABLE" "target_durable=true" \
      "worker_state=TERMINAL_PUBLISHED" "worker_exit_code=0" "transfer_activity_state=IDLE" \
      "terminal_source=ENGINE_TERMINAL" "terminal_version=1" "terminal_authoritative=true" \
      "runtime_endpoints_drained=true" "terminal_publication_pending=false" \
      "error_code=" "error_message=" "failed_component=" \
      "terminal_repaired_at=${now}" "updated_at=${now}" || return $?
    scheduler_path="$(ftctl_dr_runtime_plan_dir "${plan}")/scheduler/sequence.state"
    if [[ -f "${scheduler_path}" ]]; then
      ftctl_state_set_path "${scheduler_path}" \
        "requested_cycle_owner_run=${run}" "requested_cycle_sequence=${recovered_sequence}" \
        "requested_cycle_state=COMPLETED" "requested_cycle_error=" \
        "requested_cycle_completed_at=${now}" || return $?
    fi
    ftctl_log_event "dr-runtime" "dr.requested-cycle.failed-terminal-repair" "ok" "" "" \
      "plan=${plan} run=${run} sequence=${recovered_sequence} token=${recovered_token} source_at=${recovered_source_at} target_at=${recovered_target_at}"
    return 0
  fi
  expected_token="${plan}:${sequence}"
  if [[ "${requested_state}" != "COMPLETED" ]]; then
    scheduler_path="$(ftctl_dr_runtime_plan_dir "${plan}")/scheduler/sequence.state"
    [[ -f "${scheduler_path}" ]] || return 0
    scheduler_owner="$(ftctl_dr_runtime_state_get_from_path "${scheduler_path}" requested_cycle_owner_run)"
    scheduler_state="$(ftctl_dr_runtime_state_get_from_path "${scheduler_path}" requested_cycle_state)"
    scheduler_sequence="$(ftctl_dr_runtime_state_get_from_path "${scheduler_path}" requested_cycle_sequence)"
    [[ "${scheduler_owner}" == "${run}" && "${scheduler_state}" == "COMPLETED" \
          && "${scheduler_sequence}" =~ ^[1-9][0-9]*$ && "${scheduler_sequence}" == "${sequence}" ]] || return 0
    requested_state="COMPLETED"
  fi
  [[ "${state}" == "READY" && "${step}" == "full-resync-completed" && "${progress}" == "100" \
        && "${owner}" == "${run}" && "${requested_state}" == "COMPLETED" \
        && ( "${mode}" == "FULL_RESEED" || "${mode}" == "FULL_SEED" ) \
        && ( "${commit_state}" == "LOCAL_DURABLE" || "${commit_state}" == "COMMITTED" || "${commit_state}" == "DURABLE" ) \
        && "${durable}" == "true" && "${sequence}" =~ ^[1-9][0-9]*$ \
        && "${token}" == "${expected_token}" \
        && ( -z "${run_requested_sequence}" || "${run_requested_sequence}" == "${sequence}" ) ]] || return 0

  nonce="$(ftctl_dr_runtime_state_get_from_path "${path}" scheduler_session_uuid)"
  generation="$(ftctl_dr_runtime_state_get_from_path "${path}" scheduler_lease_epoch)"
  [[ -n "${nonce}" ]] || nonce="status-repair:${plan}"
  [[ "${generation}" =~ ^[0-9]+$ ]] || generation="0"
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_terminal_journal_write "${plan}" "${run}" "${nonce}" "${generation}" \
    "SUCCEEDED" "0" "" "${now}" || return $?
  ftctl_dr_runtime_path_set "${path}" \
    "control_request_run_uuid=${run}" \
    "requested_cycle_state=COMPLETED" \
    "worker_state=TERMINAL_PUBLISHED" \
    "worker_exit_code=0" \
    "transfer_activity_state=IDLE" \
    "terminal_source=ENGINE_TERMINAL" \
    "terminal_version=1" \
    "terminal_authoritative=true" \
    "runtime_endpoints_drained=true" \
    "terminal_publication_pending=false" \
    "terminal_repaired_at=${now}" \
    "updated_at=${now}"
  ftctl_log_event "dr-runtime" "dr.requested-cycle.terminal-repair" "ok" "" "" \
    "plan=${plan} run=${run} sequence=${sequence}"
}

ftctl_dr_runtime_status() {
  local plan="${1-}" run="${2-}" events_offset="${3-0}" events_limit="${4-20}" json="${5-0}"
  local path result="ok" payload payload_bytes max_payload_bytes

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  if [[ -n "${run}" && -f "$(ftctl_dr_runtime_run_path "${plan}" "${run}")" ]]; then
    path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  else
    path="$(ftctl_dr_runtime_status_path "${plan}")"
  fi

  if [[ ! -f "${path}" && -z "${run}" ]]; then
    ftctl_dr_runtime_restore_release_status "${plan}" || true
    path="$(ftctl_dr_runtime_status_path "${plan}")"
  fi

  if [[ ! -f "${path}" ]]; then
    if [[ -f "$(ftctl_dr_runtime_profile_path "${plan}")" ]]; then
      ftctl_dr_runtime_ensure_plan_dirs "${plan}"
      path="$(ftctl_dr_runtime_status_path "${plan}")"
      ftctl_dr_runtime_write_state "${path}" "${plan}" "" "dr-status" "PLANNED" "profile-present" "0" "" ""
    else
      if [[ "${json}" == "1" ]]; then
        printf '{"command":"dr-status","result":"not_found","plan_uuid":"%s","state":"UNKNOWN","step":"not-found","progress":0,"accepted":false,"error_code":"not_found","events_offset":%s,"exit_code":2}\n' \
          "$(ftctl__json_escape "${plan}")" \
          "$(ftctl_dr_runtime_events_offset "${plan}")"
      else
        printf 'dr-status: plan=%s not found\n' "${plan}" >&2
      fi
      return 2
    fi
  fi

  [[ -n "${run}" && ! -f "$(ftctl_dr_runtime_run_path "${plan}" "${run}")" ]] && result="run_not_found"
  if [[ -n "${run}" && "${result}" != "run_not_found" ]]; then
    ftctl_dr_runtime_repair_reprotect_terminal "${plan}" "${run}" "${path}" || true
    ftctl_dr_runtime_repair_requested_cycle_terminal "${plan}" "${run}" "${path}" || true
  fi
  if [[ -z "${run}" ]]; then
    # A completed failback may be newer than a TARGET-side status snapshot.
    # Apply the strict journal/generation/timestamp guard before the overlay so
    # read repair can persist SOURCE authority without overwriting a later
    # failover.
    ftctl_dr_runtime_converge_completed_failback_authority \
      "${plan}" "${path}" "${path}" || true
    # The durable failback sidecar can reach COMPLETED just after a forward
    # cycle publishes status. Rebuild plan authority at read time as well so
    # Cloud never loses the sticky failback completion contract to that race.
    ftctl_dr_runtime_overlay_failback_plan_authority "${path}" "${path}" || true
  fi
  if [[ "${json}" == "1" ]]; then
    payload="$(ftctl_dr_runtime_emit_state_json "dr-status" "${result}" "${plan}" "${run}" "${path}" "${events_offset}" "${events_limit}")" || payload=""
    max_payload_bytes="${FTCTL_DR_STATUS_MAX_BYTES:-262144}"
    [[ "${max_payload_bytes}" =~ ^[1-9][0-9]*$ ]] || max_payload_bytes="262144"
    payload_bytes="$(printf '%s' "${payload}" | wc -c | tr -d '[:space:]')"
    if [[ -n "${payload}" && "${payload_bytes}" =~ ^[0-9]+$ && "${payload_bytes}" -le "${max_payload_bytes}" ]] \
      && printf '%s' "${payload}" | python3 -c 'import json,sys; value=json.load(sys.stdin); raise SystemExit(0 if isinstance(value, dict) else 1)' 2>/dev/null; then
      printf '%s\n' "${payload}"
    else
      local terminal_state terminal_step terminal_progress terminal_error_code terminal_error_message
      local terminal_cleanup_state terminal_cleanup_required terminal_lease_state terminal_artifacts_state terminal_session_state
      terminal_state="$(ftctl_dr_runtime_state_get_from_path "${path}" state)"
      terminal_step="$(ftctl_dr_runtime_state_get_from_path "${path}" step)"
      terminal_progress="$(ftctl_dr_runtime_state_get_from_path "${path}" progress)"
      terminal_error_code="$(ftctl_dr_runtime_state_get_from_path "${path}" error_code)"
      terminal_error_message="$(ftctl_dr_runtime_state_get_from_path "${path}" error_message)"
      terminal_cleanup_state="$(ftctl_dr_runtime_state_get_from_path "${path}" test_cleanup_state)"
      terminal_cleanup_required="$(ftctl_dr_runtime_state_get_from_path "${path}" cleanup_required)"
      terminal_lease_state="$(ftctl_dr_runtime_state_get_from_path "${path}" checkpoint_lease_state)"
      terminal_artifacts_state="$(ftctl_dr_runtime_state_get_from_path "${path}" test_artifacts_state)"
      terminal_session_state="$(ftctl_dr_runtime_state_get_from_path "${path}" test_session_state)"
      [[ "${terminal_progress}" =~ ^[0-9]+$ ]] || terminal_progress=100
      [[ "${terminal_cleanup_required}" == "true" || "${terminal_cleanup_required}" == "false" ]] || terminal_cleanup_required=true
      if [[ -z "${terminal_artifacts_state}" \
        && "${terminal_session_state}" == "CLEANED" \
        && "${terminal_cleanup_state}" == "CLEANED" \
        && "${terminal_cleanup_required}" == "false" \
        && "${terminal_lease_state}" == "RELEASED" ]]; then
        terminal_artifacts_state="CLEANED"
      fi
      terminal_error_message="${terminal_error_message:0:4096}"
      if [[ "${terminal_state}" == "ERROR" && -n "${terminal_error_code}" ]]; then
        printf '{"command":"dr-status","result":"error","plan_uuid":"%s","run_uuid":"%s","state":"ERROR","step":"%s","progress":%s,"accepted":false,"worker_state":"FAILED","terminal_source":"ENGINE_TERMINAL","terminal_version":1,"terminal_authoritative":true,"error_code":"%s","error_message":"%s","test_session_state":"%s","test_artifacts_state":"%s","test_cleanup_state":"%s","cleanup_required":%s,"checkpoint_lease_state":"%s","status_payload_truncated":true,"status_payload_bytes":%s,"events_offset":%s,"events":[],"exit_code":0}\n' \
          "$(ftctl__json_escape "${plan}")" "$(ftctl__json_escape "${run}")" \
          "$(ftctl__json_escape "${terminal_step:-operation-failed}")" "${terminal_progress}" \
          "$(ftctl__json_escape "${terminal_error_code}")" "$(ftctl__json_escape "${terminal_error_message}")" \
          "$(ftctl__json_escape "${terminal_session_state}")" "$(ftctl__json_escape "${terminal_artifacts_state}")" \
          "$(ftctl__json_escape "${terminal_cleanup_state}")" "${terminal_cleanup_required}" \
          "$(ftctl__json_escape "${terminal_lease_state}")" "${payload_bytes:-0}" "$(ftctl_dr_runtime_events_offset "${plan}")"
        return 0
      fi
      printf '{"command":"dr-status","result":"error","plan_uuid":"%s","run_uuid":"%s","state":"ERROR","step":"status-validation","progress":0,"accepted":false,"error_code":"DR_STATUS_JSON_INVALID","error_message":"FTCTL DR status failed strict JSON validation","events_offset":%s,"events":[],"exit_code":65}\n' \
        "$(ftctl__json_escape "${plan}")" "$(ftctl__json_escape "${run}")" "$(ftctl_dr_runtime_events_offset "${plan}")"
      return 65
    fi
  else
    printf 'dr-status: plan=%s state=%s step=%s progress=%s\n' \
      "${plan}" \
      "$(ftctl_dr_runtime_state_get_from_path "${path}" state)" \
      "$(ftctl_dr_runtime_state_get_from_path "${path}" step)" \
      "$(ftctl_dr_runtime_state_get_from_path "${path}" progress)"
  fi
}

ftctl_dr_runtime_cancel() {
  local plan="${1-}" run="${2-}" force="${3-0}" json="${4-0}"
  local run_path status_path profile_path rc=0 recovery_rc=0 recovery_queued=false now
  local existing_state existing_step existing_terminal_source existing_terminal_authoritative
  local existing_runtime_endpoints_drained existing_transfer_activity_state

  ftctl_dr_runtime_require_plan "${plan}" || return 2
  ftctl_dr_runtime_require_run "${run}" || return 2
  ftctl_dr_runtime_ensure_plan_dirs "${plan}"
  run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
  status_path="$(ftctl_dr_runtime_status_path "${plan}")"
  existing_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" state)"
  existing_step="$(ftctl_dr_runtime_state_get_from_path "${run_path}" step)"
  existing_terminal_source="$(ftctl_dr_runtime_state_get_from_path "${run_path}" terminal_source)"
  existing_terminal_authoritative="$(ftctl_dr_runtime_state_get_from_path "${run_path}" terminal_authoritative)"
  existing_runtime_endpoints_drained="$(ftctl_dr_runtime_state_get_from_path "${run_path}" runtime_endpoints_drained)"
  existing_transfer_activity_state="$(ftctl_dr_runtime_state_get_from_path "${run_path}" transfer_activity_state)"
  if [[ "${existing_terminal_authoritative}" == "true" ]]; then
    case "${existing_state}" in
      READY|FAILED|ERROR|FAILED_OVER|RELEASED|UNPROTECTED|CANCELED)
        [[ "${existing_runtime_endpoints_drained}" == "true" ]] || existing_runtime_endpoints_drained="false"
        [[ -n "${existing_transfer_activity_state}" ]] || existing_transfer_activity_state="IDLE"
        if [[ "${existing_state}" == "CANCELED" ]]; then
          existing_transfer_activity_state="CANCELED"
        fi
        if [[ "${json}" == "1" ]]; then
          printf '{"command":"dr-cancel","result":"%s","accepted":true,"plan_uuid":"%s","run_uuid":"%s","state":"%s","step":"%s","terminal_source":"%s","terminal_authoritative":true,"runtime_endpoints_drained":%s,"transfer_activity_state":"%s","error_code":"","exit_code":0}\n' \
            "$([[ "${existing_state}" == "CANCELED" ]] && printf canceled || printf already_terminal)" \
            "$(ftctl__json_escape "${plan}")" \
            "$(ftctl__json_escape "${run}")" \
            "$(ftctl__json_escape "${existing_state}")" \
            "$(ftctl__json_escape "${existing_step}")" \
            "$(ftctl__json_escape "${existing_terminal_source}")" \
            "${existing_runtime_endpoints_drained}" \
            "$(ftctl__json_escape "${existing_transfer_activity_state}")"
        else
          printf 'dr-cancel: plan=%s run=%s already terminal state=%s\n' \
            "${plan}" "${run}" "${existing_state}"
        fi
        return 0
        ;;
    esac
  fi
  now="$(ftctl_now_iso8601)"
  ftctl_dr_runtime_path_set "${run_path}" \
    "plan=${plan}" "run=${run}" "action=dr-cancel" \
    "state=CANCEL_REQUESTED" "step=cancel-requested" "progress=99" \
    "accepted=true" "control_request_run_uuid=${run}" \
    "terminal_authoritative=false" "runtime_endpoints_drained=false" \
    "updated_at=${now}"
  if command -v ftctl_dr_scheduler_control_action >/dev/null 2>&1; then
    ftctl_dr_scheduler_control_action "dr-cancel" "${plan}" "${run_path}" "${status_path}" || rc=$?
  fi
  if [[ "${rc}" != "0" ]]; then
    ftctl_dr_runtime_path_set "${run_path}" \
      "state=CANCEL_REQUESTED" "step=cancel-drain-pending" "progress=99" \
      "accepted=false" "retryable=true" "retry_after_sec=5" \
      "error_code=DR_CANCEL_DRAIN_PENDING" \
      "error_message=Scheduler or transfer endpoints have not stopped yet" \
      "terminal_authoritative=false" "runtime_endpoints_drained=false" \
      "updated_at=$(ftctl_now_iso8601)" || true
    cp -f "${run_path}" "${status_path}" 2>/dev/null || true
    if [[ "${json}" == "1" ]]; then
      printf '{"command":"dr-cancel","result":"pending","accepted":false,"retryable":true,"plan_uuid":"%s","run_uuid":"%s","error_code":"DR_CANCEL_DRAIN_PENDING","exit_code":%s}\n' \
        "$(ftctl__json_escape "${plan}")" "$(ftctl__json_escape "${run}")" "${rc}"
    fi
    return "${rc}"
  fi
  ftctl_dr_runtime_path_set "${run_path}" \
    "state=CANCELED" "step=canceled" "progress=100" \
    "accepted=true" "retryable=false" "retry_after_sec=" \
    "error_code=" "error_message=" \
    "transfer_activity_state=CANCELED" \
    "terminal_source=ENGINE_TERMINAL" "terminal_version=1" \
    "terminal_authoritative=true" "runtime_endpoints_drained=true" \
    "updated_at=$(ftctl_now_iso8601)"
  cp -f "${run_path}" "${status_path}"
  chmod 0644 "${status_path}" 2>/dev/null || true
  profile_path="$(ftctl_dr_runtime_profile_path "${plan}")"
  if command -v ftctl_dr_scheduler_cancel_auto_recovery_enabled >/dev/null 2>&1 \
      && ftctl_dr_scheduler_cancel_auto_recovery_enabled "${profile_path}"; then
    if ftctl_dr_scheduler_queue_cancel_recovery "${plan}" "${run}" "${status_path}" >/dev/null; then
      recovery_queued=true
    else
      recovery_rc=$?
      ftctl_dr_runtime_path_set "${status_path}" \
        "state=READY" \
        "step=cancel-recovery-failed" \
        "scheduler_health=DEGRADED" \
        "scheduler_desired_state=RUNNING" \
        "scheduler_recovery_state=FAILED" \
        "scheduler_recovery_rc=${recovery_rc}" \
        "replication_activity=STOPPED" \
        "protection_state=DEGRADED" \
        "error_code=DR_CANCEL_AUTO_RECOVERY_FAILED" \
        "error_message=The canceled Run is terminal but continuous protection recovery could not be queued" \
        "updated_at=$(ftctl_now_iso8601)" || true
    fi
  fi
  ftctl_log_event "dr-runtime" "dr.cancel" "ok" "" "" \
    "plan=${plan} run=${run} force=${force} recovery_queued=${recovery_queued}"

  if [[ "${json}" == "1" ]]; then
    printf '{"command":"dr-cancel","result":"canceled","accepted":true,"plan_uuid":"%s","run_uuid":"%s","state":"CANCELED","terminal_authoritative":true,"runtime_endpoints_drained":true,"transfer_activity_state":"CANCELED","scheduler_recovery_queued":%s,"error_code":"","exit_code":0}\n' \
      "$(ftctl__json_escape "${plan}")" \
      "$(ftctl__json_escape "${run}")" \
      "${recovery_queued}"
  else
    printf 'dr-cancel: plan=%s run=%s canceled\n' "${plan}" "${run}"
  fi
}

# Durable checkpoint publication shares the DR lifecycle libraries.
source "${BASH_SOURCE[0]%/*}/dr_checkpoint.sh"
