# #1008 구현·배포 및 검증 기록

## 판정
구현, 모듈 빌드, 단위/계약 회귀, 배포 완료. UI 테스트 페일오버 및 정리는 성공했으나, UI 페일백 사전 점검부터 실제 복귀까지의 수용 기준은 미완료다. 전체 PASS로 판정하지 않는다.

## 변경 및 기준
- Cloud/qemu: `codex/fix-1008-failback-credentials`.
- #979 Cloud `2f79d608368c7d8cd32facae1dd9d5e8231f48e4`, qemu `cfad0d4b2325bb9298f108881749594cbc471c7e` 기반.
- 최신 Cloud upstream `11fc3c536c2e1de229ee1bc2812b5774ce475bec`를 merge `bb436f5b7328fa4722f67c41195ef3e1f27df720`으로 포함. qemu upstream `9d5f543dd0a1ffb83f661b1b7b792f16b0b1d73a` 포함.
- qemu preflight는 현재 요청에 credentials 필드가 있으면 해당 요청만 사용한다. 명시적 빈 값/잘못된 값/target-only 요청은 과거 source cache로 되돌아가지 않는다. 필드가 아예 없는 legacy 요청만 기존 fallback 유지.
- Cloud command profileJson 로그 제외. wire serializer는 보존.

## 빌드·회귀
WSL ext4 clone에서 수행. 전체 Cloud/RPM 빌드 없음.
- `mvn -pl core -Dtest=GsonHelperTest -DfailIfNoTests=false install`: BUILD SUCCESS, 5 tests PASS.
- `mvn -pl plugins/integrations/disaster-recovery -DfailIfNoTests=false test`: 450 tests PASS.
- qemu credential 회귀: 6 PASS. 32.2 설치 파일 대상으로도 6 PASS(외부 govc/storage는 mock; 실 vCenter 성공 증거와 구분).
- `tests/ftctl_dr_full_lifecycle_smoke.sh`: 71 cases PASS.
- release tombstone regression PASS.

## 배포
- 13/22/31/32 각 compute 1~3 총 12대에 수정 shell 직접 배포.
- 설치 경로 `/usr/local/lib/ablestack-qemu-exec-tools/ftctl/dr_kvm_vmware.sh`.
- SHA256 `c94c857dd2858cb4a97c188f594e68c437b8cc37b921b5e9f973015d486a704b`.
- 31/32 관리 서버 및 compute 6대, 총 8대에 core command class만 기존 JAR 엔트리를 보존해 반영.
- class SHA256 `ca576012dc353c3e3555346955eabba3e751091de1ce71830ed713bd559c89ee`.
- 모든 대상 class 해시 일치. mold/mold-agent active, 관리 UI HTTP200 및 WEB-INF 보존. UI 번들 변경 없음.
- 백업 `/root/issue1008-20260910/`.
- 31.3 Agent stop/start 경합으로 일시적 runtime mask를 사용했고 배포 후 해제/active 확인. 원인과 운영 개선은 #1010 P2로 등록.

## UI와 런타임
VMware plan `a85874ae-d1bd-470b-97c5-7c48a39486dd`:
- UI PAUSE run471 SUCCEEDED.
- 원본 독립/네트워크 어댑터 비활성화 TestFailover run472 (`af06aa25-8b66-438c-bcb0-3b6b0d489f92`) SUCCEEDED.
- 시험 VM316 `i-2-316-VM`, NIC enabled=0. POWER_STATE_VALIDATED만 확인했으며 OS 부팅 정상 판정은 하지 않는다. VMware 양단 QGA 검증 없음.
- UI cleanup run473 (`499802eb-d0ca-435b-9d41-d4039c6c476d`) SUCCEEDED, session52 CLEANED, VM316 Expunging.
- runtime credentials는 source 없이 target만 포함. 수동 credential 복구 없음.
- 최종 VMware PAUSED / scheduler RUNNING·HEALTHY / checkpoint53 / 오류 없음. 원본 vm-4486은 poweredOn이지만 XFS emergency mode.
- 기존 RBD plan `7ec74483-8554-415d-ac56-f62f8b17fbd0` checkpoint4471 READY, scheduler RUNNING·HEALTHY.
- 기존 qcow2 plan `9a20b190-d202-4b66-9358-b509756f9751` checkpoint1483 READY, scheduler RUNNING·HEALTHY.
- 위 두 경로는 지속 복제 상태 확인이며 이번 변경 후 전체 UI failover/failback 재시험을 의미하지 않는다.

