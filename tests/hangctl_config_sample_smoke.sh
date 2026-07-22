#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${ROOT_DIR}/lib/hangctl/config.sh"
hangctl_config_load_effective "${ROOT_DIR}/etc/ablestack-vm-hangctl.conf" "" ""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ "${HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC}" == "3600" ]] || fail "migration confirm window"
[[ "${HANGCTL_MIGRATION_PROGRESS_CHECK_SEC}" == "300" ]] || fail "migration progress window"
[[ "${HANGCTL_LIBVIRTD_RESTART_ENABLED}" == "0" ]] || fail "safe restart default"
[[ "${HANGCTL_CLUSTER_GUARD_ENABLE}" == "1" ]] || fail "cluster guard default"
[[ "${HANGCTL_LIBVIRTD_RESTART_ON_API_TIMEOUT}" == "0" ]] || fail "api timeout default"

echo "hangctl config sample smoke: ok"
