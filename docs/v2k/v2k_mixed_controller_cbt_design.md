# v2k 혼합 디스크 컨트롤러 CBT 개선 설계

## 1. 문제 정의

기존 v2k는 VMware 인벤토리에서 SATA와 NVMe 주소를 일부 식별하지만,
CBT 활성화와 `QueryChangedDiskAreas` 조회는 `scsiX:Y` 형식만 허용했다.
IDE 컨트롤러는 인벤토리에서도 누락되어 `devkey:<key>`로 기록되었다.

이 불일치로 인해 다음 문제가 발생했다.

- 기본 전송이 100% 완료된 뒤에야 비-SCSI 디스크의 CBT 기준점 저장 실패
- `phases.base_sync.done=false` 및 phase1 완료 마커 미기록
- phase2에서 실제 선행 원인 대신 완료 마커 오류 노출
- BIOS 기반 IDE 부팅 디스크보다 SCSI 데이터 디스크가 먼저 정렬되어 잘못된
  루트 디스크가 선택될 가능성
- CBT 활성화를 건너뛴 디스크도 manifest에 `cbt.enabled=true`로 기록

## 2. 설계 원칙

1. VMware `VirtualDisk.key`를 변경 추적의 권위 있는 식별자로 사용한다.
2. `disk_id`는 운영자 가독성과 ExtraConfig 주소 설정을 위해 유지한다.
3. 명시적인 부팅 순서가 있으면 항상 우선한다.
4. 부팅 순서가 없는 BIOS VM은 VMware의 `Hard disk N` 순서를 컨트롤러
   종류보다 우선한다.
5. CBT 활성화 또는 기준점 확인에 실패한 디스크가 하나라도 있으면 기본
   전송 전에 중단한다.
6. 실패한 디스크를 `cbt.enabled=true`로 표시하지 않는다.
7. phase1 완료 마커를 수동 보정하거나 부분 CBT 상태로 phase2를 허용하지 않는다.
8. 지원 컨트롤러는 IDE, SCSI, SATA로 제한한다.
9. NVMe는 식별 정보만 보존하고 CBT, 스냅샷, 전송 전에 명시적으로 거부한다.
10. Cloud 대상은 검증된 루트/데이터 컨트롤러 계획을 manifest에 저장하고
    같은 계획을 VM 정의에 사용한다.

## 3. 인벤토리 모델

인벤토리에서는 다음 네 종류를 정규화하되, 이관 지원 여부를 별도로 기록한다.

| VMware 컨트롤러 | `controller.kind` | `disk_id` 예 | 이관 지원 |
|---|---|---|---|
| VirtualIDEController | `ide` | `ide0:0` | 지원 |
| VirtualSCSIController 계열 | `scsi` | `scsi0:0` | 지원 |
| VirtualSATAController/AHCI | `sata` | `sata0:0` | 지원 |
| VirtualNVMEController | `nvme` | `nvme0:0` | 지원 보류 |

각 디스크는 다음 두 식별자를 함께 보존한다.

- `device_key`: VMware가 부여한 불변 VirtualDisk 장치 키
- `disk_id`: 컨트롤러 종류, 버스 및 유닛을 표현하는 주소

알 수 없는 컨트롤러는 계속 `devkey:<key>`로 표시한다. NVMe와 알 수 없는
컨트롤러는 manifest 초안을 만든
직후 사전검증에서 코드 44로 종료한다. 이 검증 전에는 CBT 설정, 스냅샷 생성,
데이터 전송을 수행하지 않는다.

## 4. 루트 디스크 결정

디스크 정렬 우선순위는 다음과 같다.

1. `config.bootOptions.bootOrder`의 명시적 VirtualDisk device key
2. `Hard disk N` 레이블의 N
3. 컨트롤러 종류와 버스/유닛 주소
4. 원본 인벤토리 순서

정렬된 첫 번째 디스크만 `role=root`로 기록한다. 이를 통해 명시적 bootOrder가
없는 Windows Server 2003과 같은 BIOS VM에서 `Hard disk 1` IDE 부팅 디스크가
SCSI 데이터 디스크보다 뒤로 밀리는 문제를 방지한다.

## 5. CBT 활성화

VM 전역 `ctkEnabled=true`를 먼저 설정하고 각 디스크에 다음 ExtraConfig를
설정한다.

```text
<disk_id>.ctkEnabled=true
```

허용 주소는 `ide|scsi|sata`와 숫자 버스/유닛의 조합이다.

