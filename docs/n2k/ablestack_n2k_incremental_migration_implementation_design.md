# ablestack_n2k 증분 마이그레이션 구현 설계

## 목적

이 문서는 `ablestack_n2k`의 다음 구현 방향을 증분 마이그레이션 중심으로 재정렬하기 위한 설계 문서이다.

기존 구현은 manifest, inventory fallback, source-map 기반 base sync, libvirt XML 생성까지 검증되었다. 다음 구현은 전체 디스크를 단순 복제하는 cold path를 주 흐름으로 보지 않고, source VM을 계속 운영하면서 base sync와 반복 incremental sync를 수행한 뒤 마지막에 짧게 cutover 하는 방식을 우선한다.

## 설계 결론

- 기능 우선순위 1순위는 증분 마이그레이션이다.
- 증분 마이그레이션은 `base sync -> repeated incremental sync -> final sync -> cutover` 흐름을 기본 파이프라인으로 둔다.
- `cold-export`는 증분 capability가 없거나 실패했을 때의 차선 fallback이다.
- 테스트의 주 흐름은 증분 마이그레이션이어야 한다.
- target storage 테스트 우선순위는 `rbd`, `qcow2`, `block/lvm` 순서이다.
- 세 storage backend는 모두 테스트 대상이다. 단, release gate의 우선순위는 RBD를 가장 높게 둔다.

## 외부 API 근거

Nutanix가 공개적으로 문서화한 changed-region 기반 증분 경로는 v4 Data Protection Recovery Point API를 기준으로 한다.

- v4 Data Protection API는 recovery point 사이의 changed regions 계산을 제공한다.
- changed regions 조회는 Prism Central에서 PE cluster 정보와 token을 얻은 뒤, PE endpoint에서 실제 changed-region metadata를 가져오는 2단계 흐름이다.
- Nutanix v4 API Introduction 기준으로 `vmm`과 `dataprotection` namespace는 GA 기준 PC 7.3/AOS 7.3 이상 요구사항을 가진다.
- 현재 AOS 6.5.2 테스트베드는 v4 VMM endpoint가 HTTP `404`이므로, v4 증분 경로는 blocked로 판단하고 legacy CBT probe를 먼저 구현한다.

참고:

- `https://www.nutanix.dev/2025/01/15/nutanix-v4-disaster-recovery-api-series-part-2-changed-blocks-tracking-cbt-and-changed-regions-tracking-crt/`
- `https://www.nutanix.dev/api-reference-v4/`
- `https://www.nutanix.dev/api-versions/`

## 모드 우선순위

`--mode auto`의 실제 선택 순서는 다음과 같이 설계한다.

| 순위 | 모드 | 선택 조건 | 실패 시 |
| ---: | --- | --- | --- |
| 1 | `v4-incremental` | v4 VMM, Data Protection, Recovery Point, changed-region API 사용 가능 | `legacy-cbt` probe |
| 2 | `legacy-cbt` | 하위 버전 changed-region endpoint가 실제 offset/length 응답을 반환하고 사용자가 experimental 사용을 허용 | `cold-export` |
| 3 | `cold-export` | 증분 capability 없음, 또는 증분 경로 실패 | `manual-disk` |
| 4 | `manual-disk` | 운영자가 source disk image를 직접 제공 | 실패 처리 |

중요한 정책은 다음과 같다.

- `cold-export`는 자동 선택될 수 있지만, 기능 설계와 테스트의 주 흐름은 아니다.
- `legacy-cbt`는 운영 기본값이 아니라 하위 버전에서 최소 중단 가능성을 확보하기 위한 experimental 증분 모드이다.
- `v4-incremental`과 `legacy-cbt`는 같은 내부 sync pipeline을 사용하되, source API adapter만 다르게 둔다.
- 증분 mode가 blocked이면 테스트 결과는 먼저 `blocked`로 기록하고, 별도 fallback 테스트에서 `cold-export`를 검증한다.

## Target Storage 우선순위

storage backend는 구현과 테스트 모두에서 다음 순서를 따른다.

