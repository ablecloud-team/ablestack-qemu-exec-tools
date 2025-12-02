<#
  Copyright 2025 ABLECLOUD

  File: ablestack-runonce.ps1
  Purpose: PowerShell script to run a specified command once at startup in Windows VMs
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

# ABLESTACK - Windows RunOnce one-shot installer
# 요구사항:
# - ISO 루트에 install.bat 존재
# 동작:
# - 모든 파일시스템 드라이브를 순회하여 루트에 install.bat이 있는 드라이브를 탐색
# - 찾으면 조용히 실행(관리자 권한 컨텍스트)

$scriptName = "install.bat"
$targetPath = $null

# 1) 라벨 기반으로 빠르게 탐색(선택적) → 실패 시 전체 드라이브 검색
try {
    $labelCandidates = @("ABLESTACK-Tools", "ABLESTACK","ablestack","ablestack-qemu-exec-tools")
    $labelDrive = Get-PSDrive -PSProvider FileSystem | ForEach-Object {
        try {
            $vol = Get-Volume -DriveLetter $_.Name -ErrorAction Stop
            if ($labelCandidates -contains $vol.FileSystemLabel) { return ($_.Name + ":\") }
        } catch {}
    } | Select-Object -First 1

    if ($labelDrive) {
        $p = Join-Path $labelDrive $scriptName
        if (Test-Path $p) { $targetPath = $p }
    }
} catch {}

# 2) 라벨로 못 찾았으면, 전체 드라이브 루트에서 install.bat 탐색
if (-not $targetPath) {
    $targetPath = Get-PSDrive -PSProvider FileSystem | ForEach-Object {
        $p = Join-Path ($_.Name + ":\") $scriptName
        if (Test-Path $p) { return $p }
    } | Select-Object -First 1
}

if ($null -ne $targetPath -and (Test-Path $targetPath)) {
    try {
        # RunOnce는 보통 관리자 컨텍스트로 수행됨. 조용히 실행 후 종료.
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$targetPath`"" -Wait
    } catch {
        # 실패해도 RunOnce 특성상 재시도는 OS 레벨에서 안 하므로 조용히 반환
    }
}
# RunOnce는 실행 후 자동으로 키 제거됨(추가 정리 불필요)
