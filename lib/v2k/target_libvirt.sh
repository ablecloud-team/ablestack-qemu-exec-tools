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

_v2k_trace_on() {
  [[ "${V2K_LIBVIRT_TRACE:-0}" == "1" ]]
}

_v2k_trace() {
  # Print to stdout so it appears in run.out (caller captures stdout)
  # Enable with: V2K_LIBVIRT_TRACE=1
  _v2k_trace_on || return 0
  echo "[v2k-libvirt] $*"
}

_v2k_trace_cmd() {
  # Usage: _v2k_trace_cmd <tag> <cmd...>
  local tag="$1"; shift || true
  _v2k_trace "CMD(${tag}): $*"
  "$@"
  local rc=$?
  _v2k_trace "RC(${tag})=${rc}"
  return "${rc}"
}

_v2k_trace_env_once() {
  # Print useful diagnostics once per process when tracing is enabled.
  _v2k_trace_on || return 0
  [[ "${V2K_LIBVIRT_TRACE_ENV_DUMPED:-0}" == "1" ]] && return 0
  export V2K_LIBVIRT_TRACE_ENV_DUMPED=1

  _v2k_trace "---- TRACE ENV START ----"
  _v2k_trace "whoami=$(whoami 2>/dev/null || echo '?') uid=$(id -u 2>/dev/null || echo '?')"
  _v2k_trace "groups=$(id -nG 2>/dev/null || echo '?')"
  _v2k_trace "pwd=$(pwd 2>/dev/null || echo '?')"
  _v2k_trace "V2K_WORKDIR=${V2K_WORKDIR:-<unset>}"
  _v2k_trace "PATH=${PATH}"
  _v2k_trace_cmd "virsh-version" virsh --version >/dev/null 2>&1 || true
  _v2k_trace "virsh.version=$(virsh --version 2>/dev/null || echo 'unknown')"
  _v2k_trace "virsh.default-uri=$(virsh uri 2>/dev/null || echo 'unknown')"
  _v2k_trace "virsh.qemu-system-uri=$(virsh -c qemu:///system uri 2>/dev/null || echo 'unknown')"
  _v2k_trace_cmd "virsh-list-all" virsh list --all >/dev/null 2>&1 || true
  _v2k_trace "---- TRACE ENV END ----"
}

_v2k_letter() {
  # 0->a, 1->b ...
  local n="$1"
  printf "%b" "\\$(printf '%03o' "$((97 + n))")"
}

_v2k_disk_bus_from_controller_type() {
  # Return: scsi|sata (default scsi)
  local t="$1"
  case "$t" in
    *AHCI*|*SATA*|*VirtualAHCIController*|*VirtualSATA*) echo "sata" ;;
    *) echo "scsi" ;;
  esac
}

_v2k_escape_xml() {
  # minimal xml escape for attributes/text
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//> /&gt; }"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  echo "$s"
}

_v2k_detect_main_bridge() {
  # ABLESTACK policy:
  # - Master bridge is strictly one of: bridge0, br0
  # - Do NOT auto-detect anything else

  local br=""

  # 1) brctl 기반 우선 확인
  if command -v brctl >/dev/null 2>&1; then
    # bridge name  bridge id  STP enabled  interfaces
    # bridge0     ...
    # br0         ...
    br="$(brctl show 2>/dev/null | awk 'NR>1 {print $1}')"

    for c in bridge0 br0; do
      if grep -qx "${c}" <<<"${br}"; then
        echo "${c}"
        return 0
      fi
    done
  fi

  # 2) fallback: bridge(8)
  if command -v bridge >/dev/null 2>&1; then
    # bridge link ... master bridge0 ...
    for c in bridge0 br0; do
      if bridge link 2>/dev/null | grep -qw "master ${c}"; then
        echo "${c}"
        return 0
      fi
    done
  fi

  # Not found
  return 1
}

