<#
  Copyright 2025 ABLECLOUD

  File: install_cloudbase_init.ps1
  Purpose: Phase 2 script to install Cloudbase-Init, deploy configs, and run sysprep
  Author: Donghyuk Park

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
#>

param(
  [switch]$Phase2  # optional - force Phase 2
)

# Options for status UI
$global:ABL_StatusDir  = "C:\ProgramData\AbleStack\CloudInit"
$global:ABL_StatusPath = Join-Path $ABL_StatusDir "status.json"
$global:ABL_TotalSteps = 6   # about 6 steps, can be adjusted
$global:ABL_StepIndex  = 

$ABL_Root    = "C:\ProgramData\AbleStack\CloudInit"
$ABL_RegKey  = "HKLM:\SOFTWARE\AbleStack\CloudInit"
$ABL_RegName = "Phase"
$ABL_Marker  = Join-Path $ABL_Root "phase.marker"
$ABL_Status  = Join-Path $ABL_Root "status.json"

# ================= Common settings =================
$ScriptDir       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$MsiPath         = Join-Path $ScriptDir ".\CloudbaseInitSetup_x64.msi"

$ConfMainSrc     = Join-Path $ScriptDir "cloudbase-init.conf"
$ConfUnattSrc    = Join-Path $ScriptDir "cloudbase-init-unattend.conf"
$UnattendSrc     = Join-Path $ScriptDir "Unattend.xml"

$ConfDir         = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"
$ConfMainDst     = Join-Path $ConfDir "cloudbase-init.conf"
$ConfUnattDst    = Join-Path $ConfDir "cloudbase-init-unattend.conf"
$UnattendDst     = "C:\ProgramData\AbleStack\CloudInit\Unattend.xml"

$SysprepExe      = "$env:SystemRoot\System32\Sysprep\Sysprep.exe"
$SysprepArgs     = "/generalize /oobe /shutdown /quiet /mode:vm /unattend:$UnattendDst"
$SetupActLog     = "$env:WINDIR\System32\Sysprep\Panther\setupact.log"
$PantherLog      = "$env:WINDIR\System32\Sysprep\Panther\setupact.log"
$SuccessTag      = "$env:WINDIR\System32\Sysprep\Sysprep_succeeded.tag"
$MaxAttempts     = 10

# State & logging
$StateDir        = "C:\ProgramData\AbleStack\CloudInit\state"
$Marker          = Join-Path $StateDir "cbi_preclean_done.flag"
$LogDir          = "C:\ProgramData\AbleStack\CloudInit\Logs"
$LogFile         = Join-Path $LogDir "install_cloudbase_init.log"
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir  -Force | Out-Null

Start-Transcript -Path $LogFile -Append | Out-Null


