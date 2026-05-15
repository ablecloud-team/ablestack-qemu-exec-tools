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

n2k_target_first_existing_file() {
  local path
  for path in "$@"; do
    [[ -f "${path}" ]] && {
      printf '%s' "${path}"
      return 0
    }
  done
  return 1
}

n2k_target_ovmf_code_path() {
  local secure_boot="${1:-false}"
  if [[ "${secure_boot}" == "true" ]]; then
    n2k_target_first_existing_file \
      /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd \
      /usr/share/OVMF/OVMF_CODE.secboot.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.fd \
      /usr/share/OVMF/OVMF_CODE.fd
    return
  fi

  n2k_target_first_existing_file \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd \
    /usr/share/OVMF/OVMF_CODE.secboot.fd
}

n2k_target_ovmf_vars_template_path() {
  local secure_boot="${1:-false}"
  if [[ "${secure_boot}" == "true" ]]; then
    n2k_target_first_existing_file \
      /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd \
      /usr/share/OVMF/OVMF_VARS.secboot.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.fd \
      /usr/share/OVMF/OVMF_VARS.fd
    return
  fi

  n2k_target_first_existing_file \
    /usr/share/edk2/ovmf/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd \
    /usr/share/OVMF/OVMF_VARS.secboot.fd
}

n2k_target_rbd_auth_xml() {
  local username secret_uuid secret_usage
  username="${N2K_RBD_USERNAME:-admin}"
  secret_uuid="${N2K_RBD_SECRET_UUID:-}"
  secret_usage="${N2K_RBD_SECRET_USAGE:-}"

  if [[ -z "${secret_uuid}" && -z "${secret_usage}" ]] && command -v virsh >/dev/null 2>&1; then
    if virsh secret-list 2>/dev/null | grep -Eq 'ceph[[:space:]]+client\.admin secret'; then
      secret_usage="client.admin secret"
    fi
  fi

  [[ -n "${secret_uuid}" || -n "${secret_usage}" ]] || return 0

  cat <<EOF
      <auth username='$(n2k_xml_escape "${username}")'>
EOF
  if [[ -n "${secret_uuid}" ]]; then
    cat <<EOF
        <secret type='ceph' uuid='$(n2k_xml_escape "${secret_uuid}")'/>
EOF
  else
    cat <<EOF
        <secret type='ceph' usage='$(n2k_xml_escape "${secret_usage}")'/>
EOF
  fi
  cat <<'EOF'
      </auth>
EOF
}

n2k_target_disk_xml() {
  local manifest="$1" idx="$2"
  local storage target_path target_format rbd_access_mode controller_type bus dev auth_xml krbd_device
  storage="$(jq -r '.target.storage.type // "file"' "${manifest}")"
  target_path="$(jq -r ".disks[${idx}].transfer.target_path" "${manifest}")"
  target_format="$(jq -r '.target.format // "qcow2"' "${manifest}")"
  rbd_access_mode="${N2K_RBD_ACCESS_MODE:-$(jq -r '.target.storage.rbd_access_mode // "librbd"' "${manifest}")}"
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
      case "${rbd_access_mode}" in
        librbd)
          auth_xml="$(n2k_target_rbd_auth_xml)"
          cat <<EOF
    <disk type='network' device='disk'>
      <driver name='qemu' type='raw' cache='none'/>
${auth_xml}
      <source protocol='rbd' name='$(n2k_xml_escape "${target_path#rbd:}")'/>
      <target dev='${dev}' bus='${bus}'/>
    </disk>
EOF
          ;;
        krbd)
          krbd_device="$(n2k_storage_rbd_krbd_device_path "${target_path}")"
          cat <<EOF
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none'/>
      <source dev='$(n2k_xml_escape "${krbd_device}")'/>
      <target dev='${dev}' bus='${bus}'/>
    </disk>
EOF
          ;;
        *)
          echo "Unsupported RBD access mode: ${rbd_access_mode}" >&2
          return 2
          ;;
      esac
      ;;
  esac
}

