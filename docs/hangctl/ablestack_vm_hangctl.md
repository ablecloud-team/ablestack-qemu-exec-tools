# ablestack_vm_hangctl

ABLESTACK 호스트(Rocky 9 기반)에서 **가상머신 Hang 상태 모니터링 및 자동 처리**를 수행하기 위한 도구입니다.

## 설치/파일

- CLI
  - `/usr/local/bin/ablestack_vm_hangctl`
- Config
  - `/etc/ablestack/ablestack-vm-hangctl.conf`
- Runtime
  - `/run/ablestack-vm-hangctl/`
- Logs
  - `/var/log/ablestack-vm-hangctl/events.log`

## Commit 02 기반 작동

현재 체계(Commit 02)에서 다음과 같이 제공합니다.

- config 파일 로드(`/etc/ablestack/ablestack-vm-hangctl.conf`)
- 필요한 디렉토리 자동 생성(`/run`, `/var/log`)
- `scan` 실행 시 scan lifecycle 이벤트(stub) 기록

## 사용 예

```bash
ablestack_vm_hangctl --help
ablestack_vm_hangctl scan --dry-run
ablestack_vm_hangctl scan --config /etc/ablestack/ablestack-vm-hangctl.conf
```

## 운영 안전 설계 문서

- VM live migration 보호 설계:
  `docs/hangctl/ablestack_vm_hangctl_migration_protection_design.md`
- HA 환경의 libvirtd 자동 재시작 보호 설계:
  `docs/hangctl/ablestack_vm_hangctl_libvirtd_ha_guard_design.md`

HA/Pacemaker 환경에서는 libvirtd health 실패가 곧바로 host-wide
`systemctl restart libvirtd.service`로 이어지면 CCVM failover, fencing,
`mold-agent.service`와 충돌할 수 있다. 따라서 libvirtd restart 경로는
cluster guard, restart backoff, 명시적 operator opt-in을 전제로 설계한다.
