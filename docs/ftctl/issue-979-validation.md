# #979 모듈 배포 및 핵심 흐름 검증 (2026-09-10)

## 판정
#979의 불변 체크포인트 발행, 이전 세트 보존, 테스트 복구 및 실제 재해 전환 복원 핵심 흐름 PASS. 전체 릴리즈/모든 장애 조합 PASS를 의미하지 않는다. VMware 페일백 사전 점검의 자격 정보 재해결 결함은 #1008(P1)로 분리했으며 수동 복구 후 운영 방향을 원복했다.

## 소스 / 빌드
- Cloud, qemu: `codex/fix-979-durable-checkpoint`.
- #1004 누적 기준 Cloud dd7fde06c4 + upstream europa bcb52804f3 → merge 7efcea7a1a; qemu 75785a36b6 + upstream main 9d5f543 → merge df00ce6. 기존 브랜치는 변경하지 않음, 병합 충돌 없음.
- WSL ext4 Cloud core 변경 모듈 빌드 SUCCESS; disaster-recovery 450 tests PASS; KVM Agent wrapper 8 tests PASS.
- qemu 신규 체크포인트 12 tests PASS, 기존 qcow2 checkpoint 17 tests PASS, lifecycle 71 cases PASS, release tombstone PASS, bash syntax PASS.
- 마지막 forward/reverse 판별 수정은 신규 12개 회귀에 포함. 전체 lifecycle 71개는 해당 판별 수정 전 실행했으며, 수정 후 실제 VMware 페일백 후 forward 발행과 표적 회귀를 추가 확인.
- qemu RPM/전체 릴리즈 빌드 없이 shell/Python 파일 직접 배포. Cloud 전체 빌드는 실행하지 않음.

## 실스토리지 스모크
- Ceph RBD 2디스크 세트: 발행, 다른 worker 캐시에서 재조회, 다음 부분 덮어쓰기 후 rollback, 두 번째 디스크 발행 실패 시 이전 COMMITTED 유지 PASS.
- GFS2 qcow2 2디스크 세트(하나는 backing chain): 독립 파일 봉인, 다른 worker 재조회, 부분 덮어쓰기 복원, 다음 세트 실패 시 이전 세트 유지 PASS.
- 스모크용 RBD 이미지 2개와 GFS2 디렉터리는 정리. 기존 VM/외부 VMware snapshot은 삭제하지 않음.
- ACK identity 불일치 거절, ACK 재전송, manifest 훼손/누락 거절, volatile 원본 산출물 삭제 후 영속 후보 재시도, 역방향 제외 및 페일백 후 stale activeSide 처리 회귀 PASS.

## UI 중심 시험
| 경로 | 계획 / 새 체크포인트 | UI 실행 및 실제 부팅 | 정리 및 복제 복귀 |
|---|---|---|---|
| VMware → RBD | plan52 a85874ae-d1bd-470b-97c5-7c48a39486dd / 45 | TEST_FAILOVER465 ea04418e-ae32-4e56-bda3-601378c1ba46 SUCCEEDED. 대상 mutable 디스크 첫 64KiB를 0으로 덮어쓴 뒤 불변 스냅샷에서 VM314 생성, Rocky Linux10.1 로그인 화면 확인. QGA 미사용 | TEST_CLEANUP466 SUCCEEDED, 기존 PAUSED 유지 |
| qcow2 → qcow2 | plan6 9a20b190-d202-4b66-9358-b509756f9751 / 1473 | TEST_FAILOVER424 263a10cf-4175-4364-b5e4-80d907a6a059 SUCCEEDED. VM265 Ubuntu26.04 부팅 및 QGA 응답 확인 | TEST_CLEANUP427 SUCCEEDED. 별도 Resume 없이 RUNNING 복원, 1474/1475 새 불변 체크포인트 확인 |
| RBD → RBD | plan51 7ec74483-8554-415d-ac56-f62f8b17fbd0 / 4460 | TEST_FAILOVER468 8a1d0ea1-0867-42af-88e2-94fe534bc671 SUCCEEDED. VM315 Windows Server2022 부팅 및 QGA 응답 확인 | TEST_CLEANUP469 SUCCEEDED. 별도 Resume 없이 RUNNING 복원, 4462/4463 새 불변 체크포인트 확인 |

세 테스트는 UI에서 원본 독립 체크포인트 및 NIC 비활성화를 선택했다. NIC는 생성되어 있고 enabled=0인 것을 확인했다. VMware 원본/대상에 QGA 검증을 요구하지 않았다. 기존 일반 삭제/강제 옵션 UI와 레거시 DR Cluster 비활성화 코드는 변경하지 않았다.

