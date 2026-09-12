#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_log_event() { :; }
ftctl__json_escape() { printf '%s' "${1-}"; }
ftctl_dr_runtime_key() { printf '%s\n' "${1//[^A-Za-z0-9._-]/_}"; }
ftctl_dr_runtime_plan_dir() { printf '%s/runtime/%s\n' "${TMP}" "$(ftctl_dr_runtime_key "$1")"; }
ftctl_state_write_json_file() { printf '%s\n' "$2" > "$1"; }
ftctl_state_write_kv_all() {
  local path="${1-}" item
  shift
  mkdir -p "$(dirname "${path}")"
  : > "${path}"
  for item in "$@"; do
    printf '%s\n' "${item}" >> "${path}"
  done
}
ftctl_state_read_kv() {
  local path="${1-}" key="${2-}"
  [[ -f "${path}" ]] || return 0
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${path}"
}

# shellcheck source=../lib/ftctl/dr_ablestack.sh
source "${ROOT}/lib/ftctl/dr_ablestack.sh"

profile="${TMP}/profile.json"
canonical="${TMP}/canonical.json"
cat > "${profile}" <<'EOF'
{
  "source": {
    "provider": "ABLESTACK",
    "externalRef": "source-vm-uuid",
    "instanceName": "i-2-332-VM",
    "hostUuid": "source-host-uuid"
  },
  "target": {"provider": "ABLESTACK"},
  "mapping": {
    "disks": [{
      "device": "sda",
      "sourcePath": "rbd:rbd/source-image",
      "targetPath": "rbd:rbd/target-image",
      "sourceFormat": "raw",
      "targetFormat": "raw"
    }]
  },
  "transport": {
    "mode": "remote-nbd",
    "targetHostUuid": "target-host-uuid",
    "targetHostAddress": "10.10.32.2",
    "secondaryUri": "qemu+ssh://root@10.10.32.2/system",
    "sshUser": "root",
    "sshPort": "22",
    "sshKeyFile": "/root/.ssh/ftctl-dr/i-2-332-VM/id_ed25519",
    "remoteNbdExportAddress": "10.10.32.2",
    "targetStorageScope": "secondary-local"
  }
}
EOF

ftctl_dr_ablestack_canonicalize_profile "${profile}" "${canonical}"
[[ "$(jq -r '.source.instanceName' "${canonical}")" == "i-2-332-VM" ]]
[[ "$(jq -r '.transport.mode' "${canonical}")" == "remote-nbd" ]]
[[ "$(jq -r '.transport.targetStorageScope' "${canonical}")" == "secondary-local" ]]
[[ "$(jq -r '.disks[0].sourcePath' "${canonical}")" == "rbd:rbd/source-image" ]]
[[ "$(jq -r '.disks[0].targetPath' "${canonical}")" == "rbd:rbd/target-image" ]]