n2k_target_prepare_libvirt_storage() {
  local manifest="$1"
  local storage rbd_access_mode count idx target_path mapped
  storage="$(jq -r '.target.storage.type // "file"' "${manifest}")"
  rbd_access_mode="${N2K_RBD_ACCESS_MODE:-$(jq -r '.target.storage.rbd_access_mode // "librbd"' "${manifest}")}"

  [[ "${storage}" == "rbd" && "${rbd_access_mode}" == "krbd" ]] || return 0

  count="$(jq -r '.disks | length' "${manifest}")"
  for ((idx=0; idx<count; idx++)); do
    target_path="$(jq -r ".disks[${idx}].transfer.target_path" "${manifest}")"
    mapped="$(n2k_storage_map_rbd_krbd "${target_path}")"
    [[ -b "${mapped}" ]] || {
      echo "RBD krbd device is not a block device after map: ${mapped}" >&2
      return 2
    }
  done
}

n2k_target_generate_libvirt_xml() {
  local manifest="$1"
  local vm vcpu memory_mb fw secure_boot count idx xml disks_xml iface_xml mac
  local ovmf_code ovmf_vars ovmf_nvram loader_attrs
  vm="$(jq -r '.target.libvirt.name // .source.vm.name' "${manifest}")"
  vcpu="$(jq -r '(.source.vm.cpu // 0 | tonumber? // 0) as $v | if $v > 0 then $v else 2 end' "${manifest}")"
  memory_mb="$(jq -r '(.source.vm.memory_mb // 0 | tonumber? // 0) as $m | if $m > 0 then $m else 2048 end' "${manifest}")"
  fw="$(jq -r '.source.vm.firmware // empty' "${manifest}")"
  secure_boot="$(jq -r '.source.vm.secure_boot // false' "${manifest}")"
  if [[ "${secure_boot}" == "true" && -z "${fw}" ]]; then
    fw="efi"
  fi
  count="$(jq -r '.disks | length' "${manifest}")"

  ovmf_code=""
  ovmf_vars=""
  ovmf_nvram=""
  loader_attrs="readonly='yes' type='pflash'"
  if [[ "${secure_boot}" == "true" ]]; then
    loader_attrs+=" secure='yes'"
  fi
  if [[ "${fw}" == "efi" ]]; then
    ovmf_code="$(n2k_target_ovmf_code_path "${secure_boot}")" || {
      echo "OVMF_CODE firmware is required to define EFI target VM '${vm}'." >&2
      return 2
    }
    ovmf_vars="$(n2k_target_ovmf_vars_template_path "${secure_boot}")" || {
      echo "OVMF_VARS template is required to define EFI target VM '${vm}'." >&2
      return 2
    }
    ovmf_nvram="${N2K_WORKDIR}/artifacts/${vm}_VARS.fd"
  fi

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
EOF
    if [[ "${fw}" == "efi" ]]; then
      cat <<EOF
    <loader ${loader_attrs}>$(n2k_xml_escape "${ovmf_code}")</loader>
    <nvram template='$(n2k_xml_escape "${ovmf_vars}")'>$(n2k_xml_escape "${ovmf_nvram}")</nvram>
EOF
    fi
    cat <<EOF
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
  local vm="" state="" err_file="" rc=0
  command -v virsh >/dev/null 2>&1 || {
    echo "virsh is required to define target VM." >&2
    return 2
  }
  err_file="$(mktemp)"
  if virsh define "${xml}" >/dev/null 2>"${err_file}"; then
    rm -f "${err_file}"
    return 0
  fi
  rc=$?

  vm="$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "${xml}" | head -n 1)"
  if [[ -n "${vm}" ]] && grep -qi 'already exists' "${err_file}" && virsh dominfo "${vm}" >/dev/null 2>&1; then
    state="$(virsh domstate "${vm}" 2>/dev/null || true)"
    if [[ "${state}" == "shut off" ]]; then
      virsh undefine "${vm}" --nvram >/dev/null 2>&1 || virsh undefine "${vm}" >/dev/null
      virsh define "${xml}" >/dev/null
      rm -f "${err_file}"
      return 0
    fi
    echo "Target VM '${vm}' already exists and is not shut off: ${state}" >&2
  else
    cat "${err_file}" >&2
  fi
  rm -f "${err_file}"
  return "${rc}"
}
