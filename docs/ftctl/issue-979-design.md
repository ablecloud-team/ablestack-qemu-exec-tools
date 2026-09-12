## #979 코드 수준 상세 설계 — 증분 쓰기와 복구 지점 발행 분리

### 기준 및 작업 브랜치
- Cloud: #1004 누적 dd7fde06c4 + 최신 upstream/ablestack-europa bcb52804f3.
- qemu: #1004 누적 75785a36b6 + 최신 upstream/main 9d5f543.
- 양 저장소 모두 codex/fix-979-durable-checkpoint. 기존 작업 브랜치를 변경하지 않고 별도 후속 브랜치에서 병합했으며 충돌 없음.
- VMware 원본/대상 QGA 비필수, 기존 NIC 비활성화 및 강제 삭제 UI 계약 유지.

### 확인한 결함과 핵심 경계
1. dr_scheduler.sh의 run_cycle 이후 append_restore_point는 완료 JSON을 기록하지만 대상의 불변 디스크 세트 발행을 보장하지 않는다.
2. dr_ablestack.sh의 site-agent-nbd는 대상 SSH를 제공하지 않는다. 원본에서 임의 SSH 스냅샷을 호출하는 구현은 사용하지 않는다.
3. dr_runtime.sh / qcow2_checkpoint.py의 기존 테스트 시점 seal을 정상 증분 완료 시점의 보존 증거로 소급 인정하면 안 된다.
4. 다음 주기의 부분 쓰기가 발생해도 이전 COMMITTED 디스크 세트가 유지되어야 한다. 재해 페일오버/체크포인트 테스트는 원본 응답을 기다리지 않는다.

### 구현 단위
**qemu 발행 프로토콜**
- dr_scheduler.sh: 한 주기의 데이터 전송/flush/teardown 완료 뒤 발행 대기 상태를 영속화한다. 대상 ACK 이전에는 다음 쓰기를 시작하지 않는다. 대기 중 재시작도 미완료 발행을 우선 재조정한다.
- 새 target checkpoint helper: plan/producerRun/sequence/ref 및 전체 디스크 식별자에 결합한 세트 manifest를 생성한다. 디스크별 준비 후 마지막에 manifest를 fsync + atomic rename한다.
- RBD: 주기별 스냅샷을 생성·보호하고 세트 전체가 완성된 경우에만 참조를 공개한다. 기존 테스트 seal 식별 규칙과 일관성을 유지한다.
- qcow2: 기존 독립 checkpoint helper를 재사용하되 guest OS 검사를 매 주기 실행하지 않는다. 대상 writer를 drain한 후 독립 파일 및 메타데이터를 보존한다. 파일 복사는 용량/시간 비용이 있으므로 그 비용을 숨기지 않고 실패 시 이전 세트를 보존한다.
- 같은 발행 요청은 멱등 처리한다. 같은 identity에 다른 디스크 세트, 누락된 snapshot/file 또는 부분 manifest는 성공으로 응답하지 않는다.
- 현재 자동 만료/GC는 하지 않고 복구 지점을 보존한다. 보존 정책, 참조 중 세트 보호, 수동 정리 및 파일 복사 비용 최적화는 후속 #1006(P2)에서 구현한다. 공간 부족은 이전 체크포인트 삭제로 무마하지 않는다.

**Cloud / Agent 조정**
- FtctlDrActionCommand 및 KVM wrapper/CLI에 대상 발행/원본 ACK 동작을 연결한다.
- FtctlDrRuntimeProjectionAdapter의 정상 protection 상태 조정 경로에서만 pending 발행을 처리한다. 기존 failover/failback/test/release 작업과 경합하지 않도록 plan 작업/authority를 확인한다.
- 대상 Agent의 세트 발행 증거를 확인한 뒤 원본에 동일 identity ACK를 전달한다. ACK 유실은 재조회/재전송하며 대상 발행을 중복 생성하지 않는다.
- UI의 정상 복구 지점은 세트 증거와 연결한다. 기존 완료 기록만 있는 plan을 immutable 보호 완료로 표시하지 않는다.

**복구 경로**
- 테스트는 이미 보존된 세트로 clone/overlay를 만든다. 다음 주기가 실패했을 때 현재 mutable 디스크를 이전 checkpoint로 다시 seal하지 않는다.
- 실제 재해 전환은 대상 쓰기 권한을 먼저 차단하고 마지막 COMMITTED 세트에서 대상 디스크를 복원한 뒤 기존 부팅/권한 전환 절차로 진행한다.
- 이 경로는 원본 Mold/Agent/VM/vCenter에 접근하지 않아도 실행 가능해야 한다. 원본 단절이 추가 허들이 되면 안 된다.
- 원본/대상 유지보수 후 정상 복제 자동 재개, 기존 PAUSED 의도, 실패 후 수동 정리/강제 삭제를 유지한다.

