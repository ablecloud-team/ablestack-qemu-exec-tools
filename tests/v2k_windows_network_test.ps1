# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
param([string]$LibraryPath=(Join-Path $PSScriptRoot '..\lib\v2k\guest-config'))
$ErrorActionPreference='Stop'
function Assert($condition,$message){if(!$condition){throw $message}}
function Import-Functions($path,$names=@()){
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 Assert (!$errors.Count) ('Parse failure: '+$path)
 foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
  if(!$names.Count -or $f.Name -in $names){. ([scriptblock]::Create('function script:'+$f.Name+$f.Extent.Text.Substring(('function '+$f.Name).Length)))}
 }
}
Import-Functions (Join-Path $LibraryPath 'windows-network-read.ps1')
Import-Functions (Join-Path $LibraryPath 'windows-network.ps1')
Import-Functions (Join-Path $LibraryPath 'windows-helper.ps1') @('Change-State')
function Save-Json($name,$value){$script:saves++}
function Get-NetAdapter {param([switch]$Physical,[switch]$IncludeHidden) return @($script:adapter,$script:foreign)}
function Get-NetIPInterface {param([int]$InterfaceIndex,[string]$AddressFamily,[string]$PolicyStore)
 Assert ($InterfaceIndex -eq 7) 'Foreign interface read';return $script:ipif
}
function Get-NetIPAddress {param([int]$InterfaceIndex,[string]$AddressFamily,[string]$PolicyStore)
 Assert ($InterfaceIndex -eq 7) 'Foreign address access'
 if($PolicyStore -eq 'PersistentStore'){return @($script:addresses|Where-Object {$_.PrefixOrigin -eq 'Manual'})};return $script:addresses
}
function Get-NetRoute {param([int]$InterfaceIndex,[string]$AddressFamily,[string]$PolicyStore,[string]$DestinationPrefix)
 Assert ($InterfaceIndex -eq 7) 'Foreign route access'
 if($PolicyStore -eq 'PersistentStore' -and $script:ipif.Dhcp -eq 'Enabled'){return @()};return $script:routes
}
function Get-DnsClientServerAddress {param([int]$InterfaceIndex,[string]$AddressFamily)
 Assert ($InterfaceIndex -eq 7) 'Foreign DNS access';return [pscustomobject]@{ServerAddresses=$script:servers}
}
function Get-ItemProperty {param([string]$LiteralPath)
 if($LiteralPath -like ('*'+$script:adapter.InterfaceGuid+'*')){return [pscustomobject]@{NameServer=$script:nameServer}}
 return [pscustomobject]@{IPAddress=@('192.0.2.10');SubnetMask=@('255.255.255.0');DefaultGateway=@('192.0.2.1');NameServer='192.0.2.53'}
}
function Test-Path {param([string]$LiteralPath) return $script:ghost}
function Get-PnpDevice {param([string]$InstanceId) if($script:oldDeviceRegistered){return [pscustomobject]@{InstanceId=$InstanceId}}}
function Get-CimInstance {param([string]$ClassName)
 if($ClassName -ne 'Win32_NetworkAdapterConfiguration'){throw 'Unmocked CIM query'}
 if($script:oldDeviceRegistered){return [pscustomobject]@{SettingID=$script:want.source_interface_guid}}
}
function Get-PnpDeviceProperty {param([string]$InstanceId,[string]$KeyName) return [pscustomobject]@{Data=$script:ghostPresent}}
function Invoke-V2KRemoveDevice($identity){
 Assert ($identity -eq $script:want.source_pnp_id) 'Foreign PnP removal'
 $script:removals++
 if($script:removeCode -eq 0){$script:oldDeviceRegistered=$false;if($script:clearGhost){$script:ghost=$false}}
 return $script:removeCode
}
function Start-Sleep {param([int]$Seconds)}
function Set-NetIPInterface {param([int]$InterfaceIndex,[string]$AddressFamily,[string]$Dhcp,[string]$AutomaticMetric,[int]$InterfaceMetric)
 Assert ($InterfaceIndex -eq 7) 'Foreign interface mutation';$script:mutations++
 if($PSBoundParameters.ContainsKey('Dhcp')){
  $script:ipif.Dhcp=$Dhcp
  if($Dhcp -eq 'Enabled'){
   $script:addresses=@([pscustomobject]@{IPAddress='192.0.2.200';PrefixLength=24;SkipAsSource=$false;AddressState='Preferred';PrefixOrigin='Dhcp';InterfaceIndex=7})
   $script:routes=@([pscustomobject]@{DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=0;InterfaceIndex=7})
  }
 }
 if($PSBoundParameters.ContainsKey('AutomaticMetric')){$script:ipif.AutomaticMetric=$AutomaticMetric}
 if($PSBoundParameters.ContainsKey('InterfaceMetric')){$script:ipif.InterfaceMetric=$InterfaceMetric}
}
function Remove-NetIPAddress {param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Confirm)
 process{Assert ($InputObject.InterfaceIndex -eq 7) 'Foreign IP removal';$script:addresses=@($script:addresses|Where-Object {$_.IPAddress -ne $InputObject.IPAddress})}
}
function Remove-NetRoute {param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Confirm)
 process{Assert ($InputObject.InterfaceIndex -eq 7) 'Foreign route removal';$script:routes=@()}
}
function New-NetIPAddress {param([int]$InterfaceIndex,[string]$AddressFamily,[string]$IPAddress,[int]$PrefixLength,[bool]$SkipAsSource)
 Assert ($InterfaceIndex -eq 7) 'Foreign IP mutation'
 $script:addresses+=@([pscustomobject]@{IPAddress=$IPAddress;PrefixLength=$PrefixLength;SkipAsSource=$SkipAsSource;AddressState=$(if($script:dadPending){'Tentative'}else{'Preferred'});PrefixOrigin='Manual';InterfaceIndex=7})
}
function New-NetRoute {param([int]$InterfaceIndex,[string]$AddressFamily,[string]$DestinationPrefix,[string]$NextHop,[int]$RouteMetric)
 Assert ($InterfaceIndex -eq 7) 'Foreign gateway mutation';$script:routes+=@([pscustomobject]@{DestinationPrefix=$DestinationPrefix;NextHop=$NextHop;RouteMetric=$RouteMetric;InterfaceIndex=7})
}
function Set-DnsClientServerAddress {param([int]$InterfaceIndex,[string[]]$ServerAddresses,[switch]$ResetServerAddresses)
 Assert ($InterfaceIndex -eq 7) 'Foreign DNS mutation'
 if($ResetServerAddresses){$script:nameServer='';$script:servers=@('192.0.2.1')}
 else{$script:nameServer=$ServerAddresses -join ',';$script:servers=$ServerAddresses}
}
function Reset-Fixture{
 $script:adapter=[pscustomobject]@{Name='Renamed #2';ifIndex=7;InterfaceGuid='33333333-3333-4333-8333-333333333333';PnPDeviceID='PCI\VEN_1AF4&DEV_1000\0002';MacAddress='00-50-56-39-90-01';HardwareInterface=$true;Virtual=$false;AdminStatus='Up';Status='Up'}
 $script:foreign=[pscustomobject]@{Name='Protected';ifIndex=99;InterfaceGuid='44444444-4444-4444-8444-444444444444';PnPDeviceID='PCI\FOREIGN';MacAddress='00-50-56-39-90-99';HardwareInterface=$true;Virtual=$false;AdminStatus='Up';Status='Up'}
 $script:ipif=[pscustomobject]@{Dhcp='Enabled';AutomaticMetric='Enabled';InterfaceMetric=25}
 $script:addresses=@([pscustomobject]@{IPAddress='192.0.2.200';PrefixLength=24;SkipAsSource=$false;AddressState='Preferred';PrefixOrigin='Dhcp';InterfaceIndex=7})
 $script:routes=@([pscustomobject]@{DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=0;InterfaceIndex=7})
 $script:servers=@('192.0.2.1');$script:nameServer='';$script:ghost=$false;$script:ghostPresent=$false;$script:dadPending=$false;$script:saves=0;$script:mutations=0;$script:networkRebootRequested=$false;$script:removals=0;$script:removeCode=0;$script:clearGhost=$true;$script:oldDeviceRegistered=$true
 $script:want=[pscustomobject]@{source_interface_guid='11111111-1111-4111-8111-111111111111';source_pnp_id='PCI\VEN_1AF4&DEV_1000\0001';target_mac='00:50:56:39:90:01';target_network_uuid='22222222-2222-4222-8222-222222222222';ipv4=[pscustomobject]@{dhcp=$false;addresses=@([pscustomobject]@{address='192.0.2.10';prefix_length=24;skip_as_source=$false})};default_routes=@([pscustomobject]@{next_hop='192.0.2.1';route_metric=10;persistent=$true});interface_metric=[pscustomobject]@{automatic=$false;value=10};dns=[pscustomobject]@{mode='static';servers=@('192.0.2.53','192.0.2.54')}}
 $script:binding=[pscustomobject]@{nics=@([pscustomobject]@{id='55555555-5555-4555-8555-555555555555';mac=$want.target_mac;network_uuid=$want.target_network_uuid})}
 $script:plan=[pscustomobject]@{network=[pscustomobject]@{interfaces=@($want)}}
 $script:journal=[pscustomobject]@{steps=@()};$script:boot='fixture-boot'
}
Reset-Fixture
$items=@(Get-V2KExpectedNetwork $binding);Apply-V2KNetwork $items;$report=Observe-V2KNetwork $items
Assert ($report.status -eq 'VERIFIED' -and $report.interfaces[0].ifindex -eq 7 -and $journal.steps.Count -eq 1) 'Static restoration or current device mapping failed'
$count=$mutations;Apply-V2KNetwork @(Get-V2KExpectedNetwork $binding)
Assert ($mutations -eq $count -and $journal.steps.Count -eq 1) 'Idempotent replay mutated the NIC'
Write-Output 'PASS: renamed/reordered target NIC restores IPv4, gateway, metric and ordered DNS once'
Reset-Fixture;$want.ipv4=[pscustomobject]@{dhcp=$true;addresses=@()};$want.default_routes=@();$want.interface_metric=[pscustomobject]@{automatic=$true;value=$null};$want.dns=[pscustomobject]@{mode='static';servers=@('192.0.2.53')}
$items=@(Get-V2KExpectedNetwork $binding);Apply-V2KNetwork $items;Observe-V2KNetwork $items|Out-Null
Assert ($ipif.Dhcp -eq 'Enabled' -and $nameServer -eq '192.0.2.53') 'DHCP with static DNS lost'
Write-Output 'PASS: DHCP and manual DNS are independent'
Reset-Fixture;$binding.nics[0].network_uuid='foreign'
try{Get-V2KExpectedNetwork $binding;throw 'Expected conflict'}catch{Assert ($_.Exception.Message -eq 'NIC_BINDING_MISMATCH') 'Wrong NIC conflict'}
Assert ($mutations -eq 0) 'Binding mismatch mutated state'
Write-Output 'PASS: wrong network binding is rejected before mutation'
Reset-Fixture;$adapter.Status='Disconnected'
try{Get-V2KExpectedNetwork $binding;throw 'Expected link wait'}catch{Assert ($_.Exception.Message -eq 'WINDOWS_NETWORK_LINK_PENDING') 'Disconnected NIC was mutated'}
Assert ($mutations -eq 0) 'Pending link allowed mutation'
Write-Output 'PASS: link readiness precedes any mutation'
Reset-Fixture;$script:ghost=$true;$script:ghostPresent=$true
try{Apply-V2KNetwork @(Get-V2KExpectedNetwork $binding);throw 'Expected conflict'}catch{Assert ($_.Exception.Message -eq 'WINDOWS_NETWORK_CONFLICT') ('Present source device was not protected: '+$_.Exception.Message)}
Assert ($mutations -eq 0 -and $journal.steps.Count -eq 0) 'Present NIC was removed'
Write-Output 'PASS: present/foreign NIC IP ownership is protected'
Reset-Fixture;$script:ghost=$true;$script:removeCode=3010
$items=@(Get-V2KExpectedNetwork $binding);Apply-V2KNetwork $items
Assert ($script:networkRebootRequested -and $mutations -eq 0 -and $removals -eq 1 -and $journal.steps[0].state -eq 'APPLIED' -and $journal.steps[0].remove_exit_code -eq 3010) 'PnP reboot requirement was lost or IP applied prematurely'
$journal|Add-Member -NotePropertyName network_reboot -NotePropertyValue ([pscustomobject]@{count=1})
try{Apply-V2KNetwork $items;throw 'Expected recovery boundary'}catch{Assert ($_.Exception.Message -eq 'WINDOWS_NETWORK_GHOST_RECOVERY_REQUIRED') 'Second unverified removal/reboot allowed'}
Assert ($removals -eq 1) 'Device removal was blindly replayed'
Write-Output 'PASS: successful removal requiring reboot is journaled once before IP mutation'
Reset-Fixture;$script:ghost=$true;$items=@(Get-V2KExpectedNetwork $binding);Apply-V2KNetwork $items;Observe-V2KNetwork $items|Out-Null
Assert ($removals -eq 1 -and !$script:networkRebootRequested) 'Completed ghost cleanup requested an unnecessary reboot'
Write-Output 'PASS: completed exact-device cleanup proceeds without reboot'
Reset-Fixture;$script:ghost=$true;$script:clearGhost=$false;$items=@(Get-V2KExpectedNetwork $binding);Apply-V2KNetwork $items;Observe-V2KNetwork $items|Out-Null
Assert ($script:ghost -and !$script:oldDeviceRegistered -and !$script:networkRebootRequested -and $removals -eq 1) 'Harmless backup key caused a false failure or was deleted'
Write-Output 'PASS: an unregistered interface backup key is retained without claiming IP ownership'
Reset-Fixture;$script:ghost=$true;$script:removeCode=5
try{Apply-V2KNetwork @(Get-V2KExpectedNetwork $binding);throw 'Expected native failure'}catch{Assert ($_.Exception.Message -eq 'WINDOWS_NETWORK_GHOST_REMOVE_FAILED') 'Native removal error ignored'}
Assert ($mutations -eq 0 -and !$script:networkRebootRequested) 'Failed removal allowed IP mutation or reboot'
Write-Output 'PASS: genuine PnP failure is not treated as a reboot request'
Reset-Fixture;$script:dadPending=$true;$items=@(Get-V2KExpectedNetwork $binding);Apply-V2KNetwork $items
try{Observe-V2KNetwork $items;throw 'Expected DAD wait'}catch{Assert ($_.Exception.Message -eq 'WINDOWS_NETWORK_ADDRESS_PENDING') 'DAD incomplete accepted'}
$addresses[0].AddressState='Preferred';Observe-V2KNetwork $items|Out-Null
Write-Output 'PASS: DAD must finish before verification'
Reset-Fixture;$items=@(Get-V2KExpectedNetwork $binding);Apply-V2KNetwork $items;$count=$mutations
$servers=@('192.0.2.54','192.0.2.53');$nameServer=$servers -join ','
try{Observe-V2KNetwork $items;throw 'Expected drift'}catch{Assert ($_.Exception.Message -eq 'WINDOWS_NETWORK_STATE_MISMATCH') 'Changed DNS order accepted'}
Assert ($mutations -eq $count -and $nameServer -eq '192.0.2.54,192.0.2.53') 'Observation overwrote user DNS'
try{Recover-V2KNetworkStep $journal.steps[0] $items;throw 'Expected recovery conflict'}catch{Assert ($_.Exception.Message -eq 'GUEST_RECOVERY_CONFLICT') 'Recovery overwrote user DNS'}
Write-Output 'PASS: drift and conditional recovery preserve external changes'
