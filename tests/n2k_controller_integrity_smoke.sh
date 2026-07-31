#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/n2k-controller-integrity.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: $1" >&2
    exit 2
  }
}

require_cmd jq

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/nutanix_api.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/source_adapter.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/transfer_cold.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/target_cloud.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/target_libvirt.sh"

mixed_no_boot_raw='{
  "name": "mixed-no-boot",
  "disks": [
    {
      "extId": "ide-boot",
      "name": "Boot disk",
      "sizeBytes": 10737418240,
      "diskAddress": {"busType": "IDE", "index": 0}
    },
    {
      "extId": "scsi-data",
      "name": "Data disk",
      "sizeBytes": 21474836480,
      "diskAddress": {"busType": "SCSI", "index": 0}
    }
  ]
}'

mixed_no_boot="$(n2k_nutanix_inventory_from_raw "${mixed_no_boot_raw}" "mixed-no-boot")"
jq -e '
  .controller_plan.status == "failed"
  and .controller_plan.failure_reason == "mixed_controller_boot_disk_ambiguous"
  and .controller_plan.root_selection == "unresolved"
  and .controller_plan.source.controller_kinds == ["ide","scsi"]
  and .disks[0].controller.kind == "scsi"
  and .disks[1].controller.kind == "ide"
' <<<"${mixed_no_boot}" >/dev/null || {
  echo "[ERR] Mixed-controller inventory without an explicit boot disk was not rejected" >&2
  printf '%s\n' "${mixed_no_boot}" >&2
  exit 1
}

explicit_boot_raw='{
  "name": "mixed-explicit-boot",
  "bootConfig": {
    "bootDevice": {
      "diskAddress": {"busType": "IDE", "index": 0}
    }
  },
  "disks": [
    {
      "extId": "scsi-data",
      "name": "Data disk",
      "sizeBytes": 21474836480,
      "diskAddress": {"busType": "SCSI", "index": 0}
    },
    {
      "extId": "ide-boot",
      "name": "Boot disk",
      "sizeBytes": 10737418240,
      "diskAddress": {"busType": "IDE", "index": 0}
    }
  ]
}'

explicit_boot="$(n2k_nutanix_inventory_from_raw "${explicit_boot_raw}" "mixed-explicit-boot")"
jq -e '
  .controller_plan.status == "passed"
  and .controller_plan.root_selection == "explicit_boot_address"
  and .controller_plan.root == {disk_id:"ide-boot",controller:"ide"}
  and .disks[0].disk_id == "ide-boot"
  and .disks[0].role == "root"
  and .disks[1].disk_id == "scsi-data"
  and .disks[1].role == "data"
' <<<"${explicit_boot}" >/dev/null || {
  echo "[ERR] Explicit Nutanix boot-disk address did not resolve the mixed-controller root disk" >&2
  printf '%s\n' "${explicit_boot}" >&2
  exit 1
}

unsupported_raw='{
  "name": "unsupported-controller",
  "disks": [
    {
      "extId": "pci-root",
      "sizeBytes": 10737418240,
      "diskAddress": {"busType": "PCI", "index": 0}
    }
  ]
}'
unsupported_inventory="$(n2k_nutanix_inventory_from_raw "${unsupported_raw}" "unsupported-controller")"
jq -e '
  .controller_plan.status == "failed"
  and .controller_plan.failure_reason == "unsupported_disk_controller"
  and .controller_plan.source.unsupported_kinds == ["pci"]
' <<<"${unsupported_inventory}" >/dev/null || {
  echo "[ERR] Unsupported Nutanix disk controller was not rejected" >&2
  printf '%s\n' "${unsupported_inventory}" >&2
  exit 1
}

mixed_fixture="${WORK_DIR}/mixed-no-boot.json"
printf '%s\n' "${mixed_no_boot_raw}" > "${mixed_fixture}"
init_workdir="${WORK_DIR}/init"
init_manifest="${init_workdir}/manifest.json"
init_rc=0
"${ROOT_DIR}/bin/ablestack_n2k.sh" \
  --workdir "${init_workdir}" \
  --run-id controller-integrity \
  --manifest "${init_manifest}" \
  init \
  --vm mixed-no-boot \
  --pc pc.example \
  --dst "${WORK_DIR}/target" \
  --inventory-file "${mixed_fixture}" \
  --target-format raw \
  --target-storage file >/dev/null 2>&1 || init_rc=$?
