# ablestack_n2k 사용자 가이드

## 문서 목적

이 문서는 Nutanix AHV 환경의 가상머신을 ABLESTACK 환경으로 이관해야 하는 일반 사용자를 위한 `ablestack_n2k` 사용 설명서이다.

가장 쉬운 사용 방법인 `wizard` 모드를 먼저 설명하고, 이후 자동 실행 명령과 단계별 명령을 순서대로 설명한다. 이 문서는 PDF 변환이 쉽도록 표준 Markdown 형식으로 작성되었다.

## 대상 독자

- Nutanix Prism에서 운영 중인 VM을 ABLESTACK으로 이관하려는 운영자
- `ablestack_n2k` RPM이 설치된 ABLESTACK 호스트에서 마이그레이션을 실행하는 사용자
- Cloud API 또는 libvirt 대상 중 하나를 선택해 VM을 생성해야 하는 사용자

## 기본 개념

`ablestack_n2k`는 Nutanix VM의 디스크를 ABLESTACK 쪽 스토리지로 복제한 뒤, 마지막 단계에서 대상 VM을 생성하고 시작한다.

권장 흐름은 최소 중단 이관이다.

1. `phase1`: 원본 VM을 켜 둔 상태에서 기본 디스크 복제와 1차 증분 동기화를 수행한다.
2. `phase2`: 나중에 같은 작업 디렉터리로 다시 실행한다. 원본 VM을 종료하거나 전원 차단한 뒤 최종 동기화를 수행하고 대상 VM을 생성한다.

단순 검증이나 작은 VM 테스트에는 `full` 흐름을 사용할 수 있다. `full`은 한 번의 명령에서 base sync, final sync, cutover를 이어서 실행한다.

## 실행 전 준비

### 필수 준비물

| 항목 | 설명 |
| --- | --- |
| Nutanix Prism 주소 | 예: `https://pc.example.local:9440` |
| Nutanix 계정 | VM 조회, snapshot 생성, 전원 제어 권한 필요 |
| ABLESTACK 대상 | Cloud API 또는 libvirt가 준비된 호스트 |
| 대상 스토리지 | RBD, Cloud FileSystem/qcow2, libvirt qcow2, block 중 선택 |
| 대상 네트워크 | Cloud network ID 또는 libvirt bridge/NAT network |
| `ablestack_n2k` RPM | 실행 호스트에 설치되어 있어야 함 |

### AHV/Nutanix 측 사전 점검

이관을 시작하기 전에 Nutanix AHV 환경에서 다음 항목을 확인한다.

| 점검 항목 | 확인 내용 |
| --- | --- |
| Prism 접속 | Prism Central 또는 Prism Element URL에 `ablestack_n2k` 실행 호스트에서 접속 가능해야 한다. 기본 API 포트는 TCP `9440`이다. |
| 계정 권한 | VM 조회, VM snapshot 생성/조회/삭제, VM 전원 제어 권한이 필요하다. 테스트 환경에서는 관리자 권한 계정 사용을 권장한다. |
| 원본 VM 상태 | VM 이름, 전원 상태, OS 종류, 디스크 수, NIC 수, firmware BIOS/UEFI 정보를 확인한다. |
| 디스크 구성 | root disk와 data disk 순서, LVM/동적 디스크/멀티 디스크 구성을 확인한다. |
| 네트워크 구성 | 원본 VM의 NIC, MAC, VLAN/subnet 정보를 확인하고 대상 Cloud network 또는 libvirt bridge에 매핑할 계획을 세운다. |
| snapshot 가능 여부 | 원본 VM에 snapshot 생성이 가능한지, snapshot 보관 시간 동안 스토리지 여유가 충분한지 확인한다. |
| 최종 중단 방식 | `phase2` cutover 시 `guest`, `poweroff`, `manual`, `none` 중 어떤 방식으로 원본 VM 변경을 멈출지 결정한다. 권장값은 `guest`이다. |
| 특수 장치 | GPU, PCI passthrough, vTPM, affinity policy, 특수 부팅 설정이 있으면 대상 환경에서 동일하게 지원되는지 사전에 확인한다. |
| NFS 데이터 경로 | 현재 검증된 데이터 경로는 v3 snapshot/NFS이다. `ablestack_n2k` 실행 호스트가 Nutanix CVM 또는 cluster NFS export를 읽을 수 있어야 한다. |

