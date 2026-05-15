# ablestack_n2k 실제 이관 테스트 시나리오

## 목적

이 문서는 Nutanix 테스트 환경에 있는 VM을 ABLESTACK KVM/libvirt 호스트로 이관하면서 `ablestack_n2k`의 기능 오류와 운영상 누락을 찾기 위한 실제 환경 테스트 시나리오이다.

기존 `ablestack_n2k_test_scenarios.md`가 정적 검증, 단위 테스트, fixture 테스트까지 포함하는 전체 테스트 카탈로그라면, 이 문서는 현재 테스트베드의 VM 종류별 실제 마이그레이션 절차와 판정 기준에 집중한다.

증분 마이그레이션 구현 우선순위와 storage backend 설계는 `docs/n2k/ablestack_n2k_incremental_migration_implementation_design.md`를 기준으로 한다.

## 작성 기준

- 작성일: 2026-05-14
- 소스 환경: Nutanix Prism Element `https://10.10.131.11:9440`
- 계정 정보: 문서에 비밀번호를 남기지 않는다. 테스트 실행 시 환경변수, 운영자 입력, 또는 보호된 임시 credential file을 사용한다.
- 대상 환경: ABLESTACK 호스트 `10.10.22.1`, `10.10.22.2`, `10.10.22.3`, SSH port `10022`
- 현재 확인된 Nutanix API 특성:
  - v2 VM API 사용 가능
  - v3 VM API 사용 가능
  - v4 VMM VM API는 HTTP `404`
  - 따라서 현재 테스트베드는 공식 v4 기반 `v4-incremental`을 바로 전제하지 않는다.
  - 그래도 테스트 주 흐름은 증분 마이그레이션으로 유지한다.
  - v4가 blocked이면 `legacy-cbt` 후보를 먼저 탐지하고, 증분 capability가 없을 때만 `cold-export` 또는 `manual-disk` fallback 테스트를 수행한다.

## 용어와 마이그레이션 전략 검토

### 증분 마이그레이션

이 문서에서 증분 마이그레이션은 전체 디스크를 한 번 복제한 뒤, 이후 변경된 영역만 반복 반영하고, 마지막 짧은 중단 시간에 final sync와 target VM 시작을 수행하는 방식을 의미한다.

공식적으로 문서화된 Nutanix changed-region 기반 증분 경로는 v4 Data Protection Recovery Point API를 기준으로 한다. v4 changed-region API는 두 VM 또는 VG disk recovery point 사이의 변경 영역을 계산한다. 이 경로는 Prism Central과 AOS 버전 요구사항이 높으므로 현재 AOS 6.5.2 테스트베드에서는 바로 사용할 수 없는 것으로 본다.

따라서 `ablestack_n2k`의 지원 수준은 다음과 같이 구분한다.

| 모드 | 의미 | 현재 테스트베드 전략 |
| --- | --- | --- |
| `v4-incremental` | v4 Recovery Point와 changed-region API 기반 최소 중단 이관 | 현재 v4 VMM/API 미지원으로 blocked |
| `legacy-cbt` | 하위 버전에서 changed-region 또는 동등 기능을 탐지해 사용하는 실험적 최소 중단 이관 | probe를 추가해 가능 여부 확인 필요 |
| `cold-export` | VM 중단 또는 일관성 있는 지점 확보 후 전체 디스크 복제 | 증분 blocked 이후 fallback |
| `manual-disk` | 운영자가 확보한 디스크 이미지를 KVM VM으로 구성 | export 자동화 전 구조 검증용 fallback |

### Cold migration

이 문서에서 cold migration 또는 `cold-export`는 가상머신을 종료하거나 쓰기 중단 상태로 만든 뒤, 일관성 있는 전체 디스크 이미지를 대상 ABLESTACK storage로 복제하는 방식을 의미한다.

운영적으로는 다음 절차를 기본으로 본다.

1. guest 정상 shutdown 또는 application quiesce 수행
2. Nutanix snapshot/export 또는 동등한 방식으로 source disk image 확보
3. 전체 disk image를 target storage로 복제
4. libvirt XML 생성과 define/start 수행

일관성 있는 snapshot을 사용하면 base image 확보 일부를 온라인으로 준비할 수는 있지만, changed-region을 안정적으로 계산하지 못하면 final cutover 시점의 변경분만 짧게 복제하는 보장이 없다. 따라서 일반적으로 `cold-export`는 다운타임이 길어질 수 있는 전체 복제 방식으로 분류한다.

### 하위 버전 최소 중단 가능성

하위 버전에서 최소 중단 마이그레이션이 절대 불가능하다고 단정하지 않는다. 다만 공개/권장 API 관점에서는 v4가 정식 경로이고, v3 또는 PE legacy 계열 changed-region 기능은 환경, 권한, 버전, API 공개 범위에 따라 달라질 수 있다.

현재 테스트베드에서는 다음 순서로 가능성을 검증한다.

1. v4 VMM/Data Protection endpoint 탐지
2. 실패 시 v3/v2 inventory fallback으로 VM과 disk 식별
3. legacy changed-region 후보 endpoint와 snapshot disk path 확보 가능성 탐지
4. legacy CBT가 실제 changed region 목록을 반환하면 `legacy-cbt` 실험 시나리오로 진행
5. legacy CBT가 없거나 불안정하면 `cold-export`로 진행

하위 버전 최소 중단 대안은 다음과 같이 분류한다.

| 대안 | 가능성 | 제한 |
| --- | --- | --- |
| legacy changed-region API | 환경에 따라 가능성 있음 | 공개/정식 지원 여부와 payload 형식 확인 필요 |
| Nutanix Protection Domain/DR 기능 | Nutanix 내부 DR에는 유용 | ABLESTACK KVM으로 직접 내보내는 경로는 별도 구현 필요 |
| guest-level replication | OS 또는 application별로 가능 | 범용 VM disk migration이 아니며 자동화 범위가 달라짐 |
| 반복 full export | 구현 가능 | 변경분만 복제하지 못하므로 최소 중단 보장 어려움 |

결론적으로 현재 문서의 실행 우선순위는 증분 capability 탐지와 증분 흐름 검증을 먼저 수행하고, 검증되지 않을 때만 `cold-export`를 차선으로 사용하는 것으로 둔다.

## 현재 구현 기준

2026-05-13 검증 기준으로 현재 RPM 설치본은 다음 흐름을 테스트할 수 있다.

