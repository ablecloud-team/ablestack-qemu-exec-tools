# ablestack_v2k Operational Scenarios

이 문서는 다양한 환경에서 `ablestack_v2k`를 운영하기 위한 권장 시나리오를 정리합니다.

---

## 1. 기본 자동 실행 (권장)

### 대상

- 일반 업무용 VM
- qcow2 또는 raw(file) 스토리지

### 실행

```bash
ablestack_v2k run \
  --vm <VM> \
  --vcenter <VCENTER> \
  --dst <DST> \
  --target-format qcow2 \
  --target-storage file
```

특징:

- 전체 라이프사이클 자동 실행
- 중단 시간 최소화
- 오류 발생 시 `--resume` 가능

---

## 2. Split-run 운영 (대규모 VM)

### Phase1 (주간/업무시간)

```bash
ablestack_v2k run --split phase1 ...
```

- base + incr1까지만 실행
- 업무 중단 없음

### Phase2 (야간/휴일시간)

```bash
ablestack_v2k run --split phase2 --resume ...
```

- 추가 incr 반복 후 cutover
- 실제 업무 중단 발생 구간

---

## 3. Windows VM 이전

- WinPE ?�동 부?�스?�랩 기본 ?�성
- virtio ?�라?�버 ISO ?�요
- �?부?????�치 ?�식 ?�인 ?�수

---

## 4. Block / RBD ?�토리�?

- `--target-map-json` ?�수
- ?�영 ?�경?�서???�전 ?�바?�스 검�??�수
- ?�수 방�?�??�해 ?�스???�경 ?�행 권장

---

## 5. ?�애 복구 ?�략

- ?�업 중단 ??

```bash
ablestack_v2k status
ablestack_v2k run --resume
```

- cleanup?� 명시?�으�??�행
