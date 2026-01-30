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

# ---------------------------------------------------------------------
# Progress helpers (state machine observability)
# ---------------------------------------------------------------------

v2k_progress_percent_from_manifest() {
  local manifest="${1:-}"
  [[ -n "${manifest}" && -f "${manifest}" ]] || { echo 0; return 0; }

  local pct
  pct="$(jq -r '
    def b($x): (if ($x==true) then 1 else 0 end);
    (
      (b(.phases.init.done) +
       b(.phases.cbt_enable.done) +
       b(.phases.base_sync.done) +
       b(.phases.incr_sync.done) +
       b(.phases.final_sync.done) +
       b(.phases.cutover.done)
      ) / 6.0 * 100
    ) | floor
  ' "${manifest}" 2>/dev/null || echo 0)"
  [[ "${pct}" =~ ^[0-9]+$ ]] || pct=0
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  echo "${pct}"
}

v2k_emit_progress_event() {
  # Usage: v2k_emit_progress_event <phase> <step> [<extra_json_obj>]
  local phase="${1:-runtime}"
  local step="${2:-}"
  local extra="${3:-{}}"

  local pct="0"
  if [[ -n "${V2K_MANIFEST:-}" && -f "${V2K_MANIFEST}" ]]; then
    pct="$(v2k_progress_percent_from_manifest "${V2K_MANIFEST}")"
  fi

  if ! printf '%s' "${extra}" | jq -e 'type=="object"' >/dev/null 2>&1; then
    extra="{}"
  fi

  v2k_event INFO "${phase}" "" "progress" \
    "$(jq -nc --arg step "${step}" --argjson percent "${pct}" --argjson extra "${extra}" \
      '$extra + {step:$step,percent:$percent,run_id:("'"${V2K_RUN_ID:-}"'")}')"
}

v2k_now_rfc3339() {
  date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/'
}
 
v2k_has_jq() {
  command -v jq >/dev/null 2>&1
}

# Read stdin and output a JSON string (including quotes).
# Prefers jq -Rs for correctness; falls back to python json.dumps.
v2k_json_string() {
  if v2k_has_jq; then
    jq -Rs '.' 2>/dev/null || echo '""'
    return 0
  fi
  python3 - <<'PY' 2>/dev/null || echo '""'
import json,sys
print(json.dumps(sys.stdin.read()))
PY
}

# Run a command and emit {"cmd": "...", "rc": N, "out": "..."} as JSON.
v2k_event_cmd_json() {
  local cmd="$1"; shift || true
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  local out_json cmd_json
  out_json="$(printf '%s' "${out}" | v2k_json_string)"
  cmd_json="$(printf '%s' "${cmd}" | v2k_json_string)"
  printf '{"cmd":%s,"rc":%d,"out":%s}' "${cmd_json}" "${rc}" "${out_json}"
  return 0
}

# Snapshot host storage state to events log (best-effort).
v2k_event_storage_snapshot() {
  local tag="${1:-snapshot}"
  declare -F v2k_event >/dev/null 2>&1 || return 0

  local lsblk_json lvs_json vgs_json
  lsblk_json="$(v2k_event_cmd_json "lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,UUID -J" \
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL,UUID -J)"
  lvs_json="$(v2k_event_cmd_json "lvs -a -o vg_name,lv_name,lv_attr,lv_size,origin,data_percent,metadata_percent,devices --reportformat json" \
    lvs -a -o vg_name,lv_name,lv_attr,lv_size,origin,data_percent,metadata_percent,devices --reportformat json)"
  vgs_json="$(v2k_event_cmd_json "vgs -o vg_name,vg_attr,vg_size,vg_free,pv_count,lv_count --reportformat json" \
    vgs -o vg_name,vg_attr,vg_size,vg_free,pv_count,lv_count --reportformat json)"

  v2k_event INFO "observability" "" "storage_snapshot" \
    "{\"tag\":$(printf '%s' "${tag}" | v2k_json_string),\"lsblk\":${lsblk_json},\"lvs\":${lvs_json},\"vgs\":${vgs_json}}"
}

v2k_event() {
  local level="$1" phase="$2" disk_id="$3" event="$4" detail_json="$5"
  local ts run_id
  ts="$(v2k_now_rfc3339)"
  run_id="${V2K_RUN_ID:-unknown}"
  local log="${V2K_EVENTS_LOG:-}"
  [[ -n "${log}" ]] || return 0
  mkdir -p "$(dirname "${log}")"
  printf '{"ts":"%s","run_id":"%s","level":"%s","phase":"%s","disk_id":"%s","event":"%s","detail":%s}\n' \
    "${ts}" "${run_id}" "${level}" "${phase}" "${disk_id}" "${event}" "${detail_json}" >> "${log}"
}
