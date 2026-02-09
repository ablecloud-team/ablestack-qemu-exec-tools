# events.log Format

`events.log`는 모든 실행 이벤트를 JSON Lines 형식으로 기록합니다.

---

## 기본 형식

```json
{"ts":"2026-01-29T15:48:00","level":"INFO","phase":"base_sync","msg":"Base sync started"}
```

---

## 필드 정의

| 필드 | 설명 |
|----|----|
| ts | ISO8601 타임스탬프 |
| level | INFO / WARN / ERROR |
| phase | 실행 단계 |
| msg | 이벤트 메시지 |
| data | 선택적 추가 정보 |

---

## 예시 로그 흐름

```json
{"phase":"init","msg":"Initialized"}
{"phase":"cbt","msg":"CBT enabled"}
{"phase":"snapshot","msg":"Base snapshot created"}
{"phase":"sync","msg":"Base sync completed"}
{"phase":"cutover","msg":"VM powered off"}
{"phase":"cutover","msg":"KVM VM started"}
```

---

## 활용 방안

- 실시간 상태 표시 대시보드
- 외부 모니터링 연계
- 장애 분석 및 감사 로그
