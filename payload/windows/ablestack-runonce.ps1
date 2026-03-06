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
# ?”êµ¬?¬í•­:
# - ISO ë£¨íŠ¸??install.bat ì¡´ì¬
# ?™ì‘:
# - ëª¨ë“  ?Œì¼?œìŠ¤???œë¼?´ë¸Œë¥??œíšŒ?˜ì—¬ ë£¨íŠ¸??install.bat???ˆëŠ” ?œë¼?´ë¸Œë¥??ìƒ‰
# - ì°¾ìœ¼ë©?ì¡°ìš©???¤í–‰(ê´€ë¦¬ì ê¶Œí•œ ì»¨í…?¤íŠ¸)

$scriptName = "install.bat"
$targetPath = $null

# 1) ?¼ë²¨ ê¸°ë°˜?¼ë¡œ ë¹ ë¥´ê²??ìƒ‰(? íƒ?? ???¤íŒ¨ ???„ì²´ ?œë¼?´ë¸Œ ê²€??
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

# 2) ?¼ë²¨ë¡?ëª?ì°¾ì•˜?¼ë©´, ?„ì²´ ?œë¼?´ë¸Œ ë£¨íŠ¸?ì„œ install.bat ?ìƒ‰
if (-not $targetPath) {
    $targetPath = Get-PSDrive -PSProvider FileSystem | ForEach-Object {
        $p = Join-Path ($_.Name + ":\") $scriptName
        if (Test-Path $p) { return $p }
    } | Select-Object -First 1
}

if ($null -ne $targetPath -and (Test-Path $targetPath)) {
    try {
        # RunOnce??ë³´í†µ ê´€ë¦¬ì ì»¨í…?¤íŠ¸ë¡??˜í–‰?? ì¡°ìš©???¤í–‰ ??ì¢…ë£Œ.
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$targetPath`"" -Wait
    } catch {
        # ?¤íŒ¨?´ë„ RunOnce ?¹ì„±???¬ì‹œ?„ëŠ” OS ?ˆë²¨?ì„œ ???˜ë?ë¡?ì¡°ìš©??ë°˜í™˜
    }
}
# RunOnce???¤í–‰ ???ë™?¼ë¡œ ???œê±°??ì¶”ê? ?•ë¦¬ ë¶ˆí•„??