v2k_target_generate_libvirt_xml() {
  local manifest="$1"
  local manifest="$1"
  shift || true

  _v2k_trace_env_once
  _v2k_trace "ENTER generate_libvirt_xml manifest=${manifest}"

  # Defaults (per requirement)
  local vcpu=2
  local mem_mib=2048

  # ABLESTACK default: use bridge (auto-detected), not libvirt network 'default'
  local net_name=""
  local bridge_name=""
  local vlan_id=""

  bridge_name="$(_v2k_detect_main_bridge 2>/dev/null || true)"
  _v2k_trace "default bridge(auto-detected)=${bridge_name:-<none>}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vcpu) vcpu="${2:-}"; shift 2 ;;
      --memory) mem_mib="${2:-}"; shift 2 ;; # MB == MiB 취급
      --network) net_name="${2:-}"; shift 2 ;;
      --bridge) bridge_name="${2:-}"; shift 2 ;;
      --vlan) vlan_id="${2:-}"; shift 2 ;;
      *) echo "target_libvirt: unknown option: $1" >&2; return 2 ;;
    esac
  done

  local vm
  vm="$(jq -r '.target.libvirt.name' "${manifest}")"
  _v2k_trace "VM name=${vm}"

  local xml="${V2K_WORKDIR}/artifacts/${vm}.xml"
  mkdir -p "$(dirname "${xml}")"

  local fmt st
  fmt="$(jq -r '.target.format // "qcow2"' "${manifest}")"
  st="$(jq -r '.target.storage.type // "file"' "${manifest}")"

  _v2k_trace "target.format=${fmt} target.storage.type=${st} vcpu=${vcpu} mem_mib=${mem_mib}"

  # driver attributes (policy)
  local driver_type
  driver_type="${fmt}"

  local disks_xml=""
  local count
  count="$(jq -r '.disks|length' "${manifest}")"

  # controller blocks (policy: scsi/sata only; no virtio-scsi)
  local have_scsi=0 have_sata=1
  local i
  for ((i=0;i<count;i++)); do
    local ctype bus
    ctype="$(jq -r ".disks[$i].controller.type // empty" "${manifest}")"
    bus="$(_v2k_disk_bus_from_controller_type "${ctype}")"
    [[ "$bus" == "sata" ]] && have_sata=1 || have_scsi=1
  done

  local controllers_xml=""
  if [[ "${have_scsi}" -eq 1 ]]; then
    # VMware SCSI(LSI 계열) 호환 우선: model=lsilogic
    controllers_xml+="
    <controller type='scsi' index='0' model='virtio-scsi'/>"
  fi
  if [[ "${have_sata}" -eq 1 ]]; then
    controllers_xml+="
    <controller type='sata' index='0'/>"
  fi

  local i
  for ((i=0;i<count;i++)); do
    local path bus ctype
    path="$(jq -r ".disks[$i].transfer.target_path" "${manifest}")"
    ctype="$(jq -r ".disks[$i].controller.type // empty" "${manifest}")"
    bus="$(_v2k_disk_bus_from_controller_type "${ctype}")"

    local dev_letter dev_name
    dev_letter="$(_v2k_letter "$i")"
    # scsi/sata 모두 sdX 네이밍 사용
    dev_name="sd${dev_letter}"

    local source_xml=""
    local disk_type=""
    case "${st}" in
      file)
        disk_type="file"
        source_xml="<source file='$(_v2k_escape_xml "${path}")'/>"
        ;;
      block)
        disk_type="block"
        source_xml="<source dev='$(_v2k_escape_xml "${path}")'/>"
        ;;
      *)
        echo "Unsupported target storage type for libvirt xml: ${st}" >&2
        return 31
        ;;
    esac

    disks_xml+="
    <disk type='${disk_type}' device='disk'>
      <driver name='qemu' type='${driver_type}' cache='none' io='io_uring'/>
      ${source_xml}
      <target dev='${dev_name}' bus='${bus}'/>
    </disk>"
  done

  local iface_xml=""
  if [[ -n "${bridge_name}" ]]; then
    iface_xml="
    <interface type='bridge'>
      <source bridge='$(_v2k_escape_xml "${bridge_name}")'/>"
    if [[ -n "${vlan_id}" ]]; then
      iface_xml+="
      <vlan><tag id='$(_v2k_escape_xml "${vlan_id}")'/></vlan>"
    fi
    iface_xml+="
      <model type='virtio'/>
    </interface>"
  else
    iface_xml="
    <interface type='network'>
      <source network='$(_v2k_escape_xml "${net_name}")'/>
      <model type='virtio'/>
    </interface>"
  fi

  cat > "${xml}" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <memory unit='MiB'>${mem_mib}</memory>
  <vcpu placement='static'>${vcpu}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'>
    <topology sockets='1' cores='${vcpu}' threads='1'/>
  </cpu>
  <devices>
    ${controllers_xml}
    ${disks_xml}
    ${iface_xml}
    <graphics type='vnc' port='-1'/>
  </devices>
