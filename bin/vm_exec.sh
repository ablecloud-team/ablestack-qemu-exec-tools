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

# ===== 공통 라이브러리 로드 =====
LIBDIR="/usr/local/lib/ablestack-qemu-exec-tools"
source "$LIBDIR/common.sh"
source "$LIBDIR/parse_linux_table.sh"
source "$LIBDIR/parse_windows_table.sh"
source "$LIBDIR/parse_csv.sh"

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
  echo "  --headers "col1,col2,..."  : Use fixed-width columns based on header names (only with --table)"
  echo "  --parallel                 : Execute commands in parallel (file mode only)"
  exit 1
}

if [[ "$#" -lt 3 ]]; then
  print_usage
fi

MODE="$1"
VM_NAME="$2"
shift 2

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
    escaped=$(escape_string "$arg")
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
  [[ $? -ne 0 || -z "$response" ]] && abort "virsh qemu-agent-command failed or returned empty response."

  local pid=$(echo "$response" | jq -r '.return.pid')
  [[ -z "$pid" || "$pid" == "null" ]] && abort "Failed to parse PID from virsh response."

  local done=false out="" err="" exitcode=""
  while ! $done; do
    sleep 0.5
    local poll=$(virsh qemu-agent-command "$VM_NAME" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" --pretty)
    [[ $? -ne 0 || -z "$poll" ]] && abort "virsh qemu-agent-command poll failed."

    done=$(echo "$poll" | jq -r '.return.exited')
    out=$(echo "$poll" | jq -r '.return."out-data"' 2>/dev/null | base64 --decode || true)
    err=$(echo "$poll" | jq -r '.return."err-data"' 2>/dev/null | base64 --decode || true)
    exitcode=$(echo "$poll" | jq -r '.return.exitcode')
  done

  if $OUTPUT_JSON; then
    local parsed="{}"
    if $PARSE_CSV; then
      parsed=$(parse_csv_to_json "$out")
    elif $PARSE_TABLE; then
      parsed=$(parse_table_to_json "$out")
    fi
    jq -n --arg cmd "$MODE ${CMD_ARR[*]}" --arg stdout "$out" --arg stderr "$err" --argjson parsed "$parsed" --argjson exit_code "$exitcode"       '{command: $cmd, parsed: $parsed, stdout_raw: $stdout, stderr: $stderr, exit_code: $exit_code}'
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
