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

CONFIG_PATH="/etc/ablestack/ablestack-vm-ftctl.conf"
SERVICE_NAME="ablestack-vm-ftctl-remote-nbd"
SERVICE_DIR="/etc/firewalld/services"
SERVICE_PATH="${SERVICE_DIR}/${SERVICE_NAME}.xml"
ACTION="${1-apply}"

FTCTL_REMOTE_NBD_PORT_BASE="10809"
FTCTL_REMOTE_NBD_PORT_COUNT="32"

if [[ -f "${CONFIG_PATH}" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${CONFIG_PATH}"
  set +a
fi

range_end=$((FTCTL_REMOTE_NBD_PORT_BASE + FTCTL_REMOTE_NBD_PORT_COUNT - 1))

write_service_file() {
  mkdir -p "${SERVICE_DIR}"
  cat > "${SERVICE_PATH}" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<service>
  <short>ABLESTACK VM FTCTL Remote NBD</short>
  <description>Remote NBD export port range for ABLESTACK VM FTCTL blockcopy replication.</description>
  <port protocol="tcp" port="${FTCTL_REMOTE_NBD_PORT_BASE}-${range_end}"/>
</service>
EOF
  chmod 0644 "${SERVICE_PATH}"
}

firewalld_running() {
  systemctl is-active --quiet firewalld
}

apply_service() {
  write_service_file
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --reload >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service="${SERVICE_NAME}" >/dev/null 2>&1 || true
    if firewalld_running; then
      firewall-cmd --add-service="${SERVICE_NAME}" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
  fi
  echo "[INFO] Firewalld service ensured: ${SERVICE_NAME} (${FTCTL_REMOTE_NBD_PORT_BASE}-${range_end}/tcp)"
}

remove_service() {
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-service="${SERVICE_NAME}" >/dev/null 2>&1 || true
    if firewalld_running; then
      firewall-cmd --remove-service="${SERVICE_NAME}" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
  fi
  rm -f "${SERVICE_PATH}" >/dev/null 2>&1 || true
  echo "[INFO] Firewalld service removed: ${SERVICE_NAME}"
}

case "${ACTION}" in
  apply)
    apply_service
    ;;
  remove)
    remove_service
    ;;
  *)
    echo "Usage: $0 [apply|remove]" >&2
    exit 2
    ;;
esac
