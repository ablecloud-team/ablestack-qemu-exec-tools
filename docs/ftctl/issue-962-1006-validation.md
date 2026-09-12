# #962 확장 + #1006 수동 정리 검증 (2026-09-11)

## 결과와 범위
수동 체크포인트 정리, 보존 후보 정책, 등록 해제 뒤 독립 자원 기록의 핵심 흐름을 구현하고 31 qcow2 / 32 VMware→RBD 실제 UI에서 검증했다. 자동 GC, 원격 orphan 전체 정리 오케스트레이션, qcow2 COW/복사 비용 최적화는 미완료 후속 범위다. 이 두 이슈 전체를 닫지 않는다.

Cloud f492aa3317 / qemu fe490da675 기반으로 각각 `codex/fix-962-1006-checkpoint-cleanup`을 생성했다. 구현 커밋은 Cloud `7fb39670cb44`, qemu `3bf9a18380e8`이다. 기존 통합 브랜치의 모든 조상 변경을 유지한다.

## 구현 계약
- 보존 개수/기간은 수동 후보 계산과 저장에만 사용한다. 자동 삭제하지 않는다. 삭제는 최대 10개의 명시 선택 세트와 사유/확인을 필요로 한다.
- 최신/Cloud 참조 복구 지점, FILE overlay pin, RBD clone 사용 세트는 보호한다. 실행 중 작업·테스트·대상 활성 권한은 backend에서 삭제를 차단한다.
- FILE flock / 갱신형 Ceph lease를 발행·복구·테스트 clone 생성·삭제가 공유한다. 전체 선택의 manifest digest, 계획/디스크/경로 소유권을 첫 삭제 전에 검사한다.
- DELETING/DELETED journal로 부분 실패 후 같은 요청을 재시도할 수 있으며 삭제 identity를 재발행/복구하지 못한다. VM와 mutable 볼륨은 삭제하지 않는다.
- FILE 정리 검사는 소유권·메타데이터·stat에 한정한다. 손상 이미지 부팅/전체 건강 검사 때문에 삭제가 막히지 않는다. FILE 할당량은 회수 가능 용량을 뜻하지 않고 RBD 물리량은 미측정이다.
- 기존 DR 계획 삭제 메뉴/강제 옵션을 유지한다. 강제 등록 해제 시 plan_id FK 없는 dr_event에 계획 UUID·소유 locator·REMOTE_CLEANUP_UNVERIFIED를 남긴다. 자격 증명/전체 profile은 기록하지 않는다. 별도 미정리 자원 목록은 읽기 전용이다.
- Cloud는 기존 Agent 확장 command를 사용하며 변경 DR 모듈만 빌드한다. VMware 원본·대상 모두 QGA 검증에서 제외한다.

## 빌드 및 스모크
- WSL ext4 Cloud DR 모듈 Checkstyle/package: 477 tests, 실패/오류 0, BUILD SUCCESS. 전체 Cloud 빌드 없음.
- UI production build PASS, UI 회귀 5 tests PASS, lint PASS.
- qemu 정리 14 tests PASS; DR lifecycle 71 cases PASS; release tombstone PASS; 기존 immutable checkpoint 13 tests PASS. qemu 패키지 빌드 없이 파일 배포.
- 실제 Ceph disposable 2 images / 4 sets: 두 번째 디스크 clone 보호, 선택 삭제, idempotent retry, mutable 보존, expired 재발행 거절, 65초 lease 갱신 PASS. fixture 정리 완료.
- 미리보기: RBD 280세트 4.57초 / FILE 211세트 0.228초.

## 실제 UI 검증
| 항목 | 31 qcow2 | 32 VMware→RBD |
|---|---|---|
| 미리보기/용량 | 150 GiB 논리 및 할당량 표시 | 100 GiB 논리, 물리 측정 불가 |
| 선택 정리 | 과거 1941, 두 디스크 세트 | 과거 170, 한 디스크 세트 |
| UI/Cloud 수렴 | DELETED / EXPIRED | DELETED / EXPIRED |
| 최신 지점 테스트 | 2016, TEST_FAILOVER SUCCEEDED | 328, TEST_FAILOVER SUCCEEDED |
| 테스트 런 | 5bf7f7c4-5c08-4897-86b1-4437c23023b1 | c8c49552-97d8-47b3-93ae-2d2b2094573a |
| 부팅 증거 | Ubuntu 26.04 guest-ping/osinfo 추가 확인 | POWER_STATE_VALIDATED; QGA 사용 안 함. 게스트 콘솔 로그인은 이번 범위에서 재검증 안 함 |
| UI 테스트 정리 | 913bb8c6-b3b0-4c7f-9d92-554a07e59f35 SUCCEEDED | 388b80d0-ef23-4878-80c1-2a2bf7ac68ff SUCCEEDED |
| 정리 후 복제 | 자동 RUNNING, 새 2017 READY | 자동 RUNNING, 새 329 READY |
| 최종 권한/자원 | READY / SOURCE, test session CLEANED | READY / SOURCE, test session CLEANED |

