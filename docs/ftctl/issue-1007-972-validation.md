# #1007 / #972 통합 검증 (2026-09-11)

## 구현 및 소스 보존
Cloud `efc2799265`와 qemu `03a16af4`에서 `codex/fix-1007-972-scheduler-resume`을 생성했다. 이전 변경을 재작성하지 않고 누적한다. qemu scheduler는 기존 PAUSE/STOP/RUN 및 generation을 보존하고 최초 control 생성만 Plan lock으로 보호한다. pause/resume Run은 Plan/sequence/완료 상태/targetDurableAt이 유효한 완료 체크포인트만 승계한다. 새 Run의 식별자와 terminal/authority는 복사하지 않는다. provider baseline 검증은 그대로 적용한다.

## 자동 검증
- WSL ext4 Cloud DR 모듈 Maven package: 451 tests, 실패/오류/skip 0, BUILD SUCCESS. Cloud production 변경이 없어 기존 JAR/UI를 유지했다.
- qemu resume 7 + checkpoint 13 + common baseline 3 = 23 tests PASS. 마지막 수정 후 resume 7 재실행 PASS.
- worker maintenance smoke PASS; full lifecycle 71 PASS; release tombstone PASS; shell syntax 및 git diff --check PASS.
- branch release workflow에 resume 회귀를 추가했다. 이번 shell 모듈 검증은 RPM/full release 빌드 없이 수행했다.

## 직접 배포
13/22/31/32 각 compute 3대, 총 12대의 dr_scheduler.sh/dr_runtime.sh를 백업 후 배포했다. 알 수 없는 기존 해시는 덮어쓰지 않는 검사를 적용했다.
- 백업: `/root/issue1007-972-20260911/modules`
- scheduler SHA256: `aaa2687e76219a9b1c2a28b79c22f91d82dbe6035bf947881b872e5c290aa269`
- runtime SHA256: `6c396012283d897f80f54f96abe27e113fdd92f1b3fe240585ff0efa3362ccaa`
- 이번 시험 Plan의 persistent worker를 재시작했다. 다른 Plan의 이미 실행 중인 프로세스까지 새 코드를 적재했다고 주장하지 않는다.

## UI 및 실제 runtime 검증
| 경로 | Plan | PAUSED 재시작 | worker 소실 후 UI Resume |
|---|---|---|---|
| RBD → RBD | 7ec74483-8554-415d-ac56-f62f8b17fbd0 | 4622 / PAUSED 유지 | 4623 CBT_INCREMENTAL, READY/RUNNING/HEALTHY |
| VMware → RBD | a85874ae-d1bd-470b-97c5-7c48a39486dd | 188 / PAUSED 유지 | 189 CBT_INCREMENTAL, READY/RUNNING/HEALTHY |
| qcow2 → qcow2 | 9a20b190-d202-4b66-9358-b509756f9751 | 1545 / PAUSED 유지 | 1546 CBT_INCREMENTAL, READY/RUNNING/HEALTHY |

qcow2 UI PAUSE Run `4cce0d01-c480-4425-9489-d7f27e962849`, Resume Run `6f96e2f1-5d68-43ca-a445-bc0da79e87b9`가 SUCCEEDED로 완료됐다. UI 조작 후 host status의 체크포인트 증가와 effective mode를 함께 확인했다. RUNNING worker 재시작은 별도 Resume 없이 RBD 4624, VMware 191, qcow2 1547을 각각 CBT_INCREMENTAL로 확정했다. 세 Plan 모두 READY/RUNNING/HEALTHY 및 UI 사용 가능 상태를 확인했다.

## 별도 발견 문제 및 검증 한계
- 원본 13 관리 서버의 DB 연결 풀 고갈(250 active / 0 idle)로 원격 제어 및 체크포인트 승인이 지연됐다. qcow2 최초 Pause는 DR_ACTION_CAPABILITY_UNAVAILABLE로 실패했다. P1 [#1023](https://github.com/ablecloud-team/ablestack-cloud/issues/1023)에 등록했다. 관리 서비스 임시 복구 후 1544/1545가 확정되고 위 시험을 진행했다. 이 수동 서비스 복구를 호스트 장애 무개입 자동복원 PASS로 계산하지 않는다. jstack 부재로 장애 당시 thread dump는 확보하지 못했다.
- 기존 scheduler 상태 표시 불일치는 #973 후속 범위다. PAUSE 보존 판단은 durable command와 실제 cycle 정지로 확인했다.
- 이번 장애 주입은 persistent worker 프로세스 재시작/소실이다. 장시간 물리 호스트 전원 단절, 모든 혼합 경로 및 전체 failover/failback UI 체인을 새로 실행한 결과가 아니다. action contract는 lifecycle 회귀로 확인했다.
- VMware 원본과 대상 모두 QGA를 사용하지 않았다. 원본 단절 재해 전환 계약과 강제 삭제 흐름을 변경하지 않았다.
- Cloud PR #1022의 최신 upstream 충돌 해결과 최종 통합 회귀는 남아 있다. 이 문서의 PASS는 이 변경의 검증 범위이며 PR 병합 준비 완료를 뜻하지 않는다.

로컬 원본 로그: `/home/ablecloud/work/issue1007-972-evidence/` (cloud-build.log, lifecycle.log, tombstone.log, deployment.log 및 경로별 status JSON).
