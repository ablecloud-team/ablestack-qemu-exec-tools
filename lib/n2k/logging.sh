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

n2k_now_iso() {
  date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/'
}

n2k_json_string() {
  local value="${1:-}"
  jq -Rn --arg s "${value}" '$s'
}

n2k_event() {
  local level="${1:-INFO}" phase="${2:-}" disk="${3:-}" event="${4:-}" payload="${5:-}"
  local log="${N2K_EVENTS_LOG:-}"
  [[ -n "${log}" ]] || return 0
  [[ -n "${payload}" ]] || payload="{}"

  mkdir -p "$(dirname "${log}")"

  if ! printf '%s' "${payload}" | jq -e . >/dev/null 2>&1; then
    payload='{"invalid_payload":true}'
  fi

  jq -nc \
    --arg ts "$(n2k_now_iso)" \
    --arg level "${level}" \
    --arg phase "${phase}" \
    --arg disk "${disk}" \
    --arg event "${event}" \
    --argjson payload "${payload}" \
    '{ts:$ts,level:$level,phase:$phase,disk:$disk,event:$event,payload:$payload}' \
    >> "${log}"
}
