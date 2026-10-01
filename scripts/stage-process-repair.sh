#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Apache-2.0.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
target="${1:?ISO staging directory required}/process-management"
mkdir -p "$target"
install -m 0755 "$repo/process-management/install-linux.sh" "$target/install-linux.sh"
install -m 0755 "$repo/lib/agent_policy/process_policy.py" "$target/process_policy.py"
install -m 0755 "$repo/bin/vm_process_verify.py" "$target/vm_process_verify.py"

install -m 0644 "$repo/process-management/ablestack_qga_probe.cil" "$target/ablestack_qga_probe.cil"

install -m 0644 "$repo/lib/process/process_list_linux.py" "$target/process_list_linux.py"

install -m 0755 "$repo/build/process-read-launcher" "$target/process-read-launcher"
install -m 0644 "$repo/process-management/ablestack_process_read.cil" "$target/ablestack_process_read.cil"
install -m 0755 "$repo/process-management/read_policy.py" "$target/read_policy.py"

if [[ -f "$repo/build/process-action-launcher" ]]; then
  install -m 0755 "$repo/build/process-action-launcher" "$target/process-action-launcher"
  install -m 0644 "$repo/lib/process/process_action_linux.py" "$target/process_action_linux.py"
  install -m 0644 "$repo/lib/process/process_profile_linux.py" "$target/process_profile_linux.py"
  install -m 0644 "$repo/process-management/ablestack_process_action.cil" "$target/ablestack_process_action.cil"
  install -m 0755 "$repo/process-management/"{action_policy.py,action_policy_plain.py,install-actions-linux.sh} "$target/"
fi
