<!-- Copyright 2026 ABLECLOUD. Apache-2.0. -->
# Epic 1199: 등록 실행 프로파일 재시작 계약

Cloud #1178 / Qemu #66. 기존 process protocol 1.0 목록·종료·서비스 재시작은 유지한다. 일반 프로세스 재시작과 프로파일 조회만 opt-in 1.1을 사용한다. 현재 개발 단계이며 실제 배포 검증 결과는 별도 검증 문서에 기록한다.

## 운영 모델

1. 게스트 관리자가 고정 실행 파일·argv·작업 디렉터리·실행 계정·환경 파일 참조·검증 조건을 JSON으로 작성한다. Linux는 `python3 /usr/libexec/ablestack-qemu-exec-tools/process/process_profile_linux.py --register <정의.json> --bind-pid <PID>`, Windows는 관리자 PowerShell의 `C:\Program Files\ABLESTACK Process Tools\Register-ProcessProfile.ps1 -Definition <정의.json> -BindPid <PID>`를 사용한다.
2. 등록 도구가 실제 기존 PID의 실행 파일·고정 인자·계정을 확인하고 현재 bootId/startTicks를 root/System·관리자 전용 바인딩 파일에 기록한다. VM UUID를 고정하므로 다른 VM·클론에 그대로 복사하면 사용할 수 없다. 수집한 명령줄을 재실행하지 않는다.
3. Linux는 관리자 전용 `ableprofile-<ID>.service` 정의를 만들며 자동 시작/재시작을 설정하지 않는다. Windows는 `\ABLESTACKProfiles\<ID>`의 트리거 없는 LocalSystem/Session 0 작업을 만든다. Windows 작업은 해시로 승인된 배포 번들의 고정 시작 도구를 호출하고, 시작 도구가 등록 정의를 검증해 shell 없이 프로그램을 실행한다. 대화형 로그인 세션/사용자 암호 재사용은 지원하지 않는다.
4. VM 프로세스 탭의 상단 **실행 프로파일 관리**에서 현재 게스트 버전을 Cloud에 **등록**한 뒤 명시적으로 **승인**한다. 동일 ID·버전은 불변이다. 변경은 게스트 버전을 올리고 다시 등록·승인한다. 새 버전 승인 시 이전 승인 버전은 폐기한다. 폐기는 실행 중 프로세스를 종료하지 않으며 같은 버전을 다시 승인할 수 없다.
5. 승인 프로파일의 바인딩과 현재 목록의 VM/boot/PID/startTicks가 일치하는 행에만 **프로세스 재시작**을 표시한다. 첫 번째 파란 버튼은 선택한 프로세스의 재시작 또는 기존 핵심 액션이다. 버튼은 상단·행·표준 대화상자에 둔다. 갱신은 기존 테이블을 유지한다.

## 프로파일 정의와 권한

- 공통: `id` canonical UUID, 양의 정수 `version`, `vmUuid`, `displayName`, 절대 `executable`, 문자열 배열 `argv` (32개 이하), 절대 `cwd`, `account`, `environmentRef` (경로 또는 null), `verification="identity-and-running"`.
- Linux 계정은 실제 로컬 계정 이름이다. 실행 파일과 모든 상위 경로는 root 소유·일반 사용자 쓰기 금지, 실행 파일 SHA256은 등록 시 고정한다. 환경 참조는 root 소유 0600 systemd EnvironmentFile이다. 등록 시 검증한 파일을 `/var/lib/ablestack-process-actions/profile-<ID>.env`로 복사해 참조하며 SELinux의 기존 action-state 경계를 유지한다. 비밀값 교체는 해당 root 전용 참조 파일을 갱신한다. 환경 파일 내용은 응답·Cloud DB·로그에 넣지 않는다.
- Windows 계정은 `S-1-5-18` (LocalSystem), Session 0이다. 실행 파일·프로파일·환경 파일은 System/관리자 전용 쓰기 ACL이며 재분석 지점은 거부한다. 환경 참조는 관리자 전용 JSON 문자열 map이며 64개 변수/값 4096자 이내이다. TaskScheduler 정의와 시작 도구를 검증한다.
- 프로파일은 foreground 프로세스 한 개의 재시작을 지원한다. Windows 작업 디렉터리도 System/관리자 전용 쓰기 ACL이어야 하며 Linux 작업 디렉터리는 root 또는 실행 계정 소유·다른 계정 쓰기 금지여야 한다. 인터프리터/보호된 시스템 프로세스·자동 복구 감독자·daemonizing workload·임의 사용자 세션 복원은 지원 대상이 아니다. 기존 자식 프로세스 전체 종료를 보장한다고 표시하지 않는다.
- Cloud API는 UUID/버전/REGISTER·APPROVE·RETIRE만 받는다. 실행 파일·argv·secret 값 입력 API는 없다. `listVirtualMachineProcessProfiles`, `manageVirtualMachineProcessProfile`, `restartVirtualMachineProcess`의 권한을 분리하며 기본 Admin만 허용한다. VM 접근 권한과 `vm.process.management.enabled`를 서버에서 확인한다.
- Cloud 테이블 `vm_process_profile`은 VM·ID·버전을 PK로 사용하고 지문·sanitized metadata·상태·등록/승인/폐기 사용자와 시각만 저장한다. argv 값과 환경 값은 저장하지 않는다. Europa S12 named migration은 기존 4.23 설치에서도 재시도 가능하게 실행한다.

