#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

source "${ROOT_DIR}/lib/hangctl/config.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cfg="${TMP_DIR}/custom.conf"
cat > "${cfg}" <<'EOF'
HANGCTL_POLICY="custom-file"
HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC="42"
HANGCTL_LIBVIRTD_RESTART_ENABLED="1"
EOF

hangctl_config_load_effective "${cfg}" "cli-policy" "1"

[[ "${HANGCTL_CONFIG_PATH}" == "${cfg}" ]] || fail "config path not applied"
[[ "${HANGCTL_POLICY}" == "cli-policy" ]] || fail "policy override failed"
[[ "${HANGCTL_DRY_RUN}" == "1" ]] || fail "dry-run override failed"
[[ "${HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC}" == "42" ]] || fail "custom config not sourced"
[[ "${HANGCTL_LIBVIRTD_RESTART_ENABLED}" == "1" ]] || fail "custom restart setting not sourced"

echo "hangctl config override smoke: ok"
