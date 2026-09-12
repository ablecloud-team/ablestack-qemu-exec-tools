# #1030 체크포인트 producer 수명 분리

## 원인
ABLESTACK replication_cycle은 scheduler가 전달한 producer Run으로 파일명을 만들지만 write_manifest/write_checkpoint는 재작성 가능한 disk map의 profile Run을 읽었다. 살아 있는 worker 재개 후 producer와 control Run이 달라 다음 publication 검증이 실패한다. VMware는 cycleMetrics가 실제 producer를 전달한다.

## 코드 설계
1. dr_ablestack.sh replication_cycle의 함수 지역 exported FTCTL_DR_PRODUCER_RUN_UUID에 scheduler 인자 run을 고정한다. manifest/checkpoint writer는 이 값을 명시적 Python 인자로 전달하여 결과 runUuid로 사용한다. 호출이 끝나면 지역 값은 사라지며 plan profile/disk map을 고쳐 과거 증거를 재라벨하지 않는다. 비-scheduler 기존 호출은 기존 map Run을 유지한다.
2. dr_scheduler.sh pending resume_context 실패를 무처리 return108로 종료하지 않는다. ERROR/RECOVERY_REQUIRED 및 구체적 오류를 기록하고 제한된 대기로 운영자 요청을 기다린다. 기존 체크포인트는 변경하지 않는다.
3. 불일치 상태에서 새로운 명시적 FULL_RESEED 요청이 들어오면 pending publication을 증거 파일로 보존하고 다음 sequence에서 새 요청 producer로 전체 복제한다. 잘못된 candidate를 승인하거나 ID 검사를 제거하지 않는다.
4. Cloud Java/UI 계약 변경 없이 기존 전체 재동기화 메뉴를 사용한다. 작업 이력 SUCCEEDED는 제어 완료일 수 있어 실제 동기화 이력 READY 및 runtime으로 완료를 별도 확인한다. #967의 전반적인 성공 표시 변경은 별도 범위다.

## 검증
- 기존 profile Run과 producer가 다른 실제 writer 출력으로 기존 코드 실패/수정본 통과 확인; 함수 지역 값 격리, full/incremental 및 pending ACK 재개 확인.
- candidate 불일치 거절 유지, 증거 보존 후 명시적 재동기화, 이전 durable 보존, 제한된 재시도 및 재시작 이후 복구.
- qemu checkpoint/resume/lifecycle/maintenance/release tombstone 회귀. shell 변경 파일 직접 배포 및 SHA256 확인, RPM/전체 Cloud 빌드 없음.
- qcow2/RBD/VMware UI Pause/Resume에서 worker 유지/소실 후 실제 다음 checkpoint 확인. VMware 양단 QGA 제외. 변경 데이터 있는 qcow2 cycle 확인, UI 전체 재동기화 복구 확인.

## 마이그레이션 계약 추가
producer identity는 plan/Run/sequence만 사용하며 host UUID, PID, VM 배치를 포함하지 않는다. 기존 profile을 통한 현재 디스크/실행 호스트 재해결을 유지한다. 원본 VM 이동 때문에 migration을 금지하는 guard를 추가하지 않는다. 실행 중 QMP는 현재 VM 호스트에서 수행하고 공유 저장소 file transfer worker는 별도 선정한다. 기존 relocated-baseline 및 source-outage 회귀와 실제 VM 이동 후 체크포인트를 추가 확인한다.

