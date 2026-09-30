# Copyright 2026 ABLECLOUD. Apache-2.0. Read-only process collector.
param([Parameter(Mandatory=$true)][string]$RequestBase64)
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RequestBase64)) | ConvertFrom-Json
if($request.schemaVersion -ne '1.0' -or $request.operation -ne 'process.list' -or $request.budgetMs -lt 1 -or $request.budgetMs -gt 10000){exit 2}
$watch=[Diagnostics.Stopwatch]::StartNew()
$budget=[Math]::Min(3000,$request.budgetMs)
Add-Type -Path (Join-Path $PSScriptRoot 'AbleProcessIdentity.dll')
[AbleProcessIdentity]::StartDeadline([Math]::Max(1,$budget-$watch.ElapsedMilliseconds+200))
try {
    $os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 1
    $build=[int]$os.BuildNumber
    $supportedClient=($os.ProductType -eq 1 -and $build -ge 22000 -and $build -lt 30000)
    $supportedServer=($os.ProductType -ne 1 -and $build -in @(17763,20348,26100))
    if(-not ($supportedClient -or $supportedServer)){throw 'unsupported OS'}
    $boot='windows:'+$os.LastBootUpTime.ToUniversalTime().ToFileTimeUtc().ToString()
    $now=[DateTime]::UtcNow
    $snapshot=[ordered]@{schemaVersion='1.0';kind='snapshot';requestId=$request.requestId;authority=$request.authority;snapshotId=[guid]::NewGuid().ToString();bootId=$boot;observedAt=$now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ');expiresAt=$now.AddSeconds(10).ToString('yyyy-MM-ddTHH:mm:ss.fffZ');status='OK';truncated=$false;totalKnown=$null;processes=@()}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $processes=Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,CreationDate,WorkingSetSize -OperationTimeoutSec 1
    $firstCpu=@{}
    foreach($item in $processes) {
        if($watch.ElapsedMilliseconds -ge $budget-300){break}
        if($item.ProcessId -gt 0){$sample=[AbleProcessIdentity]::ReadCpu([uint32]$item.ProcessId);if($null -ne $sample){$firstCpu[[string]$item.ProcessId]=$sample}}
    }
    $services=@{}
    try {
        $scm=Get-CimInstance Win32_Service -OperationTimeoutSec 1
        foreach($svc in $scm) {
            if($watch.ElapsedMilliseconds -gt $budget){$snapshot.status='PARTIAL'; break}
            if($svc.ProcessId -le 0){continue}
            # Ordered keys match Unicode code-point sorting. Never expose the command itself.
            $dependencies=@((Get-Service -Name $svc.Name).ServicesDependedOn | ForEach-Object {$_.Name} | Sort-Object)
            $config=[AbleProcessIdentity]::CanonicalService([string]$svc.StartName,($svc.StartMode -ne 'Disabled'),[bool]$svc.AcceptStop,[string]$svc.PathName,[string[]]$dependencies)
            $sha=[Security.Cryptography.SHA256]::Create()
            try {$digest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($config)))).Replace('-','').ToLowerInvariant()}
            finally {$sha.Dispose()}
            $key=[string]$svc.ProcessId
            if(-not $services.ContainsKey($key)){$services[$key]=New-Object 'System.Collections.Generic.List[object]'}
            $services[$key].Add([ordered]@{manager='scm';name=[string]$svc.Name;configurationHash=$digest})
        }
    } catch {$snapshot.status='PARTIAL'}
    if($firstCpu.Count -gt 0 -and $watch.ElapsedMilliseconds -lt $budget-300){
        $earliest=($firstCpu.Values | Measure-Object -Property SampleStamp -Minimum).Minimum
        $elapsedMs=1000.0*([Diagnostics.Stopwatch]::GetTimestamp()-$earliest)/[Diagnostics.Stopwatch]::Frequency
        $waitMs=[Math]::Min([Math]::Max(0,250-$elapsedMs),[Math]::Max(0,$budget-$watch.ElapsedMilliseconds-150))
        if($waitMs -ge 1){[Threading.Thread]::Sleep([int]$waitMs)}
    }
    $size=1024
    foreach($item in ($processes | Sort-Object ProcessId)) {
        if($item.ProcessId -le 0){continue}
        if($watch.ElapsedMilliseconds -gt $budget){$snapshot.status='PARTIAL';$snapshot.truncated=$true;break}
        $identity=[AbleProcessIdentity]::Read([uint32]$item.ProcessId)
        if(-not $identity -or -not $item.CreationDate){$snapshot.status='PARTIAL';continue}
        # CIM has microsecond precision; native FILETIME retains all 100ns ticks.
        $cimTicks=$item.CreationDate.ToUniversalTime().ToFileTimeUtc()
        if([decimal]::Floor([decimal]$identity.Start/10) -ne [decimal]::Floor([decimal]$cimTicks/10)){$snapshot.status='PARTIAL';continue}
        $mapped=@();$key=[string]$item.ProcessId
        $cpu=$null
        if($firstCpu.ContainsKey($key)) {
            $sample=$firstCpu[$key]
            $elapsed=([double]($identity.SampleStamp-$sample.SampleStamp))/[Diagnostics.Stopwatch]::Frequency
            if($identity.Start -eq $sample.Start -and $identity.Cpu100ns -ge $sample.Cpu100ns -and $elapsed -ge 0.25) {
                $cpu=[Math]::Round((($identity.Cpu100ns-$sample.Cpu100ns)/10000000.0)/$elapsed*100.0,2)
            }
        }
        if($services.ContainsKey($key)){$mapped=@($services[$key].ToArray() | Select-Object -First 128);if($services[$key].Count -gt 128){$snapshot.status='PARTIAL'}}
        if(-not $identity.Owner){$snapshot.status='PARTIAL'}
        $name=[string]$item.Name;if($name.Length -gt 256){$name=$name.Substring(0,256)};if(-not $name){$name='?'}
        $row=[ordered]@{identity=[ordered]@{vmUuid=$request.authority.vmUuid;bootId=$boot;pid=[long]$item.ProcessId;startTicks=$identity.Start};ppid=[long]$item.ParentProcessId;name=$name;owner=$identity.Owner;state='Running';memoryBytes=[long]$item.WorkingSetSize;cpuPercent=$cpu;services=$mapped;allowedActions=@()}
        $length=[Text.Encoding]::UTF8.GetByteCount(($row | ConvertTo-Json -Depth 8 -Compress))+1
        if($rows.Count -ge 10000 -or $size+$length -gt 1047552){$snapshot.status='PARTIAL';$snapshot.truncated=$true;break}
        $rows.Add($row);$size+=$length
    }
    $snapshot.processes=@($rows.ToArray())
    if($snapshot.status -eq 'OK'){$snapshot.totalKnown=$rows.Count}
    $wire=$snapshot | ConvertTo-Json -Depth 10 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($wire) -gt 1048576){throw 'output bound'}
    [Console]::WriteLine($wire)
} catch {
    [Console]::WriteLine((@{schemaVersion='1.0';kind='failure';requestId=$request.requestId;authority=$request.authority;error=@{code='CHECK_FAILED';message='Windows process observation unavailable';retryMode='READ_ONLY'}} | ConvertTo-Json -Depth 6 -Compress))
}

[AbleProcessIdentity]::StopDeadline()
