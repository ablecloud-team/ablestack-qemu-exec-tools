#!/usr/bin/env bash
#
# install.sh - Development/source installer for ablestack-qemu-exec-tools
#
# Copyright 2025 ABLECLOUD
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

set -euo pipefail

INSTALL_PREFIX="/usr/local"
BIN_DIR="${INSTALL_PREFIX}/bin"
LIB_TARGET="${INSTALL_PREFIX}/lib/ablestack-qemu-exec-tools"
PAYLOAD_SRC="payload"
LIB_SRC="lib"
BIN_SRC="bin"
SHARE_SRC="share"
SYSTEMD_UNIT_DIR="/etc/systemd/system"

ISO_DEFAULT_DIR="/usr/share/ablestack/tools"
ISO_DEFAULT_PATH="${ISO_DEFAULT_DIR}/ablestack-qemu-exec-tools.iso"
COMPAT_TARGET_ROOT="/usr/share/ablestack/v2k/compat"

is_ablestack_host() {
  if [[ -f /etc/os-release ]] && grep -q '^PRETTY_NAME="ABLESTACK' /etc/os-release; then
    return 0
  fi
  return 1
}

need_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || MISSING+=("${cmd}")
}

install_bin_links() {
  local scripts=("$@")
  local script src target

  for script in "${scripts[@]}"; do
    src="${BIN_SRC}/${script}"
    target="${BIN_DIR}/${script%.sh}"
    if [[ -f "${src}" ]]; then
      echo "Linking executable: ${target} -> $(pwd)/${src}"
      mkdir -p "$(dirname "${target}")"
      ln -sf "$(pwd)/${src}" "${target}"
      chmod +x "${src}"
    else
      echo "Skipping missing executable: ${src}"
    fi
  done
}

install_lib_tree() {
  echo "Installing library tree: ${LIB_TARGET}"
  mkdir -p "${LIB_TARGET}"

  if [[ -d "${LIB_SRC}" ]]; then
    cp -a "${LIB_SRC}/"* "${LIB_TARGET}/" 2>/dev/null || true
    find "${LIB_TARGET}" -type f -name "*.sh" -exec chmod 755 {} \;
    find "${LIB_TARGET}" -type f \( -name "*.service" -o -name "*.ps1" \) -exec chmod 644 {} \; 2>/dev/null || true
  else
    echo "Skipping missing library source directory: ${LIB_SRC}"
  fi
}

install_compat_tree() {
  local compat_src="${SHARE_SRC}/ablestack/v2k/compat"
  if [[ ! -d "${compat_src}" ]]; then
    echo "Skipping missing compatibility profile tree: ${compat_src}"
    return 0
  fi

  echo "Installing compatibility profile tree: ${COMPAT_TARGET_ROOT}"
  sudo mkdir -p "$(dirname "${COMPAT_TARGET_ROOT}")"
  sudo rm -rf "${COMPAT_TARGET_ROOT}"
  sudo cp -a "${compat_src}" "${COMPAT_TARGET_ROOT}"

  sudo find "${COMPAT_TARGET_ROOT}" -type f \( -path '*/bin/govc' -o -path '*/venv/bin/python3' \) -exec chmod 755 {} \; 2>/dev/null || true
}

