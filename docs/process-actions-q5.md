# Q5 프로세스 변경 실행기

상위 Epic: ablecloud-team/ablestack-cloud#1170. 구현 이슈: ablecloud-team/ablestack-qemu-exec-tools#64.
C1 계약 기준: Cloud 7573322eb7fe81fb7a42566e6e8ce4eb32e38acf.
분기 기준: PR #72의 769cbf1752fa80171accf51996c44e46da785df2. 기존 미병합 변경을 누적한다.

## 실행 범위

- Linux는 pidfd로 대상을 고정하고 boot ID/PID/start ticks를 검사한 후 TERM 또는 KILL을 전달한다. pidfd가 종료를 확인해야 성공한다.
- Windows는 native process handle과 FILETIME으로 대상을 고정한다. 강제 종료만 지원하며 일반 종료는 UNSUPPORTED_ACTION이다. 일반 종료를 강제 종료로 대체하지 않는다.
- systemd/SCM은 서비스 설정 해시, 원래 실행 신원, 공유/종속 영향과 보호 대상을 검사한다. 정지 확인 후 시작하고 새 실행 신원 및 active/Running을 확인한다. 일반 프로세스 command line 재실행은 제공하지 않는다.
- 공유 서비스 PID와 종속/자동 트리거 영향이 있는 서비스는 보수적으로 거부한다. OS/QGA/helper 핵심 대상은 보호한다. Windows PowerShell도 helper 보호를 위해 종료를 거부한다.
- 성공은 특정 대상의 종료 또는 서비스 실행 상태 검증이다. 애플리케이션 자체의 readiness나 서비스 관리자의 자동 재생성 금지를 의미하지 않는다.

## 영속성과 불명 상태

게스트 root/Administrators 전용 journal에 VM binding, 최대 placement generation, request/operation identity, 실행 전 intent 및 결과를 atomic replace/fsync(write-through)로 남긴다. 동일 요청은 저장 결과만 반환한다. 동일 requestId/operationId의 다른 내용은 REQUEST_CONFLICT다.

응답 유실, 타임아웃, dispatch 이후 실패는 UNKNOWN/MAY_HAVE_RUN이다. operation.get만 허용하며 변경 명령을 다시 보내지 않는다. 같은 boot에서 신호 반환 후 대상 소멸 또는 start 반환 후 새 서비스 신원을 관측한 경우만 읽기 재조정으로 성공을 확정한다. intent만 남았거나 재부팅 후에는 UNKNOWN을 유지한다. 미해결 작업은 다음 변경을 막는다.

기록은 자동 삭제하지 않는다. 30일 결과/90일 tombstone 계약의 최소 보존 기간을 초과해 보존하며 UNKNOWN도 영구 보존한다. VM별 4096개 또는 16MiB 한도에서 fail closed한다. 운영용 보존 기간 경과 정리와 관리자 UNKNOWN 해제 절차는 별도 설계 전까지 제공하지 않는다. journal을 삭제해서 운영 재시도를 허용하면 안 된다.

## Cloud C5 연결 경계

`vm_exec --process-protocol 1.0 --request-json <0600 file>`의 standalone 변경은 PERMISSION_DENIED다. C5 root Agent가 실제 lifecycle fence를 유지하는 동안만 다음 고정 인자를 사용할 수 있다.

```
--cloud-action-context <0600 reservation file> --cloud-action-guard-fd 9
```

context 필드는 schemaVersion, authority, requestId, operationId, lifecycleFenceHeld=true, ownerPid, ownerStartTicks, hostBootId, expiresMonotonicNs다. root 소유 단일 링크 파일, 살아 있는 root ancestor 신원, host boot, monotonic 유효기간(최대 95초), FD 9 VM flock와 부모 채널을 검사한다. 이 파일 자체가 분산 lifecycle fence를 만들지는 않는다. C5가 Cloud DB 예약/현재 배치/권한/펜스를 먼저 보장해야 한다.

호스트는 도메인 UUID/실행 상태/job/block job을 확인하고 작업용 스크립트와 helper의 SHA256 전체 묶음을 승인 카탈로그와 대조한다. 서로 다른 ISO 버전의 파일을 섞거나 미등록 묶음을 실행하지 않는다. 작업 전 VM별 marker를 남기며 응답 불명일 때 유지한다. 4개 active action slot과 Q1 transport admission을 사용한다. UNKNOWN guest 작업의 전역 admission 및 이동/재부팅/Cloud 장애 복구는 C5 통합 검증 대상이다.

Cloud global `vm.process.management.enabled=false` 및 allowedActions=[]는 그대로 유지된다. 이번 PR은 Cloud 변경 API/UI 활성화를 제공하지 않는다.

## 설치

Actions의 Process action adapters workflow가 Linux static launcher, Windows native DLL/테스트 fixture/MSI 및 ISO를 만든다. ISO의 install-linux.sh는 기존 RPC/read 설정과 함께 action installer를 실행한다. SELinux에서는 별도 ablestack_process_action_t만 제어 권한을 가진다. QGA 도메인 자체에 signal/service mutation 권한을 추가하지 않는다. Rocky 9/10의 service/system 권한 클래스 차이를 정책에 반영했다.

Windows MSI 1.1.0에 실행 스크립트와 DLL을 포함한다. journal은 MSI 밖 ProgramData에 보존된다. Linux action-only 설치는 기존 QGA 수동 설정/읽기 실행기를 유지할 때 사용할 수 있다.

## 검증 범위

자동 테스트: Linux 실제 pidfd 종료/중복/신원 불일치/boot 불일치/UNKNOWN/읽기 재조정/세대/보호 대상, 호스트 standalone 차단/예약 symlink 차단/설치 업그레이드 rollback, Windows native 신원/강제 종료/중복/SCM 재시작, 기존 Q1/Q4 회귀 및 C1 schema.

실제 VM: Rocky 10.2 i-2-15-VM(SELinux Enforcing), Ubuntu 26.04 i-2-28-VM, Windows Server 2025 i-2-27-VM. 격리된 시험 프로세스/서비스만 사용한다. Cloud 예약 통합 전이므로 게스트 실행기는 관리자 QGA 검증 경로로 호출한다. 전체 Cloud mutation API/RBAC/UI 경로의 PASS로 간주하지 않는다.

Rocky 최초 재시작 시 EL10 system:stop 거부로 UNKNOWN이 남았다. 실패 journal은 /root/q64-actions/first-test-journal.original.json에 보존하고 해당 시험 fixture의 상태만 분리한 뒤 수정 정책으로 재검증했다. 운영용 UNKNOWN 자동 해제 기능으로 처리한 것이 아니다.

Windows 게스트 시각과 호스트 시각의 차이를 관측했다. C5는 snapshot 수신 시점의 monotonic freshness를 함께 보장해야 하며 guest observedAt을 host wall clock과 직접 비교해 안전성을 추론하면 안 된다.

## C5 시계 경계 보완

Cloud/호스트가 snapshot observedAt을 정규화하므로 guest wall clock과 비교해서는 안 된다. C5는 snapshot cache의 monotonic TTL과 전송 직전 배치 재검사를 수행하고, 호스트는 root Agent reservation의 monotonic deadline을 검증한다. guest adapter는 observedAt 형식과 멱등 digest를 보존하지만 guest wall clock으로 재판정하지 않는다. 시계가 다른 Windows VM의 실제 Cloud API 검증에서 발견한 STALE_SNAPSHOT 오거부를 해소한다. PID/boot/시작 신원 검사는 그대로 유지한다.
