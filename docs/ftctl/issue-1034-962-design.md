# #1034 / #962 최소 UI 복구 설계

## 범위
기준 Cloud 60b9bc42fa, qemu 4493037. 양 저장소 codex/fix-1034-962-ui-recovery는 기존 통합 PR HEAD를 보존한다. 구현 완료 보고에 남은 이슈와 우선순위를 포함한다.

## #1034 원인
LibvirtFtctlDrStatusCommandWrapper.execute는 latest completed snapshot의 CONFLICT/INCOMPLETE 시 validationAnswer로 원래 status를 교체한다. checkpoint_publication_pending도 유실된다. 원격 FtctlDrSiteAgentBrokerServiceImpl.dispatch는 result=false를 전부 제외한다. Cloud projection은 boundary failure에서 반환하므로 독립적인 새 candidate의 target publish/ACK를 수행할 수 없다.

## 변경 계약
- Agent는 plan/run identity, JSON type/size와 정상 CLI 종료를 먼저 검증한다. 실패한 과거 completed evidence는 result=false/기존 오류코드로 유지한다. 단 latest snapshot 무결성 오류이며 현재 pending candidate가 존재할 때만 publication 전용 표식과 pending envelope를 오류 응답에 보존한다. 잘못된 latest 값을 정상으로 고치거나 typed readiness로 승격하지 않는다.
- 원격 broker는 이 제한된 publication 오류 응답도 운반할 수 있다. 원래 성공 응답이나 terminal authority로 변환하지 않는다. lifecycle terminal보다 우선하지 않으며 단순 timeout/identity/type 오류는 복구 후보가 아니다.
- Cloud projection은 명시적 publication-only 응답에서만 기존 reconcileCheckpointPublication을 별도 실행한다. Plan이 SOURCE이고 허용 sync/recover/resume/pause Run일 때만 처리하며 TARGET failover/release 상태에서는 금지한다. 대상이 기존 계약에 따라 Plan/producer/disk set/export generation을 검증하고 COMMITTED + 같은 request + manifestSha256을 반환해야 ACK한다. 과거 invalid snapshot은 여전히 last-good projection을 대체하지 못한다.
- qemu의 기존 CHECKPOINT_PUBLISH/ACK 및 정상 cycle 완료가 새 실제 증거로 old latest를 교체한다. 필요 없는 파일 재작성/가짜 token/DRAINED 보충은 하지 않는다. 셸 변경이 필요한지 이 경로의 실제 시험으로 판단한다.

## #962 최소 잔여
기존 DR 계획 삭제 메뉴는 항상 노출/활성, 기존 확인창 강제 옵션을 재사용한다. 기본 force unregister 구현을 중복하지 않는다. 손상 상태·원격 단절에서 일반 삭제 거절 및 강제 등록 해제/이력 보존, 활성 작업의 명시적 취소 안내를 점검한다. unrelated VM/볼륨은 보존하며 새 전체 orphan 관리 기능은 제외한다.

## 검증
Agent: invalid prior + valid pending은 오류를 유지하면서 pending 보존; identity/type/CLI failure 및 잘못된 pending은 제외. Broker: publication 전용 오류 운반 및 terminal authority 우선. Projection: target publish와 정확한 ACK, 다른 Plan/producer/disk set/미완료 proof 거절, last-good 보존, TARGET에서 미실행.
WSL ext4 변경 Maven 모듈만 build/package. qemu는 변경 시 shell 직접 배포. 기존 lifecycle/release tombstone/기존 action 계약을 회귀한다. 테스트 전 상태/증거 백업, 지정 시험 Plan의 기존 completed snapshot만 오류 fixture로 만들어 UI 전체 재동기화 이후 수동 상태 보정 없이 새 durable checkpoint를 확인한다. 실패 복구 불가능 조건에서 disposable Plan의 동일 삭제 확인창 강제 옵션을 검증한다. VMware 양단 QGA 제외, 원본 단절 target-only 복구 및 VM migration 허용 유지.

## 구현 중 추가 확인
Cloud의 isStatusBoundaryFailure 목록에 DR_STATUS_CYCLE_EVIDENCE_CONFLICT가 빠져 있었다. 이를 추가하여 recovery-only 표식 없는 충돌 응답이 일반 게시/상태 투영 경로로 흐르지 않게 한다. 새 회귀 테스트 세 개는 기존 HEAD의 Agent, broker, projection 코드에서 각각 실패했으며 수정 코드에서 통과했다. Broker는 새 publication 후보를 운반하되 RELEASED/UNPROTECTED/FAILED_OVER/CUTOVER_READY/FAILBACK_READY 상태를 덮어쓰지 않는다.

## 모듈 검증 (2026-09-11)
WSL rocky ext4에서 KVM, FTCTL service, disaster-recovery 세 모듈만 Maven package 완료. 테스트 730/83/457개, 실패 및 오류 0, KVM skipped 3. 손상된 과거 완료 상태에 대한 새 검증은 (1) 다른 Plan, TARGET, 비정상 CLI 종료, 잘못된 타입 및 비어 있는 disk 후보 제외 (2) terminal authority 우선 (3) 유효한 새 target publish/ACK만 허용하며 과거 runtime/restore point를 덮어쓰지 않음 (4) marker 없는 CONFLICT 거절을 포함한다. 실제 배포/UI 결과는 검증 후 별도 기록한다.

## 실제 UI 시험에서 확인한 추가 호환성 (2026-09-11)
1. 원격 소스의 기존 dr-status는 active_side가 빈 문자열인 정상 SOURCE 응답을 반환한다. READY/SYNCING/PAUSED + PLAN_AUTHORITY + 정상 CLI/identity/type 검증인 경우에 한해 빈 값도 publication transport 후보로 수용한다. Cloud의 실제 Plan SOURCE 권한 검증은 그대로 유지하며 TARGET 또는 전환 완료 상태는 제외한다.
2. 손상 응답에 아직 pending 후보가 없으면 broker가 이를 버리고 이전 호스트의 오래된 READY를 선택하여 UI 영속화 시각이 13:24에서 11:31로 되돌아가는 것을 관찰했다. publication 후보가 생기기 전에도 검증 오류를 보존해 retired worker를 되살리지 않는다. 실제 healthy live worker와 lifecycle terminal은 이 오류보다 우선하며, 두 오류 응답 중에는 유효한 pending 후보를 우선한다.
3. 첫 실제 시험의 checkpoint 1921은 빈 active_side 조건에 걸려 승인 대기 상태였다. 이 시도를 PASS로 간주하지 않는다. 토큰을 수동 보정하지 않고 코드 호환성을 보완한 뒤 재검증한다.
