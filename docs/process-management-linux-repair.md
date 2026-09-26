# Linux 프로세스 관리 QGA 정책 복구

상위: ablecloud-team/ablestack-cloud#1170 · Q2: ablecloud-team/ablestack-qemu-exec-tools#61

## 정책과 상태

`agent_policy_fix --policy process-management --check|--apply --json`은 실제 QGA
서비스 PID, 실행 인자, QGA_CONF 환경과 `--dump-conf` 결과를 확인한다.
기존 `--policy full` 및 무인자 동작은 유지한다. process-management는 명시적 선택이다.

8개 실행/file RPC와 libvirt 연결·조회에 필요한 guest-info, guest-ping,
guest-get-osinfo, guest-sync, guest-sync-delimited를 허용한다. 기존 allowlist의
다른 명령과 blocklist의 다른 차단은 유지한다. 이미 허용되어 있으면 파일과 QGA
서비스를 변경하지 않는다. Rocky 사용자가 수동으로 설정한 allowlist를 설치 결과로
기록해서는 안 된다. Ubuntu/Windows 기본값으로 이미 활성화된 상태도 동일하다.

자동 수정 대상은 실제 서비스가 사용하는 `/etc/sysconfig/qemu-ga`의
FILTER_RPC_ARGS 및 명시적 `--config`/QGA_CONF INI이다. 사용자 정의 ExecStart,
중복/동적 환경 변수, 실행 인자와 파일의 불일치, 제한의 출처를 확정하지 못하는
기본 INI는 CHECK_FAILED로 처리한다. 임의로 서비스 전체를 덮어쓰지 않는다.

변경 전 파일은 `/var/lib/ablestack-qemu-exec-tools/process-policy/backup-*`에
SHA256과 함께 저장한다. 재시작/적용 검증 실패 시 원본을 복원한다.
`--restore BACKUP_ID`는 적용 이후 관리자가 다시 변경한 파일을 덮어쓰지 않는다.
ROLLBACK_REQUIRED는 자동 복원도 실패했음을 뜻하며 관리자 조치가 필요하다.
`last-result.json`은 마지막 실행 결과이며 Cloud READY의 근거가 아니다.

- POLICY_REPAIR_REQUIRED: 설정상 필수 RPC 부족 (종료 코드 5).
- POLICY_CONFIGURED_PENDING_HOST_VERIFY: 설정 확인/수정 성공. 호스트 검증 필요.
- RESTORED_PENDING_HOST_VERIFY: 명시적 복원 후 호스트 검증 필요.
- CHECK_FAILED: 설치 전제, 설정 판독, 재시작 또는 복원 실패 (종료 코드 4).
- 모든 게스트 결과에서 featureReady=false를 유지한다. Q3 어댑터 준비와 다르다.

## 오프라인 실행

ISO를 게스트에 읽기 전용으로 마운트한 후 게스트 관리자 셸에서 실행한다.

```sh
cd /mnt/ablestack-tools
sha256sum -c SHA256SUMS # 전용 repair ISO에 포함
bash install-linux.sh --mode process-management
```

수정할 QGA 자신의 guest-exec로 설치/재시작하지 않는다. SSH/콘솔 관리자 셸을
사용한다. QGA 연결 단절 시 설치 결과와 재연결 결과를 호스트에서 따로 확인한다.
cloud-init, 네트워크, 계정, 비밀번호, DHCP 설정은 이 모드의 변경 대상이 아니다.
SELinux/AppArmor를 끄거나 광범위 허용 정책을 추가하지 않는다.

전용 repair ISO는 기존 QGA와 Python 3가 설치되고 QGA가 실행 중인 Linux VM을
위한 최소 페이로드다. 설치 중 외부 저장소에 접속하지 않는다. 둘 중 하나가
없으면 OFFLINE_PREREQUISITE_MISSING 또는 QGA prerequisite 오류로 중단하며,
해당 배포판의 오프라인 설치 미디어로 먼저 준비해야 한다. 기존 전체 Tools ISO의
일반 설치 경로와 구분한다. 전체 ISO에도 동일한 repair 페이로드를 포함한다.

RPM/DEB 설치 시 `ABLESTACK_TOOLS_MODE=process-management`를 명시하면 post-install은
정책 복구만 실행하고 그 종료 코드를 전달한다. 일반 패키지에는 cloud-init 등
기존 의존성이 있으므로, 기존 VM의 정책 복구에는 전용 ISO 경로를 우선 사용한다.

## 호스트 검증

QGA 재연결 후 현재 호스트에서 root로 아래를 실행한다.

```sh
python3 vm_process_verify.py i-2-15-VM
```

현재 domain UUID, Running, libvirt job 및 QMP block job, 공통 VM 작업 flock/lease를
확인한 후 guest-info의 8개 RPC와 고정 printf 실행을 검사한다.
전용 0700 `/var/lib/qemu-ga/ablestack-process-probe`의 임의 파일로
open/write/flush/seek/read/close를 수행하고 삭제한다. 정상 경로 20초, 정리 별도
6초 제한이다. 실패해도 handle close와 파일 삭제를 시도하고 정리 결과를 기록한다.
RPC_PROBES_PASSED도 Q3 process adapter 또는 Cloud capability READY를 의미하지 않는다.
SELinux/AppArmor 때문에 실제 파일/실행이 차단되면 실패로 기록하고 정책을 자동 완화하지 않는다.

## 검증 범위

지원 목표: Rocky 9/10.2, Ubuntu 22.04/24.04/26.04. 지원 목표는 실환경 인증과 다르다.
Windows 설치는 Q2 대상이 아니며 기존 기본 설정의 회귀 확인만 한다.
Python 단위 테스트는 수동 설정 보존, 추가 허용, 차단 보존, 멱등성, 모호한 설정 거부,
백업/복원, 재시작 실패 및 동시 관리자 변경 보호를 검증한다.
실환경·빌드 증거는 이 PR의 검증 기록에 별도로 기재한다.