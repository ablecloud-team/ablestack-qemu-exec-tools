#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: $1" >&2
    exit 2
  }
}

require_cmd jq

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/nutanix_api.sh"

inventory_fallback="$(n2k_nutanix_inventory_from_raw '{
  "name": "out-of-order",
  "powerState": "OFF",
  "disks": [
    {
      "extId": "unit-1",
      "sizeBytes": 1073741824000,
      "diskAddress": {"adapter_type": "SCSI", "device_index": 1}
    },
    {
      "extId": "unit-0",
      "sizeBytes": 536870912000,
      "diskAddress": {"adapter_type": "SCSI", "device_index": 0}
    }
  ]
}' "out-of-order")"

jq -e '
  .disks[0].disk_id == "unit-0"
  and .disks[0].controller.unit == 0
  and .disks[0].label == "Disk 1"
  and .disks[0].role == "root"
  and .disks[1].disk_id == "unit-1"
  and .disks[1].controller.unit == 1
  and .disks[1].label == "Disk 2"
  and .disks[1].role == "data"
' <<<"${inventory_fallback}" >/dev/null || {
  echo "[ERR] Nutanix disk inventory was not ordered by controller unit fallback" >&2
  printf '%s\n' "${inventory_fallback}" >&2
  exit 1
}

inventory_boot="$(n2k_nutanix_inventory_from_raw '{
  "name": "boot-address",
  "powerState": "OFF",
  "bootConfig": {
    "bootDevice": {
      "diskAddress": {"busType": "SCSI", "index": 1}
    }
  },
  "disks": [
    {
      "extId": "unit-0",
      "name": "Data disk",
      "sizeBytes": 536870912000,
      "diskAddress": {"busType": "SCSI", "index": 0}
    },
    {
      "extId": "unit-1",
      "name": "Boot disk",
      "sizeBytes": 1073741824000,
      "diskAddress": {"busType": "SCSI", "index": 1}
    }
  ]
}' "boot-address")"

jq -e '
  .disks[0].disk_id == "unit-1"
  and .disks[0].label == "Boot disk"
  and .disks[0].role == "root"
  and .disks[1].disk_id == "unit-0"
  and .disks[1].label == "Data disk"
  and .disks[1].role == "data"
' <<<"${inventory_boot}" >/dev/null || {
  echo "[ERR] Nutanix explicit boot disk address did not take precedence" >&2
  printf '%s\n' "${inventory_boot}" >&2
  exit 1
}

echo "[OK] n2k Nutanix inventory disk ordering passed"
