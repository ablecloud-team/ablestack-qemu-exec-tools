# Cloud C4 조회 실행 경로

관련: https://github.com/ablecloud-team/ablestack-cloud/issues/1174
기준: Q4/SELinux PR #71 commit `610b106ad9ab6939a2c22752555c70d61af83ff0`.

Cloud Agent가 고정 CLI에 `--cloud-read-guard-fd 9`를 붙여 호출한다. FD9는 Agent가 실행한
관리 자식 프로세스에서 획득한 기존 VM별 flock이며, guest 실행 완료까지 동일 open-file description을 유지한다.
root/regular/inode/쓰기 권한과 실제 배타 잠금 소유를 확인하고, 부모의 열린 stdin pipe도 확인한다.
환경 변수 또는 옵션 하나만으로 독립 잠금 획득을 우회하지 않는다. 부모 채널 종료/추가 입력을 거부한다.
standalone 호출은 기존대로 자신의 flock을 획득한다. 변경 작업은 여전히 비활성이다.

host의 domain UUID/Running/job/block-job 검사와 Q4 UNKNOWN lease를 유지한다.
Cloud 호출은 VM당 새 수집5초 간격을 호스트에서 추가 검사한다. 관리 서버 간 요청에도 동일하게 적용된다.
Agent가 기존 monitoring admission을 보유하며, qemu의 기존 transport admission도 유지한다.
Cloud host/placementGeneration은 읽기 요청의 관리 서버 권위이고 qemu가 독자적으로 Cloud DB를 조회하지 않는다.
관리 서버는 응답 전 실제 현재 배치를 재검증한다. mutation fencing 완료를 뜻하지 않는다.

전역 opt-in `vm.process.management.enabled=false`는 Cloud API/server가 소유한다.
root 운영자의 standalone vm_exec 사용은 Cloud 설정으로 제한하지 않는다.

검증: Linux flock/부모 pipe/inode/권한/독립 FD 거부7개 테스트, 기존 transport14개 및 collector14개 테스트.
실제 Rocky10.2/Ubuntu26.04/WindowsServer2025 VM에서 Agent와 같은 상속 경로 수집 및 C1 schema 검증 통과.
이번 변경은 해석 실행하는 호스트 Python 스크립트뿐이다. ISO/native helper/SELinux 정책 변경은 없으며,
31.1/31.3 호스트에 백업 후 스크립트를 직접 배포한다. 패키지 전체 빌드는 수행하지 않는다.
