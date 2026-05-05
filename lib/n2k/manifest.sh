#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ---------------------------------------------------------------------

set -euo pipefail

N2K_SCHEMA_ID="ablestack-n2k/manifest-v1"

n2k_manifest_init() {
  local manifest="$1" run_id="$2" workdir="$3" vm="$4" pc="$5" mode="$6" dst="$7" target_format="$8" target_storage="$9" target_map_json="${10}"
  local inventory_json="${11:-}"
  local created_at
  created_at="$(n2k_now_iso)"

  local map_compact inv_compact
  if [[ -z "${target_map_json}" ]]; then
    target_map_json="{}"
  fi
  if ! map_compact="$(printf '%s' "${target_map_json}" | jq -c . 2>/dev/null)"; then
    echo "Invalid target map JSON." >&2
    return 2
  fi
  if [[ -z "${inventory_json}" ]]; then
    inventory_json="$(jq -nc --arg vm "${vm}" '{vm:{name:$vm},disks:[]}' )"
  fi
  if ! inv_compact="$(printf '%s' "${inventory_json}" | jq -c . 2>/dev/null)"; then
    echo "Invalid inventory JSON." >&2
    return 2
  fi

  mkdir -p "$(dirname "${manifest}")"

  jq -n \
    --arg schema "${N2K_SCHEMA_ID}" \
    --arg run_id "${run_id}" \
    --arg created_at "${created_at}" \
    --arg workdir "${workdir}" \
    --arg vm "${vm}" \
    --arg pc "${pc}" \
    --arg mode "${mode}" \
    --arg dst "${dst}" \
    --arg target_format "${target_format}" \
    --arg target_storage "${target_storage}" \
    --argjson target_map "${map_compact}" \
    --argjson inv "${inv_compact}" \
    '
      def safe_name($s):
        ($s | tostring)
        | gsub("[/\\\\]"; "_")
        | gsub("[[:cntrl:]]"; "_")
        | gsub("[[:space:]]+"; "_")
        | gsub("^[.]+$"; "_")
        | gsub("^[.]"; "_")
        | gsub("_+"; "_");

      def disk_target_path($disk; $idx):
        ($disk.disk_id // ("disk" + ($idx | tostring))) as $disk_id
        | ($target_map[$disk_id] // "") as $mapped
        | if ($mapped | tostring | length) > 0 then
            $mapped
          elif $target_storage == "file" then
            ($dst + "/" + safe_name($vm) + "-disk" + ($idx | tostring) + "." + $target_format)
          else
            ""
          end;

      ($inv.vm // {name: $vm}) as $vm_inv
      | (($inv.disks // []) | to_entries | map(
          . as $entry
          | .value as $disk
          | ($disk + {
              transfer: {
                target_path: disk_target_path($disk; $entry.key),
                base_done: false,
                incr_seq: 0,
                last_synced_at: ""
              },
              recovery_points: {
                base: {id: "", disk_id: ""},
                incr: {id: "", disk_id: ""},
                final: {id: "", disk_id: ""}
              },
              metrics: {
                base_bytes_written: 0,
                incr_bytes_written: 0,
                incr_regions: 0
              }
            })
        )) as $disks
      | if ($target_storage == "block" or $target_storage == "rbd") and
          ([ $disks[]? | select((.transfer.target_path // "") == "") ] | length) > 0
        then error("target storage requires target map for all inventory disks")
        else . end
      | if $target_storage == "rbd" and
          ([ $disks[]? | select((.transfer.target_path | tostring | startswith("rbd:")) | not) ] | length) > 0
        then error("rbd target paths must start with rbd:")
        else . end
      | if ([ $disks[]?.transfer.target_path | select(. != "") ] | length) !=
          ([ $disks[]?.transfer.target_path | select(. != "") ] | unique | length)
        then error("duplicate target path detected")
        else . end
      | {
      schema: $schema,
      run: {
        run_id: $run_id,
        created_at: $created_at,
        workdir: $workdir
      },
      source: {
        type: "nutanix",
        mode: $mode,
        pc: $pc,
        api: {
          family: "",
          namespaces: {}
        },
        vm: (
          $vm_inv
          | .name = (if ((.name // "") | tostring | length) > 0 then .name else $vm end)
        )
      },
      target: {
        type: "kvm",
        format: $target_format,
        dst_root: $dst,
        storage: {
          type: $target_storage,
          map: $target_map
        },
        libvirt: {
          name: $vm
        }
      },
      disks: $disks,
      phases: {
        init: {done: true, ts: $created_at},
        preflight: {done: false, ts: ""},
        plan: {done: false, ts: ""},
        base_sync: {done: false, ts: ""},
        incr_sync: {done: false, ts: ""},
        final_sync: {done: false, ts: ""},
        cutover: {done: false, ts: ""},
        cleanup: {done: false, ts: ""}
      },
      runtime: {
        selected_mode: $mode,
        progress: {percent: 0, last_step: "init"},
        cleanup: {items: []},
        sync_issues: [],
        last_error: {code: 0, reason: "", ts: ""}
      }
    }' > "${manifest}"
}

n2k_manifest_phase_done() {
  local manifest="$1" phase="$2"
  local ts tmp
  ts="$(n2k_now_iso)"
  tmp="$(mktemp)"
  jq --arg phase "${phase}" --arg ts "${ts}" '
    .phases[$phase] = (.phases[$phase] // {})
    | .phases[$phase].done = true
    | .phases[$phase].ts = $ts
    | .runtime.progress.last_step = $phase
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

n2k_manifest_record_artifact() {
  local manifest="$1" path="$2" kind="${3:-artifact}"
  local tmp
  tmp="$(mktemp)"
  jq --arg path "${path}" --arg kind "${kind}" '
    .runtime.cleanup = (.runtime.cleanup // {items: []})
    | .runtime.cleanup.items = (
        ((.runtime.cleanup.items // []) + [{
          path: $path,
          kind: $kind,
          source_resource: false,
          cleanup_allowed: true,
          removed: false
        }])
        | unique_by(.path)
      )
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

n2k_manifest_mark_cleanup_item_removed() {
  local manifest="$1" path="$2"
  local ts tmp
  ts="$(n2k_now_iso)"
  tmp="$(mktemp)"
  jq --arg path "${path}" --arg ts "${ts}" '
    .runtime.cleanup.items = ((.runtime.cleanup.items // []) | map(
      if .path == $path then
        .removed = true | .removed_at = $ts
      else
        .
      end
    ))
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

n2k_manifest_resume_summary() {
  local manifest="$1"
  jq -c '
    . as $m
    | def done($p): ($m.phases[$p].done // false);
    ($m.runtime.selected_mode // $m.source.mode // "auto") as $mode
    | (if done("cleanup") then
        {completed: true, can_resume: false, next_step: "none", next_command: "", reason: "migration is already cleaned up"}
      elif done("cutover") then
        {completed: false, can_resume: true, next_step: "cleanup", next_command: "cleanup", reason: "target definition step is complete"}
      elif done("final_sync") then
        {completed: false, can_resume: true, next_step: "cutover", next_command: "cutover --define-only", reason: "final sync is complete"}
      elif done("incr_sync") then
        {completed: false, can_resume: true, next_step: "sync-final", next_command: "sync final", reason: "incremental sync is complete"}
      elif done("base_sync") then
        if ($mode == "cold-export" or $mode == "manual-disk") then
          {completed: false, can_resume: true, next_step: "cutover", next_command: "cutover --define-only", reason: "base disk sync is complete"}
        else
          {completed: false, can_resume: true, next_step: "sync-incr", next_command: "sync incr", reason: "base disk sync is complete"}
        end
      elif done("plan") then
        {completed: false, can_resume: true, next_step: "sync-base", next_command: "sync base", reason: "plan is complete"}
      elif done("preflight") then
        {completed: false, can_resume: true, next_step: "plan", next_command: "plan", reason: "preflight is complete"}
      elif done("init") then
        {completed: false, can_resume: true, next_step: "preflight", next_command: "preflight", reason: "manifest is initialized"}
      else
        {completed: false, can_resume: false, next_step: "init", next_command: "init", reason: "manifest is not initialized"}
      end) as $resume
    | ([ "init", "preflight", "plan", "base_sync", "incr_sync", "final_sync", "cutover", "cleanup" ] | map(select(done(.))) | length) as $done_count
    | $resume + {
        percent: (($done_count * 100 / 8) | floor),
        last_step: ($m.runtime.progress.last_step // "")
      }
  ' "${manifest}"
}

n2k_manifest_record_preflight_result() {
  local manifest="$1" preflight_json="$2"
  local preflight_compact tmp

  if ! preflight_compact="$(printf '%s' "${preflight_json}" | jq -c . 2>/dev/null)"; then
    echo "Invalid preflight result JSON." >&2
    return 2
  fi

  tmp="$(mktemp)"
  jq --argjson pf "${preflight_compact}" '
    .runtime.selected_mode = ($pf.selected_mode // .runtime.selected_mode)
    | .runtime.preflight = {
        requested_mode: ($pf.requested_mode // ""),
        recommended_mode: ($pf.recommended_mode // ""),
        selected_mode: ($pf.selected_mode // ""),
        can_run: ($pf.can_run // false),
        fallback_mode: ($pf.fallback_mode // "unavailable"),
        warnings: ($pf.warnings // []),
        modes: ($pf.modes // {})
      }
    | .source.api.family = (
        if ($pf.selected_mode // "") == "v4-incremental" then "v4"
        elif ($pf.selected_mode // "") == "legacy-cbt" then "legacy"
        elif ($pf.selected_mode // "") == "cold-export" then "cold-export"
        elif ($pf.selected_mode // "") == "manual-disk" then "manual-disk"
        else (.source.api.family // "")
        end
      )
    | .source.api.namespaces = {
        v4: ($pf.api.v4 // {}),
        legacy: ($pf.api.legacy // {})
      }
    | .source.fallback = {
        mode: ($pf.fallback_mode // "unavailable"),
        reason: (
          if (($pf.selected_mode // "") == "legacy-cbt") and (($pf.can_run // false) | not) then
            "legacy-cbt is blocked or unavailable"
          else ""
          end
        )
      }
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

n2k_manifest_mark_base_done() {
  local manifest="$1" idx="$2" bytes_written="$3"
  local ts tmp
  ts="$(n2k_now_iso)"
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" --arg ts "${ts}" --argjson bytes_written "${bytes_written}" '
    .disks[$idx].transfer.base_done = true
    | .disks[$idx].transfer.last_synced_at = $ts
    | .disks[$idx].metrics.base_bytes_written = $bytes_written
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

n2k_manifest_mark_patch_done() {
  local manifest="$1" idx="$2" phase="$3" bytes_written="$4" regions="$5" recovery_point_id="${6:-}"
  local ts tmp rp_key
  ts="$(n2k_now_iso)"
  tmp="$(mktemp)"

  case "${phase}" in
    incr_sync) rp_key="incr" ;;
    final_sync) rp_key="final" ;;
    *)
      echo "Unsupported patch phase: ${phase}" >&2
      return 2
      ;;
  esac

  jq \
    --argjson idx "${idx}" \
    --arg ts "${ts}" \
    --arg rp_key "${rp_key}" \
    --arg recovery_point_id "${recovery_point_id}" \
    --argjson bytes_written "${bytes_written}" \
    --argjson regions "${regions}" \
    '
      .disks[$idx].transfer.incr_seq = ((.disks[$idx].transfer.incr_seq // 0) + 1)
      | .disks[$idx].transfer.last_synced_at = $ts
      | .disks[$idx].metrics.incr_bytes_written = ((.disks[$idx].metrics.incr_bytes_written // 0) + $bytes_written)
      | .disks[$idx].metrics.incr_regions = ((.disks[$idx].metrics.incr_regions // 0) + $regions)
      | if ($recovery_point_id | length) > 0 then
          .disks[$idx].recovery_points[$rp_key].id = $recovery_point_id
        else
          .
        end
    ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

n2k_manifest_set_cold_source() {
  local manifest="$1" idx="$2" source_path="$3"
  local tmp
  tmp="$(mktemp)"
  jq --argjson idx "${idx}" --arg source_path "${source_path}" '
    .disks[$idx].source = (.disks[$idx].source // {})
    | .disks[$idx].source.cold_export = {
        path: $source_path,
        type: "manual-disk"
      }
  ' "${manifest}" > "${tmp}" && mv "${tmp}" "${manifest}"
}

n2k_manifest_status_summary() {
  local manifest="$1" events_log="${2:-}"
  local resume
  resume="$(n2k_manifest_resume_summary "${manifest}")"
  jq -c --arg events_log "${events_log}" --argjson resume "${resume}" '
    {
      schema: .schema,
      run_id: .run.run_id,
      workdir: .run.workdir,
      source: {
        type: .source.type,
        mode: .source.mode,
        pc: .source.pc,
        vm: .source.vm.name
      },
      target: {
        type: .target.type,
        format: .target.format,
        storage: .target.storage.type,
        dst_root: .target.dst_root
      },
      disks_count: (.disks | length),
      phases: .phases,
      runtime: .runtime,
      resume: $resume,
      cleanup: {
        items_total: ((.runtime.cleanup.items // []) | length),
        items_pending: ((.runtime.cleanup.items // []) | map(select((.removed // false) | not)) | length)
      },
      events_log: $events_log
    }
  ' "${manifest}"
}
