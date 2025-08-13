<#
  Licensed under the Apache License, Version 2.0
  Copyright (c) ABLECLOUD
  File: phase-runner.ps1
  Purpose: Unattended Phase1/Phase2 orchestration with auto-resume for Windows templates
#>
#requires -version 5.1
param(
    [string]$LogDir = "C:\ProgramData\AbleStack\CloudInit\Logs",
    [switch]$SysprepAfterPhase2
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$global:PhaseRegPath = "HKLM:\SOFTWARE\AbleStack\CloudInit"
$global:PhaseRegName = "Phase"             # "1","2","Done"
$global:PhaseMarker  = "C:\ProgramData\AbleStack\CloudInit\phase.marker"
$global:StateFile    = "C:\ProgramData\AbleStack\CloudInit\state.json"
$global:LogFile      = Join-Path $LogDir ("phase-runner_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Ensure-Dirs {
    foreach($d in @($LogDir, (Split-Path $global:PhaseMarker -Parent))) {
        if(-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Write-Log { param([string]$msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    "$ts [phase-runner] $msg" | Tee-Object -FilePath $global:LogFile -Append
}

function Get-Phase {
    if(Test-Path $global:PhaseRegPath){
        $p = (Get-ItemProperty -Path $global:PhaseRegPath -Name $global:PhaseRegName -ErrorAction SilentlyContinue).$global:PhaseRegName
        if($p){ return $p } 
    }
    if(Test-Path $global:PhaseMarker){
        try{
            $content = Get-Content $global:PhaseMarker -ErrorAction Stop | Select-Object -First 1
            if($content){ return $content.Trim() }
        }catch{}
    }
    return "1"
}

function Set-Phase { param([string]$p)
    if(-not (Test-Path $global:PhaseRegPath)) { New-Item -Path $global:PhaseRegPath -Force | Out-Null }
    Set-ItemProperty -Path $global:PhaseRegPath -Name $global:PhaseRegName -Value $p -Force
    $p | Out-File -FilePath $global:PhaseMarker -Encoding ascii -Force
    Write-Log "Phase set to '$p'"
}

function Save-State { param([hashtable]$h)
    $h | ConvertTo-Json -Depth 5 | Out-File -FilePath $global:StateFile -Encoding UTF8 -Force
}

function Invoke-Phase1 {
    Write-Log "=== Phase1 start ==="
    Write-Log "Phase1 tasks: pre-cleaning, Appx removals, prerequisites"
    try{
        $appxList = @(
            # Example packages; adjust for your baseline
            "Microsoft.3DBuilder","Microsoft.XboxApp"
        )
        foreach($a in $appxList){
            try{
                Write-Log "Removing AppxPackage '$a' for all users (best-effort)"
                Get-AppxPackage -AllUsers -Name $a -ErrorAction SilentlyContinue | ForEach-Object {
                    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
                }
            }catch{
                Write-Log "WARN: Appx removal failed for '$a': $($_.Exception.Message)"
            }
        }
    }catch{ Write-Log "WARN: bulk Appx removal section failed: $($_.Exception.Message)" }

    try{
        Write-Log "Ensuring Cloudbase-Init service is set to Automatic"
        sc.exe config cloudbase-init start= auto | Out-Null
    }catch{ Write-Log "WARN: service config: $($_.Exception.Message)" }

    Write-Log "=== Phase1 end, requesting reboot ==="
    Set-Phase "2"
    shutdown.exe /r /t 5 /c "AbleStack Phase1 completed; proceeding to Phase2 after reboot."
}

function Invoke-Phase2 {
    Write-Log "=== Phase2 start ==="
    try{
        Write-Log "Phase2 tasks: post-configuration"
        New-Item -ItemType Directory -Path "C:\opt\ablestack" -Force | Out-Null
        "phase2-ok" | Out-File -FilePath "C:\opt\ablestack\phase2.txt" -Encoding UTF8 -Force
    }catch{
        Write-Log "ERROR: Phase2 tasks failed: $($_.Exception.Message)"
        throw
    }
    Write-Log "=== Phase2 complete ==="
    Set-Phase "Done"

    if($SysprepAfterPhase2){
        try{
            Write-Log "Invoking Sysprep /generalize /oobe /shutdown"
            & "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /generalize /oobe /shutdown /quiet
        }catch{
            Write-Log "ERROR: sysprep failed: $($_.Exception.Message)"
            throw
        }
    }
}

try{
    Ensure-Dirs
    Write-Log "Phase runner started as $(whoami)"
    $phase = Get-Phase
    Write-Log "Detected phase: $phase"
    switch($phase){
        "1" { Invoke-Phase1 }
        "2" { Invoke-Phase2 }
        "Done" { Write-Log "Nothing to do: already Done"; }
        default { Write-Log "Unknown phase '$phase' -> set to 1 and start"; Set-Phase "1"; Invoke-Phase1 }
    }
    Save-State(@{ lastPhase=$phase; when=(Get-Date); ok=$true })
}catch{
    Write-Log "FATAL: $($_.Exception.Message)"
    Save-State(@{ lastPhase=(Get-Phase); when=(Get-Date); ok=$false; error="$($_.Exception.Message)" })
    exit 1
}