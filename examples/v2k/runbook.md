# v2k Runbook (Operator)

이 문서는 `ablestack_v2k` 기반 VMware → ABLESTACK(KVM) 최소 중단 마이그레이션을 운영 절차로 정리한 Runbook 입니다.  
(기본 정책: **final 단계는 shutdown 후 final snapshot 생성**)

---

## 0. 목적과 범위

본 Runbook은 `ablestack_v2k` 기반으로 **VMware → ABLESTACK(KVM)** 최소 중단 마이그레이션을 수행하기 위한 **운영 절차 문서**이다.

- 대상: 운영 환경 VM
- 방식: CBT + Snapshot + NBDKit(VDDK)
- 원칙: **final 단계는 반드시 VM shutdown 이후 수행**

---

## 1. 사전 점검(Go / No-Go)

### 1.1 VMware 측
- [ ] VM에 CBT 활성화 가능 상태 (스냅샷/디스크 잠금 이슈 없음)
- [ ] vCenter 접근 계정 준비 (govc 전용)
- [ ] ESXi 접근 계정 준비 (VDDK 전용)
- [ ] VM 디스크/컨트롤러 구성 확인 (SCSI 권장)
- [ ] Windows VM의 경우 Fast Startup / Hibernation 비활성화 권장

### 1.2 KVM(ABLESTACK) 측
- [ ] 대상 스토리지 경로 확보 (예: `/var/lib/libvirt/images/<VM>`)
- [ ] 필수 도구 설치: `qemu-img`, `virsh`, `jq`, `python3`
- [ ] `nbdkit` 설치 및 실행 가능
- [ ] VMware VDDK 라이브러리 설치
- [ ] ESXi ↔ KVM 호스트 간 네트워크 통신 가능 (443/TCP)

---

## 2. 인증 구조 개요 (중요)

본 파이프라인은 **인증을 명확히 분리**한다.

| 구분 | 용도 | 사용 위치 |
|---|---|---|
| GOVC (vCenter) | Inventory, Snapshot, CBT | `govc`, `pyvmomi` |
| VDDK (ESXi) | 디스크 데이터 전송 | `nbdkit-vddk` |

> ⚠️ **GOVC 계정 ≠ VDDK 계정**  
> VDDK 단계에서 vCenter 계정을 사용하는 것은 제품 정책상 허용하지 않는다.

---

## 3. 사전 환경 변수 및 인증 파일 준비

### 3.1 vCenter (GOVC) 환경 변수

```bash
# vCenter API / Snapshot / CBT 관리용
source examples/v2k/govc.env.example
```

포함 항목:
- `GOVC_URL`
- `GOVC_USERNAME`
- `GOVC_PASSWORD`
- `GOVC_INSECURE`

---

### 3.2 ESXi (VDDK) 인증 파일 생성

VDDK는 **ESXi 호스트에 직접 접속**하여 디스크 데이터를 읽는다.

```bash
# examples/v2k/vddk.cred
VDDK_USER="root"
VDDK_PASSWORD="********"

# (선택) 접속 주소 override
# 지정 시 manifest의 .source.vddk.server 로 기록됨
# VDDK_SERVER="10.10.10.21"
```

보안 정책:
- init 시 workdir로 복사
- 권한: `600`
- manifest에는 **경로만 기록** (비밀번호 저장 안 함)

---

### 3.3 기타 필수 환경 변수

```bash
export VMNAME="vmA"
export DST="/var/lib/libvirt/images/${VMNAME}"
export VDDK_LIBDIR="/opt/vmware-vix-disklib-distrib"
export VDDK_CRED="./examples/v2k/vddk.cred"
```

---

## 4. Init 단계 (Inventory + Manifest 생성)

```bash
sudo ablestack_v2k init   --vm "${VMNAME}"   --vcenter "${GOVC_URL}"   --dst "${DST}"   --vddk-cred-file "${VDDK_CRED}"
```

Init 단계에서 자동 수행되는 작업:
- VM inventory 수집
- 실행 중인 ESXi host 탐색
- ESXi management IP 자동 결정
- manifest.json 생성
- `vddk.cred`를 workdir로 안전하게 복사
- `.source.vddk.*`, `.source.esxi_*` 필드 구성

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

- Base sync는 전체 디스크 전송
- 가장 오래 걸리므로 야간/저부하 시간대 권장

---

## 7. Incremental Loop (업무 중 반복)

```bash
sudo ablestack_v2k --workdir <workdir> snapshot incr
sudo ablestack_v2k --workdir <workdir> sync incr --jobs 4
```

컷오버 판단 기준:
- incr 변경량이 충분히 감소
- 마지막 incr sync 시간이 허용 범위 이내

---

## 8. Cutover (Shutdown + Final Sync)

1) VMware VM 종료 (운영자 확인)

2) Cutover 실행

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

## 11. 트러블슈팅 (VDDK 중심)

### VDDK 인증 실패
- `vddk.cred`의 `VDDK_USER / VDDK_PASSWORD` 확인
- ESXi Lockdown Mode 여부 확인
- `.source.vddk.server` 우선 사용 여부 확인
- fallback: `.source.esxi_host`

### govc 오류
- `GOVC_*` 환경 변수 확인

### 성능 이슈
- `--jobs` 조정
- 네트워크 병목 확인
