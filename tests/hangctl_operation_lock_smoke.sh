#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/hangctl/libvirt_wrap.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
HANGCTL_OPERATION_ROOT="$tmp/operations"
HANGCTL_VIRSH_TIMEOUT_SEC=1
uuid=11111111-1111-1111-1111-111111111111
hangctl__trim_one_line() { printf '%s' "$1"; }
hangctl_virsh() { printf -v "$2" '%s' "11111111-1111-1111-1111-111111111111"; printf -v "$4" 0; }
hangctl_log_event() { echo "$*" >> "$tmp/log"; }
hangctl_state_observe_operation() { :; }
act() { echo action >> "$tmp/calls"; }
hangctl_with_operation_lock vm act
[[ $(wc -l < "$tmp/calls") == 1 ]]
exec {held}>"$HANGCTL_OPERATION_ROOT/locks/$uuid.lock"
flock -x "$held"
hangctl_with_operation_lock vm act
[[ $(wc -l < "$tmp/calls") == 1 ]]
flock -u "$held"; exec {held}>&-
printf malformed > "$HANGCTL_OPERATION_ROOT/$uuid/orphan.json"
hangctl_with_operation_lock vm act
[[ $(wc -l < "$tmp/calls") == 1 ]]
rm "$HANGCTL_OPERATION_ROOT/$uuid/orphan.json"
for i in $(seq 1 50); do hangctl_with_operation_lock vm act; done
[[ $(wc -l < "$tmp/calls") == 51 ]]
echo 'PASS operation lock: busy/unknown protected, release resumes, repeated invocations complete'
