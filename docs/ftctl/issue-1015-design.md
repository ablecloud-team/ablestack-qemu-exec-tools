# #1015 코드 수준 설계

## 문제 및 재현
#1008/#1011 검증의 FAILBACK run480 (`c02ea9e0-3ee2-4579-b71c-9c91db1f8a03`, plan52)에서 역복제55와 원본 복귀가 완료됐다. 원본 콘솔 로그인, 대상 작성 파일 SHA256 일치, XFS rw/오류 없음까지 확인했다. 이후 순방향56은 CBT_INCREMENTAL 101,908,480B를 전송하고 LOCAL_DURABLE이 됐지만 durable checkpoint publication의 ACK가 없어 UI가 `RUNNING / protection-resuming / 95%`에 남는다.

## 코드 원인
`FtctlDrRuntimeProjectionAdapter.reconcileCheckpointPublication`은 SYNC/RESUME_SYNC/PAUSE_SYNC 외 모든 projectionRun을 일괄 제외한다. FAILBACK이 이미 원본 권한으로 복귀해 순방향 체크포인트를 기다리는 단계도 제외되어, 보호 재개 완료 조건과 순환 대기한다. `checkpoint-publication.json` seq56의 ack=null을 확인했다.

## 코드 수준 설계
현재 FAILBACK run에 대응하는 active failback session이 `PROTECTION_RESUMING`, commitOutcome/engineAckState 모두 `ACKNOWLEDGED`, targetPowerState=`POWERED_OFF`, sourcePowerState=`POWERED_ON`일 때만 체크포인트 publication을 허용한다. 기존 source authority 보존 조건을 공통 판정 함수로 공유한다. 전환 전/ACK 대기/롤백/재해 페일오버/테스트/해제에서는 기존 제외 규칙을 유지한다. 기존 checkpoint identity, disk-set, target proof digest, ACK 일치 검증은 변경하지 않는다.

## 검증 및 완료 조건
- ACK 완료 failback session에서 publish/ack 실행; 동일 run의 ACK 누락/대상 ON/원본 OFF/다른 단계에서는 실행하지 않는 회귀 테스트.
- DR Maven 변경 모듈만 WSL ext4에서 빌드.
- 31/32 관리 서버의 해당 DR 모듈 클래스 백업/배포 및 서비스 정상 확인.
- 현재 대기 중인 실제 run480이 DB 수동 수정 없이 체크포인트56 확정 → UI SUCCEEDED로 수렴.
- #1008/#1011 실제 페일백 검증을 완료하기 위한 blocker이므로 해당 후속 브랜치에서 함께 해결하고 별도 commit으로 기록한다.

## 우선순위
P1. 페일백 후 실제 서비스는 원본에서 정상이나 보호 복원 완료와 UI 후속 작업이 차단된다. Epic #950. #1013(전체 재동기화 완료 잔류)과 별개인 명시적 run-type gate 원인이다.

qemu 추가 소스 변경 없음. 기존 체크포인트 요청/ACK의 disk-set identity 및 digest 검증을 유지한다.
