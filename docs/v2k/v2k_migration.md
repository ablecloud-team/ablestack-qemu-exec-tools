# ablestack_v2k

`ablestack_v2k`는 VMware 기반 가상머신을 **ABLESTACK(KVM/libvirt)** 환경으로
**CBT(Change Block Tracking)** 기반 최소 중단 방식으로 이전하기 위한 CLI 도구입니다.

## 주요 특징

- VMware CBT 기반 base / incremental / final 동기화
- qcow2 / raw(file) / raw(block, rbd) 대상 지원
- Ceph RBD 대상은 호스트에서 `rbd map` 후 block device로 처리
- 단계별 자동 실행 및 `run(auto)` 기반 전면 자동화
- split-run (phase1 / phase2) 구조 지원
- WinPE 기반 Windows 부트스트랩 자동화
- manifest / events.log 기반 재개(resume)

## Repository Layout

```
ablestack_v2k.sh        CLI entrypoint
engine.sh               Step execution engine
orchestrator.sh         run/auto pipeline orchestration
manifest.sh             Manifest lifecycle management
logging.sh              events.log writer
vmware_govc.sh          VMware(govc) integration
nbd_utils.sh            nbdkit/VDDK helpers
target_libvirt.sh       KVM/libvirt target handling
v2k_target_device.sh    Storage mapping logic
completions/            Bash completion
docs/                   Documentation
```

## Quick Start

```bash
ablestack_v2k run \
  --vm myvm \
  --vcenter vc.example.com \
  --dst /var/lib/libvirt/images/myvm \
  --target-format qcow2 \
  --target-storage file
```

## Supported Storage Types

| Format | Storage | Description |
|-------|---------|-------------|
| qcow2 | file | Default file-based qcow2 image |
| raw | file | Raw image file |
| raw | block | Direct block device |
| raw | rbd | Ceph RBD (`rbd map` → `/dev/rbd/<pool>/<image>`) |

## RBD 처리 방식

`target-storage=rbd`는 libvirt의 network disk가 아니라 **호스트에서 `rbd map`으로 생성한 block device**로 처리합니다.

- 입력 매핑은 `rbd:pool/image` 형식을 사용
- sync / bootstrap 단계에서는 작업 시점에 map 후 사용
- cutover 직전에는 persistent map을 만들고 libvirt XML에 block disk로 반영
- libvirt XML은 `<disk type='block'>`와 `/dev/rbd/<pool>/<image>` 경로를 사용
- Ceph 연결 정보는 별도 manifest 필드를 만들지 않고, 호스트의 로컬 `ceph.conf` / keyring 설정을 사용

## Cutover 시 RBD 동작

RBD cutover는 qcow2와 동일한 상위 시퀀스를 유지합니다.

1. shutdown
2. final snapshot
3. final sync
4. linux bootstrap
5. libvirt define / start

차이점은 대상 디스크 처리 방식만 다릅니다.

- qcow2/file: 파일 이미지 기반
- rbd: host-side mapped block device 기반

cutover 직전 map된 RBD 경로는 `manifest.runtime.rbd.mapped[*].dev_path`에 기록되며, libvirt define 시 이 값을 우선 사용합니다.

## License

Apache License 2.0
