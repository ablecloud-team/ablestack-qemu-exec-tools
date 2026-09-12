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

set -euo pipefail

FTCTL_DR_VMWARE_MOVER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_vddk.sh" ]]; then
  # shellcheck source=/dev/null
  source "${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_vddk.sh"
fi
if [[ -f "${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_nbd.sh" ]]; then
  # shellcheck source=/dev/null
  source "${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_nbd.sh"
fi

FTCTL_DR_VMWARE_MOVER_LOG_DIR="${FTCTL_DR_VMWARE_MOVER_LOG_DIR:-/run/ablestack-vm-ftctl/dr-runtime/mover}"
FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT="${FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT:-20}"
FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT="${FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT:-20}"
FTCTL_DR_VMWARE_SOURCE_OPEN_TIMEOUT="${FTCTL_DR_VMWARE_SOURCE_OPEN_TIMEOUT:-60}"
FTCTL_DR_NBD_READY_TIMEOUT_MS="${FTCTL_DR_NBD_READY_TIMEOUT_MS:-5000}"
FTCTL_DR_NBD_READY_POLL_MS="${FTCTL_DR_NBD_READY_POLL_MS:-50}"
FTCTL_DR_NBD_ATTACH_ATTEMPTS="${FTCTL_DR_NBD_ATTACH_ATTEMPTS:-2}"
FTCTL_DR_NBD_SYSFS_ROOT="${FTCTL_DR_NBD_SYSFS_ROOT:-/sys/class/block}"
FTCTL_DR_NBD_DRAIN_TIMEOUT_MS="${FTCTL_DR_NBD_DRAIN_TIMEOUT_MS:-10000}"
FTCTL_DR_NBD_DRAIN_POLL_MS="${FTCTL_DR_NBD_DRAIN_POLL_MS:-50}"
FTCTL_DR_NBD_UDEV_SETTLE_TIMEOUT_SEC="${FTCTL_DR_NBD_UDEV_SETTLE_TIMEOUT_SEC:-10}"
FTCTL_DR_NBD_STABLE_POLLS="${FTCTL_DR_NBD_STABLE_POLLS:-2}"
FTCTL_DR_NBD_QUARANTINE_ROOT="${FTCTL_DR_NBD_QUARANTINE_ROOT:-/run/ablestack-vm-ftctl/dr-runtime/nbd-quarantine}"
FTCTL_DR_NBD_DEVICE_START="${FTCTL_DR_NBD_DEVICE_START:-16}"
FTCTL_DR_NBD_DEVICE_END="${FTCTL_DR_NBD_DEVICE_END:-31}"
FTCTL_DR_NBD_MODULE_MAX_DEVICES="${FTCTL_DR_NBD_MODULE_MAX_DEVICES:-32}"
FTCTL_DR_NBD_MODULE_MAX_PARTITIONS="${FTCTL_DR_NBD_MODULE_MAX_PARTITIONS:-16}"
FTCTL_DR_NBD_TEARDOWN_STATE="NOT_APPLICABLE"
FTCTL_DR_NBD_TEARDOWN_STARTED_AT_MS=0
FTCTL_DR_NBD_TEARDOWN_COMPLETED_AT_MS=0
FTCTL_DR_NBD_TEARDOWN_DURATION_MS=0
FTCTL_DR_NBD_SOURCE_DEVICE_COUNT=0
FTCTL_DR_NBD_TARGET_DEVICE_COUNT=0
FTCTL_DR_NBD_QUARANTINED_DEVICE_COUNT=0
FTCTL_DR_NBD_TEARDOWN_ERROR_CODE=""
FTCTL_DR_NBD_TEARDOWN_ERROR_MESSAGE=""
FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF=""
FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD=""
FTCTL_DR_VMWARE_SOURCE_OPEN_TLS_VERIFY=""
FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT=""
FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE=""

ftctl_vmware_mover_is_source_transport_failure() {
  local message="${1-}"
  grep -Eiq \
    'no route to host|connection refused|connection reset|connection timed out|i/o timeout|context deadline exceeded|temporary failure in name resolution|name or service not known|no such host|network is unreachable|server closed idle connection|503[[:space:]]+service unavailable|no healthy upstream|upstream connect error' \
    <<< "${message}"
}

ftctl_vmware_mover_die() {
  local rc="${1:-65}"
  shift || true
  printf 'ERROR: %s\n' "$*" >&2
  exit "${rc}"
}

ftctl_vmware_mover_require() {
  command -v "$1" >/dev/null 2>&1 || ftctl_vmware_mover_die "${2:-65}" "required command not found: $1"
}

ftctl_vmware_mover_write_cycle_journal() {
  local journal_path="${1-}" state="${2-}" retry_mode="${3-}" error_code="${4-}" error_message="${5-}" results_path="${6-}" mode_decision="${7-}"
  [[ -n "${journal_path}" ]] || return 0
  python3 - "${journal_path}" "${state}" "${retry_mode}" "${error_code}" "${error_message}" "${results_path}" \
    "${FTCTL_DR_PLAN_UUID:-}" "${FTCTL_DR_RUN_UUID:-}" "${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}" "${mode_decision}" \
    "${FTCTL_DR_CYCLE_METRICS_PATH:-}" <<'PY'
import json
import os
import sys
import time

path, state, retry_mode, error_code, error_message, results_path, plan, run, sequence, raw_decision, metrics_path = sys.argv[1:12]
results = []
if results_path and os.path.isfile(results_path):
    try:
        with open(results_path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
            if isinstance(value, list):
                results = value
    except (OSError, ValueError, TypeError):
        results = []
payload = {
    "schemaVersion": 1,
    "planUuid": plan,
    "runUuid": run,
    "sequence": int(sequence or 0),
    "state": state,
    "retryMode": retry_mode,
    "errorCode": error_code,
    "errorMessage": error_message,
    "dataCopied": state in ("DATA_COPIED", "METADATA_PREPARED", "LOCAL_DURABLE", "LOCAL_COMMIT_FAILED"),
    "metadataCommitted": state == "LOCAL_DURABLE",
    "targetDurable": state == "LOCAL_DURABLE",
    "completedDiskCount": len(results),
    "disks": results,
    "updatedAtEpochMs": int(time.time() * 1000),
}
if raw_decision:
    try:
        decision = json.loads(raw_decision)
        if isinstance(decision, dict):
            payload.update({
                "requestedMode": decision.get("requestedMode"),
                "effectiveMode": decision.get("effectiveMode"),
                "automaticReseed": bool(decision.get("automaticReseed")),
                "modeDecisionCode": decision.get("decisionCode"),
                "reseedReason": decision.get("reseedReason"),
                "invalidBaselineDiskCount": int(decision.get("invalidBaselineDiskCount") or 0),
            })
    except (ValueError, TypeError):
        pass
if state == "LOCAL_DURABLE" and metrics_path and os.path.isfile(metrics_path):
    with open(metrics_path, "r", encoding="utf-8") as handle:
        metrics = json.load(handle)
    expected_sequence = int(sequence or 0)
    if (str(metrics.get("planUuid") or "") != plan
            or str(metrics.get("runUuid") or "") != run
            or int(metrics.get("sequence") or -1) != expected_sequence):
        raise SystemExit("cycle metrics identity does not match cycle journal")
    for key in (
        "cycleUuid", "cycleToken", "requestedMode", "effectiveMode",
        "automaticReseed", "modeDecisionCode", "reseedReason",
        "invalidBaselineDiskCount", "incrementalVerified", "metricsEstimated",
        "baselineGeneration", "cycleCommitState", "virtualBytes", "changedBytes",
        "sourceReadBytes", "targetWrittenBytes", "transferPayloadBytes",
        "changedExtentCount", "durationMs", "throughputBps", "nbdTeardownState",
        "nbdTeardownStartedAtEpochMs", "nbdTeardownCompletedAtEpochMs",
        "nbdTeardownDurationMs", "nbdSourceDeviceCount", "nbdTargetDeviceCount",
        "nbdQuarantinedDeviceCount", "nbdTeardownErrorCode", "nbdTeardownErrorMessage",
    ):
        if key in metrics:
            payload[key] = metrics[key]
    payload["disks"] = metrics.get("disks") or results
    payload["completedDiskCount"] = len(payload["disks"])
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, path)
PY
}

ftctl_vmware_mover_build_disk_result() {
  local index="${1-}" disk_label="${2-}" requested="${3-}" effective="${4-}" previous="${5-}" next="${6-}"
  local virtual_bytes="${7-0}" incremental_verified="${8-false}" metric_path="${9-}" output_path="${10-}"
  python3 - "${index}" "${disk_label}" "${requested}" "${effective}" "${previous}" "${next}" \
    "${virtual_bytes}" "${incremental_verified}" "${metric_path}" "${output_path}" <<'PY'
import json
import os
import sys

index, disk_label, requested, effective, previous, next_id, virtual_bytes, verified, metric_path, output_path = sys.argv[1:11]
with open(metric_path, "r", encoding="utf-8") as handle:
    metric = json.load(handle)
if not isinstance(metric, dict):
    raise SystemExit("cycle metric must be a JSON object")
required_metrics = (
    "changedExtentCount", "changedBytes", "sourceReadBytes", "targetWrittenBytes",
    "transferPayloadBytes", "durationMs", "throughputBps",
)
for key in required_metrics:
    value = metric.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SystemExit(f"invalid cycle metric {key}: {value!r}")
result = {
    "diskIndex": int(index),
    "diskLabel": disk_label,
    "requestedMode": requested,
    "effectiveMode": effective,
    "previousChangeId": previous,
    "newChangeId": next_id,
    "virtualBytes": int(virtual_bytes or 0),
    "incrementalVerified": verified.lower() == "true",
}
result.update(metric)
tmp = output_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(result, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, output_path)
PY
}

ftctl_vmware_mover_json_value() {
  local path="${1-}" expr="${2-}" default_value="${3-}"
  [[ -n "${path}" && -f "${path}" ]] || {
    printf '%s\n' "${default_value}"
    return 0
  }
  jq -er "${expr} // empty" "${path}" 2>/dev/null || printf '%s\n' "${default_value}"
}

ftctl_vmware_mover_target_uri() {
  local raw_path="${1-}" target_storage_path="${2-}" target_name="${3-}" target_storage_type="${4-}"
  local pool image
  if [[ "${target_storage_type^^}" == *RBD* ]] &&
      [[ "${raw_path}" != rbd:* && "${raw_path}" != /dev/rbd/*/* && "${raw_path}" != rbd/*/* ]]; then
    pool="${target_storage_path#rbd:}"
    pool="${pool#/dev/rbd/}"
    pool="${pool#rbd/}"
    pool="${pool#/}"
    pool="${pool%/}"
    image="${target_name:-${raw_path}}"
    image="${image#/}"
    [[ -n "${pool}" && -n "${image}" && "${pool}" != */* && "${image}" != */* ]] || return 1
    printf 'rbd:%s/%s\n' "${pool}" "${image}"
    return 0
  fi
  if [[ -z "${raw_path}" && -n "${target_storage_path}" && -n "${target_name}" ]]; then
    raw_path="${target_storage_path%/}/${target_name}"
  fi
  case "${raw_path}" in
    rbd:*)
      printf '%s\n' "${raw_path}"
      ;;
    /dev/rbd/*/*)
      pool="${raw_path#/dev/rbd/}"
      pool="${pool%%/*}"
      image="${raw_path#/dev/rbd/${pool}/}"
      printf 'rbd:%s/%s\n' "${pool}" "${image}"
      ;;
    rbd/*/*)
      printf 'rbd:%s\n' "${raw_path#rbd/}"
      ;;
    *)
      printf '%s\n' "${raw_path}"
      ;;
  esac
}

ftctl_vmware_mover_qemu_opt_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//,/\\,}"
  printf '%s\n' "${value}"
}

ftctl_vmware_mover_source_image_opts() {
  local socket_path="${1-}" escaped_socket
  [[ -n "${socket_path}" ]] || ftctl_vmware_mover_die 72 "DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID: nbd socket path is empty"
  escaped_socket="$(ftctl_vmware_mover_qemu_opt_escape "${socket_path}")"
  printf 'driver=raw,file.driver=nbd,file.server.type=unix,file.server.path=%s\n' "${escaped_socket}"
}

ftctl_vmware_mover_resolve_cbt_python() {
  local libdir="${1-}" compat_root candidate
  if [[ -n "${FTCTL_DR_VMWARE_CBT_PYTHON:-}" && -x "${FTCTL_DR_VMWARE_CBT_PYTHON}" ]]; then
    printf '%s\n' "${FTCTL_DR_VMWARE_CBT_PYTHON}"
    return 0
  fi
  if [[ -n "${libdir}" ]]; then
    compat_root="$(cd "${libdir}/.." 2>/dev/null && pwd || true)"
    for candidate in "${compat_root}/venv/bin/python" "${compat_root}/venv/bin/python3"; do
      [[ -x "${candidate}" ]] || continue
      "${candidate}" -c 'import pyVmomi' >/dev/null 2>&1 || continue
      printf '%s\n' "${candidate}"
      return 0
    done
  fi
  if python3 -c 'import pyVmomi' >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  return 1
}

