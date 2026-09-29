#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Apache-2.0.
# Guest-only, offline installer from an ABLESTACK Tools family ISO.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
fail() { printf 'ABLESTACK Tools: %s\n' "$*" >&2; exit 4; }
[[ $# == 0 ]] || fail 'This installer takes no arguments'
[[ $EUID == 0 ]] || fail 'Run as root'
[[ $(uname -m) == x86_64 ]] || fail 'Only x86_64 is supported'
[[ -r /etc/os-release ]] || fail 'OS identity unavailable'
# os-release is administrator-owned distribution metadata, not ISO content.
# shellcheck source=/dev/null
source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
    rocky:8.*) family=rocky; version=8 ;;
    rocky:9.*) family=rocky; version=9 ;;
    rocky:10.*) family=rocky; version=10 ;;
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) family=ubuntu; version=$VERSION_ID ;;
    debian:12|debian:13) family=debian; version=$VERSION_ID ;;
    *) fail "Unsupported guest OS: ${ID:-unknown} ${VERSION_ID:-unknown}" ;;
esac
[[ -f "$here/SHA256SUMS" ]] || fail 'ISO checksum manifest missing'
(cd "$here" && sha256sum -c --status SHA256SUMS) || fail 'ISO payload checksum mismatch'
[[ -r "$here/FAMILY" && $(cat "$here/FAMILY") == "$family" ]] || fail "Wrong Tools ISO for $family"
repo="$here/packages/$version"
[[ -d "$repo" ]] || fail "Offline payload missing for $family $version"

python_ready() {
    for candidate in python3 python3.9; do
        if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; assert sys.version_info >= (3, 8)' 2>/dev/null; then
            return 0
        fi
    done
    return 1
}
need_qga=false
if [[ "$family" == rocky ]]; then
    rpm -q qemu-guest-agent >/dev/null 2>&1 || need_qga=true
    packages=()
    if [[ $need_qga == true ]]; then packages+=(qemu-guest-agent); fi
    if ! python_ready; then
        if [[ $version == 8 ]]; then packages+=(python39); else packages+=(python3); fi
    fi
    if command -v getenforce >/dev/null && [[ $(getenforce) != Disabled ]]; then
        command -v semodule >/dev/null || packages+=(policycoreutils)
        command -v semanage >/dev/null || packages+=(policycoreutils-python-utils)
    fi
    if (( ${#packages[@]} )); then
        [[ -f "$repo/repodata/repomd.xml" ]] || fail 'Offline RPM repository metadata missing'
        key_file="/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-$version"
        [[ -r "$key_file" ]] || fail 'Rocky signing key missing'
        command -v gpg >/dev/null || fail 'Rocky signing key verification requires gpg'
        case $version in
            8) key_fingerprint=7051C470A929F454CEBE37B715AF5DAC6D745A60 ;;
            9) key_fingerprint=21CB256AE16FC54C6E652949702D426D350D275D ;;
            10) key_fingerprint=FC226859C0860BF0DDB95B085B106C736FEDFC85 ;;
        esac
        actual_fingerprint=$(gpg --quiet --batch --show-keys --with-colons "$key_file" 2>/dev/null | awk -F: '$1 == "fpr" { print toupper($10); exit }')
        [[ $actual_fingerprint == "$key_fingerprint" ]] || fail 'Unexpected Rocky signing key'
        rpmkeys --import "$key_file" || fail 'Rocky signing key import failed'
        for rpm in "$repo"/*.rpm; do
            [[ -f "$rpm" ]] || fail 'Offline RPM package missing'
            rpmkeys --checksig "$rpm" >/dev/null || fail "RPM signature invalid: $(basename "$rpm")"
        done
        repo_options=()
        # Rocky 8 Python 3.9 RPMs are modular; this signed offline repo has no module stream metadata.
        if [[ $version == 8 ]]; then repo_options+=(--setopt=ablestack-tools.module_hotfixes=1); fi
        dnf --disablerepo='*' --repofrompath=ablestack-tools,"file://$repo" \
            --enablerepo=ablestack-tools --setopt=install_weak_deps=False \
            --setopt=ablestack-tools.gpgcheck=1 \
            --setopt=ablestack-tools.gpgkey="file://$key_file" "${repo_options[@]}" \
            install -y "${packages[@]}" || fail 'Offline RPM installation failed'
    fi
else
    dpkg-query -W -f='${Status}' qemu-guest-agent 2>/dev/null | grep -q 'install ok installed' || need_qga=true
    packages=()
    if [[ $need_qga == true ]]; then packages+=(qemu-guest-agent); fi
    python_ready || packages+=(python3)
    if (( ${#packages[@]} )); then
        [[ -f "$repo/Packages.gz" ]] || fail 'Offline DEB repository metadata missing'
        lists=$(mktemp -d /tmp/ablestack-apt-lists.XXXXXX)
        trap 'rm -rf "$lists"' EXIT
        mkdir -p "$lists/partial"
        chmod 755 "$lists"
        sources=$(mktemp /tmp/ablestack-apt-sources.XXXXXX)
        trap 'rm -rf "$lists"; rm -f "$sources"' EXIT
        printf 'deb [trusted=yes] file:%s ./\n' "$repo" > "$sources"
        chmod 644 "$sources"
        apt_options=(-o "Dir::Etc::sourcelist=$sources" -o 'Dir::Etc::sourceparts=-'
                     -o "Dir::State::lists=$lists" -o 'Acquire::Languages=none')
        apt-get "${apt_options[@]}" update -qq || fail 'Offline DEB index failed'
        apt-get "${apt_options[@]}" install --no-install-recommends -y "${packages[@]}" \
            || fail 'Offline DEB installation failed'
    fi
fi

python_ready || fail 'Python 3.8+ unavailable after installation'
command -v qemu-ga >/dev/null || [[ -x /usr/sbin/qemu-ga ]] || fail 'QGA binary missing after installation'
qga_unit_state=$(systemctl is-enabled qemu-guest-agent 2>/dev/null || true)
case $qga_unit_state in
    enabled|static|indirect) ;;
    *) systemctl enable qemu-guest-agent || fail "QGA service enablement failed" ;;
esac
systemctl start qemu-guest-agent || fail "QGA service failed to start"
systemctl is-active --quiet qemu-guest-agent || fail 'QGA service is not running'
exec bash "$here/process-management/install-linux.sh"
