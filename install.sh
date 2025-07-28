#!/bin/bash
#
# install.sh - ablestack-qemu-exec-tools 설치 스크립트 (통합)
#
# Copyright 2025 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# You may not use this file except in compliance with the License.
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
BIN_DIR="${INSTALL_PREFIX}/bin"
LIB_TARGET="${INSTALL_PREFIX}/lib/ablestack-qemu-exec-tools"

echo "▶ ablestack-qemu-exec-tools 설치를 시작합니다..."

# jq 필수 확인
if ! command -v jq &> /dev/null; then
  echo "❌ 'jq' 명령이 설치되어 있지 않습니다. 설치 후 다시 시도하세요."
  exit 1
fi

# 1. 실행 파일 설치/업데이트 (vm_exec, agent_policy_fix)
BIN_SCRIPTS=("vm_exec.sh" "agent_policy_fix.sh" "cloud_init_auto.sh")
for script in "${BIN_SCRIPTS[@]}"; do
  src="bin/${script}"
  target="${BIN_DIR}/${script%.sh}"  # .sh 확장자 제거
  if [ -f "$src" ]; then
    echo "➤ 실행 파일 링크 생성: $target"
    mkdir -p "$(dirname "$target")"
    ln -sf "$(pwd)/$src" "$target"
    chmod +x "$src"
  fi
done

# 2. 라이브러리 설치
echo "➤ 라이브러리 설치 경로: ${LIB_TARGET}"
mkdir -p "$LIB_TARGET"
cp -a lib/* "$LIB_TARGET/" 2>/dev/null || true

echo "✅ 설치 완료! 다음 명령으로 실행할 수 있습니다:"
echo ""
echo "   vm_exec         # 호스트에서 VM 명령 실행"
echo "   agent_policy_fix # 게스트에서 qemu-guest-agent 정책 자동화"
echo ""
echo "▶ 자세한 사용법은 README.md 및 docs/usage.md를 참고하세요."