ftctl_vmware_mover_publish_cbt_failure() {
  local error_code="${1-}" message="${2-}" disk_id="${3-}" status_path="${FTCTL_DR_CBT_STATUS_PATH:-}"
  [[ -n "${status_path}" ]] || return 0
  python3 - "${status_path}" "${error_code}" "${message}" "${disk_id}" <<'PY'
import json
import os
import sys
import time

path, error_code, message, disk_id = sys.argv[1:5]
status = {}
if os.path.isfile(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
            if isinstance(value, dict):
                status = value
    except (OSError, ValueError, TypeError):
        status = {}
status.update({
    "schemaVersion": 2,
    "phase": "cbt-activation",
    "lifecycleState": "ERROR",
    "enabled": False,
    "error_code": error_code,
    "message": message,
    "failedDiskId": disk_id,
    "checkedAtEpochMs": int(time.time() * 1000),
})
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(status, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, path)
PY
}

ftctl_vmware_mover_query_cbt() {
  local endpoint="${1-}" username="${2-}" password_file="${3-}" tls_verify="${4-}" libdir="${5-}"
  local vm_ref="${6-}" snapshot_name="${7-}" disk_id="${8-}" previous_change_id="${9-}" output_path="${10-}"
  local verify_current="${11-false}" device_key="${12-}" python_bin helper current_probe_path
  local query_error_path query_attempt=1 query_attempts query_retry_sec query_rc=1
  python_bin="$(ftctl_vmware_mover_resolve_cbt_python "${libdir}" || true)"
  helper="${FTCTL_DR_VMWARE_CBT_QUERY_HELPER:-${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_vmware_changed_areas.py}"
  [[ -n "${python_bin}" ]] || ftctl_vmware_mover_die 82 "DR_CBT_QUERY_FAILED: pyVmomi runtime was not found"
  [[ -f "${helper}" ]] || ftctl_vmware_mover_die 82 "DR_CBT_QUERY_FAILED: CBT query helper was not found"
  [[ -n "${vm_ref}" && -n "${snapshot_name}" && -n "${disk_id}" ]] || \
    ftctl_vmware_mover_die 80 "DR_VMWARE_CBT_DISK_ID_UNRESOLVED: VM, snapshot, or disk identifier is empty"
  local -a helper_args=(--vm "${vm_ref}" --snapshot "${snapshot_name}" --disk-id "${disk_id}" --change-id "${previous_change_id}")
  [[ -n "${device_key}" && "${device_key}" != "null" ]] && helper_args+=(--device-key "${device_key}")
  [[ "${verify_current}" == "true" ]] && helper_args+=(--verify-current)
  query_attempts="${FTCTL_DR_VMWARE_CBT_QUERY_ATTEMPTS:-3}"
  query_retry_sec="${FTCTL_DR_VMWARE_CBT_QUERY_RETRY_SEC:-2}"
  [[ "${query_attempts}" =~ ^[1-9][0-9]*$ ]] || query_attempts=3
  [[ "${query_retry_sec}" =~ ^[0-9]+$ ]] || query_retry_sec=2
  query_error_path="${output_path}.stderr"
  while (( query_attempt <= query_attempts )); do
    rm -f "${output_path}" "${query_error_path}"
    if VCENTER_HOST="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    VCENTER_USER="${username}" \
    VCENTER_PASS="$(cat "${password_file}")" \
    VCENTER_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 0 || printf 1)" \
      "${python_bin}" "${helper}" "${helper_args[@]}" > "${output_path}" 2> "${query_error_path}"; then
      query_rc=0
      break
    else
      query_rc=$?
    fi
    if (( query_attempt >= query_attempts )) \
        || ! grep -Eqi 'vim\.hostd\.vmsvc\.cbt\.cannotGetChanges|Change tracking invalid or disk in use' \
          "${query_error_path}"; then
      break
    fi
    printf 'VMware CBT query is temporarily busy for %s; retrying (%s/%s)\n' \
      "${disk_id}" "${query_attempt}" "${query_attempts}" >&2
    (( query_retry_sec > 0 )) && sleep "${query_retry_sec}"
    query_attempt=$((query_attempt + 1))
  done
  if (( query_rc != 0 )); then
    cat "${query_error_path}" >&2 2>/dev/null || true
    if [[ "${verify_current}" != "true" && -n "${previous_change_id}" && "${previous_change_id}" != "null" && "${previous_change_id}" != "*" ]]; then
      current_probe_path="${output_path}.current"
      if VCENTER_HOST="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
      VCENTER_USER="${username}" \
      VCENTER_PASS="$(cat "${password_file}")" \
      VCENTER_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 0 || printf 1)" \
        "${python_bin}" "${helper}" "${helper_args[@]}" --verify-current \
          > "${current_probe_path}" \
          && jq -e '.activation_verified == true and .new_change_id != null and .new_change_id != ""' \
            "${current_probe_path}" >/dev/null 2>&1; then
        rm -f "${current_probe_path}"
        ftctl_vmware_mover_publish_cbt_failure "DR_CBT_BASELINE_INVALID" \
          "The previous VMware CBT changeId is outside the current CBT epoch for ${disk_id}" "${disk_id}" || true
        ftctl_vmware_mover_die 85 "DR_CBT_RESEED_REQUIRED: previous VMware CBT changeId is outside the current CBT epoch for ${disk_id}"
      fi
      rm -f "${current_probe_path}"
    fi
    ftctl_vmware_mover_publish_cbt_failure "DR_VMWARE_CBT_QUERY_FAILED" \
      "QueryChangedDiskAreas failed for ${disk_id}" "${disk_id}" || true
    ftctl_vmware_mover_die 82 "DR_CBT_QUERY_FAILED: QueryChangedDiskAreas failed for ${disk_id}"
  fi
  rm -f "${query_error_path}"
  if ! jq -e '.new_change_id != null and .new_change_id != ""' "${output_path}" >/dev/null; then
    ftctl_vmware_mover_publish_cbt_failure "DR_VMWARE_CBT_CHANGE_ID_MISSING" \
      "VMware did not return a current changeId for ${disk_id}" "${disk_id}" || true
    ftctl_vmware_mover_die 83 "DR_CBT_BASELINE_INVALID: VMware did not return a new changeId for ${disk_id}"
  fi
}

ftctl_vmware_mover_publish_cbt_active() {
  local status_path="${1-}" evidence_path="${2-}" snapshot_name="${3-}" snapshot_ref="${4-}"
  [[ -n "${status_path}" && -f "${evidence_path}" ]] || return 0
  python3 - "${status_path}" "${evidence_path}" "${snapshot_name}" "${snapshot_ref}" <<'PY'
import json
import os
import sys
import time

status_path, evidence_path, snapshot_name, snapshot_ref = sys.argv[1:5]
status = {}
if os.path.isfile(status_path):
    with open(status_path, "r", encoding="utf-8") as handle:
        value = json.load(handle)
        if isinstance(value, dict):
            status = value
with open(evidence_path, "r", encoding="utf-8") as handle:
    evidence = json.load(handle)
if not isinstance(evidence, list) or not evidence:
    raise SystemExit("CBT activation evidence is empty")
if not all(item.get("querySucceeded") and item.get("changeId") for item in evidence):
    raise SystemExit("CBT activation evidence is incomplete")
status.update({
    "schemaVersion": 2,
    "phase": "cbt-activation",
    "lifecycleState": "ACTIVE",
    "enabled": True,
    "error_code": "",
    "message": "CBT activation was verified from the run snapshot",
    "checkedAtEpochMs": int(time.time() * 1000),
    "activationEvidence": {
        "snapshotName": snapshot_name,
        "snapshotRef": snapshot_ref,
        "verifiedAtEpochMs": int(time.time() * 1000),
        "disks": evidence,
    },
})
tmp = status_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(status, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, status_path)
PY
}

ftctl_vmware_mover_free_nbd() {
  local excluded="${1-}" dev name idx
  local start="${FTCTL_DR_NBD_DEVICE_START}" end="${FTCTL_DR_NBD_DEVICE_END}"
  [[ "${start}" =~ ^[0-9]+$ ]] || start=16
  [[ "${end}" =~ ^[0-9]+$ ]] || end=31
  (( start <= end )) || {
    start=16
    end=31
  }
  modprobe nbd "nbds_max=${FTCTL_DR_NBD_MODULE_MAX_DEVICES}" \
    "max_part=${FTCTL_DR_NBD_MODULE_MAX_PARTITIONS}" >/dev/null 2>&1 || true
  for ((idx = start; idx <= end; idx++)); do
    dev="/dev/nbd${idx}"
    [[ -b "${dev}" && "${dev}" != "${excluded}" ]] || continue
    name="${dev#/dev/}"
    if ftctl_vmware_mover_nbd_is_stable_free "${dev}" &&
        ! ftctl_vmware_mover_nbd_is_quarantined "${dev}"; then
      printf '%s\n' "${dev}"
      return 0
    fi
  done
  return 1
}

ftctl_vmware_mover_require_nbd_capacity() {
  local capacity_json configured ready error_code
  capacity_json="$(ftctl_dr_nbd_capacity_json)"
  configured="$(JSON_TEXT="${capacity_json}" python3 -c 'import json,os; print(str(bool(json.loads(os.environ["JSON_TEXT"]).get("configured"))).lower())')"
  ready="$(JSON_TEXT="${capacity_json}" python3 -c 'import json,os; print(str(bool(json.loads(os.environ["JSON_TEXT"]).get("ready"))).lower())')"
  error_code="$(JSON_TEXT="${capacity_json}" python3 -c 'import json,os; print(json.loads(os.environ["JSON_TEXT"]).get("errorCode") or "")')"
  [[ "${configured}" == "true" ]] || ftctl_vmware_mover_die 98 \
    "${error_code:-DR_NBD_CAPACITY_INVALID}: reserved NBD devices ${FTCTL_DR_NBD_DEVICE_START}-${FTCTL_DR_NBD_DEVICE_END} are not installed"
  [[ "${ready}" == "true" ]] || ftctl_vmware_mover_die 97 \
    "${error_code:-DR_RESOURCE_BUSY}: reserved NBD devices are temporarily busy"
}

ftctl_vmware_mover_now_ms() {
  local value
  value="$(date +%s%3N 2>/dev/null || true)"
  if [[ "${value}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${value}"
  else
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
  fi
}

ftctl_vmware_mover_nbd_quarantine_path() {
  local device="${1-}" plan="${2-${FTCTL_DR_PLAN_UUID:-unknown}}" name
  name="${device#/dev/}"
  printf '%s/%s/%s.json\n' "${FTCTL_DR_NBD_QUARANTINE_ROOT}" "${plan}" "${name}"
}

ftctl_vmware_mover_nbd_is_quarantined() {
  local device="${1-}" name record
  name="${device#/dev/}"
  [[ -d "${FTCTL_DR_NBD_QUARANTINE_ROOT}" ]] || return 1
  while IFS= read -r record; do
    [[ -n "${record}" ]] && return 0
  done < <(find "${FTCTL_DR_NBD_QUARANTINE_ROOT}" -mindepth 2 -maxdepth 2 \
    -type f -name "${name}.json" -print 2>/dev/null | head -n 1)
  return 1
}

ftctl_vmware_mover_nbd_partition_count() {
  local device="${1-}" name entry count=0
  name="${device#/dev/}"
  shopt -s nullglob
  for entry in "${FTCTL_DR_NBD_SYSFS_ROOT}/${name}"p*; do
    [[ -e "${entry}" ]] && count=$((count + 1))
  done
  shopt -u nullglob
  printf '%s\n' "${count}"
}

ftctl_vmware_mover_nbd_holder_count() {
  local device="${1-}" name holder_dir
  name="${device#/dev/}"
  holder_dir="${FTCTL_DR_NBD_SYSFS_ROOT}/${name}/holders"
  [[ -d "${holder_dir}" ]] || {
    printf '0\n'
    return 0
  }
  find "${holder_dir}" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' '
}

ftctl_vmware_mover_nbd_mounted_count() {
  local device="${1-}"
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -nrpo MOUNTPOINT "${device}" 2>/dev/null | awk 'NF {count++} END {print count + 0}'
  else
    printf '0\n'
  fi
}

ftctl_vmware_mover_nbd_release_partition_holders() {
  local device="${1-}" name entry holder holder_name mounts
  name="${device#/dev/}"
  shopt -s nullglob
  for entry in "${FTCTL_DR_NBD_SYSFS_ROOT}/${name}"p*/holders/*; do
    [[ -e "${entry}" ]] || continue
    holder="$(readlink -f "${entry}" 2>/dev/null || printf '%s' "${entry}")"
    holder_name="${holder##*/}"
    [[ "${holder_name}" == dm-* ]] || {
      shopt -u nullglob
      return 1
    }
    command -v dmsetup >/dev/null 2>&1 || {
      shopt -u nullglob
      return 1
    }
    mounts="$(lsblk -nrpo MOUNTPOINTS "/dev/${holder_name}" 2>/dev/null |
      awk 'NF {print; exit}')"
    [[ -z "${mounts}" ]] || {
      shopt -u nullglob
      return 1
    }
    blockdev --flushbufs "/dev/${holder_name}" >/dev/null 2>&1 || true
    dmsetup remove --retry "/dev/${holder_name}" >/dev/null 2>&1 || {
      shopt -u nullglob
      return 1
    }
  done
  shopt -u nullglob
  return 0
}

ftctl_vmware_mover_nbd_is_stable_free() {
  local device="${1-}" name pid="" sectors=0 holders=0 partitions=0 mounted=0
  name="${device#/dev/}"
  [[ -e "${FTCTL_DR_NBD_SYSFS_ROOT}/${name}" ]] || return 1
  pid="$(cat "${FTCTL_DR_NBD_SYSFS_ROOT}/${name}/pid" 2>/dev/null || true)"
  sectors="$(cat "${FTCTL_DR_NBD_SYSFS_ROOT}/${name}/size" 2>/dev/null || printf '0')"
  holders="$(ftctl_vmware_mover_nbd_holder_count "${device}")"
  partitions="$(ftctl_vmware_mover_nbd_partition_count "${device}")"
  mounted="$(ftctl_vmware_mover_nbd_mounted_count "${device}")"
  [[ -z "${pid}" && "${sectors:-0}" == "0" && "${holders:-0}" == "0" &&
    "${partitions:-0}" == "0" && "${mounted:-0}" == "0" ]]
}

ftctl_vmware_mover_nbd_wait_stable_free() {
  local device="${1-}" timeout_ms="${2-${FTCTL_DR_NBD_DRAIN_TIMEOUT_MS}}"
  local poll_ms="${3-${FTCTL_DR_NBD_DRAIN_POLL_MS}}" start now stable=0 sleep_value
  [[ "${timeout_ms}" =~ ^[1-9][0-9]*$ ]] || timeout_ms=10000
  [[ "${poll_ms}" =~ ^[1-9][0-9]*$ ]] || poll_ms=50
  start="$(ftctl_vmware_mover_now_ms)"
  while true; do
    if ftctl_vmware_mover_nbd_is_stable_free "${device}"; then
      stable=$((stable + 1))
      if (( stable >= FTCTL_DR_NBD_STABLE_POLLS )); then
        return 0
      fi
    else
      stable=0
    fi
    now="$(ftctl_vmware_mover_now_ms)"
    (( now - start < timeout_ms )) || return 1
    printf -v sleep_value '%d.%03d' "$((poll_ms / 1000))" "$((poll_ms % 1000))"
    sleep "${sleep_value}"
  done
}

ftctl_vmware_mover_nbd_write_quarantine() {
  local device="${1-}" role="${2-}" method="${3-}" error_code="${4-}" error_message="${5-}"
  local path now
  path="$(ftctl_vmware_mover_nbd_quarantine_path "${device}")"
  now="$(ftctl_vmware_mover_now_ms)"
  mkdir -p "$(dirname "${path}")"
  python3 - "${path}" "${FTCTL_DR_PLAN_UUID:-}" "${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}" \
    "${device#/dev/}" "${role}" "${method}" "${error_code}" "${error_message}" "${now}" <<'PY'
import json
import os
import sys

path, plan, sequence, device, role, method, error_code, error_message, now = sys.argv[1:10]
payload = {
    "schemaVersion": 1,
    "planUuid": plan,
    "cycleSequence": int(sequence or 0),
    "deviceName": device,
    "role": role,
    "attachMethod": method,
    "state": "QUARANTINED",
    "errorCode": error_code,
    "errorMessage": error_message,
    "quarantinedAtEpochMs": int(now),
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, path)
PY
}

ftctl_vmware_mover_nbd_clear_quarantine() {
  local device="${1-}" plan="${2-${FTCTL_DR_PLAN_UUID:-unknown}}"
  rm -f "$(ftctl_vmware_mover_nbd_quarantine_path "${device}" "${plan}")"
}

ftctl_vmware_mover_nbd_set_failure() {
  local device="${1-}" role="${2-}" method="${3-}" code="${4-DR_NBD_TEARDOWN_TIMEOUT}" message="${5-NBD teardown failed}"
  FTCTL_DR_NBD_TEARDOWN_STATE="QUARANTINED"
  FTCTL_DR_NBD_QUARANTINED_DEVICE_COUNT=$((FTCTL_DR_NBD_QUARANTINED_DEVICE_COUNT + 1))
  FTCTL_DR_NBD_TEARDOWN_ERROR_CODE="${code}"
  FTCTL_DR_NBD_TEARDOWN_ERROR_MESSAGE="${message}"
  ftctl_vmware_mover_nbd_write_quarantine "${device}" "${role}" "${method}" "${code}" "${message}" || true
}