## 중단 원인과 남은 수용 기준
새 재해 전환/페일백 전에 원본 VMware 콘솔에서 XFS `Metadata CRC error`, `xfs_agi_read_verify`, block `0x80002`, error74, emergency mode를 확인했다. Tools가 없어 정상 guest shutdown도 실패했다. 원본 강제 종료, xfs_repair, 외부 snapshot 삭제, 신규 failover/failback 및 방화벽 차단은 하지 않았다.

#1011 P1에 증거와 원인 조사/OS 복귀 검증 보완을 등록했다. 기존 #979 failback470의 poweredOn 확인은 OS 정상 복귀 증거가 아니며 원본 OS 성공으로 해석해서는 안 된다. 손상 원인은 아직 미확정이다.

원본 디스크를 다시 쓰면 조사 증거가 변경되므로 계획을 PAUSED로 유지한다. #1011 조사와 정상 시험 원본 확보 후 다음을 완료해야 한다:
1. 원본 독립 재해 전환 → 원본 연결 복구 → UI preflight READY.
2. runtime source credentials 수동 복원 없이 실제 페일백 완료와 원본 OS 콘솔 정상 복귀 확인.
3. 실제 Agent preflight 로그의 비밀 제외와 요청 전후 credential 파일 불변 확인.
4. 복제 재개 및 새 checkpoint 발행.

증거 디렉터리: `/home/ablecloud/work/issue1008-evidence` (비밀 값은 문서에 포함하지 않음).

## 최종 UI 재검증 및 #1008 보완 (2026-09-10)

- 런타임 credentials는 source 없음/target 있음, mode0600이었다. UI 페일백 사전 점검이 READY가 된 전후 SHA256 `edc70ec4c8bd88f379adcd5797c4be7b96d53cd9129c5a91352d69ca5e802f19`가 동일했다. 캐시 수동 복원 없음.
- 실제 내부 worker의 저장 reverse profile은 credentials가 마스킹되어 있어 run479가 쓰기 전에 실패했다. 내부 worker만 owner-only credential 파일을 명시하는 여섯 번째 인자를 사용하도록 보완했다. 외부 빈/무효/target-only/마스킹 요청의 캐시 fallback 금지는 유지한다.
- 인증 테스트는 기존6개+내부 호출 성공/외부 마스킹 거절2개=8개 PASS. 설치된32.2 스크립트에서도8개 PASS. 전체 DR lifecycle71 및 release tombstone PASS.
- 최종 run480 `c02ea9e0-3ee2-4579-b71c-9c91db1f8a03` 역복제55: REVERSE_FINAL, 84,623,360 bytes written/verified, writeVerified=true. 원본 vm-4486 정상 콘솔 로그인, 대상 작성 파일 SHA256 일치, XFS / 및 /boot rw, 실패 서비스0, XFS kernel error/corrupt/CRC/shutdown 검색 결과 없음. VMware 원본/대상 QGA 미사용.
- Cloud 체크포인트 publication이 FAILBACK 전체를 제외해 보호 재개95%에 남는 별도 blocker #1015를 발견/등록/수정했다. 변경 DR Maven 모듈451tests PASS. 배포 후 run480은 DB 수동 수정 없이 UI SUCCEEDED/100%로 수렴(21:41:21 KST), post-failback checkpoint57 READY, scheduler RUNNING/HEALTHY, target306 Stopped.
- 사전 점검 management command 로그3건에서 profileJson/password/credentials 필드 노출0. Agent 해당 로그레벨에는 명령 레코드가 없어 Agent 원문 관찰을 PASS 근거로 사용하지 않았다. 별도 logger/wire 테스트5개 PASS 유지.
- 최초 손상 복구와 run474 FULL_RESEED의 UI95% 잔류에 대한 UI 취소는 시험 준비 복구로 기록한다. run479 실패와 #1015 배포 재기동도 포함되어 있으므로 이번 결과를 무중단/무개입 전체 체인 PASS라고 표현하지 않는다. 해당 수정 후 기능별 성공과 실제 원본 데이터/부팅 검증 완료이다.
- 다음 별도 과제: #1012 원본 단독 변경의 최초 역복제 기준점, #1013 전체 재동기화 UI 완료 잔류. 두 이슈는 아직 해결했다고 판정하지 않는다.
