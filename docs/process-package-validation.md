# 프로세스 관리 패키지·ISO 검증 및 인계

Cloud #1173 / Qemu #65. 통합 검증용 산출물은 GitHub Actions의 `process-epic.yml`에서 생성한다. `process-guest-isos/manifest.json`은 지원 OS/버전/아키텍처, 원본 commit, workflow run ID, ISO 크기와 SHA-256을 담는다. 관리자는 Ready ISO의 UUID 배열만 `vm.process.tools.iso.catalog`에 등록한다. SHA-256은 빌드·배포 무결성 검증 자료이며 Global 설정에 중복 등록하지 않는다.

## 산출물·지원 목표

| 게스트 | ISO | 설치 방식 |
| --- | --- | --- |
| Rocky 8.x/9.x/10.x x86_64 | 공통 `ABLESTACK-Tools-rocky-*.iso` | root에서 `bash install-linux.sh` |
| Ubuntu 22.04/24.04/26.04 x86_64 | 공통 `ABLESTACK-Tools-ubuntu-*.iso` | root에서 `bash install-linux.sh` |
| Debian 12/13 x86_64 | 공통 `ABLESTACK-Tools-debian-*.iso` | root에서 `bash install-linux.sh` |
| Windows 11/Server 2019/2022/2025 x86_64 | 공통 `ABLESTACK-Tools-windows-*.iso` | 관리자 권한으로 `install.bat` |

호스트 실행 RPM/DEB, Windows MSI, 네 계열의 게스트 ISO를 동일 run에서 만든다. 호스트 RPM/DEB는 ABLESTACK 호스트 프로파일의 clean install/reinstall을 검증하며 게스트용 QGA 설정을 호스트에 적용하지 않는다. Linux 읽기·작업 launcher와 Windows DLL은 한 번 빌드하고 RPM·DEB·ISO에 동일 바이트를 넣는다. Actions는 패키지를 풀어 파일 바이트와 승인 카탈로그를 대조한다. Linux ISO에는 버전별 오프라인 QGA와 설치 의존 패키지가 포함되어 QGA가 없는 게스트에도 설치할 수 있다. Windows ISO는 OS에 맞는 VirtIO 드라이버, QGA, Process Tools와 RPC 정책을 설치·검증한다. RHEL은 지원 목표지만 Rocky 설치 결과를 RHEL 설치 증거로 간주하지 않는다. RHEL 자체 패키지·구독 조건 및 RHEL VM 검증은 별도이다. Debian 11은 제외한다.

## 설치·복구·롤백

1. Actions artifact의 manifest 원본 commit/run ID를 PR commit과 대조하고 해시를 확인한다.
2. 호스트의 기존 패키지·설정·서비스 상태를 기록한 뒤 해당 배포판 패키지를 설치/업그레이드한다. 호스트 `vm_exec`와 실제 설치 스크립트가 같은 commit의 파일인지 확인한다.
3. Cloud ISO 라이브러리에 네 계열 ISO를 등록하고 Ready·zone을 확인한 뒤 UUID 배열을 매핑한다. 파일 해시는 별도로 검증한다. 기존 VM 미디어는 기록·보존한다.
4. 게스트 콘솔에서 오프라인 설치/복구를 실행한다. QGA 실행이 막힌 경우 QGA 자체 guest-exec로 설치하지 않는다. 재부팅 요청을 따르고 Cloud에서 RPC 8개, 프로세스 목록, 종료·서비스 재시작을 각각 재검증한다.
5. 실패 시 게스트 Linux는 `agent_policy_fix --policy process-management --restore BACKUP_ID` 또는 설치 도구의 백업/복구 안내를 따른다. Windows는 `Repair-ProcessPolicy.ps1 -Mode Restore -BackupId ...`를 관리자 셸에서 사용한다. 호스트 패키지는 설치 전 보관한 버전으로 되돌리고 서비스 상태를 재확인한다.

Linux 복구 정책은 이전 설치 상태와 다른 관리자 파일을 기본적으로 보존한다. 다만 업그레이드 시 현재 파일이 새 ISO payload와 바이트 단위로 완전히 일치하면 해당 파일만 신뢰하고 기존 복구 지점을 거쳐 새 버전을 적용한다. 다른 관리자 수정은 계속 거부하며, 수동 `--restore`에는 이 예외를 적용하지 않는다.

`manifest.json`은 산출물 추적 자료이며 단독으로 실환경 PASS를 의미하지 않는다. 지원 매트릭스의 실제 PASS/FAIL은 Actions 결과와 각 VM의 설치·RPC·프로세스 작업 증거를 함께 기록한다.

## 런타임과 안전성

- QGA 6.2의 CLI whitelist/blacklist, INI 및 literal sysconfig RPC 설정도 보존형으로 처리한다. 다른 RPC 제한이나 관리자 설정을 제거하지 않는다.
- Rocky 8의 pidfd_open syscall이 없는 커널은 고정한 `/proc/PID` 디렉터리 FD에 pidfd_send_signal을 사용한다. PID 숫자만으로 재조회·신호 전송하는 fallback은 제공하지 않는다.
- 목록의 systemd 서비스 매핑은 manager 속성이 아닌 `*.service` unit을 조회한다.
- Windows 작업 전 해시 검사를 시작하기 전에 PowerShell 진행 출력을 끄고 UTF-8을 설정한다. 한국어 모듈 로딩 CLIXML 때문에 성공 JSON이 버려지는 문제를 방지한다. 양쪽 출력의 엄격한 인코딩·크기·JSON 검사는 유지한다.
- 읽기 요청은 실행 전 부모 채널이 닫힌 경우 자기 marker만 정리한다. dispatch 이후 결과가 불명확하면 marker를 보존한다. 종료·재시작은 자동 재실행하지 않으며 게스트의 영속 journal을 읽어 결과를 조정한다.
- Cloud/Mold Agent가 호스트 flock을 획득하지 못한 경우는 dispatch 전 `BUSY/NOT_STARTED`로 반환한다. timeout·응답 유실은 계속 `UNKNOWN`으로 보존한다.

Windows QGA는 Session 0의 LocalSystem 서비스이다. 데스크톱 로그인은 프로세스 조회·작업의 전제 조건이 아니다. 실제 검증에는 로그인 전 사용자 부재, QGA 서비스, 목록 및 일회용 프로세스/서비스의 실제 후조건을 함께 기록한다.

최종 Actions·설치·RPC·작업 및 제한 범위는 [Q6 검증 기록](validation/qemu65/README.md)에 정리한다. 전체 Cloud E2E와 사용자 승인 방식의 실제 FT 체인은 C7이다.
