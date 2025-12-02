#!/usr/bin/env bash
#
# Filename : vm_autoinstall.sh
# Purpose : One-click automatic installation script for VMs
# Author  : Donghyuk Park (ablecloud.io)
#
# Copyright 2025 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ── ensure bash (re-exec if not) ───────────────────────────
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
# ────────────────────────────────────────────────────────────

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$ROOT_DIR/lib/ablestack-qemu-exec-tools/libvirt_helpers.sh"

usage() {
  cat <<USAGE
Usage: $0 <domain> [--force-offline] [--no-reboot]
  --force-offline : Use offline (injection) path even with QGA available
  --no-reboot     : Skip automatic reboot on offline path (startup is manual)
USAGE
}

print_bitlocker_help() {
  cat <<'HELP'
[HELP] Offline injection cannot proceed because the guest disk is BitLocker-encrypted.

Option 1 — Disable BitLocker inside the VM, then re-run:
  1) Log in as an Administrator.
  2) Open PowerShell (Run as Administrator) and execute:
       Disable-BitLocker -MountPoint "C:"
       Get-BitLockerVolume
  3) Wait until "PercentageEncrypted : 0" is shown for C:, then re-run:
       vm_autoinstall <VM-NAME>

Option 2 — Manual install from the ISO:
  1) Log in to the VM.
  2) Open the CD/DVD drive that contains 'ablestack-qemu-exec-tools.iso'.
  3) Run 'install.bat' as Administrator.

The VM has been started for you so you can perform the steps above.
HELP
}

[[ $# -ge 1 ]] || { usage; exit 1; }
DOM="$1"; shift || true

WAIT_COMPLETE=0
FORCE_EJECT=0
FORCE_OFFLINE="no"
NO_REBOOT="no"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait-complete) WAIT_COMPLETE=1 ;;
    --force-eject)   FORCE_EJECT=1 ;;
    --force-offline) FORCE_OFFLINE="yes" ;;
    --no-reboot)     NO_REBOOT="yes" ;;
    *) echo "[ERR] Unknown arg: $1"; usage; exit 1 ;;
  esac
  shift
done

require_cmd virsh
check_domain_exists "$DOM"

# 0) ISO 핫플러그 (+ 라벨 부여를 원하면 virt-xml 로 라벨 설정)
attach_cdrom_iso "$DOM" "${ISO_PATH_DEFAULT:-/usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso}"

# 1) QGA 경로 시도
QGA="$(has_qga "$DOM")"
if [[ "$FORCE_OFFLINE" == "no" && "$QGA" == "yes" ]]; then
  echo "[INFO] QGA detected → Online (non-stop) installation path selected"
  # OS 판별
  OS=$(detect_os_family_qga "$DOM")
  if [[ "$OS" == "linux" ]]; then
    # 게스트 내부에서 ISO 마운트 후 설치 스크립트 호출
    vm_exec="$(command -v vm_exec || true)"
    if [[ -z "$vm_exec" ]]; then echo "[ERR] vm_exec 미발견(QGA 호출기)"; exit 1; fi
    "$vm_exec" -l "$DOM" \
      'bash -lc "set -e; for d in /dev/cdrom /dev/sr0; do mount -o ro $d /mnt 2>/dev/null && break; done; if [ -x /mnt/install/linux/quickstart.sh ]; then /mnt/install/linux/quickstart.sh; elif [ -x /mnt/install.sh ]; then /mnt/install.sh; fi; umount /mnt || true"'
    echo "[OK] Linux guest online installation complete"
    exit 0
  elif [[ "$OS" == "windows" ]]; then
    vm_exec="$(command -v vm_exec || true)"
    if [[ -z "$vm_exec" ]]; then echo "[ERR] vm_exec not found (QGA caller)"; exit 1; fi
    "$vm_exec" -w -d "$DOM" \
      'powershell -NoProfile -ExecutionPolicy Bypass -File "$env:Temp\ablestack-runonce.ps1"' || true
    # (교체) Windows 온라인 설치: ISO 루트의 install.bat 실행
    "$vm_exec" -w -d "$DOM" \
      'powershell -NoProfile -ExecutionPolicy Bypass -Command "$p = (Get-CimInstance Win32_LogicalDisk -Filter `\"DriveType=5`\" | ForEach-Object { $f = Join-Path ($_.DeviceID+`\"\\`\") `\"install.bat`\"; if (Test-Path $f) { $f } } | Select-Object -First 1); if ($p) { Start-Process -FilePath `\"cmd.exe`\" -ArgumentList `\"/c`\", $p -Wait } else { Write-Host `\"[ERR] install.bat not found on any drive`\" }"'
    echo "[OK] Windows Guest Online Installation Attempt Completed"
    exit 0
  else
    echo "[WARN] OS detection failed (non-standard QGA response). Switching to offline path."
  fi
fi

# 2) 오프라인(1회 재부팅) 경로
echo "[INFO] Enter the offline (one-time reboot) installation path"

PERSIST=$(is_persistent "$DOM")
TMPDIR="/var/lib/ablestack/vm_autoinstall/$DOM"
mkdir -p "$TMPDIR"

# 종료 전, 필수 정보 수집
XML_PATH="$TMPDIR/domain.xml"
DISKS_FILE="$TMPDIR/disks.list"
dump_transient_xml "$DOM" "$XML_PATH"
get_disk_paths "$DOM" > "$DISKS_FILE"

graceful_shutdown_and_wait "$DOM" 120

