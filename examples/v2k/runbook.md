# v2k Runbook (Operator)

이 문서는 `ablestack_v2k` 기반 VMware → ABLESTACK(KVM) 최소 중단 마이그레이션의 운영 과정을 정리한 Runbook 입니다.
(기본 정책: **final 단계는 shutdown 후 final snapshot 생성**)

---

## 0. 목적 및 범위

이 Runbook은 `ablestack_v2k` 기반으로 **VMware → ABLESTACK(KVM)** 최소 중단 마이그레이션을 수행하기 위한 **운영 과정 문서**이다.

- 대상: 운영 환경 VM
- 방식: CBT + Snapshot + NBDKit(VDDK)
- 원칙: **final 단계는 반드시 VM shutdown 후 진행**

---

## 1. 사전 검증(Go / No-Go)

### 1.1 VMware 측

- [ ] VM의 CBT 활성화 가능 상태 (스냅샷 기반 증분 이슈 없음)
- [ ] vCenter 접근 계정 준비(govc 사용)
- [ ] ESXi 접근 계정 준비(VDDK 사용)
- [ ] VM 디스크 컨트롤러 구성 확인 (SCSI 권장)
- [ ] Windows VM의 경우 Fast Startup / Hibernation 비활성화 권장

### 1.2 KVM(ABLESTACK) 측

- [ ] 대상 스토리지 경로 준비 (예: `/var/lib/libvirt/images/<VM>`)
- [ ] 필수 패키지 설치: `qemu-img`, `virsh`, `jq`, `python3`
- [ ] `nbdkit` 설치 및 실행 가능
- [ ] VMware VDDK 라이브러리 설치
- [ ] ESXi ↔ KVM 호스트 간 네트워크 연결 가능(443/TCP)

---

## 2. 인증 구조 개요 (중요)

라이프사이클에서 **인증을 명확히 분리**한다.

| 구분 | 용도 | 사용 계정 |
|---|---|---|
| GOVC (vCenter) | Inventory, Snapshot, CBT | `govc`, `pyvmomi` |
| VDDK (ESXi) | 디스크 데이터 전송 | `nbdkit-vddk` |

> ⚠️ **GOVC 계정 ≠ VDDK 계정**
> VDDK 계정에서 vCenter 계정을 사용하는 것이 제품 정책상 허용되지 않거나 권장되지 않음

---

## 3. 사전 환경 변수 및 인증 파일 준비

### 3.1 vCenter (GOVC) ?�경 변??

```bash
# vCenter API / Snapshot / CBT 관리용
source examples/v2k/govc.env.example
```

?�함 ??��:

- `GOVC_URL`
- `GOVC_USERNAME`
- `GOVC_PASSWORD`
- `GOVC_INSECURE`

---

### 3.2 ESXi (VDDK) ?�증 ?�일 ?�성

VDDK??**ESXi ?�스?�에 직접 ?�속**?�여 ?�스???�이?��? ?�는??

```bash
# examples/v2k/vddk.cred
VDDK_USER="root"
VDDK_PASSWORD="********"

# (?�택) ?�속 주소 override
# 지????manifest??.source.vddk.server �?기록??
# VDDK_SERVER="10.10.10.21"
```

보안 ?�책:

- init ??workdir�?복사
- 권한: `600`
- manifest?�는 **경로�?기록** (비�?번호 ?�??????

---

### 3.3 기�? ?�수 ?�경 변??

```bash
export VMNAME="vmA"
export DST="/var/lib/libvirt/images/${VMNAME}"
export VDDK_LIBDIR="/opt/vmware-vix-disklib-distrib"
export VDDK_CRED="./examples/v2k/vddk.cred"
```

---

## 4. Init ?�계 (Inventory + Manifest ?�성)

```bash
sudo ablestack_v2k init   --vm "${VMNAME}"   --vcenter "${GOVC_URL}"   --dst "${DST}"   --vddk-cred-file "${VDDK_CRED}"
```

Init ?�계?�서 ?�동 ?�행?�는 ?�업:

- VM inventory ?�집
- ?�행 중인 ESXi host ?�색
- ESXi management IP ?�동 결정
- manifest.json ?�성
- `vddk.cred`�?workdir�??�전?�게 복사
- `.source.vddk.*`, `.source.esxi_*` ?�드 구성

---

## 5. CBT Enable

```bash
sudo ablestack_v2k --workdir <workdir> cbt enable
sudo ablestack_v2k --workdir <workdir> cbt status
```

---

## 6. Base Snapshot & Base Sync

```bash
sudo ablestack_v2k --workdir <workdir> snapshot base
sudo ablestack_v2k --workdir <workdir> sync base --jobs 4
```

- Base sync???�체 ?�스???�송
- 가???�래 걸리므�??�간/?�부???�간?� 권장

---

## 7. Incremental Loop (?�무 �?반복)

```bash
sudo ablestack_v2k --workdir <workdir> snapshot incr
sudo ablestack_v2k --workdir <workdir> sync incr --jobs 4
```

컷오�??�단 기�?:

- incr 변경량??충분??감소
- 마�?�?incr sync ?�간???�용 범위 ?�내

---

## 8. Cutover (Shutdown + Final Sync)

1) VMware VM 종료 (?�영???�인)

2) Cutover ?�행

```bash
sudo ablestack_v2k --workdir <workdir> cutover --define-only --start
```

---

## 9. Verify

```bash
sudo ablestack_v2k --workdir <workdir> verify --mode quick --samples 64
```

---

## 10. Cleanup

```bash
sudo ablestack_v2k --workdir <workdir> cleanup --keep-workdir
```

---

## 11. ?�러블슈??(VDDK 중심)

### VDDK ?�증 ?�패

- `vddk.cred`??`VDDK_USER / VDDK_PASSWORD` ?�인
- ESXi Lockdown Mode ?��? ?�인
- `.source.vddk.server` ?�선 ?�용 ?��? ?�인
- fallback: `.source.esxi_host`

### govc ?�류

- `GOVC_*` ?�경 변???�인

### ?�능 ?�슈

- `--jobs` 조정
- ?�트?�크 병목 ?�인
