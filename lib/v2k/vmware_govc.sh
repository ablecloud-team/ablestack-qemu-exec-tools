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

# NOTE:
# - We intentionally rely on govc commands only.
# - Hard power-off is the most reliable option in the field.
#   govc vm.power -off -force <vm> is confirmed in multiple references. :contentReference[oaicite:1]{index=1}

v2k_vmware_vm_power_state() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"
  # govc vm.info -json provides runtime.powerState; fallback to empty.
  govc vm.info -json "${vm}" 2>/dev/null \
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
    govc vm.power -off -force "${vm}"
  else
    govc vm.power -off "${vm}"
  fi

  v2k_vmware_vm_wait_poweroff "${manifest}" "${timeout}"
}

# Best-effort “guest shutdown” (only if govc supports it on this build).
# - If unsupported or fails, caller may fallback to poweroff.
v2k_vmware_vm_shutdown_guest_best_effort() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"

  # Detect supported flags dynamically (avoid hard dependency on exact govc version).
  local help
  help="$(govc vm.power -h 2>&1 || true)"

  # Commonly seen flags in some builds: -shutdown / -reboot / -reset / etc.
  if echo "${help}" | grep -q -- '-shutdown'; then
    govc vm.power -shutdown "${vm}"
    return 0
  fi

  return 1
}

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

