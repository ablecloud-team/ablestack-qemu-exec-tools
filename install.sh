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
COMPLETIONS_TARGET="/usr/share/bash-completion/completions"

ISO_DEFAULT_DIR="/usr/share/ablestack/tools"
ISO_DEFAULT_PATH="${ISO_DEFAULT_DIR}/ablestack-qemu-exec-tools.iso"
COMPAT_TARGET_ROOT="/usr/share/ablestack/v2k/compat"

is_ablestack_host() {
  if [[ -f /etc/os-release ]] && grep -q '^PRETTY_NAME="ABLESTACK' /etc/os-release; then
    return 0
  fi
  return 1
}

if is_ablestack_host; then
  echo "Detected ABLESTACK Host. Installing host-oriented tool set."
  INSTALL_MODE="HOST"
else
  echo "Detected generic Linux environment. Installing full tool set."
  INSTALL_MODE="VM"
fi

echo "Starting ablestack-qemu-exec-tools installation."

MISSING=()

need_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || MISSING+=("${cmd}")
}

need_cmd virsh
need_cmd virt-inspector
need_cmd virt-copy-in
need_cmd virt-customize
need_cmd virt-win-reg

if ((${#MISSING[@]})); then
  echo "Missing required commands: ${MISSING[*]}"
  echo "Example on Rocky 9: dnf -y install jq libvirt-client libguestfs-tools virt-install"
  exit 1
fi

if [[ "${INSTALL_MODE}" == "HOST" ]]; then
  BIN_SCRIPTS=(
    "vm_exec.sh"
    "vm_autoinstall.sh"
    "ablestack_v2k.sh"
    "ablestack_vm_hangctl.sh"
    "ablestack_vm_ftctl.sh"
    "ablestack_vm_ftctl_selftest.sh"
    "v2k_test_install.sh"
  )
else
  BIN_SCRIPTS=(
    "vm_exec.sh"
    "agent_policy_fix.sh"
    "cloud_init_auto.sh"
    "vm_autoinstall.sh"
    "ablestack_v2k.sh"
    "ablestack_vm_hangctl.sh"
    "ablestack_vm_ftctl.sh"
    "ablestack_vm_ftctl_selftest.sh"
    "v2k_test_install.sh"
  )
fi

echo "Installing executable symlinks into ${BIN_DIR}"
for script in "${BIN_SCRIPTS[@]}"; do
  src="${BIN_SRC}/${script}"
  target="${BIN_DIR}/${script%.sh}"
  if [[ -f "${src}" ]]; then
    mkdir -p "$(dirname "${target}")"
    ln -sf "$(pwd)/${src}" "${target}"
    chmod +x "${src}"
    echo "  linked ${target} -> $(pwd)/${src}"
  else
    echo "  skipped missing script: ${src}"
  fi
done

echo "Installing libraries into ${LIB_TARGET}"
mkdir -p "${LIB_TARGET}"
if [[ -d "${LIB_SRC}" ]]; then
  cp -a "${LIB_SRC}/"* "${LIB_TARGET}/" 2>/dev/null || true
  find "${LIB_TARGET}" -type f -name "*.sh" -exec chmod 755 {} \;
  find "${LIB_TARGET}" -type f \( -name "*.service" -o -name "*.ps1" \) -exec chmod 644 {} \; 2>/dev/null || true
else
  echo "  skipped missing library directory: ${LIB_SRC}"
fi

if [[ -d "${SHARE_SRC}/ablestack/v2k/compat" ]]; then
  echo "Installing compatibility profile tree into ${COMPAT_TARGET_ROOT}"
  sudo mkdir -p "$(dirname "${COMPAT_TARGET_ROOT}")"
  sudo rm -rf "${COMPAT_TARGET_ROOT}"
  sudo cp -a "${SHARE_SRC}/ablestack/v2k/compat" "${COMPAT_TARGET_ROOT}"
else
  echo "Skipping compatibility profile install: ${SHARE_SRC}/ablestack/v2k/compat"
fi

if [[ -d "completions" ]]; then
  echo "Installing bash completions into ${COMPLETIONS_TARGET}"
  sudo mkdir -p "${COMPLETIONS_TARGET}"
  for comp in ablestack_vm_ftctl ablestack_v2k; do
    if [[ -f "completions/${comp}" ]]; then
      sudo cp -a "completions/${comp}" "${COMPLETIONS_TARGET}/${comp}"
      sudo chmod 644 "${COMPLETIONS_TARGET}/${comp}" 2>/dev/null || true
      echo "  installed completion: ${comp}"
    fi
  done
fi

install_units_and_config() {
  local unit_src_dir="$1"
  local conf_src="$2"
  local conf_dst="$3"
  local label="$4"

  if [[ -d "${unit_src_dir}" ]]; then
    echo "Installing ${label} systemd units into ${SYSTEMD_UNIT_DIR}"
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
    echo "Skipping ${label} systemd units: ${unit_src_dir}"
  fi

  if [[ -f "${conf_src}" ]]; then
    echo "Checking ${label} config install: ${conf_dst}"
    sudo mkdir -p "$(dirname "${conf_dst}")"
    if [[ -f "${conf_dst}" ]]; then
      echo "  keeping existing config: ${conf_dst}"
    else
      sudo cp -a "${conf_src}" "${conf_dst}"
      sudo chmod 644 "${conf_dst}" 2>/dev/null || true
      echo "  installed config: ${conf_dst}"
    fi
  else
    echo "Skipping ${label} config install: ${conf_src}"
  fi
}

install_units_and_config \
  "${LIB_SRC}/hangctl/systemd" \
  "etc/ablestack-vm-hangctl.conf" \
  "/etc/ablestack/ablestack-vm-hangctl.conf" \
  "hangctl"

install_units_and_config \
  "${LIB_SRC}/ftctl/systemd" \
  "etc/ablestack-vm-ftctl.conf" \
  "/etc/ablestack/ablestack-vm-ftctl.conf" \
  "ftctl"

FTCTL_CLUSTER_CONF_SRC="etc/ablestack-vm-ftctl-cluster.conf"
FTCTL_CLUSTER_CONF_DST="/etc/ablestack/ablestack-vm-ftctl-cluster.conf"
FTCTL_CLUSTER_HOSTS_DST="/etc/ablestack/ftctl-cluster.d/hosts"

if [[ -f "${FTCTL_CLUSTER_CONF_SRC}" ]]; then
  echo "Checking ftctl cluster config install: ${FTCTL_CLUSTER_CONF_DST}"
  sudo mkdir -p "$(dirname "${FTCTL_CLUSTER_CONF_DST}")"
  sudo mkdir -p "${FTCTL_CLUSTER_HOSTS_DST}"
  if [[ -f "${FTCTL_CLUSTER_CONF_DST}" ]]; then
    echo "  keeping existing cluster config: ${FTCTL_CLUSTER_CONF_DST}"
  else
    sudo cp -a "${FTCTL_CLUSTER_CONF_SRC}" "${FTCTL_CLUSTER_CONF_DST}"
    sudo chmod 644 "${FTCTL_CLUSTER_CONF_DST}" 2>/dev/null || true
    echo "  installed cluster config: ${FTCTL_CLUSTER_CONF_DST}"
  fi
else
  echo "Skipping ftctl cluster config install: ${FTCTL_CLUSTER_CONF_SRC}"
fi

echo "Installing payloads into ${LIB_TARGET}/payload"
mkdir -p "${LIB_TARGET}/payload"
if [[ -d "${PAYLOAD_SRC}" ]]; then
  rsync -a "${PAYLOAD_SRC}/" "${LIB_TARGET}/payload/" 2>/dev/null || cp -a "${PAYLOAD_SRC}/"* "${LIB_TARGET}/payload/" 2>/dev/null || true
else
  echo "  skipped missing payload directory: ${PAYLOAD_SRC}"
fi

echo "Checking ISO default path: ${ISO_DEFAULT_DIR}"
mkdir -p "${ISO_DEFAULT_DIR}"
if [[ -f "${ISO_DEFAULT_PATH}" ]]; then
  echo "  ISO present: ${ISO_DEFAULT_PATH}"
else
  echo "  warning: ISO not found: ${ISO_DEFAULT_PATH}"
  echo "    - place the GitHub Actions ISO artifact at this path, or"
  echo "    - override ISO_PATH_DEFAULT when running vm_autoinstall."
fi

PROFILE_D="/etc/profile.d/ablestack-qemu-exec-tools.sh"
echo "Writing environment profile: ${PROFILE_D}"
cat <<EOF | sudo tee "${PROFILE_D}" >/dev/null
# ablestack-qemu-exec-tools environment
export ABLESTACK_QEMU_EXEC_TOOLS_HOME="${LIB_TARGET}"
export ISO_PATH_DEFAULT="${ISO_DEFAULT_PATH}"
export V2K_COMPAT_ROOT="${COMPAT_TARGET_ROOT}"
EOF

echo "Installation complete."
echo
echo "Examples:"
echo "  vm_autoinstall <domain>"
echo "  vm_exec"
echo "  ablestack_vm_hangctl health"
echo "  ablestack_vm_hangctl scan"
echo "  ablestack_vm_ftctl protect --vm <vm> --mode <ha|dr|ft> --peer <uri>"
echo "  ablestack_vm_ftctl reconcile"
echo "  ablestack_vm_ftctl_selftest"
echo
echo "Optional systemd enablement:"
echo "  systemctl enable --now ablestack-vm-hangctl.timer"
echo "  systemctl enable --now ablestack-vm-ftctl.timer"
echo
echo "Notes:"
echo "  - Payload files are installed under ${LIB_TARGET}/payload"
echo "  - The default ISO path is ${ISO_DEFAULT_PATH}"
echo "  - Compatibility profiles are installed under ${COMPAT_TARGET_ROOT}"
echo "  - Windows ISO entrypoint: install.bat"
echo "  - Linux ISO entrypoint: install-linux.sh"
