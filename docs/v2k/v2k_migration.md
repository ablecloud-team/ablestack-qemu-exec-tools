# ablestack_v2k

`ablestack_v2k`는 VMware 기반 가상머신을 **ABLESTACK(KVM/libvirt)** 환경으로
**CBT(Change Block Tracking)** 기반 최소 중단 방식으로 이관하기 위한 CLI 도구입니다.

## 주요 특징

- VMware CBT 기반 base / incremental / final 동기화
- qcow2 / raw(file) / raw(block, rbd) 타겟 지원
- 단계별 수동 실행 및 `run(auto)` 기반 완전 자동화
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
| raw | rbd | Ceph RBD |

## License

Apache License 2.0
