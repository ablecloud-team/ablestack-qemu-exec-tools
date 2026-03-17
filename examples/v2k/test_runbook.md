# v2k Test Runbook

이 문서는 `ablestack_v2k`의 기능 검증을 위한 테스트 절차를 정리한 테스트 런북이다.

목표:

- `qcow2/file` 기존 경로에 회귀가 없는지 확인
- `rbd` 대상이 `rbd map` 기반 block device 경로로 정상 동작하는지 확인
- 수동 단계별 실행과 `run(auto)`의 `full / phase1 / phase2` 시퀀스를 모두 검증

---

## 0. 테스트 범위

필수 검증 대상:

- `qcow2/file` Linux VM
- `qcow2/file` Windows VM
- `rbd` Linux VM
- 가능하면 `rbd` 다중 디스크 VM

권장 추가 검증:

- `raw/file`
- `raw/block`
- `define-only` 후 `start` 재실행
- `--resume` 재개 시나리오

---

## 1. 공통 준비

### 1.1 환경 준비

- vCenter / ESXi 접근 계정 준비
- ABLESTACK 호스트에 `govc`, `jq`, `python3`, `qemu-img`, `virsh`, `nbdkit` 설치
- VMware VDDK 라이브러리 설치
- RBD 테스트 호스트의 `ceph.conf` / keyring 준비

### 1.2 기본 환경 변수

```bash
source examples/v2k/govc.env.example

export VMNAME="vmA"
export DST="/var/lib/libvirt/images/${VMNAME}"
export VDDK_LIBDIR="/opt/vmware-vix-disklib-distrib"
export VDDK_CRED="./examples/v2k/vddk.cred.example"
```

### 1.3 결과 확인 포인트

모든 테스트에서 아래 파일을 같이 확인한다.

- `manifest.json`
- `events.log`
- `logs/`
- `artifacts/*.xml`

---

## 2. 테스트 매트릭스

| 구분 | 저장소 타입 | 게스트 | 필수 |
|---|---|---|---|
| A | qcow2/file | Linux | 예 |
| B | qcow2/file | Windows | 예 |
| C | rbd | Linux | 예 |
| D | rbd | Linux, multi-disk | 권장 |

---

## 3. 단계별 수동 테스트

이 절차는 `init -> cbt -> snapshot/sync -> verify -> cutover -> cleanup`를 개별 명령으로 검증한다.

### 3.1 qcow2/file 수동 테스트

#### Init

```bash
sudo ablestack_v2k init \
  --vm "${VMNAME}" \
  --vcenter "${GOVC_URL}" \
  --dst "${DST}" \
  --target-format qcow2 \
  --target-storage file \
  --vddk-cred-file "${VDDK_CRED}"
```

확인:

- `manifest.json` 생성
- `.target.format == "qcow2"`
- `.target.storage.type == "file"`

#### CBT

```bash
sudo ablestack_v2k --workdir <workdir> cbt enable
sudo ablestack_v2k --workdir <workdir> cbt status
```

확인:

- CBT enabled 상태
- 각 디스크의 `cbt.enabled == true`

#### Base

```bash
sudo ablestack_v2k --workdir <workdir> snapshot base
sudo ablestack_v2k --workdir <workdir> sync base --jobs 4
```

확인:

- base snapshot 생성
- qcow2 이미지 파일 생성
- `.disks[].transfer.base_done == true`

#### Incr / Final

```bash
sudo ablestack_v2k --workdir <workdir> snapshot incr
sudo ablestack_v2k --workdir <workdir> sync incr --jobs 4

sudo ablestack_v2k --workdir <workdir> snapshot final
sudo ablestack_v2k --workdir <workdir> sync final --jobs 4
```

확인:

- incr / final snapshot 정상 생성
- `incr_seq` 증가
- `last_change_id` 업데이트

#### Verify / Cutover / Cleanup