- `init --inventory-source api`로 Nutanix VM 인벤토리 조회
- v4 실패 시 v3, v2 API fallback
- manifest 생성
- source-map JSON에 지정한 디스크 파일 또는 블록 디바이스를 target storage로 base sync
- target file storage의 `qcow2` 또는 `raw` 생성
- libvirt XML 생성
- `virsh define`, 선택적 `virsh start`
- manifest와 events log 기반 status 확인
- manifest 기록 리소스 cleanup 계획 생성

현재 자동화가 부족한 부분은 테스트 절차에서 수동 단계로 구분한다.

- Nutanix snapshot 또는 recovery point 생성 자동화
- Nutanix 디스크 export 자동화
- legacy changed-region endpoint 탐지와 payload 정규화
- v4 changed-region 기반 증분 동기화
- guest 내부 상태 자동 검증
- Nutanix network를 ABLESTACK bridge/network로 자동 매핑
- Windows UEFI, Secure Boot, vTPM, virtio driver 보정 자동화

## 테스트 VM 인벤토리

다음 값은 `init --inventory-source api` smoke manifest에서 확인한 기준값이다.

| VM | 역할 | UUID | vCPU | Memory MiB | Firmware | Disk | NIC |
| --- | --- | --- | ---: | ---: | --- | ---: | ---: |
| `test` | 기본 smoke VM | `db101f83-cf86-445b-aa10-16e4ce926560` | 1 | 4096 | `efi` | 1 | 1 |
| `rhel` | Linux guest | `25398214-02a9-47c2-918b-3959d9bbde55` | 1 | 4096 | `efi` | 1 | 1 |
| `windows11` | Windows desktop guest | `5412281a-bba1-43d2-b5dc-af0970126171` | 4 | 4096 | 미확인 | 1 | 1 |
| `winsvr2022` | Windows server guest | `886fd4b7-a97e-4fee-916b-6a7bcef11fe6` | 4 | 16384 | 미확인 | 1 | 1 |

디스크 기준값은 다음과 같다.

| VM | Disk ID | Size | Controller | Unit |
| --- | --- | ---: | --- | --- |
| `test` | `635259fe-07bd-48f8-9946-81a409436b30` | 100 GiB | SCSI | 1 |
| `rhel` | `c8bf3b1c-a7a0-4762-8c77-b623e65e1776` | 100 GiB | SCSI | 0 |
| `windows11` | `0135761d-a6a0-403f-afa1-a4e5e92e4566` | 100 GiB | SCSI | 0 |
| `winsvr2022` | `47790405-9793-42a3-9231-414d906e523b` | 100 GiB | SCSI | 0 |

NIC 기준값은 다음과 같다.

| VM | MAC | Nutanix Network |
| --- | --- | --- |
| `test` | `50:6b:8d:85:a4:0e` | `default` |
| `rhel` | `50:6b:8d:f4:5a:87` | `default` |
| `windows11` | `50:6b:8d:cb:f6:c8` | `default` |
| `winsvr2022` | `50:6b:8d:fc:d3:c5` | `default` |

## 대상 호스트와 storage 배치 원칙

초기 테스트는 증분 마이그레이션을 주 흐름으로 수행한다. storage backend는 RBD, qcow2, block/LVM 순서로 테스트한다. 세 backend는 모두 테스트 대상이지만, 장애 분석과 release gate의 우선순위는 RBD를 가장 높게 둔다.

| VM | 우선 대상 호스트 | 목적 |
| --- | --- | --- |
| `test` | `10.10.22.1` | 가장 짧은 smoke 이관과 절차 검증 |
| `rhel` | `10.10.22.2` | Linux boot, virtio, network 검증 |
| `windows11` | `10.10.22.3` | Windows desktop boot, UEFI/TPM/driver 이슈 검증 |
| `winsvr2022` | `10.10.22.1` 또는 가용 메모리가 가장 큰 호스트 | Windows server boot와 16 GiB memory 정의 검증 |

storage backend 배치 기준은 다음과 같다.

| 우선순위 | Backend | 목적 | 최소 확인 |
| ---: | --- | --- | --- |
| 1 | RBD | ABLESTACK 공유 storage 주 경로 | RBD image 생성, 증분 patch, libvirt direct RBD XML |
| 2 | qcow2 file | 재현성 높은 file target | base convert, qcow2 logical patch, XML define |
| 3 | block/LVM | raw block/LVM 호환 경로 | LV 또는 block device 준비, raw patch, XML define |

호스트별 최소 확인 항목은 다음과 같다.

- `rpm -q ablestack_n2k`
- `command -v ablestack_n2k`
- `command -v qemu-img`
- `command -v virsh`
- RBD 테스트 대상 호스트는 `command -v rbd`와 Ceph config/keyring 접근 가능 여부
- qcow2 테스트 대상 호스트는 target directory free space
- block/LVM 테스트 대상 호스트는 `command -v lvs`, `command -v lvcreate`, test LV 생성 가능 여부
- `virsh list --all`
- target storage 경로 쓰기 가능 여부
- `https://10.10.131.11:9440` 접속 가능 여부

## 공통 안전 원칙

- 첫 번째 부팅은 운영망과 분리된 libvirt network에서 수행한다.
- 원본 VM이 켜져 있는 상태에서 동일 MAC, 동일 IP의 target VM을 같은 L2 네트워크에 연결하지 않는다.
- 원본 VM 삭제, 원본 디스크 삭제, Nutanix snapshot 전체 삭제는 이 테스트 범위에 포함하지 않는다.
- `cleanup --remove-source-points`는 사용하지 않는다.
- Windows VM은 이관 전 virtio storage, virtio network driver 설치 상태를 확인한다.
- Windows 11은 UEFI, Secure Boot, vTPM 요구사항을 별도 결함 후보로 추적한다.
- target VM을 시작하기 전 XML을 `define-only`로 생성하고 disk path, memory, vCPU, NIC, firmware를 확인한다.

## 공통 실행 템플릿

### 1. credential 준비

테스트 명령은 비밀번호를 직접 저장하지 않는다. 필요 시 대상 호스트의 `/run` 아래에 임시 credential file을 만들고 테스트 종료 후 제거한다.

```bash
export NUTANIX_USERNAME='admin'
read -rsp 'NUTANIX_PASSWORD: ' NUTANIX_PASSWORD
echo

install -m 600 /dev/null /run/n2k-nutanix.env
{
  printf 'NUTANIX_USERNAME=%q\n' "${NUTANIX_USERNAME}"
  printf 'NUTANIX_PASSWORD=%q\n' "${NUTANIX_PASSWORD}"
} > /run/n2k-nutanix.env
```

