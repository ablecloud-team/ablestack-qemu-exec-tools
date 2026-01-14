# v2k 테스트 준비/수행 가이드 (Pipeline 포함)

본 문서는 `ablestack_v2k`(v2k) 마이그레이션 파이프라인(**nbdkit-vddk + qemu-img / nbd-client + qemu-nbd**)을 실환경에서 검증하기 위한 절차서입니다.

> 기본 정책: **final 단계는 shutdown 후 final snapshot 생성**

---

## 0. 테스트 환경 전제

### KVM 호스트 (Rocky Linux 9 권장)
- libvirt/kvm 동작 상태
- 디스크 저장 위치(예): `/var/lib/libvirt/images/<VMNAME>/`
- 네트워크: ESXi(443), vCenter(443/SDK), KVM host 간 통신 가능

### VMware 측
- vCenter/ESXi 접근 계정
- 대상 VM이 실행 중이며 스냅샷 생성 가능
- CBT 활성화 가능한 구성(디스크 잠금/기존 스냅샷 폭주 상태 지양)

---

## 1. 설치/의존성 체크 (권장)

레포 루트에서:

```bash
export VDDK_LIBDIR=/opt/vmware-vix-disklib-distrib/lib64
sudo bin/v2k_test_install.sh
```

에어갭(오프라인)에서 pyvmomi wheel이 준비된 경우:

```bash
sudo bin/v2k_test_install.sh --offline-wheel-dir /repo/wheels
```

> 참고: RHEL 계열에서 `nbd/nbdkit` 설치는 EPEL이 필요할 수 있어 스크립트가 `epel-release` 설치를 먼저 수행합니다.

---

## 2. RPM 이외 구성요소 설치 안내 (govc / VDDK / nbdkit vddk plugin)

### 2-1) govc 설치
`govc`는 보통 RPM으로 제공되지 않는 단일 바이너리입니다.

**오프라인/사내 배포 방식(권장)**  
1) 인터넷 되는 환경에서 govc 릴리즈 바이너리를 확보
2) 에어갭 환경으로 옮긴 뒤 배치:

```bash
sudo install -m 0755 govc /usr/local/bin/govc
govc version
```

운영 팁
- 사내 Nexus/Artifactory에 govc 바이너리를 등록해두면 배포가 안정적입니다.

### 2-2) VMware VDDK 설치
- VMware VDDK는 Broadcom/VMware 포털에서 별도 다운로드(라이선스/EULA) 후 설치하는 형태가 일반적입니다.
- 설치 후 라이브러리 경로를 환경변수로 지정합니다.

예시(설치 경로는 환경에 따라 다름):
```bash
export VDDK_LIBDIR=/opt/vmware-vix-disklib-distrib
ls -l ${VDDK_LIBDIR}/lib64/libvixDiskLib.so*
```

### 2-3) nbdkit vddk plugin 설치/확인
`nbdkit vddk`는 **nbdkit의 vddk plugin**이 있어야 동작합니다.

1) 설치 확인:
```bash
nbdkit vddk --help
```

2) RPM이 있는 경우(환경에 따라 패키지명이 다름):
- `nbdkit-plugin-vddk` 또는 `nbdkit-vddk-plugin`

3) RPM이 없는 경우(특히 Rocky/RHEL에서 흔함): **소스 빌드 필요**
- 개요:
  - VDDK가 설치되어 있어야 함(`VDDK_LIBDIR` 유효)
  - nbdkit 소스에서 vddk plugin을 enable하여 빌드
- 이 절차는 에어갭 여부/사내 정책에 따라 달라서, 네 환경 기준으로 build recipe를 확정한 뒤 runbook에 고정하는 방식이 안전합니다.
- 필요하면 네 빌드 로그/OS 버전 기준으로 SPEC/빌드 스크립트까지 바로 만들어 줄게.

---

## 3. 환경 변수 설정

### 3-1) govc 환경변수
`examples/v2k/govc.env.example` 참고:

```bash
source examples/v2k/govc.env.example
```

필수:
- `GOVC_URL`
- `GOVC_USERNAME`
- `GOVC_PASSWORD`
- `GOVC_INSECURE=1` (테스트 권장)

### 3-2) VDDK 라이브러리
```bash
export VDDK_LIBDIR=/opt/vmware-vix-disklib-distrib/lib64
```

### 3-3) ESXi Host 지정(중요)
파이프라인은 안정성을 위해 **ESXi host** 지정이 필요합니다.
init 후 manifest에 `source.esxi_host`를 넣습니다.

```bash
export WORKDIR="/var/lib/ablestack-v2k/<VMNAME>/<RUN_ID>"
jq '.source.esxi_host="esxi01.example.local"' -c "${WORKDIR}/manifest.json" > /tmp/m && mv /tmp/m "${WORKDIR}/manifest.json"
```

(선택) Thumbprint를 수동 고정:
```bash
export THUMBPRINT="AA:BB:CC:..."
```

---

## 4. 테스트 수행 절차(End-to-End)

### 4-1) init
```bash
export VMNAME="vmA"
export DST="/var/lib/libvirt/images/${VMNAME}"

sudo bin/ablestack_v2k.sh init --vm "${VMNAME}" --vcenter "${GOVC_URL}" --dst "${DST}"
# 출력된 workdir 기록
```

### 4-2) CBT enable
```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" cbt enable
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" cbt status --json
```

### 4-3) base snapshot + base sync
```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" snapshot base
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" sync base
```

### 4-4) incr loop
```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" snapshot incr
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" sync incr --coalesce-gap 1048576 --chunk 4194304
```

### 4-5) 컷오버(Shutdown + Final Snapshot + Final Sync)
1) VMware에서 VM 정상 종료(운영자 확인)
2) 컷오버 실행:
```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" cutover --define-only --start
```

### 4-6) Verify
```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" verify --mode quick --samples 64
```

---

## 5. 로그/아티팩트 수집(필수)
테스트 결과 공유 시:
- `${WORKDIR}/events.log`
- `${WORKDIR}/manifest.json`
- (있으면) `${WORKDIR}/logs/*`

---

## 6. 자주 발생하는 이슈 & 1차 조치

### 6-1) nbdkit: vddk plugin 없음
- `nbdkit vddk --help` 실패
- 조치:
  - (가능하면) `nbdkit-plugin-vddk` / `nbdkit-vddk-plugin` 설치 시도
  - 안되면 소스 빌드 절차 확정 필요(네 환경 기준으로 스크립트/패키징 제공 가능)

### 6-2) thumbprint 오류
- 조치: `THUMBPRINT` 고정 또는 ESXi 인증서 갱신 여부 확인

### 6-3) /dev/nbd* busy
- 조치: `nbd-client -d /dev/nbdX`, `qemu-nbd -d /dev/nbdX`, 잔존 프로세스 종료

### 6-4) QueryChangedDiskAreas 실패
- 조치: python helper 단독 실행으로 확인
```bash
python3 lib/v2k/vmware_changed_areas.py --vm "${VMNAME}" --snapshot "<snap>" --disk-id "scsi0:0"
```
