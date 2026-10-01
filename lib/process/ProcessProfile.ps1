# Copyright 2026 ABLECLOUD. Apache-2.0.
# Dot-sourced only by the authenticated fixed adapter or administrator registrar.
function ProfilePaths([string]$id) {
    Uuid $id
    $base=Join-Path $env:ProgramData 'ABLESTACK-ProcessActions'
    return @((Join-Path (Join-Path $base 'profiles') ($id+'.json')),(Join-Path $base ('profile-'+$id+'.binding.json')))
}
function ProfileRegular([string]$path,[bool]$private=$false) {
    if(-not [IO.Path]::IsPathRooted($path)){throw 'PROFILE_CHANGED'}
    $item=Get-Item -LiteralPath $path
    if($item.PSIsContainer -or $item.Length -gt 67108864){throw 'PROFILE_CHANGED'}
    [AbleProcessAction]::CheckPath($path,$false)
    if($private) {
        $acl=[IO.File]::GetAccessControl($path)
        foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData) -ne 0){throw 'PROFILE_CHANGED'}
        }
    }
    $parent=$item.Directory
    while($parent -and $parent.Parent) {
        if(($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'PROFILE_CHANGED'}
        $parent=$parent.Parent
    }
}
function TaskInfo([string]$name) {
    $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
    $task=$scheduler.GetFolder('\ABLESTACKProfiles').GetTask($name)
    $xml=[string]$task.Xml
    if($xml.Length -gt 65536){throw 'PROFILE_CHANGED'}
    return @{task=$task;hash=(Hash $xml)}
}
function ProfileLoad([string]$id,[string]$vm) {
    $paths=ProfilePaths $id;ProfileRegular $paths[0];ProfileRegular $paths[1]
    if((Get-Item -LiteralPath $paths[0]).Length -gt 65536 -or (Get-Item -LiteralPath $paths[1]).Length -gt 1024){throw 'PROFILE_CHANGED'}
    $raw=[IO.File]::ReadAllText($paths[0]);[AbleProcessAction]::ValidateJson($raw);$p=[AbleProcessAction]::Parse($raw)
    Fields $p 'schemaVersion id version vmUuid displayName executable executableHash argv cwd account environmentRef supervisor verification'
    if($p.schemaVersion -cne '1.0' -or $p.id -cne $id -or $p.vmUuid -cne $vm -or $p.version -isnot [int] -or $p.version -lt 1 -or $p.verification -cne 'identity-and-running' -or $p.account -cne 'S-1-5-18'){throw 'PROFILE_CHANGED'}
    if($p.displayName -isnot [string] -or $p.displayName.Length -lt 1 -or $p.displayName.Length -gt 80 -or $p.argv.Count -gt 32){throw 'PROFILE_CHANGED'}
    foreach($arg in $p.argv){if($arg -isnot [string] -or $arg.Length -gt 1024 -or $arg -match '[\x00-\x1f]'){throw 'PROFILE_CHANGED'}}
    ProfileRegular $p.executable
    if((Get-FileHash -LiteralPath $p.executable).Hash.ToLowerInvariant() -cne $p.executableHash -or -not [IO.Path]::IsPathRooted($p.cwd) -or -not (Test-Path -LiteralPath $p.cwd -PathType Container)){throw 'PROFILE_CHANGED'}
    if($null -ne $p.environmentRef){ProfileRegular $p.environmentRef $true;if((Get-Item -LiteralPath $p.environmentRef).Length -gt 65536){throw 'PROFILE_CHANGED'}}
    [AbleProcessAction]::CheckPath($p.cwd,$true)
    Fields $p.supervisor 'manager name configurationHash'
    if($p.supervisor.manager -cne 'taskScheduler' -or $p.supervisor.name -cne $id){throw 'PROFILE_CHANGED'}
    $task=TaskInfo $id
    if($task.hash -cne $p.supervisor.configurationHash){throw 'PROFILE_CHANGED'}
    $rawBinding=[IO.File]::ReadAllText($paths[1]);[AbleProcessAction]::ValidateJson($rawBinding);$b=[AbleProcessAction]::Parse($rawBinding);Fields $b 'vmUuid bootId pid startTicks'
    if($b.vmUuid -cne $vm){throw 'PROFILE_CHANGED'}
    return @{definition=$p;binding=$b;hash=(Get-FileHash -LiteralPath $paths[0]).Hash.ToLowerInvariant();task=$task.task}
}
function ProfilePublic($entry) {
    $p=$entry.definition
    return @{id=$p.id;version=$p.version;definitionHash=$entry.hash;displayName=$p.displayName;executable=$p.executable;argumentCount=$p.argv.Count;cwd=$p.cwd;account=$p.account;environmentRef=$p.environmentRef;supervisor=$p.supervisor.manager;verification=$p.verification;identity=$entry.binding}
}
function ProfileList {
    $directory=Join-Path (Join-Path $env:ProgramData 'ABLESTACK-ProcessActions') 'profiles';$profiles=@()
    if(Test-Path -LiteralPath $directory) {
        [AbleProcessAction]::CheckPath($directory,$true)
        $files=@(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File)
        if($files.Count -gt 32){throw 'profile capacity'}
        foreach($file in $files) {
            try{$entry=ProfileLoad $file.BaseName $r.authority.vmUuid;$profiles+=,(ProfilePublic $entry)}catch{$profiles+=,@{id=$file.BaseName;available=$false}}
        }
    }
    return @{schemaVersion='1.1';kind='profiles';requestId=$r.requestId;authority=$r.authority;profiles=$profiles}
}
function ProfileCandidates($p) {
    Deadline
    $list=@(Get-CimInstance Win32_Process -OperationTimeoutSec 2)
    if($list.Count -gt 4096){throw 'profile process capacity'}
    $arguments=(@($p.argv | ForEach-Object {[AbleProcessAction]::QuoteArgument($_)}) -join ' ')
    $expected=[AbleProcessAction]::QuoteArgument($p.executable)+$(if($arguments){' '+$arguments}else{''})
    $matches=@()
    foreach($process in $list) {
        if($process.ExecutablePath -ine $p.executable){continue}
        $identity=[AbleProcessIdentity]::Read([uint32]$process.ProcessId)
        if(-not $identity -or $identity.Owner -cne $p.account -or $process.SessionId -ne 0){throw 'STALE_IDENTITY'}
        # Administrator provisioned task uses one canonical Windows argv quoting rule.
        if(-not [AbleProcessAction]::CommandLineMatches([string]$process.CommandLine,[string]$p.executable,[string[]]$p.argv)){continue}
        $matches+=,@{vmUuid=$r.authority.vmUuid;bootId=(Boot);pid=[long]$process.ProcessId;startTicks=$identity.Start}
    }
    return $matches
}
function ProfileProgress($value,$old,$new,$identity=$null) {$value.progress=@{oldProcess=$old;newProcess=$new;newIdentity=$identity}}
function ProfileComplete($record,$identity) {
    $value=$record.result;$value.state='SUCCEEDED';$value.effect='VERIFIED';$value.completedAt=Utc;$value.guestExitCode=0;$value.postcondition='PROFILE_RESTART_VERIFIED';$value.error=$null
    ProfileProgress $value 'EXITED' 'RUNNING' $identity;$record.stage='profile-complete';Persist
}
function ProfilePartial($record) {
    $value=$record.result;$value.state='PARTIAL';$value.effect='PARTIAL';$value.completedAt=Utc;$value.postcondition='OLD_EXITED_NEW_NOT_STARTED';$value.error=@{code='START_FAILED';message='Old process exited; new process did not start';retryMode='NONE'}
    ProfileProgress $value 'EXITED' 'NOT_RUNNING';$record.stage='profile-partial';Persist
}
function ProfileRestart($record,$target) {
    $entry=ProfileLoad $r.profile.id $r.authority.vmUuid;$p=$entry.definition;$b=$entry.binding
    if($p.version -ne $r.profile.version -or $entry.hash -cne $r.profile.definitionHash){throw 'PROFILE_CHANGED'}
    if($b.bootId -cne $r.identity.bootId -or $b.pid -ne $r.identity.pid -or $b.startTicks -cne $r.identity.startTicks){throw 'STALE_IDENTITY'}
    $candidates=@(ProfileCandidates $p)
    if($candidates.Count -ne 1 -or $candidates[0].pid -ne $r.identity.pid -or $candidates[0].startTicks -cne $r.identity.startTicks){throw 'STALE_IDENTITY'}
    if(@(Get-CimInstance Win32_Service -Filter ('ProcessId='+$r.identity.pid) -OperationTimeoutSec 2).Count -gt 0){throw 'PROTECTED_TARGET'}
    $record.stage='profile-stop-intent';Unknown $record.result;ProfileProgress $record.result 'RUNNING' 'NOT_ATTEMPTED';Persist
    $target.Kill();while(-not $target.Exited(50)){Deadline}
    $record.stage='profile-stopped';ProfileProgress $record.result 'EXITED' 'NOT_ATTEMPTED';Persist
    $entry=ProfileLoad $r.profile.id $r.authority.vmUuid
    if($entry.hash -cne $r.profile.definitionHash -or @(ProfileCandidates $p).Count -ne 0){ProfilePartial $record;return}
    $record.stage='profile-start-intent';ProfileProgress $record.result 'EXITED' 'UNKNOWN';Persist
    $record.oldTaskRun=[string]$entry.task.LastRunTime.ToUniversalTime().ToFileTimeUtc();$startElapsed=$watch.ElapsedMilliseconds;Persist
    try{$running=$entry.task.Run($null)}catch{throw 'RESULT_UNKNOWN'}
    $record.stage='profile-start-returned';Persist
    do {
        Deadline;Start-Sleep -Milliseconds 100;$next=@(ProfileCandidates $p)
        if($next.Count -gt 1){throw 'RESULT_UNKNOWN'}
        if($next.Count -eq 1) {
            Start-Sleep -Milliseconds 250;$stable=@(ProfileCandidates $p)
            if($stable.Count -eq 1 -and $stable[0].pid -eq $next[0].pid -and $stable[0].startTicks -ceq $next[0].startTicks) {
                $record.newIdentity=$next[0];Persist
                [AbleProcessAction]::Save((ProfilePaths $p.id)[1],(Json $next[0]));ProfileComplete $record $next[0];return
            }
        }
        $entry=ProfileLoad $r.profile.id $r.authority.vmUuid
        if(($watch.ElapsedMilliseconds-$startElapsed) -gt 1500 -and ([string]$entry.task.LastRunTime.ToUniversalTime().ToFileTimeUtc()) -cne $record.oldTaskRun -and $entry.task.State -eq 3 -and $entry.task.LastTaskResult -ne 267009 -and $next.Count -eq 0){ProfilePartial $record;return}
    }while($true)
}
function ProfileReconcile($record) {
    Unknown $record.result
    if($record.result.identity.bootId -cne (Boot)){Persist;return $record.result}
    if($record.stage -in @('profile-stop-intent','profile-stopped')) {
        $present=Get-CimInstance Win32_Process -Filter ('ProcessId='+$record.result.identity.pid) -OperationTimeoutSec 2
        $identity=[AbleProcessIdentity]::Read([uint32]$record.result.identity.pid)
        if(-not $present -or ($identity -and $identity.Start -cne $record.result.identity.startTicks)){ProfilePartial $record;return $record.result}
    }
    if($record.stage -eq 'profile-start-returned' -and -not $record.newIdentity) {
        try {
            $entry=ProfileLoad $record.result.profile.id $record.result.authority.vmUuid;$next=@(ProfileCandidates $entry.definition)
            if($entry.hash -ceq $record.result.profile.definitionHash -and $next.Count -eq 1 -and ($next[0].pid -ne $record.result.identity.pid -or $next[0].startTicks -cne $record.result.identity.startTicks)){$record.newIdentity=$next[0];Persist}
            elseif($entry.task.State -eq 3 -and $entry.task.LastTaskResult -ne 267009 -and $next.Count -eq 0){ProfilePartial $record;return $record.result}
        }catch{}
    }
    if($record.newIdentity) {
        try {
            $entry=ProfileLoad $record.result.profile.id $record.result.authority.vmUuid;$next=@(ProfileCandidates $entry.definition)
            $i=$record.newIdentity
            if($entry.hash -ceq $record.result.profile.definitionHash -and $next.Count -eq 1 -and $next[0].bootId -ceq $i.bootId -and $next[0].pid -eq $i.pid -and $next[0].startTicks -ceq $i.startTicks) {
                [AbleProcessAction]::Save((ProfilePaths $entry.definition.id)[1],(Json $i));ProfileComplete $record $i
            }
        }catch{}
    }
    Persist;return $record.result
}
