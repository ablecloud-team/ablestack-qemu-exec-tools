#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/v2k_inventory_disk_order_smoke"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: $1" >&2
    exit 2
  }
}

cleanup() {
  rm -rf "${WORK_DIR}"
}

require_cmd jq
trap cleanup EXIT
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/vmware_govc.sh"

fake_govc="${WORK_DIR}/govc"
cat > "${fake_govc}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "vm.info -json demo-vm")
    cat "${V2K_TEST_VM_INFO_JSON}"
    ;;
  "device.info -json -vm demo-vm")
    cat "${V2K_TEST_DEVICE_INFO_JSON}"
    ;;
  "host.info -json -host host-11")
    cat "${V2K_TEST_HOST_INFO_JSON}"
    ;;
  *)
    echo "unexpected govc call: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "${fake_govc}"

host_info="${WORK_DIR}/host.info.json"
cat > "${host_info}" <<'JSON'
{
  "hostSystems": [
    {
      "summary": {
        "config": {
          "name": "192.0.2.10",
          "product": {"version": "7.0.3"},
          "sslThumbprint": "AA:BB:CC"
        }
      },
      "config": {
        "product": {"version": "7.0.3"}
      }
    }
  ]
}
JSON

write_vm_info() {
  local path="$1" boot_order="$2"
  if [[ "${boot_order}" == "unit1" ]]; then
    cat > "${path}" <<'JSON'
{
  "virtualMachines": [
    {
      "self": {"value": "vm-101"},
      "config": {
        "uuid": "demo-vm-uuid",
        "guestId": "ubuntu64Guest",
        "firmware": "bios",
        "bootOptions": {
          "bootOrder": [
            {"deviceKey": 2001}
          ]
        },
        "hardware": {
          "numCPU": 2,
          "memoryMB": 4096,
          "device": [
            {
              "key": 4000,
              "deviceInfo": {"label": "Network adapter 1"},
              "macAddress": "52:54:00:12:34:56"
            }
          ]
        }
      },
      "guest": {"guestFamily": "linuxGuest"},
      "runtime": {"host": {"value": "host-11"}}
    }
  ]
}
JSON
  else
    cat > "${path}" <<'JSON'
{
  "virtualMachines": [
    {
      "self": {"value": "vm-101"},
      "config": {
        "uuid": "demo-vm-uuid",
        "guestId": "ubuntu64Guest",
        "firmware": "bios",
        "bootOptions": {},
        "hardware": {
          "numCPU": 2,
          "memoryMB": 4096,
          "device": [
            {
              "key": 4000,
              "deviceInfo": {"label": "Network adapter 1"},
              "macAddress": "52:54:00:12:34:56"
            }
          ]
        }
      },
      "guest": {"guestFamily": "linuxGuest"},
      "runtime": {"host": {"value": "host-11"}}
    }
  ]
}
JSON
  fi
}

device_info="${WORK_DIR}/device.info.json"
cat > "${device_info}" <<'JSON'
{
  "devices": [
    {
      "key": 1000,
      "type": "VirtualLsiLogicController",
      "busNumber": 0,
      "deviceInfo": {"label": "SCSI controller 0"}
    },
    {
      "key": 2001,
      "type": "VirtualDisk",
      "controllerKey": 1000,
      "unitNumber": 1,
      "deviceInfo": {"label": "Hard disk 2"},
      "backing": {"fileName": "[datastore1] demo-vm/demo-vm_1.vmdk"},
      "capacityInBytes": 1073741824000
    },
    {
      "key": 2000,
      "type": "VirtualDisk",
      "controllerKey": 1000,
      "unitNumber": 0,
      "deviceInfo": {"label": "Hard disk 1"},
      "backing": {"fileName": "[datastore1] demo-vm/demo-vm.vmdk"},
      "capacityInBytes": 536870912000
    }
  ]
}
JSON

export V2K_GOVC_BIN="${fake_govc}"
export V2K_TEST_DEVICE_INFO_JSON="${device_info}"
export V2K_TEST_HOST_INFO_JSON="${host_info}"
export GOVC_URL="https://vc.example.local/sdk"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD="dummy-password"
export GOVC_INSECURE="1"

vm_info_no_boot="${WORK_DIR}/vm.no-boot.json"
write_vm_info "${vm_info_no_boot}" "none"
export V2K_TEST_VM_INFO_JSON="${vm_info_no_boot}"
inventory_fallback="$(v2k_vmware_inventory_json "demo-vm" "vc.example.local")"

jq -e '
  .disks[0].disk_id == "scsi0:0"
  and .disks[0].device_key == "2000"
  and .disks[0].role == "root"
  and .disks[1].disk_id == "scsi0:1"
  and .disks[1].device_key == "2001"
  and .disks[1].role == "data"
' <<<"${inventory_fallback}" >/dev/null || {
  echo "[ERR] VMware disk inventory was not ordered by controller address fallback" >&2
  printf '%s\n' "${inventory_fallback}" >&2
  exit 1
}

vm_info_boot_unit1="${WORK_DIR}/vm.boot-unit1.json"
write_vm_info "${vm_info_boot_unit1}" "unit1"
export V2K_TEST_VM_INFO_JSON="${vm_info_boot_unit1}"
inventory_boot="$(v2k_vmware_inventory_json "demo-vm" "vc.example.local")"

jq -e '
  .disks[0].disk_id == "scsi0:1"
  and .disks[0].device_key == "2001"
  and .disks[0].role == "root"
  and .disks[1].disk_id == "scsi0:0"
  and .disks[1].device_key == "2000"
  and .disks[1].role == "data"
' <<<"${inventory_boot}" >/dev/null || {
  echo "[ERR] VMware explicit boot disk order did not take precedence" >&2
  printf '%s\n' "${inventory_boot}" >&2
  exit 1
}

echo "[OK] v2k VMware inventory disk ordering passed"
