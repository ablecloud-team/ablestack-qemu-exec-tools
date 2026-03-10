# manifest.json Specification

`manifest.json`은 ablestack_v2k의 상태 머신과 메타데이터를 저장하는 핵심 파일입니다.

---

## 기본 구조

```json
{
  "schema": "ablestack-v2k/manifest-v1",
  "run_id": "...",
  "vm": "...",
  "target_storage_type": "file|block|rbd",
  "target_format": "qcow2|raw",
  "disks": [],
  "phases": {},
  "timestamps": {}
}
```

---

## 주요 필드

| 필드 | 설명 |
|-----|-----|
| schema | manifest 스키마 버전 |
| run_id | 실행 ID |
| vm | VMware VM 식별자 |
| target_storage_type | 대상 스토리지 타입 |
| target_format | 디스크 포맷 |
| disks | 디스크 매핑 정보 |
| phases | 단계별 상태 |
| timestamps | 단계별 시간 기록 |

---

## phases 상태 예시

```json
{
  "init": "done",
  "cbt": "done",
  "base_sync": "done",
  "incr_sync": "running",
  "final_sync": "pending",
  "cutover": "pending"
}
```

---

## resume ?�작

- `--resume` ?�션 ??manifest 기반?�로 미완�??�계부???�개
- ?�료 ?�계???�실?�되지 ?�음