```bash
sudo ablestack_v2k --workdir <workdir> verify --mode quick --samples 64
sudo ablestack_v2k --workdir <workdir> cutover --shutdown guest --start
sudo ablestack_v2k --workdir <workdir> cleanup --keep-workdir
```

확인:

- libvirt XML이 `type='file'`
- VM 기동 성공
- cleanup 이후 workdir 보존

### 3.2 rbd 수동 테스트

#### Init

```bash
sudo ablestack_v2k init \
  --vm "${VMNAME}" \
  --vcenter "${GOVC_URL}" \
  --dst "${DST}" \
  --target-format raw \
  --target-storage rbd \
  --target-map-json '{"scsi0:0":"rbd:rbd/'"${VMNAME}"'-disk0"}' \
  --vddk-cred-file "${VDDK_CRED}"
```

확인:

- `.target.storage.type == "rbd"`
- `.disks[].transfer.target_path`가 `rbd:`로 시작

#### CBT / Base / Incr / Final

```bash
sudo ablestack_v2k --workdir <workdir> cbt enable
sudo ablestack_v2k --workdir <workdir> snapshot base
sudo ablestack_v2k --workdir <workdir> sync base --jobs 4

sudo ablestack_v2k --workdir <workdir> snapshot incr
sudo ablestack_v2k --workdir <workdir> sync incr --jobs 4

sudo ablestack_v2k --workdir <workdir> snapshot final
sudo ablestack_v2k --workdir <workdir> sync final --jobs 4
```

확인:

- sync 시 호스트에서 `rbd map` 수행
- 대상 장치가 `/dev/rbd/<pool>/<image>`로 준비되는지 확인
- patch sync 종료 후 임시 map이 정리되는지 확인

#### Linux bootstrap / Cutover

```bash
sudo ablestack_v2k --workdir <workdir> cutover --shutdown guest --start
```

확인:

- `manifest.runtime.rbd.mapped[*].dev_path` 기록
- libvirt XML이 `<disk type='block'>`
- `<source dev='/dev/rbd/<pool>/<image>'>` 사용
- Linux bootstrap 이후 VM 기동 성공
- cutover 후 활성 RBD map이 유지되는지 확인

#### Cleanup

```bash
sudo ablestack_v2k --workdir <workdir> cleanup --keep-workdir
```

확인:

- 활성 VM이 사용하는 RBD map을 cleanup이 잘못 unmap하지 않는지 확인

---

## 4. run(auto) Full 테스트

`run(auto)` full은 전체 파이프라인을 한 번에 검증한다.

### 4.1 qcow2/file

```bash
sudo ablestack_v2k run \
  --vm "${VMNAME}" \
  --vcenter "${GOVC_URL}" \
  --dst "${DST}" \
  --target-format qcow2 \
  --target-storage file \
  --vddk-cred-file "${VDDK_CRED}" \
  --shutdown guest
```

기대 시퀀스:

1. init
2. cbt enable
3. snapshot base
4. sync base
5. snapshot incr / sync incr 반복
6. snapshot final
7. sync final
8. verify
9. cutover
10. cleanup

확인:

- 최종 phase가 `cutover.done == true`
- qcow2 XML / VM 기동 정상

### 4.2 rbd

```bash
sudo ablestack_v2k run \
  --vm "${VMNAME}" \
  --vcenter "${GOVC_URL}" \
  --dst "${DST}" \
  --target-format raw \
  --target-storage rbd \
  --target-map-json '{"scsi0:0":"rbd:rbd/'"${VMNAME}"'-disk0"}' \
  --vddk-cred-file "${VDDK_CRED}" \
  --shutdown guest
```

추가 확인:

- sync 단계에서 `rbd map` 기반 write
- cutover 직전 persistent map 생성
- `manifest.runtime.rbd.mapped` 기록
- libvirt block disk XML 생성
- VM 시작 후 RBD map 유지

---

## 5. run(auto) Phase1 테스트

`phase1`은 업무시간 중 선행 동기화 단계 검증이다.

### 5.1 qcow2/file

