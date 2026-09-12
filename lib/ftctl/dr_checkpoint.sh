#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements. See the NOTICE file
# distributed with this work for additional information.

ftctl_dr_checkpoint_enabled() {
  [[ "$(ftctl_dr_runtime_profile_value "${1-}" "request.durableCheckpointProtocol" 2>/dev/null || true)" == "1" ]] || return 1
  [[ "$(ftctl_dr_runtime_profile_value "${1-}" "target.provider" 2>/dev/null || true)" == "ABLESTACK" ]] || return 1
  # activeSide in a forward profile can still describe the pre-failback
  # placement. Exclude the canonical reverse route, not that stale observation.
  local reverse
  reverse="$(ftctl_dr_runtime_profile_value "${1-}" "request.reverse" 2>/dev/null || true)"
  [[ "${reverse}" != "true" && "${reverse}" != "1" ]]
}

ftctl_dr_checkpoint_pending_path() {
  printf '%s/%s/checkpoint-publication.json\n' "${FTCTL_DR_CHECKPOINT_PERSIST_ROOT:-/var/lib/ablestack-vm-ftctl/dr-checkpoints}" "$(ftctl_dr_runtime_key "${1-}")"
}

ftctl_dr_checkpoint_committed_path() {
  printf '%s/checkpoint-committed.json\n' "$(dirname "$(ftctl_dr_checkpoint_pending_path "${1-}")")"
}

ftctl_dr_checkpoint_barrier() {
  local plan="${1-}" run="${2-}" sequence="${3-}" output="${4-}" profile="${5-}"
  local path tool_root="${BASH_SOURCE[0]%/*}" control cycle_type="${6-}"
  ftctl_dr_checkpoint_enabled "${profile}" || return 0
  path="$(ftctl_dr_checkpoint_pending_path "${plan}")"
  python3 - "${tool_root}" "${path}" "${plan}" "${run}" "${sequence}" "${output}" "$(ftctl_dr_ablestack_disk_map_path "${plan}")" "${cycle_type}" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from dr_checkpoint import atomic_json, request_from_map, digest
path, plan, run, sequence, output, disk_map, cycle_type = sys.argv[2:]
if not Path(path).exists():
    mapping = json.loads(Path(disk_map).read_text())
    request = request_from_map(plan, run, int(sequence), mapping)
    exports = (mapping.get("transport") or {}).get("exports") or []
    generation = int(exports[0].get("exportGeneration") or 0) if exports else 0
    exporter = str(exports[0].get("host") or "") if exports else ""
    if any(str(e.get("host") or "") != exporter for e in exports):
        raise SystemExit("DR_CHECKPOINT_EXPORT_SET_SPLIT")
    fields = next((line.split("\t") for line in output.splitlines() if "\t" in line), None)
    if not fields or len(fields) < 2:
        raise SystemExit("DR_CHECKPOINT_TRANSFER_EVIDENCE_MISSING")
    candidate = Path(path).parent / "candidates" / digest(request["checkpointRef"])
    manifest_path, checkpoint_path = candidate / "manifest.json", candidate / "checkpoint.json"
    manifest = json.loads(Path(fields[0]).read_text())
    checkpoint = json.loads(Path(fields[1]).read_text())
    checkpoint["manifest"] = str(manifest_path)
    atomic_json(manifest_path, manifest)
    atomic_json(checkpoint_path, checkpoint)
    atomic_json(path, {"request": request, "exportGeneration": generation,
                      "targetExporterAddress": exporter,
                      "output": str(manifest_path) + "\t" + str(checkpoint_path),
                      "schedulerCycleType": cycle_type, "ack": None})
PY
  [[ "$?" == "0" ]] || return 108
  # Do not hold a management request open while a checkpoint is being copied.
  # The persistent scheduler retries the same completed transfer on each pass.
  if jq -e '.ack.state == "COMMITTED" and .ack.contract == .request' "${path}" >/dev/null 2>&1; then
    python3 - "${tool_root}" "${path}" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from dr_checkpoint import atomic_json
path = Path(sys.argv[2])
atomic_json(path.with_name("checkpoint-committed.json"), json.loads(path.read_text())["ack"])
PY
    return $?
  fi
  return 107
}

