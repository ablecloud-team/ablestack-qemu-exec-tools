param(
  [switch]$Continue
)

# ================= 공통 설정 =================
# 스크립트/파일 경로(프로젝트 구조 기준)
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$MsiPath         = Join-Path $ScriptDir "..\cloudbase-init\CloudbaseInitSetup_x64.msi"

# 업로드/커스터마이징된 설정 파일(스크립트 폴더에 위치)
$ConfMainSrc     = Join-Path $ScriptDir "cloudbase-init.conf"
$ConfUnattSrc    = Join-Path $ScriptDir "cloudbase-init-unattend.conf"
$UnattendSrc     = Join-Path $ScriptDir "Unattend.xml"

# 시스템 내 배포 경로
$ConfDir         = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"
$ConfMainDst     = Join-Path $ConfDir "cloudbase-init.conf"
$ConfUnattDst    = Join-Path $ConfDir "cloudbase-init-unattend.conf"
$UnattendDst     = "C:\Windows\Panther\Unattend.xml"

$SysprepExe      = "$env:SystemRoot\System32\Sysprep\Sysprep.exe"
$SysprepArgs     = "/generalize /oobe /shutdown /unattend:$UnattendDst"

# 로그
$LogDir          = "C:\ablestack\logs"
$LogFile         = Join-Path $LogDir "install_cloudbase_init.log"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogFile -Append | Out-Null

function Abort($msg) {
  Write-Error $msg
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

# 재부팅 후 자동 재개(RunOnce) 등록
function Set-RunOnceResume {
  $cmd = "powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Continue"
  New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'AblestackCbiResume' -Value $cmd
}

# 사용자별 Appx 제거(모든 로컬 사용자 SID) + 프로비저닝 패키지 제거
function PreClean-AppxPackages {
  Write-Host "[INFO] Sysprep 전 정리: 모든 로컬 사용자 Appx 패키지 제거를 시작합니다."
  $sids = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
          Where-Object { $_.GetValue('ProfileImagePath') -like 'C:\Users\*' } |
          ForEach-Object { $_.PSChildName }

  foreach ($sid in $sids) {
    Write-Host "  - SID $sid 사용자 Appx 제거 중..."
    try {
      Get-AppxPackage -User $sid | Remove-AppxPackage -ErrorAction SilentlyContinue
    } catch {}
  }

  Write-Host "[INFO] 향후 신규 사용자용 프로비저닝 Appx 패키지 제거 중..."
  try {
    Get-AppxProvisionedPackage -Online | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
  } catch {}
}

# Cloudbase-Init MSI 설치
function Install-CloudbaseInit {
  Write-Host "[INFO] Cloudbase-Init MSI 설치를 시작합니다..."
  if (-not (Test-Path $MsiPath)) { Abort "[ERROR] MSI 파일을 찾을 수 없습니다: $MsiPath" }
  Unblock-File -Path $MsiPath -ErrorAction SilentlyContinue
  $absMsi = (Resolve-Path $MsiPath).Path

  # 조용 모드 설치(/qn). 실패 시 종료 코드 확인
  $proc = Start-Process msiexec.exe -ArgumentList "/i `"$absMsi`" /qn /norestart" -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    Abort "[ERROR] MSI 설치 실패 (exitcode: $($proc.ExitCode)). UI 설치(/qb 또는 무옵션)로 재시도하거나 MSI 무결성을 확인하세요."
  }
  Write-Host "[INFO] MSI 설치가 완료되었습니다."
}

# 설정 파일 배포(메인/언어텐드)
function Deploy-Configs {
  Write-Host "[INFO] Cloudbase-Init 설정 파일을 배포합니다..."
  if (-not (Test-Path $ConfMainSrc))  { Abort "[ERROR] cloudbase-init.conf 소스 파일 없음: $ConfMainSrc" }
  if (-not (Test-Path $ConfUnattSrc)) { Abort "[ERROR] cloudbase-init-unattend.conf 소스 파일 없음: $ConfUnattSrc" }

  if (-not (Test-Path $ConfDir)) { New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null }

  Copy-Item $ConfMainSrc  $ConfMainDst  -Force
  Copy-Item $ConfUnattSrc $ConfUnattDst -Force

  Write-Host "  - $ConfMainDst"
  Write-Host "  - $ConfUnattDst"
}

# 서비스 재시작(선택)
function Restart-CbiService {
  Write-Host "[INFO] cloudbase-init 서비스 재시작 시도..."
  try {
    Restart-Service cloudbase-init -ErrorAction Stop
  } catch {
    Write-Host "[WARN] 현재 서비스 재시작에 실패했지만, 다음 부팅에서 시작될 수 있습니다. 계속 진행합니다."
  }
}

# Unattend.xml 배치
function Deploy-Unattend {
  Write-Host "[INFO] Unattend.xml 배포..."
  if (-not (Test-Path $UnattendSrc)) { Abort "[ERROR] Unattend.xml 소스 파일 없음: $UnattendSrc" }
  Copy-Item $UnattendSrc $UnattendDst -Force
  Write-Host "  - $UnattendDst"
}

# Sysprep 실행
function Run-Sysprep {
  Write-Host "[INFO] Sysprep 실행을 시작합니다. 완료 후 시스템이 종료됩니다..."
  if (-not (Test-Path $SysprepExe)) { Abort "[ERROR] Sysprep 실행 파일을 찾을 수 없습니다: $SysprepExe" }
  Start-Process -Wait -NoNewWindow $SysprepExe -ArgumentList $SysprepArgs
  Write-Host "[INFO] Sysprep이 완료되었습니다. 시스템이 곧 종료됩니다."
}

# ================= 실행 흐름 =================
if (-not $Continue) {
  # -------- 1단계: Appx 정리 후 재부팅 & 자동 재개 등록 --------
  Write-Host "[INFO] 1단계: Sysprep 사전 정리를 시작합니다 (Appx 제거)."
  PreClean-AppxPackages

  Write-Host "[INFO] 재부팅 후 스크립트를 자동으로 이어서 실행하도록 등록합니다."
  Set-RunOnceResume

  Write-Host "[INFO] 지금 재부팅합니다. 재부팅 후 2단계가 자동으로 진행됩니다."
  try { Stop-Transcript | Out-Null } catch {}
  Restart-Computer -Force
  exit 0
}
else {
  # -------- 2단계: 설치/설정/언어텐드 배치 & Sysprep --------
  Write-Host "[INFO] 2단계: 재부팅 후 자동 재개. 설치/설정/Sysprep을 진행합니다."

  Install-CloudbaseInit
  Deploy-Configs
  Restart-CbiService
  Deploy-Unattend
  Run-Sysprep

  Write-Host "`n[INFO] 모든 작업이 완료되었습니다."
  Write-Host "      - Cloudbase-Init 설치"
  Write-Host "      - cloudbase-init.conf / cloudbase-init-unattend.conf 배포"
  Write-Host "      - Unattend.xml 배포 (specialize 단계에서 언어텐드 conf 사용)"
  Write-Host "      - Appx 패키지 정리 후 Sysprep (/generalize /oobe /shutdown)"
  Write-Host "[INFO] 전원이 꺼진 VM을 템플릿/이미지로 등록하여 클론 배포에 활용하세요."

  try { Stop-Transcript | Out-Null } catch {}
  exit 0
}
