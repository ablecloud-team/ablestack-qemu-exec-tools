# #1012 / #1013 통합 검증

## 브랜치 및 빌드

- 브랜치: 두 저장소 모두 `codex/fix-1012-1013-dr-recovery`.
- 기준: Cloud `7740f7dfec`, qemu `24af913`. 기존 #979/#1008/#1011/#1015 수정 포함.
- 구현: qemu `f364dac`. Cloud는 설계 문서 `c01986cb94`이며 production code 추가 변경 없음.
- Cloud DR 모듈을 WSL ext4에서 Maven test/package: **451 tests, 실패 0, 오류 0, skip 0, BUILD SUCCESS**. 기존 #1015 배포 JAR 유지.
- qemu: checkpoint 13, credentials 8, common baseline 3 tests PASS. 전체 DR lifecycle 71 및 release tombstone PASS. 새 회귀 테스트를 수동 release workflow의 선행 gate에도 추가했으며 릴리즈 빌드는 실행하지 않음.
- 최초 배포 후 legacy VMware checkpoint 최상위 runUuid 잔류를 발견했다. 내부 cycleMetrics의 실제 producer identity를 검증하도록 보완하고 테스트를 추가했다. 이 중간 시도는 uninterrupted PASS로 계산하지 않는다.

## 모듈 배포

13/22/31/32번 각 컴퓨트 1/2/3, 총 12호스트에 shell 4개를 직접 배포하고 해시를 확인했다. 백업은 `/root/issue1012-1013-20260911/modules`이다. RPM 빌드나 Cloud UI/JAR 교체는 하지 않았다.

| 모듈 | SHA256 |
| --- | --- |
| `dr_checkpoint.sh` | `6d304a1cb27d5b82091f4b9caa8cb2de598da6b1520514c1f54ceab8e6b1bf1f` |
| `dr_scheduler.sh` | `3b83fcb99a3df304d0159c91691fe07e09640e60c4e5410efb36f88885cf373f` |
| `dr_kvm_vmware.sh` | `4329a472401adf08659c31bd4df14760b7c15e1ce925eb857bd1aa468239a706` |
| `dr_kvm_vmware_mover.sh` | `e1a51bbbf11d09588c8570ff61c440812449fee2f63ef588b4fe98f3fa742d18` |

## 실제 64MiB 데이터 검증

32.2에 별도 VMware fixture `vm-63150`을 생성하고 설치된 mover로 검증했다.

- RBD: 전체 67,108,864B write/readback, 후속 65,536B delta write/readback.
- qcow2: 전체 67,108,864B QEMU backup, 후속 65,536B bitmap delta. 각 단계 뒤 별도 VDDK read pattern 확인.
- 원본만 수정한 1MiB 영역, 양쪽이 수정한 2MiB 영역, zero 3MiB 영역, 후속 delta 5MiB 영역을 검증했다. 대상의 변경 추적에 없는 원본 단독 변경도 전체 복구로 교정되고 다음 delta 후에도 유지됐다.
- 소유 fixture VM, RBD image/snapshots, 임시 qcow2 파일을 정리했다. 실제 원본 `vm-4486`의 외부 snapshot은 보존했다.
- qcow2의 기존 writeVerified 지표는 QEMU completion에서 생성되며 별도 readback로 해석하지 않는다. 증거 구분 개선은 #1018이다.

## 32 클러스터 UI 검증

계획 `a85874ae-d1bd-470b-97c5-7c48a39486dd`, 원본 `Rokcy10-1(vm-4486)`, 대상 `i-2-306-VM`.

