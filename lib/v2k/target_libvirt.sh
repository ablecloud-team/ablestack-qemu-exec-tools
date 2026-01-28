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

# ---------------------------------------------------------------------
# Trace helpers
# ---------------------------------------------------------------------
_v2k_trace_on() {
  [[ "${V2K_LIBVIRT_TRACE:-0}" == "1" ]]
}

_v2k_trace() {
  _v2k_trace_on || return 0
  echo "[v2k-libvirt] $*" >&2
}

_v2k_trace_cmd() {
  local tag="$1"; shift || true
  _v2k_trace "CMD(${tag}): $*"
  "$@"
  local rc=$?
  _v2k_trace "RC(${tag})=${rc}"
  return "${rc}"
}

_v2k_trace_env_once() {
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
  _v2k_trace "---- TRACE ENV END ----"
}

# ---------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------
_v2k_letter() {
  local n="$1"
  printf "%b" "\\$(printf '%03o' "$((97 + n))")"
}

_v2k_escape_xml() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  echo "$s"
}

_v2k_disk_bus_from_controller_type() {
  case "$1" in
    *AHCI*|*SATA*|*VirtualAHCIController*|*VirtualSATA*) echo "sata" ;;
    *) echo "scsi" ;;
  esac
}

# ---------------------------------------------------------------------
# ABLESTACK OVMF resolver (FIXED, NO JSON)
# ---------------------------------------------------------------------
_v2k_ovmf_pick() {
  # Args: <secure_boot 0|1>
  local sb="${1:-0}"
  local base="/usr/share/edk2/ovmf"

  local code vars

  if [[ "${sb}" == "1" ]]; then
    code="${base}/OVMF_CODE.secboot.fd"
    if [[ -f "${base}/OVMF_VARS.secboot.fd" ]]; then
      vars="${base}/OVMF_VARS.secboot.fd"
    else
      vars="${base}/OVMF_VARS.fd"
    fi
  else
    code="${base}/OVMF_CODE.fd"
    vars="${base}/OVMF_VARS.fd"
  fi

  [[ -f "${code}" ]] || { echo "Missing OVMF code: ${code}" >&2; return 1; }
  [[ -f "${vars}" ]] || { echo "Missing OVMF vars template: ${vars}" >&2; return 1; }

  # ABLESTACK policy: .fd == qcow2
  echo "${code}"
  echo "qcow2"
  echo "${vars}"
  echo "qcow2"
}

# ---------------------------------------------------------------------
# Bridge auto-detect (unchanged)
# ---------------------------------------------------------------------
_v2k_detect_main_bridge() {
  if command -v brctl >/dev/null 2>&1; then
    for b in bridge0 br0; do
      brctl show | awk 'NR>1 {print $1}' | grep -qx "${b}" && {
        echo "${b}"
        return 0
      }
    done
  fi
  return 1
}

