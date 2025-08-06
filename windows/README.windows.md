# ablestack-qemu-exec-tools : Windows VM Cloudbase-Init 자동화 및 템플릿화

## 개요

이 디렉토리는 Windows 가상머신(VM)의 클라우드 자동화 환경을 구축하기 위해
Cloudbase-Init(윈도우용 cloud-init) 자동 설치, 설정, Sysprep, Unattend 자동화
및 템플릿 배포에 필요한 스크립트, 설정, 샘플 파일을 포함합니다.

---

## 디렉토리 구조

```
windows/
  cloudbase-init/
    CloudbaseInitSetup_x64.msi           # cloudbase-init 공식 설치파일(동봉)
  scripts/
    install_cloudbase_init.ps1           # 모든 자동화 통합 PowerShell 스크립트
    cloudbase-init.conf.template         # cloudbase-init conf 템플릿(설정 가능)
    unattend.xml                         # Sysprep용 무인응답파일(한국어, 범용)
  README.windows.md                      # (본 문서)
```

---

## 주요 자동화/템플릿 특징

* **Cloudbase-Init** 자동 설치(MSI 무인설치)
* **메타데이터 데이터소스:** ConfigDrive, None 우선
* **호스트네임/네트워크/사용자(Administrator) 자동설정**
* **cloudbase-init.conf 자동 배포/확장가능**
* **sysprep + unattend.xml(한국어, 완전 무인) 자동실행**
* **SID, 환경, OOBE, 비밀번호, 클론/템플릿 환경 완벽 지원**
* **Windows Server 2016/2019/2022, Windows 10/11 등 범용 지원**

---

## 설치 및 사용법

### 1. (필수) 모든 파일/폴더를 Windows VM에 복사

* MSI, conf.template, unattend.xml, install\_cloudbase\_init.ps1 포함

### 2. **관리자 권한 PowerShell**로 아래 스크립트 실행

```powershell
cd [scripts 디렉토리 경로]
powershell.exe -ExecutionPolicy Bypass -File .\install_cloudbase_init.ps1
```

### 3. 동작 흐름

* cloudbase-init 무인 설치
* conf 템플릿 배포
* 서비스 자동 재시작
* unattend.xml 배포
* sysprep 실행(템플릿화, SID/환경 재설정, VM 자동종료)
* 이후 VM을 **이미지/템플릿**으로 등록 후 자유롭게 클론/배포

---

## 주요 설정/템플릿 설명

### cloudbase-init.conf.template

* metadata\_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.nocloudservice.NoCloudService
* username=Administrator
* set\_host\_name=true
* network\_adapter\_enabling\_method=automatic
* plugins=...UserDataPlugin...(부팅시 커맨드/runcmd 지원)

### unattend.xml

* 완전 무인설치, 모든 질문/제품키 생략
* 언어/키보드: 한국어(ko-KR)
* SID, Hostname, 계정 등 sysprep에 의해 자동 재설정
* 모든 Windows 버전(서버/데스크탑) 범용 사용 가능

---

## 참고/유의사항

* 반드시 VM 환경에서 **최초 1회만 실행**
  (Sysprep 후 VM이 종료됨 → 이 상태로 이미지/템플릿 제작)
* 관리자 권한 PowerShell 사용 필수
* cloudbase-init.conf, unattend.xml 등 **필요시 직접 커스터마이징** 가능
* 특수 환경(네트워크, 키보드, 제품키 등) 적용 필요시 템플릿 수정

---

## 추가 문의/확장 요청

* cloudbase-init.conf 옵션 추가, unattend.xml 세부 커스터마이즈
* 사용자 정의 스크립트(FirstLogonCommands 등) 적용
* 한글/영문 이중화, 다중 윈도우 버전 자동화 등

ablestack-qemu-exec-tools 윈도우 자동화 템플릿은
실제 VM 운영/배포 환경에 맞춰 자유롭게 확장/응용이 가능합니다!