| 순위 | Backend | CLI 표현 | Target path 예 | Release gate |
| ---: | --- | --- | --- | --- |
| 1 | RBD | `--target-storage rbd` | `rbd:pool/image` | 필수 |
| 2 | qcow2 file | `--target-storage file --target-format qcow2` | `/var/lib/libvirt/images/n2k/vm/disk0.qcow2` | 필수 |
| 3 | block/LVM | `--target-storage block` | `/dev/vg_n2k/vm_disk0` | 필수, 단 우선순위 낮음 |

RBD를 1순위로 두는 이유는 ABLESTACK 운영 환경에서 공유 storage와 libvirt integration의 중심 경로가 될 가능성이 높기 때문이다. qcow2는 개발과 재현성이 좋고, block/LVM은 기존 raw block target 또는 로컬 LVM 환경을 지원하기 위한 호환 경로로 둔다.

## 전체 파이프라인

증분 마이그레이션의 표준 파이프라인은 다음과 같다.

```text
preflight
  -> init inventory
  -> plan
  -> prepare target storage
  -> create/select base recovery point
  -> base sync
  -> create/select incremental recovery point
  -> compute changed regions
  -> incremental sync
  -> repeat incremental sync until change window is small enough
  -> quiesce or shutdown source VM
  -> create/select final recovery point
  -> compute final changed regions
  -> final sync
  -> generate libvirt XML
  -> define target VM
  -> start target VM
  -> verify
  -> cleanup plan
```

## Cutover 정책

마지막 cutover의 목표는 source VM 중단 시간을 다음 구간으로 제한하는 것이다.

1. source VM guest shutdown 또는 application quiesce
2. final recovery point 생성
3. final changed regions 계산
4. final changed regions target 반영
5. target VM define/start
6. boot/network 확인

source VM을 중단하기 전에는 base sync와 incremental sync를 반복해 final changed region 크기를 줄인다. final changed region 크기가 설정한 기준보다 크면 cutover를 보류하고 incremental sync를 추가 수행한다.

예상 옵션:

| 옵션 | 의미 |
| --- | --- |
| `--max-final-bytes <bytes>` | cutover 허용 final changed bytes 상한 |
| `--max-final-regions <count>` | cutover 허용 final region count 상한 |
| `--incr-interval <seconds>` | 반복 incremental sync 간격 |
| `--max-incr-rounds <count>` | 자동 incremental sync 최대 반복 횟수 |
| `--cutover-shutdown manual|guest|poweroff` | source VM 중단 방식 |

## Source API Adapter 설계

source API는 내부 공통 interface로 감싼다.

| Adapter | 역할 |
| --- | --- |
| `v4` | v4 Recovery Point 생성, disk recovery point 식별, changed regions 계산, PE redirect/JWT 처리 |
| `legacy` | 하위 버전 snapshot, vDisk path, changed-region endpoint 탐지와 호출 |
| `manual` | 운영자가 제공한 source disk image와 changed-region fixture 사용 |

공통 함수 후보:

```text
n2k_source_probe_capabilities
n2k_source_get_inventory
n2k_source_create_recovery_point
n2k_source_get_disk_recovery_points
n2k_source_compute_changed_regions
n2k_source_open_disk_reader
n2k_source_cleanup_recovery_points
```

adapter output은 mode와 상관없이 같은 canonical JSON으로 정규화한다.

```json
{
  "schema": "ablestack-n2k/changed-regions-v1",
  "source_api": "v4",
  "base_recovery_point_id": "rp-base",
  "reference_recovery_point_id": "rp-ref",
  "disks": {
    "disk-id": [
      {"offset": 0, "length": 1048576, "type": "regular"},
      {"offset": 1048576, "length": 1048576, "type": "zero"}
    ]
  }
}
```

## Target Storage Adapter 설계

target storage도 공통 interface로 감싼다.

```text
n2k_target_probe
n2k_target_prepare
n2k_target_open_writer
n2k_target_write_full
n2k_target_write_region
n2k_target_zero_region
n2k_target_finalize
n2k_target_generate_disk_xml
n2k_target_cleanup
```

