# ABLESTACK VM Hangctl Libvirtd HA Guard Design

## 1. Background

`ablestack_vm_hangctl` has two independent protection paths.

- VM-level hang detection protects or acts on an individual domain.
- The libvirtd health gate runs before VM scanning and can restart the host-wide `libvirtd.service`.

The recent HA failure showed that the second path is too aggressive for Pacemaker-managed ABLESTACK hosts. During CCVM failover, `virsh -c qemu:///system list --name` did not return within the health timeout. The health gate counted two consecutive failures and restarted `libvirtd.service` while Pacemaker was trying to recover `cloudcenter_res`. This created a race with the CCVM start operation and also affected `mold-agent.service`.

This design keeps the existing VM migration protection behavior intact and adds a conservative HA-aware guard around host-wide libvirtd recovery.

## 2. Documents Checked For Consistency

- `docs/hangctl/ablestack_vm_hangctl.md`
  - Confirms the installed CLI/config/runtime/log paths.
  - The overview must describe libvirtd restart as a guarded recovery path, not as a default first response.
- `docs/hangctl/ablestack_vm_hangctl_migration_protection_design.md`
  - Covers VM-level active migration protection.
  - This design operates before VM scanning, where migration protection is not reached if the libvirtd health gate fails.
- `docs/hangctl/ablestack_vm_hangctl_events.md`
  - Defines JSONL result values and event naming style.
  - New guard events must keep the same `stage`, `event`, `result`, `rc`, and `details` structure.
- `rpm/ablestack_vm_hangctl.spec`
  - Fresh installs currently enable and start `ablestack-vm-hangctl.timer`.
  - HA hosts need safe defaults before timer activation.
- `etc/ablestack-vm-hangctl.conf`
  - The sample config is the operator-facing source of default behavior.
  - It must be corrected so migration and libvirtd recovery settings are explicit and sourceable.

## 3. Goals

- Prevent hangctl from restarting `libvirtd.service` during Pacemaker transitions, fencing, or `cloudcenter_res` operations.
- Treat libvirt API timeout differently from a stopped or missing libvirt daemon.
- Avoid repeated libvirtd restart attempts after an unsuccessful restart.
- Keep VM-level hang detection, evidence collection, dump, storage guard, and migration protection behavior unchanged.
- Make safe behavior visible through JSONL events.
- Keep dependencies limited to tools already present on ABLESTACK HA hosts: `systemctl`, `virsh`, `pcs`, `crm_mon`, `crm_node`, and `cibadmin`.

## 4. Non-Goals

- Do not implement a replacement for Pacemaker resource management.
- Do not restart, cleanup, or move `cloudcenter_res` from hangctl.
- Do not infer that every historical failed resource action means the cluster is currently busy.
- Do not remove the existing `health` command; it remains a check-only command.

## 5. Current Code Gaps

### 5.1 Config Path Ordering

`cmd_scan`, `cmd_check`, `cmd_act`, and `cmd_health` initialize defaults and load the default config before applying the `--config` path. As a result, `--config /path/to/file` changes `HANGCTL_CONFIG_PATH` for logging, but the pointed file is not sourced.

Required fix:

```bash
hangctl_config_init_defaults
[[ -n "${cfg}" ]] && HANGCTL_CONFIG_PATH="${cfg}"
hangctl_config_load_file "${HANGCTL_CONFIG_PATH}"
hangctl_config_apply_cli "" "${pol}" "${dry}"
```

The same helper should be shared by all commands to prevent future drift.

### 5.2 Timeout Classification

The health result helper currently treats `124` as timeout. In real logs, timeout-like failures were recorded as `143`, which can happen when `timeout --preserve-status` returns the terminated child status.

Required classification:

```text
0              -> ok
124, 137, 143 -> timeout
other          -> fail
```

### 5.3 Health Signal Is Too Narrow

The current health check relies on one command:

```bash
virsh -c qemu:///system list --name
```

That is a useful API probe, but it cannot distinguish these cases:

- libvirtd is inactive.
- the libvirt socket is missing.
- libvirtd is active but the API is temporarily blocked.
- Pacemaker/libvirt resource activity is creating short-lived contention.

## 6. Proposed Architecture

### 6.1 New Module

Add:

```text
lib/hangctl/cluster_guard.sh
```

Load it from `bin/ablestack_vm_hangctl.sh` before `libvirt_wrap.sh` restart decisions are used.

Main functions:

```bash
hangctl_cluster_guard_probe <stage> <out_decision_var> <out_reason_var> <out_detail_var>
hangctl_cluster_status_collect <out_text_var> <out_rc_var>
hangctl_cluster_status_is_busy <status_text> <out_reason_var> <out_detail_var>
hangctl_cluster_status_hash_settle_check <status_text> <out_reason_var> <out_detail_var>
```

Decision values:

| Decision | Meaning |
|---|---|
| `idle` | No HA activity that should block libvirtd recovery. |
| `busy` | Active cluster transition, fencing, or resource operation detected. |
| `settle` | Cluster status changed recently; wait before host-wide restart. |
| `unknown` | Cluster guard could not evaluate; default policy decides whether to fail closed. |
| `disabled` | Guard disabled by config. |

