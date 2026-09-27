# Rocky SELinux 프로세스 조회 보완

Q4 #63 / 선행 upstream PR #70(60ce1a3)에서 분기한다. Q1~Q4를 합친 기준을 유지하고 기존 PR을 먼저 병합하지 않는다.

## 권한 경계

QGA virt_qemu_ga_t에는 일반 /proc 읽기나 systemd 관리 권한을 추가하지 않는다.
정적 native process-read-launcher를 실행할 때만 ablestack_process_read_t로 전환한다.
launcher는 root, 고정 --request-base64 인자만 받으며 경로/명령/인터프리터 옵션을 받지 않는다.
상속 FD와 환경을 제거하고 /usr/bin/python3 -I -B 및 고정 설치 수집기만 실행한다.
호스트는 수집기와 launcher 각각의 SHA256을 대조한다.

새 도메인은 procfs 정보, Python 라이브러리, 로컬 passwd, systemd private socket 및 status 조회를 허용한다.
EL10의 manager system:status는 optional CIL 블록으로 처리한다. 서비스 start/stop/reload, ptrace,
외부 네트워크, 일반 파일 쓰기나 다른 도메인 프로세스에 대한 신호 권한은 추가하지 않는다.
자신이 만든 systemctl 자식의 시간 제한 정리에는 같은 도메인 signal/sigkill이 필요하다.
/proc 텍스트는 binary read 후 decode하여 Python의 불필요한 isatty/ioctl 시도를 피한다.

이 정책은 고정된 읽기 코드와 root 소유 설치 파일을 함께 신뢰한다. 새로운 동작이나 임의 명령을
launcher에 추가하면 권한 경계를 다시 검토해야 한다. 종료/재시작 Q5의 실행 도메인으로 재사용하지 않는다.
정책 개념 참고: https://github.com/SELinuxProject/selinux-notebook/blob/main/src/domain_object_transitions.md

## 설치·복구

GitHub Actions confined-process-reader artifact의 ISO를 읽기 전용으로 마운트한 뒤:

```sh
bash /mnt/iso/process-management/install-linux.sh
```

Python3/QGA/policycoreutils/semanage가 기존 OS에 있어야 하며 외부 패키지 저장소를 사용하지 않는다.
기존 QGA 설정 보존형 복구와 전용 read 정책 설치를 수행한다. 설치 메시지를 feature READY로 해석하지 않는다.
Ubuntu/SELinux Disabled는 기존 Python 수집 경로를 사용한다. Rocky 호스트 실행기는 matching launcher도 필요하다.

정책 설치 상태는 root 0700 /var/lib/ablestack-process-read에 저장한다. 원래 collector bytes/mode,
설치 파일 hash 및 작업 단계를 기록하며 실패 시 원래 파일·매핑·모듈 상태로 되돌린다.
기존의 같은 이름 모듈 또는 대상에 적용되는 관리자 fcontext 규칙을 덮어쓰지 않는다.
설치 후 수정된 파일은 자동 복구로 덮어쓰지 않고 오류를 반환한다. 같은 payload 재실행은 idempotent하다.
새 payload는 기존 복구 지점으로 되돌린 다음 설치하고 최초 원본 복구 지점을 유지한다.

조회 정책만 제거하고 원래 collector로 되돌리려면:

```sh
python3 /usr/libexec/ablestack-qemu-exec-tools/agent_policy/read_policy.py --restore
```

QGA RPC 설정·Q2 probe 정책·SELinux Enforcing은 이 제거 작업으로 바뀌지 않는다.
최신 Rocky 호스트 실행기는 제거된 launcher를 필요로 하므로 복구/제거 상태에서 조회 실패를 예상해야 한다.
진행 중 조회가 없는 유지보수 구간에 설치/제거한다. 이후 ISO 재실행으로 재설치한다.

## 검증과 배포 범위

Actions에서 musl 정적 launcher 및 ISO를 생성하고, Rocky 9/10 컨테이너 정책 저장소에
semodule -N으로 컴파일한다. 이는 실제 VM 동작 검증과 다르다.
호스트에는 source artifact의 process_list_host.py/collector와 같은 run의 launcher를 함께 배포한다.
기존 Windows DLL/PS1은 보존한다. Linux 게스트와 호스트의 collector bytes가 일치해야 한다.
전체 RPM/DEB 배포 및 모든 OS 버전 설치 승인은 Q6 범위이며 이번 변경으로 완료되었다고 간주하지 않는다.
실제 Rocky Enforcing 조회·복구·재설치·권한 거부 결과와 Ubuntu/Windows 회귀 결과는 PR에 기록한다.
