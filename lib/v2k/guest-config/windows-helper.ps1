# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
param([int]$TimeoutSeconds=600)
$ErrorActionPreference='Stop'
$root='C:\ProgramData\ABLECLOUD\V2K\GuestConfig'
trap {
 try {
  $message=$_.Exception.GetType().Name+': '+$_.Exception.Message
  [IO.File]::WriteAllText($root+'\last-error.txt',$message.Substring(0,[Math]::Min(2048,$message.Length)),(New-Object Text.UTF8Encoding($false)))
 }catch{}
 exit 1
}

$plan=Get-Content -LiteralPath "$root\plan.json" -Raw|ConvertFrom-Json
if((Get-FileHash -Algorithm SHA256 $PSCommandPath).Hash.ToLower() -ne $plan.helper_sha256){throw 'GUEST_HELPER_HASH_MISMATCH'}
if($plan.version -eq 2){
 foreach($module in @(@{name='windows-network-read.ps1';hash=$plan.network_reader_sha256},@{name='windows-network.ps1';hash=$plan.network_helper_sha256})){
  $path=Join-Path $root $module.name
  if((Get-FileHash -Algorithm SHA256 $path).Hash.ToLower() -ne $module.hash){throw 'GUEST_NETWORK_HELPER_HASH_MISMATCH'}
  . $path
 }
}
$watch=[Diagnostics.Stopwatch]::StartNew()
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
$journalPath="$root\journal.json"
$journal=if(Test-Path $journalPath){Get-Content $journalPath -Raw|ConvertFrom-Json}else{[pscustomobject]@{version=1;operation_id=$plan.operation_id;plan_hash=$plan.hash;verified=$false;failed=$false;recovery_attempted=$false;steps=@()}}
if($journal.operation_id -ne $plan.operation_id -or $journal.plan_hash -ne $plan.hash){throw 'GUEST_JOURNAL_MISMATCH'}
function Save-Json($name,$value){
 $path=Join-Path $root $name;$temp=$path+'.tmp'
 [IO.File]::WriteAllText($temp,($value|ConvertTo-Json -Depth 18 -Compress),(New-Object Text.UTF8Encoding($false)))
 $acl=New-Object Security.AccessControl.FileSecurity
 $acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)')
 [IO.File]::SetAccessControl($temp,$acl)
 $publishWatch=[Diagnostics.Stopwatch]::StartNew()
 while($true){
  try{
   if(Test-Path $path){[IO.File]::Replace($temp,$path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$path)}
   break
  }catch [IO.IOException]{
   if(($_.Exception.HResult -band 65535) -notin @(32,33) -or $publishWatch.Elapsed.TotalSeconds -ge 15){throw}
   Start-Sleep -Milliseconds 50
  }
 }
}
function Identity($disk){
 if($disk.PartitionStyle -eq 'GPT'){return 'gpt:'+([string]$disk.Guid).Trim('{}').ToLower()}
 if($disk.PartitionStyle -eq 'MBR'){return 'mbr:'+('{0:x8}' -f $disk.Signature)}
 return 'unsupported'
}
function Get-Binding{
 $path=Join-Path $root ('binding-'+$plan.operation_id+'.json');$commit=[IO.Path]::ChangeExtension($path,'commit')
 if(!(Test-Path $path) -or !(Test-Path $commit)){return $null}
 $meta=Get-Content $commit -Raw|ConvertFrom-Json;$length=(Get-Item $path).Length;$hash=(Get-FileHash -Algorithm SHA256 $path).Hash.ToLower()
 if($length -gt 65536 -or $length -ne $meta.bytes -or $hash -ne $meta.sha256){return $null}
 $b=Get-Content $path -Raw|ConvertFrom-Json
 $script:attemptBinding=$b;$script:attemptHash=$hash
 if($b.operation_id -ne $plan.operation_id -or $b.plan_hash -ne $plan.hash -or $b.source_vm_uuid -ne $plan.source_vm_uuid){throw 'GUEST_BINDING_MISMATCH'}
 return @{value=$b;sha256=$hash}
}
function Assert-BindingIdentity($b){
 $vm=(Get-CimInstance Win32_ComputerSystemProduct).UUID.ToLower()
 if($vm -ne $b.vm_uuid.ToLower()){throw 'GUEST_VM_IDENTITY_MISMATCH'}
 $bootDisks=@(Get-Disk|Where-Object {$_.IsBoot})
 if($bootDisks.Count -ne 1 -or (Identity $bootDisks[0]) -ne $plan.root_identity){throw 'ROOT_IDENTITY_MISMATCH'}
}
function Get-ExpectedDisks($binding){
 $all=@(Get-Disk);$result=@()
 foreach($want in $plan.windows.disks){
  $hostDisk=@($binding.disks|Where-Object {$_.source_disk_id -eq $want.source_disk_id -and $_.role -eq 'data'})
  if($hostDisk.Count -ne 1){throw 'DATA_BINDING_MISMATCH'}
  $matches=@($all|Where-Object {(Identity $_) -eq $want.identity -and $_.Size -eq $want.size_bytes -and ([string]$_.SerialNumber).Trim() -eq $hostDisk[0].serial})
  if($matches.Count -ne 1 -or $matches[0].IsBoot -or $matches[0].IsClustered){throw 'DATA_IDENTITY_MISMATCH'}
  $disk=$matches[0];$parts=@(Get-Partition -DiskNumber $disk.Number)
  foreach($p in $want.partitions){
   $found=@($parts|Where-Object {((([string]$_.Guid).Trim('{}').ToLower() -eq $p.guid) -and $p.guid) -or ((!$p.guid) -and $_.Offset -eq $p.offset -and $_.Size -eq $p.size_bytes)})
   if($found.Count -ne 1){throw 'DATA_PARTITION_IDENTITY_MISMATCH'}
  }
  $result+=@{want=$want;disk=$disk;binding=$hostDisk[0]}
 }
 return $result
}
function Change-State($type,$id,$before,$after,[scriptblock]$apply){
 # Write ahead. Interrupted mutations are never blindly replayed on another boot.
 $step=[pscustomobject]@{type=$type;identity=$id;before=$before;after=$after;state='PREPARED';boot_id=$boot;timestamp=[DateTime]::UtcNow.ToString('o')}
 $journal.steps+=@($step);Save-Json 'journal.json' $journal
 & $apply
 $step.state='APPLIED';Save-Json 'journal.json' $journal
}
if(!$journal.PSObject.Properties['recovery_attempted']){$journal|Add-Member -NotePropertyName recovery_attempted -NotePropertyValue $false}
if(!$journal.PSObject.Properties['failed']){$journal|Add-Member -NotePropertyName failed -NotePropertyValue $false}
if(!$journal.PSObject.Properties['applied']){$journal|Add-Member -NotePropertyName applied -NotePropertyValue $false}
$controlledResume=(!$journal.verified -and !$journal.failed -and $journal.PSObject.Properties['network_reboot'] -and $journal.network_reboot.awaiting -and $journal.network_reboot.count -eq 1 -and $journal.network_reboot.boot_id -ne $boot)
if(!$journal.verified -and @($journal.steps).Count -gt 0 -and !$controlledResume){$journal.failed=$true;Save-Json 'journal.json' $journal}

