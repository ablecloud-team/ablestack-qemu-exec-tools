$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root='C:\ProgramData\ABLESTACK-Q62-Validation'
$helper=Join-Path $root 'Repair-ProcessPolicy.ps1'
Import-Module (Join-Path $root 'ProcessPolicy.psm1') -Force
$result=[ordered]@{status='FAILED';steps=@();cleanup=$false}
$original=$null
function Snapshot {
    [ordered]@{
        machineGuid=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
        boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
        network=@(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | Sort-Object Index | Select-Object Index,DHCPEnabled,IPAddress,DefaultIPGateway,DNSServerSearchOrder)
        users=@(Get-LocalUser | Sort-Object Name | Select-Object Name,SID,Enabled,PasswordLastSet)
    } | ConvertTo-Json -Depth 8 -Compress
}
function Run-Policy([string]$Mode,[string]$Backup='') {
    $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper,'-Mode',$Mode); if ($Backup) { $arguments+=@('-BackupId',$Backup) }; $output=& powershell.exe @arguments
    $rc=$LASTEXITCODE
    $json=$output | ConvertFrom-Json
    if ($rc -ne 0) { throw "Policy $Mode failed ($rc): $output" }
    return $json
}
try {
    $before=Snapshot
    $original=Get-QgaPolicy
    $original | ConvertTo-Json | Set-Content (Join-Path $root 'original-service.json') -Encoding UTF8
    $first=Run-Policy Apply
    $second=Run-Policy Apply
    if ($first.changed -or $second.changed -or $second.restartPerformed) { throw 'Default policy changed' }
    $result.steps+=@('default-apply','default-reapply')
    $restricted=$original.Before+' --block-rpcs=guest-exec,guest-file-write,guest-shutdown'
    Set-QgaCommand $original $original.Before $restricted
    $out=& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -Mode Check
    if ($LASTEXITCODE -ne 5) { throw "Restriction was not detected: $out" }
    $applied=Run-Policy Apply
    if (-not $applied.changed -or -not $applied.restartPerformed) { throw 'Restriction not repaired' }
    if ((Get-ItemProperty $original.Key).ImagePath -cne ($original.Before+' --block-rpcs=guest-shutdown')) { throw 'Unrelated restriction lost' }
    $result.steps+=@('restricted-check','policy-repair','unrelated-denial-preserved')
    $again=Run-Policy Apply
    if ($again.changed -or $again.restartPerformed) { throw 'Repair not idempotent' }
    $restored=Run-Policy Restore $applied.backupId
    if ((Get-ItemProperty $original.Key).ImagePath -cne $restricted) { throw 'Backup restoration mismatch' }
    $result.steps+=@('reapply','backup-restore')
    Set-QgaCommand $original $restricted $original.Before
    $original=$null
    if ((Snapshot) -cne $before) { throw 'VM identity, network, users or boot changed' }
    $result.steps+='identity-network-users-boot-preserved'
    $result.status='PASSED'
} catch { $result.error=$_.Exception.Message }
finally {
    if ($original) {
        try {
            $current=(Get-ItemProperty $original.Key).ImagePath
            if ($current -cne $original.Before) { Set-QgaCommand $original $current $original.Before }
        } catch { $result.status='ROLLBACK_REQUIRED'; $result.rollbackError=$_.Exception.Message }
    }
    $result.cleanup=($result.status -ne 'ROLLBACK_REQUIRED')
    $result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'live-result.json') -Encoding UTF8
}