```bash
sudo ablestack_v2k run \
  --vm "${VMNAME}" \
  --vcenter "${GOVC_URL}" \
  --dst "${DST}" \
  --target-format qcow2 \
  --target-storage file \
  --vddk-cred-file "${VDDK_CRED}" \
  --split phase1
```

기대 시퀀스:

1. init
2. cbt enable
3. snapshot base
4. sync base
5. snapshot incr
6. sync incr 1회
7. 종료

확인:

- cutover는 수행되지 않음
- `runtime.split.phase1.done == true`
- qcow2 이미지와 workdir 결과가 남아 있음

### 5.2 rbd

```bash
sudo ablestack_v2k run \
  --vm "${VMNAME}" \
  --vcenter "${GOVC_URL}" \
  --dst "${DST}" \
  --target-format raw \
  --target-storage rbd \
  --target-map-json '{"scsi0:0":"rbd:rbd/'"${VMNAME}"'-disk0"}' \
  --vddk-cred-file "${VDDK_CRED}" \
  --split phase1
```

기대 시퀀스:

1. init
2. cbt enable
3. snapshot base
4. sync base
5. snapshot incr
6. sync incr 1회
7. 종료

확인:

- cutover는 수행되지 않음
- `runtime.split.phase1.done == true`
- base / incr 결과가 workdir에 남아 있음

---

## 6. run(auto) Phase2 테스트

`phase2`는 `phase1` workdir을 이어받아 incr 반복 후 cutover까지 수행한다.

### 6.1 qcow2/file

```bash
sudo ablestack_v2k run \
  --vm "${VMNAME}" \
  --target-format qcow2 \
  --target-storage file \
  --split phase2 \
  --resume
```

기대 시퀀스:

1. 기존 workdir / manifest 재사용
2. incr 반복
3. deadline 또는 수렴 조건 충족
4. snapshot final
5. sync final
6. verify
7. cutover
8. cleanup

확인:

- `phase1` 결과를 이어받는지
- `phase2`에서 cutover까지 완료되는지
- qcow2/file XML과 VM 기동이 정상인지

### 6.2 rbd

```bash
sudo ablestack_v2k run \
  --vm "${VMNAME}" \
  --split phase2 \
  --resume
```

기대 시퀀스:

1. 기존 workdir / manifest 재사용
2. incr 반복
3. deadline 또는 수렴 조건 충족
4. snapshot final
5. sync final
6. verify
7. cutover
8. cleanup

확인:

- `phase1` 결과를 이어받는지
- `phase2`에서 cutover까지 완료되는지
- `rbd`이면 persistent map과 libvirt block disk가 정상 적용되는지

---

## 7. 장애 / 재시도 테스트

### 7.1 `--resume`

중단 후:

```bash
ablestack_v2k status
ablestack_v2k run --resume
```

확인:

- 완료 단계 재실행 없이 미완료 단계만 이어가는지

### 7.2 define-only 후 start

```bash
ablestack_v2k --workdir <workdir> cutover --define-only
ablestack_v2k --workdir <workdir> cutover --start
```

확인:

- libvirt define 재실행 시 충돌이 없는지
- `rbd` mapped path가 계속 유효한지

### 7.3 force-cleanup

```bash
ablestack_v2k --workdir <workdir> sync final --force-cleanup
```

확인:

- 임시 helper 프로세스 정리
- cutover 완료 후 활성 VM의 persistent RBD map은 영향받지 않는지

---

## 8. 최종 합격 기준

아래 조건을 만족하면 이번 변경 검증을 통과한 것으로 본다.

- `qcow2/file` 회귀 없음
- `rbd` base / patch sync 정상
- `rbd` Linux bootstrap 정상
- `rbd` cutover 시 `manifest.runtime.rbd.mapped` 기록
- `rbd` libvirt XML이 block disk로 생성
- VM 기동 이후 활성 RBD map이 잘못 unmap되지 않음
- `run(auto)` `full / phase1 / phase2` 모두 시퀀스 누락 없이 수행 가능
