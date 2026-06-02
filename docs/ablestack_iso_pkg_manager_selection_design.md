# ABLESTACK ISO package manager selection design

## Background

Newer ABLESTACK hosts may keep `dnf`, `yum`, or `rpm` commands on disk while blocking their direct use. Operators are expected to use `aspm` for package transactions and `aspkg` for RPM queries. The ISO installer already wrapped package operations, but it selected commands only by existence and preferred `dnf` before `aspm`.

That means an ABLESTACK host can print `dnf, yum usage is blocked` before the installer ever reaches the bundled V2K/N2K add-on install steps.

## Policy

- On ABLESTACK hosts, prefer `aspm` for RPM package manager operations when it exists.
- On ABLESTACK hosts, prefer `aspkg` for RPM query operations when it exists.
- On non-ABLESTACK RPM hosts, keep the existing native `dnf` and `rpm` preference.
- Keep the existing `dnf`/`rpm` fallback for ordinary Rocky, RHEL, CentOS, AlmaLinux, and Fedora systems.
- Apply the same command selection policy to both `install-linux.sh` and `uninstall-linux.sh`.

## Validation

The smoke test extracts the generated installer and uninstaller script bodies from the release workflow, then injects fake commands where `dnf` and `rpm` exist but are blocked. It verifies that ABLESTACK `PRETTY_NAME` selects `aspm` and `aspkg`, while a regular Rocky `PRETTY_NAME` still selects `dnf` and `rpm`.
