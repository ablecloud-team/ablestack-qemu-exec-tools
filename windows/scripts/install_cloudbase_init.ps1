# install_cloudbase_init.ps1
# ablestack-qemu-exec-tools cloudbase-init 자동 설치/설정/템플릿화

# 1. 환경설정
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$CbiMsiPath = Join-Path $BaseDir "..\cloudbase-init\CloudbaseInitSetup_x64.msi"
$ConfTemplatePath = Join-Path $BaseDir "cloudbase-init.conf.template"
$ConfTargetPath = "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf"
$UnattendPath = Join-Path $BaseDir "unattend.xml"
$WinUnattendPath = "C:\Windows\Panther\unattend.xml"

# 2. cloudbase-init MSI 무인 설치
Write-Host "[INFO] Cloudbase-Init MSI 패키지 설치 시작..."
if (-Not (Test-Path $CbiMsiPath)) {
    Write-Error "[ERROR] cloudbase-init MSI 파일이 존재하지 않습니다: $CbiMsiPath"
    exit 1
}
Start-Process msiexec.exe -ArgumentList "/i `"$CbiMsiPath`" /qn /norestart" -Wait
Write-Host "[INFO] Cloudbase-Init MSI 설치 완료."

# 3. conf 템플릿 → 실제 conf로 복사(간단한 치환 예시)
Write-Host "[INFO] cloudbase-init.conf 자동화 적용..."
if (-Not (Test-Path $ConfTemplatePath)) {
    Write-Error "[ERROR] conf 템플릿이 존재하지 않습니다: $ConfTemplatePath"
    exit 2
}
# 필요한 경우 conf 템플릿에서 환경별로 치환 (예: {{ADMIN_USER}})
$template = Get-Content $ConfTemplatePath -Raw
# 예시: 치환 필요 시 아래처럼 사용 (지금은 단순 복사)
# $config = $template -replace "{{ADMIN_USER}}", "Administrator"
$config = $template
$config | Set-Content $ConfTargetPath -Force
Write-Host "[INFO] cloudbase-init.conf 배포 완료: $ConfTargetPath"

# 4. cloudbase-init 서비스 재시작
Write-Host "[INFO] cloudbase-init 서비스 재시작..."
Restart-Service cloudbase-init

# 5. unattend.xml 복사
Write-Host "[INFO] unattend.xml 배포..."
Copy-Item $UnattendPath $WinUnattendPath -Force

# 6. Sysprep 자동 실행 (SID/컴퓨터 일반화)
Write-Host "[INFO] sysprep 실행: VM 템플릿화, SID 및 환경 재설정"
$sysprepExe = "$env:SystemRoot\System32\Sysprep\Sysprep.exe"
$sysprepArgs = "/generalize /oobe /shutdown /unattend:$WinUnattendPath"
Start-Process -Wait -NoNewWindow $sysprepExe -ArgumentList $sysprepArgs
Write-Host "[INFO] sysprep이 완료되었습니다. (VM이 곧 자동 종료됩니다)"

# 7. 안내 메시지 출력
Write-Host "`n[INFO] 모든 ablestack cloudbase-init 자동화가 완료되었습니다."
Write-Host "[INFO] 이 VM을 템플릿/이미지로 등록하여 클론/신규 배포에 사용하세요."
Write-Host "[INFO] 클론 시 SID, 비밀번호, cloudbase-init 메타데이터 등이 매번 새롭게 적용됩니다."
