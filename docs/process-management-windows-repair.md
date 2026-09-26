# Windows 프로세스 관리 Tools 설치·복구 (Q3)

이슈: https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/62
Epic: https://github.com/ablecloud-team/ablestack-cloud/issues/1170

## 브랜치와 배포 경계

`codex/process-integration-q1-q2` (`0a00165`)는 Q1 PR #67의 `5037d97`와
Q2 PR #68의 `10e921b`를 포함한다. Python 의존성 충돌은 3.9 이상으로 통합했다.
`codex/issue-62-windows-policy`는 이 기준에서 분기했다. 후속 작업은 이 누적
기준을 사용하고, Q3 리뷰 diff는 통합 기준과 비교한다. 선행 PR 병합과 구분한다.

기존 Windows Cloudbase-init MSI는 Sysprep/부팅 작업을 등록하므로 사용하지 않는다.
전용 `ABLESTACK-ProcessTools.msi`는 정책 스크립트와 SOURCE_COMMIT만 설치한다.
서비스 변경은 명시적 install.ps1/Repair-ProcessPolicy.ps1 실행이 수행한다.
계정/네트워크/Cloudbase-init 초기화, 자동 재부팅, OS 보안 정책 완화는 하지 않는다.

## 사용

Windows Server 2022/2025 x64 관리자 PowerShell에서 ISO를 연결하고 실행한다.

```powershell
.\install.ps1                       # 기존 QGA 정책 복구 및 전용 MSI 설치
.\install.ps1 -Mode Check           # 정책 확인
.\install.ps1 -Mode Restore -BackupId backup-<32자리 ID>
.\install.ps1 -InstallQga           # 번들 QGA MSI 명시적 설치/업그레이드
```

기존 전체 ISO는 `install.ps1 -Mode ProcessManagement` 또는
`install.bat -Mode ProcessManagement`로 이 전용 경로에 진입한다.
옵션 없는 기존 전체 설치는 종전 동작을 유지한다. 전체 ISO workflow는 같은
source_ref의 재사용 Windows process 빌드를 의존성으로 실행해 페이로드를 포함한다.

게스트에서 네트워크로 패키지를 내려받지 않는다. Actions가 Fedora VirtIO 공식
stable ISO에서 QGA x64 MSI를 추출하며 원본 ISO SHA256, 각 페이로드 SHA256,
소스 커밋을 manifest.json에 기록한다. install.ps1은 실행 전 필수 페이로드
해시를 확인한다. 배포자는 Actions 산출물 자체의 출처/SHA를 별도로 확인해야 한다.
MSI 코드 3010 및 기존 Windows 재부팅 대기는 REBOOT_REQUIRED로 반환하고 자동 재부팅하지 않는다.

## 정책 계약

실행 중인 유일한 QGA LocalSystem 서비스의 ImagePath와 프로세스 CommandLine을
비교한다. 명시적 CLI allow/block 필터와 --dump-conf의 실제 정책이 일치해야 한다.
8개 RPC와 연결/식별용 5개 RPC를 보충하되 기존 허용과 무관한 차단은 보존한다.
따옴표 없는 경로, 커스텀 서비스 인자, QGA_CONF, 기본 INI의 숨은 제한 등은
추측해 덮어쓰지 않고 CHECK_FAILED로 관리자가 확인하게 한다.

ProgramData의 `ABLESTACK-ProcessPolicy` 아래를 SYSTEM/Administrators 전용 ACL로
보호한다. 변경 전 ImagePath 백업, 정책 잠금, 재시작 실패 복원 및 관리자 동시
변경 거부를 적용한다. QGA 자식에서 QGA를 재시작하는 요청은 거부한다.
독립 관리자 세션 또는 독립된 작업 스케줄러 프로세스로 실행한다.

POLICY_REPAIR_REQUIRED(5), POLICY_CONFIGURED_PENDING_HOST_VERIFY(0),
RESTORED_PENDING_HOST_VERIFY(0), REBOOT_REQUIRED(3010), CHECK_FAILED(4)를 구분한다.
모든 결과의 featureReady=false이며 설치 성공이 Cloud READY는 아니다.

호스트에서는 현재 배치와 공통 작업 guard를 사용하는 아래 검증을 수행한다.

```sh
python3 bin/vm_process_verify.py i-2-27-VM --guest-os windows
```

실행 및 파일 RPC를 C:\ProgramData\ABLESTACK-ProcessPolicy\probe의 임의 파일에
한정한다. UTF-16LE 인코딩한 고정 PowerShell 명령만 실행하고 삭제 결과까지 확인한다.
현재 Windows probe는 표준 C: Windows/ProgramData 경로를 대상으로 한다.

## 완료 판정

파서/동시 변경 보호와 기존 Q1/Q2 회귀 테스트, Actions MSI/ISO 생성은 자동 검증한다.
실제 VM은 기본 정책 보존, 설치/재설치, 제한 정책 복구/복원, 서비스/네트워크/VM
identity 보존, 실행·파일 RPC·정리를 확인한다. Windows Server 2022와 2025의
실환경 결과는 분리하고, QGA 미설치/업그레이드 시험 및 전체 ISO 통합 시험도
개별 결과로 기록한다. 수행하지 않은 항목을 단위 테스트나 빌드 성공으로 대체하지 않는다.