# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
# Fixed read-only adapter, shared by source capture and target observation.
function Invoke-V2KNetworkQuery([scriptblock]$query){
 try{& $query}catch{if($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound*'){return};throw}
}
function ConvertTo-V2KMac($value){
 $hex=([string]$value).ToLower() -replace '[:-]',''
 if($hex -notmatch '^[0-9a-f]{12}$'){throw 'NIC_MAPPING_AMBIGUOUS'}
 return (($hex -split '(..)'|Where-Object {$_}) -join ':')
}
function Get-V2KIPv4State($adapter){
 $index=[int]$adapter.ifIndex
 $current=@(Get-NetAdapter -Physical|Where-Object {$_.ifIndex -eq $index -and $_.InterfaceGuid -eq $adapter.InterfaceGuid -and $_.PnPDeviceID -eq $adapter.PnPDeviceID -and $_.MacAddress -eq $adapter.MacAddress})
 if($current.Count -ne 1){throw 'NIC_BINDING_MISMATCH'}
 $ipif=@(Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -PolicyStore ActiveStore)
 if($ipif.Count -ne 1){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
 $dhcp=([string]$ipif[0].Dhcp -eq 'Enabled')
 $active=@(Invoke-V2KNetworkQuery {Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -PolicyStore ActiveStore})
 $persistent=@(Invoke-V2KNetworkQuery {Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -PolicyStore PersistentStore})
 $manual=@($active|Where-Object {[string]$_.PrefixOrigin -eq 'Manual'})
 $addresses=@()
 foreach($a in $manual){
  $persist=@($persistent|Where-Object {$_.IPAddress -eq $a.IPAddress -and $_.PrefixLength -eq $a.PrefixLength -and $_.SkipAsSource -eq $a.SkipAsSource})
  if($persist.Count -ne 1){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
  $addresses+=@{address=[string]$a.IPAddress;prefix_length=[int]$a.PrefixLength;skip_as_source=[bool]$a.SkipAsSource}
 }
 $routes=@(Invoke-V2KNetworkQuery {Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -PolicyStore PersistentStore})
 $activeRoutes=@(Invoke-V2KNetworkQuery {Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -PolicyStore ActiveStore})
 if(@($routes|Where-Object {$_.DestinationPrefix -ne '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0'}).Count){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
 $defaults=@()
 foreach($r in @($routes|Where-Object {$_.DestinationPrefix -eq '0.0.0.0/0'})){
  $defaults+=@{next_hop=[string]$r.NextHop;route_metric=[int]$r.RouteMetric;persistent=$true}
 }
 if(!$dhcp -and @($activeRoutes|Where-Object {$_.DestinationPrefix -eq '0.0.0.0/0'}).Count -ne $defaults.Count){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
 $guid=([string]$adapter.InterfaceGuid).Trim('{}').ToLower()
 $key='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{'+$guid+'}'
 $registry=Get-ItemProperty -LiteralPath $key
 $static=([string]$registry.NameServer).Trim()
 $servers=@(Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4|ForEach-Object {$_.ServerAddresses})
 if($static){
  $configured=@($static -split '[,;\s]+'|Where-Object {$_})
  if(($configured -join ',') -ne ($servers -join ',')){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
  $dns=@{mode='static';servers=$configured}
 }elseif($dhcp){$dns=@{mode='dhcp';servers=@()}}
 elseif($servers.Count -eq 0){$dns=@{mode='none';servers=@()}}
 else{throw 'WINDOWS_NETWORK_UNSUPPORTED'}
 $automatic=([string]$ipif[0].AutomaticMetric -eq 'Enabled')
 $intent=@{source_mac=(ConvertTo-V2KMac $adapter.MacAddress);source_interface_guid=$guid;source_pnp_id=[string]$adapter.PnPDeviceID;admin_enabled=([string]$adapter.AdminStatus -eq 'Up');ipv4=@{dhcp=$dhcp;addresses=$addresses};default_routes=$defaults;interface_metric=@{automatic=$automatic;value=$(if($automatic){$null}else{[int]$ipif[0].InterfaceMetric})};dns=$dns}
 return @{intent=$intent;interface_guid=$guid;pnp_id=[string]$adapter.PnPDeviceID;ifindex=$index;admin_status=[string]$adapter.AdminStatus;link_status=[string]$adapter.Status;addresses=@($active|ForEach-Object {@{address=[string]$_.IPAddress;prefix_length=[int]$_.PrefixLength;skip_as_source=[bool]$_.SkipAsSource;state=[string]$_.AddressState;origin=[string]$_.PrefixOrigin}});routes=@($activeRoutes|Where-Object {$_.DestinationPrefix -eq '0.0.0.0/0'}|ForEach-Object {@{next_hop=[string]$_.NextHop;route_metric=[int]$_.RouteMetric}});dns_servers=$servers}
}
function Get-V2KWindowsNetwork{
 if(@(Get-DnsClientNrptPolicy -Effective).Count){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
 if(Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'){
  $policy=Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
  if($policy.NameServer){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
 }
 if(Test-Path 'HKLM:\SOFTWARE\Microsoft\dot3svc\Interfaces'){
  if(@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\dot3svc\Interfaces').Count){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
 }
 if((Get-Command Get-NetLbfoTeam -ErrorAction SilentlyContinue) -and @(Get-NetLbfoTeam).Count){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
 $nics=@()
 foreach($a in @(Get-NetAdapter -Physical)){
  if(!$a.HardwareInterface -or $a.Virtual -or [string]$a.AdminStatus -ne 'Up'){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
  if(@(Invoke-V2KNetworkQuery {Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv6}|Where-Object {[string]$_.PrefixOrigin -eq 'Manual' -and $_.IPAddress -notlike 'fe80:*'}).Count){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
  # RA/DHCPv6 may advertise link-local DNS automatically; keep that protocol alone.
  # Only a persistent manual IPv6 DNS override needs the unsupported v6 adapter.
  $v6key='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\{'+([string]$a.InterfaceGuid).Trim('{}')+'}'
  if(Test-Path -LiteralPath $v6key){if((Get-ItemProperty -LiteralPath $v6key).NameServer){throw 'WINDOWS_NETWORK_UNSUPPORTED'}}
  if(@(Get-NetAdapterBinding -Name ([WildcardPattern]::Escape($a.Name))|Where-Object {$_.Enabled -and $_.ComponentID -in @('vms_pp','ms_bridge')}).Count){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
  # Some VMware NIC drivers do not expose AdvancedProperty through CIM. Read
  # only the network class instance belonging to this exact PnP/InterfaceGuid.
  $device=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\'+$a.PnPDeviceID)
  if($device.Driver -notmatch '^\{4d36e972-e325-11ce-bfc1-08002be10318\}\\[0-9]{4}$'){throw 'NIC_MAPPING_AMBIGUOUS'}
  $driver=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Control\Class\'+$device.Driver)
  if(([string]$driver.NetCfgInstanceId).Trim('{}').ToLower() -ne ([string]$a.InterfaceGuid).Trim('{}').ToLower()){throw 'NIC_MAPPING_AMBIGUOUS'}
  foreach($key in @('VlanID','*VlanID')){
   $property=$driver.PSObject.Properties[$key]
   if($property -and [string]$property.Value -and [int]$property.Value -ne 0){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
  }
  if($driver.NetworkAddress){throw 'WINDOWS_NETWORK_UNSUPPORTED'}
  $nics+=@((Get-V2KIPv4State $a).intent)
 }
 return @{adapter='windows-nettcpip';version=1;interfaces=$nics}
}
