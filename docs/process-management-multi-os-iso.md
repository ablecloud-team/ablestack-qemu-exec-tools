# Multi-OS process Tools guest ISO

The `process-guest-isos.yml` GitHub Actions workflow builds four guest installation
media from one source commit: Rocky Linux 8/9/10, Ubuntu 22.04/24.04/26.04,
Debian 12/13, and Windows 11/Server 2019/2022/2025 (x86_64 only). Debian 11 is
excluded. Rocky guest evidence does not establish support for a RHEL guest; RHEL
requires its own signed packages and VM installation evidence.

The media are separate from the host package/release ISO. They contain the
process-management policy payload and matching offline QGA packages for each
Linux version. The Windows ISO contains the ABLESTACK Process Tools MSI, QGA
MSI, and the VirtIO driver MSI extracted from one vendor ISO. The build records
the source commit, Actions run ID, supported selectors, ISO SHA-256 values,
and the vendor ISO hash in the Windows payload manifest.

## Guest installation

1. Save the existing VM media attachment and guest service/package state.
2. Attach the matching ISO using the Cloud ISO management flow. On Linux,
   mount it and run `sudo bash /media/…/install-linux.sh` (or run it as root).
   On Windows, open an elevated prompt and run `install.bat` from the ISO.
3. The Linux entry point verifies every staged file against `SHA256SUMS`, the
   guest OS/version/architecture, and the ISO family. It installs missing QGA
   and Python/SELinux prerequisites from only the matching offline repository,
   then runs the existing policy installation. It does not contact external
   repositories or alter persistent APT/YUM sources.
4. The Windows entry point installs the vendor VirtIO driver MSI, QGA MSI, and
   ABLESTACK Process Tools MSI, then applies the QGA process policy. A `3010`
   result means reboot and rerun the entry point before declaring completion.
5. Verify the installer exit status, installed packages/files, QGA service and
   configuration before/after. Verify each actual guest version separately.
   A successful ISO attachment or installer message alone is insufficient.

This issue's installer PASS does not claim QGA RPC functionality, VirtIO device
functionality, or Cloud process actions. Those are separate Q6/C7 runtime gates.
Do not remove or overwrite a pre-existing attached ISO without recording it.

## Current test cluster

The twelve target VM links and their baseline observations are recorded in
[Qemu issue #79](https://github.com/ablecloud-team/ablestack-qemu-exec-tools/issues/79).
Some Linux VMs already have QGA. Use their actual state for repair/upgrade
evidence; collect fresh-install evidence only from a VM observed without QGA.
Windows driver installation may disrupt networking or require a reboot, so
preserve console access and verify recovery before proceeding to the next VM.
