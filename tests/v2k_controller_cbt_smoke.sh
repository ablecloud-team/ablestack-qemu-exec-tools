#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/v2k_controller_cbt_smoke"

cleanup() {
  rm -rf "${WORK_DIR}"
}

for cmd in bash jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: ${cmd}" >&2
    exit 2
  }
done

trap cleanup EXIT
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/engine.sh"

govc_log="${WORK_DIR}/govc.log"
fake_govc="${WORK_DIR}/govc"
cat > "${fake_govc}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${V2K_TEST_GOVC_LOG}"
SH
chmod +x "${fake_govc}"

export V2K_GOVC_BIN="${fake_govc}"
export V2K_TEST_GOVC_LOG="${govc_log}"
export GOVC_URL="https://vc.example.local/sdk"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD="dummy-password"
export GOVC_INSECURE=1

v2k_event() {
  return 0
}

manifest="${WORK_DIR}/manifest.json"
cat > "${manifest}" <<'JSON'
{
  "source": {"vm": {"name": "mixed-vm"}},
  "disks": [
    {"disk_id":"ide0:0","device_key":"3000","controller":{"kind":"ide"},"cbt":{"enabled":false,"base_change_id":"","last_change_id":""},"transfer":{"base_done":false}},
    {"disk_id":"scsi0:0","device_key":"2000","controller":{"kind":"scsi"},"cbt":{"enabled":false,"base_change_id":"","last_change_id":""},"transfer":{"base_done":false}},
    {"disk_id":"sata0:0","device_key":"16000","controller":{"kind":"sata"},"cbt":{"enabled":false,"base_change_id":"","last_change_id":""},"transfer":{"base_done":false}}
  ],
  "runtime": {"sync_issues":[],"last_error":{"code":0,"reason":"","ts":""}}
}
JSON

v2k_vmware_cbt_enable_all "${manifest}"

for expected in \
  "vm.change -vm mixed-vm -e ctkEnabled=true" \
  "vm.change -vm mixed-vm -e ide0:0.ctkEnabled=true" \
  "vm.change -vm mixed-vm -e scsi0:0.ctkEnabled=true" \
  "vm.change -vm mixed-vm -e sata0:0.ctkEnabled=true"; do
  grep -Fx -- "${expected}" "${govc_log}" >/dev/null || {
    echo "[ERR] Missing CBT enable request: ${expected}" >&2
    cat "${govc_log}" >&2
    exit 1
  }
done

jq -e '
  [.disks[].cbt.enabled] == [true,true,true]
' "${manifest}" >/dev/null || {
  echo "[ERR] Successful mixed-controller CBT enable state was not persisted" >&2
  cat "${manifest}" >&2
  exit 1
}

nvme_manifest="${WORK_DIR}/nvme-manifest.json"
cat > "${nvme_manifest}" <<'JSON'
{
  "source": {"vm": {"name": "nvme-vm"}},
  "target": {"provider": "ablestack-cloud", "cloud": {}},
  "disks": [
    {"disk_id":"nvme0:0","device_key":"32000","role":"root","controller":{"kind":"nvme","type":"VirtualNVMEController"},"cbt":{"enabled":false},"transfer":{"base_done":false}}
  ],
  "phases": {"init":{"done":false,"ts":""}},
  "runtime": {"sync_issues":[],"last_error":{"code":0,"reason":"","ts":""}}
}
JSON

govc_lines_before="$(wc -l < "${govc_log}")"
if v2k_manifest_validate_source_disk_controllers "${nvme_manifest}"; then
  echo "[ERR] NVMe controller passed source preflight" >&2
  exit 1
else
  nvme_rc=$?
fi
[[ "${nvme_rc}" -eq 44 ]] || {
  echo "[ERR] NVMe preflight did not fail with rc=44: ${nvme_rc}" >&2
  exit 1
}
[[ "$(wc -l < "${govc_log}")" -eq "${govc_lines_before}" ]] || {
  echo "[ERR] NVMe preflight changed VMware state" >&2
  exit 1
}
jq -e '
  .runtime.source_validation.status == "failed"
  and .runtime.source_validation.supported_controllers == ["ide","scsi","sata"]
  and .runtime.source_validation.unsupported_disks[0].reason == "nvme_support_deferred"
  and .runtime.last_error.reason == "unsupported_source_disk_controller"
  and .disks[0].controller.supported == false
  and .phases.init.done == false
