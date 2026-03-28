#!/usr/bin/env bash
#
# install.sh - ablestack-qemu-exec-tools ???노뭵 ???꾩씩?源???(?띠룇裕녻????裕????노뭵??
# (dev/source install ??
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

ISO_DEFAULT_DIR="/usr/share/ablestack/tools"   # ISO?띠럾? ?브퀡????怨룻뒍 ??濡ル츎 ?リ옇?????븐뼚???⑤틲遊?(vm_autoinstall?????ISO_PATH_DEFAULT??嶺뚣볦굣?? - ???노뭵 ????諛댁뎽 ?????뉖?
ISO_DEFAULT_PATH="${ISO_DEFAULT_DIR}/ablestack-qemu-exec-tools.iso"

# ABLESTACK Host ?띠룆흮?
is_ablestack_host() {
  if [[ -f /etc/os-release ]]; then
    if grep -q '^PRETTY_NAME="ABLESTACK' /etc/os-release; then
      return 0
    fi
  fi
  return 1
}

if is_ablestack_host; then
  echo "ABLESTACK Host ???삵렱 ?띠룆흮??? ??類λ룴???깅뮔 嶺뚮ㅄ維獄?쑜?????노뭵??紐껊퉵??"
  INSTALL_MODE="HOST"
else
  echo "??怨쀫틮 Linux VM ???삵렱 ?띠룆흮??? ???????뚮봽??嶺뚮ㅄ維獄?쑜?????노뭵??紐껊퉵??"
  INSTALL_MODE="VM"
fi

echo "ablestack-qemu-exec-tools ???노뭵????戮곗굚??紐껊퉵??."

# 0) ?熬곣뫖??雅?굝????브퀡?????? (?遊붋?브퀗??????노뭵 繞벿살탮?誘?돦??????롪퍔???
MISSING=()

need_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || MISSING+=("$c")
}

# ?熬곣뫖??嶺뚮ㅏ援앲???need_cmd jq
need_cmd virsh

# ?롪퍓?????筌뤾쑴?????㉱??雅?굝?????????リ옇????熬곣뫗??
# NOTE: hangctl????類λ룴????怨멸껀 ??뚮봽?????????獄?雅?굝?????뚮봽?????┑?ご???쒕샍????우벟 ???노뭵 ?띠럾???#       (?브퀡??????????⑤벡逾??띠룇裕???寃몃쳴??
need_cmd virt-inspector
need_cmd virt-copy-in
need_cmd virt-customize
need_cmd virt-win-reg

