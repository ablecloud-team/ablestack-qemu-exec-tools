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

n2k_nutanix_request_id() {
  local hex
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr '[:upper:]' '[:lower:]' </proc/sys/kernel/random/uuid
    return 0
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  hex="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s-%s-%s-%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

n2k_nutanix_api_get() {
  local pc="$1" path="$2" username="$3" password="$4" insecure="$5"
  local base connect_timeout max_time
  base="$(n2k_nutanix_pc_base_url "${pc}")"
  connect_timeout="${N2K_NUTANIX_CONNECT_TIMEOUT:-10}"
  max_time="${N2K_NUTANIX_MAX_TIME:-120}"

  local -a args=(--silent --show-error --fail --connect-timeout "${connect_timeout}" --max-time "${max_time}")
  if [[ "${insecure}" == "1" ]]; then
    args+=(--insecure)
  fi
  if [[ -n "${username}" || -n "${password}" ]]; then
    args+=(-u "${username}:${password}")
  fi

  curl "${args[@]}" "${base}${path}"
}

n2k_nutanix_api_request_raw() {
  local method="$1" pc="$2" path="$3" username="$4" password="$5" insecure="$6" body="${7:-}"
  local base tmp_file err_file code rc err_text connect_timeout max_time
  base="$(n2k_nutanix_pc_base_url "${pc}")"
  connect_timeout="${N2K_NUTANIX_CONNECT_TIMEOUT:-10}"
  max_time="${N2K_NUTANIX_MAX_TIME:-120}"
  tmp_file="$(mktemp)"
  err_file="$(mktemp)"

  local -a args=(--silent --show-error --output "${tmp_file}" --write-out "%{http_code}" --connect-timeout "${connect_timeout}" --max-time "${max_time}")
  if [[ "${insecure}" == "1" ]]; then
    args+=(--insecure)
  fi
  if [[ -n "${username}" || -n "${password}" ]]; then
    args+=(-u "${username}:${password}")
  fi
  case "${method}" in
    GET) ;;
    POST) args+=(-X POST -H "Content-Type: application/json" -H "NTNX-Request-Id: $(n2k_nutanix_request_id)" -d "${body}") ;;
    DELETE) args+=(-X DELETE -H "NTNX-Request-Id: $(n2k_nutanix_request_id)") ;;
    *)
      echo "Unsupported HTTP method: ${method}" >&2
      rm -f "${tmp_file}" "${err_file}"
      return 2
      ;;
  esac

  rc=0
  code="$(curl "${args[@]}" "${base}${path}" 2>"${err_file}")" || rc=$?
  err_text="$(cat "${err_file}" 2>/dev/null || true)"
  N2K_NUTANIX_LAST_HTTP_CODE="${code:-000}"
  N2K_NUTANIX_LAST_ERROR="${err_text}"
  export N2K_NUTANIX_LAST_HTTP_CODE N2K_NUTANIX_LAST_ERROR
  cat "${tmp_file}"
  rm -f "${tmp_file}" "${err_file}"
  return "${rc}"
}

n2k_nutanix_api_get_raw() {
  local pc="$1" path="$2" username="$3" password="$4" insecure="$5"
  n2k_nutanix_api_request_raw GET "${pc}" "${path}" "${username}" "${password}" "${insecure}"
}

n2k_nutanix_api_post_raw() {
  local pc="$1" path="$2" username="$3" password="$4" insecure="$5" body="$6"
  n2k_nutanix_api_request_raw POST "${pc}" "${path}" "${username}" "${password}" "${insecure}" "${body}"
}

n2k_nutanix_api_delete_raw() {
  local pc="$1" path="$2" username="$3" password="$4" insecure="$5"
  n2k_nutanix_api_request_raw DELETE "${pc}" "${path}" "${username}" "${password}" "${insecure}"
}

