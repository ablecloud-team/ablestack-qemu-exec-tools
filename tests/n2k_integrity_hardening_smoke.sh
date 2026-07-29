#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/n2k_integrity_hardening_smoke"

cleanup() {
  rm -rf "${WORK_DIR}"
}

trap cleanup EXIT
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

for cmd in bash jq truncate; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: ${cmd}" >&2
    exit 2
  }
done

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/engine.sh"

n2k_event() {
  return 0
}

[[ "$(n2k_source_changed_regions_next_offset_state 0 "")" == "complete" ]]
[[ "$(n2k_source_changed_regions_next_offset_state 1024 0)" == "complete" ]]
[[ "$(n2k_source_changed_regions_next_offset_state 1024 2048)" == "next:2048" ]]
if n2k_source_changed_regions_next_offset_state 1024 invalid >/dev/null 2>&1; then
  echo "[ERR] Non-numeric pagination offset was accepted" >&2
  exit 1
fi
if n2k_source_changed_regions_next_offset_state 1024 1024 >/dev/null 2>&1; then
  echo "[ERR] Non-progressing pagination offset was accepted" >&2
  exit 1
fi

n2k_source_changed_regions_validate_payload \
  '[{"offset":0,"length":1024,"type":"regular"}]' 1024
if n2k_source_changed_regions_validate_payload \
    '[{"offset":512,"length":1024,"type":"regular"}]' 1024; then
  echo "[ERR] Region beyond disk capacity was accepted" >&2
  exit 1
fi

patch_manifest="${WORK_DIR}/patch-manifest.json"
cat >"${patch_manifest}" <<JSON
{
  "run":{"id":"smoke","workdir":"${WORK_DIR}"},
  "target":{"format":"raw","storage":{"type":"file"}},
  "disks":[
    {
      "disk_id":"disk-0",
      "size_bytes":1024,
      "transfer":{"target_path":"${WORK_DIR}/disk-0.raw","base_done":true,"incr_seq":0},
      "metrics":{"incr_bytes_written":0,"incr_regions":0},
      "recovery_points":{"incr":{"id":""},"final":{"id":""}}
    },
    {
      "disk_id":"disk-1",
      "size_bytes":1024,
      "transfer":{"target_path":"${WORK_DIR}/disk-1.raw","base_done":true,"incr_seq":0},
      "metrics":{"incr_bytes_written":0,"incr_regions":0},
      "recovery_points":{"incr":{"id":""},"final":{"id":""}}
    }
  ],
  "phases":{"incr_sync":{"done":false},"final_sync":{"done":false}},
  "runtime":{"sync_issues":[],"last_error":{"code":0,"reason":"","ts":""}}
}
JSON

preflight_manifest="${WORK_DIR}/preflight-manifest.json"
cp "${patch_manifest}" "${preflight_manifest}"
n2k_manifest_record_preflight_result "${preflight_manifest}" \
  '{"selected_mode":"v3-incremental","requested_mode":"auto","can_run":true}'
jq -e '
  .runtime.selected_mode == "v3-incremental"
  and .runtime.sync.mode == "incremental"
' "${preflight_manifest}" >/dev/null

# shellcheck disable=SC2317
n2k_source_v4_changed_region_pairs_from_indexes() {
  jq -nc '[
    {disk_key:"disk-0",capacity_bytes:1024,current_ref:{diskRecoveryPointExtId:"current-0"},reference_ref:{diskRecoveryPointExtId:"base-0"}},
    {disk_key:"disk-1",capacity_bytes:1024,current_ref:{diskRecoveryPointExtId:"current-1"},reference_ref:{diskRecoveryPointExtId:"base-1"}}
  ]'
}
# shellcheck disable=SC2317
n2k_source_v4_compute_changed_regions_for_pair() {
  jq -nc '{
    ok:true,
    complete:true,
    file_size:1024,
    pe_ip:"10.0.0.1",
    compute_path:"/changed-regions",
    region_count:0,
    bytes_total:0,
    regions:[]
  }'
}
collected="$(n2k_source_v4_collect_changed_regions_from_indexes \
  "pc" "user" "password" 1 '{}' '{}' "${patch_manifest}" "rp-current" "rp-base")"
jq -e '
  .ok == true
  and .complete == true
  and .expected_disk_count == 2
  and .disk_count == 2
' <<<"${collected}" >/dev/null