### 2. VM별 공통 변수

```bash
VM='rhel'
PC='10.10.131.11'
RUN_ID="$(date +%Y%m%d-%H%M%S)"
WORKDIR="/var/lib/ablestack-n2k/${VM}/${RUN_ID}"
MODE="${MODE:-legacy-cbt}"
TARGET_STORAGE="${TARGET_STORAGE:-rbd}"
TARGET_FORMAT="${TARGET_FORMAT:-raw}"
DST="${DST:-rbd:ablecloud-vms/n2k-${VM}-${RUN_ID}}"
MANIFEST="${WORKDIR}/manifest.json"
EVENTS="${WORKDIR}/events.log"
SOURCE_MAP="${WORKDIR}/source-map.json"
TARGET_MAP_JSON="${WORKDIR}/target-map.json"
```

`TARGET_STORAGE`별 기본값은 다음과 같이 둔다.

| Backend | `TARGET_STORAGE` | `TARGET_FORMAT` | `DST` 예 |
| --- | --- | --- | --- |
| RBD | `rbd` | `raw` | `rbd:ablecloud-vms/n2k-rhel-<run-id>` |
| qcow2 | `file` | `qcow2` | `/var/lib/libvirt/images/n2k/rhel/<run-id>` |
| block/LVM | `block` | `raw` | target map에서 disk별 `/dev/<vg>/<lv>` 지정 |

### 3. 증분 preflight와 plan

증분 capability를 먼저 확인한다. 현재 테스트베드처럼 v4가 blocked이면 `legacy-cbt` probe 결과를 기록하고, 증분이 불가능한 경우에만 cold fallback 시나리오로 이동한다.

다음 명령의 `--target-storage`와 `--probe-legacy-cbt`는 증분 구현 설계에 따른 예정 옵션이다. 현재 RPM에서 미구현이면 이 단계는 구현 backlog로 기록한다.

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${MANIFEST}" \
  --log "${EVENTS}" \
  --json \
  preflight \
  --pc "${PC}" \
  --cred-file /run/n2k-nutanix.env \
  --insecure 1 \
  --mode auto \
  --target-storage "${TARGET_STORAGE}" \
  --probe-legacy-cbt
```

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${MANIFEST}" \
  --log "${EVENTS}" \
  --json \
  plan \
  --vm "${VM}" \
  --pc "${PC}" \
  --cred-file /run/n2k-nutanix.env \
  --mode auto \
  --target-storage "${TARGET_STORAGE}"
```

판정 기준:

- `v4-incremental` 또는 `legacy-cbt`가 가능하면 증분 시나리오를 계속 진행한다.
- 증분 capability가 없으면 증분 테스트는 `blocked`로 기록한다.
- `cold-export`는 같은 VM의 fallback 시나리오에서 별도로 실행한다.

### 4. inventory init

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${MANIFEST}" \
  --log "${EVENTS}" \
  init \
  --vm "${VM}" \
  --pc "${PC}" \
  --cred-file /run/n2k-nutanix.env \
  --insecure 1 \
  --inventory-source api \
  --mode "${MODE}" \
  --dst "${DST}" \
  --target-storage "${TARGET_STORAGE}" \
  --target-format "${TARGET_FORMAT}"
```

판정 기준:

- 명령 exit code가 `0`
- manifest가 생성됨
- `source.vm.name`, `source.vm.uuid`, `disks`, `source.vm.nics`가 비어 있지 않음
- events log에 `manifest_created`, `inventory_loaded` 이벤트가 기록됨

### 5. 증분 base/incr/final sync

증분 구현 완료 후의 주 흐름은 다음과 같다.

```bash
ablestack_n2k --workdir "${WORKDIR}" --manifest "${MANIFEST}" --log "${EVENTS}" snapshot base
ablestack_n2k --workdir "${WORKDIR}" --manifest "${MANIFEST}" --log "${EVENTS}" sync base
ablestack_n2k --workdir "${WORKDIR}" --manifest "${MANIFEST}" --log "${EVENTS}" snapshot incr
ablestack_n2k --workdir "${WORKDIR}" --manifest "${MANIFEST}" --log "${EVENTS}" sync incr
ablestack_n2k --workdir "${WORKDIR}" --manifest "${MANIFEST}" --log "${EVENTS}" snapshot final
ablestack_n2k --workdir "${WORKDIR}" --manifest "${MANIFEST}" --log "${EVENTS}" sync final
```

현재 설치본은 Nutanix recovery point 생성과 changed-region 조회 자동화가 아직 부족하다. 그 기간에는 source-map과 changed-regions fixture를 사용해 storage writer와 manifest 갱신을 먼저 검증한다. 이 fixture 기반 검증은 증분 구현의 대체가 아니라 구현 전 단계의 writer 검증으로만 분류한다.

source-map 예시:


```json
{
  "c8bf3b1c-a7a0-4762-8c77-b623e65e1776": "/var/lib/ablestack-n2k/source/rhel/disk0.raw"
}
```

changed-regions 예시:

```json
{
  "disks": {
    "c8bf3b1c-a7a0-4762-8c77-b623e65e1776": [
      {"offset": 0, "length": 1048576, "type": "regular"}
    ]
  }
}
```

fixture 기반 임시 명령 예시:

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${MANIFEST}" \
  --log "${EVENTS}" \
  sync base \
  --source-map-file "${SOURCE_MAP}"
```

판정 기준:

- target disk 또는 image가 생성됨
- `qemu-img info`가 성공함
- manifest의 `phases.base_sync.done`이 `true`
- 각 disk의 `transfer.base_done`이 `true`
- incremental sync 이후 manifest의 `phases.incr_sync.done` 또는 `phases.final_sync.done`이 갱신됨
- events log에 base, incr, final sync 이벤트가 기록됨

### 6. define-only cutover review

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${MANIFEST}" \
  --log "${EVENTS}" \
  cutover --define-only
```

판정 기준:

- libvirt XML이 생성됨
- XML의 disk source가 target qcow2를 가리킴
- memory와 vCPU가 source VM 기준값과 일치함
- NIC MAC이 manifest 기준값과 일치함
- 첫 부팅 전 network가 테스트 목적에 맞는 isolated network인지 확인됨

### 7. libvirt define/start

첫 실행은 source VM이 꺼져 있거나 target VM이 격리 network에 연결된 상태에서만 수행한다.

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${MANIFEST}" \
  --log "${EVENTS}" \
  cutover --apply

virsh dominfo "${VM}"
```