</domain>
EOF

  _v2k_trace "Generated XML path=${xml}"
  echo "${xml}"
}

v2k_target_define_libvirt() {
  local xml="$1"
  _v2k_trace_env_once
  _v2k_trace "ENTER define_libvirt xml=${xml}"

  if _v2k_trace_on; then
    _v2k_trace "XML head (first 60 lines):"
    sed -n '1,60p' "${xml}" | while IFS= read -r line; do _v2k_trace "  ${line}"; done
  fi

  _v2k_trace_cmd "virsh-define" virsh define "${xml}" >/dev/null
}

v2k_target_start_vm() {
  local manifest="$1"
  local vm
  vm="$(jq -r '.target.libvirt.name' "${manifest}")"
  _v2k_trace_env_once
  _v2k_trace "ENTER start_vm vm=${vm}"
  _v2k_trace_cmd "virsh-start" virsh start "${vm}" >/dev/null
}

# ---------------------------------------------------------------------
# WinPE bootstrap helpers (libvirt)
# - boot order: cdrom only / hd
# - attach/detach cdrom
# - send-key SPACE loop
# - wait for shutdown
# ---------------------------------------------------------------------

v2k_target_domstate() {
  local vm="$1"
  _v2k_trace_env_once
  _v2k_trace "ENTER domstate vm=${vm}"
  virsh domstate "${vm}" 2>/dev/null | head -n1 | tr -d '
' || true
}

v2k_target_wait_shutdown() {
  local vm="$1"
  local timeout_sec="${2:-600}"
  _v2k_trace_env_once
  _v2k_trace "ENTER wait_shutdown vm=${vm} timeout_sec=${timeout_sec}"
  local start now elapsed
  start=$(date +%s)
  while true; do
    local st
    st="$(v2k_target_domstate "${vm}")"
    case "${st}" in
      "shut off"|"shutdown"|"crashed")
        _v2k_trace "wait_shutdown: state=${st} -> DONE"
        return 0
        ;;
    esac
    now=$(date +%s)
    elapsed=$((now - start))
    if (( elapsed >= timeout_sec )); then
      _v2k_trace "wait_shutdown: TIMEOUT elapsed=${elapsed}"
      return 1
    fi
    sleep 2
  done
}

v2k_target_send_key_space() {
  local vm="$1"
  local seconds="${2:-15}"
  _v2k_trace_env_once
  _v2k_trace "ENTER send_key_space vm=${vm} seconds=${seconds}"
  local i
  for ((i=0; i<seconds; i++)); do
    _v2k_trace_cmd "virsh-send-key" virsh send-key "${vm}" KEY_SPACE >/dev/null 2>&1 || true
    sleep 1
  done
}