n2k_nutanix_api_request_capture() {
  local method="$1" pc="$2" path="$3" username="$4" password="$5" insecure="$6" body="$7"
  local response_var="$8" status_var="$9" error_var="${10}"
  local base tmp_file err_file code rc err_text connect_timeout max_time
  base="$(n2k_nutanix_pc_base_url "${pc}")"
  connect_timeout="${N2K_NUTANIX_CONNECT_TIMEOUT:-10}"
  max_time="${N2K_NUTANIX_MAX_TIME:-120}"
  tmp_file="$(mktemp)"
  err_file="$(mktemp)"

  local -a args=(--silent --show-error --output "${tmp_file}" --write-out "%{http_code}" --connect-timeout "${connect_timeout}" --max-time "${max_time}")
  if [[ "${insecure}" == "1" ]]; then
    args+=(--insecure)
  fi
  if [[ -n "${username}" || -n "${password}" ]]; then
    args+=(-u "${username}:${password}")
  fi
  case "${method}" in
    GET) ;;
    POST) args+=(-X POST -H "Content-Type: application/json" -H "NTNX-Request-Id: $(n2k_nutanix_request_id)" -d "${body}") ;;
    DELETE) args+=(-X DELETE -H "NTNX-Request-Id: $(n2k_nutanix_request_id)") ;;
    *)
      echo "Unsupported HTTP method: ${method}" >&2
      rm -f "${tmp_file}" "${err_file}"
      return 2
      ;;
  esac

  rc=0
  code="$(curl "${args[@]}" "${base}${path}" 2>"${err_file}")" || rc=$?
  err_text="$(cat "${err_file}" 2>/dev/null || true)"
  printf -v "${response_var}" '%s' "$(cat "${tmp_file}" 2>/dev/null || true)"
  printf -v "${status_var}" '%s' "${code:-000}"
  printf -v "${error_var}" '%s' "${err_text}"
  rm -f "${tmp_file}" "${err_file}"
  return "${rc}"
}

n2k_nutanix_api_get_to_file() {
  local pc="$1" path="$2" username="$3" password="$4" insecure="$5" output_file="$6"
  local status_var="${7:-}" error_var="${8:-}"
  local base err_file code rc err_text connect_timeout max_time
  base="$(n2k_nutanix_pc_base_url "${pc}")"
  connect_timeout="${N2K_NUTANIX_CONNECT_TIMEOUT:-10}"
  max_time="${N2K_NUTANIX_MAX_TIME:-120}"
  err_file="$(mktemp)"

  mkdir -p "$(dirname "${output_file}")"

  local -a args=(--silent --show-error --output "${output_file}" --write-out "%{http_code}" --connect-timeout "${connect_timeout}" --max-time "${max_time}")
  if [[ "${insecure}" == "1" ]]; then
    args+=(--insecure)
  fi
  if [[ -n "${username}" || -n "${password}" ]]; then
    args+=(-u "${username}:${password}")
  fi

  rc=0
  code="$(curl "${args[@]}" "${base}${path}" 2>"${err_file}")" || rc=$?
  err_text="$(cat "${err_file}" 2>/dev/null || true)"
  if [[ -n "${status_var}" ]]; then
    printf -v "${status_var}" '%s' "${code:-000}"
  fi
  if [[ -n "${error_var}" ]]; then
    printf -v "${error_var}" '%s' "${err_text}"
  fi
  rm -f "${err_file}"
  return "${rc}"
}

n2k_nutanix_http_success() {
  [[ "${1:-}" =~ ^2[0-9][0-9]$ ]]
}

n2k_nutanix_http_auth_failure() {
  case "${1:-}" in
    401|403) return 0 ;;
    *) return 1 ;;
  esac
}

n2k_nutanix_v4_candidate_revisions() {
  local namespace="${1:-}"
  case "${namespace}" in
    vmm|dataprotection) printf '%s\n' v4.1 v4.0 ;;
    clustermgmt) printf '%s\n' v4.0 ;;
    *) printf '%s\n' v4.1 v4.0 ;;
  esac
}

n2k_nutanix_v4_probe_path() {
  local namespace="$1" revision="$2"
  case "${namespace}" in
    vmm) printf "/api/vmm/%s/ahv/config/vms?\$limit=1" "${revision}" ;;
    dataprotection) printf "/api/dataprotection/%s/config/recovery-points?\$limit=1" "${revision}" ;;
    clustermgmt) printf "/api/clustermgmt/%s/config/clusters?\$limit=1" "${revision}" ;;
    *)
      echo "Unsupported Nutanix v4 namespace: ${namespace}" >&2
      return 2
      ;;
  esac
}

