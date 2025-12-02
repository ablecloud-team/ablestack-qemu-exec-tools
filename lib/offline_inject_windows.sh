#!/usr/bin/env bash
#
# Filename : offline_inject_windows.sh
# Purpose : Inject files into a Windows VM's filesystem while it's offline
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

set -euo pipefail

# trap으로 에러 지점 표시(선택)
set -o errtrace
trap 'echo "[DBG] failed at ${BASH_SOURCE[0]}:${LINENO} (rc=$?)"' ERR


# libguestfs 안정화 (권장)
export LIBGUESTFS_BACKEND=direct

# Resolve script root (repo root assumed to be parent dir)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PAYLOAD_DIR="${SCRIPT_DIR}/payload"

RUNONCE_SRC="${PAYLOAD_DIR}/windows/ablestack-runonce.ps1"

# 복사 실패 시 ISO에서 바로 실행하도록 폴백
RUN_FROM_ISO=${RUN_FROM_ISO:-0}
DEST_WIN=${DEST_WIN:-/Windows/Temp}
# 부팅 즉시(로그인 전) 실행할 서비스 이름
SERVICE_NAME=${SERVICE_NAME:-ABLESTACK_AutoInstall}

# Check payload exists
if [[ ! -f "${RUNONCE_SRC}" ]]; then
  echo "[ERR] payload runonce script not found: ${RUNONCE_SRC}"
  exit 1
fi

# Helper: build virt-args array for disk mode (-a disk1 -a disk2 ...)
_build_disk_args() {
  local -n _arr=$1; shift
  local -a args=()
  for d in "$@"; do
    args+=("-a" "$d")
  done
  _arr=("${args[@]}")
}

