# #1030 / #1031 / #1032 구현 및 검증 기록 (2026-09-11)

## 범위와 기준선
Cloud ed40c8b74d, qemu 091a8da에서 각각 codex/fix-1030-checkpoint-producer를 생성했다. 기존 PR #1022/#56의 변경을 포함하며 upstream 병합/강제 push는 하지 않는다.

- #1030: producer Run과 제어 Run 분리, 잘못된 pending candidate의 무한 종료 방지, 명시적 새 전체 재동기화에서 거절 증거 보존.
- #1031: 정상 단일 LIVE scheduler를 미정리 작업으로 오인하던 메뉴 차단 해소. 실제 저장 status_json에 raw reconciliation flag가 없는 경우도 검증.
- #1032: 새 source/coordinator 역할의 과거 내부 STOP 해소, RECOVER_SYNC publication 허용, 이동 전 원본 부재 오류보다 정상 worker 우선, profile cycle 식별자 보존과 imported NBD 검증의 과장 방지.
- VMware 원본/대상 QGA 사용 없음. VM host를 미래 실행 권한으로 저장하거나 migration을 금지하지 않는다.

## 빌드 및 로컬 회귀
- WSL rocky ext4 clone에서 DR Maven 모듈 package: 456 tests PASS.
- FTCTL service Maven 모듈 package: 82 tests PASS.
- producer writer 5 tests, resume 10 tests, checkpoint 13 tests PASS.
- lifecycle 71 cases, release tombstone, worker maintenance, relocated baseline(CBT_INCREMENTAL/profile redaction), source outage PASS.
- 기존 producer writer는 재현 테스트 2 실패, RECOVER_SYNC 승인 누락은 1 실패, broker 이전-host 우선 문제는 1 실패를 확인한 뒤 수정했다.
- 전체 Cloud 빌드 및 qemu RPM 빌드 없음. qemu는 셸 파일을 직접 배포했다.

## 배포
- 13/22/31/32의 각 compute 3대, 총 12대: dr_ablestack.sh, dr_checkpoint.sh, dr_runtime.sh, dr_scheduler.sh. runtime은 v6, 최종 scheduler는 v7 백업(/root/issue1030-v7-20260911/modules)을 남기고 bash -n 및 SHA256을 확인했다. 최종 qemu 소스는 6032d06이다.
- 관리 4대: DrPlanServiceImpl, FtctlDrRuntimeProjectionAdapter, FtctlDrSiteAgentBrokerServiceImpl 클래스를 선택 교체. 관련 없는 fat JAR entry는 그대로 보존했다. UI 정적 파일 및 WEB-INF 변경 없음.
- broker의 기존 의존 클래스가 13/31에 없어 일시적인 ftctl-service/DR 기동 실패가 발생했다. FtctlDrReverseExportCoordinator/Store/Journal와 Spring 등록을 추가했고 schema ftctl_dr_reverse_export도 확인했다. 22/32 의존성은 이미 동일했다. 최종 broker 배포는 v7이며 Cloud 소스는 79b6e38668이다. 22에서는 추가로 기존 패키지에 DrTestCleanupRecoveryStore/Intent, DrExportOwnershipStore가 누락돼 DR 모듈 시작이 실패했다. v8/v9로 해당 클래스와 개별 Spring bean만 추가하고 dr_test_cleanup_recovery, dr_export_transition, dr_export_host_history를 저장소 DDL대로 확인했다. 관련 없는 JAR entry와 WEB-INF는 보존했다.
- 31번 디스크 부족으로 최초 임시 JAR 작성은 교체 전에 중단됐다. 이번 작업의 이전 백업만 WSL로 이동하고 SHA256 일치를 확인했다. /home/ablecloud/work/issue1030-evidence/31-backups에 보존한다.
- 이 배포 검증 개선은 #1033(P2)에 등록했다.