### RBD backend

RBD는 1순위 backend이다.

준비 항목:

- Ceph config와 keyring 확인
- pool 존재 확인
- per-disk RBD image 생성
- image size가 Nutanix disk size와 일치하는지 확인
- libvirt direct RBD XML 또는 mapped block device 전략 선택

쓰기 전략:

- base sync는 `qemu-img convert` 또는 streaming writer로 RBD raw image에 기록한다.
- incremental/final sync는 logical offset 기준으로 region patch를 수행한다.
- patch writer는 `rbd-nbd`, `krbd`, 또는 qemu block layer를 통해 raw block semantics를 확보해야 한다.
- zero region은 가능한 경우 discard/zero write로 처리한다.

XML 전략:

```xml
<disk type='network' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source protocol='rbd' name='pool/image'/>
  <target dev='sda' bus='scsi'/>
</disk>
```

libvirt secret이 필요한 환경은 preflight에서 별도 확인한다.

### qcow2 file backend

qcow2는 2순위 backend이다.

준비 항목:

- target directory 생성
- free space 확인
- qcow2 파일 생성 또는 base convert
- `qemu-img info`로 virtual size와 format 확인

쓰기 전략:

- base sync는 `qemu-img convert -O qcow2`를 사용한다.
- incremental/final patch는 qcow2 파일을 직접 `dd`로 수정하면 안 된다.
- qcow2 patch는 `qemu-nbd`, `qemu-storage-daemon`, 또는 qemu block layer 기반 logical writer를 통해 수행한다.
- direct file offset write는 qcow2 metadata를 손상시킬 수 있으므로 금지한다.

XML 전략:

```xml
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2' cache='none'/>
  <source file='/var/lib/libvirt/images/n2k/vm/disk0.qcow2'/>
  <target dev='sda' bus='scsi'/>
</disk>
```

### block/LVM backend

block/LVM은 3순위 backend이다.

준비 항목:

- target block device 또는 LV path 명시
- LV 생성 자동화 여부 선택
- block size와 disk size 확인
- 기존 데이터 overwrite 방지 guard 구현

쓰기 전략:

- base sync는 raw block device에 `dd` 또는 `qemu-img convert -O raw`를 사용한다.
- incremental/final patch는 `dd conv=notrunc oflag=seek_bytes` 또는 동등한 block writer로 수행한다.
- zero region은 `blkdiscard` 가능 여부를 확인하고, 불가능하면 zero write로 처리한다.

XML 전략:

```xml
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source dev='/dev/vg_n2k/vm_disk0'/>
  <target dev='sda' bus='scsi'/>
</disk>
```

## Manifest 확장

증분 구현을 위해 manifest에 다음 필드를 추가한다.

```json
{
  "runtime": {
    "sync": {
      "mode": "incremental",
      "round": 0,
      "base_recovery_point_id": "",
      "last_recovery_point_id": "",
      "last_changed_bytes": 0,
      "last_region_count": 0,
      "final_ready": false
    }
  },
  "target": {
    "storage": {
      "type": "rbd",
      "priority": 1,
      "prepared": false,
      "writer": ""
    }
  },
  "disks": [
    {
      "disk_id": "",
      "recovery_points": {
        "base": {},
        "last": {},
        "final": {}
      },
      "transfer": {
        "base_done": false,
        "incr_rounds": [],
        "final_done": false,
        "target_path": ""
      }
    }
  ]
}
```

기존 manifest v1을 깨지 않기 위해 필드는 optional로 추가하고, 없는 필드는 기본값으로 보정한다.

## CLI 설계

### preflight

증분과 storage backend를 모두 평가한다.

```bash
ablestack_n2k preflight \
  --pc 10.10.131.11 \
  --cred-file /run/n2k-nutanix.env \
  --mode auto \
  --target-storage auto \
  --probe-legacy-cbt \
  --json
```

출력에는 다음 항목이 포함되어야 한다.

