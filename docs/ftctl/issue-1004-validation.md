# #1004 구현 및 모듈 검증 결과 — 2026-09-10

## 구현
- Cloud/qemu 후속 브랜치: `codex/fix-1004-failed-test-cleanup`. 기준 Cloud `64cbaf84c3`, qemu `858b759`; 기존 #971/#988/#1003 변경 보존.
- 테스트 준비 실패 정리는 해당 run session을 먼저 사용한다. 별도 정리 재시도는 active.json에서 원래 runUuid를 찾아 동일 plan/run의 최신 자원 records를 읽는다.
- RBD 제거 실패는 CLEANED로 위장하지 않고 자원 기록과 cleanupRequired를 보존한다. 다른 계획/소유권이 다른 clone은 거절한다. 진단 로그와 원래 guestprep 종료 코드는 자원 정리 후에도 남긴다.
- Cloud는 최신 TEST_FAILOVER 실패에서 실제 CLEANED/lease RELEASED와 대상 테스트 VM 없음이 확인된 경우에만 저장한 RUNNING/PAUSED 의도를 복원한다.
- **DR 계획 삭제 메뉴는 상태와 관계없이 활성화**한다. 별도 강제 삭제 메뉴는 없으며 기존 확인창의 기본 해제된 **강제 실행** 옵션으로만 `force=true`를 보낸다.
- 강제 삭제는 계획 등록정보 soft delete, admin DISABLED, 대기 복구 의도 SUPERSEDED를 수행한다. VM/볼륨과 runtime/history는 보존한다. 원격 작업이 남아 수동 정리가 필요할 수 있음을 UUID와 함께 확인창에 안내한다. 활성 실행은 먼저 취소/완료해야 하며 메뉴 대신 API가 검증한다.

## 빌드·스모크
- WSL ext4에서 Cloud DR 모듈 컴파일 및 테스트 **448개 PASS**. 전체 Cloud 빌드는 실행하지 않았다.
- UI production build 성공, 메뉴/가용성 단위 테스트 **20개 PASS**.
- qemu 실제 cleanup 함수 회귀 **4개 PASS**: 생성 전 active 정보, 제거 실패 후 재시도, 다른 소유권 차단, stale active→원래 run records 조회.
- 기존 DR lifecycle **71개 PASS**, release tombstone **PASS**. 최종 runtime 보완 후 재실행했다.
- qemu RPM/Actions 빌드 없이 수정 셸 파일을 직접 배포했다.

## 실제 UI/실행 증거
| 항목 | 증거 | 결과 |
| --- | --- | --- |
| 준비 실패 후 실제 rollback 및 자동 RUNNING 복원 | run452 `8058ddea-9bf7-4e94-a338-2fb139737a15`; clone rbd info ENOENT(rc2), 로그 보존, recovery RUNNING/RESTORED | PASS |
| 제거 실패 시 기록 보존 | run453 `c97483ab-f848-4a74-bf64-979601da9a41`; cleanupRequired=1, 실제 clone 존재 및 원래 run records 보존 | PASS |
| 원본 단절 중 UI 정리 재시도 | vCenter 10.10.21.10만 32 관리/3호스트에서 차단. run454 `7f848499-1b52-4d25-a87e-92af3ad4190f` SUCCEEDED; clone ENOENT, active session 없음; 복구 의도 PENDING | PASS |
| 원본 연결 복구 후 자동 재개 | run453/454 intent RUNNING/RESTORED, 추가 Resume 없이 cycle29 durable 17:48:47 KST | PASS |
| 기존 PAUSED 유지 | pause455 후 실패456 `e692bae3-2426-4f9d-a412-1520d8b37b65`; clone ENOENT, intent PAUSED/RESTORED, UI 작업 상태 PAUSED | PASS |
| 단일 삭제 메뉴/강제 선택 | 보호 계획52 일반 삭제는 DR_RUNTIME_RESOURCE_EXISTS, 메뉴·확인창은 열림. 실패 정리 필요 상태에서도 삭제/테스트 정리 메뉴 활성 | PASS |
| UI 강제 등록 삭제 | UI 생성 폐기 계획53 `914593d5-46a7-462f-89f1-db124e85efbc`의 확인창에서 강제 선택→목록 복귀. DB removed 및 DISABLED, 이벤트 Force unregistering. 기존 계획51/52 보존 | PASS |

강제 삭제 실환경 검증은 자원 미생성 폐기 계획으로 수행했고, 보호 중 자원의 일반 삭제 거절은 계획52에서 확인했다. 보호 상태의 강제 guard 우회·runtime 보존은 모듈 테스트로 확인했다. 원격 VM/볼륨 삭제를 검증한 것으로 해석하지 않는다.

## 배포 및 종료 상태
- 31·32 관리 서버: 기존 JAR 백업 후 변경 DR 클래스만 overlay, 변경하지 않은 ZIP entry 동일성 검증. mold active, /client/ HTTP200.
- UI: 두 관리 서버 활성 webapp 정적 파일 반영, WEB-INF 및 기존 config.json 보존.
- 31·32 각 3호스트: 최종 dr_runtime.sh / guestprep.sh 설치 및 SHA256 검증.
  - dr_runtime.sh `0a6e5221b2e1c38fc256b251b6590124b85ab2f701bcd92aa1fe802f56e315e1`
  - guestprep.sh `768f8329e1d9764e3ed27ba06b5ff8b87a6920d354957f0cef2eaf6c1cd62ad9`
- 백업: 관리 JAR 및 호스트 `/root/issue1004-20260910`, UI `/root/issue1004-ui-20260910`.
- 최종 관리 JAR SHA256: 31 `c6f457cdc79786665f2e757961e8b0bd2d19168a61cf2a8364c514e6d5c5b520`, 32 `2909f98338938ad69f246b522dcd4c9372d99707c8d60d0c30333eb5770165ee`.
- 오류 주입 파일 적용/마커와 네트워크 차단 및 복구 타이머 모두 해제. PAUSED 시험 종료 후 fixture 복원을 위한 UI Resume457 성공. 이 조작을 자동 복구 PASS 근거로 사용하지 않았다.
- qcow2 plan6과 RBD plan51은 UI에서 RUNNING/HEALTHY 및 증분 완료를 확인했다. 이번 수정의 실환경 실패/재시도 시나리오는 VMware→RBD에서 수행했다. VMware 양단 QGA 검증은 하지 않았다.
- 이번 run452/453/456의 테스트 clone은 모두 없어졌다. 소유권 기록이 이미 유실된 이전 run440/442 clone은 이번 자동 복구로 제거됐다고 주장하지 않으며 기존 진단 자료로 보존했다. 해당 과거 자료는 별도 수동 정리 대상이다.
- 상세 로컬 증거: `/home/ablecloud/work/issue971-evidence/`의 `build1004-*`, `smoke1004-*`, `test1004-*`, `deploy1004-*`.
