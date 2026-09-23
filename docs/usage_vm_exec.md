# vm_exec 사용법

QGA의 guest-exec/guest-exec-status로 실행 파일과 argv를 전달하는 호스트 도구다.
Shell 진입점(bin/vm_exec.sh)은 같은 설치 prefix의 lib/vm_exec.py를 실행한다.
Python 3.9+ 표준 라이브러리만 필요하며 jq/common.sh/legacy table parser 로딩에 의존하지 않는다.

## 호출 및 호환성

```bash
vm_exec -l rocky-vm --json -- /bin/echo '공백 "quote" $literal'
vm_exec -d windows-vm --json -- 'C:\Windows\System32\cmd.exe' /c 'echo hello'
vm_exec -l rocky-vm /bin/ps aux --table --json
vm_exec -l rocky-vm --json --timeout 2 -- /bin/sleep 5
```

-l/--linux, -w/--windows, -d/--direct 모두 실행 파일을 직접 전달한다.
예전 도움말의 bash/cmd 자동 실행 설명은 실제 구현과 달랐으므로 수정했다.
shell이 필요하면 /bin/sh -c 또는 cmd.exe /c를 명시한다. 호스트 shell eval은 사용하지 않는다.
옵션 뒤 --를 쓰면 이후 --json 같은 문자열도 게스트 argv로 그대로 전달된다.
기존처럼 command 뒤 --json/--table을 붙이는 호출도 유지한다.

- --json: 기존 command/parsed/stdout_raw/stderr/exit_code 유지. 추가 필드는 아래 참조.
- --csv: 기존 PDH-CSV 자료를 csv.reader로 파싱(인용된 쉼표 지원).
- --table / --headers: 공백 표 또는 헤더 폭 기반 표. locale/OS별 프로세스 DTO 대신 사용하지 않는다.
- --out/-o: 게스트 stdout을 바이트 그대로 저장. NUL/비UTF8/끝 개행 보존.
- --exit-code: 텍스트 모드에서 guest exit와 signal 표시.
- --file/-f: UTF-8 파일의 줄마다 shlex argv 파싱, 빈 줄/주석 제외. Unix 인용 규칙을 사용하며 Windows 경로의 역슬래시는 인용한다.
- --parallel: file 모드만, 최대 4 worker. JSON은 입력 순서 NDJSON(한 command당 한 줄). 공유 --out은 거부.
- command 파일: 최대 64 KiB/128개 작업. 각 작업에는 별도 deadline이 적용되며 전체 batch 예산과 같지 않다.

## 제한과 결과

| 항목 | 기본/최대 |
|---|---|
| --timeout | 30초 / 90초 (최소 0.1초) |
| --rpc-timeout | 3초 / 3초 (최소 0.1초, 남은 전체 예산으로 제한) |
| --max-output-bytes | decoded stdout+stderr 합계 1 MiB |
| virsh 응답 | 2×decoded 상한+64KiB, 읽는 중 강제 |
| virsh stderr | 4 KiB, 원문은 사용자 오류에 노출하지 않음 |
| 요청 | UTF-8 JSON 64 KiB |
| host admission | /run/ablestack-vm-exec/slot-N.lock, 최대 8개 |
| poll 간격 | 250ms → 500ms → 1초 |

시간은 monotonic clock으로 측정하며, virsh process group을 kill/reap한다.
slot FD를 virsh에 상속해 회수되지 않은 자식이 살아 있는 동안 admission이 풀리지 않게 한다.
프로세스 슬롯은 0600, 디렉터리는 소유자 전용 0700이며 symlink를 거부한다.
테스트/비root 실행은 VM_EXEC_RUNTIME_DIR로 자기 소유 디렉터리를 지정할 수 있다.
guest-exec-status를 재시도하더라도 guest-exec 자체는 자동 재전송하지 않는다.

추가 JSON 필드:
guest_exec_pid, signal, state(SUCCEEDED/FAILED/UNKNOWN), error,
out_truncated, err_truncated, encoding_loss.

