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
for directory in /usr/libexec/ablestack-qemu-exec-tools "$TARGET" /usr/libexec/ablestack-qemu-exec-tools/process /var/lib/qemu-ga /var/lib/qemu-ga/ablestack-process-probe; do
    [[ ! -L "$directory" ]] || fail 'Symlinked installation directory'
    [[ ! -e "$directory" || -d "$directory" ]] || fail 'Invalid installation directory'
done
install -d -m 0755 "$TARGET"
[[ ! -L "$TARGET/process_policy.py" ]] || fail 'Symlinked policy helper'
install -m 0755 "$HELPER" "$TARGET/process_policy.py"
install -d -m 0700 /var/lib/qemu-ga/ablestack-process-probe
if command -v getenforce >/dev/null && [[ "$(getenforce)" != Disabled ]]; then
    for tool in semodule semanage restorecon; do
        command -v "$tool" >/dev/null || fail "OFFLINE_PREREQUISITE_MISSING: $tool"
    done
    policy="$SOURCE/ablestack_qga_probe.cil"
    [[ -f "$policy" ]] || fail 'SELinux probe policy missing'
    semodule -i "$policy" || fail 'SELinux probe policy installation failed'
    pattern='/var/lib/qemu-ga/ablestack-process-probe(/.*)?'
    # Existing administrator mapping must agree; never overwrite a conflicting one.
    mapping=$(semanage fcontext -l -C | awk -v p="$pattern" '$1 == p {print $NF}')
    if [[ -z "$mapping" ]]; then
        semanage fcontext -a -t ablestack_qga_probe_t "$pattern" || fail 'SELinux probe mapping failed'
    elif [[ "$mapping" != *:ablestack_qga_probe_t:* ]]; then
        fail 'Conflicting administrator SELinux mapping'
    fi
    restorecon -R /var/lib/qemu-ga/ablestack-process-probe || fail 'SELinux probe labeling failed'
fi
collector="$SOURCE/process_list_linux.py"
[[ -f "$collector" ]] || collector="$SOURCE/../lib/process/process_list_linux.py"
[[ -f "$collector" ]] || fail 'Linux process collector missing'
install -d -m 0755 /usr/libexec/ablestack-qemu-exec-tools/process
[[ ! -L /usr/libexec/ablestack-qemu-exec-tools/process/process_list_linux.py ]] || fail 'Symlinked collector'
if command -v getenforce >/dev/null && [[ "$(getenforce)" != Disabled ]]; then
    [[ ! -L "$TARGET/read_policy.py" ]] || fail 'Symlinked collector policy installer'
    install -m 0755 "$SOURCE/read_policy.py" "$TARGET/read_policy.py"
    if ! read_result=$(python3 "$TARGET/read_policy.py" --apply --payload "$SOURCE"); then
        printf '%s\n' "$read_result"
        exit 4
    fi
else
    install -m 0644 "$collector" /usr/libexec/ablestack-qemu-exec-tools/process/process_list_linux.py
fi
exec python3 "$TARGET/process_policy.py" --policy process-management --apply --json
