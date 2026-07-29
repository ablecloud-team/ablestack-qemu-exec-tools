#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/n2k-manifest-observability.XXXXXX")"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

for cmd in bash jq sha256sum; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: ${cmd}" >&2
    exit 2
  }
done

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/n2k/manifest.sh"

definition_count="$(
  grep -c '^n2k_manifest_mark_split_done()' \
    "${ROOT_DIR}/lib/n2k/manifest.sh"
)"
[[ "${definition_count}" -eq 1 ]] || {
  echo "[ERR] split completion helper must have exactly one definition" >&2
  exit 1
}

complete_calls="$(
  grep -c '^[[:space:]]*n2k_manifest_complete_patch_phase' \
    "${ROOT_DIR}/lib/n2k/transfer_patch.sh" || true
)"
[[ "${complete_calls}" -eq 1 ]] || {
  echo "[ERR] patch rounds must use one atomic completion call" >&2
  exit 1
}

legacy_patch_calls="$(
  grep -c '^[[:space:]]*n2k_manifest_mark_patch_done' \
    "${ROOT_DIR}/lib/n2k/transfer_patch.sh" || true
)"
[[ "${legacy_patch_calls}" -eq 0 ]] || {
  echo "[ERR] transfer path still commits per-disk patch state" >&2
  exit 1
}

legacy_success_helpers="$(
  grep -Ec \
    '^n2k_manifest_(mark_patch_done|record_sync_summary)\(\)' \
    "${ROOT_DIR}/lib/n2k/manifest.sh" || true
)"
[[ "${legacy_success_helpers}" -eq 0 ]] || {
  echo "[ERR] legacy multi-write patch completion helpers still exist" >&2
  exit 1
}

manifest="${WORK_DIR}/manifest.json"
cat >"${manifest}" <<'JSON'
{
  "schema": "ablestack-n2k/manifest-v1",
  "run": {
    "run_id": "observability-smoke",
    "workdir": "/tmp/observability-smoke"
  },
  "source": {
    "type": "nutanix",
    "mode": "v3-incremental",
    "pc": "pc.example",
    "vm": {"name": "observability-smoke"}
  },
  "target": {
    "type": "kvm",
    "format": "raw",
    "dst_root": "/target",
    "storage": {"type": "file"}
  },
  "phases": {
    "init": {"done": true, "ts": "2026-07-29T10:00:00+09:00"},
    "preflight": {"done": true, "ts": "2026-07-29T10:01:00+09:00"},
    "plan": {"done": true, "ts": "2026-07-29T10:02:00+09:00"},
    "base_sync": {"done": false, "ts": ""},
    "incr_sync": {"done": false, "ts": ""},
    "final_sync": {"done": false, "ts": ""},
    "cutover": {"done": false, "ts": ""},
    "cleanup": {"done": false, "ts": ""}
  },
  "runtime": {
    "selected_mode": "v3-incremental",
    "split": {
      "phase1": {"done": false, "ts": ""},
      "phase2": {"done": false, "ts": ""}
    },
    "sync": {
      "mode": "incremental",
      "round": 0,
      "last_changed_bytes": 0,
      "last_region_count": 0,
      "final_ready": false
    },
    "progress": {"percent": 0, "last_step": "plan"},
    "cleanup": {"items": []},
    "sync_issues": [],
    "last_error": {"code": 0, "reason": "", "ts": ""}
  },
  "disks": [
    {
      "disk_id": "disk-0",
      "size_bytes": 1048576,
      "transfer": {
        "target_path": "/target/disk-0.raw",
        "base_done": false,
        "incr_seq": 0,
        "last_synced_at": "",
        "last_sync": null,
        "last_error": null
      },
      "metrics": {
        "base_bytes_written": 0,
        "incr_bytes_written": 0,
        "incr_regions": 0
      },
      "recovery_points": {
        "base": {"id": ""},
        "incr": {"id": ""},
        "final": {"id": ""}
      }
    },
    {
      "disk_id": "disk-1",
      "size_bytes": 2097152,
      "transfer": {
        "target_path": "/target/disk-1.raw",
        "base_done": false,
        "incr_seq": 0,
        "last_synced_at": "",
        "last_sync": null,
        "last_error": null
      },
      "metrics": {
        "base_bytes_written": 0,
        "incr_bytes_written": 0,
        "incr_regions": 0
      },
      "recovery_points": {
        "base": {"id": ""},
        "incr": {"id": ""},
        "final": {"id": ""}
      }
    }
  ]
}
JSON

now_value="2026-07-29T11:00:00+09:00"
n2k_now_iso() {
  printf '%s\n' "${now_value}"
}