# shellcheck disable=SC2317
n2k_source_legacy_changed_region_candidate_pairs_from_indexes() {
  jq -nc '[
    {vdisk_uuid:"disk-0",snapshot_file_path:"/snap/disk-0",reference_snapshot_file_path:"/base/disk-0"},
    {vdisk_uuid:"disk-1",snapshot_file_path:"/snap/disk-1",reference_snapshot_file_path:"/base/disk-1"}
  ]'
}
# shellcheck disable=SC2317
n2k_source_legacy_collect_changed_regions_for_pair() {
  local disk_key="$5"
  jq -nc --arg disk_key "${disk_key}" '{
    ok:true,
    complete:true,
    file_size:1024,
    region_count:0,
    bytes_total:0,
    disks:{($disk_key):[]}
  }'
}
collected="$(n2k_source_v3_collect_changed_regions_from_indexes \
  "pc" "user" "password" 1 '{}' '{}' "${patch_manifest}" "rp-current" "rp-base")"
jq -e '
  .ok == true
  and .complete == true
  and .expected_disk_count == 2
  and .disk_count == 2
' <<<"${collected}" >/dev/null

# shellcheck disable=SC2317
n2k_source_legacy_changed_region_candidate_pairs_from_indexes() {
  jq -nc '[
    {vdisk_uuid:"disk-0",snapshot_file_path:"/snap/disk-0",reference_snapshot_file_path:"/base/disk-0"}
  ]'
}
collected="$(n2k_source_v3_collect_changed_regions_from_indexes \
  "pc" "user" "password" 1 '{}' '{}' "${patch_manifest}" "rp-current" "rp-base")"
jq -e '
  .ok == false
  and .complete == false
  and .expected_disk_count == 2
  and .pair_count == 1
' <<<"${collected}" >/dev/null

missing_disk_regions='{
  "schema":"ablestack-n2k/changed-regions-v1",
  "ok":true,
  "complete":true,
  "errors":[],
  "skipped":[],
  "disks":{"disk-0":[]}
}'
export N2K_DRY_RUN=1
export N2K_WORKDIR="${WORK_DIR}"
if n2k_transfer_patch_all \
    "${patch_manifest}" "incr" \
    '{"disk-0":"/source/disk-0","disk-1":"/source/disk-1"}' \
    "${missing_disk_regions}" "rp-incr" \
    2>"${WORK_DIR}/missing-disk.err"; then
  echo "[ERR] Missing changed-region disk was accepted" >&2
  exit 1
fi
grep -F "missing disk index: 1" "${WORK_DIR}/missing-disk.err" >/dev/null
jq -e '
  .runtime.last_error.reason == "changed_regions_disk_missing"
  and .runtime.last_error.disk_index == 1
' "${patch_manifest}" >/dev/null

incomplete_regions='{
  "schema":"ablestack-n2k/changed-regions-v1",
  "ok":true,
  "complete":false,
  "errors":[],
  "skipped":[],
  "disks":{"disk-0":[],"disk-1":[]}
}'
if n2k_transfer_patch_all \
    "${patch_manifest}" "incr" \
    '{"disk-0":"/source/disk-0","disk-1":"/source/disk-1"}' \
    "${incomplete_regions}" "rp-incr" \
    2>"${WORK_DIR}/incomplete-regions.err"; then
  echo "[ERR] Incomplete changed-region coverage was accepted" >&2
  exit 1
fi
grep -F "metadata is incomplete" "${WORK_DIR}/incomplete-regions.err" >/dev/null
unset N2K_DRY_RUN

truncate -s 1024 "${WORK_DIR}/disk-0.raw" "${WORK_DIR}/disk-1.raw"
jq '
  .runtime.selected_mode = "v3-incremental"
  | .runtime.sync = {mode:"incremental",final_ready:false}
  | .phases.base_sync = {done:false}
  | .phases.final_sync = {done:false}
' "${patch_manifest}" >"${patch_manifest}.tmp"
mv "${patch_manifest}.tmp" "${patch_manifest}"

integrity="$(n2k_cutover_integrity_json "${patch_manifest}")"
jq -e '
  .ok == false
  and (.errors | index("base_sync_incomplete")) != null
  and (.errors | index("final_sync_incomplete")) != null
' <<<"${integrity}" >/dev/null

jq '
  .phases.base_sync.done = true
  | .phases.final_sync.done = true
  | .runtime.sync.final_ready = true
  | .disks[].transfer.base_done = true
' "${patch_manifest}" >"${patch_manifest}.tmp"
mv "${patch_manifest}.tmp" "${patch_manifest}"
integrity="$(n2k_cutover_integrity_json "${patch_manifest}")"
jq -e '.ok == true and (.targets | all(.ok))' <<<"${integrity}" >/dev/null

