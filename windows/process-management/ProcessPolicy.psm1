# Copyright 2026 ABLECLOUD. Apache-2.0.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Required = @('guest-exec','guest-exec-status','guest-file-open','guest-file-close','guest-file-read','guest-file-write','guest-file-seek','guest-file-flush','guest-info','guest-ping','guest-get-osinfo','guest-sync','guest-sync-delimited')

function Split-QgaCommand([string]$Command) {
    # Only accept a quoted absolute executable and literal, whitespace-free options.
    if ($Command -notmatch '^"([A-Za-z]:\\[^"\r\n]+\\qemu-ga\.exe)"(?:\s+(.*))?$') { throw 'Unsupported QGA service command' }
    $binary = $Matches[1]
    $tail = if ($Matches.ContainsKey(2)) { $Matches[2] } else { '' }
    $tokens = @($tail -split '\s+' | Where-Object { $_ })
    $seen = @{}
    foreach ($token in $tokens) {
        if ($token -in @('-d','--daemon','--retry-path','-v','--verbose')) { continue }
        if ($token -match '^--(allow|block)-rpcs=([a-z0-9,-]*)$') {
            $kind = $Matches[1]
            if ($seen.ContainsKey($kind)) { throw 'Duplicate QGA filter' }
            $seen[$kind] = $true
            foreach ($rpc in @($Matches[2] -split ',' | Where-Object { $_ })) {
                if ($rpc -notmatch '^guest-[a-z0-9-]+$') { throw 'Unsupported RPC name' }
            }
        } else { throw 'Custom QGA service options require administrator review' }
    }
    [pscustomobject]@{ Binary=$binary; Tokens=$tokens }
}

function Repair-QgaCommand([string]$Command) {
    $parsed = Split-QgaCommand $Command
    $changed = $false
    $tokens = foreach ($token in $parsed.Tokens) {
        if ($token -match '^--(allow|block)-rpcs=(.*)$') {
            $kind=$Matches[1]; $old=$Matches[2]
            $items=@($old -split ',' | Where-Object { $_ })
            if ($kind -eq 'allow') { $items += @($script:Required | Where-Object { $_ -notin $items }) }
            else { $items=@($items | Where-Object { $_ -notin $script:Required }) }
            $value=$items -join ','
            if ($value -ne $old) { $changed=$true }
            "--$kind-rpcs=$value"
        } else { $token }
    }
    if (-not $changed) { return $Command }
    '"' + $parsed.Binary + '" ' + ($tokens -join ' ')
}

function Invoke-QgaDump([string]$Binary, [string[]]$Tokens) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Binary
    $start.Arguments=(@($Tokens)+@('--dump-conf')) -join ' '
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        if (-not $process.Start()) { throw 'QGA dump failed to start' }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'QGA dump deadline exceeded' }
        $text=$stdout.Result
        if ($process.ExitCode -ne 0 -or $text.Length -gt 65536 -or $stderr.Result.Length -gt 65536) { throw 'QGA dump failed' }
        return $text
    } finally { $process.Dispose() }
}

function Get-RpcSet([string]$Value) {
    $items=@($Value -split ',' | Where-Object { $_ })
    foreach ($item in $items) { if ($item -cnotmatch '^guest-[a-z0-9-]+$') { throw 'Unsupported effective RPC filter' } }
    (@($items | Sort-Object -Unique) -join ',')
}

