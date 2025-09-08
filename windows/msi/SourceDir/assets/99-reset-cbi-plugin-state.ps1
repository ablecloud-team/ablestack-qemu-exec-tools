# 99-reset-cbi-plugin-state.ps1
# 목적: Cloudbase-Init 플러그인 실행 상태를 매 부팅마다 초기화하여 다음 부팅에 다시 실행되도록 함.

$BaseKey = 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init'
$Targets = @()

# 1) 루트 \Plugins (instance_id가 없는 경우에 대비)
$Targets += Join-Path $BaseKey 'Plugins'

# 2) 모든 인스턴스ID 하위의 \Plugins
if (Test-Path $BaseKey) {
    Get-ChildItem -Path $BaseKey -ErrorAction SilentlyContinue | ForEach-Object {
        $pluginsKey = Join-Path $_.PSPath 'Plugins'
        $Targets += $pluginsKey
    }
}

foreach ($k in $Targets) {
    if (Test-Path $k) {
        try {
            # 방법 A: 키 전체 삭제 (가장 확실)
            Remove-Item -Path $k -Recurse -Force -ErrorAction Stop
            # 방법 B(보수적): 값만 0으로 리셋하고 싶다면 아래 주석을 사용
            # $item = Get-Item -Path $k
            # foreach ($vn in ($item.GetValueNames())) {
            #     New-ItemProperty -Path $k -Name $vn -PropertyType DWord -Value 0 -Force | Out-Null
            # }
        } catch {
            # 일부 값/권한 문제는 무시
        }
    }
}

# 로그 흔적 남기기(디버깅용)
try {
    $logDir = 'C:\ProgramData\AbleStack\CloudInit'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    "[{0}] Reset Cloudbase-Init plugin state" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |
        Add-Content -Path (Join-Path $logDir 'localscripts.log')
} catch {}

exit 1002