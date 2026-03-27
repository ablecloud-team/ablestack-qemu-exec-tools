# ablestack_vm_ftctl Profile Schema

## 1. 목적

이 문서는 `/etc/ablestack/ftctl.d/<vm>.conf` 형식을 고정한다.

- profile은 bash `KEY=VALUE` 형식이다.
- VM 하나당 파일 하나를 사용한다.
- 실제 구현은 `lib/ftctl/profile.sh`의 검증 로직과 이 문서를 기준으로 맞춘다.

## 2. 파일 위치

```bash
/etc/ablestack/ftctl.d/<vm>.conf
```

예:

```bash
/etc/ablestack/ftctl.d/demo-vm.conf
```

## 3. 공통 규칙

- 한 줄에 하나의 `KEY=VALUE`만 사용한다.
- 공백이 필요한 값은 전체를 큰따옴표로 감싼다.
- 값 안에 세미콜론(`;`)을 사용할 수 있다.
- 주석은 `#`로 시작한다.

## 4. 지원 필드

### 4.1 필수 필드

- `FTCTL_PROFILE_MODE`
  - 허용값: `ha`, `dr`, `ft`
- `FTCTL_PROFILE_SECONDARY_URI`
  - 예: `qemu+ssh://peer/system`

### 4.2 공통 선택 필드

- `FTCTL_PROFILE_NAME`
  - 기본값: `default`
- `FTCTL_PROFILE_PRIMARY_URI`
  - 기본값: 글로벌 설정의 `FTCTL_DEFAULT_PRIMARY_URI`
- `FTCTL_PROFILE_DISK_MAP`
  - 기본값: `auto`
  - 형식:
    - `auto`
    - `vda=/path/to/disk1;vdb=/path/to/disk2`
- `FTCTL_PROFILE_NETWORK_MAP`
  - 기본값: `inherit`
  - 형식:
    - `inherit`
    - `service=br-prod;backup=br-backup`
- `FTCTL_PROFILE_FENCING_POLICY`
  - 기본값: `manual-block`
  - 허용값:
    - `manual-block`
    - `ssh`
    - `peer-virsh-destroy`
    - `ipmi`
    - `redfish`
- `FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC`
  - 기본값: 글로벌 설정의 `FTCTL_TRANSIENT_NET_GRACE_SEC`
  - unsigned integer
- `FTCTL_PROFILE_AUTO_REARM`
  - 기본값: `1`
  - 허용값: `0`, `1`
- `FTCTL_PROFILE_RECOVERY_PRIORITY`
  - 기본값: `100`
  - unsigned integer
- `FTCTL_PROFILE_QGA_POLICY`
  - 기본값: `optional`
  - 허용값:
    - `optional`
    - `required`
    - `off`

### 4.3 FT 전용 필드

아래 필드는 `FTCTL_PROFILE_MODE=ft`에서만 허용된다.

- `FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT`
  - 예: `tcp:10.10.10.21:9000`
- `FTCTL_PROFILE_XCOLO_NBD_ENDPOINT`
  - 예: `tcp:10.10.20.21:10809`

`ha`, `dr`에서는 위 두 필드를 넣으면 검증 실패다.

## 5. mode별 요구사항

### 5.1 HA

- `FTCTL_PROFILE_MODE=ha`
- `FTCTL_PROFILE_SECONDARY_URI` 필수
- `FTCTL_PROFILE_DISK_MAP` 권장
- `FTCTL_PROFILE_XCOLO_*` 금지

예:

```bash
FTCTL_PROFILE_NAME="metro-ha"
FTCTL_PROFILE_MODE="ha"
FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer-a/system"
FTCTL_PROFILE_DISK_MAP="auto"
FTCTL_PROFILE_NETWORK_MAP="inherit"
FTCTL_PROFILE_FENCING_POLICY="peer-virsh-destroy"
FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="3"
FTCTL_PROFILE_AUTO_REARM="1"
FTCTL_PROFILE_RECOVERY_PRIORITY="100"
FTCTL_PROFILE_QGA_POLICY="optional"
```

### 5.2 DR

- `FTCTL_PROFILE_MODE=dr`
- `FTCTL_PROFILE_SECONDARY_URI` 필수
- `FTCTL_PROFILE_DISK_MAP` 권장
- `FTCTL_PROFILE_XCOLO_*` 금지

예:

```bash
FTCTL_PROFILE_NAME="remote-dr"
FTCTL_PROFILE_MODE="dr"
FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://dr-site/system"
FTCTL_PROFILE_DISK_MAP="vda=/dr/volumes/demo-vda.qcow2"
FTCTL_PROFILE_NETWORK_MAP="service=br-dr"
FTCTL_PROFILE_FENCING_POLICY="ssh"
FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="5"
FTCTL_PROFILE_AUTO_REARM="1"
FTCTL_PROFILE_RECOVERY_PRIORITY="200"
FTCTL_PROFILE_QGA_POLICY="required"
```

### 5.3 FT

- `FTCTL_PROFILE_MODE=ft`
- `FTCTL_PROFILE_SECONDARY_URI` 필수
- `FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT` 필수
- `FTCTL_PROFILE_XCOLO_NBD_ENDPOINT` 필수

예:

```bash
FTCTL_PROFILE_NAME="primary-ft"
FTCTL_PROFILE_MODE="ft"
FTCTL_PROFILE_PRIMARY_URI="qemu:///system"
FTCTL_PROFILE_SECONDARY_URI="qemu+ssh://peer-b/system"
FTCTL_PROFILE_DISK_MAP="auto"
FTCTL_PROFILE_NETWORK_MAP="inherit"
FTCTL_PROFILE_FENCING_POLICY="manual-block"
FTCTL_PROFILE_TRANSPORT_TOLERANCE_SEC="3"
FTCTL_PROFILE_AUTO_REARM="1"
FTCTL_PROFILE_RECOVERY_PRIORITY="10"
FTCTL_PROFILE_QGA_POLICY="optional"
FTCTL_PROFILE_XCOLO_PROXY_ENDPOINT="tcp:10.10.10.21:9000"
FTCTL_PROFILE_XCOLO_NBD_ENDPOINT="tcp:10.10.20.21:10809"
```

## 6. 현재 검증 규칙

현재 `lib/ftctl/profile.sh`는 아래를 검증한다.

- mode가 `ha|dr|ft`인지
- `PRIMARY_URI`, `SECONDARY_URI`가 비어 있지 않은지
- `DISK_MAP`, `NETWORK_MAP` 형식이 맞는지
- `FENCING_POLICY`, `QGA_POLICY`가 허용값인지
- `AUTO_REARM`가 `0|1`인지
- `TRANSPORT_TOLERANCE_SEC`, `RECOVERY_PRIORITY`가 unsigned integer인지
- `ft` mode에서 `XCOLO_*`가 있는지
- `ha/dr` mode에서 `XCOLO_*`가 비어 있는지

## 7. 구현 메모

- `disk_map=auto`는 Step 2에서 실제 inventory discovery와 연결한다.
- `network_map=inherit`는 Step 5에서 standby domain network attach와 연결한다.
- `fencing_policy` 실제 provider 구현은 Step 4에서 진행한다.