### 6.2 Cluster Busy Detection

Collect status in this order:

1. `crm_mon -1 -r -f`
2. `pcs status --full`

If neither exists, return `unknown`.

Treat these patterns as `busy`:

- `Fencing Actions:`
- `stonith`
- `pending`
- `unclean`
- `OFFLINE`
- `Starting`
- `Stopping`
- `Migrating`
- `cloudcenter_res_migrate`
- `cloudcenter_res_start`
- `cloudcenter_res_stop`
- `Actions:` followed by `cloudcenter_res`

Treat historical failure sections carefully. `Failed Resource Actions:` alone should not block forever, because the observed 22.x test cluster has an old failed migration record while currently stable. It should only block when paired with current transition, pending action, fencing, unclean node, or a very recent status change.

### 6.3 Cluster Settle Window

Store a hash of the collected cluster status in:

```text
${HANGCTL_STATE_DIR}/cluster.status.hash
${HANGCTL_STATE_DIR}/cluster.status.last_change_ts
```

If the hash changed within `HANGCTL_CLUSTER_GUARD_SETTLE_SEC`, return `settle`.

Default:

```bash
HANGCTL_CLUSTER_GUARD_SETTLE_SEC="600"
```

This catches membership changes and resource transitions even when the one-shot status text no longer shows a running action.

### 6.4 Libvirt Health Classification

Extend the health probe to produce both a result and a class.

```bash
hangctl_libvirtd_health_check_classified \
  <timeout_sec> \
  <out_result_var> \
  <out_class_var> \
  <out_detail_var> \
  <out_rc_var>
```

Classes:

| Class | Meaning | Restart Eligible By Default |
|---|---|---|
| `ok` | libvirt API responded. | N/A |
| `service_inactive` | `systemctl is-active libvirtd` is not active. | Yes, if cluster idle. |
| `socket_missing` | expected libvirt socket is missing. | Yes, if cluster idle. |
| `api_timeout` | service is active but virsh timed out. | No. |
| `command_fail` | virsh returned a non-timeout failure. | No. |
| `unknown` | probe could not classify. | No. |

`api_timeout` was the failure shape in the incident, so it must be conservative.

### 6.5 Restart Gate Flow

`hangctl_libvirtd_health_gate()` should use this order:

1. Run classified health check.
2. If healthy, reset fail count and return success.
3. Increment fail count and log health class.
4. If fail count is below threshold, return unhealthy without restart.
5. If restart is disabled or dry-run, skip.
6. If restart backoff is active, skip.
7. If health class is not restart eligible, skip unless explicitly allowed.
8. Run cluster guard.
9. If cluster guard is `busy` or `settle`, skip.
10. If cluster guard is `unknown`, skip by default.
11. If cooldown allows, call `hangctl_libvirtd_restart_safe`.
12. If post-restart verification fails, start long backoff.

Pseudocode:

```bash
if ! health_ok; then
  fc="$(hangctl_libvirtd_failcount_inc)"
  log libvirtd.health result class fail_count

  [[ "${fc}" -lt "${HANGCTL_LIBVIRTD_FAIL_THRESHOLD}" ]] && return 1
  [[ "${HANGCTL_LIBVIRTD_RESTART_ENABLED}" != "1" ]] && skip disabled
  [[ "${HANGCTL_DRY_RUN}" == "1" ]] && skip dry_run
  hangctl_libvirtd_restart_backoff_active && skip backoff
  hangctl_libvirtd_health_class_restart_eligible "${class}" || skip health_class

  hangctl_cluster_guard_probe "scan" guard reason detail
  case "${guard}" in
    idle|disabled) ;;
    busy|settle|unknown) skip "cluster_${guard}" ;;
  esac

  hangctl_libvirtd_restart_safe "scan"
fi
```

## 7. Config Additions

Recommended defaults for HA hosts:

```bash
HANGCTL_LIBVIRTD_RESTART_ENABLED="0"
HANGCTL_LIBVIRTD_HEALTH_TIMEOUT_SEC="10"
HANGCTL_LIBVIRTD_FAIL_THRESHOLD="5"
HANGCTL_LIBVIRTD_RESTART_COOLDOWN_SEC="1800"
HANGCTL_LIBVIRTD_RESTART_BACKOFF_SEC="3600"
HANGCTL_LIBVIRTD_RESTART_MAX_PER_HOUR="1"
HANGCTL_LIBVIRTD_RESTART_ON_API_TIMEOUT="0"

HANGCTL_CLUSTER_GUARD_ENABLE="1"
HANGCTL_CLUSTER_GUARD_FAIL_CLOSED="1"
HANGCTL_CLUSTER_GUARD_SETTLE_SEC="600"
HANGCTL_CLUSTER_GUARD_TIMEOUT_SEC="5"
HANGCTL_CLUSTER_GUARD_RESOURCE_REGEX="cloudcenter_res"
```

Non-HA or lab hosts can opt in to automatic recovery by setting:

```bash
HANGCTL_LIBVIRTD_RESTART_ENABLED="1"
HANGCTL_CLUSTER_GUARD_FAIL_CLOSED="0"
```

