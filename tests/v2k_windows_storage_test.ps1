# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
param([string]$HelperPath=(Join-Path $PSScriptRoot '..\lib\v2k\guest-config\windows-helper.ps1'))
$ErrorActionPreference='Stop'
# Only adapter functions are imported. Every storage/CIM command is replaced;
# any attempt to change ROOT or an unknown fixture is a test failure.
function Assert($condition,$message){if(!$condition){throw $message}}
function Save-Json($name,$value){$script:saved+=@(($value|ConvertTo-Json -Depth 16 -Compress))}
function Get-Disk {param([int]$Number=-1)
 if($Number -eq -1){return @($script:rootDisk,$script:dataDisk)}
 if($Number -eq 0){return $script:rootDisk}
 if($Number -eq 99){return $script:dataDisk}
 throw 'Unknown fixture disk'
}
function Get-Partition {param([int]$DiskNumber=-1,[string]$DriveLetter)
 if($PSBoundParameters.ContainsKey('DriveLetter')){if($script:part.DriveLetter -eq $DriveLetter){return $script:part};return}
 if($DiskNumber -eq 99){return $script:part}
 if($DiskNumber -eq 0){return}
 throw 'Unknown fixture partition'
}
function Set-Disk {param([Parameter(ValueFromPipeline=$true)]$InputObject,[Nullable[bool]]$IsReadOnly,[Nullable[bool]]$IsOffline)
 process{
  Assert ($InputObject.Number -eq 99) 'ROOT/foreign disk mutation'
  if($PSBoundParameters.ContainsKey('IsReadOnly')){$script:changes+=@('readonly:'+([string]$IsReadOnly));$InputObject.IsReadOnly=[bool]$IsReadOnly}
  if($PSBoundParameters.ContainsKey('IsOffline')){$script:changes+=@('offline:'+([string]$IsOffline));$InputObject.IsOffline=[bool]$IsOffline}
 }
}
function Set-Partition {param([Parameter(ValueFromPipeline=$true)]$InputObject,[string]$NewDriveLetter)
 process{
  Assert ($InputObject.DiskNumber -eq 99) 'ROOT/foreign partition mutation'
  if($script:failLetter){throw 'Injected drive letter failure'}
  $script:changes+=@('letter:'+$NewDriveLetter);$InputObject.DriveLetter=$NewDriveLetter
 }
}
function Remove-PartitionAccessPath {param([Parameter(ValueFromPipeline=$true)]$InputObject,[string]$AccessPath)
 process{Assert ($InputObject.DiskNumber -eq 99) 'ROOT/foreign partition mutation';$InputObject.DriveLetter=''}
}
function Get-CimInstance {param([string]$ClassName)
 switch($ClassName){
  'Win32_Volume' {return @($script:cdVolume,[pscustomobject]@{DeviceID='root-volume';DriveLetter='C:';DriveType=3},[pscustomobject]@{DeviceID='data-volume';DriveLetter=($script:part.DriveLetter+':');DriveType=3})}
  'Win32_CDROMDrive' {return @([pscustomobject]@{Drive=$script:cdVolume.DriveLetter;MediaLoaded=$script:mediaLoaded})}
  default {throw 'Unmocked CIM command'}
 }
}
function Set-CimInstance {param([Parameter(ValueFromPipeline=$true)]$InputObject,[hashtable]$Property)
 process{Assert ($InputObject.DeviceID -eq 'extra-cdrom') 'Protected media mutation';$InputObject.DriveLetter=$Property.DriveLetter;$script:changes+=@('cdrom')}
}
function Update-HostStorageCache {}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($HelperPath,[ref]$tokens,[ref]$errors)
Assert (!$errors.Count) 'Helper parse failure'
$names=@('Identity','Get-ExpectedDisks','Change-State','Apply-Data','Recover-OwnedChanges')
$functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($function in $functions){if($function.Name -in $names){. ([scriptblock]::Create($function.Extent.Text))}}
function Reset-Fixture {
 $script:rootDisk=[pscustomobject]@{Number=0;Guid='{00000000-0000-0000-0000-000000000001}';PartitionStyle='GPT';Size=68719476736L;SerialNumber='target-root';IsBoot=$true;IsClustered=$false;IsReadOnly=$false;IsOffline=$false}
 $script:dataDisk=[pscustomobject]@{Number=99;Guid='{00000000-0000-0000-0000-000000000002}';PartitionStyle='GPT';Size=8589934592L;SerialNumber='target-data';IsBoot=$false;IsClustered=$false;IsReadOnly=$true;IsOffline=$true}
 $script:part=[pscustomobject]@{DiskNumber=99;Guid='{00000000-0000-0000-0000-000000000003}';Offset=16777216L;Size=8572108800L;DriveLetter='F'}
 $script:cdVolume=[pscustomobject]@{DeviceID='extra-cdrom';DriveLetter='E:';DriveType=5}
 $script:mediaLoaded=$false;$script:failLetter=$false;$script:changes=@();$script:saved=@();$script:boot='fixture-boot'
 $script:journal=[pscustomobject]@{steps=@();verified=$false}
 $script:want=[pscustomobject]@{source_disk_id='scsi0:1';identity='gpt:00000000-0000-0000-0000-000000000002';size_bytes=8589934592L;online=$true;read_only=$false;partitions=@([pscustomobject]@{guid='00000000-0000-0000-0000-000000000003';offset=16777216L;size_bytes=8572108800L;access_paths=@('E:'+([char]92))})}
 $script:plan=[pscustomobject]@{windows=[pscustomobject]@{disks=@($script:want);source_cdrom_letters=@('D:')}}
 $script:binding=[pscustomobject]@{media_all_empty=$true;disks=@([pscustomobject]@{source_disk_id='scsi0:1';role='data';serial='target-data'})}
}
Reset-Fixture
$items=@(Get-ExpectedDisks $binding);Apply-Data $items $binding
Assert (!$dataDisk.IsOffline -and !$dataDisk.IsReadOnly -and $part.DriveLetter -eq 'E') 'RW/online/E restoration failed'
Assert ($null -eq $cdVolume.DriveLetter) 'Empty CD-ROM not released'
Assert ($journal.steps.Count -eq 4 -and @($journal.steps|Where-Object {$_.state -ne 'APPLIED'}).Count -eq 0) 'Write-ahead journal incomplete'
Write-Output 'PASS: stable identity after disk reorder, online/RW and E'
Reset-Fixture;$want.online=$false;$want.read_only=$true;$dataDisk.IsOffline=$false;$dataDisk.IsReadOnly=$false
Apply-Data @(Get-ExpectedDisks $binding) $binding
Assert ($dataDisk.IsOffline -and $dataDisk.IsReadOnly -and $cdVolume.DriveLetter -eq 'E:') 'Intentional offline/read-only policy changed'
Write-Output 'PASS: intentional offline/read-only preserved'
Reset-Fixture;$mediaLoaded=$true;$binding.media_all_empty=$false
try{Apply-Data @(Get-ExpectedDisks $binding) $binding;throw 'Expected conflict'}catch{Assert ($_.Exception.Message -eq 'ACCESS_PATH_CONFLICT') 'Wrong conflict reason'}
Assert ($changes.Count -eq 0) 'Conflict allowed a mutation'
Write-Output 'PASS: loaded media conflict before mutation'
Reset-Fixture;$failLetter=$true;$items=@(Get-ExpectedDisks $binding)
try{Apply-Data $items $binding}catch{Assert ($_.Exception.Message -eq 'Injected drive letter failure') 'Wrong injected failure'}
$failLetter=$false;Recover-OwnedChanges $items
Assert ($dataDisk.IsOffline -and $dataDisk.IsReadOnly -and $part.DriveLetter -eq 'F' -and $cdVolume.DriveLetter -eq 'E:') 'Owned rollback failed'
Write-Output 'PASS: partial failure compensates only owned values'
Reset-Fixture;$items=@(Get-ExpectedDisks $binding);Apply-Data $items $binding;$part.DriveLetter='Z'
try{Recover-OwnedChanges $items;throw 'Expected recovery conflict'}catch{Assert ($_.Exception.Message -eq 'GUEST_RECOVERY_CONFLICT') 'Foreign change not detected'}
Assert ($part.DriveLetter -eq 'Z') 'Recovery overwrote external change'
Write-Output 'PASS: external drive change is not overwritten'
Reset-Fixture;$want.read_only=$true
Apply-Data @(Get-ExpectedDisks $binding) $binding
Assert ($dataDisk.IsReadOnly -and !$dataDisk.IsOffline -and $changes -notcontains 'readonly:False') 'Read-only source was temporarily made writable'
Write-Output 'PASS: no temporary write enable for read-only source'