[[ "${init_rc}" -eq 44 ]] || {
  echo "[ERR] n2k init did not stop with code 44 for an ambiguous mixed-controller VM: rc=${init_rc}" >&2
  exit 1
}
jq -e '
  .runtime.source_validation.status == "failed"
  and .runtime.last_error.code == 44
  and .runtime.last_error.reason == "mixed_controller_boot_disk_ambiguous"
  and .phases.init.done == false
  and .phases.base_sync.done == false
' "${init_manifest}" >/dev/null || {
  echo "[ERR] Source controller validation failure was not recorded in the manifest" >&2
  exit 1
}

for blocked_command in "snapshot base" "sync base" "cutover"; do
  blocked_rc=0
  # shellcheck disable=SC2086
  "${ROOT_DIR}/bin/ablestack_n2k.sh" \
    --workdir "${init_workdir}" \
    --manifest "${init_manifest}" \
    ${blocked_command} >/dev/null 2>&1 || blocked_rc=$?
  [[ "${blocked_rc}" -eq 44 ]] || {
    echo "[ERR] Invalid controller manifest bypassed '${blocked_command}': rc=${blocked_rc}" >&2
    exit 1
  }
done
jq -e '
  (.runtime.recovery_points.base.id // "") == ""
  and .phases.base_sync.done == false
  and .phases.cutover.done == false
' "${init_manifest}" >/dev/null

fixture_linux_workdir="${WORK_DIR}/fixture-linux"
"${ROOT_DIR}/bin/ablestack_n2k.sh" \
  --workdir "${fixture_linux_workdir}" \
  --run-id fixture-linux \
  --manifest "${fixture_linux_workdir}/manifest.json" \
  init \
  --vm app-01 \
  --pc pc.example \
  --dst "${WORK_DIR}/fixture-linux-target" \
  --inventory-file "${ROOT_DIR}/tests/fixtures/n2k/inventory/vm_linux.json" \
  --target-format raw \
  --target-storage file >/dev/null
jq -e '
  .runtime.source_validation.status == "passed"
  and .source.controller_plan.root_selection == "controller_unit_fallback"
  and .source.controller_plan.source.controller_kinds == ["scsi"]
  and (.disks | length) == 2
' "${fixture_linux_workdir}/manifest.json" >/dev/null

fixture_bios_workdir="${WORK_DIR}/fixture-v4-bios"
"${ROOT_DIR}/bin/ablestack_n2k.sh" \
  --workdir "${fixture_bios_workdir}" \
  --run-id fixture-v4-bios \
  --manifest "${fixture_bios_workdir}/manifest.json" \
  init \
  --vm centos7-bios-ide \
  --pc pc.example \
  --dst "${WORK_DIR}/fixture-v4-bios-target" \
  --inventory-file "${ROOT_DIR}/tests/fixtures/n2k/inventory/vm_v4_ganges_bios.json" \
  --target-format raw \
  --target-storage file >/dev/null
jq -e '
  .runtime.source_validation.status == "passed"
  and .source.controller_plan.source.controller_kinds == ["ide"]
  and .disks[0].controller.kind == "ide"
' "${fixture_bios_workdir}/manifest.json" >/dev/null

fixture_uefi_workdir="${WORK_DIR}/fixture-v4-uefi"
"${ROOT_DIR}/bin/ablestack_n2k.sh" \
  --workdir "${fixture_uefi_workdir}" \
  --run-id fixture-v4-uefi \
  --manifest "${fixture_uefi_workdir}/manifest.json" \
  init \
  --vm rhel \
  --pc pc.example \
  --dst "${WORK_DIR}/fixture-v4-uefi-target" \
  --inventory-file "${ROOT_DIR}/tests/fixtures/n2k/inventory/vm_v4_ganges_uefi.json" \
  --target-format raw \
  --target-storage file >/dev/null
jq -e '
  .runtime.source_validation.status == "passed"
  and .source.vm.firmware == "efi"
  and .source.vm.secure_boot == true
' "${fixture_uefi_workdir}/manifest.json" >/dev/null

cloud_mixed_manifest="${WORK_DIR}/cloud-mixed.json"
jq -n --argjson inventory "${explicit_boot}" '
  {
    source:{
      vm:$inventory.vm,
      controller_plan:$inventory.controller_plan
    },
    target:{provider:"ablestack-cloud",cloud:{}},
    runtime:{last_error:{code:0,reason:"",ts:""}},
    disks:(
      $inventory.disks
      + [{
          disk_id:"sata-data",
          role:"data",
          size_bytes:32212254720,
          controller:{type:"SATA",kind:"sata",bus:0,unit:1}
        }]
    )
  }
' > "${cloud_mixed_manifest}"

cloud_plan_rc=0
n2k_cloud_target_prepare_disk_controller_plan "${cloud_mixed_manifest}" || cloud_plan_rc=$?
[[ "${cloud_plan_rc}" -eq 44 ]] || {
  echo "[ERR] Cloud mixed data-controller plan did not fail with code 44: rc=${cloud_plan_rc}" >&2
  exit 1
}
jq -e '
  .target.cloud.disk_controller_plan.status == "failed"
  and .target.cloud.disk_controller_plan.failure_reason == "cloud_mixed_data_controller_unsupported"
  and .target.cloud.disk_controller_plan.source.data_kinds == ["sata","scsi"]
  and .runtime.last_error.reason == "cloud_mixed_data_controller_unsupported"
' "${cloud_mixed_manifest}" >/dev/null || {
  echo "[ERR] Cloud mixed data-controller failure was not recorded" >&2
  exit 1
}

