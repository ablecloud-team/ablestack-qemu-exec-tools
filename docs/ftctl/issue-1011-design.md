# #1011 VDDK 스냅샷 부분 쓰기 손상 수정 설계

## 실증 원인
FTCTL `dr_kvm_vmware_mover.sh::ftctl_kvm_vmware_start_writer`가 writable VDDK에 `single-link=true`를 전달한다. 시험 호스트 nbdkit 1.38.5 / vSphere80 VDDK에서 스냅샷 VMDK의 부분 쓰기가 부모에서 상속된 인접 섹터를 보존하지 못하는 현상을 재현했다.

별도 poweredOff 64MiB VM `issue1011-vddk-sector-repro` (vm-62880)에 1MiB 0x5a 패턴을 기록하고 스냅샷을 생성했다. 기존 옵션으로 offset512의 512바이트만 0x6b로 쓴 후 해당 영역 readback은 성공했지만 offset0의 기존 0x5a 패턴은 소실됐다. 같은 시험에서 `single-link=false`는 수정 영역과 앞뒤 64KiB 내 비수정 영역 모두 보존했다. 기존 쓰기 영역만의 verify가 이러한 인접 영역 손상을 발견하지 못한다.

실제 plan52 보존본에서도 페일백 직전 checkpoint45 및 reverse46에 정상 XFS AGI가 존재하고, 복귀 후 checkpoint53에서 주변 섹터 일부가 0으로 변했다. AGI 절대 offset898630656은 reverse 변경 범위에 포함되지 않았다. 단순 OS 문제로 분류하지 않고 쓰기 경로의 데이터 손상 결함으로 처리한다.

## 코드 변경
- `ftctl_kvm_vmware_start_writer`: `single-link=false`로 전체 parent chain을 여는 쓰기 계약을 명시한다.
- 해당 공통 함수는 RBD 및 qcow2→VMware 역복제에 사용된다. 순방향 reader/CBT, checkpoint publish, 스케줄러, Cloud API 변경 없음.
- 전체 chain 옵션과 active leaf 경로, owner-only password 파일 전달을 검사하는 회귀 스모크를 추가한다.
- 실 VDDK parent snapshot + 부분 쓰기 시험을 설치 수정본으로 재검증한다. selected extent readback만으로 인접 영역 보존을 판정하지 않는다.

## 기준 및 배포
Cloud/qemu `codex/fix-1011-vddk-snapshot-write`, #1008 커밋 db8c0bb0c0/3d312f6 기반. 기존 #1008 변경을 포함하며 해당 브랜치는 보존한다. qemu shell만 직접 배포하고 전체/RPM 빌드는 하지 않는다. Cloud 실행 코드 변경 없음; #1008 core 빌드/배포를 유지한다.

## 복구·수용 기준
1. 손상 원본을 별도 snapshot으로 보존하고 기존 외부 snapshot은 유지한다.
2. 정상 reverse46 RBD 보존본을 원본 디스크에 전체 복원한 뒤 VMware 콘솔 OS 정상 부팅을 검증한다. 이는 기존 손상 복구 절차이며 #1008 자동 체인 성공으로 계산하지 않는다.
3. 새 UI 원본 독립 테스트/정리/재해 전환/페일백 수행. runtime source credentials 수동 복원 없이 #1008 preflight READY 및 실제 페일백 성공을 확인한다.
4. VMware 원본/대상 QGA 제외. 실제 원본 콘솔 및 정상 forward checkpoint 확인. RBD/qcow2 지속 복제 상태와 공통 계약 스모크 확인.
5. checkpoint 시점 이후 원본 단독 변경이 역증분에 포함되는지의 일반 baseline 문제는 이번 재현 원인과 구분해 후속 분석한다.

## #1003 수정 누락 확인
Git 이력으로 확인했다. #1003 커밋 `90aeb149`는 `dr_vmware_mover.sh`의 순방향 full/CBT 읽기를 false로 수정했으나, `dr_kvm_vmware_mover.sh`의 역방향 쓰기는 최초 구현 `d6f22db3`의 true가 그대로 남았다. 순방향 수정의 회귀가 아니라 역방향 적용/검증 누락이다. 당시 페일백 poweredOn만 확인한 것도 OS 손상 발견을 놓친 원인이다. 이번에는 설치 writer의 인접 섹터 보존과 원본 OS 부팅을 검증한다.

## 2026-09-10 실제 페일백 추가 검증에서 확인한 #1008 보완
UI 사전 점검은 현재 요청 credentials로 READY가 됐으나 실제 failback run479는 DR_REVERSE_TARGET_BACKING_UNRESOLVED로 쓰기 전 중단됐다. 내부 reverse profile은 credentials가 마스킹된 문자열이고, 실제 인증 정보는 owner-only runtime credentials 파일에 분리 저장된다. 외부 요청의 has(credentials) 우선 규칙을 내부 worker에도 적용한 것이 원인이다.

`ftctl_dr_kvm_vmware_reverse_preflight`에 내부 호출 전용 여섯 번째 credential file 인자를 추가한다. `dr_runtime.sh` failback worker는 `ftctl_dr_runtime_credential_path`를 명시적으로 넘긴다. CLI/UI 요청은 기존 5인자 호출로 유지하며 빈 값/무효/target-only/마스킹 문자열은 캐시를 되살리지 않는다. 내부 마스킹 profile + 유효 owner-only credentials 통과와 외부 마스킹 요청 거절을 회귀 시험에 추가한다. runtime 변경이므로 lifecycle 및 release tombstone 회귀 후 shell 파일을 직접 배포한다.