호스트에서 31의 1941 이미지 2개 부재, 2014/2016/2017 이미지 보존을 확인했다. 32의 선택한 seal snapshot 부재와 mutable RBD image 보존을 확인했다. 두 테스트 domain은 제거됐고 VM DB는 removed/Expunging, cleanup_required=0이다. 별도 복제 재개 조작이나 직접 DB 수정을 사용하지 않았다.

31 보존 개수 5→3 저장 후 재열기에서 유지 확인, 검증 후 5로 원복했다. 최신/보존 대상 선택 비활성화를 확인했다.

31 disposable metadata-only 오류 계획 `866ecedb-3984-4036-a617-450779e86cd5`의 기존 삭제 메뉴→강제 옵션→등록 해제와 목록 제거를 UI로 확인했다. 독립 기록 `5db99d4e-d893-49fb-b6ee-27f67fa7668b`는 plan_id NULL과 미정리 locator를 보존하며 실제 UI의 ‘미정리 자원’ 목록에서도 보인다. 실제 VM/볼륨이 없는 시험 자료로 등록 해제 경로만 검증했다.

## 시험 중 발견하여 이번 변경에서 수정한 문제
1. UI API import 및 중첩 응답 checkpointmanagement.details 해석 오류: getAPI/postAPI와 실제 응답 형식으로 수정.
2. FILE 미리보기에서 전체 이미지 건강 검사를 하여 45초 timeout: metadata/stat 소유권 검사로 변경. 손상된 소유 자료도 정리 가능.
3. Ceph 경로 뒤 nonblocking stdout이 큰 JSON을 부분 출력한 뒤 실패: 출력 FD를 blocking으로 전환하고 flush. 실제 UI에서 동일 삭제 요청을 재시도하여 DELETED/EXPIRED로 수렴. 삭제는 첫 시도에 수행됐지만 첫 실패를 PASS로 세지 않았다.
4. Cloud 오류에 거대한 raw inventory가 포함될 수 있는 경로: bounded error code로 응답. UI는 command별 errortext를 확인창 안에 유지한다. 오류 표시 회귀 테스트 PASS.

## 배포 및 복구 자료
- 13/22/31/32의 12 worker에 6개 qemu 소스 파일 직접 배포, SHA256 일치. 호스트 재시작 없음.
- dr_checkpoint_store.py SHA256 `f25fd73f9df7236209214ef6908d85f01445711b4de77632cf47d43072cbbd88`
- dr_checkpoint.sh SHA256 `9831a426058e4d9b275aedd550ddcf824f73dea2863bec26feed6e86b04806a8`
- 31 관리 JAR SHA256 `472847d429f327722c7306eb53c6df3135a2304a94c4629f5a199c482ca06adb`
- 32 관리 JAR SHA256 `94e85dfbf31fe1ce2e670a46199e937a355ca26b1542fe6768a58f37b0574fa8`
- 관련 DR class/context만 교체하고 다른 JAR entry는 보존. management 재시작 후 실제 DR API/UI 기능 검증.
- 최종 UI index SHA256 양쪽 동일 `9c0390eaca0278892b25ed5e711317d017d9c623aeeb5472777fafb0dee06210`; WEB-INF 유지, /client/ HTTP200, 새 marker 확인. 정적 파일만 갱신했고 최종 빌드 재배포 후 실제 목록도 확인.
- worker 백업 `/root/issue962-1006-modules/`; 최초 관리 백업 `/root/issue962-1006-20260911/`; v2 직전 관리 백업은 WSL evidence의 `management-before-v2-10.10.31.10.jar`, `management-before-v2-10.10.32.10.jar`. SCP/hash 확인 후 반영.
- 31 디스크 부족 대응으로 이전 #1020 백업 한 개를 WSL `31-previous-backups/`로 옮기고 양쪽 hash 검증 후 해당 이전 백업만 서버에서 제거. 활성 JAR/기타 백업 보존.

## 후속 범위와 제한
#962: 독립 잔여 기록에서 원격 재접속 후 실제 정리/재시도/수동 처리 완료 추적 확장.
#1006: 자동 GC는 별도 계약 필요, qcow2 COW/복사 비용 개선 잔여. 이번에는 수동 정리와 사용 중 세트 보호를 완료했다.
실제 migration/원본 단절/페일백 전체 조합은 이번 차수에서 반복하지 않았다. 공유 계약 스모크와 두 경로 최신 복구·정리·복제 재개를 확인한 결과이며 전체 릴리즈 PASS로 표현하지 않는다.

## 증거 위치
WSL `/home/ablecloud/work/issue962-1006-evidence/`: dr-tests-response.log, qemu-cleanup-final.log, qemu-lifecycle.log, qemu-tombstone-final.log, rbd-cleanup-fixture-hardened.log, ui-error-tests.log, ui-build-complete.log, worker-deploy-final-*.log, deploy-v2-*.log, ui-deploy-*.log, final-state-*.log, final-host-*.log, qcow2-test-guest-boot.log. 자격 증명은 소스/문서에 포함하지 않았다.
