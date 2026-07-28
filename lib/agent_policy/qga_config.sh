#!/bin/bash
# shellcheck disable=SC2034

hash_text() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

locate_qga_config() {
    QGA_CONFIG=""
    local candidate
    for candidate in $QGA_CONFIG_CANDIDATES; do
        if [ -f "$candidate" ]; then
            QGA_CONFIG="$candidate"
            break
        fi
    done
    if [ -z "$QGA_CONFIG" ]; then
        QGA_CONFIG="${QGA_CONFIG_CANDIDATES%% *}"
        if [ "$ACTION" = "apply" ]; then
            run_privileged install -m 0644 /dev/null "$QGA_CONFIG"
        else
            ACTIVE_POLICY_LINE=""
            return
        fi
    fi
}

normalize_rpc_list() {
    tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
        sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

extract_rpc_values() {
    local option="$1"
    local include_comments="$2"
    local expression
    if [ "$include_comments" = "true" ]; then
        expression='^[[:space:]]*#?[[:space:]]*FILTER_RPC_ARGS='
    else
        expression='^[[:space:]]*FILTER_RPC_ARGS='
    fi
    grep -E "$expression" "$QGA_CONFIG" 2>/dev/null |
        sed -n "s/.*--${option}=\\([^\\\"'[:space:]]*\\).*/\\1/p" || true
}

read_qga_policy() {
    local active_allow active_block
    active_allow="$(extract_rpc_values allow-rpcs false | normalize_rpc_list)"
    active_block="$(extract_rpc_values block-rpcs false | normalize_rpc_list)"
    if [ -n "$active_block" ]; then
        ACTIVE_POLICY_LINE="FILTER_RPC_ARGS=\"--block-rpcs=$active_block\""
    elif [ -n "$active_allow" ]; then
        ACTIVE_POLICY_LINE="FILTER_RPC_ARGS=\"--allow-rpcs=$active_allow\""
    else
        # No filter means qemu-ga exposes every command compiled into this build.
        ACTIVE_POLICY_LINE="FILTER_RPC_ARGS=\"\""
    fi
}

build_full_qga_policy() {
    local discovered
    discovered="$(
        {
            extract_rpc_values allow-rpcs true
            extract_rpc_values block-rpcs true
        } | normalize_rpc_list
    )"
    if [ -n "$discovered" ]; then
        DESIRED_POLICY_LINE="FILTER_RPC_ARGS=\"--allow-rpcs=$discovered\""
        POLICY_RPC_COUNT="$(printf '%s' "$discovered" | awk -F, '{print NF}')"
    else
        # An empty filter is the authoritative FULL setting where the vendor file
        # does not publish an RPC catalogue.
        DESIRED_POLICY_LINE="FILTER_RPC_ARGS=\"\""
        POLICY_RPC_COUNT=0
    fi
}

apply_qga_policy() {
    local config_dir backup_dir backup_file temporary
    config_dir="$(dirname "$QGA_CONFIG")"
    backup_dir="/var/lib/ablestack-qemu-exec-tools/qga-policy-backups"
    run_privileged install -d -m 0700 "$backup_dir"
    backup_file="$backup_dir/$(basename "$QGA_CONFIG").$(date +%Y%m%d%H%M%S).bak"
    run_privileged cp -a "$QGA_CONFIG" "$backup_file"
    temporary="$(run_privileged mktemp "$config_dir/.qga-policy.XXXXXX")"
    if grep -qE '^[[:space:]]*FILTER_RPC_ARGS=' "$QGA_CONFIG"; then
        sed -E "s|^[[:space:]]*FILTER_RPC_ARGS=.*$|$DESIRED_POLICY_LINE|" "$QGA_CONFIG" |
            run_privileged tee "$temporary" >/dev/null
    else
        {
            cat "$QGA_CONFIG"
            printf '%s\n' "$DESIRED_POLICY_LINE"
        } | run_privileged tee "$temporary" >/dev/null
    fi
    run_privileged chmod --reference="$QGA_CONFIG" "$temporary"
    run_privileged chown --reference="$QGA_CONFIG" "$temporary"
    run_privileged mv -f "$temporary" "$QGA_CONFIG"
    if ! run_privileged systemctl restart qemu-guest-agent ||
            ! systemctl is-active --quiet qemu-guest-agent; then
        run_privileged cp -a "$backup_file" "$QGA_CONFIG"
        run_privileged systemctl restart qemu-guest-agent || true
        echo "[ERROR] qemu-guest-agent restart failed; the previous configuration was restored." >&2
        return 4
    fi
    find "$backup_dir" -maxdepth 1 -type f -name "$(basename "$QGA_CONFIG").*.bak" \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR>5 {sub(/^[^ ]+ /, ""); print}' |
        while IFS= read -r stale; do run_privileged rm -f -- "$stale"; done
}
