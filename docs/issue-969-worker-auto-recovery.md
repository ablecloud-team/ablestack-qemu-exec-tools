# #969 코드 수준 설계 — 유지보수 후 자동 복제 복원

## 기준과 범위
Cloud 373ac7474e / qemu 0aa089c13f의 #968 누적 변경을 기반으로 각각 codex/fix-969-worker-auto-recovery를 생성했다. 정상 RUNNING 복제의 원본/대상 worker 중단·복귀를 자동 회복한다. PAUSED와 전환/해제 의도를 유지하며 planned/disaster failover·failback 동작은 변경하지 않는다. 레거시 DR Cluster는 활성화하지 않는다.

## 확인한 제어 흐름
- DrSchedulerRecoveryScheduler가 30초 주기로 source health와 recoverSync eligibility를 검사한다. 현재 idempotency key는 Plan UUID+authoritySequence로 고정되어 있다.
- DrOrchestratorImpl.createRun은 동일 key의 종료 Run도 그대로 반환한다. 같은 authority에서 첫 복구가 실패하면 다음 tick이 신규 복구를 생성하지 못한다. 별도 유지보수 장애도 동일 세대이면 기존 완료 요청에 묶일 수 있다.
- qemu scheduler는 rc98 source 단절, rc100 target export 불가에 backoff하며 같은 cycle을 재시도한다. target export reconcile은 durable intent/profile/generation으로 재시작한다. 이 경로는 재사용한다.
- 다만 로컬 scheduler reconcile은 READY/SYNCING 또는 NBD quarantine만 허용한다. source runtime 부재/일시 offline busy가 ERROR로 종료되면 control RUNNING이어도 로컬 자동 재기동이 누락된다.

## Cloud 변경
DrSchedulerRecoveryScheduler:
1. 멱등 key를 Plan UUID+authoritySequence+마지막 종료 Run ID로 구성한다. 동일 관측 상태의 중복 호출은 같은 key, 실패/완료 이후 재시도는 새 key가 된다. active Run과 eligibility 검사는 계속 유지한다.
2. 자동 복구 RECOVER_SYNC 종료 후 최소 60초 간격을 적용한다. DB completed 시각을 사용하므로 관리 서버 재시작에도 backoff가 유지된다.
3. 최신 PAUSE/RELEASE/FAILOVER/FAILBACK/REPROTECT/TEST_FAILOVER 및 취소 의도가 있으면 자동 controller가 이전 복제를 재개하지 않는다. runtime desired/control projection과 계획 active side/admin/state도 재검증한다. TEST_CLEANUP 복귀는 기존 #964 전용 journal을 따른다.
4. DR_EXPORT_OWNERSHIP_PENDING은 기존 transport 오류와 함께 자동 재시도 가능 오류로 분류한다. 정상 복귀 후 ACK를 다시 받아 진행하며 fencing 가드를 제거하지 않는다.
5. 최종 mutation 직전의 최신 Run 변화도 검사하고, 실제 dispatch의 기존 authority 검증을 유지한다.

## qemu 변경
- 로컬 reconcile에 명시적으로 retryable인 ERROR 중 DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE/DR_QCOW2_OFFLINE_SOURCE_BUSY만 추가한다. 모든 ERROR를 재기동하지 않는다.
- durable control stop/PAUSED, TARGET authority, transition 진행 중, desired STOPPED 가드를 보존한다.
- status에 다음 로컬 복구 시각을 저장해 반복 timer의 launch 폭주를 막는다. 정상 기존 READY/SYNCING recovery 경로와 release tombstone 계약은 유지한다.
- 기존 원격 endpoint 재시도 및 target export durable intent 복원은 유지한다. 실환경에서 추가 결함이 확인되면 코드 근거와 수정 설계를 갱신한다.

