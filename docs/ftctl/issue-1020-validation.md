# #1020 구현·배포·검증 기록 — 2026-09-11

## 기준과 구현
Cloud b822ca532da / qemu f379fe2(#1021+#1018 포함)를 보존한 `codex/fix-1020-reverse-progress`.
Cloud 구현377c17835e3, qemu687cff4. 기존 통합 브랜치와의 ancestry 확인 후 생성했다.

- reverse mover의 진행 자료에 부모 UI Run/Plan/sequence/KVM_TO_VMWARE/effective mode를 전달한다. artifact producer Run의 기존 이름은 보존한다.
- RBD 다중 디스크의 immutable extent를 먼저 계산해 실제 전송 총량을 고정하고 마지막 디스크 readback 후 COMPLETE로 표시한다. 준비 실패는 기존 새 snapshot 정리 경로를 사용한다. 단독 함수 호출은 기존 extent 파일을 임의 재사용하지 않는다.
- dr-status는 operation별 Plan/Run 및 failback sequence를 검사한다. 미일치·구형 무식별 진행은 unknown으로 남긴다. Cloud compact/Run response/protection projection에서 identity를 보존한다.
- UI는 이전 Run/다른 checkpoint/정방향 및 completed-cycle 대체 자료를 현재 역복제에 섞지 않는다. transfer100%만으로 원본 복구 완료 안내를 만들지 않으며 실제 protection-resuming 단계에서 안내한다.
- 완료 주기의 targetWrittenBytes를 실제 readback verifiedBytes로 합성하지 않는다. #1018의 false/0 계약을 보존한다.

## 빌드 및 회귀
- WSL rocky ext4 DR Maven 변경 모듈: **473 tests, 실패0/오류0, Checkstyle/package PASS**. 기존 #954 테스트 wildcard import를 명시 import로 정리해 checkstyle 차단도 해소했다.
- UI unit **26/26 PASS**, lint 및 production build PASS. Jest의 Vue 중복 등록 warning/종료 handle은 테스트 결과와 구분했고 forceExit를 사용했다.
- qemu full DR lifecycle **71 cases PASS**, release tombstone, final checkpoint/legacy repair smoke PASS.
- reverse progress 실제 파일 2디스크 full/delta1, common baseline3, qcow2 backup8, readback fault1, checkpoint13/qcow2 checkpoint17 PASS.
- lifecycle 초기 시험의 구형 무식별 fixture와 시험 중 파일 편집으로 인한 무효 실행은 PASS로 합산하지 않았다. 최종 `lifecycle-release.log`가71개 완료 근거다.
- 전체 Cloud 빌드나 qemu RPM 생성 없음. shell/Python 직접 모듈 배포.

## 배포 검증
13/22/31/32 compute12대, 31/32 관리/UI 적용. 별도 다른 계획의 worker를 무조건 중지하지 않았다.

- scripts backup `/root/issue1020-20260911/modules`, JAR backup `/root/issue1020-20260911`. 모든 변경 파일/클래스 해시 대조.
- dr_runtime.sh daf5a1fe2730fe7993183a6d55794bc5e5a44b9409e7e1295814d3cb94dc9284
- dr_kvm_vmware_mover.sh 08e14a8bb426c5bc58088d6dbed2185407ad3831cd62eeae2100474973836829
- dr_extent_patch.py 270d02acf312dd05c763ea5fb43fb4beb334eeadaf4b23aecad38f9a03fc5c39
- qcow2_bitmap_backup.py 36718fbe11422b9dae8954b377d09990dc65b7b43cf18ac732b746507f5cc078
- UI index9b7ef1b4ce99d30223bfc5ba99efff84f77db2187ffdb38840b8a9ba73eaa445, static-only 업데이트, WEB-INF/META-INF/config.json symlink 보존 및 HTTP200.
- 서비스 active 직후32 HTTP 준비 전 연결 거절은 기동 대기로 처리하고 최종 HTTP200까지 재확인했다. 원본 JAR의 다른 entry는 보존했다.
- 설치된 dr_extent_patch.py의 패키지 shebang 차이만 전체 diff로 확인하여 허용했다. 그 밖의 미확인 소스는 덮어쓰지 않았다.

## 실제 full/delta 데이터 시험
전용64MiB VMware VM `issue1020-evidence-fixture`를 생성하여 RBD/qcow2 full67108864B 및 delta65536B를 시험했다.
두 경로 모두 Plan/parent Run/cycle/direction/mode/bytes/100% 일치. RBD는 실제 readback bytes, qcow2는 QEMU 완료/readbackfalse0을 유지했다. 별도 sector 읽기로 변경/비변경/zero 영역 일치 확인. fixture VM/image 정리 완료. 사용자 원본 VM에 시험 패턴을 쓰지 않았다.

## 실제 UI 시험
32 계획a85874ae-d1bd-470b-97c5-7c48a39486dd, VMware Rokcy10-1(vm-4486) → RBD.
- UI planned Failover(forcefalse/finalsynctrue) Run21878e31-6fc0-4e7c-9012-5a21527b589a SUCCEEDED. 선택 cutover184.
- UI Failback(forcefalse) Run945af7c9-cb5c-4a95-b79d-6b94ffb4676e.
- 19:21:20 UI 1%,1.0GiB/100GiB,FULL_REVERSE_SEED. 이전100%/CBT_INCREMENTAL 및 원본 복구 완료 안내 없음.
- 19:22:29 UI35%,35.3GiB/100GiB,529.3MiB/s,전체 작업79%. Run/engine progress identity 모두현재Run,cycle185,KVM_TO_VMWARE.
- 최종 재읽기 및 자동 보호 재개 결과는 아래에 기록한다.

증거 위치 `/home/ablecloud/work/issue1020-evidence`. VMware 양단 QGA 제외. 실제 qcow2 전체 UI failback이나 전체 물리 장애/OS/placement 조합을 새로 검증했다고 주장하지 않는다.

### 역복제·읽기 검증·복구 단계 관찰
- 19:23:44 UI74%,74.4GiB/100GiB. 복사99% 이후 flush 대기에는 RUNNING 및 지연 안내를 유지했다. NBD 실제 쓰기/읽기가 전진함을 확인했다.
- 19:29:22 UI 전송100% / VERIFY / FULL_REVERSE_SEED, 전체95% / RUNNING. 이 단계에는 원본 복구 완료 안내가 나타나지 않았다.
- 전체107374182400B REVERSE_READBACK 후 DATA_READY, reverse baseline185/선택 출처184 보존. 별도 transferVerifiedBytes도 실제107374182400B와 일치했다.
- 19:34:57 실제 protection-resuming 단계 진입 후에만 '원본 가상머신 복구가 완료되었습니다. 지속 보호 재개와 첫 내구성 체크포인트를 확인하고 있습니다.' 표시.
- 원본 POWERED_ON/VMware Tools guestState running, 대상 POWERED_OFF. VMware 양단 QGA 사용 안 함.
- VERIFY 중 기존 작업 메뉴의 현재 실행 취소/DR 계획 삭제가 활성임을 확인했다. 진행 중인 정상 복구를 취소/삭제하지는 않았다.
- 자동 보호 재개 중 checkpoint315 전송을 관찰했다. 수동 Resume/DB 수리 없이 완료까지 확인했다.
- 31 qcow2 UI READY/TARGET_READY/RUNNING/HEALTHY, checkpoint1998 및 후속1999 확인. 기존 RBD checkpoint4754 READY/HEALTHY 확인.

### 최종 결과
19:42:52 KST UI/DB 모두 SUCCEEDED/completed/100%, 오류 없음. 수동 Resume/DB 수리 없이 후속 durable checkpoint315(요구186)를 확인했고 READY/ENABLED/RUNNING/HEALTHY로 복귀했습니다.
UI 작업 이력에서 Failover와 Failback 모두 SUCCEEDED100% 확인. 원본 POWERED_ON/대상 POWERED_OFF, 선택184/역방향185/후속315 구분 및 실제 readback107374182400B 보존.
