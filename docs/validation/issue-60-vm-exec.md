# #60 vm_exec 구현·직접 배포·검증 기록

## 기준과 구현

- 이슈: https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/60
- qemu base: 6c440e61ec80108ec9d59ef21b095d53bc9cf539
- C1: Cloud 31c3b36768a9a12d588dbd7a01f5217a5b026090
- Shell 진입점 + Python 3.9 표준 라이브러리 transport로 분리.
- argv/JSON, 설치 prefix, deadline, admission, child 회수, 출력 상한, signal/null/UNKNOWN 보강.
- protocol fixture는 검증하되 Q4/Q5 operation은 fail-closed. 실제 프로세스 관리 API 완성 아님.

## 로컬 검증

- bash -n, shellcheck 통과.
- tests/vm_exec_test.py: 14 test method 통과(모드별/오류별 subcase 포함).
- tests/vm_exec_contract_test.py: C1 request fixture 11개 입력 및 응답 schema 검증 통과.
- 소스/RPM/DEB/make 설치 디렉터리 구조를 재현하여 library loading 확인.
- 실제 RPM/DEB clean install은 미실행. 사용자 요청에 따라 패키지 빌드 대신 source를 직접 배포했다.
  RPM/DEB metadata에는 Python 의존성을 추가했으며 패키지 재설치 gate는 Q6에서 별도 검증한다.

## 원격 preflight

| 대상 | 호스트 | VM | 게스트 OS | QGA |
|---|---|---|---|---|
| Linux | 10.10.31.1 | i-2-15-VM | Rocky Linux 10.2 x86_64 | 10.1.0 |
| Windows | 10.10.31.3 | i-2-27-VM | Windows Server 2025 x86_64 | 110.2.3 |

두 VM은 Running, libvirt job=None, query-block-jobs=[], VM operation 잔존 lease 파일 없음.
guest-info에서 guest-exec/status 및 guest-file-open/close/read/write/seek/flush 모두 enabled=true.
Rocky 10.2는 C1의 Rocky 9.x 제품 지원 매트릭스와 다르며, 이번 통과는 transport 실증 범위에 한정한다.
인증 정보는 저장하지 않는다. 접속은 WSL SSH 22번 포트에서 수행했다.

## 배포 및 rollback

- 설치된 package version: ablestack-qemu-exec-tools-0.9.5-1.el9.el9.noarch (aspkg 조회).
- 기존 /usr/bin/vm_exec: mode 0644, /usr/local/lib 고정, BOM 포함.
- 교체: /usr/bin/vm_exec (0755), /usr/libexec/ablestack-qemu-exec-tools/vm_exec.py (0644).
- 같은 디렉터리의 임시 파일로 설치 후 rename, restorecon 적용. service 재시작 없음.
- 31.1 backup: /root/vm-exec-issue60-aCPrtlcT
- 31.3 backup: /root/vm-exec-issue60-8qb1Ouvx
- backup의 vm_exec.before가 원본이며 vm_exec.py.before가 있으면 기존 library도 보존.
- 원본 wrapper SHA256: 2c17288fb2223e12bedf524e5c5d1cb544f273b666a5c160d31fe2e2b02456ac
- 배포 wrapper SHA256: 3db6c33ba290a64c968deaa412dea41911a117979db2bc2809e14aff5a4a8e26
- 배포 library SHA256: d82b525ded81fa6bffc38d500ee7ac2726a86a96b0637e58c68060011e822481
- 최종 빈 table header 입력 검증을 추가하고 두 호스트에 재배포·재검증했다.
  직전 버전 backup: 31.1 /root/vm-exec-issue60-Q6Jescbu, 31.3 /root/vm-exec-issue60-ZRZ9vINW.
  패키지 원본 복원에는 위 최초 backup을 사용한다.

rollback 시 source override를 해당 backup의 원본으로 복원하고 restorecon 후 guest-ping·VM 상태를 재확인한다.
원래 vm_exec.py가 없었으면 새 파일만 제거할 수 있다. 원본 wrapper 0644도 보존되어 있으므로
정확한 원상 복구와 기존 실행 권한 결함 재발을 구분해야 한다.
패키지 version은 올리지 않은 의도적인 source overlay이며 추후 패키지 재설치로 덮어써질 수 있다.
31.2에는 배포하지 않았다.

## 실제 기능 검증

각 VM에서 6개 확인 지점 통과:
1. Linux 한글/공백/따옴표/$/역슬래시 argv 보존 및 stdout.
   Windows는 PowerShell EncodedCommand를 사용한 특수문자 출력 확인이며,
   Windows 네이티브 프로그램의 임의 argv 인용 전체를 검증한 것은 아니다.
2. stdout/stderr 분리, guest exit 7 → host exit 0 + state FAILED.
3. Linux 자기 테스트 shell의 SIGTERM → exit_code=null/signal=15.
   Windows는 cmd.exe 직접 실행 확인(Unix signal 동작을 주장하지 않음).
4. sleep 2초에 host budget 0.5초 → 약 0.54초에 host exit 3/UNKNOWN/PID 보존.
5. 3초 후 guest-exec-status로 해당 timeout 테스트 프로세스 exited=true 확인/회수.
6. 4096바이트 출력과 128바이트 상한 → OUTPUT_LIMIT, 성공 오인 없음.

모든 테스트는 새로 생성한 일회성 프로세스만 사용했다. VM reboot/stop/기존 workload kill 없음.
배포 전후 virsh VM inventory diff 없음, mold-agent active, 두 VM Running,
query-block-jobs=[], guest-ping 성공. QGA 정책 변경/ISO 설치는 하지 않았다.

WSL 원본 증거: /home/ablecloud/work/validation/qemu-issue60/
- preflight-linux.txt / preflight-windows.txt
- deploy-linux.txt / deploy-windows.txt
- deploy-final-linux.txt / deploy-final-windows.txt
- live-linux.jsonl / live-windows.jsonl
- deployments.txt

추가 범위: 정식 package clean install, Rocky 9/Ubuntu matrix, capability·ISO repair,
process.list/terminate/kill/service.restart, Cloud lifecycle fencing/journal은 각각 후속 이슈의 gate다.