ftctl_dr_ablestack_remote_transport_load "${canonical}"
[[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]
[[ "${FTCTL_PROFILE_TARGET_STORAGE_SCOPE}" == "secondary-local" ]]
[[ "${FTCTL_PROFILE_SECONDARY_TARGET_DIR}" == "/dev/rbd" ]]

remote_path=""
ftctl_dr_ablestack_remote_rbd_path "rbd:rbd/target-image" remote_path
[[ "${remote_path}" == "/dev/rbd/rbd/target-image" ]]

grep -q 'rbd export-diff --from-snap' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'rbd import-diff' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'reason=baseline_unavailable' "${ROOT}/lib/ftctl/dr_ablestack.sh"
! grep -q 'rbd mirror' "${ROOT}/lib/ftctl/dr_ablestack.sh"

site_agent_profile="${TMP}/site-agent-profile.json"
site_agent_canonical="${TMP}/site-agent-canonical.json"
cat > "${site_agent_profile}" <<'EOF'
{
  "planUuid": "plan-a",
  "source": {
    "provider": "ABLESTACK",
    "externalRef": "source-vm-uuid",
    "instanceName": "i-2-332-VM",
    "hostUuid": "source-host-uuid"
  },
  "target": {"provider": "ABLESTACK"},
  "mapping": {
    "disks": [{
      "device": "sda",
      "sourcePath": "rbd:rbd/source-image",
      "targetPath": "rbd:rbd/target-image",
      "sourceFormat": "raw",
      "targetFormat": "raw",
      "sizeBytes": 1073741824,
      "sourceType": "rbd",
      "targetType": "rbd"
    }]
  },
  "transport": {
    "mode": "site-agent-nbd",
    "controlMode": "site-agent",
    "targetHostUuid": "target-host-uuid",
    "targetHostAddress": "10.10.32.2",
    "targetStorageScope": "secondary-local",
    "exports": [{
      "device": "sda",
      "host": "10.10.32.2",
      "port": 12032,
      "name": "dr-export-sda",
      "uri": "nbd://10.10.32.2:12032/dr-export-sda"
    }]
  }
}
EOF

ftctl_dr_ablestack_canonicalize_profile "${site_agent_profile}" "${site_agent_canonical}"
[[ "$(jq -r '.transport.mode' "${site_agent_canonical}")" == "site-agent-nbd" ]]
[[ "$(jq -r '.transport.exports[0].name' "${site_agent_canonical}")" == "dr-export-sda" ]]
ftctl_dr_ablestack_site_agent_transport_load "${site_agent_canonical}"
[[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]
[[ "${FTCTL_PROFILE_PROVISIONING_BACKEND}" == "cloud-managed" ]]
[[ "$(ftctl_dr_ablestack_export_value "${site_agent_canonical}" sda uri)" == "nbd://10.10.32.2:12032/dr-export-sda" ]]
grep -q 'ftctl_dr_ablestack_site_agent_incremental_once' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'rbd_extent_copy.py' "${ROOT}/lib/ftctl/dr_ablestack.sh"
[[ "$(ftctl_dr_ablestack_normalize_cycle_type incremental)" == "INCREMENTAL" ]]
[[ "$(ftctl_dr_ablestack_normalize_cycle_type cbt-incremental)" == "CBT_INCREMENTAL" ]]
ftctl_dr_ablestack_cycle_incremental_capable incremental
ftctl_dr_ablestack_cycle_incremental_capable cbt-incremental
ftctl_dr_ablestack_cycle_incremental_capable failover-final
! ftctl_dr_ablestack_cycle_incremental_capable full-reseed

checkpoint_manifest="${TMP}/checkpoint-manifest.json"
checkpoint_path="${TMP}/checkpoint.json"
printf '{"disks":[]}\n' > "${checkpoint_manifest}"
ftctl_dr_ablestack_write_checkpoint "${site_agent_canonical}" "${checkpoint_manifest}" "${checkpoint_path}" \
  TARGET_READY 2026-08-24T00:00:00Z 2026-08-24T00:00:02Z 2 \
  CBT_INCREMENTAL CBT_INCREMENTAL true 4096 "" 7 1 1
jq -e '.requestedMode == "CBT_INCREMENTAL"
  and .effectiveMode == "CBT_INCREMENTAL"
  and .incrementalVerified == true
  and .changedBytes == 4096
  and .targetWrittenBytes == 4096
  and .sequence == 7
  and .baselineGeneration == 7
  and .baselineState == "LOCAL_DURABLE"
  and .cycleToken == "plan-a:7"' "${checkpoint_path}" >/dev/null
jq -e '.cycleCommitState == "LOCAL_DURABLE"
  and .nbdTeardownState == "DRAINED"
  and .nbdSourceDeviceCount == 1
  and .nbdTargetDeviceCount == 1
  and .nbdQuarantinedDeviceCount == 0
  and .nbdTeardownCompletedAtEpochMs > 0' "${checkpoint_path}" >/dev/null

FTCTL_REMOTE_NBD_PORT_BASE=11809
FTCTL_REMOTE_NBD_PORT_COUNT=4
ftctl_blockcopy_remote_nbd_candidate_port() { printf -v "$3" '%s' 11809; }
ftctl_dr_ablestack_local_port_in_use() { [[ "$1" == "11809" || "$1" == "11810" ]]; }
selected_port=""
ftctl_dr_ablestack_target_export_pick_port plan-a sda selected_port
[[ "${selected_port}" == "11811" ]]

export_unit_a="$(ftctl_dr_ablestack_target_export_unit_name plan-a sda)"
export_unit_b="$(ftctl_dr_ablestack_target_export_unit_name plan-a sda)"
export_unit_c="$(ftctl_dr_ablestack_target_export_unit_name plan-a sdb)"
[[ "${export_unit_a}" == "${export_unit_b}" ]]
[[ "${export_unit_a}" != "${export_unit_c}" ]]
[[ "${export_unit_a}" =~ ^ablestack-vm-ftctl-dr-export-[0-9a-f]{20}\.service$ ]]
grep -q 'systemd-run --quiet --collect --unit' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'property=Restart=on-failure' "${ROOT}/lib/ftctl/dr_ablestack.sh"

rollback_records="${TMP}/rollback.records"
rollback_manifest="${TMP}/rollback.json"
rollback_pid="${TMP}/rollback.pid"
sleep 60 &
rollback_process=$!
printf '%s\n' "${rollback_process}" > "${rollback_pid}"
python3 - "${rollback_records}" "${rollback_pid}" <<'PY'
import json,sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"pidFile": sys.argv[2]}, separators=(",", ":")) + "\n")
PY
printf '{}\n' > "${rollback_manifest}"
# A reused/unrelated PID cannot be killed or have its evidence discarded.
if ftctl_dr_ablestack_target_export_abort "${rollback_records}" "${rollback_manifest}"; then
  echo "unrelated PID accepted as export" >&2; exit 1
