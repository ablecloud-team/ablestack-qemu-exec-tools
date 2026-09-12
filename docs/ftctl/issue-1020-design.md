# #1020 코드 수준 설계

## 문제와 범위
역복제 dr_extent_patch 진행에는 Plan/Run/sequence와 방향·모드가 누락된다. DrRunProgress는 현재 실행의 자료인지 확인하지 않고 전역 runtime의 더 큰 cycle/sample을 고르며, transfer100%를 원본 복구 완료/보호 재개 안내로 추정한다. Cloud의 idle 완료 주기 projection도 실행 중 역복제 화면에 혼입될 수 있다.

## 변경 계약
- dr_runtime_reverse_checkpoint는 artifact용 하위 Run 이름과 별도로 부모 UI Run을 FTCTL_DR_PROGRESS_RUN_UUID로 전달한다. 실제 checkpoint/manifest 이름이나 lifecycle 성공 판정은 바꾸지 않는다.
- RBD reverse mover는 immutable snapshot extent를 먼저 산출해 전체 디스크의 실제 전송 합계를 정하고 dr_extent_patch에 plan/run/sequence/direction=KVM_TO_VMWARE/effectiveMode, diskCount/ordinal/label/finalDisk를 전달한다. 마지막 디스크의 쓰기·readback 완료만 transfer COMPLETE다.
- dr_extent_patch에 backward-compatible progress-direction 인자를 추가한다. 기본 forward 계약 유지. qcow2 helper에도 선택 progress-mode/direction을 추가해 reverse를 forward로 표시하지 않는다.
- dr-status는 operation의 진행 journal Plan/Run 소유권을 검사하고 명시 transfer_plan_uuid/transfer_run_uuid/transfer_direction을 출력한다. 기존 plan-scoped 검사도 유지하며 거절한 journal을 성공으로 사용하지 않는다. 과거 식별자 없는 reverse journal은 unknown이다.
- Cloud compact JSON, Run response, protection view가 identity를 전달한다. idle 과거 cycle은 active operation이 있으면 current transfer를 덮어쓰지 않는다. 과거 targetWrittenBytes를 readback verifiedBytes로 합성하지 않는다.
- UI는 Run 자체의 operation-scoped sample을 우선 유지하고, 전역 runtime sample은 현재 Run identity가 일치할 때만 후보로 사용한다. reverse 진행은 direction도 일치해야 한다. 완료 주기 projection은 current transfer에서 제외한다.
- transfer100%로 lifecycle 완료를 추정하지 않는다. 원본 복구/보호 재개 안내는 실제 현재 Run의 protection-resuming 단계에서만 표시한다. VERIFYING/쓰기100%는 전체 Run 성공이 아니다. 실패/취소/삭제 메뉴 계약은 유지한다.

## 검증과 배포
Cloud 변경 DR Maven 모듈만 WSL ext4에서 빌드, UI unit/lint/build. qemu Python/shell 회귀 및 lifecycle/tombstone/action smoke. full/delta 및 다중 디스크 progress identity/aggregate, 구 Run/forward sample 거절, VERIFYING100% 조기 안내 금지를 테스트한다.
직접 변경 스크립트 배포 및 31/32 클래스·UI 배포(백업/WEB-INF/해시/HTTP 확인). 실제 32 VMware→RBD UI에서 planned failover/failback 진행·readback·자동 보호 재개까지 확인한다. qcow2는 모듈 데이터 시험 및 기존 UI 회귀를 구분한다. VMware 양단 QGA 제외, VM host pinning이나 source-independent failover 계약 변경 없음.
