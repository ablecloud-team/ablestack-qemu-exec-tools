# Copyright 2026 ABLECLOUD. Apache-2.0.
[CmdletBinding()]
param([switch]$SkipDrivers)
$ErrorActionPreference='Stop'
$installer=Join-Path $PSScriptRoot 'process-management\install.ps1'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'ABLESTACK Tools installer payload missing' }
& $installer -Mode Apply -InstallQga -InstallDrivers:(-not $SkipDrivers)
exit $LASTEXITCODE
