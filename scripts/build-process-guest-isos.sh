#!/usr/bin/env bash
# Copyright 2026 ABLECLOUD. Apache-2.0.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
packages=$(realpath "${1:?package root required}")
windows=$(realpath "${2:?Windows payload required}")
output=$(realpath -m "${3:?output directory required}")
version=${4:?artifact version required}
[[ $version =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Unsafe artifact version' >&2; exit 2; }
mkdir -p "$output"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

for family in rocky ubuntu debian; do
    root="$stage/$family"
    mkdir -p "$root/packages"
    cp -a "$packages/$family/." "$root/packages/"
    bash "$repo/scripts/stage-process-repair.sh" "$root"
    install -m 0755 "$repo/scripts/install-guest-process-linux.sh" "$root/install-linux.sh"
    printf '%s\n' "$family" > "$root/FAMILY"
    printf 'ABLESTACK Tools offline guest installer for %s. Run: sudo bash install-linux.sh\n' "$family" > "$root/README.txt"
    (cd "$root" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$stage/checksums-$family"
    mv "$stage/checksums-$family" "$root/SHA256SUMS"
    genisoimage -quiet -r -J -V "ABLESTACK-${family^^}" \
        -o "$output/ABLESTACK-Tools-$family-$version.iso" "$root"
done

test "$(tr -d '\r\n' < "$windows/SOURCE_COMMIT")" = "$(git -C "$repo" rev-parse HEAD)"
root="$stage/windows"
mkdir -p "$root/process-management"
cp -a "$windows/." "$root/process-management/"
install -m 0644 "$repo/windows/process-management/install-iso.ps1" "$root/install.ps1"
install -m 0644 "$repo/windows/process-management/install-iso.bat" "$root/install.bat"
printf 'windows\n' > "$root/FAMILY"
cat > "$root/README.txt" <<'EOF'
ABLESTACK Tools offline Windows installer
Run install.bat from the ISO. Approve the Windows administrator prompt.
The installer configures VirtIO drivers, QEMU Guest Agent, and ABLESTACK Process Tools.
Exit code 3010 means installation completed and Windows must be restarted.
Installation and MSI logs are saved under C:\ProgramData\ABLESTACK-Tools.
EOF
for required in install.bat install.ps1 process-management/install.ps1 \
    process-management/virtio-win-gt-x64.msi \
    process-management/qemu-ga-x86_64.msi \
    process-management/ABLESTACK-ProcessTools.msi; do
    test -s "$root/$required" || { echo "Windows installer payload missing: $required" >&2; exit 2; }
done
(cd "$root" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$stage/checksums-windows"
mv "$stage/checksums-windows" "$root/SHA256SUMS"
genisoimage -quiet -r -J -V ABLESTACK-WINDOWS \
    -o "$output/ABLESTACK-Tools-windows-$version.iso" "$root"

for iso in "$output"/*.iso; do
    isoinfo -i "$iso" -R -f | grep -q '/install-linux.sh\|/install.ps1'
done
