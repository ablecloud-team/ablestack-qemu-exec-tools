# VMware -> ABLESTACK(KVM) Migration (v2k)

## 최소 실행 흐름(검증/운영)

### 0) 사전 준비
- KVM 호스트에 `qemu-img`, `virsh`, `jq`, `python3` 설치
- VMware 연동: **govc 우선**
- Changed Areas 조회: `pyvmomi` 필요 (v1은 python helper 사용)

> v1 전송 구현은 “VMDK가 로컬 파일로 접근 가능”한 환경을 기본으로 둡니다.  
> 실제 운영(최소 중단, 대용량)에서는 검증된 **nbdkit-vddk 파이프라인**을 `transfer_base.sh`/`transfer_patch.sh`에 접목해야 합니다.

---

## 1) init (inventory + manifest 생성)

```bash
# govc 환경변수 로드(예시)
source examples/v2k/govc.env.example

# init: workdir/manifest 생성
sudo bin/ablestack_v2k.sh init   --vm <VMNAME>   --vcenter <VCENTER_FQDN_OR_URL>   --dst /var/lib/libvirt/images/<VMNAME>
```

성공 시:
- workdir 생성: `/var/lib/ablestack-v2k/<VMNAME>/<run_id>/`
- `manifest.json`, `events.log` 생성

---

## 2) CBT enable

```bash
sudo bin/ablestack_v2k.sh --workdir <workdir> cbt enable
```

- 모든 디스크(멀티디스크 포함)에 대해 CBT 활성화 요청
- v1에서는 `scsiX:Y.ctkEnabled=true` 방식으로 설정 시도 (non-scsi는 경고 이벤트로 기록)

---

## 3) base snapshot + base sync

```bash
sudo bin/ablestack_v2k.sh --workdir <workdir> snapshot base
sudo bin/ablestack_v2k.sh --workdir <workdir> sync base
```

v1 기본 동작:
- `qemu-img convert`로 VMDK → qcow2 변환 (VMDK가 로컬 파일로 접근 가능해야 함)

운영 권장:
- `nbdkit-vddk --run 'qemu-img convert ... nbd:unix:...'` 파이프라인으로 교체

---

## 4) 반복: incr snapshot + incr sync

```bash
sudo bin/ablestack_v2k.sh --workdir <workdir> snapshot incr
sudo bin/ablestack_v2k.sh --workdir <workdir> sync incr
```

- `vmware_changed_areas.py`가 snapshot + disk_id 기준 changed areas를 조회
- `patch_apply.py`가 changed areas를 coalesce/chunk 방식으로 타겟에 패치

---

## 5) 컷오버(cutover)
**기본값(승인사항):** VMware VM shutdown 후 **final snapshot 생성** → **final sync**

```bash
# 1) VMware 쪽 VM을 먼저 Shutdown (운영자 확인)
# 2) 컷오버 실행: final snapshot + final sync + (옵션) libvirt define/start
sudo bin/ablestack_v2k.sh --workdir <workdir> cutover --define-only --start
```

---

## 6) 상태 조회 (ABLESTACK API 폴링용)

```bash
sudo bin/ablestack_v2k.sh --workdir <workdir> status --json
```

- manifest 요약 + events tail을 JSON으로 출력 (향후 ABLESTACK에서 폴링에 사용)

---

## 7) 정리(cleanup)

```bash
sudo bin/ablestack_v2k.sh --workdir <workdir> cleanup --keep-workdir
```

> v1에서는 안전을 위해 스냅샷 자동 삭제를 기본으로 수행하지 않습니다.  
> 운영 정책에 맞춰 v2에서 “manifest 기반 스냅샷 ID 정리”로 고도화 권장.

---

## v1 제약/주의사항 정리
- 전송(base/patch)은 v1에서 “VMDK 로컬 접근” 전제를 둠
- 최소 중단/대용량 운영은 **검증된 nbdkit-vddk 전송 파이프라인**을 transfer 모듈에 적용해야 함
- changed areas 조회는 `pyvmomi` 의존(에어갭 배포 시 wheel 사전 준비 필요)