# Recover the completed transfer identity after an asynchronous publication wait.
# A newer/canceled request must never inherit the old transfer's terminal result.
ftctl_dr_checkpoint_resume_context() {
  python3 - "$@" <<'PY'
import json
import sys
from pathlib import Path

path, state, mode, owner, sequence = sys.argv[1:]
pending = json.loads(Path(path).read_text())
request = pending["request"]
checkpoint = json.loads(Path(pending["output"].split("\t")[1]).read_text())
# VMware legacy top-level runUuid comes from its canonical profile.
# Cycle metrics carry the actual producer identity for the completed transfer.
evidence = checkpoint.get("cycleMetrics") or checkpoint
for key, expected in (("planUuid", request["planUuid"]), ("runUuid", request["producerRunUuid"]),
                      ("producerRunUuid", request["producerRunUuid"]),
                      ("checkpointSequence", request["checkpointSequence"]),
                      ("sequence", request["checkpointSequence"])):
    if key in evidence and evidence[key] != expected:
        raise SystemExit("DR_CHECKPOINT_CANDIDATE_IDENTITY_MISMATCH")
kind = pending.get("schedulerCycleType") or checkpoint.get("requestedMode") or checkpoint.get("effectiveMode") or ""
kind = kind.lower().replace("_", "-")
kind = {"cbt-incremental": "incremental", "no-change": "incremental"}.get(kind, kind)
if kind not in ("full-seed", "full-reseed", "incremental"):
    raise SystemExit("DR_CHECKPOINT_CYCLE_MODE_MISSING")
bound = (state in ("PENDING", "RUNNING", "TERMINALIZING") and mode == "FULL_RESEED"
         and owner == request["producerRunUuid"] and str(sequence) == str(request["checkpointSequence"])
         and kind in ("full-seed", "full-reseed"))
print(kind + "\t" + str(bound).lower())
PY
}

ftctl_dr_checkpoint_ack() {
  local plan="${1-}" artifact="${2-}" path
  path="$(ftctl_dr_checkpoint_pending_path "${plan}")"
  python3 - "${BASH_SOURCE[0]%/*}" "${path}" "${artifact}" "${plan}" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from dr_checkpoint import atomic_json, digest
path, artifact, plan = sys.argv[2:]
pending = json.loads(Path(path).read_text())
ack = json.loads(Path(artifact).read_text())
proof = dict(ack)
supplied = proof.pop("manifestSha256", None)
if ack.get("state") != "COMMITTED" or ack.get("contract") != pending["request"] or pending["request"]["planUuid"] != plan or supplied != digest(proof):
    raise SystemExit("DR_CHECKPOINT_ACK_IDENTITY_MISMATCH")
pending["ack"] = ack
atomic_json(path, pending)
print(json.dumps({"result": "ok", "accepted": True, "state": "COMMITTED"}))
PY
}