n2k_nutanix_v4_select_revision() {
  local namespace="$1" pc="$2" username="$3" password="$4" insecure="$5"
  local revision path response http_code api_error
  for revision in $(n2k_nutanix_v4_candidate_revisions "${namespace}"); do
    path="$(n2k_nutanix_v4_probe_path "${namespace}" "${revision}")"
    # shellcheck disable=SC2034 # populated indirectly by n2k_nutanix_api_request_capture
    response=""
    api_error=""
    n2k_nutanix_api_request_capture GET "${pc}" "${path}" \
      "${username}" "${password}" "${insecure}" "" response http_code api_error || true
    if n2k_nutanix_http_auth_failure "${http_code}"; then
      echo "Nutanix ${namespace} ${revision} authentication failed: HTTP ${http_code}" >&2
      return 3
    fi
    if n2k_nutanix_http_success "${http_code}"; then
      printf '%s' "${revision}"
      return 0
    fi
  done
  return 1
}

n2k_nutanix_fetch_v4_vm_list() {
  local pc="$1" username="$2" password="$3" insecure="$4"
  local revision="${5:-}" path
  if [[ -z "${revision}" ]]; then
    revision="$(n2k_nutanix_v4_select_revision vmm "${pc}" "${username}" "${password}" "${insecure}")" || revision="v4.0"
  fi
  path="/api/vmm/${revision}/ahv/config/vms?\$limit=100"
  n2k_nutanix_api_get "${pc}" "${path}" "${username}" "${password}" "${insecure}"
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
        or ((.extId // .ext_id // .metadata.uuid // .uuid // .vm_id // "") == $vm)
      ))
    | .[0] // empty
  '
}

n2k_nutanix_fetch_vm_inventory() {
  local pc="$1" vm="$2" username="$3" password="$4" insecure="$5"
  local list_json vm_json http_code detail_json vm_uuid attempts api_error revision
  local -a attempt_notes=()

  if [[ "${N2K_NUTANIX_INVENTORY_SKIP_V4:-0}" != "1" ]]; then
    for revision in $(n2k_nutanix_v4_candidate_revisions vmm); do
      n2k_nutanix_api_request_capture GET "${pc}" "/api/vmm/${revision}/ahv/config/vms?\$limit=100" "${username}" "${password}" "${insecure}" "" list_json http_code api_error || true
      if n2k_nutanix_http_auth_failure "${http_code}"; then
        echo "Nutanix ${revision} VM list authentication failed: HTTP ${http_code}" >&2
        return 3
      fi
      if n2k_nutanix_http_success "${http_code}"; then
        vm_json="$(n2k_nutanix_select_vm_from_list "${list_json}" "${vm}")"
        if [[ -n "${vm_json}" ]]; then
          printf '%s' "${vm_json}"
          return 0
        fi
        attempt_notes+=("${revision}:http=${http_code}:vm_not_found")
      else
        attempt_notes+=("${revision}:http=${http_code}${api_error:+:${api_error}}")
      fi
    done
  else
    attempt_notes+=("v4:skipped_by_policy")
  fi

  n2k_nutanix_api_request_capture POST "${pc}" "/api/nutanix/v3/vms/list" "${username}" "${password}" "${insecure}" '{"kind":"vm","length":100}' list_json http_code api_error || true
  if n2k_nutanix_http_auth_failure "${http_code}"; then
    echo "Nutanix v3 VM list authentication failed: HTTP ${http_code}" >&2
    return 3
  fi
  if n2k_nutanix_http_success "${http_code}"; then
    vm_json="$(n2k_nutanix_select_vm_from_list "${list_json}" "${vm}")"
    if [[ -n "${vm_json}" ]]; then
      printf '%s' "${vm_json}"
      return 0
    fi
    attempt_notes+=("v3:http=${http_code}:vm_not_found")
  else
    attempt_notes+=("v3:http=${http_code}${api_error:+:${api_error}}")
  fi

  n2k_nutanix_api_request_capture GET "${pc}" "/PrismGateway/services/rest/v2.0/vms" "${username}" "${password}" "${insecure}" "" list_json http_code api_error || true
  if n2k_nutanix_http_auth_failure "${http_code}"; then
    echo "Nutanix v2 VM list authentication failed: HTTP ${http_code}" >&2
    return 3
  fi
  if n2k_nutanix_http_success "${http_code}"; then
    vm_json="$(n2k_nutanix_select_vm_from_list "${list_json}" "${vm}")"
    if [[ -n "${vm_json}" ]]; then
      vm_uuid="$(printf '%s' "${vm_json}" | jq -r '.uuid // .metadata.uuid // empty')"
      if [[ -n "${vm_uuid}" ]]; then
        n2k_nutanix_api_request_capture GET "${pc}" "/PrismGateway/services/rest/v2.0/vms/${vm_uuid}?include_vm_disk_config=true" "${username}" "${password}" "${insecure}" "" detail_json http_code api_error || true
        if n2k_nutanix_http_success "${http_code}" && [[ -n "${detail_json}" ]]; then
          printf '%s' "${detail_json}"
          return 0
        fi
      fi
      printf '%s' "${vm_json}"
      return 0
    fi
    attempt_notes+=("v2:http=${http_code}:vm_not_found")
  else
    attempt_notes+=("v2:http=${http_code}${api_error:+:${api_error}}")
  fi

  attempts="$(IFS='; '; printf '%s' "${attempt_notes[*]}")"
  echo "VM not found in Nutanix API responses: ${vm}; attempts=${attempts}" >&2
  return 4
}