function Get-QgaPolicy {
    $services=@(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'qemu-ga\.exe' })
    if ($services.Count -ne 1) { throw 'Exactly one installed QGA service is required' }
    $svc=$services[0]
    if ($svc.StartName -ne 'LocalSystem') { throw 'Custom QGA service account requires administrator review' }
    if ($svc.State -ne 'Running') { throw 'QGA service is not running' }
    $key='HKLM:\SYSTEM\CurrentControlSet\Services\'+$svc.Name
    if ($svc.Name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Unsupported service name' }
    $raw=(Get-ItemProperty $key).ImagePath
    $running=Get-CimInstance Win32_Process -Filter "ProcessId=$($svc.ProcessId)"
    if ($running.CommandLine -cne $raw) { throw 'Running QGA differs from service configuration' }
    $parsed=Split-QgaCommand $raw
    if (-not (Test-Path -LiteralPath $parsed.Binary -PathType Leaf)) { throw 'QGA executable missing' }
    # A hidden service/machine configuration must not be mistaken for CLI defaults.
    if ([Environment]::GetEnvironmentVariable('QGA_CONF','Machine') -or $env:QGA_CONF) { throw 'External QGA_CONF requires administrator review' }
    $serviceEnv=(Get-Item -LiteralPath $key).GetValue('Environment',$null)
    if (@($serviceEnv | Where-Object { $_ -match '^QGA_CONF=' }).Count) { throw 'Service QGA_CONF requires administrator review' }
    $dump=Invoke-QgaDump $parsed.Binary $parsed.Tokens
    $values=@{}
    foreach ($line in ($dump -split '\r?\n')) {
        if ($line -match '^(allow-rpcs|block-rpcs)=(.*)$') {
            if ($values.ContainsKey($Matches[1])) { throw 'Duplicate dumped filter' }
            $values[$Matches[1]]=$Matches[2]
        }
    }
    if (-not $values.ContainsKey('allow-rpcs') -or -not $values.ContainsKey('block-rpcs')) { throw 'Unsupported QGA dump format' }
    # Compare every filter with CLI; refuse default INI restrictions or precedence ambiguity.
    foreach ($kind in @('allow','block')) {
        $filter=@($parsed.Tokens | Where-Object { $_.StartsWith("--$kind-rpcs=") })
        $expected=if ($filter.Count) { $filter[0].Split('=',2)[1] } else { '' }
        if ((Get-RpcSet $values["$kind-rpcs"]) -cne (Get-RpcSet $expected)) { throw 'QGA effective filter has an unsupported configuration source' }
    }
    [pscustomobject]@{Name=$svc.Name; Key=$key; Before=$raw; After=(Repair-QgaCommand $raw); ProcessId=$svc.ProcessId; Binary=$parsed.Binary}
}

function Set-PrivateDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
    $item=Get-Item -LiteralPath $Path
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse directory refused' }
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity=New-Object Security.Principal.SecurityIdentifier($sid)
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-IndependentSession([int]$QgaPid) {
    $ancestor=$PID
    for ($n=0; $n -lt 32 -and $ancestor -gt 0; $n++) {
        if ($ancestor -eq $QgaPid) { throw 'Use an independent administrator session to restart QGA' }
        $process=Get-CimInstance Win32_Process -Filter "ProcessId=$ancestor"
        if (-not $process) { return }
        $parent=Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ParentProcessId)"
        if (-not $parent -or $parent.CreationDate -gt $process.CreationDate) { return }
        $ancestor=$process.ParentProcessId
    }
    if ($ancestor -gt 0) { throw 'Unable to establish independent process ancestry' }
}

function Assert-RegularStateFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item=Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe policy state file' }
    }
}

function Restart-Qga([string]$Name) {
    $service=Get-Service -Name $Name
    if ($service.Status -ne 'Stopped') { $service.Stop(); $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15)) }
    $service.Start(); $service.WaitForStatus('Running',[TimeSpan]::FromSeconds(15))
}

function Set-QgaCommand($Policy,[string]$Expected,[string]$Value) {
    if ((Get-ItemProperty $Policy.Key).ImagePath -cne $Expected) { throw 'Concurrent administrator change; refusing overwrite' }
    Set-ItemProperty -LiteralPath $Policy.Key -Name ImagePath -Value $Value
    Restart-Qga $Policy.Name
}

function Test-PendingReboot {
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    [bool]((Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager').GetValue('PendingFileRenameOperations',$null))
}
Export-ModuleMember -Function *
