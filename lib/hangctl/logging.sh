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

# Commit 01 scope:
# - Provide scan_id generator and a stub logger.
# - JSONL file logging will be implemented in commit 03.
# Commit 02:
# - still stub; runtime dirs are ensured in config.sh
# Commit 03:
# - JSONL events logging with fixed schema
# - scan lifecycle events

hangctl_log_rotate_if_needed() {
  local log_file="${HANGCTL_EVENTS_LOG}"
  local max_size_mb="${HANGCTL_LOG_MAX_SIZE_MB}"
  local rotate_count="${HANGCTL_LOG_ROTATE_COUNT}"

  [[ -f "${log_file}" ]] || return 0

  # ?„ìž¬ ?¬ê¸° ?•ì¸ (KB ?¨ìœ„)
  local current_size_kb
  current_size_kb=$(du -k "${log_file}" | cut -f1)
  local max_size_kb=$(( max_size_mb * 1024 ))

  if [[ "${current_size_kb}" -ge "${max_size_kb}" ]]; then
    # ?Œì „ ?œìž‘ ë¡œê·¸ ê¸°ë¡
    hangctl_log_event "logging" "log.rotate" "ok" "" "" "" "reason=size_limit size_kb=${current_size_kb}"
    
    # ?´ì „ ë°±ì—… ?Œì¼??ë°€?´ë‚´ê¸?(Rotation)
    local i
    for ((i=rotate_count-1; i>=1; i--)); do
      [[ -f "${log_file}.${i}" ]] && mv -f "${log_file}.${i}" "${log_file}.$((i+1))"
    done
    mv -f "${log_file}" "${log_file}.1"
    
    # ??ë¡œê·¸ ?Œì¼ ?ì„± ë°?ê¶Œí•œ ?¤ì •
    touch "${log_file}"
    chmod 0644 "${log_file}" 2>/dev/null || true
  fi
}

hangctl_new_scan_id() {
  # Example: 20260211-191500-acde12
  local ts rid
  ts="$(date +"%Y%m%d-%H%M%S")"
  rid="$(hangctl_rand_id)"
  echo "${ts}-${rid}"
}

HANGCTL_SCAN_ID=""

hangctl_set_scan_id() {
  HANGCTL_SCAN_ID="${1-}"
}

hangctl_get_scan_id() {
  echo "${HANGCTL_SCAN_ID}"
}

hangctl__json_escape() {
  # Escape string for JSON value (minimal escaping).
  # usage: hangctl__json_escape "raw"
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  echo -n "${s}"
}

hangctl__details_kv_to_json() {
  # Convert "k=v k2=v2" into {"k":"v","k2":"v2"} (best effort).
  # - Values are treated as strings.
  # - Keys must not contain '='.
  # - Tokens are separated by spaces (do not put spaces around '=').
  local kvs="${1-}"
  if [[ -z "${kvs}" ]]; then
    echo -n ""
    return 0
  fi

  local out="{"
  local first="1"
  local token k v
  for token in ${kvs}; do
    k="${token%%=*}"
    v="${token#*=}"
    [[ -z "${k}" ]] && continue
    if [[ "${first}" == "1" ]]; then
      first="0"
    else
      out+=","
    fi
    out+="\"$(hangctl__json_escape "${k}")\":\"$(hangctl__json_escape "${v}")\""
  done
  out+="}"
  echo -n "${out}"
}

hangctl__jsonl_write_safe() {
  # Ensure each line written to events.log is a JSON OBJECT.
  # If 'line' is not a JSON object, wrap it as {"ts":..,"stage":"logging","event":"log.invalid","result":"warn","details":{"raw":...}}
  local line="${1-}"
  local ts
  ts="$(date -Is)"

  # Fast-path: object-like line
  if [[ "${line}" == \{*} ]]; then
    printf "%s\n" "${line}" >> "${HANGCTL_EVENTS_LOG}"
    return 0
  fi

  # Fallback wrap (escape quotes minimally)
  local raw="${line//\\/\\\\}"
  raw="${raw//\"/\\\"}"
  printf "%s\n" \
    "{\"ts\":\"${ts}\",\"stage\":\"logging\",\"event\":\"log.invalid\",\"result\":\"warn\",\"details\":{\"raw\":\"${raw}\"}}" \
    >> "${HANGCTL_EVENTS_LOG}"
  return 0
}