ftctl_vmware_mover_nbd_drain() {
  local device="${1-}" role="${2-}" method="${3-}" started now disconnect_rc=0
  [[ -n "${device}" ]] || return 0
  started="$(ftctl_vmware_mover_now_ms)"
  [[ "${FTCTL_DR_NBD_TEARDOWN_STARTED_AT_MS}" != "0" ]] ||
    FTCTL_DR_NBD_TEARDOWN_STARTED_AT_MS="${started}"
  FTCTL_DR_NBD_TEARDOWN_STATE="DRAINING"

  if [[ "${role}" == "TARGET" ]] && ! blockdev --flushbufs "${device}" >/dev/null 2>&1; then
    ftctl_vmware_mover_nbd_set_failure "${device}" "${role}" "${method}" \
      "DR_NBD_TARGET_FLUSH_FAILED" "Target NBD flush failed"
    return 96
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout="${FTCTL_DR_NBD_UDEV_SETTLE_TIMEOUT_SEC}" >/dev/null 2>&1 || true
  fi
  if ! ftctl_vmware_mover_nbd_release_partition_holders "${device}"; then
    ftctl_vmware_mover_nbd_set_failure "${device}" "${role}" "${method}" \
      "DR_NBD_DEVICE_BUSY" "Mounted, active, or unsupported NBD partition holder remained"
    return 94
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout="${FTCTL_DR_NBD_UDEV_SETTLE_TIMEOUT_SEC}" >/dev/null 2>&1 || true
  fi
  if command -v partx >/dev/null 2>&1; then
    partx -d "${device}" >/dev/null 2>&1 || true
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout="${FTCTL_DR_NBD_UDEV_SETTLE_TIMEOUT_SEC}" >/dev/null 2>&1 || true
  fi

  case "${method}" in
    QEMU_NBD) qemu-nbd --disconnect "${device}" >/dev/null 2>&1 || disconnect_rc=$? ;;
    NBD_CLIENT) nbd-client -d "${device}" >/dev/null 2>&1 || disconnect_rc=$? ;;
    *) disconnect_rc=2 ;;
  esac
  if ! ftctl_vmware_mover_nbd_wait_stable_free "${device}"; then
    if [[ "${disconnect_rc}" != "0" ]]; then
      ftctl_vmware_mover_nbd_set_failure "${device}" "${role}" "${method}" \
        "DR_NBD_DISCONNECT_FAILED" "NBD disconnect failed and the device remained busy"
      return 93
    else
      ftctl_vmware_mover_nbd_set_failure "${device}" "${role}" "${method}" \
        "DR_NBD_TEARDOWN_TIMEOUT" "NBD device did not reach stable-free before timeout"
      return 92
    fi
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout="${FTCTL_DR_NBD_UDEV_SETTLE_TIMEOUT_SEC}" >/dev/null 2>&1 || true
  fi
  ftctl_vmware_mover_nbd_is_stable_free "${device}" || {
    ftctl_vmware_mover_nbd_set_failure "${device}" "${role}" "${method}" \
      "DR_NBD_DEVICE_BUSY" "NBD partition, holder, or mount remained after disconnect"
    return 94
  }
  ftctl_vmware_mover_nbd_clear_quarantine "${device}"
  now="$(ftctl_vmware_mover_now_ms)"
  FTCTL_DR_NBD_TEARDOWN_COMPLETED_AT_MS="${now}"
  FTCTL_DR_NBD_TEARDOWN_DURATION_MS=$((FTCTL_DR_NBD_TEARDOWN_DURATION_MS + now - started))
  FTCTL_DR_NBD_TEARDOWN_STATE="DRAINED"
  return 0
}

ftctl_vmware_mover_nbd_cleanup_pair() {
  local target_dev="${1-}" source_dev="${2-}" first_rc=0 rc=0
  if [[ -n "${target_dev}" ]]; then
    ftctl_vmware_mover_nbd_drain "${target_dev}" "TARGET" "QEMU_NBD" || rc=$?
    [[ "${first_rc}" != "0" ]] || first_rc="${rc}"
  fi
  rc=0
  if [[ -n "${source_dev}" ]]; then
    ftctl_vmware_mover_nbd_drain "${source_dev}" "SOURCE" "NBD_CLIENT" || rc=$?
    [[ "${first_rc}" != "0" ]] || first_rc="${rc}"
  fi
  return "${first_rc}"
}

ftctl_vmware_mover_nbd_die() {
  local rc="${1-92}" code
  case "${rc}" in
    93) code="DR_NBD_DISCONNECT_FAILED" ;;
    94) code="DR_NBD_DEVICE_BUSY" ;;
    95) code="DR_NBD_DEVICE_QUARANTINED" ;;
    96) code="DR_NBD_TARGET_FLUSH_FAILED" ;;
    *) rc=92; code="DR_NBD_TEARDOWN_TIMEOUT" ;;
  esac
  ftctl_vmware_mover_die "${rc}" "${code}: ${FTCTL_DR_NBD_TEARDOWN_ERROR_MESSAGE:-NBD teardown failed}"
}

ftctl_vmware_mover_nbd_append_metrics() {
  local metrics_path="${1-}"
  python3 - "${metrics_path}" "${FTCTL_DR_NBD_TEARDOWN_STATE}" \
    "${FTCTL_DR_NBD_TEARDOWN_STARTED_AT_MS}" "${FTCTL_DR_NBD_TEARDOWN_COMPLETED_AT_MS}" \
    "${FTCTL_DR_NBD_TEARDOWN_DURATION_MS}" "${FTCTL_DR_NBD_SOURCE_DEVICE_COUNT}" \
    "${FTCTL_DR_NBD_TARGET_DEVICE_COUNT}" "${FTCTL_DR_NBD_QUARANTINED_DEVICE_COUNT}" \
    "${FTCTL_DR_NBD_TEARDOWN_ERROR_CODE}" "${FTCTL_DR_NBD_TEARDOWN_ERROR_MESSAGE}" <<'PY'
import json
import os
import sys

path, state, started, completed, duration, source_count, target_count, quarantined_count, error_code, error_message = sys.argv[1:11]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
payload.update({
    "nbdTeardownState": state,
    "nbdTeardownStartedAtEpochMs": int(started or 0),
    "nbdTeardownCompletedAtEpochMs": int(completed or 0),
    "nbdTeardownDurationMs": int(duration or 0),
    "nbdSourceDeviceCount": int(source_count or 0),
    "nbdTargetDeviceCount": int(target_count or 0),
    "nbdQuarantinedDeviceCount": int(quarantined_count or 0),
    "nbdTeardownErrorCode": error_code,
    "nbdTeardownErrorMessage": error_message,
})
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, path)
PY
}

