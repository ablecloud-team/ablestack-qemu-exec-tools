# manifest.json Specification

`manifest.json`은 ablestack_v2k의 상태 머신과 메타데이터를 저장하는 핵심 파일입니다.

---

## 기본 구조

```json
{
  "schema": "ablestack-v2k/manifest-v1",
  "run": {
    "run_id": "...",
    "created_at": "...",
    "workdir": "..."
  },
  "source": {
    "type": "vmware",
    "vm": {}
  },
  "target": {
    "type": "kvm",
    "format": "qcow2|raw",
    "storage": {
      "type": "file|block|rbd",
      "map": {}
    }
  },
  "disks": [],
  "phases": {},
  "runtime": {}
}
```

---

## 주요 필드

| 필드 | 설명 |
|-----|-----|
| schema | manifest 스키마 버전 |
| run.run_id | 실행 ID |
| source.vm | VMware VM 식별자/메타데이터 |
| target.storage.type | 대상 스토리지 타입 |
| target.format | 디스크 포맷 |
| disks | 디스크 매핑 정보 |
| phases | 단계별 상태 |
| runtime | 실행 중 상태 및 관측 정보 |

---

## phases 상태 예시

```json
{
  "init": { "done": true, "ts": "..." },
  "base_sync": { "done": true, "ts": "..." },
  "incr_sync": { "done": false, "ts": "" },
  "final_sync": { "done": false, "ts": "" },
  "cutover": { "done": false, "ts": "" }
}
```

---

## runtime.rbd.mapped

`target.storage.type=rbd`인 경우 cutover 직전 host-side persistent map 경로를 runtime에 기록합니다.

```json
{
  "runtime": {
    "rbd": {
      "mapped": {
        "scsi0:0": {
          "uri": "rbd:rbd/vmA-disk0",
          "dev_path": "/dev/rbd/rbd/vmA-disk0",
          "mapped": true,
          "ts": "2026-03-11T12:00:00+09:00"
        }
      }
    }
  }
}
```

용도:

- cutover 시 실제 block device 경로 추적
- libvirt XML 생성 시 mapped path 우선 사용
- status / 장애 분석 시 현재 매핑 상태 확인

---

## resume 동작

- `--resume` 옵션은 manifest 기반으로 미완료 단계를 재개합니다.
- 완료된 단계는 다시 실행하지 않습니다.