### AHV/Nutanix 측 방화벽 포트

다음 포트는 `ablestack_n2k` 실행 호스트에서 Nutanix Prism/CVM/cluster 방향으로 열려 있어야 한다. 상태 기반 방화벽에서는 established return traffic도 허용되어야 한다.

| 출발지 | 목적지 | 프로토콜/포트 | 용도 | 필수 여부 |
| --- | --- | --- | --- | --- |
| n2k 실행 호스트 | Prism Central 또는 Prism Element | TCP `9440` | Prism REST API, VM inventory, snapshot, power operation | 필수 |
| n2k 실행 호스트 | Nutanix CVM 또는 cluster NFS export IP | TCP `2049` | NFS vDisk/snapshot 파일 읽기 | 필수 |
| n2k 실행 호스트 | Nutanix CVM 또는 cluster NFS export IP | TCP/UDP `111` | NFSv3 portmapper/mount 협상. 환경에 따라 필요 | 조건부 |
| n2k 실행 호스트 | Nutanix CVM 또는 cluster NFS export IP | TCP/UDP `20048-20050`, `7508` | Nutanix NFS/data-service 보조 포트. 엄격한 방화벽에서 확인 필요 | 조건부 |
| n2k 실행 호스트 | Prism Central 또는 Prism Element | TCP `80` | HTTP에서 HTTPS로 redirect되는 환경 확인용 | 선택 |

`ablestack_n2k`는 기본 NFS mount 옵션으로 `ro,vers=3,nolock,proto=tcp`를 사용한다. 따라서 최소 동작에는 TCP `2049`가 핵심이지만, NFSv3 mount 협상이나 환경별 NFS service 구성 때문에 `111`, `20048-20050`, `7508`이 막혀 있으면 mount 또는 읽기 단계에서 실패할 수 있다.

대상 ABLESTACK 쪽 포트도 별도로 확인해야 한다.

| 대상 방식 | 확인할 포트 |
| --- | --- |
| ABLESTACK Cloud API | Cloud API endpoint 포트. 예: TCP `8080` 또는 `443` |
| libvirt 직접 대상 | 운영 방식에 따라 SSH, libvirt 관리 포트, 호스트 방화벽 정책 확인 |
| Cloud FileSystem/qcow2 | Cloud storage pool path가 대상 호스트에서 실제로 mount되어 있고 n2k가 해당 path에 쓸 수 있어야 함 |

참고한 공식 Nutanix 문서:

