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
