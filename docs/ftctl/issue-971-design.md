## #971 코드 수준 설계

기준 Cloud f616359046 / qemu7a0880d (#970 실측 검증 완료), 별도 WSL ext4 worktree와 `codex/fix-971-source-independent-recovery` 생성. 기존 브랜치 병합·수정 없음.

### 안전성 발견과 경계
현재 site-agent NBD 복제는 대상 이미지를 제자리 수정한다. Cloud의 last completed record가 있더라도 다음 cycle의 부분 쓰기가 반영되었을 수 있다. 원본 PAUSE 실패를 무시하고 현재 backing으로 새 snapshot을 만들면 마지막 성공 체크포인트라고 증명할 수 없다. 따라서 source-independent 시험은 **요청한 ref/sequence에 대응하는 기존 immutable 대상 봉인본**만 사용한다. 봉인본이 없는 기존 데이터는 명확한 오류로 차단하며 성공 체크포인트로 포장하지 않는다. 매 cycle immutable publication은 별도 발견 이슈로 추적한다.

### Cloud
1. StartDrTestFailoverCmd: `sourceindependent` Boolean을 명시적 요청에 기록. 기본 false로 정상 PAUSE barrier 유지. true일 때 NIC_DISABLED/격리망 시험만 허용. Cloud VM은 NIC를 생성하며 NIC_DISABLED는 최초 부팅부터 linkState=false인 어댑터로 생성한다. 기존 NO_NIC 값은 이 의미의 호환 별칭이다.
2. FtctlDrUnifiedActionAdapter: sourceIndependent TEST_PREPARE는 source hardware live 조회/검증과 source PAUSE RPC를 실행하지 않는다. 기존 Plan 저장 boot metadata와 target capability를 사용한다. target export ownership STOP/ACK는 반드시 성공해야 한다. request에 `checkpointExistingSealRequired=true`, durable ref/sequence, writer DRAINED 증거를 전달한다. qemu 신규 capability 없으면 차단한다.
3. target-only 실행의 worker/profile 구성에서 source worker 탐색을 피한다. cleanup은 이미 #964의 durable recovery queue를 사용하므로 artifact cleanup 성공과 source resume 대기를 계속 분리한다.
4. cleanup recovery는 최신 PAUSE/RELEASE/FAILOVER/target authority가 우선한다. 원본 연결 실패 중 반복 target export 교체를 피하도록 비동기 재개 워커에서 원본 상태를 먼저 확인한다. 원본에 연결되지 않으면 대상 export 생성 전에 재시도 대기로 남긴다. 연결이 살아 있는 구간의 재개 실패까지 포함하는 영속적인 준비 단계 재사용은 별도 보강이 필요하다.
5. UI: 테스트 모달에 원본 연결 없는 봉인 체크포인트 시험 옵션과 제한 안내. scheduler/RPO 이상 때문에 test 메뉴 자체를 숨기지 않고 유효 target checkpoint를 기준으로 이 모드를 제공한다. 정상 모드의 준비 조건은 API에서 유지한다.

### qemu
1. capability `dr-source-independent-test-v1`을 추가한다.
2. FILE: qcow2_checkpoint.py에 existing-only 경로 추가. plan/ref/sequence/device/path contract hash, checkpoint file/qemu check 및 OS probe를 검증하고 독립 overlay 생성. mutable backing과 비교하거나 새로 seal하지 않는다. 부분/누락/불일치 봉인본은 구조화 오류.
3. RBD: 정상 barrier에서 plan/ref/device로 식별되는 checkpoint snapshot을 생성하고 시험 clone과 별도 보존한다. source-independent 모드에서는 해당 snapshot 존재 확인 후 clone만 생성하며 live image에서 새 snapshot을 만들지 않는다. cleanup은 시험 clone만 지우고 봉인 checkpoint를 유지한다. RBD snapshot 유지/발행 정책은 후속 자동 publication 설계와 연계한다.
4. 정상 테스트·cleanup·failover/failback·release tombstone 회귀 게이트를 유지한다. Disaster Failover에 source RPC를 새로 추가하지 않는다.

### 검증
- 단위: source RPC 호출0, 정상 PAUSE 유지, target STOP 실패 차단, seal 없음/손상/다른 ref 차단, source cleanup 실패는 재개 대기로 분리, 최신 사용자 의도 우선.
- WSL changed Maven modules/UI 빌드, qemu Actions 패키지/필수 smoke.
- RBD 및 qcow2: 정상 UI 시험으로 유효 봉인본 준비, 원래 PAUSED 의도 유지 후 source 관리망 실제 차단. source-independent UI Test/QGA/cleanup 실행, 원본 연결 복구 후 PAUSED 유지 및 RUNNING recovery를 분리 확인.
- source 단절 disaster UI 전환은 명시적 격리 근거와 target-only 경로로 검증. 원본 VM이 통신 단절만으로 중지됐다고 주장하지 않는다. 테스트 VM 네트워크는 격리/NIC_DISABLED 사용.
- 실행한 네트워크 차단/프로세스 중단과 실제 전원 장애, VMware/혼합 미실행 경로는 구분해 보고한다.
### 대상 복구 결과 투영과 시작 검사 보완

실환경 source Mold 단절에서 대상 아티팩트 준비는 성공했지만 PLAN_AUTHORITY 조회가 원본으로 라우팅되어 테스트 VM 생성이 지연되는 것을 확인했다. 원본 독립 Test Failover, Test Cleanup, Disaster Failover는 대상 역할로 작업자를 선택하고 대상 상태/작업 결과를 조회한다. 테스트 작업의 대상 관측 결과로 원본 복제 authority와 restore point를 갱신하지 않는다. API 사전 검사는 해당 작업에 대해 DB 기반 readiness와 blockers를 적용하고 실제 capability 검증은 기존 대상 dispatch 경로에서 수행하여, 관련 없는 원본 capability RPC와 timeout을 기다리지 않는다. Planned Failover와 원본 동기화의 검증 조건은 유지한다.

## VMware 원본·대상 QGA 검증 제외 (2026-09-10 사용자 요구)

VMware에서 복제한 VM은 VMware 원본과 ABLESTACK 대상 모두 QGA 검증 대상에서 제외한다. 대상이 KVM으로 실행되더라도 QGA 필수 옵션이나 guest-ping 성공을 조건으로 사용하지 않는다. 대상 OS 부팅 및 필수 드라이버 동작을 확인하며 QGA 미설치를 제품 실패로 판정하지 않는다. 정상/원본 독립 테스트 페일오버와 재해 전환 검증에 동일하게 적용한다. KVM 원본 경로의 QGA 검증과 구분한다.

## #988: Cloud 관리 테스트의 복제 복원 소유권

모든 TEST_PREPARE에서 이전 RUNNING/PAUSED 의도를 durable store에 저장한다. Cloud 요청은 TEST_PREPARE/TEST_ARTIFACT_CLEANUP에 `sourceSchedulerRestoreManagedByCloud=true`를 포함하고 `dr-cloud-test-recovery-v1` capability를 요구한다. qemu는 이 계약이 있는 cleanup/실패 rollback에서 source scheduler를 직접 재개하지 않는다. 로컬 transition 종료와 checkpoint lease/테스트 아티팩트 정리는 유지한다. 직접 CLI와 계약 없는 요청은 기존 재개 동작을 유지한다.

Cloud 복구 worker가 정상 source profile을 다시 구성한 뒤 RUNNING 의도일 때만 RESUME한다. PAUSED 의도는 재개하지 않는다. 따라서 VMware의 source mover와 target 작업이 같은 host에서 실행되어도 source credential이 없는 target-only profile로 복제를 시작하지 않는다. 대상 정리는 원본의 QGA/연결/자격 증명에 의존하지 않는다. 새 capability가 없는 host에는 이 변경을 보내지 않는다.
## #988 Cloud-managed 테스트 정리 복원 계약
sourceSchedulerRestoreManagedByCloud=true일 때 local cleanup/rollback은 전환 종료와 artifact 정리만 수행하고 source RUN을 보내지 않는다. Cloud durable recovery가 기록한 RUNNING/PAUSED 의도를 적용하고 source 자격 증명을 포함한 정상 프로필을 복원한다. 직접 CLI cleanup은 기존 재개 동작을 유지한다. capability dr-cloud-test-recovery-v1로 혼합 버전을 차단한다. VMware 원본과 ABLESTACK 대상 모두 QGA 검증에서 제외한다.

구현 220c7e9, 회귀 보정 50b7424. Actions 34443556696은 full lifecycle 71 cases, release tombstone 및 전체 gate PASS. 13/22/31/32 총12대 배포. 실환경 RBD RUNNING 자동 복원과 PAUSED 유지 각각 PASS. VMware 외부 스냅샷 충돌(#1001) 및 31 다른 시험용 Cloud JAR 복원 차단으로 나머지 실환경 회귀는 미완료. Cloud docs/ftctl/issue-988-validation.md에 정확한 run과 배포 증거를 기록한다.