v2k_is_ipv4() {
  local s="${1:-}"
  [[ "${s}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  # 0-255 범위는 엄격 체크 안 함(필요 시 보강)
  return 0
}

v2k_resolve_ipv4() {
  local host="$1"
  # DNS/hosts 기반 IPv4 1개만 선택
  getent ahostsv4 "${host}" 2>/dev/null | awk 'NR==1{print $1; exit}'
}

v2k_vmware_esxi_mgmt_ip_from_hostinfo_json() {
  local hostinfo_json="$1"
  printf '%s' "${hostinfo_json}" | jq -r '
    (.hostSystems[0].config.virtualNicManagerInfo.netConfig // [])
    | map(select(.nicType=="management"))[0] // {} as $m
    | ($m.selectedVnic[0] // "") as $sel
    | ($m.candidateVnic // []) as $c
    | (
        ( $c | map(select(.key==$sel)) | .[0].spec.ip.ipAddress )
        // ( $c[0].spec.ip.ipAddress )
        // ""
      )
  '
}

v2k_vmware_inventory_json() {
  local vm="$1" vcenter="$2"
  v2k_require_govc_env

  local vm_info dev_info
  local host_moref host_name hostinfo_json
  local esxi_mgmt_ip esxi_thumbprint

  vm_info="$(govc vm.info -json "${vm}")"
  dev_info="$(govc device.info -json -vm "${vm}")"

  # 1) VM이 올라간 HostSystem MoRef 추출
  host_moref="$(
    printf '%s' "${vm_info}" | jq -r '
      .virtualMachines[0] as $v
      | ($v.runtime.host.value // $v.runtime.host.Value // $v.summary.runtime.host.value // $v.summary.runtime.host.Value // "")
    ' 2>/dev/null || echo ""
  )"

  # 2) host.info로 management IP + thumbprint 추출 (DNS 의존 제거)
  esxi_mgmt_ip=""
  esxi_thumbprint=""
  hostinfo_json=""

  # 2-1) MoRef 우선 조회
  if [[ -n "${host_moref}" && "${host_moref}" != "null" ]]; then
    hostinfo_json="$(govc host.info -json -host "${host_moref}" 2>/dev/null || true)"
  fi

  # 2-2) 파싱
  if [[ -n "${hostinfo_json}" ]]; then
    host_name="$(printf '%s' "${hostinfo_json}" | jq -r '.hostSystems[0].summary.config.name // empty' 2>/dev/null || true)"
    esxi_thumbprint="$(printf '%s' "${hostinfo_json}" | jq -r '.hostSystems[0].summary.config.sslThumbprint // empty' 2>/dev/null || true)"
    esxi_mgmt_ip="$(v2k_vmware_esxi_mgmt_ip_from_hostinfo_json "${hostinfo_json}" 2>/dev/null | head -n1 || true)"
  fi

  # 3) fallback: management IP가 비어있으면 host_name이 IP인지/resolve 가능한지 확인
  if [[ -z "${esxi_mgmt_ip}" && -n "${host_name}" ]]; then
    if v2k_is_ipv4 "${host_name}"; then
      esxi_mgmt_ip="${host_name}"
    else
      esxi_mgmt_ip="$(v2k_resolve_ipv4 "${host_name}")"
    fi
  fi

  jq -n --arg vm "${vm}" \
    --argjson vminfo "${vm_info}" \
    --argjson devinfo "${dev_info}" \
    --arg esxi_host "${esxi_mgmt_ip}" \
    --arg esxi_name "${host_name}" \
    --arg esxi_thumbprint "${esxi_thumbprint}" \
    '
    def VMINFO0: ($vminfo.virtualMachines[0] // {});

    # device.info 스키마: 현재 환경은 루트가 {"devices":[...]}
    def DEVICES:
      ( $devinfo.devices
        // $devinfo.virtualMachines[0].devices
        // $devinfo.VirtualMachines[0].Devices
        // []
      );

    # ---- helpers (jq 1.6 safe: use ? + //, no try/catch) ----
    def lbl($o): ($o.deviceInfo?.label // "");
    def typ($o): ($o.type // "");

    # 컨트롤러 분류: deviceInfo.label 우선
    def is_scsi_ctrl($o):
      (lbl($o) | ascii_downcase | test("^scsi controller"));

    def is_sata_ctrl($o):
      (lbl($o) | ascii_downcase | test("^sata controller"));

    def is_nvme_ctrl($o):
      (lbl($o) | ascii_downcase | test("^nvme controller"));

    # fallback: label이 비어있거나 예상과 다를 때 type 패턴으로 보조 식별
    def is_scsi_ctrl_by_type($o):
      (typ($o) | test("SCSIController$"))
      or (typ($o) | test("LsiLogic"))
      or (typ($o) | test("ParaVirtualSCSI"))
      or (typ($o) | test("BusLogic"));

    def controllers:
      (DEVICES
        | map(select(is_scsi_ctrl(.) or is_nvme_ctrl(.) or is_sata_ctrl(.) or is_scsi_ctrl_by_type(.)))
        | map({
            key: .key,
            type: .type,
            label: lbl(.),
            bus: (.busNumber // 0)
          })
      );

    def disks($ctls):
      (DEVICES
        | map(select(.type=="VirtualDisk"))
        | map(
            . as $d
            | ($ctls | map(select(.key==$d.controllerKey)) | .[0]) as $c
            | {
                disk_id: (
                  if $c != null and (($c.label|ascii_downcase) | test("^scsi controller")) then
                    ("scsi" + ($c.bus|tostring) + ":" + ($d.unitNumber|tostring))
                  elif $c != null and (($c.label|ascii_downcase) | test("^sata controller")) then
                    ("sata" + ($c.bus|tostring) + ":" + ($d.unitNumber|tostring))
                  elif $c != null and (($c.label|ascii_downcase) | test("^nvme controller")) then
                    ("nvme" + ($c.bus|tostring) + ":" + ($d.unitNumber|tostring))
                  else
                    ("devkey:" + ($d.key|tostring))
                  end
                ),
                label: ($d.deviceInfo?.label // $d.label // "VirtualDisk"),
                device_key: ($d.key|tostring),
                controller: (
                  if $c!=null then
                    {type:$c.type,bus:$c.bus,unit:$d.unitNumber,label:$c.label}
                  else
                    {type:"unknown",bus:0,unit:($d.unitNumber//0),label:""}
                  end
                ),
                vmdk: { path: ($d.backing?.fileName // "") },
                size_bytes: ($d.capacityInBytes // 0)
              }
          )
      );

    {
      vm: {
        name: $vm,
        moref: (VMINFO0.self?.value // ""),
        uuid: (VMINFO0.config?.uuid // "")
      },
      esxi_host: $esxi_host,
      esxi_name: $esxi_name,
      esxi_thumbprint: $esxi_thumbprint,
      disks: disks(controllers)
    }'
}

v2k_assign_target_paths() {
  local manifest="$1"
  local dst_root format storage_type
  dst_root="$(jq -r '.target.dst_root' "${manifest}")"
  format="$(jq -r '.target.format // "qcow2"' "${manifest}")"
  storage_type="$(jq -r '.target.storage.type // "file"' "${manifest}")"  # file|block

  # 확장자 결정 (file 타입만)
  local ext=""
  if [[ "${storage_type}" == "file" ]]; then
    case "${format}" in
      qcow2) ext="qcow2" ;;
      raw)   ext="raw" ;;
      *) echo "[ERR] Unsupported target.format: ${format}" >&2; return 2 ;;
    esac
  fi

  # per-disk override map (optional): .target.storage.map : { "scsi0:0": "/dev/sdb", "scsi0:1": "/dev/sdc" }
  # file 타입에서도 override 가능하게 함(예: 특정 파일명 강제)
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
                    # block 타입은 반드시 map으로 지정하도록 강제 (자동 할당 위험)
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

  # block 타입이면 반드시 override가 채워져야 함
  if [[ "${storage_type}" == "block" ]]; then
    local missing
    missing="$(jq -r '.disks[] | select(.transfer.target_path=="" or .transfer.target_path=="null") | .disk_id' "${manifest}" | wc -l)"
    if [[ "${missing}" -ne 0 ]]; then
      echo "[ERR] target.storage.type=block requires per-disk mapping: .target.storage.map{disk_id:\"/dev/...\"}" >&2
      echo "      Example: jq '.target.storage={type:\"block\",map:{\"scsi0:0\":\"/dev/sdb\",\"scsi0:1\":\"/dev/sdc\"}}' -c manifest.json" >&2
      return 2
    fi
  fi

  # 유니크 체크
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
  v2k_event INFO "snapshot.${which}" "" "snapshot_create_start" "{\"name\":\"${name}\"}"
  govc snapshot.create -vm "${vm}" -m=false -q=false "${name}" >/dev/null
  v2k_event INFO "snapshot.${which}" "" "snapshot_create_done" "{\"name\":\"${name}\"}"
}

v2k_vmware_snapshot_cleanup() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"
  govc snapshot.tree -vm "${vm}" >/dev/null 2>&1 || true
  v2k_event INFO "cleanup" "" "snapshot_cleanup_skip" "{\"reason\":\"v1 does not auto-remove snapshots for safety\"}"
}

v2k_vmware_cbt_enable_all() {
  local manifest="$1"
  v2k_require_govc_env
  local vm
  vm="$(jq -r '.source.vm.name' "${manifest}")"

  govc vm.change -vm "${vm}" -e "ctkEnabled=true" >/dev/null

  local count
  count="$(jq -r '.disks|length' "${manifest}")"
  local i
  for ((i=0;i<count;i++)); do
    local disk_id
    disk_id="$(jq -r ".disks[$i].disk_id" "${manifest}")"
    if [[ "${disk_id}" =~ ^scsi[0-9]+:[0-9]+$ ]]; then
      govc vm.change -vm "${vm}" -e "${disk_id}.ctkEnabled=true" >/dev/null
    else
      v2k_event INFO "cbt_enable" "${disk_id}" "cbt_enable_skip" "{\"reason\":\"non-scsi disk_id; cannot set scsiX:Y.ctkEnabled\"}"
    fi
  done

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
  govc object.collect -json "${vm_ref}" snapshot 2>/dev/null \
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

  # 1) nicType=="management" 우선
  local ip
  ip="$(
    printf '%s' "${hostinfo_json}" | jq -r '
      .hostSystems[0].config.virtualNicManagerInfo.netConfig // []
      | map(select(.nicType=="management"))
      | .[]
      | (.candidateVnic // [])
      | .[]
      | .spec.ip.ipAddress // empty
    ' 2>/dev/null | awk 'NF{print; exit}'
  )"

  # 2) 혹시 management가 없으면 selectedVnic가 있는 netConfig에서 후보 찾기(보수적 fallback)
  if [[ -z "${ip}" ]]; then
    ip="$(
      printf '%s' "${hostinfo_json}" | jq -r '
        .hostSystems[0].config.virtualNicManagerInfo.netConfig // []
        | .[]
        | select((.selectedVnic // []) | length > 0)
        | (.candidateVnic // [])
        | .[]
        | .spec.ip.ipAddress // empty
      ' 2>/dev/null | awk 'NF{print; exit}'
    )"
  fi

  # 3) 값이 JSON 덩어리/공백 포함이면 방어적으로 IPv4만 필터링
  if [[ -n "${ip}" ]]; then
    # 혹시 여러 줄이 섞여 들어오면 첫 IPv4만 고정
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
  if govc snapshot.remove -vm "${vm}" '*' >/dev/null 2>&1; then
    return 0
  fi

  # If it failed, surface stderr for diagnostics.
  # (Caller decides whether to treat as fatal.)
  govc snapshot.remove -vm "${vm}" '*' 2>&1 | sed 's/^/[govc] /' >&2
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

  # We may need multiple passes because snapshot trees can change as parents are removed.
  # Try up to N rounds until no matching snapshots remain.
  local round max_round
  max_round=10
  for ((round=1; round<=max_round; round++)); do
    local tree_json names
    tree_json="$(govc snapshot.tree -vm "${vm}" -json 2>/dev/null || true)"
    if [[ -z "${tree_json}" ]]; then
      # If there is no snapshot, govc may return empty/err. Treat as nothing to do.
      return 0
    fi

    # Extract all snapshot names from json (robust: scan all objects with Name field).
    # Filter by pattern and uniq.
    names="$(printf '%s' "${tree_json}" \
      | jq -r '.. | objects | .Name? // empty' 2>/dev/null \
      | grep -F "${pattern}" \
      | sort -u || true)"

    if [[ -z "${names}" ]]; then
      return 0
    fi

    # Best-effort delete each matching snapshot name.
    # NOTE: if duplicate names exist, govc may fail/act ambiguously; we keep best-effort.
    while IFS= read -r snap_name; do
      [[ -n "${snap_name}" ]] || continue
      govc snapshot.remove -vm "${vm}" "${snap_name}" >/dev/null 2>&1 || true
    done <<< "${names}"
  done

  # If we still have matching snapshots after max rounds, return non-zero for observability.
  # Print remaining names for diagnostics.
  {
    govc snapshot.tree -vm "${vm}" -json 2>/dev/null \
      | jq -r '.. | objects | .Name? // empty' 2>/dev/null \
      | grep -F "${pattern}" \
      | sort -u || true
  } | sed 's/^/[v2k] remaining migr snapshot: /' >&2
  return 1
}