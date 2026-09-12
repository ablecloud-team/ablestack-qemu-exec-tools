# #970 역방향 export 소유권 상세 설계

## 기준과 브랜치
Cloud c6dceb85f1 / qemu 7bd0017 (#969 배포 검증 누적 기준)에서 각각 독립 WSL ext4 worktree와 codex/fix-970-reverse-export-ownership 생성. 이전 브랜치를 병합하거나 변경하지 않는다. 기능은 누적 기반에 의존하므로 독립 cherry-pick 가능하다고 주장하지 않는다.

## 현재 공백
DrPlanOwnedTransportServiceImpl의 reverse START/STOP은 remote broker가 선택한 단일 worker의 일반 성공만 확인한다. broker는 workerHostUuid를 실행 권한으로 고정하지 않는 반면, 과거 export 소유자 회수 이력도 없다. qemu generation tombstone만으로 원격 다른 worker의 writer 종료를 증명할 수 없다.

## 변경 계약
1. Plan 소유 Cloud가 기존 DrExportOwnershipStore에서 정·역방향 공통 단조 generation을 발급한다. 원격 Cloud의 auto-increment를 섞지 않는다. plan UUID가 generation scope이며 양 사이트 역할 변경에도 같은 소유 Cloud가 발급한다. 역방향 START에는 STOP floor+1, STOP에는 floor를 전달한다.
2. reverse request에 exportAuthorityScope=Plan UUID, exportDirection=REVERSE, exportGeneration, reverseTargetExport=true를 전달한다. STOP도 식별 프로파일을 전달한다. Cloud는 qemu generation/scope/direction ACK와 remote ownership broker protocol을 확인해야 성공한다. 구버전 broker의 일반 성공을 허용하지 않는다.
3. 원본 사이트 FtctlDrSiteAgentBrokerServiceImpl에서 reverse export만 별도 orchestration으로 처리한다. 신규 FtctlDrReverseExportStore는 ftctl_dr_reverse_export 테이블에 Plan UUID, 원본 VM UUID, zone, generation, operation, Run 및 worker별 상태 JSON을 저장한다. 전용 DB global lock으로 여러 관리 서버 요청을 직렬화한다.
4. 초기 legacy 이관은 원본 VM zone의 기존 KVM host들을 UNKNOWN으로 기록하여 STOP 확인한다. 한 번 REVOKED로 확인된 never-owner는 다음 장애 때 필수 ACK로 다시 요구하지 않는다. 새 grant 후보만 실행 전 UNKNOWN/GRANTED로 영속 기록한다. GRANTED/불확실 host는 STOP ACK 전 새 grant 금지. host 삭제/단절/ACK 유실은 fail-closed이며 복귀 후 재시도로 수렴한다. 실제 fencing 시스템을 추가하거나 timeout을 성공으로 바꾸지 않는다.
5. worker는 원본 VM zone의 live eligible pool에서 선정한다. 이전 grant 기록은 회수 의무이며 Plan placement pin이 아니다. 같은 generation/Run 재전송은 동일 grant를 재확인하며 불확실 START 뒤 무조건 다른 worker로 보내지 않는다. 더 높은 generation 요청은 기존 grant 회수 후 새 선정이 가능하다. STOP은 새 worker 선정 없이 이력 회수만 수행한다.
6. 역방향 START 전에 원본 VM의 Stopped 상태를 확인한다. failback의 기존 cutover/authority 조건은 그대로이며 disaster failover에 원본 연결 조건을 추가하지 않는다.
7. qemu dr_export_ownership.py는 scope/direction을 generation에 결합하고 같은 generation의 방향/범위 변경을 거절한다. host-local tombstone은 프로세스/Agent 재시작 후에도 유지한다. 구조화된 protocol 2 ACK는 실제 managed scope/direction을 돌려준다. 기존 정방향 protocol 1 이력은 새 STOP으로 회수한 뒤 이관하며 managed scope를 legacy START가 덮을 수 없다.

## 파일/빌드
Cloud: DrPlanOwnedTransportServiceImpl, ftctl-service broker 및 신규 store/orchestrator, 두 schema SQL(Europa-After/42210to42300), 관련 단위 테스트. schema는 CREATE IF NOT EXISTS로 멱등 설치; 신규 runtime store는 배포 전 schema 확인이 필요하다. WSL ext4에서 변경 Maven 모듈만 build.
qemu: dr_export_ownership.py, dr_ablestack.sh ACK, ownership smoke 및 branch release workflow. Actions 패키지 빌드와 lifecycle/release tombstone/기존 action contract 게이트 실행.

## 검증과 배포
- 단위/스모크: stale/duplicate START STOP, ACK 누락, scope/direction 충돌, 초기 이관, 이전 worker Down/복귀, REVOKED worker Down 비차단, DB 재로드, 현재 원본 VM Running 차단, STOP 시 worker 미선정.
- 기존 sync/pause/resume/test/cleanup/planned/disaster/failback/reprotect/release 계약 회귀. 원본 단절 시 disaster 경로에 새 원본 RPC가 추가되지 않았음을 확인.
- 설치 버전·백업·DB schema 확인 후 원본/대상 관리 모듈과 qemu 배포. UI 정적 파일 수정 없음.
- RBD와 qcow2 UI failover→reverse sync→failback→reprotect를 통해 journal, tombstone, unit/PID/listener, authority, 신규 checkpoint 및 실제 게스트 데이터 확인. 실제 실행한 장애 주입/경로와 자동화 모의 시험을 구분해서 결과 기록. 혼합/VMware 경로 미확인 시 PASS로 집계하지 않는다.
- 발견한 별도 결함은 이슈로 추적한다. 레거시 DR Cluster 활성화 금지.
## 최종 구현 및 검증
- 코드61725fc: ACK protocol2의 scope/direction/generation/state와 같은 generation mapping fingerprint를 검증한다. reverse export 재시작 profile은 변환 전 원래 요청으로 저장한다. 같은 파일 replay 복사를 건너뛰며 복사 오류는 전파한다.
- Actions34431985704 SUCCESS, release tombstone 및 기존 DR action smoke 통과. 최종 RPM SHA2563dd90c877479b32dfbc5a0c4fcd288a73d4b70336fb749a6cc778a90762b0c0e,13/22/31/32 총12호스트 배포.
- 실제 qcow2/RBD UI 전환→페일백→자동 복제 재개 PASS, 반환 데이터 SHA 일치. RBD 동일 START 재전송 시 PID 유지, qcow2 이전 세대 START/STOP 거절·writer 미재생성 확인.
- Cloud 후속#975/#976/#977과 함께 검증했다. 물리 장기 전원 단절, 모든 혼합 경로, VMware UI 전체 회귀는 실측 PASS로 주장하지 않는다.
- 상세 결과: https://github.com/dhslove/ablestack-cloud/blob/codex/fix-970-reverse-export-ownership/docs/ftctl/issue-970-validation-20260910.md