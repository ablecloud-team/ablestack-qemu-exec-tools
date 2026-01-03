# v2k Runbook (Operator)

이 문서는 `ablestack_v2k` 기반 VMware → ABLESTACK(KVM) 최소 중단 마이그레이션을 운영 절차로 정리한 Runbook 입니다.
(기본 정책: **final 단계는 shutdown 후 final snapshot 생성**)

---

## 0. 사전 점검(Go/No-Go)

### VMware 측
- [ ] VM에 CBT 활성화 가능한 상태(스냅샷/디스크 잠금 이슈 없음)
- [ ] vCenter/ESXi 접근 계정 권한 확보
- [ ] VM의 디스크/컨트롤러 구성(멀티디스크/컨트롤러 타입) 확인
- [ ] Windows VM: Fast Startup/Hibernation 비활성 권고(정합성)

### KVM(ABLESTACK) 측
- [ ] 대상 스토리지 경로 준비(예: /var/lib/libvirt/images/<VM>)
- [ ] qemu-img/virsh/jq/python3 준비
- [ ] 전송 대역폭(기간/업무시간) 계획

---

## 1. 작업 디렉토리 / 환경변수

```bash
source examples/v2k/govc.env.example
export VMNAME="vmA"
export DST="/var/lib/libvirt/images/${VMNAME}"
```

---

## 2. Init (Inventory + Manifest 생성)

```bash
sudo bin/ablestack_v2k.sh init --vm "${VMNAME}" --vcenter "${GOVC_URL}" --dst "${DST}"
```

- 출력된 `workdir` 기록
- `manifest.json`, `events.log` 생성 확인

---

## 3. CBT Enable

```bash
sudo bin/ablestack_v2k.sh --workdir <workdir> cbt enable
sudo bin/ablestack_v2k.sh --workdir <workdir> cbt status --json
```

---

## 4. Base Snapshot & Base Sync

```bash
sudo bin/ablestack_v2k.sh --workdir <workdir> snapshot base
sudo bin/ablestack_v2k.sh --workdir <workdir> sync base
```

운영 팁
- base는 가장 오래 걸리므로 야간/저부하 구간 권장
- 실제 운영 파이프라인(nbdkit-vddk)을 적용한 후 사용

---

## 5. Incremental Loop (업무시간 반복 가능)

```bash
# 반복(예: 30분~2시간 간격)
sudo bin/ablestack_v2k.sh --workdir <workdir> snapshot incr
sudo bin/ablestack_v2k.sh --workdir <workdir> sync incr
```

컷오버 판단 기준(권장)
- incr bytes(변경량)가 충분히 작아지고, 마지막 sync 소요 시간이 허용 범위에 들어오면 컷오버 창(maintenance window) 확정

---

## 6. Cutover (Shutdown + Final Snapshot + Final Sync)

1) VMware VM Shutdown (운영자 확인)
- [ ] 애플리케이션 정지/서비스 배포 창 확보
- [ ] VM 정상 종료 확인

2) Cutover 실행

```bash
sudo bin/ablestack_v2k.sh --workdir <workdir> cutover --define-only --start
```

- final snapshot 생성 → final sync 실행 → libvirt define/start(옵션)
- ABLESTACK 환경에 맞는 XML 템플릿/네트워크/CPU/메모리는 추후 정책 반영

---

## 7. Verify (Quick)

```bash
sudo bin/ablestack_v2k.sh --workdir <workdir> verify --mode quick --samples 64
```

---

## 8. 롤백 플랜(요약)

- KVM VM 부팅 실패/서비스 이상:
  - [ ] KVM VM stop/undefine
  - [ ] VMware VM power on (원본 유지되어야 함)
- 최종적으로 문제 원인 분석 후 재시도:
  - [ ] workdir 유지한 채 `--resume` 기반 재실행 권장

---

## 9. Cleanup

```bash
# 스냅샷 삭제는 정책 확인 후 진행(기본: v1은 자동 삭제 안 함)
sudo bin/ablestack_v2k.sh --workdir <workdir> cleanup --keep-workdir
```

---

## 장애/트러블슈팅 체크포인트

- govc 연결 오류: GOVC_URL/USERNAME/PASSWORD/INSECURE 확인
- changedAreas 조회 실패: pyvmomi 설치/인증서/권한 확인
- nbd 장치 문제(운영 파이프라인 적용 시): detach/lock/잔존 프로세스 확인
- 성능 이슈: coalesce-gap/chunk/jobs 튜닝, 네트워크 병목 확인
