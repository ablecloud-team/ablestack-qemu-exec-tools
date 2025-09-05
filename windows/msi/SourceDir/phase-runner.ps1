<#
  Licensed under the Apache License, Version 2.0
  File: phase-runner.ps1
  Purpose: Two-phase orchestrator that delegates Phase2 to install_cloudbase_init.ps1
#>
#requires -version 5.1
param(
    [string]$LogDir = "C:\ProgramData\AbleStack\CloudInit\Logs",
    [switch]$SysprepAfterPhase2  # kept for compatibility; install script already runs sysprep
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# --- Paths and state ---
$InstallDir       = $PSScriptRoot  # ScheduledTask runs this script with absolute path => INSTALLDIR
$LogRoot          = $LogDir
$global:PhaseRegPath = "HKLM:\SOFTWARE\AbleStack\CloudInit"
$global:PhaseRegName = "Phase"   # "1","2","Done"
$global:PhaseMarker  = "C:\ProgramData\AbleStack\CloudInit\phase.marker"
$global:StateFile    = "C:\ProgramData\AbleStack\CloudInit\state.json"
if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
$global:LogFile      = Join-Path $LogRoot ("phase-runner_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Log { param([string]$Message)
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
  "$ts [phase-runner] $Message" | Tee-Object -FilePath $global:LogFile -Append
}

function Set-Phase([string]$p) {
  if (-not (Test-Path $global:PhaseRegPath)) { New-Item -Path $global:PhaseRegPath -Force | Out-Null }
  Set-ItemProperty -Path $global:PhaseRegPath -Name $global:PhaseRegName -Value $p -Force
  $p | Out-File -FilePath $global:PhaseMarker -Encoding ascii -Force
  Write-Log "Phase set to '$p'"
}

function Get-Phase {
  try {
    if (Test-Path $global:PhaseRegPath) {
      $v = (Get-ItemProperty -Path $global:PhaseRegPath -Name $global:PhaseRegName -ErrorAction SilentlyContinue).$global:PhaseRegName
      if ($v) { return $v }
    }
    if (Test-Path $global:PhaseMarker) {
      $t = Get-Content $global:PhaseMarker -ErrorAction Stop | Select-Object -First 1
      if ($t) { return $t.Trim() }
    }
  } catch {}
  return "Done"
}

function Save-State([hashtable]$h) {
  if (-not (Test-Path (Split-Path $global:StateFile))) { New-Item -ItemType Directory -Path (Split-Path $global:StateFile) -Force | Out-Null }
  $h | ConvertTo-Json -Depth 6 | Out-File -FilePath $global:StateFile -Encoding UTF8 -Force
}

function Test-SetupInProgress {
  try {
    $k = Get-ItemProperty -Path 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
    return (($k.SystemSetupInProgress -eq 1) -or ($k.OOBEInProgress -eq 1))
  } catch { return $false }
}

# ---- Phase1: pre-clean (Appx, service mode) + reboot ----
function Invoke-Phase1 {
  Write-Log "=== Phase1 start ==="
  try {
    # Warn user (best-effort)
    try {
      $wshell = New-Object -ComObject WScript.Shell
      $wshell.Popup("Phase 1 will remove Appx packages. PowerShell may close unexpectedly. If it closes, this process will resume automatically on next boot (Phase 2).", 10, "ABLESTACK CloudInit Phase1", 48) | Out-Null
    } catch {}

    # Remove user-scoped Appx packages for all local users
    try {
      $sids = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
              Where-Object { $_.GetValue('ProfileImagePath') -like 'C:\Users\*' } |
              ForEach-Object { $_.PSChildName }
      foreach ($sid in $sids) {
        Write-Log "Removing Appx for SID $sid"
        try {
          Get-AppxPackage -User $sid | Remove-AppxPackage -ErrorAction SilentlyContinue
        } catch {
          Write-Log "WARN: Remove-AppxPackage for SID $sid : $($_.Exception.Message)"
        }
      }
    } catch { Write-Log "WARN: Enumerating SIDs failed: $($_.Exception.Message)" }

    # Remove provisioned (for new users) packages as well – best-effort
    try {
      Get-AppxProvisionedPackage -Online | ForEach-Object {
        Write-Log "Removing provisioned Appx: $($_.DisplayName)"
        try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
        catch { Write-Log "WARN: Remove-AppxProvisionedPackage '$($_.PackageName)': $($_.Exception.Message)" }
      }
    } catch { Write-Log "WARN: Provisioned Appx removal failed: $($_.Exception.Message)" }

    # Ensure Cloudbase-Init service is set to auto (install may happen in Phase2)
    try {
      sc.exe config cloudbase-init start= auto | Out-Null
      Write-Log "cloudbase-init service set to Automatic (if installed)"
    } catch { Write-Log "WARN: service config: $($_.Exception.Message)" }
  }
  catch {
    Write-Log "ERROR: Phase1 failed: $($_.Exception.Message)"
    throw
  }

  Write-Log "=== Phase1 completed: scheduling reboot to continue with Phase2 ==="
  Set-Phase "2"
  shutdown.exe /r /t 5 /c "AbleStack Phase1 completed; proceeding to Phase2 after reboot."
}

# ---- Phase2: delegate to install_cloudbase_init.ps1 ----
function Invoke-Phase2 {
  Write-Log "=== Phase2 start ==="
  $installer = Join-Path $InstallDir "install_cloudbase_init.ps1"
  if (-not (Test-Path $installer)) {
    Write-Log "ERROR: install_cloudbase_init.ps1 not found at $installer"
    throw "Missing installer script"
  }

  # Run the installer with -Phase2 (so it skips its own Phase1)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$installer`" -Phase2"
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($stdout) { $stdout.Trim().Split("`n") | ForEach-Object { Write-Log $_ } }
  if ($stderr) { $stderr.Trim().Split("`n") | ForEach-Object { Write-Log "STDERR: $_" } }

  if ($proc.ExitCode -ne 0) {
    Write-Log "ERROR: install_cloudbase_init.ps1 failed with exit code $($proc.ExitCode)"
    throw "Phase2 failed (installer exit $($proc.ExitCode))"
  }

  # If you still want a guard to run extra sysprep, keep it – installer already does sysprep.
  if ($SysprepAfterPhase2.IsPresent) {
    Write-Log "SysprepAfterPhase2 requested, but install script already performs sysprep. Skipping."
  }

  Write-Log "=== Phase2 complete ==="
  Set-Phase "Done"
}

# ---- Main ----
try {
  if (Test-SetupInProgress) {
    Write-Log "Setup/OOBE in progress → Phase-Runner exits."
    exit 0
  }
  
  Write-Log "Phase runner started as $(whoami)"
  $phase = Get-Phase
  Write-Log "Detected phase: $phase"

  switch ($phase) {
    "1"    { Invoke-Phase1 }
    "2"    { Invoke-Phase2 }
    "Done" { Write-Log "Nothing to do: already Done" }
    default{ Write-Log "Unknown phase '$phase' -> set to 1 and start"; Set-Phase "1"; Invoke-Phase1 }
  }

  Save-State(@{ lastPhase=$phase; when=(Get-Date); ok=$true })
}
catch {
  Write-Log "FATAL: $($_.Exception.Message)"
  Save-State(@{ lastPhase=(Get-Phase); when=(Get-Date); ok=$false; error="$($_.Exception.Message)" })
  exit 1
}