' "${nvme_manifest}" >/dev/null || {
  echo "[ERR] NVMe preflight failure state was not persisted" >&2
  cat "${nvme_manifest}" >&2
  exit 1
}

cloud_manifest="${WORK_DIR}/cloud-controller-manifest.json"
cat > "${cloud_manifest}" <<'JSON'
{
  "source": {"vm": {"name":"kri-vm","firmware":"bios","cpu":2,"memory_mb":4096}},
  "target": {"provider":"ablestack-cloud","cloud":{"cpu_speed":"1000"}},
  "disks": [
    {"disk_id":"ide0:0","device_key":"3000","role":"root","size_bytes":21474836480,"controller":{"kind":"ide","type":"VirtualIDEController"}},
    {"disk_id":"scsi0:0","device_key":"2000","role":"data","size_bytes":10737418240,"controller":{"kind":"scsi","type":"VirtualLsiLogicController"}}
  ],
  "phases": {"init":{"done":false,"ts":""},"split.phase1":{"done":true,"ts":"2026-01-01T00:00:00Z"}},
  "runtime": {"sync_issues":[],"last_error":{"code":0,"reason":"","ts":""}}
}
JSON

v2k_manifest_validate_source_disk_controllers "${cloud_manifest}"
v2k_cloud_target_prepare_disk_controller_plan "${cloud_manifest}"
cloud_params="$(v2k_cloud_target_source_deploy_params_json "${cloud_manifest}")"
jq -e '
  .["details[0].rootDiskController"] == "ide"
  and .["details[0].dataDiskController"] == "scsi"
' <<<"${cloud_params}" >/dev/null || {
  echo "[ERR] KRI IDE/SCSI Cloud controller plan was not applied" >&2
  printf '%s\n' "${cloud_params}" >&2
  exit 1
}
v2k_manifest_split_is_done "${cloud_manifest}" "phase1" || {
  echo "[ERR] Validated Cloud phase1 manifest was rejected" >&2
  exit 1
}

root_only_manifest="${WORK_DIR}/root-only-cloud-manifest.json"
jq '
  .disks = [.disks[0]]
  | del(.target.cloud.disk_controller_plan)
  | .runtime.source_validation.status = "pending"
' "${cloud_manifest}" > "${root_only_manifest}"
v2k_manifest_validate_source_disk_controllers "${root_only_manifest}"
v2k_cloud_target_prepare_disk_controller_plan "${root_only_manifest}"
root_only_params="$(v2k_cloud_target_source_deploy_params_json "${root_only_manifest}")"
jq -e '
  .["details[0].rootDiskController"] == "ide"
  and (has("details[0].dataDiskController") | not)
' <<<"${root_only_params}" >/dev/null || {
  echo "[ERR] Root-only Cloud plan emitted an invalid data controller" >&2
  printf '%s\n' "${root_only_params}" >&2
  exit 1
}

for controller_kind in scsi sata; do
  homogeneous_manifest="${WORK_DIR}/${controller_kind}-cloud-manifest.json"
  jq \
    --arg kind "${controller_kind}" \
    --arg root_id "${controller_kind}0:0" \
    --arg data_id "${controller_kind}0:1" '
    .disks[0].disk_id = $root_id
    | .disks[0].controller.kind = $kind
    | .disks[0].controller.type = (
        if $kind == "sata" then "VirtualAHCIController"
        else "VirtualLsiLogicController"
        end
      )
    | .disks[1].disk_id = $data_id
    | .disks[1].controller.kind = $kind
    | .disks[1].controller.type = .disks[0].controller.type
    | del(.target.cloud.disk_controller_plan)
    | .runtime.source_validation.status = "pending"
  ' "${cloud_manifest}" > "${homogeneous_manifest}"
  v2k_manifest_validate_source_disk_controllers "${homogeneous_manifest}"
  v2k_cloud_target_prepare_disk_controller_plan "${homogeneous_manifest}"
  homogeneous_params="$(v2k_cloud_target_source_deploy_params_json "${homogeneous_manifest}")"
  jq -e \
    --arg kind "${controller_kind}" '
    .["details[0].rootDiskController"] == $kind
    and .["details[0].dataDiskController"] == $kind
  ' <<<"${homogeneous_params}" >/dev/null || {
    echo "[ERR] Homogeneous ${controller_kind} Cloud controller plan was not applied" >&2
    printf '%s\n' "${homogeneous_params}" >&2
    exit 1
  }