# ---------------------------------------------------------------------
# Generate libvirt XML
# ---------------------------------------------------------------------
v2k_target_generate_libvirt_xml() {
  local manifest="$1"
  shift || true

  _v2k_trace_env_once
  _v2k_trace "ENTER generate_libvirt_xml manifest=${manifest}"

  local vm
  vm="$(jq -r '.target.libvirt.name' "${manifest}")"

  local vcpu mem_mib
  vcpu="$(jq -r '.source.vm.cpu // 2' "${manifest}")"
  mem_mib="$(jq -r '.source.vm.memory_mb // 2048' "${manifest}")"

  local fw secure_boot tpm
  fw="$(jq -r '.source.vm.firmware // empty' "${manifest}")"
  secure_boot="$(jq -r '.source.vm.secure_boot // false' "${manifest}")"
  tpm="$(jq -r '.source.vm.tpm // false' "${manifest}")"

  local bridge
  bridge="$(_v2k_detect_main_bridge || true)"

  local os_xml features_xml tpm_xml=""
  features_xml="<features><acpi/><apic/></features>"

  if [[ "${fw}" == "efi" ]]; then
    local sb=0
    [[ "${secure_boot}" == "true" ]] && sb=1

    local -a fw
    mapfile -t fw < <(_v2k_ovmf_pick "${sb}")
    local code_path="${fw[0]:-}"
    local code_fmt="${fw[1]:-}"
    local vars_path="${fw[2]:-}"
    local vars_fmt="${fw[3]:-}"

    # 방어(필수): 비어있으면 즉시 실패
    if [[ -z "${code_path}" || -z "${code_fmt}" || -z "${vars_path}" || -z "${vars_fmt}" ]]; then
      echo "OVMF pick returned empty fields: code_path='${code_path}' code_fmt='${code_fmt}' vars_path='${vars_path}' vars_fmt='${vars_fmt}'" >&2
      return 41
    fi

    local nvram="/var/lib/libvirt/qemu/nvram/${vm}_VARS.fd"

    os_xml="
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' secure='$( [[ "${sb}" -eq 1 ]] && echo yes || echo no )' type='pflash' format='${code_fmt}'>$(_v2k_escape_xml "${code_path}")</loader>
    <nvram template='$(_v2k_escape_xml "${vars_path}")' templateFormat='${vars_fmt}' format='${vars_fmt}'>$(_v2k_escape_xml "${nvram}")</nvram>
    <boot dev='hd'/>
  </os>"

    features_xml="<features><acpi/><apic/><smm state='on'/></features>"

    if [[ "${tpm}" == "true" ]]; then
      tpm_xml="
    <tpm model='tpm-crb'>
      <backend type='emulator' version='2.0'/>
    </tpm>"
    fi
  else
    os_xml="
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>"
  fi

  local disks_xml=""
  local count
  count="$(jq -r '.disks | length' "${manifest}")"

  for ((i=0;i<count;i++)); do
    local path bus dev
    path="$(jq -r ".disks[$i].transfer.target_path" "${manifest}")"
    bus="$(_v2k_disk_bus_from_controller_type "$(jq -r ".disks[$i].controller.type // empty" "${manifest}")")"
    dev="sd$(_v2k_letter "$i")"

    disks_xml+="
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='io_uring'/>
      <source file='$(_v2k_escape_xml "${path}")'/>
      <target dev='${dev}' bus='${bus}'/>
    </disk>"
  done

  local iface_xml=""
  local mac
  mac="$(jq -r '.source.vm.nics[0].mac // empty' "${manifest}")"
  if [[ -n "${mac}" && -n "${bridge}" ]]; then
    iface_xml="
    <interface type='bridge'>
      <mac address='$(_v2k_escape_xml "${mac}")'/>
      <source bridge='$(_v2k_escape_xml "${bridge}")'/>
      <model type='virtio'/>
      <filterref filter='allow-all-traffic'/>
      <link state='down'/>
    </interface>"
  fi

  local xml="${V2K_WORKDIR}/artifacts/${vm}.xml"
  mkdir -p "$(dirname "${xml}")"

  cat > "${xml}" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <memory unit='MiB'>${mem_mib}</memory>
  <vcpu placement='static'>${vcpu}</vcpu>
  ${os_xml}
  ${features_xml}
  <cpu mode='host-passthrough'>
    <topology sockets='1' cores='${vcpu}' threads='1'/>
  </cpu>
  <devices>
    <controller type='scsi' index='0' model='virtio-scsi'/>
    ${disks_xml}
    ${iface_xml}
    ${tpm_xml}
    <video>
      <model type='virtio' heads='1' primary='yes'/>
    </video>
    <graphics type='vnc' port='-1'/>
  </devices>
</domain>
EOF

  _v2k_trace "Generated XML path=${xml}"
  echo "${xml}"
}

# ---------------------------------------------------------------------
# Define & start
# ---------------------------------------------------------------------
v2k_target_define_libvirt() {
  local xml="$1"
  _v2k_trace_cmd "virsh-define" virsh define "${xml}" >/dev/null
}

v2k_target_start_vm() {
  local manifest="$1"
  local vm
  vm="$(jq -r '.target.libvirt.name' "${manifest}")"
  _v2k_trace_cmd "virsh-start" virsh start "${vm}" >/dev/null
}

