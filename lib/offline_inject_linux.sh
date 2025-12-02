#!/usr/bin/env bash
#
# Filename : offline_inject_linux.sh
# Purpose : Inject files into a Linux VM's filesystem while it's offline
# Author  : Donghyuk Park (ablecloud.io)
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

# Resolve script root (repo root assumed to be parent dir)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PAYLOAD_DIR="${SCRIPT_DIR}/payload"

SYSTEMD_UNIT_SRC="${PAYLOAD_DIR}/linux/ablestack-install.service"

# Check payload exists
if [[ ! -f "${SYSTEMD_UNIT_SRC}" ]]; then
  echo "[ERR] payload systemd unit not found: ${SYSTEMD_UNIT_SRC}"
  exit 1
fi

# Helper: build virt-args array for disk mode (-a disk1 -a disk2 ...)
_build_disk_args() {
  local -n _arr=$1; shift
  local -a args=()
  for d in "$@"; do
    args+=("-a" "$d")
  done
  _arr=("${args[@]}")
}

# Main injection for disk-image mode
_inject_into_disks() {
  local disks=("$@")
  local disk_args
  _build_disk_args disk_args "${disks[@]}"

  echo "[INFO] Inspecting images to find OS root: ${disks[*]}"
  # virt-inspector supports multiple -a args
  if ! command -v virt-inspector >/dev/null 2>&1; then
    echo "[ERR] virt-inspector not installed"
    exit 1
  fi

  # virt-copy-in expects -a <disk> before source, so pass disk_args then source, then dest
  echo "[INFO] Copying systemd unit into image(s)..."
  # copy to /etc/systemd/system/
  virt-copy-in "${disk_args[@]}" "${SYSTEMD_UNIT_SRC}" /etc/systemd/system/ || {
    echo "[ERR] virt-copy-in failed"; exit 1
  }

  echo "[INFO] Enabling and arranging one-shot start on first-boot via virt-customize"
  # Enable unit on first boot. virt-customize supports multiple -a options as well.
  virt-customize "${disk_args[@]}" \
    --run-command 'systemctl enable ablestack-install.service' \
    --firstboot-command 'systemctl start ablestack-install.service' || {
      echo "[WARN] virt-customize returned non-zero (continuing)"; true
    }

  echo "[OK] Linux offline injection completed for images: ${disks[*]}"
}

# Main injection for live domain mode (-d <domain>)
_inject_into_domain() {
  local dom="$1"

  if ! command -v virt-copy-in >/dev/null 2>&1 || ! command -v virt-customize >/dev/null 2>&1; then
    echo "[ERR] virt-copy-in / virt-customize not installed on host"
    exit 1
  fi

  echo "[INFO] Injecting systemd unit into domain: ${dom}"
  virt-copy-in -d "${dom}" "${SYSTEMD_UNIT_SRC}" /etc/systemd/system/ || {
    echo "[ERR] virt-copy-in (domain) failed"; exit 1
  }

  virt-customize -d "${dom}" \
    --run-command 'systemctl enable ablestack-install.service' \
    --firstboot-command 'systemctl start ablestack-install.service' || {
      echo "[WARN] virt-customize (domain) returned non-zero (continuing)"; true
    }

  echo "[OK] Linux offline injection completed for domain: ${dom}"
}

# CLI parsing
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <domain>  OR  $0 --disks /path/to/disk1.img [/path/to/disk2.img ...]"
  exit 1
fi

if [[ "$1" == "--disks" ]]; then
  shift
  if [[ $# -lt 1 ]]; then
    echo "[ERR] --disks requires at least one disk image path"
    exit 1
  fi
  # Validate disk files
  for d in "$@"; do
    if [[ ! -f "$d" ]]; then
      echo "[ERR] disk image not found: $d"
      exit 1
    fi
  done
  _inject_into_disks "$@"
else
  DOMAIN="$1"
  # Quick sanity: ensure domain exists if called in domain mode
  if ! virsh dominfo "$DOMAIN" >/dev/null 2>&1; then
    echo "[ERR] domain not found or libvirt inaccessible: ${DOMAIN}"
    exit 1
  fi
  _inject_into_domain "${DOMAIN}"
fi