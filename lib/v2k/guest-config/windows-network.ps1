# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# Loaded only after its frozen digest and the VM/ROOT binding have been checked.
function Test-V2KNetworkIntent($actual,$want){
 if([bool]$actual.ipv4.dhcp -ne [bool]$want.ipv4.dhcp){return $false}
 $left=@($actual.ipv4.addresses|ForEach-Object {$_.address+'/'+$_.prefix_length+'/'+$_.skip_as_source}|Sort-Object)
 $right=@($want.ipv4.addresses|ForEach-Object {$_.address+'/'+$_.prefix_length+'/'+$_.skip_as_source}|Sort-Object)
 if(($left -join ',') -ne ($right -join ',')){return $false}
 $left=@($actual.default_routes|ForEach-Object {$_.next_hop+'/'+$_.route_metric+'/'+$_.persistent}|Sort-Object)
 $right=@($want.default_routes|ForEach-Object {$_.next_hop+'/'+$_.route_metric+'/'+$_.persistent}|Sort-Object)
 if(($left -join ',') -ne ($right -join ',')){return $false}
 if([bool]$actual.interface_metric.automatic -ne [bool]$want.interface_metric.automatic){return $false}
 if(!$want.interface_metric.automatic -and $actual.interface_metric.value -ne $want.interface_metric.value){return $false}
 return ($actual.dns.mode -eq $want.dns.mode -and (@($actual.dns.servers) -join ',') -eq (@($want.dns.servers) -join ','))
}
function Get-V2KTargetNic($want,$binding){
 $bound=@($binding.nics|Where-Object {$_.mac -eq $want.target_mac -and $_.network_uuid -eq $want.target_network_uuid})
 if($bound.Count -ne 1 -or !$bound[0].id){throw 'NIC_BINDING_MISMATCH'}
 $nics=@(Get-NetAdapter -Physical|Where-Object {(ConvertTo-V2KMac $_.MacAddress) -eq $want.target_mac})
 if($nics.Count -ne 1 -or !$nics[0].HardwareInterface -or $nics[0].Virtual -or [string]$nics[0].AdminStatus -ne 'Up'){throw 'NIC_MAPPING_AMBIGUOUS'}
 if([string]$nics[0].Status -ne 'Up'){throw 'WINDOWS_NETWORK_LINK_PENDING'}
 return @{adapter=$nics[0];binding=$bound[0];want=$want}
}
function Get-V2KExpectedNetwork($binding){
 $out=@();$seen=@()
 foreach($want in $plan.network.interfaces){
  $item=Get-V2KTargetNic $want $binding
  $seen+=@($item.adapter.ifIndex);$out+=@($item)
 }
 if(@($seen|Select-Object -Unique).Count -ne $seen.Count -or $binding.nics.Count -ne $out.Count){throw 'NIC_BINDING_MISMATCH'}
 return $out
}
function Set-V2KNetworkIntent($adapter,$want){
 $index=[int]$adapter.ifIndex
 # Recheck the current instance before each group; an old ifIndex is never authority.
 $current=@(Get-NetAdapter -Physical|Where-Object {$_.ifIndex -eq $index -and $_.InterfaceGuid -eq $adapter.InterfaceGuid -and $_.PnPDeviceID -eq $adapter.PnPDeviceID})
 if($current.Count -ne 1){throw 'NIC_BINDING_MISMATCH'}
 Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
 foreach($r in @(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)){
  $r|Remove-NetRoute -Confirm:$false -ErrorAction Stop
 }
 foreach($ip in @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object {$_.IPAddress -notlike '127.*'})){
  $ip|Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
 }
 if($want.ipv4.dhcp){Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop}
 else{
  foreach($ip in $want.ipv4.addresses){
   New-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -IPAddress $ip.address -PrefixLength $ip.prefix_length -SkipAsSource $ip.skip_as_source -ErrorAction Stop|Out-Null
  }
  foreach($r in $want.default_routes){New-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -NextHop $r.next_hop -RouteMetric $r.route_metric -ErrorAction Stop|Out-Null}
 }
 if($want.interface_metric.automatic){Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction Stop}
 else{Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric $want.interface_metric.value -ErrorAction Stop}
 if($want.dns.mode -eq 'static'){Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses @($want.dns.servers) -ErrorAction Stop}
 else{Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction Stop}
}
function Test-V2KGhostReleased($want,$key){
 $owned=@($want.ipv4.addresses|ForEach-Object {$_.address})
 if(!(Test-Path -LiteralPath $key)){return $true}
 $remaining=Get-ItemProperty -LiteralPath $key
 if(!@($remaining.IPAddress|Where-Object {$owned -contains $_}).Count){return $true}
 # Windows can retain a backup TCP/IP key after PnP removal. It is no longer an
 # address owner only when all three registered device/interface views are gone.
 $devices=@(Get-PnpDevice -InstanceId $want.source_pnp_id -ErrorAction SilentlyContinue)
 $adapters=@(Get-NetAdapter -IncludeHidden|Where-Object {([string]$_.InterfaceGuid).Trim('{}').ToLower() -eq $want.source_interface_guid})
 $configs=@(Get-CimInstance Win32_NetworkAdapterConfiguration|Where-Object {([string]$_.SettingID).Trim('{}').ToLower() -eq $want.source_interface_guid})
 return ($devices.Count -eq 0 -and $adapters.Count -eq 0 -and $configs.Count -eq 0)
}
function Remove-V2KOwnedGhost($item){
 $want=$item.want;$actualGuid=([string]$item.adapter.InterfaceGuid).Trim('{}').ToLower()
 if($actualGuid -eq $want.source_interface_guid){return}
 $key='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{'+$want.source_interface_guid+'}'
 if(!(Test-Path -LiteralPath $key)){return}
 $old=Get-ItemProperty -LiteralPath $key
 $owned=@($want.ipv4.addresses|ForEach-Object {$_.address})
 $held=@($old.IPAddress|Where-Object {$owned -contains $_})
 if(!$held.Count){return}
 $prior=@($journal.steps|Where-Object {$_.type -eq 'network-ghost' -and $_.identity -eq $want.source_pnp_id -and $_.state -eq 'APPLIED'})
 if($prior.Count){
  if($prior.Count -eq 1 -and $prior[0].remove_exit_code -in @(0,3010) -and (Test-V2KGhostReleased $want $key)){return}
  throw 'WINDOWS_NETWORK_GHOST_RECOVERY_REQUIRED'
 }
 $device=@(Get-PnpDevice -InstanceId $want.source_pnp_id -ErrorAction SilentlyContinue)
 if($device.Count -ne 1 -or $device[0].InstanceId -ne $want.source_pnp_id){throw 'WINDOWS_NETWORK_CONFLICT'}
 $present=Get-PnpDeviceProperty -InstanceId $want.source_pnp_id -KeyName DEVPKEY_Device_IsPresent -ErrorAction Stop
 if($present.Data -ne $false){throw 'WINDOWS_NETWORK_CONFLICT'}
 if(@($old.IPAddress|Where-Object {$_ -ne '0.0.0.0' -and $owned -notcontains $_}).Count){throw 'WINDOWS_NETWORK_CONFLICT'}
 Change-State 'network-ghost' $want.source_pnp_id @{guid=$want.source_interface_guid;addresses=@($old.IPAddress);subnets=@($old.SubnetMask);gateways=@($old.DefaultGateway);dns=[string]$old.NameServer} @{removed=$true} {
  # Exact instance only. Never /deviceid, /subtree, /force or driver-store removal.
  $code=Invoke-V2KRemoveDevice $want.source_pnp_id
  $step=$journal.steps[-1];$step|Add-Member -NotePropertyName remove_exit_code -NotePropertyValue $code
  Save-Json 'journal.json' $journal
  if($code -notin @(0,3010)){throw 'WINDOWS_NETWORK_GHOST_REMOVE_FAILED'}
  $released=$false
  for($attempt=0;$attempt -lt 10;$attempt++){
   if(Test-V2KGhostReleased $want $key){$released=$true;break}
   Start-Sleep -Seconds 1
  }
  if(!$released -or $code -eq 3010){
   if($journal.PSObject.Properties['network_reboot'] -and $journal.network_reboot.count -ge 1){throw 'WINDOWS_NETWORK_GHOST_RECOVERY_REQUIRED'}
   $script:networkRebootRequested=$true
  }
 }
}
function Invoke-V2KRemoveDevice($identity){
 & "$env:SystemRoot\System32\pnputil.exe" /remove-device $identity|Out-Null
 return [int]$LASTEXITCODE
}
function Apply-V2KNetwork($items){
 # All identities and initial states are checked before the first mutation.
 foreach($item in $items){$item.before=Get-V2KIPv4State $item.adapter}
 foreach($item in $items){Remove-V2KOwnedGhost $item}
 if($script:networkRebootRequested){return}
 foreach($item in $items){
  if(!(Test-V2KNetworkIntent $item.before.intent $item.want)){
   Change-State 'network-ipv4' $item.want.target_mac $item.before.intent $item.want {Set-V2KNetworkIntent $item.adapter $item.want}
  }
 }
}
function Observe-V2KNetwork($items){
 $out=@()
 foreach($item in $items){
  $state=Get-V2KIPv4State $item.adapter;$want=$item.want
  if(!(Test-V2KNetworkIntent $state.intent $want) -or $state.admin_status -ne 'Up' -or $state.link_status -ne 'Up'){throw 'WINDOWS_NETWORK_STATE_MISMATCH'}
  $addresses=@($state.addresses)
  if($want.ipv4.dhcp){
   $usable=@($addresses|Where-Object {$_.origin -eq 'Dhcp' -and $_.state -eq 'Preferred' -and $_.address -notlike '169.254.*'})
   if(!$usable.Count){throw 'WINDOWS_NETWORK_ADDRESS_PENDING'}
  }else{
   foreach($ip in $want.ipv4.addresses){
    $found=@($addresses|Where-Object {$_.address -eq $ip.address -and $_.prefix_length -eq $ip.prefix_length -and $_.skip_as_source -eq $ip.skip_as_source -and $_.origin -eq 'Manual' -and $_.state -eq 'Preferred'})
    if($found.Count -ne 1){throw 'WINDOWS_NETWORK_ADDRESS_PENDING'}
   }
  }
  foreach($route in $want.default_routes){
   if(@($state.routes|Where-Object {$_.next_hop -eq $route.next_hop -and $_.route_metric -eq $route.route_metric}).Count -ne 1){throw 'WINDOWS_NETWORK_ROUTE_MISMATCH'}
  }
  if($want.dns.mode -eq 'dhcp' -and !$state.dns_servers.Count){throw 'WINDOWS_NETWORK_DNS_PENDING'}
  $out+=@{target_mac=$want.target_mac;nic_uuid=$item.binding.id;network_uuid=$item.binding.network_uuid;interface_guid=$state.interface_guid;pnp_id=$state.pnp_id;ifindex=$state.ifindex;ipv4=$state.intent.ipv4;default_routes=$state.intent.default_routes;interface_metric=$state.intent.interface_metric;dns=$state.intent.dns;observed=$state;status='VERIFIED'}
 }
 return @{status='VERIFIED';interfaces=$out}
}
function Recover-V2KNetworkStep($step,$items){
 if($step.type -eq 'network-ghost'){throw 'WINDOWS_NETWORK_GHOST_RECOVERY_REQUIRED'}
 $item=@($items|Where-Object {$_.want.target_mac -eq $step.identity})
 if($item.Count -ne 1){throw 'GUEST_RECOVERY_CONFLICT'}
 $actual=(Get-V2KIPv4State $item[0].adapter).intent
 if($actual.source_interface_guid -ne $step.before.source_interface_guid -or $actual.source_pnp_id -ne $step.before.source_pnp_id){throw 'GUEST_RECOVERY_CONFLICT'}
 if(Test-V2KNetworkIntent $actual $step.before){$step.state='NOT_APPLIED'}
 elseif(Test-V2KNetworkIntent $actual $step.after){Set-V2KNetworkIntent $item[0].adapter $step.before;$step.state='ROLLED_BACK'}
 else{throw 'GUEST_RECOVERY_CONFLICT'}
}