- [AHV Administration Guide](https://www.nutanix.com/content/dam/nutanix/documents/certifications/ahv-admin.pdf): Nutanix NFS/data service 관련 포트
- [Nutanix CAPX Port Requirements](https://opendocs.nutanix.com/capx/v1.3.x/port_requirements/): Prism Central TCP `9440` 통신 예시

### 권장 대상 프로파일

| 프로파일 | 대상 생성 방식 | 스토리지 | 설명 |
| --- | --- | --- | --- |
| `cloud-rbd` | ABLESTACK Cloud API | RBD raw | 기본 권장 방식 |
| `cloud-filesystem` | ABLESTACK Cloud API | qcow2 file | Cloud의 FileSystem 또는 Shared Mount Point 스토리지 사용 |
| `cloud-qcow2` | ABLESTACK Cloud API | qcow2 file | `cloud-filesystem` 별칭 |
| `libvirt-rbd` | libvirt XML | RBD raw | Cloud API를 사용하지 않는 기존 방식 |
| `libvirt-qcow2` | libvirt XML | qcow2 file | 호스트 파일 경로에 qcow2 생성 |

Cloud 대상에서는 현재 block/LVM 방식은 사용하지 않는다. block/LVM은 libvirt 대상에서만 절차적으로 사용할 수 있다.

### 비밀번호와 키 관리

명령줄에 비밀번호와 Secret Key를 직접 입력하면 shell history에 남을 수 있다. 가능하면 wizard의 숨김 입력 또는 별도 credential 파일을 사용한다.

Nutanix credential 파일 예:

```bash
cat >/root/nutanix.env <<'EOF'
NUTANIX_USERNAME='admin'
NUTANIX_PASSWORD='여기에_비밀번호_입력'
EOF
chmod 600 /root/nutanix.env
```

ABLESTACK Cloud credential 파일 예:

```bash
cat >/root/ablestack-cloud.env <<'EOF'
ABLESTACK_CLOUD_ENDPOINT='http://cloud.example.local:8080/client/api'
ABLESTACK_CLOUD_API_KEY='여기에_API_KEY_입력'
ABLESTACK_CLOUD_SECRET_KEY='여기에_SECRET_KEY_입력'
EOF
chmod 600 /root/ablestack-cloud.env
```

## Wizard 모드로 이관하기

`wizard` 모드는 사용자가 꼭 선택해야 하는 값만 물어보고, 나머지는 자동으로 채운 뒤 일반 `run` 명령을 만들어 실행한다.

동일한 기능을 하는 명령 이름은 세 가지이다.

```bash
ablestack_n2k wizard
ablestack_n2k migrate
ablestack_n2k interactive
```

### Wizard 기본 실행

가장 단순한 시작 명령은 다음과 같다.

```bash
ablestack_n2k wizard
```

실행하면 대략 다음 순서로 입력을 받는다.

1. 마이그레이션 방식 선택: `phase1`, `phase2`, `full`
2. 작업 디렉터리 선택 또는 기본값 확인
3. Prism 주소 입력
4. Nutanix 사용자 이름과 비밀번호 입력
5. 원본 VM 선택
6. 대상 프로파일 선택
7. 대상 VM 이름 입력 또는 기본값 사용
8. Cloud API 또는 libvirt 대상 정보 선택
9. 요약 확인
10. `yes` 입력 후 실행

목록이 여러 개일 때는 번호로 선택할 수 있다. 번호 대신 ID 또는 정확한 이름을 입력해도 된다.

### 권장 흐름: Cloud RBD phase1

Cloud RBD로 최소 중단 이관을 시작하는 예시는 다음과 같다.

```bash
ablestack_n2k wizard \
  --target-profile cloud-rbd \
  --split phase1 \
  --cred-file /root/nutanix.env \
  --cloud-cred-file /root/ablestack-cloud.env
```

`phase1`이 완료되면 프로그램은 종료된다. 출력 또는 요약에 표시된 작업 디렉터리를 기록해 둔다.

작업 디렉터리 예:

```text
/var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a
```

### 권장 흐름: Cloud RBD phase2

`phase2`는 반드시 `phase1`에서 생성된 작업 디렉터리를 사용한다.

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a \
  wizard \
  --split phase2 \
  --cred-file /root/nutanix.env \
  --cloud-cred-file /root/ablestack-cloud.env
```

`phase2`에서는 최종 동기화 전 원본 VM 셧다운이 필요하다. 기본값은 `guest`이며, 가능하면 guest shutdown을 시도하고 실패하거나 timeout이 발생하면 poweroff로 보완한다.

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a \
  wizard \
  --split phase2 \
  --shutdown guest \
  --cred-file /root/nutanix.env \
  --cloud-cred-file /root/ablestack-cloud.env
```

### 대상 VM 이름 지정

Wizard는 Cloud 대상 VM 이름의 기본값을 자동으로 만든다.

```text
n2k-<원본VM이름>-<날짜시간>
```

새로운 Cloud 대상 이관에서는 이 이름을 직접 바꿀 수 있다. 예:

```text
Cloud target VM name [n2k-rhel-20260519213000]: migrated-rhel-prod
```

`phase2` 재개 시에는 `phase1` manifest에 저장된 이름을 그대로 사용한다. `phase2` 중간에 대상 VM 이름을 바꾸지 않는다.

### Cloud FileSystem/qcow2로 실행

Cloud FileSystem 또는 Shared Mount Point 스토리지에 qcow2로 이관하려면 다음 프로파일을 사용한다.

```bash
ablestack_n2k wizard \
  --target-profile cloud-filesystem \
  --split phase1 \
  --cred-file /root/nutanix.env \
  --cloud-cred-file /root/ablestack-cloud.env
```

이 방식에서는 사용자가 `/var/lib/libvirt/images` 같은 경로를 직접 지정하지 않는다. Wizard가 Cloud API로 선택한 스토리지 풀의 실제 마운트 경로를 조회하고, 그 경로 바로 아래에 qcow2 파일을 생성한다.

예:

```text
/mnt/glue-gfs/migrated-rhel-prod-disk0.qcow2
/mnt/glue-gfs/migrated-rhel-prod-disk1.qcow2
```

Cloud FileSystem 대상에서 `--dst`를 직접 지정하면 선택한 Cloud 스토리지 경로와 일치해야 한다.

### libvirt qcow2로 실행

Cloud API를 사용하지 않고 로컬 libvirt에 VM을 정의하려면 `libvirt-qcow2`를 선택한다.

```bash
ablestack_n2k wizard \
  --target-profile libvirt-qcow2 \
  --split phase1 \
  --file-root /var/lib/libvirt/images \
  --network-mode bridge \
  --bridge bridge0 \
  --cred-file /root/nutanix.env
```

libvirt NAT network를 사용해야 하면 다음처럼 지정한다.

```bash
ablestack_n2k wizard \
  --target-profile libvirt-qcow2 \
  --network-mode network \
  --network default \
  --cred-file /root/nutanix.env
```

### libvirt RBD로 실행

libvirt RBD 방식은 VM XML에서 RBD를 직접 참조하거나, krbd로 매핑한 block device를 참조할 수 있다.

```bash
ablestack_n2k wizard \
  --target-profile libvirt-rbd \
  --rbd-pool rbd \
  --rbd-access-mode librbd \
  --cred-file /root/nutanix.env
```

krbd 방식:

```bash
ablestack_n2k wizard \
  --target-profile libvirt-rbd \
  --rbd-pool rbd \
  --rbd-access-mode krbd \
  --cred-file /root/nutanix.env
```

### 실행 전 명령만 확인하기

실제 이관을 시작하지 않고 Wizard가 생성할 명령만 확인하려면 `--print-command`를 사용한다. Secret 값은 출력에서 마스킹된다.

```bash
ablestack_n2k wizard \
  --target-profile cloud-rbd \
  --split phase1 \
  --cred-file /root/nutanix.env \
  --cloud-cred-file /root/ablestack-cloud.env \
  --print-command
```

### 기본값으로 자동 실행하기

자동화 스크립트에서 사용할 때는 `--yes`를 사용할 수 있다. 단, 선택지가 여러 개인 값은 미리 옵션으로 지정해야 한다.

```bash
ablestack_n2k wizard \
  --yes \
  --pc https://pc.example.local:9440 \
  --vm rhel \
  --target-profile cloud-rbd \
  --split phase1 \
  --cloud-zone-id <ZONE_ID> \
  --cloud-service-offering-id <SERVICE_OFFERING_ID> \
  --cloud-network-id <NETWORK_ID> \
  --cloud-storage-id <STORAGE_ID> \
  --cred-file /root/nutanix.env \
  --cloud-cred-file /root/ablestack-cloud.env
```

## 상태 확인

작업 상태는 `status` 명령으로 확인한다.

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a \
  status
```

다음 단계만 보고 싶으면 `--resume-plan`을 사용한다.

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a \
  status --resume-plan
```

## 절차형 명령으로 사용하기

Wizard가 내부적으로 만드는 실행 흐름은 `run` 명령이다. 고급 사용자는 `run`을 직접 사용할 수 있다.

### 사전 점검

Nutanix API와 대상 환경 조건을 확인한다.

```bash
ablestack_n2k preflight \
  --pc https://pc.example.local:9440 \
  --cred-file /root/nutanix.env \
  --target-provider ablestack-cloud \
  --target-storage rbd \
  --target-format raw \
  --cloud-cred-file /root/ablestack-cloud.env
```

v3 경로를 명시적으로 강제하려면 다음 옵션을 사용한다.

```bash
--source-api v3
```

또는:

```bash
--force-v3
```

### 이관 계획 확인

특정 VM에 대한 계획을 확인한다.

```bash
ablestack_n2k plan \
  --vm rhel \
  --pc https://pc.example.local:9440 \
  --cred-file /root/nutanix.env \
  --target-provider ablestack-cloud \
  --target-storage rbd \
  --target-format raw \
  --cloud-cred-file /root/ablestack-cloud.env
```

### phase1 직접 실행

Cloud RBD 대상의 phase1 예:

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a \
  run \
  --vm rhel \
  --pc https://pc.example.local:9440 \
  --cred-file /root/nutanix.env \
  --inventory-source api \
  --source-api v3 \
  --force-v3 \
  --split phase1 \
  --target-provider ablestack-cloud \
  --target-storage rbd \
  --target-format raw \
  --dst rbd:rbd/migrated-rhel-prod \
  --cloud-cred-file /root/ablestack-cloud.env \
  --cloud-zone-id <ZONE_ID> \
  --cloud-service-offering-id <SERVICE_OFFERING_ID> \
  --cloud-network-id <NETWORK_ID> \
  --cloud-storage-id <STORAGE_ID> \
  --cloud-name migrated-rhel-prod \
  --apply \
  --start
```

### phase2 직접 실행

`phase2`는 같은 작업 디렉터리로 실행한다.

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a \
  run \
  --split phase2 \
  --shutdown guest \
  --cred-file /root/nutanix.env \
  --cloud-cred-file /root/ablestack-cloud.env \
  --apply \
  --start
```

### full 직접 실행

한 번에 전체 흐름을 실행하려면 `--split full`을 사용한다.

```bash
ablestack_n2k run \
  --vm rhel \
  --pc https://pc.example.local:9440 \
  --cred-file /root/nutanix.env \
  --source-api v3 \
  --force-v3 \
  --split full \
  --target-provider ablestack-cloud \
  --target-storage rbd \
  --target-format raw \
  --dst rbd:rbd/migrated-rhel-prod-full \
  --cloud-cred-file /root/ablestack-cloud.env \
  --cloud-zone-id <ZONE_ID> \
  --cloud-service-offering-id <SERVICE_OFFERING_ID> \
  --cloud-network-id <NETWORK_ID> \
  --cloud-storage-id <STORAGE_ID> \
  --cloud-name migrated-rhel-prod-full \
  --apply \
  --start
```

## 수동 단계 명령

대부분의 사용자는 `wizard` 또는 `run`만 사용하면 된다. 문제 분석이나 특수 검증이 필요할 때는 다음 단계 명령을 직접 사용할 수 있다.

### init

작업 디렉터리와 manifest를 만든다.

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/manual-run \
  init \
  --vm rhel \
  --pc https://pc.example.local:9440 \
  --cred-file /root/nutanix.env \
  --inventory-source api \
  --mode v3-incremental \
  --target-provider libvirt \
  --target-storage file \
  --target-format qcow2 \
  --dst /var/lib/libvirt/images/migrated-rhel
```

### snapshot

Nutanix 쪽 snapshot을 생성하거나 기록한다.

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/manual-run \
  snapshot base \
  --source-api v3 \
  --create-vm-snapshot \
  --pc https://pc.example.local:9440 \
  --vm rhel \
  --cred-file /root/nutanix.env
```

### sync

디스크 데이터를 복제한다.

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/manual-run \
  sync base \
  --source-map-from-v3-nfs
```

증분 동기화:

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/manual-run \
  sync incr \
  --source-map-from-v3-nfs
```

최종 동기화:

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/manual-run \
  sync final \
  --source-map-from-v3-nfs
```

### cutover

대상 VM을 생성하거나 시작한다.

libvirt 대상:

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/manual-run \
  cutover \
  --network-mode bridge \
  --bridge bridge0 \
  --apply \
  --start
```

ABLESTACK Cloud 대상:

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/manual-run \
  cutover \
  --target-provider ablestack-cloud \
  --cloud-cred-file /root/ablestack-cloud.env \
  --apply \
  --start
```

## 대상 스토리지 선택

### Cloud RBD

가장 권장되는 방식이다.

- 대상 스토리지: RBD
- 대상 포맷: raw
- Cloud API가 importVolume과 VM 생성 과정을 수행한다.
- `--dst` 예: `rbd:rbd/migrated-rhel-prod`

### Cloud FileSystem/qcow2

Cloud의 FileSystem, NetworkFilesystem, Shared Mount Point primary storage를 사용하는 방식이다.

- 대상 스토리지: file
- 대상 포맷: qcow2
- `ablestack_n2k`가 Cloud API로 선택한 storage pool path를 조회한다.
- qcow2 파일은 해당 path 바로 아래에 생성되어야 한다.

잘못된 예:

```text
/var/lib/libvirt/images/migrated-rhel-disk0.qcow2
```

올바른 예:

```text
<Cloud storage pool path>/migrated-rhel-disk0.qcow2
```

### Cloud 디스크 오퍼링과 캐시 정책

Cloud 대상에서는 `importVolume`으로 가져오는 디스크에 디스크 오퍼링이 연결된다. 사용자가 별도 오퍼링을 지정하지 않으면 `ablestack_n2k`가 n2k 전용 writeback 오퍼링을 자동으로 찾거나 생성해서 사용한다.

| 대상 스토리지 | 자동 오퍼링 이름 | 주요 속성 |
| --- | --- | --- |
| RBD, Shared Mount Point, NetworkFilesystem 등 공유 스토리지 | `N2K Migration Writeback` | customized, `storagetype=shared`, `cachemode=writeback` |
| host-local FileSystem 스토리지 | `N2K Migration Writeback Local` | customized, `storagetype=local`, `cachemode=writeback` |

이 오퍼링은 Cloud UI/API에서 명시적으로 확인할 수 있다. 같은 이름의 오퍼링이 이미 있지만 `writeback`이 아니거나 tag가 있거나 customized가 아니면 n2k는 자동 수정하지 않고 중단한다. 이 경우 오퍼링을 수정하거나 삭제한 뒤 다시 실행한다.

특정 오퍼링을 강제로 사용해야 하는 경우에만 다음 옵션을 사용한다.

```bash
--cloud-disk-offering-id <DISK_OFFERING_ID>
```

### libvirt qcow2

Cloud API 없이 호스트의 libvirt에 VM을 직접 정의하는 방식이다.

- 기본 bridge: `bridge0`
- 기본 파일 루트: `/var/lib/libvirt/images`
- 사용자가 `--file-root` 또는 `--dst`로 경로를 지정할 수 있다.

### libvirt RBD

RBD 이미지를 libvirt 대상 VM에 연결한다.

| 모드 | 설명 |
| --- | --- |
| `librbd` | libvirt가 RBD 이미지를 직접 참조 |
| `krbd` | RBD 이미지를 `/dev/rbd/<pool>/<image>` 형식으로 map한 뒤 block device로 사용 |

### block/LVM

block/LVM은 대상 디스크를 명시적으로 지정해야 한다. 실수로 운영 디스크를 덮어쓸 수 있으므로 반드시 빈 디스크인지 확인한 뒤 사용한다.

예시 형식:

```bash
--target-storage block \
--target-format raw \
--target-map-json '{"disk0":{"path":"/dev/mapper/vg_n2k_rhel/root"}}'
```

## 네트워크 선택

Cloud 대상은 `--cloud-network-id` 또는 `--cloud-network-ids`로 Cloud 네트워크를 선택한다. Wizard에서는 Cloud API에서 조회한 네트워크 목록을 보여주고 번호로 선택할 수 있다.

libvirt 대상은 두 가지 방식 중 하나를 선택한다.

| 방식 | 옵션 | 설명 |
| --- | --- | --- |
| bridge | `--network-mode bridge --bridge bridge0` | 호스트 bridge에 직접 연결 |
| NAT network | `--network-mode network --network default` | libvirt NAT network 사용 |

운영 환경에서는 bridge 방식이 일반적이며 기본 bridge 이름은 `bridge0`이다.

## 셧다운 정책

`phase2` 또는 `full`의 최종 단계에서는 원본 VM의 변경을 멈춘 뒤 final sync를 수행해야 한다.

| 정책 | 설명 |
| --- | --- |
| `guest` | guest shutdown 시도 후 필요하면 poweroff로 보완 |
| `poweroff` | Nutanix 전원 차단 방식으로 종료 |
| `manual` | 사용자가 직접 VM을 끄고 진행 |
| `none` | 셧다운하지 않음. 일반 이관에는 권장하지 않음 |

권장값은 `guest`이다.

```bash
--shutdown guest
```

## cleanup

성공한 cutover 이후에는 기본적으로 Nutanix 쪽 임시 snapshot이 정리된다. 별도로 정리 계획을 확인하려면 다음 명령을 사용한다.

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a \
  cleanup
```

실제 정리를 적용하려면:

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a \
  cleanup --apply
```

source snapshot을 강제로 제거하려면 전역 `--force`가 필요하다.

```bash
ablestack_n2k \
  --force \
  --workdir /var/lib/ablestack-n2k/rhel/20260519-173256-08dcf48a \
  cleanup --remove-source-points --apply
```

## Bash completion

패키지가 정상 설치되면 bash completion 파일은 다음 위치에 설치된다.

```text
/usr/share/bash-completion/completions/ablestack_n2k
```

현재 shell에서 바로 적용하려면 다음을 실행한다.

```bash
source /usr/share/bash-completion/completions/ablestack_n2k
```

이후 `ablestack_n2k <Tab>` 또는 `ablestack_n2k wizard --<Tab>`으로 명령과 옵션을 확인할 수 있다.

## 문제 해결

### Wizard가 TTY 오류를 출력하는 경우

대화형 입력이 필요한데 현재 입력이 TTY가 아니면 실패한다.

예:

```text
ERROR: migration split selection requires a TTY
```

해결 방법:

- 터미널에서 직접 실행한다.
- 자동화 환경에서는 `--yes`와 필요한 옵션을 모두 제공한다.
- `phase2`에서는 `--workdir` 또는 `--manifest`를 지정한다.

### Cloud importVolume이 volume을 찾지 못하는 경우

Cloud FileSystem/qcow2 대상에서 자주 발생한다. 선택한 Cloud storage pool의 실제 path와 n2k가 생성한 qcow2 파일 위치가 일치해야 한다.

확인할 항목:

1. Wizard 또는 manifest의 Cloud storage ID가 맞는지 확인한다.
2. qcow2 파일이 Cloud storage pool path 바로 아래에 있는지 확인한다.
3. `/var/lib/libvirt/images`에 생성된 파일을 Cloud storage로 import하려고 하지 않았는지 확인한다.

### phase2가 실행되지 않는 경우

`phase2`는 `phase1` 완료 marker가 있는 manifest가 필요하다.

확인 명령:

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/<vm>/<run-id> \
  status --resume-plan
```

### 대상 VM이 부팅되지 않는 경우

확인할 항목:

- 원본 VM의 disk 순서가 유지되었는지 확인한다.
- Cloud 대상에서는 root disk가 ROOT 타입으로 변환되었는지 확인한다.
- 대상 VM의 firmware, disk driver, CPU, memory 정보가 원본과 맞게 반영되었는지 확인한다.
- Linux VM은 initramfs, LVM PV/VG, `/etc/fstab` 문제를 확인한다.
- Windows VM은 VirtIO driver와 boot firmware 설정을 확인한다.

### 로그와 증거 파일 확인

작업 디렉터리에는 manifest와 이벤트 로그가 남는다.

```text
<workdir>/manifest.json
<workdir>/events.log
```

문제 보고 시 다음 정보를 함께 제공하면 분석이 빠르다.

- 실행한 명령
- 작업 디렉터리 경로
- `manifest.json`
- `events.log`
- 출력된 오류 메시지

Secret Key와 비밀번호는 공유하지 않는다.

## PDF 변환

이 문서는 Markdown으로 작성되어 있으므로 `pandoc`으로 PDF 변환할 수 있다.

한글 폰트가 설치된 환경에서의 예:

```bash
pandoc docs/n2k/ablestack_n2k_user_guide_ko.md \
  -o ablestack_n2k_user_guide_ko.pdf \
  --pdf-engine=xelatex \
  -V mainfont="Noto Sans CJK KR" \
  -V geometry:margin=20mm \
  --toc
```

`xelatex`가 없으면 HTML로 먼저 변환한 뒤 브라우저에서 PDF로 저장할 수 있다.

```bash
pandoc docs/n2k/ablestack_n2k_user_guide_ko.md \
  -o ablestack_n2k_user_guide_ko.html \
  --toc
```

## 빠른 참조

### Help 확인

```bash
ablestack_n2k --help
ablestack_n2k wizard --help
ablestack_n2k run --help
```

### Wizard phase1

```bash
ablestack_n2k wizard \
  --target-profile cloud-rbd \
  --split phase1 \
  --cred-file /root/nutanix.env \
  --cloud-cred-file /root/ablestack-cloud.env
```

### Wizard phase2

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/<vm>/<run-id> \
  wizard \
  --split phase2 \
  --shutdown guest \
  --cred-file /root/nutanix.env \
  --cloud-cred-file /root/ablestack-cloud.env
```

### 상태 확인

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/<vm>/<run-id> \
  status
```

### 다음 단계 확인

```bash
ablestack_n2k \
  --workdir /var/lib/ablestack-n2k/<vm>/<run-id> \
  status --resume-plan
```
