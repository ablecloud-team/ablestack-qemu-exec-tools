#!/bin/bash
# shellcheck disable=SC2034

detect_guest_os() {
    [ -r /etc/os-release ] || {
        echo "[ERROR] /etc/os-release is not available." >&2
        return 1
    }
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION="${VERSION_ID:-unknown}"
    case " $OS_ID $OS_ID_LIKE " in
        *" rhel "*|*" rocky "*|*" centos "*|*" almalinux "*|*" ol "*|*" fedora "*)
            OS_FAMILY="rpm"
            QGA_CONFIG_CANDIDATES="/etc/sysconfig/qemu-ga"
            ;;
        *" debian "*|*" ubuntu "*)
            OS_FAMILY="deb"
            QGA_CONFIG_CANDIDATES="/etc/default/qemu-guest-agent /etc/default/qemu-ga"
            ;;
        *)
            echo "[ERROR] Unsupported Linux distribution: $OS_ID ($OS_ID_LIKE)" >&2
            return 1
            ;;
    esac
}

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

ensure_qga_installed_and_active() {
    local action="${1:-check}"
    if ! command -v qemu-ga >/dev/null 2>&1; then
        if [ "$action" != "apply" ]; then
            echo "[ERROR] qemu-guest-agent is not installed." >&2
            return 3
        fi
        if [ "$OS_FAMILY" = "rpm" ]; then
            run_privileged dnf install -y qemu-guest-agent iproute
        else
            run_privileged apt-get update
            run_privileged apt-get install -y qemu-guest-agent iproute2 jq
        fi
    fi
    if ! systemctl is-active --quiet qemu-guest-agent; then
        if [ "$action" != "apply" ]; then
            echo "[ERROR] qemu-guest-agent is not active." >&2
            return 3
        fi
        run_privileged systemctl enable --now qemu-guest-agent
    fi
}
