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

v2k_fleet_cmd_status() {
  local vm_raw=""
  v2k_fleet_extract_opt "--vm" vm_raw "$@" || v2k_fleet_die "fleet status requires --vm"
  local -a vms=()
  v2k_fleet_parse_vm_csv "${vm_raw}" vms
  
  # [MODIFIED] Allow single VM (>=1)
  (( ${#vms[@]} >= 1 )) || v2k_fleet_die "fleet status requires multiple VMs"

  local json_out=0
  if [[ "${V2K_JSON_OUT:-0}" == "1" ]] || v2k_fleet_has_opt "--json" "$@"; then
    json_out=1
  fi

  local fleet_root
  fleet_root="$(v2k_fleet_root_dir)"
  local -a items_json=()
  local vm
  for vm in "${vms[@]}"; do
    local latest_state=""
    latest_state="$(ls -1t "${fleet_root}"/*/state/"${vm}".json 2>/dev/null | head -n 1 || true)"

    local state="unknown" phase="" updated_at="" extra="{}" workdir=""
    
    if [[ -n "${latest_state}" && -f "${latest_state}" ]]; then
      state="$(jq -r '.state // "unknown"' "${latest_state}" 2>/dev/null || echo "unknown")"
      phase="$(jq -r '.phase // ""' "${latest_state}" 2>/dev/null || echo "")"
      updated_at="$(jq -r '.updated_at // ""' "${latest_state}" 2>/dev/null || echo "")"
      workdir="$(jq -r '.workdir // ""' "${latest_state}" 2>/dev/null || echo "")"
      extra="$(jq -c '.' "${latest_state}" 2>/dev/null || echo '{}')"
    fi

    if [[ -z "${workdir}" ]]; then
       v2k_fleet_find_latest_workdir "${vm}" workdir || true
    fi

    local manifest="${workdir}/manifest.json"
    local p1="false" p2="false" base_done="false" incr_max="0"
    
    if [[ -n "${workdir}" && -f "${manifest}" ]]; then
        p1="$(jq -r '.runtime.split.phase1.done // false' "${manifest}" 2>/dev/null || echo false)"
        p2="$(jq -r '.runtime.split.phase2.done // false' "${manifest}" 2>/dev/null || echo false)"
        base_done="$(jq -r '[.disks[].transfer.base_done] | all' "${manifest}" 2>/dev/null || echo false)"
        incr_max="$(jq -r '[.disks[].transfer.incr_seq // 0] | max' "${manifest}" 2>/dev/null || echo 0)"
    fi

    if [[ "${state}" == "unknown" ]]; then
      if [[ "${p2}" == "true" ]]; then
        state="done"
        phase="phase2"
      elif [[ "${p1}" == "true" ]]; then
        state="ready"
        phase="phase2"
      elif [[ -n "${workdir}" ]]; then
        state="stopped"
      fi
      if [[ -z "${updated_at}" ]]; then
         updated_at="$(v2k_fleet_now_rfc3339)"
      fi
    fi

    items_json+=("$(jq -cn \
      --arg vm "${vm}" \
      --arg phase "${phase}" \
      --arg state "${state}" \
      --arg workdir "${workdir}" \
      --arg updated_at "${updated_at}" \
      --argjson base_done "${base_done}" \
      --argjson incr_max "${incr_max}" \
      --argjson phase1_done "${p1}" \
      --argjson phase2_done "${p2}" \
      --argjson fleet_state "${extra}" \
      '{vm:$vm,phase:$phase,state:$state,workdir:$workdir,updated_at:$updated_at,progress:{base_done:$base_done,incr_max:$incr_max,phase1_done:$phase1_done,phase2_done:$phase2_done},fleet_state:$fleet_state}' \
    )")
  done

  if (( json_out == 1 )); then
    local json_array
    if (( ${#items_json[@]} > 0 )); then
       json_array="$(printf '%s\n' "${items_json[@]}" | jq -s '.')"
    else
       json_array="[]"
    fi
    
    jq -cn --arg ts "$(v2k_fleet_now_rfc3339)" --argjson vms "${json_array}" '{ok:true,timestamp:$ts,vms:$vms}'
    return 0
  fi

  printf '%-24s %-8s %-12s %-8s %-24s\n' "VM" "PHASE" "STATE" "INCR" "WORKDIR"
  printf '%-24s %-8s %-12s %-8s %-24s\n' "------------------------" "--------" "------------" "--------" "------------------------"
  local item
  for item in "${items_json[@]}"; do
    local name phase state workdir incr
    name="$(echo "${item}" | jq -r '.vm')"
    phase="$(echo "${item}" | jq -r '.phase')"
    state="$(echo "${item}" | jq -r '.state')"
    incr="$(echo "${item}" | jq -r '.progress.incr_max')"
    workdir="$(echo "${item}" | jq -r '.workdir')"
    workdir="${workdir##*/ablestack-v2k/}"
    printf '%-24s %-8s %-12s %-8s %-24s\n' "${name}" "${phase}" "${state}" "${incr}" "${workdir:0:24}"
  done
}