- selected migration mode
- incremental capability reason
- v4 Data Protection availability
- legacy CBT probe result
- cold fallback availability
- storage backend ranking
- selected target storage
- missing dependencies

### plan

plan은 증분 흐름을 기본으로 출력한다.

```bash
ablestack_n2k plan \
  --vm rhel \
  --pc 10.10.131.11 \
  --mode auto \
  --target-storage auto \
  --json
```

증분이 불가능하면 plan은 cold fallback을 보여주되, primary flow가 blocked 된 이유를 먼저 표시한다.

### run

run은 전체 orchestration을 수행한다.

```bash
ablestack_n2k run \
  --vm rhel \
  --pc 10.10.131.11 \
  --cred-file /run/n2k-nutanix.env \
  --mode auto \
  --target-storage rbd \
  --dst rbd:ablecloud-vms/n2k-rhel \
  --max-final-bytes 1073741824 \
  --max-incr-rounds 3 \
  --cutover-shutdown manual
```

### 단계별 실행

운영자는 자동 run 대신 단계별로 실행할 수 있어야 한다.

```bash
ablestack_n2k snapshot base
ablestack_n2k sync base
ablestack_n2k snapshot incr
ablestack_n2k sync incr
ablestack_n2k snapshot final
ablestack_n2k sync final
ablestack_n2k cutover --apply --start
```

## 구현 단계

| 단계 | 이름 | 목표 | 완료 기준 |
| ---: | --- | --- | --- |
| 1 | target storage adapter | rbd/qcow2/block writer interface | 세 backend prepare/base/write/cleanup fixture 통과 |
| 2 | logical patch writer | region patch를 storage별로 안전하게 수행 | qcow2 direct write 금지, rbd/block patch 통과 |
| 3 | v4 incremental adapter | recovery point와 changed regions 구현 | v4 fixture와 API smoke 통과 |
| 4 | legacy CBT probe | 하위 버전 changed-region 가능성 탐지 | AOS 6.5.2 테스트베드에서 가능/불가 판정 기록 |
| 5 | incremental orchestrator | base/incr/final/cutover 자동 흐름 | source 중단 전 반복 incr, final threshold 판정 |
| 6 | cutover/verify 강화 | define/start/boot evidence 관리 | VM별 boot 결과와 rollback 증거 수집 |
| 7 | cold fallback 정리 | cold-export를 차선 경로로 유지 | 증분 blocked 시 fallback test만 수행 |

구현 순서상 cold fallback보다 target storage adapter와 incremental source adapter를 먼저 강화한다.

## 테스트 전략

테스트의 주 흐름은 증분 마이그레이션이다.

### Storage backend 테스트 우선순위

| 우선순위 | Backend | 테스트 목적 |
| ---: | --- | --- |
| 1 | RBD | ABLESTACK 공유 storage 주 경로 검증 |
| 2 | qcow2 | 재현성 높은 file target 검증 |
| 3 | block/LVM | raw block/LVM 호환 경로 검증 |

### 기본 테스트 행렬

| Test ID | VM | Mode | Storage | 목적 |
| --- | --- | --- | --- | --- |
| `N2K-INCR-RBD-001` | `rhel` | `v4-incremental` 또는 `legacy-cbt` | RBD | Linux 증분 주 흐름 |
| `N2K-INCR-QCOW2-001` | `rhel` | `v4-incremental` 또는 `legacy-cbt` | qcow2 | qcow2 logical patch 검증 |
| `N2K-INCR-BLOCK-001` | `rhel` | `v4-incremental` 또는 `legacy-cbt` | block/LVM | raw block patch 검증 |
| `N2K-INCR-RBD-002` | `windows11` | `v4-incremental` 또는 `legacy-cbt` | RBD | Windows desktop 증분 이관 |
| `N2K-INCR-RBD-003` | `winsvr2022` | `v4-incremental` 또는 `legacy-cbt` | RBD | Windows Server 증분 이관 |
| `N2K-COLD-RBD-001` | `test` | `cold-export` | RBD | 증분 blocked 시 fallback 검증 |
| `N2K-COLD-QCOW2-001` | `test` | `cold-export` | qcow2 | fallback file target 검증 |
| `N2K-COLD-BLOCK-001` | `test` | `cold-export` | block/LVM | fallback block target 검증 |