fi
kill -0 "${rollback_process}"
[[ -e "${rollback_records}" && -e "${rollback_manifest}" && -e "${rollback_pid}" ]]
kill "${rollback_process}"
wait "${rollback_process}" 2>/dev/null || true

FTCTL_DR_TARGET_EXPORT_PERSIST_ROOT="${TMP}/persist"
persistent_manifest="${TMP}/persistent-exports.json"
cat > "${persistent_manifest}" <<'EOF'
{"schemaVersion":1,"exports":[{"device":"sda","host":"127.0.0.1","port":12032,"name":"dr-export-sda"}]}
EOF
ftctl_dr_ablestack_export_persist_intent plan-persist run-persist RUNNING "${site_agent_profile}" "${persistent_manifest}"
persist_dir="$(ftctl_dr_ablestack_export_persist_dir plan-persist)"
[[ "$(jq -r '.desiredState' "${persist_dir}/intent.json")" == "RUNNING" ]]
[[ "$(jq -r '.actualState' "${persist_dir}/intent.json")" == "RUNNING" ]]
[[ "$(jq -r '.runUuid' "${persist_dir}/intent.json")" == "run-persist" ]]
[[ "$(jq -r '.exports[0].port' "${persist_dir}/exports.json")" == "12032" ]]
resolved_persisted_profile=""
ftctl_dr_ablestack_target_export_resolve_profile plan-persist "" resolved_persisted_profile
[[ "${resolved_persisted_profile}" == "${persist_dir}/profile.json" ]]
resolved_requested_profile=""
ftctl_dr_ablestack_target_export_resolve_profile plan-persist "${site_agent_profile}" resolved_requested_profile
[[ "${resolved_requested_profile}" == "${site_agent_profile}" ]]
if ftctl_dr_ablestack_target_export_resolve_profile missing-plan "" resolved_missing_profile; then
  echo "missing Plan-owned export profile was accepted" >&2
  exit 1
else
  [[ "$?" == "2" ]]
fi

# Preserve the pre-reversal request as recovery input. Replaying its generation
# must not fingerprint a reversed map or reverse the source/target a second time.
(
  original="${TMP}/reverse-owner-request.json"
  jq '.request={exportGeneration:3,exportAuthorityScope:"plan-replay",exportDirection:"REVERSE",reverseTargetExport:true}' "${site_agent_profile}" > "${original}"
  ftctl_dr_runtime_profile_value() { jq -r ".${2} // empty" "$1"; }
  ftctl_dr_runtime_build_reverse_profile() {
    mkdir -p "$(dirname "$4")"
    jq '.mapping.disks |= map(.sourcePath as $source | .sourcePath=.targetPath | .targetPath=$source) | .reverseOf={operation:"export"}' "$3" > "$4"
  }
  # Transport is mocked; exercise real generation gate, profile conversion and durable publication.
  ftctl_dr_ablestack_disk_rows() { :; }
  ftctl_dr_ablestack_target_export_start plan-replay run-replay "${original}" 1 >/dev/null
  persisted="$(ftctl_dr_ablestack_export_persist_profile_path plan-replay)"
  [[ "$(jq -r '.mapping.disks[0].sourcePath' "${persisted}")" == "rbd:rbd/source-image" ]]
  [[ "$(jq -r '.reverseOf // empty' "${persisted}")" == "" ]]
  ftctl_dr_ablestack_target_export_start plan-replay run-replay "${persisted}" 1 >/dev/null
  [[ "$(jq -r '.disks[0].targetPath' "$(ftctl_dr_ablestack_disk_map_path plan-replay)")" == "rbd:rbd/source-image" ]]
  ftctl_dr_ablestack_export_persist_intent plan-replay run-replay STOPPED "" "" STOPPED
)
# A timer reconciliation may start while a site Agent is publishing a
# multi-disk export set. Both operations must serialize on the Plan lock so the
# response and persisted manifest can never expose a partial set.
lock_trace="${TMP}/target-export-lock.trace"
ftctl_dr_ablestack_target_export_start_unlocked() {
  printf 'start:%s\n' "$2" >> "${lock_trace}"
  sleep 0.2
  printf 'end:%s\n' "$2" >> "${lock_trace}"
}
ftctl_dr_ablestack_target_export_start plan-lock run-agent "${site_agent_profile}" 0 &
lock_pid=$!
sleep 0.05
ftctl_dr_ablestack_target_export_start plan-lock run-reconcile "${site_agent_profile}" 0
wait "${lock_pid}"
[[ "$(tr '\n' ' ' < "${lock_trace}")" == \
  "start:run-agent end:run-agent start:run-reconcile end:run-reconcile " ]]

