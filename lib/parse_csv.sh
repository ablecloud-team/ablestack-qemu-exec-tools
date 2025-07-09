#!/bin/bash
#
# parse_csv.sh - CSV to JSON parser for vm_exec.sh
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

parse_csv_to_json() {
  local csv_data="$1"
  local IFS=$'\n'
  local lines
  mapfile -t lines < <(echo "$csv_data" | sed 's/\r//g' | grep '^"')

  local header_line=""
  local result='[]'
  local start_index=-1

  for ((i = 0; i < ${#lines[@]}; i++)); do
    if [[ "${lines[$i]}" == *"PDH-CSV"* ]]; then
      if [[ $((i)) -lt ${#lines[@]} ]]; then
        header_line="${lines[$((i))]}"
        start_index=$((i + 1))
      fi
      break
    fi
  done

  if [[ -z "$header_line" || $start_index -eq -1 ]]; then
    echo '[]' && return
  fi

  local headers
  IFS=',' read -ra headers <<< "$header_line"
  headers[0]="timestamp"

  for ((i = start_index; i < ${#lines[@]}; i++)); do
    local line="${lines[$i]}"
    [[ "$line" =~ Exiting ]] && continue
    [[ "$line" =~ The\ command\ completed ]] && continue

    local values
    IFS=',' read -ra values <<< "$line"
    if [[ ${#headers[@]} -ne ${#values[@]} ]]; then
      continue
    fi

    local obj='{}'
    for ((j = 0; j < ${#headers[@]}; j++)); do
      local key=$(echo "${headers[$j]}" | sed 's/^"//;s/"$//')
      local val=$(echo "${values[$j]}" | sed 's/^"//;s/"$//')
      obj=$(echo "$obj" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')
    done
    result=$(echo "$result" | jq --argjson row "$obj" '. + [ $row ]')
  done

  echo "$result"
}