install_hangctl_units() {
  local conf_src="etc/ablestack-vm-hangctl.conf"
  local conf_dst="/etc/ablestack/ablestack-vm-hangctl.conf"
  local unit_src_dir="${LIB_SRC}/hangctl/systemd"

  if [[ -d "${unit_src_dir}" ]]; then
    echo "Installing hangctl systemd units into ${SYSTEMD_UNIT_DIR}"
    sudo mkdir -p "${SYSTEMD_UNIT_DIR}"
    if ls "${unit_src_dir}"/*.service >/dev/null 2>&1; then
      sudo cp -a "${unit_src_dir}"/*.service "${SYSTEMD_UNIT_DIR}/"
      sudo chmod 644 "${SYSTEMD_UNIT_DIR}"/*.service 2>/dev/null || true
    fi
    if ls "${unit_src_dir}"/*.timer >/dev/null 2>&1; then
      sudo cp -a "${unit_src_dir}"/*.timer "${SYSTEMD_UNIT_DIR}/"
      sudo chmod 644 "${SYSTEMD_UNIT_DIR}"/*.timer 2>/dev/null || true
    fi
    sudo systemctl daemon-reload 2>/dev/null || true
  else
    echo "Skipping missing hangctl systemd directory: ${unit_src_dir}"
  fi

  if [[ -f "${conf_src}" ]]; then
    echo "Installing default hangctl config if absent: ${conf_dst}"
    sudo mkdir -p "$(dirname "${conf_dst}")"
    if [[ -f "${conf_dst}" ]]; then
      echo "Keeping existing config: ${conf_dst}"
    else
      sudo cp -a "${conf_src}" "${conf_dst}"
      sudo chmod 644 "${conf_dst}" 2>/dev/null || true
      echo "Installed config: ${conf_dst}"
    fi
  else
    echo "Skipping missing hangctl config template: ${conf_src}"
  fi
}

install_payload_tree() {
  echo "Installing payload tree: ${LIB_TARGET}/payload"
  mkdir -p "${LIB_TARGET}/payload"
  if [[ -d "${PAYLOAD_SRC}" ]]; then
    rsync -a "${PAYLOAD_SRC}/" "${LIB_TARGET}/payload/" 2>/dev/null || \
      cp -a "${PAYLOAD_SRC}/"* "${LIB_TARGET}/payload/" 2>/dev/null || true
  else
    echo "Skipping missing payload source directory: ${PAYLOAD_SRC}"
  fi
}

ensure_iso_path() {
  echo "Ensuring ISO default directory exists: ${ISO_DEFAULT_DIR}"
  mkdir -p "${ISO_DEFAULT_DIR}"
  if [[ -f "${ISO_DEFAULT_PATH}" ]]; then
    echo "ISO already present: ${ISO_DEFAULT_PATH}"
  else
    echo "ISO not found: ${ISO_DEFAULT_PATH}"
    echo "Place the generated ISO there, or override ISO_PATH_DEFAULT in your shell environment."
  fi
}

write_profile_env() {
  local profile_d="/etc/profile.d/ablestack-qemu-exec-tools.sh"
  echo "Writing environment profile: ${profile_d}"
  cat <<EOF | sudo tee "${profile_d}" >/dev/null
# ablestack-qemu-exec-tools environment
export ABLESTACK_QEMU_EXEC_TOOLS_HOME="${LIB_TARGET}"
export ISO_PATH_DEFAULT="${ISO_DEFAULT_PATH}"
export V2K_COMPAT_ROOT="${COMPAT_TARGET_ROOT}"
EOF
}

print_summary() {
  cat <<EOF

Installation complete.

Examples:
  vm_autoinstall <domain>        ISO-based guest autoinstall
  vm_exec                        Execute guest commands through QGA
  ablestack_vm_hangctl health    Check hangctl health
  ablestack_vm_hangctl scan      Scan VMs for hang conditions

Systemd:
  systemctl enable --now ablestack-vm-hangctl.timer
  systemctl status ablestack-vm-hangctl.timer --no-pager -l

Notes:
  - Guest-injection scripts use payloads from ${LIB_TARGET}/payload
  - The default ISO path is ${ISO_DEFAULT_PATH}
  - Compatibility profiles are installed under ${COMPAT_TARGET_ROOT}
EOF
}

main() {
  local install_mode
  local bin_scripts=()
  MISSING=()

  if is_ablestack_host; then
    echo "ABLESTACK host detected. Installing host-oriented command set."
    install_mode="HOST"
  else
    echo "Generic Linux environment detected. Installing full command set."
    install_mode="VM"
  fi

  need_cmd jq
  need_cmd virsh
  need_cmd virt-inspector
  need_cmd virt-copy-in
  need_cmd virt-customize
  need_cmd virt-win-reg

  if ((${#MISSING[@]})); then
    echo "Missing required commands: ${MISSING[*]}" >&2
    echo "Recommended on Rocky 9: dnf -y install jq libvirt-client libguestfs-tools virt-install" >&2
    exit 1
  fi

  if [[ "${install_mode}" == "HOST" ]]; then
    bin_scripts=("vm_exec.sh" "vm_autoinstall.sh" "ablestack_v2k.sh" "ablestack_vm_hangctl.sh" "v2k_test_install.sh")
  else
    bin_scripts=("vm_exec.sh" "agent_policy_fix.sh" "cloud_init_auto.sh" "vm_autoinstall.sh" "ablestack_v2k.sh" "ablestack_vm_hangctl.sh" "v2k_test_install.sh")
  fi

  install_bin_links "${bin_scripts[@]}"
  install_lib_tree
  install_compat_tree
  install_hangctl_units
  install_payload_tree
  ensure_iso_path
  write_profile_env
  print_summary
}

main "$@"
