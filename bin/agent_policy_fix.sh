#!/bin/bash
#
# agent_policy_fix.sh - 게스트 qemu-guest-agent 정책 자동화 (RHEL/Ubuntu 계열)
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

LIBDIR="/usr/libexec/ablestack-qemu-exec-tools"
source "$LIBDIR/cloud_init_common.sh"

set -e

# 1. 배포판 감지
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DIST=$ID
else
    msg "[ERROR] 지원되지 않는 리눅스 배포판입니다." "[ERROR] Unsupported Linux distribution."
    exit 1
fi

# 2. qemu-guest-agent 설치 확인
QGA_PKG="qemu-guest-agent"
QGA_SERVICE="qemu-guest-agent"

check_service_and_start() {
    # 서비스 활성화 여부 확인 & 필요 시 enable/start
    if ! systemctl is-active --quiet "$QGA_SERVICE"; then
        msg "[WARN] $QGA_SERVICE 서비스가 활성화되어 있지 않습니다. enable 및 start를 시도합니다." "[WARN] $QGA_SERVICE service is not active. Attempting to enable and start."
        sudo systemctl enable "$QGA_SERVICE"
        sudo systemctl start "$QGA_SERVICE"
        # 재확인
        if systemctl is-active --quiet "$QGA_SERVICE"; then
            msg "[SUCCESS] $QGA_SERVICE 서비스가 활성화되었습니다." "[SUCCESS] $QGA_SERVICE service has been activated."
        else
            msg "[ERROR] $QGA_SERVICE 서비스 활성화에 실패했습니다. 로그를 확인하세요." "[ERROR] Failed to activate $QGA_SERVICE service. Please check the logs."
            exit 3
        fi
    else
        msg "[INFO] $QGA_SERVICE 서비스가 이미 활성화(실행) 상태입니다." "[INFO] $QGA_SERVICE service is already active (running)."
    fi
}