ftctl_dr_ablestack_local_port_in_use() { return 1; }
selected_port=""
ftctl_dr_ablestack_target_export_pick_port plan-persist sda selected_port
[[ "${selected_port}" == "12032" ]]

listener_port_file="${TMP}/listener.port"
python3 - "${listener_port_file}" <<'PY' &
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(4)
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(str(s.getsockname()[1]))
while True:
    conn, _ = s.accept()
    conn.close()
PY
listener_pid=$!
for _ in $(seq 1 50); do [[ -s "${listener_port_file}" ]] && break; sleep 0.1; done
listener_port="$(cat "${listener_port_file}")"
ftctl_dr_ablestack_target_export_reachable 127.0.0.1 "${listener_port}" 1
kill "${listener_pid}"
wait "${listener_pid}" 2>/dev/null || true
! ftctl_dr_ablestack_target_export_reachable 127.0.0.1 "${listener_port}" 1

# A Plan Owner may dispatch target-side test actions while the canonical
# restore-point journal remains on a remote KVM source worker.
ftctl_state_vm_key() { printf '%s\n' "${1//[^A-Za-z0-9._-]/_}"; }
ftctl_now_iso8601() { printf '%s\n' 2026-08-24T00:05:00Z; }
export FTCTL_RUN_DIR="${TMP}/runtime-root"
# shellcheck source=../lib/ftctl/dr_runtime.sh
source "${ROOT}/lib/ftctl/dr_runtime.sh"
# shellcheck source=../lib/ftctl/dr_scheduler.sh
source "${ROOT}/lib/ftctl/dr_scheduler.sh"

plan_owner_profile="${TMP}/plan-owner-profile.json"
plan_owner_artifact="${TMP}/plan-owner-artifact.json"
checkpoint_ref="ftctl:plan-owner:source-run:12"
cat > "${plan_owner_profile}" <<EOF
{
  "planUuid":"plan-owner",
  "direction":"KVM_TO_KVM",
  "workers":{"source":"source-host","coordinator":"target-host","target":"target-host"},
  "target":{"vmId":283,"externalRef":"target-vm-uuid"},
  "mapping":{"disks":[{"source":{"canonicalLocator":"rbd:rbd/source"},"target":{"canonicalLocator":"rbd:rbd/target"}}]},
  "request":{
    "schedulerTransitionScope":"REMOTE_SOURCE",
    "checkpointContractVersion":1,
    "checkpointPlanUuid":"plan-owner",
    "checkpointRef":"${checkpoint_ref}",
    "restorePointRef":"${checkpoint_ref}",
    "checkpointSequence":12,
    "checkpointState":"READY",
    "checkpointCycleType":"CBT_INCREMENTAL",
    "checkpointCycleToken":"plan-owner:12",
    "checkpointEffectiveMode":"CBT_INCREMENTAL",
    "checkpointSourceCreatedAt":"2026-08-24T00:04:57Z",
    "checkpointTargetReadyAt":"2026-08-24T00:05:00Z",
    "checkpointTargetReadyRpoSeconds":3
  }
}
EOF
cat > "${plan_owner_artifact}" <<EOF
{"contractVersion":3,"planUuid":"plan-owner","runUuid":"test-run","checkpointRef":"${checkpoint_ref}","checkpointSequence":12,"disks":[]}
EOF
ftctl_dr_runtime_remote_source_transition "${plan_owner_profile}"

# A target-side Cross-Mold profile cannot name a remote source host from its
# local host inventory. REMOTE_SOURCE still forbids a local scheduler resume.
target_only_profile="${TMP}/plan-owner-target-only-profile.json"
jq 'del(.workers.source)' "${plan_owner_profile}" > "${target_only_profile}"
ftctl_dr_runtime_remote_source_transition "${target_only_profile}"

# Target-side cutover authority uses the Plan-owned export profile when the
# transient runtime profile is absent after the export is stopped.
target_commit_plan="plan-target-cutover-commit"
target_commit_run="run-target-cutover-commit"
target_commit_session="${target_commit_plan}:${target_commit_run}"
target_commit_cloud_session="cloud-target-cutover-session"
target_commit_attempt="target-cutover-attempt"
target_commit_manifest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
ftctl_dr_ablestack_export_persist_intent "${target_commit_plan}" "${target_commit_run}" RUNNING \
  "${target_only_profile}" "${persistent_manifest}"
