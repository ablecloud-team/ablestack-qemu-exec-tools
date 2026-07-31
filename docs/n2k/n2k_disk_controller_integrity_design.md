# n2k 디스크 컨트롤러 및 디스크 식별 무결성 설계

## 1. 문제 정의

n2k 인벤토리는 명시적인 Nutanix 부팅 디스크 주소가 없을 때 컨트롤러
종류와 유닛 번호로 디스크를 정렬한다. 기존 우선순위는 SCSI를 IDE보다
앞에 두므로 IDE 부팅 디스크와 SCSI 데이터 디스크가 혼합된 VM에서 SCSI
데이터 디스크를 루트로 선택할 수 있다.

Cloud 대상은 모든 데이터 디스크에 적용되는 `dataDiskController` 하나만
받지만, 기존 구현은 첫 번째 데이터 디스크의 컨트롤러만 사용했다. SATA와
SCSI 데이터 디스크가 혼합되어도 나머지 종류를 확인하지 않았고, PCI 또는
알 수 없는 컨트롤러는 오류 없이 기본값으로 변환되거나 파라미터에서
누락될 수 있었다.

Nutanix 변경영역과 NFS 스냅샷 경로를 manifest 디스크에 연결할 때는
vDisk UUID를 우선하지만, UUID가 없으면 크기와 ordinal을 함께 사용했다.
동일 크기 디스크의 스냅샷 순서가 manifest 순서와 다르면 잘못된 디스크로
전송될 가능성이 있다.

## 2. 설계 원칙

1. Nutanix `extId`와 vDisk UUID를 디스크 식별의 권위 값으로 사용한다.
2. 디스크 컨트롤러는 `ide`, `scsi`, `sata`, `virtio`로 정규화한다.
3. `pci`, NVMe 계열 및 알 수 없는 컨트롤러는 지원 보류로 처리한다.
4. 명시적인 부팅 디스크 주소가 있으면 정확히 한 디스크와 일치해야 한다.
5. 명시적인 부팅 주소 없이 여러 컨트롤러 종류가 혼합되면 루트 디스크를
   추정하지 않는다.
6. 지원하지 않거나 모호한 인벤토리는 스냅샷과 전송 전에 코드 44로
   중단한다.
7. Cloud 데이터 디스크의 컨트롤러 종류는 비어 있거나 정확히 하나여야 한다.
8. libvirt의 혼합 컨트롤러는 검증된 명시적 부팅 디스크가 있을 때만 허용한다.
9. UUID가 없는 스냅샷 디스크는 크기가 유일할 때만 manifest 디스크에
   연결한다.
10. 일부 디스크만 매핑된 NFS source map은 기본 전송에 사용하지 않는다.

## 3. 인벤토리 컨트롤러 계획

정규화된 각 디스크는 원본 `controller.type`과 정규화된
`controller.kind`를 함께 보존한다.

| Nutanix 주소 | 정규화 값 | 지원 |
|---|---|---|
| SCSI 계열 | `scsi` | 지원 |
| IDE | `ide` | 지원 |
| SATA | `sata` | 지원 |
| VirtIO | `virtio` | 지원 |
| PCI/NVMe | `pci` | 지원 보류 |
| 그 외 | `unknown` | 미지원 |

인벤토리에는 다음 검증 결과를 `controller_plan`으로 저장한다.

- 검증 상태와 실패 사유
- 부팅 주소 존재 여부와 일치 디스크 수
- 루트 선택 방식
- 발견된 전체 컨트롤러 종류
- 미지원 컨트롤러 종류
- 선택된 루트 디스크와 컨트롤러
- 데이터 디스크 컨트롤러 종류

루트 선택 방식은 다음 두 가지 성공 상태만 허용한다.

- `explicit_boot_address`: Nutanix 부팅 주소가 정확히 한 디스크와 일치
- `controller_unit_fallback`: 모든 디스크가 같은 컨트롤러 종류이며
  버스와 유닛 번호로 정렬

혼합 컨트롤러인데 명시적인 부팅 주소가 없으면
`mixed_controller_boot_disk_ambiguous`로 중단한다.