# ??ルㅎ臾??잙갭梨???detach??XML ?브퀗?????熬곣뫗??
# need_cmd virt-xml   # 雅?굝????????띠룆踰???熬곣뫀六?
if ((${#MISSING[@]})); then
  echo "???깅쾳 嶺뚮ㅏ援앲????熬곣뫗???紐껊퉵?? ${MISSING[*]}"
  echo "   Rocky 9 ?????dnf -y install jq libvirt-client libguestfs-tools virt-install"
  exit 1
fi

# 1) ???덈뺄 ???逾????노뭵
#    - vm_exec.sh / agent_policy_fix.sh / cloud_init_auto.sh (?リ옇???
#    - vm_autoinstall.sh (?잙?裕??
#    嶺뚮씧?긷칰???諛댁뎽 ??.sh ?筌먦끉?????蹂ㅽ깴 (vm_exec, agent_policy_fix, cloud_init_auto, vm_autoinstall)
#    ABLESTACK Host ?????vm_exec, vm_autoinstall ???筌뤾쑵??
if [[ "$INSTALL_MODE" == "HOST" ]]; then
  # ABLESTACK Host: 嶺뚣끉裕????뚮봽???怨쀬Ŧ ???노뭵
  BIN_SCRIPTS=("vm_exec.sh" "vm_autoinstall.sh" "ablestack_v2k.sh" "ablestack_vm_hangctl.sh" "ablestack_vm_ftctl.sh" "ablestack_vm_ftctl_selftest.sh" "v2k_test_install.sh")
else
  # ??怨쀫틮 VM: ???????뚮봽???怨쀬Ŧ ???노뭵
  BIN_SCRIPTS=("vm_exec.sh" "agent_policy_fix.sh" "cloud_init_auto.sh" "vm_autoinstall.sh" "ablestack_v2k.sh" "ablestack_vm_hangctl.sh" "ablestack_vm_ftctl.sh" "ablestack_vm_ftctl_selftest.sh" "v2k_test_install.sh")
fi

for script in "${BIN_SCRIPTS[@]}"; do
  src="${BIN_SRC}/${script}"
  target="${BIN_DIR}/${script%.sh}"  # .sh ?筌먦끉?????蹂ㅽ깴
  if [[ -f "$src" ]]; then
    echo "???덈뺄 ???逾?嶺뚮씧?긷칰???諛댁뎽: $target -> $(pwd)/$src"
    mkdir -p "$(dirname "$target")"
    ln -sf "$(pwd)/$src" "$target"
    chmod +x "$src"
  else
    echo "??ル쵑?? ???덈뺄 ???逾???怨몃쾳(濾곌쑬????): $src"
  fi
done

# 2) ??源녿턄??곗뒧??逾?????瑜곷턄?β돦裕녻キ????노뭵
#    - lib/*  -> ${LIB_TARGET}/
#    - payload/* -> ${LIB_TARGET}/payload/
#    (?롪퍓?????筌뤾쑴??????꾩씩?源??猿껋쾸? payload??嶺뚣볦굣??

echo "??源녿턄??곗뒧??逾????노뭵 ?롪퍔?δ빳? ${LIB_TARGET}"
mkdir -p "$LIB_TARGET"
if [[ -d "$LIB_SRC" ]]; then
  # ???逾??곌랜踰딀쾮?  cp -a "$LIB_SRC/"* "$LIB_TARGET/" 2>/dev/null || true

  # 嶺뚮ㅄ維獄????꾩씩?源??????덈뺄 雅?굝??뇡??遊붋??lib/*.sh, lib/**/**/*.sh)
  find "$LIB_TARGET" -type f -name "*.sh" -exec chmod 755 {} \;

  # (嶺뚣볝늾?? ?꾩룆?????용뉴 PS1 ?繹? ???덈뺄雅?굝??뇡??熬곣뫗????怨몃쾳. ?リ옇???苡?怨뺣┰??怨쀬Ŧ ?곌랜???  find "$LIB_TARGET" -type f \( -name "*.service" -o -name "*.ps1" \) -exec chmod 644 {} \; 2>/dev/null || true
else
  echo "??ル쵑?? ??源녿턄??곗뒧??逾????裕???븐뼚???⑤틲遊?亦껋꼶梨??? $LIB_SRC"
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
# 2.1) hangctl ??㉱????戮?츩????類λ룴???????????ル봾六????リ옇??????깆젧 ???노뭵
#   - unit: lib/hangctl/systemd/*.service|*.timer -> /etc/systemd/system/
#   - config(default): etc/ablestack-vm-hangctl.conf -> /etc/ablestack/ablestack-vm-hangctl.conf (noreplace)
#   - enable/start ??????熬곣뫀六???怨멸껀 嶺?援앾쨭????⑤벡逾??롪퍒???
HANGCTL_DEFAULT_CONF_SRC="etc/ablestack-vm-hangctl.conf"
HANGCTL_DEFAULT_CONF_DST="/etc/ablestack/ablestack-vm-hangctl.conf"
HANGCTL_UNIT_SRC_DIR="${LIB_SRC}/hangctl/systemd"

if [[ -d "${HANGCTL_UNIT_SRC_DIR}" ]]; then
  echo "hangctl systemd unit ???노뭵: ${SYSTEMD_UNIT_DIR}"
  sudo mkdir -p "${SYSTEMD_UNIT_DIR}"
  # service/timer copy
  if ls "${HANGCTL_UNIT_SRC_DIR}"/*.service >/dev/null 2>&1; then
    sudo chmod 644 "${SYSTEMD_UNIT_DIR}"/*.service 2>/dev/null || true
  fi
  if ls "${HANGCTL_UNIT_SRC_DIR}"/*.timer >/dev/null 2>&1; then
    sudo cp -a "${HANGCTL_UNIT_SRC_DIR}"/*.timer "${SYSTEMD_UNIT_DIR}/"
    sudo chmod 644 "${SYSTEMD_UNIT_DIR}"/*.timer 2>/dev/null || true
  fi
  sudo systemctl daemon-reload 2>/dev/null || true
else
  echo "??ル쵑?? hangctl systemd unit ???裕???븐뼚???⑤틲遊?亦껋꼶梨???濾곌쑬????): ${HANGCTL_UNIT_SRC_DIR}"
fi

if [[ -f "${HANGCTL_DEFAULT_CONF_SRC}" ]]; then
  echo "hangctl ?リ옇??????깆젧 ???노뭵(?브퀡????筌먦끉逾?: ${HANGCTL_DEFAULT_CONF_DST}"
  sudo mkdir -p "$(dirname "${HANGCTL_DEFAULT_CONF_DST}")"
  if [[ -f "${HANGCTL_DEFAULT_CONF_DST}" ]]; then
    echo "   ?リ옇??????깆젧 ?브퀡??? ${HANGCTL_DEFAULT_CONF_DST} (?????? ???곷쾳)"
  else
    sudo cp -a "${HANGCTL_DEFAULT_CONF_SRC}" "${HANGCTL_DEFAULT_CONF_DST}"
    sudo chmod 644 "${HANGCTL_DEFAULT_CONF_DST}" 2>/dev/null || true
    echo "   ???노뭵 ?熬곣뫁?? ${HANGCTL_DEFAULT_CONF_DST}"
  fi
else
  echo "??ル쵑?? hangctl ?リ옇??????깆젧 ???ロ깵????怨몃쾳(濾곌쑬????): ${HANGCTL_DEFAULT_CONF_SRC}"
fi

echo "??瑜곷턄?β돦裕녻キ????노뭵 ?롪퍔?δ빳? ${LIB_TARGET}/payload"
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
  # ?熬곣뫕??payload ?곌랜踰딀쾮???臾먮뺄
  rsync -a "$PAYLOAD_SRC/"" " "${LIB_TARGET}/payload/" 2>/dev/null || cp -a "$PAYLOAD_SRC/"* "${LIB_TARGET}/payload/" 2>/dev/null || true
else
  echo "??ル쵑?? ??瑜곷턄?β돦裕녻キ????裕???븐뼚???⑤틲遊?亦껋꼶梨??? $PAYLOAD_SRC"
fi

# 3) ISO ?リ옇????롪퍔?δ빳??筌먦끉逾???諛댁뎽 ?????뉖?
echo "ISO ?リ옇????롪퍔?δ빳??筌먦끉逾? ${ISO_DEFAULT_DIR}"
mkdir -p "${ISO_DEFAULT_DIR}"
if [[ -f "${ISO_DEFAULT_PATH}" ]]; then
  echo "   ISO present: ${ISO_DEFAULT_PATH}"
else
  echo "   warning: ISO not found: ${ISO_DEFAULT_PATH}"
  echo "      - place the GitHub Actions ISO artifact at this path, or"
  echo "      - override ISO_PATH_DEFAULT when running vm_autoinstall."
fi

# 4) ???삵렱 ???깆젧 ???逾???諛댁뎽
PROFILE_D="/etc/profile.d/ablestack-qemu-exec-tools.sh"
echo "???삵렱???깆젧 ???逾? ${PROFILE_D}"
cat <<EOF | sudo tee "${PROFILE_D}" >/dev/null
# ablestack-qemu-exec-tools env (hint)
export ABLESTACK_QEMU_EXEC_TOOLS_HOME="${LIB_TARGET}"
export ISO_PATH_DEFAULT="${ISO_DEFAULT_PATH}"
EOF

echo "???노뭵 ?熬곣뫁??"

echo ""
echo "???????곕뻣:"
echo "  vm_autoinstall <domain>     # ISO ?リ옇?↑??롪퍓???????吏????노뭵 (vm_autoinstall.sh)"
echo "  vm_exec                      # ?롪퍓??????戮?츩??嶺뚮ㅏ援앲?????덈뺄(QGA ?熬곣뫗??"
echo ""
echo "  ablestack_vm_hangctl health  # libvirtd ??⑤객臾????"
echo "  ablestack_vm_hangctl scan    # VM hang ???노뼌 (domstate ??QMP ?リ옇?↑?"
echo ""
echo "systemd(?띠룇裕녻????노뭵 ????ル봾六??怨쀬Ŧ ?꾩룄??? enable????類ｌ쭢):"
echo "  systemctl enable --now ablestack-vm-hangctl.timer"
echo "  systemctl status ablestack-vm-hangctl.timer --no-pager -l"
echo ""
echo "嶺뚣볝늾??"
echo "  - ?롪퍓?????筌뤾쑴??????꾩씩?源????${LIB_TARGET}/payload/* ??????????紐껊퉵??"
echo "  - ISO??${ISO_DEFAULT_PATH} ???브퀡????怨룻뒍 ??紐껊퉵??"
echo "  - Windows: ISO ?猷먮쳜???install.bat ???덈뺄 / Linux: install-linux.sh ???덈뺄"