- 호스트 exit 0: 완료된 guest 결과를 수신. guest exit_code가 7이어도 호스트 exit은 0이며 state=FAILED다.
- 호스트 exit 2: CLI/입력 오류(실행 전).
- 호스트 exit 3: transport·timeout·출력 상한·로컬 I/O 실패. state/error를 반드시 확인한다.
- signal 종료: exit_code=null, signal에 번호. null/비정상 응답을 성공으로 처리하지 않는다.
- timeout/응답 유실: UNKNOWN, 얻은 guest_exec_pid 보존. **host 종료는 guest 취소가 아니다.**
- QGA out/err-truncated: FAILED+OUTPUT_LIMIT. decoded 상한 초과/잘못된 응답은 UNKNOWN.
- UTF-8 변환 손실은 encoding_loss=true. --out은 변환 전 원본 bytes다.
- decoded 출력 상한과 JSON 직렬화 크기는 다르다(제어문자 이스케이프 확장 가능).
- 기존 legacy command 필드는 argv를 포함하므로 사용자 스스로 secret이 있는 명령을 로그에 남기지 않아야 한다.
  미래 Cloud protocol 경로는 임의 command/argv를 허용하지 않는다.

## 설치 경로

같은 prefix에 있는 도구와 라이브러리만 사용한다.

- source: bin/vm_exec.sh → lib/vm_exec.py
- RPM/DEB: /usr/bin/vm_exec → /usr/libexec/ablestack-qemu-exec-tools/vm_exec.py
- make/local prefix: /usr/local/bin/vm_exec → /usr/local/lib/ablestack-qemu-exec-tools/vm_exec.py
- custom prefix도 같은 상대 구조를 사용한다. 라이브러리가 없으면 exit 3, 다른 버전의 임의 경로로 fallback하지 않는다.
- Python 3.9+ 의존성을 RPM/DEB 메타데이터에 명시했다.

## C1 프로세스 프로토콜 경계

```bash
vm_exec --process-protocol 1.0 --request-json /root/private-request.json
```

요청은 소유자 0600 regular file, 64KiB 이하이며 symlink/FIFO/중복 JSON key/NaN/Infinity를 거부한다.
기준 계약: Cloud commit 31c3b36768a9a12d588dbd7a01f5217a5b026090,
docs/design/vm-process-contract.

Q1은 bounded transport만 제공한다. Q4/Q5 guest adapter 및 Cloud 실행 권위/guard 연동은 아직 구현하지 않았다.
따라서 올바른 protocol 요청도 **HOST_TOOL_MISSING** failure envelope로 종료하며 virsh를 호출하지 않는다.
미지원 버전은 UNSUPPORTED_VERSION, malformed 요청은 exit 2다.
정상 failure envelope 반환은 protocol host exit 0이며 legacy CLI exit 규칙과 구분한다.
generic legacy 실행 슬롯은 Cloud의 VM별 lifecycle flock·lease·분산 fencing을 대체하지 않는다.
process.list/kill/restart가 구현되었다고 광고하거나 기존 범용 실행을 Cloud API로 노출하지 않는다.

## 검증

```bash
bash -n bin/vm_exec.sh
shellcheck bin/vm_exec.sh
python3 tests/vm_exec_test.py
python3 tests/vm_exec_contract_test.py --contract-dir /path/to/pinned/Cloud/docs/design/vm-process-contract
```

마지막 검증에는 C1의 requirements.txt 설치가 필요하다. production vm_exec에는 jsonschema가 필요 없다.
GitHub Actions VM exec transport contract가 동일한 commit을 고정하여 검사한다.
실제 VM 검증은 tests/vm_exec_live.py를 배포된 호스트에서 지정 VM 대상으로 실행한다.
이 검증은 자기 테스트 프로세스만 생성하며 기존 VM workload에 종료 명령을 보내지 않는다.
결과와 배포/복구 경로는 docs/validation/issue-60-vm-exec.md를 참조한다.