ftctl_vmware_mover_nbd_recover_quarantine() {
  local plan="${1-}" plan_dir record device role method rc=0 failed=0
  [[ -n "${plan}" ]] || return 2
  plan_dir="${FTCTL_DR_NBD_QUARANTINE_ROOT}/${plan}"
  [[ -d "${plan_dir}" ]] || return 0
  for record in "${plan_dir}"/*.json; do
    [[ -f "${record}" ]] || continue
    device="/dev/$(jq -r '.deviceName // ""' "${record}")"
    role="$(jq -r '.role // ""' "${record}")"
    method="$(jq -r '.attachMethod // ""' "${record}")"
    rc=0
    FTCTL_DR_PLAN_UUID="${plan}" ftctl_vmware_mover_nbd_drain "${device}" "${role}" "${method}" || rc=$?
    if [[ "${rc}" == "0" ]]; then
      rm -f "${record}"
    else
      failed=$((failed + 1))
    fi
  done
  rmdir "${plan_dir}" 2>/dev/null || true
  [[ "${failed}" == "0" ]]
}

ftctl_vmware_mover_wait_block_device_ready() {
  local device="${1-}" expected_bytes="${2-}" timeout_ms="${3-${FTCTL_DR_NBD_READY_TIMEOUT_MS}}"
  local poll_ms="${4-${FTCTL_DR_NBD_READY_POLL_MS}}"
  local name start now observed=0 sectors=0 sysfs_bytes=0 sleep_value
  [[ -n "${device}" && "${expected_bytes}" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "${timeout_ms}" =~ ^[1-9][0-9]*$ ]] || timeout_ms=5000
  [[ "${poll_ms}" =~ ^[1-9][0-9]*$ ]] || poll_ms=50
  name="${device#/dev/}"
  start="$(ftctl_vmware_mover_now_ms)"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=1 >/dev/null 2>&1 || true
  fi
  while true; do
    observed="$(blockdev --getsize64 "${device}" 2>/dev/null || printf '0')"
    sectors="$(cat "${FTCTL_DR_NBD_SYSFS_ROOT}/${name}/size" 2>/dev/null || printf '0')"
    [[ "${observed}" =~ ^[0-9]+$ ]] || observed=0
    [[ "${sectors}" =~ ^[0-9]+$ ]] || sectors=0
    sysfs_bytes=$((sectors * 512))
    FTCTL_DR_NBD_LAST_OBSERVED_BYTES="${observed}"
    FTCTL_DR_NBD_LAST_SYSFS_BYTES="${sysfs_bytes}"
    now="$(ftctl_vmware_mover_now_ms)"
    FTCTL_DR_NBD_LAST_ELAPSED_MS=$((now - start))
    if (( observed >= expected_bytes && sysfs_bytes >= expected_bytes && observed == sysfs_bytes )); then
      return 0
    fi
    if (( now - start >= timeout_ms )); then
      return 1
    fi
    printf -v sleep_value '%d.%03d' "$((poll_ms / 1000))" "$((poll_ms % 1000))"
    sleep "${sleep_value}"
  done
}

ftctl_vmware_mover_resolve_cycle_mode() {
  local rows="${1-}" requested_mode="${2-CBT_INCREMENTAL}"
  python3 - "${requested_mode}" "${rows}" <<'PY'
import json
import hashlib
import sys

requested = sys.argv[1]
rows = json.loads(sys.argv[2])
if not isinstance(rows, list) or not rows:
    raise SystemExit("disk execution rows must be a non-empty list")

invalid = []
generations = set()
identities = []
for row in rows:
    if not isinstance(row, dict):
        raise SystemExit("disk execution row must be an object")
    disk_key = str(row.get("sourceDiskKey") or row.get("cbtDiskId") or row.get("index") or "")
    identity = str(row.get("diskIdentityHash") or "")
    identities.append(identity or disk_key)
    generation = int(row.get("baselineGeneration") or 0)
    if generation > 0:
        generations.add(generation)
    reason = ""
    if not str(row.get("previousChangeId") or ""):
        reason = "MISSING_CHANGE_ID"
    elif generation <= 0:
        reason = "MISSING_BASELINE_GENERATION"
    elif str(row.get("baselineState") or "") != "LOCAL_DURABLE":
        reason = "BASELINE_NOT_LOCAL_DURABLE"
    elif not identity:
        reason = "DISK_IDENTITY_UNRESOLVED"
    if reason:
        invalid.append({"sourceDiskKey": disk_key, "reason": reason})

effective = requested
decision = "BASELINE_NOT_REQUIRED"
automatic = False
reseed_reason = ""
if requested == "CBT_INCREMENTAL":
    if invalid:
        reseed_reason = invalid[0]["reason"]
        if reseed_reason == "BASELINE_NOT_LOCAL_DURABLE":
            effective = "BLOCKED"
            decision = reseed_reason
        else:
            effective = "FULL_RESEED"
            decision = reseed_reason
            automatic = True
    elif len(generations) != 1:
        effective = "FULL_RESEED"
        decision = "BASELINE_GENERATION_DIVERGED"
        reseed_reason = decision
        automatic = True
    else:
        effective = "CBT_INCREMENTAL"
        decision = "BASELINE_VALID"
elif requested == "FULL_RESEED":
    decision = "OPERATOR_REQUESTED"
    reseed_reason = decision

identity_material = "|".join(sorted(identities)).encode("utf-8")
payload = {
    "requestedMode": requested,
    "effectiveMode": effective,
    "automaticReseed": automatic,
    "decisionCode": decision,
    "reseedReason": reseed_reason,
    "invalidDisks": invalid,
    "invalidBaselineDiskCount": len(invalid),
    "baselineGeneration": next(iter(generations)) if len(generations) == 1 else 0,
    "diskIdentityHash": "sha256:" + hashlib.sha256(identity_material).hexdigest(),
}
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
}

ftctl_vmware_mover_resolve_requested_mode() {
  local decision
  decision="$(ftctl_vmware_mover_resolve_cycle_mode "${1-}" "${2-CBT_INCREMENTAL}")" || return $?
  jq -er '.effectiveMode' <<< "${decision}"
}

ftctl_vmware_mover_reseed_guard() {
  local state_path="${1-}" decision="${2-}"
  python3 - "${state_path}" "${decision}" <<'PY'
import json
import os
import sys

path, raw = sys.argv[1:3]
decision = json.loads(raw)
previous = {}
if path and os.path.isfile(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
            if isinstance(value, dict):
                previous = value
    except (OSError, ValueError, TypeError):
        previous = {}

if decision.get("automaticReseed"):
    same = (
        previous.get("automaticReseed") is True
        and previous.get("reseedReason") == decision.get("reseedReason")
        and previous.get("baselineGeneration") == decision.get("baselineGeneration")
        and previous.get("diskIdentityHash") == decision.get("diskIdentityHash")
    )
    if same:
        raise SystemExit(90)
PY
}

ftctl_vmware_mover_commit_mode_decision() {
  local state_path="${1-}" decision="${2-}" actual_mode="${3-}"
  python3 - "${state_path}" "${decision}" "${actual_mode}" <<'PY'
import json
import os
import sys

path, raw, actual_mode = sys.argv[1:4]
if not path:
    raise SystemExit(0)
decision = json.loads(raw)
payload = {
    "automaticReseed": bool(decision.get("automaticReseed")),
    "reseedReason": str(decision.get("reseedReason") or ""),
    "decisionCode": str(decision.get("decisionCode") or ""),
    "baselineGeneration": int(decision.get("baselineGeneration") or 0),
    "diskIdentityHash": str(decision.get("diskIdentityHash") or ""),
    "actualMode": actual_mode,
    "consecutiveAutomaticReseedCount": 1 if decision.get("automaticReseed") else 0,
}
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, path)
PY
}

ftctl_vmware_mover_patch_disk() {
  local source_vmdk="${1-}" source_vm_ref="${2-}" source_snapshot_ref="${3-}" target_uri="${4-}" target_format="${5-}" label="${6-}"
  local endpoint="${7-}" username="${8-}" password_file="${9-}" tls_verify="${10-}" thumbprint="${11-}" libdir="${12-}"
  local areas_path="${13-}" metrics_path="${14-}" expected_bytes="${15-}" work_dir socket_path pid="" source_opts safe_label nbdkit_log qemu_info_log transports
  local progress_path="${16-}" progress_base_bytes="${17-0}" progress_total_bytes="${18-0}" progress_disk_index="${19-0}" progress_disk_count="${20-1}" progress_final_disk="${21-false}"
  local source_dev="" target_dev="" target_cleanup_dev="" target_direct=false target_direct_block=false
  local patch_helper lock_file="${FTCTL_DR_VMWARE_NBD_LOCK:-/run/ablestack-vm-ftctl/dr-runtime/nbd.lock}"
  local attach_attempt ready=false attached=false cleanup_rc=0

  FTCTL_DR_NBD_TEARDOWN_STATE="NOT_APPLICABLE"
  FTCTL_DR_NBD_TEARDOWN_STARTED_AT_MS=0
  FTCTL_DR_NBD_TEARDOWN_COMPLETED_AT_MS=0
  FTCTL_DR_NBD_TEARDOWN_DURATION_MS=0
  FTCTL_DR_NBD_SOURCE_DEVICE_COUNT=0
  FTCTL_DR_NBD_TARGET_DEVICE_COUNT=0
  FTCTL_DR_NBD_QUARANTINED_DEVICE_COUNT=0
  FTCTL_DR_NBD_TEARDOWN_ERROR_CODE=""
  FTCTL_DR_NBD_TEARDOWN_ERROR_MESSAGE=""

  [[ -s "${areas_path}" ]] || ftctl_vmware_mover_die 84 "DR_CBT_EXTENT_INVALID: changed-area payload is missing for ${label}"
  ftctl_vmware_mover_require_nbd_capacity
  work_dir="$(mktemp -d -t ftctl.vmware.patch.XXXXXX)"
  socket_path="${work_dir}/vddk.sock"
  safe_label="$(ftctl_vmware_mover_safe_label "${label}")"
  nbdkit_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/nbdkit-patch-${safe_label}.log"
  qemu_info_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/qemu-img-patch-info-${safe_label}.log"
  transports="${FTCTL_DR_VMWARE_VDDK_TRANSPORTS:-nbd:nbdssl}"
  endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
  if [[ "${tls_verify}" != "true" ]]; then
    thumbprint="$(ftctl_vmware_mover_resolve_thumbprint "${endpoint}" "${tls_verify}" "${thumbprint}" || true)"
    if [[ "${FTCTL_DR_VMWARE_CONFIGURED_THUMBPRINT_SOURCE:-}" == "backend-auto" ]]; then
      FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="backend-auto-refreshed"
    fi
    [[ -n "${thumbprint}" ]] || ftctl_vmware_mover_die 77 "DR_VMWARE_VDDK_THUMBPRINT_UNRESOLVED: thumbprint is missing for ${label}"
  fi
  # Read the complete snapshot chain: parent-only sectors are valid guest data.
  # SINGLE_LINK returns holes for them and corrupts full/CBT copies (#1003).
  local nbdkit_args=(--exit-with-parent --foreground --unix "${socket_path}" -r vddk
    "server=${endpoint}" "user=${username}" "password=+${password_file}" "file=${source_vmdk}" "single-link=false")
  [[ -n "${source_vm_ref}" ]] && nbdkit_args+=("vm=moref=${source_vm_ref}")
  [[ -n "${source_snapshot_ref}" ]] && nbdkit_args+=("snapshot=${source_snapshot_ref}")
  [[ -n "${transports}" ]] && nbdkit_args+=("transports=${transports}")
  [[ -n "${thumbprint}" && "${tls_verify}" != "true" ]] && nbdkit_args+=("thumbprint=${thumbprint}")
  [[ -n "${libdir}" && -d "${libdir}" ]] && nbdkit_args+=("libdir=${libdir}")
  nbdkit "${nbdkit_args[@]}" >"${nbdkit_log}" 2>&1 &
  pid=$!
  if ! ftctl_vmware_mover_wait_for_socket "${socket_path}" "${pid}" "${FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT}"; then
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
  fi
  source_opts="$(ftctl_vmware_mover_source_image_opts "${socket_path}")"
  qemu-img info --force-share --image-opts "${source_opts}" >/dev/null 2>"${qemu_info_log}" || {
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
  }
  ftctl_vmware_mover_write_source_open_status true "" "VDDK source open succeeded" \
    "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"

  mkdir -p "$(dirname "${lock_file}")"
  exec 9>"${lock_file}"
  flock -x 9
  source_dev="$(ftctl_vmware_mover_free_nbd || true)"
  if [[ -z "${source_dev}" ]]; then
    flock -u 9
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_die 97 "DR_RESOURCE_BUSY: no free source NBD device"
  fi
  if ! nbd-client -u -N default "${socket_path}" "${source_dev}" >/dev/null; then
    flock -u 9
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_die 86 "DR_CBT_PATCH_FAILED: source NBD attach failed"
  fi
  FTCTL_DR_NBD_SOURCE_DEVICE_COUNT=1
  if ! ftctl_vmware_mover_wait_block_device_ready "${source_dev}" "${expected_bytes}"; then
    cleanup_rc=0
    ftctl_vmware_mover_nbd_cleanup_pair "" "${source_dev}" || cleanup_rc=$?
    flock -u 9
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    [[ "${cleanup_rc}" == "0" ]] || ftctl_vmware_mover_nbd_die "${cleanup_rc}"
    ftctl_vmware_mover_die 89 "DR_SOURCE_NBD_SIZE_NOT_READY: expected=${expected_bytes} observed=${FTCTL_DR_NBD_LAST_OBSERVED_BYTES:-0} sysfs=${FTCTL_DR_NBD_LAST_SYSFS_BYTES:-0} elapsedMs=${FTCTL_DR_NBD_LAST_ELAPSED_MS:-0}"
  fi
  if [[ "${target_uri}" == rbd:* ]]; then
    target_dev="${target_uri}"
    target_direct=true
    ready=true
  elif [[ -b "${target_uri}" ]]; then
    target_dev="${target_uri}"
    target_direct=true
    target_direct_block=true
    if ftctl_vmware_mover_wait_block_device_ready "${target_dev}" "${expected_bytes}"; then
      ready=true
    fi
  else
    target_dev="$(ftctl_vmware_mover_free_nbd "${source_dev}" || true)"
    if [[ -z "${target_dev}" ]]; then
      cleanup_rc=0
      ftctl_vmware_mover_nbd_cleanup_pair "" "${source_dev}" || cleanup_rc=$?
      flock -u 9
      ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
      [[ "${cleanup_rc}" == "0" ]] || ftctl_vmware_mover_nbd_die "${cleanup_rc}"
      ftctl_vmware_mover_die 97 "DR_RESOURCE_BUSY: no free target NBD device"
    fi
    target_cleanup_dev="${target_dev}"
    for ((attach_attempt=1; attach_attempt<=FTCTL_DR_NBD_ATTACH_ATTEMPTS; attach_attempt++)); do
      attached=false
      if qemu-nbd --connect="${target_dev}" --format="${target_format:-raw}" "${target_uri}" >/dev/null; then
        attached=true
        FTCTL_DR_NBD_TARGET_DEVICE_COUNT=1
        if ftctl_vmware_mover_wait_block_device_ready "${target_dev}" "${expected_bytes}"; then
          ready=true
          break
        fi
      fi
      if [[ "${attached}" == "true" ]]; then
        cleanup_rc=0
        ftctl_vmware_mover_nbd_cleanup_pair "${target_dev}" "" || cleanup_rc=$?
        [[ "${cleanup_rc}" == "0" ]] || {
          flock -u 9
          ftctl_vmware_mover_nbd_cleanup_pair "" "${source_dev}" >/dev/null 2>&1 || true
          ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
          ftctl_vmware_mover_nbd_die "${cleanup_rc}"
        }
      fi
    done
  fi
  if [[ "${ready}" != "true" ]]; then
    cleanup_rc=0
    ftctl_vmware_mover_nbd_cleanup_pair "" "${source_dev}" || cleanup_rc=$?
    flock -u 9
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    [[ "${cleanup_rc}" == "0" ]] || ftctl_vmware_mover_nbd_die "${cleanup_rc}"
    if [[ "${target_direct}" == "true" ]]; then
      ftctl_vmware_mover_die 89 "DR_TARGET_BLOCK_SIZE_NOT_READY: expected=${expected_bytes} observed=${FTCTL_DR_NBD_LAST_OBSERVED_BYTES:-0} sysfs=${FTCTL_DR_NBD_LAST_SYSFS_BYTES:-0} elapsedMs=${FTCTL_DR_NBD_LAST_ELAPSED_MS:-0}"
    fi
    ftctl_vmware_mover_die 89 "DR_TARGET_NBD_SIZE_NOT_READY: expected=${expected_bytes} observed=${FTCTL_DR_NBD_LAST_OBSERVED_BYTES:-0} sysfs=${FTCTL_DR_NBD_LAST_SYSFS_BYTES:-0} elapsedMs=${FTCTL_DR_NBD_LAST_ELAPSED_MS:-0} attempts=${FTCTL_DR_NBD_ATTACH_ATTEMPTS}"
  fi
  flock -u 9

  patch_helper="${FTCTL_DR_VMWARE_EXTENT_PATCH_HELPER:-${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_extent_patch.py}"
  local patch_command=(python3 "${patch_helper}" --source "${source_dev}" --target "${target_dev}" --areas-json "${areas_path}"
      --expected-source-size "${expected_bytes}" --expected-target-size "${expected_bytes}"
      --progress-json "${progress_path}" --progress-base-bytes "${progress_base_bytes:-0}"
      --progress-total-bytes "${progress_total_bytes:-0}" --progress-disk-index "${progress_disk_index:-0}"
      --progress-disk-count "${progress_disk_count:-1}" --progress-disk-label "${label}"
      --progress-mode "${FTCTL_DR_CYCLE_EFFECTIVE_MODE:-CBT_INCREMENTAL}"
      --progress-plan-uuid "${FTCTL_DR_PLAN_UUID:-}" --progress-run-uuid "${FTCTL_DR_RUN_UUID:-}"
      --progress-cycle-sequence "${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}")
  if [[ "${FTCTL_DR_BANDWIDTH_LIMIT_MBPS:-0}" =~ ^[1-9][0-9]*$ ]]; then
    patch_command+=(--bandwidth-limit-mbps "${FTCTL_DR_BANDWIDTH_LIMIT_MBPS}")
  fi
  [[ "${progress_final_disk}" == "true" ]] && patch_command+=(--progress-final-disk)
  if ! "${patch_command[@]}" > "${metrics_path}"; then
    cleanup_rc=0
    ftctl_vmware_mover_nbd_cleanup_pair "${target_cleanup_dev}" "${source_dev}" || cleanup_rc=$?
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    [[ "${cleanup_rc}" == "0" ]] || ftctl_vmware_mover_nbd_die "${cleanup_rc}"
    ftctl_vmware_mover_die 86 "DR_CBT_PATCH_FAILED: extent apply failed for ${label}"
  fi
  if [[ "${target_direct_block}" == "true" ]] &&
      ! blockdev --flushbufs "${target_dev}" >/dev/null 2>&1; then
    cleanup_rc=0
    ftctl_vmware_mover_nbd_cleanup_pair "" "${source_dev}" || cleanup_rc=$?
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    [[ "${cleanup_rc}" == "0" ]] || ftctl_vmware_mover_nbd_die "${cleanup_rc}"
    ftctl_vmware_mover_die 96 "DR_NBD_TARGET_FLUSH_FAILED: direct target flush failed for ${label}"
  fi
  cleanup_rc=0
  ftctl_vmware_mover_nbd_cleanup_pair "${target_cleanup_dev}" "${source_dev}" || cleanup_rc=$?
  ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
  [[ "${cleanup_rc}" == "0" ]] || ftctl_vmware_mover_nbd_die "${cleanup_rc}"
  ftctl_vmware_mover_nbd_append_metrics "${metrics_path}"
}

ftctl_vmware_mover_safe_label() {
  local value="${1:-disk}"
  value="${value//[^A-Za-z0-9_.-]/_}"
  [[ -n "${value}" ]] || value="disk"
  printf '%s\n' "${value}"
}

ftctl_vmware_mover_finalize_transfer_progress() {
  local path="${1-}" total_bytes="${2-0}" processed_bytes="${3-0}" mode="${4-}" disk_count="${5-0}"
  [[ -n "${path}" ]] || return 0
  python3 - "${path}" "${FTCTL_DR_PLAN_UUID:-}" "${FTCTL_DR_RUN_UUID:-}" "${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}" \
    "${total_bytes:-0}" "${processed_bytes:-0}" "${mode}" "${disk_count:-0}" <<'PY'
import json
import os
import sys
import tempfile
import time

path, plan, run, cycle, total, processed, mode, disk_count = sys.argv[1:9]
previous = {}
try:
    with open(path, "r", encoding="utf-8") as handle:
        value = json.load(handle)
        previous = value if isinstance(value, dict) else {}
except (OSError, ValueError):
    pass
total_value = max(0, int(total or 0))
processed_value = max(0, int(processed or 0))
now_ms = int(time.time() * 1000)
payload = dict(previous)
payload.update({
    "schemaVersion": 2,
    "planUuid": plan,
    "runUuid": run,
    "cycleSequence": max(0, int(cycle or 0)),
    "sampleSequence": max(0, int(previous.get("sampleSequence") or 0)) + 1,
    "phase": "COMPLETE",
    "state": "COMPLETE",
    "mode": mode,
    "direction": "VMWARE_TO_KVM",
    "diskCount": max(0, int(disk_count or 0)),
    "bytesTotal": total_value,
    "bytesProcessed": processed_value,
    "sourceReadBytes": processed_value,
    "targetWrittenBytes": processed_value,
    "transferPayloadBytes": processed_value,
    "percent": 100.0,
    "etaSeconds": 0,
    "updatedAtEpochMs": now_ms,
    "heartbeatAtEpochMs": now_ms,
})
directory = os.path.dirname(path) or "."
os.makedirs(directory, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

ftctl_vmware_mover_normalize_vcenter_server() {
  local endpoint="${1-}"
  endpoint="${endpoint#https://}"
  endpoint="${endpoint#http://}"
  endpoint="${endpoint%%/sdk}"
  endpoint="${endpoint%%/api}"
  endpoint="${endpoint%%/client/api}"
  endpoint="${endpoint%%/}"
  printf '%s\n' "${endpoint}"
}

ftctl_vmware_mover_endpoint_connect_target() {
  local endpoint="${1-}"
  endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
  endpoint="${endpoint%%/*}"
  if [[ "${endpoint}" == *:* ]]; then
    printf '%s\n' "${endpoint}"
  else
    printf '%s:443\n' "${endpoint}"
  fi
}

ftctl_vmware_mover_fetch_vcenter_thumbprint() {
  local endpoint="${1-}" connect_target fingerprint
  connect_target="$(ftctl_vmware_mover_endpoint_connect_target "${endpoint}")"
  [[ -n "${connect_target}" ]] || return 1
  if command -v timeout >/dev/null 2>&1; then
    fingerprint="$(timeout 15 openssl s_client -connect "${connect_target}" </dev/null 2>/dev/null \
      | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
      | sed -n 's/^.*Fingerprint=//Ip' \
      | head -n 1 \
      | tr '[:lower:]' '[:upper:]')" || true
  else
    fingerprint="$(openssl s_client -connect "${connect_target}" </dev/null 2>/dev/null \
      | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
      | sed -n 's/^.*Fingerprint=//Ip' \
      | head -n 1 \
      | tr '[:lower:]' '[:upper:]')" || true
  fi
  [[ -n "${fingerprint}" ]] || return 1
  printf '%s\n' "${fingerprint}"
}

ftctl_vmware_mover_resolve_thumbprint() {
  local endpoint="${1-}" tls_verify="${2-}" configured="${3-}" fetched
  FTCTL_DR_VMWARE_SOURCE_OPEN_TLS_VERIFY="${tls_verify}"
  FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT="false"
  FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="missing"
  [[ "${tls_verify}" == "true" ]] && {
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="tls-verify"
    return 0
  }
  if [[ -n "${configured}" && "${FTCTL_DR_VMWARE_CONFIGURED_THUMBPRINT_SOURCE:-}" != "backend-auto" ]]; then
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT="true"
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="runtime"
    printf '%s\n' "${configured}"
    return 0
  fi
  fetched="$(ftctl_vmware_mover_fetch_vcenter_thumbprint "${endpoint}" || true)"
  if [[ -n "${fetched}" ]]; then
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT="true"
    if [[ -n "${configured}" && "${fetched}" != "${configured}" ]]; then
      FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="backend-auto-refreshed"
    else
      FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="host-auto"
    fi
    printf '%s\n' "${fetched}"
    return 0
  fi
  if [[ -n "${configured}" ]]; then
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT="true"
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="backend-auto-fallback"
    printf '%s\n' "${configured}"
    return 0
  fi
  return 1
}

ftctl_vmware_mover_govc_url() {
  local endpoint="${1-}"
  if [[ "${endpoint}" != http://* && "${endpoint}" != https://* ]]; then
    endpoint="https://${endpoint}"
  fi
  endpoint="${endpoint%/}"
  [[ "${endpoint}" == */sdk ]] || endpoint="${endpoint}/sdk"
  printf '%s\n' "${endpoint}"
}

