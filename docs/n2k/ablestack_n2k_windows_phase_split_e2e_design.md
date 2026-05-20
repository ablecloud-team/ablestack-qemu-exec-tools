# ABLESTACK n2k Windows Phase1/Phase2 E2E 설계

## 목적

`windows11`과 `winsvr2022` VM은 실제 전환 시점의 중단 시간을 줄이기 위해 전체 마이그레이션을 `Phase1`과 `Phase2`로 나누어 검증한다.

- Phase1은 source VM이 계속 실행 중인 상태에서 base copy와 1차 incremental sync를 완료한다.
- Phase2는 cutover 직전에 incremental sync를 반복해 변경량을 줄이고, 마지막 final sync 후 target VM 정의 단계까지 진행한다.
- 첫 Windows E2E의 cutover 정책은 안전하게 `--define-only`를 기본값으로 둔다.

## 현재 코드 기준

`v2k`에는 이미 split orchestration이 있다. `n2k`는 `init`, `snapshot`, `sync`, `cutover` 단위 명령은 구현되어 있으나 `run` orchestration은 아직 비어 있었다.

따라서 `n2k` 구현은 새 전송기를 만들지 않고 기존 명령을 아래 순서로 묶는 방식으로 진행한다.

## Phase1 흐름

Phase1은 온라인 사전 적재 단계다.

1. `init`
2. `plan`
3. `snapshot base --source-api v3 --create-vm-snapshot`
4. `sync base --source-map-from-v3-nfs`
5. `snapshot incr --source-api v3 --create-vm-snapshot --collect-changed-regions --reference-kind base`
6. `sync incr --source-map-from-v3-nfs`
7. `runtime.split.phase1.done=true` 기록

Phase1은 source VM shutdown, final sync, cutover, cleanup을 수행하지 않는다.

## Phase2 흐름

Phase2는 최소 중단 전환 단계다.

1. 기존 manifest 존재 확인
2. `runtime.split.phase1.done=true` 확인
3. incremental snapshot/sync 반복
4. 각 반복의 소요 시간과 변경량 기록
5. `--deadline-sec` 이내로 들어오면 final boundary로 진입
6. source VM shutdown을 자동 수행한다.
7. `snapshot final --reference-kind incr`
8. `sync final --source-map-from-v3-nfs`
9. `cutover --define-only`
10. `runtime.split.phase2.done=true` 기록

`--deadline-sec` 기준을 만족하지 못하고 `--max-incr-phase2`에 도달하면 cutover 없이 종료한다. 이 경우 Phase2를 다시 실행한다.

## Final Boundary Shutdown

final snapshot은 source VM이 더 이상 disk 변경을 만들지 않는 상태에서 생성되어야 한다. 따라서 Phase2의 deadline gate를 통과한 뒤에는 final snapshot 전에 source VM을 자동으로 종료하는 흐름을 주 경로로 사용한다.

shutdown 정책:

| 정책 | 동작 | 용도 |
| --- | --- | --- |
| `guest` | Nutanix v2 `set_power_state` API에 `ACPI_SHUTDOWN` transition 요청 후 timeout/실패 시 `poweroff` fallback | Windows E2E 기본 권장 |
| `poweroff` | Nutanix v2 `set_power_state` API에 `OFF` transition 요청 | guest shutdown 실패 시 강제 종료 |
| `manual` | 자동 종료하지 않고 operator가 source VM을 직접 멈춘 뒤 진행 | 운영자 통제/비상 fallback |
| `none` | 종료 없이 final snapshot 진행 | 테스트 전용 |

자동 종료는 다음 순서로 수행한다.

1. 현재 VM power state 조회
2. 이미 off 상태이면 API 호출 없이 final snapshot으로 진행
3. `guest` 또는 `poweroff` transition 요청
4. `--shutdown-timeout-sec` 동안 power state가 off 계열이 될 때까지 polling
5. `guest` timeout/실패 시 `poweroff` fallback을 한 번 수행하고, fallback도 실패하면 final snapshot을 생성하지 않고 중단

이렇게 해야 final snapshot 이후 source VM에서 추가 변경이 발생하는 것을 막을 수 있다.

## Windows 전용 주의사항

Windows 11과 Windows Server 2022는 Linux VM보다 target 정의 조건이 민감하다.

- UEFI 여부를 manifest에서 읽어 libvirt XML에 반영해야 한다.
- Windows 11은 TPM과 Secure Boot 요구사항을 별도 검토해야 한다.
- VirtIO disk/NIC 드라이버가 guest에 준비되어 있지 않으면 target boot가 실패할 수 있다.
- 첫 E2E는 data plane과 XML 생성 검증을 목표로 `--define-only`까지 수행한다.
- 실제 `--apply`와 `--start`는 UEFI/TPM/driver 정책 검증 뒤 별도 단계로 확장한다.

## 우선순위별 target storage 테스트

1. RBD
2. qcow2
3. block disk 또는 LVM

Phase split 구현은 target storage와 무관하게 동일한 orchestration을 사용한다. storage 차이는 `init`의 `--target-storage`, `--target-format`, `--target-map-json`, `--dst`로 분기한다.

## 예시 명령

Phase1:

```bash
ablestack_n2k --workdir /tmp/n2k-windows11-phase --manifest /tmp/n2k-windows11-phase/manifest.json run \
  --vm windows11 \
  --pc 10.10.131.11 \
  --cred-file /root/.n2k/nutanix.env \
  --insecure 1 \
  --split phase1 \
  --source-api v3 \
  --nfs-host 10.10.131.10 \
  --target-storage file \
  --target-format qcow2 \
  --dst /tmp/n2k-windows11-target
```

Phase2:

```bash
ablestack_n2k --workdir /tmp/n2k-windows11-phase --manifest /tmp/n2k-windows11-phase/manifest.json run \
  --vm windows11 \
  --pc 10.10.131.11 \
  --cred-file /root/.n2k/nutanix.env \
  --insecure 1 \
  --split phase2 \
  --source-api v3 \
  --nfs-host 10.10.131.10 \
  --deadline-sec 120 \
  --max-incr-phase2 20 \
  --shutdown guest \
  --shutdown-timeout-sec 300 \
  --cutover-args "--define-only"
```

## 완료 기준

- Phase1 종료 후 manifest에 `runtime.split.phase1.done=true`가 기록된다.
- Phase2 시작 시 Phase1 완료 marker가 없으면 중단된다.
- Phase2 반복 중 마지막 incremental sync가 deadline 안에 들어오면 final sync로 진입한다.
- Phase2 final snapshot 전에 `guest` 또는 `poweroff` 자동 종료가 완료된다.
- final sync 후 cutover artifact XML이 생성된다.
- 기본 cutover 정책은 `define-only`다.
- Windows boot/start 검증은 별도 보강 단계로 분리한다.

## winsvr2022 E2E 결과 (2026-05-14)

- Workdir: `/tmp/n2k-winsvr2022-phase-e2e-20260514-225934`
- Phase1 base sync: 100 GiB qcow2 target 생성 완료.
- Phase1 incremental sync: 181 regions, 17,085,440 bytes 적용 완료.
- Phase2 incremental gate: 38 regions, 3,514,368 bytes, 8초로 deadline 통과.
- Final sync: 573 regions, 12,514,304 bytes 적용 완료.
- Cutover artifact: `/tmp/n2k-winsvr2022-phase-e2e-20260514-225934/artifacts/winsvr2022.xml`
- Source VM final power state: `OFF`
- Target image verification: `qemu-img check` 통과, qcow2 virtual size 100 GiB.

E2E 중 발견한 보완 사항:

- Nutanix changed-region payload에서 `zeroed` region type이 반환되어 validator/materializer/target patch 경로에 허용 처리를 추가했다.
- qcow2 incremental patch가 stale `/dev/nbdX` pid를 free device로 오판하지 않도록 NBD attach 후보 검증과 attach 후 size 확인을 추가했다.
- 큰 `zeroed` region을 `dd bs=1`로 쓰면 Phase2가 장시간 지연되어, offset/length 정렬에 따라 1M/64K/4K/1K/512 byte 단위로 패치하도록 최적화했다.
- Windows guest shutdown timeout/실패 시 v2k와 같은 hard poweroff fallback을 수행하도록 `guest` shutdown 정책을 보완했다.

## windows11 E2E 시도 결과 - 무효/제외 (2026-05-15)

- Workdir: `/tmp/n2k-windows11-phase-e2e-20260515-002350`
- Target path: `/var/lib/libvirt/images/windows11/windows11-disk0.qcow2`
- Phase1 base sync: 100 GiB qcow2 target 생성 완료.
- Phase1 incremental sync: 0 regions, 0 bytes 적용 완료.
- Phase2 incremental gate: 0 regions, 0 bytes, 7초로 deadline 통과.
- Final sync: 0 regions, 0 bytes 적용 완료.
- Cutover artifact: `/tmp/n2k-windows11-phase-e2e-20260515-002350/artifacts/windows11.xml`
- Source VM final power state: `OFF`
- Target image verification: `qemu-img check` 통과, qcow2 virtual size 100 GiB.

판정:

- 이 결과는 migration data-plane 검증 결과로 인정하지 않는다.
- `windows11` 테스트 VM의 Nutanix source vDisk는 정상 Windows OS 디스크가 아니다.
- base snapshot과 live vDisk 모두 100 GiB logical size이지만 실제 할당량은 512 bytes 수준이다.
- MBR signature는 `55aa`가 아니라 `0000`이고, GPT `EFI PART` 및 NTFS signature도 확인되지 않았다.
- VM inventory에는 5 GiB SATA CDROM과 100 GiB SCSI DISK가 있었고, n2k는 CDROM을 제외한 SCSI DISK만 migration disk로 선택했다. 디스크 선택은 맞지만 선택된 SCSI DISK 자체가 비어 있다.
- 따라서 `windows11`은 정상 원본 데이터가 준비될 때까지 E2E 대상에서 제외한다.
- OS가 설치된 `windows11` VM을 새로 준비한 뒤 source disk sanity check를 통과해야 Phase1/Phase2 E2E를 다시 수행한다.

E2E 중 발견한 보완 사항:

- shutdown 결과가 단일 JSON object가 아닌 빈 값/복수 JSON stream 형태로 들어와도 manifest/event 기록에 사용할 수 있도록 JSON compact helper를 추가했다.
- Phase2 첫 실행에서 shutdown 후 JSON 기록 단계가 실패했으나, source VM은 OFF로 전환되었고 재개 실행에서 final snapshot, final sync, cutover artifact 생성을 완료했다.