증분 capability가 없는 환경에서는 `N2K-INCR-*`를 failed로 처리하지 않는다. capability probe 결과와 함께 `blocked`로 기록하고, `N2K-COLD-*` fallback 시나리오를 별도로 실행한다.

### Release gate

preview gate:

- target storage adapter fixture 통과
- qcow2 direct patch 금지 검증 통과
- block/LVM raw patch fixture 통과
- RBD backend prepare/write fixture 또는 실제 RBD smoke 통과
- legacy CBT probe가 현재 테스트베드에서 가능/불가를 명확히 기록

incremental gate:

- 최소 1개 Linux VM이 증분 base/incr/final/cutover 흐름을 통과
- RBD backend에서 증분 흐름 통과
- qcow2 backend에서 증분 흐름 통과
- block/LVM backend에서 증분 흐름 통과
- final cutover 중 source 중단 구간이 기록됨
- failure 시 source VM이 보존됨

fallback gate:

- 증분 blocked 환경에서 cold fallback이 명확히 안내됨
- cold fallback은 RBD, qcow2, block/LVM 모두 실행 가능함

## 구현상 주의 사항

- qcow2 파일을 host file offset 기준으로 직접 patch하지 않는다.
- changed region offset은 guest disk logical offset으로 취급한다.
- region type이 `zero`이면 source read 없이 zero/discard로 처리한다.
- final sync 전 source VM 중단 또는 quiesce 상태를 manifest에 기록한다.
- source recovery point와 target disk cleanup은 분리한다.
- source recovery point 삭제는 기본값으로 수행하지 않는다.
- target storage prepare는 idempotent해야 한다.
- target disk overwrite는 `--force` 없이는 금지한다.
- RBD image와 LVM LV 이름은 VM 이름뿐 아니라 run id를 포함해 충돌을 피한다.
- libvirt XML은 storage backend별로 별도 생성하고, generated XML은 항상 artifact로 보관한다.

## 2026-05-14 구현 반영

1차 구현에서 다음 항목을 반영했다.

- `lib/n2k/target_storage.sh`를 추가해 file, RBD, block target의 base sync와 incremental patch 진입점을 분리했다.
- RBD target은 `rbd:pool/image` 형식을 검증하고, base sync는 `qemu-img convert -O raw` 경로를 사용하도록 정리했다.
- qcow2 incremental patch는 host file offset 직접 쓰기를 금지하고, `qemu-nbd` 기반 logical device patch 경로로 분리했다.
- block/LVM target은 raw block device patch 경로를 유지하되 storage adapter를 통해 호출하도록 정리했다.
- changed-region payload에 `regular`, `zero`, `zeros`, `zeroed`, `hole` region type을 허용하고 zero region은 source read 없이 zero write로 처리한다.
- `preflight`와 `plan`은 `--target-storage auto|rbd|file|block`, `--target-format qcow2|raw`, `--probe-legacy-cbt` 옵션을 받아 storage 우선순위와 selected storage를 출력한다.
- RBD가 없으면 `auto` storage는 qcow2 file backend로 fallback한다.
- `snapshot base|incr|final`은 현재 단계에서 Nutanix API 생성 대신 recovery point reference를 manifest에 기록한다. 실제 v4/legacy API 생성은 source adapter 구현 단계에서 연결한다.
- manifest에는 incremental sync runtime summary와 target storage priority를 기록한다.
- CI fixture smoke에 qcow2 base sync, RBD manifest path 생성, incremental plan storage selection 검증을 추가했다.

2차 구현에서 다음 항목을 반영했다.

