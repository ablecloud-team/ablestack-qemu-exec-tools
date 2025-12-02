#!/usr/bin/env bash
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
PAYLOAD_SRC="payload"
LIB_SRC="lib"
BIN_SRC="bin"

ISO_DEFAULT_DIR="/usr/share/ablestack/tools"   # ISO가 존재해야 하는 디렉토리
ISO_DEFAULT_PATH="${ISO_DEFAULT_DIR}/ablestack-qemu-exec-tools.iso"

echo "▶ ablestack-qemu-exec-tools 설치를 시작합니다..."

# ───────────────────────────────────────────────────────────
# 0) 필수/권장 의존성 점검 (부재 시 설치 중단보다는 경고)
# ───────────────────────────────────────────────────────────
MISSING=()

need_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || MISSING+=("$c")
}

# 필수
need_cmd jq
need_cmd virsh

# 오프라인 주입 관련 권장(실제 기능에 필요)
need_cmd virt-inspector
need_cmd virt-copy-in
need_cmd virt-customize
need_cmd virt-win-reg

# 선택(있으면 detach나 XML 조작이 더 안정적)
# need_cmd virt-xml   # 권장이나 강제는 아님

if ((${#MISSING[@]})); then
  echo "❌ 다음 명령이 필요합니다: ${MISSING[*]}"
  echo "   Rocky 9 예) dnf -y install jq libvirt-client libguestfs-tools virt-install"
  exit 1
fi

# ───────────────────────────────────────────────────────────
# 1) 실행 파일 설치/업데이트
#    - vm_exec.sh / agent_policy_fix.sh / cloud_init_auto.sh (기존)
#    - vm_autoinstall.sh (신규)
#    링크 생성 시 .sh 확장자 제거 (vm_exec, agent_policy_fix, cloud_init_auto, vm_autoinstall)
# ───────────────────────────────────────────────────────────
BIN_SCRIPTS=("vm_exec.sh" "agent_policy_fix.sh" "cloud_init_auto.sh" "vm_autoinstall.sh")

for script in "${BIN_SCRIPTS[@]}"; do
  src="${BIN_SRC}/${script}"
  target="${BIN_DIR}/${script%.sh}"  # .sh 확장자 제거
  if [[ -f "$src" ]]; then
    echo "➤ 실행 파일 링크 생성: $target -> $(pwd)/$src"
    mkdir -p "$(dirname "$target")"
    ln -sf "$(pwd)/$src" "$target"
    chmod +x "$src"
  else
    echo "⚠️  실행 파일 없음(건너뜀): $src"
  fi
done

# ───────────────────────────────────────────────────────────
# 2) 라이브러리 및 페이로드 설치
#    - lib/*  →  ${LIB_TARGET}/
#    - payload/* → ${LIB_TARGET}/payload/
#    (오프라인 주입 스크립트가 payload를 참조)
# ───────────────────────────────────────────────────────────
echo "➤ 라이브러리 설치 경로: ${LIB_TARGET}"
mkdir -p "$LIB_TARGET"
if [[ -d "$LIB_SRC" ]]; then
  # 파일 복사
  cp -a "$LIB_SRC/"* "$LIB_TARGET/" 2>/dev/null || true

  # 셸 스크립트 실행 권한 부여 (lib/*.sh, lib/**/**/*.sh)
  find "$LIB_TARGET" -type f -name "*.sh" -exec chmod 755 {} \;

  # (참고) 서비스/PS1 등은 실행권한 필요 없음. 읽기권한만 보장
  find "$LIB_TARGET" -type f \( -name "*.service" -o -name "*.ps1" \) -exec chmod 644 {} \; 2>/dev/null || true
else
  echo "⚠️  라이브러리 소스 디렉토리 미존재: $LIB_SRC"
fi


echo "➤ 페이로드 설치 경로: ${LIB_TARGET}/payload"
mkdir -p "${LIB_TARGET}/payload"
if [[ -d "$PAYLOAD_SRC" ]]; then
  # 전체 payload를 덮어쓰기
  rsync -a "$PAYLOAD_SRC/"" " "${LIB_TARGET}/payload/" 2>/dev/null || cp -a "$PAYLOAD_SRC/"* "${LIB_TARGET}/payload/" 2>/dev/null || true
else
  echo "⚠️  페이로드 소스 디렉토리 미존재: $PAYLOAD_SRC"
fi

# ───────────────────────────────────────────────────────────
# 3) ISO 기본 경로 안내/생성
# ───────────────────────────────────────────────────────────
echo "➤ ISO 기본 경로 확인: ${ISO_DEFAULT_DIR}"
mkdir -p "${ISO_DEFAULT_DIR}"
if [[ -f "${ISO_DEFAULT_PATH}" ]]; then
  echo "   ✅ ISO 존재: ${ISO_DEFAULT_PATH}"
else
  echo "   ⚠️  ISO가 없습니다: ${ISO_DEFAULT_PATH}"
  echo "      - GitHub Actions 산출물을 이 경로로 배치하거나,"
  echo "      - 다른 경로를 사용할 경우 vm_autoinstall에서 환경변수 ISO_PATH_DEFAULT로 지정하세요."
fi

# ───────────────────────────────────────────────────────────
# 4) 환경 파일(선택): 라이브 경로/ISO 경로 힌트 제공
# ───────────────────────────────────────────────────────────
PROFILE_D="/etc/profile.d/ablestack-qemu-exec-tools.sh"
echo "➤ 환경설정 힌트: ${PROFILE_D}"
cat <<EOF | sudo tee "${PROFILE_D}" >/dev/null
# ablestack-qemu-exec-tools env (hint)
export ABLESTACK_QEMU_EXEC_TOOLS_HOME="${LIB_TARGET}"
export ISO_PATH_DEFAULT="${ISO_DEFAULT_PATH}"
EOF

echo "✅ 설치 완료!"

echo ""
echo "사용 예시:"
echo "  vm_autoinstall <domain>     # ISO 핫플러그 + (QGA 있으면 온라인) / (없으면 오프라인 주입+부팅)"
echo "  vm_exec                      # 게스트 내부 명령 실행(QGA 필요)"
echo ""
echo "참고:"
echo "  - 오프라인 주입 스크립트는 ${LIB_TARGET}/payload/* 를 사용합니다."
echo "  - ISO는 ${ISO_DEFAULT_PATH} 에 존재해야 합니다."
echo "  - Windows: ISO 루트의 install.bat 실행 / Linux: install-linux.sh 실행"