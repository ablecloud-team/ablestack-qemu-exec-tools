#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/lib/guest-network-snapshot"
POLICY="$ROOT/bin/agent_policy_fix.sh"

bash -n "$HELPER"
bash -n "$POLICY"
bash -n "$ROOT/lib/agent_policy/os_detect.sh"
bash -n "$ROOT/lib/agent_policy/qga_config.sh"
bash -n "$ROOT/lib/agent_policy/profile_check.sh"
bash -n "$ROOT/lib/install-qga-network-selinux-policy"

policy_work="$(mktemp -d)"
trap 'rm -rf -- "$policy_work"' EXIT
checkmodule -M -m -o "$policy_work/ablestack_qga_observer.mod" \
    "$ROOT/selinux/ablestack_qga_observer.te"
semodule_package -o "$policy_work/ablestack_qga_observer.pp" \
    -m "$policy_work/ablestack_qga_observer.mod"

payload="$("$HELPER" --schema 1 --sections addresses,routes,dns)"
jq -e '
  .schemaVersion == 1
  and .tool.name == "ablestack-qemu-exec-tools"
  and .profile.name == "cloud-network-observability"
  and (.interfaces | type == "array")
  and (.routes | type == "array")
  and (.dns.servers | type == "array")
' >/dev/null <<<"$payload"

if "$HELPER" --schema 2 --sections addresses >/dev/null 2>&1; then
    echo "unsupported schema was accepted" >&2
    exit 1
fi
if "$HELPER" --schema 1 --sections 'addresses,../../etc/passwd' >/dev/null 2>&1; then
    echo "unsupported section was accepted" >&2
    exit 1
fi

echo "guest network observability smoke: PASS"
