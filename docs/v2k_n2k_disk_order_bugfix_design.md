# V2K/N2K 디스크 순서 보정 설계

## 배경

N2K wizard 테스트에서 Nutanix inventory 배열 첫 번째 디스크가 실제 `SCSI unit 0`이 아닌 `SCSI unit 1`로 내려왔고, n2k가 배열 첫 번째 디스크를 Cloud ROOT 볼륨으로 사용하면서 대상 VM의 root/data 디스크 역할이 뒤바뀌었다.

V2K 코드도 Cloud cutover, libvirt XML 생성, Linux bootstrap 단계에서 `.disks[0]`을 root 디스크로 간주한다. VMware inventory는 `disk_id`를 `scsi0:0`처럼 주소 기반으로 만들지만, govc device 배열을 명시적으로 정렬하지 않으면 같은 계열의 오류가 발생할 수 있다.

## 원칙

- 외부 API가 반환한 디스크 배열 순서를 root 판정 근거로 사용하지 않는다.
- 명시적인 boot disk 정보가 있으면 가장 우선한다.
- boot disk 정보가 없으면 컨트롤러 타입, 버스, 유닛 번호 기준으로 안정 정렬한다.
- 정렬 후 첫 번째 디스크는 `role=root`, 나머지는 `role=data`로 기록해 후속 분석과 로그 판독을 쉽게 한다.
- wizard target map, manifest, phase1/phase2/full cutover가 동일한 정렬 결과를 공유하도록 inventory 정규화 단계에서 보정한다.

## N2K 적용

- Nutanix inventory 정규화 단계에서 `bootConfig.bootDevice.diskAddress`가 있으면 해당 디스크를 root로 우선 정렬한다.
- boot 주소가 없으면 `controller.type`, `controller.bus`, `controller.unit/device_index`, 원본 배열 인덱스 순으로 정렬한다.
- 정렬 후 fallback label과 `role`을 부여한다.

## V2K 적용

- VMware inventory 정규화 단계에서 `config.bootOptions.bootOrder[].deviceKey`가 있으면 해당 `VirtualDisk.key`를 가진 디스크를 root로 우선 정렬한다.
- boot order가 없거나 디스크 항목이 없으면 `controller.type`, `controller.bus`, `controller.unit`, 원본 배열 인덱스 순으로 정렬한다.
- 정렬 후 `role=root|data`와 `source_ordinal`을 기록한다.

## 검증

- N2K: Nutanix API 배열이 `unit 1`, `unit 0` 순서로 내려와도 `unit 0`이 `.disks[0]`이 되는 smoke test를 추가한다.
- V2K: govc `device.info` 배열이 `scsi0:1`, `scsi0:0` 순서로 내려와도 `scsi0:0`이 `.disks[0]`이 되는 smoke test를 추가한다.
- V2K: boot order가 `scsi0:1`의 `deviceKey`를 명시하면 `scsi0:1`을 root로 우선하는 smoke test를 추가한다.
