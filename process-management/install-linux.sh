#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Apache-2.0.
# Offline guest repair only. No package repositories, cloud-init or network changes.
set -euo pipefail
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fail() {
    printf '{"schemaVersion":1,"profile":"process-management","status":"CHECK_FAILED","featureReady":false,"error":"%s"}\n' "$1"
    exit 4
}
[[ $# == 0 ]] || fail 'No options accepted by the repair payload'
[[ $EUID == 0 ]] || fail 'Root privileges are required'
command -v python3 >/dev/null || fail 'OFFLINE_PREREQUISITE_MISSING: python3'
command -v systemctl >/dev/null || fail 'OFFLINE_PREREQUISITE_MISSING: systemd'
[[ -r /etc/os-release ]] || fail 'OS identity unavailable'
# Root-owned distribution metadata, not an ISO-supplied script.
source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
    rocky:9*|rocky:10*|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
    *) fail 'Unsupported Linux repair target' ;;
esac
systemctl is-active --quiet qemu-guest-agent || fail 'QGA must already be installed and running; use distribution offline media first'
if [[ -f "$SOURCE/process_policy.py" ]]; then
    HELPER="$SOURCE/process_policy.py"
else
    HELPER="$SOURCE/../lib/agent_policy/process_policy.py"
fi
[[ -f "$HELPER" ]] || fail 'Policy payload missing'
TARGET=/usr/libexec/ablestack-qemu-exec-tools/agent_policy
# Refuse symlinked administrator destinations instead of replacing their targets.
for directory in /usr/libexec/ablestack-qemu-exec-tools "$TARGET" /var/lib/qemu-ga /var/lib/qemu-ga/ablestack-process-probe; do
    [[ ! -L "$directory" ]] || fail 'Symlinked installation directory'
    [[ ! -e "$directory" || -d "$directory" ]] || fail 'Invalid installation directory'
done
install -d -m 0755 "$TARGET"
[[ ! -L "$TARGET/process_policy.py" ]] || fail 'Symlinked policy helper'
install -m 0755 "$HELPER" "$TARGET/process_policy.py"
install -d -m 0700 /var/lib/qemu-ga/ablestack-process-probe
if command -v restorecon >/dev/null; then
    restorecon -R /var/lib/qemu-ga/ablestack-process-probe "$TARGET"
fi
exec python3 "$TARGET/process_policy.py" --policy process-management --apply --json