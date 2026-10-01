# Copyright 2026 ABLECLOUD. Apache-2.0.
param([Parameter(Mandatory=$true)][string]$Definition,[Parameter(Mandatory=$true)][uint32]$BindPid)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
Add-Type -Path (Join-Path $PSScriptRoot 'AbleProcessIdentity.dll')
Add-Type -Path (Join-Path $PSScriptRoot 'AbleProcessAction.dll')
function Json($v){ConvertTo-Json -InputObject $v -Depth 20 -Compress}
function Hash($v){$s=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($s.ComputeHash([Text.Encoding]::UTF8.GetBytes($v)))).Replace('-','').ToLowerInvariant()}finally{$s.Dispose()}}
function Uuid($v){if($v -isnot [string] -or $v -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'UUID'}}
function Fields($v,$n){if((($v.Keys | Sort-Object) -join ',') -cne (($n.Split(' ') | Sort-Object) -join ',')){throw 'fields'}}
function Boot{'windows:'+(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToFileTimeUtc()}
function Deadline{}
function Escape($v){[Security.SecurityElement]::Escape([string]$v)}
. (Join-Path $PSScriptRoot 'ProcessProfile.ps1')
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run as administrator'}
$raw=[IO.File]::ReadAllText($Definition);[AbleProcessAction]::ValidateJson($raw);$p=[AbleProcessAction]::Parse($raw)
Fields $p 'id version vmUuid displayName executable argv cwd account environmentRef verification';Uuid $p.id;Uuid $p.vmUuid
if($p.version -isnot [int] -or $p.version -lt 1 -or $p.account -cne 'S-1-5-18' -or $p.verification -cne 'identity-and-running'){throw 'Windows profiles require a noninteractive LocalSystem workload and administrator-owned environment references'}
if($p.displayName.Length -lt 1 -or $p.displayName.Length -gt 80 -or $p.argv.Count -gt 32 -or -not [IO.Path]::IsPathRooted($p.cwd) -or -not (Test-Path -LiteralPath $p.cwd -PathType Container)){throw 'profile fields'}
foreach($arg in $p.argv){if($arg -isnot [string] -or $arg.Length -gt 1024 -or $arg -match '[\x00-\x1f]'){throw 'argument'}}
ProfileRegular $p.executable
$guard=New-Object AbleProcessAction+Target($BindPid,([AbleProcessIdentity]::Read($BindPid).Start));$guard.Dispose()
$p.schemaVersion='1.0';$p.executableHash=(Get-FileHash -LiteralPath $p.executable).Hash.ToLowerInvariant()
$script:r=@{authority=@{vmUuid=$p.vmUuid}}
$candidates=@(ProfileCandidates $p)
if($candidates.Count -ne 1 -or $candidates[0].pid -ne $BindPid){throw 'Binding must match the executable, fixed arguments, LocalSystem account and session 0'}
$arguments=@($p.argv | ForEach-Object {[AbleProcessAction]::QuoteArgument($_)}) -join ' '
$launcher=Join-Path $PSScriptRoot 'Start-ProcessProfile.ps1';ProfileRegular $launcher
$xml=ProfileTaskDefinition $p $launcher
$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
try{$folder=$scheduler.GetFolder('\ABLESTACKProfiles')}catch{$folder=$scheduler.GetFolder('\').CreateFolder('ABLESTACKProfiles','D:P(A;;FA;;;SY)(A;;FA;;;BA)')}
$task=$folder.RegisterTask($p.id,$xml,6,'SYSTEM',$null,5,'D:P(A;;FA;;;SY)(A;;FA;;;BA)')
$p.supervisor=@{manager='taskScheduler';name=$p.id;configurationHash=(Hash ([string]$task.Xml))}
$base=Join-Path $env:ProgramData 'ABLESTACK-ProcessActions';[AbleProcessAction]::SecureDirectory($base);[AbleProcessAction]::SecureDirectory((Join-Path $base 'profiles'))
$paths=ProfilePaths $p.id;[AbleProcessAction]::Save($paths[0],(Json $p));[AbleProcessAction]::Save($paths[1],(Json $candidates[0]))
$null=ProfileLoad $p.id $p.vmUuid
Write-Output 'Profile registered; Cloud registration and approval are required'
