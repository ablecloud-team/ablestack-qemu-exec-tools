# Copyright 2026 ABLECLOUD. Apache-2.0.
[CmdletBinding()]
param([ValidateSet('Check','Apply','Restore')][string]$Mode='Apply',[string]$BackupId,[switch]$InstallQga,[switch]$InstallDrivers)
$ErrorActionPreference='Stop'
$result=[ordered]@{schemaVersion=1;profile='process-management';status='CHECK_FAILED';featureReady=$false;hostVerificationRequired=$true;rebootRequired=$false}
$logDirectory=Join-Path $env:ProgramData 'ABLESTACK-Tools'

function Test-InstalledMsi([string]$Path) {
    $installer=New-Object -ComObject WindowsInstaller.Installer
    $database=$installer.OpenDatabase($Path,0)
    $view=$database.OpenView('SELECT * FROM Property')
    $productCode=$null
    try {
        $view.Execute()
        while ($record=$view.Fetch()) {
            if ($record.StringData(1) -eq 'ProductCode') { $productCode=$record.StringData(2); break }
        }
    } finally { $view.Close() }
    if (-not $productCode) { throw "MSI product identity missing: $Path" }
    return ($installer.ProductState($productCode) -eq 5)
}

function Install-Msi([string]$Path,[string]$Label,[string]$Properties,[string]$LogName) {
    $log=Join-Path $logDirectory $LogName
    Write-Host "[INSTALL] $Label"
    $arguments="/i `"$Path`" /qn /norestart REBOOT=ReallySuppress $Properties /l*v `"$log`""
    $process=Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -notin @(0,3010)) { throw "$Label installation failed: $($process.ExitCode). See $log" }
    if ($process.ExitCode -eq 3010) {
        $result.rebootRequired=$true
        Write-Host "[REBOOT] $Label installed; restart required after remaining steps"
    } else { Write-Host "[OK] $Label installed" }
}

function Get-DriverVariant([int]$Build,[int]$ProductType) {
    if ($ProductType -eq 1 -and $Build -ge 22000 -and $Build -lt 30000) { return 'w11' }
    switch ($Build) {
        17763 { return '2k19' }
        20348 { return '2k22' }
        26100 { return '2k25' }
        default { throw "Unsupported Windows build for VirtIO drivers: $Build" }
    }
}

function Get-VirtioDevices([string]$DevicePattern) {
    return @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -match $DevicePattern })
}