부팅 검증을 진행할 때만 다음을 실행한다.

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${MANIFEST}" \
  --log "${EVENTS}" \
  cutover --apply --start
```

판정 기준:

- `virsh define` 성공
- `virsh dominfo`에서 memory, vCPU가 기대값과 일치
- `virsh start` 성공 여부 기록
- boot 실패 시 XML, console log, libvirt log를 증거로 남김

### 8. cleanup

기본 cleanup은 계획 확인만 수행한다.

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${MANIFEST}" \
  --log "${EVENTS}" \
  cleanup --keep-source-points --keep-workdir
```

테스트 종료 후 credential file은 제거한다.

```bash
rm -f /run/n2k-nutanix.env
```

## 시나리오 목록

| ID | VM | 유형 | 대상 | 핵심 목적 | 상태 |
| --- | --- | --- | --- | --- | --- |
| `N2K-MIG-ENV-001` | 전체 | 환경 점검 | 전체 호스트 | RPM, dependency, Prism reachability 확인 | planned |
| `N2K-MIG-API-001` | 전체 | inventory | 전체 호스트 | v3/v2 fallback inventory 생성 확인 | planned |
| `N2K-MIG-LEGACY-001` | 전체 | legacy CBT probe | 전체 호스트 | 하위 버전 changed-region 가능성 확인 | planned |
| `N2K-MIG-INCR-RBD-001` | `rhel` | incremental/RBD | RBD 가능 호스트 | 증분 주 흐름과 RBD target 검증 | planned |
| `N2K-MIG-INCR-QCOW2-001` | `rhel` | incremental/qcow2 | qcow2 가능 호스트 | 증분 주 흐름과 qcow2 logical patch 검증 | planned |
| `N2K-MIG-INCR-BLOCK-001` | `rhel` | incremental/block | LVM 가능 호스트 | 증분 주 흐름과 block/LVM patch 검증 | planned |
| `N2K-MIG-GEN-001` | `test` | smoke | `10.10.22.1` | 가장 작은 전체 절차 검증 | planned |
| `N2K-MIG-LNX-001` | `rhel` | Linux | `10.10.22.2` | RHEL boot, virtio, network 검증 | planned |
| `N2K-MIG-WIN-001` | `windows11` | Windows desktop | `10.10.22.3` | Windows 11 boot 요구사항과 driver 검증 | planned |
| `N2K-MIG-WS22-001` | `winsvr2022` | Windows server | 가용 메모리 최대 호스트 | 16 GiB VM define/start와 server guest 검증 | planned |
| `N2K-MIG-NET-001` | 전체 | network | 전체 호스트 | Nutanix `default` network의 ABLESTACK network 매핑 검증 | planned |
| `N2K-MIG-RESUME-001` | `test` | resume | `10.10.22.1` | base sync 이후 중단/재개 계획 확인 | planned |
| `N2K-MIG-ROLLBACK-001` | 전체 | rollback | 전체 호스트 | target VM 제거와 source 보존 확인 | planned |
| `N2K-MIG-COLD-RBD-001` | `test` | cold fallback/RBD | RBD 가능 호스트 | 증분 blocked 시 RBD cold fallback 검증 | planned |
| `N2K-MIG-COLD-QCOW2-001` | `test` | cold fallback/qcow2 | qcow2 가능 호스트 | 증분 blocked 시 qcow2 cold fallback 검증 | planned |
| `N2K-MIG-COLD-BLOCK-001` | `test` | cold fallback/block | LVM 가능 호스트 | 증분 blocked 시 block/LVM cold fallback 검증 | planned |

## 상세 시나리오

### N2K-MIG-ENV-001: 환경 점검

대상:

- `10.10.22.1`
- `10.10.22.2`
- `10.10.22.3`

절차:

1. RPM 설치 상태를 확인한다.
2. `ablestack_n2k --help`를 실행한다.
3. `qemu-img`, `virsh`, `jq`, `curl` 존재 여부를 확인한다.
4. 각 호스트에서 Prism `https://10.10.131.11:9440` TCP 접속을 확인한다.
5. `/var/lib/libvirt/images/n2k` 생성 및 쓰기 가능 여부를 확인한다.

합격 기준:

- 모든 대상 호스트에서 명령 실행 가능
- Prism 접속 가능
- target storage 경로 생성 가능

### N2K-MIG-API-001: inventory fallback 검증

대상 VM:

- `test`
- `rhel`
- `windows11`
- `winsvr2022`

절차:

1. 각 VM에 대해 `init --inventory-source api`를 실행한다.
2. manifest의 VM UUID, disk count, NIC count를 기준값과 비교한다.
3. events log의 `inventory_loaded` payload가 valid JSON인지 확인한다.

합격 기준:

- 4개 VM 모두 manifest 생성 성공
- disk 1개, NIC 1개가 확인됨
- v4 API 미지원 환경에서도 inventory 생성이 실패하지 않음

### N2K-MIG-LEGACY-001: 하위 버전 changed-region 가능성 탐지

목적:

- AOS 6.5.2 테스트베드에서 v4 없이 최소 중단 마이그레이션을 구성할 수 있는지 판단한다.
- 가능하면 `legacy-cbt` 실험 시나리오로 승격하고, 불가능하면 `cold-export`를 공식 fallback으로 확정한다.

탐지 항목:

1. VM snapshot 또는 crash-consistent/application-consistent 지점 생성 가능 여부
2. snapshot별 vDisk path 또는 disk recovery point에 준하는 식별자 확보 가능 여부
3. 두 snapshot 사이 changed region 목록을 반환하는 legacy endpoint 존재 여부
4. changed region 응답의 offset, length, zero-region 정보를 target patch에 매핑할 수 있는지 여부
5. endpoint 인증 방식과 권한 요구사항
6. endpoint가 공개/지원 API인지, 벤더 전용 또는 내부 API인지 여부

합격 기준:

- 같은 VM disk에 대해 base 지점과 reference 지점 사이 changed region 목록을 얻을 수 있음
- 응답이 반복 호출에서 안정적임
- region offset과 length가 source disk size 범위 안에 있음
- final sync 직전 snapshot을 만들고 변경분만 반영하는 절차가 설계 가능함

불합격 기준:

