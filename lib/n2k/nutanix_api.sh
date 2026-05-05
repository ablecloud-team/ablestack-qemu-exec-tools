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

n2k_nutanix_pc_base_url() {
  local pc="$1"
  if [[ "${pc}" =~ ^https?:// ]]; then
    printf '%s' "${pc%/}"
  else
    printf 'https://%s:9440' "${pc}"
  fi
}

n2k_nutanix_load_cred_file() {
  local file="$1"
  [[ -f "${file}" ]] || {
    echo "Credential file not found: ${file}" >&2
    return 2
  }
  set -a
  # shellcheck source=/dev/null
  source "${file}"
  set +a
}

n2k_nutanix_curl_auth_args() {
  local username="${1:-}" password="${2:-}"
  if [[ -n "${username}" || -n "${password}" ]]; then
    printf '%s\n' "-u" "${username}:${password}"
  fi
}

n2k_nutanix_api_get() {
  local pc="$1" path="$2" username="$3" password="$4" insecure="$5"
  local base
  base="$(n2k_nutanix_pc_base_url "${pc}")"

  local -a args=(--silent --show-error --fail)
  if [[ "${insecure}" == "1" ]]; then
    args+=(--insecure)
  fi
  if [[ -n "${username}" || -n "${password}" ]]; then
    args+=(-u "${username}:${password}")
  fi

  curl "${args[@]}" "${base}${path}"
}

n2k_nutanix_fetch_v4_vm_list() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  n2k_nutanix_api_get "${pc}" "/api/vmm/v4.0/ahv/config/vms?\$limit=100" "${username}" "${password}" "${insecure}"
}

n2k_nutanix_select_vm_from_list() {
  local raw_json="$1" vm="$2"
  printf '%s' "${raw_json}" | jq -c --arg vm "${vm}" '
    def items:
      if (.data | type) == "array" then .data
      elif (.entities | type) == "array" then .entities
      elif (.metadata.entities | type) == "array" then .metadata.entities
      else [] end;

    items
    | map(select(
        ((.name // .spec.name // .status.name // "") == $vm)
        or ((.extId // .ext_id // .metadata.uuid // .uuid // "") == $vm)
      ))
    | .[0] // empty
  '
}

n2k_nutanix_fetch_v4_vm_inventory() {
  local pc="$1" vm="$2" username="$3" password="$4" insecure="$5"
  local list_json vm_json
  list_json="$(n2k_nutanix_fetch_v4_vm_list "${pc}" "${username}" "${password}" "${insecure}")"
  vm_json="$(n2k_nutanix_select_vm_from_list "${list_json}" "${vm}")"
  [[ -n "${vm_json}" ]] || {
    echo "VM not found in v4 VM list response: ${vm}" >&2
    return 4
  }
  printf '%s' "${vm_json}"
}

n2k_nutanix_load_inventory_json_arg() {
  local value="${1:-}"
  [[ -n "${value}" ]] || return 1
  if [[ -f "${value}" ]]; then
    jq -c . "${value}"
  else
    printf '%s' "${value}" | jq -c .
  fi
}

n2k_nutanix_inventory_from_raw() {
  local raw_json="$1" vm_arg="${2:-}"
  printf '%s' "${raw_json}" | jq -c --arg vm_arg "${vm_arg}" '
    def first_nonempty(xs):
      reduce xs[] as $x (""; if . != "" then . elif ($x // "") != "" then ($x | tostring) else . end);

    def bytes_to_mib($v):
      (($v // 0) | tonumber? // 0) / 1048576 | floor;

    def vm_root:
      if (.data | type) == "object" then .data
      elif (.vm | type) == "object" and (.disks | type) == "array" then .
      elif (.spec | type) == "object" or (.status | type) == "object" then .
      else . end;

    def disk_items($r):
      ($r.disks
       // $r.disk_list
       // $r.storageConfig.disks
       // $r.storage_config.disks
       // $r.resources.disk_list
       // $r.status.resources.disk_list
       // []);

    def nic_items($r):
      ($r.nics
       // $r.nic_list
       // $r.networkInterfaces
       // $r.network_interfaces
       // $r.resources.nic_list
       // $r.status.resources.nic_list
       // []);

    def power_state($r):
      first_nonempty([
        $r.powerState,
        $r.power_state,
        $r.status.powerState,
        $r.status.resources.power_state,
        $r.resources.power_state
      ]);

    def cpu_count($r):
      (($r.numCpus
        // $r.num_cpus
        // $r.numSockets
        // $r.num_sockets
        // $r.resources.num_vcpus_per_socket
        // $r.status.resources.num_vcpus_per_socket
        // 0) | tonumber? // 0) as $base
      | (($r.numCoresPerSocket
          // $r.num_cores_per_socket
          // $r.resources.num_sockets
          // $r.status.resources.num_sockets
          // 1) | tonumber? // 1) as $mult
      | if $base > 0 then ($base * $mult) else 0 end;

    def memory_mb($r):
      if (($r.memorySizeBytes // $r.memory_size_bytes // null) != null) then
        bytes_to_mib($r.memorySizeBytes // $r.memory_size_bytes)
      else
        (($r.memorySizeMib
          // $r.memory_size_mib
          // $r.memoryMb
          // $r.memory_mb
          // $r.resources.memory_size_mib
          // $r.status.resources.memory_size_mib
          // 0) | tonumber? // 0)
      end;

    def firmware($r):
      (first_nonempty([
        $r.bootConfig.bootType,
        $r.boot_config.boot_type,
        $r.resources.boot_config.boot_type,
        $r.status.resources.boot_config.boot_type
      ]) | ascii_downcase) as $fw
      | if ($fw | test("uefi|efi")) then "efi"
        elif ($fw | test("legacy|bios")) then "bios"
        else "" end;

    def disk_id($d; $idx):
      ($d.diskAddress // $d.disk_address // {}) as $a
      | first_nonempty([
          $d.disk_id,
          $d.diskId,
          $d.extId,
          $d.ext_id,
          $d.vdiskUuid,
          $d.vdisk_uuid,
          (if ($a.busType // $a.bus_type // "") != "" then
            (($a.busType // $a.bus_type | tostring | ascii_downcase) + "0:" + (($a.index // $a.deviceIndex // $a.device_index // $idx) | tostring))
          else "" end)
        ]) as $id
      | if $id != "" then $id else ("disk" + ($idx | tostring)) end;

    def disk_size($d):
      ($d.sizeBytes
       // $d.size_bytes
       // $d.diskSizeBytes
       // $d.disk_size_bytes
       // $d.capacityBytes
       // $d.capacity_bytes
       // $d.backingInfo.sizeBytes
       // $d.backing_info.size_bytes
       // 0) | tonumber? // 0;

    def normalize_disk($d; $idx):
      ($d.diskAddress // $d.disk_address // {}) as $a
      | {
          disk_id: disk_id($d; $idx),
          label: first_nonempty([$d.name, $d.label, ("Disk " + (($idx + 1) | tostring))]),
          device_key: first_nonempty([$d.extId, $d.ext_id, $d.vdiskUuid, $d.vdisk_uuid, ($idx | tostring)]),
          controller: {
            type: first_nonempty([$a.busType, $a.bus_type, $d.busType, $d.bus_type, "scsi"]),
            bus: (($a.bus // $a.busNumber // $a.bus_number // 0) | tonumber? // 0),
            unit: (($a.index // $a.deviceIndex // $a.device_index // $d.unit // $d.unitNumber // $idx) | tonumber? // $idx),
            label: first_nonempty([$a.busType, $a.bus_type, $d.busType, $d.bus_type, ""])
          },
          nutanix: {
            ext_id: first_nonempty([$d.extId, $d.ext_id]),
            vdisk_uuid: first_nonempty([$d.vdiskUuid, $d.vdisk_uuid, $d.backingInfo.vdiskUuid, $d.backing_info.vdisk_uuid]),
            disk_address: $a,
            storage_container_ext_id: first_nonempty([$d.storageContainerExtId, $d.storage_container_ext_id, $d.backingInfo.storageContainerExtId, $d.backing_info.storage_container_ext_id])
          },
          size_bytes: disk_size($d)
        };

    def normalize_nic($n; $idx):
      {
        key: ($idx | tostring),
        ext_id: first_nonempty([$n.extId, $n.ext_id, $n.uuid]),
        mac: first_nonempty([$n.macAddress, $n.mac_address, $n.mac]),
        network: first_nonempty([$n.subnet.name, $n.subnetName, $n.subnet_name, $n.networkName, $n.network_name])
      };

    (vm_root) as $r
    | {
        vm: {
          name: first_nonempty([$r.name, $r.spec.name, $r.status.name, $r.vm.name, $vm_arg]),
          ext_id: first_nonempty([$r.extId, $r.ext_id, $r.metadata.uuid, $r.uuid, $r.vm.ext_id]),
          uuid: first_nonempty([$r.uuid, $r.metadata.uuid, $r.extId, $r.ext_id, $r.vm.uuid]),
          power_state: power_state($r),
          firmware: firmware($r),
          secure_boot: (($r.secureBoot // $r.secure_boot // $r.resources.secure_boot // false) | if type == "boolean" then . else false end),
          tpm: (($r.tpmPresent // $r.tpm_present // $r.resources.tpm_present // false) | if type == "boolean" then . else false end),
          cpu: cpu_count($r),
          memory_mb: memory_mb($r),
          nics: (nic_items($r) | to_entries | map(normalize_nic(.value; .key))),
          guestId: first_nonempty([$r.guestCustomization.guestOs, $r.guest_customization.guest_os, $r.guestTools.guestOs, $r.guest_tools.guest_os]),
          guestFamily: first_nonempty([$r.guestFamily, $r.guest_family])
        },
        disks: (disk_items($r) | to_entries | map(normalize_disk(.value; .key)))
      }
  '
}
