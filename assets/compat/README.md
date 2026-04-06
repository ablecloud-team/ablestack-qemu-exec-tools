# V2K Compatibility Asset Layout

This directory is used to pre-stage profile-specific VMware runtime assets before installation.

## Goal

Allow `bin/v2k_test_install.sh` to install different `govc`, `VDDK`, and `pyVmomi` inputs per compatibility profile without editing the installer script.

## Directory Layout

For each profile, place assets under:

```text
assets/
  compat/
    vsphere60/
      govc_Linux_x86_64.tar.gz
      VMware-vix-disklib-<version>.tar.gz
      wheels/
        pyvmomi-*.whl
        six-*.whl
        ...
    vsphere67/
      govc_Linux_x86_64.tar.gz
      VMware-vix-disklib-<version>.tar.gz
      wheels/
        *.whl
    vsphere80/
      govc_Linux_x86_64.tar.gz
      VMware-vix-disklib-<version>.tar.gz
      wheels/
        *.whl
```

## Installer Lookup Rules

For each selected profile, `bin/v2k_test_install.sh` resolves assets in this order.

### govc

1. `assets/compat/<profile>/govc_Linux_x86_64.tar.gz`
2. `assets/govc_Linux_x86_64.tar.gz`

### VDDK

1. `assets/compat/<profile>/VMware-vix-disklib-*.tar.gz`
2. `assets/VMware-vix-disklib-*.tar.gz`

### pyVmomi wheels

1. `--offline-wheel-dir <path>`
2. `assets/compat/<profile>/wheels/`
3. `assets/v2k/wheels/`

## Recommended Staging Policy

- Put version-sensitive assets in `assets/compat/<profile>/...`
- Keep `assets/...` top-level only for a default fallback set
- Treat `assets/compat/vsphere60` as the legacy toolchain bucket
- Treat `assets/compat/vsphere67` as the mid-generation toolchain bucket
- Treat `assets/compat/vsphere80` as the modern/default toolchain bucket

## Example

```text
assets/
  compat/
    vsphere60/
      govc_Linux_x86_64.tar.gz
      VMware-vix-disklib-6.7.3.tar.gz
      wheels/
        pyvmomi-6.7.3-*.whl
    vsphere67/
      govc_Linux_x86_64.tar.gz
      VMware-vix-disklib-7.0.3.tar.gz
      wheels/
        pyvmomi-7.0.3-*.whl
    vsphere80/
      govc_Linux_x86_64.tar.gz
      VMware-vix-disklib-8.0.2.tar.gz
      wheels/
        pyvmomi-8.0.3.0.1-*.whl
```

## Validation

Before installing, inspect which assets the installer sees:

```bash
bin/v2k_test_install.sh --list-profiles
```

The output shows, for each profile:

- detected `govc_asset`
- detected `vddk_asset`
- detected `wheel_dir`

## Notes

- The installer does not rename assets; keep the expected filenames.
- Only text files should be added here manually in Git. Large binary SDKs may be stored outside Git depending on repository policy.
- Real host installs should prefer `--install-assets --install-profile <id|all>`.