- 성공한 디스크만 `cbt.enabled=true`
- 실패하거나 주소가 없는 디스크는 `cbt.enabled=false`
- 실패 상세는 `runtime.sync_issues`, `runtime.last_error` 및 디스크
  `transfer.last_error`에 기록
- 하나라도 실패하면 코드 44로 base 이전에 중단

ExtraConfig 설정 성공은 최종 지원 판정이 아니다. 실제 지원 여부는 base
스냅샷의 backing changeId 확인으로 다시 검증한다.

NVMe는 ExtraConfig 설정을 시도하지 않는다. 인벤토리에서 `nvme`로 정확히
식별한 뒤 `nvme_support_deferred`로 사전 실패시켜 부분 이관이나 암묵적
SATA/SCSI 변환을 방지한다.

## 6. CBT 기준점 및 증분 조회

Python 조회기는 `--device-key`를 `--disk-id`보다 우선한다.

1. 스냅샷 config의 VirtualDisk 목록에서 device key가 일치하는 디스크 선택
2. device key가 없는 구형 manifest만 주소 기반 선택 사용
3. `devkey:<key>` 형식도 이전 manifest 호환을 위해 device key로 해석
4. base 스냅샷 backing changeId가 비어 있으면 코드 44로 중단
5. 증분 및 최종 조회는 같은 device key로 `QueryChangedDiskAreas` 실행
6. 전체 용량 coverage 검증과 patch flush 후에만 `last_change_id` 갱신

CBT 기준점 검증은 장시간 기본 전송보다 먼저 실행하여 지원하지 않는 디스크를
조기에 발견한다.

## 7. Cloud 디스크 컨트롤러 계획

Cloud 대상은 사전검증 후 다음 계획을 manifest에 저장한다.

- 원본 루트 디스크의 `controller.kind`
- 데이터 디스크 컨트롤러 종류 목록
- Cloud에 실제 적용할 루트/데이터 컨트롤러
- SATA 부팅 폴백과 같은 명시적 override 사유

정상 경로에서는 다음 값을 `deployVirtualMachineForVolume`에 전달한다.

```text
details[0].rootDiskController=<ide|scsi|sata>
details[0].dataDiskController=<ide|scsi|sata>
```

Cloud는 데이터 디스크별 컨트롤러가 아니라 모든 데이터 디스크에 적용되는
컨트롤러 하나만 받는다. 따라서 데이터 디스크에 SCSI와 SATA가 혼합된 경우
첫 번째 타입을 임의 선택하지 않고 `cloud_mixed_data_controller_unsupported`
오류로 전송 전에 중단한다.

## 8. 실패 및 재시도 정책

- NVMe/알 수 없는 컨트롤러: init 실패, CBT 및 스냅샷 미실행
- Cloud 혼합 데이터 컨트롤러: init 실패, CBT 및 스냅샷 미실행
- CBT 활성화 실패: base 미실행, phase1 미완료
- base changeId 실패: base 미실행, phase1 미완료
- 증분 조회 실패: patch 및 changeId 갱신 금지
- patch 실패: 기존 changeId 유지, 동일 범위 재전송
- 혼합 컨트롤러 수정 전 생성된 manifest는 루트 순서와 CBT 상태가 잘못되었을
  수 있으므로 새 workdir에서 phase1부터 다시 시작

## 9. 검증 범위

- IDE/SCSI/SATA/NVMe 인벤토리 식별과 IDE 루트 순서
- 명시적 bootOrder 우선
- IDE/SCSI/SATA의 ExtraConfig 설정과 manifest 상태
- NVMe 사전 거부와 VMware 무변경 확인
- 알 수 없는 컨트롤러의 fail-closed 처리 및 오류 상태 기록
- device key 우선 디스크 선택 및 `devkey:<key>` 호환
- CBT 기준점 검증이 base 전송보다 먼저 수행되는 순서
- IDE 루트/SCSI 데이터 Cloud 파라미터
- 혼합 데이터 컨트롤러 Cloud 사전 거부
- SATA 폴백의 원본/실효 컨트롤러 기록
- 기존 CBT 다중 페이지 coverage 및 대용량 변경영역 파일 전달 회귀

실제 VMware 버전별 IDE/SCSI/SATA CBT 지원은 ExtraConfig와 backing changeId
응답으로 런타임에 다시 판정한다. NVMe는 현재 버전에서 지원 보류이며
지원하지 않는 조합을 강제로 증분 이관하지 않는다.