cloud_supported_manifest="${WORK_DIR}/cloud-supported.json"
jq -n --argjson inventory "${explicit_boot}" '
  {
    source:{vm:($inventory.vm + {cpu:2,memory_mb:4096}),controller_plan:$inventory.controller_plan},
    target:{provider:"ablestack-cloud",cloud:{cpu_speed:"1000"}},
    runtime:{last_error:{code:0,reason:"",ts:""}},
    disks:$inventory.disks
  }
' > "${cloud_supported_manifest}"
n2k_cloud_target_prepare_disk_controller_plan "${cloud_supported_manifest}"
cloud_params="$(n2k_cloud_target_source_deploy_params_json "${cloud_supported_manifest}")"
jq -e '
  .["details[0].rootDiskController"] == "ide"
  and .["details[0].dataDiskController"] == "scsi"
' <<<"${cloud_params}" >/dev/null || {
  echo "[ERR] Valid Cloud disk-controller plan was not applied to deploy parameters" >&2
  printf '%s\n' "${cloud_params}" >&2
  exit 1
}

stale_cloud_plan_manifest="${WORK_DIR}/cloud-stale-plan.json"
jq '.disks[1].controller = {type:"SATA",kind:"sata",bus:0,unit:1}' \
  "${cloud_supported_manifest}" > "${stale_cloud_plan_manifest}"
if n2k_cloud_target_source_deploy_params_json "${stale_cloud_plan_manifest}" >/dev/null 2>&1; then
  echo "[ERR] Cloud deploy parameters accepted a controller plan that no longer matched the disks" >&2
  exit 1
fi

legacy_mixed_manifest="${WORK_DIR}/legacy-mixed.json"
jq 'del(.source.controller_plan, .target.cloud.disk_controller_plan)' \
  "${cloud_mixed_manifest}" > "${legacy_mixed_manifest}"
if n2k_cloud_target_source_deploy_params_json "${legacy_mixed_manifest}" >/dev/null 2>&1; then
  echo "[ERR] Legacy Cloud manifest silently accepted mixed data controllers" >&2
  exit 1
fi

if n2k_libvirt_disk_controller_plan_is_valid "${legacy_mixed_manifest}"; then
  echo "[ERR] Libvirt accepted an unvalidated mixed-controller manifest" >&2
  exit 1
