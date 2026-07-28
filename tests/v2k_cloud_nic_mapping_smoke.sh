#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/v2k-cloud-nic-mapping.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/cloudstack_api.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/target_cloud.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/interactive.sh"

manifest="${WORK_DIR}/manifest.json"
cat > "${manifest}" <<'JSON'
{
  "source": {
    "vm": {
      "name": "two-nic-vm",
      "cpu": 2,
      "memory_mb": 4096,
      "firmware": "bios",
      "nics": [
        {
          "key": 4000,
          "label": "Network adapter 1",
          "mac": "52:54:00:12:34:56",
          "network": "VM Network"
        },
        {
          "key": 4001,
          "label": "Network adapter 2",
          "mac": "52:54:00:65:43:20",
          "network": "Backup Network"
        }
      ]
    }
  },
  "target": {
    "provider": "ablestack-cloud",
    "cloud": {
      "zone_id": "zone-1",
      "service_offering_id": "offering-1",
      "network_ids": ["network-a", "network-b"],
      "storage_id": "storage-1",
      "name": "two-nic-vm",
      "display_name": "two-nic-vm",
      "cpu_speed": "1000"
    }
  },
  "runtime": {},
  "disks": [
    {
      "disk_id": "scsi0:0",
      "size_bytes": 10737418240,
      "controller": {"type": "VirtualLsiLogicController"}
    }
  ]
}
JSON

v2k_cloud_target_ensure_manifest_nic_mappings "${manifest}"
jq -e '
  .target.cloud.nic_mappings == [
    {
      source_index: 0,
      source_key: "4000",
      source_label: "Network adapter 1",
      source_network: "VM Network",
      mac: "52:54:00:12:34:56",
      network_id: "network-a",
      default: true
    },
    {
      source_index: 1,
      source_key: "4001",
      source_label: "Network adapter 2",
      source_network: "Backup Network",
      mac: "52:54:00:65:43:20",
      network_id: "network-b",
      default: false
    }
  ]
' "${manifest}" >/dev/null

cfg="$(v2k_cloud_target_required_config_json "${manifest}")"
nic_params="$(v2k_cloud_target_nic_request_params_json "${cfg}")"
jq -e '
  .["iptonetworklist[0].networkid"] == "network-a"
  and .["iptonetworklist[0].mac"] == "52:54:00:12:34:56"
  and .["iptonetworklist[1].networkid"] == "network-b"
  and .["iptonetworklist[1].mac"] == "52:54:00:65:43:20"
' <<<"${nic_params}" >/dev/null

source_params="$(v2k_cloud_target_source_deploy_params_json "${manifest}")"
deploy_params="$(v2k_cloud_target_deploy_params_json \
  "${cfg}" "root-volume-1" "false" \
  "$(jq -c '. + {macaddress:"52:54:00:ff:ff:fe"}' <<<"${source_params}")")"
jq -e '
  (has("networkids") | not)
  and (has("macaddress") | not)
  and .["iptonetworklist[0].networkid"] == "network-a"
  and .["iptonetworklist[0].mac"] == "52:54:00:12:34:56"
  and .["iptonetworklist[1].networkid"] == "network-b"
  and .["iptonetworklist[1].mac"] == "52:54:00:65:43:20"
  and .startvm == "false"
' <<<"${deploy_params}" >/dev/null

query="$(v2k_cloud_params_query "${nic_params}")"
[[ "${query}" == *"iptonetworklist[0].mac=52%3A54%3A00%3A12%3A34%3A56"* ]]
[[ "${query}" == *"iptonetworklist[1].networkid=network-b"* ]]

actual_vm='{
  "id": "vm-1",
  "nic": [
    {"networkid": "network-a", "macaddress": "52:54:00:12:34:56", "isdefault": true},
    {"networkid": "network-b", "macaddress": "52:54:00:65:43:20", "isdefault": false}
  ]
}'
verification="$(v2k_cloud_target_verify_vm_nics_json "${cfg}" "${actual_vm}")"
jq -e '.matched == true and (.checks | all(.matched))' <<<"${verification}" >/dev/null

bad_actual_vm="$(jq '.nic[1].macaddress = "52:54:00:ff:ff:fe"' <<<"${actual_vm}")"
bad_verification="$(v2k_cloud_target_verify_vm_nics_json "${cfg}" "${bad_actual_vm}")"
jq -e '.matched == false and (.checks[1].matched == false)' <<<"${bad_verification}" >/dev/null

v2k_cloud_target_vm_json() {
  printf '%s' "${bad_actual_vm}"
}
export V2K_CLOUD_NIC_VERIFY_ATTEMPTS=1
export V2K_CLOUD_NIC_VERIFY_INTERVAL=0
if wait_failure="$(v2k_cloud_target_wait_for_vm_nic_match \
    "endpoint" "api-key" "secret-key" "${cfg}" "vm-1" 2>/dev/null)"; then
  echo "[ERR] Post-deploy NIC mismatch was accepted" >&2
  exit 1
fi
jq -e '.matched == false' <<<"${wait_failure}" >/dev/null
unset V2K_CLOUD_NIC_VERIFY_ATTEMPTS V2K_CLOUD_NIC_VERIFY_INTERVAL

inventory_json="$(jq -c '{vm:{nics:.source.vm.nics}}' "${manifest}")"
choices=$'network-a\tNetwork A\tL2\nnetwork-b\tNetwork B\tL2'
selected_networks="$(
  # shellcheck disable=SC2317
  v2k_interactive_has_tty() { return 0; }
  v2k_interactive_select_cloud_networks_for_nics \
    "${inventory_json}" "${choices}" 0 <<<"1"
)"
[[ "${selected_networks}" == "network-a,network-b" ]]

if (
  # shellcheck disable=SC2317
  v2k_interactive_select_tsv() { return 2; }
  v2k_interactive_select_cloud_networks_for_nics \
    "${inventory_json}" "${choices}" 0 >/dev/null 2>&1
); then
  echo "[ERR] Cloud network selection failure was ignored" >&2
  exit 1
fi

mismatch_manifest="${WORK_DIR}/mismatch.json"
jq '.target.cloud.network_ids = ["network-a"]' "${manifest}" > "${mismatch_manifest}"
if v2k_cloud_target_ensure_manifest_nic_mappings "${mismatch_manifest}" >/dev/null 2>&1; then
  echo "[ERR] NIC/network count mismatch was accepted" >&2
  exit 1
fi

duplicate_network_manifest="${WORK_DIR}/duplicate-network.json"
jq '.target.cloud.network_ids = ["network-a", "network-a"]' \
  "${manifest}" > "${duplicate_network_manifest}"
if v2k_cloud_target_ensure_manifest_nic_mappings "${duplicate_network_manifest}" >/dev/null 2>&1; then
  echo "[ERR] Duplicate Cloud networks were accepted" >&2
  exit 1
fi

invalid_mac_manifest="${WORK_DIR}/invalid-mac.json"
jq '.source.vm.nics[1].mac = "53:54:00:65:43:20"' \
  "${manifest}" > "${invalid_mac_manifest}"
if v2k_cloud_target_ensure_manifest_nic_mappings "${invalid_mac_manifest}" >/dev/null 2>&1; then
  echo "[ERR] Non-unicast source MAC was accepted" >&2
  exit 1
fi

echo "[OK] v2k Cloud multi-NIC mapping and MAC preservation helpers passed"
