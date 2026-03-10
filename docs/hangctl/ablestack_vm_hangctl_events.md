# ablestack_vm_hangctl - Events (JSONL)

`ablestack_vm_hangctl`의 운영/감사/분석을 위해 **append-only JSONL 이벤트 로그**를 기록합니다.

- 기본 경로: `/var/log/ablestack-vm-hangctl/events.log`
- 포맷: 1라인 = 1 JSON 객체 (JSONL)

## 스키마(고정)

모든 이벤트는 다음과 같은 공통 필드를 가집니다.

| Field | Type | Required | Description |
|---|---:|:---:|---|
| ts | string | Y | ISO8601 (+TZ) |
| scan_id | string | Y | 스캔 실행 시위 식별자 |
| incident_id | string | N | VM Hang 사건 시위 식별자 |
| vm | string | N | VM 이름 |
| stage | string | Y | scan/detect/confirm/evidence/action/libvirtd/verify/done/error |
| event | string | Y | 이벤트명(체계 내 고유) |
| result | string | Y | ok/fail/timeout/skip/warn |
| rc | number | N | 커맨드 실행 결과 코드 |
| elapsed_ms | number | N | 실행 시간(ms) |
| details | object | N | 추가 정보(선택) |

## Commit 03 범위

Commit 03에서 스캔 라이프사이클 이벤트만 기록합니다.

- `scan.scan.start`
- `scan.scan.end`

Commit 05에서 circuit breaker / 대상 VM 수집 이벤트들을 추가합니다.

- `scan.libvirtd.health`
- `scan.scan.targets`

Commit 06에서 domstate 기반 전체(stuck) 계산 이벤트들을 추가합니다.

- `detect.vm.domstate`

Commit 07에서 probe(특정 시도) 이벤트와 최종 결정 이벤트들을 추가합니다.

- `detect.probe.qmp`
- `detect.probe.qga`
- `detect.vm.decision`

Commit 08에서 confirmed VM들의 조치/사후 검증 이벤트들을 추가합니다.

- `action.incident.start`
- `action.action.destroy`
- `action.action.kill.term`
- `action.action.kill.k9`
- `verify.verify.domstate`
- `action.incident.end`

## ?�시

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

?�후 커밋?�서 VM�??�건(incident_id), 증적(evidence), ?�션(action), libvirtd ?�시???�이 추�??�니?? 

---

## Commit 05 검�?가?�드

### A) ?�상 케?�스
```bash
truncate -s 0 /var/log/ablestack-vm-hangctl/events.log || true
ablestack_vm_hangctl scan --dry-run
tail -n 10 /var/log/ablestack-vm-hangctl/events.log | jq -r '.event + " " + .result'
```

기�?:

- scan.start ok
- libvirtd.health ok
- scan.target ok
- scan.end ok

### B) libvirtd 비정??(?�스??방법)

?�시?�적?�로 HANGCTL_VIRSH_TIMEOUT_SEC=0.001 같�? 극단값을 config???�고 ?�행?�면 timeout???�발?????�습?�다. 
�?경우:

- libvirtd.health timeout (?�는 fail)
- scan.end warn (branch=libvirtd_unhealthy)
- ?�후 scan.targets??발생?��? ?�아???�니?? 

---

### 구현 메모(?�영 ?�정??
- Circuit breaker ?�패 ??VM probe�????��? 말고 즉시 종료?�니??
- ?�음 Commit 10?�서 libvirtd ?�시??로직??불�? ?�까지?? ?�기?�는 "조용??warn 종료"가 ?�전?�니?? 

---

## Commit 07 ?�용 ??빠른 검�??�인??명령)

1) `confirm_window`�??�시�??�게 ?�서 `suspect`�?만들�?probe가 ?�제�?찍히?��? ?�인:
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

2) ?�인 ??confirm_window ?�복:

```
sudo sed -i 's/^HANGCTL_CONFIRM_WINDOW_SEC=.*/HANGCTL_CONFIRM_WINDOW_SEC="120"/' /etc/ablestack/ablestack-vm-hangctl.conf
```

## Commit 08 action/verify ?�시(개략):

```
json +{"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"action","event":"incident.start","result":"ok","details":{"reason":"qmp_timeout","dry_run":"0"}} {"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"action","event":"action.destroy","result":"fail","rc":124,"details":{"timeout_sec":"3","err_url":"..."}} {"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"action","event":"action.kill.term","result":"ok","details":{"pids":"1234"}} +{"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"verify","event":"verify.domstate","result":"ok","details":{"domstate":"shut off"}} +{"ts":"...","scan_id":"...","incident_id":"...","vm":"w22-01","stage":"action","event":"incident.end","result":"ok","details":{"result":"stopped"}} +
```

?�후 커밋?�서 VM�?증적(evidence) ?�장, libvirtd ?�시???�이 추�??�니??

---

## 구현 주의?�항(?�영 관??
- `hangctl_find_qemu_pids()`??libvirt qemu argv???�함?�는 `-name guest=<VM>` ?�턴 기반 **best-effort**?�니?? (Commit 09?�서 `/proc/<pid>/cmdline` 추�? 검�??�으�???견고??가??
- `verify.domstate`??**domstate 조회 ?�패???�도메인 ?�멸?�로 간주?�여 stopped 처리**?�니???�무?�서 ?�전??방향).