v2k_target_pick_cdrom_target_dev() {
  # Pick an unused target dev name for CDROM.
  # Policy: start far from OS disks (default from 'l' => sdl)
  # Override start letter with: V2K_CDROM_DEV_START=l (single lowercase letter)
  local vm="$1"
  _v2k_trace_env_once
  _v2k_trace "ENTER pick_cdrom_target_dev vm=${vm}"

  local start="${V2K_CDROM_DEV_START:-l}"

  # Collect used target dev names (one per line)
  local used
  used="$(virsh domblklist "${vm}" 2>/dev/null | awk 'NR>2 && $1!="" {print $1}')"

  _v2k_trace "domblklist.used=$(echo "${used}" | tr '\n' ' ')"

  # Iterate from start..z
  local l
  for l in {a..z}; do
    # skip letters before start
    [[ "${l}" < "${start}" ]] && continue

    local dev="sd${l}"
    if ! grep -qx "${dev}" <<<"${used}"; then
      echo "${dev}"
      return 0
    fi
  done

  # Fallback
  echo "sdz"
}

v2k_target_attach_cdrom() {
  local vm="$1"
  local iso="$2"
  local target_dev="${3:-}"
  _v2k_trace_env_once
  [[ -n "${target_dev}" ]] || target_dev="$(v2k_target_pick_cdrom_target_dev "${vm}")"
  _v2k_trace "ENTER attach_cdrom vm=${vm} iso=${iso} target_dev=${target_dev}"
  _v2k_trace_cmd "virsh-attach-disk" virsh attach-disk "${vm}" "${iso}" "${target_dev}" \
    --type cdrom --mode readonly --targetbus sata --live --config >/dev/null
  echo "${target_dev}"
  _v2k_trace "attach_cdrom: picked target_dev=${target_dev}"
}

v2k_target_detach_disk() {
  local vm="$1"
  local target_dev="$2"
  _v2k_trace_env_once
  _v2k_trace "ENTER detach_disk vm=${vm} target_dev=${target_dev}"
  virsh detach-disk "${vm}" "${target_dev}" --config >/dev/null 2>&1 || true
}

_v2k_target_redefine_os_boot() {
  local vm="$1"
  local bootdev="$2"  # cdrom|hd
  _v2k_trace_env_once
  _v2k_trace "ENTER redefine_os_boot vm=${vm} bootdev=${bootdev}"
  local tmp
  tmp="${V2K_WORKDIR:-/tmp}/artifacts/${vm}.boot.xml"
  mkdir -p "$(dirname "${tmp}")"

  # Dump current domain XML
  _v2k_trace_cmd "virsh-dumpxml" virsh dumpxml "${vm}" > "${tmp}.in"

  # Remove existing <boot dev='...'/>
  perl -0777 -pe "s#<boot\s+dev='[^']+'\s*/>\s*##g" "${tmp}.in" > "${tmp}.mid"

  # Inject exactly one <boot dev='...'/>
  # IMPORTANT:
  # - Use Perl backreference \1 (NOT bash ${1})
  # - Avoid relying too much on specific newlines
  perl -0777 -pe "s#(<os>\s*<type[^>]*>[^<]*</type>\s*)#\\1    <boot dev='${bootdev}'/>\n#s" \
    "${tmp}.mid" > "${tmp}"

  # Define updated XML
  _v2k_trace_cmd "virsh-define-bootxml" virsh define "${tmp}" >/dev/null
}

v2k_target_set_boot_cdrom_only() {
  local vm="$1"
  _v2k_trace_env_once
  _v2k_trace "ENTER set_boot_cdrom_only vm=${vm}"
  _v2k_target_redefine_os_boot "${vm}" "cdrom"
}

v2k_target_set_boot_hd() {
  local vm="$1"
  _v2k_trace_env_once
  _v2k_trace "ENTER set_boot_hd vm=${vm}"
  _v2k_target_redefine_os_boot "${vm}" "hd"
}