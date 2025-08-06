# ablestack-qemu-exec-tools/windows/scripts/install_cloudbase_init.ps1
# cloudbase-init unattended installation + conf/Unattend setup + sysprep automation

# 1. Environment (relative path)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$MsiPath   = Join-Path $ScriptDir "..\cloudbase-init\CloudbaseInitSetup_x64.msi"
$ConfSrc   = Join-Path $ScriptDir "cloudbase-init.conf.template"
$ConfDst   = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf"
$UnattendSrc = Join-Path $ScriptDir "unattend.xml"
$UnattendDst = "C:\Windows\Panther\unattend.xml"

function Abort($msg) { Write-Error $msg; exit 1 }

# 2. Unattended installation of cloudbase-init MSI
Write-Host "[INFO] Starting unattended installation of Cloudbase-Init MSI..."
if (-not (Test-Path $MsiPath)) { Abort "[ERROR] cloudbase-init MSI file not found: $MsiPath" }
Start-Process msiexec.exe -ArgumentList "/i `"$MsiPath`" /qn /norestart" -Wait
Write-Host "[INFO] Cloudbase-Init MSI installation completed."

# 3. Apply conf template to actual conf (with or without variable substitution)
Write-Host "[INFO] Applying cloudbase-init.conf template..."
if (-not (Test-Path $ConfSrc)) { Abort "[ERROR] conf template not found: $ConfSrc" }
Copy-Item $ConfSrc $ConfDst -Force
Write-Host "[INFO] conf file deployed: $ConfDst"

# 4. Restart cloudbase-init service
Write-Host "[INFO] Restarting cloudbase-init service..."
Restart-Service cloudbase-init

# 5. Copy unattend.xml (Korean language, version-agnostic)
Write-Host "[INFO] Deploying unattend.xml..."
if (-not (Test-Path $UnattendSrc)) { Abort "[ERROR] unattend.xml not found: $UnattendSrc" }
Copy-Item $UnattendSrc $UnattendDst -Force

# 6. Sysprep automation (SID/environment reset)
Write-Host "[INFO] Running sysprep: VM template creation and SID reinitialization (VM will shut down soon)"
$SysprepExe = "$env:SystemRoot\System32\Sysprep\Sysprep.exe"
$SysprepArgs = "/generalize /oobe /shutdown /unattend:$UnattendDst"
Start-Process -Wait -NoNewWindow $SysprepExe -ArgumentList $SysprepArgs
Write-Host "[INFO] Sysprep completed. VM will shut down soon."

# 7. Final message
Write-Host "`n[INFO] ablestack cloudbase-init automation and templating are complete!"
Write-Host "[INFO] Now register this VM as an image/template for future cloning."
Write-Host "[INFO] Upon clone/deployment, SID, password, and cloudbase-init metadata will be freshly applied."
