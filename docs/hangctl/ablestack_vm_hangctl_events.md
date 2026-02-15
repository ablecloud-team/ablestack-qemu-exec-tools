# ablestack_vm_hangctl - Events (JSONL)

`ablestack_vm_hangctl`은 운영/감사/원인분석을 위해 **append-only JSONL 이벤트 로그**를 기록합니다.

- 기본 경로: `/var/log/ablestack-vm-hangctl/events.log`
- 포맷: 1라인 = 1 JSON 객체 (JSONL)

## 스키마(고정)

모든 이벤트는 아래 공통 필드를 가집니다.

| Field | Type | Required | Description |
|---|---:|:---:|---|
| ts | string | Y | ISO8601 (+TZ) |
| scan_id | string | Y | 스캔 실행 단위 식별자 |
| incident_id | string | N | VM Hang 사건 단위 식별자 |
| vm | string | N | VM 이름 |
| stage | string | Y | scan/detect/confirm/evidence/action/libvirtd/verify/done/error |
| event | string | Y | 이벤트명(단계 내 세부) |
| result | string | Y | ok/fail/timeout/skip/warn |
| rc | number | N | 커맨드 실행 결과 코드 |
| elapsed_ms | number | N | 실행 시간(ms) |
| details | object | N | 추가 정보(키/값) |

## Commit 03 범위

Commit 03에서는 스캔 라이프사이클 이벤트만 기록합니다.

- `scan.scan.start`
- `scan.scan.end`

Commit 05에서는 circuit breaker / 대상 VM 수집 이벤트가 추가됩니다.

- `scan.libvirtd.health`
- `scan.scan.targets`

Commit 06에서는 domstate 기반 정체(stuck) 개산 이벤트가 추가됩니다.

- `detect.vm.domstate`

Commit 07에서는 probe(확정 신호) 이벤트 및 최종 판정 이벤트가 추가됩니다.

- `detect.probe.qmp`
- `detect.probe.qga`
- `detect.vm.decision`

Commit 08에서는 confirmed VM에 대한 액션/사후 검증 이벤트가 추가됩니다.

- `action.incident.start`
- `action.action.destroy`
- `action.action.kill.term`
- `action.action.kill.k9`
- `verify.verify.domstate`
- `action.incident.end`

## 예시

```json
{"ts":"2026-02-12T19:15:00+09:00","scan_id":"20260212-191500-acde12","stage":"scan","event":"scan.start","result":"ok","details":{"policy":"default","dry_run":"1","config":"/etc/ablestack/ablestack-vm-hangctl.conf"}}
{"ts":"2026-02-12T19:15:00+09:00","scan_id":"20260212-191500-acde12","stage":"scan","event":"libvirtd.health","result":"ok","details":{"timeout_sec":"3"}}
{"ts":"2026-02-12T19:15:00+09:00","scan_id":"20260212-191500-acde12","stage":"scan","event":"scan.targets","result":"ok","details":{"running":"12"}}
{"ts":"2026-02-12T19:15:01+09:00","scan_id":"20260212-191500-acde12","stage":"detect","vm":"w22-01","event":"vm.domstate","result":"ok","details":{"domstate":"running","stuck_sec":"5","decision":"clear","confirm_window":"120"}}
{"ts":"2026-02-12T19:15:10+09:00","scan_id":"20260212-191500-acde12","stage":"detect","vm":"w22-01","event":"probe.qmp","result":"ok","details":{"timeout_sec":"5","status":"running"}}
{"ts":"2026-02-12T19:15:10+09:00","scan_id":"20260212-191500-acde12","stage":"detect","vm":"w22-01","event":"probe.qga","result":"fail","rc":1,"details":{"timeout_sec":"5","has_qga":"no","err_url":"..."}}
{"ts":"2026-02-12T19:15:10+09:00","scan_id":"20260212-191500-acde12","stage":"detect","vm":"w22-01","event":"vm.decision","result":"ok","details":{"final":"suspect","reason":"domstate_stuck","domstate":"running","stuck_sec":"130","confirm_window":"120","qmp_result":"ok","qmp_rc":"0","qmp_status":"running","has_qga":"no","qga_result":"fail","qga_rc":"1"}}
{"ts":"2026-02-12T19:15:00+09:00","scan_id":"20260212-191500-acde12","stage":"scan","event":"scan.end","result":"ok","details":{"policy":"default","dry_run":"1"}}
```