## 4. Manifest 및 사전 실패

`init`은 정규화된 계획을 `source.controller_plan`에 저장하고
`runtime.source_validation`에 최종 판정과 지원 컨트롤러 목록을 기록한다.

실패 시 다음 정보를 함께 기록한다.

- 오류 코드 `44`
- 구체적인 실패 사유
- 전체 컨트롤러 계획
- 미지원 컨트롤러 목록
- `stop_before_snapshot` 이벤트

이 검증은 Nutanix recovery point, VM snapshot, NFS mount 또는 대상 데이터
전송보다 먼저 완료된다.

## 5. Cloud 컨트롤러 계획

Cloud 대상은 source 검증을 통과한 뒤 별도의
`target.cloud.disk_controller_plan`을 생성한다.

- 루트 디스크는 정확히 하나여야 한다.
- 루트 및 데이터 컨트롤러는 지원 목록에 있어야 한다.
- 데이터 컨트롤러 종류가 둘 이상이면
  `cloud_mixed_data_controller_unsupported`로 중단한다.
- 성공한 계획의 `effective.root`와 `effective.data`만
  `deployVirtualMachineForVolume` 파라미터에 사용한다.

기존 manifest를 재사용하는 cutover 경로에서도 계획을 재검증한다. 계획이
없는 구형 manifest는 디스크 배열 전체를 검사해 동일한 조건을 만족할
때만 허용한다.

## 6. Libvirt 컨트롤러 검증

libvirt는 디스크별 bus를 지정할 수 있으므로 명시적 부팅 디스크가 검증된
IDE/SCSI/SATA/VirtIO 혼합은 허용한다.

다음 조건은 XML 생성 전에 중단한다.

- PCI/NVMe/알 수 없는 컨트롤러
- source controller plan이 없는 구형 혼합 컨트롤러 manifest
- 혼합 컨트롤러지만 `explicit_boot_address` 판정이 없는 경우

알 수 없는 컨트롤러를 SCSI로 암묵 변환하지 않는다.

## 7. 변경영역 및 NFS 디스크 매핑

스냅샷 디스크는 다음 순서로 manifest 디스크와 연결한다.

1. `disk_id`, `device_key`, `nutanix.vdisk_uuid` 직접 일치
2. 정확히 한 manifest 디스크만 같은 용량을 갖는 경우
3. 그 외에는 매핑 실패

ordinal 기반 추정은 제거한다. v3 NFS source map은 다음 수가 모두
manifest 디스크 수와 같아야 성공한다.

- 스냅샷 경로의 디스크 수
- 성공적으로 매핑된 디스크 수
- 최종 source map의 고유 디스크 수

하나라도 다르면 기본 전송을 시작하지 않는다.

## 8. 재시도 및 호환성

- 새 실패는 외부 스냅샷이나 대상 VM을 만들기 전 발생하므로 같은 입력을
  수정한 뒤 안전하게 다시 실행할 수 있다.
- 수정 전 생성된 혼합 컨트롤러 manifest는 루트 역할이 잘못됐을 수 있으므로
  새 workdir에서 `phase1`부터 다시 시작한다.
- 단일 SCSI/IDE/SATA/VirtIO VM과 명시적 부팅 주소가 있는 혼합 VM은 기존
  경로를 유지한다.
- UUID가 보존된 v3/v4 변경영역 경로는 기존 직접 매핑을 유지한다.

## 9. 검증 범위

- 단일 컨트롤러의 유닛 순서 fallback
- 명시적 부팅 주소가 있는 IDE/SCSI 혼합 VM
- 부팅 주소 없는 혼합 컨트롤러 사전 거부
- PCI/알 수 없는 컨트롤러 사전 거부
- Cloud 단일 데이터 컨트롤러 계획
- Cloud 혼합 데이터 컨트롤러 사전 거부
- libvirt 검증된 혼합 컨트롤러 허용과 미검증 혼합 거부
- UUID 직접 매핑과 유일 용량 fallback
- 동일 용량 디스크의 ordinal 추정 거부
- 기존 변경영역, phase marker, Cloud NIC 및 대상 런타임 회귀 테스트