[[ ! -e "$(ftctl_dr_runtime_profile_path "${target_commit_plan}")" ]]
resolved_target_commit_profile="$(ftctl_dr_runtime_cloud_target_profile_path "${target_commit_plan}")"
[[ "${resolved_target_commit_profile}" == "$(ftctl_dr_ablestack_export_persist_profile_path "${target_commit_plan}")" ]]
rm -rf "$(ftctl_dr_runtime_cutover_commit_dir "${target_commit_plan}")"
[[ ! -d "$(ftctl_dr_runtime_cutover_commit_dir "${target_commit_plan}")" ]]
ftctl_dr_scheduler_control_set() { return 0; }
ftctl_dr_scheduler_systemd_available() { return 1; }
target_commit_sha="$(ftctl_dr_runtime_cutover_commit_envelope_sha256 \
  DR_CUTOVER_COMMIT_V2 "${target_commit_plan}" "${target_commit_run}" \
  "${target_commit_session}" "${target_commit_cloud_session}" 12 "${target_commit_manifest}" \
  400 "${target_commit_attempt}" 283 target-vm-uuid POWERED_ON POWER_STATE_VALIDATED \
  VERIFIED POWERED_OFF)"
ftctl_dr_runtime_cutover_commit "${target_commit_plan}" "${target_commit_run}" \
  "${target_commit_session}" 12 400 POWERED_ON POWER_STATE_VALIDATED 1 \
  DR_CUTOVER_COMMIT_V2 "${target_commit_cloud_session}" "${target_commit_manifest}" \
  "${target_commit_attempt}" "${target_commit_sha}" 283 target-vm-uuid VERIFIED POWERED_OFF target \
  > "${TMP}/target-cutover-commit.json"
jq -e '.result == "ok" and .state == "FAILED_OVER" and .active_side == "TARGET"' \
  "${TMP}/target-cutover-commit.json" >/dev/null
target_commit_run_path="$(ftctl_dr_runtime_run_path "${target_commit_plan}" "${target_commit_run}")"
[[ "$(ftctl_dr_runtime_state_get_from_path "${target_commit_run_path}" role)" == "target" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${target_commit_run_path}" terminal_authoritative)" == "true" ]]
target_commit_journal="$(ftctl_dr_runtime_cutover_commit_state_path "${target_commit_plan}" "${target_commit_run}")"
[[ "$(ftctl_state_read_kv "${target_commit_journal}" phase)" == "ACKNOWLEDGED" ]]
rm -rf "$(ftctl_dr_ablestack_export_persist_dir "${target_commit_plan}")"

# Missing site scope must never be inferred from transient worker identities.
local_transition_profile="${TMP}/plan-owner-local-transition-profile.json"
jq 'del(.request.schedulerTransitionScope)' "${plan_owner_profile}" > "${local_transition_profile}"
! ftctl_dr_runtime_remote_source_transition "${local_transition_profile}"

ftctl_dr_runtime_ensure_plan_dirs plan-owner
plan_owner_run_path="$(ftctl_dr_runtime_run_path plan-owner test-run)"
plan_owner_status_path="$(ftctl_dr_runtime_status_path plan-owner)"
printf 'state=READY\n' > "${plan_owner_run_path}"
printf 'state=READY\nrestore_points_path=%s\n' "${TMP}/missing-restore-points.jsonl" > "${plan_owner_status_path}"
ftctl_dr_runtime_prepare_test_session plan-owner test-run "${plan_owner_profile}" "${checkpoint_ref}" \
  "${plan_owner_run_path}" "${plan_owner_status_path}" "${plan_owner_artifact}"
plan_owner_session="$(ftctl_dr_runtime_test_session_path plan-owner test-run)"
jq -e --arg ref "${checkpoint_ref}" '.restorePoint.ref == $ref
  and .restorePoint.checkpointSequence == 12
  and .request.schedulerTransitionScope == "REMOTE_SOURCE"' "${plan_owner_session}" >/dev/null

failover_run_path="$(ftctl_dr_runtime_run_path plan-owner failover-run)"
printf 'state=READY\nlast_target_durable_at=2026-08-24T00:05:00Z\n' > "${failover_run_path}"
ftctl_dr_runtime_finalize_failover plan-owner failover-run "${plan_owner_profile}" "${checkpoint_ref}" planned \
  "${failover_run_path}" "${plan_owner_status_path}"
[[ "$(ftctl_dr_runtime_state_get_from_path "${failover_run_path}" state)" == "CUTOVER_READY" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${failover_run_path}" active_side)" == "SOURCE" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${failover_run_path}" target_power_state)" == "POWERED_OFF" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${failover_run_path}" target_vm_id)" == "283" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${failover_run_path}" target_external_ref)" == "target-vm-uuid" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${failover_run_path}" manifest_sha256)" =~ ^[0-9a-f]{64}$ ]]

# Disaster failover is target-owned and must use the controller-selected
# durable checkpoint without a remote source journal or source worker.
target_disaster_profile="${TMP}/target-disaster-profile.json"
jq '.workers={"source":"","coordinator":"target-host","target":"target-host"}
  | .request.mode="disaster"
  | .request.finalSync=false
  | .request.schedulerTransitionScope="TARGET_DISASTER"' \
  "${plan_owner_profile}" > "${target_disaster_profile}"