## 1.1 wire와 작업 결과

- 조회: `readRequest operation="profile.list" operationId=null`, 10초 이내, 게스트 프로파일 32개 이하. 검증된 metadata/identity만 응답한다. 유효하지 않은 프로파일은 INVALID로 반환하며 승인·실행할 수 없다.
- 변경: 기존 snapshot/identity/authority/reservation + `action="process.restart"`, `service=null`, `profile={id,version,definitionHash}`, 85초 예산. Cloud 승인 row와 VM lifecycle row의 잠금을 유지한 채 Mold Agent의 host flock으로 전달한다.
- 게스트는 고정 정의·버전·VM scope·파일 해시·감독자 설정·바인딩 identity·중복 프로세스 부재를 확인한 뒤 종료한다. 종료 확인 후 start-intent를 fsync하고 고정 감독자를 한 번만 시작한다. 새 identity가 달라지고 안정적으로 Running일 때 SUCCEEDED/VERIFIED/PROFILE_RESTART_VERIFIED를 반환한다.
- `progress={oldProcess,newProcess,newIdentity}`를 별도로 노출한다. 종료 후 확실한 시작 실패는 PARTIAL/PARTIAL/OLD_EXITED_NEW_NOT_STARTED로 표시한다. 불확실한 시작·응답 유실은 UNKNOWN/MAY_HAVE_RUN을 유지한다. FAILED는 실제 변경 전 거부만 뜻한다.
- 동일 requestId/operationId는 기존 durable journal 결과를 조회하며 재실행하지 않는다. 읽기 복구는 기록된 단계·현재 감독자·새 identity를 확인할 뿐 stop/start를 보내지 않는다. UNKNOWN을 TTL로 삭제하지 않는다. 기존 서비스/종료 journal과 같은 게스트 lock을 공유한다.
- host/guest 해시 비교는 기존 whole-bundle 승인 목록을 유지하고 linux-profile/windows-profile 번들을 별도 추가한다. 호스트 업데이트·마이그레이션 시 이전 승인 1.0 번들을 보존하며 서로 다른 번들의 파일 조합은 거부한다. 프로파일 정의는 host UUID에 종속되지 않는다.

## 최종 검증 계획

기존 12개 Process VM (Rocky 8/9/10, Ubuntu 22/24/26, Debian 12/13, Windows 11/2019/2022/2025)에서 패키지·정책·1.0 호환·1.1 프로파일 등록/승인/실행을 검증한다. 실제 PID 종료와 새 PID/시작 identity, 계정·cwd·환경 참조 적용, 중복 방지·미승인·폐기·다른 VM·변조·버전 변경·시작 실패·읽기 복구·마이그레이션·Global OFF·RBAC를 대조한다. 일반/다크 모드에서 상단/행/대화상자 배치와 테이블 유지도 검증한다. Windows CD-ROM은 최종 모두 해제 상태로 유지한다.