| 동작 | Run UUID | 결과 및 시각(KST, 2026-09-11) |
| --- | --- | --- |
| 전체 재동기화 | `571415ed-4750-46b0-90a9-d10b71b84b0c` | 07:48:00~07:54:48, SUCCEEDED 100%, FULL_RESEED 100GiB, checkpoint 182 |
| 테스트 페일오버 | `1752a928-c193-4972-a0c8-9e0e6813b9f2` | 07:56:04~07:56:41, SUCCEEDED 100% |
| 테스트 정리 | `6dd211d0-1b42-4c5e-8fe0-daf8100b67a1` | 07:57:36~07:57:47, SUCCEEDED 100%, VM318 정리 및 기존 PAUSED 유지 |
| 재해 페일오버 | `7aa6f7df-8e8a-4c46-952d-23e55faafca9` | 07:59:39~08:00:21, SUCCEEDED 100% |
| 페일백 | `dcd5694a-f133-463e-a4a8-2bc35be2d1a7` | 08:03:27~08:24:50, SUCCEEDED 100%, 정방향 checkpoint 184 확정 |

전체 재동기화는 요청 시작 후 DB 수정, 서비스 재시작, 수동 완료 처리 없이 `full-resync-completed / READY / TERMINAL_PUBLISHED`로 완료됐다. 후속 삭제/재동기화/일시 중지/테스트/페일오버 메뉴가 활성화됐으며 과거 CANCELED 요청은 그대로 유지됐다.

checkpoint 182에서 복제를 일시 중지한 후 원본에만 4MiB 데이터와 marker를 쓰고 정상 guest shutdown했다. poweredOff를 확인한 뒤 32.1/2/3/10에서 vCenter 21.10만 차단했다. 테스트, 정리, 재해 전환은 이 단절 상태에서 성공했다. 전환 성공 직후 차단 규칙이 여전히 존재함을 확인한 뒤 모두 제거했다.

대상 noVNC 콘솔에서 root 로그인, XFS rw, 원본 단독 파일 부재를 확인했다. `/root/issue1012-target.txt`를 쓰고 SHA256 `c21ea2b3008033e3d618a5169515997bdd5847ec35ada21f121276f78fa3d146`을 확인했다. 기존 #1011 검증 파일도 유지됐다.

## 페일백 데이터 및 원본 검증

- 역복제 183: `FULL_REVERSE_SEED`, targetWrittenBytes = verifiedBytes = **107,374,182,400**, writeVerified=true, writer/tracker LOCAL_DURABLE. 소요 749,172ms.
- 전체 검증 전에는 commonBaselineVerified=false를 유지했으며, 검증 성공 후에만 true / REVERSE_READBACK으로 확정됐다.
- 원본 정상 부팅 콘솔을 확인했다. VMware Tools guest API로 XFS rw, 이번 부팅의 XFS error/corrupt/CRC/shutdown 검색 결과 없음, 대상 신규 파일 해시 일치, 원본 단독 시험 파일 2개 부재를 확인했다. VMware 양단 QGA는 사용하지 않았다.
- 운영 권한 SOURCE, scheduler RUNNING/HEALTHY로 복귀했다. 정방향 CBT 100GiB 체크포인트 184가 확정됐고 UI FAILBACK은 08:24:50에 SUCCEEDED 100%로 완료됐다. UI의 data-ready, target-stop, source-start, source-boot-validation, authority-commit, scheduler-resume, post-checkpoint가 모두 SUCCEEDED다. 대상 VM306은 Stopped, 시험 VM318 세션은 CLEANED이며 vCenter 차단 규칙은 네 호스트 모두 제거됐다.

## 후속 이슈와 범위

- #1018(P2): qcow2 QEMU completion과 실제 readback 지표 구분.
- #1019(P2): PREPARING 이력 polling 누락. 테스트 정리 이력은 내부 업데이트로 확인했다. 백엔드 완료와 메뉴 복원은 정상이었다.
- #1020(P2): 역복제 progress의 실행 ID/방향/mode 누락 및 원본 복귀 후 이전 진행 표시 잔류.
- #1021(P2): cutover baseline 출처 번호 54와 선택 체크포인트 182 불일치 조사. 실제 역복제는 183, 다음 정방향 최소값은 184였으므로 순번 역행으로 전환이 차단되지는 않았다. 번호 차이만으로 과거 데이터 복구를 단정하지 않는다.

위 P2를 전체 UI 무결성 PASS로 포함하지 않는다. 이번 검증은 #1012 데이터 정합성 및 #1013 완료 요청 확정과 후속 동작 가용성에 대한 검증이다.
