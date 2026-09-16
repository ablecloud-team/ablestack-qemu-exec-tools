# Cloud VM 작업 보호 소비자

Cloud #1103/#1104와 함께 배포한다. 기준은 PR #58 (`10cd94c`), 관련 코드를 삭제하거나 이전 버전으로 되돌리지 않는다.

## 수정·추가·삭제 사유

| 코드 | 구체적인 이유와 대체 동작 |
|---|---|
| lib/hangctl/libvirt_wrap.sh: hangctl_with_operation_lock 추가 | 기존 domain-job 검사 직후 Agent가 snapshot을 시작할 수 있는 경쟁을 차단한다. UUID별 Linux flock을 비차단으로 획득하고 callback 반환까지 유지한다. Java FileChannel lock과 혼용하지 않는다. |
| bin/ablestack_vm_hangctl.sh: detector를 guarded 함수로 이동, wrapper 추가 | PR58의 ACTIVE/UNKNOWN/QMP/paused 판정 순서는 그대로 보존하고 그 전체 앞에 Cloud admission을 둔다. 함수명 변경은 기존 판정을 제거하기 위한 것이 아니다. |
| lib/hangctl/actions.sh: confirmed action을 guarded 함수로 이동, wrapper 추가 | detector 이외 직접 조치 진입도 공통 lock을 거치게 한다. 동일 UUID의 nested callback은 상위 lock을 유지하며 중복 획득하지 않아 자기 교착을 피한다. 기존 dump/destroy/signal별 재검증은 제거하지 않는다. |
| 테스트 snapshot fixture의 domuuid 응답 추가 | 새 identity 조회 경계를 모의 객체에 반영한다. 기존 PR58 destructive gate 단언을 유지한다. |
| hangctl_operation_lock_smoke.sh 추가 | 실제 flock 충돌, 잔여/잘못된 lease 보호, 정상 해제 후 재개, 반복 실행 종료를 확인한다. 실제 VM의 destructive action은 실행하지 않는다. |

## 공통 계약과 잔여 상태

- `/run/ablestack-vm-operations/locks/<UUID>.lock`; lock 파일은 삭제하지 않는다.
- `/run/ablestack-vm-operations/<UUID>/<operationId>.json`; 디렉터리 실행 UID 소유 0700, symlink 거부.
- Cloud producer가 전체 snapshot/revert/delete/blockcommit 동안 lock을 잡고 별도 단일 scheduler로 JSON을 갱신한다.
- lock 충돌은 ACTIVE, 잔여/부분/알 수 없는 파일은 UNKNOWN으로 보호한다. TTL 만료나 owner 종료만으로 destroy/TERM/KILL을 허가하지 않는다. 모든 파일이 없더라도 기존 PR58 domain-job/paused/identity gate를 계속 수행한다.
- Agent와 모니터링이 공유하는 lock이므로 짧은 모니터링 수집과 hangctl scan이 겹쳐도 안전하게 다음 주기로 미룬다.
- 이 소비자는 추가 daemon, executor, retry queue를 만들지 않는다. 함수는 subshell이며 종료 시 FD를 닫는다. 기존 virsh 및 action timeout이 적용된다.
- 장기간 UNKNOWN은 수동 재조정 대상이다. owner identity/실제 작업 종료/VM identity를 확인하지 않고 lease를 지우지 않는다.

## 배포

13번의 설치된 PR58 파일과 비교한 뒤 producer KVM JAR와 consumer 3개 파일을 함께 배포한다. timer를 일시 중지하고 실행 scan 종료를 기다린다. Agent 재시작 전후 running VM UUID 집합을 비교한다. rollback도 두 구성요소를 함께 복원하며 활성 작업 및 잔여 lease를 먼저 확인한다.

Cloud 검증 문서: `developer/issue-1103-1104/verification.ko.md`. 실물 결과는 paired PR에 링크한다.