mapfile -t DISKS < "$DISKS_FILE"
if [[ "${#DISKS[@]}" -eq 0 ]]; then
  echo "[ERR] Disk path not found"; exit 1
fi

INSPECT_OUT="$TMPDIR/inspect.xml"
INSPECT_ERR="$TMPDIR/inspect.err"

# -a <disk> 쌍 생성
ARGS=()
for d in "${DISKS[@]}"; do ARGS+=(-a "$d"); done

# 👇 핵심: STDIN 닫기 + 타임아웃으로 사용자 입력 대기 방지
#  - </dev/null : 아무 입력도 받지 않음 → 프롬프트가 떠도 즉시 EOF로 실패
#  - timeout 10s : 혹시라도 블록되면 강제 종료
set +e
timeout 10s virt-inspector "${ARGS[@]}" > "$INSPECT_OUT" 2> "$INSPECT_ERR" </dev/null
rc=$?
set -e

# BitLocker / 암호화 감지 → 온라인 경로 안내 + 부팅
if grep -qiE 'BITLK|encrypt-on-write|could not find key to open LUKS|Enter key or passphrase' "$INSPECT_ERR" || [[ $rc -ne 0 ]]; then
  echo "[WARN] BitLocker-encrypted Windows volume detected. Skipping offline injection."
  echo "[INFO] Booting the VM so you can disable BitLocker or run install.bat manually."
  print_bitlocker_help
  create_from_xml "$XML_PATH" >/dev/null 2>&1 || virsh start "$DOM" || true
  exit 0
fi

# virt-inspector는 <operatingsystems>/<operatingsystem>/<name> 에 OS 계열을 표기함
# - Windows 계열: <name>windows</name> (일부 환경에서 mswindows 표기도 커버)
# - Linux 계열  : <name>linux</name>
# 추가로 product_name/distro를 보조 지표로 사용해 견고성 강화
if grep -qiE '<name>\s*(ms)?windows\s*</name>|<product_name>[^<]*Windows' "$INSPECT_OUT"; then
  if ! "$ROOT_DIR/lib/ablestack-qemu-exec-tools/offline_inject_windows.sh" --disks "${DISKS[@]}"; then
    echo "[WARN] Offline injection failed on Windows (possible BitLocker or RO filesystem)."
    echo "[INFO] Booting the VM so you can disable BitLocker or run install.bat manually."
    print_bitlocker_help
    create_from_xml "$XML_PATH" >/dev/null 2>&1 || virsh start "$DOM" || true
    exit 0
  fi

elif grep -qiE '<name>\s*linux\s*</name>|<distro>\s*(rocky|rhel|centos|almalinux|fedora|ubuntu|debian|opensuse|sles)\s*</distro>' "$INSPECT_OUT"; then
  "$ROOT_DIR/lib/ablestack-qemu-exec-tools/offline_inject_linux.sh" --disks "${DISKS[@]}"

else
  echo "[ERR] Unsupported OS or detection failure"
  echo "----- inspector head -----"; head -n 50 "$INSPECT_OUT" || true
  exit 1
fi

# 재부팅: Persistent면 virsh start, Transient면 virsh create(ISO 포함 XML 사용)
ISO="${ISO_PATH_DEFAULT:-/usr/share/ablestack/tools/ablestack-qemu-exec-tools.iso}"

# XML에 이미 우리의 ISO가 물려 있으면 skip, 아니면 XML 갱신
if [[ -f "$XML_PATH" ]]; then
  if [[ "$(xml_has_cdrom_iso "$XML_PATH" "$ISO")" == "yes" ]]; then
    echo "[OK] XML already has our ISO on a CD-ROM; skip XML edit"
  else
    echo "[INFO] Persisting ISO into XML (no existing cdrom/source found)"
    inject_cdrom_into_xml "$XML_PATH" "$ISO"
  fi
fi

if [[ "$PERSIST" == "yes" ]]; then
  # 영구 도메인은 XML에 CD-ROM을 --config로 추가하는 편이 간단하지만
  # 여기서는 재사용성을 위해 덤프 XML을 수정 후 define & start 로 처리
  virsh define "$XML_PATH" >/dev/null
  start_domain "$DOM"
else
  # Transient: 덤프 XML에 CD-ROM 주입 → virsh create 로 부팅
  create_from_xml "$XML_PATH"
fi

# --- ISO 분리 정책 ---
# 1) 강제 분리 요청 시: 즉시 이젝트
if [[ "$FORCE_EJECT" -eq 1 ]]; then
  detach_iso_safely "$DOM" "$ISO" || echo "[WARN] ISO detach failed, but we will continue."
# 2) 설치 완료 대기 옵션이 있고 QGA guest-exec 가능하면: 완료 감지 후 이젝트
elif [[ "$WAIT_COMPLETE" -eq 1 && "$(has_qga "$DOM")" == "yes" ]]; then
  # OS 판별 결과 변수(GUEST_OS) 사용: linux/windows
  if wait_install_done_via_qga "$DOM" "$GUEST_OS" 900; then    # 15분 타임아웃 예시
    detach_iso_safely "$DOM" "$ISO" || echo "[WARN] ISO detach failed after completion."
  else
    echo "[WARN] Could not confirm completion; leaving ISO attached for safety."
  fi
# 3) 기본: 안전상 ISO 유지 (게스트 스크립트가 자체적으로 eject할 수도 있음)
else
  echo "[INFO] Keeping ISO attached (no --wait-complete or QGA-exec not available)."
fi

echo "[OK] Offline auto-installation ready (automatic installation from ISO after booting)"