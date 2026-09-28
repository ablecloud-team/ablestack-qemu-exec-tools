# 프로세스 관리 패키지·ISO 검증 및 인계

Cloud #1173 / Qemu #65. 산출물은 GitHub Actions의 `build.yml`에서 생성한다. `release-validation-<run>` artifact의 `build/iso/manifest.json`은 각 ISO의 지원 OS/버전/아키텍처, 원본 commit, workflow run ID, 패키지·ISO 크기와 SHA-256을 담는다. `SHA256SUMS`로 ISO 바이트를 재검증한다. Cloud 관리자가 등록할 `vm.process.tools.iso.catalog`의 `sha256`은 해당 ISO 해시와 일치해야 한다.

## 산출물·지원 목표

| 게스트 | ISO | 설치 방식 |
| --- | --- | --- |
| Rocky 9.6/9.7/9.8 x86_64 | 각 버전별 `ABLESTACK-Tools-rocky*.iso` | ISO에서 `bash install-linux.sh --mode process-management` |
| Rocky 10.2 x86_64 | `ABLESTACK-Tools-rocky10.2-*.iso` | 프로세스 전용 repair media. Rocky 9 호스트 RPM을 포함하지 않음 |
| Ubuntu 22.04/24.04/26.04 x86_64 | `ABLESTACK-Tools-ubuntu-*.iso` | 동일한 Linux 설치 명령 |
| Windows Server 2022/2025 x86_64 | `ABLESTACK-Tools-windows-*.iso` | 관리자 PowerShell에서 `process-management\install.bat -Mode Apply` |

호스트 패키지는 Rocky 9.6/9.7/9.8 RPM, Ubuntu 22.04/24.04/26.04 DEB, Windows MSI를 동일 Actions run에서 만든다. 프로세스 전용 Windows MSI는 `windows-process-payload`에 들어 있고, `ProcessAction.ps1`/`AbleProcessAction.dll`까지 해시 manifest에 포함한다. 패키지 설치와 ISO 게스트 복구는 별개이다. 게스트 QGA가 없으면 Linux 전용 repair ISO만으로 QGA 패키지를 설치할 수 없다.

## 설치·복구·롤백

1. Actions artifact의 manifest 원본 commit/run ID를 PR commit과 대조하고 해시를 확인한다.
2. 호스트의 기존 패키지·설정·서비스 상태를 기록한 뒤 해당 배포판 패키지를 설치/업그레이드한다. 호스트 `vm_exec`와 실제 설치 스크립트가 같은 commit의 파일인지 확인한다.
3. Cloud ISO 라이브러리에 알맞은 ISO를 등록하고 Ready·zone·SHA-256을 확인한 후 매핑한다. 기존 VM 미디어는 무단 분리하지 않는다.
4. 게스트 콘솔에서 오프라인 설치/복구를 실행한다. QGA 실행이 막힌 경우 QGA 자체 guest-exec로 설치하지 않는다. 재부팅 요청을 따르고 Cloud에서 RPC 8개, 프로세스 목록, 종료·서비스 재시작을 각각 재검증한다.
5. 실패 시 게스트 Linux는 `agent_policy_fix --policy process-management --restore BACKUP_ID` 또는 설치 도구의 백업/복구 안내를 따른다. Windows는 `Repair-ProcessPolicy.ps1 -Mode Restore -BackupId ...`를 관리자 셸에서 사용한다. 호스트 패키지는 설치 전 보관한 버전으로 되돌리고 서비스 상태를 재확인한다.

`manifest.json`은 산출물 추적 자료이며 단독으로 실환경 PASS를 의미하지 않는다. 지원 매트릭스의 실제 PASS/FAIL은 Actions 결과와 각 VM의 설치·RPC·프로세스 작업 증거를 함께 기록한다.
