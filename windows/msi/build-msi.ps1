<#
  Copyright 2025 ABLECLOUD

  File: build-msi.ps1
  Purpose: Build script for MSI (WiX v4).
  Usage:
    powershell.exe -File .\build-msi.ps1
  Author: Donghyuk Park

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

# 0) wix CLI 확인
$wix = (Get-Command wix -ErrorAction Stop).Source

# 1) 출력/소스 경로
$out = Join-Path $PSScriptRoot "out"
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

$src = Join-Path $PSScriptRoot "SourceDir"
$wxs = Join-Path $PSScriptRoot "Product.wxs"
if (-not (Test-Path $wxs)) { throw "WiX source not found: $wxs" }

# 2) 필요한 WiX 확장(Extensions) 등록
$requiredExts = @(
  "WixToolset.Util.wixext/4.0.6",
  "WixToolset.Bal.wixext/4.0.6",
  "WixToolset.UI.wixext/4.0.6"
)
foreach ($ext in $requiredExts) {
  try {
    & $wix extension add -g $ext | Out-Null
  } catch { }
}

# 3) 빌드: 버전/릴리즈/깃해시 변수 전달
$outMsi = Join-Path $out "ablestack-qemu-exec-tools-$Version-$Release-$GitHash.msi"
& $wix build $wxs `
  -arch x64 `
  -d SourceDir="$src" `
  -d ProductVersion="$Version" `
  -d ProductRelease="$Release" `
  -d GitHash="$GitHash" `
  -ext WixToolset.Util.wixext/4.0.6 `
  -o $outMsi

Write-Host "[OK] Built: $outMsi"