<#
  Copyright 2025 ABLECLOUD

  File: 99-reset-cbi-plugin-state.ps1
  Purpose: Reset Cloudbase-Init plugin state in registry to ensure all plugins run on next boot
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

$BaseKey = 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init'
$Targets = @()

# 1) ë£¨íŠ¸ \Plugins (instance_idê°€ ?†ëŠ” ê²½ìš°???€ë¹?
$Targets += Join-Path $BaseKey 'Plugins'

# 2) ëª¨ë“  ?¸ìŠ¤?´ìŠ¤ID ?˜ìœ„??\Plugins
if (Test-Path $BaseKey) {
    Get-ChildItem -Path $BaseKey -ErrorAction SilentlyContinue | ForEach-Object {
        $pluginsKey = Join-Path $_.PSPath 'Plugins'
        $Targets += $pluginsKey
    }
}

foreach ($k in $Targets) {
    if (Test-Path $k) {
        try {
            # ë°©ë²• A: ???„ì²´ ?? œ (ê°€???•ì‹¤)
            Remove-Item -Path $k -Recurse -Force -ErrorAction Stop
            # ë°©ë²• B(ë³´ìˆ˜??: ê°’ë§Œ 0?¼ë¡œ ë¦¬ì…‹?˜ê³  ?¶ë‹¤ë©??„ë˜ ì£¼ì„???¬ìš©
            # $item = Get-Item -Path $k
            # foreach ($vn in ($item.GetValueNames())) {
            #     New-ItemProperty -Path $k -Name $vn -PropertyType DWord -Value 0 -Force | Out-Null
            # }
        } catch {
            # ?¼ë? ê°?ê¶Œí•œ ë¬¸ì œ??ë¬´ì‹œ
        }
    }
}

# ë¡œê·¸ ?”ì  ?¨ê¸°ê¸??”ë²„ê¹…ìš©)
try {
    $logDir = 'C:\ProgramData\AbleStack\CloudInit'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    "[{0}] Reset Cloudbase-Init plugin state" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |
        Add-Content -Path (Join-Path $logDir 'localscripts.log')
} catch {}

exit 1002