# v2k ESXi 5.5 VDDK 6.0.2 Legacy nbdkit Design

## Background

The `esxi55` compatibility profile intentionally uses VMware VDDK 6.0.2
because newer VDDK 6.5.x packages are no longer practically obtainable through
the current VMware/Broadcom download path.

The host system nbdkit VDDK plugin cannot be used with this VDDK. Runtime logs
from ESXi 5.5 validation showed that the system plugin fails before connecting
to vCenter or NFC:

```text
required VDDK symbol "VixDiskLib_Wait" is missing. VDDK version must be >= 6.5.
```

This means profile selection is working, but the selected VDDK is too old for
the installed system `nbdkit-vddk-plugin`.

## Decision

The `esxi55` profile must carry a profile-local legacy nbdkit runtime that can
load VDDK 6.0.2. The system nbdkit remains the default for other profiles.

The selected runtime layout is:

```text
/usr/share/ablestack/v2k/compat/esxi55/
  bin/govc
  venv/bin/python3
  vddk/
  nbdkit/
    bin/nbdkit
    lib/nbdkit/plugins/nbdkit-vddk-plugin.so
```

The legacy runtime asset is:

```text
assets/compat/esxi55/nbdkit-vddk-legacy-1.14.2-rocky9-x86_64.tar.gz
```

It contains nbdkit 1.14.2 server binary, `nbdkit-vddk-plugin.so`, and the
nbdkit license. It was built on Rocky Linux 9.7 x86_64 and verified with:

```bash
LD_LIBRARY_PATH=/path/to/vddk/lib64 \
  /path/to/nbdkit/bin/nbdkit \
  /path/to/nbdkit/lib/nbdkit/plugins/nbdkit-vddk-plugin.so \
  --dump-plugin libdir=/path/to/vddk
```

## Runtime Rules

When `esxi55` is active:

- `VDDK_LIBDIR` points to the profile-local VDDK 6.0.2 directory.
- `V2K_NBDKIT_BIN` points to the profile-local legacy nbdkit binary.
- `V2K_NBDKIT_VDDK_PLUGIN` points to the profile-local VDDK plugin `.so`.
- transfer code invokes the plugin by absolute path, not by the short name
  `vddk`, so the compiled default plugin directory in the legacy binary is not
  relevant.
- `LD_LIBRARY_PATH` includes both `VDDK_LIBDIR/lib64` and `VDDK_LIBDIR`.

Other profiles continue to use the system `nbdkit` and the short plugin name
`vddk`.

## Installer Validation

The installer must not stop at checking whether `libvixDiskLib.so` exists.
For real profile assets it must also prove that the selected nbdkit runtime can
load the selected VDDK:

```bash
LD_LIBRARY_PATH="${VDDK_LIBDIR}/lib64:${VDDK_LIBDIR}" \
  "${V2K_NBDKIT_BIN}" "${V2K_NBDKIT_VDDK_PLUGIN}" \
  --dump-plugin libdir="${VDDK_LIBDIR}"
```

This catches ABI mismatches during installation instead of failing later in
`sync.base`.

## Remaining Risk

Passing `--dump-plugin` proves local ABI compatibility only. It does not prove
that ESXi 5.5 NFC transfer succeeds in the target environment. After this
change, ESXi 5.5 validation must be rerun through at least base sync to confirm
that the original NFC error is resolved or to expose the next compatibility
issue.
