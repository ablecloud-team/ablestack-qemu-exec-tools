# #1021 / #1018 복구 출처와 검증 증거 분리 설계

기준 Cloud `2e3d3168643` / qemu `fb6df9b`, 양쪽 안전 브랜치 `codex/fix-1021-1018-recovery-evidence`. 기존 통합 커밋을 보존한다.

## #1021
`dr_runtime.sh` failover worker가 reverse baseline을 준비할 때 과거 Run의 checkpoint_sequence를 먼저 읽는다. guestprep가 실제 선택하는 복구 지점과 다른 번호가 baseline에 남을 수 있다. guestprep_manifest.select_checkpoint의 동일 선택/내구성 검사를 재사용하여 먼저 복구 지점을 확정하고, canonical ref를 이후 guestprep/finalize에 전달한다. baseline에는 선택 ref/sequence와 manifest·checkpoint 파일 SHA256을 기록한다. forward 출처 번호와 reverse generation 및 Cloud authority generation은 다른 의미이며 번호만으로 동일성을 판정하지 않는다. 기존 tracker 생성/쓰기 경로는 유지한다. 원본 조회·QGA·호스트 고정을 추가하지 않는다.

## #1018
qcow2 mover는 성공한 QEMU backup을 writeVerified=true/verifiedBytes=written로 기록한다. legacy writeVerified는 기존 완료 계약 호환용으로 유지하되 readback 의미로 사용하지 않는다. 새 transferCompletionVerified, verificationMethod, readbackVerified, readbackVerifiedBytes를 명시한다. QEMU 경로는 QEMU_BACKUP_COMPLETION / readback false / verifiedBytes 0, 실제 --verify RBD 경로는 REVERSE_READBACK 및 실제 비교 bytes다. qcow2 baseline commit은 QEMU 완료/쓰기 양을 검증하며 readback counter에 의존하지 않는다. Cloud projection/UI는 쓰기 완료와 readback을 별개 표시하고 누락된 과거 증거를 검증 완료로 추정하지 않는다. live 원본의 현재 데이터를 임의 비교하지 않는다.

## 검증과 배포
선택 checkpoint182/과거 Run54, 명시 구형 선택, final checkpoint, 반복 cutover와 잘못된 선택을 회귀한다. QEMU 실패/불완전 쓰기/실제 readback 불일치 및 live source를 재비교하지 않는 계약을 시험한다. release tombstone와 공통 lifecycle 회귀 후 qemu shell 파일 직접 배포, Cloud 변경 Maven 모듈 WSL ext4 빌드 및 UI build를 수행한다. 실제 UI failover/failback와 보호 정보의 출처·검증 표시를 런타임 artifact와 대조한다. 실패는 원인/증거를 남겨 수정하고 재시험한다. 전체 물리 장애/모든 배치 조합으로 범위를 확대하지 않는다.

## 실제 구현/시험 중 보완
- Cloud `FtctlDrRuntimeProjectionAdapter.compactRuntimeStatusJson`의 필드 allowlist에도 출처와 readback5개 필드를 추가한다. UI 첫 시험에서 호스트183 proof가 저장 과정에서 누락되어 표시되지 않았고, false/0 보존 및 credential 제외 회귀를 추가했다. #1021/#1018 안에서 수정하며 별도 과제로 미루지 않는다.
- `qcow2_bitmap_backup.py` 진행률의 verifiedBytes도0으로 바꾼다. QEMU 완료 bytesProcessed/targetWrittenBytes/percent는 유지한다. live 원본의 현재 데이터를 readback 비교하지 않는다.
- 과거 원본 Run의 숫자나 Cloud 전역 cycle row ID와 새로운 final checkpoint 번호는 별개다. 실제 UI planned failover Run2fd79125는 최종 checkpoint183을 선택했다. 직전 정기 sync303과 번호가 다르다는 이유로 손상으로 판정하지 않으며, 선택 ref와 manifest/checkpoint SHA256으로 출처를 확인한다.
