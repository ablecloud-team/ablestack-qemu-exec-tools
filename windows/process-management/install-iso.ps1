# Copyright 2026 ABLECLOUD. Apache-2.0.
[CmdletBinding()]
param([switch]$SkipDrivers)
$ErrorActionPreference='Stop'

$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[INFO] Requesting administrator privileges for ABLESTACK Tools installation'
    $arguments="-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($SkipDrivers) { $arguments+=' -SkipDrivers' }
    try {
        $elevated=Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        exit $elevated.ExitCode
    } catch {
        Write-Host ("[FAILED] Administrator elevation failed: "+$_.Exception.Message)
        exit 4
    }
}

$installer=Join-Path $PSScriptRoot 'process-management\install.ps1'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    Write-Host '[FAILED] ABLESTACK Tools installer payload missing'
    exit 4
}
$logDirectory=Join-Path $env:ProgramData 'ABLESTACK-Tools'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$transcript=Join-Path $logDirectory 'install.log'
Start-Transcript -Path $transcript -Append | Out-Null
$code=4
try {
    Write-Host 'ABLESTACK Tools: VirtIO drivers, QEMU Guest Agent, Process Tools'
    Write-Host "Installation log: $transcript"
    & $installer -Mode Apply -InstallQga -InstallDrivers:(-not $SkipDrivers)
    $code=$LASTEXITCODE
    if ($code -eq 0) {
        Write-Host '[COMPLETE] All components and QGA policy configured'
    } elseif ($code -eq 3010) {
        Write-Host '[REBOOT] Installation completed; restart Windows before using the tools'
    } else {
        Write-Host "[FAILED] Installer returned $code; see $transcript"
    }
} catch {
    Write-Host ("[FAILED] "+$_.Exception.Message)
    Write-Host "[FAILED] See $transcript"
    $code=4
} finally {
    Stop-Transcript | Out-Null
}
exit $code
