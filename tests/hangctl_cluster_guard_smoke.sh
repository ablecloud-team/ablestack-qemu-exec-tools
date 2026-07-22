#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

source "${ROOT_DIR}/lib/hangctl/config.sh"
source "${ROOT_DIR}/lib/hangctl/cluster_guard.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_busy() {
  local text="${1-}" reason="" detail=""
  hangctl_cluster_status_is_busy "${text}" reason detail || fail "expected busy"
}

assert_idle() {
  local text="${1-}" reason="" detail=""
  if hangctl_cluster_status_is_busy "${text}" reason detail; then
    fail "expected idle: reason=${reason} detail=${detail}"
  fi
}

hangctl_config_init_defaults
HANGCTL_STATE_DIR="${TMP_DIR}/state"
HANGCTL_CLUSTER_GUARD_RESOURCE_REGEX="cloudcenter_res"
mkdir -p "${HANGCTL_STATE_DIR}"

stable_status=$'Cluster Summary:\n  * Stack: corosync (Pacemaker is running)\nNode List:\n  * Online: [ 100.100.22.1 100.100.22.2 ]\nFull List of Resources:\n  * cloudcenter_res (ocf:heartbeat:VirtualDomain): Started 100.100.22.1\nFailed Resource Actions:\n  * cloudcenter_res migrate_to on 100.100.22.1 could not be executed (Timed Out)\nTickets:\n'
assert_idle "${stable_status}"

fencing_status=$'Cluster Summary:\nFencing Actions:\n  * reboot of 100.100.22.1 pending\n'
assert_busy "${fencing_status}"

action_status=$'Cluster Summary:\nActions:\n  * Start cloudcenter_res on 100.100.22.1\n'
assert_busy "${action_status}"

reason=""; detail=""
hangctl_cluster_status_hash_settle_check "${stable_status}" reason detail && fail "first hash should not settle"
hangctl_cluster_status_hash_settle_check "${stable_status}" reason detail && fail "unchanged hash should not settle"
changed_status="${stable_status}"$'\nCurrent DC: 100.100.22.2\n'
hangctl_cluster_status_hash_settle_check "${changed_status}" reason detail || fail "changed hash should settle"
hangctl_cluster_status_hash_settle_check "${changed_status}" reason detail || fail "recent changed hash should keep settling"

echo "hangctl cluster guard smoke: ok"
