param(
  [switch]$Continue
)

# ================= Common settings =================
# Project-relative paths (adjust if your layout differs)
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$MsiPath         = Join-Path $ScriptDir "..\cloudbase-init\CloudbaseInitSetup_x64.msi"

# Customized input files located next to this script
$ConfMainSrc     = Join-Path $ScriptDir "cloudbase-init.conf"
$ConfUnattSrc    = Join-Path $ScriptDir "cloudbase-init-unattend.conf"
$UnattendSrc     = Join-Path $ScriptDir "Unattend.xml"

# System deployment targets
$ConfDir         = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"
$ConfMainDst     = Join-Path $ConfDir "cloudbase-init.conf"
$ConfUnattDst    = Join-Path $ConfDir "cloudbase-init-unattend.conf"
$UnattendDst     = "C:\Windows\Panther\Unattend.xml"

$SysprepExe      = "$env:SystemRoot\System32\Sysprep\Sysprep.exe"
$SysprepArgs     = "/generalize /oobe /shutdown /unattend:$UnattendDst"

# Logging
$LogDir          = "C:\ablestack\logs"
$LogFile         = Join-Path $LogDir "install_cloudbase_init.log"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path $LogFile -Append | Out-Null

function Abort($msg) {
  Write-Error $msg
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

# Register self-resume via RunOnce after reboot
function Set-RunOnceResume {
  $cmd = "powershell.exe -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Continue"
  New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'AblestackCbiResume' -Value $cmd
}

# Remove user-scoped AppxPackages for all local users and remove provisioned packages
function PreClean-AppxPackages {
  Write-Host "[INFO] Pre-clean: removing Appx packages for all local user profiles..."
  $sids = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
          Where-Object { $_.GetValue('ProfileImagePath') -like 'C:\Users\*' } |
          ForEach-Object { $_.PSChildName }

  foreach ($sid in $sids) {
    Write-Host "  - Removing Appx packages for SID $sid"
    try {
      Get-AppxPackage -User $sid | Remove-AppxPackage -ErrorAction SilentlyContinue
    } catch {}
  }

  Write-Host "[INFO] Removing provisioned Appx packages (for new users)..."
  try {
    Get-AppxProvisionedPackage -Online | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
  } catch {}
}

# Install Cloudbase-Init via MSI
function Install-CloudbaseInit {
  Write-Host "[INFO] Installing Cloudbase-Init MSI..."
  if (-not (Test-Path $MsiPath)) { Abort "[ERROR] MSI file not found: $MsiPath" }
  Unblock-File -Path $MsiPath -ErrorAction SilentlyContinue
  $absMsi = (Resolve-Path $MsiPath).Path

  # Quiet install; capture exit code
  $proc = Start-Process msiexec.exe -ArgumentList "/i `"$absMsi`" /qn /norestart" -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    Abort "[ERROR] MSI installation failed (exitcode: $($proc.ExitCode)). Try UI install (/qb) or verify MSI integrity."
  }
  Write-Host "[INFO] MSI installation completed."
}

# Deploy both configuration files
function Deploy-Configs {
  Write-Host "[INFO] Deploying Cloudbase-Init configuration files..."
  if (-not (Test-Path $ConfMainSrc))  { Abort "[ERROR] cloudbase-init.conf source not found: $ConfMainSrc" }
  if (-not (Test-Path $ConfUnattSrc)) { Abort "[ERROR] cloudbase-init-unattend.conf source not found: $ConfUnattSrc" }

  if (-not (Test-Path $ConfDir)) { New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null }

  Copy-Item $ConfMainSrc  $ConfMainDst  -Force
  Copy-Item $ConfUnattSrc $ConfUnattDst -Force

  Write-Host "  - $ConfMainDst"
  Write-Host "  - $ConfUnattDst"
}

# Restart service (best-effort)
function Restart-CbiService {
  Write-Host "[INFO] Attempting to restart cloudbase-init service..."
  try {
    Restart-Service cloudbase-init -ErrorAction Stop
  } catch {
    Write-Host "[WARN] Service restart deferred; it may start on next boot. Continuing."
  }
}

# Deploy Unattend.xml
function Deploy-Unattend {
  Write-Host "[INFO] Deploying Unattend.xml..."
  if (-not (Test-Path $UnattendSrc)) { Abort "[ERROR] Unattend.xml source not found: $UnattendSrc" }
  Copy-Item $UnattendSrc $UnattendDst -Force
  Write-Host "  - $UnattendDst"
}

# Run Sysprep
function Run-Sysprep {
  Write-Host "[INFO] Running Sysprep. The system will shut down on completion..."
  if (-not (Test-Path $SysprepExe)) { Abort "[ERROR] Sysprep executable not found: $SysprepExe" }
  Start-Process -Wait -NoNewWindow $SysprepExe -ArgumentList $SysprepArgs
  Write-Host "[INFO] Sysprep completed. The system should power off soon."
}

# ================= Execution flow =================
if (-not $Continue) {
  # Phase 1: pre-clean and reboot with auto-resume
  Write-Host "[INFO] Phase 1: starting pre-clean for Sysprep (Appx removal)."
  PreClean-AppxPackages

  Write-Host "[INFO] Registering auto-resume after reboot (RunOnce)."
  Set-RunOnceResume

  Write-Host "[INFO] Rebooting now. Phase 2 will resume automatically after reboot."
  try { Stop-Transcript | Out-Null } catch {}
  Restart-Computer -Force
  exit 0
}
else {
  # Phase 2: install/configure and sysprep
  Write-Host "[INFO] Phase 2: resumed after reboot. Proceeding with install/config/sysprep."

  Install-CloudbaseInit
  Deploy-Configs
  Restart-CbiService
  Deploy-Unattend
  Run-Sysprep

  Write-Host "`n[INFO] All tasks completed:"
  Write-Host "      - Cloudbase-Init installed"
  Write-Host "      - cloudbase-init.conf / cloudbase-init-unattend.conf deployed"
  Write-Host "      - Unattend.xml placed (specialize will use the unattend conf)"
  Write-Host "      - Appx packages cleaned"
  Write-Host "      - Sysprep executed (/generalize /oobe /shutdown)"
  Write-Host "[INFO] Power off the VM (it should shut down automatically) and register it as a template/image for cloning."

  try { Stop-Transcript | Out-Null } catch {}
  exit 0
}
