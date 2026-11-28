# v2k 원본 디스크 식별과 대상 드라이버 정책

이슈 [#89](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/89)의 v2k 구현이다. n2k 적용은 별도 후속 작업이다.

## 사용 방법

`--target-disk-controller auto|sata|virtio-scsi|preserve`를 `init`, `run`, `wizard`에서 지정한다. 기본값은 `auto`다. Wizard에서는 대상 드라이버와 필요한 경우 부팅 디스크를 선택한다. `--yes`에서도 명시한 값을 그대로 사용한다.

```bash
ablestack_v2k wizard --target-profile cloud-filesystem \
  --target-disk-controller auto --target-preallocation falloc ...
ablestack_v2k wizard --target-profile libvirt-qcow2 \
  --root-disk-id scsi0:1 --target-disk-controller virtio-scsi ...
```

| 정책 | 대상 ROOT/DATA 드라이버 |
|---|---|
| `auto` | 원본 IDE/SATA는 SATA/AHCI, 원본 SCSI는 VirtIO SCSI로 변환 |
| `sata` | SATA/AHCI로 명시 변환 |
| `virtio-scsi` | VirtIO SCSI로 명시 변환 |
| `preserve` | 버전 1에서 검증된 원본 SATA/AHCI만 유지. IDE 및 VMware 전용 SCSI 모델은 사전 거부 |

대상은 q35이며 BIOS/EFI 선택을 원본에서 유지한다. 원본 IDE 정보는 대상 SATA 변환과 별개로 보존한다. 서로 다른 종류의 DATA 디스크는 하나의 VirtIO SCSI 정책으로 정규화하며 그 결과를 명시적으로 기록한다. 지원하지 않는 원본 컨트롤러 및 불명확한 부팅 디스크는 전송 전에 거부한다.

부팅 디스크는 명시한 `--root-disk-id`(안정적인 주소 또는 VMware 장치 키), 원본의 명시적 bootOrder, `Hard disk 1`, 단일 디스크, 동일 컨트롤러의 주소 순으로 결정한다. 컨트롤러가 혼합되고 근거가 없으면 선택을 요구한다. 선택한 ROOT가 CBT와 파일명 생성 전에 인덱스 0이 된다.

## 기록과 재개

`target.disk_controller_plan`에 원본 UUID, 각 디스크 ID/장치 키/컨트롤러 주소/역할/크기, 대상 버스/모델/장치명과 정규화 SHA-256을 저장한다. 원본 식별 정보는 변환 후에도 남는다. `sda`부터 `sdz`, `sdaa` 이후까지 장치명이 중복되지 않는다.

같은 workdir의 재개는 원본 디스크 식별, 크기, ROOT, 대상 정책의 변경을 거부한다. 실패한 게스트 준비 단계에서 다른 버스로 암묵적으로 폴백하지 않는다. VDDK 인증은 런타임 환경이나 운영자가 공급한 보호된 자격 파일을 사용하며, 작업 디렉터리에 비밀번호 파일을 자동 생성하지 않는다.

## Mold 연동

Mold에 다음 API와 Agent 버전 1 계약이 필요하다.

- `getMigrationDiskControllerCapabilities`: 선택 스토리지에 현재 연결된 KVM 작업 호스트의 q35, 펌웨어, SATA/VirtIO SCSI 지원을 실제 조회한다.
- `verifyMigratedVirtualMachine`: 최초 시작 전에 계획을 실제 ROOT/DATA 볼륨 UUID, 슬롯, 크기, 풀, 경로, 포맷과 결합한다. 시작 후에는 실행 중인 도메인 XML을 검증한다.

VM 생성 요청에 canonical 계획과 `rootDiskController`, `dataDiskController`, q35 및 BIOS/UEFI 세부 값을 전달한다. Mold는 계획과 증거를 숨김 메타데이터로 저장하고 일반 VM 업데이트 및 메타데이터 API에서 변경/삭제를 막는다. 기존 미완료 작업의 복구는 정지 상태이며 아직 시작하지 않은 엄격한 import와 기존 볼륨 결합이 정확히 일치할 때만 허용한다.

실제 시작 호스트는 최종 XML의 펌웨어/머신, 디스크 수, ROOT 순서, 각 볼륨 경로와 포맷, 대상 버스와 해당 주소에 연결된 컨트롤러 모델을 확인한다. XML 변환 훅 뒤와 libvirt 정규화 뒤에 검사하며 불일치 시 게스트를 실행하지 않는다. 실행 후 조회는 이미지에 접근하지 않는다.

preallocation `falloc` 기본값 및 writeback은 별도 #87 계약을 그대로 유지한다. 최초 시작 뒤에는 기존 물리 extent 수를 다시 고정하거나 실행 중 이미지를 오프라인 검사하지 않는다.

## 검증 범위

자동 회귀 검증은 `tests/v2k_controller_policy_test.py`, `tests/v2k_cbt_pagination_smoke.py`, 기존 preallocation/Mold handoff 검증과 Cloud의 `MigrationDiskController*Test`를 사용한다. 실제 VMware와 13번 GFS2 클러스터 결과는 별도 검증 문서에 기록한다. NIC MAC 보존과 게스트 내부 인터페이스 이름 설정은 구분해야 한다. 원본의 인터페이스 이름에 고정된 네트워크 설정은 VirtIO NIC 전환 뒤 운영자 조정이 필요할 수 있다.

## 실제 검증과 OS 후속 절차

[13번 GFS2 실제 검증 결과](../validation/issue89-v2k-cluster13-20261126.md)를 확인한다. Windows는 원본 게스트 계열에 맞는 q35 16포트 프로파일을 최초 생성 요청에 명시한다. 원본 이름에 고정된 Linux NIC 설정과 Windows SAN/드라이브 문자 조정은 디스크 드라이버 계약과 별도이며, 이번 코드가 자동 변경하지 않는다.

Mold import 요청 UUID가 기록된 이후에는 source snapshot/base/incremental/final 전송과 offline bootstrap으로 대상 이미지를 다시 쓰지 않는다. 동일 workdir의 full/phase2 재개는 Mold API의 조립·검증 경로만 사용하며, 직접 byte-plane 명령은 코드 44로 거부한다.
