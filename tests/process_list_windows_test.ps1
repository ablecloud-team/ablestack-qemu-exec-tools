# Copyright 2026 ABLECLOUD. Apache-2.0.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
New-Item -ItemType Directory -Force "$root/build" | Out-Null
Add-Type -Path "$root/lib/process/AbleProcessIdentity.dll"
$canonical=[AbleProcessIdentity]::CanonicalService("a'b",$true,$false,('x'+[char]960),[string[]]@('z','A'))
$expected='{"account":"a''b","canStart":true,"canStop":false,"command":"x'+[char]960+'","requires":["A","z"],"wants":[]}'
if($canonical -cne $expected){throw 'Noncanonical service configuration JSON'}
$request=@{schemaVersion='1.0';kind='readRequest';requestId=[guid]::NewGuid().ToString();authority=@{vmUuid=[guid]::NewGuid().ToString();hostUuid=[guid]::NewGuid().ToString();placementGeneration='1'};operation='process.list';operationId=$null;budgetMs=10000}
$b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request|ConvertTo-Json -Compress)))
# Separate child scope: collector watchdog and native handles cannot affect test runner.
for($attempt=0;$attempt -lt 2;$attempt++){
 $wire=& powershell.exe -NoProfile -NonInteractive -File "$root/lib/process/ProcessList.ps1" -RequestBase64 $b64
 # Cold WMI/module loading can exhaust the fixed observation budget. Retry
 # only after this local child is confirmed exited; never retry UNKNOWN QGA.
 if($LASTEXITCODE -eq 3 -and $attempt -eq 0){Write-Host 'Cold observation budget exhausted; child exit confirmed; testing a new read';continue}
 if($LASTEXITCODE){throw "Collector exit $LASTEXITCODE"}
 break
}
[IO.File]::WriteAllText("$root/build/windows-snapshot.json",($wire -join "`n"),(New-Object Text.UTF8Encoding($false)))
$snapshot=$wire|ConvertFrom-Json
if($snapshot.kind -ne 'snapshot' -or $snapshot.processes.Count -lt 5){throw 'Missing process snapshot'}
$self=@($snapshot.processes|Where-Object {$_.identity.pid -eq $PID})
if($self.Count -ne 1){throw 'Test parent process missing'}
if([long]$self[0].identity.startTicks -ne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc()){throw 'Native start identity mismatch'}
foreach($row in $snapshot.processes){
 if($row.allowedActions.Count){throw 'Unsafe action advertisement'}
 if($null -ne $row.cpuPercent -and ([double]$row.cpuPercent -lt 0 -or [double]::IsNaN([double]$row.cpuPercent) -or [double]::IsInfinity([double]$row.cpuPercent))){throw 'Invalid CPU sample'}
 foreach($svc in $row.services){
  $actual=Get-CimInstance Win32_Service -Filter ("Name='"+$svc.name.Replace("'","''")+"'")
  if($actual.ProcessId -ne $row.identity.pid){throw 'SCM PID mismatch'}
 }
}
Write-Host "PASS: $($snapshot.processes.Count) rows; parent identity exact; SCM mappings verified"
