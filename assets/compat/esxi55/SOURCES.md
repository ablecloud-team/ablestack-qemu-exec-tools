# ESXi 5.5 Public Asset Sources

These assets are public and may be staged in Git or release assets according to
the repository's binary asset policy.

| Asset | Source | Selected version | Role |
| --- | --- | --- | --- |
| `govc_Linux_x86_64.tar.gz` | `https://github.com/vmware/govmomi/releases/download/v0.46.3/govc_Linux_x86_64.tar.gz` | `govc 0.46.3` | vSphere inventory, snapshot, power, and host queries |
| `nbdkit-vddk-legacy-1.14.2-rocky9-x86_64.tar.gz` | `https://download.libguestfs.org/nbdkit/1.14-stable/nbdkit-1.14.2.tar.gz` | `nbdkit 1.14.2` | Profile-local VDDK plugin runtime that can load VDDK 6.0.2 |
| `wheels/pyvmomi-5.5.0.2014.1.1.tar.gz` | PyPI package `pyvmomi==5.5.0.2014.1.1` | `5.5.0.2014.1.1` | Changed block tracking API calls |
| `wheels/*.whl` | PyPI dependency resolver output for pyVmomi 5.5 | current compatible releases | Offline installation dependencies |

The VDDK archive is intentionally not sourced from public package feeds. The
operator must download the ESXi 5.5-compatible VMware VDDK archive after
accepting VMware/Broadcom license terms and place it in this directory. The
current staged candidate is
`VMware-vix-disklib-6.0.2-3566099.x86_64.tar.gz`.
