<!--
Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.  See the License for the
specific language governing permissions and limitations
under the License.
-->
# Epic 1199: 등록 실행 프로파일 재시작 계약

Cloud #1178 / Qemu #66. 기존 process protocol 1.0 목록·종료·서비스 재시작은 유지한다. 일반 프로세스 재시작과 프로파일 조회만 opt-in 1.1을 사용한다. 지원 범위와 운영 절차를 아래에 정의하며, 실제 배포 결과는 [Cloud 최종 검증 기록](https://github.com/dhslove/ablestack-cloud/tree/codex/process-profile-epic1199/docs/validation/vm-process-1199)에 기록한다.

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

## 운영 및 복구

- Global `vm.process.management.enabled`를 명시적으로 활성화한다. 기본 Admin만 프로파일 등록·승인·폐기 및 재시작을 사용할 수 있다. 기능 비활성화는 서버에서 조회/변경을 모두 거부한다.
- Cloud 운영 문서의 Linux/Windows JSON 예제의 UUID·경로를 실제 VM과 고정 foreground 프로그램에 맞춘다. 먼저 관리자가 해당 프로그램을 실행한 뒤 등록 도구의 `--bind-pid` 또는 `-BindPid`에 **현재 PID**를 전달한다. Cloud에는 실행 명령을 입력하지 않는다.
- 정의를 변경하면 버전을 올려 다시 등록·승인한다. 자동 시작을 설정하지 않았으므로 게스트 재부팅 뒤에는 관리자가 해당 workload를 시작하고 현재 identity를 다시 바인딩해야 한다. VM 클론은 새 vmUuid/프로파일로 등록한다. 호스트 이동에는 재등록이 필요 없다.
- Linux 환경 참조는 systemd EnvironmentFile이고 Windows는 JSON 문자열 map이다. 읽기 실패·잘못된 형식·쓰기 ACL/경로 변조는 **기존 PID를 종료하기 전에** 거부한다. 환경 값은 파일에서만 관리하며 API/감사/운영 로그에 복사하지 않는다.
- `FAILED / NOT_STARTED`: 기존 대상은 변경되지 않았다. 관리자에게 정의·해시·권한·감독자 설정 확인을 요청하고 수정 후 새 목록으로 명시적으로 실행한다.
- `PARTIAL / OLD_EXITED_NEW_NOT_STARTED`: 기존 PID가 종료되고 신규 PID가 없다. **자동 재실행하지 않는다.** Linux `systemctl status ableprofile-<ID>.service` / `journalctl -u ...`, Windows `\ABLESTACKProfiles\<ID>`의 LastTaskResult 및 고정 환경 파일을 게스트 관리자가 확인한다. 수정·관리자 시작 후 실제 PID를 다시 바인딩한다.
- `UNKNOWN / MAY_HAVE_RUN`: UI 상단 **결과 확인**은 읽기 복구만 수행한다. 동일 requestId도 stop/start를 재전송하지 않는다. 원래 작업의 journal과 감독자/프로세스 identity를 관리자와 대조해 결과를 확정하기 전 새 실행 요청을 보내지 않는다. 호스트·게스트 UNKNOWN 기록을 TTL로 삭제하지 않는다.
- 재기동 직후 목록 조회가 제한 시간을 넘겨 남긴 `q4-read-lease`는 Mold Agent가 VM flock을 잡은 상태에서 원래 소유자 종료와 QGA 완료 응답을 확인한다. 요청 UUID·VM UUID가 일치하고 종료 코드 0·비절단·정상 UTF-8 JSON인 **읽기 응답만** 증거로 정리한다. 조회를 재전송하지 않고 종료·재시작 UNKNOWN 기록은 정리하지 않는다. 살아 있는 소유자, 응답 유실·변조·불일치·이미 소비된 응답은 보존한다. QGA의 완료 응답은 한 번 읽으면 소비되므로 운영자가 별도로 `guest-exec-status`를 읽을 때는 증거를 저장하고 원래 기록과 대조해야 한다. 증거가 없는 기록을 일괄 삭제하지 않는다.
- **폐기**는 Cloud 승인을 철회하고 감사 이력을 보존한다. 실행 중 프로그램은 계속 실행된다. 게스트 감독자/파일 삭제는 관리자가 폐기 후 별도 수행한다. 같은 버전은 다시 승인할 수 없다.

## 설치·업데이트 및 되돌리기

호스트 RPM과 Rocky/RHEL 8·9·10, Ubuntu 22·24·26, Debian 12·13, Windows 11·2019·2022·2025 다중 ISO는 동일 GitHub Actions 실행에서 만든다. Windows Process Tools MSI 버전은 1.2.0이다. 설치 전후 QGA/고정 adapter 경로와 실제 파일 해시를 확인한다.

호스트의 승인 catalog는 **전체 파일 묶음**으로 이전 게스트를 계속 허용한다. 개별 파일을 다른 릴리스와 섞으면 거부한다. Windows 준비 상태 검사는 고정 4개 파일의 해시를 읽은 뒤 일치한 승인 묶음만 다시 검증·로드하므로 catalog가 커져도 전체 catalog를 명령줄에 넣지 않는다. 두 단계 사이에 파일이 바뀌면 거부한다.

Cloud는 S12 멱등 migration을 완료해야 하며 기존 4.23에도 적용된다. 기존 DB를 새로 만들거나 승인 이력을 지우지 않는다. 테스트 배포의 되돌리기는 백업 JAR/정적 파일을 복원하고 이전 whole-bundle catalog가 있는 패키지를 사용하는 절차다. DB 테이블은 되돌리기 때 삭제하지 않는다. 이전 1.0 게스트의 목록·종료·서비스 재시작은 유지되며 프로파일 기능은 1.1 adapter 설치 이후에 사용한다.

## 검증 범위

12개 Process VM의 실제 기존 PID 종료·신규 identity·계정/cwd/환경 참조·동일 요청 중복 방지를 확인했다. Linux/Windows 시작 실패, Windows 잘못된 환경 참조, Linux 파일 변조, 다른 VM/버전/미승인/폐기/권한/Global OFF 거부를 확인했다. Linux 실제 응답 유실은 호스트의 해당 요청 전달 프로세스만 끊은 뒤 읽기 복구로 신규 PID가 한 번만 생성됨을 확인했다. Windows 물리 응답 유실은 실제 VM 검증 범위에 포함하지 않았으며 durable journal 복구는 자동 회귀 검증에 포함한다.

일반·다크 모드의 상단/행/표준 대화상자 배치, 핵심 액션의 첫 파란 버튼, CPU/메모리, PARTIAL의 기존/신규 상태, 갱신 중 테이블 유지를 확인한다. 배포 상태·최종 증거·지원 범위는 최종 검증 기록을 기준으로 판단한다. 이 기능은 foreground 단일 프로세스와 명시적으로 지원하는 실행 계정에 한정한다. 대화형 세션 복원, 자동 daemonization, 자식 트리 전체 종료는 지원한다고 주장하지 않는다.
