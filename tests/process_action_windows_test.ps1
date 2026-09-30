# Copyright 2026 ABLECLOUD. Apache-2.0.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Add-Type -Path "$root/lib/process/AbleProcessIdentity.dll"
Add-Type -Path "$root/lib/process/AbleProcessAction.dll"
$boot='windows:'+(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToFileTimeUtc().ToString()
function Request($process,[string]$action='process.kill'){
 return [ordered]@{schemaVersion='1.0';kind='actionRequest';requestId=[guid]::NewGuid().ToString();authority=@{vmUuid='11111111-1111-4111-8111-111111111111';hostUuid='22222222-2222-4222-8222-222222222222';placementGeneration='42'};operationId=[guid]::NewGuid().ToString();action=$action;identity=@{vmUuid='11111111-1111-4111-8111-111111111111';bootId=$boot;pid=$process.Id;startTicks=([AbleProcessIdentity]::Read([uint32]$process.Id)).Start};snapshotId=[guid]::NewGuid().ToString();observedAt=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ');service=$null;budgetMs=10000}
}
function Invoke-Action($r){
 $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($r|ConvertTo-Json -Depth 12 -Compress)))
 $wire=& powershell.exe -NoProfile -NonInteractive -File "$root/lib/process/ProcessAction.ps1" -RequestBase64 $encoded
 if($LASTEXITCODE){throw 'action execution failed'}
 return $wire|ConvertFrom-Json
}
$fixture=Join-Path $root 'build/AbleProcessQ5Fixture.exe'
$p=Start-Process -FilePath $fixture -PassThru -WindowStyle Hidden
try{
 Start-Sleep -Milliseconds 100
 $r=Request $p;$r.observedAt='2000-01-01T00:00:00Z';$bad=Request $p;$bad.identity.startTicks='1'
 $denied=Invoke-Action $bad;if($denied.error.code -ne 'STALE_IDENTITY' -or $p.HasExited){throw 'stale identity accepted'}
 $result=Invoke-Action $r;if($result.state -ne 'SUCCEEDED' -or $result.postcondition -ne 'TARGET_EXITED'){throw ($result|ConvertTo-Json -Depth 10)}
 $p.WaitForExit();$again=Invoke-Action $r;if($again.state -ne 'SUCCEEDED' -or $again.completedAt -ne $result.completedAt){throw 'duplicate replay'}
 $r.action='process.terminate';if((Invoke-Action $r).error.code -ne 'REQUEST_CONFLICT'){throw 'conflict accepted'}
 $result|ConvertTo-Json -Depth 12|Set-Content "$root/build/windows-action.json" -Encoding UTF8
 try{[AbleProcessAction]::ValidateJson('{"x":1,"x":2}');throw 'duplicate accepted'}catch{if($_.Exception.Message -eq 'duplicate accepted'){throw}}
 Write-Output 'PASS: Windows native identity, kill, durable replay, conflict and strict JSON'
}finally{if(-not $p.HasExited){$p.Kill()};$p.Dispose()}

$name='AbleProcessQ5Fixture'
try {
 New-Service -Name $name -BinaryPathName ('"'+$fixture+'" service') -StartupType Manual | Out-Null
 Start-Service $name
 $svc=Get-CimInstance Win32_Service -Filter "Name='$name'"
 $p=Get-Process -Id $svc.ProcessId
 $r=Request $p 'service.restart'
 $controller=Get-Service $name
 $deps=[string[]]@($controller.ServicesDependedOn|ForEach-Object {$_.Name})
 $canonical=[AbleProcessIdentity]::CanonicalService([string]$svc.StartName,($svc.StartMode -ne 'Disabled'),[bool]$svc.AcceptStop,[string]$svc.PathName,$deps)
 $sha=[Security.Cryptography.SHA256]::Create()
 $hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant()
 $r.service=@{manager='scm';name=$name;configurationHash=$hash}
 $value=Invoke-Action $r
 $value|ConvertTo-Json -Depth 12 -Compress
 if($value.state -ne 'SUCCEEDED'){throw 'service restart not verified'}
 $again=Invoke-Action $r;if($again.completedAt -ne $value.completedAt){throw 'service replay'}
 Write-Output 'PASS: service restart and durable duplicate'
}finally{Stop-Service $name -ErrorAction SilentlyContinue; & sc.exe delete $name | Out-Null}