function Install-VirtioDriver([string]$Variant,[string]$Component,[string]$InfName,[string]$DevicePattern) {
    $devices=@(Get-VirtioDevices $DevicePattern)
    if ($devices.Count -eq 0) {
        Write-Host "[SKIP] $Component hardware is not present"
        return
    }
    if (@($devices | Where-Object { $_.ConfigManagerErrorCode -ne 0 }).Count -eq 0) {
        Write-Host "[OK] $Component device driver is active"
        return
    }
    $inf=Join-Path $PSScriptRoot "drivers\$Component\$Variant\amd64\$InfName"
    if (-not (Test-Path -LiteralPath $inf -PathType Leaf)) { throw "Signed driver payload missing: $inf" }
    $log=Join-Path $logDirectory "driver-$Component.log"
    Write-Host "[INSTALL] Binding $Component to present VirtIO hardware"
    $process=Start-Process pnputil.exe -ArgumentList "/add-driver `"$inf`" /install" -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $log
    if ($process.ExitCode -notin @(0,3010)) { throw "$Component driver installation failed: $($process.ExitCode). See $log" }
    if ($process.ExitCode -eq 3010) { $result.rebootRequired=$true }
    $devices=@(Get-VirtioDevices $DevicePattern)
    $failed=@($devices | Where-Object { $_.ConfigManagerErrorCode -notin @(0,14) })
    if ($failed.Count -gt 0) {
        $codes=($failed | ForEach-Object { $_.ConfigManagerErrorCode }) -join ','
        throw "$Component device driver is not active after installation (PnP code: $codes). See $log"
    }
    if (@($devices | Where-Object { $_.ConfigManagerErrorCode -eq 14 }).Count -gt 0) { $result.rebootRequired=$true }
    Write-Host "[OK] $Component device driver bound"
}

try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this installer from an elevated administrator session' }
    if ($Mode -ne 'Apply' -and ($InstallQga -or $InstallDrivers)) { throw 'InstallQga and InstallDrivers are only valid with Apply' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Only x86_64 Windows is supported' }
    $os=Get-CimInstance Win32_OperatingSystem
    $build=[int]$os.BuildNumber
    $isWindows11=($os.ProductType -eq 1 -and $build -ge 22000 -and $build -lt 30000)
    $isServer=($os.ProductType -ne 1 -and $build -in @(17763,20348,26100))
    if (-not ($isWindows11 -or $isServer)) { throw 'Unsupported Windows version' }
    $driverVariant=Get-DriverVariant $build $os.ProductType
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1) { throw 'Unsupported manifest' }
    $expected=@('ProcessPolicy.psm1','Repair-ProcessPolicy.ps1','ProcessList.ps1','AbleProcessIdentity.dll','ProcessAction.ps1','AbleProcessAction.dll','ABLESTACK-ProcessTools.msi','qemu-ga-x86_64.msi','virtio-win-gt-x64.msi','virtio-win_license.txt')
    foreach ($name in $expected) {
        $entry=@($manifest.files | Where-Object { $_.name -ceq $name })
        if ($entry.Count -ne 1 -or $entry[0].sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Missing manifest entry: $name" }
        $hash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash
        if ($hash -ne $entry[0].sha256) { throw "Payload hash mismatch: $name" }
    }
    $driverRoot=Join-Path $PSScriptRoot 'drivers'
    $driverFiles=@(Get-ChildItem -LiteralPath $driverRoot -Recurse -File)
    if ($driverFiles.Count -eq 0 -or $manifest.driverFiles.Count -ne $driverFiles.Count) { throw 'VirtIO driver manifest is incomplete' }
    foreach ($file in $driverFiles) {
        $name=$file.FullName.Substring($PSScriptRoot.Length+1).Replace('\','/')
        $entry=@($manifest.driverFiles | Where-Object { $_.name -ceq $name })
        if ($entry.Count -ne 1 -or $entry[0].sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Missing driver manifest entry: $name" }
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $entry[0].sha256) { throw "Driver payload hash mismatch: $name" }
    }
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    Write-Host '[OK] Windows compatibility and ISO payload verified'
    $services=@(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'qemu-ga\.exe' })
    if ($services.Count -gt 1) { throw 'Multiple QGA services require administrator review' }
    if ($services.Count -eq 0 -and -not $InstallQga) { throw 'QGA_MISSING: explicit -InstallQga required for offline installation' }
    if ($InstallDrivers) {
        $msi=Join-Path $PSScriptRoot 'virtio-win-gt-x64.msi'
        if (Test-InstalledMsi $msi) { Write-Host '[SKIP] VirtIO MSI registered; checking device bindings' }
        else { Install-Msi $msi 'VirtIO drivers' 'ADDLOCAL=ALL' 'virtio-install.log' }
        Install-VirtioDriver $driverVariant 'NetKVM' 'netkvm.inf' '^PCI\\VEN_1AF4&DEV_(1000|1041)'
        Install-VirtioDriver $driverVariant 'vioserial' 'vioser.inf' '^PCI\\VEN_1AF4&DEV_(1003|1043)'
        Install-VirtioDriver $driverVariant 'Balloon' 'balloon.inf' '^PCI\\VEN_1AF4&DEV_(1002|1045)'
    }
    if ($InstallQga) {
        if ($services.Count -eq 1) {
            Import-Module (Join-Path $PSScriptRoot 'ProcessPolicy.psm1') -Force
            Assert-IndependentSession $services[0].ProcessId
            Write-Host '[SKIP] QEMU Guest Agent already installed'
        } else {
            $msi=Join-Path $PSScriptRoot 'qemu-ga-x86_64.msi'
            Install-Msi $msi 'QEMU Guest Agent' '' 'qga-install.log'
        }
    }
    if ($Mode -eq 'Apply') {
        $msi=Join-Path $PSScriptRoot 'ABLESTACK-ProcessTools.msi'
        Install-Msi $msi 'ABLESTACK Process Tools' 'REINSTALLMODE=amus' 'process-tools-install.log'
    }
    if ($InstallQga) {
        $svc=@(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'qemu-ga\.exe' })
        if ($svc.Count -ne 1) { throw 'QGA service absent after installation' }
        if ($svc[0].State -ne 'Running') { Start-Service $svc[0].Name }
        Write-Host '[OK] QEMU Guest Agent service running'
    }
    Write-Host '[CONFIGURE] QGA process execution policy'
    & (Join-Path $PSScriptRoot 'Repair-ProcessPolicy.ps1') -Mode $Mode -BackupId $BackupId
    $policyExit=$LASTEXITCODE
    if ($Mode -ne 'Apply' -or $policyExit -notin @(0,3010)) { exit $policyExit }
    if ($policyExit -eq 3010) { $result.rebootRequired=$true }
    $result.status=if ($result.rebootRequired) { 'REBOOT_REQUIRED' } else { 'POLICY_CONFIGURED_PENDING_HOST_VERIFY' }
    $result | ConvertTo-Json -Compress
    if ($result.rebootRequired) { exit 3010 }
    exit 0
} catch {
    $result.error=$_.Exception.Message
    $result | ConvertTo-Json -Compress
    exit 4
}
