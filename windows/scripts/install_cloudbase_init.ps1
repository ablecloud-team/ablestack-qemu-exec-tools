# ablestack-qemu-exec-tools/windows/scripts/install_cloudbase_init.ps1
# Cloudbase-Init unattended install + conf(main/unattend) deploy + sysprep

# -------- Paths (relative to this script) --------
$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Definition
$MsiPath       = Join-Path $ScriptDir "..\cloudbase-init\CloudbaseInitSetup_x64.msi"

$ConfMainSrc   = Join-Path $ScriptDir "cloudbase-init.conf"               # <- uploaded/customized
$ConfUnattSrc  = Join-Path $ScriptDir "cloudbase-init-unattend.conf"      # <- uploaded/customized
$UnattendSrc   = Join-Path $ScriptDir "Unattend.xml"                      # <- uploaded/customized

$ConfDir       = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf"
$ConfMainDst   = Join-Path $ConfDir "cloudbase-init.conf"
$ConfUnattDst  = Join-Path $ConfDir "cloudbase-init-unattend.conf"
$UnattendDst   = "C:\Windows\Panther\Unattend.xml"

$SysprepExe    = "$env:SystemRoot\System32\Sysprep\Sysprep.exe"
$SysprepArgs   = "/generalize /oobe /shutdown /unattend:$UnattendDst"

function Abort($msg) { Write-Error $msg; exit 1 }

# -------- 1) Install Cloudbase-Init (MSI) --------
Write-Host "[INFO] Installing Cloudbase-Init MSI..."
if (-not (Test-Path $MsiPath)) { Abort "[ERROR] MSI not found: $MsiPath" }
$MsiPath = (Resolve-Path $MsiPath).Path

# Use direct invocation to capture exit code reliably
& msiexec.exe /i "$MsiPath" /qn /norestart
if ($LASTEXITCODE -ne 0) {
    Abort "[ERROR] MSI installation failed (exitcode: $LASTEXITCODE). Try UI install or verify the MSI integrity."
}
Write-Host "[INFO] MSI installation completed."

# -------- 2) Deploy both conf files (main + unattend) --------
Write-Host "[INFO] Deploying Cloudbase-Init configuration files..."
if (-not (Test-Path $ConfMainSrc))  { Abort "[ERROR] Main conf not found: $ConfMainSrc" }
if (-not (Test-Path $ConfUnattSrc)) { Abort "[ERROR] Unattend conf not found: $ConfUnattSrc" }

# Ensure conf dir exists (installer normally creates it)
if (-not (Test-Path $ConfDir)) { New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null }

Copy-Item $ConfMainSrc  $ConfMainDst  -Force
Copy-Item $ConfUnattSrc $ConfUnattDst -Force
Write-Host "[INFO] Deployed:"
Write-Host "  - $ConfMainDst"
Write-Host "  - $ConfUnattDst"

# -------- 3) Restart service (optional but safe) --------
Write-Host "[INFO] Restarting cloudbase-init service..."
try {
    Restart-Service cloudbase-init -ErrorAction Stop
} catch {
    Write-Host "[WARN] Could not restart service now (it may start on next boot). Continuing..."
}

# -------- 4) Place Unattend.xml used by sysprep/specialize --------
Write-Host "[INFO] Placing Unattend.xml..."
if (-not (Test-Path $UnattendSrc)) { Abort "[ERROR] Unattend.xml not found: $UnattendSrc" }
Copy-Item $UnattendSrc $UnattendDst -Force
Write-Host "[INFO] Unattend deployed: $UnattendDst"

# -------- 5) Pre-clean Appx packages (user-scoped + provisioned) --------
Write-Host "[INFO] Removing user-scoped AppxPackages for all local users (pre-sysprep)..."
# Remove Appx for all local user SIDs
$users = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
    Where-Object { $_.GetValue('ProfileImagePath') -like 'C:\Users\*' } |
    ForEach-Object { $_.PSChildName }

foreach ($sid in $users) {
    Write-Host "  - Removing Appx for SID $sid ..."
    try {
        Get-AppxPackage -User $sid | Remove-AppxPackage -ErrorAction SilentlyContinue
    } catch { }
}

Write-Host "[INFO] Removing provisioned Appx packages (for future users)..."
try {
    Get-AppxProvisionedPackage -Online | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
} catch { }

# -------- 6) Run Sysprep --------
Write-Host "[INFO] Running sysprep (VM will shut down on completion)..."
if (-not (Test-Path $SysprepExe)) { Abort "[ERROR] Sysprep not found: $SysprepExe" }
Start-Process -Wait -NoNewWindow $SysprepExe -ArgumentList $SysprepArgs
Write-Host "[INFO] Sysprep completed. The VM should shut down now."

# -------- 7) Final message --------
Write-Host "`n[INFO] All Windows template steps complete:"
Write-Host "      - Cloudbase-Init installed"
Write-Host "      - cloudbase-init.conf & cloudbase-init-unattend.conf deployed"
Write-Host "      - Unattend.xml placed (specialize will run cloudbase-init with unattend conf)"
Write-Host "      - Appx packages cleaned"
Write-Host "      - Sysprep executed (/generalize /oobe /shutdown)"
Write-Host "[INFO] Register this powered-off VM as a template/image for cloning."