- changed-region endpoint가 없음
- 인증 또는 권한 문제를 해결할 수 없음
- snapshot disk path를 안정적으로 식별할 수 없음
- 응답 형식이 VM/disk별 patch에 필요한 offset/length를 제공하지 않음
- API가 지원 범위 밖이라 운영 도구 기본 경로로 쓰기 어렵다고 판단됨

결과 처리:

- 합격하면 `legacy-cbt`를 별도 실험 모드로 문서화하고 구현 후보에 추가한다.
- 불합격하면 현재 테스트베드의 최소 보장 경로는 `cold-export`로 확정한다.
- 부분 합격이면 `legacy-cbt`를 hidden/experimental 옵션으로만 허용한다.

2026-05-14 현재 테스트베드 probe 결과:

- v4 VMM/Data Protection: unavailable
- legacy endpoint: `/api/nutanix/v3/data/changed_regions`
- probe status: HTTP `422`
- 판정: endpoint는 존재하지만 Protection Domain snapshot 기반 `snapshot_file_path` payload가 필요하다.
- 2026-05-14 추가 확인: 테스트 VM을 Protection Domain에 포함해 OOB snapshot 2개를 만들고 후보 path pair를 검증했다.
- 결과: live vDisk path와 `.snapshot/<snapshot_id>/<vm_handle>/.acropolis/vmdisk/<disk_id>` 후보 모두 HTTP `400`으로 거절되었다.
- 주요 응답: `kInvalidValue: Snapshot file pathname ... is not valid`, `reason: ENTITY_NOT_FOUND`.
- 2026-05-14 추가 확인: Prism Element API Explorer의 내부 v3 `vm_snapshots` API가 `status.snapshot_file_list[].snapshot_file_path`를 제공한다.
- v3 VM snapshot path 예: `/Storage-Container/.snapshot/<number>/<long-id>/.acropolis/vmdisk/<disk_uuid>`.
- 해당 v3 VM snapshot path를 current/reference pair로 넣은 `changed_regions` 호출은 HTTP `200`으로 성공했다.
- 판정: 현재 테스트베드의 증분 주 경로는 Protection Domain OOB snapshot이 아니라 내부 v3 VM snapshot + `/data/changed_regions` 조합으로 검증한다.
- 2026-05-14 추가 확인: `snapshot incr --source-api v3 --collect-changed-regions`가 changed-region 응답을 manifest의 `metadata.v3.changed_regions`에 저장하는 것을 확인했다.
- 저장된 changed-regions는 manifest disk id 기준으로 매핑되며, `sync incr`는 별도 `--changed-regions-file` 없이 이 값을 읽을 수 있다.
- 남은 과제: changed region에 해당하는 실제 바이트를 Nutanix snapshot에서 읽는 data plane을 구현해야 한다. 공개 backup 제품 문서들은 proxy VM에 snapshot disk copy를 hotplug한 뒤 읽는 방식을 사용한다.

### N2K-MIG-INCR-RBD-001: RBD 증분 이관

목적:

- ABLESTACK storage 주 경로인 RBD에서 증분 base/incr/final/cutover 흐름을 검증한다.

절차:

1. RBD pool, Ceph config, keyring, libvirt secret 준비 상태를 확인한다.
2. `rhel` VM에 대해 증분 capability를 먼저 판정한다.
3. disk별 RBD image target map을 생성한다.
4. base recovery point 기준으로 RBD image에 base sync를 수행한다.
5. source VM을 운영 상태로 유지하고 incremental recovery point를 만든다.
6. changed regions만 RBD image에 patch한다.
7. final cutover 시 source VM을 중단하고 final changed regions를 patch한다.
8. direct RBD libvirt XML을 생성하고 target VM을 define/start한다.

합격 기준:

- RBD image size가 source disk size와 일치
- base sync 이후 RBD image가 libvirt disk source로 사용 가능
- incr/final sync가 logical offset 기준으로 반영됨
- source VM 중단 구간이 기록됨
- target VM boot 결과가 기록됨

### N2K-MIG-INCR-QCOW2-001: qcow2 증분 이관

목적:

- file target의 qcow2 backend에서 증분 patch가 qcow2 metadata를 손상시키지 않는지 검증한다.

절차:

1. target directory free space를 확인한다.
2. base sync로 qcow2 파일을 생성한다.
3. `qemu-img info`로 format과 virtual size를 확인한다.
4. incremental/final patch는 host file offset 직접 쓰기가 아니라 qemu block layer 또는 NBD logical writer를 통해 수행한다.
5. patch 이후 `qemu-img check` 또는 동등 검사를 수행한다.
6. libvirt XML로 define/start를 수행한다.

합격 기준:

- qcow2 파일에 직접 `dd seek` 방식 patch를 사용하지 않음
- patch 이후 `qemu-img info`가 정상
- 가능하면 `qemu-img check`가 정상
- target VM define/start 결과가 기록됨

### N2K-MIG-INCR-BLOCK-001: block/LVM 증분 이관

목적:

- raw block device 또는 LVM LV를 target으로 사용할 때 증분 offset patch가 정상 동작하는지 검증한다.

절차:

1. 테스트용 VG와 LV 생성 가능 여부를 확인한다.
2. source disk size와 같은 크기의 LV를 준비한다.
3. base sync를 LV에 raw로 기록한다.
4. incremental/final changed regions를 offset 기준으로 patch한다.
5. zero region이 있으면 discard 또는 zero write 정책을 확인한다.
6. block disk XML로 define/start를 수행한다.

합격 기준:

- LV 크기가 source disk size 이상
- `--force` 없이 기존 LV overwrite를 시도하지 않음
- region patch 후 manifest metrics가 갱신됨
- target VM define/start 결과가 기록됨

### N2K-MIG-GEN-001: `test` smoke 이관

목적:

- 가장 먼저 전체 절차를 한 번 통과시켜 inventory, storage prepare, base sync, incremental/final sync, cutover XML 생성, define까지의 결함을 빠르게 찾는다.

특이사항:

- EFI VM으로 인식됨
- SCSI unit이 `1`로 확인되어 unit `0`만 가정하는 코드가 있는지 확인한다.

절차:

1. `test` VM의 증분 capability를 판정한다.
2. 가능하면 `v4-incremental` 또는 `legacy-cbt`로 base/incr/final sync를 수행한다.
3. 증분 capability가 blocked이면 결과를 blocked로 기록하고 cold fallback 시나리오로 이동한다.
4. XML disk target bus와 target path를 확인한다.
5. source VM이 꺼져 있거나 target network가 격리된 상태에서 define/start를 수행한다.

합격 기준:

