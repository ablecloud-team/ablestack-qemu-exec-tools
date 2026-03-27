#!/usr/bin/env bash
#
# install.sh - ablestack-qemu-exec-tools 설치 스크립트 (개발/소스 설치용)
# (dev/source install 용)
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
SYSTEMD_UNIT_DIR="/etc/systemd/system"
COMPLETIONS_TARGET="/usr/share/bash-completion/completions"

ISO_DEFAULT_DIR="/usr/share/ablestack/tools"   # ISO가 존재해야 하는 기본 디렉터리 (vm_autoinstall에서 ISO_PATH_DEFAULT로 참조) - 설치 시 생성 및 안내
ISO_DEFAULT_PATH="${ISO_DEFAULT_DIR}/ablestack-qemu-exec-tools.iso"

# ABLESTACK Host 감지
is_ablestack_host() {
  if [[ -f /etc/os-release ]]; then
    if grep -q '^PRETTY_NAME="ABLESTACK' /etc/os-release; then
      return 0
    fi
  fi
  return 1
}

if is_ablestack_host; then
  echo "ABLESTACK Host 환경 감지됨: 서비스용 모드로 설치합니다."
  INSTALL_MODE="HOST"
else
  echo "일반 Linux VM 환경 감지됨: 자체 구성 모드로 설치합니다."
  INSTALL_MODE="VM"
fi

echo "ablestack-qemu-exec-tools 설치를 시작합니다.."

# 0) 필수/권장 존재 여부 (부족시 설치 중단보다는 경고)
MISSING=()

need_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || MISSING+=("$c")
}

# 필수 명령어
need_cmd jq
need_cmd virsh

# 게스트 인젝션 관련 권장(자체 기능 필요)
# NOTE: hangctl의 서비스 운영 구성에서 이들 권장 구성 업무를 무시하게 설치 가능
#       (존재 여부에 따라 개별 충족)
need_cmd virt-inspector
need_cmd virt-copy-in
need_cmd virt-customize
need_cmd virt-win-reg

# 선택(그러나 detach나 XML 조작에 필요)
# need_cmd virt-xml   # 권장이나 강제 아님