MOCK_RBD_DIR="${WORK_DIR}/mock-rbd"
mkdir -p "${MOCK_RBD_DIR}"

mock_rbd_file() {
  printf '%s/%s' "${MOCK_RBD_DIR}" "$(printf '%s' "$1" | tr '/' '_')"
}

rbd() {
  local action="${1:-}" spec source target file
  shift || true
  case "${action}" in
    info)
      if [[ "${1:-}" == "--format" ]]; then
        spec="${3:-}"
        file="$(mock_rbd_file "${spec}")"
        [[ -f "${file}" ]] || return 1
        printf '{"size":%s}\n' "$(cat "${file}")"
      else
        spec="${1:-}"
        [[ -f "$(mock_rbd_file "${spec}")" ]]
      fi
      ;;
    create)
      spec="${1:-}"
      printf '%s' 1048576 >"$(mock_rbd_file "${spec}")"
      ;;
    resize)
      spec="${1:-}"
      printf '%s' 1048576 >"$(mock_rbd_file "${spec}")"
      ;;
    rm)
      spec="${1:-}"
      rm -f "$(mock_rbd_file "${spec}")"
      ;;
    mv)
      source="${1:-}"
      target="${2:-}"
      mv "$(mock_rbd_file "${source}")" "$(mock_rbd_file "${target}")"
      ;;
    sparsify)
      return 0
      ;;
    *)
      echo "[ERR] Unexpected mock rbd action: ${action}" >&2
      return 2
      ;;
  esac
}

MOCK_QEMU_FAIL=0
qemu-img() {
  local action="${1:-}" target
  case "${action}" in
    info)
      printf '{"virtual-size":1024,"format":"raw"}\n'
      ;;
    convert)
      target="${!#}"
      if [[ "${MOCK_QEMU_FAIL}" -eq 1 ]]; then
        echo "fatal conversion error" >&2
        return 9
      fi
      printf '%s' 1048576 >"$(mock_rbd_file "${target#rbd:}")"
      ;;
    *)
      echo "[ERR] Unexpected mock qemu-img action: ${action}" >&2
      return 2
      ;;
  esac
}

source_file="${WORK_DIR}/source.raw"
truncate -s 1024 "${source_file}"
rbd_manifest="${WORK_DIR}/rbd-manifest.json"
cat >"${rbd_manifest}" <<JSON
{
  "run":{"id":"rbd-smoke","workdir":"${WORK_DIR}"},
  "target":{"format":"raw","storage":{"type":"rbd"}},
  "disks":[{
    "disk_id":"disk-rbd",
    "size_bytes":1024,
    "transfer":{"target_path":"rbd:pool/final","base_done":false,"incr_seq":0,"last_error":null},
    "metrics":{"base_bytes_written":0,"incr_bytes_written":0,"incr_regions":0}
  }],
  "phases":{"base_sync":{"done":false}},
  "runtime":{"sync_issues":[],"last_error":{"code":0,"reason":"","ts":""}}
}
JSON

export N2K_RUN_ID="rbd-smoke"
export N2K_BASE_COPY_RETRIES=0
n2k_transfer_cold_base_one \
  "${rbd_manifest}" \
  "$(jq -nc --arg source "${source_file}" '{"disk-rbd":$source}')" 0
[[ -f "$(mock_rbd_file "pool/final")" ]]
if find "${MOCK_RBD_DIR}" -type f -name '*n2k-stage*' | grep -q .; then
  echo "[ERR] Successful RBD transfer left a staging image" >&2
  exit 1
fi
jq -e '
  .disks[0].transfer.base_done == true
  and .disks[0].metrics.base_bytes_written == 1024
' "${rbd_manifest}" >/dev/null

MOCK_QEMU_FAIL=1
n2k_transfer_cold_base_one \
  "${rbd_manifest}" \
  "$(jq -nc --arg source "${source_file}" '{"disk-rbd":$source}')" 0

jq '
  .disks[0].transfer.target_path = "rbd:pool/fail"
  | .disks[0].transfer.base_done = false
  | .disks[0].transfer.last_error = null
  | .runtime.last_error = {code:0,reason:"",ts:""}
' "${rbd_manifest}" >"${rbd_manifest}.tmp"
mv "${rbd_manifest}.tmp" "${rbd_manifest}"
if n2k_transfer_cold_base_one \
    "${rbd_manifest}" \
    "$(jq -nc --arg source "${source_file}" '{"disk-rbd":$source}')" 0 \
    2>"${WORK_DIR}/rbd-failure.err"; then
  echo "[ERR] Failed RBD conversion was accepted" >&2
  exit 1
