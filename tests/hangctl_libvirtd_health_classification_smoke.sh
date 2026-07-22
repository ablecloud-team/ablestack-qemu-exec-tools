#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PATH="${TMP_DIR}:$PATH"

cat > "${TMP_DIR}/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == "is-active" ]]; then
  exit "${HANGCTL_TEST_SYSTEMCTL_RC:-0}"
fi
exit 0
EOF
chmod +x "${TMP_DIR}/systemctl"

cat > "${TMP_DIR}/virsh" <<'EOF'
#!/usr/bin/env bash
echo "${HANGCTL_TEST_VIRSH_OUT:-}"
if [[ -n "${HANGCTL_TEST_VIRSH_ERR:-}" ]]; then
  echo "${HANGCTL_TEST_VIRSH_ERR}" >&2
fi
exit "${HANGCTL_TEST_VIRSH_RC:-0}"
EOF
chmod +x "${TMP_DIR}/virsh"

source "${ROOT_DIR}/lib/hangctl/common.sh"
source "${ROOT_DIR}/lib/hangctl/config.sh"
source "${ROOT_DIR}/lib/hangctl/libvirt_wrap.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local got="${1-}" want="${2-}" msg="${3-}"
  [[ "${got}" == "${want}" ]] || fail "${msg}: got=${got} want=${want}"
}

hangctl_config_init_defaults
HANGCTL_LIBVIRTD_EXPECTED_SOCKET=""
HANGCTL_STATE_DIR="${TMP_DIR}/state"
mkdir -p "${HANGCTL_STATE_DIR}"

assert_eq "$(hangctl__result_from_rc 124)" "timeout" "rc 124"
assert_eq "$(hangctl__result_from_rc 137)" "timeout" "rc 137"
assert_eq "$(hangctl__result_from_rc 143)" "timeout" "rc 143"

result=""; class=""; detail=""; rc=0
export HANGCTL_TEST_SYSTEMCTL_RC=0 HANGCTL_TEST_VIRSH_RC=143
hangctl_libvirtd_health_check_classified 1 result class detail rc
assert_eq "${result}" "timeout" "api timeout result"
assert_eq "${class}" "api_timeout" "api timeout class"
assert_eq "${rc}" "143" "api timeout rc"

result=""; class=""; detail=""; rc=0
export HANGCTL_TEST_SYSTEMCTL_RC=3 HANGCTL_TEST_VIRSH_RC=0
hangctl_libvirtd_health_check_classified 1 result class detail rc
assert_eq "${result}" "fail" "inactive result"
assert_eq "${class}" "service_inactive" "inactive class"

HANGCTL_LIBVIRTD_EXPECTED_SOCKET="${TMP_DIR}/missing.sock"
result=""; class=""; detail=""; rc=0
export HANGCTL_TEST_SYSTEMCTL_RC=0 HANGCTL_TEST_VIRSH_RC=0
hangctl_libvirtd_health_check_classified 1 result class detail rc
assert_eq "${class}" "socket_missing" "socket missing class"

echo "hangctl libvirtd health classification smoke: ok"
