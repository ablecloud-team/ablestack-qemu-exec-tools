# AbleStack CloudInit Automator (Windows MSI)

This directory contains the WiX v4 project to build a Windows MSI that
installs an **unattended Phase1/Phase2 runner**, resilient to shell termination
and safe for automated imaging workflows.

## Directory layout

```text
windows/
  msi/
    Product.wxs                 # WiX v4 product definition (features, dirs, registry, scheduled task)
    build-msi.bat               # One-shot build using WiX v4 on Windows cmd
    build-msi.ps1               # PowerShell build script (WiX v4)
    SourceDir/
      phase-runner.ps1          # Phase orchestrator (SYSTEM), auto-resume, logs, Sysprep optional
      assets/
        cloudbase-init.conf             # (copied from repo/uploads) deployed alongside
        cloudbase-init-unattend.conf    # (copied from repo/uploads)
        unattend-server2025.xml         # (copied from repo/uploads)
        unattend-windows11.xml          # (copied from repo/uploads)
        install_cloudbase_init.ps1      # (copied from repo/uploads)
```

## What gets installed

- `C:\Program Files\AbleStack\CloudInit\phase-runner.ps1`
- Optional assets under the same folder (reference configs/scripts)
- Registry seed: `HKLM\SOFTWARE\AbleStack\CloudInit\Phase = "1"`
- Scheduled Task: **AbleStack-CloudInit-PhaseRunner**
  - Triggers: Boot + Logon (30s delay)
  - Runs as `SYSTEM`
  - Command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "phase-runner.ps1" -SysprepAfterPhase2`

Logs are written to `C:\ProgramData\AbleStack\CloudInit\Logs\phase-runner_*.log`

## Build

1. Install **WiX Toolset v4**.
2. From `windows\msi` run one of:
   - `build-msi.bat`
   - `pwsh -File .\build-msi.ps1 -WixBin "C:\Program Files\WiX Toolset v4.0\bin"`

Output: `windows\msi\out\AbleStack-CloudInit-Automator.msi`

## Customize Phase1/Phase2

Edit `SourceDir\phase-runner.ps1`:
- `Invoke-Phase1`: pre-clean, Appx removal, prerequisites, then sets Phase=2 and requests reboot.
- `Invoke-Phase2`: post-config steps; on success sets Phase=Done and (optionally) runs Sysprep.
- Both phases are **idempotent** and **heavily logged**.

## Integrating Cloudbase-Init

If you want the MSI to **configure/install Cloudbase-Init** in-line, either:
- Embed your Cloudbase-Init MSI as another `File` in `Product.wxs` and add a CustomAction, **or**
- Keep using `assets\install_cloudbase_init.ps1` from `phase-runner.ps1`.

This repository version keeps the MSI **agnostic** and only ships reference assets.