# #1011 검증 기록 — 기능 검증 완료

## 확인된 원인과 수정
#1003 순방향 수정 90aeb149에서 역방향 writer의 single-link=true가 누락됐다. 기존 옵션의 writable snapshot 부분 쓰기에서 비수정 인접 섹터가 손상됨을 별도 VM(vm-62880, 64MiB, poweredOff)으로 재현했다. 1MiB 0x5a→snapshot→offset512 512B 0x6b 쓰기 후 offset0 패턴 실패. false 대조 및 설치 FTCTL writer 함수에서는 수정 구간과 인접 64KiB 영역 모두 일치했다.

## 회귀/배포
- writer chain shell smoke PASS, lifecycle71 PASS, #1008 credential6 PASS, tombstone PASS.
- VDDK 수정 자체는 Cloud 실행 코드 변경 없음. #1008 core 모듈 빌드/배포를 유지하며, 아래 #1015 blocker 보완으로 DR 모듈만 추가 빌드/배포했다. qemu shell 직접 배포, RPM/전체 빌드 없음.
- 13/22/31/32 각 compute1~3 총12대 reverse mover SHA256: `65f05d8969f68d2d020a6182d68674bc2e146b225d257dd77892c531a2b0a671`.
- 32 forward mover에는 #1003 수정이 있었으나 13/22/31의 9대에는 true 두 곳이 남았다. 해당 두 옵션만 false로 수정하고 그 외 바이트를 보존했다.
- 위9대 forward mover 변경 전 SHA256 `0f26f83e44c21d13a56bbd20d09f4b4a0ec3af2b6562a04361abbcc6876c4279`, 후 `e3fb22d1a24051b4212852f61d0f969f84cac1c32ae327b355a5ee2ddfe4ac7d`.
- 백업 `/root/issue1011-20260910`.

## 기존 손상 복구 (새 자동 DR 체인과 구분)
원본 vm-4486에 `issue1011-corrupt-source-before-recovery` snapshot을 생성하고 전원을 종료했다. 기존 외부 snapshot은 보존했다. reverse46 보존 RBD snapshot `ftctl-dr-a85874ae-46-543841d8-c98-0`에서 새 active leaf로 전체100GiB 복원.
- bytesWritten/verifiedBytes 각각107374182400, writeVerified=true, 복사 및 읽기 비교769068ms, 임시 NBD 정상 정리.
- 원본 정상 부팅, 콘솔 root 로그인 성공. 실패 서비스0. `/` 및 `/boot` XFS rw 마운트. 이번 부팅 kernel journal의 `XFS.*(error|corrupt|CRC|shutdown)` 검색 결과 없음.
- VMware Tools running은 보조 증거이며 VMware 원본/대상 QGA는 사용하지 않았다.
- 이후 정상 guest shutdown 성공 및 poweredOff 확인.
- 증거 `/home/ablecloud/work/issue1011-evidence/source-recovery.log`, `source-recovered-health.png`.

## 새 UI 체인
- SYNC run474 `f61da0af-5054-460e-babf-14f453af536d`: 실제100GiB FULL_RESEED/checkpoint54 durable 완료, UI95% 잔류 #1013 등록. UI 현재 작업 취소로 종료(CANCELED). DB 수정/체크포인트 삭제 없음. 이 run을 UI PASS로 세지 않는다.
- PAUSE run475 성공 → source-independent TEST_FAILOVER run476 성공(test VM317 실제 Rocky 로그인 화면, NIC disabled) → TEST_CLEANUP run477 성공.
- 원본 정상 guest shutdown 상태를 유지한 채32.1/2/3/10에서 vCenter21.10 통신만 차단했다. forced disaster FAILOVER run478 성공, target306 Running. 네 호스트 방화벽 규칙은 복구했고10분 자동복구 timer도 정지했다. 복구 후 UI 사이트 점검으로 CONNECTED 확인.
- 대상 console root 로그인, `/root/issue1011-roundtrip.txt` 작성/flush. 값 `issue1011-roundtrip-20260910\n`, SHA256 `87e7b487f7a9a72da3dbdd44a486f9ff0a0e748145ffb5b442d0c1b9e5f89b09`.
- 원본이 poweredOff인 상태에서 `issue1011-healthy-pre-failback` 스냅샷을 보존하여 새 sparse active leaf에 실제 부분 역복제를 수행했다. 기존 외부 및 손상 보존 스냅샷도 유지했다.
- run479 내부 인증 profile 처리 누락은 #1008에 기록하고 수정. run480 실제 역복제와 원본 건강 검사 성공. UI 완료를 막던 별도 #1015도 수정 후 정상 수렴(아래 참조).

## 별도 후속
#1012 P1: 첫 역복제 기준점에서 원본 단독 변경까지 반영되는지 별도 검증. 이번 부분 쓰기 손상의 실증 원인과 구분한다.

