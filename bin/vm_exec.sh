#!/bin/bash
#
# vm_exec.sh - Remote VM command execution tool using qemu-guest-agent
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


print_usage() {
  echo "Usage:"
  echo "  $0 -l|-w|-d <vm-name> <command> [args...] [options]"
  echo
  echo "Options:"
  echo "  -l | --linux               : Linux VM, use bash -c"
  echo "  -w | --windows             : Windows VM, use cmd.exe"
  echo "  -d | --direct              : Windows direct exec (e.g., tasklist.exe)"
  echo "  -o | --out <file>          : Save output to file"
  echo "  -f | --file <script file>  : Execute each line as a command"
  echo "  --exit-code                : Print guest process exit code"
  echo "  --json                     : Output result in JSON format"
  echo "  --csv                      : Parse CSV format output"
  echo "  --table                    : Parse table format output"
  echo "  --headers \"col1,col2,...\"  : Use fixed-width columns based on header names (only with --table)"
  echo "  --parallel                 : Execute commands in parallel (file mode only)"
  exit 1
}

if [[ "$#" -lt 3 ]]; then
  print_usage
fi

MODE="$1"
VM_NAME="$2"
shift 2

# Normalize MODE value
case "$MODE" in
  --linux) MODE="-l" ;;
  --windows) MODE="-w" ;;
  --direct) MODE="-d" ;;
esac

OUT_FILE=""
SCRIPT_FILE=""
PRINT_EXIT_CODE=false
OUTPUT_JSON=false
PARSE_CSV=false
PARSE_TABLE=false
PARALLEL_EXEC=false
CMD_ARR=()
USER_DEFINED_HEADERS=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --out|-o)
      OUT_FILE="$2"
      shift 2
      ;;
    --file|-f)
      SCRIPT_FILE="$2"
      shift 2
      ;;
    --exit-code)
      PRINT_EXIT_CODE=true
      shift
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    --csv)
      PARSE_CSV=true
      shift
      ;;
    --table)
      PARSE_TABLE=true
      shift
      ;;
    --headers)
      shift
      if [[ "$#" -eq 0 || "$1" =~ ^-- ]]; then
        echo "❌ Error: --headers option requires a comma-separated string argument."
        exit 1
      fi
      USER_DEFINED_HEADERS="$1"
      shift
      ;;
    --parallel)
      PARALLEL_EXEC=true
      shift
      ;;
    *)
      CMD_ARR+=("$1")
      shift
      ;;
  esac
done

CMD_NAME="${CMD_ARR[0]}"
CMD_ARGS=("${CMD_ARR[@]:1}")

escape_win_path() {
  echo "$1" | sed 's/\\/\\\\/g'
}

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

# 첫 번째 header 문자열의 일부로 라인 탐색
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
    local line="${lines[$i]}"
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

