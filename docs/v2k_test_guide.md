# v2k 테스트 준비/수행 가이드 (Pipeline 포함)

본 문서는 `ablestack_v2k`(v2k) 마이그레이션 파이프라인( **nbdkit-vddk + qemu-img / nbd-client + qemu-nbd** )을 실환경에서 검증하기 위한 절차서입니다.

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

### 필수 도구/의존성
- govc
- nbdkit (vddk plugin 포함)
- VMware VDDK 라이브러리 (`VDDK_LIBDIR`)
- nbd-client, qemu-nbd, qemu-img
- python3 + pyvmomi
- jq, openssl, udevadm

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

---

## 2. 환경 변수 설정

### 2-1) govc 환경변수
`examples/v2k/govc.env.example`을 참고하여 설정:

```bash
source examples/v2k/govc.env.example
```

필수:
- `GOVC_URL`
- `GOVC_USERNAME`
- `GOVC_PASSWORD`
- `GOVC_INSECURE=1` (테스트 단계 권장)

### 2-2) VDDK 라이브러리
```bash
export VDDK_LIBDIR=/opt/vmware-vix-disklib-distrib/lib64
```

### 2-3) ESXi Host 지정(중요)
v2k 파이프라인은 안정성을 위해 **ESXi host** 지정이 필요합니다.

- init 후 manifest에 `source.esxi_host`를 넣어야 합니다.

예시:
```bash
export WORKDIR="/var/lib/ablestack-v2k/<VMNAME>/<RUN_ID>"
jq '.source.esxi_host="esxi01.example.local"' -c "${WORKDIR}/manifest.json" > /tmp/m && mv /tmp/m "${WORKDIR}/manifest.json"
```

(선택) Thumbprint를 수동으로 고정하고 싶으면:
```bash
export THUMBPRINT="AA:BB:CC:..."
```

---

## 3. 테스트 수행 절차(End-to-End)

### 3-1) init
```bash
export VMNAME="vmA"
export DST="/var/lib/libvirt/images/${VMNAME}"

sudo bin/ablestack_v2k.sh init --vm "${VMNAME}" --vcenter "${GOVC_URL}" --dst "${DST}"
# 출력된 workdir 기록
```

### 3-2) CBT enable
```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" cbt enable
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" cbt status --json
```

### 3-3) base snapshot + base sync (Pipeline 검증 핵심 1)
```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" snapshot base
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" sync base
```

정상 확인:
- `${DST}/disk0.qcow2` 등 디스크별 qcow2 생성/크기 증가
- `${WORKDIR}/events.log`에 base convert 이벤트 기록

### 3-4) incr loop (Pipeline 검증 핵심 2)
```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" snapshot incr
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" sync incr --coalesce-gap 1048576 --chunk 4194304
```

정상 확인:
- events.log에서 `changed_areas_fetched`가 0이 아닌 값이면 patch 수행
- coalesce/chunk 값은 성능 튜닝 포인트

### 3-5) 컷오버(Shutdown + Final Snapshot + Final Sync)
1) VMware에서 VM 정상 종료(운영자 확인)
2) 컷오버 실행:

```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" cutover --define-only --start
```

### 3-6) Verify
```bash
sudo bin/ablestack_v2k.sh --workdir "${WORKDIR}" verify --mode quick --samples 64
```

---

## 4. 로그/아티팩트 수집(필수)

테스트 결과 공유 시 아래 파일을 제공하면, 다음 수정 단계에서 정확히 잡을 수 있습니다.

- `${WORKDIR}/events.log`
- `${WORKDIR}/manifest.json`
- (파이프라인 로그 파일이 생성된 경우) `${WORKDIR}/logs/*`

---

## 5. 자주 발생하는 이슈 & 1차 조치

### 5-1) nbdkit: vddk plugin 없음
- `nbdkit vddk --help` 실패
- 조치: nbdkit을 vddk plugin 포함해서 재빌드/설치, VDDK SDK 설치 확인

### 5-2) thumbprint 오류
- 조치: `THUMBPRINT` 환경변수로 고정하거나, ESXi 인증서 갱신 여부 확인

### 5-3) /dev/nbd* busy
- 조치: `nbd-client -d /dev/nbdX`, `qemu-nbd -d /dev/nbdX`, 잔존 프로세스 종료
- 개선: nbd lock/cleanup 로직 튜닝(현재 v2k_nbd_alloc 포함)

### 5-4) QueryChangedDiskAreas 실패
- 원인: 권한/인증서/pyvmomi 설치/스냅샷 참조 실패
- 조치: python helper 단독 실행으로 확인
  ```bash
  python3 lib/v2k/vmware_changed_areas.py --vm "${VMNAME}" --snapshot "<snap>" --disk-id "scsi0:0"
  ```

---

## 6. 다음 개선(자동화/제품화 방향)
- init 단계에서 `--esxi-host` 옵션을 받아 manifest에 자동 기록
- changeId를 디스크별로 저장하여 “진짜 CBT 증분” 구현
- jobs 병렬 처리 시, nbd 할당/락/소켓 네이밍 안정화
- ABLESTACK API 호출을 위한 status JSON 확장(메트릭/진행률)
