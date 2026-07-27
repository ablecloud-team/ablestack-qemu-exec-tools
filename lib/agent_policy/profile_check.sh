#!/bin/bash

profile_status="UNKNOWN"
profile_error_code=""
profile_details=""

check_cloud_network_profile() {
    local helper="$LIBDIR/guest-network-snapshot"
    if [ ! -x "$helper" ]; then
        profile_status="HELPER_NOT_FOUND"
        profile_error_code="HELPER_NOT_INSTALLED"
        profile_details="$helper is not executable"
        return 5
    fi
    local output
    if ! output="$("$helper" --schema 1 --sections addresses,routes,dns 2>&1)"; then
        profile_status="SECURITY_POLICY_NOT_READY"
        profile_error_code="HELPER_EXEC_FAILED"
        profile_details="${output:0:255}"
        return 5
    fi
    if ! printf '%s' "$output" | jq -e \
            '.schemaVersion == 1 and .profile.status == "READY"' >/dev/null 2>&1; then
        profile_status="POLICY_NOT_READY"
        profile_error_code="HELPER_PROFILE_INCOMPLETE"
        profile_details="One or more network sections are not ready"
        return 5
    fi
    profile_status="READY"
    profile_error_code=""
    profile_details=""
    return 0
}

emit_policy_json() {
    local json="$1"
    local mode="$2"
    local changed_value="$3"
    local restarted="$4"
    local result_code="$5"
    local qga_version
    qga_version="$(qemu-ga --version 2>/dev/null | head -n1 | sed 's/.*version[[:space:]]*//' || true)"
    if [ "$json" = "true" ]; then
        jq -cn \
            --arg policyMode "$mode" \
            --arg osId "$OS_ID" \
            --arg osIdLike "$OS_ID_LIKE" \
            --arg osVersion "$OS_VERSION" \
            --arg qgaVersion "$qga_version" \
            --arg profileStatus "$profile_status" \
            --arg profileErrorCode "$profile_error_code" \
            --arg profileDetails "$profile_details" \
            --arg activeHash "${active_hash:-}" \
            --arg desiredHash "${desired_hash:-}" \
            --argjson changed "$changed_value" \
            --argjson restartPerformed "$restarted" \
            --argjson resultCode "$result_code" \
            --argjson policyEnabledRpcCount "${POLICY_RPC_COUNT:-0}" \
            '{
              schemaVersion: 1,
              policyMode: $policyMode,
              os: {id: $osId, idLike: ($osIdLike | split(" ") | map(select(length > 0))), version: $osVersion},
              qga: {installed: true, active: true, version: $qgaVersion,
                    policyEnabledRpcCount: $policyEnabledRpcCount},
              profiles: {
                "cloud-network-observability": {
                  version: 1,
                  status: $profileStatus,
                  errorCode: (if $profileErrorCode == "" then null else $profileErrorCode end),
                  details: (if $profileDetails == "" then null else $profileDetails end)
                }
              },
              activeHash: $activeHash,
              desiredHash: $desiredHash,
              changed: $changed,
              restartPerformed: $restartPerformed,
              resultCode: $resultCode
            }'
    elif [ "$result_code" -eq 0 ]; then
        echo "[SUCCESS] qemu-guest-agent policy/profile is ready."
    else
        echo "[ERROR] qemu-guest-agent policy/profile is not ready: ${profile_error_code:-$mode}" >&2
    fi
}
