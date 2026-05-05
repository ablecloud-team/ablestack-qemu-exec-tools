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

n2k_xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "${s}"
}

n2k_disk_letter() {
  local n="$1"
  printf "%b" "\\$(printf '%03o' "$((97 + n))")"
}

n2k_disk_bus_from_inventory() {
  local controller_type="$1"
  controller_type="$(printf '%s' "${controller_type}" | tr '[:upper:]' '[:lower:]')"
  case "${controller_type}" in
    *sata*|*ide*) printf 'sata' ;;
    *virtio*) printf 'virtio' ;;
    *) printf 'scsi' ;;
  esac
}

n2k_target_disk_xml() {
  local manifest="$1" idx="$2"
  local storage target_path target_format controller_type bus dev
  storage="$(jq -r '.target.storage.type // "file"' "${manifest}")"
  target_path="$(jq -r ".disks[${idx}].transfer.target_path" "${manifest}")"
  target_format="$(jq -r '.target.format // "qcow2"' "${manifest}")"
  controller_type="$(jq -r ".disks[${idx}].controller.type // \"scsi\"" "${manifest}")"
  bus="$(n2k_disk_bus_from_inventory "${controller_type}")"
  dev="sd$(n2k_disk_letter "${idx}")"

  case "${storage}" in
    file)
      cat <<EOF
    <disk type='file' device='disk'>
      <driver name='qemu' type='$(n2k_xml_escape "${target_format}")' cache='none'/>
      <source file='$(n2k_xml_escape "${target_path}")'/>
      <target dev='${dev}' bus='${bus}'/>
    </disk>
EOF
      ;;
    block)
      cat <<EOF
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none'/>
      <source dev='$(n2k_xml_escape "${target_path}")'/>
      <target dev='${dev}' bus='${bus}'/>
    </disk>
EOF
      ;;
    rbd)
      cat <<EOF
    <disk type='network' device='disk'>
      <driver name='qemu' type='raw' cache='none'/>
      <source protocol='rbd' name='$(n2k_xml_escape "${target_path#rbd:}")'/>
      <target dev='${dev}' bus='${bus}'/>
    </disk>
EOF
      ;;
  esac
}

n2k_target_generate_libvirt_xml() {
  local manifest="$1"
  local vm vcpu memory_mb fw count idx xml disks_xml iface_xml mac
  vm="$(jq -r '.target.libvirt.name // .source.vm.name' "${manifest}")"
  vcpu="$(jq -r '.source.vm.cpu // 2' "${manifest}")"
  memory_mb="$(jq -r '.source.vm.memory_mb // 2048' "${manifest}")"
  fw="$(jq -r '.source.vm.firmware // empty' "${manifest}")"
  count="$(jq -r '.disks | length' "${manifest}")"

  disks_xml=""
  for ((idx=0; idx<count; idx++)); do
    disks_xml+="
$(n2k_target_disk_xml "${manifest}" "${idx}")"
  done

  mac="$(jq -r '.source.vm.nics[0].mac // empty' "${manifest}")"
  iface_xml=""
  if [[ -n "${mac}" ]]; then
    iface_xml="
    <interface type='network'>
      <mac address='$(n2k_xml_escape "${mac}")'/>
      <source network='default'/>
      <model type='virtio'/>
    </interface>"
  fi

  xml="${N2K_WORKDIR}/artifacts/${vm}.xml"
  mkdir -p "$(dirname "${xml}")"

  {
    cat <<EOF
<domain type='kvm'>
  <name>$(n2k_xml_escape "${vm}")</name>
  <memory unit='MiB'>${memory_mb}</memory>
  <vcpu placement='static'>${vcpu}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
EOF
    if [[ "${fw}" == "efi" ]]; then
      cat <<'EOF'
    <smm state='on'/>
EOF
    fi
    cat <<EOF
  </features>
  <cpu mode='host-passthrough'/>
  <devices>
    <controller type='scsi' index='0' model='virtio-scsi'/>
${disks_xml}
${iface_xml}
    <controller type='virtio-serial' index='0'/>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <video>
      <model type='vga' vram='16384' heads='1' primary='yes'/>
    </video>
    <graphics type='vnc' port='-1'/>
  </devices>
</domain>
EOF
  } > "${xml}"

  printf '%s' "${xml}"
}

n2k_target_define_libvirt() {
  local xml="$1"
  command -v virsh >/dev/null 2>&1 || {
    echo "virsh is required to define target VM." >&2
    return 2
  }
  virsh define "${xml}" >/dev/null
}
