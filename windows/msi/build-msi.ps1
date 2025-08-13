<#
  Build script for MSI (WiX v4).
  Usage:
    pwsh -File .\build-msi.ps1
#>

$ErrorActionPreference = "Stop"

# 0) wix CLI 확인
$wix = (Get-Command wix -ErrorAction Stop).Source

# 1) 출력/소스 경로
$out = Join-Path $PSScriptRoot "out"
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

$src = Join-Path $PSScriptRoot "SourceDir"
$wxs = Join-Path $PSScriptRoot "Product.wxs"
if (-not (Test-Path $wxs)) { throw "WiX source not found: $wxs" }

# 2) 필요한 WiX 확장(Extensions) 캐시 등록
#    (이미 등록되어 있으면 무시됨)
$requiredExts = @(
  "WixToolset.Util.wixext/4.0.6", "WixToolset.Bal.wixext/4.0.6", "WixToolset.UI.wixext/4.0.6"   # 필요에 따라 추가: "WixToolset.Bal.wixext" 등
)
foreach ($ext in $requiredExts) {
  try {
    & $wix extension add -g $ext | Out-Null
  } catch {
    # 이미 등록된 경우 등은 무시 (로그 원하면 Write-Verbose 사용)
  }
}

# 3) 빌드: candle/light 단계는 wix CLI가 내부적으로 수행
#    -d 로 프리프로세서 변수 전달, -ext 로 확장 사용, -o 로 출력 지정
$outMsi = Join-Path $out "AbleStack-CloudInit-Automator.msi"
& $wix build $wxs `
  -arch x64 `
  -d SourceDir="$src" `
  -ext WixToolset.Util.wixext/4.0.6 `
  -o $outMsi

Write-Host "[OK] Built: $outMsi"