### 검증 계획 / PASS 기준
- 단위/스모크: 디스크 2개 중 2번째 발행 실패, ACK 유실/중복, 발행 중 프로세스 재시작, 다음 증분 부분 쓰기, 부족 공간, 사용 중 checkpoint GC 보호.
- qemu release tombstone + 기존 full lifecycle contract 회귀.
- 변경 Cloud Maven 모듈만 WSL ext4에서 빌드/테스트. qemu는 shell/Python 검사 후 변경 파일 직접 배포.
- 31 qcow2 / 32 RBD 및 VMware→RBD: UI로 정상 복제 → 체크포인트 발행 확인 → 다음 쓰기 실패/원본 단절 → 기존 복구 지점 테스트 → cleanup → 복제 자동 재개 확인.
- 실제 재해 전환의 대상 디스크 복원 및 부팅도 별도로 확인한다. 테스트 clone만 성공한 경우 재해 전환 PASS로 보고하지 않는다.
- 외부 작업 데이터/기존 진단 artifact는 임의 삭제하지 않는다. 모든 결과는 실행 증거와 함께 이 이슈에 기록한다.

이 설계는 구현 기준이며 아직 배포/기능 검증 완료를 의미하지 않는다.

## 구현 상세 보완 및 검증 진행
- 대상 발행은 비동기 작업으로 시작하고 PREPARING/COMMITTED를 재조회한다. 큰 qcow2 복사가 Cloud/UI 상태 조회를 장시간 점유하지 않게 했다.
- 원본 scheduler의 pending 세트/출력/ACK를 영속화하고 동일 세트를 재시도한다. target export generation이 바뀌면 이전 미확정 후보를 보관 처리하고 full seed로 재시작한다.
- 대상 공유 저장소(RBD image metadata / SharedMountPoint manifest)에 완료 세트 증거를 저장한다. 특정 호스트의 로컬 캐시만을 복구 근거로 사용하지 않는다.
- 새로 ACK된 복구 지점은 FTCTL_DR_IMMUTABLE_CHECKPOINT 유형으로 구분한다. 기존 FTCTL_DR_CHECKPOINT 기록을 소급 변경하지 않는다.
- 불변 복구 지점의 테스트는 existing seal을 사용한다. 재해 전환은 대상 writer를 drain한 후 보존된 세트로 복원하고 기존 전환 절차를 이어간다.
- 체크포인트 보관 수/기간, 사용 중 세트의 GC 경합 보호, 수동 정리 및 qcow2 복사 비용 최적화는 후속 #1006(P2)으로 분리했다. 현재 안전 기본값은 자동 삭제 없이 보존하는 것이다.

현재 확인:
- Cloud core 모듈 빌드, DR 450개 테스트, KVM Agent wrapper 8개 테스트 통과.
- qemu lifecycle 71개, release tombstone, qcow2 checkpoint 17개, 새 checkpoint 12개 테스트 통과.
- 실제 Ceph RBD 및 GFS2에서 각각 2디스크 세트 발행/다른 작업자 재조회/부분 덮어쓰기 후 복원/다음 세트 발행 실패 시 기존 세트 유지 스모크 통과.
- Ceph 신규 이미지의 빈 metadata list 출력 처리 결함을 실환경 스모크에서 발견하여 수정하고 회귀 테스트를 추가했다.
- 시험용 RBD 이미지 2개와 GFS2 시험 디렉터리는 정리했다. 기존 VM 디스크를 이 스모크에 사용하지 않았다.

최종 배포 및 핵심 흐름 검증 결과는 [검증 기록](issue-979-validation.md)에 기록한다.


## 최종 원본 발행 증거 보존
- 원본 pending/COMMITTED ACK와 후보 manifest/checkpoint JSON을 `/var/lib/ablestack-vm-ftctl/dr-checkpoints/<plan>/`에 보존한다. `/run`의 전송 산출물이 없어져도 동일 후보를 재조회할 수 있다.
- export generation 변경 시 미확정 후보를 별도 보관하고 후보 순번보다 큰 순번으로 full seed한다. 이전 후보의 파일 경로나 identity를 재사용하지 않는다.
- forward ABLESTACK 대상에만 적용한다. VMware 역방향 failback/reprotect 쓰기에 forward 발행 barrier를 적용하지 않는다.
- 실제 테스트에서 발견한 VMware 페일백 자격 정보 재해결 누락은 #1008(P1), PAUSED worker 재시작은 #1007(P1), 보존량/GC는 #1006(P2)에서 추적한다.

페일백 이후 forward 프로필에 이전 activeSide=TARGET 값이 남을 수 있으므로 request.reverse 표식으로 실제 역방향을 제외한다. UI 페일백 후 새 불변 체크포인트48 발행으로 이 조건을 실환경 검증했다.
