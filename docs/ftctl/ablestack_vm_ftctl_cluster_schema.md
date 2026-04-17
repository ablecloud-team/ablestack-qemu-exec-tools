# ablestack_vm_ftctl Cluster Schema

## 1. 목적

이 문서는 `ftctl`이 ABLESTACK cluster에서 사용할 cluster/host inventory 형식을 고정한다.

- cluster 전역 정보는 단일 설정 파일에서 관리한다.
- host inventory는 host별 파일로 관리한다.
- 운영자는 직접 편집할 수도 있지만, 기본 방식은 `ablestack_vm_ftctl config ...` 명령을 사용하는 것이다.

## 2. 파일 위치

전역 cluster 설정:

```bash
/etc/ablestack/ablestack-vm-ftctl-cluster.conf
```

host inventory:

```bash
/etc/ablestack/ftctl-cluster.d/hosts/<host-id>.conf
```

## 3. 전역 cluster 설정

### 3.1 필드

- `FTCTL_CLUSTER_NAME`
  - 예: `cluster-a`
- `FTCTL_LOCAL_HOST_ID`
  - 예: `host-01`

### 3.2 예제

```bash
FTCTL_CLUSTER_NAME="cluster-a"
FTCTL_LOCAL_HOST_ID="host-01"
```

## 4. host inventory 설정

### 4.1 필드

- `FTCTL_HOST_ID`
  - host 식별자
- `FTCTL_HOST_ROLE`
  - 허용값:
    - `primary`
    - `secondary`
    - `observer`
    - `generic`
- `FTCTL_HOST_MANAGEMENT_IP`
  - 클러스터 관리 네트워크 주소
- `FTCTL_HOST_LIBVIRT_URI`
  - 예: `qemu+ssh://host-01/system`
- `FTCTL_HOST_BLOCKCOPY_REPLICATION_IP`
  - blockcopy 데이터 경로용 주소
- `FTCTL_HOST_XCOLO_CONTROL_IP`
  - x-colo control 경로용 주소
- `FTCTL_HOST_XCOLO_DATA_IP`
  - x-colo data/NBD 경로용 주소

### 4.2 예제

```bash
FTCTL_HOST_ID="host-01"
FTCTL_HOST_ROLE="primary"
FTCTL_HOST_MANAGEMENT_IP="10.0.0.11"
FTCTL_HOST_LIBVIRT_URI="qemu+ssh://host-01/system"
FTCTL_HOST_BLOCKCOPY_REPLICATION_IP="172.16.10.11"
FTCTL_HOST_XCOLO_CONTROL_IP="172.16.20.11"
FTCTL_HOST_XCOLO_DATA_IP="172.16.30.11"
```

## 5. 구성 명령

cluster 초기화:

```bash
ablestack_vm_ftctl config init-cluster \
  --cluster-name cluster-a \
  --local-host-id host-01
```

로컬 호스트 변경:

```bash
ablestack_vm_ftctl config set-local-host --local-host-id host-02
```

host 등록/갱신:

```bash
ablestack_vm_ftctl config host-upsert \
  --host-id host-01 \
  --role primary \
  --management-ip 10.0.0.11 \
  --libvirt-uri qemu+ssh://host-01/system \
  --blockcopy-ip 172.16.10.11 \
  --xcolo-control-ip 172.16.20.11 \
  --xcolo-data-ip 172.16.30.11
```

host 삭제:

```bash
ablestack_vm_ftctl config host-remove --host-id host-02
```

조회:

```bash
ablestack_vm_ftctl config show
ablestack_vm_ftctl config show --json
ablestack_vm_ftctl config host-list
ablestack_vm_ftctl config host-list --json
```

## 6. 현재 검증 규칙

현재 구현은 아래를 검증한다.

- cluster name, local host id 형식
- host id 형식
- host role 허용값
- management/blockcopy/x-colo 주소 값 존재 여부
- libvirt URI가 `qemu://` 또는 `qemu+ssh://`로 시작하는지

주소 값은 현재 IPv4 또는 hostname 형태를 허용한다.

## 7. 구현 메모

- Step 4에서는 이 inventory를 바탕으로 source fenced와 network blip를 구분한다.
- Step 5에서는 local host id와 peer host record를 기준으로 standby XML 적용 위치를 결정한다.
- Step 7에서는 x-colo endpoint 구성 시 `FTCTL_HOST_XCOLO_*` 값을 사용한다.