## 실제 재해 전환 / 부분 쓰기 복구
1. VMware 원본 vm-4486(Rokcy10-1)을 정상 종료하고 poweredOff 확인.
2. 32 관리/호스트 4대에서 vCenter10.10.21.10만 차단. 사용자 단말과 다른21대역은 차단하지 않음. 자동 원복 timer 설정.
3. UI 재해 페일오버467 (`521a036a-dc8f-4cb7-8519-e4fa5c4cd969`) SUCCEEDED. Cloud FAILED_OVER/TARGET, engine cloud-promotion-committed, VM306 Running, Rocky Linux10.1 로그인 화면 확인.
4. mutable 첫64KiB는 체크포인트45 원래 데이터와 정확히 같도록 복원됨. SHA256 `71e8eb08d2bcc7de82c179277d333b4756f0e8b3eea54fd305fb540408040b7b`. 수동 디스크 복원을 성공으로 대체하지 않았음.
5. vCenter 차단과 자동 원복 timer 해제 후, UI 페일백 사전 점검에서 원본 자격 정보 누락 발견 → #1008(P1).
6. 동일 vCenter의 유효한 자격 정보를 해당 런타임에 수동으로 다시 제공한 뒤 UI 페일백470 (`543841d8-c98b-4a4c-8de4-a1b083a2f9a5`) SUCCEEDED.
7. 최종 원본 vm-4486 poweredOn, 대상 VM306 Stopped, plan52 READY/SOURCE. 페일백 후 stale profile activeSide를 역방향으로 오인하던 #979 발행 조건을 request.reverse로 수정하고 새 불변 체크포인트48 생성 확인.

#1008 수동 자격 정보 복구가 있었으므로 자동 페일백 전체 체인 PASS로 보고하지 않는다. #979 재해 복원은 그 수동 복구 이전에 성공했다.

## 배포
- 13/22/31/32 클러스터 각3개 compute, 총12개: core command 클래스와 qemu 변경7파일. mold-agent active 및 최종 파일 SHA 일치 확인.
- 관리13/22는 core command 클래스만, 관리31/32는 core+DR 클래스. 기존 fat JAR의 나머지 엔트리 보존을 검증한 모듈 overlay. mold active, /client HTTP200, WEB-INF 존재 확인.
- UI 소스 변경/번들 덮어쓰기 없음. 기존 DR UI로 새 backend/runtime 동작 검증.
- 백업/배포 근거: 각 서버 `/root/issue979-20260910`; WSL `/home/ablecloud/work/issue979-evidence`.
- core.zip SHA256 `ff93a9ae51b6dfe687cc4cf4e9e77787a192758f769c0c42dadbe65436496715`.
- management.zip SHA256 `d5e15866ec8b68159f32e12580fd221d47469d2673b99c70f88956086a6f5f41`.

## 후속 우선순위 / 한계
- P1 #1008: 원본 독립 재해 전환 이후 VMware 페일백의 현재 자격 정보 재해결. 운영 복귀를 막으므로 우선 처리.
- P1 #1007: PAUSED worker 직접 재시작 시 사용자 일시 중지 의도 보존. 이번 배포는 PAUSED unit 정지 후 UI Resume를 사용했고, 마지막 코드 갱신은 RUNNING/IDLE worker만 재시작.
- P2 #1006: 보존 개수/기간, 사용 중 checkpoint pin/GC, 수동 정리, qcow2 복사 비용과 발행 대기 시간 계측. 현재 자동 GC 없이 보존하므로 용량이 계속 증가할 수 있음.
- 전체 전원 장애/저장소 공간 부족/장시간 장애/모든 live migration 조합은 이번 실환경 검증 범위가 아님. 실제 부분 쓰기와 재해 전환은 VMware→RBD에서, 양 저장소 2디스크 부분 실패·복원은 별도 실스토리지 스모크에서 확인.
- 기존 진단용 실패 session49와 외부 snapshot은 이번 시험에서 생성한 데이터가 아니므로 보존. 새 session50/51/58은 정리 완료.

## 배포 qemu 최종 파일 SHA256

```json
{
  "bin/ablestack_vm_ftctl.sh": "d71e266c17e73709af9203673b00ca703d7481d94b1df741709edb93eed8af5e",
  "lib/ftctl/dr_ablestack.sh": "080c6b0683832dddb8e52fd2ede75ec4b0532746717e85b11ffe15f8def9b8a9",
  "lib/ftctl/dr_runtime.sh": "ed6da0319fc58c01d0b897d1309b978c28ca1a467bd866c9e52f761fcf5e92e6",
  "lib/ftctl/dr_scheduler.sh": "ccece318772a79c32806132db783704337d08dbfd97244b902035c141bda0c9e",
  "lib/ftctl/qcow2_checkpoint.py": "9768ec80f864a8682ae183d393f6900231f96a8d67fc648fe10375e3377b1728",
  "lib/ftctl/dr_checkpoint.py": "e938e976d751555a94e1c705535b0022ae49e25a7445f8e52161aa939bdf8d64",
  "lib/ftctl/dr_checkpoint.sh": "53456c9bb8fe87746e64a8563d092becfc5cd6f09d30e008401b89252f80fb84"
}
```

최종 UI 확인: VMware48 / RBD4463 / qcow21476 모두 SOURCE, RUNNING, HEALTHY, COMPLETED.
