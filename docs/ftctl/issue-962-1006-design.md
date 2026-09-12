# #962 확장 + #1006 수동 정리·보존 정책 설계

## 기준/범위
Cloud f492aa3317e/qemu fe490da(#1020 및 이전 구현 포함)에서 codex/fix-962-1006-checkpoint-cleanup 생성. 기존 삭제 메뉴 상시 활성/확인창 force 옵션 유지. 핵심 수동 복구를 먼저 완성한다.
최근 N/기간 보존 정책에 따른 후보 미리보기 및 명시적 세트 선택 정리를 구현한다. 자동 무인 GC/전체 COW 최적화는 이번 수동 경로의 선행조건이 아니며 별도 잔여 검증으로 명시한다.

## Cloud
관리자 checkpoint 관리 API는 저장된 target disk mapping을 사용하여 live target worker를 선택한다. 사용자 입력 locator나 host를 실행 권한으로 사용하지 않는다. 현재 Plan/Run/활성 test/latest checkpoint를 재검증하고 삭제 요청에는 사유·명시적 선택·미리보기 manifest digest를 요구한다.
force unregister 직전에 자격증명 없는 UUID/대상 자원/위치/미정리 사유 snapshot을 독립 감사 기록에 저장한다. 삭제된 Plan 조회에만 의존하지 않고 잔여 기록을 조회한다. 원격 확인 불가를 정리 완료로 바꾸지 않는다.
기존 sync history와 관리 화면에서 목록/보호 사유/논리 용량·측정 가능한 할당량/정리 결과를 확인한다. 논리 용량을 회수 가능 물리 용량으로 오인하지 않는다.

## FTCTL
새 checkpoint 관리 명령은 Plan 소유의 committed manifest와 실제 artifact를 대조한다. 최신/정책 보존/사용 중 세트는 보호한다. FILE은 공유 저장소 잠금과 overlay pin, RBD는 clone/보호 snapshot 및 공유 잠금으로 다른 호스트 요청과 직렬화한다.
정리 전 DELETING journal을 영속화하고 각 디스크 결과를 기록한다. 중단 후 같은 선택을 재시도하며 모두 완료한 경우만 DELETED. 새 publish/restore가 만료된 identity를 재사용하지 않는다. mutable target/original VM/다른 Plan은 삭제 대상이 아니다.
reflink 경로와 실제 copy의 비용을 구분하며 기존 독립 체크포인트 계약을 보존한다.

## 검증
후보 계산/최신 보호/다중 디스크/다른 Plan/digest 불일치/사용 중 clone·overlay/동시 요청/부분 삭제·재시작·재시도/용량 부족 검증. 기존 action lifecycle/release tombstone 실행.
WSL ext4 변경 Maven 모듈 및 UI build, qemu 파일 직접 배포. 31 qcow2/32 RBD UI 목록·선택·거절·정리/후속 복제와 복구 가능성 확인. VMware 양단 QGA 제외. full release 미실행.
