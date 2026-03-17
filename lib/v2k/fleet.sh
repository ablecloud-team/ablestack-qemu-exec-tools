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

# Fleet runner for multi-VM phase1/phase2.
# Design goals:
# - Run as a detached background manager (Daemon-like behavior).
# - Spawn one process per VM (foreground) with isolated workdir.
# - Gate concurrency by a simple NBD-slot semaphore.
# - Robustness: Handle stale locks and signal interrupts.

v2k_fleet_die() { echo "ERROR: $*" >&2; exit 2; }

v2k_fleet_now_rfc3339() {
  date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/'
}

v2k_fleet_trim() {
  local s="${1-}"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "${s}"
}

v2k_fleet_parse_vm_csv() {
  # Usage: v2k_fleet_parse_vm_csv "a, b,c" out_array
  local raw="${1-}"
  local -n _out="${2}"
  _out=()

  raw="$(v2k_fleet_trim "${raw}")"
  [[ -z "${raw}" ]] && return 0

  # Use read loop for robust CSV parsing
  local item
  while IFS=, read -r -d ',' item; do
    item="$(v2k_fleet_trim "${item}")"
    if [[ -n "${item}" ]]; then
       local exists=0
       for existing in "${_out[@]-}"; do
         [[ "${existing}" == "${item}" ]] && exists=1 && break
       done
       if (( exists == 0 )); then
         _out+=("${item}")
       fi
    fi
  done <<< "${raw},"
}

v2k_fleet_extract_opt() {
  # Usage: v2k_fleet_extract_opt <optname> out_value "${args[@]}"
  local opt="${1:?}"; shift
  local -n _out="${1:?}"; shift
  _out=""
  
  local i j a
  for ((i=0; i<$#; i++)); do
    j=$((i+1))
    a="${!j}"
    
    # Case 1: --vm val
    if [[ "${a}" == "${opt}" ]]; then
      j=$((i+2))
      _out="${!j:-}"
      return 0
    fi
    
    # Case 2: --vm=val
    if [[ "${a}" == "${opt}="* ]]; then
      _out="${a#*=}"
      return 0
    fi
  done
  return 1
}

v2k_fleet_has_opt() {
  local opt="${1:?}"; shift
  local a
  for a in "$@"; do
    [[ "${a}" == "${opt}" ]] && return 0
  done
  return 1
}

v2k_fleet_should_handle_run() {
  # Handle only multi-VM run/auto with --split phase1|phase2.
  
  # [FIX] If --foreground is present, it means this is a worker process spawned by fleet.
  # Do NOT handle it via fleet again (avoids infinite recursion).
  if v2k_fleet_has_opt "--foreground" "$@"; then
    return 1
  fi

  local vm_raw="" split=""
  v2k_fleet_extract_opt "--vm" vm_raw "$@" || true
  v2k_fleet_extract_opt "--split" split "$@" || true

  [[ -z "${vm_raw}" ]] && return 1
  local -a vms=()
  v2k_fleet_parse_vm_csv "${vm_raw}" vms
  
  # Allow single VM (>=1) to enter fleet mode (for consistent background/status UX)
  (( ${#vms[@]} >= 1 )) || return 1

  [[ "${split}" == "phase1" || "${split}" == "phase2" ]] || return 1
  return 0
}

v2k_fleet_should_handle_status() {
  local vm_raw=""
  v2k_fleet_extract_opt "--vm" vm_raw "$@" || return 1
  local -a vms=()
  v2k_fleet_parse_vm_csv "${vm_raw}" vms
  
  # [MODIFIED] Allow Fleet status for single VM as well (>= 1)
  (( ${#vms[@]} >= 1 )) || return 1
  return 0
}

# ------------------------------------------------------------
# Fleet status: detailed step/progress (best-effort)
# - Do NOT touch engine/orchestrator logic.
# - Parse workdir/events.log (JSONL) + manifest.json for step/state/progress.
# ------------------------------------------------------------

v2k_fleet_events_tail_json() {
  # Usage: v2k_fleet_events_tail_json <events_file> [lines]
  local f="${1-}" n="${2:-800}"
  [[ -n "${f}" && -f "${f}" ]] || { echo '[]'; return 0; }

  # Robust JSONL -> JSON array (ignore broken lines)
  # NOTE: jq fromjson? returns null for invalid JSON; we filter them out.
  tail -n "${n}" "${f}" 2>/dev/null \
    | jq -sR 'split("\n") | map(select(length>0) | (fromjson? // empty))' 2>/dev/null \
    || echo '[]'
}

v2k_fleet_events_select_meaningful() {
  # Reads JSON array from stdin; outputs filtered array (jq)
  jq -c '
    def is_step_phase:
      (.phase|tostring) as $p
      | ($p=="cbt_enable"
         or $p=="snapshot.base" or $p=="snapshot.incr" or $p=="snapshot.final"
         or $p=="sync.base" or $p=="sync.incr" or $p=="sync.final"
         or $p=="cutover" or $p=="cleanup");

    def is_step_event:
      (.event|tostring) as $e
      | ($e=="phase_start" or $e=="phase_done" or $e=="phase_skipped_by_policy"
         or $e=="disk_start" or $e=="disk_done" or $e=="no_changes"
         or $e=="changed_areas_fetched"
         or $e=="start" or $e=="done" or $e=="error" or $e=="fail"
         or $e=="nbdkit_log");

    map(select(is_step_phase and is_step_event))
  ' 2>/dev/null || echo '[]'
}

v2k_fleet_step_priority() {
  # Higher = later stage
  case "${1-}" in
    CLEANUP) echo 90;;
    CUTOVER) echo 80;;
    FINAL_SYNC) echo 70;;
    FINAL_SNAP) echo 65;;
    INCR_SYNC) echo 60;;
    INCR_SNAP) echo 55;;
    BASE_SYNC) echo 50;;
    BASE_SNAP) echo 45;;
    CBT_ENABLE) echo 40;;
    *) echo 0;;
  esac
}

v2k_fleet_parse_percent_from_log() {
  # Usage: v2k_fleet_parse_percent_from_log <log_file>
  # Returns: percent integer [0-100] or empty
  local f="${1-}"
  [[ -n "${f}" && -f "${f}" ]] || return 1

  # Best-effort patterns:
  # - qemu-img convert -p: " (xx.xx/yy.yy)  12.34% "
  # - nbdcopy --progress: often contains "xx%" somewhere in the line
  local last
  last="$(tail -n 50 "${f}" 2>/dev/null | grep -Eo '([0-9]{1,3}(\.[0-9]+)?)%' | tail -n 1 || true)"
  [[ -n "${last}" ]] || return 1
  last="${last%\%}"
  # floor numeric
  printf '%s' "${last}" | awk '{printf("%d\n",$1)}'
}