## 8. Event Contract

Add these events while keeping the existing JSONL schema.

Health with classification:

```json
{"stage":"scan","event":"libvirtd.health","result":"timeout","rc":143,"details":{"timeout_sec":"10","fail_count":"5","class":"api_timeout"}}
```

Cluster guard skip:

```json
{"stage":"scan","event":"libvirtd.restart.skip","result":"ok","details":{"reason":"cluster_busy","guard_reason":"fencing"}}
```

Cluster settle skip:

```json
{"stage":"scan","event":"libvirtd.restart.skip","result":"ok","details":{"reason":"cluster_settle","settle_sec":"600"}}
```

Health class skip:

```json
{"stage":"scan","event":"libvirtd.restart.skip","result":"ok","details":{"reason":"health_class","class":"api_timeout"}}
```

Backoff skip:

```json
{"stage":"scan","event":"libvirtd.restart.skip","result":"ok","details":{"reason":"backoff","remain":"3100"}}
```

## 9. Packaging and Timer Policy

The RPM currently enables and starts `ablestack-vm-hangctl.timer` on fresh install. That is risky if the installed config still allows host-wide libvirtd restart.

Preferred packaging change:

- Do not auto-start the timer on fresh install.
- Let the operator run `ablestack_vm_hangctl health --dry-run` and `scan --dry-run` first.
- Start the timer explicitly after preflight.

Compatibility alternative:

- Keep timer auto-start.
- Change defaults so host-wide libvirtd restart is disabled unless explicitly enabled.

The safer release default is the compatibility alternative plus a later packaging change, because it avoids surprising existing deployments while removing the dangerous action.

## 10. Test Server Preflight Notes

On the 22.x test cluster:

- `10.10.22.1`, `10.10.22.2`, and `10.10.22.3` have SSH on port 22.
- `ablestack_vm_hangctl-0.9.2-1.noarch` installed successfully on all three hosts.
- `ablestack-vm-hangctl.timer` was masked before install and remained `masked/inactive`.
- `libvirtd`, `mold-agent.service`, `pacemaker`, and `corosync` were active after install.
- `pcs`, `crm_mon`, `cibadmin`, and `crm_node` exist on all three hosts.
- `ablestack_vm_hangctl health --dry-run` returned `libvirtd.health: ok`.
- `scan --dry-run --vm ccvm` on the CCVM owner host detected CCVM as running and healthy.

Observed cluster detail:

- `cloudcenter_res` was started on `100.100.22.1`.
- The cluster had an old `Failed Resource Actions` entry. This confirms that the guard must not block forever on historical failure text alone.

## 11. Test Plan

Add smoke tests that mock command output instead of requiring a live cluster:

```text
tests/hangctl_libvirtd_health_classification_smoke.sh
tests/hangctl_cluster_guard_smoke.sh
tests/hangctl_libvirtd_restart_gate_smoke.sh
tests/hangctl_config_override_smoke.sh
tests/hangctl_config_sample_smoke.sh
```

Required cases:

- `rc=143` is classified as timeout.
- `api_timeout` does not restart by default.
- `service_inactive` can restart only when cluster guard is idle.
- fencing text blocks restart.
- active `cloudcenter_res` migration/start/stop text blocks restart.
- historical `Failed Resource Actions` without active transition does not block.
- cluster status hash change triggers settle skip.
- verify timeout sets long backoff.
- `--config` actually loads the provided file.
- sample config can be sourced and exposes migration progress settings.

Run:

```bash
bash -n bin/ablestack_vm_hangctl.sh lib/hangctl/*.sh
bash tests/hangctl_migration_protection_smoke.sh
bash tests/hangctl_libvirtd_health_classification_smoke.sh
bash tests/hangctl_cluster_guard_smoke.sh
bash tests/hangctl_libvirtd_restart_gate_smoke.sh
bash tests/hangctl_config_override_smoke.sh
bash tests/hangctl_config_sample_smoke.sh
```

## 12. Implementation Sequence

1. Fix config load ordering and add a smoke test for `--config`.
2. Fix sample config sourceability and add a smoke test.
3. Add timeout result classification for `124`, `137`, and `143`.
4. Add classified libvirt health probe.
5. Add `cluster_guard.sh` and mock-based tests.
6. Add restart backoff state helpers.
7. Wire the restart gate flow into `hangctl_libvirtd_health_gate`.
8. Update events documentation.
9. Build hangctl RPM and validate on 22.x hosts with timer masked and dry-run first.

## 13. Acceptance Criteria

- During Pacemaker transition, hangctl logs `libvirtd.restart.skip` with a cluster reason and does not run `systemctl restart libvirtd.service`.
- During `api_timeout` with active libvirtd, hangctl does not restart libvirtd by default.
- During inactive libvirtd on an idle non-transitioning cluster, restart can occur only when explicitly enabled.
- A failed post-restart verification prevents repeated restart attempts for the configured backoff window.
- `--config` uses the provided config file for real behavior, not only for log metadata.
- Fresh package defaults cannot restart host-wide libvirtd without an operator opt-in.