ftctl_vmware_mover_resolve_govc_bin() {
  local credentials_file="${1-}" libdir="${2-}" candidate version normalized
  candidate="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.govcBin // .credentials.source.govcPath' '')"
  [[ -n "${candidate}" && -x "${candidate}" ]] && {
    printf '%s\n' "${candidate}"
    return 0
  }
  [[ -n "${FTCTL_DR_VMWARE_GOVC_BIN:-}" && -x "${FTCTL_DR_VMWARE_GOVC_BIN}" ]] && {
    printf '%s\n' "${FTCTL_DR_VMWARE_GOVC_BIN}"
    return 0
  }
  if [[ -n "${libdir}" ]]; then
    candidate="$(cd "${libdir}/.." 2>/dev/null && pwd)/bin/govc"
    [[ -x "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  fi
  version="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.vddkVersion // .credentials.source.version' '')"
  if [[ -n "${version}" ]]; then
    normalized="${version//./}"
    [[ "${normalized}" == "8" ]] && normalized="80"
    candidate="/usr/share/ablestack/v2k/compat/vsphere${normalized}/bin/govc"
    [[ -x "${candidate}" ]] && {
      printf '%s\n' "${candidate}"
      return 0
    }
  fi
  command -v govc 2>/dev/null || true
}

ftctl_vmware_mover_cleanup_nbdkit() {
  local pid="${1-}" work_dir="${2-}"
  [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
  [[ -n "${pid}" ]] && wait "${pid}" 2>/dev/null || true
  [[ -n "${work_dir}" ]] && rm -rf "${work_dir}"
}

ftctl_vmware_mover_source_open_die() {
  local rc="${1-}" error_code="${2-}" message="${3-}" vm_ref="${4-}" snapshot_ref="${5-}" source_vmdk="${6-}"
  ftctl_vmware_mover_write_source_open_status false "${error_code}" "${message}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  ftctl_vmware_mover_die "${rc}" "${error_code}: ${message}"
}

ftctl_vmware_mover_classify_source_open_failure() {
  local label="${1-}" nbdkit_log="${2-}" qemu_log="${3-}" vm_ref="${4-}" snapshot_ref="${5-}" source_vmdk="${6-}" combined
  combined="$(cat "${nbdkit_log}" "${qemu_log}" 2>/dev/null || true)"
  if ftctl_vmware_mover_is_source_transport_failure "${combined}"; then
    ftctl_vmware_mover_source_open_die 98 "DR_SOURCE_SITE_UNAVAILABLE" "VMware source site is temporarily unreachable for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  fi
  if grep -qi 'DiskLib error 16392\|Failed to lock the file' <<< "${combined}"; then
    ftctl_vmware_mover_source_open_die 75 "DR_VMWARE_VDDK_SOURCE_LOCKED" "source VMDK is locked; create/use a run snapshot for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  fi
  if grep -qi 'access rights to this file\|Permission denied' <<< "${combined}"; then
    ftctl_vmware_mover_source_open_die 76 "DR_VMWARE_VDDK_OPEN_DENIED" "VDDK cannot open the requested VMDK path for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  fi
  if grep -qi 'VixDiskLib_ConnectEx' <<< "${combined}"; then
    ftctl_vmware_mover_source_open_die 73 "DR_VMWARE_VDDK_CONNECT_INVALID" "VDDK rejected source connection parameters for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  fi
  if grep -qi 'Requested export not available' <<< "${combined}"; then
    ftctl_vmware_mover_source_open_die 74 "DR_VMWARE_VDDK_EXPORT_UNAVAILABLE" "VDDK NBD export is unavailable for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
  fi
  ftctl_vmware_mover_source_open_die 72 "DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID" "qemu-img cannot open VDDK NBD source for ${label}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}"
}

ftctl_vmware_mover_disk_plan() {
  local vmware_map="${1-}" target_map="${2-}"
  python3 - "${vmware_map}" "${target_map}" <<'PY'
import json
import os
import sys

vmware_path, target_path = sys.argv[1:3]

def load(path):
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

def text(value):
    if value is None or isinstance(value, (dict, list)):
        return ""
    return str(value).strip()

def first(*values):
    for value in values:
        value = text(value)
        if value:
            return value
    return ""

def integer(value):
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0

def item_at(items, index):
    if isinstance(items, list) and index < len(items) and isinstance(items[index], dict):
        return items[index]
    return {}

vmware = load(vmware_path)
target = load(target_path)
source_disks = vmware.get("disks") if isinstance(vmware.get("disks"), list) else []
target_disks = target.get("disks") if isinstance(target.get("disks"), list) else []
if not source_disks:
    raise SystemExit("DR_VMWARE_SOURCE_DISK_MAP_EMPTY")
if len(source_disks) != len(target_disks):
    raise SystemExit("DR_FORWARD_TARGET_MAP_CARDINALITY_MISMATCH")
count = len(source_disks)
rows = []
for index in range(count):
    source = item_at(source_disks, index)
    dest = item_at(target_disks, index)
    source_disk_key = first(source.get("sourceDiskKey"), source.get("cbtDiskId"), source.get("device"), index)
    identity_parts = [
        source_disk_key,
        first(source.get("sourceVmdkPath"), source.get("sourceDiskRef"), source.get("sourcePath")),
        first(source.get("sizeBytes"), dest.get("sizeBytes")),
        first(dest.get("targetPath")),
    ]
    import hashlib
    identity_hash = "sha256:" + hashlib.sha256("|".join(identity_parts).encode("utf-8")).hexdigest()
    rows.append({
        "index": index,
        "label": first(source.get("device"), source.get("label"), dest.get("device"), dest.get("label"), f"disk{index}"),
        "sourceVmdk": first(source.get("sourceOpenVmdk"), source.get("sourceOpenVmdkPath"), source.get("sourceVmdkPath"), source.get("sourceDiskRef"), source.get("sourcePath")),
        "sourceVmRef": first(source.get("sourceVmRef"), vmware.get("sourceVmRef")),
        "sourceSnapshotRef": first(source.get("sourceSnapshotRef"), source.get("snapshotRef"), source.get("snapshot"), vmware.get("sourceSnapshotRef")),
        "sourceSnapshotName": first(source.get("sourceSnapshotName"), source.get("snapshotName"), vmware.get("sourceSnapshotName")),
        "sourceDiskKey": source_disk_key,
        "cbtDiskId": first(source.get("cbtDiskId"), source.get("sourceDiskKey"), source.get("device")),
        "previousChangeId": first(source.get("changeId"), source.get("cbtChangeId")),
        "baselineState": first(source.get("baselineState")),
        "baselineGeneration": integer(source.get("baselineGeneration")),
        "lastSyncSequence": integer(source.get("lastSyncSequence")),
        "diskIdentityHash": identity_hash,
        "virtualBytes": first(source.get("sizeBytes"), dest.get("sizeBytes")),
        "targetPath": first(dest.get("targetPath")),
        "targetName": first(dest.get("targetName")),
        "targetStoragePath": first(dest.get("targetStoragePath"), target.get("target", {}).get("storagePath") if isinstance(target.get("target"), dict) else ""),
        "targetStorageType": first(dest.get("targetStorageType"), target.get("target", {}).get("storagePoolType") if isinstance(target.get("target"), dict) else ""),
        "targetFormat": first(dest.get("targetFormat"), source.get("targetFormat"), "raw").lower(),
    })
print(json.dumps(rows, sort_keys=True, separators=(",", ":")))
PY
}

ftctl_vmware_mover_wait_for_socket() {
  local socket_path="${1-}" pid="${2-}" deadline="${3-}"
  local waited=0
  while [[ "${waited}" -lt "${deadline}" ]]; do
    [[ -S "${socket_path}" ]] && return 0
    if ! kill -0 "${pid}" 2>/dev/null; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

ftctl_vmware_mover_write_source_open_status() {
  local path="${FTCTL_DR_SOURCE_OPEN_STATUS_PATH:-}" ready="${1-}" error_code="${2-}" message="${3-}" vm_ref="${4-}" snapshot_ref="${5-}" source_vmdk="${6-}"
  local tls_verify="${FTCTL_DR_VMWARE_SOURCE_OPEN_TLS_VERIFY:-}" thumbprint_present="${FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT:-}" thumbprint_source="${FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE:-}"
  [[ -n "${path}" ]] || return 0
  mkdir -p "$(dirname "${path}")"
  python3 - "${path}" "${ready}" "${error_code}" "${message}" "${vm_ref}" "${snapshot_ref}" "${source_vmdk}" "${tls_verify}" "${thumbprint_present}" "${thumbprint_source}" <<'PY'
import json
import os
import sys

path, ready, error_code, message, vm_ref, snapshot_ref, source_vmdk, tls_verify, thumbprint_present, thumbprint_source = sys.argv[1:11]
data = {
    "checked": True,
    "ready": str(ready).lower() == "true",
    "error_code": error_code,
    "message": message,
    "vmRef": vm_ref,
    "snapshotRefPresent": bool(snapshot_ref),
    "sourceVmdkPathPresent": bool(source_vmdk),
}
if tls_verify:
    data["tlsVerify"] = str(tls_verify).lower() == "true"
if thumbprint_present:
    data["thumbprintPresent"] = str(thumbprint_present).lower() == "true"
if thumbprint_source:
    data["thumbprintSource"] = thumbprint_source
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, path)
PY
}

ftctl_vmware_mover_write_source_snapshot_status() {
  local path="${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH:-}" ready="${1-}" error_code="${2-}" message="${3-}" vm_ref="${4-}" snapshot_name="${5-}" snapshot_ref="${6-}" created="${7-}" cleanup_required="${8-}" resolve_method="${9-}" lifecycle_state="${10-}" last_snapshot_ref="${11-}" last_snapshot_name="${12-}"
  [[ -n "${last_snapshot_ref}" ]] || last_snapshot_ref="${snapshot_ref}"
  [[ -n "${last_snapshot_name}" ]] || last_snapshot_name="${snapshot_name}"
  [[ -n "${path}" ]] || return 0
  mkdir -p "$(dirname "${path}")"
  python3 - "${path}" "${ready}" "${error_code}" "${message}" "${vm_ref}" "${snapshot_name}" "${snapshot_ref}" "${created}" "${cleanup_required}" "${resolve_method}" "${lifecycle_state}" "${last_snapshot_ref}" "${last_snapshot_name}" <<'PY'
import json
import os
import sys
import time

path, ready, error_code, message, vm_ref, snapshot_name, snapshot_ref, created, cleanup_required, resolve_method, lifecycle_state, last_snapshot_ref, last_snapshot_name = sys.argv[1:14]
now_ms = int(time.time() * 1000)
previous = {}
try:
    with open(path, "r", encoding="utf-8") as fh:
        value = json.load(fh)
        if isinstance(value, dict):
            previous = value
except (OSError, ValueError):
    pass
if not lifecycle_state:
    lifecycle_state = "ACTIVE" if snapshot_ref else ("CLEANUP_FAILED" if str(cleanup_required).lower() == "true" else "CLEANED")
active = lifecycle_state in ("CREATING", "ACTIVE", "COMMITTED", "CLEANUP_PENDING", "CLEANUP_FAILED") and bool(snapshot_ref)
created_at_ms = previous.get("createdAtEpochMs")
if lifecycle_state in ("CREATING", "ACTIVE") and (not created_at_ms or previous.get("lastSnapshotRef") != last_snapshot_ref):
    created_at_ms = now_ms
if not last_snapshot_ref:
    last_snapshot_ref = str(previous.get("lastSnapshotRef") or "")
if not last_snapshot_name:
    last_snapshot_name = str(previous.get("lastSnapshotName") or "")
if not snapshot_name:
    snapshot_name = last_snapshot_name
data = {
    "checked": True,
    "ready": str(ready).lower() == "true",
    "created": str(created).lower() == "true",
    "cleanupRequired": str(cleanup_required).lower() == "true",
    "lifecycleState": lifecycle_state,
    "error_code": error_code,
    "message": message,
    "vmRef": vm_ref,
    "snapshotName": snapshot_name,
    "snapshotRefPresent": active,
    "snapshotRef": snapshot_ref if active else "",
    "activeSnapshotRefPresent": active,
    "activeSnapshotRef": snapshot_ref if active else "",
    "lastSnapshotRef": last_snapshot_ref,
    "lastSnapshotName": last_snapshot_name,
    "resolveMethod": resolve_method,
    "createdAtEpochMs": created_at_ms,
    "checkedAtEpochMs": now_ms,
    "cleanedAtEpochMs": now_ms if lifecycle_state == "CLEANED" else None,
    "cleanupErrorCode": error_code if lifecycle_state == "CLEANUP_FAILED" else "",
    "cleanupMessage": message if lifecycle_state == "CLEANUP_FAILED" else "",
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
os.replace(tmp, path)
PY
}

ftctl_vmware_mover_convert_disk() {
  local source_vmdk="${1-}" source_vm_ref="${2-}" source_snapshot_ref="${3-}" target_uri="${4-}" target_format="${5-}" label="${6-}"
  local endpoint="${7-}" username="${8-}" password_file="${9-}" tls_verify="${10-}" thumbprint="${11-}" libdir="${12-}"
  local progress_path="${13-}" disk_index="${14-0}" disk_count="${15-1}" disk_bytes="${16-0}" total_bytes="${17-0}" base_bytes="${18-0}" final_disk="${19-false}"
  local work_dir socket_path pid="" source_opts safe_label nbdkit_log qemu_info_log transports progress_helper

  [[ -n "${source_vmdk}" ]] || ftctl_vmware_mover_die 65 "source VMDK path is empty for ${label}"
  [[ -n "${target_uri}" ]] || ftctl_vmware_mover_die 65 "target disk path is empty for ${label}"
  [[ -n "${endpoint}" ]] || ftctl_vmware_mover_die 65 "vCenter endpoint is empty"
  [[ -n "${username}" ]] || ftctl_vmware_mover_die 65 "vCenter username is empty"
  [[ -s "${password_file}" ]] || ftctl_vmware_mover_die 65 "vCenter password file is empty"
  FTCTL_DR_VMWARE_SOURCE_OPEN_TLS_VERIFY="${tls_verify}"
  [[ -n "${source_vm_ref}" ]] || ftctl_vmware_mover_source_open_die 73 "DR_VMWARE_VDDK_CONNECT_INVALID" "source VM reference is empty for ${label}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"

  if [[ "${FTCTL_DR_VMWARE_MOVER_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN: %s snapshot=%s -> %s\n' "${source_vmdk}" "${source_snapshot_ref:-none}" "${target_uri}" >&2
    return 0
  fi

  endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
  work_dir="$(mktemp -d -t ftctl.vmware.mover.XXXXXX)"
  socket_path="${work_dir}/vddk.sock"
  safe_label="$(ftctl_vmware_mover_safe_label "${label}")"
  nbdkit_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/nbdkit-${safe_label}.log"
  qemu_info_log="${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/qemu-img-info-${safe_label}.log"
  transports="${FTCTL_DR_VMWARE_VDDK_TRANSPORTS:-nbd:nbdssl}"
  if [[ "${tls_verify}" != "true" ]]; then
    thumbprint="$(ftctl_vmware_mover_resolve_thumbprint "${endpoint}" "${tls_verify}" "${thumbprint}" || true)"
    if [[ "${FTCTL_DR_VMWARE_CONFIGURED_THUMBPRINT_SOURCE:-}" == "backend-auto" ]]; then
      FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="backend-auto-refreshed"
    fi
    if [[ -z "${thumbprint}" ]]; then
      ftctl_vmware_mover_source_open_die 77 "DR_VMWARE_VDDK_THUMBPRINT_UNRESOLVED" \
        "VDDK requires the vCenter thumbprint when TLS verification is disabled for ${label}" \
        "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
    fi
  else
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT="$([[ -n "${thumbprint}" ]] && printf 'true' || printf 'false')"
    FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE="tls-verify"
  fi
  # A snapshot leaf alone is not a complete guest disk (#1003).
  local nbdkit_args=(
    --exit-with-parent
    --foreground
    --unix "${socket_path}"
    -r
    vddk
    "server=${endpoint}"
    "user=${username}"
    "password=+${password_file}"
    "file=${source_vmdk}"
    "single-link=false"
  )
  [[ -n "${source_vm_ref}" ]] && nbdkit_args+=("vm=moref=${source_vm_ref}")
  [[ -n "${source_snapshot_ref}" ]] && nbdkit_args+=("snapshot=${source_snapshot_ref}")
  [[ -n "${transports}" ]] && nbdkit_args+=("transports=${transports}")
  [[ -n "${thumbprint}" && "${tls_verify}" != "true" ]] && nbdkit_args+=("thumbprint=${thumbprint}")
  [[ -n "${libdir}" && -d "${libdir}" ]] && nbdkit_args+=("libdir=${libdir}")

  nbdkit "${nbdkit_args[@]}" >"${nbdkit_log}" 2>&1 &
  pid=$!
  if ! ftctl_vmware_mover_wait_for_socket "${socket_path}" "${pid}" "${FTCTL_DR_VMWARE_NBDKIT_READY_TIMEOUT}"; then
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
  fi

  source_opts="$(ftctl_vmware_mover_source_image_opts "${socket_path}")"
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout "${FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT}" qemu-img info --force-share --image-opts "${source_opts}" >/dev/null 2>"${qemu_info_log}"; then
      ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
      ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
    fi
  elif ! qemu-img info --force-share --image-opts "${source_opts}" >/dev/null 2>"${qemu_info_log}"; then
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_classify_source_open_failure "${label}" "${nbdkit_log}" "${qemu_info_log}" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
  fi
  ftctl_vmware_mover_write_source_open_status true "" "VDDK source open preflight succeeded" "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"

  progress_helper="${FTCTL_DR_QEMU_IMG_PROGRESS_HELPER:-${FTCTL_DR_VMWARE_MOVER_LIB_DIR}/dr_qemu_img_progress.py}"
  local qemu_command=(qemu-img convert --force-share -p -n --image-opts -O "${target_format:-raw}" "${source_opts}" "${target_uri}")
  local progress_command=(python3 "${progress_helper}"
    --progress-json "${progress_path}"
    --plan-uuid "${FTCTL_DR_PLAN_UUID:-}"
    --run-uuid "${FTCTL_DR_RUN_UUID:-}"
    --cycle-sequence "${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}"
    --mode "${FTCTL_DR_CYCLE_EFFECTIVE_MODE:-FULL_SEED}"
    --disk-index "${disk_index:-0}"
    --disk-count "${disk_count:-1}"
    --disk-label "${label}"
    --disk-bytes "${disk_bytes:-0}"
    --base-bytes "${base_bytes:-0}"
    --total-bytes "${total_bytes:-0}")
  [[ "${final_disk}" == "true" ]] && progress_command+=(--final-disk)
  if [[ -n "${progress_path}" && -f "${progress_helper}" ]]; then
    progress_command+=(-- "${qemu_command[@]}")
    "${progress_command[@]}" || {
      ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
      ftctl_vmware_mover_die 68 "qemu-img conversion failed for ${label}"
    }
  elif ! "${qemu_command[@]}"; then
    ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
    ftctl_vmware_mover_die 68 "qemu-img conversion failed for ${label}"
  fi

  ftctl_vmware_mover_cleanup_nbdkit "${pid}" "${work_dir}"
}

ftctl_vmware_mover_snapshot_ref_from_tree() {
  local json_path="${1-}" snapshot_name="${2-}"
  [[ -s "${json_path}" && -n "${snapshot_name}" ]] || return 1
  python3 - "${json_path}" "${snapshot_name}" <<'PY'
import json
import sys

path, name = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, UnicodeError, json.JSONDecodeError):
    sys.exit(1)

def text(value):
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return ""
    return str(value)

def ref_value(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("Value", "value", "MoRef", "moRef", "moid", "id"):
            result = text(value.get(key))
            if result:
                return result
    return ""

def walk(value):
    if isinstance(value, dict):
        node_name = text(value.get("Name") or value.get("name"))
        if node_name == name:
            result = ref_value(value.get("Snapshot") or value.get("snapshot"))
            if result:
                return result
        for child in value.values():
            result = walk(child)
            if result:
                return result
    elif isinstance(value, list):
        for child in value:
            result = walk(child)
            if result:
                return result
    return ""

result = walk(data)
if result:
    print(result)
    sys.exit(0)
sys.exit(1)
PY
}

ftctl_vmware_mover_snapshot_ref_from_object_collect() {
  ftctl_vmware_mover_snapshot_ref_from_tree "$@"
}

ftctl_vmware_mover_snapshot_name_from_tree() {
  local json_path="${1-}" snapshot_ref="${2-}"
  [[ -s "${json_path}" && -n "${snapshot_ref}" ]] || return 1
  python3 - "${json_path}" "${snapshot_ref}" <<'PY'
import json
import sys

path, expected_ref = sys.argv[1:3]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, UnicodeError, json.JSONDecodeError):
    sys.exit(1)

def scalar(value):
    return "" if value is None or isinstance(value, (dict, list)) else str(value)

def ref_value(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("Value", "value", "MoRef", "moRef", "moid", "id"):
            result = scalar(value.get(key))
            if result:
                return result
    return ""

def walk(value):
    if isinstance(value, dict):
        node_ref = ref_value(value.get("Snapshot") or value.get("snapshot"))
        if node_ref == expected_ref:
            name = scalar(value.get("Name") or value.get("name"))
            if name:
                return name
        for child in value.values():
            result = walk(child)
            if result:
                return result
    elif isinstance(value, list):
        for child in value:
            result = walk(child)
            if result:
                return result
    return ""

result = walk(data)
if result:
    print(result)
    sys.exit(0)
sys.exit(1)
PY
}

ftctl_vmware_mover_snapshot_subtree_is_owned() {
  local json_path="${1-}" snapshot_ref="${2-}" snapshot_name="${3-}"
  [[ -s "${json_path}" && -n "${snapshot_ref}" && -n "${snapshot_name}" ]] || return 1
  python3 - "${json_path}" "${snapshot_ref}" "${snapshot_name}" <<'PY'
import json
import re
import sys

path, expected_ref, expected_name = sys.argv[1:4]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, UnicodeError, json.JSONDecodeError):
    sys.exit(1)

prefix = re.sub(r"-cycle-[0-9]+$", "-cycle-", expected_name)

def ref_value(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("Value", "value", "MoRef", "moRef", "moid", "id"):
            result = value.get(key)
            if result is not None and not isinstance(result, (dict, list)):
                return str(result)
    return ""

def find(value):
    if isinstance(value, dict):
        if ref_value(value.get("Snapshot") or value.get("snapshot")) == expected_ref:
            return value
        for child in value.values():
            result = find(child)
            if result is not None:
                return result
    elif isinstance(value, list):
        for child in value:
            result = find(child)
            if result is not None:
                return result
    return None

def owned(value):
    if isinstance(value, dict):
        if "Snapshot" in value or "snapshot" in value:
            name = str(value.get("Name") or value.get("name") or "")
            if not name or not (name == expected_name or name.startswith(prefix)):
                return False
        return all(owned(child) for child in value.values())
    if isinstance(value, list):
        return all(owned(child) for child in value)
    return True

node = find(data)
sys.exit(0 if node is not None and owned(node) else 1)
PY
}

ftctl_vmware_mover_resolve_run_snapshot_ref() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}" source_vm_ref="${6-}" snapshot_name="${7-}"
  local object_collect_json snapshot_tree snapshot_ref

  FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF=""
  FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD=""
  [[ -x "${govc_bin}" && -n "${source_vm_ref}" && -n "${snapshot_name}" && -s "${password_file}" ]] || return 1

  object_collect_json="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-snapshot-object-collect.XXXXXX.json)"
  if GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" \
    GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
      "${govc_bin}" object.collect -json "${source_vm_ref}" snapshot.rootSnapshotList > "${object_collect_json}" 2>/dev/null; then
    snapshot_ref="$(ftctl_vmware_mover_snapshot_ref_from_object_collect "${object_collect_json}" "${snapshot_name}" || true)"
    if [[ -n "${snapshot_ref}" ]]; then
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF="${snapshot_ref}"
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD="object.collect:snapshot.rootSnapshotList"
      rm -f "${object_collect_json}"
      return 0
    fi
  fi
  rm -f "${object_collect_json}"

  snapshot_tree="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-snapshot-tree.XXXXXX.json)"
  if GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" \
    GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
      "${govc_bin}" snapshot.tree -vm "${source_vm_ref}" -json > "${snapshot_tree}" 2>/dev/null; then
    snapshot_ref="$(ftctl_vmware_mover_snapshot_ref_from_tree "${snapshot_tree}" "${snapshot_name}" || true)"
    if [[ -n "${snapshot_ref}" ]]; then
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF="${snapshot_ref}"
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD="snapshot.tree"
      rm -f "${snapshot_tree}"
      return 0
    fi
  fi
  rm -f "${snapshot_tree}"
  return 1
}

ftctl_vmware_mover_resolve_snapshot_name_by_ref() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}" source_vm_ref="${6-}" snapshot_ref="${7-}"
  local object_collect_json snapshot_tree snapshot_name

  FTCTL_DR_VMWARE_LAST_SNAPSHOT_NAME=""
  [[ -x "${govc_bin}" && -n "${source_vm_ref}" && -n "${snapshot_ref}" && -s "${password_file}" ]] || return 1

  object_collect_json="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-snapshot-object-collect.XXXXXX.json)"
  if GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" \
    GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
      "${govc_bin}" object.collect -json "${source_vm_ref}" snapshot.rootSnapshotList > "${object_collect_json}" 2>/dev/null; then
    snapshot_name="$(ftctl_vmware_mover_snapshot_name_from_tree "${object_collect_json}" "${snapshot_ref}" || true)"
    if [[ -n "${snapshot_name}" ]]; then
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_NAME="${snapshot_name}"
      rm -f "${object_collect_json}"
      return 0
    fi
  fi
  rm -f "${object_collect_json}"

  snapshot_tree="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-snapshot-tree.XXXXXX.json)"
  if GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" \
    GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
      "${govc_bin}" snapshot.tree -vm "${source_vm_ref}" -json > "${snapshot_tree}" 2>/dev/null; then
    snapshot_name="$(ftctl_vmware_mover_snapshot_name_from_tree "${snapshot_tree}" "${snapshot_ref}" || true)"
    if [[ -n "${snapshot_name}" ]]; then
      FTCTL_DR_VMWARE_LAST_SNAPSHOT_NAME="${snapshot_name}"
      rm -f "${snapshot_tree}"
      return 0
    fi
  fi
  rm -f "${snapshot_tree}"
  return 1
}

ftctl_vmware_mover_create_run_snapshot() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}" source_vm_ref="${6-}" snapshot_name="${7-}"
  local snapshot_error pending_cleanup_rc=0
  [[ -x "${govc_bin}" ]] || return 73
  [[ -n "${source_vm_ref}" && -n "${snapshot_name}" ]] || return 73
  mkdir -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}"
  if [[ -n "${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH:-}" && -f "${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH}" ]] \
    && jq -e '.cleanupRequired == true and (.lifecycleState == "CLEANUP_FAILED" or .lifecycleState == "CLEANUP_PENDING")' \
      "${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH}" >/dev/null 2>&1; then
    ftctl_vmware_mover_cleanup_pending_snapshot "${govc_bin}" "${endpoint}" "${username}" \
      "${password_file}" "${tls_verify}" || pending_cleanup_rc=$?
    [[ "${pending_cleanup_rc}" == "0" ]] || return "${pending_cleanup_rc}"
  fi
  snapshot_error="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-snapshot-create.XXXXXX.log)"
  if ! GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" \
    GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
      "${govc_bin}" snapshot.create -vm "${source_vm_ref}" -m=false -q=false "${snapshot_name}" >/dev/null 2>"${snapshot_error}"; then
    if ftctl_vmware_mover_is_source_transport_failure "$(cat "${snapshot_error}" 2>/dev/null || true)"; then
      ftctl_vmware_mover_write_source_snapshot_status false "DR_SOURCE_SITE_UNAVAILABLE" \
        "VMware source site is temporarily unreachable" "${source_vm_ref}" "${snapshot_name}" "" false false ""
      rm -f "${snapshot_error}"
      return 98
    fi
    ftctl_vmware_mover_write_source_snapshot_status false "DR_VMWARE_VDDK_CONNECT_INVALID" \
      "Failed to create VMware source snapshot" "${source_vm_ref}" "${snapshot_name}" "" false false ""
    rm -f "${snapshot_error}"
    return 73
  fi
  rm -f "${snapshot_error}"

  FTCTL_DR_VMWARE_GOVC_BIN_EFFECTIVE="${govc_bin}"
  FTCTL_DR_VMWARE_SOURCE_VM_REF_EFFECTIVE="${source_vm_ref}"
  FTCTL_DR_VMWARE_RUN_SNAPSHOT_NAME="${snapshot_name}"
  FTCTL_DR_VMWARE_RUN_SNAPSHOT_CREATED="true"

  if ! ftctl_vmware_mover_resolve_run_snapshot_ref "${govc_bin}" "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${source_vm_ref}" "${snapshot_name}"; then
    ftctl_vmware_mover_write_source_snapshot_status false "DR_VMWARE_SNAPSHOT_REF_UNRESOLVED" \
      "VMware source snapshot was created, but its MoRef could not be resolved" \
      "${source_vm_ref}" "${snapshot_name}" "" true true "" "CLEANUP_FAILED" ""
    return 81
  fi

  FTCTL_DR_VMWARE_RUN_SNAPSHOT_REF="${FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF}"
  ftctl_vmware_mover_write_source_snapshot_status true "" \
    "VMware source snapshot was created and resolved" \
    "${source_vm_ref}" "${snapshot_name}" "${FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF}" true false \
    "${FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD}" "ACTIVE" "${FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF}"
}

