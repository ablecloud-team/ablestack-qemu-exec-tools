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
#
# govc is used as primary integration for:
# - inventory
# - snapshot create/remove
# - CBT enable (via extraConfig)
#
# Changed areas query is done via python helper (pyvmomi), invoked in transfer_patch.sh.
# ---------------------------------------------------------------------

set -euo pipefail

V2K_ROOT_DIR="${V2K_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
V2K_LIB_DIR="${V2K_LIB_DIR:-${V2K_ROOT_DIR}/lib/v2k}"
if [[ ! -f "${V2K_LIB_DIR}/compat.sh" ]]; then
  V2K_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  V2K_LIB_DIR="${V2K_ROOT_DIR}/lib/ablestack-qemu-exec-tools/v2k"
fi
# shellcheck source=/dev/null
source "${V2K_LIB_DIR}/compat.sh"

# -----------------------------------------------------------------------------
# Physical size helpers (VMDK actual/physical size)
#
# govc datastore.ls -l "[datastore] path/to.vmdk"
#   4.7GB  Thu Feb 5 15:13:25 2026  utest1.vmdk
#
# We parse the first token (human size) and convert to bytes.
# -----------------------------------------------------------------------------

v2k_vmware__human_to_bytes() {
  # Input examples: 4.7GB, 512MB, 1023KB, 123B
  # Output: integer bytes (best-effort; uses binary 1024 units)
  local s="${1-}"
  [[ -n "${s}" ]] || { echo 0; return 0; }

  # split number and unit (case-insensitive)
  local num unit
  num="$(printf '%s' "${s}" | sed -E 's/^[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/' | tr -d '[:space:]')"
  unit="$(printf '%s' "${s}" | sed -E 's/^[[:space:]]*[0-9]+(\.[0-9]+)?([A-Za-z]+).*/\2/I' | tr -d '[:space:]')"
  unit="$(printf '%s' "${unit}" | tr '[:lower:]' '[:upper:]')"

  # If parsing failed, return 0
  [[ "${num}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo 0; return 0; }

  # Default unit
  [[ -n "${unit}" && "${unit}" != "${s}" ]] || unit="B"

  # Convert using awk to handle decimals, then integer-cast.
  awk -v n="${num}" -v u="${unit}" '
    function pow1024(e,    i,r){ r=1; for(i=0;i<e;i++) r*=1024; return r }
    BEGIN{
      m=1
      if(u=="B") m=1
      else if(u=="KB") m=pow1024(1)
      else if(u=="MB") m=pow1024(2)
      else if(u=="GB") m=pow1024(3)
      else if(u=="TB") m=pow1024(4)
      else if(u=="PB") m=pow1024(5)
      else m=1
      # integer bytes (truncate)
      printf "%.0f", (n*m)
    }'
}

v2k_vmware_datastore_vmdk_physical_bytes() {
  # Args: "<[datastore] path/to.vmdk>"
  # Returns: physical bytes (integer) or 0 on failure
  local ds_path="${1-}"
  [[ -n "${ds_path}" ]] || { echo 0; return 0; }

  v2k_has_govc_bin || { echo 0; return 0; }

  # Ensure govc is configured; if not, fail fast.
  v2k_govc about >/dev/null 2>&1 || { echo 0; return 0; }

  local line size_h size_b
  # Use the first line only.
  line="$(v2k_govc datastore.ls -l "${ds_path}" 2>/dev/null | head -n 1 || true)"
  [[ -n "${line}" ]] || { echo 0; return 0; }

  size_h="$(awk '{print $1}' <<<"${line}")"
  size_b="$(v2k_vmware__human_to_bytes "${size_h}")"
  [[ "${size_b}" =~ ^[0-9]+$ ]] || size_b=0
  echo "${size_b}"
}

v2k_vmware_manifest_sum_vmdk_physical_bytes() {
  # Args: manifest.json
  # Returns: sum of physical bytes for all disks (best-effort) or 0
  local manifest="${1-}"
  [[ -n "${manifest}" && -f "${manifest}" ]] || { echo 0; return 0; }

  command -v jq >/dev/null 2>&1 || { echo 0; return 0; }

  local sum=0 vmdk_path b
  while IFS= read -r vmdk_path; do
    [[ -n "${vmdk_path}" ]] || continue
    b="$(v2k_vmware_datastore_vmdk_physical_bytes "${vmdk_path}")"
    [[ "${b}" =~ ^[0-9]+$ ]] || b=0
    sum=$(( sum + b ))
  done < <(jq -r '.disks[].vmdk.path // empty' "${manifest}" 2>/dev/null || true)

  echo "${sum}"
}

# NOTE:
# - We intentionally rely on govc commands only.
# - Hard power-off is the most reliable option in the field.
#   govc vm.power -off -force <vm>
 
v2k_json_s() {
  # best-effort JSON string builder for event detail
  local s="${1-}"
  if declare -F v2k_json_string >/dev/null 2>&1; then
    printf '%s' "${s}" | v2k_json_string
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "${s}" | jq -Rs '.'
    return 0
  fi
  v2k_python - <<'PY' 2>/dev/null || echo '""'
import json,sys
print(json.dumps(sys.argv[1]))
PY
}

v2k_vmware_vm_power_state() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"
  # govc vm.info -json provides runtime.powerState; fallback to empty.
  v2k_govc vm.info -json "${vm}" 2>/dev/null \
    | jq -r '.virtualMachines[0].runtime.powerState // empty' 2>/dev/null \
    || true
}

v2k_vmware_vm_wait_poweroff() {
  local manifest="$1" timeout="${2:-300}"
  local t=0
  while (( t < timeout )); do
    local st
    st="$(v2k_vmware_vm_power_state "${manifest}")"
    if [[ "${st}" == "poweredOff" || "${st}" == "off" ]]; then
      return 0
    fi
    sleep 2
    t=$((t+2))
  done
  return 1
}

v2k_vmware_vm_poweroff() {
  local manifest="$1" force="${2:-1}" timeout="${3:-300}"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"

  # If already off, ok.
  local st
  st="$(v2k_vmware_vm_power_state "${manifest}")"
  if [[ "${st}" == "poweredOff" || "${st}" == "off" ]]; then
    return 0
  fi

  if [[ "${force}" == "1" ]]; then
    v2k_govc vm.power -off -force "${vm}"
  else
    v2k_govc vm.power -off "${vm}"
  fi

  v2k_vmware_vm_wait_poweroff "${manifest}" "${timeout}"
}

# Best-effort ?guest shutdown??(only if govc supports it on this build).
# - If unsupported or fails, caller may fallback to poweroff.
v2k_vmware_vm_shutdown_guest_best_effort() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"

  # Detect supported flags dynamically (avoid hard dependency on exact govc version).
  local help
  help="$(v2k_govc vm.power -h 2>&1 || true)"

  # Commonly seen flags in some builds: -shutdown / -reboot / -reset / etc.
  if echo "${help}" | grep -q -- '-shutdown'; then
    v2k_govc vm.power -shutdown "${vm}"
    return 0
  fi

  return 1
}