function Disable-PhaseRunnerTasks {
    param([string[]]$Names = @(
        'AbleStack-CloudInit-PhaseRunner-Boot',
        'AbleStack-CloudInit-PhaseRunner-Logon'
    ))
    try {
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect(); $root = $svc.GetFolder('\')
        foreach($n in $Names){
            try { $null = $root.GetTask($n); $root.DeleteTask($n,0); Write-Host "[INFO] Deleted task $n" }
            catch { }
        }
    } catch {
        foreach($n in $Names){ schtasks /Delete /TN $n /F | Out-Null }
    }
}

function Set-PhaseDone {
    if (-not (Test-Path $ABL_Root)) { New-Item -ItemType Directory -Path $ABL_Root -Force | Out-Null }
    # Registry
    if (-not (Test-Path $ABL_RegKey)) { New-Item -Path $ABL_RegKey -Force | Out-Null }
    Set-ItemProperty -Path $ABL_RegKey -Name $ABL_RegName -Value 'Done' -Force
    # Marker file
    'Done' | Out-File -FilePath $ABL_Marker -Encoding ascii -Force
    # Remove status file
    Remove-Item $ABL_Status -ErrorAction SilentlyContinue
    Write-Host "[INFO] Phase marked as Done (registry + marker)"
}

function Seal-Template {
    Write-Host "[INFO] Sealing template: deleting Phase-Runner tasks and marking Done..."
    Disable-PhaseRunnerTasks
    Set-PhaseDone
}

function Show-Status {
    param(
        [Parameter(Mandatory)] [string]$Label,
        [int]$StepIndex = $null,
        [int]$TotalSteps = $null,
        [switch]$NoToast       # Refrain from toast notification (for silent mode
    )
    if (-not (Test-Path $ABL_StatusDir)) { New-Item -ItemType Directory -Force -Path $ABL_StatusDir | Out-Null }

    # Calculate progress
    if ($StepIndex -ne $null) { $global:ABL_StepIndex = $StepIndex }
    if ($TotalSteps -ne $null) { $global:ABL_TotalSteps = $TotalSteps }
    $idx = [Math]::Max(0, [int]$global:ABL_StepIndex)
    $tot = [Math]::Max(1, [int]$global:ABL_TotalSteps)
    $pct = [Math]::Min(100, [Math]::Round(($idx / $tot) * 100))

    # Console progress + log
    Write-Progress -Activity "AbleStack CloudInit - Phase2" -Status $Label -PercentComplete $pct
    Write-Host ("[STEP {0}/{1}] {2}" -f $idx, $tot, $Label)

    # Status file
    $status = [ordered]@{
        time   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        step   = $idx
        total  = $tot
        label  = $Label
        sysprepAttempt = $script:ABL_SysprepAttempt
    }
    $status | ConvertTo-Json | Out-File -FilePath $ABL_StatusPath -Encoding UTF8 -Force

    # Toast notification (best-effort)
    if (-not $NoToast.IsPresent) {
        try {
            & msg.exe * /TIME:60 ("AbleStack Init: " + $Label) | Out-Null
        } catch { }  # Ignore errors
    }
}

function Abort($msg) {
  Write-Error $msg
  try { Stop-Transcript | Out-Null } catch {}
  exit 1
}

function Show-WarningPopup($text, $title="Ablestack Cloudbase-Init Installer") {
  try {
    # Lightweight popup; works on Server/Desktop without adding assemblies
    $wshell = New-Object -ComObject WScript.Shell
    # Popup(text, timeout sec, title, type)
    # type 48 = Exclamation icon + OK
    $wshell.Popup($text, 15, $title, 48) | Out-Null
  } catch {
    # Fallback - no-op if COM not available
  }
}

# ---------- Phase 1 - remove Appx (may kill the shell) ----------
function Phase1-Preclean {
  Write-Host "[INFO] Phase 1 - Pre-clean (Appx removal) starts."
  Write-Host "[WARN] PowerShell window MAY close unexpectedly during Appx removal."
  Write-Host "[WARN] If it closes, please run THIS script again to continue with Phase 2."

  Show-WarningPopup "Phase 1 will remove Appx packages. Your PowerShell window MAY close unexpectedly. If it closes, re-run this script to continue (Phase 2)."

  # Remove user-scoped Appx packages for all local users
  $sids = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
          Where-Object { $_.GetValue('ProfileImagePath') -like 'C:\Users\*' } |
          ForEach-Object { $_.PSChildName }

  foreach ($sid in $sids) {
    Write-Host "  - Removing Appx packages for SID $sid"
    try {
      Get-AppxPackage -User $sid | Remove-AppxPackage -ErrorAction SilentlyContinue
    } catch {}
  }

  # Remove provisioned packages (for new users)
  Write-Host "[INFO] Removing provisioned Appx packages (for future users)..."
  try {
    Get-AppxProvisionedPackage -Online | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
  } catch {}

  # Mark Phase 1 completion
  Set-Content -Path $Marker -Value (Get-Date).ToString("s") -Force
  Write-Host "[INFO] Phase 1 finished. If your shell closed, simply re-run this script. If not closed, please CLOSE this window and run the script again for Phase 2."

  try { Stop-Transcript | Out-Null } catch {}
  # Intentionally exit without reboot. The user will run Phase 2 manually.
  exit 0
}

# ---------- Phase 2 - install, deploy configs, sysprep ----------
function Install-CloudbaseInit {
  Write-Host "[INFO] Installing Cloudbase-Init MSI..."
  if (-not (Test-Path $MsiPath)) { Abort "[ERROR] MSI file not found - $MsiPath" }
  Unblock-File -Path $MsiPath -ErrorAction SilentlyContinue
  $absMsi = (Resolve-Path $MsiPath).Path

  $proc = Start-Process msiexec.exe -ArgumentList "/i `"$absMsi`" /qn /norestart" -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    Abort "[ERROR] MSI installation failed exitcode - $($proc.ExitCode). Try UI install (/qb) or verify MSI integrity."
  }
  Write-Host "[INFO] MSI installation completed."
}

function Deploy-Configs {
  Write-Host "[INFO] Deploying Cloudbase-Init configuration files..."

  if (-not (Test-Path $ConfMainSrc))  { Abort "[ERROR] cloudbase-init.conf source not found - $ConfMainSrc" }
  if (-not (Test-Path $ConfUnattSrc)) { Abort "[ERROR] cloudbase-init-unattend.conf source not found - $ConfUnattSrc" }

  if (-not (Test-Path $ConfDir)) { New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null }

  Copy-Item $ConfMainSrc  $ConfMainDst  -Force
  Copy-Item $ConfUnattSrc $ConfUnattDst -Force

  Write-Host "  - $ConfMainDst"
  Write-Host "  - $ConfUnattDst"
}

function Disable-CbiService {
  Write-Host "[INFO] Attempting to disable cloudbase-init service..."
  try {
    sc.exe config cloudbase-init start= disabled | Out-Null
  } catch {
    Write-Host "[WARN] Service disable deferred; it may start on next boot. Continuing."
  }
}

function Deploy-Unattend {
  Write-Host "[INFO] Deploying Unattend.xml..."
  if (-not (Test-Path $UnattendSrc)) { Abort "[ERROR] Unattend.xml source not found - $UnattendSrc" }
  Copy-Item $UnattendSrc $UnattendDst -Force
  Write-Host "  - $UnattendDst"
}

function Disable-BitLockerIfNeeded {
    Write-Host "[INFO] Checking BitLocker status..."
    Show-Status -Label ("[INFO] Checking BitLocker status...")

    $volumes = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $volumes) {
        Write-Host "[INFO] BitLocker is not available on this system."
        Show-Status -Label ("[INFO] BitLocker is not available on this system.")
        return
    }

    foreach ($vol in $volumes) {
        # Case 1: If protection is on, turn it off
        # Case 2: If volume status is FullyEncrypted (but ProtectionStatus is Off), turn it off to start decryption
        if ($vol.ProtectionStatus -eq 'On' -or $vol.VolumeStatus -eq 'FullyEncrypted') {
            Write-Host "[WARN] BitLocker detected on $($vol.MountPoint). Starting decryption..."
            Show-Status -Label ("[WARN] BitLocker detected on $($vol.MountPoint). Starting decryption...")
            Disable-BitLocker -MountPoint $vol.MountPoint -ErrorAction SilentlyContinue
        }
    }

    # Wait for decryption to complete (max 120 minutes)
    $maxWaitMinutes = 120
    $waited = 0
    while ($true) {
        $pending = Get-BitLockerVolume | Where-Object {
            $_.VolumeStatus -ne 'FullyDecrypted'
        }
        if (-not $pending) { break }
        if ($waited -ge $maxWaitMinutes) {
            throw "BitLocker decryption did not complete within $maxWaitMinutes minutes."
        }
        Write-Host "[INFO] Waiting for BitLocker decryption to finish... ($waited/$maxWaitMinutes min)"
        Show-Status -Label ("[INFO] Waiting for BitLocker decryption to finish... ($waited/$maxWaitMinutes min)")
        Start-Sleep -Seconds 60
        $waited++
    }

    Write-Host "[INFO] All BitLocker volumes are fully decrypted."
    Show-Status -Label ("[INFO] All BitLocker volumes are fully decrypted.")
}

function Run-Sysprep {
    if (-not (Test-Path $SysprepExe)) { throw "sysprep.exe not found - $SysprepExe" }
    if (-not (Test-Path $UnattendDst)) { throw "Unattend.xml not found - $UnattendDst" }

    if (-not $script:HandledPkgs) {
        $script:HandledPkgs = New-Object System.Collections.Generic.HashSet[string]
    }

    # --- helpers ---
    function Invoke-SysprepOnce {
        param([datetime]$Since, [int]$TimeoutSeconds = 900) # Timeout default 15 min

        Write-Host "[INFO] Start sysprep: $SysprepExe $SysprepArgs"
        $p = Start-Process -FilePath $SysprepExe -ArgumentList $SysprepArgs -PassThru
        $done = $p.WaitForExit($TimeoutSeconds * 1000)

        if (-not $done) {
            Write-Host "[WARN] Sysprep did not exit in $TimeoutSeconds sec. Killing process."
            try { $p.Kill() } catch {}
            # If sysprep spawns child processes, kill them too
            Get-Process -Name sysprep -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $p.Id } | Stop-Process -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "[INFO] Sysprep exited with code $($p.ExitCode)"
        }

        if (Test-Path $SuccessTag) {
            Write-Host "[INFO] Sysprep_succeeded.tag detected."
            return @{ Success = $true; Offenders = @() }
        }

        Start-Sleep -Seconds 1

        $offenders = Get-OffendingPackages -Since $Since
        $offenders = $offenders | Sort-Object -Unique
        $offenders = $offenders | Where-Object { -not $script:HandledPkgs.Contains($_) } 

        if ($offenders.Count -gt 0) { return @{ Success = $false; Offenders = $offenders } }

        return @{ Success = $false; Offenders = @() }
    }

    function Get-OffendingPackages {
        param(
            [string]$PantherLog = "$env:WINDIR\System32\Sysprep\Panther\setupact.log",
            [datetime]$Since
        )

        if (-not (Test-Path $PantherLog)) { return @() }

        $rxTime = [regex]'^(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),'
        $rxErr  = [regex]'SYSPRP.*?Package\s+([^\s]+)\s+was\s+installed\s+for\s+a\s+user'
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $styles  = [System.Globalization.DateTimeStyles]::None
        $cutoff  = if ($Since) { $Since.AddSeconds(-2) } else { [datetime]::MinValue }
        $found   = New-Object System.Collections.Generic.List[string]

        Get-Content -Path $PantherLog | ForEach-Object {
            $line = $_
            $consider = $true

            $m = $rxTime.Match($line)
            if ($m.Success) {
                $tsParsed = [datetime]::MinValue
                $ok = [datetime]::TryParseExact(
                    $m.Groups['ts'].Value,
                    'yyyy-MM-dd HH:mm:ss',
                    $culture,
                    $styles,
                    [ref]$tsParsed
                )
                if ($ok -and $Since) {
                    if ($tsParsed -lt $cutoff) { $consider = $false }
                }
            }

            if ($consider -and $rxErr.IsMatch($line)) {
                $pkg = $rxErr.Match($line).Groups[1].Value
                if ($pkg) { [void]$found.Add($pkg) }
            }
        }

        return $found | Sort-Object -Unique
    }

    function Remove-PackageEverywhere {
        param([string]$PackageFullName)

        Write-Host "[INFO] Removing Appx - $PackageFullName"
        $baseName = ($PackageFullName -split '_')[0]  # e.g. Microsoft.WindowsTerminal

        # (1) 설치본 제거 (모든 사용자)
        try {
            $pkgs = Get-AppxPackage -AllUsers | Where-Object {
                $_.PackageFullName -eq $PackageFullName -or
                $_.Name -eq $baseName -or
                $_.PackageFamilyName -like "$baseName*"
            }
            foreach ($p in $pkgs) {
                Write-Host "  - Remove-AppxPackage (AllUsers) - $($p.PackageFullName)"
                Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            }
        } catch { Write-Host "[WARN] Remove-AppxPackage - $($_.Exception.Message)" }

        # (2) 프로비저닝 제거
        try {
            $prov = Get-AppxProvisionedPackage -Online | Where-Object {
                $_.DisplayName -eq $baseName -or $_.PackageName -like "$baseName*"
            }
            foreach ($pv in $prov) {
                Write-Host "  - Remove-AppxProvisionedPackage - $($pv.PackageName)"
                Remove-AppxProvisionedPackage -Online -PackageName $pv.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null
            }
        } catch { Write-Host "[WARN] Remove-AppxProvisionedPackage - $($_.Exception.Message)" }
    }

    # --- main attempts ---
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "[INFO] Sysprep attempt $attempt / $MaxAttempts"
        Show-Status -Label ("Sysprep {0}/{1} Trying..." -f $attempt, $MaxAttempts) -StepIndex 5
        $since = (Get-Date).AddSeconds(-3)
        $result = Invoke-SysprepOnce -Since $since
        if ($result.Success) {
            Write-Host "[INFO] Sysprep succeeded."
            Seal-Template
            return
        }

        $off = @($result.Offenders)
        if ($off.Count -gt 0) {
            Write-Host "[WARN] Sysprep failed; offending packages - $($off.Count):"
            foreach ($pkg in $off) {
              Show-Status -Label ("Removing Non All Users Appx {0}..." -f $pkg)
              Remove-PackageEverywhere -PackageFullName $pkg
              [void]$script:HandledPkgs.Add($pkg)
            }

            if ($attempt -lt $MaxAttempts) {
                Write-Host "[INFO] Retrying sysprep after cleanup..."
                Start-Sleep -Seconds ($off.Count * 10)
                continue
            }
        }
        
        throw "Sysprep failed (no success tag and/or SYSPRP errors remain)."
    }
}

# ================= Entry =================
$phase2Ready = (Test-Path $Marker) -or $Phase2

if (-not $phase2Ready) {
  # Phase 1
  Phase1-Preclean
} else {
  # Phase 2
  Write-Host "[INFO] Phase 2 - continuing (pre-clean marker found or -Phase2 supplied)."
  Show-Status -Label "Please wait. The system will initialize and shut down shortly." -StepIndex 1 -TotalSteps 6

  Show-Status -Label "Installing Cloudbase-Init MSI..." -StepIndex 2
  Install-CloudbaseInit

  Show-Status -Label "Deploying Cloudbase-Init Config..." -StepIndex 3
  Deploy-Configs

  Show-Status -Label "Deploying Unattend.xml..." -StepIndex 4
  Disable-CbiService
  Deploy-Unattend

  Disable-BitLockerIfNeeded
  Run-Sysprep

  Show-Status -Label "Finished Sysprep, System shutdown immediately..." -StepIndex 6

  Write-Host "`n[INFO] All tasks completed -"
  Write-Host "      - Cloudbase-Init installed"
  Write-Host "      - cloudbase-init.conf / cloudbase-init-unattend.conf deployed"
  Write-Host "      - Unattend.xml placed (specialize will use the unattend conf)"
  Write-Host "      - Sysprep executed (/generalize /oobe /shutdown)"
  Write-Host "[INFO] Power off the VM (it should shut down automatically) and register it as a template/image for cloning."
  try { Stop-Transcript | Out-Null } catch {}
  exit 0
}