- 선택한 storage backend의 target disk 생성 성공
- 증분 sync가 가능하면 base/incr/final phase 갱신 성공
- XML 생성 성공
- `virsh define` 성공
- guest boot 가능 또는 boot 실패 원인이 명확히 수집됨

### N2K-MIG-LNX-001: `rhel` Linux 이관

목적:

- RHEL 계열 guest가 KVM/libvirt target에서 부팅 가능한지 검증한다.

사전 점검:

- source guest에서 `/etc/fstab`이 UUID 또는 LABEL 기반인지 확인한다.
- initramfs에 virtio storage/network driver가 포함되어 있는지 확인한다.
- NetworkManager connection이 MAC 고정에 의존하는지 확인한다.

절차:

1. `rhel` VM을 운영 상태로 둔 채 base recovery point를 만든다.
2. 선택한 storage backend에 base sync를 수행한다.
3. incremental recovery point를 만들고 changed regions만 반영한다.
4. final cutover 직전에 source VM을 shutdown 또는 quiesce한다.
5. final recovery point와 final changed regions를 반영한다.
6. XML에서 firmware `efi`, memory `4096`, vCPU `1`, NIC MAC을 확인한다.
7. isolated network에서 target VM을 시작한다.
8. console 또는 SSH로 부팅 상태를 확인한다.
9. guest 내부에서 disk, filesystem, network, qemu guest agent 상태를 확인한다.

합격 기준:

- kernel panic 없이 OS 부팅
- root filesystem mount 성공
- NIC 인식
- IP 설정 방식이 확인됨
- reboot 후에도 부팅 가능

결함 후보:

- UEFI loader 누락
- virtio-scsi driver 누락
- MAC 기반 network profile 불일치
- SELinux relabel 필요

### N2K-MIG-WIN-001: `windows11` Windows desktop 이관

목적:

- Windows 11 VM의 boot 요구사항, virtio driver, firmware/TPM 차이를 검증한다.

사전 점검:

- source VM의 firmware가 UEFI인지 확인한다.
- BitLocker 사용 여부를 확인한다.
- virtio storage, virtio network driver 설치 여부를 확인한다.
- TPM 또는 Secure Boot 요구사항이 있는지 확인한다.

절차:

1. Windows 11을 운영 상태로 둔 채 base recovery point를 만든다.
2. 선택한 storage backend에 base sync를 수행한다.
3. incremental recovery point를 만들고 changed regions만 반영한다.
4. final cutover 직전에 Windows 11을 정상 shutdown한다.
5. final recovery point와 final changed regions를 반영한다.
6. XML에서 memory `4096`, vCPU `4`, NIC MAC을 확인한다.
7. firmware가 manifest에서 비어 있으면 Prism UI 기준 boot mode와 XML 차이를 기록한다.
8. 필요한 경우 테스트용 XML 사본에 UEFI loader, TPM, Secure Boot 관련 보정이 필요한지 확인한다.
9. isolated network에서 target VM start를 시도한다.
10. Windows boot manager, recovery screen, INACCESSIBLE_BOOT_DEVICE, driver 오류 여부를 기록한다.

합격 기준:

- `virsh define` 성공
- boot 성공 또는 실패 원인이 firmware/TPM/driver 중 하나로 분류됨
- boot 성공 시 장치 관리자에서 storage/network driver 상태 확인
- source와 target을 동시에 운영망에 연결하지 않음

결함 후보:

- Windows 11 firmware 정보가 inventory에서 누락됨
- libvirt XML에 UEFI loader가 없음
- vTPM 또는 Secure Boot 설정 미지원
- virtio storage driver 미설치로 boot device 접근 실패

### N2K-MIG-WS22-001: `winsvr2022` Windows Server 이관

목적:

- Windows Server 2022 VM의 16 GiB memory 정의, service boot, network profile을 검증한다.

사전 점검:

- source VM 역할을 확인한다.
- static IP, DNS, domain join 여부를 확인한다.
- virtio driver 설치 여부를 확인한다.
- application service 자동 시작 여부를 기록한다.

절차:

1. Windows Server 2022를 운영 상태로 둔 채 base recovery point를 만든다.
2. 선택한 storage backend에 base sync를 수행한다.
3. incremental recovery point를 만들고 changed regions만 반영한다.
4. final cutover 직전에 Windows Server 2022를 정상 shutdown한다.
5. final recovery point와 final changed regions를 반영한다.
6. XML에서 memory `16384`, vCPU `4`, NIC MAC을 확인한다.
7. 대상 호스트의 free memory가 충분한지 확인한다.
8. isolated network에서 target VM을 시작한다.
9. Windows event log, disk online 상태, network profile, 주요 service 상태를 확인한다.

합격 기준:

- `virsh define` 성공
- memory 부족 없이 start 가능
- Windows Server 로그인 가능
- disk online 상태 정상
- network adapter 인식
- 주요 service 상태가 source 기준과 비교 가능

결함 후보:

- target host memory 부족
- Windows Server virtio driver 누락
- static IP가 새 NIC profile에 묶이지 않음
- UEFI boot 정보 누락

### N2K-MIG-NET-001: network 매핑 검증

목적:

- Nutanix `default` network가 ABLESTACK에서 어떤 libvirt network 또는 bridge로 연결되어야 하는지 검증한다.

절차:

1. 각 VM manifest의 NIC MAC과 Nutanix network 이름을 확인한다.
2. ABLESTACK host의 `virsh net-list --all`과 bridge 구성을 확인한다.
3. 첫 부팅은 libvirt `default` 또는 별도 isolated network로 제한한다.
4. 운영망 cutover 전 source VM을 shutdown한다.
5. target XML의 network source를 실제 ABLESTACK bridge/network로 조정해야 하는지 판단한다.

합격 기준:

- duplicate MAC/IP 충돌 없이 boot 검증 가능
- 운영망 연결 시 gateway, DNS, east-west 통신 확인
- 필요한 network mapping 요구사항이 문서화됨

### N2K-MIG-RESUME-001: 중단 후 재개

목적:

- base sync 이후 명령이 중단되었을 때 manifest 기반으로 다음 단계를 판단할 수 있는지 확인한다.

절차:

1. `test` VM으로 init과 base sync를 완료한다.
2. cutover 전에 명령 세션을 종료한다.
3. 다음 명령을 실행한다.

```bash
ablestack_n2k \
  --workdir "${WORKDIR}" \
  --manifest "${MANIFEST}" \
  --resume \
  run --json
```