n2k_manifest_mark_split_done "${manifest}" "phase1"
now_value="2026-07-29T11:05:00+09:00"
n2k_manifest_mark_split_done "${manifest}" "phase1"
jq -e '
  .runtime.split.phase1 == {
    done: true,
    ts: "2026-07-29T11:00:00+09:00"
  }
  and .runtime.progress.last_step == "phase1_done"
' "${manifest}" >/dev/null || {
  echo "[ERR] repeated split completion changed its original timestamp" >&2
  cat "${manifest}" >&2
  exit 1
}

now_value="2026-07-29T11:10:00+09:00"
n2k_manifest_mark_base_done "${manifest}" 0 1048576
n2k_manifest_mark_base_done "${manifest}" 1 2097152
jq -e --arg ts "${now_value}" '
  all(
    .disks[];
    .transfer.base_done == true
    and .transfer.last_synced_at == $ts
    and .transfer.last_sync.phase == "base"
    and .transfer.last_sync.regions == 0
    and .transfer.last_error == null
  )
  and .disks[0].transfer.last_sync.bytes_written == 1048576
  and .disks[1].transfer.last_sync.bytes_written == 2097152
  and .disks[0].metrics.base_bytes_written == 1048576
  and .disks[1].metrics.base_bytes_written == 2097152
' "${manifest}" >/dev/null || {
  echo "[ERR] base observability was not recorded per disk" >&2
  cat "${manifest}" >&2
  exit 1
}

incr_results='[
  {"index":0,"bytes_written":4096,"regions":2},
  {"index":1,"bytes_written":8192,"regions":3}
]'
now_value="2026-07-29T11:20:00+09:00"
n2k_manifest_complete_patch_phase \
  "${manifest}" "incr_sync" "${incr_results}" "rp-incr"
jq -e --arg ts "${now_value}" '
  .phases.incr_sync == {done:true, ts:$ts}
  and .runtime.progress.last_step == "incr_sync"
  and .runtime.sync.round == 1
  and .runtime.sync.last_phase == "incr_sync"
  and .runtime.sync.last_changed_bytes == 12288
  and .runtime.sync.last_region_count == 5
  and .runtime.sync.phase_summaries.incr_sync == {
    bytes_written:12288,
    regions:5,
    recovery_point_id:"rp-incr",
    ts:$ts
  }
  and .disks[0].transfer.last_sync == {
    phase:"incr",
    bytes_written:4096,
    regions:2,
    ts:$ts
  }
  and .disks[1].transfer.last_sync == {
    phase:"incr",
    bytes_written:8192,
    regions:3,
    ts:$ts
  }
  and all(.disks[]; .transfer.incr_seq == 1)
  and .disks[0].metrics.incr_bytes_written == 4096
  and .disks[1].metrics.incr_bytes_written == 8192
  and .disks[0].recovery_points.incr.id == "rp-incr"
  and .disks[1].recovery_points.incr.id == "rp-incr"
' "${manifest}" >/dev/null || {
  echo "[ERR] incremental observability was not committed atomically" >&2
  cat "${manifest}" >&2
  exit 1
}

before_invalid="$(sha256sum "${manifest}" | awk '{print $1}')"
if n2k_manifest_complete_patch_phase \
    "${manifest}" "final_sync" \
    '[{"index":0,"bytes_written":0,"regions":0}]' \
    "rp-final" >/dev/null 2>&1; then
  echo "[ERR] incomplete disk observations were accepted" >&2
  exit 1
fi
after_invalid="$(sha256sum "${manifest}" | awk '{print $1}')"
[[ "${before_invalid}" == "${after_invalid}" ]] || {
  echo "[ERR] rejected patch observations changed the manifest" >&2
  exit 1
}

final_results='[
  {"index":0,"bytes_written":0,"regions":0},
  {"index":1,"bytes_written":0,"regions":0}
]'
now_value="2026-07-29T11:30:00+09:00"
n2k_manifest_complete_patch_phase \
  "${manifest}" "final_sync" "${final_results}" "rp-final"
jq -e --arg ts "${now_value}" '
  .phases.final_sync == {done:true, ts:$ts}
  and .runtime.sync.round == 2
  and .runtime.sync.final_ready == true
  and .runtime.sync.final_recovery_point_id == "rp-final"
  and .runtime.sync.phase_summaries.final_sync == {
    bytes_written:0,
    regions:0,
    recovery_point_id:"rp-final",
    ts:$ts
  }
  and all(
    .disks[];
    .transfer.incr_seq == 2
    and .transfer.last_synced_at == $ts
    and .transfer.last_sync == {
      phase:"final",
      bytes_written:0,
      regions:0,
      ts:$ts
    }
    and .recovery_points.final.id == "rp-final"
  )
  and .disks[0].metrics.incr_bytes_written == 4096
  and .disks[1].metrics.incr_bytes_written == 8192
' "${manifest}" >/dev/null || {
  echo "[ERR] no-change final sync did not refresh observability" >&2
  cat "${manifest}" >&2
  exit 1
}