## 검증
- Cloud: 종료 Run 후 새 key, 같은 snapshot 중복, backoff 경계, active Run/PAUSE/전환/해제/cancel 억제, ownership pending 재시도 단위 시험.
- qemu: transient ERROR 복귀, 재시도 간격, 비재시도 오류/PAUSED/STOPPED/TARGET/transition 억제. release tombstone 및 기존 action contract 회귀.
- Cloud WSL ext4 변경 모듈 빌드, qemu Actions artifact 빌드. 설치 파일 hash 및 서비스/WEB-INF/HTTP200 확인.
- UI: RBD32 및 qcow2 31 정상 Plan을 기준으로 source worker, target worker, 양쪽의 복제 관련 실행/통신을 여러 retry 주기 동안 중단 후 복원. 복원 후 수동 Resume/Full Sync/DB 수리 없이 신규 durable checkpoint와 변경 데이터 전송 증거를 확인한다.
- Agent/프로세스 중단·네트워크 단절과 실제 전원 중단은 구분한다. 업무 VM 전체를 멈추는 장애는 기존 inventory와 영향을 확인한 후에만 수행하며 미수행 시험을 PASS로 표시하지 않는다.
- 기존 test/cleanup 및 PAUSED 유지 UI 회귀, source-unreachable disaster routing/권한 및 역방향 action contract 회귀를 수행한다. 전체 물리 페일오버/페일백 시험과 자동 회귀 결과를 구분해 보고한다.

## 후속 범위 경계
#969의 첫 구현은 정상 호스트 복귀 후 무인 수렴에 집중한다. 영구 폐기 호스트 fencing 증거 UI나 전체 ownership journal 재설계는 구현하지 않은 채 완료했다고 주장하지 않는다. #970/#971의 별도 기능 확장은 선행 조건이 아니며 기존 동작의 회귀 가드를 유지한다.

## #969 구현·빌드·배포 및 UI 검증 결과 (2026-09-10 KST)