_inject_into_disks() {
  local disks=("$@")
  local disk_args
  _build_disk_args disk_args "${disks[@]}"

  # Ensure virt-copy-in and virt-win-reg exist
  if ! command -v virt-copy-in >/dev/null 2>&1 || ! command -v virt-win-reg >/dev/null 2>&1; then
    echo "[ERR] virt-copy-in or virt-win-reg not installed on host"
    exit 1
  fi

  echo "[INFO] Copying runonce ps1 into Windows image(s)..."
  # virt-copy-in 은 게스트 경로를 리눅스식 절대경로로 받아야 함
  # 복사 실패 시 ISO에서 바로 실행하도록 폴백
  if ! virt-copy-in "${disk_args[@]}" "${RUNONCE_SRC}" "$DEST_WIN" 2>&1; then
    echo "[WARN] virt-copy-in failed (disk mode). The filesystem may be read-only (hibernation/dirty-bit)."
    echo "[WARN] Falling back to RunOnce-from-ISO (no copy)."
    RUN_FROM_ISO=1
  fi

  echo "[INFO] Registering RunOnce + Boot-time Service in offline registry..."

  # --- .reg 본문 생성 (RUN_FROM_ISO 분기) ---
  regtmp="$(mktemp)"
  if [[ "$RUN_FROM_ISO" -eq 0 ]]; then
    # 복사 성공: Temp의 PS1을 RunOnce + 서비스로 실행
    cat > "$regtmp" <<REG
Windows Registry Editor Version 5.00

; RunOnce (fallback on first logon)
[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce]
"ABLESTACK_OneShot_Installer"="powershell -NoProfile -ExecutionPolicy Bypass -File \\"C:\\\\Windows\\\\Temp\\\\ablestack-runonce.ps1\\""

; Boot-time Service (runs before logon as LocalSystem)
; NOTE: Offline edit ⇒ use ControlSet001/002 explicitly (CurrentControlSet is not resolved by hivex)
[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\${SERVICE_NAME}]
"DisplayName"="ABLESTACK Auto Installer"
"Description"="One-shot auto installer to run ABLESTACK installer at system boot"
"ImagePath"="C:\\\\Windows\\\\System32\\\\cmd.exe /c \\"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\\\Windows\\\\Temp\\\\ablestack-runonce.ps1\\""
"Type"=dword:00000010
"Start"=dword:00000002
"DelayedAutoStart"=dword:00000001
"ErrorControl"=dword:00000001
"ObjectName"="LocalSystem"

; Duplicate for ControlSet002 (harmless if absent)
[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet002\\Services\\${SERVICE_NAME}]
"DisplayName"="ABLESTACK Auto Installer"
"Description"="One-shot auto installer to run ABLESTACK installer at system boot"
"ImagePath"="C:\\\\Windows\\\\System32\\\\cmd.exe /c \\"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\v1.0\\\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\\\Windows\\\\Temp\\\\ablestack-runonce.ps1\\""
"Type"=dword:00000010
"Start"=dword:00000002
"DelayedAutoStart"=dword:00000001
"ErrorControl"=dword:00000001
"ObjectName"="LocalSystem"
REG
  else
    # 복사 실패: ISO(CD-ROM)의 install.bat을 RunOnce + 서비스로 실행
    cat > "$regtmp" <<REG
Windows Registry Editor Version 5.00

; RunOnce (on logon) — find CD/DVD and run install.bat
[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce]
"ABLESTACK_OneShot_Installer"="powershell -NoProfile -ExecutionPolicy Bypass -Command \\"$d=(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object { \$f = Join-Path (\$_.DeviceID+'\\\\') 'install.bat'; if (Test-Path \$f) { return \$f } } | Select-Object -First 1); if (\$d) { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c',\$d -Wait } else { Write-Host 'ABLESTACK ISO not found'; }\\""

; Boot-time Service (before logon) — find CD/DVD and run install.bat
; NOTE: Offline edit ⇒ use ControlSet001/002 explicitly (CurrentControlSet is not resolved by hivex)
[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\${SERVICE_NAME}]
"DisplayName"="ABLESTACK Auto Installer"
"Description"="One-shot auto installer to run ABLESTACK installer at system boot (from CD if necessary)"
"ImagePath"="C:\\\\Windows\\\\System32\\\\cmd.exe /c \\"for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %%D:\\\\install.bat (start /wait %%D:\\\\install.bat ^& exit) & timeout /t 2 >NUL\\""
"Type"=dword:00000010
"Start"=dword:00000002
"DelayedAutoStart"=dword:00000001
"ErrorControl"=dword:00000001
"ObjectName"="LocalSystem"

; Duplicate for ControlSet002 (harmless if absent)
[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet002\\Services\\${SERVICE_NAME}]
"DisplayName"="ABLESTACK Auto Installer"
"Description"="One-shot auto installer to run ABLESTACK installer at system boot (from CD if necessary)"
"ImagePath"="C:\\\\Windows\\\\System32\\\\cmd.exe /c \\"for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %%D:\\\\install.bat (start /wait %%D:\\\\install.bat ^& exit) & timeout /t 2 >NUL\\""
"Type"=dword:00000010
"Start"=dword:00000002
"DelayedAutoStart"=dword:00000001
"ErrorControl"=dword:00000001
"ObjectName"="LocalSystem"
REG
  fi

  # --- virt-win-reg 실행: set -e 보호 + stdin 사용 + timeout ---
  # disk_args(-a path ...) 에서 이미지 경로만 추출
  disk_imgs=()
  for ((i=0; i<${#disk_args[@]}; i++)); do
    if [[ "${disk_args[$i]}" == "-a" ]]; then
      (( i += 1 ))  # ← set -e 안전 (항상 0이 아닌 값)
      if [[ $i -ge ${#disk_args[@]} ]]; then
        echo "[ERR] malformed disk_args: -a without a following path"
        return 1
      fi
      disk_imgs+=("${disk_args[$i]}")
    fi
  done

  # 기존(문제): regtmp를 내부 셸에 변수로 안 넣어서 빈 문자열이 됨
  # timeout 60s bash -c 'virt-win-reg --merge "$@" - < "$regtmp"' _ "${disk_imgs[@]}" "$regtmp"

  # 교체(정상): $1을 regtmp로 받고, 나머지($@)는 이미지 목록으로 전달
  set +e
  timeout 60s bash -c '
    reg="$1"; shift
    virt-win-reg --merge "$@" - < "$reg"
  ' _ "$regtmp" "${disk_imgs[@]}" </dev/null
  rc=$?
  set -e


  if (( rc != 0 )); then
    echo "[WARN] virt-win-reg (disk mode) failed or timed out (rc=$rc)."
    # 최후 폴백: ISO RunOnce로 다시 세팅하여 재시도
    RUN_FROM_ISO=1
    cat > "$regtmp" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce]
"ABLESTACK_OneShot_Installer"="powershell -NoProfile -ExecutionPolicy Bypass -Command \"$d=(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object { $f = Join-Path ($_.DeviceID+'\\') 'install.bat'; if (Test-Path $f) { return $f } } | Select-Object -First 1); if ($d) { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c',$d -Wait } else { Write-Host 'ABLESTACK ISO not found'; }\""
REG
    set +e
    timeout 60s bash -c 'virt-win-reg --merge "$@" - < "$regtmp"' _ "${disk_imgs[@]}" "$regtmp"
    rc2=$?
    set -e
    if (( rc2 != 0 )); then
      echo "[WARN] virt-win-reg still failing (rc=$rc2). Continuing without offline merge (online path will run from ISO)."
    fi
  fi

  rm -f "${regtmp}"

  echo "[OK] Windows offline injection completed for images: ${disks[*]}"
}

_inject_into_domain() {
  local dom="$1"

  if ! command -v virt-copy-in >/dev/null 2>&1 || ! command -v virt-win-reg >/dev/null 2>&1; then
    echo "[ERR] virt-copy-in or virt-win-reg not installed on host"
    exit 1
  fi

  echo "[INFO] Copying runonce ps1 into domain: ${dom}"
  if ! virt-copy-in -d "${dom}" "${RUNONCE_SRC}" "$DEST_WIN" 2>&1; then
    echo "[WARN] virt-copy-in failed (domain). The filesystem may be read-only."
    echo "[WARN] Falling back to RunOnce-from-ISO (no copy)."
    RUN_FROM_ISO=1
  fi

  echo "[INFO] Registering RunOnce + Boot-time Service in domain registry..."

  # --- .reg 본문 생성 (RUN_FROM_ISO 분기) ---
  regtmp="$(mktemp)"
  if [[ "$RUN_FROM_ISO" -eq 0 ]]; then
    cat > "$regtmp" <<REG
Windows Registry Editor Version 5.00

; RunOnce (fallback on first logon)
[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce]
"ABLESTACK_OneShot_Installer"="powershell -NoProfile -ExecutionPolicy Bypass -File \\"C:\\\\Windows\\\\Temp\\\\ablestack-runonce.ps1\\""

; Boot-time Service (runs before logon as LocalSystem)
; NOTE: Offline edit ⇒ use ControlSet001/002 explicitly (CurrentControlSet is not resolved by hivex)
[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\${SERVICE_NAME}]
"DisplayName"="ABLESTACK Auto Installer"
"Description"="One-shot auto installer to run ABLESTACK installer at system boot"
"ImagePath"="C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\\\Windows\\\\Temp\\\\ablestack-runonce.ps1"
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ObjectName"="LocalSystem"

[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet002\\Services\\${SERVICE_NAME}]
"DisplayName"="ABLESTACK Auto Installer"
"Description"="One-shot auto installer to run ABLESTACK installer at system boot"
"ImagePath"="C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\\\Windows\\\\Temp\\\\ablestack-runonce.ps1"
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ObjectName"="LocalSystem"
REG
  else
    cat > "$regtmp" <<REG
Windows Registry Editor Version 5.00

; RunOnce (on logon) — find CD/DVD and run install.bat
[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce]
"ABLESTACK_OneShot_Installer"="powershell -NoProfile -ExecutionPolicy Bypass -Command \\"$d=(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object { \$f = Join-Path (\$_.DeviceID+'\\\\') 'install.bat'; if (Test-Path \$f) { return \$f } } | Select-Object -First 1); if (\$d) { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c',\$d -Wait } else { Write-Host 'ABLESTACK ISO not found'; }\\""

; Boot-time Service (before logon) — find CD/DVD and run install.bat
; NOTE: Offline edit ⇒ use ControlSet001/002 explicitly (CurrentControlSet is not resolved by hivex)
[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\${SERVICE_NAME}]
"DisplayName"="ABLESTACK Auto Installer"
"Description"="One-shot auto installer to run ABLESTACK installer at system boot (from CD if necessary)"
"ImagePath"="C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \\"$d=(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object { \$f = Join-Path (\$_.DeviceID+'\\\\') 'install.bat'; if (Test-Path \$f) { return \$f } } | Select-Object -First 1); if (\$d) { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c',\$d -Wait } else { Write-Host 'ABLESTACK ISO not found'; }\\""
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ObjectName"="LocalSystem"

[HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet002\\Services\\${SERVICE_NAME}]
"DisplayName"="ABLESTACK Auto Installer"
"Description"="One-shot auto installer to run ABLESTACK installer at system boot (from CD if necessary)"
"ImagePath"="C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \\"$d=(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object { \$f = Join-Path (\$_.DeviceID+'\\\\') 'install.bat'; if (Test-Path \$f) { return \$f } } | Select-Object -First 1); if (\$d) { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c',\$d -Wait } else { Write-Host 'ABLESTACK ISO not found'; }\\""
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ObjectName"="LocalSystem"
REG
  fi

  # 기존(문제)
  # timeout 60s bash -c 'virt-win-reg --merge "$1" - < "$2"' _ "${dom}" "${regtmp}"

  # 교체(정상)
  set +e
  timeout 60s bash -c '
    dom="$1"; reg="$2"
    virt-win-reg --merge "$dom" - < "$reg"
  ' _ "${dom}" "${regtmp}"
  rc=$?
  set -e

  if (( rc != 0 )); then
    echo "[WARN] virt-win-reg (domain mode) failed or timed out (rc=$rc)."
    # 이미 RUN_FROM_ISO 분기까지 포함했으므로 추가 조치는 로그만
  fi

  rm -f "${regtmp}"

  echo "[OK] Windows offline injection completed for domain: ${dom}"
}

# CLI parsing
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <domain>  OR  $0 --disks /path/to/disk1.img [/path/to/disk2.img ...]"
  exit 1
fi

if [[ "$1" == "--disks" ]]; then
  shift
  if [[ $# -lt 1 ]]; then
    echo "[ERR] --disks requires at least one disk image path"
    exit 1
  fi
  for d in "$@"; do
    # 파일 또는 블록 디바이스 허용
    if [[ ! -e "$d" ]]; then
      echo "[ERR] disk path not found: $d"
      exit 1
    fi
  done
  _inject_into_disks "$@"
else
  DOMAIN="$1"
  if ! virsh dominfo "$DOMAIN" >/dev/null 2>&1; then
    echo "[ERR] domain not found or libvirt inaccessible: ${DOMAIN}"
    exit 1
  fi
  _inject_into_domain "${DOMAIN}"
fi