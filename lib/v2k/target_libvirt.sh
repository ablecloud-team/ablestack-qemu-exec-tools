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

v2k_target_generate_libvirt_xml() {
  local manifest="$1"
  local vm
  vm="$(jq -r '.target.libvirt.name' "${manifest}")"
  local dst_root
  dst_root="$(jq -r '.target.dst_root' "${manifest}")"

  local xml="${V2K_WORKDIR}/artifacts/${vm}.xml"
  mkdir -p "$(dirname "${xml}")"

  local disks_xml=""
  local count
  count="$(jq -r '.disks|length' "${manifest}")"
  local i
  for ((i=0;i<count;i++)); do
    local path
    path="$(jq -r ".disks[$i].transfer.target_path" "${manifest}")"
    disks_xml+="
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${path}'/>
      <target dev='vd$(printf "%c" $((97+i)))' bus='virtio'/>
    </disk>"
  done

  cat > "${xml}" <<EOF
<domain type='kvm'>
  <name>${vm}</name>
  <memory unit='MiB'>2048</memory>
  <vcpu>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough'/>
  <devices>
    ${disks_xml}
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <graphics type='vnc' port='-1'/>
  </devices>
</domain>
EOF

  echo "${xml}"
}

v2k_target_define_libvirt() {
  local xml="$1"
  virsh define "${xml}" >/dev/null
}

v2k_target_start_vm() {
  local manifest="$1"
  local vm
  vm="$(jq -r '.target.libvirt.name' "${manifest}")"
  virsh start "${vm}" >/dev/null
}
