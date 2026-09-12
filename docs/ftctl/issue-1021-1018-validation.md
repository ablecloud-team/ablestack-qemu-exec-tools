# #1021 / #1018 검증 기록 — 2026-09-11

## 기준과 구현
Cloud `2e3d3168643` (#954 포함), qemu `fb6df9b`를 보존한 양쪽 `codex/fix-1021-1018-recovery-evidence` 브랜치. Cloud 구현 `5cf94b79cd1`, qemu 구현 `e5c6a0a`.

- 동일 guestprep 선택 로직으로 cutover 복구 지점을 확정하여 후속 baseline/guestprep/finalize에 같은 canonical ref를 전달한다.
- baseline에 createdFromRestorePoint의 plan/run/ref/sequence 및 manifest/checkpoint SHA256을 기록한다. reverse commit 이후에도 출처를 보존한다.
- qcow2의 QEMU 완료와 readback을 분리한다. legacy writeVerified는 기존 durability 완료 계약으로 유지하지만 readback에는 사용하지 않는다. verifiedBytes/readbackVerifiedBytes는 실제 비교가 없으면0, readbackVerified=false다. QEMU 진행률도 동일하다.
- RBD 실제 --verify 비교는 REVERSE_READBACK/true 및 비교 bytes를 기록한다.
- Cloud 압축 저장/보호 projection/UI를 연결한다. 누락된 과거 증거는 완료로 추정하지 않고 기록된 증거 없음으로 표시한다. VMware 원본/대상 QGA를 추가하지 않는다.

## 빌드·회귀
- WSL rocky ext4 DR Maven 변경 모듈 package: 최종 **471 tests, 실패/오류0, BUILD SUCCESS**.
- UI ESLint 및 production build PASS. 전체 Cloud 빌드/RPM 빌드 없음.
- qemu 공통 lifecycle **71 cases PASS**, release tombstone PASS.
- 선택 provenance1(명시182/구형54/최신183/final183/미존재999), common baseline3, checkpoint13, qcow2 backup8/ checkpoint17/commit1, readback fault1 PASS.
- planned final checkpoint/legacy repair 및 SharedMountPoint planned QMP quiesce smoke PASS.
- 쓰기 실패와 readback 불일치가 서로 다른 오류를 반환하고 성공 증거를 만들지 않는 것을 시험했다. live QEMU의 현재 원본을 임의로 readback 비교하지 않는다.

## 배포
- 13/22/31/32 compute 총12대에 shell3개와 Python1개 직접 배포. 모든 파일의 설치 SHA256을 대조했다. 실행 중인 다른 계획 worker를 무조건 종료하지 않았다.
- 31/32 관리 클래스 DrProtectionViewServiceImpl 및 FtctlDrRuntimeProjectionAdapter 선택 적용. 다른 JAR entry 바이트 보존, 최종 백업 `/root/issue1021-v2-20260911/`.
- 31/32 UI static 배포. WEB-INF/META-INF와 config.json symlink 보존. /client/ HTTP200 및 서비스 active 확인. index SHA256 `c2005b20fe8c2055bf1f0d38f7f5b1244c2abcc87313e5e4a3c9c61a859e2d09`.
- 31 공간 확보를 위해 이전954 v2/v3 백업을 WSL 별도 보관 후 SHA256 대조하여 원격 사본만 정리했다. 현재 운영 JAR/직전1021 백업은 보존했다.
- Python 패키지 shebang 차이는 전체 diff로 확인했고 실행 경로 표기 차이만 허용했다. 임의 소스 차이를 덮어쓰지 않았다.

## 실제 데이터 모듈 시험
과거64MiB fixture가 이미 삭제되어 사전 검사에서 중단했다. 새 전용 `issue1021-evidence-fixture`(64MiB, 전원OFF)를 만들고 RBD/qcow2 전체·증분 역복제를 각각 수행했다.

- RBD full67108864B / delta65536B 실제 readback PASS.
- qcow2 full67108864B / delta65536B, QEMU_BACKUP_COMPLETION, readbackVerified=false, verifiedBytes=0 PASS.
- 시험 검증기가 별도로 변경/비변경/zero 영역을 다시 읽어 데이터 일치 확인. 이 외부 시험 결과를 mover 자체의 readback 완료로 바꿔 기록하지 않았다.
- VM 및 시험 RBD image를 정리했다. 사용자 원본 vm-4486에 이 fixture의 sector 패턴을 쓰지 않았다.

## 실제 UI 전환
32 계획 `a85874ae-d1bd-470b-97c5-7c48a39486dd`, 원본 VMware Rokcy10-1(vm-4486).

- UI planned Failover, force=false/finalsync=true. Run `2fd79125-1598-4498-86d7-7811fecaf701` SUCCEEDED.
- 최종 선택 checkpoint183과 baseline.createdFromCheckpoint183, canonical ref 일치. manifest/checkpoint SHA256은 전환 후에도 동일했다.
- 직전 정기 sync303과 final183은 서로 다른 생산자/주기 번호다. 숫자 차이만으로 데이터 손상이라고 판정하지 않았다.
- 원본 VMware poweredOff, DR 대상만 POWERED_ON. UI 보호 정보에 전환 기준183 및 정확한 ref 표시 확인.
- 최초 UI 확인에서 Cloud compact allowlist가 새 필드를 버리는 문제를 발견하여 같은 과제에서 수정했다. false/0 보존 및 credential 제외 회귀 후 재배포했다.
- 31 기존 qcow2 계획 UI에서 과거 readback 증거가 없을 때 기록된 증거 없음 표시와 기존 복제 정상 상태 확인.
- UI Failback Run `93a89a1c-5be7-411a-a80a-d8fd6b39b49e` 실행. 최종 결과는 아래에 이어 기록한다.

## 발견한 별도 기존 문제
#1020 진행 식별자 누락이 재현되어 댓글에 현재 Run/시각/표시를 추가했다. 실제 역복제 worker가 COPYING 중인데 UI가 과거100%/192KiB 및 원본 복구 완료 안내를 섞어 표시했다. 이를 실제 완료로 계산하지 않는다. 현재 Run과 무관한 완료 안내를 배제하는 조건을 #1020에 추가했으며 후속 P2 우선순위를 앞당긴다.

증거 폴더: `/home/ablecloud/work/issue1021-evidence`. 비밀번호/자격 증명은 기록하지 않는다. 이번 검증은 물리 장애/모든 VM 배치/모든 OS 및 전체 릴리즈 검증이 아니다.

## 최종 UI 및 자동 보호 재개 결과
- 2026-09-11 18:31:26 KST FAILBACK SUCCEEDED/completed. UI 작업 이력과 dr_run 모두 일치, error_code NULL.
- 원본 POWERED_ON, 대상 POWERED_OFF. VMware Tools guestState running 확인. 양단 QGA 검증은 수행하지 않았다.
- 100GiB(107374182400B) 전체 역복제 후 실제 REVERSE_READBACK/true/동일 bytes 확인. baseline generation184로 진행해도 전환 출처183/ref를 보존했다.
- 사용자 Resume/Full Sync/DB 수리 없이 보호 자동 재개. 첫 정방향 durable checkpoint304, READY/ENABLED/RUNNING, scheduler ACK75/75, failback COMPLETED 확인.
- 18:34 이후 실제 UI 보호 정보에서 출처183/ref, readback true/100GiB, 후속 checkpoint304와 원본/대상 전원을 확인했다. UI 작업 이력의 failover 및 failback SUCCEEDED를 확인했다.
- 기존 qcow2 checkpoint1988, RBD checkpoint4742 READY/HEALTHY 및 복제 지속 확인.
- qcow2 전체 UI failback 체인을 새로 수행한 것은 아니다. qcow2는 실제 데이터 모듈 full/incremental fixture 및 QMP 회귀, 기존 UI 정상/증거 없음 표시를 검증했다. 물리 장애·전체 배치·OS 조합의 완전 검증으로 확대 해석하지 않는다.

## 후속 관리
#1021/#1018 핵심 구현·명시 범위 검증 완료, upstream 병합 대기. 다음 DR P2는 재현된 #1020 진행/완료 안내 오류, 이어 #962 확장+#1006이다. Diplo #1029는 별도 P1. Nutanix 제외 잔여19건(Cloud18+qemu1), 핵심 구현·검증/병합·잔여 시험36건이다.