ftctl_dr_runtime_target_disaster_transition "${target_disaster_profile}"
ftctl_dr_runtime_cloud_target_transition "${target_disaster_profile}"
disaster_run_path="$(ftctl_dr_runtime_run_path plan-owner disaster-run)"
printf 'state=READY\nlast_target_durable_at=2026-08-24T00:05:00Z\nsource_fence_state=ACKNOWLEDGED\nsource_power_state=UNKNOWN\n' > "${disaster_run_path}"
ftctl_dr_runtime_finalize_failover plan-owner disaster-run "${target_disaster_profile}" \
  "${checkpoint_ref}" disaster "${disaster_run_path}" "${plan_owner_status_path}"
[[ "$(ftctl_dr_runtime_state_get_from_path "${disaster_run_path}" state)" == "CUTOVER_READY" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${disaster_run_path}" active_side)" == "SOURCE" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${disaster_run_path}" source_fence_state)" == "ACKNOWLEDGED" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${disaster_run_path}" source_power_state)" == "UNKNOWN" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${disaster_run_path}" manifest_sha256)" =~ ^[0-9a-f]{64}$ ]]

reverse_profile_source="${TMP}/reverse-baseline-source.json"
jq '.direction="KVM_TO_KVM"
  | .workers={"source":"source-host","coordinator":"target-host","target":"target-host"}
  | .request={"schedulerTransitionScope":"REMOTE_SOURCE"}
  | .target={"provider":"ABLESTACK","externalRef":"target-vm-uuid"}' \
  "${site_agent_profile}" > "${reverse_profile_source}"
ftctl_dr_ablestack_export_persist_intent plan-reverse run-cutover RUNNING \
  "${reverse_profile_source}" "${persistent_manifest}"
reverse_snap="$(ftctl_dr_ablestack_snapshot_name plan-reverse reverse-33)"
rbd() {
  case "${1-} ${2-}" in
    "snap create"|"snap rm") return 0 ;;
    "snap ls")
      printf '[{"name":"%s"}]\n' "${reverse_snap}"
      return 0
      ;;
    "snap info") return 99 ;;
    *) return 0 ;;
  esac
}
reverse_stop="$(ftctl_dr_ablestack_target_export_stop plan-reverse 1 run-cutover 33)"
[[ "${reverse_stop}" == *'"reverse_baseline_state":"READY"'* ]]
[[ "$(ftctl_dr_ablestack_reverse_baseline_status plan-reverse run-cutover 33)" == "READY" ]]
reverse_state="$(ftctl_dr_ablestack_reverse_baseline_state_path plan-reverse)"
reverse_map="$(ftctl_state_read_kv "${reverse_state}" disk_map_path)"
[[ "$(jq -r '.disks[0].sourcePath' "${reverse_map}")" == "rbd:rbd/target-image" ]]
[[ "$(jq -r '.disks[0].targetPath' "${reverse_map}")" == "rbd:rbd/source-image" ]]

test_failover_profile="${TMP}/test-failover-profile.json"
printf '%s\n' '{"request":{"actionIntent":"TEST_FAILOVER"}}' > "${test_failover_profile}"
test_failover_stop="$(ftctl_dr_ablestack_target_export_stop plan-test 1 run-test 33 "${test_failover_profile}")"
[[ "${test_failover_stop}" == *'"result":"ok"'* ]]
[[ "${test_failover_stop}" == *'"reverse_baseline_state":"NOT_REQUESTED"'* ]]
[[ ! -e "$(ftctl_dr_ablestack_reverse_baseline_state_path plan-test)" ]]

# Reverse baseline selection is based on the promoted source format, not the
# complete transfer pair. RBD-to-qcow2 reverses to qcow2-to-RBD and must retain
# qcow2 persistent-bitmap semantics instead of treating the file as an RBD ref.
cross_format_reverse_map="${TMP}/cross-format-reverse-map.json"
cat > "${cross_format_reverse_map}" <<EOF
{"source":{"storagePath":"${TMP}"},"count":1,"disks":[{"device":"sda","sourcePath":"${TMP}/replica.qcow2","sourceType":"file","sourceFormat":"qcow2","targetPath":"rbd:rbd/source-image","targetType":"rbd","targetFormat":"raw"}]}
EOF
ftctl_dr_ablestack_qcow2_push_provider "${cross_format_reverse_map}"
(
  called="${TMP}/qcow2-initialize-called"
  ftctl_dr_ablestack_initialize_qcow2_source_baselines() { printf '%s\n' "$*" > "${called}"; }
  ftctl_dr_ablestack_initialize_source_baselines plan-cross reverse-33 "${cross_format_reverse_map}"
  [[ -s "${called}" ]]
)
(
  called="${TMP}/qcow2-ready-called"
  ftctl_dr_ablestack_qcow2_source_baselines_ready() { printf '%s\n' "$*" > "${called}"; }
  ftctl_dr_ablestack_source_baselines_ready plan-cross "${cross_format_reverse_map}"
  [[ -s "${called}" ]]
)

