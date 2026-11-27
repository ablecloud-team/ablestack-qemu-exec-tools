# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
param([string]$OutputPath,[ValidateSet('file','stdout')][string]$OutputMode='file')
$ErrorActionPreference='Stop'
trap {
 $code=if($_.Exception.Message -match '^[A-Z0-9_]{1,96}$'){$_.Exception.Message}else{'SOURCE_GUEST_PROBE_FAILED'}
 $failure=@{source_probe_error=$code;source_probe_line=$_.InvocationInfo.ScriptLineNumber}|ConvertTo-Json -Compress
 if($OutputMode -eq 'stdout'){$failure}elseif($OutputPath){$failure|Out-File -LiteralPath $OutputPath -Encoding UTF8}
 exit 44
}
# @WINDOWS_NETWORK_READ@
$os=Get-CimInstance Win32_OperatingSystem
$disks=@()
foreach($disk in Get-Disk){
 $parts=@()
 foreach($p in Get-Partition -DiskNumber $disk.Number){
  if(@($p.AccessPaths|Where-Object {$_ -match '^[A-Z]:\\.+'}).Count){throw 'ACCESS_PATH_UNSUPPORTED'}
  $paths=@($p.AccessPaths|Where-Object {$_ -match '^[A-Z]:\\$'})
  $parts+=@{guid=([string]$p.Guid).Trim('{}').ToLower();offset=[long]$p.Offset;size_bytes=[long]$p.Size;type=[string]$p.Type;access_paths=$paths}
 }
 $identity=if($disk.PartitionStyle -eq 'GPT'){'gpt:'+([string]$disk.Guid).Trim('{}').ToLower()}elseif($disk.PartitionStyle -eq 'MBR'){'mbr:'+('{0:x8}' -f $disk.Signature)}else{'unsupported'}
 $disks+=@{number=$disk.Number;identity=$identity;size_bytes=[long]$disk.Size;partition_style=[string]$disk.PartitionStyle;is_boot=[bool]$disk.IsBoot;is_clustered=[bool]$disk.IsClustered;online=(!$disk.IsOffline);read_only=[bool]$disk.IsReadOnly;partitions=$parts;source_serial=([string]$disk.SerialNumber).Trim()}
}
$r=@{os='windows';build=[string]$os.BuildNumber;capture_id=[guid]::NewGuid().ToString();boot_id=$os.LastBootUpTime.ToUniversalTime().ToString('o');san_policy=(Get-StorageSetting).NewDiskPolicy.ToString();disks=$disks;cdrom_letters=@(Get-CimInstance Win32_CDROMDrive|ForEach-Object {$_.Drive});reserved_letters=@(Get-CimInstance Win32_LogicalDisk|ForEach-Object {$_.DeviceID})}
$r.network=Get-V2KWindowsNetwork
$r.source_vm_uuid=(Get-CimInstance Win32_ComputerSystemProduct).UUID.ToLower()
if($OutputMode -eq 'stdout'){$r|ConvertTo-Json -Depth 12 -Compress}
else{if(!$OutputPath){throw 'SOURCE_OUTPUT_REQUIRED'};$r|ConvertTo-Json -Depth 12 -Compress|Out-File -LiteralPath $OutputPath -Encoding UTF8}
