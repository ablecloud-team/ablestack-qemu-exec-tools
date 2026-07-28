<#
  Copyright 2025 ABLECLOUD

  File: build-msi.ps1
  Purpose: Build the Windows MSI with WiX v4.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
#>

param(
    [string]$Version = "0.1.0",
    [string]$Release = "1",
    [string]$GitHash = "dev"
)

$ErrorActionPreference = "Stop"

$wix = (Get-Command wix -ErrorAction Stop).Source

$out = Join-Path $PSScriptRoot "out"
if (-not (Test-Path -LiteralPath $out)) {
    New-Item -ItemType Directory -Path $out | Out-Null
}

$src = Join-Path $PSScriptRoot "SourceDir"
$wxs = Join-Path $PSScriptRoot "Product.wxs"
if (-not (Test-Path -LiteralPath $wxs)) {
    throw "WiX source not found: $wxs"
}

$requiredExts = @(
    "WixToolset.Util.wixext/4.0.6",
    "WixToolset.Bal.wixext/4.0.6",
    "WixToolset.UI.wixext/4.0.6"
)
foreach ($ext in $requiredExts) {
    try {
        & $wix extension add -g $ext | Out-Null
    }
    catch {
        Write-Verbose "WiX extension is already installed or could not be added: $ext"
    }
}

$outMsi = Join-Path $out "ablestack-qemu-exec-tools-$Version-$Release-$GitHash.msi"
if (Test-Path -LiteralPath $outMsi) {
    Remove-Item -LiteralPath $outMsi -Force
}

& $wix build $wxs `
    -arch x64 `
    -d SourceDir="$src" `
    -d ProductVersion="$Version" `
    -d ProductRelease="$Release" `
    -d GitHash="$GitHash" `
    -ext WixToolset.Util.wixext/4.0.6 `
    -o $outMsi

if ($LASTEXITCODE -ne 0) {
    throw "WiX build failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $outMsi)) {
    throw "WiX reported success but the MSI was not created: $outMsi"
}

Write-Host "[OK] Built: $outMsi"
