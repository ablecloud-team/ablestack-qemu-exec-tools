#!/bin/bash
#
# agent_policy_fix.sh - Configure and verify the guest qemu-ga policy.
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLED_LIBDIR="/usr/libexec/ablestack-qemu-exec-tools"
SOURCE_LIBDIR=""
if cd "$SCRIPT_DIR/../lib" 2>/dev/null; then
    SOURCE_LIBDIR="$(pwd)"
    cd - >/dev/null
fi
if [ -r "$INSTALLED_LIBDIR/agent_policy/os_detect.sh" ]; then
    LIBDIR="$INSTALLED_LIBDIR"
elif [ -n "$SOURCE_LIBDIR" ] && [ -r "$SOURCE_LIBDIR/agent_policy/os_detect.sh" ]; then
    LIBDIR="$SOURCE_LIBDIR"
else
    echo "[ERROR] ablestack-qemu-exec-tools libraries were not found." >&2
    exit 3
fi

# shellcheck source=../lib/agent_policy/os_detect.sh
source "$LIBDIR/agent_policy/os_detect.sh"
# shellcheck source=../lib/agent_policy/qga_config.sh
source "$LIBDIR/agent_policy/qga_config.sh"
# shellcheck source=../lib/agent_policy/profile_check.sh
source "$LIBDIR/agent_policy/profile_check.sh"

ACTION="apply"
POLICY="full"
PROFILE=""
JSON_OUTPUT=false

usage() {
    cat <<'EOF'
Usage:
  agent_policy_fix [--policy full] (--check|--apply) [--json]
  agent_policy_fix --check-profile cloud-network-observability [--json]

With no options, the command applies the full qemu-ga RPC policy.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --policy)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            POLICY="$2"
            shift 2
            ;;
        --check)
            ACTION="check"
            shift
            ;;
        --apply)
            ACTION="apply"
            shift
            ;;
        --check-profile)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            ACTION="profile"
            PROFILE="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[ "$POLICY" = "full" ] || {
    echo "[ERROR] Only the full qemu-ga policy is supported." >&2
    exit 2
}

detect_guest_os || exit 2
ensure_qga_installed_and_active "$ACTION"

changed=false
restart_performed=false
policy_mode="UNKNOWN"
active_hash=""
desired_hash=""

if [ "$ACTION" = "profile" ]; then
    [ "$PROFILE" = "cloud-network-observability" ] || {
        echo "[ERROR] Unsupported profile: $PROFILE" >&2
        exit 2
    }
    profile_rc=0
    check_cloud_network_profile || profile_rc=$?
    emit_policy_json "$JSON_OUTPUT" "FULL" false false "$profile_rc"
    exit "$profile_rc"
fi

locate_qga_config
read_qga_policy
build_full_qga_policy

active_hash="$(hash_text "$ACTIVE_POLICY_LINE")"
desired_hash="$(hash_text "$DESIRED_POLICY_LINE")"
if [ "$ACTIVE_POLICY_LINE" = "$DESIRED_POLICY_LINE" ]; then
    policy_mode="FULL"
elif [ "$ACTION" = "apply" ]; then
    apply_qga_policy
    changed=true
    restart_performed=true
    policy_mode="FULL"
else
    policy_mode="CUSTOM"
fi

if [ "$ACTION" = "check" ] && [ "$policy_mode" != "FULL" ]; then
    emit_policy_json "$JSON_OUTPUT" "$policy_mode" "$changed" "$restart_performed" 5
    exit 5
fi

emit_policy_json "$JSON_OUTPUT" "$policy_mode" "$changed" "$restart_performed" 0
