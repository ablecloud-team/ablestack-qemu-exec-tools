#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/v2k-manifest-observability.XXXXXX")"

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

export V2K_ROOT_DIR="${ROOT_DIR}"
export V2K_LIB_DIR="${ROOT_DIR}/lib/v2k"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/v2k/manifest.sh"

definition_count="$(
  grep -c '^v2k_manifest_mark_split_done()' \
    "${ROOT_DIR}/lib/v2k/manifest.sh"
)"
[[ "${definition_count}" -eq 1 ]] || {
  echo "[ERR] split completion helper must have exactly one definition" >&2
  exit 1
}

patch_success_calls="$(
  grep -c '^[[:space:]]*v2k_manifest_record_patch_success' \
    "${ROOT_DIR}/lib/v2k/transfer_patch.sh"
)"
[[ "${patch_success_calls}" -eq 2 ]] || {
  echo "[ERR] changed and no-change patch paths must use the atomic success helper" >&2
  exit 1
}

manifest="${WORK_DIR}/manifest.json"
cat > "${manifest}" <<'JSON'
{
  "run": {"run_id": "observability-smoke"},
  "source": {"vm": {"name": "observability-smoke"}},
  "phases": {},
  "runtime": {
    "split": {
      "phase1": {"done": false, "ts": ""},
      "phase2": {"done": false, "ts": ""}
    },
    "sync_issues": []
  },
  "disks": [
    {
      "disk_id": "scsi0:0",
      "size_bytes": 3298534883328,
      "transfer": {
        "target_path": "rbd:pool/observability-smoke",
        "base_done": false,
        "incr_seq": 0,
        "last_synced_at": "",
        "last_sync": null
      },
      "metrics": {
        "base_bytes_written": 0,
        "incr_bytes_written": 0,
        "incr_areas": 0
      },
      "cbt": {
        "enabled": true,
        "base_change_id": "*",
        "last_change_id": "change-40"
      }
    }
  ]
}
JSON

now_value="2026-07-29T16:30:17+09:00"
v2k_manifest_now() {
  printf '%s\n' "${now_value}"
}

# Legacy orchestrator writes are routed to the atomic dual-view marker.
v2k_manifest_runtime_set \
  "${manifest}" ".runtime.split.phase1.done" "true"
jq -e --arg ts "${now_value}" '
  .phases["split.phase1"] == {done:true, ts:$ts}
  and .runtime.split.phase1 == {done:true, ts:$ts}
  and .runtime.split.phase2.done == false
' "${manifest}" >/dev/null || {
  echo "[ERR] phase1 completion views were not committed together" >&2
  cat "${manifest}" >&2
  exit 1
}
v2k_manifest_split_is_done "${manifest}" "phase1" || {
  echo "[ERR] authoritative phase1 completion marker was not readable" >&2
  exit 1
}

# The legacy phase1 path invokes the helper once more; completion must remain
# idempotent and preserve the first timestamp.
now_value="2026-07-29T16:35:00+09:00"
v2k_manifest_mark_split_done "${manifest}" "phase1"
jq -e --arg ts "2026-07-29T16:30:17+09:00" '
  .phases["split.phase1"].ts == $ts
  and .runtime.split.phase1.ts == $ts
' "${manifest}" >/dev/null || {
  echo "[ERR] repeated phase1 completion changed the original timestamp" >&2
  cat "${manifest}" >&2
  exit 1
}

# Reproduce the legacy defect and verify that the next atomic split update
# repairs runtime observability from the authoritative phases timestamp.
v2k_manifest_runtime_set \
  "${manifest}" ".runtime.split.phase1.ts" '""'
now_value="2026-07-29T16:40:00+09:00"
v2k_manifest_mark_split_done "${manifest}" "phase2"
jq -e \
  --arg phase1_ts "2026-07-29T16:30:17+09:00" \
  --arg phase2_ts "${now_value}" '
  .phases["split.phase2"] == {done:true, ts:$phase2_ts}
  and .runtime.split.phase2 == {done:true, ts:$phase2_ts}
  and .runtime.split.phase1 == {done:true, ts:$phase1_ts}
' "${manifest}" >/dev/null || {
  echo "[ERR] phase2 completion views were not committed together" >&2
  cat "${manifest}" >&2
  exit 1
}

before_invalid="$(sha256sum "${manifest}" | awk '{print $1}')"
if v2k_manifest_mark_split_done "${manifest}" "phase3" >/dev/null 2>&1; then
  echo "[ERR] invalid split marker was accepted" >&2
  exit 1