- `lib/n2k/source_adapter.sh`를 추가해 Nutanix source capability probe를 분리했다.
- `preflight --probe-legacy-cbt`가 credential을 받은 경우 실제 Nutanix endpoint를 비파괴 probe한다.
- legacy changed-region 후보 endpoint는 `/api/nutanix/v3/data/changed_regions`로 probe한다.
- 현재 AOS 6.5.2 테스트베드에서 이 endpoint는 HTTP `422`를 반환했다. 이는 endpoint가 존재하지만 `snapshot_file_path` payload가 필요한 후보 상태로 분류한다.
- legacy changed-region request body helper를 추가했다. body는 `snapshot_file_path`, `reference_snapshot_file_path`, `start_offset`, 선택적 `end_offset`으로 구성한다.
- legacy changed-region 응답의 `region_list`, `file_size`, `next_offset`를 canonical changed-regions JSON으로 정규화하는 helper를 추가했다.
- `sync incr/final`은 직접 legacy 응답의 `region_list`도 changed-region 입력으로 받을 수 있도록 보강했다.

3차 구현에서 다음 항목을 반영했다.

- Prism Element v2 API Explorer를 통해 legacy Protection Domain API schema를 확인했다.
- `source_adapter.sh`에 Protection Domain 생성, VM 보호 등록, OOB snapshot 생성, PD snapshot 조회, snapshot 대기 helper를 추가했다.
- `snapshot base|incr|final --source-api legacy --create-oob-snapshot` 경로를 추가해 legacy PD snapshot을 만들고 manifest에 recovery point metadata로 기록할 수 있게 했다.
- manifest recovery point에는 legacy OOB schedule 응답, PD snapshot 원본 응답, disk별 snapshot path 후보 index를 함께 저장한다.
- PD snapshot full details의 `vm_files`는 현재 테스트베드에서 live vDisk path만 제공했다. 따라서 `.snapshot/<snapshot_id>/<vm_handle>/...` path는 `candidate_unverified`로 기록한다.
- 현재 테스트베드에서 candidate path를 `changed_regions` endpoint에 직접 넣었을 때 HTTP `400`이 반환되었다. 따라서 legacy CBT는 endpoint 존재와 PD snapshot 생성까지는 확인됐지만, snapshot file path 검증은 아직 blocked 상태다.
- CI smoke에는 PD snapshot path 후보 생성과 legacy snapshot dry-run manifest 출력 검증을 추가했다.

4차 구현에서 다음 항목을 반영했다.

- legacy PD snapshot 두 개의 disk path index를 비교해 동일 vDisk의 `snapshot_file_path`와 `reference_snapshot_file_path` 후보 pair를 만드는 helper를 추가했다.
- `snapshot incr|final --source-api legacy --create-oob-snapshot --verify-changed-regions` 옵션을 추가해 snapshot 생성 직후 후보 path pair를 `/api/nutanix/v3/data/changed_regions`에 probe하고 결과를 recovery point metadata에 기록한다.
- `snapshot incr`의 기본 reference는 `base`, `snapshot final`의 기본 reference는 `incr`로 잡고, 필요한 경우 `--reference-kind base|incr|final`로 명시할 수 있게 했다.
- 현재 AOS 6.5.2 테스트베드에서는 live vDisk path와 `.snapshot/<snapshot_id>/<vm_handle>/.acropolis/vmdisk/<disk_id>` 후보 모두 HTTP `400`으로 거절되었다. 응답 사유는 `kInvalidValue: Snapshot file pathname ... is not valid`, `reason: ENTITY_NOT_FOUND`였다.
- `changed_regions` request의 `start_offset`은 문자열이 아니라 integer여야 한다. 문자열 `"0"`을 넣으면 HTTP `422`와 `is not of type 'integer'` 검증 오류가 반환된다.
- 따라서 현재 구현은 legacy CBT를 완료 처리하지 않고, path 검증 실패 시 `changed_regions_validation.verified=false`와 실패 attempt를 manifest에 남긴다.

5차 구현에서 다음 항목을 반영했다.