## #1031 / #1032 실행 중 발견 사항 반영
- #1031: Cloud status_json에는 reconciliation_required가 필터링되어 빠질 수 있다. 따라서 typed reconciliationState=LIVE를 필수로 검증하고, raw flag가 있을 때는 false도 확인한다. worker PID와 scheduler/active PID 일치, count1, MATCHED/ALIVE/active/RUNNING 조건은 유지한다. 실제 저장 형식 회귀 포함 DR456 tests/package PASS.
- #1032: 실제13.2→13.1 이동 후 새 source worker가 과거 remote-source-target-suppressed STOP 때문에 종료됨을 확인했다. dr-sync-start/dr-sync-recover에 새 profile과 role=source 또는 원본 Mold가 사용하는 coordinator가 명시된 경우만 plan lock 아래 exact reason/빈 owner STOP을 다음 generation RUN으로 바꾼다. 사용자 pause/stop 및 lifecycle stop은 그대로 보존한다. 평범한 daemon 재시작에서는 변경하지 않는다. 호스트/PID를 미래 계획의 실행 권한으로 저장하지 않는다.

- #1032 추가: FtctlDrRuntimeProjectionAdapter.reconcileCheckpointPublication의 복제 Run 허용 목록에 RECOVER_SYNC가 빠져 새 worker의 올바른 candidate가 ACK되지 않았다. 기존 plan activeSide/target durable 검증을 유지하면서 RECOVER_SYNC만 포함한다. 기존 publication 검증 테스트에 실제 RECOVER_SYNC Run을 추가해 수정 전 ACK 누락 실패를 재현했고, 수정 후 DR456 tests/package PASS. 재해 페일오버/해제 경로에 원본 접근 조건은 추가하지 않는다.

- #1032 broker: 마이그레이션 이전 worker가 DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE/ERROR이며 scheduler PID가 죽은 경우에 한해, HEALTHY이며 살아 있는 READY/SYNCING/PAUSED 복제 worker를 로컬 authoritySequence보다 우선한다. 요청 Run 일치, lifecycle authority, 일반 sequence 비교는 유지한다. RELEASED/FAILED_OVER/CUTOVER_READY/FAILBACK_READY/PAUSED의 상위 authority 회귀를 추가했다.

## 새 호스트의 Agent 상태 검증 실패 추가 원인

실제 이동 후 새 worker는 실행 중이지만 Agent가 DR_STATUS_CYCLE_EVIDENCE_CONFLICT로 상태를 거절했습니다.

1. qemu save_profile의 포괄적인 token 비식별화가 비밀이 아닌 checkpointCycleToken을 REDACTED로 변경했습니다. 정확히 정의된 cycle 식별자 필드만 보존하고 password/secret/accessToken/API credential 비식별화는 유지합니다.
2. controller에서 전달받은 과거 durable checkpoint에는 새 호스트의 NBD drain 증거가 없습니다. 그런데 seed_relocated_baseline이 incrementalVerified=true를 그대로 복사했습니다. 해당 imported reference는 durable 정보만 유지하고 로컬 incremental verification은 unknown으로 둡니다. 다음 실제 cycle의 검증 결과는 기존대로 기록합니다. DRAINED를 임의 생성하지 않습니다.

이전 NO_CHANGE만 다룬 relocation 회귀를 CBT_INCREMENTAL로 바꾸고 실제 profile 비식별화까지 검사합니다. 실제 UI 복구 및 재마이그레이션 검증을 이어갑니다.

## #1032 재마이그레이션 추가 회귀
VM 부재 rc110이 generic failure로 종료되어 systemd가 재시작하고 RECOVERING을 반복했다. 새 오류를 유지하지 못해 Cloud 자동 복구 eligibility가 영구 false가 되는 실환경 실패를 확인했다. rc110은 bounded source retry로 전환하며 같은 sequence/producer를 보존하고 scheduler_recovery_state=REQUIRED로 현재 배치 재해결을 요청한다. VMware rc98의 PENDING 대기는 유지한다. 사용자 pause/stop은 기존 sleep/control 경계를 그대로 따른다. broker는 해당 명시적 source-runtime 오류에 한해 살아 있지만 VM을 실행할 수 없는 WAITING_SOURCE worker도 정상 새 worker보다 낮게 선택한다. lifecycle authority 비교는 변경하지 않는다.