## 최종 UI 재검증 및 #1008 보완 (2026-09-10)

- 런타임 credentials는 source 없음/target 있음, mode0600이었다. UI 페일백 사전 점검이 READY가 된 전후 SHA256 `edc70ec4c8bd88f379adcd5797c4be7b96d53cd9129c5a91352d69ca5e802f19`가 동일했다. 캐시 수동 복원 없음.
- 실제 내부 worker의 저장 reverse profile은 credentials가 마스킹되어 있어 run479가 쓰기 전에 실패했다. 내부 worker만 owner-only credential 파일을 명시하는 여섯 번째 인자를 사용하도록 보완했다. 외부 빈/무효/target-only/마스킹 요청의 캐시 fallback 금지는 유지한다.
- 인증 테스트는 기존6개+내부 호출 성공/외부 마스킹 거절2개=8개 PASS. 설치된32.2 스크립트에서도8개 PASS. 전체 DR lifecycle71 및 release tombstone PASS.
- 최종 run480 `c02ea9e0-3ee2-4579-b71c-9c91db1f8a03` 역복제55: REVERSE_FINAL, 84,623,360 bytes written/verified, writeVerified=true. 원본 vm-4486 정상 콘솔 로그인, 대상 작성 파일 SHA256 일치, XFS / 및 /boot rw, 실패 서비스0, XFS kernel error/corrupt/CRC/shutdown 검색 결과 없음. VMware 원본/대상 QGA 미사용.
- Cloud 체크포인트 publication이 FAILBACK 전체를 제외해 보호 재개95%에 남는 별도 blocker #1015를 발견/등록/수정했다. 변경 DR Maven 모듈451tests PASS. 배포 후 run480은 DB 수동 수정 없이 UI SUCCEEDED/100%로 수렴(21:41:21 KST), post-failback checkpoint57 READY, scheduler RUNNING/HEALTHY, target306 Stopped.
- 사전 점검 management command 로그3건에서 profileJson/password/credentials 필드 노출0. Agent 해당 로그레벨에는 명령 레코드가 없어 Agent 원문 관찰을 PASS 근거로 사용하지 않았다. 별도 logger/wire 테스트5개 PASS 유지.
- 최초 손상 복구와 run474 FULL_RESEED의 UI95% 잔류에 대한 UI 취소는 시험 준비 복구로 기록한다. run479 실패와 #1015 배포 재기동도 포함되어 있으므로 이번 결과를 무중단/무개입 전체 체인 PASS라고 표현하지 않는다. 해당 수정 후 기능별 성공과 실제 원본 데이터/부팅 검증 완료이다.
- 다음 별도 과제: #1012 원본 단독 변경의 최초 역복제 기준점, #1013 전체 재동기화 UI 완료 잔류. 두 이슈는 아직 해결했다고 판정하지 않는다.

## 최종 배포/회귀 범위
- qemu `dr_kvm_vmware.sh` 최종SHA256 `026c66ab64b391ec39a588eb578f8e11b70475ddefed56c6500a32213f004332`.
- qemu `dr_runtime.sh` 최종SHA256 `e1b16cc439ba1e1a22e5a63f1c50e3d381ccafec80f1e73fcf03ec5c2440370b`.
- 두 파일과 reverse mover를13/22/31/32각 compute1~3 총12대에 백업 후 파일 배포했다. 신규 qemu RPM 빌드 없음.
- 모든12대의 forward reader2곳/reverse writer1곳에서 single-link=false이며 true 없음.
- 기존 RBD/SharedMountPoint 순방향 복제는 배포 후 READY/RUNNING/HEALTHY, NBD DRAINED. RBD checkpoint4483→4486, qcow2 checkpoint1496→1498 진행. 이번 실클러스터 조작 체인은 VMware 경로이며, 나머지 전체 UI 페일오버 체인을 재실행한 결과는 아니다.
- 재현 전용64MiB vm-62880 제거. test VM317 CLEANED/Expunging. 원본/대상 본 VM, 복구 스냅샷 보존. source vm-4486 poweredOn/target306 Stopped.
- 증거 루트 `/home/ablecloud/work/issue1011-evidence`: sector repro/control/installed 로그, source-failback480-health.png, reverse55-metrics.json, final-vmware-status.json, final-ui-run-db.tsv, final-other-paths.json, 배포 해시/빌드 로그.

- #1015 Cloud projection class7개를31/32 관리 서버에 기존 JAR 백업 후 overlay 배포. 그 외 JAR entry는 byte-preserved 검증. outer class SHA256 `ce2ef145db242ba591846125e5280602c254b33d10e2829cdc402b997873e0dd`. 두 서버 mold active, /client HTTP200, WEB-INF 보존, 최근 클래스 로딩 오류0. 백업 `/root/issue1015-20260910/projection-backup`.