v2k_fleet_calc_step_progress() {
  # Usage: v2k_fleet_calc_step_progress <workdir> <manifest_path> <fleet_state> <fleet_phase>
  # Output: compact JSON object with step/step_state/sync totals and last_event
  local workdir="${1-}" manifest="${2-}" fleet_state="${3-}" fleet_phase="${4-}"

  local events_file="${workdir}/events.log"
  local ev_arr meaningful

  ev_arr="$(v2k_fleet_events_tail_json "${events_file}" 800)"
  meaningful="$(printf '%s' "${ev_arr}" | v2k_fleet_events_select_meaningful)"

  # Collect manifest-derived stats (best-effort)
  local incr_max="0" total_bytes_base="0"
  local -A disk_size=()
  if [[ -n "${manifest}" && -f "${manifest}" ]]; then
    incr_max="$(jq -r '[.disks[].transfer.incr_seq // 0] | max // 0' "${manifest}" 2>/dev/null || echo 0)"
    total_bytes_base="$(jq -r '[.disks[].size_bytes // 0] | add // 0' "${manifest}" 2>/dev/null || echo 0)"
    # Build disk_id -> size_bytes map for base progress
    while IFS=$'\t' read -r did sz; do
      [[ -n "${did}" ]] || continue
      disk_size["${did}"]="${sz:-0}"
    done < <(jq -r '.disks[] | [.disk_id, (.size_bytes//0)] | @tsv' "${manifest}" 2>/dev/null || true)
  fi

  # If no meaningful events, fall back to coarse fleet_state only
  if [[ -z "${workdir}" || ! -d "${workdir}" || "${meaningful}" == "[]" ]]; then
    jq -cn --arg step "" --arg step_state "" --argjson total 0 --argjson done 0 --argjson percent 0 \
      --arg last_ts "" --arg last_phase "" --arg last_event "" \
      '{step:$step,step_state:$step_state,sync:{total_bytes:$total,done_bytes:$done,percent:$percent,mode:""},last_event:{ts:$last_ts,phase:$last_phase,event:$last_event}}'
    return 0
  fi

  # Determine the "current" event (last by ts)
  # Note: ts is RFC3339; lexical sort works.
  local last_json
  last_json="$(printf '%s' "${meaningful}" | jq -c 'sort_by(.ts) | last' 2>/dev/null || echo '{}')"
  local last_phase last_event last_ts last_level last_disk
  last_phase="$(jq -r '.phase // ""' <<<"${last_json}" 2>/dev/null || echo "")"
  last_event="$(jq -r '.event // ""' <<<"${last_json}" 2>/dev/null || echo "")"
  last_ts="$(jq -r '.ts // ""' <<<"${last_json}" 2>/dev/null || echo "")"
  last_level="$(jq -r '.level // ""' <<<"${last_json}" 2>/dev/null || echo "")"
  last_disk="$(jq -r '.disk_id // ""' <<<"${last_json}" 2>/dev/null || echo "")"

  # Map last event -> canonical step + step_state
  local step="" step_base="" step_state="running" mode=""
  local n_disp=""

  case "${last_phase}" in
    cbt_enable) step="CBT_ENABLE";;
    snapshot.base) step="BASE_SNAP";;
    sync.base) step="BASE_SYNC"; mode="base";;
    snapshot.incr) step="INCR_SNAP";;
    sync.incr) step="INCR_SYNC"; mode="incr";;
    snapshot.final) step="FINAL_SNAP";;
    sync.final) step="FINAL_SYNC"; mode="final";;
    cutover) step="CUTOVER";;
    cleanup) step="CLEANUP";;
    *) step="";;
  esac

  # step_state from event/level
  if [[ "${last_level}" == "ERROR" || "${last_event}" == "error" || "${last_event}" == "fail" ]]; then
    step_state="failed"
  else
    case "${last_event}" in
      phase_done|done) step_state="done";;
      phase_skipped_by_policy) step_state="skipped";;
      *) step_state="running";;
    esac
  fi

  # N display (incr)
  if [[ "${step}" == "INCR_SNAP" || "${step}" == "INCR_SYNC" ]]; then
    # If we are in "running" part of the cycle, show incr_max+1; for done/no_changes/disk_done/phase_done show incr_max.
    case "${last_event}" in
      phase_start|disk_start|changed_areas_fetched|nbdkit_log)
        n_disp="$((incr_max + 1))"
        ;;
      *)
        n_disp="${incr_max}"
        ;;
    esac
  fi

  # Sync totals/done/percent
  local sync_total=0 sync_done=0 sync_percent=0

  if [[ "${step}" == "BASE_SYNC" ]]; then
    sync_total="${total_bytes_base:-0}"

    # Done bytes by completed disks in this base phase
    local done_list
    done_list="$(printf '%s' "${meaningful}" | jq -r '
        # slice events after last sync.base phase_start if exists
        def after_last_start($p):
          ( [ range(0; length) | select(.[.].phase==$p and .[.].event=="phase_start") ] | last ) as $i
          | if ($i|type)=="number" then .[$i:] else . end;
        after_last_start("sync.base")
        | map(select(.phase=="sync.base" and .event=="disk_done" and (.disk_id//"")!="") | .disk_id) | unique | .[]
      ' 2>/dev/null || true)"

    local did
    for did in ${done_list}; do
      sync_done=$(( sync_done + ${disk_size["${did}"]:-0} ))
    done

    # If there's an active disk and we have nbdkit_log -> parse percent for that disk (best-effort)
    local log_path=""
    log_path="$(printf '%s' "${meaningful}" | jq -r '
        def after_last_start($p):
          ( [ range(0; length) | select(.[.].phase==$p and .[.].event=="phase_start") ] | last ) as $i
          | if ($i|type)=="number" then .[$i:] else . end;
        after_last_start("sync.base")
        | map(select(.phase=="sync.base" and .event=="nbdkit_log") | (.detail.path // "")) | map(select(length>0)) | last // ""
      ' 2>/dev/null || echo "")"

    if [[ -n "${log_path}" && -f "${log_path}" && -n "${last_disk}" ]]; then
      local pct=""
      pct="$(v2k_fleet_parse_percent_from_log "${log_path}" || true)"
      if [[ -n "${pct}" && "${pct}" =~ ^[0-9]+$ && "${pct}" -ge 0 && "${pct}" -le 100 ]]; then
        local dsz="${disk_size["${last_disk}"]:-0}"
        # add partial done for current disk (avoid double counting if already done)
        if ! grep -qx "${last_disk}" <<<"${done_list}"; then
          sync_done=$(( sync_done + (dsz * pct / 100) ))
        fi
      fi
    fi

    if [[ "${sync_total}" -gt 0 ]]; then
      sync_percent=$(( sync_done * 100 / sync_total ))
    else
      sync_percent=0
    fi
  elif [[ "${step}" == "INCR_SYNC" || "${step}" == "FINAL_SYNC" ]]; then
    # Consider only events after last phase_start of this phase
    local p="${last_phase}"
    sync_total="$(printf '%s' "${meaningful}" | jq -r --arg p "${p}" '
        def after_last_start($p):
          ( [ range(0; length) | select(.[.].phase==$p and .[.].event=="phase_start") ] | last ) as $i
          | if ($i|type)=="number" then .[$i:] else . end;
        after_last_start($p)
        | map(select(.phase==$p and .event=="changed_areas_fetched") | (.detail.bytes // 0)) | add // 0
      ' 2>/dev/null || echo 0)"

    sync_done="$(printf '%s' "${meaningful}" | jq -r --arg p "${p}" '
        def after_last_start($p):
          ( [ range(0; length) | select(.[.].phase==$p and .[.].event=="phase_start") ] | last ) as $i
          | if ($i|type)=="number" then .[$i:] else . end;
        after_last_start($p)
        | map(select(.phase==$p and .event=="disk_done") | (.detail.bytes_written // 0)) | add // 0
      ' 2>/dev/null || echo 0)"

    if [[ "${sync_total}" -gt 0 ]]; then
      sync_percent=$(( sync_done * 100 / sync_total ))
    else
      # total=0 can mean "no_changes" across disks; treat as 100% if we have any no_changes/disk_done.
      local has_any
      has_any="$(printf '%s' "${meaningful}" | jq -r --arg p "${p}" '
          def after_last_start($p):
            ( [ range(0; length) | select(.[.].phase==$p and .[.].event=="phase_start") ] | last ) as $i
            | if ($i|type)=="number" then .[$i:] else . end;
          after_last_start($p)
          | map(select(.phase==$p and (.event=="no_changes" or .event=="disk_done"))) | length
        ' 2>/dev/null || echo 0)"
      if [[ "${has_any}" -gt 0 ]]; then
        sync_percent=100
      else
        sync_percent=0
      fi
    fi
  else
    sync_total=0; sync_done=0; sync_percent=0
  fi

  # Embed N into step label if needed
  local step_label="${step}"
  if [[ "${step}" == "INCR_SNAP" || "${step}" == "INCR_SYNC" ]]; then
    if [[ -n "${n_disp}" ]]; then
      step_label="${step}#${n_disp}"
    fi
  fi

  jq -cn \
    --arg step "${step_label}" \
    --arg step_state "${step_state}" \
    --argjson total "${sync_total:-0}" \
    --argjson done "${sync_done:-0}" \
    --argjson percent "${sync_percent:-0}" \
    --arg mode "${mode}" \
    --arg last_ts "${last_ts}" \
    --arg last_phase "${last_phase}" \
    --arg last_event "${last_event}" \
    '{step:$step,step_label:$step,step_state:$step_state,sync:{total_bytes:$total,done_bytes:$done,percent:$percent,mode:$mode},last_event:{ts:$last_ts,phase:$last_phase,event:$last_event}}'
}

v2k_fleet_die() { echo "ERROR: $*" >&2; exit 2; }

v2k_fleet_now_rfc3339() {
  date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/'
}

# [Helper] ?§Ìñâ Ï§ëÏù∏ patch_apply.py ?ÑÎ°ú?∏Ïä§??I/O ?ëÏùÑ Ï°∞Ìöå?òÏó¨ Î∞òÌôò
v2k_fleet_get_active_patch_bytes() {
  local target_path="$1"
  [[ -z "${target_path}" ]] && echo 0 && return

  # 1. target_pathÎ•??∏ÏûêÎ°?Í∞ÄÏßÄ??python3 patch_apply.py ?ÑÎ°ú?∏Ïä§ Ï∞æÍ∏∞
  # pgrep -f???ÑÏ≤¥ Ïª§Îß®?úÎùº?∏ÏùÑ Í≤Ä?âÌï®.
  # grep?ºÎ°ú patch_apply.py?Ä target_pathÍ∞Ä Î™®Îëê ?¨Ìï®???ºÏù∏ ?ÑÌÑ∞Îß?
  local pids
  pids=$(pgrep -f "patch_apply.py" 2>/dev/null || true)
  
  local total_active_bytes=0
  
  for pid in ${pids}; do
    # ?¥Îãπ PID??cmdline ?ïÏù∏ (?ïÌôï??Î≥¥Ïû•)
    if [[ -f "/proc/${pid}/cmdline" ]]; then
      # cmdline?Ä nullÎ°?Íµ¨Î∂Ñ?òÎ?Î°?cat -v ?±ÏúºÎ°??ΩÍ±∞??grep -a ?¨Ïö©
      if grep -a -q "${target_path}" "/proc/${pid}/cmdline"; then
        # 2. /proc/[pid]/io ?êÏÑú write_bytes Ï∂îÏ∂ú
        # write_bytes: 123456
        local wb
        wb=$(grep "write_bytes:" "/proc/${pid}/io" 2>/dev/null | awk '{print $2}' || echo 0)
        total_active_bytes=$((total_active_bytes + wb))
      fi
    fi
  done
  
  echo "${total_active_bytes}"
}

# ------------------------------------------------------------
# ?ÅÌÉú Ï°∞Ìöå ?ÅÏÑ∏ Í≥ÑÏÇ∞ (?úÎ†à???úÍ±∞, ?ÅÏÑ∏ ?ÅÌÉú Î≥µÍµ¨, ?êÎü¨ ?∞ÏÑ† Í∞êÏ?)
# ------------------------------------------------------------
v2k_fleet_calculate_detailed_status() {
  local workdir="$1" manifest="$2" phase_hint="$3"
  local events_log="${workdir}/events.log"
  local govc_env="${workdir}/govc.env"
  local last_ev_json phase_raw event_raw level_raw step_str="Ready"
  local vm_total_phys=0 vm_current_phys=0 vm_sync_pct=0
  local t_gb c_gb ref_state="starting"

  # 1. Î°úÍ∑∏ Î∂ÑÏÑù (ÏµúÍ∑º 50Ï§?
  if [[ -f "${events_log}" ]]; then
    last_ev_json="$(tail -n 50 "${events_log}" 2>/dev/null | jq -sR '
      split("\n") | map(select(length>0) | fromjson?) 
      | map(select(.event | test("start|done|failed|error|progress|shutdown|snapshot|mount|dracut|update"))) 
      | last' 2>/dev/null || echo "{}")"
    
    phase_raw=$(echo "${last_ev_json}" | jq -r '.phase // ""')
    event_raw=$(echo "${last_ev_json}" | jq -r '.event // ""')
    level_raw=$(echo "${last_ev_json}" | jq -r '.level // ""')
  fi

  # 2. Step Î¨∏Ïûê???ÅÏÑ∏ Îß§Ìïë
  case "${phase_raw:-}" in
    cbt_enable)     step_str="cbt enabled" ;;
    snapshot.base)  step_str="base snap" ;;
    sync.base|base_sync) step_str="base sync" ;;
    snapshot.incr)  step_str="incr snap" ;;
    sync.incr|incr_sync) step_str="incr sync" ;;
    
    # [?ÅÏÑ∏?? Cutover Î∞?Bootstrap ?®Í≥Ñ ?∏Î∂Ñ??
    snapshot.final) step_str="final snap" ;;
    sync.final|final_sync) step_str="final sync" ;;
    linux_bootstrap)
        if [[ "${event_raw}" == *"dracut"* || "${event_raw}" == *"initramfs"* ]]; then
            step_str="initramfs rebuild"
        elif [[ "${event_raw}" == *"mount"* ]]; then
            step_str="mounting disk"
        elif [[ "${event_raw}" == *"lvm"* ]]; then
            step_str="lvm scanning"
        else
            step_str="bootstrap"
        fi
        ;;
    winpe)          step_str="winpe driver" ;;
    cutover)
        if [[ "${event_raw}" == *"shutdown"* ]]; then
            step_str="shutting down"
        elif [[ "${event_raw}" == *"start"* ]]; then
            step_str="cutover start"
        else
            step_str="cutover"
        fi
        ;;
    cleanup)        step_str="cleaning up" ;;
    *)              step_str="${phase_raw:-Ready}" ;;
  esac

  # ?ÑÎ£å ?¥Î≤§???§Î≤Ñ?ºÏù¥??
  if [[ "${phase_raw}" == "cleanup" && "${event_raw}" == *"done"* ]]; then
      step_str="done"
  fi

  # 3. Î¨ºÎ¶¨ ?©Îüâ Í≥ÑÏÇ∞
  vm_total_phys=$(jq -r '[.disks[] | (.vmdk.physical_bytes // 0)] | add' "${manifest}" 2>/dev/null || echo 0)
  if [[ "${vm_total_phys}" -le 0 && -f "${govc_env}" ]]; then
    export GOVC_URL=$(grep "GOVC_URL=" "${govc_env}" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    export GOVC_USERNAME=$(grep "GOVC_USERNAME=" "${govc_env}" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    export GOVC_PASSWORD=$(grep "GOVC_PASSWORD=" "${govc_env}" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    export GOVC_INSECURE=$(grep "GOVC_INSECURE=" "${govc_env}" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if command -v v2k_vmware_manifest_sum_vmdk_physical_bytes >/dev/null 2>&1; then
      vm_total_phys=$(v2k_vmware_manifest_sum_vmdk_physical_bytes "${manifest}" 2>/dev/null || echo 0)
    fi
  fi
  [[ "${vm_total_phys}" -le 0 ]] && vm_total_phys=$(jq -r '[.disks[].size_bytes // 0] | add' "${manifest}" 2>/dev/null || echo 0)

  local display_total
  display_total=$(awk "BEGIN {printf \"%.1f\", ${vm_total_phys}/1024/1024/1024}")

  # [?∞ÏÑ†?úÏúÑ 1] ?êÎü¨/?§Ìå® Í∞êÏ?
  if [[ "${level_raw}" == "ERROR" || "${event_raw}" == *"failed"* || "${event_raw}" == "fail" ]]; then
      jq -cn \
        --arg step "${step_str}" \
        --arg sync "Physical ${display_total}G/${display_total}G (100%)" \
        --arg state "failed" \
        --argjson history "{}" \
        '{step:$step, sync_display:$sync, refined_state:$state, history:$history}'
      return 0
  fi

  # [?∞ÏÑ†?úÏúÑ 2] ?ÑÎ£å Í∞êÏ?
  local is_cutover_done
  is_cutover_done=$(jq -r '.phases.cutover.done // false' "${manifest}" 2>/dev/null)
  
  if [[ "${is_cutover_done}" == "true" || "${step_str}" == "done" ]]; then
      jq -cn \
        --arg step "success" \
        --arg sync "Physical ${display_total}G/${display_total}G (100%)" \
        --arg state "done" \
        --argjson history "{}" \
        '{step:$step, sync_display:$sync, refined_state:$state, history:$history}'
      return 0
  fi

  # [?∞ÏÑ†?úÏúÑ 3] ÏßÑÌñâ ?ÅÌÉú ?©Îüâ Í≥ÑÏÇ∞ (Logic Fix)
  # - Í∏∞Î≥∏?ÅÏúºÎ°?Phase 2 ?åÌä∏Í∞Ä ?àÏúºÎ©?Delta Î™®ÎìúÎ°??ôÏûë?òÏ?Îß?
  # - Bootstrap, Cleanup ??"?ôÍ∏∞???¥ÌõÑ" ?®Í≥Ñ?êÏÑú??0.0GÍ∞Ä ?ÑÎãå ?ÑÏ≤¥ ?©Îüâ(100%)??Î≥¥Ïó¨Ï£ºÍ∏∞ ?ÑÌï¥
  #   Í∞ïÏ†úÎ°?Base Mode(Done)Î°?Ï∑®Í∏â?©Îãà??
  local sync_mode="base"
  local target_phase_key="sync.base"
  local force_full_display=0
  
  if [[ "${step_str}" == *"bootstrap"* || "${step_str}" == *"initramfs"* || "${step_str}" == *"mounting"* || "${step_str}" == *"lvm"* || "${step_str}" == *"cleaning"* || "${step_str}" == "done" || "${step_str}" == "success" ]]; then
     force_full_display=1
  fi

  if [[ "${force_full_display}" -eq 1 ]]; then
     sync_mode="base"
  elif [[ "${phase_hint}" == "phase2" || "${phase_raw}" == *"incr"* || "${phase_raw}" == *"final"* || "${phase_raw}" == *"cutover"* ]]; then
     sync_mode="delta"
     if [[ "${phase_raw}" == *"final"* || "${phase_raw}" == *"cutover"* ]]; then 
         target_phase_key="sync.final" 
     else 
         target_phase_key="sync.incr"
     fi
  fi

  local is_base_done=$(jq -r '.phases.base_sync.done // false' "${manifest}" 2>/dev/null)
  local history_json="{}" # (History Î°úÏßÅ?Ä ?ùÎûµ?òÍ±∞???ÑÏöî??Í∏∞Ï°¥ ?†Ï?)

  if [[ "${sync_mode}" == "base" ]]; then
    if [[ "${is_base_done}" == "true" || "${force_full_display}" -eq 1 ]]; then
      vm_current_phys=${vm_total_phys}
    else
      local did
      while IFS= read -r did; do
        [[ -n "${did}" ]] || continue
        vm_current_phys=$((vm_current_phys + $(v2k_fleet_disk_used_bytes "${manifest}" "${did}") ))
      done < <(jq -r '.disks[].disk_id // empty' "${manifest}" 2>/dev/null || true)
    fi
  else
    # Delta Mode
    local delta_stats
    delta_stats=$(tail -n 1500 "${events_log}" 2>/dev/null | jq -sR --arg p "${target_phase_key}" '
      split("\n") | map(select(length>0) | fromjson?) |
      (map(select(.phase == $p and .event == "phase_start")) | last | .ts // "") as $start_ts |
      if $start_ts == "" then {total: 0, current: 0} else
        map(select(.phase == $p and .ts >= $start_ts)) |
        {
          total: (map(select(.event == "changed_areas_fetched") | .detail.bytes // 0) | add // 0),
          current: (map(select(.event == "disk_done") | .detail.bytes_written // 0) | add // 0)
        }
      end
    ')
    vm_total_phys=$(echo "${delta_stats}" | jq -r '.total')
    vm_current_phys=$(echo "${delta_stats}" | jq -r '.current')
    
    # (Optional) Active I/O tracking here...
  fi

  local display_current
  display_current=$(awk "BEGIN {printf \"%.1f\", ${vm_current_phys}/1024/1024/1024}")
  
  if (( vm_total_phys > 0 )); then
    vm_sync_pct=$(awk "BEGIN {p=(${vm_current_phys}*100/${vm_total_phys}); printf \"%d\", (p>100?100:p)}")
  else
    if [[ "${sync_mode}" == "delta" ]]; then vm_sync_pct=100; else vm_sync_pct=0; fi
  fi
  
  # Delta Î™®Îìú?∏Îç∞ 0.0G/0.0G (100%) Î°??òÏò§Î©?Î≥¥Í∏∞ ?´ÏúºÎØÄÎ°? Î∂Ä?∏Ïä§?∏Îû©/?ÑÎ£å ?®Í≥ÑÎ©?display_total(?êÎ≥∏?¨Í∏∞) ?¨Ïö©
  if [[ "${force_full_display}" -eq 1 ]]; then
     display_current="${display_total}"
  fi

  [[ "${event_raw}" == *"start"* || "${event_raw}" == "progress" ]] && ref_state="started"

  jq -cn \
    --arg step "${step_str}" \
    --arg sync "Physical ${display_current}G/${display_total}G (${vm_sync_pct}%)" \
    --arg state "${ref_state}" \
    --argjson history "{}" \
    '{step:$step, sync_display:$sync, refined_state:$state, history:$history}'
}

v2k_fleet_human_bytes() {
  # Usage: v2k_fleet_human_bytes <bytes>
  local b="${1:-0}"
  [[ "${b}" =~ ^[0-9]+$ ]] || { printf '%s' "${b}"; return 0; }
  local units=(B K M G T P)
  local u=0
  local v="${b}"
  while (( v >= 1024 && u < ${#units[@]}-1 )); do
    v=$(( v / 1024 ))
    u=$(( u + 1 ))
  done
  printf '%s%s' "${v}" "${units[$u]}"
}

v2k_fleet_format_sync() {
  # Usage: v2k_fleet_format_sync <total_bytes> <done_bytes> <percent> <mode>
  local total="${1:-0}" done="${2:-0}" pct="${3:-0}" mode="${4:-}"
  if [[ -z "${mode}" || "${mode}" == "null" || ( "${total}" == "0" && "${done}" == "0" ) ]]; then
    echo "-"
    return 0
  fi
  printf '%s/%s (%s%%)' "$(v2k_fleet_human_bytes "${done}")" "$(v2k_fleet_human_bytes "${total}")" "${pct}"
}

# ------------------------------------------------------------
# Fleet bookkeeping paths
# ------------------------------------------------------------

v2k_fleet_mk_fleet_id() {
  date +"%Y%m%d-%H%M%S" | tr -d '\n'
}

v2k_fleet_root_dir() {
  echo "/var/lib/ablestack-v2k/fleet"
}

v2k_fleet_lock_root() {
  echo "/var/lock/ablestack-v2k/fleet"
}

v2k_fleet_slot_dir() {
  echo "$(v2k_fleet_lock_root)/nbd-slots"
}

v2k_fleet_vm_lock_dir() {
  echo "$(v2k_fleet_lock_root)/vm-locks"
}

v2k_fleet_log() {
  # Usage: v2k_fleet_log <fleet_log_path> <message>
  local f="${1:?}"; shift
  local ts
  ts="$(v2k_fleet_now_rfc3339)"
  printf '[%s] %s\n' "${ts}" "$*" | tee -a "${f}" >&2
}

v2k_fleet_state_write() {
  # Usage: v2k_fleet_state_write <state_json> <json_literal>
  local f="${1:?}" json="${2:?}"
  # Ensure json is valid before writing
  if [[ -n "${json}" ]]; then
      printf '%s\n' "${json}" > "${f}"
  fi
}

# ------------------------------------------------------------
# NBD slot semaphore (avoid /dev/nbd exhaustion)
# ------------------------------------------------------------

v2k_fleet_detect_total_nbd() {
  local n
  n="$(ls -1 /dev/nbd* 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  echo "${n}"
}

v2k_fleet_slot_init() {
  local total_nbd reserved
  total_nbd="$(v2k_fleet_detect_total_nbd)"
  reserved="${V2K_FLEET_NBD_RESERVED:-2}"
  local total_slots=$(( total_nbd - reserved ))
  if (( total_slots < 2 )); then
    total_slots=0
  fi

  local dir
  dir="$(v2k_fleet_slot_dir)"
  mkdir -p "${dir}"

  local i
  for ((i=0; i<total_slots; i++)); do
    printf '%s\n' "slot" > "${dir}/slot.$(printf '%03d' "${i}").marker" 2>/dev/null || true
  done

  echo "${total_slots}"
}

v2k_fleet_slot_try_acquire_one() {
  # Usage: v2k_fleet_slot_try_acquire_one <slot_dir> <fleet_id> <vm> out_slotname
  local dir="${1:?}" fleet_id="${2:?}" vm="${3:?}"
  local -n _out="${4:?}"
  _out=""

  local m
  for m in "${dir}"/slot.*.marker; do
    [[ -e "${m}" ]] || continue
    local base
    base="$(basename "${m}" .marker)"
    local lock="${dir}/${base}.lock.d"

    # 1. Try atomic acquire (mkdir)
    if mkdir "${lock}" 2>/dev/null; then
      printf '%s\n' "$$" > "${lock}/pid" || true
      printf '%s\n' "${vm}" > "${lock}/vm" || true
      printf '%s\n' "${fleet_id}" > "${lock}/fleet_id" || true
      printf '%s\n' "$(v2k_fleet_now_rfc3339)" > "${lock}/ts" || true
      _out="${base}"
      return 0
    fi

    # 2. Stale lock check (Zombie cleanup)
    if [[ -f "${lock}/pid" ]]; then
      local owner_pid
      owner_pid="$(cat "${lock}/pid" 2>/dev/null || true)"
      if [[ -n "${owner_pid}" ]] && ! kill -0 "${owner_pid}" 2>/dev/null; then
        rm -rf "${lock}" 2>/dev/null || true
        if mkdir "${lock}" 2>/dev/null; then
          printf '%s\n' "$$" > "${lock}/pid" || true
          printf '%s\n' "${vm}" > "${lock}/vm" || true
          printf '%s\n' "${fleet_id}" > "${lock}/fleet_id" || true
          printf '%s\n' "$(v2k_fleet_now_rfc3339)" > "${lock}/ts" || true
          _out="${base}"
          return 0
        fi
      fi
    fi
  done
  return 1
}

v2k_fleet_slot_acquire() {
  # Usage: v2k_fleet_slot_acquire <n> <fleet_id> <vm> out_slots_array
  local need="${1:?}" fleet_id="${2:?}" vm="${3:?}"
  local -n _out="${4:?}"
  _out=()

  local dir
  dir="$(v2k_fleet_slot_dir)"
  mkdir -p "${dir}"

  if (( need <= 0 )); then
    return 0
  fi
  local total_markers
  total_markers="$(ls -1 "${dir}"/slot.*.marker 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -z "${total_markers}" || "${total_markers}" == "0" ]]; then
    return 0
  fi

  local sleep_sec="${V2K_FLEET_SLOT_WAIT_SEC:-1}"

  while true; do
    local -a got=()
    local one
    local ok=1
    for ((k=0; k<need; k++)); do
      one=""
      if v2k_fleet_slot_try_acquire_one "${dir}" "${fleet_id}" "${vm}" one; then
        got+=("${one}")
      else
        ok=0
        break
      fi
    done

    if (( ok == 1 )); then
      _out=("${got[@]}")
      return 0
    fi

    if (( ${#got[@]} > 0 )); then
      v2k_fleet_slot_release got
    fi
    sleep "${sleep_sec}"
  done
}

v2k_fleet_slot_release() {
  # Usage: v2k_fleet_slot_release slots_array
  local -n _slots="${1:?}"
  local dir
  dir="$(v2k_fleet_slot_dir)"
  local s
  for s in "${_slots[@]}"; do
    [[ -n "${s}" ]] || continue
    rm -rf "${dir}/${s}.lock.d" 2>/dev/null || true
  done
}

# ------------------------------------------------------------
# VM lock (avoid running same VM concurrently)
# ------------------------------------------------------------

v2k_fleet_vm_lock_acquire() {
  local vm="${1:?}" lockdir
  lockdir="$(v2k_fleet_vm_lock_dir)"
  mkdir -p "${lockdir}"
  
  local lock="${lockdir}/${vm}.lock.d"
  
  # 1. Try atomic acquire
  if mkdir "${lock}" 2>/dev/null; then
    printf '%s\n' "$$" > "${lock}/pid" || true
    return 0
  fi
  
  # 2. Stale VM lock check
  if [[ -f "${lock}/pid" ]]; then
      local owner_pid
      owner_pid="$(cat "${lock}/pid" 2>/dev/null || true)"
      if [[ -n "${owner_pid}" ]] && ! kill -0 "${owner_pid}" 2>/dev/null; then
          rm -rf "${lock}" 2>/dev/null || true
          if mkdir "${lock}" 2>/dev/null; then
              printf '%s\n' "$$" > "${lock}/pid" || true
              return 0
          fi
      fi
  fi
  
  return 1
}

v2k_fleet_vm_lock_release() {
  local vm="${1:?}" lockdir
  lockdir="$(v2k_fleet_vm_lock_dir)"
  rm -rf "${lockdir}/${vm}.lock.d" 2>/dev/null || true
}

# ------------------------------------------------------------
# Phase2 workdir discovery (phase1 done only)
# ------------------------------------------------------------

v2k_fleet_vm_has_phase1_done() {
  local vm="${1:?}"
  local root="/var/lib/ablestack-v2k/${vm}"
  [[ -d "${root}" ]] || return 1
  local m
  for m in "${root}"/*/manifest.json; do
    [[ -f "${m}" ]] || continue
    local p1
    p1="$(jq -r '.runtime.split.phase1.done // false' "${m}" 2>/dev/null || echo false)"
    if [[ "${p1}" == "true" ]]; then
      return 0
    fi
  done
  return 1
}

v2k_fleet_find_latest_workdir() {
  # Usage: v2k_fleet_find_latest_workdir <vm> out_workdir
  local vm="${1:?}"
  local -n _out="${2:?}"
  _out=""

  local root="/var/lib/ablestack-v2k/${vm}"
  [[ -d "${root}" ]] || return 1

  local best="" best_mtime=0
  local m
  for m in "${root}"/*/manifest.json; do
    [[ -f "${m}" ]] || continue
    
    local cand_dir
    cand_dir="$(dirname "${m}")"

    local e="${cand_dir}/events.log"
    local mt=0
    if [[ -f "${e}" ]]; then
      mt="$(stat -c %Y "${e}" 2>/dev/null || echo 0)"
    else
      mt="$(stat -c %Y "${m}" 2>/dev/null || echo 0)"
    fi

    if (( mt > best_mtime )); then
      best_mtime="${mt}"
      best="${cand_dir}"
    fi
  done

  [[ -n "${best}" ]] || return 1
  _out="${best}"
}

v2k_fleet_find_phase2_workdir() {
  # Usage: v2k_fleet_find_phase2_workdir <vm> out_workdir
  local vm="${1:?}"
  local -n _out="${2:?}"
  _out=""

  local root="/var/lib/ablestack-v2k/${vm}"
  [[ -d "${root}" ]] || return 1

  local best="" best_mtime=0
  local m
  for m in "${root}"/*/manifest.json; do
    [[ -f "${m}" ]] || continue
    local p1 p2
    p1="$(jq -r '.runtime.split.phase1.done // false' "${m}" 2>/dev/null || echo false)"
    [[ "${p1}" == "true" ]] || continue
    p2="$(jq -r '.runtime.split.phase2.done // false' "${m}" 2>/dev/null || echo false)"
    [[ "${p2}" == "true" ]] && continue

    local cand_dir
    cand_dir="$(dirname "${m}")"

    local e="${cand_dir}/events.log"
    local mt=0
    if [[ -f "${e}" ]]; then
      mt="$(stat -c %Y "${e}" 2>/dev/null || echo 0)"
    else
      mt="$(stat -c %Y "${m}" 2>/dev/null || echo 0)"
    fi

    if (( mt > best_mtime )); then
      best_mtime="${mt}"
      best="${cand_dir}"
    fi
  done

  [[ -n "${best}" ]] || return 1
  _out="${best}"
}

v2k_fleet_update_state_simple() {
  local state_json="${1:?}" vm="${2:?}" phase="${3:?}" state="${4:?}" workdir="${5:-}"
  v2k_fleet_state_write "${state_json}" "$(jq -cn --arg vm "${vm}" --arg phase "${phase}" --arg state "${state}" --arg workdir "${workdir}" --arg ts "$(v2k_fleet_now_rfc3339)" '{vm:$vm,phase:$phase,state:$state,workdir:$workdir,updated_at:$ts}')"
}

# ------------------------------------------------------------
# Core Manager Logic (Runs in Background)
# ------------------------------------------------------------

_v2k_fleet_run_core() {
  # Usage: _v2k_fleet_run_core <fleet_id> <split> <vm_raw> <extra_args...>
  local fleet_id="${1:?}"
  local split="${2:?}"
  local vm_raw="${3:?}"
  shift 3
  local -a extra_args=()
  if (( $# > 0 )); then
    extra_args=("$@")
  fi

  local out_dir
  out_dir="$(v2k_fleet_root_dir)/${fleet_id}"
  local fleet_log="${out_dir}/fleet.log"
  
  # Re-parse VMs inside the background process
  local -a vms=()
  v2k_fleet_parse_vm_csv "${vm_raw}" vms

  local total_slots
  total_slots="$(v2k_fleet_slot_init)"
  v2k_fleet_log "${fleet_log}" "fleet_id=${fleet_id} split=${split} vms=${#vms[@]} total_slots=${total_slots} slots_per_vm=2 reserved=${V2K_FLEET_NBD_RESERVED:-2}"

  local -A pid_of=()
  local -A workdir_of=()
  local -A slots_of=()
  local -A state_json_of=()

  # Trap in background process
  trap '
    v2k_fleet_log "${fleet_log:-/dev/stderr}" "[fleet] Interrupted! Cleaning up..."
    for p in "${pid_of[@]-}"; do
      [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    for vm_key in "${!slots_of[@]}"; do
        local s_str="${slots_of[$vm_key]-}"
        if [[ -n "$s_str" ]]; then
            local -a rel=($s_str)
            v2k_fleet_slot_release rel
        fi
    done
    for vm_key in "${!pid_of[@]}"; do
        v2k_fleet_vm_lock_release "$vm_key" || true
    done
    exit 130
  ' INT TERM

  local vm
  for vm in "${vms[@]}"; do
    local state_json="${out_dir}/state/${vm}.json"
    state_json_of["${vm}"]="${state_json}"
    v2k_fleet_update_state_simple "${state_json}" "${vm}" "${split}" "queued" ""
  done

  local slots_per_vm=2

  for vm in "${vms[@]}"; do
    if [[ "${split}" == "phase2" ]]; then
      if ! v2k_fleet_vm_has_phase1_done "${vm}"; then
        v2k_fleet_log "${fleet_log}" "[${vm}] phase2 skip: no phase1-done history found"
        v2k_fleet_update_state_simple "${state_json_of[${vm}]}" "${vm}" "${split}" "skipped" ""
        continue
      fi

      local wd=""
      if ! v2k_fleet_find_phase2_workdir "${vm}" wd; then
        v2k_fleet_log "${fleet_log}" "[${vm}] phase2 skip: could not select workdir"
        v2k_fleet_update_state_simple "${state_json_of[${vm}]}" "${vm}" "${split}" "skipped" ""
        continue
      fi
      workdir_of["${vm}"]="${wd}"

      if [[ ! -f "${wd}/vddk.cred" ]]; then
          v2k_fleet_log "${fleet_log}" "[${vm}] phase2 fail: credential file (vddk.cred) not found in ${wd}"
          v2k_fleet_update_state_simple "${state_json_of[${vm}]}" "${vm}" "${split}" "failed" "${wd}"
          continue
      fi
    fi

    if ! v2k_fleet_vm_lock_acquire "${vm}"; then
      v2k_fleet_log "${fleet_log}" "[${vm}] skip: VM is already running (lock exists)"
      v2k_fleet_update_state_simple "${state_json_of[${vm}]}" "${vm}" "${split}" "skipped" "${workdir_of[${vm}]-}"
      continue
    fi

    v2k_fleet_update_state_simple "${state_json_of[${vm}]}" "${vm}" "${split}" "waiting_slots" "${workdir_of[${vm}]-}"
    local -a held=()
    v2k_fleet_slot_acquire "${slots_per_vm}" "${fleet_id}" "${vm}" held
    slots_of["${vm}"]="${held[*]}"

    v2k_fleet_update_state_simple "${state_json_of[${vm}]}" "${vm}" "${split}" "running" "${workdir_of[${vm}]-}"
    
    local state_dir="${out_dir}/state"
    local state_json="${state_dir}/${vm}.json"
    local outlog="${out_dir}/${vm}.out"

    local cmd
    cmd="$(command -v ablestack_v2k || true)"
    
    local -a argv=()
    if [[ -n "${workdir_of[${vm}]-}" ]]; then
      argv+=("--workdir" "${workdir_of[${vm}]}")
    fi
    argv+=("run" "--foreground" "--split" "${split}" "--vm" "${vm}")
    
    if (( ${#extra_args[@]} > 0 )); then
      argv+=("${extra_args[@]}")
    fi

    v2k_fleet_state_write "${state_json}" "$(jq -cn --arg vm "${vm}" --arg phase "${split}" --arg state "starting" --arg workdir "${workdir_of[${vm}]-}" --arg ts "$(v2k_fleet_now_rfc3339)" '{vm:$vm,phase:$phase,state:$state,workdir:$workdir,updated_at:$ts}')"
    v2k_fleet_log "${fleet_log}" "[${vm}] spawn: ${cmd} ${argv[*]}"

    "${cmd}" "${argv[@]}" >>"${outlog}" 2>&1 &
    local pid=$!
    pid_of["${vm}"]="${pid}"
  done

  local failed=0
  for vm in "${vms[@]}"; do
    local pid="${pid_of[${vm}]-}"
    [[ -n "${pid}" ]] || continue
    
    if wait "${pid}"; then
      v2k_fleet_log "${fleet_log}" "[${vm}] done (rc=0)"
      v2k_fleet_update_state_simple "${state_json_of[${vm}]}" "${vm}" "${split}" "done" "${workdir_of[${vm}]-}"
    else
      local rc=$?
      v2k_fleet_log "${fleet_log}" "[${vm}] failed (rc=${rc})"
      
      local outlog="${out_dir}/${vm}.out"
      if [[ -f "${outlog}" ]]; then
          local err_tail
          err_tail="$(tail -n 10 "${outlog}" 2>/dev/null || true)"
          if [[ -n "${err_tail}" ]]; then
              v2k_fleet_log "${fleet_log}" ">> [${vm}] Last 10 lines of output:"
              while IFS= read -r line; do
                  v2k_fleet_log "${fleet_log}" "   ${line}"
              done <<< "${err_tail}"
          fi
      fi
      
      v2k_fleet_update_state_simple "${state_json_of[${vm}]}" "${vm}" "${split}" "failed" "${workdir_of[${vm}]-}"
      failed=1
    fi

    local slots_str="${slots_of[${vm}]-}"
    if [[ -n "${slots_str}" ]]; then
      local -a rel=()
      # shellcheck disable=SC2206
      rel=( ${slots_str} )
      v2k_fleet_slot_release rel
    fi
    v2k_fleet_vm_lock_release "${vm}" || true
  done

  if (( failed == 1 )); then
    v2k_fleet_log "${fleet_log}" "fleet result: FAILED (one or more VMs)"
    exit 2
  fi
  v2k_fleet_log "${fleet_log}" "fleet result: OK"
}

# ------------------------------------------------------------
# Main Command (Foreground Wrapper)
# ------------------------------------------------------------

v2k_fleet_cmd_run() {
  local vm_raw="" split=""
  v2k_fleet_extract_opt "--vm" vm_raw "$@" || v2k_fleet_die "fleet run requires --vm"
  v2k_fleet_extract_opt "--split" split "$@" || v2k_fleet_die "fleet run requires --split phase1|phase2"
  [[ "${split}" == "phase1" || "${split}" == "phase2" ]] || v2k_fleet_die "fleet supports only --split phase1|phase2"

  local -a vms=()
  v2k_fleet_parse_vm_csv "${vm_raw}" vms
  
  # [MODIFIED] Allow single VM (>=1)
  (( ${#vms[@]} >= 1 )) || v2k_fleet_die "fleet requires multiple VMs in --vm (comma-separated)"

  # --------------------------------------------------------------------------
  # [FIX START] Idempotency Check: Filter out completed VMs
  # VM ?∞Ïù¥?∞Îäî 'fleet' ?¥ÎçîÍ∞Ä ?ÑÎãå '/var/lib/ablestack-v2k/<VM_NAME>'???àÏäµ?àÎã§.
  # --------------------------------------------------------------------------
  local -a pending_vms=()
  
  # [?òÏ†ï] VM ?∞Ïù¥?∞Í? ?àÎäî ?§Ï†ú Î£®Ìä∏ ?îÎ†â?†Î¶¨ ÏßÄ??
  local data_root="${V2K_WORKDIR:-/var/lib/ablestack-v2k}"

  for vm in "${vms[@]}"; do
      local skip=0
      # [?òÏ†ï] VMÎ≥??îÎ†â?†Î¶¨ Í≤ΩÎ°ú ?òÏ†ï (fleet ?úÏô∏)
      local current_vm_dir="${data_root}/${vm}"
      
      # ÏµúÏã† Run ID Ï°∞Ìöå
      local latest_run_id=""
      if [[ -d "${current_vm_dir}" ]]; then
          latest_run_id=$(ls -1t "${current_vm_dir}" 2>/dev/null | head -n 1 || true)
      fi

      if [[ -n "${latest_run_id}" ]]; then
          local current_manifest="${current_vm_dir}/${latest_run_id}/manifest.json"
          if [[ -f "${current_manifest}" ]]; then
              local is_done="false"
              
              # Split Î≥Ä?òÏóê ?∞Îùº Í≤Ä?¨Ìï† JSON ??Î∂ÑÍ∏∞
              if [[ "${split}" == "phase1" ]]; then
                  # Phase 1 ?îÏ≤≠ -> Base Sync ?ÑÎ£å ?¨Î? ?ïÏù∏
                  is_done=$(jq -r '.phases.base_sync.done // false' "${current_manifest}" 2>/dev/null)
              else
                  # Phase 2 ?îÏ≤≠ -> Cutover ?ÑÎ£å ?¨Î? ?ïÏù∏
                  is_done=$(jq -r '.phases.cutover.done // false' "${current_manifest}" 2>/dev/null)
              fi
              
              # ?¥Îãπ ?®Í≥ÑÍ∞Ä ?¥Î? ?ÑÎ£å?òÏóàÍ≥? Í∞ïÏ†ú ?§Ìñâ ?åÎûòÍ∑∏Í? ?ÜÏúºÎ©??§ÌÇµ
              if [[ "${is_done}" == "true" && "${V2K_FORCE:-0}" != "1" ]]; then
                  echo "[Fleet] Skipping VM '${vm}': Already completed (${split})."
                  skip=1
              fi
          fi
      fi

      if [[ "${skip}" -eq 0 ]]; then
          pending_vms+=("${vm}")
      fi
  done

  # Î™®Îì† VM???ÑÎ£å??Í≤ΩÏö∞ Ï¢ÖÎ£å
  if (( ${#pending_vms[@]} == 0 )); then
      echo "All requested VMs are already completed for ${split}. Nothing to do."
      exit 0
  fi

  # ?ÑÌÑ∞ÎßÅÎêú VM Î™©Î°ù?ºÎ°ú vms Î∞∞Ïó¥ Î∞?vm_raw Î¨∏Ïûê??Í∞±Ïã†
  vms=("${pending_vms[@]}")
  vm_raw=$(IFS=,; echo "${vms[*]}")
  
  echo "[Fleet] Starting fleet for ${#vms[@]} VM(s) in ${split}: ${vm_raw}"
  # --------------------------------------------------------------------------
  # [FIX END]
  # --------------------------------------------------------------------------

  # Fleet ?§Ìñâ Î°úÍ∑∏??Í∏∞Ï°¥?ÄÎ°?fleet ?¥Îçî???Ä??
  local fleet_id
  fleet_id="$(v2k_fleet_mk_fleet_id)"
  local out_dir
  out_dir="$(v2k_fleet_root_dir)/${fleet_id}"
  mkdir -p "${out_dir}/state"
  
  local fleet_log="${out_dir}/fleet.log"
  touch "${fleet_log}"

  local -a extra_args=()
  if [[ "${split}" == "phase1" ]]; then
    local i=0
    while (( i < $# )); do
      local idx=$((i+1))
      local a="${!idx}"
      case "${a}" in
        --vm|--split) i=$((i+2)); continue;;
        --vm=*|--split=*) i=$((i+1)); continue;;
        --foreground) i=$((i+1)); continue;;
      esac
      extra_args+=("${a}")
      i=$((i+1))
    done
  else
    local i=0
    while (( i < $# )); do
      local idx=$((i+1))
      local a="${!idx}"
      case "${a}" in
        --vm|--split|--vm=*|--split=*|--foreground) 
          i=$((i+1))
          if [[ "${a}" == --* && "${a}" != *=* && "${a}" != "--foreground" ]]; then
             if [[ "${a}" == "--vm" || "${a}" == "--split" ]]; then i=$((i+1)); fi
          fi
          continue
          ;;
      esac
      extra_args+=("${a}")
      i=$((i+1))
    done
  fi

  (
    # ?ÑÌÑ∞ÎßÅÎêú vm_rawÎ•??òÍ≤®Ï§çÎãà??
    _v2k_fleet_run_core "${fleet_id}" "${split}" "${vm_raw}" "${extra_args[@]+"${extra_args[@]}"}"
  ) > /dev/null 2>&1 & disown

  echo "Fleet started in background."
  echo "  Fleet ID : ${fleet_id}"
  echo "  Log File : ${fleet_log}"
  echo "  Check Status :"
  echo "    ablestack_v2k status --vm \"${vm_raw}\""
  echo ""
  
  exit 0
}

# ------------------------------------------------------------
# Status Command
# ------------------------------------------------------------

# -----------------------------------------------------------------------------
# Fleet status helpers (best-effort telemetry; does NOT affect success/failure)
# -----------------------------------------------------------------------------

v2k_fleet_manifest_get_run_id() {
  local manifest="$1"
  jq -r '.run.run_id // ""' "${manifest}" 2>/dev/null || echo ""
}

v2k_fleet_manifest_get_vm_name() {
  local manifest="$1"
  jq -r '.source.vm.name // ""' "${manifest}" 2>/dev/null || echo ""
}

v2k_fleet_used_bytes_file() {
  local path="$1"
  [[ -n "${path}" && -f "${path}" ]] || { echo 0; return 0; }
  # allocated blocks * block size (works even when qemu-img info is blocked/locked)
  stat -c '%b %B' "${path}" 2>/dev/null | awk '{print $1*$2}' || echo 0
}

v2k_fleet_used_bytes_rbd() {
  local spec="$1" # e.g. rbd:pool/image
  command -v rbd >/dev/null 2>&1 || { echo 0; return 0; }
  local img="${spec#rbd:}"
  local used
  used="$(rbd du --format json "${img}" 2>/dev/null | jq -r '
      if (.images? | type) == "array" then
        (.images | map(.used_size // .used_bytes // .used // 0) | add // 0)
      else
        (.used_size // .used_bytes // .used // .stats.used_size // 0)
      end
    ' 2>/dev/null || echo 0)"
  if [[ ! "${used}" =~ ^[0-9]+$ ]]; then
    used="$(rbd du "${img}" 2>/dev/null | awk 'NR>1 {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) {print $i; exit}}' || echo 0)"
  fi
  [[ "${used}" =~ ^[0-9]+$ ]] || used=0
  echo "${used}"
}

v2k_fleet_disk_used_bytes() {
  local manifest="$1" disk_id="$2"
  local st
  st="$(jq -r '.target.storage.type // ""' "${manifest}" 2>/dev/null || echo "")"
  local target_path
  target_path="$(jq -r --arg did "${disk_id}" '.disks[] | select(.disk_id==$did) | .transfer.target_path // ""' "${manifest}" 2>/dev/null || echo "")"

  case "${st}" in
    file)
      v2k_fleet_used_bytes_file "${target_path}"
      ;;
    rbd)
      # manifest.sh enforces rbd: prefix for rbd type
      v2k_fleet_used_bytes_rbd "${target_path}"
      ;;
    *)
      # block/unknown: best-effort not available
      echo 0
      ;;
  esac
}

v2k_fleet_cache_dir() {
  local workdir="$1"
  echo "${workdir}/.fleet-cache"
}

v2k_fleet_cache_key() {
  # sanitize to a safe filename
  local s="$1"
  echo "${s}" | tr -c 'A-Za-z0-9_.-@' '_'
}

v2k_fleet_cache_get_or_set_baseline() {
  local workdir="$1" key="$2" now_bytes="$3"
  local dir f
  dir="$(v2k_fleet_cache_dir "${workdir}")"
  mkdir -p "${dir}" 2>/dev/null || true
  f="${dir}/$(v2k_fleet_cache_key "${key}").start"
  if [[ -f "${f}" ]]; then
    cat "${f}" 2>/dev/null || echo "${now_bytes}"
    return 0
  fi
  printf '%s\n' "${now_bytes}" > "${f}" 2>/dev/null || true
  echo "${now_bytes}"
}

v2k_fleet_events_tail_valid_json() {
  local events_log="$1" tail_n="${2:-5000}"
  [[ -f "${events_log}" ]] || { echo '[]'; return 0; }
  tail -n "${tail_n}" "${events_log}" 2>/dev/null \
    | jq -sR '
        split("\n")
        | map(select(length>0) | (fromjson? // empty))
      ' 2>/dev/null || echo '[]'
}

v2k_fleet_meaningful_events() {
  # input: JSON array on stdin
  jq '
    map(
      select(.phase|tostring|IN(
        "cbt_enable",
        "snapshot.base","snapshot.incr","snapshot.final",
        "sync.base","sync.incr","sync.final",
        "cutover","cleanup"
      ))
      | select(.event|tostring|IN(
        "phase_start","phase_done","phase_skipped_by_policy",
        "disk_start","disk_done","no_changes","changed_areas_fetched",
        "start","done","error","fail","nbdkit_log",
        "policy_evaluation",
        "shutdown_guest_start","final_snapshot_start","final_sync_start","libvirt_define_start"
      ))
    )
  '
}

v2k_fleet_calc_step_progress() {
  local workdir="$1" manifest="$2" state="$3" phase_hint="$4"
  local events_log="${workdir}/events.log"
  local E M
  E="$(v2k_fleet_events_tail_valid_json "${events_log}" 8000)"
  M="$(printf '%s' "${E}" | v2k_fleet_meaningful_events 2>/dev/null || echo '[]')"

  # last meaningful event
  local last_ev
  last_ev="$(printf '%s' "${M}" | jq -c 'sort_by(.ts) | last // {}' 2>/dev/null || echo '{}')"

  local has_events
  has_events="$(printf '%s' "${M}" | jq -r 'length>0' 2>/dev/null || echo false)"

  # disk sizes + disk ids
  local disks_json
  disks_json="$(jq -c '.disks // []' "${manifest}" 2>/dev/null || echo '[]')"

  # choose step based on hint + events
  local step="" step_state="" step_label=""
  local phase="${phase_hint:-}"

  # NOTE: fleet state phase("phase1/phase2") is a runner phase, not a step phase.
  # If we use it here, step mapping will fail and STEP/SYNC will be blank.
  if [[ "${phase}" == "phase1" || "${phase}" == "phase2" ]]; then
    phase=""
  fi

  if [[ -z "${phase}" || "${phase}" == "null" ]]; then
    phase="$(printf '%s' "${last_ev}" | jq -r '.phase // ""' 2>/dev/null || echo "")"
  fi

  case "${phase}" in
    sync.base)  step="BASE_SYNC";  step_label="base sync" ;;
    sync.incr)  step="INCR_SYNC";  step_label="incr sync" ;;
    sync.final) step="FINAL_SYNC"; step_label="final sync" ;;
    snapshot.base)  step="BASE_SNAP";  step_label="base snap" ;;
    snapshot.incr)  step="INCR_SNAP";  step_label="incr snap" ;;
    snapshot.final) step="FINAL_SNAP"; step_label="final snap" ;;
    cutover)    step="CUTOVER";    step_label="cutover" ;;
    cleanup)    step="CLEANUP";    step_label="cleanup" ;;
    *) step=""; step_label="" ;;
  esac

  # step_state: starting/started/done (telemetry only)
  if [[ "${state}" == "done" || "${state}" == "failed" ]]; then
    step_state="${state}"
  else
    if [[ "${has_events}" == "true" ]]; then
      step_state="started"
    else
      step_state="starting"
    fi
  fi

  # totals/done per step
  local sync_total=0 sync_done=0 sync_pct=0 sync_kind="" sync_mode=""
  local total_bytes_base=0 total_kind_base="logical"
  local total_bytes_phys=0

  if [[ -f "${manifest}" ]]; then
    total_bytes_base="$(jq -r '[.disks[].size_bytes // 0] | add // 0' "${manifest}" 2>/dev/null || echo 0)"
    total_bytes_phys="$(jq -r '[.disks[].vmdk.physical_bytes // .disks[].source.physical_bytes // 0] | add // 0' "${manifest}" 2>/dev/null || echo 0)"
    if [[ "${total_bytes_phys}" =~ ^[0-9]+$ ]] && (( total_bytes_phys > 0 )); then
      total_kind_base="physical"
    else
      # If manifest doesn't have physical size, try govc via vmware_govc.sh (best-effort)
      if declare -F v2k_vmware_manifest_sum_vmdk_physical_bytes >/dev/null 2>&1; then
        total_bytes_phys="$(v2k_vmware_manifest_sum_vmdk_physical_bytes "${manifest}")"
      else
        total_bytes_phys=0
      fi
      if [[ "${total_bytes_phys}" =~ ^[0-9]+$ ]] && (( total_bytes_phys > 0 )); then
        total_kind_base="physical"
      else
        total_bytes_phys=0
        total_kind_base="logical"
      fi
    fi
  fi

  # helper: sum used bytes for all disks
  local disk_ids
  disk_ids="$(printf '%s' "${disks_json}" | jq -r '.[].disk_id' 2>/dev/null || true)"
  local used_sum=0
  local did
  for did in ${disk_ids}; do
    used_sum=$(( used_sum + $(v2k_fleet_disk_used_bytes "${manifest}" "${did}") ))
  done

  if [[ "${step}" == "BASE_SYNC" ]]; then
    if [[ "${total_kind_base}" == "physical" ]]; then
      sync_total="${total_bytes_phys}"
    else
      sync_total="${total_bytes_base}"
    fi
    sync_done="${used_sum}"
    sync_kind="${total_kind_base}"
    sync_mode="base"
  elif [[ "${step}" == "INCR_SYNC" || "${step}" == "FINAL_SYNC" ]]; then
    local p="sync.incr"
    [[ "${step}" == "FINAL_SYNC" ]] && p="sync.final"
    sync_mode="${p#sync.}"

    # window start ts
    local start_ts
    start_ts="$(printf '%s' "${M}" | jq -r --arg p "${p}" '
        ( [ range(0; length) | select(.[.].phase==$p and .[.].event=="phase_start") ] | last ) as $i
        | if ($i|type)=="number" then .[$i].ts else "" end
      ' 2>/dev/null || echo "")"

    # window events
    local total_delta done_event
    total_delta="$(printf '%s' "${M}" | jq -r --arg p "${p}" --arg st "${start_ts}" '
        if ($st=="") then 0 else
          ( . | map(select(.phase==$p and .ts >= $st and .event=="changed_areas_fetched") | (.detail.bytes // 0)) | add // 0 )
        end
      ' 2>/dev/null || echo 0)"
    done_event="$(printf '%s' "${M}" | jq -r --arg p "${p}" --arg st "${start_ts}" '
        if ($st=="") then 0 else
          ( . | map(select(.phase==$p and .ts >= $st and .event=="disk_done") | (.detail.bytes_written // 0)) | add // 0 )
        end
      ' 2>/dev/null || echo 0)"

    sync_total="${total_delta}"
    sync_kind="delta"

    # baseline cache for this window (progress display only)
    local run_id
    run_id="$(v2k_fleet_manifest_get_run_id "${manifest}")"
    local key="run=${run_id}|phase=${p}|start_ts=${start_ts}"
    local base_used
    base_used="$(v2k_fleet_cache_get_or_set_baseline "${workdir}" "${key}" "${used_sum}")"
    local delta_used=$(( used_sum - base_used ))
    (( delta_used < 0 )) && delta_used=0

    if [[ "${done_event}" =~ ^[0-9]+$ ]] && (( done_event > 0 )); then
      sync_done="${done_event}"
    else
      sync_done="${delta_used}"
    fi
  fi

  if (( sync_total > 0 )); then
    sync_pct=$(( (sync_done * 100) / sync_total ))
    (( sync_pct > 100 )) && sync_pct=100
  else
    sync_pct=0
  fi

  jq -cn \
    --arg step "${step}" \
    --arg step_label "${step_label}" \
    --arg step_state "${step_state}" \
    --argjson has_events "$( [[ "${has_events}" == "true" ]] && echo true || echo false )" \
    --argjson sync_total "${sync_total}" \
    --argjson sync_done "${sync_done}" \
    --argjson sync_pct "${sync_pct}" \
    --arg sync_kind "${sync_kind}" \
    --arg sync_mode "${sync_mode}" \
    --arg last_ev_ts "$(printf '%s' "${last_ev}" | jq -r '.ts // ""' 2>/dev/null || echo "")" \
    --arg last_ev_phase "$(printf '%s' "${last_ev}" | jq -r '.phase // ""' 2>/dev/null || echo "")" \
    --arg last_ev_event "$(printf '%s' "${last_ev}" | jq -r '.event // ""' 2>/dev/null || echo "")" \
    '{
      has_events:$has_events,
      step:$step,
      step_label:$step_label,
      step_state:$step_state,
      sync:{mode:$sync_mode,kind:$sync_kind,total_bytes:$sync_total,done_bytes:$sync_done,percent:$sync_pct},
      last_event:{ts:$last_ev_ts,phase:$last_ev_phase,event:$last_ev_event}
    }'
}

v2k_fleet_base_total_bytes_physical_or_logical() {
  # Args: manifest.json
  # Returns: "kind bytes" (e.g. "physical 123", "logical 456")
  local manifest="${1-}"
  [[ -n "${manifest}" && -f "${manifest}" ]] || { echo "logical 0"; return 0; }

  local logical phys
  logical="$(jq -r '[.disks[].size_bytes // 0] | add // 0' "${manifest}" 2>/dev/null || echo 0)"
  phys="$(jq -r '[.disks[].vmdk.physical_bytes // .disks[].source.physical_bytes // 0] | add // 0' "${manifest}" 2>/dev/null || echo 0)"

  if [[ "${phys}" =~ ^[0-9]+$ ]] && (( phys > 0 )); then
    echo "physical ${phys}"
    return 0
  fi

  # fallback: govc query (vmware_govc.sh)
  if declare -F v2k_vmware_manifest_sum_vmdk_physical_bytes >/dev/null 2>&1; then
    phys="$(v2k_vmware_manifest_sum_vmdk_physical_bytes "${manifest}")"
    if [[ "${phys}" =~ ^[0-9]+$ ]] && (( phys > 0 )); then
      echo "physical ${phys}"
      return 0
    fi
  fi

  [[ "${logical}" =~ ^[0-9]+$ ]] || logical=0
  echo "logical ${logical}"
}

v2k_fleet_last_step_from_events() {
  # Args: workdir
  # Returns: "step_label" or empty
  local workdir="${1-}"
  local ev="${workdir}/events.log"
  [[ -f "${ev}" ]] || { echo ""; return 0; }
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }

  local phase
  phase="$(tail -n 5000 "${ev}" 2>/dev/null | jq -sR '
    split("\n")
    | map(select(length>0) | (fromjson? // empty))
    | map(select(.phase|tostring|IN("snapshot.base","snapshot.incr","snapshot.final","sync.base","sync.incr","sync.final","cutover","cleanup")))
    | sort_by(.ts)
    | (last // {}) .phase // ""
  ' 2>/dev/null || echo "")"

  case "${phase}" in
    sync.base) echo "base sync" ;;
    sync.incr) echo "incr sync" ;;
    sync.final) echo "final sync" ;;
    snapshot.base) echo "base snap" ;;
    snapshot.incr) echo "incr snap" ;;
    snapshot.final) echo "final snap" ;;
    cutover) echo "cutover" ;;
    cleanup) echo "cleanup" ;;
    *) echo "" ;;
  esac
}

# ------------------------------------------------------------
# Status Command
# ------------------------------------------------------------

v2k_fleet_cmd_status() {
  # [FIX 1] JSON Flag Inheritance
  local vm_raw="" json_out="${V2K_JSON_OUT:-0}" watch_mode=0
  v2k_fleet_extract_opt "--vm" vm_raw "$@" || true
  
  # Check flags
  for a in "$@"; do
    [[ "$a" == "--json" ]] && json_out=1
    [[ "$a" == "--watch" ]] && watch_mode=1
  done

  # Parse requested VMs into array
  local -a filter_vms=()
  v2k_fleet_parse_vm_csv "${vm_raw}" filter_vms

  # [FIX] Correct Root Dir Path
  local root_dir="${V2K_WORKDIR:-/var/lib/ablestack-v2k}"
  [[ -d "${root_dir}" ]] || { echo "No data found in ${root_dir}"; return 0; }

  local -a items_json=()
  local d vm_name

  # Iterate through all VM directories in the work root
  for d in "${root_dir}"/*; do
    [[ -d "$d" ]] || continue
    vm_name="$(basename "$d")"

    # Skip metadata directory
    [[ "${vm_name}" == "fleet" ]] && continue

    # Filter by VM name if provided
    if (( ${#filter_vms[@]} > 0 )); then
        local match=0
        for f in "${filter_vms[@]}"; do
            if [[ "${f}" == "${vm_name}" ]]; then
                match=1
                break
            fi
        done
        [[ "${match}" -eq 0 ]] && continue
    fi

    # Find latest run_id
    local latest_run_id
    latest_run_id=$(ls -1t "$d" 2>/dev/null | head -n 1 || true)
    
    if [[ -z "${latest_run_id}" ]]; then
      continue
    fi

    local current_vm_dir="$d/${latest_run_id}"
    local current_manifest="${current_vm_dir}/manifest.json"
    local phase="unknown"
    local state="unknown"
    local step="-"
    local sync="-"
    local history="{}"

    if [[ -f "${current_manifest}" ]]; then
      # 1. Determine Phase (Initial Guess)
      local p1_done p2_done
      p1_done=$(jq -r '.phases.base_sync.done // false' "${current_manifest}" 2>/dev/null)
      p2_done=$(jq -r '.phases.cutover.done // false' "${current_manifest}" 2>/dev/null)
      
      if [[ "${p2_done}" == "true" ]]; then
        phase="phase2" # Completed
      elif [[ "${p1_done}" == "true" ]]; then
        phase="phase1" # Default to phase1 unless active Phase 2 work is detected
      else
        phase="phase1"
      fi
      
      # 2. Determine State/Step/Sync from Detail Logic
      local detail_json
      detail_json="$(v2k_fleet_calculate_detailed_status "${current_vm_dir}" "${current_manifest}" "${phase}")"
      
      state=$(echo "${detail_json}" | jq -r '.refined_state // ""')
      [[ -z "${state}" ]] && state="started" # fallback

      step=$(echo "${detail_json}" | jq -r '.step // "Ready"')
      sync=$(echo "${detail_json}" | jq -r '.sync_display // "-"')
      
      if [[ "${json_out}" -eq 1 ]]; then
        history=$(echo "${detail_json}" | jq -c '.history // {}')
      fi

      # --------------------------------------------------------------------------
      # [FIX 3] Phase Promotion Logic (Strict Inclusion - Incr Excluded)
      # 'incr sync'??Phase 1?ºÎ°ú ?†Ï??òÍ≥†, 
      # ?§Ï†ú Cutover Î∞?Final Sync Í¥Ä???ëÏóÖÎß?Phase 2Î°??πÍ≤©?©Îãà??
      # --------------------------------------------------------------------------
      local is_phase2_activity=0
      
      # 1) ÏµúÏ¢Ö ?ôÍ∏∞??final) Î∞??§ÎÉÖ??(Ï¶ùÎ∂Ñ incr ?úÏô∏!)
      if [[ "${step}" == *"final"* ]]; then
          is_phase2_activity=1
      fi
      
      # 2) Ïª∑Ïò§Î≤?Î∞?Ï¢ÖÎ£å
      if [[ "${step}" == *"cutover"* || "${step}" == *"shut"* ]]; then
          is_phase2_activity=1
      fi
      
      # 3) Î∂Ä?∏Ïä§?∏Îû© Í¥Ä??(initramfs, mount, lvm, winpe)
      if [[ "${step}" == *"bootstrap"* || "${step}" == *"initramfs"* || "${step}" == *"mount"* || "${step}" == *"lvm"* || "${step}" == *"winpe"* ]]; then
          is_phase2_activity=1
      fi
      
      # 4) ?¥Î¶∞??Î∞??ÑÎ£å
      if [[ "${step}" == *"clean"* || "${step}" == "success" || "${step}" == "done" ]]; then
          # ?? Phase 1 ?ÑÎ£å ?ÅÌÉú(done)Í∞Ä ?ÑÎãà???§Ï†ú ?ëÏóÖ ?ÑÎ£å(done)??Í≤ΩÏö∞?¨Ïïº ??
          # ?¥Îäî p2_done Ï≤¥ÌÅ¨?Ä Í≤∞Ìï©?òÏñ¥ Ï≤òÎ¶¨??
          if [[ "${p2_done}" == "true" ]]; then
              is_phase2_activity=1
          fi
      fi

      # Ï°∞Í±¥ Ï∂©Ï°± ???πÍ≤©
      if [[ "${is_phase2_activity}" -eq 1 ]]; then
          phase="phase2"
      fi

      # [Phase 1 ?ÑÎ£å ?ÅÌÉú ?§Î≤Ñ?ºÏù¥??
      # ?πÍ≤©?òÏ? ?äÍ≥† ?¨Ï†Ñ??phase1 ?ÅÌÉú?ºÎ©¥ (Ï¶? incr sync???ÄÍ∏??ÅÌÉú),
      # ?ÑÎ£å ?åÎûòÍ∑∏Î? ?ïÏù∏?òÏó¨ ?ÅÌÉúÎ•??úÏãú?©Îãà??
      if [[ "${phase}" == "phase1" && "${p1_done}" == "true" && "${state}" != "failed" ]]; then
          # Ï¶ùÎ∂Ñ ?ôÍ∏∞??incr) Ï§ëÏùº ?åÎäî 'started/running' ?ÅÌÉúÎ•?Í∑∏Î?Î°?Î≥¥Ïó¨Ï§?(??ñ¥?∞Í∏∞ Î∞©Ï?)
          if [[ "${step}" == *"incr"* ]]; then
              : # Keep current state (e.g., Phase 1 | started | incr sync)
          else
              # Í∑??∏Ïùò Í≤ΩÏö∞(run, Ready ???†Ìú¥ ?ÅÌÉú)?êÎäî 'Phase2 Ready'Î°??úÏãú
              state="done"
              step="Phase2 Ready"
          fi
      fi
    fi

    local short_wd="${vm_name}/${latest_run_id}"

    if [[ "${json_out}" -eq 1 ]]; then
      items_json+=("$(jq -cn --arg vm "${vm_name}" --arg ph "${phase}" --arg st "${state}" \
        --arg step "${step}" --arg sync "${sync}" --arg wd "${short_wd}" --argjson hist "${history}" \
        '{vm:$vm, phase:$ph, state:$st, step:$step, sync:$sync, workdir:$wd, history:$hist}')")
    else
       # Table row format: VM PHASE STATE STEP SYNC WORKDIR
       items_json+=("${vm_name}|${phase}|${state}|${step}|${sync}|${short_wd}")
    fi
  done

  # Output
  if [[ "${json_out}" -eq 1 ]]; then
    local joined
    joined=$(printf ",%s" "${items_json[@]}")
    joined="${joined:1}"
    echo "[${joined}]"
  else
    if (( ${#items_json[@]} == 0 )); then
        if (( ${#filter_vms[@]} > 0 )); then
            echo "No status found for specified VMs: ${vm_raw}"
        else
            echo "No VMs found."
        fi
    else
        {
          echo "VM|PHASE|STATE|STEP|SYNC(Physical)|WORKDIR"
          echo "--------------------|--------|----------|---------------|----------------------|--------------------"
          for item in "${items_json[@]}"; do
            echo "${item}"
          done
        } | column -t -s "|"
    fi
  fi
}