v2k_target_set_uefi_secureboot() {
  local vm="$1"
  local on="${2:-1}" # 1=enable secure, 0=disable secure

  _v2k_trace_env_once
  _v2k_trace "ENTER set_uefi_secureboot vm=${vm} on=${on}"

  local tmp
  tmp="${V2K_WORKDIR:-/tmp}/artifacts/${vm}.uefi.xml"
  mkdir -p "$(dirname "${tmp}")"

  _v2k_trace_cmd "virsh-dumpxml" virsh dumpxml "${vm}" > "${tmp}.in"

  local base="/usr/share/edk2/ovmf"
  local code vars
  local secure_attr firmware_block=""

  if [[ "${on}" == "1" ]]; then
    code="${base}/OVMF_CODE.secboot.fd"
    if [[ -f "${base}/OVMF_VARS.secboot.fd" ]]; then
      vars="${base}/OVMF_VARS.secboot.fd"
    else
      vars="${base}/OVMF_VARS.fd"
    fi
    secure_attr="yes"
    firmware_block=$'\n    <firmware>\n      <feature enabled='\''yes'\'' name='\''enrolled-keys'\''/>\n      <feature enabled='\''yes'\'' name='\''secure-boot'\''/>\n    </firmware>\n'
  else
    code="${base}/OVMF_CODE.fd"
    vars="${base}/OVMF_VARS.fd"
    secure_attr="no"
    firmware_block=""  # WinPE용: firmware feature block 제거(가장 호환성 좋음)
  fi

  [[ -f "${code}" ]] || { echo "Missing OVMF code: ${code}" >&2; return 1; }
  [[ -f "${vars}" ]] || { echo "Missing OVMF vars: ${vars}" >&2; return 1; }

  # 1) <loader> 완전 제거
  perl -0777 -pe "s#<loader[^>]*>[^<]*</loader>##s" \
    "${tmp}.in" > "${tmp}.mid"

  # 2) <firmware> 블록도 완전 제거 (남아있으면 on/off 불일치의 근본 원인)
  perl -0777 -i -pe "s#<firmware>.*?</firmware>\s*##s" "${tmp}.mid"

  # 3) <type> 뒤에 loader + (필요 시) firmware block 삽입
  perl -0777 -i -pe "s#(<type[^>]*>[^<]*</type>)#\$1\n    <loader readonly='yes' type='pflash' format='qcow2' secure='${secure_attr}'>${code}</loader>${firmware_block}#s" \
    "${tmp}.mid"

  # 4) nvram 정규화 (template/format 일관 유지)
  perl -0777 -i -pe "s#<nvram[^>]*>#<nvram template='${vars}' templateFormat='qcow2' format='qcow2'>#s" \
    "${tmp}.mid"

  _v2k_trace_cmd "virsh-define-uefi" virsh define "${tmp}.mid" >/dev/null
}

# ---------------------------------------------------------------------
# Boot order helpers (cdrom only / hd)
# ---------------------------------------------------------------------
v2k_target_set_boot_cdrom_only() {
  local vm="$1"

  _v2k_trace_env_once
  _v2k_trace "ENTER set_boot_cdrom_only vm=${vm}"

  local tmp
  tmp="${V2K_WORKDIR:-/tmp}/artifacts/${vm}.boot.xml"
  mkdir -p "$(dirname "${tmp}")"

  _v2k_trace_cmd "virsh-dumpxml-boot" virsh dumpxml "${vm}" > "${tmp}.in"

  # 1) 기존 <boot .../> 전부 제거
  perl -0777 -pe "s#\s*<boot[^>]*/>\s*##sg" "${tmp}.in" > "${tmp}.mid"

  # 2) <os> 내부에 <boot dev='cdrom'/> 1개만 삽입
  #    - <type ...> 바로 뒤에 넣는다.
  perl -0777 -i -pe "s#(<os[^>]*>\s*<type[^>]*>[^<]*</type>)#\$1\n    <boot dev='cdrom'/>#s" \
    "${tmp}.mid"

  _v2k_trace_cmd "virsh-define-boot-cdrom" virsh define "${tmp}.mid" >/dev/null
}

v2k_target_set_boot_hd() {
  local vm="$1"

  _v2k_trace_env_once
  _v2k_trace "ENTER set_boot_hd vm=${vm}"

  local tmp
  tmp="${V2K_WORKDIR:-/tmp}/artifacts/${vm}.boot.xml"
  mkdir -p "$(dirname "${tmp}")"

  _v2k_trace_cmd "virsh-dumpxml-boot" virsh dumpxml "${vm}" > "${tmp}.in"

  # 1) 기존 <boot .../> 전부 제거
  perl -0777 -pe "s#\s*<boot[^>]*/>\s*##sg" "${tmp}.in" > "${tmp}.mid"

  # 2) <os> 내부에 <boot dev='hd'/> 1개만 삽입
  perl -0777 -i -pe "s#(<os[^>]*>\s*<type[^>]*>[^<]*</type>)#\$1\n    <boot dev='hd'/>#s" \
    "${tmp}.mid"

  _v2k_trace_cmd "virsh-define-boot-hd" virsh define "${tmp}.mid" >/dev/null
}

v2k_target_detach_disk() {
  local vm="$1"
  local target_dev="$2"

  _v2k_trace_env_once
  _v2k_trace "ENTER detach_disk vm=${vm} dev=${target_dev}"

  [[ -n "${target_dev}" ]] || return 0

  # persistent detach
  _v2k_trace_cmd "virsh-detach-disk" \
    virsh detach-disk "${vm}" "${target_dev}" --persistent >/dev/null
}