ftctl_dr_checkpoint_publish_worker() (
  local plan="${1-}" artifact="${2-}" lock_path manifest item profile run result had_exports=0 rc=0
  lock_path="$(ftctl_dr_ablestack_target_export_lock_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${lock_path}")" "0750"
  exec 203>"${lock_path}"
  flock -w 30 203 || return 93
  [[ "$(jq -r '.request.planUuid' "${artifact}")" == "${plan}" ]] || return 2
  manifest="$(ftctl_dr_ablestack_export_manifest_path "${plan}")"
  profile="$(ftctl_dr_ablestack_export_persist_profile_path "${plan}")"
  run="$(jq -r '.request.producerRunUuid' "${artifact}")"
  local owner="$(ftctl_dr_ablestack_export_persist_dir "${plan}")/ownership.json"
  local generation="$(jq -r '.exportGeneration // 0' "${artifact}")"
  if [[ "${generation}" != "0" ]] && [[ ! -f "${owner}" || "$(jq -r '.generation' "${owner}")" != "${generation}" ]]; then
    printf '%s\n' '{"result":"error","error_code":"DR_CHECKPOINT_STALE_EXPORT_GENERATION"}'
    return 93
  fi
  if [[ -f "${owner}" ]] && [[ "$(jq -r '.operation' "${owner}")" == "STOP" ]]; then
    printf '%s\n' '{"result":"error","error_code":"DR_CHECKPOINT_AUTHORITY_REVOKED"}'
    return 93
  fi
  # Reuse the owner generation: this is an idle-cycle flush, not a transfer of
  # writer authority. Reconciliation and lifecycle transitions share this lock.
  if [[ -f "${manifest}" ]]; then
    had_exports=1
    while IFS= read -r item; do
      ftctl_dr_ablestack_target_export_stop_item "${item}" || return $?
    done < <(jq -c '.exports[]' "${manifest}")
  fi
  result="$(python3 "${BASH_SOURCE[0]%/*}/dr_checkpoint.py" --request "${artifact}" \
    --directory "$(ftctl_dr_ablestack_export_persist_dir "${plan}")/checkpoints")" || rc=$?
  if [[ "${had_exports}" == "1" && -f "${profile}" ]]; then
    ftctl_dr_ablestack_target_export_start_unlocked "${plan}" "${run}" "${profile}" 0 >/dev/null || return $?
  fi
  [[ "${rc}" == "0" ]] || { printf '%s\n' "${result}"; return "${rc}"; }
  printf '%s\n' "${result}"
)

ftctl_dr_checkpoint_restore() (
  local plan="${1-}" artifact="${2-}" lock_path
  [[ "$(jq -r '.planUuid' "${artifact}")" == "${plan}" ]] || return 2
  if ftctl_dr_scheduler_has_live_worker "${plan}"; then
    local state_path
    state_path="$(ftctl_dr_runtime_status_path "${plan}")"
    ftctl_dr_scheduler_cancel_active_transfer "${plan}" "checkpoint-restore" "${state_path}" "${state_path}" >/dev/null || return $?
  fi
  lock_path="$(ftctl_dr_ablestack_target_export_lock_path "${plan}")"
  ftctl_ensure_dir "$(dirname "${lock_path}")" "0750"
  exec 203>"${lock_path}"
  flock -w 30 203 || return 93
  local pending_path
  pending_path="$(ftctl_dr_checkpoint_pending_path "${plan}")"
  if [[ -f "${pending_path}" ]]; then
    mv "${pending_path}" "${pending_path}.abandoned-$(date +%s%N)"
  fi
  python3 "${BASH_SOURCE[0]%/*}/dr_checkpoint.py" --restore --request "${artifact}" \
    --directory "$(ftctl_dr_ablestack_export_persist_dir "${plan}")/checkpoints"
)

ftctl_dr_checkpoint_publish() {
  local plan="${1-}" artifact="${2-}"
  python3 - "${BASH_SOURCE[0]%/*}" "${plan}" "${artifact}" "$(ftctl_dr_ablestack_export_persist_dir "${plan}")/checkpoint-jobs" <<'PY'
import fcntl, json, os, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from dr_checkpoint import atomic_json, digest, Backend
plan, artifact, root = sys.argv[2:]
envelope = json.loads(Path(artifact).read_text())
if envelope["request"]["planUuid"] != plan:
    raise SystemExit("DR_CHECKPOINT_PLAN_MISMATCH")
directory = Path(root) / digest(envelope["request"]["checkpointRef"])
directory.mkdir(parents=True, exist_ok=True)
request_file, result_file = directory / "request.json", directory / "result.json"
with (directory / "job.lock").open("a+") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    if request_file.exists() and json.loads(request_file.read_text())["request"] != envelope["request"]:
        raise SystemExit("DR_CHECKPOINT_IDENTITY_MISMATCH")
    if result_file.exists():
        result = json.loads(result_file.read_text())
        if result.get("state") == "COMMITTED":
            backend = Backend()
            shared = backend.shared_manifest(envelope["request"])
            if shared != result:
                raise SystemExit("DR_CHECKPOINT_COMMITTED_SET_MISSING")
            for record in result["records"]:
                backend.verify(envelope["request"], record)
            print(json.dumps(result))
            raise SystemExit(0)
        if time.time() - result_file.stat().st_mtime < 10:
            print(json.dumps(result))
            raise SystemExit(1)
        result_file.unlink()
    pid_file = directory / "worker.pid"
    running = False
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text())
            command = Path(f"/proc/{pid}/cmdline").read_bytes()
            running = b"dr-checkpoint-publish-worker" in command and plan.encode() in command
        except (OSError, ValueError):
            pass
    if not running:
        atomic_json(request_file, envelope)
        os.chmod(request_file, 0o600)
        with (directory / "worker.log").open("ab") as log:
            child = subprocess.Popen(["ablestack_vm_ftctl", "dr-checkpoint-publish-worker", "--plan", plan,
                    "--run", envelope["request"]["producerRunUuid"], "--artifact-spec-json", str(request_file), "--json"],
                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        pid_file.write_text(str(child.pid))
    print(json.dumps({"result": "ok", "accepted": True, "state": "PREPARING"}))
PY
}

ftctl_dr_checkpoint_publish_worker_result() {
  local plan="${1-}" artifact="${2-}" result rc=0
  result="$(ftctl_dr_checkpoint_publish_worker "${plan}" "${artifact}")" || rc=$?
  python3 - "${BASH_SOURCE[0]%/*}" "${artifact}" "${rc}" "${result}" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from dr_checkpoint import atomic_json
artifact, rc, output = sys.argv[2:]
try:
    result = json.loads(output)
except ValueError:
    result = {"result": "error", "error_code": "DR_CHECKPOINT_PUBLICATION_FAILED", "error_message": output[-1000:]}
atomic_json(Path(artifact).with_name("result.json"), result)
PY
  return "${rc}"
}

# Evidence is retained for diagnosis; the last committed checkpoint is untouched.
ftctl_dr_checkpoint_abandon_invalid() {
  python3 - "$@" <<'PY'
import json, os, sys, time
from pathlib import Path
path, plan, owner = sys.argv[1:]
path = Path(path)
pending = json.loads(path.read_text())
request = pending["request"]
if request.get("planUuid") != plan or not owner or owner == request.get("producerRunUuid"):
    raise SystemExit("DR_CHECKPOINT_RECOVERY_REQUEST_INVALID")
os.replace(path, path.with_name(path.name + ".rejected-" + str(time.time_ns())))
PY
}

ftctl_dr_checkpoint_manage() {
  python3 - "${BASH_SOURCE[0]%/*}" "${1-}" "${2-}" <<'PYTHON'
import json, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from dr_checkpoint_store import execute
def emit(value):
    # Ceph can leave inherited stdout nonblocking. Large inventories must be
    # completely drained; a partial JSON write must not turn a committed delete
    # into an unparseable failure response.
    os.set_blocking(sys.stdout.fileno(), True)
    print(json.dumps(value, separators=(",", ":")), flush=True)
try:
    request = json.loads(Path(sys.argv[3]).read_text())
    if request.get("planUuid") != sys.argv[2]:
        raise ValueError("DR_CHECKPOINT_PLAN_MISMATCH")
    result = execute(request)
    result.update(result="ok", accepted=True)
    emit(result)
except Exception as exc:
    emit({"result": "error", "error_code": "DR_CHECKPOINT_CLEANUP_FAILED",
          "error_message": str(exc)[:1000]})
    raise SystemExit(1)
PYTHON
}