ftctl_vmware_mover_remove_run_snapshot() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}" source_vm_ref="${6-}" snapshot_name="${7-}" snapshot_ref="${8-}"
  local verified_name="${snapshot_name}" remove_selector="${snapshot_name}" remove_children="false" object_collect_json
  [[ -x "${govc_bin}" && -n "${source_vm_ref}" ]] || return 0
  [[ -s "${password_file}" ]] || return 0
  FTCTL_DR_VMWARE_REMOVED_SNAPSHOT_NAME=""
  if [[ -n "${snapshot_ref}" ]]; then
    if ! ftctl_vmware_mover_resolve_snapshot_name_by_ref "${govc_bin}" "${endpoint}" "${username}" \
        "${password_file}" "${tls_verify}" "${source_vm_ref}" "${snapshot_ref}"; then
      return 0
    fi
    verified_name="${FTCTL_DR_VMWARE_LAST_SNAPSHOT_NAME}"
    object_collect_json="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-snapshot-owned.XXXXXX.json)"
    if ! GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
      GOVC_USERNAME="${username}" \
      GOVC_PASSWORD="$(cat "${password_file}")" \
      GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
        "${govc_bin}" object.collect -json "${source_vm_ref}" snapshot.rootSnapshotList > "${object_collect_json}" 2>/dev/null \
        || ! ftctl_vmware_mover_snapshot_subtree_is_owned "${object_collect_json}" "${snapshot_ref}" "${verified_name}"; then
      rm -f "${object_collect_json}"
      return 1
    fi
    rm -f "${object_collect_json}"
    remove_selector="${snapshot_ref}"
    remove_children="true"
  fi
  [[ -n "${verified_name}" ]] || return 0
  FTCTL_DR_VMWARE_REMOVED_SNAPSHOT_NAME="${verified_name}"
  if ! GOVC_URL="$(ftctl_vmware_mover_govc_url "${endpoint}")" \
    GOVC_USERNAME="${username}" \
    GOVC_PASSWORD="$(cat "${password_file}")" \
    GOVC_INSECURE="$([[ "${tls_verify}" == "true" ]] && printf 'false' || printf 'true')" \
      timeout "${FTCTL_DR_VMWARE_SNAPSHOT_CLEANUP_TIMEOUT:-60}" "${govc_bin}" snapshot.remove \
        -vm "${source_vm_ref}" "-r=${remove_children}" "${remove_selector}" >/dev/null 2>&1; then
    return 1
  fi
  if [[ -n "${snapshot_ref}" ]] && ftctl_vmware_mover_resolve_snapshot_name_by_ref \
      "${govc_bin}" "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${source_vm_ref}" "${snapshot_ref}"; then
    return 1
  fi
  if [[ -z "${snapshot_ref}" ]] && ftctl_vmware_mover_resolve_run_snapshot_ref \
      "${govc_bin}" "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${source_vm_ref}" "${verified_name}"; then
    return 1
  fi
  return 0
}