v2k_vmware_load_cred_file() {
  local file="$1"
  [[ -f "${file}" ]] || { echo "cred-file not found: ${file}" >&2; exit 2; }
  # expected format: KEY=VALUE lines (GOVC_URL/GOVC_USERNAME/GOVC_PASSWORD/GOVC_INSECURE)
  set -a
  # shellcheck disable=SC1090
  source "${file}"
  set +a
}

v2k_require_govc_env() {
  : "${GOVC_URL:?missing GOVC_URL}"
  : "${GOVC_USERNAME:?missing GOVC_USERNAME}"
  : "${GOVC_PASSWORD:?missing GOVC_PASSWORD}"
  : "${GOVC_INSECURE:=1}"
  export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE
}

v2k_is_ipv4() {
  local s="${1:-}"
  [[ "${s}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  # 0-255 범위???격 체크 ?????요 ??보강)
  return 0
}

v2k_resolve_ipv4() {
  local host="$1"
  # DNS/hosts 기반 IPv4 1개만 ?택
  getent ahostsv4 "${host}" 2>/dev/null | awk 'NR==1{print $1; exit}'
}

v2k_vmware_inventory_json() {
  local vm="$1" vcenter="$2"
  v2k_require_govc_env

  local vm_info dev_info tmpdir vm_info_file dev_info_file rc
  local host_moref="" host_name="" host_version="" hostinfo_json=""
  local esxi_mgmt_ip="" esxi_thumbprint=""

  vm_info="$(v2k_govc vm.info -json "${vm}")"
  dev_info="$(v2k_govc device.info -json -vm "${vm}")"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/v2k-inventory.XXXXXX")"
  vm_info_file="${tmpdir}/vm.info.json"
  dev_info_file="${tmpdir}/device.info.json"
  printf '%s' "${vm_info}" > "${vm_info_file}"
  printf '%s' "${dev_info}" > "${dev_info_file}"

  # 1) VM???라?HostSystem MoRef 추출
  host_moref="$(
    printf '%s' "${vm_info}" | jq -r '
      .virtualMachines[0] as $v
      | ($v.runtime.host.value // $v.runtime.host.Value // $v.summary.runtime.host.value // $v.summary.runtime.host.Value // "")
    ' 2>/dev/null || echo ""
  )"

  # 2) host.info?management IP + thumbprint 추출 (DNS ?존 ?거)

  # 2-1) MoRef ?선 조회
  if [[ -n "${host_moref}" && "${host_moref}" != "null" ]]; then
    hostinfo_json="$(v2k_govc host.info -json -host "${host_moref}" 2>/dev/null || true)"
  fi

  # 2-2) ?싱
  if [[ -n "${hostinfo_json}" ]]; then
    host_name="$(printf '%s' "${hostinfo_json}" | jq -r '.hostSystems[0].summary.config.name // empty' 2>/dev/null || true)"
    host_version="$(printf '%s' "${hostinfo_json}" | jq -r '.hostSystems[0].summary.config.product.version // .hostSystems[0].config.product.version // empty' 2>/dev/null || true)"
    esxi_thumbprint="$(printf '%s' "${hostinfo_json}" | jq -r '.hostSystems[0].summary.config.sslThumbprint // empty' 2>/dev/null || true)"
    esxi_mgmt_ip="$(v2k_vmware_esxi_mgmt_ip_from_hostinfo_json "${hostinfo_json}" 2>/dev/null | head -n1 || true)"
  fi

  # 3) fallback: management IP가 비어?으?host_name??IP??/resolve 가?한지 ?인
  if [[ -z "${esxi_mgmt_ip}" && -n "${host_name}" ]]; then
    if v2k_is_ipv4 "${host_name}"; then
      esxi_mgmt_ip="${host_name}"
    else
      esxi_mgmt_ip="$(v2k_resolve_ipv4 "${host_name}")"
    fi
  fi

  if jq -n --arg vm "${vm}" \
    --slurpfile vminfo_file "${vm_info_file}" \
    --slurpfile devinfo_file "${dev_info_file}" \
    --arg esxi_host "${esxi_mgmt_ip}" \
    --arg esxi_name "${host_name}" \
    --arg esxi_version "${host_version}" \
    --arg esxi_thumbprint "${esxi_thumbprint}" \
    '
    ($vminfo_file[0] // {}) as $vminfo
    | ($devinfo_file[0] // {}) as $devinfo
    |
    def VMINFO0: ($vminfo.virtualMachines[0] // {});
    def CFG: (VMINFO0.config // {});
    def HW: (CFG.hardware // {});
    def BOOT: (CFG.bootOptions // {});
    def HWDEVS: (HW.device // []);    

    # device.info ?키? ?재 ?경? 루트가 {"devices":[...]}
    def DEVICES:
      ( $devinfo.devices
        // $devinfo.virtualMachines[0].devices
        // $devinfo.VirtualMachines[0].Devices
        // []
      );

    # ---- helpers (jq 1.6 safe: use ? + //, no try/catch) ----
    def lbl($o): ($o.deviceInfo?.label // "");
    def typ($o): ($o.type // "");

    # --- VMware -> libvirt carry-over fields (confirmed by vm.info samples) ---
    # firmware: "efi" or "bios"
    def vm_firmware: (CFG.firmware // "");

    # efiSecureBootEnabled exists even for non-efi in some outputs; treat meaningful only if firmware=="efi"
    def vm_secure_boot: (BOOT.efiSecureBootEnabled // false);

    # vCPU / MemoryMB are in config.hardware
    def vm_cpu: (HW.numCPU // 0);
    def vm_mem_mb: (HW.memoryMB // 0);

    # TPM detection:
    # In your efi+secure+tpm sample, TPM device entry has no ".type".
    # It is identified by:
    # - deviceInfo.label == "Virtual TPM"
    # - deviceInfo.summary contains "Trusted Platform"
    # - endorsementKeyCertificate* keys exist
    def vm_has_tpm:
      (HWDEVS
        | any(.[]?;
            (type=="object") and (
              ((.deviceInfo?.label // "") | test("TPM"; "i"))
              or ((.deviceInfo?.summary // "") | test("TPM|Trusted Platform"; "i"))
              or (has("endorsementKeyCertificate"))
              or (has("endorsementKeyCertificateSigningRequest"))
            )
          )
      );

    # NIC list (MAC must be preserved).
    # NOTE: In some govc vm.info -json outputs, config.hardware.device entries do NOT have ".type".
    #       Reliable signals are: has("macAddress") and deviceInfo.label like "Network adapter N".
    def vm_nics:
      (HWDEVS
        | map(
            select(
              (has("macAddress"))
              and ((.macAddress // "") != "")
              and (((.deviceInfo?.label // "") | test("^Network adapter"; "i")))
            )
          )
        | map({
            key: (.key // 0),
            type: (.type? // (.deviceInfo?.label // "nic")),
            label: (.deviceInfo?.label // "Network adapter"),
            mac: (.macAddress // "" | ascii_downcase),
            network: (
              .backing?.deviceName //
              .backing?.opaqueNetworkId //
              .deviceInfo?.summary //
              ""
            ),
            connected: (.connectable?.connected // false),
            start_connected: (.connectable?.startConnected // false),
            backing: {
              device_name: (.backing?.deviceName // ""),
              portgroup_key: (.backing?.port?.portgroupKey // ""),
              switch_uuid: (.backing?.port?.switchUuid // ""),
              opaque_network_id: (.backing?.opaqueNetworkId // ""),
              opaque_network_type: (.backing?.opaqueNetworkType // "")
            }
          })
        | sort_by(.key)
      );

    # 컨트롤러 분류: deviceInfo.label ?선
    def is_scsi_ctrl($o):
      (lbl($o) | ascii_downcase | test("^scsi controller"));

    def is_ide_ctrl($o):
      (lbl($o) | ascii_downcase | test("^ide( controller)?[[:space:]]*[0-9]*$"));

    def is_sata_ctrl($o):
      (lbl($o) | ascii_downcase | test("^sata controller"));

    def is_nvme_ctrl($o):
      (lbl($o) | ascii_downcase | test("^nvme controller"));

    # fallback: label??비어?거???상??? ??type ?턴?로 보조 ?별
    def is_scsi_ctrl_by_type($o):
      (typ($o) | test("SCSIController$"))
      or (typ($o) | test("LsiLogic"))
      or (typ($o) | test("ParaVirtualSCSI"))
      or (typ($o) | test("BusLogic"));

    def is_ide_ctrl_by_type($o):
      (typ($o) | test("IDEController$"; "i"));

    def is_sata_ctrl_by_type($o):
      (typ($o) | test("SATAController$"; "i"));

    def is_nvme_ctrl_by_type($o):
      (typ($o) | test("NVMEController$"; "i"));

    def controller_kind($o):
      if is_scsi_ctrl($o) or is_scsi_ctrl_by_type($o) then "scsi"
      elif is_ide_ctrl($o) or is_ide_ctrl_by_type($o) then "ide"
      elif is_sata_ctrl($o) or is_sata_ctrl_by_type($o) then "sata"
      elif is_nvme_ctrl($o) or is_nvme_ctrl_by_type($o) then "nvme"
      else "unknown"
      end;

    def controllers:
      (DEVICES
        | map(select((controller_kind(.) != "unknown")))
        | map({
            key: .key,
            type: .type,
            label: lbl(.),
            bus: (.busNumber // 0),
            kind: controller_kind(.)
          })
      );

    def controller_rank($kind; $type; $ctrl_label):
      (($ctrl_label // "") | tostring | ascii_downcase) as $lbl
      | (($type // "") | tostring) as $typ
      | if $kind == "ide" or ($typ | test("IDEController$"; "i")) then 0
        elif $kind == "scsi" or ($lbl | test("^scsi controller")) or ($typ | test("SCSIController$|LsiLogic|ParaVirtualSCSI|BusLogic")) then 1
        elif $kind == "sata" or ($lbl | test("^sata controller")) or ($typ | test("SATA"; "i")) then 2
        elif $kind == "nvme" or ($lbl | test("^nvme controller")) or ($typ | test("NVME"; "i")) then 3
        else 9 end;

    def boot_disk_device_keys:
      (BOOT.bootOrder // BOOT.boot_order // [])
      | map((.deviceKey // .device_key // .key // empty) | tostring);

    def boot_rank($disk; $boot_keys):
      ([$boot_keys | to_entries[]? | select(.value == (($disk.device_key // "") | tostring)) | .key] | .[0] // 9999);

    # A BIOS VM often has no explicit disk device in bootOrder. The VMware
    # "Hard disk N" label preserves source disk order more reliably than
    # ranking controller families (for example, an IDE boot disk plus a SCSI
    # data disk). Explicit bootOrder still has first priority.
    def disk_label_rank($disk_label):
      try (
        (($disk_label // "") | tostring)
        | capture("^[Hh]ard disk (?<ordinal>[0-9]+)$").ordinal
        | tonumber
      ) catch 9999;

    def disks($ctls):
      (DEVICES
        | to_entries
        | map(select(.value.type=="VirtualDisk"))
        | map(
            . as $entry
            | .value as $d
            | ($ctls | map(select(.key==$d.controllerKey)) | .[0]) as $c
            | {
                disk_id: (
                  if $c != null and ($c.kind != "unknown") then
                    ($c.kind + ($c.bus|tostring) + ":" + ($d.unitNumber|tostring))
                  else
                    ("devkey:" + ($d.key|tostring))
                  end
                ),
                label: ($d.deviceInfo?.label // $d.label // "VirtualDisk"),
                source_ordinal: $entry.key,
                device_key: ($d.key|tostring),
                controller: (
                  if $c!=null then
                    {kind:$c.kind,type:$c.type,bus:$c.bus,unit:$d.unitNumber,label:$c.label}
                  else
                    {kind:"unknown",type:"unknown",bus:0,unit:($d.unitNumber//0),label:""}
                  end
                ),
                vmdk: { path: ($d.backing?.fileName // "") },
                size_bytes: ($d.capacityInBytes // 0)
              }
          )
        | boot_disk_device_keys as $boot_keys
        | sort_by([
            boot_rank(.; $boot_keys),
            disk_label_rank(.label // ""),
            controller_rank(.controller.kind // ""; .controller.type // ""; .controller.label // ""),
            (.controller.bus // 0),
            (.controller.unit // 0),
            (.source_ordinal // 0)
          ])
        | to_entries
        | map(.value + {role:(if .key == 0 then "root" else "data" end)})
      );

    {
      vm: {
        name: $vm,
        moref: (VMINFO0.self?.value // ""),
        uuid: (VMINFO0.config?.uuid // ""),
 
        # --- carry-over hardware profile (for libvirt definition) ---
        firmware: vm_firmware,
        secure_boot: vm_secure_boot,
        tpm: vm_has_tpm,
        cpu: vm_cpu,
        memory_mb: vm_mem_mb,
        nics: vm_nics,

        # --- guest metadata (for Windows detection / WinPE automation) ---
        # govc -json fields are lowerCamel:
        #   .virtualMachines[0].config.guestId
        #   .virtualMachines[0].guest.guestFullName
        #   .virtualMachines[0].guest.osFullName
        guestId: (VMINFO0.config?.guestId // ""),
        guest_id: (VMINFO0.config?.guestId // ""),
        guestFullName: (VMINFO0.guest?.guestFullName // ""),
        guest_full_name: (VMINFO0.guest?.guestFullName // ""),
        osFullName: (VMINFO0.guest?.osFullName // ""),
        os_full_name: (VMINFO0.guest?.osFullName // ""),
        guestFamily: (VMINFO0.guest?.guestFamily // ""),

        # keep subtrees for heuristic readers that look into vm.guest.* or vm.config.*
        config: {
          guestId: (VMINFO0.config?.guestId // ""),
          guest_id: (VMINFO0.config?.guestId // "")
        },
        guest: (VMINFO0.guest // {})
      },
      esxi_host: $esxi_host,
      esxi_name: $esxi_name,
      esxi_version: $esxi_version,
      esxi_thumbprint: $esxi_thumbprint,
      disks: disks(controllers)
    }'; then
    rc=0
  else
    rc=$?
  fi
  rm -rf "${tmpdir}"
  return "${rc}"
}

v2k_assign_target_paths() {
  local manifest="$1"
  local dst_root format storage_type
  dst_root="$(jq -r '.target.dst_root' "${manifest}")"
  format="$(jq -r '.target.format // "qcow2"' "${manifest}")"
  storage_type="$(jq -r '.target.storage.type // "file"' "${manifest}")"  # file|block

  # ?장??결정 (file ??만)
  local ext=""
  if [[ "${storage_type}" == "file" ]]; then
    case "${format}" in
      qcow2) ext="qcow2" ;;
      raw)   ext="raw" ;;
      *) echo "[ERR] Unsupported target.format: ${format}" >&2; return 2 ;;
    esac
  fi

  # per-disk override map (optional): .target.storage.map : { "scsi0:0": "/dev/sdb", "scsi0:1": "/dev/sdc" }
  # file ??에?도 override 가?하????? ?정 ?일?강제)
  jq -c --arg dst_root "${dst_root}" --arg ext "${ext}" --arg st "${storage_type}" '
    .target.storage.type = (.target.storage.type // "file")
    | .target.format = (.target.format // "qcow2")
    | .target.storage.map = (.target.storage.map // {})
    | .disks = (
        .disks
        | to_entries
        | map(
            . as $e
            | ($e.key|tostring) as $idx
            | ($e.value.disk_id) as $disk_id
            | (.target.storage.map[$disk_id] // empty) as $override
            | $e.value.transfer.target_path = (
                if ($override|length) > 0 then
                  $override
                else
                  if $st == "block" then
                    # block ??? 반드??map?로 지?하?록 강제 (?동 ?당 ?험)
                    ("")
                  else
                    ($dst_root + "/disk" + $idx + "." + $ext)
                  end
                end
              )
            | $e.value
          )
      )
  ' "${manifest}" > "${manifest}.tmp" && mv -f "${manifest}.tmp" "${manifest}"

  # block ??이?반드??override가 채워?야 ??
  if [[ "${storage_type}" == "block" ]]; then
    local missing
    missing="$(jq -r '.disks[] | select(.transfer.target_path=="" or .transfer.target_path=="null") | .disk_id' "${manifest}" | wc -l)"
    if [[ "${missing}" -ne 0 ]]; then
      echo "[ERR] target.storage.type=block requires per-disk mapping: .target.storage.map{disk_id:\"/dev/...\"}" >&2
      echo "      Example: jq '.target.storage={type:\"block\",map:{\"scsi0:0\":\"/dev/sdb\",\"scsi0:1\":\"/dev/sdc\"}}' -c manifest.json" >&2
      return 2
    fi
  fi

  # ?니??체크
  local dup
  dup="$(jq -r '.disks[].transfer.target_path' "${manifest}" | sort | uniq -d | wc -l)"
  if [[ "${dup}" -ne 0 ]]; then
    echo "[ERR] Duplicate target_path detected. Each disk must have unique transfer.target_path." >&2
    jq -r '.disks[].transfer.target_path' "${manifest}" | sort | uniq -d >&2
    return 2
  fi

  return 0
}


v2k_vmware_snapshot_create() {
  local manifest="$1" which="$2" name="$3"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"
  v2k_event INFO "snapshot.${which}" "" "snapshot_create_start" "{\"name\":$(v2k_json_s "${name}")}"
  v2k_govc snapshot.create -vm "${vm}" -m=false -q=true "${name}" >/dev/null
  v2k_event INFO "snapshot.${which}" "" "snapshot_create_done" "{\"name\":$(v2k_json_s "${name}")}"
}

v2k_vmware_snapshot_cleanup() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"
  v2k_govc snapshot.tree -vm "${vm}" >/dev/null 2>&1 || true
  v2k_event INFO "cleanup" "" "snapshot_cleanup_skip" "{\"reason\":\"v1 does not auto-remove snapshots for safety\"}"
}

v2k_vmware_cbt_enable_all() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"

  local count failures=0
  count="$(jq -r '.disks|length' "${manifest}")"
  local i
  if ! v2k_govc vm.change -vm "${vm}" -e "ctkEnabled=true" >/dev/null; then
    v2k_event ERROR "cbt_enable" "" "cbt_enable_vm_failed" \
      '{"extra_config":"ctkEnabled","action":"stop_before_base"}'
    for ((i=0;i<count;i++)); do
      v2k_manifest_set_disk_cbt "${manifest}" "${i}" "false" "" ""
      if declare -F v2k_manifest_record_sync_failure >/dev/null 2>&1; then
        v2k_manifest_record_sync_failure \
          "${manifest}" "base" "${i}" 44 \
          "cbt_enable_vm_failed" \
          '{"extra_config":"ctkEnabled","action":"stop_before_base"}' || true
      fi
    done
    return 44
  fi

  for ((i=0;i<count;i++)); do
    local disk_id device_key
    disk_id="$(jq -r ".disks[$i].disk_id" "${manifest}")"
    device_key="$(jq -r ".disks[$i].device_key // empty" "${manifest}")"
    if [[ "${disk_id}" =~ ^(ide|scsi|sata)[0-9]+:[0-9]+$ ]]; then
      if v2k_govc vm.change -vm "${vm}" -e "${disk_id}.ctkEnabled=true" >/dev/null; then
        v2k_manifest_set_disk_cbt "${manifest}" "${i}" "true" "" ""
        v2k_event INFO "cbt_enable" "${disk_id}" "cbt_enable_disk_done" \
          "{\"device_key\":$(v2k_json_s "${device_key}"),\"extra_config\":$(v2k_json_s "${disk_id}.ctkEnabled")}"
      else
        failures=$((failures + 1))
        v2k_manifest_set_disk_cbt "${manifest}" "${i}" "false" "" ""
        local failure_detail
        failure_detail="$(jq -nc \
          --arg disk_id "${disk_id}" \
          --arg device_key "${device_key}" \
          --arg extra_config "${disk_id}.ctkEnabled" \
          '{disk_id:$disk_id,device_key:$device_key,extra_config:$extra_config,action:"stop_before_base"}')"
        v2k_event ERROR "cbt_enable" "${disk_id}" "cbt_enable_disk_failed" \
          "${failure_detail}"
        if declare -F v2k_manifest_record_sync_failure >/dev/null 2>&1; then
          v2k_manifest_record_sync_failure \
            "${manifest}" "base" "${i}" 44 \
            "cbt_enable_disk_failed" "${failure_detail}" || true
        fi
      fi
    else
      failures=$((failures + 1))
      v2k_manifest_set_disk_cbt "${manifest}" "${i}" "false" "" ""
      local unsupported_detail
      unsupported_detail="$(jq -nc \
        --arg disk_id "${disk_id}" \
        --arg device_key "${device_key}" \
        '{disk_id:$disk_id,device_key:$device_key,reason:"controller address is unavailable",action:"stop_before_base"}')"
      v2k_event ERROR "cbt_enable" "${disk_id}" "cbt_enable_disk_unsupported" \
        "${unsupported_detail}"
      if declare -F v2k_manifest_record_sync_failure >/dev/null 2>&1; then
        v2k_manifest_record_sync_failure \
          "${manifest}" "base" "${i}" 44 \
          "cbt_enable_disk_unsupported" "${unsupported_detail}" || true
      fi
    fi
  done

  if [[ "${failures}" -ne 0 ]]; then
    return 44
  fi
}

v2k_vmware_cbt_status_all() {
  local manifest="$1"
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"
  jq -c '{
    vm:.source.vm.name,
    disks:(.disks|map({
      disk_id:.disk_id,
      device_key:(.device_key // ""),
      controller:(.controller.kind // .controller.type // "unknown"),
      cbt_enabled:.cbt.enabled,
      last_change_id:(.cbt.last_change_id // "")
    }))
  }' "${manifest}"
}

# --- append below existing functions ---

v2k_vmware_get_vm_moref() {
  local manifest="$1"
  jq -r '.source.vm.moref' "${manifest}"
}

v2k_vmware_snapshot_moref_by_name() {
  local manifest="$1" snap_name="$2"
  v2k_require_govc_env
  local vm_name vm_moref
  vm_name="$(jq -r '.source.vm.name' "${manifest}")"
  vm_moref="$(jq -r '.source.vm.moref // empty' "${manifest}")"

  # Prefer VM MoRef for stability (avoids inventory path ambiguity)
  # govc object.collect accepts a managed object reference like "vm-4106".
  local vm_ref
  if [[ -n "${vm_moref}" && "${vm_moref}" != "null" ]]; then
    vm_ref="${vm_moref}"
  else
    # fallback to inventory path-style reference
    vm_ref="vm/${vm_name}"
  fi

  # NOTE:
  # - govc snapshot.tree -json may omit snapshot MoRef depending on version/environment.
  # - govc object.collect <vm_ref> snapshot returns full snapshot tree WITH MoRef.
  #
  # Output example shape:
  # [
  #   { "name":"snapshot", "val": { "rootSnapshotList":[{ "name":"X", "snapshot":{ "value":"snapshot-123" }, "childSnapshotList":[...] }] } }
  # ]
  v2k_govc object.collect -json "${vm_ref}" snapshot 2>/dev/null \
    | jq -r --arg n "${snap_name}" '
        def walk(nodes):
          nodes[]? as $x
          | if ($x.name // "") == $n then ($x.snapshot.value // empty)
            else (walk($x.childSnapshotList // []))
            end;
        .[]? 
        | select(.name=="snapshot")
        | (.val.rootSnapshotList // [])
        | walk(.) 
      ' | head -n1
}

v2k_vmware_get_thumbprint() {
  local esxi_host="$1"
  echo | openssl s_client -connect "${esxi_host}:443" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr '[:lower:]' '[:upper:]'
}

v2k_vmware_require_esxi_host() {
  local manifest="$1"
  local esxi
  esxi="$(jq -r '.source.esxi_host // empty' "${manifest}")"
  if [[ -z "${esxi}" || "${esxi}" == "null" ]]; then
    echo "Missing source.esxi_host in manifest. Add it (ESXi host FQDN/IP) for nbdkit-vddk pipeline." >&2
    echo "Example: jq '.source.esxi_host=\"esxi01.example.local\"' -c manifest.json > /tmp/m && mv /tmp/m manifest.json" >&2
    exit 2
  fi
  echo "${esxi}"
}

v2k_vmware_esxi_mgmt_ip_from_hostinfo_json() {
  # input: govc host.info -json output (string)
  # output: first IPv4 address of management vmk (one line). empty if not found.
  local hostinfo_json="${1:-}"
  [[ -n "${hostinfo_json}" ]] || return 0

  local ip
  ip="$(
    printf '%s' "${hostinfo_json}" | jq -r '
      def first_ipv4($s):
        ($s // "") | tostring;

      # netConfig 배열
      (.hostSystems[0].config.virtualNicManagerInfo.netConfig // []) as $nc

      # 1) nicType=="management" 블록?서 selectedVnic ?선
      | ( $nc | map(select(.nicType=="management"))[0] // {} ) as $m
      | ( ($m.selectedVnic[0] // "") | tostring ) as $sel
      | ( $m.candidateVnic // [] ) as $c
      | (
          ( if ($sel|length) > 0 then
              ( $c | map(select(.key==$sel)) | .[0].spec.ip.ipAddress )
            else
              empty
            end
          )
          // ( $c[0].spec.ip.ipAddress )
          // empty
        )
    ' 2>/dev/null
  )"

  # 2) fallback: ?에???찾으?selectedVnic가 ?는 netConfig?서 ?보 ??IP
  if [[ -z "${ip}" ]]; then
    ip="$(
      printf '%s' "${hostinfo_json}" | jq -r '
        (.hostSystems[0].config.virtualNicManagerInfo.netConfig // [])
        | map(select((.selectedVnic // []) | length > 0))
        | .[0] // {} as $m
        | ($m.candidateVnic // [])
        | .[0].spec.ip.ipAddress // empty
      ' 2>/dev/null
    )"
  fi

  # 3) 방어?으?IPv4??터??러 ??음 ?임 ?거)
  if [[ -n "${ip}" ]]; then
    ip="$(printf '%s\n' "${ip}" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true)"
  fi

  if v2k_is_ipv4 "${ip}"; then
    printf '%s\n' "${ip}"
  fi
}

v2k_vmware_snapshot_remove_all() {
  local manifest="$1"
  local vm
  vm="$(jq -r '.source.vm.name // empty' "${manifest}" 2>/dev/null || true)"
  [[ -n "${vm}" && "${vm}" != "null" ]] || {
    echo "Cannot purge snapshots: missing .source.vm.name in manifest" >&2
    return 2
  }

  # Delete ALL snapshots of the source VM.
  # govc usage: snapshot.remove NAME (NAME can be '*' to remove all snapshots)
  # Ref: govc USAGE.md
  if v2k_govc snapshot.remove -vm "${vm}" '*' >/dev/null 2>&1; then
    return 0
  fi

  # If it failed, surface stderr for diagnostics.
  # (Caller decides whether to treat as fatal.)
  v2k_govc snapshot.remove -vm "${vm}" '*' 2>&1 | sed 's/^/[govc] /' >&2
  return 1
}

v2k_vmware_snapshot_remove_migr() {
  local manifest="$1"
  local pattern="${2:-migr-}"

  local vm
  vm="$(jq -r '.source.vm.name // empty' "${manifest}" 2>/dev/null || true)"
  [[ -n "${vm}" && "${vm}" != "null" ]] || {
    echo "Cannot remove migr snapshots: missing .source.vm.name in manifest" >&2
    return 2
  }

  local round max_round
  max_round=10
  for ((round=1; round<=max_round; round++)); do
    local tree_json names
    
    # [?정 1] ?러 메시지?stderr?출력?도?2>/dev/null ?거, ?패 ??loop continue ????러 체크 강화
    if ! tree_json="$(v2k_govc snapshot.tree -vm "${vm}" -json 2>&1)"; then
       # govc 명령 ?체가 ?패??경우 (?? ?결 ??, VM Busy)
       echo "[WARN] Failed to list snapshots (round ${round}): ${tree_json}" >&2
       sleep 2
       continue
    fi

    if [[ -z "${tree_json}" ]]; then
      # ?냅?이 ?말 ?는 경우
      return 0
    fi

    names="$(printf '%s' "${tree_json}" \
      | jq -r '.. | objects | (.name? // .Name? // empty)' 2>/dev/null \
      | grep -F "${pattern}" \
      | sort -u || true)"

    if [[ -z "${names}" ]]; then
      # ?턴 매칭?는 ?냅?이 ?으??료
      return 0
    fi

    # [?정 2] ?? ?행 ??러 로깅
    local delete_failed=0
    while IFS= read -r snap_name; do
      [[ -n "${snap_name}" ]] || continue
      
      local out
      if ! out="$(v2k_govc snapshot.remove -vm "${vm}" "${snap_name}" 2>&1)"; then
        echo "[WARN] Failed to remove snapshot '${snap_name}': ${out}" >&2
        delete_failed=1
      else
        echo "[INFO] Removed snapshot: ${snap_name}" >&2
      fi
    done <<< "${names}"

    # ?? ?패 건이 ?었?면 ?시 ?????시??(vCenter Task Busy ?화)
    if [[ "${delete_failed}" -eq 1 ]]; then
      sleep 3
    fi
  done

  # [?정 3] 루프 종료 ?에???아?는지 ?인
  local remain
  remain="$(v2k_govc snapshot.tree -vm "${vm}" -json 2>/dev/null \
      | jq -r '.. | objects | (.name? // .Name? // empty)' 2>/dev/null \
      | grep -F "${pattern}" || true)"
      
  if [[ -n "${remain}" ]]; then
    echo "[ERR] Failed to purge all migr snapshots. Remaining: ${remain}" >&2
    return 1
  fi
  
  return 0
}
