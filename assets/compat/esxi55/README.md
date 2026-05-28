# ESXi 5.5 Compatibility Assets

This directory contains the profile-local assets for the strict `esxi55`
compatibility profile.

The role split for this profile is deliberate:

- VDDK is operator-provided because VMware/Broadcom authentication and license
  acceptance are required.
- `govc` and pyVmomi dependencies are public assets and should be staged here
  with the repository assets.

```text
assets/compat/esxi55/
  govc_Linux_x86_64.tar.gz
  VMware-vix-disklib-6.0.2-3566099.x86_64.tar.gz
  nbdkit-vddk-legacy-1.14.2-rocky9-x86_64.tar.gz
  wheels/
    pyvmomi-5.5.0.2014.1.1.tar.gz
    six-*.whl
    requests-*.whl
    urllib3-*.whl
    idna-*.whl
    certifi-*.whl
    charset_normalizer-*.whl
```

The installer intentionally does not fall back to top-level `govc`, VDDK,
legacy nbdkit, or wheel assets for this profile. Newer VDDK releases can fail
against ESXi 5.5 NFC sessions, while the system nbdkit VDDK plugin can reject
VDDK 6.0.2 at load time, so missing profile-local assets are treated as an
installation error.

The VDDK archive is operator-provided. The currently staged and validated
candidate is `VMware-vix-disklib-6.0.2-3566099.x86_64.tar.gz`.

The legacy nbdkit archive is public redistributable runtime support built from
nbdkit 1.14.2. It is used only by the `esxi55` profile and is invoked with the
profile-local `nbdkit-vddk-plugin.so` absolute path.