합격 기준:

- `next_step`이 `cutover`로 표시됨
- `next_command`가 `cutover --define-only`로 표시됨
- 이미 완료된 base sync를 재수행하지 않음

### N2K-MIG-ROLLBACK-001: rollback과 정리

목적:

- target VM 생성 또는 부팅 실패 시 원본 VM을 보존하고 target 리소스만 되돌릴 수 있는지 확인한다.

절차:

1. target VM이 define되어 있으면 `virsh destroy`와 `virsh undefine` 절차를 기록한다.
2. target disk 파일을 삭제하기 전 manifest와 events log를 보관한다.
3. `cleanup --keep-source-points --keep-workdir`로 cleanup plan을 확인한다.
4. source VM이 삭제되거나 변경되지 않았는지 Nutanix UI에서 확인한다.

합격 기준:

- source VM 보존
- target VM 제거 가능
- target disk 제거 여부를 운영자가 선택 가능
- 작업 증거가 보존됨

## VM별 합격 기준 요약

| VM | 최소 합격 | 추가 합격 |
| --- | --- | --- |
| `test` | init, base sync, XML 생성, define 성공 | isolated boot 성공 |
| `rhel` | define/start 성공 | SSH 또는 console login, network 확인, reboot 성공 |
| `windows11` | define 성공, boot 실패 원인 분류 | login, device driver 정상, reboot 성공 |
| `winsvr2022` | define/start 성공 | login, service 상태 확인, network 확인 |

## 증거 수집 항목

각 테스트 실행마다 다음 항목을 기록한다.

| 항목 | 예시 |
| --- | --- |
| Test ID | `N2K-MIG-LNX-001` |
| Date | `2026-05-14` |
| Branch/Commit | `feature/ablestack_n2k`, commit hash |
| Source VM | `rhel` |
| Target Host | `10.10.22.2` |
| Workdir | `/var/lib/ablestack-n2k/rhel/<run-id>` |
| Manifest | `${WORKDIR}/manifest.json` |
| Events | `${WORKDIR}/events.log` |
| Source disk export method | 수동 export, snapshot export 등 |
| Result | passed, failed, blocked |
| Failure class | api, export, transfer, xml, define, boot, network, cleanup |
| Notes | 재현 조건과 다음 조치 |

## 결함 판정 기준

테스트 중 다음 현상이 발견되면 코드 수정 대상 결함으로 분류한다.

- API inventory가 기준 VM을 찾지 못함
- manifest에 disk, NIC, CPU, memory가 잘못 기록됨
- source-map이 올바른데 base sync가 실패함
- target qcow2가 생성되었지만 manifest 상태가 갱신되지 않음
- events log가 valid JSON line 형식을 깨뜨림
- generated XML이 source VM 속성과 명백히 불일치함
- `virsh define`이 XML 구조 문제로 실패함
- `--resume`이 다음 단계를 잘못 안내함
- cleanup plan이 workdir 밖 리소스를 삭제 대상으로 제안함

다음 현상은 처음에는 환경 또는 절차 이슈로 분류하되, 반복되면 기능 요구사항으로 승격한다.

- Nutanix disk export 경로 확보 실패
- Windows virtio driver 미설치
- Windows 11 vTPM/Secure Boot 필요
- 운영망 bridge 매핑 정보 부재
- target host memory 부족

## 테스트 완료 기준

이번 테스트 라운드의 완료 기준은 다음과 같다.

- 4개 VM 모두 `init --inventory-source api` 성공
- 최소 `test` VM은 base sync와 libvirt define 성공
- `rhel` VM은 target boot 결과까지 확인
- `windows11`, `winsvr2022`는 define 성공과 boot 실패 원인 분류 또는 boot 성공 확인
- 발견 결함은 재현 명령, manifest, events log, libvirt log 위치를 포함해 기록
- 원본 Nutanix VM은 삭제하지 않고 보존

## 2026-05-14 live probe 업데이트

Protection Domain 기반 legacy CBT 후보 경로를 실제 테스트베드에서 확인했다.

- Prism Element v2 API Explorer 경로: `/api/nutanix/v2/api_explorer/`
- v2 API schema 원본: `/PrismGateway/services/rest/api/api-docs/v2.0`
- Protection Domain schema: `/PrismGateway/services/rest/api/api-docs/v2.0/protection_domains`
- snapshot schema: `/PrismGateway/services/rest/api/api-docs/v2.0/snapshots`
- PD 생성 API: `POST /PrismGateway/services/rest/v2.0/protection_domains/`
- VM 보호 등록 API: `POST /PrismGateway/services/rest/v2.0/protection_domains/{name}/protect_vms`
- OOB snapshot API: `POST /PrismGateway/services/rest/v2.0/protection_domains/{name}/oob_schedules`
- PD snapshot 조회 API: `GET /PrismGateway/services/rest/v2.0/protection_domains/{name}/dr_snapshots/?full_details=true`

검증 결과:

- 임시 PD 생성, `test` VM 보호 등록, OOB snapshot 2회 생성, PD snapshot 조회, snapshot 삭제, PD 삭제는 성공했다.
- 현재 테스트베드의 PD snapshot full details는 `snapshot_id`, `snapshot_uuid`, `vm_handle`, `vm_id`, `consistency_group`, `vm_files`를 제공한다.
- `vm_files`는 `/Storage-Container/.acropolis/vmdisk/<uuid>` 형태의 live path이며, changed-region API가 요구하는 검증된 `.snapshot/...` file path는 직접 제공하지 않는다.
- `/Container/.snapshot/<snapshot_id>/<vm_handle>/.acropolis/vmdisk/<uuid>` 형태의 후보 경로는 HTTP `400`으로 거절됐다.
- 따라서 다음 실제 테스트 단계는 Nutanix CVM/Prism 내부에서 snapshot file path를 확정하거나, legacy changed-region API 대신 다른 export/read 경로를 선택하는 것이다.

추가로 관측된 VM:

| VM | UUID | 특성 |
| --- | --- | --- |
| `centos7-bios-ide` | `284b7ac1-bdff-42b9-b546-5a672226b62b` | BIOS/IDE 계열 테스트 후보 |

## 2026-05-14 data plane 업데이트

Prism v3 disk data API를 실제 테스트베드에서 확인했다.