### 완료한 구현
양쪽 브랜치: `codex/fix-969-worker-auto-recovery`.
- Cloud 구현 커밋 [019bf23bb2](https://github.com/dhslove/ablestack-cloud/commit/019bf23bb2): DrSchedulerRecoveryScheduler의 복구 키를 Plan/authority/latest Run으로 구성해 같은 authority에서 실패 후 재시도가 막히는 문제를 해소. 완료된 복구 Run 기준 60초 durable backoff, 최신 Run/계획 의도 재검증, PAUSED/STOPPED/TARGET 및 전환 작업 가드. 일시적 ownership/Agent/dispatch/engine 오류를 안전한 자동 재시도 대상으로 분류.
- qemu 구현 커밋 [c059eda](https://github.com/dhslove/ablestack-qemu-exec-tools/commit/c059eda): source runtime unavailable/offline busy의 retryable ERROR에 한해 local reconcile 재시도, 60초 backoff. 기존 PAUSE/STOP/authority/전환 가드를 보존. 임의 오류·CBT 유실·소유권 미확인을 강제 성공 처리하지 않음.
- 새 fencing API, 영구 폐기 호스트 journal, 역방향 export 계약 변경은 이번 구현에 포함하지 않았다. #970/#971은 별도 후속이며 기존 failover/failback 조건을 변경하지 않았다.

### 빌드와 배포
- WSL ext4 Cloud 변경 Maven 모듈 `plugins/integrations/disaster-recovery` package: **432 tests, failures 0, errors 0, skipped 0, BUILD SUCCESS**. 전체 Cloud 빌드 아님.
- qemu [GitHub Actions 34426283087](https://github.com/dhslove/ablestack-qemu-exec-tools/actions/runs/34426283087): **SUCCESS**. 신규 maintenance smoke, 70 lifecycle 테스트, release tombstone, remote RBD/qcow2 및 sync/pause/resume/release/test/cleanup/failover/failback 계약 회귀 포함.
- qemu RPM SHA256: `7bd3cdd14147d32105d73a2afcbf1eac9332e9796719096725249088b05c748e`.
- qemu 배포: 13/22/31/32 클러스터의 각 .1/.2/.3, 총 12호스트. 설치 scheduler SHA256 `9705b0d183f3dc55005014d8f47a662509cd23d3837ba8dc6fc57c77fc99ccb5`, agent/timer active, agent.properties와 VM inventory 보존.
- Cloud 배포: 31.10/32.10. 변경된 scheduler 클래스 두 개만 기존 management JAR에 반영. 다른 ZIP entry 바이트 불변 검증, 백업 `/root/issue969-v2/backup`. 정적 UI/스키마 변경 없음. mold active, WEB-INF 보존, /client HTTP 200 및 UI 재로그인 확인.
- 배포 JAR SHA256: 31 `fdcadcddebd92a20974d25f071fe310c9292eb4eb2cdecfd92c1f31fcbda38f9`, 32 `5288e166cfa7847fb3f2c8211f6f2a091b520f2d3ba446f29352ed917449ab1f`.

### 실제 UI 및 런타임 검증
장애는 시험 Plan의 source scheduler 실행 차단 또는 target 전송 포트 차단으로 주입했다. 물리 전원 OFF 시험과 구분한다. 차단 해제 스크립트는 mask/방화벽 규칙만 해제하며 start/Resume/Full Sync/DB 보정을 수행하지 않았다.

| 경로/시험 | 복원 관측 | 판정 |
|---|---|---|
| RBD 원본 scheduler 7분 실행 차단 | 10:52:53 해제 → 10:53:11 증분 4376 durable, 18초 | PASS |
| qcow2 대상 전송 7분 차단 | 10:52:59 해제 → 10:55:19 증분 1368 durable, 140초, 기존 backoff 내 | PASS |
| RBD 대상 전송 7분 차단 | 11:01:29 해제 → 11:02:01 증분 4377 durable, 32초 | PASS |
| qcow2 원본 7분 차단 + 대상 차단 중첩 | 대상 먼저 11:05:00 정상화, 원본 11:07:00 해제 → 11:07:14 증분 1370 durable, 14초 | PASS |
| RBD PAUSED 중 source scheduler 부재 | 11:06:08 실행 차단 해제 뒤 3분 이상 PAUSED/4377 유지, 자동 재개 없음 | PASS |
| RBD export 프로세스 중지 | 새 PID와 listener 자동 생성 | 프로세스 소실 복원 PASS; transient unit mask가 장기 차단을 만들지 못했으므로 장기 중단으로 집계하지 않음 |
| qcow2 복원 데이터 + UI 테스트 페일오버 | Run 289 SUCCEEDED, session 49 ACTIVE/QGA_VALIDATED, VM 250 실제 QGA 응답 및 source marker SHA256 일치 | PASS |
| UI 테스트 정리 | Run 290 SUCCEEDED, session 49 CLEANED/cleanup_required=0, VM250 제거, 볼륨348 Expunged, 자동 증분1369 | PASS |

변경 데이터 SHA256: `0b874d70a3999c69455d16f19c39514f0f9f0502d32debe6f5a8193c1a6c6806`. 대상 게스트에서 직접 확인했으며 원본 시험 파일은 삭제했다. 모든 시험 방화벽 규칙과 scheduler mask를 해제했다.

최종 UI: qcow2 1370 incremental COMPLETED / RUNNING / HEALTHY / RESUMED. RBD는 PAUSED 검증 종료 후 UI 수동 Resume를 실행하여 4378 full-seed COMPLETED / RUNNING / HEALTHY / RESUMED로 복귀했다. 이 수동 Resume는 자동 복원 시험 종료 후 원상 복구이며 자동 복원 성공 근거로 사용하지 않는다.

### 발견 문제 및 남은 검증
- **#972 P1**: worker가 없는 PAUSED에서 수동 Resume 시 유효 baseline 승계가 안 되어 full-seed가 시작되는 별도 현상. 4378은 11:10:46 완료했지만 불필요한 전체 전송은 개선 필요.
- **#973 P2**: 정상 PAUSED가 DEAD/DEGRADED/OVERDUE로 장애처럼 표시되는 문제.
- source 실행 불가 중 UI disaster failover 진입/기존 옵션 유지와 자동화 action 계약을 확인했다. 실제 disaster cutover/failback을 실행한 PASS로 주장하지 않는다.
- 실제 호스트 전원 OFF/재부팅, 모든 Agent·관리망 단절 조합, 양 사이트 복원 순서 전체 조합, VMware/stopped/live migration 전체 실환경 매트릭스는 이번 실행에서 검증하지 않았다. 프로세스/전송 단절 검증을 해당 결과로 대체하지 않는다.
- 따라서 **핵심 정상 유지보수 자동 복원은 위 재현 범위에서 PASS**, upstream 병합 및 잔여 물리 장애/회귀 게이트까지 완료한 상태는 아니다. #969는 열린 상태로 유지한다. 원래 본문의 영구 폐기/fencing 확장 항목도 완료 처리하지 않는다.

로컬 원시 증거: WSL `/home/ablecloud/work/issue969-evidence`의 cloud-build-v2.log, actions.log, deploy-*.log, phase1/phase2 로그·상태 JSON, target-marker.txt. 로그인 비밀값은 문서/이슈에 기록하지 않았다.
