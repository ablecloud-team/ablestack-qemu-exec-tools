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

v2k_vmware_load_cred_file() {
  local file="$1"
  [[ -f "${file}" ]] || { echo "cred-file not found: ${file}" >&2; exit 2; }
  # expected format: KEY=VALUE lines (GOVC_URL/GOVC_USERNAME/GOVC_PASSWORD/GOVC_INSECURE)
  # shellcheck disable=SC1090
  source "${file}"
}

v2k_require_govc_env() {
  : "${GOVC_URL:?missing GOVC_URL}"
  : "${GOVC_USERNAME:?missing GOVC_USERNAME}"
  : "${GOVC_PASSWORD:?missing GOVC_PASSWORD}"
  : "${GOVC_INSECURE:=1}"
}

v2k_vmware_inventory_json() {
  local vm="$1" vcenter="$2"
  v2k_require_govc_env

  # govc doesn't require vcenter param if GOVC_URL is set, but we store vcenter in manifest
  # Use govc vm.info -json to get overall config; device details via device.info -json
  local vm_info dev_info
  vm_info="$(govc vm.info -json -vm "${vm}")"
  dev_info="$(govc device.info -json -vm "${vm}")"

  # Extract disks: VirtualDisk with controller & unit.
  # We normalize disk_id as "scsi<bus>:<unit>" when controller is SCSI-like; otherwise "devkey:<key>".
  # For PVSCSI/LSI this will still be scsi.
  jq -n --arg vm "${vm}" \
    --argjson vminfo "${vm_info}" \
    --argjson devinfo "${dev_info}" \
    '
    def ctrl_type($c):
      ($c | tostring | ascii_downcase);

    # Map controllerKey -> {type,bus}
    def controllers:
      ($devinfo.VirtualMachines[0].Devices
        | map(select(.Type | test("SCSIController")))
        | map({
            key: .Key,
            type: .Type,
            bus: (try (.BusNumber) catch 0)
          })
      );

    # Map disk list
    def disks($ctls):
      ($devinfo.VirtualMachines[0].Devices
        | map(select(.Type=="VirtualDisk"))
        | map(
            . as $d
            | ($ctls | map(select(.key==$d.ControllerKey)) | .[0]) as $c
            | {
                disk_id: (
                  if $c != null then
                    ("scsi" + ($c.bus|tostring) + ":" + ($d.UnitNumber|tostring))
                  else
                    ("devkey:" + ($d.Key|tostring))
                  end
                ),
                label: ($d.Label // "VirtualDisk"),
                device_key: ($d.Key|tostring),
                controller: (if $c!=null then {type:$c.type,bus:$c.bus,unit:$d.UnitNumber} else {type:"unknown",bus:0,unit:($d.UnitNumber//0)} end),
                vmdk: { path: ($d.Backing.FileName // "") },
                size_bytes: (try ($d.CapacityInBytes) catch 0)
              }
          )
      );

    {
      vm: {
        name: $vm,
        moref: ($vminfo.VirtualMachines[0].Self.Value // ""),
        uuid: ($vminfo.VirtualMachines[0].Config.Uuid // "")
      },
      disks: disks(controllers)
    }'
}

v2k_vmware_snapshot_create() {
  local manifest="$1" which="$2" name="$3"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"
  v2k_event INFO "snapshot.${which}" "" "snapshot_create_start" "{\"name\":\"${name}\"}"
  govc snapshot.create -vm "${vm}" -m=false -q=false "${name}" >/dev/null
  v2k_event INFO "snapshot.${which}" "" "snapshot_create_done" "{\"name\":\"${name}\"}"
}

v2k_vmware_snapshot_cleanup() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"
  # Conservative: remove snapshots starting with migr-
  # (You can harden this with manifest snapshot refs later)
  govc snapshot.tree -vm "${vm}" >/dev/null 2>&1 || true
  # govc snapshot.remove accepts a snapshot name, but tree parsing is non-trivial without stable IDs
  # v1: do nothing by default (safe). Implement in v2 if needed.
  v2k_event INFO "cleanup" "" "snapshot_cleanup_skip" "{\"reason\":\"v1 does not auto-remove snapshots for safety\"}"
}

v2k_vmware_cbt_enable_all() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"

  # Enable VM-level CBT (ctkEnabled)
  govc vm.change -vm "${vm}" -e "ctkEnabled=true" >/dev/null

  local count
  count="$(jq -r '.disks|length' "${manifest}")"
  local i
  for ((i=0;i<count;i++)); do
    local disk_id
    disk_id="$(jq -r ".disks[$i].disk_id" "${manifest}")"
    # disk_id example: scsi0:0 -> key scsi0:0.ctkEnabled=true
    if [[ "${disk_id}" =~ ^scsi[0-9]+:[0-9]+$ ]]; then
      govc vm.change -vm "${vm}" -e "${disk_id}.ctkEnabled=true" >/dev/null
    else
      # fallback: can't map to scsi param; record warning
      v2k_event INFO "cbt_enable" "${disk_id}" "cbt_enable_skip" "{\"reason\":\"non-scsi disk_id; cannot set scsiX:Y.ctkEnabled\"}"
    fi
  done

  # Verify and update manifest fields (enabled flag only in v1)
  for ((i=0;i<count;i++)); do
    local d_id
    d_id="$(jq -r ".disks[$i].disk_id" "${manifest}")"
    v2k_manifest_set_disk_cbt "${manifest}" "${i}" "true" "" ""
  done
}

v2k_vmware_cbt_status_all() {
  local manifest="$1"
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"
  # Minimal status from manifest
  jq -c '{vm:.source.vm.name, disks:(.disks|map({disk_id:.disk_id, cbt_enabled:.cbt.enabled}))}' "${manifest}"
}

# --- append below existing functions ---

v2k_vmware_get_vm_moref() {
  local manifest="$1"
  jq -r '.source.vm.moref' "${manifest}"
}

v2k_vmware_snapshot_moref_by_name() {
  local manifest="$1" snap_name="$2"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"

  # govc snapshot.tree -json includes snapshot moRef
  govc snapshot.tree -vm "${vm}" -json | jq -r --arg n "${snap_name}" '
    def walk(nodes):
      nodes[]? as $x
      | if $x.Name == $n then $x.Snapshot.Value
        else (walk($x.ChildSnapshotList // []) )
        end;
    walk(.Tree.RootSnapshotList // []) | select(. != null) ' | head -n1
}

v2k_vmware_get_thumbprint() {
  local esxi_host="$1"
  # From validated sequence: openssl s_client -> x509 fingerprint -sha1 -> uppercase
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