function Recover-OwnedChanges($items){
 for($index=$journal.steps.Count-1;$index -ge 0;$index--){
  $step=$journal.steps[$index]
  if($step.state -notin @('APPLIED','PREPARED')){continue}
  if($step.type -in @('readonly','offline')){
   $item=@($items|Where-Object {$_.want.identity -eq $step.identity})
   if($item.Count -ne 1){throw 'GUEST_RECOVERY_CONFLICT'}
   $disk=Get-Disk -Number $item[0].disk.Number
   $actual=if($step.type -eq 'readonly'){$disk.IsReadOnly}else{$disk.IsOffline}
   if($actual -eq $step.before){$step.state='NOT_APPLIED'}
   elseif($actual -ne $step.after){throw 'GUEST_RECOVERY_CONFLICT'}
   elseif($step.type -eq 'readonly'){$disk|Set-Disk -IsReadOnly $step.before;$step.state='ROLLED_BACK'}
   else{$disk|Set-Disk -IsOffline $step.before;$step.state='ROLLED_BACK'}
  }elseif($step.type -eq 'partition-letter'){
   $matches=@()
   foreach($item in $items){foreach($part in $item.want.partitions){
    if(($item.want.identity+':'+$part.guid+':'+$part.offset) -eq $step.identity){
     $matches+=@(Get-Partition -DiskNumber $item.disk.Number|Where-Object {$_.Offset -eq $part.offset -and $_.Size -eq $part.size_bytes -and ((!$part.guid) -or ([string]$_.Guid).Trim('{}').ToLower() -eq $part.guid)})
    }
   }}
   if($matches.Count -ne 1){throw 'GUEST_RECOVERY_CONFLICT'}
   $part=$matches[0];$actual=[string]$part.DriveLetter
   if($actual -eq $step.before){$step.state='NOT_APPLIED'}
   elseif($actual -ne $step.after){throw 'GUEST_RECOVERY_CONFLICT'}
   elseif(!$step.before){$part|Remove-PartitionAccessPath -AccessPath ($step.after+':'+[char]92);$step.state='ROLLED_BACK'}
   else{
    if(@(Get-Partition -DriveLetter $step.before -ErrorAction SilentlyContinue).Count){throw 'GUEST_RECOVERY_CONFLICT'}
    $part|Set-Partition -NewDriveLetter $step.before;$step.state='ROLLED_BACK'
   }
  }elseif($step.type -eq 'cdrom-letter'){
   $volume=@(Get-CimInstance Win32_Volume|Where-Object {$_.DeviceID -eq $step.identity -and $_.DriveType -eq 5})
   if($volume.Count -ne 1){throw 'GUEST_RECOVERY_CONFLICT'}
   if($volume[0].DriveLetter -eq $step.before){$step.state='NOT_APPLIED'}
   elseif($volume[0].DriveLetter -ne $step.after -or @(Get-CimInstance Win32_CDROMDrive|Where-Object {$_.MediaLoaded}).Count){throw 'GUEST_RECOVERY_CONFLICT'}
   else{
    if(@(Get-CimInstance Win32_Volume|Where-Object {$_.DriveLetter -eq $step.before}).Count){throw 'GUEST_RECOVERY_CONFLICT'}
    $volume[0]|Set-CimInstance -Property @{DriveLetter=$step.before}|Out-Null;$step.state='ROLLED_BACK'
   }
   }elseif($step.type -in @('network-ipv4','network-ghost')){
    Recover-V2KNetworkStep $step $script:networkItems
   }else{throw 'GUEST_RECOVERY_CONFLICT'}
  Save-Json 'journal.json' $journal
 }
}
function Apply-Data($items,$binding){
 # Validate every requested access path before changing any disk.
 foreach($item in $items){foreach($part in $item.want.partitions){foreach($path in $part.access_paths){
  $letter=$path.Substring(0,2);$volume=@(Get-CimInstance Win32_Volume|Where-Object {$_.DriveLetter -eq $letter})
  if(!$volume){continue}
  if($volume.Count -ne 1){throw 'ACCESS_PATH_CONFLICT'}
  if($volume[0].DriveType -eq 5){
   $cd=@(Get-CimInstance Win32_CDROMDrive|Where-Object {$_.Drive -eq $letter})
   if(!$binding.media_all_empty -or $cd.Count -ne 1 -or $cd[0].MediaLoaded -or $plan.windows.source_cdrom_letters -contains $letter){throw 'ACCESS_PATH_CONFLICT'}
  }else{
   $owned=@(Get-Partition -DiskNumber $item.disk.Number|Where-Object {($_.DriveLetter -eq $letter[0]) -and ((($part.guid) -and ([string]$_.Guid).Trim('{}').ToLower() -eq $part.guid) -or ((!$part.guid) -and $_.Offset -eq $part.offset -and $_.Size -eq $part.size_bytes))})
   if($owned.Count -ne 1){throw 'ACCESS_PATH_CONFLICT'}
  }
 }}}
 foreach($item in $items){
  $want=$item.want;$disk=Get-Disk -Number $item.disk.Number
  if(!$want.online){
   if(!$disk.IsOffline){Change-State 'offline' $want.identity $false $true { $disk|Set-Disk -IsOffline $true }}
   if($disk.IsReadOnly -ne $want.read_only){Change-State 'readonly' $want.identity $disk.IsReadOnly $want.read_only { $disk|Set-Disk -IsReadOnly $want.read_only }}
   continue
  }
  if(!$want.read_only -and $disk.IsReadOnly){Change-State 'readonly' $want.identity $true $false { $disk|Set-Disk -IsReadOnly $false }}
  if($want.read_only -and !$disk.IsReadOnly){Change-State 'readonly' $want.identity $false $true { $disk|Set-Disk -IsReadOnly $true }}
  if($disk.IsOffline){Change-State 'offline' $want.identity $true $false { $disk|Set-Disk -IsOffline $false }}
  Update-HostStorageCache
  foreach($part in $want.partitions){foreach($path in $part.access_paths){
   $letter=$path.Substring(0,2);$volume=@(Get-CimInstance Win32_Volume|Where-Object {$_.DriveLetter -eq $letter})
   if($volume -and $volume[0].DriveType -eq 5){Change-State 'cdrom-letter' $volume[0].DeviceID $letter $null { $volume[0]|Set-CimInstance -Property @{DriveLetter=$null} }}
   $p=@(Get-Partition -DiskNumber $disk.Number|Where-Object {((([string]$_.Guid).Trim('{}').ToLower() -eq $part.guid) -and $part.guid) -or ((!$part.guid) -and $_.Offset -eq $part.offset -and $_.Size -eq $part.size_bytes)})[0]
   if($p.DriveLetter -ne $letter[0]){$before=[string]$p.DriveLetter;Change-State 'partition-letter' ($want.identity+':'+$part.guid+':'+$part.offset) $before ([string]$letter[0]) { $p|Set-Partition -NewDriveLetter $letter[0] }}
  }}
  $disk=Get-Disk -Number $disk.Number
  if($disk.IsReadOnly -ne $want.read_only){Change-State 'readonly' $want.identity $disk.IsReadOnly $want.read_only { $disk|Set-Disk -IsReadOnly $want.read_only }}
 }
}
function Observe-Data($items){
 $out=@()
 foreach($item in $items){
  $d=Get-Disk -Number $item.disk.Number;$w=$item.want
  if($d.IsOffline -eq $w.online -or $d.IsReadOnly -ne $w.read_only){throw 'DATA_STATE_MISMATCH'}
  $paths=@()
  if($w.online){foreach($p in $w.partitions){foreach($path in $p.access_paths){
   $part=@(Get-Partition -DiskNumber $d.Number|Where-Object {((([string]$_.Guid).Trim('{}').ToLower() -eq $p.guid) -and $p.guid) -or ((!$p.guid) -and $_.Offset -eq $p.offset -and $_.Size -eq $p.size_bytes)})
   if($part.Count -ne 1 -or $part[0].AccessPaths -notcontains $path -or !(Test-Path -LiteralPath $path)){throw 'DATA_ACCESS_PATH_MISMATCH'}
   $paths+=$path
  }}}
  $out+=@{source_disk_id=$w.source_disk_id;identity=$w.identity;serial=([string]$d.SerialNumber).Trim();online=(!$d.IsOffline);read_only=[bool]$d.IsReadOnly;access_paths=$paths;status='VERIFIED'}
 }
 return $out
}
$last=''
while($true){
 $binding=$null;$items=@();$script:attemptBinding=$null
 try{
  $envelope=Get-Binding
  if(!$envelope){Start-Sleep -Seconds 2;continue}
  $binding=$envelope.value
  if($last -eq $envelope.sha256){Start-Sleep -Seconds 2;continue}
  Assert-BindingIdentity $binding
   if($controlledResume){
    if($binding.vm_uuid -ne $journal.network_reboot.vm_uuid){throw 'GUEST_REBOOT_IDENTITY_MISMATCH'}
    if($envelope.sha256 -eq $journal.network_reboot.binding_sha256){
     if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'GUEST_CONFIG_TIMEOUT'}
     Start-Sleep -Seconds 2;continue
    }
    $journal.network_reboot.awaiting=$false;$controlledResume=$false;Save-Json 'journal.json' $journal
   }
  if(!$journal.verified -and $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'GUEST_CONFIG_TIMEOUT'}
  $policy=(Get-StorageSetting).NewDiskPolicy.ToString()
  if($policy -ne $plan.windows.san_policy){throw 'GLOBAL_SAN_POLICY_CHANGED'}
  $items=@(Get-ExpectedDisks $binding)
  if($journal.failed){throw 'GUEST_JOURNAL_RECOVERY_REQUIRED'}
   $script:networkItems=@()
   if($plan.version -eq 2){$script:networkItems=@(Get-V2KExpectedNetwork $binding)}
   if(!$journal.verified -and !$journal.applied){
    Apply-Data $items $binding
    $script:networkRebootRequested=$false
    if($plan.version -eq 2){Apply-V2KNetwork $script:networkItems}
    if($script:networkRebootRequested){
     if($journal.PSObject.Properties['network_reboot']){throw 'WINDOWS_NETWORK_GHOST_RECOVERY_REQUIRED'}
     $journal|Add-Member -NotePropertyName network_reboot -NotePropertyValue ([pscustomobject]@{count=1;awaiting=$true;boot_id=$boot;vm_uuid=$binding.vm_uuid;binding_sha256=$envelope.sha256;reason='owned-network-ghost'})
     Save-Json 'journal.json' $journal
     Save-Json 'report.json' @{version=$plan.version;operation_id=$plan.operation_id;plan_hash=$plan.hash;vm_uuid=$binding.vm_uuid;binding_sha256=$envelope.sha256;boot_scope=$binding.boot_scope;boot_id=$boot;root_identity=$plan.root_identity;helper_sha256=$plan.helper_sha256;status='PENDING';reason='WINDOWS_NETWORK_REBOOT_REQUIRED'}
     Restart-Computer -Force
     exit 0
    }
    $journal.applied=$true;Save-Json 'journal.json' $journal
   }
  $observed=@(Observe-Data $items)
   $network=@{status='NOT_APPLICABLE'}
   if($plan.version -eq 2){$network=Observe-V2KNetwork $script:networkItems}
  if((Get-StorageSetting).NewDiskPolicy.ToString() -ne $policy){throw 'GLOBAL_SAN_POLICY_CHANGED'}
  $journal.verified=$true;Save-Json 'journal.json' $journal
   Save-Json 'report.json' @{version=$plan.version;operation_id=$plan.operation_id;plan_hash=$plan.hash;vm_uuid=$binding.vm_uuid;binding_sha256=$envelope.sha256;boot_scope=$binding.boot_scope;boot_id=$boot;root_identity=$plan.root_identity;helper_sha256=$plan.helper_sha256;network_reader_sha256=$plan.network_reader_sha256;network_helper_sha256=$plan.network_helper_sha256;status='VERIFIED';network=$network;windows=@{status='VERIFIED';san_policy=$policy;disks=$observed};mutations=$journal.steps}
  $last=$envelope.sha256
 }catch{
  if(!$binding -and $script:attemptBinding){$binding=$script:attemptBinding;$envelope=@{sha256=$script:attemptHash}}
   if(!$journal.verified -and $_.Exception.Message -in @('WINDOWS_NETWORK_LINK_PENDING','WINDOWS_NETWORK_ADDRESS_PENDING','WINDOWS_NETWORK_DNS_PENDING') -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){
    if($binding){Save-Json 'report.json' @{version=$plan.version;operation_id=$plan.operation_id;plan_hash=$plan.hash;vm_uuid=$binding.vm_uuid;binding_sha256=$envelope.sha256;boot_scope=$binding.boot_scope;boot_id=$boot;root_identity=$plan.root_identity;status='PENDING';reason=$_.Exception.Message}}
    Start-Sleep -Seconds 2;continue
   }
  if(!$journal.verified -and @($journal.steps).Count -gt 0){
   $journal.failed=$true;Save-Json 'journal.json' $journal
   if($items.Count -gt 0 -and !$journal.recovery_attempted){
    $journal.recovery_attempted=$true;Save-Json 'journal.json' $journal
    try{Recover-OwnedChanges $items}catch{Save-Json 'journal.json' $journal}
   }
  }
   if($binding){Save-Json 'report.json' @{version=$plan.version;operation_id=$plan.operation_id;plan_hash=$plan.hash;vm_uuid=$binding.vm_uuid;binding_sha256=$envelope.sha256;boot_scope=$binding.boot_scope;boot_id=$boot;root_identity=$plan.root_identity;status=($(if($journal.verified){'DRIFT'}else{'FAILED'}));reason=$_.Exception.Message}}
  Start-Sleep -Seconds 2
 }
}