- Prism Element API Explorer의 `/static/v3/swagger.json`에서 `/data/changed_regions`와 내부 `/vm_snapshots` API schema를 확인했다.
- `changed_regions_query.snapshot_file_path`는 "VM, Volume Group, Protection Domain 같은 entity snapshot 안의 file 절대 경로"이며, `vm_snapshot.status.snapshot_file_list[].snapshot_file_path`가 API가 요구하는 실제 경로로 제공된다.
- `lib/n2k/source_adapter.sh`에 v3 VM snapshot 생성, 조회, 대기, 삭제 helper와 `snapshot_file_list` 기반 path index helper를 추가했다.
- `snapshot base|incr|final --source-api v3 --create-vm-snapshot` 경로를 추가해 내부 v3 VM snapshot을 만들고, API가 제공한 snapshot file path를 manifest recovery point metadata에 기록한다.
- 현재 테스트베드의 `test` VM에서 v3 VM snapshot path는 `/Storage-Container/.snapshot/<number>/<long-id>/.acropolis/vmdisk/<disk_uuid>` 형식으로 반환되었다.
- 해당 path를 사용한 `changed_regions` incremental 호출은 HTTP `200`으로 성공했다. 변화가 없는 두 snapshot 사이에서는 `region_list`가 빈 배열이고 `file_size`가 반환된다.
- `reference_snapshot_file_path`가 없을 때 JSON `null`을 넣으면 HTTP `422`가 반환되므로, helper는 reference가 비어 있으면 해당 필드를 아예 생략하도록 수정했다.

6차 구현에서 다음 항목을 반영했다.

- `snapshot incr|final --source-api v3 --create-vm-snapshot --collect-changed-regions` 옵션을 추가했다.
- current/reference v3 VM snapshot의 `snapshot_file_path` pair를 모든 snapshot file에 대해 조회하고, `/api/nutanix/v3/data/changed_regions` 응답을 canonical changed-regions JSON으로 수집한다.
- 수집 결과는 `runtime.recovery_points.<kind>.metadata.v3.changed_regions`에 저장한다.
- snapshot file path의 vDisk UUID와 Prism VM disk UUID가 다를 수 있으므로, `changed_regions.file_size`와 manifest disk size를 이용해 manifest disk id로 매핑한다.
- 현재 `test` VM에서는 `Storage-Container`의 data disk가 manifest disk id `635259fe-07bd-48f8-9946-81a409436b30`로 매핑되고, `SelfServiceContainer` snapshot file은 manifest disk와 크기가 맞지 않아 `skipped`로 기록된다.
- `sync incr|final`은 `--changed-regions-json` 또는 `--changed-regions-file`이 없으면 manifest에 저장된 collected changed-regions를 자동으로 사용한다.
- 아직 실제 바이트 read는 기존 `--source-map-*` 입력에 의존한다. Nutanix snapshot file data plane은 backup proxy VM hotplug 또는 별도 export/read 경로로 연결해야 한다.

7차 구현에서 다음 항목을 반영했다.

- Prism v3 swagger에서 확인한 `GET /api/nutanix/v3/vms/{vm_uuid}/vm_disk/{vm_disk_uuid}/data?offset=<n>&length=<n>` API를 실험했다.
- 현재 테스트베드에서 이 API는 HTTP `200`으로 응답하며, body는 raw bytes가 아니라 base64 문자열이다. 예를 들어 512 bytes read는 684 bytes base64 payload로 반환된다.
- 현재 테스트베드에서 이 API는 `offset > 16777216` 요청을 HTTP `422`로 거절한다. 따라서 전체 디스크 read data plane이 아니라 작은 구간 read와 plumbing 검증용으로만 취급한다.
- `sync incr|final` source-map에 `nutanix-v3-data://<vm_uuid>/<vm_disk_uuid>` URI를 사용할 수 있게 했다.
- `nutanix-v3-data://` source는 changed-region 중 `regular` region만 API로 chunk read하고, base64 decode 후 workdir의 `source-cache` sparse raw file에 materialize한다.
- `zero`, `zeros`, `hole` region은 source API read 없이 기존 target zero-write 경로를 사용한다.
- Prism credential은 `sync` 명령의 `--pc`, `--username`, `--password`, `--cred-file`, `--insecure` 옵션 또는 `NUTANIX_USERNAME`/`NUTANIX_PASSWORD` 환경 변수로 런타임에만 전달하며 manifest나 문서에 저장하지 않는다.
- 현재 구현의 data source는 VM에 attach된 identity disk read API를 사용한다. 즉, snapshot file 자체를 직접 읽는 경로가 아니라 live VM disk 또는 snapshot clone VM disk를 읽는 경로다.
- 운영 증분 흐름에서 snapshot-consistent bytes와 전체 disk offset read를 보장하려면 다음 단계에서 v3 VM snapshot clone, proxy VM hotplug, CVM/NFS export 등 제한 없는 block-level read source를 확보해야 한다.