# Export termination is durable even if the following reverse-baseline step
# fails. A retry observes STOPPED rather than remaining stuck at STOPPING, and
# callers receive a structured error instead of an empty Agent answer.
set +e
stop_failure_output="$(
  ftctl_dr_ablestack_prepare_reverse_baseline() { return 32; }
  ftctl_dr_ablestack_target_export_stop plan-stop-failure 1 run-stop-failure 41
)"
stop_failure_rc=$?
set -e
[[ "${stop_failure_rc}" == "32" ]]
[[ "${stop_failure_output}" == *'"state":"STOPPED"'* ]]
[[ "${stop_failure_output}" == *'"error_code":"DR_REVERSE_BASELINE_PREPARE_FAILED"'* ]]
stop_failure_intent="$(ftctl_dr_ablestack_export_persist_intent_path plan-stop-failure)"
[[ "$(jq -r '.actualState' "${stop_failure_intent}")" == "STOPPED" ]]
[[ "$(jq -r '.desiredState' "${stop_failure_intent}")" == "STOPPED" ]]

reverse_preflight="$(ftctl_dr_ablestack_reverse_preflight plan-reverse "${reverse_profile_source}" FAILBACK_FINAL AUTO 1)"
jq -e '.ready == true
  and .effective_mode == "RBD_INCREMENTAL"
  and .initial_seed_required == false
  and .baseline_file_state == "READY"
  and .source_disk_probe_state == "READY"
  and .source_disk_count == 1
  and .target_writer_probe_state == "AGENT_VALIDATION_REQUIRED"
  and .target_backing_probe_state == "REMOTE_AGENT_VALIDATION_REQUIRED"' <<< "${reverse_preflight}" >/dev/null

full_seed_preflight="$(ftctl_dr_ablestack_reverse_preflight plan-without-baseline "${reverse_profile_source}" FAILBACK_FINAL AUTO 1)"
jq -e '.ready == true
  and .effective_mode == "FULL_RESEED"
  and .initial_seed_required == true
  and .baseline_file_state == "FULL_SEED_REQUIRED"' <<< "${full_seed_preflight}" >/dev/null

rbd() {
  [[ "${1-} ${2-}" != "info rbd/target-image" ]]
}
set +e
missing_preflight="$(ftctl_dr_ablestack_reverse_preflight plan-missing-source "${reverse_profile_source}" FAILBACK_FINAL AUTO 1)"
missing_rc=$?
set -e
[[ "${missing_rc}" == "82" ]]
jq -e '.ready == false
  and .error_code == "DR_REVERSE_SOURCE_STORAGE_MISSING"
  and .source_disk_probe_state == "NOT_READY"' <<< "${missing_preflight}" >/dev/null

grep -q 'reverse_source_provider=.*ftctl_dr_ablestack_profile_provider' "${ROOT}/bin/ablestack_vm_ftctl.sh"
grep -q 'ftctl_dr_ablestack_reverse_preflight' "${ROOT}/bin/ablestack_vm_ftctl.sh"

# A remote-source profile exists on both workers. Only the target-side worker
# may suppress its local scheduler; the source-side worker remains the producer.
role_plan="plan-role-contract"
role_plan_dir="$(ftctl_dr_runtime_plan_dir "${role_plan}")"
mkdir -p "${role_plan_dir}"
cp "${plan_owner_profile}" "${role_plan_dir}/profile.json"
printf 'state=READY\nscheduler_health=HEALTHY\n' > "${role_plan_dir}/status.state"
ftctl_dr_runtime_record_worker_role "${role_plan}" source
[[ "$(ftctl_dr_runtime_local_worker_role "${role_plan}")" == "source" ]]
ftctl_dr_runtime_record_export_worker_role "${role_plan}" reverse-target
[[ "$(ftctl_dr_runtime_local_worker_role "${role_plan}")" == "source" ]]
set +e
ftctl_dr_runtime_record_export_worker_role "${role_plan}" unexpected-role
invalid_export_role_rc=$?
set -e
[[ "${invalid_export_role_rc}" == "2" ]]
ftctl_dr_scheduler_active_worker_valid() { return 0; }
ftctl_dr_scheduler_reconcile_plan "${role_plan}"
[[ "$(ftctl_dr_runtime_state_get_from_path "${role_plan_dir}/status.state" scheduler_health)" == "HEALTHY" ]]
ftctl_dr_runtime_record_export_worker_role "${role_plan}" target
[[ "$(ftctl_dr_runtime_local_worker_role "${role_plan}")" == "target" ]]
ftctl_dr_scheduler_control_command() { printf 'stop\n'; }
ftctl_dr_scheduler_systemd_available() { return 1; }
ftctl_dr_scheduler_reconcile_plan "${role_plan}"
[[ "$(ftctl_dr_runtime_state_get_from_path "${role_plan_dir}/status.state" scheduler_health)" == "SUPPRESSED" ]]