parse_linux_table() {
  local raw_data="$1"
  local lines
  mapfile -t lines < <(echo "$raw_data" | sed 's/\r//' | grep -vE '^[=\s]*$')

  [[ "${#lines[@]}" -lt 2 ]] && echo '[]' && return

  local header_line=""
  local header_index=0
  local headers=()
  local field_keys=()
  local field_widths=()

  if [[ -n "$USER_DEFINED_HEADERS" ]]; then
# --headers 옵션이 있는 경우
    IFS=',' read -ra headers <<< "$USER_DEFINED_HEADERS"

# 첫 번째 헤더 키워드 추출 (공백 제거 + 첫 단어)
    local first_header="${headers[0]}"
    local first_word=$(echo "$first_header" | sed 's/^ *//;s/ *$//' | awk '{print $1}')

# 헤더 라인 탐색
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
# --headers 옵션이 없는 경우: 자동 감지
    for line in "${lines[@]}"; do
      if [[ "$line" =~ ^Proto|^USER ]]; then
        header_line="$line"
        break
      fi
    done
    [[ -z "$header_line" ]] && header_line="${lines[0]}"
    header_index=0
    IFS=' ' read -ra field_keys <<< "$header_line"
  fi

  local result='[]'

  for ((i = header_index + 1; i < ${#lines[@]}; i++)); do
    local line="${lines[$i]}"
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

parse_table_to_json() {
  local raw_data="$1"
  case "$MODE" in
    -l)
      parse_linux_table "$raw_data"
      ;;
    -w|-d)
      parse_windows_table "$raw_data"
      ;;
    *)
      echo '[]'
      ;;
  esac
}

run_guest_exec() {
  local args=("virsh" "qemu-agent-command" "$VM_NAME" "--pretty")

  local cmd_path="${CMD_ARR[0]}"
  local cmd_args=("${CMD_ARR[@]:1}")
  local json_args=""
  for arg in "${cmd_args[@]}"; do
    escaped=$(printf '%s' "$arg" | sed 's/\\/\\\\/g; s/"/\\"/g')
    json_args+="\"$escaped\"," 
  done
  json_args="${json_args%,}"

  local json=$(cat <<EOF
{
  "execute": "guest-exec",
  "arguments": {
    "path": "$cmd_path",
    "arg": [$json_args],
    "capture-output": true
  }
}
EOF
)

  local response=$(virsh qemu-agent-command "$VM_NAME" "$json" --pretty)
  if [[ $? -ne 0 || -z "$response" ]]; then
    echo "❌ virsh qemu-agent-command failed or returned empty response."
    exit 1
  fi
  local pid=$(echo "$response" | jq -r '.return.pid')
  if [[ -z "$pid" || "$pid" == "null" ]]; then
    echo "❌ Failed to parse PID from virsh response."
    exit 1
  fi

  if [[ "$pid" == "null" || -z "$pid" ]]; then
    echo "❌ Failed to get PID. Is qemu-guest-agent running in guest?"
    exit 1
  fi

  local done=false
  local out="" err="" exitcode=""

  while ! $done; do
    sleep 0.5
    local poll=$(virsh qemu-agent-command "$VM_NAME" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" --pretty)
  if [[ $? -ne 0 || -z "$response" ]]; then
    echo "❌ virsh qemu-agent-command failed or returned empty response."
    exit 1
  fi
    done=$(echo "$poll" | jq -r '.return.exited')
    out=$(echo "$poll" | jq -r '.return."out-data"' 2>/dev/null | base64 --decode || true)
    if [[ $? -ne 0 ]]; then echo "⚠️ base64 decode failed"; fi
    err=$(echo "$poll" | jq -r '.return."err-data"' 2>/dev/null | base64 --decode || true)
    if [[ $? -ne 0 ]]; then echo "⚠️ base64 decode failed"; fi
    exitcode=$(echo "$poll" | jq -r '.return.exitcode')
  done

  if $OUTPUT_JSON; then
    local parsed="{}"
    if $PARSE_CSV; then
      parsed=$(parse_csv_to_json "$out")
    elif $PARSE_TABLE; then
      parsed=$(parse_table_to_json "$out")
    fi
    jq -n --arg cmd "$MODE ${CMD_ARR[*]}" --arg stdout "$out" --arg stderr "$err" --argjson parsed "$parsed" --argjson exit_code "$exitcode" \
      '{command: $cmd, parsed: $parsed, stdout_raw: $stdout, stderr: $stderr, exit_code: $exit_code}'
  else
    echo "===== $MODE: ${CMD_ARR[*]} STDOUT ====="
    echo "$out"
    echo "===== $MODE: ${CMD_ARR[*]} STDERR ====="
    echo "$err"
    $PRINT_EXIT_CODE && echo "Exit Code: $exitcode"
  fi

  [[ -n "$OUT_FILE" ]] && echo "$out" > "$OUT_FILE"
}

run_command() {
  if [[ -n "$SCRIPT_FILE" ]]; then
    mapfile -t commands < "$SCRIPT_FILE"
    if $PARALLEL_EXEC; then
      for cmd in "${commands[@]}"; do
        local cmd=("$cmd")
        CMD_ARR=("${cmd[@]}")
        run_guest_exec &
      done
      wait
    else
      for cmd in "${commands[@]}"; do
        CMD_ARR=("$cmd")
        run_guest_exec
      done
    fi
  else
    run_guest_exec
  fi
}

run_command



