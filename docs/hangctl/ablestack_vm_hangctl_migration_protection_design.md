# ABLESTACK VM Hangctl Migration Protection Design

## Background

`ablestack_vm_hangctl` currently has a migration protection path, but it is not
strong enough for long-running live migrations.

The current flow has these weaknesses:

- A VM is treated as migrating only when `virsh domstate --reason` contains
  `migration`.
- `virsh domjobinfo` is used for backup/job detection, but active migration jobs
  are not classified separately before the generic backup path.
- `HANGCTL_MIGRATION_PROGRESS_CHECK_SEC` is defined but not used for migration
  zombie decisions.
- Migration progress is parsed from `Data processed` or `Memory processed`
  without unit normalization, so values such as `47.235 MiB` are not reliable
  inputs for shell integer arithmetic.
- A long-running live migration can therefore reach the confirmed action path
  and be destroyed even when the migration is still active.

The protection policy must be conservative: an active migration should be
protected unless hangctl has clear evidence that the migration job is present
but has made no progress for the configured grace period.

## Goals

- Detect active live migration from both `domstate --reason` and `domjobinfo`.
- Use `HANGCTL_MIGRATION_PROGRESS_CHECK_SEC` as the no-progress grace window.
- Keep `HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC` as the wider confirmation window
  before destructive action is allowed.
- Treat progress parsing failures as protected active migration when a
  migration job is visible.
- Avoid classifying migration jobs as generic backup/block jobs.
- Add smoke tests that do not require a real libvirt migration.

## Non-Goals

- Do not change the default destructive action behavior for non-migration hangs.
- Do not replace hangctl's existing evidence, dump, storage guard, or libvirtd
  health-check behavior.
- Do not require new binary dependencies.

## Proposed Decision Flow

For each VM scan:

1. Collect QMP status, blockstats, `domstate --reason`, and `domjobinfo`.
2. Classify `domjobinfo` before choosing the confirmation window.
3. If active migration is detected:
   - Parse a progress metric in bytes.
   - If the metric increased, update `migration_last_progress_ts` and protect.
   - If the metric cannot be parsed, protect.
   - If the metric did not increase, compare the current time with
     `migration_last_progress_ts`.
   - Confirm `migration_zombie_no_progress` only when both of these are true:
     - `last_progress_age_sec >= HANGCTL_MIGRATION_PROGRESS_CHECK_SEC`
     - `duration_sec >= HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC`
4. If active migration is not detected, continue through the existing hangctl
   non-migration decision logic.

This keeps short no-progress windows safe while still allowing hangctl to act on
real zombie migration jobs after the configured confirmation period.

## Migration Classification

Add a helper in `lib/hangctl/detect.sh`:

```bash
hangctl_classify_domjobinfo <domjobinfo_text> <out_job_type> <out_operation> <out_is_migration> <out_is_backup>
```

`out_is_migration=1` when any of these are true:

- `domstate --reason` contains `migration`.
- `domjobinfo` contains an `Operation:` value with `migration`.
- `domjobinfo` contains migration-specific progress fields such as
  `Memory processed`, `Memory remaining`, or `Memory total`.

`out_is_backup=1` should be reserved for non-migration active jobs. A non-`None`
job must not automatically become backup if it is classified as migration.

## Progress Metric

Add a size parser in `lib/hangctl/detect.sh`:

```bash
hangctl_parse_size_to_bytes <value> <unit>
```

Supported examples:

- `1024 bytes`
- `47.235 MiB`
- `2.1 GiB`
- `1 TB`

The preferred progress metric order is:

1. `Data processed`
2. `Memory processed`
3. `Memory remaining` as an inverse metric, where a decrease means progress

If no metric can be parsed from an active migration job, the result must be
`protect_unknown_progress`, not `confirmed`.

## State Cache Format

Replace the single numeric `<vm>.state.migrate` payload with key-value fields.
The existing file path can remain the same to limit blast radius.

```text
migration_metric_bytes=123456789
migration_metric_kind=data_processed
migration_last_progress_ts=1780000000
migration_last_seen_ts=1780000030
migration_job_type=Unbounded
migration_operation=Migration Out
```

Required helpers in `lib/hangctl/state_cache.sh`:

```bash
hangctl_state_get_migration_kv <vm> <key>
hangctl_state_set_migration_kv_all <vm> key=value ...
hangctl_state_reset_migration <vm>
```

Backward compatibility:

- If the old file contains only a number, treat it as the previous
  `migration_metric_bytes`.
- Rewrite the file in key-value format on the next active migration scan.

## Zombie Evaluation API

Replace the current boolean-only migration zombie function with a richer helper:

```bash
hangctl_probe_migration_progress_evaluate \
  <vm> \
  <domjobinfo_text> \
  <duration_sec> \
  <out_status_var> \
  <out_detail_var>
```

Status values:

- `progressing`
- `no_progress_within_grace`
- `zombie_no_progress`
- `protect_unknown_progress`
- `not_migration`

The caller maps these statuses as follows:

- `progressing`, `no_progress_within_grace`, `protect_unknown_progress`:
  return without action.
- `zombie_no_progress`: continue to confirmed decision with
  `migration_zombie_no_progress`.
- `not_migration`: continue existing non-migration logic.

## Logging

Add structured details to the existing JSONL events.

Progressing:

```text
event=vm.migration_check
status=progressing
metric_kind=data_processed
metric_bytes=123456789
delta_bytes=10485760
last_progress_age_sec=0
note=protecting_active_migration
```

No progress but still protected:

```text
event=vm.migration_check
status=no_progress_within_grace
metric_kind=data_processed
metric_bytes=123456789
last_progress_age_sec=180
progress_window_sec=300
note=protecting_active_migration
```

Confirmed zombie:

```text
event=vm.decision
final=confirmed
reason=migration_zombie_no_progress
last_progress_age_sec=3900
progress_window_sec=300
confirm_window_sec=3600
```

Unknown progress:

```text
event=vm.migration_check
status=protect_unknown_progress
reason=metric_parse_failed
note=protecting_active_migration
```

## Test Plan

Add a shell smoke test under `tests/`, for example:

```text
tests/hangctl_migration_protection_smoke.sh
```

Suggested cases:

- `domstate="paused (in-migration)"` and progress increases: no action.
- `domstate="running"` with `domjobinfo Operation: Migration Out`: no action.
- Active migration with unparsable progress: no action.
- Active migration with no progress for less than
  `HANGCTL_MIGRATION_PROGRESS_CHECK_SEC`: no action.
- Active migration with no progress beyond
  `HANGCTL_MIGRATION_PROGRESS_CHECK_SEC` but before
  `HANGCTL_MIGRATION_CONFIRM_WINDOW_SEC`: no action.
- Active migration with no progress beyond both windows:
  `migration_zombie_no_progress`.
- Non-migration active backup/block job: keep existing backup policy.

Run:

```bash
bash -n bin/ablestack_vm_hangctl.sh lib/hangctl/*.sh
bash tests/hangctl_migration_protection_smoke.sh
```
