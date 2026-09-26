# Copyright 2026 ABLECLOUD. Apache-2.0.
[CmdletBinding()]
param([ValidateSet('Check','Apply','Restore')][string]$Mode='Apply',[string]$BackupId,[switch]$InstallQga)
$ErrorActionPreference='Stop'
$result=[ordered]@{schemaVersion=1;profile='process-management';status='CHECK_FAILED';featureReady=$false;hostVerificationRequired=$true;rebootRequired=$false}
try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this installer from an elevated administrator session' }
    if ($Mode -ne 'Apply' -and $InstallQga) { throw 'InstallQga is only valid with Apply' }
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1) { throw 'Unsupported manifest' }
    $expected=@('ProcessPolicy.psm1','Repair-ProcessPolicy.ps1','ABLESTACK-ProcessTools.msi','qemu-ga-x86_64.msi')
    foreach ($name in $expected) {
        $entry=@($manifest.files | Where-Object { $_.name -ceq $name })
        if ($entry.Count -ne 1 -or $entry[0].sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Missing manifest entry: $name" }
        $hash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash
        if ($hash -ne $entry[0].sha256) { throw "Payload hash mismatch: $name" }
    }
    $services=@(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'qemu-ga\.exe' })
    if ($services.Count -gt 1) { throw 'Multiple QGA services require administrator review' }
    if ($services.Count -eq 0 -and -not $InstallQga) { throw 'QGA_MISSING: explicit -InstallQga required for offline installation' }
    if ($InstallQga) {
        if ($services.Count -eq 1) {
            Import-Module (Join-Path $PSScriptRoot 'ProcessPolicy.psm1') -Force
            Assert-IndependentSession $services[0].ProcessId
        }
        $msi=Join-Path $PSScriptRoot 'qemu-ga-x86_64.msi'
        $p=Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart REBOOT=ReallySuppress" -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 3010) { $result.status='REBOOT_REQUIRED'; $result.rebootRequired=$true; $result | ConvertTo-Json -Compress; exit 3010 }
        if ($p.ExitCode -ne 0) { throw "QGA MSI installation failed: $($p.ExitCode)" }
        $svc=@(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'qemu-ga\.exe' })
        if ($svc.Count -ne 1) { throw 'QGA service absent after installation' }
        Start-Service $svc[0].Name
    }
    if ($Mode -eq 'Apply') {
        $msi=Join-Path $PSScriptRoot 'ABLESTACK-ProcessTools.msi'
        $p=Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart REBOOT=ReallySuppress" -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 3010) { $result.status='REBOOT_REQUIRED'; $result.rebootRequired=$true; $result | ConvertTo-Json -Compress; exit 3010 }
        if ($p.ExitCode -ne 0) { throw "Process Tools MSI installation failed: $($p.ExitCode)" }
    }
    & (Join-Path $PSScriptRoot 'Repair-ProcessPolicy.ps1') -Mode $Mode -BackupId $BackupId
    exit $LASTEXITCODE
} catch {
    $result.error=$_.Exception.Message
    $result | ConvertTo-Json -Compress
    exit 4
}
