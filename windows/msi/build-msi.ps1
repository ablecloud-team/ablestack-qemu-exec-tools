<#
  Build script for MSI (WiX v4). 
  Usage:
    pwsh -File .\build-msi.ps1 [-WixBin "C:\Program Files\WiX Toolset v4.0\bin"]
#>
param(
  [string]$WixBin = "$Env:ProgramFiles\WiX Toolset v4.0\bin"
)
$ErrorActionPreference = "Stop"
$out = Join-Path $PSScriptRoot "out"
if(-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }
$src = Join-Path $PSScriptRoot "SourceDir"
$candle = Join-Path $WixBin "candle.exe"
$light  = Join-Path $WixBin "light.exe"
if(-not (Test-Path $candle)) { throw "candle.exe not found in $WixBin" }
if(-not (Test-Path $light))   { throw "light.exe not found in $WixBin" }

& $candle -ext WixToolset.Util.wixext -dSourceDir="$src" -out "$out\" "$PSScriptRoot\Product.wxs"
& $light  -ext WixToolset.Util.wixext -out "$out\AbleStack-CloudInit-Automator.msi" "$out\Product.wixobj"
Write-Host "[OK] Built: $out\AbleStack-CloudInit-Automator.msi"