# Remote-source Failback acknowledges authority on the target worker without
# starting a scheduler there. Commit-status reconciliation must recover an
# already submitted pre-patch journal without a control/ack file.
commit_plan="plan-remote-failback-commit"
commit_run="run-remote-failback-commit"
commit_session="session-remote-failback-commit"
commit_plan_dir="$(ftctl_dr_runtime_plan_dir "${commit_plan}")"
ftctl_dr_runtime_ensure_plan_dirs "${commit_plan}"
jq --arg plan "${commit_plan}" '.planUuid=$plan' "${plan_owner_profile}" > "${commit_plan_dir}/profile.json"
ftctl_dr_runtime_record_worker_role "${commit_plan}" target
commit_run_path="$(ftctl_dr_runtime_run_path "${commit_plan}" "${commit_run}")"
commit_status_path="$(ftctl_dr_runtime_status_path "${commit_plan}")"
commit_journal_path="$(ftctl_dr_runtime_failback_commit_state_path "${commit_plan}" "${commit_run}")"
mkdir -p "$(dirname "${commit_journal_path}")"
cat > "${commit_run_path}" <<EOF
state=SYNCING
failback_session_id=${commit_session}
boot_validation_state=READY
EOF
cp "${commit_run_path}" "${commit_status_path}"
cat > "${commit_journal_path}" <<EOF
version=3
plan=${commit_plan}
run=${commit_run}
session_id=${commit_session}
checkpoint_sequence=12
authority_generation=676
baseline_generation=11
evidence_run=reverse-run
contract_version=DR_FAILBACK_COMMIT_V1
commit_attempt_id=attempt-1
commit_envelope_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
phase=SCHEDULER_RESUMING
outcome=UNKNOWN
source_power_state=POWERED_ON
target_power_state=POWERED_OFF
EOF
ftctl_dr_runtime_reconcile_failback_commit "${commit_plan}" "${commit_run}" "${commit_session}"
[[ "$(ftctl_state_read_kv "${commit_journal_path}" phase)" == "ACKNOWLEDGED" ]]
[[ "$(ftctl_state_read_kv "${commit_journal_path}" scheduler_transition_scope)" == "REMOTE_SOURCE" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${commit_run_path}" active_side)" == "SOURCE" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${commit_run_path}" scheduler_health)" == "SUPPRESSED" ]]
[[ "$(ftctl_dr_runtime_state_get_from_path "${commit_run_path}" failback_phase)" == "PROTECTION_RESUMING" ]]

invalid_profile="${TMP}/invalid-plan-owner-profile.json"
jq '.request.checkpointPlanUuid="wrong-plan"' "${plan_owner_profile}" > "${invalid_profile}"
ftctl_dr_runtime_ensure_plan_dirs invalid-plan
invalid_run_path="$(ftctl_dr_runtime_run_path invalid-plan invalid-run)"
invalid_status_path="$(ftctl_dr_runtime_status_path invalid-plan)"
printf 'state=READY\n' > "${invalid_run_path}"
printf 'state=READY\nrestore_points_path=%s\n' "${TMP}/missing-invalid-restore-points.jsonl" > "${invalid_status_path}"
if ftctl_dr_runtime_prepare_test_session invalid-plan invalid-run "${invalid_profile}" "${checkpoint_ref}" \
  "${invalid_run_path}" "${invalid_status_path}" "${plan_owner_artifact}"; then
  echo "controller checkpoint with mismatched Plan was accepted" >&2
  exit 1
else
  [[ "$?" == "44" ]]
fi

reconcile_marker="${TMP}/reconciled"
ftctl_dr_ablestack_target_export_start() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "${reconcile_marker}"
}
rm -f "$(ftctl_dr_ablestack_export_manifest_path plan-persist)"
ftctl_dr_ablestack_target_export_reconcile_all 0
[[ "$(cut -f1 "${reconcile_marker}")" == "plan-persist" ]]
[[ "$(cut -f2 "${reconcile_marker}")" == "run-persist" ]]

grep -q 'DR_TARGET_EXPORT_UNAVAILABLE' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'pending_resource_sequence=${sequence}' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'rc.*100' "${ROOT}/lib/ftctl/dr_scheduler.sh"
awk '/^ftctl_dr_ablestack_site_agent_incremental_once\(\)/ { inside=1 }
     inside { print }
     inside && /^}/ { exit }' "${ROOT}/lib/ftctl/dr_ablestack.sh" | grep 'return 100' >/dev/null

echo "ftctl DR ABLESTACK remote RBD smoke: PASS"
