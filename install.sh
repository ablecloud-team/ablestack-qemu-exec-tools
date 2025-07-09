#!/bin/bash
#
# install.sh - ablestack-qemu-exec-tools 설치 스크립트
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

set -e

INSTALL_PREFIX="/usr/local"
BIN_TARGET="${INSTALL_PREFIX}/bin/vm_exec"
LIB_TARGET="${INSTALL_PREFIX}/lib/ablestack-qemu-exec-tools"

echo "▶ ablestack-qemu-exec-tools 설치를 시작합니다..."

# jq 필수 확인
if ! command -v jq &> /dev/null; then
  echo "❌ 'jq' 명령이 설치되어 있지 않습니다. 설치 후 다시 시도하세요."
  exit 1
fi

# 실행 파일 설치
echo "➤ 실행 파일 링크 생성: ${BIN_TARGET}"
mkdir -p "$(dirname "$BIN_TARGET")"
ln -sf "$(pwd)/bin/vm_exec.sh" "$BIN_TARGET"

# 라이브러리 설치
echo "➤ 라이브러리 설치 경로: ${LIB_TARGET}"
mkdir -p "$LIB_TARGET"
cp -a lib/* "$LIB_TARGET/" 2>/dev/null || true

echo "✅ 설치 완료! 다음 명령으로 실행할 수 있습니다:"
echo ""
echo "   vm_exec -l|-w|-d <vm-name> <command> [args...] [options]"
