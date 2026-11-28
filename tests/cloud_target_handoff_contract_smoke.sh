#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloud-handoff-contract.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT

run_v2k_contract() (
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/v2k/cloudstack_api.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/v2k/target_cloud.sh"
  source "${ROOT_DIR}/lib/v2k/cloud_handoff.sh"

  local manifest="${WORK_DIR}/v2k.json" result scenario="${1:-inspection}" requested_start=0 rc=0
  cat >"${manifest}" <<'JSON'
{
  "source":{"vm":{"name":"v2k-test","nics":[]}},
  "target":{"provider":"ablestack-cloud","storage":{"type":"rbd"},"format":"raw","cloud":{}},
  "runtime":{"source_validation":{"status":"passed"},"cloud":{"readiness":{"status":"degraded","inspection_required":true,"components":{"boot":{"status":"degraded","reason":"test-bootstrap-failure"},"controller":{"status":"degraded","fallback":"sata"}}}}},
  "disks":[{"disk_id":"root","role":"root","size_bytes":1024,"transfer":{"target_path":"rbd:pool/root"},"controller":{"kind":"scsi"}}]
}
JSON

  # shellcheck disable=SC2317
  v2k_cloud_target_resolve_runtime_json() { printf '%s' '{"endpoint":"endpoint","api_key":"key","secret_key":"secret"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_ensure_manifest_nic_mappings() { return 0; }
  # shellcheck disable=SC2317
  v2k_cloud_target_required_config_json() { printf '%s' '{"storage_id":"storage","disk_offering_id":"offering","network_ids":["network"],"nic_mappings":[],"name":"v2k-test","display_name":"v2k-test"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_validate_config() { return 0; }
  # shellcheck disable=SC2317
  v2k_cloud_target_source_deploy_params_json() { printf '%s' '{"details[0].rootDiskController":"sata"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_import_path() { printf '%s' 'root'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_validate_import_visible() { return 0; }
  # shellcheck disable=SC2317
  v2k_cloud_target_import_volume() { printf '%s' '{"id":"root-v2k","job_id":"job-root-v2k"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_deploy_vm_for_volume() { printf '%s' '{"id":"vm-v2k","job_id":"job-vm-v2k"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_wait_for_vm_nic_match() {
    if [[ "$scenario" == start-failure ]]; then printf '%s' '{"matched":true,"checks":[]}';return 0;fi
    printf '%s' '{"matched":false,"checks":[]}';return 1
  }
  # shellcheck disable=SC2317
  v2k_cloud_target_start_vm() { return 37; }
  # shellcheck disable=SC2317
  v2k_cloud_target_ensure_root_volume() { printf '%s' '{"volume":{"id":"root-v2k","type":"ROOT"},"converted":false}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_storage_pool_json() { printf '%s' '{"id":"storage","type":"RBD","path":"pool","scope":"CLUSTER"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_service_offering_json() { printf '%s' '{"cpuspeed":2000}'; }
  # shellcheck disable=SC2317
  v2k_cloud_target_resolve_disk_offering() { printf '%s' '{"id":"offering","source":"explicit"}'; }
  # shellcheck disable=SC2317
  v2k_cloud_api_get() {
    case "$4" in
      listDiskOfferings) printf '%s' '{"listdiskofferingsresponse":{"diskoffering":[{"id":"offering","cachemode":"writeback","iscustomized":true,"storagetype":"shared"}]}}';;
      listVolumes) printf '%s' '{"listvolumesresponse":{"volume":[{"id":"root-v2k","type":"ROOT","state":"Ready","deviceid":0,"path":"root","storageid":"storage","virtualmachineid":"vm-v2k","cachemode":"writeback"}]}}';;
      *) echo "Unexpected fixture API: $4" >&2;return 2;;
    esac
  }

  if [[ "$scenario" == start-failure ]]; then
    jq 'del(.runtime.cloud.readiness)' "$manifest" > "$manifest.tmp";mv "$manifest.tmp" "$manifest"
    requested_start=1
  fi
  result="$(v2k_cloud_target_cutover "${manifest}" 0 1 "$requested_start" endpoint key secret '')" || rc=$?
  if [[ "$scenario" == start-failure ]]; then
    [[ "$rc" == 37 ]]
    jq -e '.runtime.cloud.retention.exit_code==37 and .runtime.cloud.checkpoint.vm_id=="vm-v2k" and .runtime.cloud.checkpoint.complete==false and .runtime.cloud.checkpoint.stage=="vm-start-failed"' "$manifest" >/dev/null
    return 0
  fi
  [[ "$rc" == 0 ]]
  jq -e '
    .status == "retained_unverified"
    and .retention.status == "RETAINED_UNVERIFIED"
    and .vm_id == "vm-v2k"
    and .inspection_required == true
    and .started == false
  ' <<<"${result}" >/dev/null
  jq -e '
    .runtime.cloud.vm_id == "vm-v2k"
    and .runtime.cloud.checkpoint.complete == false
    and .runtime.cloud.checkpoint.stage == "inspection-required"
  ' "${manifest}" >/dev/null
)

run_n2k_contract() (
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/cloudstack_api.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/target_cloud.sh"
  source "${ROOT_DIR}/lib/n2k/cloud_handoff.sh"
  source "${ROOT_DIR}/lib/n2k/controller_policy.sh"
  source "${ROOT_DIR}/lib/n2k/guest_configuration.sh"

  local manifest="${WORK_DIR}/n2k.json" result scenario="${1:-inspection}" requested_start=0 rc=0
  cat >"${manifest}" <<'JSON'
{
  "source":{"vm":{"name":"n2k-test","nics":[]}},
  "target":{"provider":"ablestack-cloud","storage":{"type":"rbd"},"format":"raw","cloud":{}},
  "runtime":{"source_validation":{"status":"passed"},"cloud":{"readiness":{"status":"degraded","inspection_required":true,"components":{"controller":{"status":"degraded","fallback":"sata","reason":"test-controller-failure"}}}}},
  "disks":[{"disk_id":"root","role":"root","size_bytes":1024,"transfer":{"target_path":"rbd:pool/root"},"controller":{"kind":"scsi"}}]
}
JSON

  # shellcheck disable=SC2317
  n2k_cloud_target_resolve_runtime_json() { printf '%s' '{"endpoint":"endpoint","api_key":"key","secret_key":"secret"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_ensure_manifest_nic_mappings() { return 0; }
  # shellcheck disable=SC2317
  n2k_cloud_target_required_config_json() { printf '%s' '{"storage_id":"storage","disk_offering_id":"offering","network_ids":["network"],"nic_mappings":[],"name":"n2k-test","display_name":"n2k-test"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_validate_config() { return 0; }
  # shellcheck disable=SC2317
  n2k_cloud_target_source_deploy_params_json() { printf '%s' '{"details[0].rootDiskController":"sata"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_import_path() { printf '%s' 'root'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_validate_import_visible() { return 0; }
  # shellcheck disable=SC2317
  n2k_cloud_target_import_volume() { printf '%s' '{"id":"root-n2k","job_id":"job-root-n2k"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_deploy_vm_for_volume() { printf '%s' '{"id":"vm-n2k","job_id":"job-vm-n2k"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_wait_for_vm_nic_match() {
    if [[ "$scenario" == start-failure ]]; then printf '%s' '{"matched":true,"checks":[]}';return 0;fi
    printf '%s' '{"matched":false,"checks":[]}';return 1
  }
  # shellcheck disable=SC2317
  n2k_cloud_target_start_vm() { return 37; }
  # shellcheck disable=SC2317
  n2k_cloud_target_ensure_root_volume() { printf '%s' '{"volume":{"id":"root-n2k","type":"ROOT"},"converted":false}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_storage_pool_json() { printf '%s' '{"id":"storage","type":"RBD","path":"pool","scope":"CLUSTER"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_service_offering_json() { printf '%s' '{"cpuspeed":2000}'; }
  # shellcheck disable=SC2317
  n2k_cloud_target_resolve_disk_offering() { printf '%s' '{"id":"offering","source":"explicit"}'; }
  # shellcheck disable=SC2317
  n2k_cloud_api_get() {
    case "$4" in
      listDiskOfferings) printf '%s' '{"listdiskofferingsresponse":{"diskoffering":[{"id":"offering","cachemode":"writeback","iscustomized":true,"storagetype":"shared"}]}}';;
      listVolumes) printf '%s' '{"listvolumesresponse":{"volume":[{"id":"root-n2k","type":"ROOT","state":"Ready","deviceid":0,"path":"root","storageid":"storage","virtualmachineid":"vm-n2k","cachemode":"writeback"}]}}';;
      *) echo "Unexpected fixture API: $4" >&2;return 2;;
    esac
  }

  if [[ "$scenario" == start-failure ]]; then
    jq 'del(.runtime.cloud.readiness)' "$manifest" > "$manifest.tmp";mv "$manifest.tmp" "$manifest"
    requested_start=1
  fi
  result="$(n2k_cloud_target_cutover "${manifest}" 0 1 "$requested_start" endpoint key secret '')" || rc=$?
  if [[ "$scenario" == start-failure ]]; then
    [[ "$rc" == 37 ]]
    jq -e '.runtime.cloud.retention.exit_code==37 and .runtime.cloud.checkpoint.vm_id=="vm-n2k" and .runtime.cloud.checkpoint.complete==false and .runtime.cloud.checkpoint.stage=="vm-start-failed"' "$manifest" >/dev/null
    return 0
  fi
  [[ "$rc" == 0 ]]
  jq -e '
    .status == "retained_unverified"
    and .retention.status == "RETAINED_UNVERIFIED"
    and .vm_id == "vm-n2k"
    and .inspection_required == true
    and .started == false
  ' <<<"${result}" >/dev/null
  jq -e '
    .runtime.cloud.vm_id == "vm-n2k"
    and .runtime.cloud.checkpoint.complete == false
    and .runtime.cloud.checkpoint.stage == "inspection-required"
  ' "${manifest}" >/dev/null
)

run_v2k_submission_checkpoint() (
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/v2k/cloudstack_api.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/v2k/target_cloud.sh"
  local manifest="${WORK_DIR}/v2k-submitted.json"
  printf '%s\n' '{"runtime":{"cloud":{}}}' >"${manifest}"
  # shellcheck disable=SC2317
  v2k_cloud_api_get() {
    [[ "$4" == importVolume ]]
    jq -e '.sourceidentity == "rbd:ceph-image-id" and .storageid == "storage" and .path == "root"' <<<"$5" >/dev/null || return 1
    printf '%s' '{"importvolumeresponse":{"jobid":"job-v2k-submitted"}}'
  }
  # shellcheck disable=SC2317
  v2k_cloud_wait_job() { return 1; }
  if v2k_cloud_target_import_volume \
      endpoint key secret storage offering root name '{}' "${manifest}" 0 rbd:ceph-image-id; then
    echo "[ERR] v2k accepted a failed submitted import job" >&2
    exit 1
  fi
  jq -e '
    .runtime.cloud.checkpoint.stage == "root-import-submitted"
    and .runtime.cloud.checkpoint.root_import_job_id == "job-v2k-submitted"
  ' "${manifest}" >/dev/null
)

run_n2k_submission_checkpoint() (
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/cloudstack_api.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/target_cloud.sh"
  local manifest="${WORK_DIR}/n2k-submitted.json"
  printf '%s\n' '{"runtime":{"cloud":{}}}' >"${manifest}"
  # shellcheck disable=SC2317
  n2k_cloud_api_get() {
    [[ "$4" == importVolume ]]
    jq -e '.sourceidentity == "rbd:ceph-image-id" and .storageid == "storage" and .path == "root"' <<<"$5" >/dev/null || return 1
    printf '%s' '{"importvolumeresponse":{"jobid":"job-n2k-submitted"}}'
  }
  # shellcheck disable=SC2317
  n2k_cloud_wait_job() { return 1; }
  if n2k_cloud_target_import_volume \
      endpoint key secret storage offering root name '{}' "${manifest}" 0 rbd:ceph-image-id; then
    echo "[ERR] n2k accepted a failed submitted import job" >&2
    exit 1
  fi
  jq -e '
    .runtime.cloud.checkpoint.stage == "root-import-submitted"
    and .runtime.cloud.checkpoint.root_import_job_id == "job-n2k-submitted"
  ' "${manifest}" >/dev/null
)

run_import_candidate_contract() (
  local tool="$1" response expected
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/${tool}/cloud_allocation.sh"
  response='{"listvolumesforimportresponse":{"volumeforimport":[{"path":"root","storageid":"pool","format":"RAW","storagetype":"RBD","virtualsize":1024,"details":{"SOURCE_IDENTITY":"rbd:ceph-image-id"}}]}}'
  expected="$(migration_cloud_import_identity "$response" pool root rbd raw)"
  [[ "$expected" == rbd:ceph-image-id ]]
  ! migration_cloud_import_identity "$response" other root rbd raw 2>/dev/null
  ! migration_cloud_import_identity "$response" pool different rbd raw 2>/dev/null
  ! migration_cloud_import_identity "$response" pool root file raw 2>/dev/null
  ! migration_cloud_import_identity "$response" pool root rbd qcow2 2>/dev/null
  ! migration_cloud_import_identity '{"listvolumesforimportresponse":{"count":1}}' pool root rbd raw 2>/dev/null
  response='{"listvolumesforimportresponse":{"volumeforimport":[{"path":"old.qcow2","fullpath":"/pool/old.qcow2","format":"QCOW2","virtualsize":1024}]}}'
  expected="$(migration_cloud_import_identity "$response" pool /pool/old.qcow2 file qcow2)"
  [[ -z "$expected" ]]
  response='{"listvolumesforimportresponse":{"volumeforimport":[{"path":"new.raw","format":"RAW","virtualsize":1024,"details":{"SOURCE_IDENTITY":"file:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}]}}'
  expected="$(migration_cloud_import_identity "$response" pool new.raw file raw)"
  [[ "$expected" == file:* ]]
)

run_import_candidate_contract v2k
run_import_candidate_contract n2k

run_v2k_contract
run_n2k_contract
run_v2k_contract start-failure
run_n2k_contract start-failure
run_v2k_submission_checkpoint
run_n2k_submission_checkpoint
run_n2k_guest_stage_with_credential_file() (
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/cloudstack_api.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/target_cloud.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/n2k/guest_configuration.sh"

  local manifest="${WORK_DIR}/n2k-guest-stage.json" creds="${WORK_DIR}/n2k-test.env"
  cat >"$manifest" <<'JSON'
{"target":{"guest_config_policy":"preserve","storage":{"type":"rbd"},"format":"raw","cloud":{"storage_id":"pool-id"}},"disks":[{"size_bytes":1024,"transfer":{"target_path":"rbd:pool/root"}}]}
JSON
  cat >"$creds" <<'ENV'
N2K_CLOUD_ENDPOINT=https://mold.example.test/client/api
N2K_CLOUD_API_KEY=test-key
N2K_CLOUD_SECRET_KEY=test-secret
ENV
  unset N2K_CLOUD_ENDPOINT N2K_CLOUD_API_KEY N2K_CLOUD_SECRET_KEY

  # shellcheck disable=SC2317
  n2k_cloud_require_unmanaged_target() { return 0; }
  # shellcheck disable=SC2317
  n2k_guest_config_python() { return 0; }
  # shellcheck disable=SC2317
  n2k_cloud_api_get() {
    [[ "$1" == https://mold.example.test/client/api && "$2" == test-key && "$3" == test-secret ]]
    [[ "$4" == listVolumesForImport ]]
    jq -e '.storageid=="pool-id" and .path=="pool/root"' <<<"$5" >/dev/null
    printf '%s' '{"listvolumesforimportresponse":{"volumeforimport":[{"path":"pool/root"}]}}'
  }
  n2k_guest_config_stage "$manifest" "" "" "" "$creds"
)

run_n2k_guest_stage_with_credential_file

echo "[OK] v2k/n2k Cloud inspection handoff contract passed"
