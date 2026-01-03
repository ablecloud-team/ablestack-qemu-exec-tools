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

v2k_now_rfc3339() {
  date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([+-][0-9][0-9]\)\([0-9][0-9]\)$/\1:\2/'
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