ftctl_vmware_mover_cleanup_pending_snapshot() {
  local govc_bin="${1-}" endpoint="${2-}" username="${3-}" password_file="${4-}" tls_verify="${5-}"
  local status_path="${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH:-}" source_vm_ref snapshot_name snapshot_ref
  [[ -s "${status_path}" ]] || return 0
  jq -e '.cleanupRequired == true' "${status_path}" >/dev/null 2>&1 || return 0
  source_vm_ref="$(jq -r '.vmRef // ""' "${status_path}" 2>/dev/null || true)"
  snapshot_name="$(jq -r '.lastSnapshotName // .snapshotName // ""' "${status_path}" 2>/dev/null || true)"
  snapshot_ref="$(jq -r '.lastSnapshotRef // .snapshotRef // ""' "${status_path}" 2>/dev/null || true)"
  if ftctl_vmware_mover_remove_run_snapshot "${govc_bin}" "${endpoint}" "${username}" "${password_file}" \
      "${tls_verify}" "${source_vm_ref}" "${snapshot_name}" "${snapshot_ref}"; then
    [[ -n "${FTCTL_DR_VMWARE_REMOVED_SNAPSHOT_NAME:-}" ]] \
      && snapshot_name="${FTCTL_DR_VMWARE_REMOVED_SNAPSHOT_NAME}"
    ftctl_vmware_mover_write_source_snapshot_status true "" \
      "Previous VMware source snapshot cleanup completed" "${source_vm_ref}" "" "" true false \
      "snapshot-ref" "CLEANED" "${snapshot_ref}" "${snapshot_name}"
    return 0
  fi
  ftctl_vmware_mover_write_source_snapshot_status false "DR_VMWARE_SNAPSHOT_CLEANUP_PENDING" \
    "Previous VMware source snapshot cleanup is not complete" "${source_vm_ref}" "" "${snapshot_ref}" true true \
    "snapshot-ref" "CLEANUP_FAILED" "${snapshot_ref}" "${snapshot_name}"
  return 99
}

ftctl_vmware_mover_cleanup() {
  local last_ref="${FTCTL_DR_VMWARE_RUN_SNAPSHOT_REF:-}" cleanup_rc=0
  if [[ "${FTCTL_DR_VMWARE_RUN_SNAPSHOT_CREATED:-false}" == "true" ]]; then
    ftctl_vmware_mover_write_source_snapshot_status true "" \
      "VMware source snapshot cleanup is pending" \
      "${FTCTL_DR_VMWARE_SOURCE_VM_REF_EFFECTIVE:-}" "${FTCTL_DR_VMWARE_RUN_SNAPSHOT_NAME:-}" "${last_ref}" true true \
      "${FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD:-}" "CLEANUP_PENDING" "${last_ref}"
    if ftctl_vmware_mover_remove_run_snapshot \
      "${FTCTL_DR_VMWARE_GOVC_BIN_EFFECTIVE:-}" \
      "${FTCTL_DR_VMWARE_ENDPOINT_EFFECTIVE:-}" \
      "${FTCTL_DR_VMWARE_USERNAME_EFFECTIVE:-}" \
      "${FTCTL_DR_VMWARE_PASSWORD_FILE:-}" \
      "${FTCTL_DR_VMWARE_TLS_VERIFY_EFFECTIVE:-false}" \
      "${FTCTL_DR_VMWARE_SOURCE_VM_REF_EFFECTIVE:-}" \
      "${FTCTL_DR_VMWARE_RUN_SNAPSHOT_NAME:-}" "${last_ref}"; then
      ftctl_vmware_mover_write_source_snapshot_status true "" \
        "VMware source snapshot cleanup completed" \
        "${FTCTL_DR_VMWARE_SOURCE_VM_REF_EFFECTIVE:-}" "${FTCTL_DR_VMWARE_RUN_SNAPSHOT_NAME:-}" "" true false \
        "${FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD:-}" "CLEANED" "${last_ref}"
    else
      cleanup_rc=1
      ftctl_vmware_mover_write_source_snapshot_status false "DR_VMWARE_SNAPSHOT_CLEANUP_FAILED" \
        "VMware source snapshot cleanup failed" \
        "${FTCTL_DR_VMWARE_SOURCE_VM_REF_EFFECTIVE:-}" "${FTCTL_DR_VMWARE_RUN_SNAPSHOT_NAME:-}" "${last_ref}" true true \
        "${FTCTL_DR_VMWARE_LAST_SNAPSHOT_RESOLVE_METHOD:-}" "CLEANUP_FAILED" "${last_ref}"
    fi
  fi
  rm -f "${FTCTL_DR_VMWARE_PASSWORD_FILE:-}"
  return "${cleanup_rc}"
}

ftctl_vmware_mover_on_exit() {
  local original_rc=$?
  trap - EXIT
  ftctl_vmware_mover_cleanup || true
  exit "${original_rc}"
}

