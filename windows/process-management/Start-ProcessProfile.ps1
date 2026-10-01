# Copyright 2026 ABLECLOUD. Apache-2.0.
param([Parameter(Mandatory=$true)][string]$ProfileId)
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
$paths=ProfilePaths $ProfileId;ProfileRegular $paths[0]
$raw=[IO.File]::ReadAllText($paths[0]);[AbleProcessAction]::ValidateJson($raw);$definition=[AbleProcessAction]::Parse($raw)
$entry=ProfileLoad $ProfileId $definition.vmUuid;$p=$entry.definition
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-18'){throw 'LocalSystem task required'}
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=$p.executable;$start.Arguments=@($p.argv | ForEach-Object {[AbleProcessAction]::QuoteArgument($_)}) -join ' '
$start.WorkingDirectory=$p.cwd;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
if($null -ne $p.environmentRef) {
    $environment=ProfileEnvironment $p.environmentRef
    foreach($name in $environment.Keys) {
        $start.EnvironmentVariables[$name]=$environment[$name]
    }
}
# The OS receives only the sealed administrator definition, never Cloud request argv.
$child=[Diagnostics.Process]::Start($start)
if(-not $child){throw 'profile start failed'}
$child.Dispose()