if ((${#MISSING[@]})); then
  echo "다음 명령이 필요합니다: ${MISSING[*]}"
  echo "   Rocky 9 에서 dnf -y install jq libvirt-client libguestfs-tools virt-install"
  exit 1
fi

# 1) 실행 파일 설치
#    - vm_exec.sh / agent_policy_fix.sh / cloud_init_auto.sh (기존)
#    - vm_autoinstall.sh (규칙)
#    링크 생성 시 .sh 확장자 제거 (vm_exec, agent_policy_fix, cloud_init_auto, vm_autoinstall)
#    ABLESTACK Host 에서 vm_exec, vm_autoinstall 등 호출

if [[ "$INSTALL_MODE" == "HOST" ]]; then
  # ABLESTACK Host: 최소 구성으로 설치
  BIN_SCRIPTS=("vm_exec.sh" "vm_autoinstall.sh" "ablestack_v2k.sh" "ablestack_vm_hangctl.sh" "ablestack_vm_ftctl.sh" "v2k_test_install.sh")
else
  # 일반 VM: 자체 구성으로 설치
  BIN_SCRIPTS=("vm_exec.sh" "agent_policy_fix.sh" "cloud_init_auto.sh" "vm_autoinstall.sh" "ablestack_v2k.sh" "ablestack_vm_hangctl.sh" "ablestack_vm_ftctl.sh" "v2k_test_install.sh")
fi

for script in "${BIN_SCRIPTS[@]}"; do
  src="${BIN_SRC}/${script}"
  target="${BIN_DIR}/${script%.sh}"  # .sh 확장자 제거
  if [[ -f "$src" ]]; then
    echo "실행 파일 링크 생성: $target -> $(pwd)/$src"
    mkdir -p "$(dirname "$target")"
    ln -sf "$(pwd)/$src" "$target"
    chmod +x "$src"
  else
    echo "⚠️  실행 파일 없음(건너뜀): $src"
  fi
done

# 2) 라이브러리 및 페이로드 설치
#    - lib/*  -> ${LIB_TARGET}/
#    - payload/* -> ${LIB_TARGET}/payload/
#    (게스트 인젝션 스크립트가 payload를 참조)

echo "라이브러리 설치 경로: ${LIB_TARGET}"
mkdir -p "$LIB_TARGET"
if [[ -d "$LIB_SRC" ]]; then
  # 파일 복사
  cp -a "$LIB_SRC/"* "$LIB_TARGET/" 2>/dev/null || true

  # 모든 스크립트 실행 권한 부여(lib/*.sh, lib/**/**/*.sh)
  find "$LIB_TARGET" -type f -name "*.sh" -exec chmod 755 {} \;

  # (참고) 바이너리 PS1 등은 실행권한 필요 없음. 기본권한으로 보장
  find "$LIB_TARGET" -type f \( -name "*.service" -o -name "*.ps1" \) -exec chmod 644 {} \; 2>/dev/null || true
else
  echo "⚠️  라이브러리 소스 디렉터리 미존재: $LIB_SRC"
fi

if [[ -d "completions" ]]; then
  echo "bash completion install path: ${COMPLETIONS_TARGET}"
  sudo mkdir -p "${COMPLETIONS_TARGET}"
  if [[ -f "completions/ablestack_vm_ftctl" ]]; then
    sudo cp -a "completions/ablestack_vm_ftctl" "${COMPLETIONS_TARGET}/ablestack_vm_ftctl"
    sudo chmod 644 "${COMPLETIONS_TARGET}/ablestack_vm_ftctl" 2>/dev/null || true
  fi
  if [[ -f "completions/ablestack_v2k" ]]; then
    sudo cp -a "completions/ablestack_v2k" "${COMPLETIONS_TARGET}/ablestack_v2k"
    sudo chmod 644 "${COMPLETIONS_TARGET}/ablestack_v2k" 2>/dev/null || true
  fi
fi

#
# 2.1) hangctl 관련 시스템 서비스/타이머 유닛 및 기본 설정 설치
#   - unit: lib/hangctl/systemd/*.service|*.timer -> /etc/systemd/system/
#   - config(default): etc/ablestack-vm-hangctl.conf -> /etc/ablestack/ablestack-vm-hangctl.conf (noreplace)
#   - enable/start 여부는 아님(운영 책무에 따라 결정)
HANGCTL_DEFAULT_CONF_SRC="etc/ablestack-vm-hangctl.conf"
HANGCTL_DEFAULT_CONF_DST="/etc/ablestack/ablestack-vm-hangctl.conf"
HANGCTL_UNIT_SRC_DIR="${LIB_SRC}/hangctl/systemd"

if [[ -d "${HANGCTL_UNIT_SRC_DIR}" ]]; then
  echo "hangctl systemd unit 설치: ${SYSTEMD_UNIT_DIR}"
  sudo mkdir -p "${SYSTEMD_UNIT_DIR}"
  # service/timer 복사
  if ls "${HANGCTL_UNIT_SRC_DIR}"/*.service >/dev/null 2>&1; then
    sudo cp -a "${HANGCTL_UNIT_SRC_DIR}"/*.service "${SYSTEMD_UNIT_DIR}/"
    sudo chmod 644 "${SYSTEMD_UNIT_DIR}"/*.service 2>/dev/null || true
  fi
  if ls "${HANGCTL_UNIT_SRC_DIR}"/*.timer >/dev/null 2>&1; then
    sudo cp -a "${HANGCTL_UNIT_SRC_DIR}"/*.timer "${SYSTEMD_UNIT_DIR}/"
    sudo chmod 644 "${SYSTEMD_UNIT_DIR}"/*.timer 2>/dev/null || true
  fi
  sudo systemctl daemon-reload 2>/dev/null || true
else
  echo "⚠️  hangctl systemd unit 소스 디렉터리 미존재(건너뜀): ${HANGCTL_UNIT_SRC_DIR}"
fi

if [[ -f "${HANGCTL_DEFAULT_CONF_SRC}" ]]; then
  echo "hangctl 기본 설정 설치(존재 확인): ${HANGCTL_DEFAULT_CONF_DST}"
  sudo mkdir -p "$(dirname "${HANGCTL_DEFAULT_CONF_DST}")"
  if [[ -f "${HANGCTL_DEFAULT_CONF_DST}" ]]; then
    echo "   기존 설정 존재: ${HANGCTL_DEFAULT_CONF_DST} (덮어쓰지 않음)"
  else
    sudo cp -a "${HANGCTL_DEFAULT_CONF_SRC}" "${HANGCTL_DEFAULT_CONF_DST}"
    sudo chmod 644 "${HANGCTL_DEFAULT_CONF_DST}" 2>/dev/null || true
    echo "   설치 완료: ${HANGCTL_DEFAULT_CONF_DST}"
  fi
else
  echo "⚠️  hangctl 기본 설정 템플릿 없음(건너뜀): ${HANGCTL_DEFAULT_CONF_SRC}"
fi

echo "페이로드 설치 경로: ${LIB_TARGET}/payload"
FTCTL_DEFAULT_CONF_SRC="etc/ablestack-vm-ftctl.conf"
FTCTL_DEFAULT_CONF_DST="/etc/ablestack/ablestack-vm-ftctl.conf"
FTCTL_UNIT_SRC_DIR="${LIB_SRC}/ftctl/systemd"

if [[ -d "${FTCTL_UNIT_SRC_DIR}" ]]; then
  echo "ftctl systemd unit install: ${SYSTEMD_UNIT_DIR}"
  sudo mkdir -p "${SYSTEMD_UNIT_DIR}"
  if ls "${FTCTL_UNIT_SRC_DIR}"/*.service >/dev/null 2>&1; then
    sudo cp -a "${FTCTL_UNIT_SRC_DIR}"/*.service "${SYSTEMD_UNIT_DIR}/"
    sudo chmod 644 "${SYSTEMD_UNIT_DIR}"/*.service 2>/dev/null || true
  fi
  if ls "${FTCTL_UNIT_SRC_DIR}"/*.timer >/dev/null 2>&1; then
    sudo cp -a "${FTCTL_UNIT_SRC_DIR}"/*.timer "${SYSTEMD_UNIT_DIR}/"
    sudo chmod 644 "${SYSTEMD_UNIT_DIR}"/*.timer 2>/dev/null || true
  fi
  sudo systemctl daemon-reload 2>/dev/null || true
else
  echo "skip ftctl systemd unit install: ${FTCTL_UNIT_SRC_DIR}"
fi

if [[ -f "${FTCTL_DEFAULT_CONF_SRC}" ]]; then
  echo "ftctl default config install check: ${FTCTL_DEFAULT_CONF_DST}"
  sudo mkdir -p "$(dirname "${FTCTL_DEFAULT_CONF_DST}")"
  if [[ -f "${FTCTL_DEFAULT_CONF_DST}" ]]; then
    echo "   existing config kept: ${FTCTL_DEFAULT_CONF_DST}"
  else
    sudo cp -a "${FTCTL_DEFAULT_CONF_SRC}" "${FTCTL_DEFAULT_CONF_DST}"
    sudo chmod 644 "${FTCTL_DEFAULT_CONF_DST}" 2>/dev/null || true
    echo "   installed: ${FTCTL_DEFAULT_CONF_DST}"
  fi
else
  echo "skip ftctl default config install: ${FTCTL_DEFAULT_CONF_SRC}"
fi

FTCTL_CLUSTER_CONF_SRC="etc/ablestack-vm-ftctl-cluster.conf"
FTCTL_CLUSTER_CONF_DST="/etc/ablestack/ablestack-vm-ftctl-cluster.conf"
FTCTL_CLUSTER_HOSTS_DST="/etc/ablestack/ftctl-cluster.d/hosts"

if [[ -f "${FTCTL_CLUSTER_CONF_SRC}" ]]; then
  echo "ftctl cluster config install check: ${FTCTL_CLUSTER_CONF_DST}"
  sudo mkdir -p "$(dirname "${FTCTL_CLUSTER_CONF_DST}")"
  sudo mkdir -p "${FTCTL_CLUSTER_HOSTS_DST}"
  if [[ -f "${FTCTL_CLUSTER_CONF_DST}" ]]; then
    echo "   existing cluster config kept: ${FTCTL_CLUSTER_CONF_DST}"
  else
    sudo cp -a "${FTCTL_CLUSTER_CONF_SRC}" "${FTCTL_CLUSTER_CONF_DST}"
    sudo chmod 644 "${FTCTL_CLUSTER_CONF_DST}" 2>/dev/null || true
    echo "   installed: ${FTCTL_CLUSTER_CONF_DST}"
  fi
else
  echo "skip ftctl cluster config install: ${FTCTL_CLUSTER_CONF_SRC}"
fi

mkdir -p "${LIB_TARGET}/payload"
if [[ -d "$PAYLOAD_SRC" ]]; then
  # 전체 payload 복사 수행
  rsync -a "$PAYLOAD_SRC/"" " "${LIB_TARGET}/payload/" 2>/dev/null || cp -a "$PAYLOAD_SRC/"* "${LIB_TARGET}/payload/" 2>/dev/null || true
else
  echo "⚠️  페이로드 소스 디렉터리 미존재: $PAYLOAD_SRC"
fi

# 3) ISO 기본 경로 확인/생성 및 안내
echo "ISO 기본 경로 확인: ${ISO_DEFAULT_DIR}"
mkdir -p "${ISO_DEFAULT_DIR}"
if [[ -f "${ISO_DEFAULT_PATH}" ]]; then
  echo "   ISO 존재: ${ISO_DEFAULT_PATH}"
else
  echo "   ⚠️  ISO가 없습니다: ${ISO_DEFAULT_PATH}"
  echo "      - GitHub Actions 출력물을 이 경로에 배치하거나"
  echo "      - 다른 경로를 사용할 경우 vm_autoinstall에서 환경변수 ISO_PATH_DEFAULT를 지정하세요."
fi

# 4) 환경 설정 파일 생성
PROFILE_D="/etc/profile.d/ablestack-qemu-exec-tools.sh"
echo "환경설정 파일: ${PROFILE_D}"
cat <<EOF | sudo tee "${PROFILE_D}" >/dev/null
# ablestack-qemu-exec-tools env (hint)
export ABLESTACK_QEMU_EXEC_TOOLS_HOME="${LIB_TARGET}"
export ISO_PATH_DEFAULT="${ISO_DEFAULT_PATH}"
EOF

echo "설치 완료!"

echo ""
echo "사용 예시:"
echo "  vm_autoinstall <domain>     # ISO 기반 게스트 자동 설치 (vm_autoinstall.sh)"
echo "  vm_exec                      # 게스트 시스템 명령 실행(QGA 필요)"
echo ""
echo "  ablestack_vm_hangctl health  # libvirtd 상태 점검"
echo "  ablestack_vm_hangctl scan    # VM hang 스캔 (domstate 및 QMP 기반)"
echo ""
echo "systemd(개발 설치 시 유닛으로 배치, enable후 시동):"
echo "  systemctl enable --now ablestack-vm-hangctl.timer"
echo "  systemctl status ablestack-vm-hangctl.timer --no-pager -l"
echo ""
echo "참고:"
echo "  - 게스트 인젝션 스크립트는 ${LIB_TARGET}/payload/* 에서 사용합니다."
echo "  - ISO는 ${ISO_DEFAULT_PATH} 에 존재해야 합니다."
echo "  - Windows: ISO 루트에 install.bat 실행 / Linux: install-linux.sh 실행"
