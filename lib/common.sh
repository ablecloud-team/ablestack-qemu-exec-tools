#!/bin/bash
#
# common.sh - Common utility functions for vm_exec.sh
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

# 로그 출력 함수
log_info() {
  echo -e "🔷 [INFO] $*"
}

log_warn() {
  echo -e "⚠️  [WARN] $*"
}

log_error() {
  echo -e "❌ [ERROR] $*" >&2
}

abort() {
  log_error "$1"
  exit 1
}

trim() {
  echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

escape_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

cut_fixed_range() {
  local line="$1"
  local start="$2"
  local length="$3"
  echo "${line:$start:$length}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Windows 경로 이스케이프 처리
escape_win_path() {
  echo "$1" | sed 's/\\\\/\\\\\\\\/g'
}