8차 구현에서 다음 항목을 반영했다.

- Nutanix cluster/CVM NFS export를 확인했다. 현재 테스트베드의 `10.10.131.10`과 `10.10.131.11`은 `/Storage-Container`를 NFSv3로 export한다.
- live vDisk `/Storage-Container/.acropolis/vmdisk/<vmdisk_uuid>`는 NFS에서 raw block file로 보이며, `qemu-img info` 기준 100GiB raw image로 인식된다.
- v3 VM snapshot이 제공한 `/Storage-Container/.snapshot/<nn>/<id>/.acropolis/vmdisk/<vmdisk_uuid>` 경로도 NFS에서 raw block file로 읽을 수 있다.
- v3 disk data API가 거절한 `offset=20971520` 구간을 NFS snapshot file에서 직접 읽어 local target raw file에 patch했고, source/target byte compare가 통과했다.
- source-map에 `nutanix-nfs://<host>/<container>/<path>` URI를 사용할 수 있게 했다. `sync`는 URI를 읽기 전용 NFS mount로 변환한 뒤 기존 base copy 또는 changed-region patch writer에 넘긴다.
- `sync --source-map-from-v3-nfs --nfs-host <host>` 옵션을 추가했다. base sync는 manifest의 v3 base recovery point `path_index`에서 source-map을 만들고, incr/final sync는 collected changed-region `disk_mappings`에서 source-map을 만든다.
- 접근이 거절되는 container path는 source-map 자동 생성에서 skip한다. 현재 테스트베드에서는 `SelfServiceContainer`가 이 경우에 해당하며, migration 대상 data disk는 `/Storage-Container`에 있다.

9차 검증에서 다음 항목을 확인했다.

- `test` VM에 대해 v3 base snapshot을 만들고, NFS snapshot file에서 local raw target으로 base sync를 수행했다.
- 100GiB source disk의 base sync는 `9:17.05`가 걸렸고, `cp --sparse=always` 적용 후 target apparent size는 100GiB이지만 실제 disk usage는 `0`으로 유지됐다.
- v3 incr/final snapshot을 만들고 각각 current/reference snapshot path pair로 changed-region을 수집했다.
- 테스트 중 source VM 변경이 없었으므로 incr/final `region_count=0`, `bytes_total=0`으로 수집됐고, `sync incr`와 `sync final`이 정상 완료됐다.
- final snapshot file과 target raw를 `offset=0`, `offset=20971520`, `offset=107374181888`에서 512 bytes 비교했고 모두 일치했다.

10차 검증에서 다음 항목을 확인했다.

- `rhel` VM에 대해 동일한 v3 snapshot + NFS data plane 흐름을 실행했다.
- 100GiB source disk의 base sync는 `8:09.94`가 걸렸고, sparse raw target의 실제 disk usage는 `2.8G`였다.
- VM이 실행 중이어서 incr snapshot에서 `32` regions, `356352` bytes 변경이 관측됐고, final snapshot에서 `1` region, `16384` bytes 변경이 관측됐다.
- `sync incr`와 `sync final`은 NFS snapshot file에서 해당 changed-region만 patch해 정상 완료됐다.
- final snapshot file과 target raw를 `offset=0`, `offset=20971520`, `offset=107374181888`에서 512 bytes 비교했고 모두 일치했다.
