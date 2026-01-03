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

v2k_verify() {
  local manifest="$1" mode="$2" samples="$3"
  case "${mode}" in
    quick)
      # quick: ensure target files exist and have non-zero size
      local count
      count="$(jq -r '.disks|length' "${manifest}")"
      local i
      for ((i=0;i<count;i++)); do
        local p
        p="$(jq -r ".disks[$i].transfer.target_path" "${manifest}")"
        [[ -f "${p}" ]] || { echo "{\"ok\":false,\"error\":\"missing target\",\"path\":\"${p}\"}"; return 1; }
        local sz
        sz="$(stat -c%s "${p}" 2>/dev/null || echo 0)"
        [[ "${sz}" -gt 0 ]] || { echo "{\"ok\":false,\"error\":\"zero size\",\"path\":\"${p}\"}"; return 1; }
      done
      echo "{\"ok\":true,\"mode\":\"quick\",\"disks\":${count}}"
      ;;
    *)
      echo "{\"ok\":false,\"error\":\"unsupported verify mode\"}"
      return 1
      ;;
  esac
}
