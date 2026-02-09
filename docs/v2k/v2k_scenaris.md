# ablestack_v2k Operational Scenarios

본 문서는 실환경에서 `ablestack_v2k`를 운영하기 위한 권장 시나리오를 정리합니다.

---

## 1. 기본 자동 이관 (권장)

### 대상
- 일반 서비스 VM
- qcow2 또는 raw(file) 스토리지

### 절차
```bash
ablestack_v2k run \
  --vm <VM> \
  --vcenter <VCENTER> \
  --dst <DST> \
  --target-format qcow2 \
  --target-storage file
```

특징:
- 전체 파이프라인 자동 수행
- 중단 시간 최소화
- 오류 발생 시 `--resume` 가능

---

## 2. Split-run 운영 (대규모 VM)

### Phase1 (주간/업무시간)
```bash
ablestack_v2k run --split phase1 ...
```

- base + incr1까지만 수행
- 서비스 중단 없음

### Phase2 (야간/점검시간)
```bash
ablestack_v2k run --split phase2 --resume ...
```

- 추가 incr 반복 후 cutover
- 실제 서비스 중단 발생 구간

---

## 3. Windows VM 이관

- WinPE 자동 부트스트랩 기본 활성
- virtio 드라이버 ISO 필요
- 첫 부팅 후 장치 인식 확인 필수

---

## 4. Block / RBD 스토리지

- `--target-map-json` 필수
- 운영 환경에서는 사전 디바이스 검증 필수
- 실수 방지를 위해 테스트 환경 선행 권장

---

## 5. 장애 복구 전략

- 작업 중단 시:
```bash
ablestack_v2k status
ablestack_v2k run --resume
```

- cleanup은 명시적으로 실행