fi
grep -F "fatal conversion error" "${WORK_DIR}/rbd-failure.err" >/dev/null
[[ ! -f "$(mock_rbd_file "pool/fail")" ]]
if find "${MOCK_RBD_DIR}" -type f -name '*n2k-stage*' | grep -q .; then
  echo "[ERR] Failed RBD transfer left a staging image" >&2
  exit 1
fi
jq -e '
  .disks[0].transfer.base_done == false
  and .runtime.last_error.reason == "rbd_staging_copy_failed"
' "${rbd_manifest}" >/dev/null

checkpoint_manifest="${WORK_DIR}/checkpoint-manifest.json"
printf '%s\n' '{"runtime":{"cloud":{}}}' >"${checkpoint_manifest}"
n2k_cloud_target_record_checkpoint "${checkpoint_manifest}" "root-imported" \
  '{"complete":false,"root_volume_id":"root-1","data_volumes":{}}'
checkpoint="$(n2k_cloud_target_existing_checkpoint_json "${checkpoint_manifest}")"
[[ "$(n2k_cloud_target_checkpoint_reentry_state "${checkpoint}")" == "incomplete" ]]
n2k_cloud_target_record_checkpoint "${checkpoint_manifest}" "data-imported" \
  '{"data_volumes":{"1":{"id":"data-1","attached":false}}}'
n2k_cloud_target_record_checkpoint "${checkpoint_manifest}" "data-attached" \
  '{"data_volumes":{"1":{"attach_job_id":"job-attach-1","attached":true}}}'
jq -e '
  .runtime.cloud.checkpoint.root_volume_id == "root-1"
  and .runtime.cloud.checkpoint.data_volumes["1"].id == "data-1"
  and .runtime.cloud.checkpoint.data_volumes["1"].attached == true
' "${checkpoint_manifest}" >/dev/null
n2k_cloud_target_record_checkpoint "${checkpoint_manifest}" "complete" \
  '{"complete":true,"vm_id":"vm-1"}'
checkpoint="$(n2k_cloud_target_existing_checkpoint_json "${checkpoint_manifest}")"
[[ "$(n2k_cloud_target_checkpoint_reentry_state "${checkpoint}")" == "complete" ]]

reentry_manifest="${WORK_DIR}/reentry-manifest.json"
cat >"${reentry_manifest}" <<'JSON'
{
  "target":{"storage":{"type":"rbd"},"format":"raw"},
  "disks":[{"disk_id":"root","transfer":{"target_path":"rbd:pool/root"}}],
  "runtime":{"cloud":{"checkpoint":{"complete":false,"stage":"root-imported","root_volume_id":"root-1"}}}
}
JSON
import_marker="${WORK_DIR}/unexpected-import"
# shellcheck disable=SC2317
n2k_cloud_target_resolve_runtime_json() {
  printf '%s' '{"endpoint":"endpoint","api_key":"api-key","secret_key":"secret-key"}'
}
# shellcheck disable=SC2317
n2k_cloud_target_ensure_manifest_nic_mappings() {
  return 0
}
# shellcheck disable=SC2317
n2k_cloud_target_required_config_json() {
  printf '%s' '{"storage_id":"storage-1","disk_offering_id":"offering-1","network_ids":[]}'
}
# shellcheck disable=SC2317
n2k_cloud_target_validate_config() {
  return 0
}
# shellcheck disable=SC2317
n2k_cloud_target_source_deploy_params_json() {
  printf '%s' '{}'
}
# shellcheck disable=SC2317
n2k_cloud_target_import_path() {
  printf '%s' 'pool/root'
}
# shellcheck disable=SC2317
n2k_cloud_target_validate_import_visible() {
  return 0
}
# shellcheck disable=SC2317
n2k_cloud_target_import_volume() {
  : >"${import_marker}"
  printf '%s' '{"id":"duplicate-root","job_id":"duplicate-job"}'
}
checkpoint_rc=0
n2k_cloud_target_cutover \
  "${reentry_manifest}" 0 1 0 \
  "endpoint" "api-key" "secret-key" "" >/dev/null 2>&1 || checkpoint_rc=$?
[[ "${checkpoint_rc}" -eq 79 ]] || {
  echo "[ERR] Incomplete Cloud checkpoint returned rc=${checkpoint_rc}, expected 79" >&2
  exit 1
}
[[ ! -e "${import_marker}" ]] || {
  echo "[ERR] Incomplete Cloud checkpoint allowed a duplicate import" >&2
  exit 1
}

echo "[OK] n2k changed-region, cutover, RBD staging, and Cloud checkpoint integrity passed"
