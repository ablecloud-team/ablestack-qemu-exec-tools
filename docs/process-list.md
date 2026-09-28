# Q4 프로세스 목록 어댑터

상위 이슈: ablecloud-team/ablestack-qemu-exec-tools#63, Cloud Epic #1170.
기준: Q1 #67 + Q2 #68 + Q3 #69 통합 68dc5385d95629c0320a69696d246fa31ed92752.
C1 계약: Cloud 7573322eb7fe81fb7a42566e6e8ce4eb32e38acf.

## 실행과 범위

루트 소유 0600 요청 파일을 `vm_exec --process-protocol 1.0 --request-json FILE`에 전달한다.
`readRequest/process.list`만 활성화한다. 임의 명령/추가 요청 키는 거부한다.
VM UUID에서 도메인 이름을 찾고 UUID를 재확인한다. VM별 flock, 기존 lease,
libvirt job/block job을 검사한 뒤 고정 경로의 설치 수집기 SHA256을 확인하고 QGA로 실행한다.
응답의 VM/boot/PID/startTicks와 허용 필드를 다시 확인한다. CPU는 동일 PID/start identity의 두 CPU 시간 샘플 차분을 실제 관측 시간으로 나눈 한 코어 100% 기준 값이다. 새 프로세스·관측 부족·카운터 감소는 null이다. allowedActions는 항상 빈 배열이다.
종료/재시작은 Q5, Cloud 배치 세대 검증·부모 guard FD·공유 admission·API 연결은 C4 범위다.
현재 hostUuid/placementGeneration은 루트 호출자가 제공한 문맥이다. Cloud의 신뢰 가능한 최신 배치 검증으로 해석하면 안 된다.
capability READY를 활성화하지 않으며 Q1의 다른 요청은 계속 fail closed다.

호스트 관측 5초, 게스트 관측 최대 3초, RPC 최대 3초로 제한한다.
UTF-8 JSON 최대 1MiB/10,000행, 스냅샷 유효기간 10초다.
실행 전 `/run/ablestack-vm-operations/VM_UUID/q4-read-REQUEST_UUID.json`을 기록한다.
정상 완료 후에만 제거하고 UNKNOWN/호스트 중단 시 남겨 후속 요청을 BUSY로 차단한다.
Q4는 자동 lease 복구를 제공하지 않는다. 관리자/C4가 해당 guest-exec PID 종료를 확인한 후 해당 파일만 정리해야 한다.
PID를 받기 전 전송 결과가 불명확하면 재부팅 또는 별도 종료 증거 없이 자동 삭제하지 않는다.

## 게스트 수집

- Linux: /proc stat 전후 startTicks 대조, 로컬 passwd UID 이름, RSS 페이지 수.
  systemd MainPID를 서비스와 연결한다. 자식 worker 전체의 cgroup 귀속은 현재 범위 밖이다.
- Windows: CIM 목록에 native OpenProcess/GetProcessTimes identity를 결합한다.
  owner는 네트워크 계정 조회가 필요 없는 SID다. SCM 공유 PID를 여러 서비스로 보존한다.
- 서비스 hash는 명령/계정/의존 관계/제어 가능 속성의 정렬된 JSON SHA256이다.
  명령문과 환경 변수는 응답에 포함하지 않는다. systemd 실행 PID/시각은 hash에서 제외한다.
- 접근 거부/사라진 프로세스/서비스 조회 실패는 PARTIAL이다. 시간/행/출력 상한은 truncated=true다.
  Linux 단일 문자 state와 Windows Running은 OS별 표현이다.

## 설치

Linux process repair ISO staging에 `process_list_linux.py`를 포함하고 설치 스크립트가
`/usr/libexec/ablestack-qemu-exec-tools/process/`에 배치한다.
Windows native GetProcessTimes/owner SID 보조 DLL은 GitHub Actions에서 .NET Framework csc로 미리 빌드한다. 조회 시 C# 컴파일을 수행하지 않는다. 호스트가 PS1(LF 정규화)과 DLL SHA256을 각각 검사한다.
Windows MSI는 `C:\Program Files\ABLESTACK Process Tools\ProcessList.ps1`를 배치한다.
호스트 lib 디렉터리의 collector와 게스트 collector가 일치해야 실행한다.
Windows 도구 MSI 설치는 REINSTALLMODE=amus로 패키지 소유 파일을 갱신한다. QGA vendor MSI에는 이 옵션을 적용하지 않는다.
프로세스 수집을 위해 SELinux/AppArmor 정책을 넓히거나 QGA allowlist를 덮어쓰지 않는다.

## 검증

`tests/process_list_test.py`: PID 재사용, Unicode, 종료/권한 거부, 서비스 조회 실패,
서비스 hash 안정성, 대량/출력 상한, 잘못된 VM/중복 identity, 명령문·action 유출 거부.
`tests/process_list_windows_test.ps1`: 독립 부모 PID의 native startTicks와 SCM 매핑을 대조한다.
Windows CI는 cold WMI 초기화로 예산이 끝나면 자식 exit=3 확인 후 새 조회를 한 번만 검증한다. UNKNOWN QGA 실행을 자동 재시도하지 않는다.
GitHub Actions `process-list.yml`에서 선행 테스트와 C1 fixture, Windows 실제 수집/스키마,
소스 아카이브와 Windows MSI 빌드를 수행한다. 전체 Cloud 빌드는 수행하지 않는다.

실제 VM 검증 결과와 빌드 run은 PR에 기록한다.
Rocky 10.2 SELinux Enforcing에서는 QGA 프로세스 도메인의 /proc·systemd 접근 제한 때문에
제한된 목록(PARTIAL)을 반환한다. 이는 전체 Linux 프로세스/서비스 지원 완료를 의미하지 않는다.
별도 최소 권한 설계 없이 QGA 도메인에 광범위한 읽기/제어 권한을 부여하지 않는다.