n2k_nutanix_fetch_v4_vm_inventory() {
  n2k_nutanix_fetch_vm_inventory "$@"
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
       // $r.vm_disk_info
       // $r.storageConfig.disks
       // $r.storage_config.disks
       // $r.resources.disk_list
       // $r.status.resources.disk_list
       // [])
      | map(select(
          ((.is_cdrom // false) != true)
          and (((.device_properties.device_type // .deviceProperties.deviceType // .device_type // .deviceType // "DISK") | tostring | ascii_upcase) != "CDROM")
        ));

    def address_bus($a):
      ($a.busType // $a.bus_type // $a.adapter_type // $a.device_bus // "" | tostring | ascii_downcase);

    def address_unit($a; $fallback):
      (($a.index // $a.deviceIndex // $a.device_index // $a.deviceIndex // $fallback) | tonumber? // $fallback);

    def controller_rank($type):
      ($type | tostring | ascii_downcase) as $t
      | if $t == "scsi" then 0
        elif $t == "virtio" then 1
        elif $t == "sata" then 2
        elif $t == "ide" then 3
        elif $t == "pci" then 4
        else 9 end;

    def boot_disk_address($r):
      ($r.bootConfig.bootDevice.diskAddress
       // $r.bootConfig.boot_device.disk_address
       // $r.boot_config.bootDevice.diskAddress
       // $r.boot_config.boot_device.disk_address
       // $r.resources.boot_config.boot_device.disk_address
       // $r.status.resources.boot_config.boot_device.disk_address
       // {});

    def boot_disk_match($disk; $boot):
      if (($boot | type) != "object") or (($boot | length) == 0) then false
      else
        (address_bus($boot)) as $boot_bus
        | (address_unit($boot; -1)) as $boot_unit
        | (($disk.controller.type // "" | tostring | ascii_downcase) == $boot_bus
           and (($disk.controller.unit // -2) == $boot_unit))
      end;

    def nic_items($r):
      ($r.nics
       // $r.nic_list
       // $r.vm_nics
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
        // $r.num_vcpus
        // $r.numSockets
        // $r.num_sockets
        // $r.resources.num_vcpus_per_socket
        // $r.status.resources.num_vcpus_per_socket
        // 0) | tonumber? // 0) as $base
      | (($r.numCoresPerSocket
          // $r.num_cores_per_socket
          // $r.num_cores_per_vcpu
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
      if (($r.boot.uefi_boot // false) == true) then "efi"
      else
        ($r.bootConfig["$objectType"] // $r.boot_config["$objectType"] // "") as $boot_object_type
        | if (($boot_object_type | tostring) | test("UefiBoot|UEFI"; "i")) then "efi"
          elif (($boot_object_type | tostring) | test("LegacyBoot|LEGACY|BIOS"; "i")) then "bios"
          else
        (first_nonempty([
          $r.bootConfig.bootType,
          $r.boot_config.boot_type,
          $r.bootConfig.boot_type,
          $r.resources.boot_config.boot_type,
          $r.status.resources.boot_config.boot_type
        ]) | ascii_downcase) as $fw
        | if ($fw | test("uefi|efi|secure")) then "efi"
          elif ($fw | test("legacy|bios")) then "bios"
          else "" end
          end
      end;

    def disk_id($d; $idx):
      ($d.diskAddress // $d.disk_address // $d.device_properties.disk_address // $d.deviceProperties.diskAddress // {}) as $a
      | first_nonempty([
          $d.disk_id,
          $d.diskId,
          $d.extId,
          $d.ext_id,
          $d.uuid,
          $d.device_uuid,
          $d.vdiskUuid,
          $d.vdisk_uuid,
          $d.backingInfo.diskExtId,
          $d.backing_info.disk_ext_id,
          $a.device_uuid,
          $a.vmdisk_uuid,
          (if ($a.busType // $a.bus_type // $a.adapter_type // $a.device_bus // "") != "" then
            (($a.busType // $a.bus_type // $a.adapter_type // $a.device_bus | tostring | ascii_downcase) + "0:" + (($a.index // $a.deviceIndex // $a.device_index // $a.deviceIndex // $idx) | tostring))
          else "" end)
        ]) as $id
      | if $id != "" then $id else ("disk" + ($idx | tostring)) end;

    def disk_size($d):
      if (($d.sizeBytes
           // $d.size_bytes
           // $d.diskSizeBytes
           // $d.disk_size_bytes
           // $d.capacityBytes
           // $d.capacity_bytes
           // $d.backingInfo.diskSizeBytes
           // $d.backing_info.disk_size_bytes
           // $d.backingInfo.sizeBytes
           // $d.backing_info.size_bytes
           // $d.size
           // null) != null) then
        (($d.sizeBytes
          // $d.size_bytes
          // $d.diskSizeBytes
          // $d.disk_size_bytes
          // $d.capacityBytes
          // $d.capacity_bytes
          // $d.backingInfo.diskSizeBytes
          // $d.backing_info.disk_size_bytes
          // $d.backingInfo.sizeBytes
          // $d.backing_info.size_bytes
          // $d.size) | tonumber? // 0)
      elif (($d.disk_size_mib // $d.size_mib // null) != null) then
        ((($d.disk_size_mib // $d.size_mib) | tonumber? // 0) * 1048576)
      else
        0
      end;

    def normalize_disk($d; $idx):
      ($d.diskAddress // $d.disk_address // $d.device_properties.disk_address // $d.deviceProperties.diskAddress // {}) as $a
      | first_nonempty([$d.name, $d.label, $a.disk_label]) as $disk_label
      | {
          disk_id: disk_id($d; $idx),
          label: $disk_label,
          source_ordinal: $idx,
          device_key: first_nonempty([$d.extId, $d.ext_id, $d.uuid, $d.device_uuid, $d.vdiskUuid, $d.vdisk_uuid, $a.device_uuid, $a.vmdisk_uuid, ($idx | tostring)]),
          controller: {
            type: first_nonempty([$a.busType, $a.bus_type, $a.adapter_type, $a.device_bus, $d.busType, $d.bus_type, "scsi"]),
            bus: (($a.bus // $a.busNumber // $a.bus_number // 0) | tonumber? // 0),
            unit: (($a.index // $a.deviceIndex // $a.device_index // $a.deviceIndex // $d.unit // $d.unitNumber // $idx) | tonumber? // $idx),
            label: first_nonempty([$a.disk_label, $a.busType, $a.bus_type, $a.adapter_type, $a.device_bus, $d.busType, $d.bus_type, ""])
          },
          nutanix: {
            ext_id: first_nonempty([$d.extId, $d.ext_id, $d.uuid]),
            vdisk_uuid: first_nonempty([$d.vdiskUuid, $d.vdisk_uuid, $d.uuid, $d.backingInfo.diskExtId, $d.backing_info.disk_ext_id, $d.backingInfo.vdiskUuid, $d.backing_info.vdisk_uuid, $a.vmdisk_uuid, $a.device_uuid]),
            disk_address: $a,
            storage_container_ext_id: first_nonempty([$d.storageContainerExtId, $d.storage_container_ext_id, $d.storage_container_uuid, $d.backingInfo.storageContainerExtId, $d.backingInfo.storageContainer.extId, $d.backing_info.storage_container_ext_id, $d.backing_info.storage_container.ext_id, $d.storage_config.storage_container_reference.uuid])
          },
          size_bytes: disk_size($d)
        };

    def ordered_disks($r):
      (boot_disk_address($r)) as $boot_addr
      | (disk_items($r) | to_entries | map(normalize_disk(.value; .key)))
      | sort_by([
          (if boot_disk_match(.; $boot_addr) then 0 else 1 end),
          controller_rank(.controller.type // ""),
          (.controller.bus // 0),
          (.controller.unit // 0),
          (.source_ordinal // 0)
        ])
      | to_entries
      | map(
          . as $entry
          | .value
          | .label = (if ((.label // "") | tostring | length) > 0 then .label else ("Disk " + (($entry.key + 1) | tostring)) end)
          | .role = (if $entry.key == 0 then "root" else "data" end)
        );

    def normalize_nic($n; $idx):
      {
        key: ($idx | tostring),
        ext_id: first_nonempty([$n.extId, $n.ext_id, $n.uuid]),
        mac: first_nonempty([$n.macAddress, $n.mac_address, $n.mac, $n.backingInfo.macAddress, $n.backing_info.mac_address]),
        network: first_nonempty([$n.subnet.name, $n.subnet_reference.name, $n.subnetName, $n.subnet_name, $n.networkName, $n.network_name, $n.networkInfo.subnet.name, $n.networkInfo.subnet.extId, $n.network_info.subnet.ext_id])
      };

    (vm_root) as $r
    | {
        vm: {
          name: first_nonempty([$r.name, $r.spec.name, $r.status.name, $r.vm.name, $vm_arg]),
          ext_id: first_nonempty([$r.extId, $r.ext_id, $r.metadata.uuid, $r.uuid, $r.vm.ext_id]),
          uuid: first_nonempty([$r.uuid, $r.metadata.uuid, $r.extId, $r.ext_id, $r.vm.uuid]),
          power_state: power_state($r),
          firmware: firmware($r),
          secure_boot: (
            ($r.secureBoot // $r.secure_boot // $r.bootConfig.isSecureBootEnabled // $r.boot_config.is_secure_boot_enabled // $r.resources.secure_boot // null) as $secure
            | if ($secure | type) == "boolean" then $secure
              else
                (first_nonempty([
                  $r.bootConfig.bootType,
                  $r.boot_config.boot_type,
                  $r.resources.boot_config.boot_type,
                  $r.status.resources.boot_config.boot_type
                ]) | ascii_downcase | test("secure"))
              end
          ),
          tpm: (($r.tpmPresent // $r.tpm_present // $r.vtpmConfig.isVtpmEnabled // $r.vtpm_config.is_vtpm_enabled // $r.resources.tpm_present // false) | if type == "boolean" then . else false end),
          cpu: cpu_count($r),
          memory_mb: memory_mb($r),
          nics: (nic_items($r) | to_entries | map(normalize_nic(.value; .key))),
          guestId: first_nonempty([$r.guestCustomization.guestOs, $r.guest_customization.guest_os, $r.guestTools.guestOs, $r.guest_tools.guest_os]),
          guestFamily: first_nonempty([$r.guestFamily, $r.guest_family])
        },
        disks: ordered_disks($r)
      }
  '
}
