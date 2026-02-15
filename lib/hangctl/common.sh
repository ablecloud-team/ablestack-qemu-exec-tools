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

# NOTE:
# - Libraries should not set 'set -euo pipefail' unilaterally.
# - Entry scripts control strict mode.

hangctl_die() {
  # usage: hangctl_die "message"
  echo "ERROR: $*" >&2
  return 10
}

hangctl_warn() {
  echo "WARN: $*" >&2
}

hangctl_info() {
  echo "INFO: $*"
}

hangctl_now_iso8601() {
  # ISO8601 with timezone offset, e.g., 2026-02-11T19:15:00+09:00
  date +"%Y-%m-%dT%H:%M:%S%z" | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'
}

hangctl_rand_id() {
  # Best-effort short random id; used for scan/incident ids in early commits.
  # Prefer kernel uuid if available; fallback to time+pid.
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    head -c 8 /proc/sys/kernel/random/uuid
    return 0
  fi
  printf "%08x" "$(( ( $(date +%s) ^ $$ ) & 0xffffffff ))"
}

hangctl_ensure_dir() {
  # usage: hangctl_ensure_dir <path> [mode]
  local d="${1-}"
  local mode="${2-0755}"
  if [[ -z "${d}" ]]; then
    echo "ERROR: ensure_dir: empty path" >&2
    return 10
  fi
  if [[ ! -d "${d}" ]]; then
    mkdir -p "${d}" || return 10
  fi
  chmod "${mode}" "${d}" 2>/dev/null || true
}
