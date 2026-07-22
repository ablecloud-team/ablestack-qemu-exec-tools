#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

source "${ROOT_DIR}/lib/hangctl/common.sh"
source "${ROOT_DIR}/lib/hangctl/config.sh"
source "${ROOT_DIR}/lib/hangctl/logging.sh"
source "${ROOT_DIR}/lib/hangctl/libvirt_wrap.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local got="${1-}" want="${2-}" msg="${3-}"
  [[ "${got}" == "${want}" ]] || fail "${msg}: got=${got} want=${want}"
}

EVENTS=()
hangctl_log_event() {
  EVENTS+=("${2}:${7-}")
}

restart_called=0
hangctl_libvirtd_restart_safe() {
  restart_called=$((restart_called + 1))
  return "${HANGCTL_TEST_RESTART_RC:-0}"
}

guard_decision="idle"
hangctl_cluster_guard_probe() {
  local -n _decision="${2}"
  local -n _reason="${3}"
  local -n _detail="${4}"
  _decision="${guard_decision}"
  _reason="test_${guard_decision}"
  _detail="detail=mock"
}

health_calls=0
health_class="api_timeout"
health_result="timeout"
health_rc=143
hangctl_libvirtd_health_check_classified() {
  local -n _result="${2}"
  local -n _class="${3}"
  local -n _detail="${4}"
  local -n _rc="${5}"
  health_calls=$((health_calls + 1))
  if [[ "${HANGCTL_TEST_SECOND_HEALTH_OK:-0}" == "1" && "${health_calls}" -gt 1 ]]; then
    _result="ok"; _class="ok"; _detail=""; _rc=0
  else
    _result="${health_result}"; _class="${health_class}"; _detail="detail=mock"; _rc="${health_rc}"
  fi
}

reset_case() {
  rm -rf "${TMP_DIR}/state"
  mkdir -p "${TMP_DIR}/state"
  HANGCTL_STATE_DIR="${TMP_DIR}/state"
  HANGCTL_DRY_RUN="0"
  HANGCTL_LIBVIRTD_FAIL_THRESHOLD="1"
  HANGCTL_LIBVIRTD_RESTART_ENABLED="1"
  HANGCTL_LIBVIRTD_RESTART_ON_API_TIMEOUT="0"
  HANGCTL_LIBVIRTD_RESTART_COOLDOWN_SEC="0"
  HANGCTL_LIBVIRTD_RESTART_BACKOFF_SEC="3600"
  HANGCTL_LIBVIRTD_RESTART_MAX_PER_HOUR="0"
  HANGCTL_CLUSTER_GUARD_ENABLE="1"
  HANGCTL_CLUSTER_GUARD_FAIL_CLOSED="1"
  EVENTS=()
  restart_called=0
  health_calls=0
  health_result="timeout"
  health_class="api_timeout"
  health_rc=143
  guard_decision="idle"
  unset HANGCTL_TEST_SECOND_HEALTH_OK HANGCTL_TEST_RESTART_RC
}

hangctl_config_init_defaults

reset_case
hangctl_libvirtd_health_gate "scan" || true
assert_eq "${restart_called}" "0" "api timeout must not restart by default"
[[ "${EVENTS[*]}" == *"reason=health_class"* ]] || fail "missing health_class skip"

reset_case
health_result="fail"; health_class="service_inactive"; health_rc=3
guard_decision="busy"
hangctl_libvirtd_health_gate "scan" || true
assert_eq "${restart_called}" "0" "cluster busy must block restart"
[[ "${EVENTS[*]}" == *"reason=cluster_busy"* ]] || fail "missing cluster_busy skip"

reset_case
health_result="fail"; health_class="service_inactive"; health_rc=3
guard_decision="idle"
HANGCTL_TEST_SECOND_HEALTH_OK="1"
hangctl_libvirtd_health_gate "scan" || true
assert_eq "${restart_called}" "1" "idle service inactive should restart when enabled"

reset_case
health_result="fail"; health_class="service_inactive"; health_rc=3
HANGCTL_TEST_RESTART_RC="2"
hangctl_libvirtd_health_gate "scan" || true
remain="$(hangctl_libvirtd_backoff_remaining)"
[[ "${remain}" -gt 0 ]] || fail "verify failure must set backoff"

echo "hangctl libvirtd restart gate smoke: ok"
