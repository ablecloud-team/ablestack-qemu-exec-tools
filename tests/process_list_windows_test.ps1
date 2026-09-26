# Copyright 2026 ABLECLOUD. Apache-2.0.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
New-Item -ItemType Directory -Force "$root/build" | Out-Null
$request=@{schemaVersion='1.0';kind='readRequest';requestId=[guid]::NewGuid().ToString();authority=@{vmUuid=[guid]::NewGuid().ToString();hostUuid=[guid]::NewGuid().ToString();placementGeneration='1'};operation='process.list';operationId=$null;budgetMs=10000}
$b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request|ConvertTo-Json -Compress)))
# Separate child scope: collector watchdog and native handles cannot affect test runner.
$wire=& powershell.exe -NoProfile -NonInteractive -File "$root/lib/process/ProcessList.ps1" -RequestBase64 $b64
if($LASTEXITCODE){throw "Collector exit $LASTEXITCODE"}
[IO.File]::WriteAllText("$root/build/windows-snapshot.json",($wire -join "`n"),(New-Object Text.UTF8Encoding($false)))
$snapshot=$wire|ConvertFrom-Json
if($snapshot.kind -ne 'snapshot' -or $snapshot.processes.Count -lt 5){throw 'Missing process snapshot'}
$self=@($snapshot.processes|Where-Object {$_.identity.pid -eq $PID})
if($self.Count -ne 1){throw 'Test parent process missing'}
if([long]$self[0].identity.startTicks -ne (Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc()){throw 'Native start identity mismatch'}
foreach($row in $snapshot.processes){
 if($row.allowedActions.Count -or $null -ne $row.cpuPercent){throw 'Unsafe action/CPU advertisement'}
 foreach($svc in $row.services){
  $actual=Get-CimInstance Win32_Service -Filter ("Name='"+$svc.name.Replace("'","''")+"'")
  if($actual.ProcessId -ne $row.identity.pid){throw 'SCM PID mismatch'}
 }
}
Write-Host "PASS: $($snapshot.processes.Count) rows; parent identity exact; SCM mappings verified"