done

v2k_cloud_target_apply_disk_controller_override \
  "${cloud_manifest}" "sata" "bootstrap_sata_fallback"
fallback_params="$(v2k_cloud_target_source_deploy_params_json "${cloud_manifest}")"
jq -e '
  .["details[0].rootDiskController"] == "sata"
  and .["details[0].dataDiskController"] == "sata"
' <<<"${fallback_params}" >/dev/null || {
  echo "[ERR] Explicit SATA bootstrap fallback was not applied to Cloud params" >&2
  printf '%s\n' "${fallback_params}" >&2
  exit 1
}
jq -e '
  .target.cloud.disk_controller_plan.source == {
    root:"ide",data:"scsi",data_kinds:["scsi"]
  }
  and .target.cloud.disk_controller_plan.effective == {
    root:"sata",data:"sata"
  }
  and .target.cloud.disk_controller_plan.override_reason == "bootstrap_sata_fallback"
' "${cloud_manifest}" >/dev/null || {
  echo "[ERR] SATA fallback did not preserve source/effective controller observability" >&2
  cat "${cloud_manifest}" >&2
  exit 1
}

mixed_data_manifest="${WORK_DIR}/mixed-data-controller-manifest.json"
cat > "${mixed_data_manifest}" <<'JSON'
{
  "source": {"vm": {"name":"mixed-data-vm"}},
  "target": {"provider":"ablestack-cloud","cloud":{}},
  "disks": [
    {"disk_id":"ide0:0","device_key":"3000","role":"root","controller":{"kind":"ide","type":"VirtualIDEController"}},
    {"disk_id":"scsi0:0","device_key":"2000","role":"data","controller":{"kind":"scsi","type":"VirtualLsiLogicController"}},
    {"disk_id":"sata0:0","device_key":"16000","role":"data","controller":{"kind":"sata","type":"VirtualAHCIController"}}
  ],
  "phases": {"init":{"done":false,"ts":""}},
  "runtime": {"sync_issues":[],"last_error":{"code":0,"reason":"","ts":""}}
}
JSON
v2k_manifest_validate_source_disk_controllers "${mixed_data_manifest}"
if v2k_cloud_target_prepare_disk_controller_plan "${mixed_data_manifest}"; then
  echo "[ERR] Mixed Cloud data-disk controllers were accepted" >&2
  exit 1
else
  mixed_data_rc=$?
fi
[[ "${mixed_data_rc}" -eq 44 ]] || {
  echo "[ERR] Mixed Cloud data controllers did not fail with rc=44: ${mixed_data_rc}" >&2
  exit 1
}
jq -e '
  .target.cloud.disk_controller_plan.status == "failed"
  and .target.cloud.disk_controller_plan.failure_reason == "cloud_mixed_data_controller_unsupported"
  and .target.cloud.disk_controller_plan.source.data_kinds == ["sata","scsi"]
  and .runtime.last_error.reason == "cloud_mixed_data_controller_unsupported"
' "${mixed_data_manifest}" >/dev/null || {
  echo "[ERR] Mixed Cloud data-controller failure was not recorded" >&2
  cat "${mixed_data_manifest}" >&2
  exit 1
}

unsupported_manifest="${WORK_DIR}/unsupported-manifest.json"
cat > "${unsupported_manifest}" <<'JSON'
{
  "source": {"vm": {"name": "unsupported-vm"}},
  "disks": [
    {"disk_id":"devkey:9000","device_key":"9000","controller":{"kind":"unknown"},"cbt":{"enabled":true,"base_change_id":"","last_change_id":""},"transfer":{"base_done":false}}
  ],
  "runtime": {"sync_issues":[],"last_error":{"code":0,"reason":"","ts":""}}
}
JSON

if v2k_vmware_cbt_enable_all "${unsupported_manifest}"; then
  echo "[ERR] Unknown controller address was accepted for CBT" >&2
  exit 1
else
  unsupported_rc=$?
fi
[[ "${unsupported_rc}" -eq 44 ]] || {
  echo "[ERR] Unknown controller did not fail with rc=44: ${unsupported_rc}" >&2
  exit 1
}

