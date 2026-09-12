## #968 코드 수준 상세 설계

기준 Cloud b987aab7b4 (#964 누적), qemu 2e78369 (#961 코드 포함). 각각 codex/fix-968-export-ownership 후속 브랜치에서 구현한다. upstream 미병합 수정은 보존한다.

### 확인된 원인

DrPlanOwnedTransportServiceImpl의 forward START/STOP은 resolveWorkerHostId(TARGET)가 고른 한 호스트만 호출한다. 과거 worker의 RUNNING intent는 남아 있고 dr_ablestack.sh reconcile이 이를 다시 기동할 수 있다. stop_item은 systemctl/kill 오류를 무시하고 종료 검증 없이 manifest를 삭제한다.

### Cloud 변경

- DrExportOwnershipStore: 전환마다 DB auto increment 기반 단조 증가 generation을 발급하고 plan별 과거 대상 host 집합을 영속화한다. host는 실행 위치 고정이 아니라 회수해야 할 쓰기 권한의 이력이다.
- 신규 grant 전에 대상 zone의 모든 등록 KVM worker(Down 포함)와 과거 발급 host의 합집합에 revoke를 수행한다. 대상 VM의 현재 배치와 무관하다. 누락/제거된 과거 host나 단절 worker는 fence 증거 없이 성공으로 간주하지 않는다.
- generation 2N의 STOP을 모든 후보가 실제 종료 확인으로 응답한 후, live placement로 선택한 worker에만 generation 2N+1의 START를 허용한다. 이후 전환은 항상 더 큰 generation을 사용한다. 지연 도착한 이전 START/STOP은 qemu에서 거절한다.
- 응답의 ownership protocol version/generation을 검증해 구형 Agent/engine의 일반 ok를 회수 증거로 사용하지 않는다. 실패는 DR_EXPORT_OWNERSHIP_PENDING 및 worker 정보를 포함해 기존 Run 오류/복원 PENDING 경로에 전달한다.
- 실제 failover의 reverse baseline 생성은 모든 writer drain 후 선택된 worker에서만 실행한다. test cleanup은 baseline 생성을 요구하지 않는다.

### qemu 변경

- 기존 plan transition flock 내부에서 영속 ownership generation/state tombstone을 검사하고 원자적으로 갱신한다. STOP을 durable 기록한 뒤 프로세스를 종료한다. 구형 generation 없는 명령은 아직 managed ownership이 없는 기존 plan에서만 호환된다.
- 같은 generation의 동일 operation은 멱등, 낮은 generation 또는 같은 generation의 상충 operation은 거절한다. reconcile의 과거 profile도 동일 gate를 통과해야 한다. STOP 뒤 재시작으로 옛 RUNNING intent가 살아나지 않아야 한다.
- STOP은 runtime 및 영속 manifest를 이용해 정확한 plan/device unit/PID를 찾고 종료를 검증한다. PID 재사용/무관한 process는 종료하지 않으며, 종료를 증명할 수 없으면 실패한다. manifest 누락 상태도 영속 증거를 확인한다.
- 기존 RBD/qcow2 transport와 source outage 계약은 유지한다. 원본 VM/볼륨 삭제나 전체 qemu-nbd kill은 사용하지 않는다.

### 검증/배포

Cloud 변경 DR/schema 모듈은 WSL ext4에서 빌드한다. qemu는 branch release Actions로 빌드하며 generation/reconcile/stop 실패/무관 PID 회귀를 release gate에 추가한다. 기존 tombstone/lifecycle/RBD/qcow2/source outage smoke를 실행한다.

32 RBD 기존 이중 export를 UI test failover drain으로 회수하고 cleanup 후 단일 export 및 새 durable incremental checkpoint를 확인한다. 31 qcow2도 회귀한다. PAUSED 유지, 지연 명령, worker 단절/복귀 및 Agent 재시작의 결과를 별도로 기록한다. 백업 후 qemu를 먼저 배포하고 Cloud를 배포하여 구형 엔진 응답을 성공으로 오인하지 않도록 한다. 검증 전 PASS를 선언하지 않는다.

범위: 발견된 forward 대상 writer 경로를 우선 수정한다. reverse export는 원본 site의 별도 권한이므로 forward host 이력을 적용하지 않으며, 기존 reverse/failback 회귀로 보존한다.
## 구현 상세 보완 및 검증 기록

Cloud 구현 42c43766c1: 신규 dr_export_transition과 dr_export_host_history, DrExportOwnershipStore, forward revoke/grant 응답 검증. 복원 PENDING의 worker/generation 사유는 DrTestCleanupRecoveryStore와 DrResponseGenerator를 통해 기존 UI에 표시한다. 최초 Checkstyle 실패는 #964 테스트의 wildcard import였으며 명시 import로 수정했다. 최종 DR 모듈 424 tests/0 failures/0 errors, schema 모듈 빌드 성공.

qemu 구현 d9ff729 및 1816fe6: generation tombstone, stale START/STOP 거절, 정확한 PID/unit 종료 검증. 추가로 시작 도중 manifest 발행 전에 중단된 경우 영속 profile의 device로 unit을 재구성한다. corrupt manifest/다른 Plan 또는 unit 증거는 fail closed한다. 회귀 8개를 Actions RPM 생성 전 gate에 추가했다.

실환경 32 RBD: 기존 32.1 및 32.3 이중 export를 확인한 뒤 UI PAUSE402, TEST403 실행으로 세 호스트 모두 generation2 STOP 및 unit inactive 확인. CLEANUP404 성공, PAUSED 유지, checkpoint4356 불변. 이전 worker의 낮은 generation START는 DR_EXPORT_STALE_GENERATION / exit93으로 거절. UI RESUME405 이후 32.1만 generation5 START, 32.2/3은 generation4 STOP, checkpoint4357 durable 및 UI incremental READY 확인. 실제 데이터 손상은 관측되지 않았다.

RBD TEST406 및 qcow2 TEST287은 UI에서 QGA_REQUIRED/QGA_VALIDATED/SUCCEEDED 확인. 최종 패키지 적용 후 cleanup 및 새 durable checkpoint를 추가 확인한다. 완료 전 결과를 PASS로 기재하지 않는다.

원격 관리 서버 백업 /root/issue968/backup, host 스크립트 백업 /root/issue968/ftctl-before.tgz. 배포는 기존 management JAR 6개 class/resource overlay이며 변경 외 entry를 바이트 비교했다. Cloud 전체 RPM 빌드를 하지 않았다. UI 정적 파일은 이번 이슈에서 변경하지 않았다.

롤백 시 Cloud DB generation/history와 host ownership tombstone을 임의 삭제하지 않는다. fencing을 이해하지 못하는 구형 qemu로 되돌리려면 모든 해당 writer를 먼저 정지/검증하고 보호 동기화를 중지한 통제된 절차가 필요하다. 단순 파일 제거로 stale writer를 다시 허용해서는 안 된다.

안전상 이전 worker 단절/삭제를 회수 완료로 간주하지 않는다. host 이력은 실행 placement가 아니라 미회수 가능성을 확인할 의무이며, source VM host binding을 추가하지 않는다. 역방향 원본 site export는 기존 계약을 유지한다. 전체 VMware/worker 이동/실호스트 장애 조합의 실환경 PASS를 주장하지 않는다.
## 최종 검증 완료 (2026-09-10 KST)

| 환경/시나리오 | 테스트 → 정리 | 결과 |
| --- | --- | --- |
| RBD 기존 이중 export, PAUSED | 403 → 404 | 두 writer 회수, 3개 host STOP, checkpoint4356 및 PAUSED 유지 |
| RBD RUNNING, QGA_REQUIRED | 406 → 407 | cleanup09:20:33 → checkpoint4358 durable09:20:45, 12초 자동 증분 복귀 |
| qcow2 RUNNING, QGA_REQUIRED | 287 → 288 | cleanup09:20:42 → checkpoint1350 durable09:20:53, 11초 자동 증분 복귀 |
| RBD runtime/영속 manifest 누락, PAUSED | 409 → 410 | profile 기반 실제 writer 회수, QGA_VALIDATED, 정리 후 PAUSED 유지 |

RUNNING 두 시험은 cleanup 이후 추가 RESUME/Full Sync/DB 수리/서비스 재시작 없이 자동 복귀했다. 마지막 누락 시험은 PAUSED 의도를 확인한 뒤 UI RESUME411로 시험 전 RUNNING 상태를 복원했고 checkpoint4359 영속화를 확인했다.

최종 RBD 32.1만 generation13 START, 32.2/32.3 generation12 STOP. 낮은 세대 START와 STOP을 설치된 CLI에 전달했을 때 exit93으로 거절하고 현재 writer PID를 보존했다. 구 worker32.3 Agent 재시작 후에도 STOP 유지, VM inventory 불변을 확인했다. 무관한 qemu-nbd PID/명령 해시도 검증 구간 전후 동일했다.

최종 qemu [Actions34420373232](https://github.com/dhslove/ablestack-qemu-exec-tools/actions/runs/34420373232) 성공, source1816fe6f8d28fc2e1f042408c3b3f8d47adfd41f. RPM SHA256 `4f0796bc8d0fea0eff44cc4a438a366f08b6e5250970bcbb0302d07038296ece`. 31/32 각3개 호스트 배포 및 설치 script/VM inventory/agent.properties 검증. 초기 빌드34419167959는 최종 산출물이 아니다.

Management JAR SHA256: 31 `56d9125224ff58e08784bd74f539f596e35d61c84ac71a9d31f612c40181cd55`, 32 `ebd6f8c40833e8646a70d72f655c9182a18b6fdfb4ea7b30e9a59092c56d177e`. 서비스 active, /client HTTP200, WEB-INF 보존. 최종 host 백업은 /root/issue968-v2/ftctl-before.tgz. 두 manifest는 장애 재현 증거로 /root/issue968-v2/manifest-loss에 격리했고 정상 경로에는 새 generation의 manifest가 재생성됐다.

테스트 VM249(31), VM301/302/303(32)의 session CLEANED 및 cleanup_required=0, VM/볼륨 제거 상태를 확인했다. 모든 해당 호스트에서 domain 부재와 qcow22개/RBD3개 임시 이미지 부재를 확인했다. 보호 replica와 durable checkpoint는 보존했다.

전체 lifecycle70, release tombstone, remote RBD, qcow2 shared, source outage 스모크 PASS. host 단절/삭제·구형 프로토콜 거절은 자동 테스트로 검증했다. 실제 장시간 호스트 장애/fencing 및 전체 VMware/역방향 실환경 매트릭스는 이번 PASS 범위가 아니다. Upstream 병합은 별도 완료 조건이다.

증거 위치: /home/ablecloud/work/issue968-evidence (build-final.log, schema-build.log, final-31/32-db.txt, final-32-exports.txt, manifest-loss-pre/drain.txt, stale-start/stop-final.txt, agent-restart-32-3.txt, cleanup-31/32-hosts.txt, deploy-v2-*.log).