향후 커밋에서 VM별 사건(incident_id), 증적(evidence), 액션(action), libvirtd 재시작 등이 추가됩니다. 

---

## Commit 05 검증 가이드

### A) 정상 케이스
```bash
truncate -s 0 /var/log/ablestack-vm-hangctl/events.log || true
ablestack_vm_hangctl scan --dry-run
tail -n 10 /var/log/ablestack-vm-hangctl/events.log | jq -r '.event + " " + .result'
```

기대:

- scan.start ok
- libvirtd.health ok
- scan.target ok
- scan.end ok

### B) libvirtd 비정상 (테스트 방법)

일시ㅣ적으로 HANGCTL_VIRSH_TIMEOUT_SEC=0.001 같은 극단값을 config에 넣고 실행하면 timeout을 유발할 수 있습니다. 
그 경우:

- libvirtd.health timeout (또는 fail)
- scan.end warn (branch=libvirtd_unhealthy)
- 이후 scan.targets는 발생하지 않아야 합니다. 

---

### 구현 메모(운영 안정성)
- Circuit breaker 실패 시 VM probe를 더 하지 말고 즉시 종료합니다.
- 다음 Commit 10에서 libvirtd 재시작 로직이 불가 전까지는, 여기서는 "조용히 warn 종료"가 안전합니다. 

---

## Commit 07 적용 후 빠른 검증 포인트(명령)

1) `confirm_window`를 임시로 작게 해서 `suspect`를 만들고 probe가 실제로 찍히는지 확인:
```bash
sudo sed -i 's/^HANGCTL_CONFIRM_WINDOW_SEC=.*/HANGCTL_CONFIRM_WINDOW_SEC="3"/' /etc/ablestack/ablestack-vm-hangctl.conf
sudo rm -rf /run/ablestack-vm-hangctl/state && sudo mkdir -p /run/ablestack-vm-hangctl/state
sudo truncate -s 0 /var/log/ablestack-vm-hangctl/events.log || true

ablestack_vm_hangctl scan --dry-run
sleep 4
ablestack_vm_hangctl scan --dry-run

sudo jq -r 'select(.event=="probe.qmp" or .event=="probe.qga" or .event=="vm.decision") | .event + " " + .result + " vm=" + (.vm//"")' \
  /var/log/ablestack-vm-hangctl/events.log | head -n 30
```

2) 확인 후 confirm_window 원복:

```
sudo sed -i 's/^HANGCTL_CONFIRM_WINDOW_SEC=.*/HANGCTL_CONFIRM_WINDOW_SEC="120"/' /etc/ablestack/ablestack-vm-hangctl.conf
```

## Commit 08 action/verify 예시(개략):

```
json +{"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"action","event":"incident.start","result":"ok","details":{"reason":"qmp_timeout","dry_run":"0"}} {"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"action","event":"action.destroy","result":"fail","rc":124,"details":{"timeout_sec":"3","err_url":"..."}} {"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"action","event":"action.kill.term","result":"ok","details":{"pids":"1234"}} +{"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"verify","event":"verify.domstate","result":"ok","details":{"domstate":"shut off"}} +{"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"action","event":"incident.end","result":"ok","details":{"result":"stopped"}} +
```

향후 커밋에서 VM별 증적(evidence) 확장, libvirtd 재시작 등이 추가됩니다.

---

## 구현 주의사항(운영 관점)
- `hangctl_find_qemu_pids()`는 libvirt qemu argv에 포함되는 `-name guest=<VM>` 패턴 기반 **best-effort**입니다. (Commit 09에서 `/proc/<pid>/cmdline` 추가 검증 등으로 더 견고화 가능)
- `verify.domstate`는 **domstate 조회 실패도 “도메인 소멸”로 간주하여 stopped 처리**합니다(실무에서 안전한 방향).