hangctl_log_event() {
  # Fixed schema JSONL logger (append-only)
  #
  # usage:
  #   hangctl_log_event <stage> <event> <result> <vm> <incident_id> <rc> <details_kv>
  #
  # notes:
  # - elapsed_ms is optional and currently not emitted in commit 03 (reserved)
  # - rc is optional; pass "" to omit
  local stage="${1-}"
  local event="${2-}"
  local result="${3-}"
  local vm="${4-}"
  local incident_id="${5-}"
  local rc="${6-}"
  local details_kv="${7-}"

  local ts scan_id
  ts="$(hangctl_now_iso8601)"
  scan_id="$(hangctl_get_scan_id)"
  if [[ -z "${scan_id}" ]]; then
    scan_id="$(hangctl_new_scan_id)"
    hangctl_set_scan_id "${scan_id}"
  fi

  local json="{"
  json+="\"ts\":\"$(hangctl__json_escape "${ts}")\""
  json+=",\"scan_id\":\"$(hangctl__json_escape "${scan_id}")\""
  if [[ -n "${vm}" ]]; then
    json+=",\"vm\":\"$(hangctl__json_escape "${vm}")\""
  fi
  if [[ -n "${incident_id}" ]]; then
    json+=",\"incident_id\":\"$(hangctl__json_escape "${incident_id}")\""
  fi
  json+=",\"stage\":\"$(hangctl__json_escape "${stage}")\""
  json+=",\"event\":\"$(hangctl__json_escape "${event}")\""
  json+=",\"result\":\"$(hangctl__json_escape "${result}")\""
  if [[ -n "${rc}" ]]; then
    # numeric rc
    json+=",\"rc\":${rc}"
  fi

  local details_json
  details_json="$(hangctl__details_kv_to_json "${details_kv}")"
  if [[ -n "${details_json}" ]]; then
    json+=",\"details\":${details_json}"
  fi
  json+="}"

  # Ensure log dir exists (best effort). config.sh ensures runtime dirs,
  # but this keeps logger safe for direct calls.
  local log_path="${HANGCTL_EVENTS_LOG-}"
  if [[ -z "${log_path}" ]]; then
    log_path="/var/log/ablestack-vm-hangctl/events.log"
  fi
  local parent
  parent="$(dirname "${log_path}")"
  if [[ ! -d "${parent}" ]]; then
    mkdir -p "${parent}" 2>/dev/null || true
  fi

  hangctl__jsonl_write_safe "${json}"
}

hangctl_log_event_console() {
  # Optional helper for development; prints JSON to stdout (no file append)
  local stage="${1-}"
  local event="${2-}"
  local result="${3-}"
  local vm="${4-}"
  local incident_id="${5-}"
  local rc="${6-}"
  local details_kv="${7-}"

  local ts scan_id
  ts="$(hangctl_now_iso8601)"
  scan_id="$(hangctl_get_scan_id)"
  if [[ -z "${scan_id}" ]]; then
    scan_id="$(hangctl_new_scan_id)"
    hangctl_set_scan_id "${scan_id}"
  fi

  local json="{"
  json+="\"ts\":\"$(hangctl__json_escape "${ts}")\""
  json+=",\"scan_id\":\"$(hangctl__json_escape "${scan_id}")\""
  if [[ -n "${incident_id}" ]]; then
    json+=",\"incident_id\":\"$(hangctl__json_escape "${incident_id}")\""
  fi
  if [[ -n "${vm}" ]]; then
    json+=",\"vm\":\"$(hangctl__json_escape "${vm}")\""
  fi
  json+=",\"stage\":\"$(hangctl__json_escape "${stage}")\""
  json+=",\"event\":\"$(hangctl__json_escape "${event}")\""
  json+=",\"result\":\"$(hangctl__json_escape "${result}")\""
  if [[ -n "${rc}" ]]; then
    json+=",\"rc\":${rc}"
  fi
  local details_json
  details_json="$(hangctl__details_kv_to_json "${details_kv}")"
  if [[ -n "${details_json}" ]]; then
    json+=",\"details\":${details_json}"
  fi
  json+="}"
  echo "${json}"
}
