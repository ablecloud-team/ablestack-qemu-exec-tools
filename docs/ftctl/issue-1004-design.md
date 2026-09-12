# #1004 코드 수준 설계 및 사용자 복구 경로

## 범위
핵심 실패 흐름과 사용자 정리/강제 삭제를 우선한다. 모든 장애 조합의 자동 복구를 구현하는 과제로 확대하지 않는다. 기존 #971/#988/#1003를 포함한 Cloud64cbaf84c3/qemu858b759에서 각각 codex/fix-1004-failed-test-cleanup 브랜치를 생성했다. 기존 브랜치 병합 없이 누적 변경을 보존한다.

## qemu
- dr_runtime.sh cleanup: 해당 run session을 우선 읽고, 별도 TEST_CLEANUP은 active.json이 가리키는 원래 run session을 다시 읽는다. active.json이 materialization 이전 정보인 경우에도 최신 자원 records를 사용한다. plan/run 소유권이 다른 session은 정리하지 않는다. 실패 시 원래 records를 덮어쓰지 않는다.
- RBD clone 삭제와 실제 부재 확인, file artifact 소유 경로 확인. 제거 실패는 cleanup_required=true 및 FAILED로 보존하여 UI에서 정리 재시도 가능. 정상 복제본/retained checkpoint는 제거하지 않는다.
- 실패 후 자동 rollback이 성공한 경우 CLEANED/lease RELEASED를 남긴다. Cloud-managed 복제 재개는 Cloud가 담당한다.
- guestprep 원래 종료 코드와 run별 안전한 진단 로그 보존. profile/credentials를 로그에 쓰지 않는다.

## Cloud
- FtctlDrRuntimeProjectionAdapter: 현재 TEST_FAILOVER 실패에서 검증된 CLEANED 증거와 Cloud VM 없음이 확인되면 기존 RUNNING/PAUSED intent를 arm. 실제 잔여 자원은 FAILED/cleanupRequired를 유지하여 기존 테스트 정리 UI/API 경로를 재사용.
- 늦은 과거 실패가 신규 작업 의도를 복구하지 않도록 latest run 검사. recovery worker는 삭제/비활성/대상전환 계획을 SUPERSEDED 처리.
- 강제 삭제: deleteDrPlan(force=true), Admin 전용. 활성 실행 중에는 취소/완료가 먼저 필요하다. 정상 삭제의 runtime resource guard는 유지하고 강제 모드만 등록정보 soft delete를 허용한다. admin DISABLED 및 pending/held 복원 intent SUPERSEDED로 Cloud 자동 복원을 차단한다. 원격 ACK나 원본 접속은 필수가 아니다.
- 강제 삭제는 VM/볼륨/원격 scheduler의 제거를 성공으로 위장하지 않는다. 원격 작업이 남을 수 있고 수동 정리가 필요하다는 안내와 계획 UUID를 확인창에 표시한다. 기존 runtime/history는 강제 삭제 시 감사·수동 정리 근거로 보존한다. API 이벤트에 forced mode를 기록한다.

## UI
- 기존 테스트 정리 메뉴가 실패+cleanupRequired 상태에서 열리는지 검증한다.
- 기존 DR 계획 삭제 메뉴는 계획 상태와 관계없이 항상 활성화한다. 별도 강제 삭제 메뉴는 만들지 않는다. 삭제 확인 대화상자에 기본 해제된 강제 옵션을 제공하며, 선택한 경우에만 force=true를 전송한다. 등록정보 삭제 범위, VM/볼륨 보존 및 원격 자원 수동 정리 필요성을 표시한다. 메뉴 접근성과 실행 안전 검증은 분리하여 활성 실행이 있는 경우 API에서 취소/완료를 안내한다.

## 검증/배포
Cloud DR 모듈 WSL ext4 빌드/테스트, UI 빌드/행동 테스트. qemu는 사용자 지시대로 RPM빌드 없이 수정 파일 직접 배포; failure cleanup/기존 lifecycle/release tombstone 스모크 실행.
실환경 UI: guestprep 실패→자동 정리·RUNNING 복원, 정리 실패→사용자 재정리, PAUSED 유지, 원본 단절 중 정리, 폐기용 실패 계획 강제 삭제. VMware 양단 QGA 제외. 기존 qcow2/RBD 핵심 경로 회귀. DB 직접수정은 검증 근거로 사용하지 않는다.
