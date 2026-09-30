# Copyright 2026 ABLECLOUD. Apache-2.0.
[CmdletBinding()]
param([ValidateSet('Check','Apply','Restore')][string]$Mode='Check',[string]$BackupId)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProcessPolicy.psm1') -Force
$result=[ordered]@{schemaVersion=1;profile='process-management';status='CHECK_FAILED';featureReady=$false;hostVerificationRequired=$true;changed=$false;restartPerformed=$false;rebootRequired=$false;backupId=$null}
$code=4; $lock=$null; $root=Join-Path $env:ProgramData 'ABLESTACK-ProcessPolicy'
try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges required' }
    $os=Get-CimInstance Win32_OperatingSystem
    $build=[int]$os.BuildNumber
    $isWindows11=($os.ProductType -eq 1 -and $build -ge 22000 -and $build -lt 30000)
    $isServer=($os.ProductType -ne 1 -and $build -in @(17763,20348,26100))
    if (-not ($isWindows11 -or $isServer)) { throw 'Supported targets are Windows 11 and Server 2019/2022/2025' }
    Set-PrivateDirectory $root
    Assert-RegularStateFile (Join-Path $root 'policy.lock')
    Assert-RegularStateFile (Join-Path $root 'last-result.json')
    $lock=[IO.File]::Open((Join-Path $root 'policy.lock'),'OpenOrCreate','ReadWrite','None')
    $result.rebootRequired=Test-PendingReboot
    if ($Mode -eq 'Restore') {
        if ($BackupId -notmatch '^backup-[a-f0-9]{32}$') { throw 'Invalid backup identifier' }
        Assert-RegularStateFile (Join-Path $root "$BackupId.json")
        $saved=Get-Content -LiteralPath (Join-Path $root "$BackupId.json") -Raw | ConvertFrom-Json
        if ($saved.Name -notmatch '^[A-Za-z0-9_-]+$' -or $saved.Key -ne ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$saved.Name)) { throw 'Invalid backup service' }
        $null=Split-QgaCommand $saved.Before; $null=Split-QgaCommand $saved.After
        $current=Get-CimInstance Win32_Service -Filter "Name='$($saved.Name)'"
        Assert-IndependentSession $current.ProcessId
        $result.changed=$null; $result.restartPerformed=$null
        Set-QgaCommand $saved $saved.After $saved.Before
        $result.status='RESTORED_PENDING_HOST_VERIFY'; $result.changed=$true; $result.restartPerformed=$true; $code=0
    } else {
        $policy=Get-QgaPolicy
        $result.serviceName=$policy.Name
        $result.qgaFileVersion=(Get-Item -LiteralPath $policy.Binary).VersionInfo.FileVersion
        if ($policy.Before -cne $policy.After -and $Mode -eq 'Check') { $result.status='POLICY_REPAIR_REQUIRED'; $code=5 }
        else {
            if ($Mode -eq 'Apply') {
                Set-PrivateDirectory (Join-Path $root 'probe')
                if ($policy.Before -cne $policy.After) {
                    # Reject invoking restart from QGA's own child process.
                    Assert-IndependentSession $policy.ProcessId
                    $result.backupId='backup-'+[guid]::NewGuid().ToString('N')
                    $policy | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root ($result.backupId+'.json')) -Encoding UTF8
                    $result.changed=$null; $result.restartPerformed=$null
                    try {
                        Set-QgaCommand $policy $policy.Before $policy.After
                        $verified=Get-QgaPolicy
                        if ($verified.Before -cne $verified.After) { throw 'Effective policy remains restricted' }
                    } catch {
                        $failure=$_.Exception.Message
                        try { Set-QgaCommand $policy $policy.After $policy.Before }
                        catch { throw ('ROLLBACK_REQUIRED: '+$result.backupId+'; '+$_.Exception.Message) }
                        throw ('Repair failed; original policy restored: '+$failure)
                    }
                    $result.changed=$true; $result.restartPerformed=$true
                }
            }
            $result.status='POLICY_CONFIGURED_PENDING_HOST_VERIFY'; $code=0
        }
    }
    if ($result.rebootRequired -and $code -eq 0) { $result.status='REBOOT_REQUIRED'; $code=3010 }
} catch { $result.status='CHECK_FAILED'; $result.error=$_.Exception.Message; $code=4 }
finally {
    if ($lock) {
        try { $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'last-result.json') -Encoding UTF8 }
        catch { $result.status='CHECK_FAILED'; $result.error='Unable to persist policy result'; $code=4 }
        finally { $lock.Dispose() }
    }
}
$result | ConvertTo-Json -Depth 6 -Compress
exit $code