jq -e '
  .disks[0].cbt.enabled == false
  and .runtime.last_error.code == 44
  and .runtime.last_error.reason == "cbt_enable_disk_unsupported"
  and .runtime.sync_issues[-1].details.device_key == "9000"
' "${unsupported_manifest}" >/dev/null || {
  echo "[ERR] Unsupported controller failure state was not recorded" >&2
  cat "${unsupported_manifest}" >&2
  exit 1
}

baseline_manifest="${WORK_DIR}/baseline-manifest.json"
cat > "${baseline_manifest}" <<'JSON'
{
  "source": {"vm": {"name": "mixed-vm"}},
  "disks": [
    {"disk_id":"ide0:0","device_key":"3000","cbt":{"enabled":true,"base_change_id":"","last_change_id":""},"snapshots":{"base":{"name":"migr-base-test"}},"transfer":{"base_done":false}},
    {"disk_id":"sata0:0","device_key":"16000","cbt":{"enabled":true,"base_change_id":"","last_change_id":""},"snapshots":{"base":{"name":"migr-base-test"}},"transfer":{"base_done":false}}
  ],
  "runtime": {"sync_issues":[],"last_error":{"code":0,"reason":"","ts":""}}
}
JSON

selector_log="${WORK_DIR}/selector.log"
v2k_python() {
  local device_key=""
  printf '%q ' "$@" >> "${selector_log}"
  printf '\n' >> "${selector_log}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device-key)
        device_key="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  jq -nc --arg key "${device_key}" \
    '{new_change_id:("change-" + $key),change_id_source:"snapshot"}'
}

# The function is intentionally replaced later to assert base-sync ordering.
# shellcheck disable=SC2218
v2k_manifest_fetch_and_save_base_change_ids \
  "${baseline_manifest}" \
  "${ROOT_DIR}/lib/v2k/vmware_changed_areas.py"

grep -F -- "--disk-id ide0:0 --change-id \\* --device-key 3000" \
  "${selector_log}" >/dev/null || {
    echo "[ERR] IDE baseline query did not carry immutable device_key" >&2
    cat "${selector_log}" >&2
    exit 1
  }
grep -F -- "--disk-id sata0:0 --change-id \\* --device-key 16000" \
  "${selector_log}" >/dev/null || {
    echo "[ERR] SATA baseline query did not carry immutable device_key" >&2
    cat "${selector_log}" >&2
    exit 1
  }
jq -e '
  .disks[0].cbt.last_change_id == "change-3000"
  and .disks[1].cbt.last_change_id == "change-16000"
' "${baseline_manifest}" >/dev/null || {
  echo "[ERR] Mixed-controller CBT baselines were not persisted" >&2
  cat "${baseline_manifest}" >&2
  exit 1
}

order_manifest="${WORK_DIR}/order-manifest.json"
cat > "${order_manifest}" <<'JSON'
{
  "source": {"vm": {"guestFamily": "windowsGuest"}},
  "target": {"format":"raw","storage":{"type":"rbd"}},
  "disks": [
    {"cbt":{"enabled":true,"last_change_id":"change-1"}}
  ],
  "phases": {"base_sync":{"done":false,"ts":""}}
}
JSON

export V2K_MANIFEST="${order_manifest}"
export V2K_WORKDIR="${WORK_DIR}"
export V2K_RUN_ID="controller-cbt-smoke"
order_log="${WORK_DIR}/order.log"

v2k_load_runtime_flags_from_manifest() { return 0; }
v2k_restore_runtime_env_from_workdir() { return 0; }
v2k_maybe_force_cleanup() { return 0; }
v2k_prepare_cbt_change_ids_for_sync() { return 0; }
v2k_manifest_fetch_and_save_base_change_ids() { printf 'baseline\n' >> "${order_log}"; }
v2k_transfer_base_all() { printf 'transfer\n' >> "${order_log}"; }
v2k_prepare_cbt_change_ids_after_base() { return 0; }
v2k_manifest_phase_done() { return 0; }
v2k_json_or_text_ok() { return 0; }

v2k_cmd_sync base

[[ "$(cat "${order_log}")" == $'baseline\ntransfer' ]] || {
  echo "[ERR] CBT baseline was not validated before base transfer" >&2
  cat "${order_log}" >&2
  exit 1
}

echo "[OK] v2k mixed-controller CBT safety passed"