ftctl_vmware_mover_commit_cycle_metrics() {
  local disk_map="${1-}" results_path="${2-}" metrics_path="${3-}" plan="${4-}" run="${5-}" sequence="${6-}" requested_mode="${7-}" mode_decision="${8-}"
  python3 - "${disk_map}" "${results_path}" "${metrics_path}" "${plan}" "${run}" "${sequence}" "${requested_mode}" "${mode_decision}" <<'PY'
import json
import os
import sys
import time
import uuid

disk_map_path, results_path, metrics_path, plan, run, sequence, requested_mode, raw_decision = sys.argv[1:9]
decision = json.loads(raw_decision) if raw_decision else {}
with open(disk_map_path, "r", encoding="utf-8") as handle:
    original_disk_map = json.load(handle)
with open(results_path, "r", encoding="utf-8") as handle:
    disks = json.load(handle)

if not isinstance(disks, list) or not disks:
    raise SystemExit("cycle result list is empty")
required_result_fields = (
    "diskIndex", "newChangeId", "virtualBytes", "changedBytes", "sourceReadBytes",
    "targetWrittenBytes", "transferPayloadBytes", "changedExtentCount", "durationMs",
)
for result in disks:
    if not isinstance(result, dict):
        raise SystemExit("cycle result must be a JSON object")
    missing = [key for key in required_result_fields if key not in result]
    if missing:
        raise SystemExit("cycle result is missing fields: " + ",".join(missing))
    for key in required_result_fields[2:]:
        value = result.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise SystemExit(f"invalid cycle result {key}: {value!r}")

disk_map = json.loads(json.dumps(original_disk_map))

generation = int(sequence or 0)
for result in disks:
    index = int(result["diskIndex"])
    if index >= len(disk_map.get("disks") or []):
        raise SystemExit(f"disk result index is out of range: {index}")
    disk = disk_map["disks"][index]
    disk["changeId"] = result["newChangeId"]
    disk["cbtChangeId"] = result["newChangeId"]
    disk["baselineGeneration"] = generation
    disk["lastSyncSequence"] = generation
    disk["baselineState"] = "LOCAL_DURABLE"

effective_modes = {str(item.get("effectiveMode") or "") for item in disks}
if effective_modes == {"NO_CHANGE"}:
    effective_mode = "NO_CHANGE"
elif effective_modes and effective_modes <= {"NO_CHANGE", "CBT_INCREMENTAL"}:
    effective_mode = "CBT_INCREMENTAL"
elif effective_modes == {"FULL_SEED"}:
    effective_mode = "FULL_SEED"
elif effective_modes == {"FULL_RESEED"}:
    effective_mode = "FULL_RESEED"
else:
    raise SystemExit("cycle disks have inconsistent effective modes: " + ",".join(sorted(effective_modes)))
incremental_verified = bool(disks) and all(bool(item.get("incrementalVerified")) for item in disks)
if effective_mode in ("FULL_SEED", "FULL_RESEED"):
    incremental_verified = False
for item in disks:
    if item.get("effectiveMode") == "CBT_INCREMENTAL" and item.get("nbdTeardownState") != "DRAINED":
        raise SystemExit("incremental cycle cannot commit before NBD teardown is DRAINED")

nbd_states = {str(item.get("nbdTeardownState") or "NOT_APPLICABLE") for item in disks}
if "QUARANTINED" in nbd_states or "DRAINING" in nbd_states:
    raise SystemExit("cycle contains an incomplete NBD teardown")
nbd_teardown_state = "DRAINED" if "DRAINED" in nbd_states else "NOT_APPLICABLE"
nbd_started_values = [int(item.get("nbdTeardownStartedAtEpochMs") or 0) for item in disks]
nbd_completed_values = [int(item.get("nbdTeardownCompletedAtEpochMs") or 0) for item in disks]
nbd_started_values = [value for value in nbd_started_values if value > 0]
nbd_completed_values = [value for value in nbd_completed_values if value > 0]

sum_fields = (
    "virtualBytes", "changedBytes", "sourceReadBytes", "targetWrittenBytes",
    "transferPayloadBytes", "changedExtentCount", "durationMs"
)
metrics = {field: sum(int(item.get(field) or 0) for item in disks) for field in sum_fields}
duration_ms = max((int(item.get("durationMs") or 0) for item in disks), default=0)
metrics["durationMs"] = duration_ms
metrics["throughputBps"] = (metrics["sourceReadBytes"] * 1000 // duration_ms) if duration_ms else 0
metrics.update({
    "schemaVersion": 1,
    "cycleUuid": str(uuid.uuid5(uuid.NAMESPACE_URL, f"ablestack-dr:{plan}:{sequence}")),
    "cycleToken": f"{plan}:{sequence}",
    "planUuid": plan,
    "runUuid": run,
    "sequence": generation,
    "requestedMode": requested_mode,
    "effectiveMode": effective_mode,
    "automaticReseed": bool(decision.get("automaticReseed")),
    "modeDecisionCode": str(decision.get("decisionCode") or ""),
    "reseedReason": str(decision.get("reseedReason") or ""),
    "invalidBaselineDiskCount": int(decision.get("invalidBaselineDiskCount") or 0),
    "incrementalVerified": incremental_verified,
    "metricsEstimated": any(bool(item.get("metricsEstimated")) for item in disks),
    "baselineGeneration": generation,
    "cycleCommitState": "LOCAL_DURABLE",
    "targetDurableAtEpochMs": int(time.time() * 1000),
    "nbdTeardownState": nbd_teardown_state,
    "nbdTeardownStartedAtEpochMs": min(nbd_started_values) if nbd_started_values else 0,
    "nbdTeardownCompletedAtEpochMs": max(nbd_completed_values) if nbd_completed_values else 0,
    "nbdTeardownDurationMs": sum(int(item.get("nbdTeardownDurationMs") or 0) for item in disks),
    "nbdSourceDeviceCount": sum(int(item.get("nbdSourceDeviceCount") or 0) for item in disks),
    "nbdTargetDeviceCount": sum(int(item.get("nbdTargetDeviceCount") or 0) for item in disks),
    "nbdQuarantinedDeviceCount": sum(int(item.get("nbdQuarantinedDeviceCount") or 0) for item in disks),
    "nbdTeardownErrorCode": "",
    "nbdTeardownErrorMessage": "",
    "disks": disks,
})
os.makedirs(os.path.dirname(metrics_path) or ".", exist_ok=True)
metrics_tmp = metrics_path + ".tmp"
with open(metrics_tmp, "w", encoding="utf-8") as handle:
    json.dump(metrics, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
disk_tmp = disk_map_path + ".tmp"
with open(disk_tmp, "w", encoding="utf-8") as handle:
    json.dump(disk_map, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(metrics_tmp, metrics_path)
os.replace(disk_tmp, disk_map_path)
PY
}

main() {
  local disk_map="${FTCTL_DR_DISK_MAP:-}" target_disk_map="${FTCTL_DR_TARGET_DISK_MAP:-}" credentials_file="${FTCTL_DR_CREDENTIALS_FILE:-}"
  local endpoint username password tls_verify thumbprint thumbprint_source libdir password_file rows row count i
  local govc_bin source_vm_ref_for_snapshot snapshot_name snapshot_ref snapshot_created="false" mover_rc=0
  local cycle_type requested_mode effective_mode_request mode_decision reseed_reason
  local metrics_path results_path result_tmp query_path patch_metrics_path journal_path commit_rc mode_state_path guard_rc cbt_evidence_path
  local transfer_progress_path transfer_total_bytes transfer_completed_bytes=0 is_final_disk

  [[ -n "${disk_map}" && -f "${disk_map}" ]] || ftctl_vmware_mover_die 65 "FTCTL_DR_DISK_MAP is required"
  [[ -n "${target_disk_map}" && -f "${target_disk_map}" ]] ||
    ftctl_vmware_mover_die 65 "DR_FORWARD_TARGET_MAP_MISSING: FTCTL_DR_TARGET_DISK_MAP is required"
  [[ -n "${credentials_file}" && -f "${credentials_file}" ]] || ftctl_vmware_mover_die 65 "FTCTL_DR_CREDENTIALS_FILE is required"
  if [[ -n "${FTCTL_DR_PLAN_UUID:-}" && -d "${FTCTL_DR_NBD_QUARANTINE_ROOT}/${FTCTL_DR_PLAN_UUID}" ]] &&
      find "${FTCTL_DR_NBD_QUARANTINE_ROOT}/${FTCTL_DR_PLAN_UUID}" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null | grep -q .; then
    ftctl_vmware_mover_die 95 "DR_NBD_DEVICE_QUARANTINED: cleanup-only recovery is required before the next cycle"
  fi
  ftctl_vmware_mover_require jq 65
  ftctl_vmware_mover_require python3 65
  ftctl_vmware_mover_require nbdkit 65
  ftctl_vmware_mover_require qemu-img 65

  endpoint="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.endpoint' '')"
  endpoint="$(ftctl_vmware_mover_normalize_vcenter_server "${endpoint}")"
  username="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.principal // .credentials.source.username' '')"
  password="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.auth.password // .credentials.source.password' '')"
  tls_verify="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.tlsVerify' 'false')"
  thumbprint="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.thumbprint // .credentials.source.tlsThumbprint' '')"
  thumbprint_source="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.thumbprintSource' '')"
  FTCTL_DR_VMWARE_CONFIGURED_THUMBPRINT_SOURCE="${thumbprint_source}"
  if command -v ftctl_dr_vddk_resolve_libdir >/dev/null 2>&1; then
    libdir="$(ftctl_dr_vddk_resolve_libdir "${credentials_file}" 2>/dev/null || true)"
  else
    libdir="$(ftctl_vmware_mover_json_value "${credentials_file}" '.credentials.source.vddkLibdir // .credentials.source.libdir' '')"
  fi

  [[ -n "${password}" ]] || ftctl_vmware_mover_die 65 "source credential password is empty"
  [[ -n "${libdir}" ]] || ftctl_vmware_mover_die 70 "DR_VDDK_LIBDIR_UNRESOLVED: usable VDDK library directory was not found"
  if command -v ftctl_dr_vddk_nbdkit_loads >/dev/null 2>&1 && ! ftctl_dr_vddk_nbdkit_loads "${libdir}"; then
    ftctl_vmware_mover_die 71 "DR_VDDK_LIBRARY_LOAD_FAILED: nbdkit cannot load VDDK library directory ${libdir}"
  fi
  mkdir -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}"
  password_file="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-password.XXXXXX)"
  chmod 0600 "${password_file}"
  printf '%s' "${password}" > "${password_file}"
  FTCTL_DR_VMWARE_PASSWORD_FILE="${password_file}"
  FTCTL_DR_VMWARE_ENDPOINT_EFFECTIVE="${endpoint}"
  FTCTL_DR_VMWARE_USERNAME_EFFECTIVE="${username}"
  FTCTL_DR_VMWARE_TLS_VERIFY_EFFECTIVE="${tls_verify}"
  FTCTL_DR_VMWARE_RUN_SNAPSHOT_CREATED="false"
  trap 'ftctl_vmware_mover_on_exit' EXIT

  rows="$(ftctl_vmware_mover_disk_plan "${disk_map}" "${target_disk_map}")"
  count="$(jq 'length' <<< "${rows}")"
  [[ "${count}" =~ ^[1-9][0-9]*$ ]] || ftctl_vmware_mover_die 65 "no VMware disk rows to move"
  transfer_progress_path="${FTCTL_DR_TRANSFER_PROGRESS_PATH:-}"
  transfer_total_bytes="$(jq -r '[.[] | (.virtualBytes | tonumber? // 0)] | add // 0' <<< "${rows}")"
  [[ "${transfer_total_bytes}" =~ ^[0-9]+$ ]] || transfer_total_bytes=0
  cycle_type="${FTCTL_DR_CYCLE_TYPE:-full-seed}"
  case "${cycle_type}" in
    full-seed) requested_mode="FULL_SEED" ;;
    full-reseed) requested_mode="FULL_RESEED" ;;
    *) requested_mode="CBT_INCREMENTAL" ;;
  esac
  mode_decision="$(ftctl_vmware_mover_resolve_cycle_mode "${rows}" "${requested_mode}")" ||
    ftctl_vmware_mover_die 83 "DR_CBT_BASELINE_INVALID: cycle mode decision failed"
  effective_mode_request="$(jq -er '.effectiveMode' <<< "${mode_decision}")" ||
    ftctl_vmware_mover_die 83 "DR_CBT_BASELINE_INVALID: effective mode is unavailable"
  reseed_reason="$(jq -r '.reseedReason // ""' <<< "${mode_decision}")"
  if [[ "${requested_mode}" == "FULL_RESEED" && -n "${FTCTL_DR_AUTOMATIC_RESEED_REASON:-}" ]]; then
    mode_decision="$(jq -c --arg reason "${FTCTL_DR_AUTOMATIC_RESEED_REASON}" \
      '.automaticReseed=true | .decisionCode=$reason | .reseedReason=$reason' <<< "${mode_decision}")"
    reseed_reason="${FTCTL_DR_AUTOMATIC_RESEED_REASON}"
  fi
  [[ "${effective_mode_request}" != "BLOCKED" ]] ||
    ftctl_vmware_mover_die 91 "DR_CBT_BASELINE_NOT_DURABLE: ${reseed_reason:-baseline is not locally durable}"
  mode_state_path="${FTCTL_DR_MODE_DECISION_STATE_PATH:-$(dirname "${disk_map}")/mode-decision.json}"
  guard_rc=0
  ftctl_vmware_mover_reseed_guard "${mode_state_path}" "${mode_decision}" || guard_rc=$?
  [[ "${guard_rc}" != "90" ]] ||
    ftctl_vmware_mover_die 90 "DR_CBT_RESEED_LOOP_DETECTED: ${reseed_reason:-automatic reseed repeated}"
  [[ "${guard_rc}" == "0" ]] ||
    ftctl_vmware_mover_die 83 "DR_CBT_BASELINE_INVALID: reseed guard failed"
  metrics_path="${FTCTL_DR_CYCLE_METRICS_PATH:-${FTCTL_DR_VMWARE_MOVER_LOG_DIR}/cycle-${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}.json}"
  journal_path="${FTCTL_DR_CYCLE_JOURNAL_PATH:-${metrics_path}.journal.json}"
  results_path="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-cycle-results.XXXXXX.json)"
  printf '[]\n' > "${results_path}"
  cbt_evidence_path="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-cbt-evidence.XXXXXX.json)"
  printf '[]\n' > "${cbt_evidence_path}"
  ftctl_vmware_mover_write_cycle_journal "${journal_path}" "PREPARING" "FULL_RETRY" "" "" "${results_path}" "${mode_decision}"
  snapshot_ref="$(jq -r '[.[].sourceSnapshotRef // ""] | map(select(. != "")) | .[0] // ""' <<< "${rows}")"
  snapshot_name="$(jq -r '[.[].sourceSnapshotName // ""] | map(select(. != "")) | .[0] // ""' <<< "${rows}")"
  source_vm_ref_for_snapshot="$(jq -r '[.[].sourceVmRef // ""] | map(select(. != "")) | .[0] // ""' <<< "${rows}")"
  if [[ -z "${snapshot_ref}" && -n "${source_vm_ref_for_snapshot}" && "${FTCTL_DR_VMWARE_CREATE_RUN_SNAPSHOT:-1}" == "1" ]]; then
    govc_bin="$(ftctl_vmware_mover_resolve_govc_bin "${credentials_file}" "${libdir}")"
    [[ -n "${govc_bin}" ]] || ftctl_vmware_mover_die 73 "DR_VMWARE_VDDK_CONNECT_INVALID: govc binary is required to create VMware source snapshot"
    snapshot_name="ftctl-dr-${FTCTL_DR_RUN_UUID:-$(date +%s)}-cycle-${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}"
    mover_rc=0
    ftctl_vmware_mover_create_run_snapshot "${govc_bin}" "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${source_vm_ref_for_snapshot}" "${snapshot_name}" || mover_rc=$?
    if [[ "${mover_rc}" != "0" ]]; then
      if [[ "${mover_rc}" == "81" ]]; then
        ftctl_vmware_mover_die 81 "DR_VMWARE_SNAPSHOT_REF_UNRESOLVED: VMware source snapshot was created but its MoRef could not be resolved"
      fi
      if [[ "${mover_rc}" == "98" ]]; then
        ftctl_vmware_mover_die 98 "DR_SOURCE_SITE_UNAVAILABLE: VMware source site is temporarily unreachable"
      fi
      ftctl_vmware_mover_die "${mover_rc:-73}" "DR_VMWARE_VDDK_CONNECT_INVALID: failed to create VMware source snapshot"
    fi
    snapshot_ref="${FTCTL_DR_VMWARE_LAST_SNAPSHOT_REF}"
    snapshot_created="true"
  fi

  i=0
  while [[ "${i}" -lt "${count}" ]]; do
    row="$(jq -c ".[$i]" <<< "${rows}")"
    local label source_vmdk source_vm_ref source_snapshot_ref target_path target_name target_storage_path target_storage_type target_uri target_format
    local cbt_disk_id source_disk_key previous_change_id new_change_id virtual_bytes areas_count changed_bytes effective_mode incremental_verified
    label="$(jq -r '.label // ""' <<< "${row}")"
    source_vmdk="$(jq -r '.sourceVmdk // ""' <<< "${row}")"
    source_vm_ref="$(jq -r '.sourceVmRef // ""' <<< "${row}")"
    source_snapshot_ref="$(jq -r '.sourceSnapshotRef // ""' <<< "${row}")"
    [[ -n "${source_snapshot_ref}" ]] || source_snapshot_ref="${snapshot_ref}"
    cbt_disk_id="$(jq -r '.cbtDiskId // ""' <<< "${row}")"
    source_disk_key="$(jq -r '.sourceDiskKey // ""' <<< "${row}")"
    previous_change_id="$(jq -r '.previousChangeId // ""' <<< "${row}")"
    virtual_bytes="$(jq -r '.virtualBytes // 0' <<< "${row}")"
    target_path="$(jq -r '.targetPath // ""' <<< "${row}")"
    target_name="$(jq -r '.targetName // ""' <<< "${row}")"
    target_storage_path="$(jq -r '.targetStoragePath // ""' <<< "${row}")"
    target_storage_type="$(jq -r '.targetStorageType // ""' <<< "${row}")"
    target_uri="$(ftctl_vmware_mover_target_uri "${target_path}" "${target_storage_path}" "${target_name}" "${target_storage_type}")" ||
      ftctl_vmware_mover_die 65 "DR_FORWARD_TARGET_LOCATOR_INVALID: ${label:-disk${i}} target locator cannot be canonicalized"
    case "${target_uri}" in
      rbd:*/*|/*) ;;
      *) ftctl_vmware_mover_die 65 "DR_FORWARD_TARGET_LOCATOR_INVALID: ${label:-disk${i}} resolved to ${target_uri:-empty}" ;;
    esac
    target_format="$(jq -r '.targetFormat // "raw"' <<< "${row}")"
    [[ -n "${snapshot_name}" ]] || ftctl_vmware_mover_die 82 "DR_CBT_QUERY_FAILED: VMware snapshot name is unavailable"
    query_path="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-cbt-query-${i}.XXXXXX.json)"
    ftctl_vmware_mover_query_cbt "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${libdir}" \
      "${source_vm_ref}" "${snapshot_name}" "${cbt_disk_id}" \
      "$([[ "${effective_mode_request}" == "CBT_INCREMENTAL" ]] && printf '%s' "${previous_change_id}")" "${query_path}" \
      "$([[ "${effective_mode_request}" == "FULL_SEED" || "${effective_mode_request}" == "FULL_RESEED" ]] && printf true || printf false)" \
      "${source_disk_key}"
    new_change_id="$(jq -r '.new_change_id // ""' "${query_path}")"
    jq --arg diskId "${cbt_disk_id}" --arg changeId "${new_change_id}" \
      '. + [{diskId:$diskId,changeId:$changeId,querySucceeded:true}]' "${cbt_evidence_path}" > "${cbt_evidence_path}.tmp"
    mv -f "${cbt_evidence_path}.tmp" "${cbt_evidence_path}"
    source_vmdk="$(jq -r '.vmdk_path // ""' "${query_path}")"
    areas_count="$(jq -r '(.areas // []) | length' "${query_path}")"
    changed_bytes="$(jq -r '[.areas[]?.length] | add // 0' "${query_path}")"
    if [[ "${effective_mode_request}" == "CBT_INCREMENTAL" && "${count}" == "1" ]]; then
      transfer_total_bytes="${changed_bytes:-0}"
    fi
    is_final_disk="$([[ $((i + 1)) -eq "${count}" ]] && printf true || printf false)"
    patch_metrics_path="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-patch-metrics-${i}.XXXXXX.json)"
    if [[ "${effective_mode_request}" == "FULL_SEED" || "${effective_mode_request}" == "FULL_RESEED" ]]; then
      local copy_started_ms copy_finished_ms copy_duration_ms
      copy_started_ms="$(date +%s%3N)"
      printf 'VMware DR mover full copy: %s snapshot=%s -> %s\n' "${source_vmdk}" "${source_snapshot_ref:-none}" "${target_uri}" >&2
      FTCTL_DR_CYCLE_EFFECTIVE_MODE="${effective_mode_request}"
      ftctl_vmware_mover_convert_disk "${source_vmdk}" "${source_vm_ref}" "${source_snapshot_ref}" "${target_uri}" "${target_format:-raw}" "${label:-disk${i}}" \
        "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${thumbprint}" "${libdir}" \
        "${transfer_progress_path}" "${i}" "${count}" "${virtual_bytes:-0}" "${transfer_total_bytes:-0}" "${transfer_completed_bytes:-0}" "${is_final_disk}"
      copy_finished_ms="$(date +%s%3N)"
      copy_duration_ms=$((copy_finished_ms - copy_started_ms))
      (( copy_duration_ms > 0 )) || copy_duration_ms=1
      effective_mode="${effective_mode_request}"
      incremental_verified="false"
      jq -cn --argjson size "${virtual_bytes:-0}" --argjson duration "${copy_duration_ms}" \
        '{changedExtentCount:1,changedBytes:$size,sourceReadBytes:$size,targetWrittenBytes:$size,transferPayloadBytes:$size,durationMs:$duration,throughputBps:(if $duration > 0 then ($size * 1000 / $duration | floor) else 0 end),metricsEstimated:true}' > "${patch_metrics_path}"
    elif [[ "${areas_count}" == "0" ]]; then
      effective_mode="NO_CHANGE"
      incremental_verified="true"
      printf '{"changedExtentCount":0,"changedBytes":0,"sourceReadBytes":0,"targetWrittenBytes":0,"transferPayloadBytes":0,"durationMs":0,"throughputBps":0,"metricsEstimated":false}\n' > "${patch_metrics_path}"
    else
      effective_mode="CBT_INCREMENTAL"
      incremental_verified="true"
      printf 'VMware DR mover CBT patch: disk=%s extents=%s bytes=%s -> %s\n' "${label:-disk${i}}" "${areas_count}" "${changed_bytes}" "${target_uri}" >&2
      FTCTL_DR_CYCLE_EFFECTIVE_MODE="CBT_INCREMENTAL"
      ftctl_vmware_mover_patch_disk "${source_vmdk}" "${source_vm_ref}" "${source_snapshot_ref}" "${target_uri}" "${target_format:-raw}" "${label:-disk${i}}" \
        "${endpoint}" "${username}" "${password_file}" "${tls_verify}" "${thumbprint}" "${libdir}" "${query_path}" "${patch_metrics_path}" "${virtual_bytes}" \
        "${transfer_progress_path}" "${transfer_completed_bytes:-0}" "${transfer_total_bytes:-0}" "${i}" "${count}" "${is_final_disk}"
    fi
    result_tmp="$(mktemp -p "${FTCTL_DR_VMWARE_MOVER_LOG_DIR}" vmware-cycle-result.XXXXXX.json)"
    if ! ftctl_vmware_mover_build_disk_result "${i}" "${label:-disk${i}}" "${requested_mode}" "${effective_mode}" \
      "${previous_change_id}" "${new_change_id}" "${virtual_bytes:-0}" "${incremental_verified}" "${patch_metrics_path}" "${result_tmp}"; then
      ftctl_vmware_mover_write_cycle_journal "${journal_path}" "DATA_COPIED_METADATA_FAILED" "RESEED_REQUIRED" \
        "DR_CBT_METRICS_INVALID" "Copied disk result could not be validated" "${results_path}" "${mode_decision}" || true
      ftctl_vmware_mover_die 87 "DR_CBT_METRICS_INVALID: copied disk result could not be validated"
    fi
    jq --slurpfile item "${result_tmp}" '. + $item' "${results_path}" > "${results_path}.tmp"
    mv -f "${results_path}.tmp" "${results_path}"
    ftctl_vmware_mover_write_cycle_journal "${journal_path}" "DATA_COPIED" "METADATA_ONLY" "" "" "${results_path}" "${mode_decision}"
    if [[ "${effective_mode}" == "FULL_SEED" || "${effective_mode}" == "FULL_RESEED" ]]; then
      transfer_completed_bytes=$((transfer_completed_bytes + virtual_bytes))
    else
      transfer_completed_bytes=$((transfer_completed_bytes + changed_bytes))
    fi
    rm -f "${query_path}" "${patch_metrics_path}" "${result_tmp}"
    i=$((i + 1))
  done
  ftctl_vmware_mover_finalize_transfer_progress "${transfer_progress_path}" "${transfer_total_bytes:-0}" \
    "${transfer_completed_bytes:-0}" "${effective_mode_request}" "${count}"
  ftctl_vmware_mover_publish_cbt_active "${FTCTL_DR_CBT_STATUS_PATH:-}" "${cbt_evidence_path}" "${snapshot_name}" "${snapshot_ref}" || \
    ftctl_vmware_mover_die 82 "DR_CBT_QUERY_FAILED: CBT activation evidence could not be published"
  ftctl_vmware_mover_write_cycle_journal "${journal_path}" "METADATA_PREPARED" "METADATA_ONLY" "" "" "${results_path}" "${mode_decision}"
  commit_rc=0
  ftctl_vmware_mover_commit_cycle_metrics "${disk_map}" "${results_path}" "${metrics_path}" \
    "${FTCTL_DR_PLAN_UUID:-}" "${FTCTL_DR_RUN_UUID:-}" "${FTCTL_DR_CHECKPOINT_SEQUENCE:-0}" "${requested_mode}" "${mode_decision}" || commit_rc=$?
  if [[ "${commit_rc}" != "0" ]]; then
    ftctl_vmware_mover_write_cycle_journal "${journal_path}" "LOCAL_COMMIT_FAILED" "RESEED_REQUIRED" \
      "DR_CBT_LOCAL_COMMIT_FAILED" "Cycle metadata could not be committed atomically" "${results_path}" "${mode_decision}" || true
    ftctl_vmware_mover_die 88 "DR_CBT_LOCAL_COMMIT_FAILED: cycle metadata could not be committed atomically"
  fi
  ftctl_vmware_mover_commit_mode_decision "${mode_state_path}" "${mode_decision}" \
    "$(jq -r '.effectiveMode // ""' "${metrics_path}")" ||
      ftctl_vmware_mover_die 88 "DR_CBT_LOCAL_COMMIT_FAILED: mode decision state commit failed"
  ftctl_vmware_mover_write_cycle_journal "${journal_path}" "LOCAL_DURABLE" "NONE" "" "" "${results_path}" "${mode_decision}"
  ftctl_vmware_mover_write_source_open_status true "" "VMware source cycle completed" \
    "${source_vm_ref}" "${source_snapshot_ref}" "${source_vmdk}"
  rm -f "${results_path}" "${cbt_evidence_path}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ "${1-}" == "--recover-nbd" ]]; then
    ftctl_vmware_mover_nbd_recover_quarantine "${2-}"
  else
    main "$@"
  fi
fi