## UI 및 runtime 결과
| 경로 | 실제 수행과 증거 | 결과 |
|---|---|---|
| qcow2 | UI Pause/Resume, 기존 worker 562a81d3 유지. 1560 CBT_INCREMENTAL, 변경 2424832 bytes, target durable 확인 | PASS |
| RBD | UI Pause/Resume 기존 worker 유지. Pause 후 해당 worker 소실을 재현하고 UI Resume 0474aea3로 새 worker 기동. 4641 이후 4652 READY 증분 완료 | PASS |
| VMware | 기존 worker Pause/Resume 및 Pause 후 worker 소실/Resume. 새 worker 0011e840, 211 NO_CHANGE 및 후속 221 CBT_INCREMENTAL READY | PASS |
| qcow2 오류 상태 정리 | UI 전체 재동기화 42e7c5fd가 처음 DR_RUNTIME_NOT_CREATED로 실패했다. 실제 1560 원본 증거로 손상 snapshot을 수동 복원한 뒤 1572 READY/HEALTHY에 도달했다. 이후 DB에서 Run이 SUCCEEDED로 재투영됐지만 최초 실패를 제외하지 않는다 | 시험 준비 복구. 자동 복원 PASS에 포함하지 않음 |
| qcow2 내부 STOP 복원 | 13.1→13.2 UI 이동. 13.2에 과거 내부 STOP을 시험 전 재현. 최종 v7 활성화를 위한 13.1 scheduler 재시작 이후 Cloud가 08bb25f0 worker를 자동 생성, 1897 READY/SUCCEEDED 및 1898 완료 | 배포 재시작을 포함한 자동 복원 확인 |
| qcow2 최종 반복 이동 | 최종 배포 후 UI에서 13.2→13.1 이동. 이후 수동 DR 명령/파일 수정/서비스 재시작 없이 RECOVER_SYNC af43a8fe, b0edf844 자동 실행. 기존 producer 42e7c5fd 재사용, 체크포인트 1638 CBT_INCREMENTAL(655360 bytes), 대상 영속화 11:38:17 KST. UI WITHIN_RPO/RUNNING/HEALTHY/IDLE/RESUMED, runtime recovery SUCCEEDED | PASS |

## 기존 손상 상태 한계 및 후속
수정 이전 producer에 이미 REDACTED cycle 식별자와 불완전한 verified snapshot이 남은 경우 Agent가 상태 전체를 거절하여 새 candidate 승인까지 막았다. 기존 UI 전체 재동기화만으로 이 과거 상태를 정리하지 못한 사례는 #1034(P1)에 별도 등록했다. 원본 호스트의 실제 완료 증거/파일을 검증해 현재 시험 상태를 복구했으며, 복구 지점이나 VM 디스크 데이터를 추정/수정하지 않았다. 이 수동 복구를 자동 복원 또는 UI-only PASS로 주장하지 않는다.

원시 로그와 상태 증거는 /home/ablecloud/work/issue1030-evidence에 있다. 서비스 시작 중 발생한 실패, 재시도, 최종 검증을 구분해 보존한다. #967의 일반적인 요청 성공/데이터 완료 표시 문제나 모든 스토리지 경로의 실제 live migration을 이번 검증만으로 완료 처리하지 않는다.

## 반복 이동 판정 주의
체크포인트 sequence는 producer별 값이다. 08bb25f0의 1898과 42e7c5fd의 1638을 숫자만 비교해 데이터 후퇴로 판단하지 않는다. 실제 현재 디스크 전송, producer identity, candidate 승인, 대상 영속화 시각을 함께 확인했다. 반복 이동 중 오래된 재시도 번호를 의심했으나 실제 전송 및 승인이 완료됨을 확인했으므로 불필요한 candidate 폐기 코드를 추가하지 않았다. 전체 스토리지 경로의 live migration, 중단/재개, 재해 페일오버 전체 행렬을 모두 실환경 PASS로 주장하지 않는다.

추가 최종 회귀: rc110 재시작 반복 방지 테스트(old baseline 실패/수정 PASS), lifecycle 71, release tombstone, maintenance PASS. #1034(P1: 기존 손상 증거 UI 복구), #1033(P2: 배포 의존성/스키마/공간 사전 점검)는 별도 후속이다.

최종 상태 조회에서 RBD 4656, VMware 226 모두 CBT_INCREMENTAL/READY/HEALTHY/IDLE를 확인했다. 22 DR projection이 참조하는 DrHardwareCompatibilityPolicy도 기존 JAR에 없어 v10에서 추가했다(별도 Spring bean이 필요 없는 static helper).

## 최종 서비스/API 검증
13/22/31/32 모두 mold active, /client/ HTTP 200, WEB-INF 보존, 최종 배포 기동 이후 module start failure 없음. 22/31/32 인증 listDrPlans 정상 응답. 13은 원본 broker 기능으로 실제 자동 복구를 수행했지만 listDrPlans는 Unknown API command(432)이며 관리형 DR API 전체 지원을 검증한 서버가 아니다. 역할별 API 등록 검증은 #1033에 반영했다.

PR 반영은 기존 head의 조상 관계 확인 후 fast-forward push로 수행했다. Cloud PR #1022는 기존 upstream 충돌(CONFLICTING), qemu PR #56은 MERGEABLE이며 병합하지 않았다.