fi
n2k_libvirt_disk_controller_plan_is_valid "${cloud_supported_manifest}" || {
  echo "[ERR] Libvirt rejected a validated mixed-controller manifest" >&2
  exit 1
}

unsupported_manifest="${WORK_DIR}/unsupported.json"
jq -n --argjson inventory "${unsupported_inventory}" '
  {
    source:{vm:$inventory.vm,controller_plan:$inventory.controller_plan},
    target:{provider:"libvirt",storage:{type:"file"},format:"raw",libvirt:{name:"unsupported"}},
    disks:$inventory.disks
  }
' > "${unsupported_manifest}"
if n2k_libvirt_disk_controller_plan_is_valid "${unsupported_manifest}"; then
  echo "[ERR] Libvirt accepted an unsupported PCI disk controller" >&2
  exit 1
fi
if n2k_disk_bus_from_inventory "pci" >/dev/null 2>&1; then
  echo "[ERR] Unsupported PCI disk controller silently fell back to SCSI" >&2
  exit 1
fi

ambiguous_map_manifest="${WORK_DIR}/ambiguous-map.json"
cat > "${ambiguous_map_manifest}" <<'JSON'
{
  "disks": [
    {"disk_id":"disk-a","device_key":"key-a","nutanix":{"vdisk_uuid":"vdisk-a"},"size_bytes":1024},
    {"disk_id":"disk-b","device_key":"key-b","nutanix":{"vdisk_uuid":"vdisk-b"},"size_bytes":1024}
  ]
}
JSON
[[ "$(n2k_source_manifest_disk_id_for_snapshot_file "${ambiguous_map_manifest}" "vdisk-a" 1024 1)" == "disk-a" ]] || {
  echo "[ERR] Direct Nutanix vDisk UUID mapping failed" >&2
  exit 1
}
[[ -z "$(n2k_source_manifest_disk_id_for_snapshot_file "${ambiguous_map_manifest}" "unknown" 1024 0)" ]] || {
  echo "[ERR] Same-size disks were mapped by ordinal instead of failing closed" >&2
  exit 1
}

truncate -s 1024 "${WORK_DIR}/snapshot-a" "${WORK_DIR}/snapshot-b"
ambiguous_path_index="$(jq -nc \
  --arg first "${WORK_DIR}/snapshot-a" \
  --arg second "${WORK_DIR}/snapshot-b" \
  '{
    disks:{
      "unknown-a":{snapshot_file_path:$first},
      "unknown-b":{snapshot_file_path:$second}
    }
  }')"
n2k_source_nfs_host_from_endpoint() {
  printf '%s' "$1"
}
n2k_source_nfs_uri_from_path() {
  printf '%s' "$2"
}
n2k_source_nfs_mount_uri() {
  printf '%s' "$1"
}
n2k_storage_file_size_bytes() {
  stat -c '%s' "$1"
}
source_map_error="${WORK_DIR}/source-map.err"
if n2k_source_map_from_v3_nfs_path_index \
    "${ambiguous_map_manifest}" "${ambiguous_path_index}" "nfs.example" \
    >"${WORK_DIR}/source-map.json" 2>"${source_map_error}"; then
  echo "[ERR] Incomplete ambiguous NFS source map was accepted" >&2
  exit 1
fi
jq -e '
  .expected_disk_count == 2
  and .snapshot_disk_count == 2
  and .mapped_disk_count == 0
  and .source_map_count == 0
  and (.mapping_errors | length) == 2
' "${source_map_error}" >/dev/null || {
  echo "[ERR] Incomplete NFS source-map diagnostics were not preserved" >&2
  cat "${source_map_error}" >&2
  exit 1
}

unique_map_manifest="${WORK_DIR}/unique-map.json"
jq '.disks[1].size_bytes = 2048' "${ambiguous_map_manifest}" > "${unique_map_manifest}"
[[ "$(n2k_source_manifest_disk_id_for_snapshot_file "${unique_map_manifest}" "unknown" 2048 0)" == "disk-b" ]] || {
  echo "[ERR] Unique-size legacy disk mapping fallback failed" >&2
  exit 1
}

echo "[OK] n2k controller planning and disk identity integrity passed"