if [[ "$DIST" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
    msg "[INFO] Rocky/RHEL 계열로 감지됨." "[INFO] Detected Rocky/RHEL family."

    # 2-1. qemu-guest-agent 설치 확인 및 자동 설치 (RHEL 계열)
    if ! rpm -q $QGA_PKG >/dev/null 2>&1; then
        msg "[WARN] $QGA_PKG가 설치되어 있지 않습니다. 자동 설치를 진행합니다." "[WARN] $QGA_PKG is not installed. Proceeding with automatic installation."
        sudo dnf install -y $QGA_PKG
        if [ $? -ne 0 ]; then
            msg "[ERROR] $QGA_PKG 설치에 실패했습니다. 네트워크 또는 yum/dnf 설정을 확인하세요." "[ERROR] Failed to install $QGA_PKG. Please check your network or yum/dnf configuration."
            exit 2
        fi
        msg "[SUCCESS] $QGA_PKG 패키지 설치 완료." "[SUCCESS] $QGA_PKG package installation completed."
    else
        msg "[INFO] $QGA_PKG가 이미 설치되어 있습니다." "[INFO] $QGA_PKG is already installed."
    fi

    # 서비스 시작/활성화 확인 및 자동처리
    check_service_and_start
elif [[ "$DIST" =~ ^(ubuntu|debian)$ ]]; then
    msg "[INFO] Ubuntu/Debian 계열로 감지됨." "[INFO] Detected Ubuntu/Debian family."

    # 2-2. qemu-guest-agent 설치 확인 및 자동 설치 (Ubuntu 계열)
    if ! dpkg -l | grep -qw $QGA_PKG; then
        msg "[WARN] $QGA_PKG가 설치되어 있지 않습니다. 자동 설치를 진행합니다." "[WARN] $QGA_PKG is not installed. Proceeding with automatic installation."
        sudo apt-get update
        sudo apt-get install -y $QGA_PKG
        if [ $? -ne 0 ]; then
            msg "[ERROR] $QGA_PKG 설치에 실패했습니다. 네트워크 또는 apt 설정을 확인하세요." "[ERROR] Failed to install $QGA_PKG. Please check your network or apt configuration."
            exit 2
        fi
        msg "[SUCCESS] $QGA_PKG 패키지 설치 완료." "[SUCCESS] $QGA_PKG package installation completed."
    else
        msg "[INFO] $QGA_PKG가 이미 설치되어 있습니다." "[INFO] $QGA_PKG is already installed."
    fi

    # 서비스 시작/활성화 확인 및 자동처리
    check_service_and_start

    # Ubuntu 정책 자동화 안내
    msg "[NOTICE] Ubuntu 계열은 qemu-guest-agent의 모든 RPC 명령이 기본적으로 허용되어 있습니다." \
        "[NOTICE] In Ubuntu family, all RPC commands of qemu-guest-agent are allowed by default."
    msg "         별도의 정책 설정이나 추가 자동화 작업은 필요하지 않습니다." \
        "         No additional policy settings or automation tasks are required."
    exit 0
else
    msg "[INFO] 현재 자동화는 Rocky/RHEL/Ubuntu 계열만 지원합니다." \
        "[INFO] Currently, automation only supports Rocky/RHEL/Ubuntu families."
    exit 0
fi

# 3. 환경파일 위치 확인
CONF_FILE="/etc/sysconfig/qemu-ga"
if [ ! -f "$CONF_FILE" ]; then
    msg "[ERROR] 설정파일 $CONF_FILE 가 존재하지 않습니다." "[ERROR] Configuration file $CONF_FILE does not exist."
    exit 3
fi

# 4. allow-rpcs, block-rpcs, guest-exec/guest-exec-status 처리
ALLOW_CMDS=""
BLOCK_CMDS=""

# 기존 FILTER_RPC_ARGS 라인 파싱
ALLOW_CMDS_RAW=$(grep -E '^FILTER_RPC_ARGS=.*--allow-rpcs=' "$CONF_FILE" | sed -n 's/.*--allow-rpcs=\([^"]*\).*/\1/p' | tr -d "'\"")
BLOCK_CMDS_RAW=$(grep -E '^#.*--block-rpcs=' "$CONF_FILE" | \
    sed -n 's/.*--block-rpcs=\([^"]*\).*/\1/p' | \
    tr -d "'\"" | \
    grep -v '^\s*$' | \
    grep -v '^?$')

# allow-rpcs, block-rpcs 항목을 쉼표로 분리해서 배열화
IFS=',' read -ra ALLOW_ARR <<< "$ALLOW_CMDS_RAW"
IFS=',' read -ra BLOCK_ARR <<< "$BLOCK_CMDS_RAW"

# 중복 없이 allow-rpcs 배열에 block-rpcs 항목 전체를 병합
for cmd in "${BLOCK_ARR[@]}"; do
    skip=0
    for allow in "${ALLOW_ARR[@]}"; do
        [[ "$cmd" == "$allow" ]] && skip=1 && break
    done
    [[ $skip -eq 0 && -n "$cmd" ]] && ALLOW_ARR+=("$cmd")
done

# 배열 → 쉼표구분 문자열로 재조합
ALLOW_CMDS_FINAL=$(IFS=','; echo "${ALLOW_ARR[*]}" | sed 's/,,*/,/g;s/^,//;s/,$//')

NEW_LINE="FILTER_RPC_ARGS=\"--allow-rpcs=$ALLOW_CMDS_FINAL\""

# 5. 실제 파일 내용 수정 (백업 후 교체)
sudo cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
sudo sed -i 's|^FILTER_RPC_ARGS=.*|'"$NEW_LINE"'|' "$CONF_FILE"

msg "[INFO] $CONF_FILE의 FILTER_RPC_ARGS를 다음과 같이 수정했습니다:" "[INFO] Modified FILTER_RPC_ARGS in $CONF_FILE as follows:"
msg "      $NEW_LINE" "      $NEW_LINE"

# 6. qemu-guest-agent 서비스 재시작
msg "[INFO] qemu-guest-agent 서비스를 재시작합니다." "[INFO] Restarting qemu-guest-agent service."
sudo systemctl restart $QGA_SERVICE

# 7. 서비스 상태 확인
if systemctl is-active --quiet $QGA_SERVICE; then
    msg "[SUCCESS] qemu-guest-agent 서비스가 정상적으로 재시작되었습니다." "[SUCCESS] qemu-guest-agent service has been restarted successfully."
else
    msg "[ERROR] qemu-guest-agent 서비스가 비정상입니다. 로그 확인 요망." "[ERROR] qemu-guest-agent service is not active. Please check the logs."
    exit 4
fi