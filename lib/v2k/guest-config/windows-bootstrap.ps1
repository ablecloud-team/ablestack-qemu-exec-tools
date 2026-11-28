# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
param([switch]$PrepareOnly)
$ErrorActionPreference='Stop'
$root='C:\ProgramData\ABLECLOUD\V2K\GuestConfig'
$plan=Get-Content "$root\plan.json" -Raw|ConvertFrom-Json
function Protect-OwnedPath([string]$path,[bool]$directory){
 if($directory){
  $acl=New-Object Security.AccessControl.DirectorySecurity
  $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
  [IO.Directory]::SetAccessControl($path,$acl)
 }else{
  $acl=New-Object Security.AccessControl.FileSecurity
  $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)')
  [IO.File]::SetAccessControl($path,$acl)
 }
}
# Prepare the fixed channel files before the MSI starts QGA. CREATE_ALWAYS
# subsequently preserves these explicit ACLs rather than relying on inheritance
# from an NTFS directory originally created by an offline Linux appliance.
Protect-OwnedPath $root $true
foreach($item in Get-ChildItem -LiteralPath $root -Recurse -Force){
 if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'GUEST_CONFIG_REPARSE_POINT'}
 Protect-OwnedPath $item.FullName $item.PSIsContainer
}
foreach($suffix in @('json','commit')){
 $path=Join-Path $root ('binding-'+$plan.operation_id+'.'+$suffix)
 if(!(Test-Path -LiteralPath $path)){[IO.File]::WriteAllText($path,'',(New-Object Text.UTF8Encoding($false)))}
 Protect-OwnedPath $path $false
}
if($PrepareOnly){exit 0}
$name='ABLECLOUD-V2K-GuestConfig-'+$plan.operation_id
$action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "'+$root+'\helper.ps1"')
$startup=New-ScheduledTaskTrigger -AtStartup
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
if(!(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)){Register-ScheduledTask -TaskName $name -Action $action -Trigger $startup -Principal $principal -Settings $settings|Out-Null}
# The qualified firstboot runner reboots once; the startup task runs afterwards.
