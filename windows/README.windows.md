# ablestack-qemu-exec-tools : Windows VM Cloudbase-Init 자동화 및 템플릿화

## 개요

이 디렉토리는 Windows 가상머신(VM)의 클라우드 초기화 환경 구축하기 위해
Cloudbase-Init(윈도우용 cloud-init) 자동 설치, 설정, Sysprep, Unattend 자동화
및 템플릿 배포에 필요한 스크립트, 설정, 템플 파일들을 포함합니다.

---

## 디렉토리 구조

```
windows/
  cloudbase-init/
    CloudbaseInitSetup_x64.msi           # cloudbase-init 공식 설치파일(포함)
  scripts/
    install_cloudbase_init.ps1           # 모든 자동화를 통합 PowerShell 스크립트
    cloudbase-init.conf.template         # cloudbase-init conf 템플릿 설정 가이드
    unattend.xml                         # Sysprep용 무인응답파일(한국어 범용)
  README.windows.md                      # (이 문서)
```

---

## 주요 자동화 및 템플릿 특징

* **Cloudbase-Init** 자동 설치(MSI 무인 설치)
* **메타데이터 소스 선택** ConfigDrive, None 선택
* **네트워크/사용자(Administrator) 자동 설정**
* **cloudbase-init.conf 자동 배포/환경가이드**
* **sysprep + unattend.xml(한국어 완전 무인) 자동 실행**
* **SID, 컴퓨터명, OOBE, 비밀번호, 아이콘/바탕화면 초기화 지원**
* **Windows Server 2016/2019/2022, Windows 10/11 범용 지원**

---

## 설치 및 사용법

### 1. (필수) 모든 파일/디렉토리를 Windows VM에 복사

* MSI, conf.template, unattend.xml, install_cloudbase_init.ps1 포함

### 2. **관리자 권한 PowerShell**에서 다음과 같이 스크립트 실행

```powershell
cd [scripts 디렉토리 경로]
powershell.exe -ExecutionPolicy Bypass -File .\install_cloudbase_init.ps1
```

### 3. ?�작 ?�름

* cloudbase-init 무인 ?�치
* conf ?�플�?배포
* ?�비???�동 ?�시??
* unattend.xml 배포
* sysprep ?�행(?�플릿화, SID/?�경 ?�설?? VM ?�동종료)
* ?�후 VM??**?��?지/?�플�?*?�로 ?�록 ???�유�?�� ?�론/배포

---

## 주요 ?�정/?�플�??�명

### cloudbase-init.conf.template

* metadata\_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.nocloudservice.NoCloudService
* username=Administrator
* set\_host\_name=true
* network\_adapter\_enabling\_method=automatic
* plugins=...UserDataPlugin...(부?�시 커맨??runcmd 지??

### unattend.xml

* ?�전 무인?�치, 모든 질문/?�품???�략
* ?�어/?�보?? ?�국??ko-KR)
* SID, Hostname, 계정 ??sysprep???�해 ?�동 ?�설??
* 모든 Windows 버전(?�버/?�스?�탑) 범용 ?�용 가??

---

## 참고/?�의?�항

* 반드??VM ?�경?�서 **최초 1?�만 ?�행**
  (Sysprep ??VM??종료???????�태�??��?지/?�플�??�작)
* 관리자 권한 PowerShell ?�용 ?�수
* cloudbase-init.conf, unattend.xml ??**?�요??직접 커스?�마?�징** 가??
* ?�수 ?�경(?�트?�크, ?�보?? ?�품???? ?�용 ?�요???�플�??�정

---

## 추�? 문의/?�장 ?�청

* cloudbase-init.conf ?�션 추�?, unattend.xml ?��? 커스?�마?�즈
* ?�용???�의 ?�크립트(FirstLogonCommands ?? ?�용
* ?��?/?�문 ?�중?? ?�중 ?�도??버전 ?�동????

ablestack-qemu-exec-tools ?�도???�동???�플릿�?
?�제 VM ?�영/배포 ?�경??맞춰 ?�유�?�� ?�장/?�용??가?�합?�다!