# ---------------------------------------------------------------------
# Input automation (press SPACE repeatedly)
# ---------------------------------------------------------------------
v2k_target_send_key_space() {
  local vm="$1"
  local seconds="${2:-15}"

  _v2k_trace_env_once
  _v2k_trace "ENTER send_key_space vm=${vm} seconds=${seconds}"

  local i
  for ((i=0; i<seconds; i++)); do
    # SPACE == keycode 57 (linux input keycode)
    # virsh send-key accepts keycodes; 'KEY_SPACE' is not always available.
    virsh send-key "${vm}" KEY_SPACE >/dev/null 2>&1 \
      || virsh send-key "${vm}" 57 >/dev/null 2>&1 \
      || true
    sleep 1
  done
}

# ---------------------------------------------------------------------
# Wait for VM shutdown (polling)
# ---------------------------------------------------------------------
v2k_target_wait_shutdown() {
  local vm="$1"
  local timeout="${2:-600}"

  _v2k_trace_env_once
  _v2k_trace "ENTER wait_shutdown vm=${vm} timeout=${timeout}"

  local start now state
  start="$(date +%s)"

  while true; do
    state="$(virsh domstate "${vm}" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]' || echo "unknown")"
    case "${state}" in
      shut\ off|shutdown|shutoff)
        _v2k_trace "wait_shutdown: vm=${vm} state=${state} -> done"
        return 0
        ;;
    esac

    now="$(date +%s)"
    if (( now - start >= timeout )); then
      _v2k_trace "wait_shutdown: timeout vm=${vm} last_state=${state}"
      return 1
    fi
    sleep 2
  done
}

# CDROM 후보: sdv..sdz -> sdaa..sdaz -> sdba..sdbz (정방향)
_v2k_target_gen_dev_candidates_cdrom() {
  local c b
  for c in v w x y z; do echo "sd${c}"; done
  for b in {a..z}; do echo "sda${b}"; done
  for b in {a..z}; do echo "sdb${b}"; done
}

# virsh dumpxml에서 현재 사용중 target dev 목록 추출
_v2k_target_list_used_devs_from_xml() {
  local vm="$1"
  virsh dumpxml "${vm}" 2>/dev/null \
    | sed -n "s/.*<target[^>]*dev='\([^']\+\)'.*/\1/p" \
    | sort -u
}

# 이번 run에서 이미 할당한 cdrom dev 기록 파일(덤프 반영 지연도 방어)
_v2k_target_cdrom_alloc_file() {
  local vm="$1"
  echo "${V2K_WORKDIR:-/tmp}/artifacts/.cdrom_devs.${vm}.txt"
}

_v2k_target_pick_free_cdrom_dev() {
  local vm="$1"
  local alloc_file used_xml used_run used_all dev

  alloc_file="$(_v2k_target_cdrom_alloc_file "${vm}")"
  mkdir -p "$(dirname "${alloc_file}")"
  touch "${alloc_file}"

  used_xml="$(_v2k_target_list_used_devs_from_xml "${vm}" || true)"
  used_run="$(cat "${alloc_file}" 2>/dev/null || true)"

  # 두 목록 합쳐서 membership 검사
  used_all="$(printf "%s\n%s\n" "${used_xml}" "${used_run}" | sed '/^$/d' | sort -u)"

  while read -r dev; do
    echo "${used_all}" | grep -qx "${dev}" && continue
    echo "${dev}" >> "${alloc_file}"
    echo "${dev}"
    return 0
  done < <(_v2k_target_gen_dev_candidates_cdrom)

  return 1
}

v2k_target_attach_cdrom() {
  local vm="$1"
  local iso="$2"

  _v2k_trace_env_once
  _v2k_trace "ENTER attach_cdrom vm=${vm} iso=${iso}"

  [[ -f "${iso}" ]] || { echo "ISO not found: ${iso}" >&2; return 2; }

  local dev
  dev="$(_v2k_target_pick_free_cdrom_dev "${vm}")" || {
    echo "No free cdrom dev available for ${vm}" >&2
    return 3
  }

  # ✅ SATA로 강제 (드라이버 중립) + persistent
  _v2k_trace_cmd "virsh-attach-disk-cdrom" \
    virsh attach-disk "${vm}" "${iso}" "${dev}" \
      --type cdrom --mode readonly --persistent --targetbus sata >/dev/null

  echo "${dev}"
}