- API: `GET /api/nutanix/v3/vms/{vm_uuid}/vm_disk/{vm_disk_uuid}/data?offset=<n>&length=<n>`
- 대상 확인: `test` VM의 data disk `635259fe-07bd-48f8-9946-81a409436b30`
- 512 bytes read 결과: HTTP `200`, 응답 body는 raw bytes가 아니라 base64 문자열
- 구현 반영: `sync incr|final` source-map에서 `nutanix-v3-data://<vm_uuid>/<vm_disk_uuid>` URI 사용 가능
- read 제한: API schema와 live probe 기준 `length` 최대 `16777216` bytes, `offset > 16777216` 요청은 HTTP `422`

테스트 source-map 예시:

```json
{
  "635259fe-07bd-48f8-9946-81a409436b30": "nutanix-v3-data://db101f83-cf86-445b-aa10-16e4ce926560/635259fe-07bd-48f8-9946-81a409436b30"
}
```

주의:

- 이 API는 VM에 attach된 disk data read 경로다.
- v3 VM snapshot의 `snapshot_file_path`에서 직접 bytes를 읽는 API는 아직 확인되지 않았다.
- offset 제한 때문에 이 API만으로는 전체 VM disk를 migration source로 읽을 수 없다.
- snapshot-consistent incremental sync를 완성하려면 v3 VM snapshot clone, proxy VM hotplug, CVM/NFS export 등 제한 없는 block-level read source를 확보해야 한다.
- 현재 구현은 data plane plumbing 검증 단계이며, 운영 cutover 전에는 source VM 중단 또는 quiesce 상태에서 final sync를 수행해야 한다.

## 2026-05-14 NFS snapshot data plane 업데이트

Nutanix NFS export를 통해 snapshot file을 직접 읽는 경로를 확인했다.

- `10.10.131.10:/Storage-Container`와 `10.10.131.11:/Storage-Container` NFSv3 export 확인
- live vDisk path: `/Storage-Container/.acropolis/vmdisk/8875da58-2410-4c91-8f59-4f0152513b55`
- v3 snapshot file path 예시: `/Storage-Container/.snapshot/21/8923884864966230203-1778550560544334-921/.acropolis/vmdisk/8875da58-2410-4c91-8f59-4f0152513b55`
- NFS snapshot file은 `qemu-img info`에서 raw 100GiB disk로 인식됨
- `offset=20971520`, `length=512` 구간 read와 local target patch byte compare 통과

source-map URI 예시:

```json
{
  "635259fe-07bd-48f8-9946-81a409436b30": "nutanix-nfs://10.10.131.10/Storage-Container/.snapshot/21/8923884864966230203-1778550560544334-921/.acropolis/vmdisk/8875da58-2410-4c91-8f59-4f0152513b55"
}
```

자동 source-map 생성:

```bash
ablestack_n2k --workdir "${WORKDIR}" --manifest "${MANIFEST}" sync base \
  --source-map-from-v3-nfs \
  --nfs-host 10.10.131.10

ablestack_n2k --workdir "${WORKDIR}" --manifest "${MANIFEST}" sync incr \
  --source-map-from-v3-nfs \
  --nfs-host 10.10.131.10
```

주의:

- WSL 또는 실행 호스트에 NFS client가 필요하다.
- source-map 자동 생성은 v3 snapshot `path_index` 또는 collected changed-region `disk_mappings`가 manifest에 있어야 한다.
- 접근 권한이 없는 container는 skip된다. 현재 테스트베드에서는 migration data disk가 있는 `/Storage-Container`가 핵심 경로다.

## 2026-05-14 test VM E2E 검증 결과

`test` VM에서 v3 snapshot과 NFS data plane을 사용한 base, incr, final sync 흐름을 실행했다.

실행 요약:

- VM: `test`
- Source disk: `635259fe-07bd-48f8-9946-81a409436b30`
- Target: local raw file
- Source data plane: `10.10.131.10:/Storage-Container` NFS snapshot file
- Base snapshot: `2f215f8e-747e-4a63-a439-812f01b43061`
- Incr snapshot: `d8ed4cb8-b667-4d76-ba32-46b22bb1fb89`
- Final snapshot: `a34def08-9a5f-47bc-adbe-d307e25cf51e`
- Base sync elapsed: `9:17.05`
- Target apparent size: `107374182400`
- Target disk usage after sparse copy: `0`

검증 결과:

- `base_sync`, `incr_sync`, `final_sync` phase 모두 완료
- source VM에 변경이 없어서 incr/final changed-region은 `region_count=0`, `bytes_total=0`
- final snapshot file과 target raw를 `offset=0`, `offset=20971520`, `offset=107374181888`에서 512 bytes 비교했고 모두 일치
- 테스트 후 NFS mount와 `n2k-*` v3 VM snapshot 잔여 없음
- 증거 파일: `/tmp/n2k-e2e-evidence/manifest-20260514-215552.json`, `/tmp/n2k-e2e-evidence/e2e-20260514-215552.log`

## 2026-05-14 rhel VM E2E 검증 결과

`rhel` VM에서 같은 v3 snapshot과 NFS data plane 기반 흐름을 실행했다. `rhel`은 실행 중인 Linux guest라서 실제 증분 변경 영역이 관측됐다.

실행 요약:

- VM: `rhel`
- Firmware: `efi`
- Source disk: `c8bf3b1c-a7a0-4762-8c77-b623e65e1776`
- NFS vDisk UUID: `3067bd12-6040-4a1d-b014-f4ab03090b1f`
- Target: local raw file
- Source data plane: `10.10.131.10:/Storage-Container` NFS snapshot file
- Base snapshot: `ee4e3249-ff73-4054-a696-612e37be83d9`
- Incr snapshot: `7b015f2e-3772-4340-9ff8-ca7f1ed08367`
- Final snapshot: `657bc392-5eb6-4f8b-90d0-b0a996403d8d`
- Base sync elapsed: `8:09.94`
- Target apparent size: `107374182400`
- Target disk usage after sparse copy: `2.8G`

검증 결과:

- `base_sync`, `incr_sync`, `final_sync` phase 모두 완료
- incr changed-region: `32` regions, `356352` bytes
- final changed-region: `1` region, `16384` bytes
- final snapshot file과 target raw를 `offset=0`, `offset=20971520`, `offset=107374181888`에서 512 bytes 비교했고 모두 일치
- 테스트 후 NFS mount와 `n2k-*` v3 VM snapshot 잔여 없음
- 증거 파일: `/tmp/n2k-e2e-evidence/manifest-rhel-20260514-221426.json`, `/tmp/n2k-e2e-evidence/e2e-rhel-20260514-221426.log`
