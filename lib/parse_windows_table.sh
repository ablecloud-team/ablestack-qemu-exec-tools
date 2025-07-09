#!/bin/bash
#
# parse_windows_table.sh - Windows fixed-width table parser for vm_exec.sh
#
# Copyright 2025 ABLECLOUD
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

source "$(dirname "$0")/common.sh"

parse_windows_table() {
  local raw_data="$1"
  local lines
  mapfile -t lines < <(echo "$raw_data" | sed 's/\r//' | grep -vE '^[=\s]*$')

  [[ "${#lines[@]}" -lt 2 ]] && echo '[]' && return

  local header_line=""
  local header_index=0
  local headers=()
  local field_widths=()
  local field_keys=()

  if [[ -n "$USER_DEFINED_HEADERS" ]]; then
    IFS=',' read -ra headers <<< "$USER_DEFINED_HEADERS"
    local first_header="${headers[0]}"
    local first_word=$(echo "$first_header" | sed 's/^ *//;s/ *$//' | awk '{print $1}')

    for ((i = 0; i < ${#lines[@]}; i++)); do
      if echo "${lines[$i]}" | grep -Fq "$first_word"; then
        header_line="${lines[$i]}"
        header_index=$i
        break
      fi
    done

    if [[ -z "$header_line" ]]; then
      echo "❌ Header keyword '$first_word' not found in data." >&2
      echo '[]'
      return
    fi

    for header in "${headers[@]}"; do
      local width=$(echo -n "$header" | wc -c)
      field_widths+=("$width")
      field_keys+=( "$(echo "$header" | sed 's/^ *//;s/ *$//')" )
    done
  else
    header_line="${lines[0]}"
    header_index=0
    IFS=' ' read -ra field_keys <<< "$header_line"
  fi

  local result='[]'

  for ((i = header_index + 1; i < ${#lines[@]}; i++)); do
    local line="${lines[i]}"
    [[ -z "$line" ]] && continue

    local obj='{}'
    if [[ -n "$USER_DEFINED_HEADERS" ]]; then
      local pos=0
      for ((j = 0; j < ${#field_keys[@]}; j++)); do
        local width="${field_widths[$j]}"
        local key="${field_keys[$j]}"
        local raw_field="${line:$pos:$width}"
        local val=$(echo "$raw_field" | sed 's/^[ \t]*//;s/[ \t]*$//')
        obj=$(echo "$obj" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')
        pos=$((pos + width))
      done
    else
      read -ra fields <<< "$line"
      for ((j = 0; j < ${#field_keys[@]}; j++)); do
        local key="${field_keys[$j]}"
        local val="${fields[$j]:-}"
        obj=$(echo "$obj" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')
      done
    fi

    result=$(echo "$result" | jq --argjson row "$obj" '. + [ $row ]')
  done

  echo "$result"
}