fi
after_invalid="$(sha256sum "${manifest}" | awk '{print $1}')"
[[ "${before_invalid}" == "${after_invalid}" ]] || {
  echo "[ERR] invalid split marker changed the manifest" >&2
  exit 1
}

now_value="2026-07-29T16:50:00+09:00"
v2k_manifest_mark_base_done "${manifest}" 0 3298534883328
jq -e --arg ts "${now_value}" '
  .disks[0].transfer.base_done == true
  and .disks[0].transfer.last_synced_at == $ts
  and .disks[0].transfer.last_sync == {
    phase:"base",
    bytes_written:3298534883328,
    areas:0,
    ts:$ts
  }
  and .disks[0].metrics.base_bytes_written == 3298534883328
' "${manifest}" >/dev/null || {
  echo "[ERR] base completion observability was not recorded" >&2
  cat "${manifest}" >&2
  exit 1
}

coverage_incr='{
  "mode": "delta",
  "complete": true,
  "start_offset": 0,
  "end_offset": 3298534883328,
  "disk_capacity": 3298534883328,
  "pages": 4,
  "phase": "incr",
  "new_change_id": "change-42"
}'
now_value="2026-07-29T17:00:00+09:00"
v2k_manifest_record_patch_success \
  "${manifest}" 0 "incr" "change-40" "change-42" \
  "${coverage_incr}" 52187627520 7582
jq -e --arg ts "${now_value}" '
  .disks[0].cbt.base_change_id == "change-40"
  and .disks[0].cbt.last_change_id == "change-42"
  and .disks[0].cbt.last_coverage.pages == 4
  and .disks[0].transfer.incr_seq == 1
  and .disks[0].transfer.last_synced_at == $ts
  and .disks[0].transfer.last_sync == {
    phase:"incr",
    bytes_written:52187627520,
    areas:7582,
    ts:$ts
  }
  and .disks[0].metrics.incr_bytes_written == 52187627520
  and .disks[0].metrics.incr_areas == 7582
' "${manifest}" >/dev/null || {
  echo "[ERR] incremental completion observability was not committed atomically" >&2
  cat "${manifest}" >&2
  exit 1
}

coverage_final='{
  "mode": "delta",
  "complete": true,
  "start_offset": 0,
  "end_offset": 3298534883328,
  "disk_capacity": 3298534883328,
  "pages": 1,
  "phase": "final",
  "new_change_id": "change-43"
}'
now_value="2026-07-29T17:10:00+09:00"
v2k_manifest_record_patch_success \
  "${manifest}" 0 "final" "change-42" "change-43" \
  "${coverage_final}" 0 0
jq -e --arg ts "${now_value}" '
  .disks[0].cbt.last_change_id == "change-43"
  and .disks[0].cbt.last_coverage.phase == "final"
  and .disks[0].transfer.incr_seq == 2
  and .disks[0].transfer.last_synced_at == $ts
  and .disks[0].transfer.last_sync == {
    phase:"final",
    bytes_written:0,
    areas:0,
    ts:$ts
  }
  and .disks[0].metrics.incr_bytes_written == 52187627520
  and .disks[0].metrics.incr_areas == 7582
' "${manifest}" >/dev/null || {
  echo "[ERR] no-change final sync did not refresh completion observability" >&2
  cat "${manifest}" >&2
  exit 1
}

before_invalid="$(sha256sum "${manifest}" | awk '{print $1}')"
if v2k_manifest_record_patch_success \
    "${manifest}" 0 "incr" "change-43" "change-44" \
    '[]' 1 1 >/dev/null 2>&1; then
  echo "[ERR] invalid coverage metadata was accepted" >&2
  exit 1
fi
after_invalid="$(sha256sum "${manifest}" | awk '{print $1}')"
[[ "${before_invalid}" == "${after_invalid}" ]] || {
  echo "[ERR] rejected patch success changed the manifest" >&2
  exit 1
}

summary="$(v2k_manifest_status_summary "${manifest}")"
jq -e '
  .manifest.runtime.split.phase1.done == true
  and .manifest.runtime.split.phase2.done == true
  and .manifest.disks[0].base_bytes_written == 3298534883328
  and .manifest.disks[0].incr_bytes_written == 52187627520
  and .manifest.disks[0].incr_areas == 7582
  and .manifest.disks[0].last_sync.phase == "final"
  and .manifest.disks[0].last_coverage.phase == "final"
' <<<"${summary}" >/dev/null || {
  echo "[ERR] status summary omitted transfer observability" >&2
  printf '%s\n' "${summary}" >&2
  exit 1
}

echo "[OK] v2k split, base, incremental, and final observability"