summary="$(n2k_manifest_status_summary "${manifest}")"
jq -e '
  .disks_count == 2
  and (.disks | length) == 2
  and .disks[0].disk_id == "disk-0"
  and .disks[0].base_bytes_written == 1048576
  and .disks[0].incr_bytes_written == 4096
  and .disks[0].incr_regions == 2
  and .disks[0].last_sync.phase == "final"
  and .disks[0].recovery_points.final.id == "rp-final"
  and .disks[1].base_bytes_written == 2097152
  and .runtime.sync.phase_summaries.final_sync.ts ==
    "2026-07-29T11:30:00+09:00"
' <<<"${summary}" >/dev/null || {
  echo "[ERR] status summary omitted per-disk observability" >&2
  printf '%s\n' "${summary}" >&2
  exit 1
}

if find "${WORK_DIR}" -maxdepth 1 -name 'manifest.json.tmp.*' | grep -q .; then
  echo "[ERR] manifest-local temporary files were left behind" >&2
  exit 1
fi

cli_dir="${WORK_DIR}/cli"
printf 'aaaabbbb\n' >"${WORK_DIR}/disk0-base.raw"
printf '11112222\n' >"${WORK_DIR}/disk1-base.raw"
base_map="$(
  jq -nc \
    --arg d0 "${WORK_DIR}/disk0-base.raw" \
    --arg d1 "${WORK_DIR}/disk1-base.raw" \
    '{"disk-ext-001":$d0,"disk-ext-002":$d1}'
)"
"${ROOT_DIR}/bin/ablestack_n2k.sh" \
  --workdir "${cli_dir}/work" \
  --run-id observability-cli \
  --manifest "${cli_dir}/work/manifest.json" \
  init \
  --vm app-01 \
  --pc pc.example \
  --dst "${cli_dir}/target" \
  --inventory-file "${ROOT_DIR}/tests/fixtures/n2k/inventory/vm_linux.json" \
  --target-format raw \
  --target-storage file >/dev/null
"${ROOT_DIR}/bin/ablestack_n2k.sh" \
  --workdir "${cli_dir}/work" \
  --manifest "${cli_dir}/work/manifest.json" \
  sync base \
  --source-map-json "${base_map}" >/dev/null

printf 'ZZZZbbbb\n' >"${WORK_DIR}/disk0-incr.raw"
printf '1111YYYY\n' >"${WORK_DIR}/disk1-incr.raw"
incr_map="$(
  jq -nc \
    --arg d0 "${WORK_DIR}/disk0-incr.raw" \
    --arg d1 "${WORK_DIR}/disk1-incr.raw" \
    '{"disk-ext-001":$d0,"disk-ext-002":$d1}'
)"
"${ROOT_DIR}/bin/ablestack_n2k.sh" \
  --workdir "${cli_dir}/work" \
  --manifest "${cli_dir}/work/manifest.json" \
  sync incr \
  --source-map-json "${incr_map}" \
  --changed-regions-file \
    "${ROOT_DIR}/tests/fixtures/n2k/changed_regions/non_empty.json" \
  --recovery-point-id rp-observability >/dev/null

jq -e '
  .phases.incr_sync.done == true
  and .runtime.sync.phase_summaries.incr_sync.regions == 2
  and (.runtime.sync.phase_summaries.incr_sync.ts | length) > 0
  and (.disks | length) == 2
  and all(
    .disks[];
    .transfer.incr_seq == 1
    and .transfer.last_sync.phase == "incr"
  )
  and .disks[0].metrics.incr_bytes_written == 4
  and .disks[1].metrics.incr_bytes_written == 4
' "${cli_dir}/work/manifest.json" >/dev/null || {
  echo "[ERR] CLI patch path did not commit two-disk observability" >&2
  cat "${cli_dir}/work/manifest.json" >&2
  exit 1
}
[[ "$(cat "${cli_dir}/target/app-01-disk0.raw")" == "ZZZZbbbb" ]]
[[ "$(cat "${cli_dir}/target/app-01-disk1.raw")" == "1111YYYY" ]]

status_text="$(
  "${ROOT_DIR}/bin/ablestack_n2k.sh" \
    --workdir "${cli_dir}/work" \
    --manifest "${cli_dir}/work/manifest.json" \
    status
)"
grep -F "Disk sync:" <<<"${status_text}" >/dev/null
grep -F \
  "[0] disk-ext-001 base=true base_bytes=9 incr_bytes=4 regions=1 last=incr@" \
  <<<"${status_text}" >/dev/null
grep -F \
  "[1] disk-ext-002 base=true base_bytes=9 incr_bytes=4 regions=1 last=incr@" \
  <<<"${status_text}" >/dev/null

echo "[OK] n2k split, base, incremental, final, and status observability"
