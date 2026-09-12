# #1012 / #1013 통합 코드 설계

기준: Cloud7740f7dfec / qemu24af913. 기존 #979/#1008/#1011/#1015를 포함한 codex/fix-1012-1013-dr-recovery 후속 브랜치.

## #1013
실제 run474는 FULL_RESEED/checkpoint54가 durable이며 accepted cycle206에 결합됐지만 operation snapshot은 full-reseed-transfer/cycle_state=RUNNING으로 남았다. scheduler의 checkpoint ACK 재시도에서 cycle_request_bound가 false로 초기화되고 요청 상태는 이미 RUNNING이므로 PENDING 분기를 타지 않는다. pending checkpoint에서 sequence/run만 복구하고 full-reseed cycle type 및 요청 결합을 복구하지 않아 terminal publication을 누락한다.
- checkpoint publication envelope에 scheduler cycle type을 보존하고 ACK 재시도에서 복원한다. 요청 owner+sequence+mode+상태를 확인한 경우에만 requested cycle terminal로 결합한다. 기존 envelope는 실제 checkpoint/metrics의 mode로 복원한다.
- 다른 run/sequence, 취소된 요청을 성공 처리하지 않는다. 데이터 복사를 재실행하지 않고 동일 immutable checkpoint ACK 후 동일 요청을 terminal publication한다.
- Cloud는 run-owned durable full-seed 증거가 충족된 경우 최신 연속 worker의 stale RUNNING 상태에 의해 이전 완료 요청이 막히지 않도록 판정 경로를 검토한다. target readiness와 run/cycle 소유 확인은 유지한다.
- 지연 ACK/프로세스 재시작/다른 owner/취소 음성 테스트, 페일백 후 UI 전체 재동기화 성공 및 후속 메뉴 활성화 검증.

## #1012
FAILOVER_CUTOVER의 RBD snapshot/qcow2 bitmap은 대상 변경 추적 증거이며 원본과 동일하다는 증거가 아니다. 원본만 변경된 영역은 target diff에 없어서 기존 최초 역복제로 복구되지 않는다.
- 공통 기준점 검증 여부를 baseline에 명시한다. cutover baseline 및 기존 검증 증거 없는 baseline은 미검증으로 처리한다.
- AUTO 첫 역복제는 FULL_REVERSE_SEED로 전체 디스크를 쓴다. RBD는 readback 검증, qcow2는 QEMU backup concluded/error-free 완료를 확인한다. 같은 기준점이 증명되지 않은 명시적 delta 요청은 거절하며 전체 복구 선택은 허용한다.
- 전체 쓰기와 경로별 완료 검증이 모두 성공한 뒤에만 common baseline verified를 원자적으로 기록한다. 이후 기존 원본 격리 계약 하에서 증분을 허용한다. 새 failover는 검증 상태를 무효화한다.
- RBD 및 qcow2 reverse tracker 모두 적용하고 직접 mover 호출에서도 미검증 delta를 차단한다.
- source-only/target-only/같은 LBA/다른 LBA/zero 범위를 구성해 최초 전체 정합성 및 다음 증분을 검증한다. 실제 VMware 원본 정상 종료 후 발생한 쓰기도 포함한다.
- 원본 단절은 재해 페일오버 및 대상 체크포인트 테스트를 막지 않는다. 검증/전체 정합성 처리는 원본에 쓰기가 가능한 페일백 단계에만 적용한다. VMware 양단 QGA 제외.

## 빌드·배포
Cloud 변경 모듈만 WSL ext4 Maven 빌드. qemu는 shell/python 모듈 스모크 후 파일 배포(RPM 빌드 없음). 공유 scheduler/checkpoint 변경은 lifecycle/action 계약 및 release tombstone 회귀를 선행한다. 현재 테스트 VM/계획 상태를 새로 확인하고 UI로 실행, 콘솔/데이터 증거로 완료 판정한다. 실패 시 취소/삭제 등 사용자 복구 경로도 보존한다.

### 검증 증거 구분
RBD commonBaselineVerification은 REVERSE_READBACK, qcow2는 QEMU_BACKUP_COMPLETION이다. 기존 qcow2 writeVerified/verifiedBytes는 QEMU 작업 성공을 나타내며 별도 readback이 아니다. 이 지표 명칭 및 실제 readback 추가는 후속 개선으로 구분한다.

### 실제 환경 확인 후 보완
실제 VMware checkpoint 최상위 runUuid는 과거 canonical profile의 run ID일 수 있다. cycleMetrics.runUuid/sequence/planUuid가 현재 전송 producer 증거이므로, ACK 복원 시 cycleMetrics가 있으면 이를 우선 검증한다. 단순히 다른 owner를 허용하지 않으며 pending request identity와 metrics identity가 일치해야 한다. 해당 실제 잔류 사례와 foreign producer 거절 테스트를 추가했다.
qcow2 완료 지표/readback 증거 분리는 후속 P2 #1018로 등록했다.
