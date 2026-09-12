# #1015 검증 완료

- 변경 Cloud DR 모듈 WSL ext4 Maven install BUILD SUCCESS,451 tests/0failure/0error/0skip. 새 원본 복귀 publication 회귀와 기존 disaster/release 제외 계약 통과.
- source-restored session 판정은 기존 권한 보존 조건과 공통 함수 사용. 다른 run의 session을 재사용하지 않고 active session을 현재 runId로 조회.
-31/32 management JAR의 projection class7개만 교체, 나머지 entry 동일성 확인. outer class SHA256 `ce2ef145db242ba591846125e5280602c254b33d10e2829cdc402b997873e0dd`.
- 두 서버 mold active, /client HTTP200, WEB-INF 보존, 최근 클래스 로딩 오류0.
- run480 c02ea9e0-3ee2-4579-b71c-9c91db1f8a03: 배포 전 protection-resuming95%, forward56 LOCAL_DURABLE/ack=null. 배포 후 DB 수동 수정 없이 2026-09-10 21:41:21 KST UI SUCCEEDED/100% 자동 수렴. failback session59 COMPLETED/ACKNOWLEDGED.
- 이후 checkpoint57 READY, scheduler RUNNING/HEALTHY, failback COMPLETED, source POWERED_ON/target POWERED_OFF, NBD DRAINED.
- 원본 콘솔 XFS rw, 실패서비스0, XFS 오류검색 없음 및 대상→원본 marker SHA256 동일(#1011 검증 기록 참조).
- 기존95% 작업을 배포 재기동 후 복구한 검증이며, 재기동이 없었던 전체 체인 PASS로 표현하지 않는다.
