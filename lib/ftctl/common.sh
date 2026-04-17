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

ftctl_die() {
  echo "ERROR: $*" >&2
  return 10
}

ftctl_warn() {
  echo "WARN: $*" >&2
}

ftctl_info() {
  echo "INFO: $*"
}

ftctl_now_iso8601() {
  date +"%Y-%m-%dT%H:%M:%S%z" | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'
}

ftctl_now_epoch() {
  date +%s
}

ftctl_iso_to_epoch() {
  local iso="${1-}"
  [[ -n "${iso}" ]] || return 1
  date -d "${iso}" +%s 2>/dev/null
}

ftctl_elapsed_since_iso() {
  local iso="${1-}"
  local ts now
  ts="$(ftctl_iso_to_epoch "${iso}")" || return 1
  now="$(ftctl_now_epoch)"
  echo $((now - ts))
}

ftctl_rand_id() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    head -c 8 /proc/sys/kernel/random/uuid
    return 0
  fi
  printf "%08x" "$((( $(date +%s) ^ $$ ) & 0xffffffff ))"
}

ftctl_ensure_dir() {
  local d="${1-}"
  local mode="${2-0755}"
  [[ -n "${d}" ]] || return 10
  [[ -d "${d}" ]] || mkdir -p "${d}"
  chmod "${mode}" "${d}" 2>/dev/null || true
}
