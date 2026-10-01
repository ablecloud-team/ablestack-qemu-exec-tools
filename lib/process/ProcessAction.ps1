# Copyright 2026 ABLECLOUD. Apache-2.0.
param([Parameter(Mandatory=$true)][string]$RequestBase64)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
Add-Type -Path (Join-Path $PSScriptRoot 'AbleProcessIdentity.dll')
Add-Type -Path (Join-Path $PSScriptRoot 'AbleProcessAction.dll')
# The extension is loaded only for protocol 1.1; old installations remain usable.

function Json($value){return ConvertTo-Json -InputObject $value -Depth 20 -Compress}
function Utc {return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')}
function Uuid($value){if($value -isnot [string] -or $value -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'UUID'}}
function Fields($value,[string]$names){if($null -eq $value -or (($value.Keys | Sort-Object) -join ',') -cne (($names.Split(' ') | Sort-Object) -join ',')){throw 'fields'}}
function Hash([string]$text){$sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Failure([string]$code){return @{schemaVersion=$r.schemaVersion;kind='failure';requestId=$r.requestId;authority=$r.authority;error=@{code=$code;message='Process operation unavailable';retryMode= $(if($code -in @('BUSY','NOT_FOUND')){'READ_ONLY'}else{'NONE'})}}}
function Unknown($value){$value.state='UNKNOWN';$value.effect='MAY_HAVE_RUN';$value.completedAt=$null;$value.postcondition='NOT_CHECKED';$value.error=@{code='RESULT_UNKNOWN';message='Execution may have occurred; query only';retryMode='READ_ONLY'}}
function Success($value){$value.state='SUCCEEDED';$value.effect='VERIFIED';$value.completedAt=Utc;$value.guestExitCode=0;$value.postcondition=$(if($value.action -eq 'service.restart'){'SERVICE_RESTART_VERIFIED'}else{'TARGET_EXITED'});$value.error=$null}
function Persist {[AbleProcessAction]::Save($journal,(Json $state))}
function Deadline {if($watch.ElapsedMilliseconds -ge $r.budgetMs){throw 'RESULT_UNKNOWN'}}
function Boot {return 'windows:'+(Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 2).LastBootUpTime.ToUniversalTime().ToFileTimeUtc().ToString()}
function ServiceInfo([string]$name){
    Deadline
    # Name validated without WQL metacharacters; never accept arbitrary query input.
    $svc=Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'") -OperationTimeoutSec 2
    if(-not $svc){throw 'STALE_IDENTITY'}
    $controller=Get-Service -Name $name
    $dependencies=[string[]]@($controller.ServicesDependedOn | ForEach-Object {$_.Name})
    $canonical=[AbleProcessIdentity]::CanonicalService([string]$svc.StartName,($svc.StartMode -ne 'Disabled'),[bool]$svc.AcceptStop,[string]$svc.PathName,$dependencies)
    return @{svc=$svc;controller=$controller;hash=(Hash $canonical)}
}
function ServiceCheck {
    $name=$r.service.name
    if($name -match '^(QEMU|WinDefend|WdNis|Winmgmt|RpcSs|DcomLaunch|EventLog|SamSs|LSM|Power|PlugPlay|BFE|MpsSvc|Dhcp|Dnscache|Lanman|Netlogon|Schedule|TermService|TrustedInstaller|CryptSvc|W32Time|W32Time|ABLESTACK)'){throw 'PROTECTED_TARGET'}
    $info=ServiceInfo $name
    if($info.hash -cne $r.service.configurationHash -or $info.svc.ProcessId -ne $r.identity.pid){throw 'STALE_IDENTITY'}
    if($info.svc.State -ne 'Running' -or -not $info.svc.AcceptStop -or @($info.controller.DependentServices).Count -gt 0){throw 'UNSUPPORTED_ACTION'}
    $sharing=@(Get-CimInstance Win32_Service -Filter ('ProcessId='+$r.identity.pid) -OperationTimeoutSec 2)
    if($sharing.Count -ne 1){throw 'UNSUPPORTED_ACTION'}
    return $info
}
function Reconcile($record){
    $value=$record.result
    if($value.state -in @('ACCEPTED','RUNNING','UNKNOWN')){
        if($value.action -eq 'process.restart'){return ProfileReconcile $record}
        Unknown $value
        if($value.identity.bootId -ceq (Boot) -and $record.stage -eq 'signal-returned'){
            $current=[AbleProcessIdentity]::Read([uint32]$value.identity.pid)
            # Read failure alone can mean access denied. Open the identity handle
            # before dispatch; for recovery only a separately enumerated absence
            # or a positively observed different generation establishes exit.
            $present=Get-CimInstance Win32_Process -Filter ('ProcessId='+$value.identity.pid) -OperationTimeoutSec 2
            if(-not $present -or ($current -and $current.Start -cne $value.identity.startTicks)){Success $value;$record.stage='complete'}
        }
        if($value.state -eq 'UNKNOWN' -and $value.identity.bootId -ceq (Boot) -and $record.stage -eq 'start-returned'){
            try{
                $info=ServiceInfo $value.service.name
                $current=[AbleProcessIdentity]::Read([uint32]$info.svc.ProcessId)
                if($info.svc.State -eq 'Running' -and $current -and $info.hash -ceq $value.service.configurationHash -and ($info.svc.ProcessId -ne $value.identity.pid -or $current.Start -cne $value.identity.startTicks)){
                    Success $value;$record.stage='complete'
                }
            }catch{}
        }
        Persist
    }
    return $value
}
function Main {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){return Failure 'PERMISSION_DENIED'}
    if($r.operation -eq 'profile.list'){return ProfileList}
    $root=Join-Path $env:ProgramData 'ABLESTACK-ProcessActions';[AbleProcessAction]::SecureDirectory($root)
    $script:journal=Join-Path $root 'journal.json';$lockPath=Join-Path $root 'lock'
    if(Test-Path -LiteralPath $lockPath){[AbleProcessAction]::CheckPath($lockPath,$false)}
    try{$lock=New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{return Failure 'BUSY'}
    try{
        if(Test-Path -LiteralPath $journal){[AbleProcessAction]::CheckPath($journal,$false);if((Get-Item -LiteralPath $journal).Length -gt 16777216){throw 'journal limit'};$script:state=[AbleProcessAction]::Parse([IO.File]::ReadAllText($journal))}
        else{$script:state=@{vmUuid=$r.authority.vmUuid;generation='0';records=@{}}}
        if($state.vmUuid -cne $r.authority.vmUuid -or [decimal]$r.authority.placementGeneration -lt [decimal]$state.generation){return Failure 'STALE_AUTHORITY'}
        $state.generation=$r.authority.placementGeneration;Persist
        $records=$state.records;$old=$records[$r.operationId]
        if($r.kind -eq 'readRequest'){if(-not $old){return Failure 'NOT_FOUND'};return Reconcile $old}
        $service=$null
        if($r.service){$service=[ordered]@{configurationHash=$r.service.configurationHash;manager=$r.service.manager;name=$r.service.name}}
        $fingerprint=[ordered]@{action=$r.action;identity=[ordered]@{bootId=$r.identity.bootId;pid=$r.identity.pid;startTicks=$r.identity.startTicks;vmUuid=$r.identity.vmUuid};observedAt=$r.observedAt;service=$service;snapshotId=$r.snapshotId}
        if($r.schemaVersion -eq '1.1'){$fingerprint.profile=$r.profile}
        $digest=Hash (Json $fingerprint)
        if($old){if($old.digest -cne $digest -or $old.result.requestId -cne $r.requestId){return Failure 'REQUEST_CONFLICT'};return Reconcile $old}
        foreach($entry in $records.Values){if($entry.result.requestId -ceq $r.requestId){return Failure 'REQUEST_CONFLICT'}}
        if($records.Count -ge 4096 -or @($records.Values | Where-Object {$_.result.state -in @('ACCEPTED','RUNNING','UNKNOWN')}).Count -gt 0){return Failure 'BUSY'}
        # Cloud snapshot monotonic TTL and host reservation enforce freshness.
        # Do not compare the host observation timestamp with a guest wall clock.
        $value=@{schemaVersion=$r.schemaVersion;kind='actionResult';requestId=$r.requestId;authority=$r.authority;operationId=$r.operationId;action=$r.action;identity=$r.identity;service=$r.service;state='ACCEPTED';effect='NOT_STARTED';submittedAt=(Utc);completedAt=$null;guestExecPid=$null;guestExitCode=$null;postcondition='NOT_CHECKED';error=$null}
        if($r.schemaVersion -eq '1.1'){$value.profile=$r.profile;ProfileProgress $value 'NOT_CHECKED' 'NOT_ATTEMPTED'}
        $record=@{digest=$digest;stage='reserved';result=$value};$records[$r.operationId]=$record;Persist
        $target=$null
        try{
            if($r.action -eq 'process.terminate'){throw 'UNSUPPORTED_ACTION'}
            if($r.identity.bootId -cne (Boot)){throw 'STALE_IDENTITY'}
            $target=New-Object AbleProcessAction+Target([uint32]$r.identity.pid,[string]$r.identity.startTicks)
            if($r.action -eq 'process.restart'){ProfileRestart $record $target;return $value}
            $info=$null
            if($r.action -eq 'service.restart'){$info=ServiceCheck}
            else{if(@(Get-CimInstance Win32_Service -Filter ('ProcessId='+$r.identity.pid) -OperationTimeoutSec 2).Count -gt 0){throw 'PROTECTED_TARGET'}}
            Deadline
            $record.stage='dispatch-intent';Unknown $value;Persist
            if(-not $info){
                $target.Kill();$record.stage='signal-returned';Persist
                while(-not $target.Exited(50)){Deadline}
            }else{
                $info=ServiceCheck;$record.stage='stop-intent';Persist
                $info.controller.Stop()
                do{Deadline;Start-Sleep -Milliseconds 50;$info.controller.Refresh()}while($info.controller.Status -ne 'Stopped' -or -not $target.Exited(0))
                $record.stage='stopped';Persist
                $next=ServiceInfo $r.service.name
                # AcceptStop is a running-state property. Compare a fresh start
                # configuration using the previously verified stop capability.
                $deps=[string[]]@($next.controller.ServicesDependedOn | ForEach-Object {$_.Name})
                $hash=Hash ([AbleProcessIdentity]::CanonicalService([string]$next.svc.StartName,($next.svc.StartMode -ne 'Disabled'),$true,[string]$next.svc.PathName,$deps))
                if($hash -cne $r.service.configurationHash){throw 'STALE_IDENTITY'}
                $record.stage='start-intent';Persist;$next.controller.Start();$record.stage='start-returned';Persist
                do{
                    Deadline;Start-Sleep -Milliseconds 50;$new=ServiceInfo $r.service.name
                    $identity=[AbleProcessIdentity]::Read([uint32]$new.svc.ProcessId)
                }while($new.svc.State -ne 'Running' -or -not $identity -or ($new.svc.ProcessId -eq $r.identity.pid -and $identity.Start -ceq $r.identity.startTicks))
                if($new.hash -cne $r.service.configurationHash){throw 'STALE_IDENTITY'}
                $record.newIdentity=@{pid=$new.svc.ProcessId;startTicks=$identity.Start}
            }
            Success $value;$record.stage='complete';Persist
        }catch{
            if($record.stage -eq 'reserved'){
                $code='STALE_IDENTITY'
                foreach($known in @('PROTECTED_TARGET','UNSUPPORTED_ACTION','STALE_IDENTITY','PROFILE_CHANGED')){if($_.Exception.ToString().Contains($known)){$code=$known;break}}
                $value.state='FAILED';$value.effect='NOT_STARTED';$value.completedAt=Utc;$value.error=@{code=$code;message='Process action rejected';retryMode='NONE'}
            }else{Unknown $value}
            Persist
        }finally{if($target){$target.Dispose()}}
        return $value
    }finally{$lock.Dispose()}
}
try{
    $raw=([Text.UTF8Encoding]::new($false,$true)).GetString([Convert]::FromBase64String($RequestBase64));[AbleProcessAction]::ValidateJson($raw);$script:r=[AbleProcessAction]::Parse($raw)
    Fields $r.authority 'vmUuid hostUuid placementGeneration';Uuid $r.requestId;Uuid $r.authority.vmUuid;Uuid $r.authority.hostUuid
    if($r.schemaVersion -cnotin @('1.0','1.1') -or $r.authority.placementGeneration -isnot [string] -or $r.authority.placementGeneration -cnotmatch '^[0-9]{1,20}$' -or $r.budgetMs -isnot [int] -or $r.budgetMs -lt 1 -or $r.budgetMs -gt 90000){throw 'request'}
    if($r.schemaVersion -eq '1.1'){. (Join-Path $PSScriptRoot 'ProcessProfile.ps1')}
    if($r.operation -ne 'profile.list'){Uuid $r.operationId}
    if($r.kind -ceq 'readRequest'){
        Fields $r 'schemaVersion kind requestId authority operation operationId budgetMs'
        if($r.operation -cnotin @('operation.get','profile.list') -or $r.budgetMs -gt 10000){throw 'operation'}
        if($r.operation -eq 'profile.list' -and ($r.schemaVersion -ne '1.1' -or $null -ne $r.operationId)){throw 'profile query'}
    }else{
        Fields $r ('schemaVersion kind requestId authority operationId action identity snapshotId observedAt service budgetMs'+$(if($r.schemaVersion -eq '1.1'){' profile'}else{''}))
        if($r.kind -cne 'actionRequest' -or $r.action -cnotin @('process.terminate','process.kill','service.restart','process.restart')){throw 'action'}
        if($r.schemaVersion -eq '1.1'){
            if($r.action -ne 'process.restart'){throw 'extension action'}
            Fields $r.profile 'id version definitionHash';Uuid $r.profile.id
            if($r.profile.version -isnot [int] -or $r.profile.version -lt 1 -or $r.profile.definitionHash -cnotmatch '^[a-f0-9]{64}$'){throw 'profile'}
        }elseif($r.action -eq 'process.restart'){throw 'extension required'}
        Fields $r.identity 'vmUuid bootId pid startTicks';Uuid $r.snapshotId
        if($r.identity.vmUuid -cne $r.authority.vmUuid -or $r.identity.bootId -isnot [string] -or $r.identity.bootId -cnotmatch '^windows:[0-9]{1,20}$' -or $r.identity.startTicks -isnot [string] -or $r.identity.startTicks -cnotmatch '^[0-9]{1,20}$' -or $r.identity.pid -isnot [int] -and $r.identity.pid -isnot [long] -or $r.identity.pid -lt 1 -or $r.identity.pid -gt 4294967295){throw 'identity'}
        if($r.observedAt -isnot [string] -or -not $r.observedAt.EndsWith('Z')){throw 'time'};[void][DateTime]::Parse($r.observedAt)
        if($r.action -ceq 'service.restart'){
            Fields $r.service 'manager name configurationHash'
            if($r.service.manager -cne 'scm' -or $r.service.name -isnot [string] -or $r.service.name -cnotmatch '^[A-Za-z0-9_.-]{1,256}$' -or $r.service.configurationHash -cnotmatch '^[a-f0-9]{64}$'){throw 'service'}
        }elseif($null -ne $r.service -or ($r.action -ne 'process.restart' -and $r.budgetMs -gt 15000)){throw 'service'}
    }
    $script:watch=[Diagnostics.Stopwatch]::StartNew();[AbleProcessIdentity]::StartDeadline($r.budgetMs+1000)
    [Console]::WriteLine((Json (Main)))
    [AbleProcessIdentity]::StopDeadline()
}catch{[Console]::Error.WriteLine('Process action request or journal unavailable');exit 3}
