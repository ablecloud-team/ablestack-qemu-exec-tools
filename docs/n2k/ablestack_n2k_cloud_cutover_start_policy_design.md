# ABLESTACK-N2K Cloud Cutover Start Policy and Release Checkout Design

## Background

Cloud-managed N2K migrations use the same engine as the CLI wizard, but the Cloud agent wrapper previously forced Cloud target cutover to pass `--start`. The CLI already distinguishes the two target policies:

- `--apply`: deploy/import the target VM and leave it stopped.
- `--apply --start`: deploy/import the target VM and start it after cutover.

This means a user can already request a stopped target VM from direct CLI or wizard mode, but the Cloud UI/API path could not express that preference.

The release workflow also had inconsistent checkout behavior during tag-triggered release builds. The release job checked out `workflow_run.head_sha`, while build jobs used the default checkout ref. If the default branch differs from the tag commit, generated artifacts can be built from a different commit than the release metadata.

## Design

### Cloud cutover policy

The Cloud API owns the user-facing choice and passes it to the host command as a boolean start policy. The KVM wrapper maps it to the engine flags:

- `starttargetvm=true`: pass `--start` and keep the current default behavior.
- `starttargetvm=false`: pass `--apply` only, so Cloud creates the target VM but leaves it stopped.

CLI and wizard behavior remains unchanged. Existing wizard users can keep using `--apply` or `--start` directly.

### Release workflow checkout policy

All build jobs and the release job must check out the same source ref:

- `workflow_run`: use `github.event.workflow_run.head_sha`.
- `workflow_dispatch`: use `github.ref`.

The final GitHub Release must also publish with `target_commitish` equal to the resolved checked-out commit.

## Compatibility

- Default behavior remains start-after-cutover for existing Cloud API/UI users.
- Direct CLI and wizard mode keep their current semantics.
- No database schema change is required.
