# ablestack_v2k Test Runbook

이 문서는 `ablestack_v2k`의 기능 검증용 테스트 절차를 정리한 문서입니다.

- 수동 단계별 시퀀스 테스트
- `run(auto)`의 `full / phase1 / phase2` 테스트
- `qcow2/file` 회귀 확인
- `rbd map` 기반 cutover 확인

상세 절차는 [examples/v2k/runbook.md](/c:/Users/ablecloud/Documents/GitHub/dhslove/ablestack-qemu-exec-tools/examples/v2k/runbook.md) 와 별도로
[test_runbook.md](/c:/Users/ablecloud/Documents/GitHub/dhslove/ablestack-qemu-exec-tools/examples/v2k/test_runbook.md)에 정리한다.

Compatibility profile 자산을 미리 준비할 때는
[assets/compat/README.md](/c:/Users/ablecloud/Documents/GitHub/dhslove/ablestack-qemu-exec-tools/assets/compat/README.md)
의 레이아웃을 따른다.

설치 전에 아래 명령으로 profile별 asset 탐지 결과를 먼저 확인한다.

```bash
bin/v2k_test_install.sh --list-profiles
```

핵심 검증 포인트:

- `qcow2/file` 기존 경로 회귀 없음
- `rbd`는 `rbd map` 기반 block device로 sync / bootstrap / cutover 수행
- cutover 직전 persistent map 생성
- `manifest.runtime.rbd.mapped` 기록
- libvirt XML의 `<disk type='block'>` 반영
- VM 기동 이후 활성 RBD map 자동 unmap 금지
